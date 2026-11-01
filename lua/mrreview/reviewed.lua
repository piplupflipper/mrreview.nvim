-- mrreview.reviewed: <leader>x で閉じたファイルの「確認済み」状態の永続化
--
-- GitLab の Viewed チェックボックスはブラウザ localStorage 保存で API が無いため、
-- 確認済みはこちら側で持つ。MR 連携セッションのみ対象で、
-- キーは MR の web_url、値は path → content_key (base 側と HEAD 側の blob sha の組)。
-- content_key が変わった = そのファイルの差分が変わったなので、読み込み側
-- (init.lua) が照合して確認済みを無効化する。
--
-- ストアは stdpath("state")/mrreview/reviewed.json の 1 ファイル。呼び出しごとに
-- 読み書きする (数 KB の JSON なのでキャッシュより単純さを優先)。

local M = {}

local PRUNE_SECONDS = 90 * 24 * 60 * 60 -- 更新が 90 日ない MR のエントリは捨てる

local function store_dir() return vim.fn.stdpath("state") .. "/mrreview" end

local function store_path() return store_dir() .. "/reviewed.json" end

-- ストア全体を読む。壊れた JSON や未作成は空として扱う (確認済みが消えるだけで
-- レビュー自体は続行できるため、エラーにしない)。
local function load()
    local f = io.open(store_path(), "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return {} end
    return decoded
end

local function save(store)
    local now = os.time()
    for key, entry in pairs(store) do
        local stale = type(entry) ~= "table" or type(entry.files) ~= "table" or next(entry.files) == nil
        if stale or (entry.updated or 0) < now - PRUNE_SECONDS then store[key] = nil end
    end
    vim.fn.mkdir(store_dir(), "p")
    local f, err = io.open(store_path(), "w")
    if not f then return nil, ("確認済み状態の保存に失敗: " .. tostring(err)) end
    f:write(vim.json.encode(store))
    f:close()
    return true
end

-- mr_key に紐づく { path = content_key } を返す (無ければ空テーブル)。
function M.get(mr_key)
    local entry = load()[mr_key]
    return (entry and type(entry.files) == "table") and entry.files or {}
end

function M.mark(mr_key, path, content_key)
    local store = load()
    local entry = store[mr_key]
    if type(entry) ~= "table" or type(entry.files) ~= "table" then
        entry = { files = {} }
        store[mr_key] = entry
    end
    entry.files[path] = content_key
    entry.updated = os.time()
    return save(store)
end

function M.unmark(mr_key, path)
    local store = load()
    local entry = store[mr_key]
    if not (entry and type(entry.files) == "table" and entry.files[path]) then return true end
    entry.files[path] = nil
    entry.updated = os.time()
    return save(store)
end

function M.clear(mr_key)
    local store = load()
    if not store[mr_key] then return true end
    store[mr_key] = nil
    return save(store)
end

return M
