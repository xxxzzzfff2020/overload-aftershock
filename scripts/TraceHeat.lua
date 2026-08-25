-- TraceHeat.lua
-- [R2] 网络追踪热度(§R2任务包C):仅实验B、仅枯竭阶段的风险压力。
-- 不是长期资源:只影响 AI 调度(搜索时长/警戒速度/调查派遣),
-- 禁止提高敌人生命/伤害、禁止无提示贴脸刷怪、禁止全图全知。
-- 由 World:update 调用(玩法逻辑,Bot/SelfTest 直接驱动 World 也生效)。

local Config = require "Config"
local Util = require "Util"

local TraceHeat = {}

-- 档位:0 隐匿 / 1 暴露 / 2 追踪 / 3 锁定
function TraceHeat.level(world)
    local h = world.heat or 0
    local T = Config.HEAT.thresholds
    if h >= T[3] then return 3 end
    if h >= T[2] then return 2 end
    if h >= T[1] then return 1 end
    return 0
end

TraceHeat.levelNames = { [0] = "隐匿", "暴露", "追踪", "锁定" }

-- 噪声行为:加热度并记录噪声位置(调查派遣的目标,不是玩家实时位置)
function TraceHeat.noise(world, amount, x, y)
    if not world.exp.traceHeat then return end
    if world.phase ~= "depleted" then return end
    local mul = world.relayBonus and Config.OPPORTUNITY.relayHeatMul or 1
    local before = TraceHeat.level(world)
    world.heat = Util.clamp((world.heat or 0) + amount * mul, 0, Config.HEAT.max)
    world.heatQuietTimer = 0
    if x then world.noiseX, world.noiseY = x, y end
    local after = TraceHeat.level(world)
    if after > before then
        world:emit("heat_up")
        world:addFx("toast", { text = "追踪热度上升:" .. TraceHeat.levelNames[after], dur = 1.4 })
    end
end

-- AI 调度参数(EnemyAI 读取;A 实验恒为 1 倍率)
function TraceHeat.searchTimeMul(world)
    if not world.exp.traceHeat then return 1 end
    return Config.HEAT.searchTimeMul[TraceHeat.level(world) + 1]
end

function TraceHeat.suspectTimeMul(world)
    if not world.exp.traceHeat then return 1 end
    return Config.HEAT.suspectTimeMul[TraceHeat.level(world) + 1]
end

-- 020R L10 pressure slots. The fairGate guard keeps these helpers inert for
-- L1-9 and L11+, so the existing global AI contract remains unchanged there.
local function fairGate(world)
    return world.layerPlan and world.layerPlan.fairGate or nil
end

local function isAmbientPressure(enemy)
    return enemy.state == "alert" or enemy.state == "search"
        or enemy.roaming == true or enemy.investigating == true
end

function TraceHeat.countChaseOrHunter(world, excluded)
    local count = 0
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and enemy ~= excluded
            and (enemy.hunter == true or enemy.state == "chase") then
            count = count + 1
        end
    end
    return count
end

function TraceHeat.countAmbientPressure(world, excluded)
    local count = 0
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and enemy ~= excluded and isAmbientPressure(enemy) then
            count = count + 1
        end
    end
    return count
end

function TraceHeat.canTakeChase(world, enemy)
    local gate = fairGate(world)
    if not gate or not gate.pressureChaseCap then return true end
    if enemy.hunter == true or enemy.state == "chase" then return true end
    if (world.postToolRelockTimer or 0) > 0 then return false end
    return TraceHeat.countChaseOrHunter(world, enemy) < gate.pressureChaseCap
end

function TraceHeat.canTakeAmbient(world, enemy)
    local gate = fairGate(world)
    if not gate or not gate.pressureAmbientCap then return true end
    -- Existing ambient units must also yield when another ambient branch has
    -- filled the L10 slot; otherwise search + stale roaming flags can exceed
    -- the combined cap even though every new admission was individually gated.
    return TraceHeat.countAmbientPressure(world, enemy) < gate.pressureAmbientCap
end

