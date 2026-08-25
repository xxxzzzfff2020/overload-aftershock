local Util = require "Util"
local EnemyAI = require "EnemyAI"
local LayerPlan = require "LayerPlan"
local Config = require "Config"
local EndlessOverclock = require "EndlessOverclock"

local SignalBlackout = {}

local MAX_TRACKED = 256
local function newState(world)
    return {
        layer = world.round,
        phase = world.phase,
        clock = 0,
        lastKnown = {},
        cleanupCount = 0,
    }
end

local function stateFor(world)
    if type(world.signalBlackout) ~= "table"
        or world.signalBlackout.layer ~= world.round then
        world.signalBlackout = newState(world)
    end
    world.signalBlackout.phase = world.phase
    return world.signalBlackout
end

-- 查询路径不得创建或刷新状态；Render只允许读取该视图。
local function readState(world)
    local state = world.signalBlackout
    if type(state) == "table" and state.layer == world.round then return state end
    return { layer = world.round, phase = world.phase, clock = 0, lastKnown = {}, cleanupCount = 0 }
end

local function planFor(world)
    local plan = world.layerPlan
    if plan and plan.blackout then return plan.blackout end
    return LayerPlan.get(math.max(1, math.floor(tonumber(world.round) or 1))).blackout
end

local function fullPhase(world)
    return world.phase == "layer_intro"
        or world.phase == "overload"
        or world.phase == "anti_hunt"
end

local function modeIsOpen(policy)
    return policy.mode == "disabled" or policy.mode == "preview"
end

local function valueKind(kind, entity)
    if kind == "core" then return true end
    return kind == "wreck" and entity and entity.deep == true
end

local function dangerKind(kind, entity)
    return kind == "enemy" and entity
        and (entity.hunter == true or entity.kind == "sentinel")
end

local function positionOf(world, entity)
    if not entity or type(entity.x) ~= "number" or type(entity.y) ~= "number" then
        return nil, nil
    end
    return entity.x, entity.y
end

local function reconActive(world)
    return world.phase == "depleted"
        and world.exp and world.exp.recon == true
        and (world.reconLeft or 0) > 0
end

-- 侦察沿用既有Config.RECON.radius作为“额外上行带宽”，而不是替换基础感知半径。
-- 这样L5软黑障和L6+正式黑障都能获得清晰、有限、非全图的工具价值。
local function reconRadius(world, policy)
    local base = tonumber(policy.radius or policy.effectiveRadius) or 0
    if base == math.huge or not reconActive(world) then return base end
    local extra = math.max(0, tonumber(Config.RECON.radius) or 0)
    return (base + extra) * EndlessOverclock.reconRadiusMultiplier(world)
end

local function reconLocationLive(world, x, y, policy)
    if x == nil or y == nil or not reconActive(world) then return false end
    local player = world.player
    if not player then return false end
    local radius = reconRadius(world, policy)
    return radius == math.huge
        or Util.dist2(player.x, player.y, x, y) <= radius * radius
end

local function locationLive(world, x, y, policy)
    if x == nil or y == nil then return false end
    if fullPhase(world) or modeIsOpen(policy) then return true end
    local player = world.player
    if not player then return false end
    local radius = policy.radius or policy.effectiveRadius or 0
    if radius ~= math.huge and Util.dist2(player.x, player.y, x, y) > radius * radius then
        return false
    end
    if not policy.requiresLos then return true end
    if type(world.isSolidAt) ~= "function" then return false end
    return EnemyAI.losClear(world, player.x, player.y, x, y)
end

local function liveReason(world, x, y, policy)
    if locationLive(world, x, y, policy) then return "radius_los" end
    if reconLocationLive(world, x, y, policy) then return "recon_pulse" end
    return nil
end

local function directionFromPlayer(world, x, y)
    local player = world.player
    if not player or x == nil or y == nil then return nil, nil end
    local dx, dy = x - player.x, y - player.y
    local distance = math.sqrt(dx * dx + dy * dy)
    return math.atan(dy, dx), distance
