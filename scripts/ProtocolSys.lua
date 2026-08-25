-- ProtocolSys.lua
-- 三种首发协议、地图B扫描区域与猎杀协议。纯逻辑，可由SelfTest/Bot直接驱动。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local LayerPlan = require "LayerPlan"
local TraceHeat = require "TraceHeat"

local ProtocolSys = {}

local function fairGate(world)
    return world.layerPlan and world.layerPlan.fairGate or nil
end

local function scanTiming(world, key, fallback)
    local gate = fairGate(world)
    return gate and gate[key] or fallback
end

function ProtocolSys.applyLayer(world, plan)
    world.layerPlan = plan
    world.protocols = {}
    for _, id in ipairs(plan.protocols or {}) do world.protocols[id] = true end
    world.protocolLabel = LayerPlan.protocolLabel(plan)
    world.hunterEnabled = plan.hunter == true
end

function ProtocolSys.has(world, id)
    return world.protocols and world.protocols[id] == true
end

function ProtocolSys.adjustDifficulty(world, source)
    local out = {}
    for k, v in pairs(source) do out[k] = v end
    if ProtocolSys.has(world, "blockade") or (world.layerPlan and world.layerPlan.relayDebt) then
        out.patrolExtra = math.min(Config.ROUNDS.maxPatrolAdd,
            out.patrolExtra + Config.PROTOCOL.blockade.patrolExtra)
    end
    return out
end

function ProtocolSys.hordeBatch(world)
    local count = Config.ROUNDS.hordeBatch
    if ProtocolSys.has(world, "cluster") then
        count = math.max(count + 1, math.floor(count * Config.PROTOCOL.cluster.hordeBatchMul + 0.5))
    end
    return count
end

function ProtocolSys.scoreMultiplier(world, kind)
    if kind == "normalKill" and ProtocolSys.has(world, "cluster") then
        return Config.PROTOCOL.cluster.normalKillMul
    elseif kind == "node" and ProtocolSys.has(world, "blockade") then
        return Config.PROTOCOL.blockade.nodeScoreMul
    elseif kind == "deep" and ProtocolSys.has(world, "deep_cache") then
        return Config.PROTOCOL.deep_cache.deepScoreMul
    elseif kind == "risk" and ProtocolSys.has(world, "deep_cache") then
        return Config.PROTOCOL.deep_cache.riskScoreMul
    end
    return 1
end

function ProtocolSys.resetRound(world, announce)
    world.scan = {
        state = "idle", timer = scanTiming(world, "scanFirstDelay", Config.SCAN.firstDelay), zoneIndex = 0,
        zone = nil, hit = false,
    }
    world.scanJammedLeft = 0
    world.scanExposedLeft = 0
    if fairGate(world) then
        world.scanHunterGap = 0
        world.postToolRelockTimer = 0
    end
    world.hunterActivationTimer = 0
    world.lockReinforceTimer = 0
    world.huntersActivated = 0
    if announce and world.protocolLabel ~= "" then
        world:addFx("banner", { text = world.protocolLabel .. "启动", dur = 2.0 })
        world:emit("protocol_start")
    end
end

function ProtocolSys.onJammer(world)
    if world.mapId == "firewall_core" then
        world.scanJammedLeft = math.max(world.scanJammedLeft or 0, Config.SCAN.jammerSuppressTime)
    end
end

function ProtocolSys.onForceDrop(world)
    ProtocolSys.resetRound(world, false)
    if ProtocolSys.has(world, "blockade") then
        local alive = 0
        for _, relay in ipairs(world.relays) do if not relay.dead then alive = alive + 1 end end
        if alive > 0 then
            local heatPerRelay = ProtocolSys.has(world, "blockade")
                and Config.PROTOCOL.blockade.debtHeatPerRelay or 4
            TraceHeat.noise(world, alive * heatPerRelay,
                world.player.x, world.player.y)
            world:addFx("toast", { text = "中继器债务：初始热度上升", dur = 1.8 })
        end
    end
end

local function inZone(world, zone)
    local c, r = MapDef.toTile(world.player.x, world.player.y)
    return c >= zone.c1 and c <= zone.c2 and r >= zone.r1 and r <= zone.r2
end

