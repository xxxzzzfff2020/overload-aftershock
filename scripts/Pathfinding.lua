-- Pathfinding.lua
-- 34x24 固定网格 A* 寻路(§任务包C):路径缓存 + 节流 + 防火墙动态失效。
-- 纯逻辑模块,不依赖渲染。所有敌人共享同一份 solid 网格;
-- 防火墙状态改变时 World 调用 Pathfinding.invalidate(world) 使全部缓存失效。

local Config = require "Config"
local MapDef = require "MapDef"

local Pathfinding = {}

-- 8方向(对角需两侧直角格都可走,避免穿墙角)
local DIRS = {
    { 1, 0, 1.0 }, { -1, 0, 1.0 }, { 0, 1, 1.0 }, { 0, -1, 1.0 },
    { 1, 1, 1.414 }, { 1, -1, 1.414 }, { -1, 1, 1.414 }, { -1, -1, 1.414 },
}

local function key(c, r) return r * 64 + c end

local function walkable(world, c, r)
    if c < 1 or r < 1 or c > world.map.w or r > world.map.h then return false end
    return not world.solid[r][c]
end

-- [R2] 激光格惩罚(仅"避激光"实体使用:Bot 导航;敌人不吃激光伤害,不惩罚)
local function laserPenalty(world, c, r)
    if not world.laserActive then return 0 end
    for _, t in ipairs(world.map.laserTiles) do
        if t.col == c and t.row == r then return 40 end
    end
    return 0
end

-- 找 (c,r) 附近最近的可走格(目标点在墙里时的安全回退)
local function nearestOpen(world, c, r)
    if walkable(world, c, r) then return c, r end
    for radius = 1, 5 do
        for dr = -radius, radius do
            for dc = -radius, radius do
                local nc, nr = c + dc, r + dr
                if walkable(world, nc, nr) then return nc, nr end
            end
        end
    end
    return nil, nil
end

