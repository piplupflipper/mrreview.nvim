-- mrreview.position: diff の行番号対応付け
--
-- GitLab のインラインコメントは position に「変更後ファイルの行 (new_line)」と
-- 「変更前ファイルの行 (old_line)」の両方を要求する (文脈行は両方、追加行は new のみ、
-- 削除行は old のみ)。複数行コメント (line_range) では各端点を line_code
--   SHA1(path)_<old_pos>_<new_pos>
-- で指定する。old_pos / new_pos は「その行までに数えた旧/新の行番号」で、追加行でも
-- 旧側の running 値 (直前の旧行) を持つ。
--
-- これらをカーソル行から正しく求めるため、git diff -U0 のハンクヘッダだけを走査して
-- 行番号を再構成する。-U0 なので各ハンクは "@@ -os,oc +ns,nc @@" だけで「旧側 oc 行
-- 削除 / 新側 nc 行追加」が確定し、ハンク間の文脈行は旧/新を等速で進めれば再構成できる。
-- count=0 のrange startは「変更位置の直前行」を表すため、その側だけ start+1 を
-- 最初の変更行として扱う。これによりファイル途中の挿入・削除でもハンク手前の
-- 文脈行を正しく対応付けられる。

local M = {}

-- @param diff string      git diff -U0 の出力
-- @param new_total integer  変更後ファイルの総行数
-- @return table {
--   new_to_old   = {[new]=old|false},  -- 文脈行は対応 old / 追加行は false
--   old_to_new   = {[old]=new|false},  -- 文脈行は対応 new / 削除行は false
--   new_to_oldpos= {[new]=old(number)},-- line_code 用 running old (追加行でも number)
--   old_to_newpos= {[old]=new(number)},-- line_code 用 running new (削除行でも number)
--   added        = {[new]=true},       -- 追加行フラグ
--   removed      = {[old]=true},        -- 削除行フラグ
-- }
function M.build_maps(diff, new_total)
    local n2o, o2n = {}, {}
    local noldpos, onewpos = {}, {}
    local added, removed = {}, {}
    local old, new = 1, 1

    for line in diff:gmatch("[^\n]+") do
        local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if os_ then
            os_ = tonumber(os_)
            ns = tonumber(ns)
            oc = oc == "" and 1 or tonumber(oc)
            nc = nc == "" and 1 or tonumber(nc)
            local old_change = oc == 0 and os_ + 1 or os_
            local new_change = nc == 0 and ns + 1 or ns
            -- ハンク手前の文脈行 (diff には出ない) を等速で埋める。
            while old < old_change and new < new_change do
                n2o[new], o2n[old] = old, new
                noldpos[new], onewpos[old] = old, new
                old, new = old + 1, new + 1
            end
            for _ = 1, oc do -- 旧側だけの行 (削除)
                o2n[old] = false
                onewpos[old] = new - 1 -- 直前の新行
                removed[old] = true
                old = old + 1
            end
            for _ = 1, nc do -- 新側だけの行 (追加)
                n2o[new] = false
                noldpos[new] = old - 1 -- 直前の旧行
                added[new] = true
                new = new + 1
            end
        end
    end

    -- 最後のハンク以降の文脈行を埋める。
    while new <= new_total do
        n2o[new], o2n[old] = old, new
        noldpos[new], onewpos[old] = old, new
        old, new = old + 1, new + 1
    end

    return {
        new_to_old = n2o,
        old_to_new = o2n,
        new_to_oldpos = noldpos,
        old_to_newpos = onewpos,
        added = added,
        removed = removed,
    }
end

-- カーソル位置 (side="new"=変更後窓 / "old"=変更前窓, 1-origin line) から
-- GitLab position の {new_line, old_line} を組む。コメント不可なら nil。
-- 片側だけの行 (追加/削除) は対応行が false → その側を nil にする。
function M.line_position(side, line, maps)
    if side == "new" then
        local old = maps.new_to_old[line]
        if old == nil then
            return nil -- マッピング外 (ファイル末尾超過など)
        end
        return { new_line = line, old_line = old or nil }
    else
        local new = maps.old_to_new[line]
        if new == nil then return nil end
        return { old_line = line, new_line = new or nil }
    end
end

-- line_range の端点 1 つ分 { line_code, type } を返す (範囲コメント用)。コメント不可なら nil。
-- type は追加行="new" / 削除行="old" / 文脈行=nil。line_code は SHA1(path)_<old>_<new>。
function M.endpoint(path_sha1, side, line, maps)
    local oldpos, newpos, typ
    if side == "new" then
        if maps.added[line] then
            oldpos, newpos, typ = maps.new_to_oldpos[line], line, "new"
        else
            oldpos, newpos = maps.new_to_old[line], line
            if not oldpos then return nil end
        end
    else
        if maps.removed[line] then
            oldpos, newpos, typ = line, maps.old_to_newpos[line], "old"
        else
            newpos, oldpos = maps.old_to_new[line], line
            if not newpos then return nil end
        end
    end
    return { line_code = string.format("%s_%d_%d", path_sha1, oldpos, newpos), type = typ }
end

return M
