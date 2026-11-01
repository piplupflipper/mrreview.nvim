-- GitLab line_code用のSHA-1。
-- sha1sum (GNU coreutils) に依存せず、Linux / macOSの両方で同じ結果を返す。

local bit = _G.bit or require("bit")

local M = {}

local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local rol = bit.rol

local function add32(...)
    local sum = 0
    for i = 1, select("#", ...) do
        sum = sum + select(i, ...)
    end
    return band(sum, 0xffffffff)
end

function M.digest(input)
    assert(type(input) == "string", "sha1 input must be a string")

    local bytes = { input:byte(1, #input) }
    local bit_len = #input * 8
    bytes[#bytes + 1] = 0x80
    while #bytes % 64 ~= 56 do
        bytes[#bytes + 1] = 0
    end

    local high = math.floor(bit_len / 0x100000000)
    local low = bit_len % 0x100000000
    for shift = 24, 0, -8 do
        bytes[#bytes + 1] = band(rshift(high, shift), 0xff)
    end
    for shift = 24, 0, -8 do
        bytes[#bytes + 1] = band(rshift(low, shift), 0xff)
    end

    local h0 = 0x67452301
    local h1 = 0xefcdab89
    local h2 = 0x98badcfe
    local h3 = 0x10325476
    local h4 = 0xc3d2e1f0

    for chunk = 1, #bytes, 64 do
        local w = {}
        for i = 0, 15 do
            local j = chunk + i * 4
            w[i] = bor(lshift(bytes[j], 24), lshift(bytes[j + 1], 16), lshift(bytes[j + 2], 8), bytes[j + 3])
        end
        for i = 16, 79 do
            w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f = bor(band(b, c), band(bnot(b), d))
                k = 0x5a827999
            elseif i < 40 then
                f = bxor(b, c, d)
                k = 0x6ed9eba1
            elseif i < 60 then
                f = bor(band(b, c), band(b, d), band(c, d))
                k = 0x8f1bbcdc
            else
                f = bxor(b, c, d)
                k = 0xca62c1d6
            end
            local temp = add32(rol(a, 5), f, e, k, w[i])
            e = d
            d = c
            c = rol(b, 30)
            b = a
            a = temp
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
    end

    return bit.tohex(h0) .. bit.tohex(h1) .. bit.tohex(h2) .. bit.tohex(h3) .. bit.tohex(h4)
end

return M
