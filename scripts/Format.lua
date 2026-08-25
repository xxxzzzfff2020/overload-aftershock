-- Format.lua
-- 正式冲分数字格式：底层始终保留整数，显示统一使用千位分隔。

local Format = {}

function Format.integer(value)
    local n = math.floor(tonumber(value) or 0)
    local sign = n < 0 and "-" or ""
    local digits = tostring(math.abs(n))
    local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    formatted = formatted:gsub("^,", "")
    return sign .. formatted
end

function Format.layer(value)
    return string.format("%02d", math.max(0, math.floor(tonumber(value) or 0)))
end

function Format.multiplier(value)
    return string.format("x%.1f", tonumber(value) or 1)
end

-- 兼容旧调用名；不再产生“万/亿”缩写。
Format.compact = Format.integer

return Format
