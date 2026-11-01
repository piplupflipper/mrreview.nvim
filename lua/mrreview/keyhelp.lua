-- mrreview.keyhelp: キーヘルプのフロート表示
--
-- keymap の desc 前置詞 ("MrReview:") を手掛かりに nvim_(buf_)get_keymap から動的に
-- 収集するので、キーを足し引きしてもヘルプ側の追従漏れが起きない。

local M = {}

-- 桁揃えした素のテキストをフロート表示する (q / <Esc> で閉じる)。
-- 桁揃えを保つため、markdown 系のプラグインが描画しない専用の filetype にする。
---@param lines string[]
---@param title string
function M.open_float(lines, title)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "mrreview-help"
    vim.bo[buf].syntax = "markdown"

    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width + 2, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 4)

    vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2 - 1),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = vim.o.winborder ~= "" and vim.o.winborder or "rounded",
        title = title,
        title_pos = "center",
    })
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close help" })
    vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close help" })
end

-- desc が prefixes のいずれかで始まる keymap を集め、桁揃え済みの行にして返す。
-- 同じ desc を持つ複数キーは "lhs1 / lhs2" に併合し、desc 順に整列する。
---@param prefixes string[]
---@param opts? { bufnr?: integer, global?: boolean, modes?: string[] }
---@return string[]
function M.keymap_rows(prefixes, opts)
    opts = opts or {}
    local modes = opts.modes or { "n", "x" }

    local lhs_by_desc, descs = {}, {}
    local function add(km)
        local desc = km.desc or ""
        for _, p in ipairs(prefixes) do
            if desc:sub(1, #p) == p then
                -- leader (space) は raw lhs に空白で入るため表記へ戻す
                local lhs = (km.lhs or ""):gsub("^ ", "<leader>"):gsub("^<Space>", "<leader>")
                if not lhs_by_desc[desc] then
                    lhs_by_desc[desc] = {}
                    descs[#descs + 1] = desc
                end
                if not vim.tbl_contains(lhs_by_desc[desc], lhs) then table.insert(lhs_by_desc[desc], lhs) end
                return
            end
        end
    end
    for _, mode in ipairs(modes) do
        if opts.bufnr then
            for _, km in ipairs(vim.api.nvim_buf_get_keymap(opts.bufnr, mode)) do
                add(km)
            end
        end
        if opts.global then
            for _, km in ipairs(vim.api.nvim_get_keymap(mode)) do
                add(km)
            end
        end
    end

    table.sort(descs)
    local rows, width = {}, 0
    for _, desc in ipairs(descs) do
        table.sort(lhs_by_desc[desc])
        local lhs = table.concat(lhs_by_desc[desc], " / ")
        width = math.max(width, vim.fn.strdisplaywidth(lhs))
        rows[#rows + 1] = { lhs = lhs, desc = desc }
    end

    local lines = {}
    local fmt = "  %-" .. math.max(width + 2, 14) .. "s %s"
    for _, r in ipairs(rows) do
        lines[#lines + 1] = string.format(fmt, r.lhs, r.desc)
    end
    return lines
end

return M