end

local function remember(state, entity, kind, x, y)
    local entry = state.lastKnown[entity]
    if not entry then
        entry = { kind = kind, age = 0, signalOffset = 0 }
        state.lastKnown[entity] = entry
    end
    entry.kind = kind
    entry.x, entry.y = x, y
    entry.age = 0
end

local function signalActive(world, entity, kind, policy, state)
    if not valueKind(kind, entity) then return false end
    local interval = policy.signalInterval or 2.4
    local duration = policy.signalDuration or 0.75
    if interval <= 0 then return true end
    local phase = state.clock % interval
    return phase < math.min(duration, interval)
end

local function makeVisibility(mode, reason, x, y, entity, world)
    local visibility = {
        mode = mode,
        display = mode,
        level = mode,
        reason = reason,
        x = x,
        y = y,
    }
    if mode == "signal" and dangerKind("enemy", entity) then
        local angle, distance = directionFromPlayer(world, entity.x, entity.y)
        visibility.signalKind = "danger"
        visibility.directionAngle = angle
        visibility.distance = distance
        if distance then
            visibility.distanceBand = distance <= 300 and "near"
                or distance <= 600 and "mid" or "far"
        end
        visibility.x, visibility.y = nil, nil
    elseif mode == "signal" then
        visibility.signalKind = "value"
    end
    return visibility
end

local function classify(world, entity, kind)
    if not entity or entity.dead then
        return makeVisibility("hidden", "dead", nil, nil, entity, world)
    end
    local state = readState(world)
    local policy = planFor(world)
    local x, y = positionOf(world, entity)
    local reason = liveReason(world, x, y, policy)
    if reason then
        return makeVisibility("live", reason, x, y, entity, world)
    end
    if world.phase == "depleted" and world.mark and world.mark.ref == entity then
        local tracked = makeVisibility("tracked", "marked_target", x, y, entity, world)
        tracked.signalKind = "mark"
        return tracked
    end
    if dangerKind(kind, entity) then
        return makeVisibility("signal", "danger_direction", nil, nil, entity, world)
    end
    if signalActive(world, entity, kind, policy, state) then
        return makeVisibility("signal", "intermittent_value", x, y, entity, world)
    end
    local known = state.lastKnown[entity]
    if known and known.age <= (policy.ghostDuration or 2.5) then
        return makeVisibility("ghost", "last_known", known.x, known.y, entity, world)
    end
    return makeVisibility("hidden", "outside_signal", nil, nil, entity, world)
end

local function eachTrackable(world, callback)
    for _, entity in ipairs(world.enemies or {}) do callback(entity, "enemy") end
    for _, entity in ipairs(world.cells or {}) do callback(entity, "cell") end
    for _, entity in ipairs(world.cores or {}) do callback(entity, "core") end
    for _, entity in ipairs(world.wrecks or {}) do callback(entity, "wreck") end
end

local function isTrackedEntityLive(world, entity, kind)
    local policy = planFor(world)
    local x, y = positionOf(world, entity)
    return locationLive(world, x, y, policy), kind
end

local function purge(state, world)
    local trackedCount = 0
    local oldestEntity, oldestAge = nil, -1
    for entity, entry in pairs(state.lastKnown) do
        if entity.dead or not entity.x or not entity.y then
            state.lastKnown[entity] = nil
            state.cleanupCount = state.cleanupCount + 1
        else
            trackedCount = trackedCount + 1
            if entry.age > oldestAge then
                oldestEntity, oldestAge = entity, entry.age
            end
        end
    end
    while trackedCount > MAX_TRACKED and oldestEntity do
        state.lastKnown[oldestEntity] = nil
        state.cleanupCount = state.cleanupCount + 1
        trackedCount = trackedCount - 1
        oldestEntity, oldestAge = nil, -1
        for entity, entry in pairs(state.lastKnown) do
            if entry.age > oldestAge then
                oldestEntity, oldestAge = entity, entry.age
            end
        end
    end
end

