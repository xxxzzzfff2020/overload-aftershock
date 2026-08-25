-- EnemyAI.lua
-- 敌人 AI:枯竭阶段的巡逻/可疑/警戒/追击/丢失/搜索/返回(§6.2),
-- 过载阶段的全员扑向玩家。视野 = 扇形 + 墙体遮挡(格网采样射线)。
-- [R1] 追击/丢失/返回/诱饵状态使用网格 A* 寻路(Pathfinding),带节流与防卡死;
--      寻路不绕过视野系统——只有看见/刚看见/搜索中才会追踪玩家(§7.4)。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local Pathfinding = require "Pathfinding"
local TraceHeat = require "TraceHeat"

local EnemyAI = {}

local function fairGate(world)
    return world.layerPlan and world.layerPlan.fairGate or nil
end

-- 053A：无尽从第 11 层开始，普通巡逻小怪在“已经看见玩家”的观察/警戒段
-- 也要以既有巡逻速度收近距离。它们仍须经过 suspect → alert → chase 的完整状态机，
-- 不增加敌人、视野、追击速度或 L1–L10 的压力；割草怪本来就是 chase，不走这里。
local function endlessInvestigatesWhileSeeing(world, e)
    return world.endless == true and (world.round or 0) >= 11
        and not e.isHorde and (e.kind == "drone" or e.kind == "glitch")
end

-- 射线是否被墙阻挡(步进采样)
local function losClear(world, x1, y1, x2, y2)
    local dx, dy, len = Util.norm(x2 - x1, y2 - y1)
    if len < 1 then return true end
    local step = Config.TILE / 3
    local n = math.floor(len / step)
    for i = 1, n do
        local x, y = x1 + dx * step * i, y1 + dy * step * i
        if world:isSolidAt(x, y) then return false end
    end
    return true
end
EnemyAI.losClear = losClear

-- 敌人能否看见玩家(视距×轮次/隐身修正、扇形角、LOS)
function EnemyAI.canSeePlayer(world, e)
    local p = world.player
    local cfg = Config.ENEMIES[e.kind]
    local diff = world:difficulty()
    local range = cfg.viewRange * diff.viewMul
    local d = Util.dist(e.x, e.y, p.x, p.y)
    -- 隐身切断“实时目标信息”，不是无敌：已经贴身的敌人仍会在最后暴露点
    -- 完成本帧接触攻击，但不能继续刷新玩家位置形成永久锁定。
    if world.cloakLeft > 0 then return false end
    if d > range then return false end
    if cfg.viewAngle < 360 and d > e.radius * 3 then
        local toP = math.atan(p.y - e.y, p.x - e.x)
        if math.abs(Util.angleDiff(toP, e.angle)) > math.rad(cfg.viewAngle) * 0.5 then
            return false
        end
    end
    return losClear(world, e.x, e.y, p.x, p.y)
end

-- 玩家处于该敌人视野边缘(用于枯竭威胁预警,§8.3:1.15 倍视距内且朝向大致对准)
function EnemyAI.nearViewEdge(world, e)
    local p = world.player
    if world.cloakLeft > 0 then return false end
    local cfg = Config.ENEMIES[e.kind]
    local diff = world:difficulty()
    local range = cfg.viewRange * diff.viewMul
    local d = Util.dist(e.x, e.y, p.x, p.y)
    if d > range * 1.15 or d < range * 0.7 then return false end
    if cfg.viewAngle < 360 then
        local toP = math.atan(p.y - e.y, p.x - e.x)
        if math.abs(Util.angleDiff(toP, e.angle)) > math.rad(cfg.viewAngle) * 0.65 then
            return false
        end
    end
    return losClear(world, e.x, e.y, p.x, p.y)
end

