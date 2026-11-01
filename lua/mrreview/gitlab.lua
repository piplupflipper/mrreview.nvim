-- mrreview.gitlab: glab CLI 経由の GitLab 連携
--
-- glab は「カレントディレクトリの git リモート」からプロジェクトを解決するため、
-- 全コマンドを repo root を cwd にして実行する (vim.system の cwd)。
-- 認証は glab 側 (GITLAB_TOKEN / glab auth) に委ねる。

local async = require("mrreview.async")

local M = {}

-- エラー文字列を 1 行に潰す。複数行の notify は hit-enter プロンプトを招き、
-- 放置すると nvim のメインループが止まるため、改行は空白に置換する。
local function one_line(s)
    s = (s or ""):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

-- glab を root を cwd にして非同期実行。coroutineを中断し、完了後に
-- {code, stdout, stderr} を返す。呼び出し元はmrreview.async.run内で実行すること。
-- stdin を渡すと標準入力経由でボディを送る (--input - と併用)。
local function run(root, args, stdin)
    local cmd = { "glab" }
    vim.list_extend(cmd, args)
    local opts = { cwd = root, text = true }
    if stdin then opts.stdin = stdin end
    return async.system(cmd, opts)
end

-- glab の呼び出しに失敗したとき、呼び出し側が「API が空を返した」と区別できるよう
-- exit code を含めたエラー文字列を返す。glab が PATH に無い / mise shim のバージョン
-- 未 pin といった環境不備はここに stderr ごと現れる。
local function run_json(root, args, stdin)
    if vim.fn.executable("glab") == 0 then return nil, "glab が PATH にありません" end
    local res = run(root, args, stdin)
    if res.code ~= 0 then
        local msg = one_line(res.stderr ~= "" and res.stderr or res.stdout)
        return nil, string.format("glab 実行失敗 (exit %d): %s", res.code, msg ~= "" and msg or "(出力なし)")
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if not ok then return nil, "JSON decode 失敗: " .. tostring(decoded) end
    return decoded
end