-- 每帧更新(仅枯竭阶段):被动增长、衰减、调查派遣
function TraceHeat.update(world, dt)
    if not world.exp.traceHeat then return end
    if world.phase ~= "depleted" then return end
    local H = Config.HEAT
    local p = world.player
    -- 试玩数据:本枯竭阶段热度峰值(forceDrop 时重置)
    world.heatPeakRound = math.max(world.heatPeakRound or 0, world.heat or 0)

    -- 被动增长:达标后停留 + 高危区停留
    local mul = world.relayBonus and Config.OPPORTUNITY.relayHeatMul or 1
    local grow = 0
    if world.energy >= world.energyNeed then
        local protocolMul = world.hasProtocol and world:hasProtocol("deep_cache")
            and Config.PROTOCOL.deep_cache.readyHeatMul or 1
        grow = grow + Config.FORMAL.readyHeatPerSec * protocolMul
    end
    local MapDef = require "MapDef"
    local _, row = MapDef.toTile(p.x, p.y)
    if row <= (world.layout.dangerRows or 7) then grow = grow + H.dangerZonePerSec end
    if grow > 0 then
        local before = TraceHeat.level(world)
        world.heat = Util.clamp((world.heat or 0) + grow * mul * dt, 0, H.max)
        if TraceHeat.level(world) > before then
            world:emit("heat_up")
            world:addFx("toast", { text = "追踪热度上升:" ..
                TraceHeat.levelNames[TraceHeat.level(world)], dur = 1.4 })
        end
    end

    -- 衰减:未被追击/盯上,且一段时间无噪声(不能瞬间清零)
    local threatened = false
    for _, e in ipairs(world.enemies) do
        if not e.dead and (e.state == "chase" or e.state == "alert" or e.state == "suspect") then
            threatened = true
            break
        end
    end
    if threatened or grow > 0 then
        world.heatQuietTimer = 0
    else
        world.heatQuietTimer = (world.heatQuietTimer or 0) + dt
        if world.heatQuietTimer >= H.decayDelay then
            world.heat = math.max(0, (world.heat or 0) - H.decayPerSec * dt)
        end
    end

    -- 调查派遣(追踪/锁定档):每隔一段时间,最近的巡逻单位前往最后噪声点搜索。
    -- 目标是"噪声发生地",不是玩家实时位置(§8.3 禁全知)。
    -- 热度2起,派遣点向最后暴露点方向靠近一部分,但仍不是实时位置。
    local lvl = TraceHeat.level(world)
    local gate = fairGate(world)
    local interval = H.investigateInterval[lvl + 1]
    if interval and interval > 0 and world.noiseX then
        world.investigateTimer = (world.investigateTimer or 0) - dt
        if world.investigateTimer <= 0 then
            world.investigateTimer = interval
            local tx, ty = world.noiseX, world.noiseY
            if lvl >= 2 then
                local f = H.investigateCloseFactor
                tx = tx + (p.x - tx) * f
                ty = ty + (p.y - ty) * f
                -- 派遣点必须落在可通行格上，否则调查单位会卡在墙里。
                if world:isSolidAt(tx, ty) then tx, ty = world.noiseX, world.noiseY end
            end
            local best, bestD = nil, math.huge
            for _, e in ipairs(world.enemies) do
                if not e.dead and (e.state == "patrol" or e.state == "return")
                    and e.jammed <= 0 and e.daze <= 0 then
                    local d = Util.dist2(e.x, e.y, tx, ty)
                    if d < bestD then best, bestD = e, d end
                end
            end
            if best and (not gate or TraceHeat.canTakeAmbient(world, best)) then
                if gate then best.investigating = true end
                best.state = "lost"      -- 复用"前往最后目击点→搜索"链路
                best.stateTime = 0
                best.lastSeenX, best.lastSeenY = tx, ty
                world:addFx("ring", { x = tx, y = ty, r = 70, color = "red", dur = 0.8 })
                world:emit("heat_investigate", tx, ty)
            elseif best then
                -- 超出调查槽位时保留原巡逻单位，下一次调查周期再尝试。
                best.pressureWait = math.max(best.pressureWait or 0, 0.8)
            end
        end
    end
end

-- 完成层结算：标准第1—10层热度清零；无尽第11层后只降低一个档位，
-- 形成持续升级的终局压力（不完全清零）。
function TraceHeat.onLayerComplete(world)
    if not world.exp.traceHeat then
        world.heat = 0
        return
    end
    world.noiseX, world.noiseY = nil, nil
    world.investigateTimer = 0
    world.heatQuietTimer = 0
    if not world.endless then
        world.heat = 0
        return
    end
    local T = Config.HEAT.thresholds
    local step = Config.RUN.endlessHeatStep
    local target = TraceHeat.level(world) - step
    if target <= 0 then
        -- 已经在最低档：只压到"暴露"档的下界之下一点，仍保留残余热度。
        world.heat = math.min(world.heat or 0, math.max(0, T[1] - 1))
    else
        -- 降到目标档的下界（刚好进入该档），保留可感知的残余压力。
        world.heat = math.min(world.heat or 0, T[target])
    end
end

-- 重启进入反猎:噪声点清除(热度本体由 onLayerComplete 在层结算时处理)
function TraceHeat.onRestart(world)
    if not world.exp.traceHeat then return end
    world.noiseX, world.noiseY = nil, nil
    world.investigateTimer = 0
    world.heatQuietTimer = 0
end

return TraceHeat