-- 直线移动(近距离/巡逻用)
local function moveToward(world, e, tx, ty, speed, dt)
    local dx, dy, len = Util.norm(tx - e.x, ty - e.y)
    -- 到点阈值必须大于单帧步长,否则在路点附近来回抖动
    if len <= math.max(6, speed * dt * 1.2) then return true end
    e.angle = math.atan(dy, dx)
    world:moveCircle(e, dx * speed * dt, dy * speed * dt)
    return false
end

-- 寻路移动:有视线且距离近时直线;否则走 A* 路径。返回是否到达。
local function movePathed(world, e, tx, ty, speed, dt)
    local d = Util.dist(e.x, e.y, tx, ty)
    if d <= math.max(6, speed * dt * 1.2) then return true end
    if d < Config.TILE * 2.2 and losClear(world, e.x, e.y, tx, ty) then
        Pathfinding.clear(e)
        return moveToward(world, e, tx, ty, speed, dt)
    end
    Pathfinding.requestPath(world, e, tx, ty)
    local st = Pathfinding.followPath(world, e, speed, dt)
    if st == "arrived" then return true end
    if st == "failed" then
        -- 无解:直线兜底(贴墙滑动),下次节流窗口再试
        return moveToward(world, e, tx, ty, speed, dt)
    end
    return false
end

local function patrolTarget(e)
    if not e.patrol or #e.patrol == 0 then return nil end
    local wp = e.patrol[e.patrolIdx]
    return MapDef.tileCenter(wp[1], wp[2])
end

local function advancePatrol(e)
    if not e.patrol then return end
    e.patrolIdx = e.patrolIdx % #e.patrol + 1
end

-- 找最近的有效诱饵
local function nearestDecoy(world, e)
    local best, bestD = nil, Config.DEPLETED.decoyRadius + 0.0
    for _, d in ipairs(world.decoys) do
        if not d.dead then
            local dist = Util.dist(d.x, d.y, e.x, e.y)
            if dist < bestD then best, bestD = d, dist end
        end
    end
    return best
end

-- 攻击判定(接触)
local function tryAttack(world, e, dt)
    local cfg = Config.ENEMIES[e.kind]
    e.attackCd = math.max(0, e.attackCd - dt)
    local p = world.player
    local d = Util.dist(e.x, e.y, p.x, p.y)
    if d < e.radius + p.radius + 6 and e.attackCd <= 0 then
        e.attackCd = cfg.attackCd
        world:damagePlayer(cfg.damage, e.x, e.y)
        world:addFx("hitspark", { x = p.x, y = p.y, color = "red", dur = 0.2 })
    end
end

-- 过载阶段真正翻转：普通敌人徒劳围堵，高价值目标逃散/守点，重型低频预警拦截。
local function nearestGuardTarget(world, e)
    if e.guardTarget and not e.guardTarget.dead then return e.guardTarget end
    local target, bestD = nil, math.huge
    for _, rl in ipairs(world.relays) do
        if not rl.dead then
            local d = Util.dist2(e.x, e.y, rl.x, rl.y)
            if d < bestD then target, bestD = rl, d end
        end
    end
    for _, fw in ipairs(world.firewalls) do
        if not fw.dead then
            local d = Util.dist2(e.x, e.y, fw.x, fw.y)
            if d < bestD then target, bestD = fw, d end
        end
    end
    e.guardTarget = target
    return target
end

local function fleePlayer(world, e, speed, dt)
    local p = world.player
    local dx, dy, len = Util.norm(e.x - p.x, e.y - p.y)
    if len < 1 then dx, dy = math.cos(e.angle), math.sin(e.angle) end
    local tx, ty = e.x + dx * 180, e.y + dy * 180
    moveToward(world, e, tx, ty, speed, dt)
end

