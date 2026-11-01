-- mrreview: 自作 MR diff レビューワ
--
-- diffview.nvim の「専用タブで画面を乗っ取る」挙動を避け、nvim を汎用エディタの
-- まま使いながら MR の差分を見る/コメントするためのツール。
--   * 変更ファイル一覧 = git diff --name-status -M <base> HEAD (rename/削除も判別)
--   * 各ファイルを実バッファで開く (LSP/DAP/bufferline/gitsigns すべて従来どおり)
--   * base 側 (変更前) は git の内容を scratch バッファに読み込み、ネイティブ diff で
--     左に並べる。ウィンドウは 1 組だけ作って使い回すので split は積み上がらない。
--   * カレントブランチに MR があれば自動で紐づけ、既存 discussion (💬) / 未公開 draft (📝)
--     を diff 上に表示。行末には先頭 50 桁だけ出すので、全文は <leader>mc (:MrPeek) の
--     ポップアップで読む。:MrComment で行/範囲コメント投稿、:MrThread でスレッド表示/返信/
--     resolve/削除、:MrDraftToggle/Publish/Discard で下書きの一括レビューができる (glab 経由)。
--     行に紐づかない MR 全体コメントは diff 上に置き場所がないので <leader>mn (:MrNotes)。
--   * MR 連携時、<leader>x で閉じたファイルは「確認済み」として永続化し、次回の
--     :MrReview で一覧から除外する (差分が変わっていたら自動で無効化)。:MrReview! で
--     除外せず全表示、:MrReviewed / :MrReviewedClear で解除。
--   * :MrReviewScope でレビュー単位を選び、現在の all_files から対象を切り替える。候補は
--     diff から自動導出したコンポーネント/テスト (mrreview.scopes) と、設定済みのパス
--     スコープ (層別など) の両方。この diff に該当が無い候補は並べない。
--   * レビュー中の MR / 進捗と、MR の base_sha・head_sha に対するローカル HEAD の
--     ずれを statusline に出す (M.status を lualine などから参照)。
--
-- 関連モジュール: mrreview.gitlab (glab 連携) / mrreview.position (行マッピング) /
-- mrreview.reviewed (確認済み状態の永続化) / mrreview.scopes (レビュー単位の自動導出)。

local gitlab = require("mrreview.gitlab")
local position = require("mrreview.position")
local async = require("mrreview.async")
local reviewed = require("mrreview.reviewed")
local scopes = require("mrreview.scopes")

local M = {}

local state = {
    active = false,
    root = nil, -- リポジトリルート (絶対パス)
    base = nil, -- base のラベル (表示用)
    merge_base = nil, -- 差分基点の sha (MR があれば diff_refs.base_sha)
    drift = nil, -- MR とローカル HEAD のずれ ("base" / "head") / ずれ無しは nil
    all_files = {}, -- dir 条件まで適用した全変更ファイル
    files = {}, -- 現在のスコープ/確認済み条件を適用した変更ファイル
    scope = nil, -- 現在のスコープ ({ name, patterns } / { name, paths }) / 全ファイルは nil
    scopes = {}, -- setup(opts) で受け取る名前付きパススコープ
    scope_markers = nil, -- 自動導出のプロジェクトマーカー上書き (nil は scopes.default_markers)
    derived_scopes = nil, -- all_files から導出したスコープ (初回の :MrReviewScope で構築)
    include_reviewed = false, -- :MrReview! の状態
    idx = 1, -- 現在表示中ファイルの 1-origin インデックス
    plain_idx = nil, -- diff を組まずに開いているファイルの idx (<C-o> とバイナリ)。BufEnter の自動再開を抑止 / 通常は nil
    numstat = nil, -- 変更行数 path -> { add, del } ("-" はバイナリ)。セッション開始時に 1 回だけ取る
    work_win = nil, -- 実ファイル (変更後) を表示する右ウィンドウ
    base_win = nil, -- base (変更前) を表示する左ウィンドウ
    base_buf = nil, -- base 内容の scratch バッファ (使い回す)
    mapped_bufs = {}, -- ファイル移動キーを張ったバッファ集合 (終了時に解除)
    listed_before = {}, -- セッション開始前の bufferline (buflisted) 状態
    views = {}, -- work buffer ごとの window view (cursor/topline/leftcol 等)
    mr = nil, -- 紐づく MR { iid, project_id, diff_refs, target_branch, ... } / なければ nil
    mr_err = nil, -- MR 解決に失敗した理由 (MR 不在 / glab の実行失敗など) / 成功時 nil
    discussions = {}, -- MR の discussion 一覧 (生 JSON)
    ns = nil, -- コメント表示用 extmark namespace
    me = nil, -- 認証中ユーザー名 (自分のノート削除可否の判定用)
    draft = false, -- draft モード (ON なら :MrComment は下書きになる)
    drafts = {}, -- 未公開 draft note 一覧
    reviewed_entries = {}, -- 確認済みファイルのエントリ (:MrReviewed の解除候補)
    loading = false, -- MR情報を非同期取得中
    generation = 0, -- 非同期callbackが古いsessionへ書き戻すことを防ぐ世代番号
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- 起動時の notify 連発を禁止する (各所のコメントアウトの理由):
-- 環境によっては vim.notify が素の cmdline メッセージに落ちる。メッセージが複数行に
-- 達すると hit-enter プロンプト (Press ENTER or type command to continue) が出る。
-- そのままペインを離れて放置すると nvim のメインループが止まり、attach 済み LSP サーバの
-- notification が処理されないまま蓄積して、メモリ使用量が増え続ける。
-- 単発・ユーザー操作直後のメッセージは許容されるが、起動シーケンスで連発する notify は
-- 復活させないこと。
local function notify(msg, level) vim.notify("MrReview: " .. msg, level or vim.log.levels.INFO) end

-- MR 解決中だけ表示する一時メッセージ。通常の vim.notify は次のメッセージが出るまで
-- cmdline に残るため、history=false の echo を同じ ID の空 text で更新して消す。
-- :messages の履歴にも取得中文言を残さない。
local loading_message_id

local function start_loading_message(generation)
    loading_message_id = "mrreview.start." .. generation
    vim.api.nvim_echo({ { "MrReview: MR情報を取得中…" } }, false, {
        id = loading_message_id,
    })
end

local function finish_loading_message(generation)
    local id = "mrreview.start." .. generation
    if loading_message_id ~= id then return end
    loading_message_id = nil
    vim.api.nvim_echo({ { "" } }, false, {
        id = id,
    })
end

local function session_is_current(generation) return state.active and state.generation == generation end

-- 現在sessionに紐づく非同期操作。session終了/再開始後の結果は破棄する。
local function run_session_async(fn)
    local generation = state.generation
    async.run(function() fn(generation) end, function(err)
        if session_is_current(generation) then notify("非同期処理に失敗しました: " .. tostring(err), vim.log.levels.ERROR) end
    end)
end

-- MR 連携コマンド (:MrComment / :MrThread / :MrDraftToggle) が state.mr 不在で
-- 止まるときのメッセージ。理由を出さないと「MR が本当に無い」のか「glab が動いて
-- いない」のかが区別できず、原因の切り分けができない (実例: glab の shim が常に
-- 失敗していても、表示は MR 不在と同じになる)。
-- notify は起動時に増やさず、ユーザー操作直後のこの 1 回にまとめる。
local function no_mr_reason()
    if state.mr_err then return "この diff に紐づく MR がありません: " .. state.mr_err end
    return "この diff に紐づく MR がありません"
end

-- セッション中だけ効くバッファローカルキーの定義。set_buf_maps が張り、M.stop が
-- 同じ lhs を消すので、ここ 1 箇所を直せば付け外しの両方に反映される。
-- ]c / [c はネイティブ diff のモーションを上書きするが、ファイル内は素の挙動へ
-- 委譲する (jump_hunk 参照)。normal mode だけなので d]c 等の operator 用途は無傷。
-- setup({ keymaps = { <action> = lhs | { lhs, ... } | false } }) で上書きできる。false は割り当てない。
local default_keymaps = {
    next_file = { "<Tab>", "]r" },
    prev_file = { "<S-Tab>", "[r" },
    next_hunk = "]c",
    prev_hunk = "[c",
    close_file = "<leader>x",
    toggle_folds = "<leader>z",
    peek = "<leader>mc",
    notes = "<leader>mn",
    help = "<leader>m?",
}

local keymap_actions = {
    { "next_file", function() M.next() end, "MrReview: 次のファイル" },
    { "prev_file", function() M.prev() end, "MrReview: 前のファイル" },
    { "next_hunk", function() M.next_hunk() end, "MrReview: 次の差分 (末端で次ファイルへ)" },
    { "prev_hunk", function() M.prev_hunk() end, "MrReview: 前の差分 (先頭で前ファイルへ)" },
    { "close_file", function() M.close_current() end, "MrReview: このファイルを閉じる (MR 連携時は確認済みとして記録)" },
    { "toggle_folds", function() M.toggle_folds() end, "MrReview: 未変更行の畳み/展開トグル" },
    { "peek", function() M.peek() end, "MrReview: カーソル行のコメントをポップアップ表示 (draft 含む)" },
    { "notes", function() M.notes() end, "MrReview: MR 全体コメント (行に紐づかないもの) を開く" },
    { "help", function() M.show_help() end, "MrReview: キーヘルプ (float)" },
}

