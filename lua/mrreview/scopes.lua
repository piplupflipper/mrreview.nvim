-- mrreview.scopes: 変更ファイル一覧からレビュー単位を自動導出する。
--
-- :MrReviewScope の候補は当初 setup(opts) のベタ書きだけだった。リポジトリごとの
-- ディレクトリ規約を手で書き写す必要があり、別レイアウトのモノレポを開くと 0 件の
-- スコープばかりが並ぶ。ここでは diff に出たパスだけを見て 2 軸でグループを作る。
--   * コンポーネント境界 = そのファイルから最も近い祖先のうち、プロジェクトマーカー
--     (pyproject.toml / package.json / Cargo.toml など) を持つディレクトリ。
--     モノレポはルートにも同名ファイルを置くので、リポジトリルート自身は候補外。
--     マーカーが 1 つも無ければ最上位ディレクトリで束ねる。
--   * テスト / プロダクションコード = コンポーネント根から見たパス要素とファイル名。
-- 設定ゼロで効くので、設定済みスコープ (層別など、規約を知らないと作れない単位) と
-- 併存させる。
--
-- 導出したスコープは patterns ではなく paths (この diff に実在するパスの集合) を持つ。
-- テストはディレクトリに固まっているとは限らず (frontend の *.test.ts など) glob で
-- 書き下せないため。all_files はセッション中不変なので集合で持って構わない。

local M = {}

-- 「ここが 1 つのプロジェクトの根である」ことを示すファイル。
M.default_markers = {
    "pyproject.toml",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "composer.json",
    "Gemfile",
}

-- コンポーネント根から見たパス要素がこれらのいずれかならテスト扱い。
local test_dirs = {
    test = true,
    tests = true,
    __tests__ = true,
    spec = true,
    specs = true,
    e2e = true,
}

local function is_test_path(rel)
    for _, seg in ipairs(vim.split(rel, "/", { plain = true })) do
        if test_dirs[seg] then return true end
    end
    local base = rel:match("[^/]+$") or rel
    return base:match("^test_") ~= nil
        or base:match("_test%.") ~= nil
        or base:match("%.test%.") ~= nil
        or base:match("%.spec%.") ~= nil
        or base:match("_spec%.") ~= nil
end

local function parent_dir(dir)
    local parent = vim.fs.dirname(dir)
    if parent == "." or parent == dir or parent == "/" then return "" end
    return parent
end

local function has_marker(root, dir, markers)
    for _, m in ipairs(markers) do
        if vim.fn.filereadable(root .. "/" .. dir .. "/" .. m) == 1 then return true end
    end
    return false
end

-- path (リポジトリルート相対) を含むコンポーネント根をリポジトリルート相対で返す。
-- ルート直下のファイルとマーカー未検出のルート直下ディレクトリは "" / 最上位名になる。
-- cache はディレクトリ → コンポーネント根。祖先を辿る途中も同じ答えなので全部埋める。
local function component_of(root, path, markers, cache)
    local dir = vim.fs.dirname(path)
    if dir == "." then dir = "" end

    local walked = {}
    local cur = dir
    while cur ~= "" do
        local cached = cache[cur]
        if cached ~= nil then
            for _, d in ipairs(walked) do
                cache[d] = cached
            end
            return cached
        end
        walked[#walked + 1] = cur
        if has_marker(root, cur, markers) then
            for _, d in ipairs(walked) do
                cache[d] = cur
            end
            return cur
        end
        cur = parent_dir(cur)
    end

    -- マーカーが無いツリー (infrastructure/ や docs/ など) は最上位ディレクトリで束ねる。
    -- walked は下から上へ積むので、末尾が最上位ディレクトリ。ルート直下のファイルは "" になる。
    local top = walked[#walked] or ""
    for _, d in ipairs(walked) do
        cache[d] = top
    end
    return top
end

-- files (init.lua の変更ファイルエントリ { status, old, new }) から導出スコープの配列を返す。
-- グループが 1 つしかできない場合は「全ファイル」と同義なので何も返さない。
function M.derive(root, files, markers)
    markers = markers or M.default_markers
    local cache = {}
    local groups = {}
    local comps = {}
    local comp_names = {}

    for _, f in ipairs(files) do
        local path = f.new or f.old
        if path then
            local comp = component_of(root, path, markers, cache)
            local rel = comp == "" and path or path:sub(#comp + 2)
            local test = is_test_path(rel)
            local key = comp .. "\0" .. tostring(test)
            local g = groups[key]
            if not g then
                g = { comp = comp, test = test, paths = {}, count = 0 }
                groups[key] = g
                if not comps[comp] then
                    comps[comp] = { marker = comp ~= "" and has_marker(root, comp, markers) }
                    local name = comp == "" and "(repo root)" or vim.fs.basename(comp)
                    comp_names[name] = (comp_names[name] or 0) + 1
                    comps[comp].name = name
                end
            end
            if f.new then g.paths[f.new] = true end
            if f.old then g.paths[f.old] = true end
            g.count = g.count + 1
        end
    end

    local list = vim.tbl_values(groups)
    if #list < 2 then return {} end
    -- コンポーネント根のパス順に並べ、同一コンポーネント内はプロダクションコードを先に出す。
    table.sort(list, function(a, b)
        if a.comp ~= b.comp then return a.comp < b.comp end
        return (a.test and 1 or 0) < (b.test and 1 or 0)
    end)

    local scopes = {}
    for _, g in ipairs(list) do
        local info = comps[g.comp]
        -- basename が衝突する別コンポーネントがあるときだけ、フルパスで区別する。
        local name = comp_names[info.name] > 1 and (g.comp == "" and "(repo root)" or g.comp) or info.name
        local where = g.comp == "" and "リポジトリ直下" or g.comp
        scopes[#scopes + 1] = {
            kind = g.test and "test" or (info.marker and "component" or "dir"),
            name = g.test and (name .. " (tests)") or name,
            description = g.test and (where .. " のテスト") or where,
            paths = g.paths,
            derived = true,
        }
    end
    return scopes
end

return M