local function updateOverloadEnemy(world, e, dt)
    local cfg = Config.ENEMIES[e.kind]
    local p = world.player
    local dist = Util.dist(e.x, e.y, p.x, p.y)

    if world.phase == "anti_hunt" then
        -- 反猎奖励目标优先逃散/守点，普通敌人短暂失神后也转入逃散或防御；
        -- 两类都不再沿用枯竭阶段的高压索敌和围攻行为。
        local guard = nearestGuardTarget(world, e)
        local fleeThreshold = e.huntTarget and 250 or 205
        local speedMul = e.huntTarget and 1.0 or 0.82
        if dist < fleeThreshold then
            fleePlayer(world, e, cfg.chaseSpeed * speedMul, dt)
        elseif guard then
            movePathed(world, e, guard.x, guard.y, cfg.speed * speedMul, dt)
        else
            fleePlayer(world, e, cfg.speed * speedMul, dt)
        end
        e.attackCd = 0
        e.heavyWindup = 0
        return
    end

    if e.kind == "heavy" then
        e.attackCd = math.max(0, e.attackCd - dt)
        if (e.heavyWindup or 0) > 0 then
            e.heavyWindup = e.heavyWindup - dt
            e.angle = math.atan(p.y - e.y, p.x - e.x)
            if e.heavyWindup <= 0 then
                if Util.dist(e.x, e.y, p.x, p.y) <= Config.FORMAL.heavyStrikeRange then
                    world:damagePlayer(cfg.damage, e.x, e.y)
                    world:addFx("hitspark", { x = p.x, y = p.y, color = "red", dur = 0.25 })
                end
                e.attackCd = Config.FORMAL.heavyStrikeCooldown
            end
        elseif dist <= Config.FORMAL.heavyStrikeRange and e.attackCd <= 0 then
            e.heavyWindup = Config.FORMAL.heavyWarningTime
            world:addFx("alertmark", { ref = e, dur = Config.FORMAL.heavyWarningTime })
        else
            local guard = nearestGuardTarget(world, e)
            local tx, ty = p.x, p.y
            if guard and dist > Config.FORMAL.heavyStrikeRange * 1.6 then tx, ty = guard.x, guard.y end
            movePathed(world, e, tx, ty, cfg.speed, dt)
        end
        return
    end

    if e.kind == "sentinel" or e.huntTarget then
        local guard = nearestGuardTarget(world, e)
        if dist < 230 then
            fleePlayer(world, e, cfg.chaseSpeed, dt)
        elseif guard then
            movePathed(world, e, guard.x, guard.y, cfg.speed, dt)
        else
            fleePlayer(world, e, cfg.speed, dt)
        end
        return
    end

    if losClear(world, e.x, e.y, p.x, p.y) then
        Pathfinding.clear(e)
        moveToward(world, e, p.x, p.y, cfg.chaseSpeed, dt)
    else
        movePathed(world, e, p.x, p.y, cfg.chaseSpeed, dt)
    end
    e.attackCd = math.max(0, e.attackCd - dt)
    if dist < e.radius + p.radius + 6 and e.attackCd <= 0 then
        e.attackCd = cfg.attackCd
        world:interfereOverload(Config.FORMAL.overloadContactTimeLoss)
        world:addFx("hitspark", { x = p.x, y = p.y, color = "blue", dur = 0.15 })
    end
end

-- 热度2(追踪)起：单点守卫与静止单位开始在有限区域巡逻。
-- 只改巡逻路径，不生成新敌人、不提供玩家实时位置，仍受视野与墙体限制。
local function roamStationary(world, e, cfg, dt, ax, ay)
    local H = Config.HEAT
    local diff = world:difficulty()
    local gate = fairGate(world)
    if gate and not TraceHeat.canTakeAmbient(world, e) then
        e.roaming = false
        e.roamX, e.roamY = nil, nil
        e.pressureWait = math.max(e.pressureWait or 0, 0.8)
        return
    end
    if gate then e.roaming = true end
    e.roamTimer = (e.roamTimer or 0) - dt
    if e.roamTimer <= 0 or not e.roamX then
        e.roamTimer = diff.roamRepathTime or H.roamRepathTime
        local a = math.random() * math.pi * 2
        local radius = diff.roamRadius or H.roamRadius
        local r = radius * (0.35 + math.random() * 0.65)
        e.roamX, e.roamY = ax + math.cos(a) * r, ay + math.sin(a) * r
    end
    if moveToward(world, e, e.roamX, e.roamY, cfg.speed * 0.85, dt) then
        e.roamTimer = 0
    end
