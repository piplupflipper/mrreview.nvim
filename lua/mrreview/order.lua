-- mrreview.order: 変更ファイルとタブを、設定した読む順に並べる。
--
-- git diff はパスのアルファベット順に出すので、Clean Architecture の層のように
-- 依存の向きに沿って読みたくても adapter → application → domain の順になる。
-- setup({ order = { glob, ... } }) の各パターンの位置を順位とし、ファイルが最初に
-- 一致したパターンの順位で並べる。どれにも一致しないファイルは最後に置く。
-- 順位が同じファイルは git の順を保つ (安定ソート)。
--
-- タブは bufferline.nvim の表示で、既定ではバッファ番号の順に並ぶ。files を並べ替えても
-- タブは動かないので、bufferline が読み込まれていれば sort_by で同じ順に並べ直す。

local M = {}

local function matches(path, regpats)
    if not path then return false end
    for _, re in ipairs(regpats) do
        if vim.fn.match(path, re) >= 0 then return true end
    end
    return false
end

-- patterns を glob2regpat 済みの配列にしておく (ファイル数 × パターン数回変換しないため)。
local function compile(patterns)
    local out = {}
    for i, p in ipairs(patterns or {}) do
        out[i] = { vim.fn.glob2regpat(p) }
    end
    return out
end

-- entry ({ status, old, new }) の順位。rename は新旧どちらのパスでも一致を見る。
local function rank_of(entry, compiled)
    for i, regpats in ipairs(compiled) do
        if matches(entry.new, regpats) or matches(entry.old, regpats) then return i end
    end
    return #compiled + 1
end

-- files を patterns の順に並べた新しい配列を返す。patterns が空なら元の順のまま複製する。
function M.sort(files, patterns)
    local sorted = {}
    for i, f in ipairs(files) do
        sorted[i] = f
    end
    if not patterns or #patterns == 0 then return sorted end

    local compiled = compile(patterns)
    local key = {}
    for i, f in ipairs(sorted) do
        key[f] = { rank_of(f, compiled), i }
    end
    table.sort(sorted, function(a, b)
        local ka, kb = key[a], key[b]
        if ka[1] ~= kb[1] then return ka[1] < kb[1] end
        return ka[2] < kb[2]
    end)
    return sorted
end

-- bufferline の sort_by に渡す比較関数を返す。pos はバッファ番号 → 並べたい位置。
-- レビュー対象 (pos にあるバッファ) を先に、それ以外は元のバッファ番号の順で後ろに置く。
function M.tab_comparator(pos)
    return function(a, b)
        local pa, pb = pos[a.id], pos[b.id]
        if pa and pb then return pa < pb end
        if pa or pb then return pa ~= nil end
        return a.id < b.id
    end
end

-- files (相対パス) の順に bufferline のタブを並べる。bufferline が無ければ何もしない。
-- 読み込みを強制しない (lazy で未ロードなら、タブを描いていないので並べる対象も無い)。
-- bufferline はタブの要素を tabline の描画時に作るので、直前に :badd したバッファは
-- 描画するまで要素に無い。そのまま sort_by を呼ぶと新しいバッファが並べ替えから漏れ、
-- 末尾に付くので、先に tabline を描き直す。
function M.sort_tabs(root, files)
    local bufferline = package.loaded["bufferline"]
    if not bufferline or type(bufferline.sort_by) ~= "function" then return end
    pcall(vim.cmd.redrawtabline)
    local bl_state = package.loaded["bufferline.state"]
    -- 要素が空だと sort_by は警告を出すだけなので呼ばない。
    if bl_state and next(bl_state.components or {}) == nil then return end
    local pos = {}
    for i, f in ipairs(files) do
        local b = vim.fn.bufnr(root .. "/" .. f.new)
        if b ~= -1 then pos[b] = i end
    end
    pcall(bufferline.sort_by, M.tab_comparator(pos))
end

return M
