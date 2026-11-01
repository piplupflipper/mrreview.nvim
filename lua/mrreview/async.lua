-- mrreview.async: callback型APIを直列に記述するための最小coroutine runner。
-- vim.systemの完了コールバックはscheduleしてからcoroutineを再開し、editor APIを安全に呼ぶ。

local M = {}

-- starter(resume) を開始し、resume(...) の引数を返す。
function M.await(starter)
    assert(coroutine.running(), "mrreview.async.await must run inside mrreview.async.run")
    return coroutine.yield(starter)
end

-- 外部コマンドを非同期実行して完了結果を返す。
function M.system(cmd, opts)
    return M.await(function(resume)
        local ok, err = pcall(vim.system, cmd, opts or {}, function(result)
            vim.schedule(function() resume(result) end)
        end)
        if not ok then vim.schedule(function() resume({ code = -1, signal = 0, stdout = "", stderr = tostring(err) }) end) end
    end)
end

-- fnをcoroutineとして開始する。yieldされたstarterへ再開関数を渡し、完了まで接続する。
function M.run(fn, on_error)
    local co
    local function step(...)
        local ok, yielded = coroutine.resume(co, ...)
        if not ok then
            if on_error then
                on_error(yielded)
            else
                vim.notify("MrReview async error: " .. tostring(yielded), vim.log.levels.ERROR)
            end
            return
        end
        if coroutine.status(co) == "dead" then return end
        if type(yielded) ~= "function" then
            local err = "MrReview async task yielded a non-function value"
            if on_error then
                on_error(err)
            else
                vim.notify(err, vim.log.levels.ERROR)
            end
            return
        end

        local resumed = false
        yielded(function(...)
            if resumed then return end
            resumed = true
            step(...)
        end)
    end

    co = coroutine.create(fn)
    step()
    return co
end

return M