function SignalBlackout.attach(world)
    world.signalBlackout = newState(world)
    return world.signalBlackout
end

function SignalBlackout.reset(world)
    return SignalBlackout.attach(world)
end

function SignalBlackout.getPolicy(world)
    return planFor(world)
end

function SignalBlackout.getMode(world)
    return planFor(world).mode
end

function SignalBlackout.isRealtimeVisible(world, x, y)
    local policy = planFor(world)
    return liveReason(world, x, y, policy) ~= nil
end

function SignalBlackout.getRealtimeRadius(world)
    local policy = planFor(world)
    if modeIsOpen(policy) then return math.max(0, tonumber(Config.RECON.radius) or 0) end
    return reconRadius(world, policy)
end

function SignalBlackout.getVisualRadius(world)
    local policy = planFor(world)
    if modeIsOpen(policy) then return tonumber(policy.visualRadius or policy.radius) or 0 end
    if reconActive(world) then return reconRadius(world, policy) end
    return tonumber(policy.visualRadius or policy.radius) or 0
end

-- 044R: 常态感知边界与侦察外圈分开表达。基础半径不因侦察扩张，
-- 最大侦察半径只供单一虚线圈和真实侦察可见性使用。
function SignalBlackout.getBaseVisualRadius(world)
    local policy = planFor(world)
    return tonumber(policy.visualRadius or policy.radius) or 0
end

function SignalBlackout.getReconMaxRadius(world)
    local policy = planFor(world)
    local base = tonumber(policy.radius or policy.effectiveRadius) or 0
    if base == math.huge then return base end
    if modeIsOpen(policy) then return math.max(0, tonumber(Config.RECON.radius) or 0) end
    return (base + math.max(0, tonumber(Config.RECON.radius) or 0))
        * EndlessOverclock.reconRadiusMultiplier(world)
end

function SignalBlackout.isReconActive(world)
    return reconActive(world)
end

function SignalBlackout.decoySignal(world, decoy)
    local inbound = 0
    for _, enemy in ipairs(world.enemies or {}) do
        if not enemy.dead and enemy.decoyTarget == decoy then inbound = inbound + 1 end
    end
    return {
        mode = "signal",
        signalKind = "decoy",
        x = decoy and decoy.x or nil,
        y = decoy and decoy.y or nil,
        inboundCount = inbound,
    }
end

function SignalBlackout.scanSignalMode(world)
    return (world.scanJammedLeft or 0) > 0 and "jammed" or "normal"
end

function SignalBlackout.classify(world, entity, kind)
    return classify(world, entity, kind)
end

SignalBlackout.classifyEntity = SignalBlackout.classify

function SignalBlackout.update(world, dt)
    local state = stateFor(world)
    local delta = math.max(0, tonumber(dt) or 0)
    local policy = planFor(world)
    state.clock = (state.clock + delta) % math.max(policy.signalInterval or 2.4, 0.001)
    local current = {}
    eachTrackable(world, function(entity, kind)
        current[entity] = kind
        if not entity.dead then
            local x, y = positionOf(world, entity)
            if liveReason(world, x, y, policy) then
                remember(state, entity, kind, x, y)
            else
                local known = state.lastKnown[entity]
                if known then known.age = known.age + delta end
            end
        end
    end)
    for entity, entry in pairs(state.lastKnown) do
        if not current[entity] or entity.dead then
            state.lastKnown[entity] = nil
            state.cleanupCount = state.cleanupCount + 1
        elseif entry.age > (policy.ghostDuration or 2.5) then
            state.lastKnown[entity] = nil
            state.cleanupCount = state.cleanupCount + 1
        end
    end
    purge(state, world)
    state.phase = world.phase
    return state
end

function SignalBlackout.capture(world)
    return SignalBlackout.update(world, 0)
end

-- 兼容旧测试/开发调用；正式渲染不得调用。
SignalBlackout.observe = SignalBlackout.capture

function SignalBlackout.state(world)
    return stateFor(world)
end

function SignalBlackout.peekState(world)
    return readState(world)
end

return SignalBlackout
