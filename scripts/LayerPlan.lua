-- LayerPlan.lua
-- 首发第1—10层与11+无尽内容的唯一解释器。地图与协议组合确定性、有限增长。

local Config = require "Config"

local LayerPlan = {}

local BLACKOUT = Config.SIGNAL_BLACKOUT
local BLACKOUT_BASE_RADIUS = BLACKOUT.baseRadius
local BLACKOUT_SOFT_RADIUS = BLACKOUT_BASE_RADIUS * BLACKOUT.softRadiusMultiplier
local BLACKOUT_MIN_FACTOR = BLACKOUT.minimumRadiusFactor
local BLACKOUT_ENDLESS_STEP = BLACKOUT.futureEndlessStep
local BLACKOUT_GHOST_DURATION = BLACKOUT.ghostDuration
local BLACKOUT_SIGNAL_INTERVAL = BLACKOUT.signalInterval
local BLACKOUT_SIGNAL_DURATION = BLACKOUT.signalDuration

local function copyList(source)
    local out = {}
    for i, value in ipairs(source or {}) do out[i] = value end
    return out
end

local function difficultyFor(layer)
    local fixed = Config.ROUNDS.layers
    if layer <= #fixed then
        local src = fixed[layer]
        return {
            energyNeed = src.energyNeed, viewMul = src.viewMul, chaseMul = src.chaseMul,
            hordeInterval = src.hordeInterval, heavyCount = src.heavyCount,
            patrolExtra = src.patrolExtra,
        }
    end
    local step = math.floor((layer - 11) / 3) + 1
    local tail = fixed[#fixed]
    local endlessIndex = math.min(6, math.max(1, layer - 10))
    local hordeMul = Config.ENDLESS and Config.ENDLESS.hordeIntervalMul[endlessIndex] or 1
    local viewMul = Config.ENDLESS and Config.ENDLESS.viewMul[endlessIndex] or 1.06
    local chaseMul = Config.ENDLESS and Config.ENDLESS.chaseMul[endlessIndex] or 1.08
    local endlessCfg = Config.ENDLESS or {}
    local roamRadius = nil
    local roamRepathTime = nil
    if layer >= (endlessCfg.roamStartLayer or math.huge) then
        roamRadius = math.min(endlessCfg.roamRadiusMax or 300,
            (endlessCfg.roamRadiusBase or 240)
                + (layer - (endlessCfg.roamStartLayer or layer))
                    * (endlessCfg.roamRadiusStep or 0))
        roamRepathTime = endlessCfg.roamRepathTime or 1.8
    end
    local trackerInterval = nil
    local trackerAliveCap = nil
    if layer >= (endlessCfg.trackerStartLayer or math.huge) then
        trackerInterval = math.max(endlessCfg.trackerIntervalFloor or 15,
            (endlessCfg.trackerIntervalStart or 30)
                - (layer - (endlessCfg.trackerStartLayer or layer)))
        trackerAliveCap = endlessCfg.trackerAliveCap or 6
    end
    return {
        energyNeed = math.min(Config.ROUNDS.energyNeedCap, tail.energyNeed + step * 6),
        viewMul = math.min(1.34, viewMul),
        chaseMul = math.min(1.34, chaseMul),
        hordeInterval = math.max(0.68, tail.hordeInterval * hordeMul),
        heavyCount = math.min(Config.ROUNDS.maxHeavy, 3 + math.floor((layer - 11) / 4)),
        patrolExtra = math.min(Config.ROUNDS.maxPatrolAdd, 2 + math.floor((layer - 11) / 3)),
        endlessIndex = endlessIndex,
        roamRadius = roamRadius,
        roamRepathTime = roamRepathTime,
        trackerInterval = trackerInterval,
        trackerAliveCap = trackerAliveCap,
        pressureBand = layer <= 13 and "power_ramp"
            or layer <= 16 and "build_test"
            or layer <= 20 and "endless_challenge" or "overtake",
    }
end

local function blackoutFor(layer)
    local mode = "endless_base"
    local radius = BLACKOUT_BASE_RADIUS
    local requiresLos = true
    if layer <= 3 then
        mode = "disabled"
        radius = math.huge
        requiresLos = false
    elseif layer == 4 then
        mode = "preview"
        radius = math.huge
        requiresLos = false
    elseif layer == 5 then
        mode = "soft"
        radius = BLACKOUT_SOFT_RADIUS
    elseif layer <= 10 then
        mode = layer == 10 and "full_fair_gate" or "full"
    end
    local minimumRadius = BLACKOUT_BASE_RADIUS * BLACKOUT_MIN_FACTOR
    local endlessBlock = math.max(0, math.floor((layer - 11) / 3))
    local futureRadius = math.max(minimumRadius,
        BLACKOUT_BASE_RADIUS * (1 - endlessBlock * BLACKOUT_ENDLESS_STEP))
    return {
        mode = mode,
        radius = radius,
        effectiveRadius = radius,
        visualRadius = layer == 4 and BLACKOUT_SOFT_RADIUS or radius,
        visualField = layer >= 4,
        previewOnly = layer == 4,
        fieldAlpha = layer == 4 and BLACKOUT.previewFieldAlpha
            or layer == 5 and BLACKOUT.softFieldAlpha or BLACKOUT.fullFieldAlpha,
        outerBlackoutAlpha = layer == 4 and 0 or BLACKOUT.outerBlackoutAlpha,
        configSource = "signal_blackout",
        baseRadius = BLACKOUT_BASE_RADIUS,
        softRadius = BLACKOUT_SOFT_RADIUS,
        minimumRadius = minimumRadius,
        futureRadius = futureRadius,
        futureStep = BLACKOUT_ENDLESS_STEP,
        requiresLos = requiresLos,
        ghostDuration = BLACKOUT_GHOST_DURATION,
        signalInterval = BLACKOUT_SIGNAL_INTERVAL,
        signalDuration = BLACKOUT_SIGNAL_DURATION,
        fairGate = layer == 10,
    }
end

function LayerPlan.get(layer)
    layer = math.max(1, math.floor(layer or 1))
    local fixed = Config.CONTENT.fixedLayers[layer]
    local plan
    if fixed then
        plan = {
            layer = layer, map = fixed.map, layout = fixed.layout,
            protocols = copyList(fixed.protocols), hunter = fixed.hunter == true,
            milestone = fixed.milestone == true, relayDebt = fixed.relayDebt == true,
            fairGate = fixed.fairGate,
        }
    else
        local block = math.floor((layer - 11) / 3)
        local cycle = { "cluster", "blockade", "deep_cache" }
        local protocolIndex = ((layer - 11) % #cycle) + 1
        local protocols = { cycle[protocolIndex] }
        plan = {
            layer = layer,
            map = (block % 2 == 0) and "outer_grid" or "firewall_core",
            layout = block % 3 + 1,
            protocols = protocols,
            hunter = true,
            milestone = false,
            endless = true,
        }
    end
    plan.mapName = Config.CONTENT.maps[plan.map].name
    plan.difficulty = difficultyFor(layer)
    plan.blackout = blackoutFor(layer)
    plan.endless = plan.endless == true or layer >= 11
    return plan
end

function LayerPlan.has(plan, protocol)
    for _, value in ipairs(plan and plan.protocols or {}) do
        if value == protocol then return true end
    end
    return false
end

function LayerPlan.protocolLabel(plan)
    local names = {}
    for _, id in ipairs(plan and plan.protocols or {}) do
        names[#names + 1] = Config.CONTENT.protocolNames[id] or id
    end
    return table.concat(names, " + ")
end

function LayerPlan.validate()
    for layer = 1, 20 do
        local p = LayerPlan.get(layer)
        if not Config.CONTENT.maps[p.map] or p.layout < 1 or p.layout > 3 then
            return false, "invalid layer content at " .. layer
        end
        if p.difficulty.energyNeed > Config.ROUNDS.energyNeedCap
            or p.difficulty.heavyCount > Config.ROUNDS.maxHeavy
            or p.difficulty.patrolExtra > Config.ROUNDS.maxPatrolAdd then
            return false, "unbounded difficulty at " .. layer
        end
        if layer == 10 and p.blackout.radius < LayerPlan.get(9).blackout.radius then
            return false, "L10 blackout radius is narrower than L9"
        end
        if p.blackout.futureRadius < p.blackout.minimumRadius then
            return false, "endless blackout radius below floor at " .. layer
        end
    end
    return true
end

return LayerPlan
