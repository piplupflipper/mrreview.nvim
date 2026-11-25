-- 実行: nvim --headless -u NONE -l tests/run.lua (リポジトリ root で)
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local passed = 0

local function assert_equal(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(string.format("%s\nexpected: %s\nactual:   %s", message or "values differ", vim.inspect(expected), vim.inspect(actual)))
    end
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        io.stderr:write("not ok - " .. name .. "\n" .. err .. "\n")
        os.exit(1)
    end
    passed = passed + 1
    print("ok - " .. name)
end

test("SHA-1 known vectors", function()
    local sha1 = require("mrreview.sha1")
    assert_equal(sha1.digest(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    assert_equal(sha1.digest("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    assert_equal(sha1.digest("The quick brown fox jumps over the lazy dog"), "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
end)

test("diff position maps insertion and deletion in the middle", function()
    local position = require("mrreview.position")

    local inserted = position.build_maps("@@ -1,0 +2,1 @@", 3)
    assert_equal(inserted.new_to_old, { [1] = 1, [2] = false, [3] = 2 })
    assert_equal(inserted.new_to_oldpos[2], 1)
    assert_equal(position.endpoint("hash", "new", 2, inserted), {
        line_code = "hash_1_2",
        type = "new",
    })

    local deleted = position.build_maps("@@ -2,1 +1,0 @@", 2)
    assert_equal(deleted.old_to_new, { [1] = 1, [2] = false, [3] = 2 })
    assert_equal(deleted.old_to_newpos[2], 1)
    assert_equal(position.endpoint("hash", "old", 2, deleted), {
        line_code = "hash_2_1",
        type = "old",
    })
end)

test("async system yields without blocking and resumes once", function()
    local async = require("mrreview.async")
    local result
    async.run(function() result = async.system({ "git", "--version" }, { text = true }) end)
    assert_equal(result, nil, "vim.system completion must resume on a later event-loop tick")
    assert(vim.wait(3000, function() return result ~= nil end), "async command timed out")
    assert_equal(result.code, 0)
    assert(result.stdout:match("^git version "), result.stdout)
end)

test("setup registers commands and keymaps can be overridden", function()
    local mrreview = require("mrreview")
    local function lhs_list()
        return vim.tbl_map(function(map) return map[1] end, mrreview._buf_maps())
    end

    mrreview.setup({})
    assert(vim.tbl_contains(lhs_list(), "<leader>x"), "default keymap")
    assert(vim.tbl_contains(lhs_list(), "]r"), "default keymap with multiple lhs")
    assert_equal(vim.fn.exists(":MrReview"), 2)

    mrreview.setup({ keymaps = { close_file = "<leader>q", peek = false, next_file = { "gn" } } })
    local lhs = lhs_list()
    assert(vim.tbl_contains(lhs, "<leader>q"), "overridden keymap")
    assert(not vim.tbl_contains(lhs, "<leader>x"), "replaced keymap")
    assert(not vim.tbl_contains(lhs, "<leader>mc"), "disabled keymap")
    assert(vim.tbl_contains(lhs, "gn") and not vim.tbl_contains(lhs, "<Tab>"), "list override")
end)

test("key help opens without any other configuration", function()
    vim.keymap.set("n", "<leader>m?", function() end, { desc = "MrReview: キーヘルプ (float)" })
    require("mrreview").show_help()
    local buf = vim.api.nvim_get_current_buf()
    assert_equal(vim.bo[buf].filetype, "mrreview-help")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(text:find(":MrReview", 1, true), text)
    assert(text:find("キーヘルプ (float)", 1, true), text)
end)

test("derived scopes include production files across components without tests", function()
    local scopes = require("mrreview.scopes")
    local root = vim.fn.tempname()
    for _, dir in ipairs({ "svc/backend", "svc/frontend" }) do
        vim.fn.mkdir(root .. "/" .. dir, "p")
        vim.fn.writefile({}, root .. "/" .. dir .. "/pyproject.toml")
    end

    local function prod_scope(files)
        for _, s in ipairs(scopes.derive(root, files)) do
            if s.kind == "prod" then return s end
        end
    end

    local files = {
        { status = "M", old = "svc/backend/app/main.py", new = "svc/backend/app/main.py" },
        { status = "A", new = "svc/backend/tests/test_main.py" },
        { status = "R", old = "svc/frontend/src/old.ts", new = "svc/frontend/src/new.ts" },
        { status = "M", old = "svc/frontend/src/a.test.ts", new = "svc/frontend/src/a.test.ts" },
        { status = "M", old = "infra/.env", new = "infra/.env" },
    }
    local prod = prod_scope(files)
    assert(prod, "production scope must exist")
    assert_equal(prod.paths, {
        ["svc/backend/app/main.py"] = true,
        ["svc/frontend/src/old.ts"] = true,
        ["svc/frontend/src/new.ts"] = true,
        ["infra/.env"] = true,
    })
    assert_equal(scopes.derive(root, files)[1].kind, "prod", "production scope comes first")

    -- テスト以外が 1 コンポーネントだけならコンポーネントの候補と同じなので出さない
    assert_equal(prod_scope({ files[1], files[2] }), nil)
    -- テストが無ければ全ファイルと同じなので出さない
    assert_equal(prod_scope({ files[1], files[3], files[5] }), nil)
    vim.fn.delete(root, "rf")
end)

test("order sorts files by the first matching pattern and keeps git order within a rank", function()
    local order = require("mrreview.order")
    local files = {
        { status = "M", old = "app/adapter/repo.py", new = "app/adapter/repo.py" },
        { status = "M", old = "app/application/b.py", new = "app/application/b.py" },
        { status = "M", old = "app/application/a.py", new = "app/application/a.py" },
        { status = "R", old = "app/legacy/model.py", new = "app/x/model.py" },
        { status = "M", old = "README.md", new = "README.md" },
        { status = "A", new = "app/domain/entity.py" },
    }
    local patterns = { "**/domain/**", "**/application/**", "**/adapter/**" }
    local paths = vim.tbl_map(function(f) return f.new end, order.sort(files, patterns))
    assert_equal(paths, {
        "app/domain/entity.py",
        "app/application/b.py",
        "app/application/a.py",
        "app/adapter/repo.py",
        "app/x/model.py",
        "README.md",
    })

    -- rename は旧パスでも一致を見る
    paths = vim.tbl_map(function(f) return f.new end, order.sort(files, { "**/legacy/**" }))
    assert_equal(paths[1], "app/x/model.py")

    -- order が空なら元の順のまま、元の配列は変えない
    assert_equal(order.sort(files, {}), files)
    assert_equal(files[1].new, "app/adapter/repo.py")
end)

test("tab comparator puts review buffers first in the given order", function()
    local order = require("mrreview.order")
    local tabs = { { id = 1 }, { id = 5 }, { id = 3 }, { id = 2 }, { id = 4 } }
    table.sort(tabs, order.tab_comparator({ [3] = 1, [5] = 2, [2] = 3 }))
    assert_equal(vim.tbl_map(function(t) return t.id end, tabs), { 3, 5, 2, 1, 4 })
end)

print(string.format("1..%d", passed))