local function scannerLineClear(world, zone)
    local EnemyAI = require "EnemyAI"
    local cx, cy = MapDef.tileCenter((zone.c1 + zone.c2) * 0.5, (zone.r1 + zone.r2) * 0.5)
    return EnemyAI.losClear(world, cx, cy, world.player.x, world.player.y)
end

local function hitScan(world)
    local scan = world.scan
    if scan.hit or world.cloakLeft > 0 or (world.scanJammedLeft or 0) > 0 then return end
    if not scan.zone or not inZone(world, scan.zone) or not scannerLineClear(world, scan.zone) then return end
    scan.hit = true
    world.scanExposedLeft = Config.SCAN.exposeTime
    TraceHeat.noise(world, Config.SCAN.heatAdd, world.player.x, world.player.y)
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and enemy.jammed <= 0
            and Util.dist(enemy.x, enemy.y, world.player.x, world.player.y) <= 520 then
            local EnemyAI = require "EnemyAI"
            if EnemyAI.losClear(world, enemy.x, enemy.y, world.player.x, world.player.y) then
                enemy.state = "suspect"
                enemy.stateTime = 0
                enemy.suspicion = math.max(enemy.suspicion or 0, Config.AI.suspectTime * 0.5)
            end
        end
    end
    world:emit("scan_hit", world.player.x, world.player.y)
    world:addFx("banner", { text = "扫描命中：位置短暂暴露", dur = 1.6 })
end

local function updateScan(world, dt)
    if world.mapId ~= "firewall_core" or world.phase ~= "depleted" then return end
    local zones = world.map.scanZones or {}
    if #zones == 0 then return end
    local scan = world.scan
    scan.timer = scan.timer - dt
    if scan.state == "idle" and scan.timer <= 0 then
        -- L10公平门：扫描负责未满能阶段的路线压力；满能后由猎杀接棒，
        -- 禁止扫描、猎杀和双协议路线封锁三者同时达到峰值。
        local gate = fairGate(world)
        if gate and gate.staggerScanAndHunter and world.readyAt then
            scan.timer = 0.5
            return
        end
        scan.zoneIndex = scan.zoneIndex % #zones + 1
        scan.zone = zones[scan.zoneIndex]
        scan.state, scan.timer, scan.hit = "warning", Config.SCAN.warningTime, false
        world:emit("scan_warning")
        world:addFx("toast", { text = "扫描预警：离开高亮区域或利用掩体", dur = 1.5 })
    elseif scan.state == "warning" and scan.timer <= 0 then
        scan.state, scan.timer = "active", Config.SCAN.activeTime
    elseif scan.state == "active" then
        hitScan(world)
        if scan.timer <= 0 then
            scan.state, scan.timer, scan.zone = "idle",
                scanTiming(world, "scanInterval", Config.SCAN.interval), nil
            local gate = fairGate(world)
            if gate then
                world.scanHunterGap = math.max(world.scanHunterGap or 0,
                    scanTiming(world, "scanHunterGap", 0))
            end
        end
    end
end

-- 猎杀者上限。分层：第1—4层最多1个，第5—10层最多2个，无尽阶段缓慢提高但有上限。
-- 锁定档(热度3)可以在协议未开启猎杀的层里也激活有限猎杀者。
local function hunterCap(world)
    local L = Config.HEAT_LOCK
    local gate = fairGate(world)
    if gate and gate.hunterCap then return gate.hunterCap end
    if world.round > Config.RUN.finalLayer then
        local step = math.floor((world.round - Config.RUN.finalLayer) / L.endlessStepLayers)
        return math.min(L.endlessMax, L.endlessBase + step)
    end
    if world.round >= 5 then return L.maxPerLayerMid end
    return L.maxPerLayerEarly
end
ProtocolSys.hunterCap = hunterCap

