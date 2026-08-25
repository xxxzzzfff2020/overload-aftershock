-- RunFlow.lua
-- 016T每层收口状态机：反猎、层结算、第10层分支与复活安全检查点。
-- 仅搬移World既有职责，不定义地图、难度、商品或计分数值。

local Config = require "Config"
local Util = require "Util"
local CombatSys = require "CombatSys"
local ScoreSys = require "ScoreSys"
local TraceHeat = require "TraceHeat"
local RunShop = require "RunShop"
local LayerPlan = require "LayerPlan"
local ProtocolSys = require "ProtocolSys"
local MapRuntime = require "MapRuntime"
local MapDef = require "MapDef"
local EndlessOverclock = require "EndlessOverclock"

local RunFlow = {}

-- 结算层数的唯一口径：只统计已完成层，不把刚进入但未通过的层计入。
function RunFlow.completedLayerForRun(world, completionReason, explicitLayer)
    if explicitLayer ~= nil then
        return math.max(0, math.floor(tonumber(explicitLayer) or 0))
    end
    world = type(world) == "table" and world or {}
    if completionReason == "challenge_complete" or completionReason == "layer_complete" then
        return math.max(0, math.floor(tonumber(world.round) or 0))
    end
    local checkpointLayer = world._reviveCheckpoint
        and tonumber(world._reviveCheckpoint.completedLayer) or nil
    return math.max(0, math.floor(checkpointLayer
        or math.max(0, (tonumber(world.round) or 1) - 1)))
end