-- A*:返回世界坐标路点数组 { {x,y}, ... }(不含起点格),失败返回 nil。
-- 结果只依赖网格,与实体碰撞半径无关(半格中心行走天然留有 24px 余量,
-- 重型半径 26 借助 moveCircle 分轴滑动仍可通过 48px 宽走廊)。
function Pathfinding.findPath(world, sx, sy, tx, ty, avoidLaser)
    local sc, sr = MapDef.toTile(sx, sy)
    local tc, tr = MapDef.toTile(tx, ty)
    sc, sr = nearestOpen(world, sc, sr)
    tc, tr = nearestOpen(world, tc, tr)
    if not sc or not tc then return nil end
    if sc == tc and sr == tr then return { { x = tx, y = ty } } end

    world.pathSearches = (world.pathSearches or 0) + 1

    local open = { { c = sc, r = sr, g = 0, f = 0 } }
    local gScore = { [key(sc, sr)] = 0 }
    local cameFrom = {}
    local closed = {}
    local expanded = 0
    local maxNodes = Config.PATH.maxSearchNodes

    while true do
        local n = #open
        if n == 0 then return nil end
        -- 取 f 最小(线性扫描;开放集最多几百项,可接受)
        local bi = 1
        for i = 2, n do
            if open[i].f < open[bi].f then bi = i end
        end
        local cc, cr, cg = open[bi].c, open[bi].r, open[bi].g
        open[bi] = open[n]
        open[n] = nil
        local ck = key(cc, cr)
        if not closed[ck] then
            closed[ck] = true
            expanded = expanded + 1
            if expanded > maxNodes then return nil end

            if cc == tc and cr == tr then
                -- 回溯路径
                local rev = {}
                local k = ck
                while k do
                    local c, r = k % 64, (k - k % 64) / 64
                    local x, y = MapDef.tileCenter(c, r)
                    rev[#rev + 1] = { x = x, y = y }
                    k = cameFrom[k]
                end
                local path = {}
                for i = #rev - 1, 1, -1 do  -- 去掉起点格
                    path[#path + 1] = rev[i]
                end
                if #path == 0 then path[1] = { x = tx, y = ty } end
                path[#path] = { x = tx, y = ty }  -- 终点用精确坐标
                return path
            end

            for _, d in ipairs(DIRS) do
                local nc, nr = cc + d[1], cr + d[2]
                if walkable(world, nc, nr)
                    and (d[3] < 1.2 or (walkable(world, nc, cr) and walkable(world, cc, nr))) then
                    local nk = key(nc, nr)
                    local ng = cg + d[3]
                    if avoidLaser then ng = ng + laserPenalty(world, nc, nr) end
                    if not closed[nk] and (gScore[nk] == nil or ng < gScore[nk]) then
                        gScore[nk] = ng
                        cameFrom[nk] = ck
                        local dh = math.abs(nc - tc) + math.abs(nr - tr)
                        open[#open + 1] = { c = nc, r = nr, g = ng, f = ng + dh }
                    end
                end
            end
        end
    end
end

-- ============================================================
-- 每敌人路径跟随:节流刷新 + 缓存 + 防卡死
-- 敌人字段:e.path, e.pathIdx, e.pathTimer, e.pathTx/pathTy, e.pathVersion
-- ============================================================

-- 请求路径(带节流:间隔不足且目标没大幅移动且版本没变则复用缓存)
function Pathfinding.requestPath(world, e, tx, ty)
    local P = Config.PATH
    e.pathTimer = e.pathTimer or 0
    local moved = true
    if e.pathTx then
        local dx, dy = tx - e.pathTx, ty - e.pathTy
        moved = (dx * dx + dy * dy) > P.repathMoveThreshold * P.repathMoveThreshold
    end
    local stale = (e.pathVersion or -1) ~= world.pathVersion
    if e.path and not stale and not moved and e.pathTimer > 0 then
        return e.path
    end
    if e.pathTimer > 0 and not stale and e.path then
        -- 节流期内目标虽移动,先沿旧路走,终点微调
        e.path[#e.path] = { x = tx, y = ty }
        return e.path
    end
    -- 错峰:加入随机抖动,避免全体同帧重算
    e.pathTimer = P.repathInterval * (0.8 + math.random() * 0.4)
    e.pathTx, e.pathTy = tx, ty
    e.pathVersion = world.pathVersion
    e.path = Pathfinding.findPath(world, e.x, e.y, tx, ty, e.avoidLaser)
    e.pathIdx = 1
    return e.path
end

-- 沿路径移动一帧;返回 "arrived" | "moving" | "failed"
function Pathfinding.followPath(world, e, speed, dt)
    local path = e.path
    if not path or #path == 0 then return "failed" end
    local idx = e.pathIdx or 1
    if idx > #path then return "arrived" end
    local wp = path[idx]
    local dx, dy = wp.x - e.x, wp.y - e.y
    local len = math.sqrt(dx * dx + dy * dy)
    local arriveR = math.max(6, speed * dt * 1.2)
    if len <= arriveR then
        e.pathIdx = idx + 1
        if e.pathIdx > #path then return "arrived" end
        return "moving"
    end
    e.angle = math.atan(dy, dx)
    world:moveCircle(e, dx / len * speed * dt, dy / len * speed * dt)
    return "moving"
end

-- 卡死检测:一段时间位移不足 → 清缓存强制下次重算(返回 true 表示刚触发)
function Pathfinding.checkStuck(e, dt)
    local P = Config.PATH
    e.stuckClock = (e.stuckClock or 0) + dt
    if e.stuckClock >= P.stuckTime then
        local lx, ly = e.stuckX or e.x, e.stuckY or e.y
        local dx, dy = e.x - lx, e.y - ly
        local movedEnough = (dx * dx + dy * dy) >= P.stuckMinMove * P.stuckMinMove
        e.stuckClock = 0
        e.stuckX, e.stuckY = e.x, e.y
        if not movedEnough and e.path then
            e.path = nil
            e.pathTimer = 0
            return true
        end
    end
    return false
end

function Pathfinding.clear(e)
    e.path = nil
    e.pathIdx = 1
    e.pathTimer = 0
    e.pathTx, e.pathTy = nil, nil
end

-- 防火墙开关等地形变化后调用:全部敌人缓存路径失效
function Pathfinding.invalidate(world)
    world.pathVersion = (world.pathVersion or 0) + 1
end

return Pathfinding