local function activateHunter(world)
    if world.phase ~= "depleted" then return false end
    local cap = hunterCap(world)
    if (world.huntersActivated or 0) >= cap then return false end
    -- 不在玩家视野内、也不在脚边转化猎杀者。
    local EnemyAI = require "EnemyAI"
    local minDist = Config.HEAT_LOCK.minSpawnDistance
    local best, bestScore = nil, math.huge
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and not enemy.hunter and enemy.kind ~= "heavy" then
            local d = Util.dist(enemy.x, enemy.y, world.player.x, world.player.y)
            local visible = EnemyAI.losClear(world, enemy.x, enemy.y,
                world.player.x, world.player.y)
            if d > minDist and not visible then
                local kindBias = enemy.kind == "sentinel" and -100000 or 0
                local score = d * d + kindBias
                if score < bestScore then best, bestScore = enemy, score end
            end
        end
    end
    if not best then return false end
    if fairGate(world) and not best.hunter and best.state ~= "chase"
        and not TraceHeat.canTakeChase(world, best) then
        return false
    end
    best.hunter = true
    best.hunterScanTimer = 0.4
    best.lastSeenX = world.noiseX or world.player.x
    best.lastSeenY = world.noiseY or world.player.y
    best.state, best.stateTime = "lost", 0
    world.huntersActivated = (world.huntersActivated or 0) + 1
    world:emit("hunter_protocol", best.x, best.y)
    return true
end

local function updateHunters(world, dt)
    local EnemyAI = require "EnemyAI"
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and enemy.hunter then
            enemy.hunterScanTimer = (enemy.hunterScanTimer or Config.HUNTER.scanInterval) - dt
            enemy.hunterPulse = math.max(0, (enemy.hunterPulse or 0) - dt)
            if enemy.hunterScanTimer <= 0 then
                enemy.hunterScanTimer = Config.HUNTER.scanInterval
                enemy.hunterPulse = 0.6
                if world.cloakLeft <= 0
                    and Util.dist(enemy.x, enemy.y, world.player.x, world.player.y) <= Config.HUNTER.scanRange
                    and EnemyAI.losClear(world, enemy.x, enemy.y, world.player.x, world.player.y) then
                    enemy.lastSeenX, enemy.lastSeenY = world.player.x, world.player.y
                    enemy.state, enemy.stateTime = "suspect", 0
                    enemy.suspicion = math.max(enemy.suspicion or 0, Config.AI.suspectTime * 0.6)
                end
            end
        end
    end
end

function ProtocolSys.update(world, dt)
    if world.phase ~= "depleted" then return end
    world.scanJammedLeft = math.max(0, (world.scanJammedLeft or 0) - dt)
    world.scanExposedLeft = math.max(0, (world.scanExposedLeft or 0) - dt)
    local gate = fairGate(world)
    if gate then
        world.scanHunterGap = math.max(0, (world.scanHunterGap or 0) - dt)
        world.postToolRelockTimer = math.max(0, (world.postToolRelockTimer or 0) - dt)
    end
    updateScan(world, dt)
    updateHunters(world, dt)
    world.hunterActivationTimer = math.max(0, (world.hunterActivationTimer or 0) - dt)
    world.lockReinforceTimer = math.max(0, (world.lockReinforceTimer or 0) - dt)
    local readyDelay = scanTiming(world, "hunterReadyDelay", Config.HUNTER.readyDelay)
    local readyLongEnough = world.readyAt and world.timeAlive - world.readyAt >= readyDelay
    local scanBusy = world.scan and (world.scan.state == "warning" or world.scan.state == "active")
    local scanGapBusy = gate and (world.scanHunterGap or 0) > 0 or false
    local toolRelockBusy = gate and (world.postToolRelockTimer or 0) > 0 or false
    -- 猎杀协议：只强化"满能后继续诱敌"的既有选择，不由普通高热度提前抢跑。
    if world.hunterEnabled and world.hunterActivationTimer <= 0 and readyLongEnough
        and not scanBusy and not scanGapBusy and not toolRelockBusy then
        world.hunterActivationTimer = Config.HUNTER.activationCooldown
        if activateHunter(world) then
            world:addFx("banner", { text = "满能诱敌：猎杀者追踪最后暴露位置", dur = 2.0 })
        end
    end
    -- 锁定档(热度3)：满能后激活或补充有限猎杀者。可以被隐身、诱饵、干扰和墙体摆脱。
    if TraceHeat.level(world) >= 3 and readyLongEnough and not scanBusy
        and not scanGapBusy and not toolRelockBusy
        and world.lockReinforceTimer <= 0 then
        world.lockReinforceTimer = Config.HEAT_LOCK.reinforceCooldown
        if activateHunter(world) then
            world:addFx("banner", { text = "锁定档：猎杀者已补充", dur = 2.0 })
            world:emit("heat_lock_hunter")
        end
    end
end

return ProtocolSys