end

-- 枯竭阶段七态机:patrol → suspect → alert → chase → lost → search → return
local function updateStealthEnemy(world, e, dt)
    local cfg = Config.ENEMIES[e.kind]
    local p = world.player
    local diff = world:difficulty()
    local gate = fairGate(world)
    e.stateTime = e.stateTime + dt

    -- 诱饵必须能从追击中夺走目标，否则最需要脱身时反而完全无效。
    -- 它只替换目标信息，不提供无敌：玩家留在诱饵旁仍会受到接触攻击。
    local decoy = nearestDecoy(world, e)
    if decoy then
        if e.state ~= "decoyed" then
            local redirectedFromChase = e.state == "chase" or e.state == "alert"
            e.state = "decoyed"
            e.stateTime = 0
            Pathfinding.clear(e)
            e.lastSeenX, e.lastSeenY = decoy.x, decoy.y
            if redirectedFromChase then
                e.wasChasing = true
                world:emit("enemy_decoyed", e.x, e.y)
            end
        end
        e.decoyTarget = decoy
    end

    local sees = (e.jammed <= 0) and EnemyAI.canSeePlayer(world, e)
    if gate and (e.pressureWait or 0) > 0
        and (e.state == "patrol" or e.state == "return" or e.state == "search") then
        e.pressureWait = math.max(0, e.pressureWait - dt)
        sees = false
    end

    if e.state == "patrol" or e.state == "return" then
        local tx, ty = patrolTarget(e)
        -- 热度2起：单点岗位(只有一个路点)与重型守卫开始在有限区域巡逻。
        local stationary = e.patrol == nil or #e.patrol <= 1
        local endlessRoam = world.endless == true and (world.round or 0) >= 13
        local heatRoam = stationary and (not gate or not e.overflowHold)
            and (TraceHeat.level(world) >= 2 or endlessRoam)
        if gate and not heatRoam then
            e.roaming = false
            e.roamX, e.roamY = nil, nil
        end
        if e.kind == "glitch" then
            -- 数据畸变体:围绕锚点不规则漫游(§10.3)
            e.wanderTimer = e.wanderTimer - dt
            if e.wanderTimer <= 0 then
                e.wanderTimer = 0.6 + math.random() * 1.2
                local ax, ay = tx or e.x, ty or e.y
                e.wanderX = ax + math.random(-140, 140)
                e.wanderY = ay + math.random(-140, 140)
            end
            if e.wanderX then moveToward(world, e, e.wanderX, e.wanderY, cfg.speed, dt) end
        elseif heatRoam then
            roamStationary(world, e, cfg, dt, tx or e.x, ty or e.y)
        elseif tx then
            if e.state == "return" then
                -- 返回巡逻线:可能离线较远,用寻路;到点后转常规巡逻
                if movePathed(world, e, tx, ty, cfg.speed, dt) then
                    e.state = "patrol"
                    e.stateTime = 0
                    Pathfinding.clear(e)
                end
            else
                if moveToward(world, e, tx, ty, cfg.speed, dt) then advancePatrol(e) end
            end
        end
        if sees then
            e.state = "suspect"
            e.stateTime = 0
            e.suspicion = 0
            e.lastSeenX, e.lastSeenY = p.x, p.y
            if gate then e.roaming = false end
        end

    elseif e.state == "suspect" then
        -- 观察可疑目标。L11+ 普通小怪会以原有巡逻速度收近距离，避免“已发现但原地不动”；
        -- 状态升级和真正追击仍使用原合同，失去视线后不会获得玩家实时位置。
        if sees then
            e.angle = math.atan(p.y - e.y, p.x - e.x)
            e.lastSeenX, e.lastSeenY = p.x, p.y
            if endlessInvestigatesWhileSeeing(world, e) then
                moveToward(world, e, p.x, p.y, cfg.speed * 0.85, dt)
            end
            e.suspicion = e.suspicion + dt
            -- [R2] 热度越高警戒累积越快(实验A倍率恒1)
            local suspectReady = e.suspicion >= Config.AI.suspectTime
                * TraceHeat.suspectTimeMul(world)
            if suspectReady and (not gate or TraceHeat.canTakeAmbient(world, e)) then
                e.state = "alert"
                e.stateTime = 0
                if gate then e.investigating = false end
                world:addFx("alertmark", { ref = e, dur = Config.AI.alertTime + 0.3 })
                world:emit("enemy_alert", e.x, e.y)
            elseif gate and suspectReady then
                -- Ambient槽满时回到巡逻并等待，不删除或静态无敌化。
                e.state = "patrol"
                e.stateTime = 0
                e.suspicion = 0
                e.pressureWait = 0.8
            end
        else
            e.suspicion = e.suspicion - dt * 1.5
            if e.suspicion <= 0 then
                e.state = "patrol"
                e.stateTime = 0
                if gate then e.investigating = false end
            end
        end

    elseif e.state == "alert" then
        if sees then
            e.lastSeenX, e.lastSeenY = p.x, p.y
            if endlessInvestigatesWhileSeeing(world, e) then
                moveToward(world, e, p.x, p.y, cfg.speed * 0.85, dt)
            end
        end
        if e.stateTime >= Config.AI.alertTime then
            if not gate or TraceHeat.canTakeChase(world, e) then
                e.state = "chase"
                e.stateTime = 0
                e.wasChasing = true
                world:emit("enemy_chase", e.x, e.y)
            else
                -- Chase/Hunter槽满时退出警戒，回到路线等待空槽。
                e.state = "patrol"
                e.stateTime = 0
                e.suspicion = 0
                e.pressureWait = 0.8
                e.investigating = false
            end
        end

    elseif e.state == "chase" then
        if sees then
            e.lastSeenX, e.lastSeenY = p.x, p.y
            e.loseTimer = 0
        else
            e.loseTimer = (e.loseTimer or 0) + dt
        end
        -- 看得见:直冲实时位置;看不见:只朝最后目击点寻路(§7.4 不作弊)
        if sees then
            Pathfinding.clear(e)
            moveToward(world, e, p.x, p.y, cfg.chaseSpeed * diff.chaseMul, dt)
        else
            movePathed(world, e, e.lastSeenX or p.x, e.lastSeenY or p.y,
                cfg.chaseSpeed * diff.chaseMul, dt)
        end
        tryAttack(world, e, dt)
        if (e.loseTimer or 0) > Config.AI.loseTime then
            e.state = "lost"
            e.stateTime = 0
        end

    elseif e.state == "lost" then
        -- 前往最后目击点(寻路绕障)
        local arrived = true
        if e.lastSeenX then
            arrived = movePathed(world, e, e.lastSeenX, e.lastSeenY, cfg.chaseSpeed * 0.8, dt)
        end
        if arrived or e.stateTime > 3.5 then
            if not gate or TraceHeat.canTakeAmbient(world, e) then
                e.state = "search"
                e.stateTime = 0
                e.wanderTimer = 0
                Pathfinding.clear(e)
            elseif gate then
                e.state = "return"
                e.stateTime = 0
                e.pressureWait = 0.8
                e.investigating = false
                Pathfinding.clear(e)
            end
        end
        if not gate then
            if sees then e.state = "chase"; e.loseTimer = 0 end
        elseif sees and TraceHeat.canTakeChase(world, e) then
            e.state = "chase"
            e.loseTimer = 0
            e.investigating = false
        end

    elseif e.state == "search" then
        -- 小范围搜索
        e.wanderTimer = e.wanderTimer - dt
        if e.wanderTimer <= 0 then
            e.wanderTimer = 0.5 + math.random() * 0.8
            e.wanderX = (e.lastSeenX or e.x) + math.random(-100, 100)
            e.wanderY = (e.lastSeenY or e.y) + math.random(-100, 100)
        end
        if e.wanderX then moveToward(world, e, e.wanderX, e.wanderY, cfg.speed, dt) end
        if sees then
            if not gate or TraceHeat.canTakeChase(world, e) then
                e.state = "chase"
                e.loseTimer = 0
                if gate then e.investigating = false end
            elseif gate then
                e.pressureWait = math.max(e.pressureWait or 0, 0.8)
            end
        -- [R2] 热度越高搜索维持越久(实验A倍率恒1)
        elseif e.stateTime > Config.AI.searchTime * TraceHeat.searchTimeMul(world) then
            e.state = "return"
            e.stateTime = 0
            if gate then e.investigating = false end
            Pathfinding.clear(e)
            world:emit("enemy_lost", e.x, e.y)
            if e.wasChasing then
                e.wasChasing = false
                world:emit("player_escaped", e.x, e.y)
            end
        end

    elseif e.state == "decoyed" then
        local d = e.decoyTarget
        if not d or d.dead then
            -- 诱饵消失后先在假信号处搜索，再返回巡逻；不会瞬间知道玩家位置。
            if d then e.lastSeenX, e.lastSeenY = d.x, d.y end
            e.state = "lost"
            e.stateTime = 0
            e.decoyTarget = nil
            if gate then e.investigating = false end
            Pathfinding.clear(e)
        else
            local arrived = movePathed(world, e, d.x, d.y, cfg.chaseSpeed * 0.9, dt)
            if arrived then e.angle = e.angle + dt * 3 end -- 到点后原地打转
            tryAttack(world, e, dt)
        end
    end