local function git_out(root, args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return nil end
    return (out:gsub("%s+$", ""))
end

-- カレントブランチ (または iid 指定) の MR を解決する。
-- iid 省略時はカレントブランチの open MR を API で一意に特定する
-- (`glab mr view` は同名 source の closed MR があると曖昧になり失敗するため使わない)。
-- 戻り: { iid, project_id, diff_refs={base_sha,start_sha,head_sha}, target_branch,
--         source_branch, web_url } / 失敗時 nil, err
function M.resolve_mr(root, iid)
    if not iid then
        local branch = git_out(root, { "rev-parse", "--abbrev-ref", "HEAD" })
        if not branch then return nil, "カレントブランチの解決に失敗" end
        -- query文字列へbranchを直接埋め込むと &, +, # 等を含むrefで壊れるため、
        -- glabのfield引数に分離してURL encodeを委ねる。
        local list, list_err = run_json(root, {
            "api",
            "--method",
            "GET",
            "projects/:id/merge_requests",
            "--field",
            "source_branch=" .. branch,
            "--field",
            "state=opened",
            "--field",
            "per_page=1",
        })
        -- 「glab が動かない」と「MR が本当に無い」を混ぜない (混ぜると環境不備が
        -- MR 不在に見え、原因の切り分けができなくなる)。
        if not list then return nil, list_err end
        if #list == 0 then return nil, "open MR が見つかりません (branch=" .. branch .. ")" end
        iid = list[1].iid
    end
    -- 単一 MR エンドポイントは diff_refs を含む。
    local mr, err = run_json(root, { "api", string.format("projects/:id/merge_requests/%d", iid) })
    if not mr then return nil, err end
    return {
        iid = mr.iid,
        project_id = mr.project_id,
        diff_refs = mr.diff_refs,
        target_branch = mr.target_branch,
        source_branch = mr.source_branch,
        web_url = mr.web_url,
    }
end

-- MR の discussion 一覧を取得する (position 付きノートを含む生の配列)。
function M.fetch_discussions(root, iid)
    local endpoint = string.format("projects/:id/merge_requests/%d/discussions?per_page=100", iid)
    return run_json(root, { "api", endpoint })
end

-- インラインコメント (新規 discussion) を投稿する。
-- position = { base_sha, start_sha, head_sha, old_path, new_path, new_line?, old_line? }
-- new_line / old_line は片側だけの行では nil を渡す (その側を送らない)。
-- GitLab はネストした position オブジェクトを要求するため、ブラケット記法
-- (position[...]=) ではなく JSON ボディを組んで --input - で送る。
-- 戻り: 投稿された discussion (table) / 失敗時 nil, err
-- position 入力から GitLab の position オブジェクトを組む (nil フィールドは省略される)。
local function build_position(position)
    return {
        base_sha = position.base_sha,
        start_sha = position.start_sha,
        head_sha = position.head_sha,
        old_path = position.old_path,
        new_path = position.new_path,
        position_type = "text",
        new_line = position.new_line, -- nil ならエンコード時に省略される
        old_line = position.old_line,
        line_range = position.line_range, -- 複数行コメント時のみ (start/end 端点)
    }
end

-- ネストした JSON を組んで --input - で POST する (Content-Type 必須、無いと HTTP 415)。
local function post_json(root, endpoint, payload)
    return run_json(root, {
        "api",
        "--method",
        "POST",
        endpoint,
        "--header",
        "Content-Type: application/json",
        "--input",
        "-",
    }, vim.json.encode(payload))
end

function M.post_comment(root, iid, body, position)
    local endpoint = string.format("projects/:id/merge_requests/%d/discussions", iid)
    return post_json(root, endpoint, { body = body, position = build_position(position) })
end

-- 既存 discussion に返信ノートを追加する。body は入れ子が無いので --raw-field で良い。
function M.reply(root, iid, discussion_id, body)
    local endpoint = string.format("projects/:id/merge_requests/%d/discussions/%s/notes", iid, discussion_id)
    return run_json(root, { "api", "--method", "POST", endpoint, "--raw-field", "body=" .. body })
end

-- discussion の resolved 状態を設定する (resolved = true/false)。
function M.set_resolved(root, iid, discussion_id, resolved)
    local endpoint = string.format("projects/:id/merge_requests/%d/discussions/%s", iid, discussion_id)
    return run_json(root, { "api", "--method", "PUT", endpoint, "--field", "resolved=" .. tostring(resolved) })
end

-- ノートを削除する。DELETE は 204 (本文なし) なので run_json は使わない。
function M.delete_note(root, iid, discussion_id, note_id)
    local endpoint = string.format("projects/:id/merge_requests/%d/discussions/%s/notes/%d", iid, discussion_id, note_id)
    local res = run(root, { "api", "--method", "DELETE", endpoint })
    if res.code ~= 0 then return nil, (res.stderr ~= "" and res.stderr or res.stdout) end
    return true
end

-- 認証中ユーザーの username (自分のノートか判定する用)。
function M.current_user(root)
    local u = run_json(root, { "api", "user" })
    return u and u.username or nil
end

-- draft note (未公開コメント) を作成する。本文は note フィールド、position は
-- discussion と同形 (line_range も可)。自分にしか見えず、publish するまで通知されない。
function M.post_draft(root, iid, body, position)
    local endpoint = string.format("projects/:id/merge_requests/%d/draft_notes", iid)
    local payload = { note = body }
    if position then payload.position = build_position(position) end
    return post_json(root, endpoint, payload)
end

-- draft note 一覧を取得する。
function M.fetch_drafts(root, iid) return run_json(root, { "api", string.format("projects/:id/merge_requests/%d/draft_notes?per_page=100", iid) }) end

-- 全 draft をまとめて公開する (GitLab の "Start a review" → submit 相当)。
function M.publish_drafts(root, iid)
    local endpoint = string.format("projects/:id/merge_requests/%d/draft_notes/bulk_publish", iid)
    local res = run(root, { "api", "--method", "POST", endpoint })
    if res.code ~= 0 then return nil, (res.stderr ~= "" and res.stderr or res.stdout) end
    return true
end

-- draft note を削除する。
function M.delete_draft(root, iid, draft_id)
    local endpoint = string.format("projects/:id/merge_requests/%d/draft_notes/%d", iid, draft_id)
    local res = run(root, { "api", "--method", "DELETE", endpoint })
    if res.code ~= 0 then return nil, (res.stderr ~= "" and res.stderr or res.stdout) end
    return true
end

return M
