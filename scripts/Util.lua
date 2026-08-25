-- Util.lua
-- 数学与通用工具

local Util = {}

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Util.dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

function Util.dist2(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return dx * dx + dy * dy
end

function Util.norm(dx, dy)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return 0, 0, 0 end
    return dx / len, dy / len, len
end

function Util.lerp(a, b, t)
    return a + (b - a) * t
end

-- 角度差(弧度,归一到 [-pi, pi])
function Util.angleDiff(a, b)
    local d = a - b
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return d
end

-- 简单对象池:acquire 返回复用 table,release 归还
function Util.newPool()
    local pool = { free = {} }
    function pool:acquire()
        local n = #self.free
        if n > 0 then
            local t = self.free[n]
            self.free[n] = nil
            return t
        end
        return {}
    end
    function pool:release(t)
        for k in pairs(t) do t[k] = nil end
        self.free[#self.free + 1] = t
    end
    return pool
end

-- 从数组中按 alive 标记原地压缩移除死亡元素,死亡元素归还给池(可选)
function Util.compact(list, pool)
    local j = 1
    for i = 1, #list do
        local e = list[i]
        if e.dead then
            if pool then pool:release(e) end
        else
            list[j] = e
            j = j + 1
        end
    end
    for i = #list, j, -1 do list[i] = nil end
end

return Util