-- { lhs, 関数, desc } の並びへ展開する。
local function build_buf_maps(keymaps)
    local maps = {}
    for _, action in ipairs(keymap_actions) do
        local lhs = default_keymaps[action[1]]
        if keymaps and keymaps[action[1]] ~= nil then lhs = keymaps[action[1]] end
        if lhs then
            for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
                maps[#maps + 1] = { key, action[2], action[3] }
            end
        end
    end
    return maps
end

local buf_maps = build_buf_maps()

-- 変更ファイル / base バッファに、セッション中だけ効くバッファローカルキーを張る。
-- グローバルの <Tab>/<S-Tab> (= :bn/:bp) を当該バッファでだけ上書きするので、
-- :MrReviewOff やバッファを離れれば元の挙動に戻る。
local function set_buf_maps(b)
    for _, map in ipairs(buf_maps) do
        vim.keymap.set("n", map[1], map[2], { buffer = b, silent = true, desc = map[3] })
    end
    state.mapped_bufs[b] = true
end

-- レビュー対象を bufferline に載せる。既存バッファの listed 状態は保存し、
-- スコープ切替時は対象外を一時的に隠し、セッション終了時に元へ戻す。
local function add_review_buffer(abs)
    local b = vim.fn.bufnr(abs)
    local listed_before = b ~= -1 and vim.bo[b].buflisted or true
    vim.cmd("badd " .. vim.fn.fnameescape(abs))
    b = vim.fn.bufnr(abs)
    if b == -1 then return end
    if state.listed_before[b] == nil then state.listed_before[b] = listed_before end
    vim.bo[b].buflisted = true
    set_buf_maps(b)
end

-- state.root を起点に git を実行し、trim した stdout を返す。失敗時は nil。
local function git(args)
    local cmd = { "git", "-C", state.root }
    vim.list_extend(cmd, args)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return nil end
    return trim(out)
end

local function ref_exists(ref) return git({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }) ~= nil end

-- 一覧に出す変更行数。--name-status とは別に git を叩くのは、numstat が既定で rename を
-- {a => b}/c 形式へ圧縮し、state.files 側のパスと突き合わせられなくなるためである。
-- -z なら旧パスと新パスが別フィールドで返るので、そのまま照合できる。
-- レコードは "add\tdel\tpath\0" の形で、rename と copy だけ path が空になり、続く
-- 2 フィールドが旧パスと新パスになる。バイナリは add と del がともに "-" で返る。
local function numstat_by_path()
    -- git() が使う vim.fn.system は出力中の NUL を SOH へ置き換えるため -z の区切りが
    -- 壊れる。生のバイト列が要るので、ここだけ vim.system を同期で回す。
    local res = vim.system({
        "git", "-C", state.root, "diff", "--numstat", "-z", "-M", state.merge_base, "HEAD",
    }):wait()
    local stats = {}
    if res.code ~= 0 or not res.stdout then return stats end
    local fields = vim.split(res.stdout, "\0", { plain = true })
    local i = 1
    while i <= #fields do
        local add, del, path = fields[i]:match("^(%S+)\t(%S+)\t(.*)$")
        if not add then break end
        if path == "" then
            if fields[i + 2] then stats[fields[i + 2]] = { add = add, del = del } end
            i = i + 3
        else
            stats[path] = { add = add, del = del }
            i = i + 1
        end
    end
    return stats
end

-- numstat が add と del の双方に "-" を返すものがバイナリ。base 側に並べられる
-- テキストが無いので、diff を組まずに実ファイルだけ開く (show_file 参照)。
local function is_binary(e)
    local stat = state.numstat and state.numstat[e.new]
    return stat ~= nil and stat.add == "-"
end

-- base 未指定かつ MR も無いときは develop/main/master を (remote 優先で) 順に探す。
local function resolve_base(arg)
    if arg and arg ~= "" then return ref_exists(arg) and arg or nil end
    for _, c in ipairs({ "origin/develop", "develop", "origin/main", "main", "origin/master", "master" }) do
        if ref_exists(c) then return c end
    end
    return nil
end

-- base scratch バッファを (無ければ作って) 返す。
local function ensure_base_buf()
    if state.base_buf and vim.api.nvim_buf_is_valid(state.base_buf) then return state.base_buf end
    local b = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].swapfile = false
    state.base_buf = b
    set_buf_maps(b)
    return b
end

-- base scratch に <merge_base>:<relpath> の内容を読み込む。新規追加ファイルは空。
-- base scratch に <merge_base>:<旧パス> の内容を読み込む。新規追加 (e.old=nil) は空。
local function set_base_content(e, work_ft)
    local b = ensure_base_buf()
    local lines = {}
    if e.old then
        lines = vim.fn.systemlist({ "git", "-C", state.root, "show", state.merge_base .. ":" .. e.old })
        if vim.v.shell_error ~= 0 then
            lines = {} -- 取得失敗時は空扱い
        end
    end
    vim.bo[b].modifiable = true
    vim.bo[b].readonly = false
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].modifiable = false
    vim.bo[b].readonly = true
    vim.bo[b].modified = false
    pcall(vim.api.nvim_buf_set_name, b, "mrbase://" .. state.merge_base:sub(1, 8) .. "/" .. (e.old or e.new))
    if work_ft and work_ft ~= "" then vim.bo[b].filetype = work_ft end
    return b
end

-- body の 1 行目を短く整形 (コメント表示用ラベル)。
local function snippet(body)
    local first = (body or ""):match("[^\n]*") or ""
    if vim.fn.strdisplaywidth(first) > 50 then first = vim.fn.strcharpart(first, 0, 50) .. "…" end
    return first
end

-- 1 行に 1 つ、サイン + 行末テキストでコメントを表示する (diff の行整合を保つため
-- 行を増やす virt_lines は使わない)。sign は 💬 (discussion) / 📝 (draft)。
local function place_mark(buf, line, sign, label)
    if line < 1 or line > vim.api.nvim_buf_line_count(buf) then return end
    pcall(vim.api.nvim_buf_set_extmark, buf, state.ns, line - 1, 0, {
        sign_text = sign,
        sign_hl_group = "Comment",
        virt_text = { { " " .. label, "Comment" } },
        virt_text_pos = "eol",
    })
end

-- position を見て、現在エントリ (e.new=新側パス / e.old=旧側パス) に一致する窓・行へ印を置く。
local function place_at_position(e, work_buf, pos, sign, label)
    if not (pos and pos.position_type == "text") then return end
    if pos.new_path == e.new and pos.new_line then
        place_mark(work_buf, pos.new_line, sign, label)
    elseif pos.old_path == (e.old or e.new) and pos.old_line and state.base_buf then
        place_mark(state.base_buf, pos.old_line, sign, label)
    end
end

-- 現在表示中ファイルの discussion (💬) と未公開 draft (📝) を diff 上に貼り直す。
local function place_discussion_marks(e, work_buf)
    if not state.ns then return end
    vim.api.nvim_buf_clear_namespace(work_buf, state.ns, 0, -1)
    if state.base_buf and vim.api.nvim_buf_is_valid(state.base_buf) then vim.api.nvim_buf_clear_namespace(state.base_buf, state.ns, 0, -1) end
    for _, d in ipairs(state.discussions or {}) do
        local note = d.notes and d.notes[1]
        if note then
            local mark = note.resolvable and note.resolved and " ✓" or ""
            local who = (note.author and note.author.username) or "?"
            place_at_position(e, work_buf, note.position, "💬", string.format("💬 %s%s: %s", who, mark, snippet(note.body)))
        end
    end
    for _, dn in ipairs(state.drafts or {}) do
        place_at_position(e, work_buf, dn.position, "📝", string.format("📝 draft: %s", snippet(dn.note)))
    end
end

-- 現在ファイルの discussion / draft 表示を貼り直す (投稿・返信・resolve・削除の後に呼ぶ)。
local function refresh_marks()
    local e = state.files[state.idx]
    if e and state.work_win and vim.api.nvim_win_is_valid(state.work_win) then place_discussion_marks(e, vim.api.nvim_win_get_buf(state.work_win)) end
end

-- work 窓でレビュー対象外のバッファを開いたら、無関係な base との diff を残さない。
-- セッション自体は維持し、変更ファイルへ戻るか移動コマンドを実行すれば再開できる。
local function suspend_view()
    if state.work_win and vim.api.nvim_win_is_valid(state.work_win) then
        vim.api.nvim_win_call(state.work_win, function()
            -- ジャンプで押し出された直前の変更ファイルが隠れ diff バッファとして
            -- 残らないよう ! で全解除する (見えている diff はこの base|work 組だけ)。
            vim.cmd("diffoff!")
        end)
    end
    if state.base_win and vim.api.nvim_win_is_valid(state.base_win) then pcall(vim.api.nvim_win_close, state.base_win, true) end
    state.base_win = nil
end