end

-- 敌人间分离:防止完全重叠(§7.3),只推不改状态
local function separate(world, dt)
    local P = Config.PATH
    local list = world.enemies
    local minD = P.separationDist
    for i = 1, #list do
        local a = list[i]
        if not a.dead then
            for j = i + 1, #list do
                local b = list[j]
                if not b.dead then
                    local dx, dy = b.x - a.x, b.y - a.y
                    local d2 = dx * dx + dy * dy
                    local want = minD + (a.radius + b.radius) * 0.5
                    if d2 < want * want and d2 > 0.01 then
                        local d = math.sqrt(d2)
                        local push = P.separationPush * dt * (1 - d / want)
                        local nx, ny = dx / d, dy / d
                        world:moveCircle(a, -nx * push, -ny * push)
                        world:moveCircle(b, nx * push, ny * push)
                    end
                end
            end
        end
    end
end

function EnemyAI.update(world, dt)
    for _, e in ipairs(world.enemies) do
        if not e.dead then
            if e.hitFlash > 0 then e.hitFlash = e.hitFlash - dt end
            if e.jammed > 0 then e.jammed = e.jammed - dt end
            if e.pathTimer and e.pathTimer > 0 then e.pathTimer = e.pathTimer - dt end
            if e.stun > 0 then
                e.stun = e.stun - dt
            elseif e.daze > 0 then
                e.daze = e.daze - dt   -- 跌落瞬间的短暂失神(§18.1)
            elseif world.phase == "overload" or world.phase == "anti_hunt" then
                updateOverloadEnemy(world, e, dt)
            elseif world.phase == "depleted" then
                if e.jammed > 0 then
                    -- 被干扰:原地缓慢转圈,不索敌
                    e.angle = e.angle + dt * 1.5
                else
                    updateStealthEnemy(world, e, dt)
                end
            end
            -- 防卡死:位移不足强制重算路径(§7.3)
            Pathfinding.checkStuck(e, dt)
            world:unstuck(e)
        end
    end
    separate(world, dt)
end

return EnemyAI