local function copyFlat(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

function RunFlow.saveReviveCheckpoint(world, completedLayer)
    world._reviveCheckpoint = {
        completedLayer = math.max(0, math.floor(tonumber(completedLayer) or 0)),
        score = world.score or 0,
        wreckData = world.wreckData or 0,
        coreCount = world.coreCount or 0,
        runUpgrades = copyFlat(world.runUpgrades),
        shopPurchases = world.shopPurchases or 0,
        counters = copyFlat(world.counters),
        restarts = world.restarts or 0,
        huntKills = world.huntKills or 0,
        bestCombo = world.bestCombo or 0,
        bestAntiHuntChain = world.bestAntiHuntChain or 0,
        riskSuccesses = world.riskSuccesses or 0,
        lostRiskScore = world.lostRiskScore or 0,
        endless = world.endless == true,
    }
    return world._reviveCheckpoint
end

function RunFlow.startOverload(world, carryOver)
    world:clearTransientPrompts()
    world.round = world.round + 1
    local previousMap = world.mapId
    local nextPlan = LayerPlan.get(world.round)
    if world.endless and world.round >= 11 then
        EndlessOverclock.beginLayer(world)
    end
    ProtocolSys.applyLayer(world, nextPlan)
    local mapChanged = previousMap ~= nextPlan.map
    local layoutChanged = world.layout == nil or world.layout.index ~= nextPlan.layout
    if mapChanged or layoutChanged then
        MapRuntime.load(world, nextPlan.map, nextPlan.layout, previousMap == nil)
    end
    world:spawnPatrols()
    world.phase = "overload"
    world.phaseTime = 0
    world.huntTargetsLeft = 0
    world.antiHuntChain = 0
    world.antiHuntTimer = 0
    world.antiHuntElapsed = 0
    world.antiHuntResolveTimer = nil
    world.antiHuntResolved = false
    world.antiHuntSnapshot = nil
    world.layerSettlement = nil
    world.activeModules.capacitor = world.modules.capacitor
    world.activeModules.amplifier = world.modules.amplifier
    world.modules.capacitor = false
    world.modules.amplifier = false
    world.activeCache = world.pendingCache
    world.pendingCache = 0
    world.overloadDuration = Config.OVERLOAD.duration
        + (world.activeModules.capacitor and Config.MODULES.capacitor.bonusTime or 0)
        + (world.activeCache >= 1 and Config.RISK.cacheTime or 0)
    world.overloadLeft = world.overloadDuration
    world.pulseCd, world.collapseCd, world.chainTimer = 0, 0, 0
    world.hordeTimer = 0.4
    world.trackerTimer = nextPlan.difficulty.trackerInterval or 0
    world.trackerSpawnCount = 0
    world.overloadContactWindow = 0
    world.overloadContactLoss = 0
    world.lastWarnSecond = -1
    world.dismantle = nil
    world.restartChannel = nil
    world.cloakLeft = 0
    world:beginLayerStats()
    if carryOver then
        if world.activeModules.capacitor then
            world:addFx("banner", { text = "扩容模块生效:过载 +" ..
                Config.MODULES.capacitor.bonusTime .. " 秒", dur = 2.0 })
        end
        if world.activeModules.amplifier then
            world:addFx("banner", { text = "链路放大器生效:连锁 +" ..
                Config.MODULES.amplifier.bonusJumps .. " 跳", dur = 2.0 })
        end
        if world.activeCache >= 1 then
            local message = "超额缓存 Lv" .. world.activeCache .. ":过载 +" .. Config.RISK.cacheTime .. " 秒"
            if world.activeCache >= 2 then
                message = message .. " · 连锁 +" .. Config.RISK.cacheChainTargets
            end
            world:addFx("banner", { text = message, dur = 2.0 })
            world:emit("cache_applied")
        end
    end
    if world.mark and world.mark.ref and not world.mark.ref.dead then
        world.mark.armed = true
    else
        world.mark = nil
    end
    for _, wreck in ipairs(world.wrecks) do if wreck.deep then wreck.dead = true end end
    for _, relay in ipairs(world.relays) do
        relay.dead = false
        relay.hp = relay.maxHp
    end
    world:spawnPatrols()
    ProtocolSys.resetRound(world, true)
    world:pickOpportunities()
    world._ovSnap = { heavyKills = world.counters.heavyKills or 0,
        nodes = world.counters.nodes or 0, relays = world.counters.relays or 0 }
    world.areaAnnouncement = {
        text = string.format("第 %d 层", world.round),
        sub = (nextPlan.fairGate and nextPlan.fairGate.routeHint)
            or string.format("%s · %s", world.mapDef.name, world.layout.name),
        left = Config.FORMAL.layerIntroDuration,
    }
    world.pendingOverloadStart = { mapChanged = mapChanged, previousMap = previousMap }
    if world.skipLayerIntro then
        RunFlow.activateOverload(world)
    else
        world.phase = "layer_intro"
        world.phaseTime = 0
        world.layerIntroTimer = Config.FORMAL.layerIntroDuration
        world.layerIntroCue = tostring(math.ceil(world.layerIntroTimer))
        world:emit("layer_intro_start")
    end
    if Config.DEBUG.log then
        print(string.format("[WORLD] Layer %d prepared (intro=%.1f skip=%s dur=%.1f)",
            world.round, world.layerIntroTimer, tostring(world.skipLayerIntro), world.overloadDuration))
    end
end

function RunFlow.activateOverload(world)
    local pending = world.pendingOverloadStart or {}
    world.pendingOverloadStart = nil
    world.phase = "overload"
    world.phaseTime = 0
    world.layerIntroTimer = 0
    world.layerIntroCue = "开始"
    world.layerIntroCueLeft = 0.55
    if world.areaAnnouncement then world.areaAnnouncement.left = 0 end
    world:addFx("phaseflash", { color = "overload", dur = 0.5 })
    if pending.mapChanged and pending.previousMap ~= nil then world:emit("map_switch") end
    if world.layerPlan.milestone then
        world:addFx("banner", { text = "第10层里程碑 · 双协议", dur = 2.4 })
        world:emit("milestone_10")
    end
    world:emit("overload_start")
    if Config.DEBUG.log then
        print(string.format("[WORLD] Layer %d OVERLOAD start (dur=%.1f cap=%s amp=%s)",
            world.round, world.overloadDuration,
            tostring(world.activeModules.capacitor), tostring(world.activeModules.amplifier)))
    end
end

function RunFlow.updateLayerIntro(world, dt)
    local before = math.ceil(math.max(0, world.layerIntroTimer))
    world.layerIntroTimer = math.max(0, world.layerIntroTimer - dt)
    local after = math.ceil(world.layerIntroTimer)
    if after > 0 and after ~= before then
        world.layerIntroCue = tostring(after)
        world:emit("layer_intro_tick", nil, nil, after)
    end
    if world.layerIntroTimer <= 0 then RunFlow.activateOverload(world) end
end

function RunFlow.startAntiHunt(world)
    world:clearTransientPrompts()
    world.phase = "anti_hunt"
    world.phaseTime = 0
    world.antiHuntTimer = Config.ANTI_HUNT_PHASE.maximumDuration
    world.antiHuntElapsed = 0
    world.antiHuntResolveTimer = nil
    world.antiHuntResolved = false
    world.antiHuntTargetsCleared = false
    world.antiHuntClearFeedback = false
    world.antiHuntZeroThreat = false
    world.antiHuntChain = 0
    world.huntTargetsLeft = 0
    world.pulseCd, world.collapseCd = 0, 0
    world.chainTimer = Config.ANTI_HUNT_PHASE.chainWarmup
    world.overloadContactWindow = 0
    world.overloadContactLoss = 0
    world.dismantle = nil
    world.restartChannel = nil
    world.cloakLeft = 0

    local player = world.player
    player.hp = math.min(player.maxHp, player.hp + Config.PLAYER.restartHeal)

    local pressureCandidates, fallbackCandidates = {}, {}
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            local redirectedPressure = enemy.wasChasing
                and (enemy.state == "decoyed" or enemy.state == "lost" or enemy.state == "search")
            local pressureTarget = enemy.hunter or enemy.state == "chase" or enemy.state == "alert"
                or enemy.state == "search" or redirectedPressure
            if pressureTarget then
                pressureCandidates[#pressureCandidates + 1] = enemy
            else
                fallbackCandidates[#fallbackCandidates + 1] = enemy
            end
        end
    end
    local function byPlayerDistance(a, b)
        return Util.dist2(a.x, a.y, player.x, player.y)
            < Util.dist2(b.x, b.y, player.x, player.y)
    end
    table.sort(pressureCandidates, byPlayerDistance)
    table.sort(fallbackCandidates, byPlayerDistance)

    local selected, selectedCount = {}, 0
    local function selectCandidate(enemy)
        if selectedCount >= Config.FORMAL.huntMarkMax or selected[enemy] then return end
        selected[enemy] = true
        selectedCount = selectedCount + 1
    end
    for _, enemy in ipairs(pressureCandidates) do selectCandidate(enemy) end
    if selectedCount < Config.FORMAL.huntPreferredMinimum then
        for _, enemy in ipairs(fallbackCandidates) do
            selectCandidate(enemy)
            if selectedCount >= Config.FORMAL.huntPreferredMinimum then break end
        end
    end

    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            enemy.huntTarget = false
            enemy.huntLeft = 0
            if selected[enemy] then
                enemy.huntTarget = true
                enemy.huntLeft = Config.ANTI_HUNT_PHASE.maximumDuration
                enemy.hunter = false
                enemy.stun = math.max(enemy.stun or 0, Config.FORMAL.huntStunTime)
                enemy.daze = 0
                enemy.antiHuntMode = "reward"
                world.huntTargetsLeft = world.huntTargetsLeft + 1
            else
                enemy.daze = math.max(enemy.daze or 0, Config.ANTI_HUNT_PHASE.ordinaryDazeTime)
                enemy.state = "patrol"
                enemy.suspicion = 0
                enemy.stateTime = 0
                enemy.hunter = false
                enemy.wasChasing = false
                enemy.decoyTarget = nil
                enemy.attackCd = 0
                enemy.heavyWindup = 0
                enemy.antiHuntMode = "ordinary"
            end
        end
    end
    world.antiHuntSnapshot = {
        pressureCount = #pressureCandidates,
        aliveCount = #pressureCandidates + #fallbackCandidates,
        fallbackCount = math.max(0, world.huntTargetsLeft - #pressureCandidates),
        selectedCount = world.huntTargetsLeft,
    }
    world.antiHuntZeroThreat = world.antiHuntSnapshot.aliveCount == 0
    world.huntMarked = world.huntMarked + world.huntTargetsLeft
    if world.huntTargetsLeft > 0 then world:emit("hunt_target") end

    world:addFx("bigring", { x = player.x, y = player.y, r = Config.FORMAL.huntMarkRadius,
        color = "cyan", dur = 0.7 })
    -- 039B：重启完成的翻盘瞬间——二次同心冲击波 + 更强的短镜头震动，
    -- 复用既有bigring/shake/phaseflash，不新增粒子系统。
    world:addFx("bigring", { x = player.x, y = player.y,
        r = Config.FORMAL.huntMarkRadius * 0.62, color = "purple", dur = 0.45 })
    world:addFx("shake", { power = 12, dur = 0.35 })
    world:addFx("phaseflash", { color = "overload", dur = 0.55 })
    if world.huntTargetsLeft > 0 then
        world:addFx("banner", { text = string.format("反猎启动 · 目标 %d · 窗口 %.0f 秒",
            world.huntTargetsLeft, Config.ANTI_HUNT_PHASE.maximumDuration), dur = 2.0 })
    else
        world:addFx("banner", { text = "本层威胁已清空", dur = 1.0 })
    end
    world:emit("anti_hunt_start")
    TraceHeat.onRestart(world)
    if world.antiHuntZeroThreat then
        world.antiHuntResolveTimer = Config.ANTI_HUNT_PHASE.zeroThreatDelay
    end
    if Config.DEBUG.log then
        print(string.format("[WORLD] Layer %d ANTI_HUNT start targets=%d",
            world.round, world.huntTargetsLeft))
    end
end

function RunFlow.buildLayerSettlement(world)
    local stats = world.layerStats or world:newLayerStats()
    stats.scoreGained = world.score - (stats.scoreAtLayerStart or 0)
    stats.heatPeak = math.max(stats.heatPeak or 0, world.heatPeakRound or 0)
    return {
        layer = world.round,
        scoreAtLayerStart = stats.scoreAtLayerStart or 0,
        scoreGained = stats.scoreGained,
        totalScore = world.score,
        normalKills = stats.normalKills or 0,
        heavyKills = stats.heavyKills or 0,
        antiHuntKills = stats.antiHuntKills or 0,
        antiHuntScore = stats.antiHuntScore or 0,
        maxCombo = stats.maxCombo or 0,
        wrecksDismantled = stats.wrecksDismantled or 0,
        normalWrecksDismantled = stats.normalWrecksDismantled or 0,
        coresGained = stats.coresGained or 0,
        deepWrecks = stats.deepWrecks or 0,
        heatPeak = math.floor(stats.heatPeak or 0),
        wreckDataGained = stats.wreckDataGained or 0,
        toolsUsed = stats.toolsUsed or 0,
        wreckData = world.wreckData or 0,
        coreCount = world.coreCount or 0,
        runComplete = world.round == Config.RUN.finalLayer and not world.endless,
    }
end

function RunFlow.finishAntiHunt(world)
    if world.antiHuntResolved or world.phase == "dead" then return end
    world.antiHuntResolved = true
    world.antiHuntTimer = 0
    world.antiHuntResolveTimer = nil
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            enemy.huntTarget = false
            enemy.huntLeft = 0
            enemy.antiHuntMode = nil
            enemy.hunter = false
            enemy.state = "patrol"
            enemy.stateTime = 0
            enemy.suspicion = 0
            enemy.loseTimer = 0
            enemy.wasChasing = false
            enemy.attackCd = 0
            enemy.heavyWindup = 0
            enemy.decoyTarget = nil
            enemy.lastSeenX, enemy.lastSeenY = nil, nil
            enemy.stun, enemy.daze, enemy.jammed = 0, 0, 0
            enemy.roamTimer = 0
            enemy.roamX, enemy.roamY = nil, nil
            enemy.dead = true
        end
    end
    Util.compact(world.enemies, world.enemyPool)
    world.huntTargetsLeft = 0
    world.decoys = {}
    world.dismantle = nil
    world.restartChannel = nil
    world.mark = nil
    world.opportunities = nil
    world:clearTransientPrompts()
    for _, effect in ipairs(world.fx) do effect.dead = true end
    Util.compact(world.fx, world.fxPool)

    world.layerSettlement = RunFlow.buildLayerSettlement(world)
    world.phase = "layer_settlement"
    world.phaseTime = 0
    RunShop.open(world)
    if EndlessOverclock.isActive(world) then
        EndlessOverclock.onLayerComplete(world)
        EndlessOverclock.prepareChoice(world)
    end
    TraceHeat.onLayerComplete(world)
    if world.round == Config.RUN.finalLayer and not world.endless then world.runComplete = true end
    world:emit("layer_settled")
    world:signal("layer_ready_for_settlement")
    if Config.DEBUG.log then
        print(string.format("[WORLD] Layer %d SETTLEMENT score+%d antiHunt=%d",
            world.round, world.layerSettlement.scoreGained, world.layerSettlement.antiHuntKills))
    end
end

function RunFlow.advanceLayer(world)
    if world.phase ~= "layer_settlement" then return false end
    if world.overclockChoiceOpen then return false end
    RunFlow.saveReviveCheckpoint(world, world.round)
    world.layerSettlement = nil
    world.shopUi = nil
    world.pendingSignal = nil
    world.runComplete = false
    world:startOverload(true)
    return true
end

function RunFlow.chooseEndless(world)
    if world.phase ~= "layer_settlement" then return false end
    world.endless = true
    world.runComplete = false
    world:addFx("banner", { text = "继续无尽 · 热度不再完全清零", dur = 2.4 })
    world:emit("endless_start")
    return RunFlow.advanceLayer(world)
end

function RunFlow.completeChallenge(world)
    if world.phase ~= "layer_settlement" then return false end
    world.challengeCompleted = true
    world.layerSettlement = nil
    world.shopUi = nil
    world.pendingSignal = nil
    world.runComplete = false
    world.challengeExitConfirm = false
    world.challengeCheckpointAvailable = false
    world.reviveOffer = nil
    world.rewardedReviveState = "closed"
    world.phaseBeforeDeath = nil
    world.phase = "dead"
    world.phaseTime = 0
    world:clearTransientPrompts()
    world:emit("challenge_complete")
    return true
end

function RunFlow.buyRunUpgrade(world, itemId)
    if world.phase ~= "layer_settlement" then return false, "只能在协议整备中升级" end
    local ok, message = RunShop.buy(world, itemId)
    if ok then
        world:addFx("toast", { text = message, dur = 1.4 })
        world:emit("shop_purchase")
    elseif message then
        world:feedback(message)
    end
    return ok, message
end

function RunFlow.die(world)
    if world.phase == "dead" then return end
    world.phaseBeforeDeath = world.phase
    world.phaseTimeBeforeDeath = world.phaseTime
    ScoreSys.loseRisk(world)
    if world.phase == "depleted" and world.readyAt then
        local snap = world._readySnap or {}
        local loss = {
            cache = world:totalCacheLevel(),
            cores = math.max(0, world.coreCount - (snap.coreCount or world.coreCount)),
            crafted = (world.counters.crafted or 0) - (snap.crafted or 0),
        }
        if loss.cache > 0 or loss.cores > 0 or loss.crafted > 0 then
            world.unbankedLoss = loss
            world:bump("unbankedCacheLost", loss.cache)
            world:bump("unbankedCoresLost", loss.cores)
            world:bump("unbankedCraftedLost", loss.crafted)
        end
    end
    world.phase = "dead"
    world.phaseTime = 0
    world.dismantle = nil
    world.restartChannel = nil
    world.layerSettlement = nil
    world.shopUi = nil
    world.runComplete = false
    world.pendingSignal = nil
    -- 死亡页仍持有本层战局，供广告安全复活读取；只释放过期视觉引用，
    -- 不清空资源、升级、敌人或位置，因此不会改变安全复活与免费检查点重试语义。
    world:clearTransientEffects()
    world:emit("player_dead")
    if Config.DEBUG.log then
        print(string.format("[WORLD] DEAD round=%d time=%.1f restarts=%d",
            world.round, world.timeAlive, world.restarts))
    end
end

function RunFlow.reviveAssisted(world)
    if world.phase ~= "dead" then return false end
    local resumePhase = world.phaseBeforeDeath
    if resumePhase ~= "overload" and resumePhase ~= "depleted"
        and resumePhase ~= "anti_hunt" then
        return false
    end
    local map = world.mapId and MapDef.get(world.mapId) or nil
    if type(map) ~= "table" or type(map.playerSpawn) ~= "table" then return false end

    -- 保留当前层已发生的分数、资源、敌人、协议、能量和阶段计时；只取消死亡时
    -- 被打断的交互，并把玩家送回该地图既有安全出生点，避免原地贴身连死。
    local px, py = MapDef.tileCenter(map.playerSpawn.col, map.playerSpawn.row)
    world.player.x, world.player.y = px, py
    -- 广告原地复活统一为满血；算力、热度、分数、敌人和道具数量均保留。
    -- 安全区只改变出生位置，不补充任何工具或资源。
    world.player.hp = world.player.maxHp
    world.player.hurtFlash = 0
    world.player.moving = false
    world.phase = resumePhase
    world.phaseTime = world.phaseTimeBeforeDeath or 0
    world.phaseBeforeDeath = nil
    world.phaseTimeBeforeDeath = nil
    world.dismantle = nil
    world.restartChannel = nil
    world.challengeCompleted = false
    world.events = {}
    world:addFx("banner", { text = "已复活 · 满血安全区继续", dur = 2.4 })
    return true
end

function RunFlow.updateAntiHunt(world, dt, pressed)
    if world.antiHuntResolveTimer then
        world.antiHuntElapsed = (world.antiHuntElapsed or 0) + dt
        world.antiHuntTimer = math.max(0,
            Config.ANTI_HUNT_PHASE.maximumDuration - world.antiHuntElapsed)
        world.antiHuntResolveTimer = world.antiHuntResolveTimer - dt
        if not world.antiHuntZeroThreat then CombatSys.update(world, dt, pressed) end
        if world.phase ~= "anti_hunt" then return end
        if (not world.antiHuntZeroThreat
                and world.antiHuntElapsed >= Config.ANTI_HUNT_PHASE.maximumDuration)
            or world.antiHuntResolveTimer <= 0 then
            RunFlow.finishAntiHunt(world)
        end
        return
    end

    world.antiHuntElapsed = (world.antiHuntElapsed or 0) + dt
    world.antiHuntTimer = math.max(0,
        Config.ANTI_HUNT_PHASE.maximumDuration - world.antiHuntElapsed)
    CombatSys.update(world, dt, pressed)
    if world.phase ~= "anti_hunt" then return end

    local rewardAlive, ordinaryAlive = 0, 0
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            if enemy.huntTarget then
                enemy.huntLeft = world.antiHuntTimer
                rewardAlive = rewardAlive + 1
            else
                ordinaryAlive = ordinaryAlive + 1
            end
        end
    end
    world.huntTargetsLeft = rewardAlive

    if rewardAlive <= 0 and not world.antiHuntTargetsCleared then
        world.antiHuntTargetsCleared = true
        world:addFx("banner", { text = ordinaryAlive > 0
            and "反猎目标已清除 · 继续清场" or "反猎目标已清除", dur = 1.4 })
        world:emit("anti_hunt_cleared")
    end

    -- 反猎窗口已冻结为完整 10 秒：提前清掉奖励目标只改变反馈，不提前跳过
    -- 反杀和清场时间。这样玩家能获得完整的反转节奏与对应音乐段。
    if world.antiHuntElapsed >= Config.ANTI_HUNT_PHASE.maximumDuration then
        if not world.antiHuntTargetsCleared then world:emit("anti_hunt_timeout") end
        RunFlow.finishAntiHunt(world)
    elseif world.antiHuntTargetsCleared
        and world.antiHuntElapsed >= Config.ANTI_HUNT_PHASE.minimumVisibleDuration then
        if not world.antiHuntClearFeedback then
            world.antiHuntClearFeedback = true
            world:addFx("banner", { text = "清算完成", dur = Config.ANTI_HUNT_PHASE.clearedDelay })
        end
        world.antiHuntResolveTimer = Config.ANTI_HUNT_PHASE.clearedDelay
    end
end

return RunFlow