local function review_index(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then return nil end
    local normalized = vim.fs.normalize(name)
    for i, e in ipairs(state.files) do
        if normalized == vim.fs.normalize(state.root .. "/" .. e.new) then return i end
    end
    return nil
end

-- work buffer を離れる前の cursor / scroll 位置を保存する。bufferline のマウス切替は
-- show_file より先に BufLeave するため autocmd から、Tab 移動は show_file 冒頭から呼ぶ。
local function save_work_view(buf)
    if not (state.active and state.work_win and vim.api.nvim_win_is_valid(state.work_win)) then return end
    if vim.api.nvim_win_get_buf(state.work_win) ~= buf or not review_index(buf) then return end
    state.views[buf] = vim.api.nvim_win_call(state.work_win, function() return vim.fn.winsaveview() end)
end

-- idx 番目のファイルを base(左)|実ファイル(右) のネイティブ diff で表示する。
-- landing="last" なら最後の hunk に着地する (差分を逆向きに辿るとき用)。既定は最初。
-- landing="keep" は現在の view を、first/last は明示した hunk を優先する。
-- landing 未指定で再訪した場合は buffer ごとに保存した view を復元する。
local function show_file(idx, landing)
    if idx < 1 or idx > #state.files then return end
    -- diff 表示の要求なので、<C-o> で通常バッファにしていた指定は解除する。
    state.plain_idx = nil
    local previous_idx = state.idx
    local e = state.files[idx]
    local abs = state.root .. "/" .. e.new -- 変更後パス (削除ファイルは存在しないので空バッファ)

    -- 右 (work) ウィンドウへフォーカス。無効なら現在のウィンドウを採用。
    if not (state.work_win and vim.api.nvim_win_is_valid(state.work_win)) then state.work_win = vim.api.nvim_get_current_win() end
    vim.api.nvim_set_current_win(state.work_win)
    local current_buf = vim.api.nvim_win_get_buf(state.work_win)
    -- Tab 移動ではまだ旧 buffer、bufferline/F12 では既に移動先 buffer が表示されている。
    -- 旧 index と一致するときだけ保存し、移動先の既存 view を近似値で上書きしない。
    if review_index(current_buf) == previous_idx then save_work_view(current_buf) end
    local keep_view = landing == "keep" and vim.fn.winsaveview() or nil
    state.idx = idx

    -- 前ファイルの diff を解除してから差し替える (再計算をクリーンに)。
    -- F12 等のジャンプは diff ON のまま work 窓のバッファを差し替えるため、旧バッファが
    -- 非表示のまま diff 参加者に残って 3-way 化する。! で隠れバッファも含め全解除する
    -- (この直後に base|work を diffthis し直すので、このタブの diff は必ず再構成される)。
    vim.cmd("diffoff!")
    vim.cmd.edit(vim.fn.fnameescape(abs))
    local work_buf = vim.api.nvim_get_current_buf()
    set_buf_maps(work_buf)
    local work_ft = vim.bo[work_buf].filetype

    -- バイナリは base 側に並べられるテキストを持たない。git show の出力を
    -- systemlist で読むと改行を含む要素になり、nvim_buf_set_lines が
    -- 'replacement string' item contains newlines で拒否する。
    -- diff を組まず、実ファイルだけを 1 窓で開く。
    if is_binary(e) then
        if state.base_win and vim.api.nvim_win_is_valid(state.base_win) then
            pcall(vim.api.nvim_win_close, state.base_win, true)
        end
        state.base_win = nil
        -- base 窓が無い状態は BufEnter の再構成条件に当たるため、そのままだと
        -- show_file が呼び直されて notify が無限に続く (hit-enter プロンプトで止まる)。
        -- <C-o> と同じ仕組みで「この idx は diff を組まない」と覚えさせる。
        state.plain_idx = idx
        -- パスは載せない。セッション開始時にも出うるメッセージで、長いパスだと
        -- 1 通でも折り返して hit-enter を誘発する。対象は bufferline で分かる。
        notify("バイナリなので diff は表示しません", vim.log.levels.WARN)
        return
    end

    local base_buf = set_base_content(e, work_ft)

    -- 左 (base) ウィンドウを用意 (無ければ左に縦分割を 1 つだけ作る)。
    if not (state.base_win and vim.api.nvim_win_is_valid(state.base_win)) then
        vim.cmd("leftabove vsplit")
        state.base_win = vim.api.nvim_get_current_win()
        vim.wo[state.base_win].winfixwidth = true
    end
    vim.api.nvim_win_set_buf(state.base_win, base_buf)

    -- 両ウィンドウで diff を有効化。
    vim.api.nvim_set_current_win(state.base_win)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(state.work_win)
    vim.cmd("diffthis")
    vim.cmd("diffupdate")

    -- 未変更行も畳まずに全文を表示する (閲覧時は折りたたみを開いた状態を既定に)。
    -- foldmethod=diff のまま foldlevel を上げるだけなので、必要なら zm/zM で畳める。
    vim.wo[state.base_win].foldlevel = 99
    vim.wo[state.work_win].foldlevel = 99

    local saved_view = state.views[work_buf]
    if keep_view then
        -- bufferline の切替は保存済みcursorへ戻るが topline が近似値になる場合がある。
        -- cursor が一致すれば保存済みviewを、F12/fzf等で変わっていればジャンプ先を優先する。
        local cursor_matches = saved_view and saved_view.lnum == keep_view.lnum and saved_view.col == keep_view.col
        local view = cursor_matches and saved_view or keep_view
        pcall(vim.fn.winrestview, view)
    elseif landing == "last" then
        pcall(vim.cmd, "silent! normal! G[c") -- 最後の変更へ ([c は変更ブロック内なら先頭に戻る)
    elseif landing == "first" then
        pcall(vim.cmd, "silent! normal! gg]c")
    elseif saved_view then
        pcall(vim.fn.winrestview, saved_view) -- Tab で再訪した buffer 固有の view を復元
    else
        pcall(vim.cmd, "silent! normal! gg]c") -- 最初の変更へ
    end
    -- winrestview は scrollbind の相手を自動調整しないため、base 側も現在の相対位置へ同期する。
    pcall(vim.cmd, "syncbind")

    place_discussion_marks(e, work_buf)
    local label = (e.status == "R" or e.status == "C") and (e.old .. " → " .. e.new) or e.new
    -- 起動シーケンスでサマリと連発して hit-enter を誘発するため停止 (notify() 上のコメント参照)。
    -- 長いパスは 1 通でも折り返しで hit-enter になるため、単独でも復活させない。
    -- notify(string.format("[%d/%d] %s [%s]", idx, #state.files, label, e.status))
end

local function parse_start_args(fargs)
    local parsed = { base = nil, dir = nil }
    local i = 1
    while i <= #(fargs or {}) do
        local arg = fargs[i]
        if arg == "--dir" then
            i = i + 1
            if not fargs[i] or fargs[i] == "" or fargs[i]:sub(1, 1) == "-" then return nil, "--dir にはディレクトリを指定してください" end
            if parsed.dir then return nil, "--dir は 1 つだけ指定できます" end
            parsed.dir = fargs[i]
        elseif arg:sub(1, 6) == "--dir=" then
            if parsed.dir then return nil, "--dir は 1 つだけ指定できます" end
            parsed.dir = arg:sub(7)
            if parsed.dir == "" then return nil, "--dir にはディレクトリを指定してください" end
        elseif arg:sub(1, 1) == "-" then
            return nil, "不明なオプションです: " .. arg
        elseif parsed.base then
            return nil, "base ref は 1 つだけ指定できます"
        else
            parsed.base = arg
        end
        i = i + 1
    end
    return parsed
end

local function relative_to_root(abs, root)
    if abs == root then return "" end
    if vim.startswith(abs, root .. "/") then return abs:sub(#root + 2):gsub("/+$", "") end
    return nil
end

-- repo 相対ディレクトリへ正規化する。相対指定は repo root を優先し、そこに
-- 実在しなければ cwd 相対も試す (repo の親から <repo名>/<dir> と指定できる)。
local function normalize_review_dir(dir)
    if not dir then return nil end
    local root = vim.fs.normalize(state.root)
    local candidates
    if vim.startswith(dir, "/") then
        candidates = { vim.fs.normalize(dir) }
    else
        candidates = {
            vim.fs.normalize(root .. "/" .. dir),
            vim.fs.normalize(vim.fn.getcwd() .. "/" .. dir),
        }
    end

    -- 実在する候補を優先する。これにより cwd が repo の親でも期待どおり解決する。
    for _, abs in ipairs(candidates) do
        local rel = relative_to_root(abs, root)
        if rel ~= nil and vim.fn.isdirectory(abs) == 1 then return rel end
    end
    -- 削除済みディレクトリもレビュー可能にするため、非実在なら repo 相対候補を許可。
    local rel = relative_to_root(candidates[1], root)
    if rel ~= nil then return rel end
    return nil, "--dir はリポジトリ内を指定してください: " .. dir
end

local function path_in_dir(path, dir) return dir == "" or path == dir or vim.startswith(path, dir .. "/") end

-- 確認済み状態の永続化キー。MR 単位で持つ (web_url はインスタンスを跨いでも一意)。
local function mr_key() return state.mr and state.mr.web_url end

-- 確認済み記録用のファイル内容キー。base 側 (merge_base の旧パス) と HEAD 側 (新パス)
-- の blob sha を組にする。どちらかが変わった = そのファイルの差分が変わったなので、
-- 読み込み側で照合して確認済みを無効化する (push だけでは全ファイルを無効化しない)。
local function reviewed_content_key(e)
    local old_blob = e.old and git({ "rev-parse", state.merge_base .. ":" .. e.old }) or "-"
    local new_blob = e.status ~= "D" and git({ "rev-parse", "HEAD:" .. e.new }) or "-"
    return (old_blob or "-") .. ".." .. (new_blob or "-")
end

-- scope の patterns は Vim の glob 記法で指定する。glob2regpat を使うことで、
-- 削除済みファイルや rename 前のパスも、実ファイルを列挙せずに判定できる。
local function path_matches_pattern(path, pattern)
    return path ~= nil and vim.fn.match(path, vim.fn.glob2regpat(pattern)) >= 0
end

-- 設定済みスコープは patterns (glob)、自動導出スコープは paths (この diff に実在する
-- パスの集合) で判定する。導出側が glob でないのは mrreview.scopes の冒頭コメント参照。
local function entry_in_scope(entry, scope)
    if not scope then return true end
    if scope.paths then return (entry.new and scope.paths[entry.new]) or (entry.old and scope.paths[entry.old]) or false end
    for _, pattern in ipairs(scope.patterns or {}) do
        if path_matches_pattern(entry.new, pattern) or path_matches_pattern(entry.old, pattern) then return true end
    end
    return false
end

-- scope 選択後も MR の確認済み状態は共通で使う。スコープ外の確認済みファイルを
-- reviewed_entries に混ぜないので、:MrReviewed は現在のスコープだけを扱える。
local function files_for_scope(scope)
    local files = {}
    local reviewed_entries = {}
    for _, f in ipairs(state.all_files) do
        if entry_in_scope(f, scope) then files[#files + 1] = f end
    end

    if state.mr then
        local key = mr_key()
        local marked = reviewed.get(key)
        if next(marked) then
            local kept = {}
            for _, f in ipairs(files) do
                local saved = marked[f.new]
                if saved and saved == reviewed_content_key(f) then
                    reviewed_entries[#reviewed_entries + 1] = f
                    if state.include_reviewed then kept[#kept + 1] = f end
                else
                    if saved then reviewed.unmark(key, f.new) end
                    kept[#kept + 1] = f
                end
            end
            files = kept
        end
    end
    return files, reviewed_entries
end

local function finish_start(parsed, review_dir, generation, mr, mr_err)
    if generation ~= state.generation then return end
    local arg = parsed.base
    state.mr, state.mr_err = mr, mr_err

    -- 差分基点の決定: 明示引数 > MR の base_sha > develop/main/master。
    -- 明示引数と develop/main/master は merge-base で求めるので必ず HEAD の祖先になる。
    -- MR の base_sha だけは GitLab 側の値をそのまま使うため祖先とは限らない (from_mr)。
    local mb, base_label, from_mr
    if arg and arg ~= "" then
        if not ref_exists(arg) then return notify("base ref が見つかりません: " .. arg, vim.log.levels.ERROR) end
        mb = git({ "merge-base", arg, "HEAD" })
        base_label = arg
    elseif state.mr and state.mr.diff_refs and state.mr.diff_refs.base_sha then
        mb = state.mr.diff_refs.base_sha
        base_label = string.format("%s (MR !%d)", state.mr.target_branch, state.mr.iid)
        from_mr = true
    else
        local base = resolve_base(nil)
        if not base then
            return notify(
                "base ref が見つかりません (develop/main/master を試行)。:MrReview <ref> で指定してください",
                vim.log.levels.ERROR
            )
        end
        mb = git({ "merge-base", base, "HEAD" })
        base_label = base
    end
    if not mb then return notify("merge-base の解決に失敗しました", vim.log.levels.ERROR) end
    state.base = base_label
    state.merge_base = mb

    -- MR 由来の base_sha は「MR 側が見ている target branch」を指す。ローカルブランチが
    -- force-push 済みの MR に追従していないとこれが HEAD の祖先にならず、git diff の
    -- 結果に target branch の巻き戻しが丸ごと混入して MR と無関係なファイルが大量に
    -- 並ぶ (実例: 実 16 ファイルの MR が 88 ファイルとして表示された)。
    -- ここで 1 回だけ判定して state.drift に持ち、statusline (M.status) から参照する。
    -- 起動シーケンスで notify を連発すると hit-enter プロンプトを踏む ため、
    -- 継続中の警告は notify ではなく statusline に出す。
    state.drift = nil
    if from_mr then
        -- base_sha 自体が未 fetch のときは git diff が失敗して「変更ファイルがありません」に
        -- 落ちる。原因が分からないので、ここで理由を添えて止める (ユーザー操作直後の 1 回)。
        if not ref_exists(mb) then
            return notify(
                string.format("MR !%d の base (%s) がローカルにありません。git fetch してください", state.mr.iid, mb:sub(1, 8)),
                vim.log.levels.ERROR
            )
        end
        if git({ "merge-base", "--is-ancestor", mb, "HEAD" }) == nil then
            state.drift = "base"
        elseif git({ "rev-parse", "HEAD" }) ~= state.mr.diff_refs.head_sha then
            state.drift = "head"
        end
    end

    -- --name-status -M で rename/削除を含めて取得。各エントリは status + 旧/新パス。
    --   A → old=nil, new=path / M(等) → old=new=path / D → old=new=path (実体は削除)
    --   R,C → old=旧パス, new=新パス
    local list = git({ "diff", "--name-status", "-M", mb, "HEAD" })
    local files = {}
    for line in (list or ""):gmatch("[^\n]+") do
        local parts = vim.split(line, "\t", { plain = true })
        local st = parts[1]:sub(1, 1)
        local entry
        if st == "R" or st == "C" then
            entry = { status = st, old = parts[2], new = parts[3] }
        elseif st == "A" then
            entry = { status = "A", old = nil, new = parts[2] }
        elseif parts[2] then
            entry = { status = st, old = parts[2], new = parts[2] }
        end
        if entry and (review_dir == nil or path_in_dir(entry.new, review_dir) or (entry.old and path_in_dir(entry.old, review_dir))) then
            files[#files + 1] = entry
        end
    end
    -- 全ファイルを保持し、通常起動ではスコープを適用しない。確認済みの除外は
    -- 既存仕様どおり維持し、:MrReviewScope でスコープを切り替えても同じ状態を使う。
    state.all_files = files
    state.scope = nil
    state.derived_scopes = nil
    state.include_reviewed = parsed.bang
    local reviewed_entries
    files, reviewed_entries = files_for_scope(nil)

    if #files == 0 then
        local scope = review_dir and (", dir: " .. (review_dir == "" and "." or review_dir)) or ""
        if #reviewed_entries > 0 then
            return notify(string.format("全 %d ファイルが確認済みです (vs %s%s)。:MrReview! で表示できます", #reviewed_entries, base_label, scope))
        end
        return notify("変更ファイルがありません (vs " .. base_label .. scope .. ")")
    end

    state.files = files
    state.reviewed_entries = reviewed_entries
    -- state.files はセッション中不変なので変更行数も 1 回だけ取る。バイナリ判定
    -- (is_binary) と一覧表示 (:MrReviewFiles) の双方がこれを情報源にする。
    state.numstat = numstat_by_path()
    state.idx = 1
    state.active = true
    state.work_win = vim.api.nvim_get_current_win()
    state.base_win = nil
    state.mapped_bufs = {}
    state.listed_before = {}
    state.views = {}
    state.discussions = {}
    state.drafts = {}
    state.draft = false
    state.me = nil

    -- HEAD ずれは base 決定時に state.drift へ判定済み (statusline に出る)。
    -- discussion 等は diff 表示後に非同期取得する。

    -- bufferline に全変更ファイル (変更後パス) をタブとして並べ、各バッファに移動キーを張る
    -- (badd は listed=true のバッファを作る)。
    for _, f in ipairs(files) do
        add_review_buffer(state.root .. "/" .. f.new)
    end

    -- 起動シーケンスの notify 連発 (hit-enter 誘発) のため停止 (notify() 上のコメント参照)
    -- local mrinfo = state.mr
    --     and string.format(" / MR !%d (%d discussions, %d drafts)", state.mr.iid, #state.discussions, #state.drafts)
    --     or ""
    -- notify(string.format("%d files vs %s%s", #files, base_label, mrinfo))
    show_file(1)

    if parsed.scope_picker then
        vim.schedule(function()
            if generation == state.generation and state.active then M.pick_scope() end
        end)
    end

    if parsed.file_picker then
        vim.schedule(function()
            if generation == state.generation and state.active then M.pick_files() end
        end)
    end

    -- diffは先に操作可能にし、GitLab表示用データはバックグラウンドで順次取得する。
    if state.mr then
        local iid = state.mr.iid
        local discussions = gitlab.fetch_discussions(state.root, iid)
        if generation ~= state.generation or not state.active then return end
        state.discussions = discussions or {}

        local drafts = gitlab.fetch_drafts(state.root, iid)
        if generation ~= state.generation or not state.active then return end
        state.drafts = drafts or {}

        local me = gitlab.current_user(state.root)
        if generation ~= state.generation or not state.active then return end
        state.me = me
        refresh_marks()
    end
end

local function add_scope_buffers(files)
    for _, f in ipairs(files) do
        add_review_buffer(state.root .. "/" .. f.new)
    end
end

-- 現在の MR の全差分を再取得せず、メモリ上の all_files だけを差し替える。
-- scope 外のバッファは破棄せず、MrReview のバッファローカルキーだけ解除する。
function M.select_scope(scope)
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end

    -- 「全ファイル」はスコープ無しを表す擬似エントリなので nil に落とす。
    -- (`a and nil or b` は Lua では常に b になるので使えない)
    local selected_scope = (scope and not scope.all) and scope or nil
    local files, reviewed_entries = files_for_scope(selected_scope)
    if #files == 0 then
        local label = scope and scope.name or "全ファイル"
        return notify(label .. " に表示できる変更ファイルがありません")
    end

    local current = state.files[state.idx]
    local current_path = current and current.new
    for b in pairs(state.listed_before) do
        if vim.api.nvim_buf_is_valid(b) then vim.bo[b].buflisted = false end
    end
    for b in pairs(state.mapped_bufs) do
        if vim.api.nvim_buf_is_valid(b) then
            for _, map in ipairs(buf_maps) do
                pcall(vim.keymap.del, "n", map[1], { buffer = b })
            end
            if state.ns then vim.api.nvim_buf_clear_namespace(b, state.ns, 0, -1) end
        end
    end
    state.mapped_bufs = {}
    state.scope = selected_scope
    state.files = files
    state.reviewed_entries = reviewed_entries
    state.idx = 1
    for i, f in ipairs(files) do
        if f.new == current_path then
            state.idx = i
            break
        end
    end
    add_scope_buffers(files)
    show_file(state.idx)
    notify(string.format("スコープ: %s (%d ファイル)", scope and scope.name or "全ファイル", #files))
end

-- all_files はセッション中不変なので、導出は 1 セッションにつき 1 回だけ行う
-- (マーカー探索でファイルシステムを叩くため)。
local function derived_scopes()
    if not state.derived_scopes then state.derived_scopes = scopes.derive(state.root, state.all_files, state.scope_markers) end
    return state.derived_scopes
end

-- 変更ファイル一覧ピッカー (:MrReviewFiles / <leader>mf) ---------------------
-- 逐次送り (<Tab> / ]r) だけでは、変更ファイルが多い MR で目的のファイルへ届くまでに
-- 何度も送ることになる。state.files をフローティングウィンドウへ並べて直接選べるようにする。
-- 選択 UI に vim.ui.select ではなく fzf-lua を直に使うのは、<CR> (ネイティブ diff) と
-- <C-o> (diff なしで開く) をキーで撃ち分けるため。vim.ui.select は選択肢を 1 つ返す
-- インターフェイスしか持たないので、アクションの分岐を表現できない。

-- 表示幅で右詰めする。日本語を含む文字列に %-34s を使うとバイト数で詰めるため桁がずれる。
-- ANSI を掛ける前に呼ぶこと (エスケープ列の分だけ strdisplaywidth が狂う)。
local function pad(s, width) return s .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(s))) end

-- status 1 文字に当てる色。git の意味づけ (追加/変更/削除/移動) に合わせる。
local status_color = { A = "green", M = "yellow", D = "red", R = "blue", C = "blue" }


-- 選択したファイルを diff 無しの通常バッファとして開く (<C-o>)。セッションは維持するので
-- :MrReviewDiff で diff を貼り直せるし、<Tab> での移動も従来どおり働く。
local function open_plain(idx)
    local e = state.files[idx]
    if not e then return end
    if state.work_win and vim.api.nvim_win_is_valid(state.work_win) then
        save_work_view(vim.api.nvim_win_get_buf(state.work_win))
    end
    state.idx = idx
    -- BufEnter の autocmd はレビュー対象ファイルへ入ると show_file で diff を貼り直す。
    -- 通常バッファで開くという指定はこのフラグで覚えさせ、次に diff を要求する操作
    -- (<Tab> / ]c / :MrReviewDiff など、いずれも show_file を通る) で解除する。
    state.plain_idx = idx
    suspend_view() -- diffoff! + base 窓を閉じる
    if state.work_win and vim.api.nvim_win_is_valid(state.work_win) then vim.api.nvim_set_current_win(state.work_win) end
    vim.cmd.edit(vim.fn.fnameescape(state.root .. "/" .. e.new))
end

-- fzf へ流す行を組む。先頭に state.files のインデックスをタブ区切りで置き、--with-nth で
-- 表示から外す。fzf が返すのは加工前の行なので、選択後にそのインデックスを引ける。
local function picker_entries()
    local utils = require("fzf-lua.utils")
    local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
    local stats = state.numstat or {}

    -- +N と -N の桁は一覧全体で揃える。バイナリは数値カラムの代わりに bin と出す。
    local wa, wd = 2, 2
    for _, e in ipairs(state.files) do
        local s = stats[e.new]
        if s and s.add ~= "-" then
            wa = math.max(wa, #s.add + 1)
            wd = math.max(wd, #s.del + 1)
        end
    end

    local entries = {}
    for i, e in ipairs(state.files) do
        local s = stats[e.new]
        local counts
        if not s then
            counts = pad("", wa + 1 + wd)
        elseif s.add == "-" then
            counts = pad("bin", wa + 1 + wd)
        else
            counts = utils.ansi_codes.green(pad("+" .. s.add, wa)) .. " " .. utils.ansi_codes.red(pad("-" .. s.del, wd))
        end

        local icon = ""
        if ok_devicons then
            local name = vim.fs.basename(e.new)
            local glyph, hl = devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
            if glyph then icon = utils.ansi_from_hl(hl, glyph) .. " " end
        end

        local color = status_color[e.status]
        local status = color and utils.ansi_codes[color](e.status) or e.status
        -- rename と copy は、移動元を追わないと差分の意味が取れないので旧パスも並べる。
        local path = ((e.status == "R" or e.status == "C") and e.old) and (e.new .. " ← " .. e.old) or e.new

        entries[#entries + 1] = table.concat({
            tostring(i), "\t", pad(i == state.idx and "●" or "", 2), icon, status, "  ", counts, "  ", path,
        })
    end
    return entries
end

-- セッション中の一覧表示。セッション外からの入口は M.files。
function M.pick_files()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end

    local fzf = require("fzf-lua")
    local utils = require("fzf-lua.utils")

    local function index_of(selected)
        if not selected or not selected[1] then return nil end
        return tonumber(utils.strip_ansi_coloring(selected[1]):match("^%s*(%d+)\t"))
    end

    fzf.fzf_exec(picker_entries(), {
        prompt = "MrReview> ",
        fzf_opts = {
            ["--delimiter"] = "\t",
            ["--with-nth"] = "2..",
            ["--no-multi"] = true,
            -- fzf_opts の値は fzf-lua が shellescape するので、ここでクォートしない
            -- (自前で囲むと is_escaped に検出されて警告が出る)。
            ["--header"] = string.format("%d files vs %s   <CR> diff / <C-o> 通常バッファ", #state.files, state.base or "?"),
        },
        actions = {
            ["default"] = function(selected)
                local idx = index_of(selected)
                if idx then show_file(idx) end
            end,
            ["ctrl-o"] = function(selected)
                local idx = index_of(selected)
                if idx then open_plain(idx) end
            end,
        },
    })
end

-- セッションが無ければ base を自動解決して開始し、その直後に一覧を出す。
function M.files()
    if state.active then return M.pick_files() end
    if state.loading then return notify("MR情報を取得中です", vim.log.levels.WARN) end
    M.start({ fargs = {}, file_picker = true })
end

function M.pick_scope()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end

    -- 候補には「今この MR で実際に開けるファイル数」を出す。確認済みで全部消えている
    -- スコープを選ぶと空振りするので、件数 0 の候補は最初から並べない。
    -- 母集合を 1 回だけ作り、各候補はそれを entry_in_scope で数える (files_for_scope は
    -- 確認済み判定で git を叩くため、候補ごとに呼ぶと重い)。
    local visible = files_for_scope(nil)
    local function count_of(scope)
        local n = 0
        for _, f in ipairs(visible) do
            if entry_in_scope(f, scope) then n = n + 1 end
        end
        return n
    end

    local choices = { { kind = "all", name = "全ファイル", description = "スコープ指定なし", all = true, count = #visible } }
    -- diff から導出したコンポーネント / テストを先に、設定済みスコープ (層別など、
    -- 規約を知らないと作れない単位) を後ろに置く。
    for _, group in ipairs({ derived_scopes(), state.scopes }) do
        for _, scope in ipairs(group) do
            local n = count_of(scope)
            if n > 0 then
                choices[#choices + 1] = vim.tbl_extend("force", scope, { count = n })
            end
        end
    end

    if #choices == 1 then return notify("この diff から分割できるスコープがありません", vim.log.levels.WARN) end

    vim.ui.select(choices, {
        prompt = "レビューするスコープを選択",
        format_item = function(scope)
            return string.format("[%s] %s %3d  %s", pad(scope.kind or "scope", 9), pad(scope.name, 34), scope.count, scope.description or "")
        end,
    }, function(choice)
        if choice then M.select_scope(choice) end
    end)
end

function M.scope()
    if state.active then return M.pick_scope() end
    if state.loading then return notify("MR情報を取得中です", vim.log.levels.WARN) end
    M.start({ fargs = {}, scope_picker = true })
end

function M.start(opts)
    local parsed, parse_err = parse_start_args(opts and opts.fargs or {})
    if not parsed then return notify(parse_err, vim.log.levels.ERROR) end
    parsed.bang = (opts and opts.bang) or false -- ! は確認済みファイルも一覧に載せる
    parsed.scope_picker = opts and opts.scope_picker or false
    parsed.file_picker = opts and opts.file_picker or false -- :MrReviewFiles からの開始

    -- 既にセッション中または読込中なら一旦畳み、古い非同期処理を無効化する。
    if state.active or state.loading then M.stop() end

    -- 現在バッファのあるディレクトリ (無ければ cwd) を起点にリポジトリルートを解決。
    local bufpath = vim.api.nvim_buf_get_name(0)
    local dir = bufpath ~= "" and vim.fn.fnamemodify(bufpath, ":h") or vim.fn.getcwd()
    local root = vim.fn.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
    if vim.v.shell_error ~= 0 then return notify("git リポジトリ内で実行してください", vim.log.levels.ERROR) end
    state.root = trim(root)

    local review_dir, dir_err = normalize_review_dir(parsed.dir)
    if dir_err then return notify(dir_err, vim.log.levels.ERROR) end

    state.generation = state.generation + 1
    local generation = state.generation
    state.loading = true
    start_loading_message(generation)

    async.run(function()
        -- カレントブランチのMRを解決する。MRが無くてもローカルdiffは開始する。
        local mr, mr_err = gitlab.resolve_mr(state.root)
        if generation ~= state.generation then return end
        state.loading = false
        finish_loading_message(generation)
        finish_start(parsed, review_dir, generation, mr, mr_err)
    end, function(err)
        if generation ~= state.generation then return end
        state.loading = false
        finish_loading_message(generation)
        notify("MR情報の取得に失敗しました: " .. tostring(err), vim.log.levels.ERROR)
    end)
end

function M.next()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    show_file(math.min(state.idx + 1, #state.files))
end

function M.prev()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    show_file(math.max(state.idx - 1, 1))
end

function M.redraw()
    if state.active then show_file(state.idx) end
end

-- ]c / [c を 1 段進める。ファイル内で動けたらそれで終わり。動けなければ (= その
-- ファイルの端の hunk にいる) 隣の変更ファイルへ移り、進行方向側の端の hunk に
-- 着地する。レビュー対象の最初/最後の差分に達していたら false。
local function step_hunk(back)
    local before = vim.api.nvim_win_get_cursor(0)[1]
    pcall(vim.cmd, back and "silent! normal! [c" or "silent! normal! ]c")
    if vim.api.nvim_win_get_cursor(0)[1] ~= before then return true end
    local nidx = state.idx + (back and -1 or 1)
    if nidx < 1 or nidx > #state.files then return false end
    show_file(nidx, back and "last" or "first")
    return true
end

-- ファイル境界を越えて差分を辿る (]c / [c)。ファイル単位で移動する ]r / [r と違い、
-- hunk 単位で MR 全体を頭から潰していくための動線。
local function jump_hunk(back)
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    -- base 窓で押しても work 窓を基準に動かす。ファイル跨ぎでは show_file が work 窓へ
    -- フォーカスするため、揃えないと途中で焦点が飛ぶ。base 窓のカーソルは cursorbind で追従する。
    if state.work_win and vim.api.nvim_win_is_valid(state.work_win) then vim.api.nvim_set_current_win(state.work_win) end
    local count = math.max(vim.v.count, 1)
    if not vim.wo.diff then
        -- 対象外バッファ表示中 (suspend) は素の挙動に任せる。
        pcall(vim.cmd, string.format("silent! normal! %d%s", count, back and "[c" or "]c"))
        return
    end
    for _ = 1, count do
        if not step_hunk(back) then return notify(back and "最初の差分です" or "最後の差分です") end
    end
end

function M.next_hunk() jump_hunk(false) end

function M.prev_hunk() jump_hunk(true) end

-- 現在のファイルをレビュー対象から外して閉じる。:bd だと work 窓に表示中の
-- バッファを消すため base|work 分割ごと壊れる。先に隣のファイルへ移ってから
-- 旧バッファ (非表示) を削除することで、分割レイアウトを保ったままタブだけ消す。
function M.close_current()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    local removed = state.files[state.idx]
    local buf = vim.fn.bufnr(state.root .. "/" .. removed.new)

    -- MR 連携時は「確認済み」として永続化し、次回 :MrReview で一覧から除外する。
    -- (:MrReview! で既に確認済みのファイルを閉じ直しても解除候補は重複させない)
    local mark_note = ""
    if state.mr then
        local ok, err = reviewed.mark(mr_key(), removed.new, reviewed_content_key(removed))
        if not ok then notify(tostring(err), vim.log.levels.ERROR) end
        local present = false
        for _, x in ipairs(state.reviewed_entries) do
            if x.new == removed.new then
                present = true
                break
            end
        end
        if not present then table.insert(state.reviewed_entries, removed) end
        mark_note = ", 確認済みとして記録"
    end

    if #state.files <= 1 then
        notify("最後のファイルです。セッションを終了します" .. (state.mr and " (確認済みとして記録)" or ""))
        return M.stop()
    end
    table.remove(state.files, state.idx)
    if state.idx > #state.files then state.idx = #state.files end
    -- 先に別ファイルを work 窓へ表示 → 旧バッファは非表示になり、消しても分割は残る
    show_file(state.idx)
    if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) and buf ~= vim.api.nvim_get_current_buf() then
        state.mapped_bufs[buf] = nil
        state.listed_before[buf] = nil
        state.views[buf] = nil
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    notify(string.format("閉じました: %s (残り %d ファイル%s)", removed.new, #state.files, mark_note))
end

-- 確認済みを解除して一覧へ戻す。除外されていたファイルは末尾に追加し、bufferline の
-- タブと移動キーも復元する (:MrReview! では一覧に居るので解除候補から外すだけ)。
local function restore_reviewed(e)
    reviewed.unmark(mr_key(), e.new)
    for i, x in ipairs(state.reviewed_entries) do
        if x.new == e.new then
            table.remove(state.reviewed_entries, i)
            break
        end
    end
    for _, f in ipairs(state.files) do
        if f.new == e.new then return end
    end
    state.files[#state.files + 1] = e
    add_review_buffer(state.root .. "/" .. e.new)
end

-- 確認済みファイルを選んで解除する。戻したファイルをそのまま表示して見直しを始める。
function M.reviewed_pick()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    if #state.reviewed_entries == 0 then return notify("確認済みのファイルはありません") end
    vim.ui.select(state.reviewed_entries, {
        prompt = "確認済みを解除するファイルを選択",
        format_item = function(e) return e.new end,
    }, function(choice)
        if not choice then return end
        restore_reviewed(choice)
        for i, f in ipairs(state.files) do
            if f.new == choice.new then
                show_file(i)
                break
            end
        end
        notify("確認済みを解除しました: " .. choice.new)
    end)
end

-- この MR の確認済みを全解除する (除外されていたファイルは一覧へ戻す)。
function M.reviewed_clear()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    local n = #state.reviewed_entries
    for _, e in ipairs(vim.list_extend({}, state.reviewed_entries)) do
        restore_reviewed(e)
    end
    -- 現在の diff に現れないパスの記録も残さないよう、キーごと消す。
    reviewed.clear(mr_key())
    if n == 0 then return notify("確認済みのファイルはありません") end
    notify(string.format("確認済み %d 件を解除して一覧へ戻しました", n))
end

-- 未変更行 (foldmethod=diff のフォールド) を base|work 両ペアで一括トグルする。
-- foldlevel=99 (全開) ⇄ 0 (未変更を畳む)。標準の zR/zM/za も併用可。
function M.toggle_folds()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    local open = state.work_win and vim.api.nvim_win_is_valid(state.work_win) and (vim.wo[state.work_win].foldlevel or 0) >= 99
    local lvl = open and 0 or 99
    for _, w in ipairs({ state.base_win, state.work_win }) do
        if w and vim.api.nvim_win_is_valid(w) then vim.wo[w].foldlevel = lvl end
    end
    notify(open and "未変更行を畳みました" or "全行を表示しました")
end

-- 入力用の小さな scratch popup を開き、ZZ で本文を on_submit に渡す / ZQ で破棄。
local function comment_popup(title, on_submit)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.cmd("botright 10split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].winbar = title .. "  —  ZZ:送信  ZQ:破棄"
    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    vim.keymap.set("n", "ZZ", function()
        local body = trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
        close()
        if body == "" then return notify("空コメントのため中止") end
        on_submit(body)
    end, { buffer = buf })
    vim.keymap.set("n", "ZQ", function()
        close()
        notify("コメントを破棄しました")
    end, { buffer = buf })
    vim.cmd("startinsert")
end

-- パス文字列のSHA-1 (GitLabのline_code用)。外部コマンドには依存しない。
local function path_sha1(relpath) return require("mrreview.sha1").digest(relpath) end

-- カーソル行 (または :'<,'> のビジュアル範囲) に MR コメントを投稿する。
-- work窓=新側 / base窓=旧側。範囲のときは line_range を組む (アンカーは末尾行)。
function M.comment(opts)
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    local side = (vim.api.nvim_get_current_win() == state.base_win) and "old" or "new"
    local e = state.files[state.idx]
    local work_buf = vim.api.nvim_win_get_buf(state.work_win)
    local new_total = vim.api.nvim_buf_line_count(work_buf)

    -- ビジュアル範囲 (:'<,'>MrComment) なら opts.range>0。それ以外はカーソル行。
    local l1, l2
    if opts and opts.range and opts.range > 0 then
        l1, l2 = opts.line1, opts.line2
    else
        l1 = vim.fn.line(".")
        l2 = l1
    end

    -- rename は旧/新パス両方を渡し -M で 1 つの diff として対応付ける。
    local args = { "diff", "-U0", "-M", state.merge_base, "HEAD", "--" }
    if e.old and e.old ~= e.new then
        vim.list_extend(args, { e.old, e.new })
    else
        table.insert(args, e.new)
    end
    local diff = git(args) or ""
    local maps = position.build_maps(diff, new_total)

    local dr = state.mr.diff_refs
    local full = {
        base_sha = dr.base_sha,
        start_sha = dr.start_sha,
        head_sha = dr.head_sha,
        old_path = e.old or e.new,
        new_path = e.new,
    }
    -- line_code 用のパス: 新側=new_path / 旧側=old_path。
    local lc_path = (side == "old") and (e.old or e.new) or e.new
    local where

    if l1 == l2 then
        local pos = position.line_position(side, l1, maps)
        if not pos then return notify("この行にはコメントできません (diff 範囲外)", vim.log.levels.WARN) end
        full.new_line, full.old_line = pos.new_line, pos.old_line
        where = pos.new_line and ("+" .. pos.new_line) or ("-" .. pos.old_line)
    else
        local psha = path_sha1(lc_path)
        if not psha then return notify("path の SHA1 計算に失敗しました", vim.log.levels.ERROR) end
        local s_ep = position.endpoint(psha, side, l1, maps)
        local e_ep = position.endpoint(psha, side, l2, maps)
        local anchor = position.line_position(side, l2, maps)
        if not (s_ep and e_ep and anchor) then return notify("範囲にコメントできない行が含まれます (diff 範囲外)", vim.log.levels.WARN) end
        full.new_line, full.old_line = anchor.new_line, anchor.old_line
        full.line_range = { start = s_ep, ["end"] = e_ep }
        where = string.format("%d-%d", l1, l2)
    end

    local title = string.format("%sMR !%d  %s:%s", state.draft and "[draft] " or "", state.mr.iid, e.new, where)
    comment_popup(title, function(body)
        local draft = state.draft
        local root, iid = state.root, state.mr.iid
        run_session_async(function(generation)
            local res, err
            if draft then
                res, err = gitlab.post_draft(root, iid, body, full)
            else
                res, err = gitlab.post_comment(root, iid, body, full)
            end
            if not session_is_current(generation) then return end
            if not res then return notify("投稿失敗: " .. tostring(err), vim.log.levels.ERROR) end
            notify(draft and "draft を保存しました (:MrDraftPublish で公開)" or "コメントを投稿しました")

            local discussions = gitlab.fetch_discussions(root, iid)
            if not session_is_current(generation) then return end
            state.discussions = discussions or state.discussions
            local drafts = gitlab.fetch_drafts(root, iid)
            if not session_is_current(generation) then return end
            state.drafts = drafts or state.drafts
            refresh_marks()
        end)
    end)
end

-- draft モードの toggle / 公開 / 破棄。
function M.draft_toggle()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    state.draft = not state.draft
    notify(state.draft and "draft モード ON (:MrComment は下書きに / :MrDraftPublish で一括公開)" or "draft モード OFF")
end

function M.draft_publish()
    if not (state.active and state.mr) then return notify("MR セッションがありません", vim.log.levels.WARN) end
    local n = #(state.drafts or {})
    if n == 0 then return notify("公開する draft がありません") end
    local root, iid = state.root, state.mr.iid
    run_session_async(function(generation)
        local ok, err = gitlab.publish_drafts(root, iid)
        if not session_is_current(generation) then return end
        if not ok then return notify("公開失敗: " .. tostring(err), vim.log.levels.ERROR) end
        notify(n .. " 件の draft を公開しました")
        local discussions = gitlab.fetch_discussions(root, iid)
        if not session_is_current(generation) then return end
        state.discussions = discussions or {}
        local drafts = gitlab.fetch_drafts(root, iid)
        if not session_is_current(generation) then return end
        state.drafts = drafts or {}
        refresh_marks()
    end)
end

function M.draft_discard()
    if not (state.active and state.mr) then return notify("MR セッションがありません", vim.log.levels.WARN) end
    local n = #(state.drafts or {})
    if n == 0 then return notify("破棄する draft がありません") end
    if vim.fn.confirm(n .. " 件の draft を破棄しますか?", "&Yes\n&No", 2) ~= 1 then return end
    local root, iid = state.root, state.mr.iid
    local drafts = vim.deepcopy(state.drafts)
    run_session_async(function(generation)
        for _, dn in ipairs(drafts) do
            local ok, err = gitlab.delete_draft(root, iid, dn.id)
            if not session_is_current(generation) then return end
            if not ok then return notify("draft破棄失敗: " .. tostring(err), vim.log.levels.ERROR) end
        end
        notify(n .. " 件の draft を破棄しました")
        local current = gitlab.fetch_drafts(root, iid)
        if not session_is_current(generation) then return end
        state.drafts = current or {}
        refresh_marks()
    end)
end

-- カーソル位置 (work窓=新側 / base窓=旧側) にコメントの position が載っているかを
-- 判定する述語を返す。discussion と draft で同じ判定を使う。
local function cursor_position_matcher()
    local side = (vim.api.nvim_get_current_win() == state.base_win) and "old" or "new"
    local e = state.files[state.idx]
    local line = vim.fn.line(".")
    return function(pos)
        if not (e and pos and pos.position_type == "text") then return false end
        if side == "new" then return pos.new_path == e.new and pos.new_line == line end
        return pos.old_path == (e.old or e.new) and pos.old_line == line
    end
end

-- カーソル位置の行にある discussion を集める。
local function discussions_at_cursor()
    local at = cursor_position_matcher()
    local matches = {}
    for _, d in ipairs(state.discussions or {}) do
        if at(d.notes and d.notes[1] and d.notes[1].position) then matches[#matches + 1] = d end
    end
    return matches
end

-- カーソル位置の行にある未公開 draft を集める。draft は :MrThread の対象外なので、
-- ポップアップ (M.peek) だけが全文を読む手段になる。
local function drafts_at_cursor()
    local at = cursor_position_matcher()
    local matches = {}
    for _, dn in ipairs(state.drafts or {}) do
        if at(dn.position) then matches[#matches + 1] = dn end
    end
    return matches
end

-- discussion の全ノートを表示用の行配列にする。
local function build_thread(d)
    local lines = {}
    for _, n in ipairs(d.notes or {}) do
        local who = (n.author and n.author.username) or "?"
        local mark = n.resolved and "  ✓resolved" or ""
        lines[#lines + 1] = string.format("── @%s%s ──", who, mark)
        for _, bl in ipairs(vim.split(n.body or "", "\n", { plain = true })) do
            lines[#lines + 1] = bl
        end
        lines[#lines + 1] = ""
    end
    return lines
end

local open_thread -- 前方宣言 (resolve/削除後に開き直すため)

local function reopen_thread(disc_id)
    for _, x in ipairs(state.discussions or {}) do
        if x.id == disc_id then return open_thread(x) end
    end
end

-- discussion をフロートに表示し、r=返信 / x=resolve切替 / D=自ノート削除 / q=閉じる。
open_thread = function(d)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local lines = build_thread(d)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local width = math.min(90, math.floor(vim.o.columns * 0.7))
    local height = math.max(3, math.min(#lines, math.floor(vim.o.lines * 0.6)))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        border = vim.o.winborder,
        title = string.format(" MR !%d  r:返信 x:resolve切替 D:自分のを削除 q:閉じる ", state.mr.iid),
    })

    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    local function after_change(generation, root, iid)
        local discussions = gitlab.fetch_discussions(root, iid)
        if not session_is_current(generation) then return false end
        state.discussions = discussions or state.discussions
        refresh_marks()
        return true
    end

    local kopts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set("n", "q", close, kopts)
    vim.keymap.set("n", "<Esc>", close, kopts)

    vim.keymap.set("n", "r", function()
        close()
        comment_popup(string.format("MR !%d reply", state.mr.iid), function(body)
            local root, iid = state.root, state.mr.iid
            run_session_async(function(generation)
                local ok, err = gitlab.reply(root, iid, d.id, body)
                if not session_is_current(generation) then return end
                if not ok then return notify("返信失敗: " .. tostring(err), vim.log.levels.ERROR) end
                notify("返信しました")
                if after_change(generation, root, iid) then reopen_thread(d.id) end
            end)
        end)
    end, kopts)

    vim.keymap.set("n", "x", function()
        local resolved = d.notes[1] and d.notes[1].resolved
        local root, iid = state.root, state.mr.iid
        run_session_async(function(generation)
            local ok, err = gitlab.set_resolved(root, iid, d.id, not resolved)
            if not session_is_current(generation) then return end
            if not ok then return notify("resolve 切替失敗: " .. tostring(err), vim.log.levels.ERROR) end
            notify(resolved and "unresolved にしました" or "resolved にしました")
            if not after_change(generation, root, iid) then return end
            close()
            reopen_thread(d.id)
        end)
    end, kopts)

    vim.keymap.set("n", "D", function()
        local mine = {}
        for _, n in ipairs(d.notes or {}) do
            if n.author and n.author.username == state.me then mine[#mine + 1] = n end
        end
        if #mine == 0 then return notify("このスレッドに自分のノートはありません", vim.log.levels.WARN) end
        if vim.fn.confirm(string.format("自分のノート %d 件を削除しますか?", #mine), "&Yes\n&No", 2) ~= 1 then return end
        local root, iid = state.root, state.mr.iid
        run_session_async(function(generation)
            for _, n in ipairs(mine) do
                local ok, err = gitlab.delete_note(root, iid, d.id, n.id)
                if not session_is_current(generation) then return end
                if not ok then return notify("削除失敗: " .. tostring(err), vim.log.levels.ERROR) end
            end
            notify("削除しました")
            if not after_change(generation, root, iid) then return end
            close()
            reopen_thread(d.id) -- 残っていれば開き直し、全削除で消えていれば何もしない
        end)
    end, kopts)
end

-- 行末の virt_text は 50 桁で切っていて全文が読めず、:MrThread は返信/resolve のための
-- modal で draft を扱わない。読むだけの経路として、gitsigns の blame (<leader>gb) と
-- 同じ操作感のポップアップを用意する。カーソル相対・非フォーカスで開き、カーソルを
-- 動かすと閉じる。中身のコピーは <leader>yp (core/keymaps.lua の全 float 共通キー)。
local function open_peek(lines, title)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local width = vim.fn.strdisplaywidth(title)
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.max(20, math.min(width, math.floor(vim.o.columns * 0.7)))
    -- 折り返す行があるので、実際に必要な高さは行数より増えうる。
    local height = 0
    for _, l in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    height = math.max(1, math.min(height, math.floor(vim.o.lines * 0.5)))

    local win = vim.api.nvim_open_win(buf, false, {
        relative = "cursor",
        row = 1,
        col = 1,
        width = width,
        height = height,
        style = "minimal",
        border = vim.o.winborder,
        title = title,
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true

    -- 非フォーカスで開くため、閉じるキーは元バッファ側に一時的に張る (gitsigns と同じ)。
    -- カーソル移動でポップアップごと畳み、一時マップも必ず外す。
    local src = vim.api.nvim_get_current_buf()
    local function close()
        if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
        pcall(vim.keymap.del, "n", "q", { buffer = src })
        pcall(vim.keymap.del, "n", "<Esc>", { buffer = src })
    end
    local kopts = { buffer = src, nowait = true, silent = true, desc = "MrReview: コメントポップアップを閉じる" }
    vim.keymap.set("n", "q", close, kopts)
    vim.keymap.set("n", "<Esc>", close, kopts)
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "InsertEnter" }, { buffer = src, once = true, callback = close })
end

-- カーソル行の discussion (全ノート) と draft を 1 つの表示内容にまとめる。
local function build_peek(discussions, drafts)
    local lines = {}
    for _, d in ipairs(discussions) do
        vim.list_extend(lines, build_thread(d))
    end
    for _, dn in ipairs(drafts) do
        -- draft は自分のものだけが返るので author は出さない。既存スレッドへの
        -- 返信 draft は discussion_id を持つので、単発コメントと区別して出す。
        lines[#lines + 1] = dn.discussion_id and "── 📝 draft (返信) ──" or "── 📝 draft ──"
        vim.list_extend(lines, vim.split(dn.note or "", "\n", { plain = true }))
        lines[#lines + 1] = ""
    end
    while lines[#lines] == "" do
        lines[#lines] = nil
    end
    return lines
end

-- カーソル行のコメントをポップアップで読む (<leader>mc / :MrPeek)。
-- 返信・resolve・削除は :MrThread 側。
function M.peek()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    local discussions, drafts = discussions_at_cursor(), drafts_at_cursor()
    local total = #discussions + #drafts
    if total == 0 then return notify("この行にコメントはありません") end
    open_peek(build_peek(discussions, drafts), string.format(" MR !%d  コメント %d 件 ", state.mr.iid, total))
end

-- 行に紐づかない MR 全体へのコメント (GitLab の Overview タブに並ぶもの) を集める。
-- discussions API は "added 29 commits" のような system note も同じ配列で返すので、
-- 人が書いたものだけに絞る。position を持つものは diff 上に出るのでここでは扱わない。
local function mr_level_discussions()
    local matches = {}
    for _, d in ipairs(state.discussions or {}) do
        local note = d.notes and d.notes[1]
        if note and not note.system and not note.position then matches[#matches + 1] = d end
    end
    return matches
end

-- MR 全体コメントを開く (複数あれば選択)。行に紐づかないので diff 上に置き場所がなく、
-- ここが唯一の閲覧経路になる。開いた後は行コメントと同じ open_thread なので、返信と
-- 自ノート削除はそのまま使える (resolve は GitLab 側が非対応で、押すとエラーになる)。
function M.notes()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    local matches = mr_level_discussions()
    if #matches == 0 then
        return notify("MR 全体コメントはありません")
    elseif #matches == 1 then
        open_thread(matches[1])
    else
        vim.ui.select(matches, {
            prompt = "開く MR 全体コメントを選択",
            format_item = function(d)
                local n = d.notes[1]
                return string.format("@%-16s %s", (n.author and n.author.username) or "?", snippet(n.body))
            end,
        }, function(choice)
            if choice then open_thread(choice) end
        end)
    end
end

-- カーソル行の discussion スレッドを開く (複数あれば選択)。
function M.thread()
    if not state.active then return notify("セッションがありません。:MrReview で開始してください", vim.log.levels.WARN) end
    if not state.mr then return notify(no_mr_reason(), vim.log.levels.WARN) end
    local matches = discussions_at_cursor()
    if #matches == 0 then
        return notify("この行に discussion はありません")
    elseif #matches == 1 then
        open_thread(matches[1])
    else
        vim.ui.select(matches, {
            prompt = "開く discussion を選択",
            format_item = function(d) return snippet(d.notes[1].body) end,
        }, function(choice)
            if choice then open_thread(choice) end
        end)
    end
end

-- statusline に出す drift の表示。base ずれは差分そのものが別物になるので error 色、
-- head ずれは行位置がずれうるだけなので warn 色。意味と対処は :DotfilesHelp に載せる。
local drift_labels = {
    base = { label = "⚠base不一致", hl = "DiagnosticError" },
    head = { label = "⚠HEADずれ", hl = "DiagnosticWarn" },
}

-- statusline (lualine) 用の状態。1 描画ごとに呼ばれるので git は叩かず state だけを
-- 読む (drift は finish_start で 1 回だけ判定済み)。表示不要なら nil を返す。
-- 戻り値: { text = 進捗の表示文字列, label = drift の表示文字列 | nil,
--           hl = label に当てるハイライトグループ名 | nil }。
-- text と label を分けるのは lualine 側の都合。色を動的に変える (color に関数を渡す)
-- コンポーネントは、関数が nil を返したとき mode 別 hl の解決が非 focus 扱いに落ちて
-- 非アクティブ色で描かれる。drift の有無で色が変わる label だけを別コンポーネントに
-- 切り出し、常に色を持たせることでこれを避ける。
function M.status()
    if state.loading then return { text = "MrReview …" } end
    if not state.active then return nil end
    local text = state.mr and string.format("MR !%d %d/%d", state.mr.iid, state.idx, #state.files)
        or string.format("vs %s %d/%d", state.base or "?", state.idx, #state.files)
    local drift = drift_labels[state.drift]
    return { text = text, label = drift and drift.label, hl = drift and drift.hl }
end

-- キーヘルプ (<leader>m?)。レビューバッファの "MrReview:" desc キーを
-- mrreview.keyhelp で動的収集する。コマンド類は keymap では
-- ないので静的ブロックで併記する (定義は同じこのファイル内にあり、ドリフトしにくい)。
function M.show_help()
    local keyhelp = require("mrreview.keyhelp")

    local lines = { "# MrReview キーヘルプ", "", "## キーマップ (レビューバッファ / 動的)" }
    local rows = keyhelp.keymap_rows({ "MrReview:" }, { bufnr = 0, global = true })
    if #rows == 0 then
        lines[#lines + 1] = "  (レビューバッファ外です。:MrReview で開始)"
    else
        vim.list_extend(lines, rows)
    end

    -- setup() が登録する user command は全てここに載せる (登録側とこの一覧は同じ
    -- ファイル内にあるので、片方だけ足すとすぐ気付ける)。
    vim.list_extend(lines, {
        "",
        "## コマンド (開始・移動)",
        "  :MrReview [base] [--dir <dir>]  レビュー開始 (! で確認済みも表示)",
        "  :MrReviewScope                  レビュー単位を fzf で選択して開始/切替",
        "  :MrReviewFiles                  変更ファイル一覧から選んで表示 (<CR> diff / <C-o> 通常)",
        "  :MrReviewNext / :MrReviewPrev   次 / 前の変更ファイル",
        "  :MrReviewDiff                   diff 表示を現在バッファに同期",
        "  :MrReviewFold                   未変更行の畳み/展開トグル",
        "  :MrReviewClose                  現在ファイルを閉じる (MR 連携時は確認済み)",
        "  :MrReviewed / :MrReviewedClear  確認済みの個別解除 / 全解除",
        "  :MrReviewOff                    セッション終了",
        "",
        "## コマンド (コメント)",
        "  :MrComment                      カーソル行/選択範囲に MR コメント投稿",
        "  :MrPeek                         カーソル行のコメントをポップアップ表示 (読むだけ)",
        "  :MrThread                       カーソル行の discussion (返信/resolve/削除)",
        "  :MrNotes                        MR 全体コメント (行に紐づかないもの) を開く",
        "  :MrDraftToggle / :MrDraftPublish / :MrDraftDiscard  draft 切替/一括公開/全破棄",
    })

    -- セッション状態 (statusline と同じ情報源)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## セッション"
    local st = M.status()
    if not st then
        lines[#lines + 1] = "  (なし)"
    else
        lines[#lines + 1] = "  " .. st.text .. (st.label and (" " .. st.label) or "")
        -- MR 全体コメントは diff 上に出ないので、件数はここでしか気付けない。
        local overview = #mr_level_discussions()
        if overview > 0 then lines[#lines + 1] = string.format("  MR 全体コメント %d 件 (:MrNotes)", overview) end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "q / <Esc> で閉じる"

    keyhelp.open_float(lines, " MrReview help ")
end

function M.stop()
    if not state.active and not state.loading then return end
    local was_active = state.active
    local loading_generation = state.loading and state.generation or nil

    -- 進行中のGitLab callbackを先に無効化してからwindow/stateを破棄する。
    state.generation = state.generation + 1
    state.loading = false
    if loading_generation then finish_loading_message(loading_generation) end

    if was_active then
        pcall(vim.cmd, "diffoff!")
        if state.base_win and vim.api.nvim_win_is_valid(state.base_win) then pcall(vim.api.nvim_win_close, state.base_win, true) end
        if state.base_buf and vim.api.nvim_buf_is_valid(state.base_buf) then pcall(vim.api.nvim_buf_delete, state.base_buf, { force = true }) end
        -- バッファローカルの移動キー解除 + コメント表示の extmark を消す。
        for b in pairs(state.mapped_bufs) do
            if vim.api.nvim_buf_is_valid(b) then
                for _, map in ipairs(buf_maps) do
                    pcall(vim.keymap.del, "n", map[1], { buffer = b })
                end
                if state.ns then vim.api.nvim_buf_clear_namespace(b, state.ns, 0, -1) end
            end
        end
        for b, listed in pairs(state.listed_before) do
            if vim.api.nvim_buf_is_valid(b) then vim.bo[b].buflisted = listed end
        end
    end
    state.mapped_bufs = {}
    state.listed_before = {}
    state.views = {}
    state.active = false
    state.work_win, state.base_win, state.base_buf = nil, nil, nil
    state.root, state.base, state.merge_base = nil, nil, nil
    state.all_files, state.files = {}, {}
    state.scope, state.include_reviewed = nil, false
    state.derived_scopes = nil
    state.drift = nil
    state.mr, state.mr_err, state.discussions = nil, nil, {}
    state.drafts, state.draft, state.me = {}, false, nil
    state.reviewed_entries = {}
    state.plain_idx = nil
    state.numstat = nil
    if was_active then notify("ended") end
end

-- :MrReview の補完候補にローカル/リモートブランチを出す。
local function complete_ref(arglead)
    local out = vim.fn.systemlist({
        "git",
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads",
        "refs/remotes",
    })
    if vim.v.shell_error ~= 0 then return {} end
    return vim.tbl_filter(function(b) return b:find(arglead, 1, true) == 1 end, out)
end

-- テストから現在のキー割り当てを確かめるための参照。
function M._buf_maps() return buf_maps end

function M.setup(opts)
    buf_maps = build_buf_maps(opts and opts.keymaps)
    state.scopes = (opts and opts.scopes) or {}
    state.scope_markers = opts and opts.scope_markers
    state.ns = vim.api.nvim_create_namespace("mrreview")
    local group = vim.api.nvim_create_augroup("MrReview", { clear = true })
    vim.api.nvim_create_autocmd("BufLeave", {
        group = group,
        callback = function(args) save_work_view(args.buf) end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(args)
            if not state.active then return end
            local entered_win = vim.api.nvim_get_current_win()
            -- :edit / bufferline による切替が完了してから表示を同期する。
            vim.schedule(function()
                if not state.active or not vim.api.nvim_win_is_valid(entered_win) or vim.api.nvim_win_get_buf(entered_win) ~= args.buf then return end

                -- base 窓で直接ファイルを開いた場合は、そちらを通常の編集窓として残す。
                if entered_win == state.base_win and args.buf ~= state.base_buf then
                    -- 押し出された base バッファや旧 work バッファが隠れ diff 参加者として
                    -- 残らないよう、タブの diff を丸ごと解除してから窓を整理する。
                    vim.api.nvim_win_call(entered_win, function() vim.cmd("diffoff!") end)
                    if state.work_win and vim.api.nvim_win_is_valid(state.work_win) then pcall(vim.api.nvim_win_close, state.work_win, true) end
                    state.work_win = entered_win
                    state.base_win = nil
                elseif entered_win ~= state.work_win then
                    -- base 窓が base バッファを出している間は diff がセッションの一部なので触らない。
                    -- (show_file は diffthis のために base 窓へ一度フォーカスするので、ここで
                    --  解除すると scrollbind まで落ちてスクロール同期が失われる)
                    if entered_win == state.base_win and args.buf == state.base_buf then return end
                    -- :new / :split は元窓の window-local な diff を継承するため、新窓だけ解除する。
                    if vim.wo[entered_win].diff then vim.api.nvim_win_call(entered_win, function() vim.cmd("diffoff") end) end
                    return
                end

                local idx = review_index(args.buf)
                if idx then
                    -- <C-o> で通常バッファとして開いたファイルとバイナリは diff 無しで残す。
                    if state.plain_idx == idx then return end
                    if idx ~= state.idx or not (state.base_win and vim.api.nvim_win_is_valid(state.base_win)) or not vim.wo[state.work_win].diff then
                        -- F12 / <C-o> / fzf 等のジャンプで来た場合はその着地点を尊重する
                        -- (hunk への強制着地は <Tab>/]c 等の明示的な移動コマンド側で行う)。
                        show_file(idx, "keep")
                    end
                else
                    suspend_view()
                end
            end)
        end,
        desc = "MrReview の diff 表示を現在バッファに同期",
    })
    vim.api.nvim_create_user_command("MrReview", M.start, {
        nargs = "*",
        bang = true,
        complete = complete_ref,
        desc = "MR diff レビュー開始 ([base] [--dir <repo root/cwd相対dir>]、! で確認済みも表示)",
    })
    vim.api.nvim_create_user_command("MrReviewScope", M.scope, {
        desc = "MR diff レビュー開始/切替 (fzf でスコープを選択。diff から自動導出 + 設定済み)",
    })
    vim.api.nvim_create_user_command("MrReviewFiles", M.files, {
        desc = "MrReview: 変更ファイル一覧から選んで表示 (<CR> diff / <C-o> 通常バッファ)",
    })
    vim.api.nvim_create_user_command("MrReviewNext", M.next, { desc = "MrReview: 次の変更ファイル" })
    vim.api.nvim_create_user_command("MrReviewPrev", M.prev, { desc = "MrReview: 前の変更ファイル" })
    vim.api.nvim_create_user_command("MrReviewDiff", M.redraw, { desc = "MrReview: 現在ファイルの diff を貼り直す" })
    vim.api.nvim_create_user_command(
        "MrReviewClose",
        M.close_current,
        { desc = "MrReview: 現在ファイルを閉じる (一覧から除外、MR 連携時は確認済みとして永続化)" }
    )
    vim.api.nvim_create_user_command("MrReviewed", M.reviewed_pick, { desc = "MrReview: 確認済みファイルを選んで解除 (一覧へ戻す)" })
    vim.api.nvim_create_user_command("MrReviewedClear", M.reviewed_clear, { desc = "MrReview: この MR の確認済みを全解除" })
    vim.api.nvim_create_user_command("MrReviewFold", M.toggle_folds, { desc = "MrReview: 未変更行の畳み/展開トグル" })
    vim.api.nvim_create_user_command("MrComment", M.comment, { range = true, desc = "MrReview: カーソル行/選択範囲に MR コメントを投稿" })
    vim.api.nvim_create_user_command("MrPeek", M.peek, { desc = "MrReview: カーソル行のコメントをポップアップ表示 (draft 含む、読むだけ)" })
    vim.api.nvim_create_user_command("MrThread", M.thread, { desc = "MrReview: カーソル行の discussion を開く (返信/resolve/削除)" })
    vim.api.nvim_create_user_command("MrNotes", M.notes, { desc = "MrReview: MR 全体コメント (行に紐づかないもの) を開く" })
    vim.api.nvim_create_user_command("MrDraftToggle", M.draft_toggle, { desc = "MrReview: draft モード切替 (:MrComment を下書きに)" })
    vim.api.nvim_create_user_command("MrDraftPublish", M.draft_publish, { desc = "MrReview: 溜めた draft を一括公開" })
    vim.api.nvim_create_user_command("MrDraftDiscard", M.draft_discard, { desc = "MrReview: 未公開 draft を全破棄" })
    vim.api.nvim_create_user_command("MrReviewOff", M.stop, { desc = "MrReview: セッション終了" })
end

return M
