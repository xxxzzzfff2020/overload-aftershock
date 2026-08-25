-- 047：无尽模式层间快照。
-- 与 ChallengeCheckpoint 分离：只保存已确认的层间状态，不保存敌人、位置、
-- 当前阶段或本层未确认收益。快照是恢复入口，不改变战斗规则。

local RunShop = require "RunShop"
local EndlessOverclock = require "EndlessOverclock"

local EndlessCheckpoint = {}
EndlessCheckpoint.VERSION = 1
EndlessCheckpoint.SCHEMA_VERSION = 10

local UPGRADE_KEYS = {
    "collapseCooldownLevel", "pulseCooldownLevel", "chainIntervalLevel",
    "jammerBonusUses", "decoyBonusUses", "cloakBonusUses",
}

local function integer(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return math.max(0, math.floor(n))
end

local function finite(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return n
end

local function flatCopy(source)
    local out = {}
    for key, value in pairs(type(source) == "table" and source or {}) do
        if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
            out[key] = value
        end
    end
    return out
end

local function upgradesCopy(source)
    local out = RunShop.newUpgrades()
    for _, key in ipairs(UPGRADE_KEYS) do out[key] = integer(source and source[key], 0) end
    return out
end

local function modulesCopy(source)
    source = type(source) == "table" and source or {}
    return { capacitor = source.capacitor == true, amplifier = source.amplifier == true }
end

local function overclockCopy(raw)
    if type(raw) ~= "table" then return nil end
    local out = {
        version = integer(raw.version, 1),
        runSeed = integer(raw.runSeed, 1),
        choiceSeed = integer(raw.choiceSeed, 1),
        rng = integer(raw.rng, 1),
        data = integer(raw.data, 0),
        shards = integer(raw.shards, 0),
        overflowCores = integer(raw.overflowCores, 0),
        overflowWreckData = integer(raw.overflowWreckData, 0),
        spent = integer(raw.spent, 0),
        choiceIndex = integer(raw.choiceIndex, 0),
        choiceCount = integer(raw.choiceCount, 0),
        layerChoiceCount = integer(raw.layerChoiceCount, 0),
        freeChoiceTokens = integer(raw.freeChoiceTokens, 0),
        starterGranted = raw.starterGranted == true,
        entryChoice = raw.entryChoice == true,
        choiceMode = (raw.choiceMode == "free" or raw.choiceMode == "data"
            or raw.choiceMode == "starter") and raw.choiceMode or nil,
        levels = {},
        history = {},
        currentChoices = nil,
        currentCost = integer(raw.currentCost, 0),
        lastGainReason = type(raw.lastGainReason) == "string" and raw.lastGainReason or nil,
    }
    for key, value in pairs(type(raw.levels) == "table" and raw.levels or {}) do
        out.levels[tostring(key)] = integer(value, 0)
    end
    for index, entry in ipairs(type(raw.history) == "table" and raw.history or {}) do
        if type(entry) == "table" and type(entry.id) == "string" then
            out.history[index] = {
                layer = integer(entry.layer, 0), id = entry.id, cost = integer(entry.cost, 0),
            }
        end
    end
    if type(raw.currentChoices) == "table" then
        out.currentChoices = {}
        for index, card in ipairs(raw.currentChoices) do
            if type(card) == "table" and type(card.id) == "string" then
                out.currentChoices[index] = { id = card.id }
            elseif type(card) == "string" then
                out.currentChoices[index] = { id = card }
            end
        end
        if #out.currentChoices ~= 3 then out.currentChoices = nil end
    end
    return out
end

function EndlessCheckpoint.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local runId = raw.run_id or raw.runId
    local nextLayer = integer(raw.next_layer or raw.nextLayer, 0)
    if runId == nil or tostring(runId) == "" or nextLayer < 11 then return nil end
    local cp = {
        version = integer(raw.version, EndlessCheckpoint.VERSION),
        schemaVersion = integer(raw.schema_version or raw.schemaVersion,
            EndlessCheckpoint.SCHEMA_VERSION),
        runId = tostring(runId),
        seed = integer(raw.seed, 1),
        endlessRunSeed = integer(raw.endless_run_seed or raw.endlessRunSeed, 1),
        completedLayer = integer(raw.completed_layer or raw.completedLayer, nextLayer - 1),
        nextLayer = nextLayer,
        score = integer(raw.score, 0),
        wreckData = integer(raw.wreck_data or raw.wreckData, 0),
        coreCount = integer(raw.core_count or raw.coreCount, 0),
        runUpgrades = upgradesCopy(raw.run_upgrades or raw.runUpgrades),
        modules = modulesCopy(raw.modules),
        activeModules = modulesCopy(raw.active_modules or raw.activeModules),
        pendingCache = integer(raw.pending_cache or raw.pendingCache, 0),
        activeCache = integer(raw.active_cache or raw.activeCache, 0),
        shopPurchases = integer(raw.shop_purchases or raw.shopPurchases, 0),
        counters = flatCopy(raw.counters),
        restarts = integer(raw.restarts, 0),
        huntKills = integer(raw.hunt_kills or raw.huntKills, 0),
        bestCombo = integer(raw.best_combo or raw.bestCombo, 0),
        bestAntiHuntChain = integer(raw.best_anti_hunt_chain or raw.bestAntiHuntChain, 0),
        riskSuccesses = integer(raw.risk_successes or raw.riskSuccesses, 0),
        lostRiskScore = integer(raw.lost_risk_score or raw.lostRiskScore, 0),
        timeAlive = math.max(0, finite(raw.time_alive or raw.timeAlive, 0)),
        hp = math.max(1, finite(raw.hp or raw.checkpoint_hp or raw.checkpointHp, 1)),
        cleanRun = raw.clean_run == true or raw.cleanRun == true,
        assistedRun = raw.assisted_run == true or raw.assistedRun == true,
        rewardedReviveAttempted = raw.rewarded_revive_attempted == true
            or raw.rewardedReviveAttempted == true,
        rewardedReviveUsed = raw.rewarded_revive_used == true
            or raw.rewardedReviveUsed == true,
        rewardedReviveCount = integer(raw.rewarded_revive_count or raw.rewardedReviveCount, 0),
        recoveredRun = raw.recovered_run == true or raw.recoveredRun == true,
        checkpointRecovery = raw.checkpoint_recovery == true or raw.checkpointRecovery == true,
        sourceGraduationArchiveId = raw.source_graduation_archive_id
            or raw.sourceGraduationArchiveId,
        overclock = overclockCopy(raw.overclock),
        createdAt = integer(raw.created_at or raw.createdAt, 0),
    }
    if cp.assistedRun then cp.cleanRun = false end
    return cp
end

function EndlessCheckpoint.capture(world, nextLayer, createdAt)
    if type(world) ~= "table" or world.endless ~= true then return nil end
    local overclock = EndlessOverclock.snapshot(world)
    return EndlessCheckpoint.normalize({
        version = EndlessCheckpoint.VERSION,
        schema_version = EndlessCheckpoint.SCHEMA_VERSION,
        run_id = world.runId,
        seed = world.seed,
        endless_run_seed = world.endlessRunSeed,
        completed_layer = math.max(0, math.floor(tonumber(nextLayer or world.round) or 0) - 1),
        next_layer = nextLayer or ((world.round or 10) + 1),
        score = world.score,
        wreck_data = world.wreckData,
        core_count = world.coreCount,
        run_upgrades = world.runUpgrades,
        modules = world.modules,
        active_modules = world.activeModules,
        pending_cache = world.pendingCache,
        active_cache = world.activeCache,
        shop_purchases = world.shopPurchases,
        counters = world.counters,
        restarts = world.restarts,
        hunt_kills = world.huntKills,
        best_combo = world.bestCombo,
        best_anti_hunt_chain = world.bestAntiHuntChain,
        risk_successes = world.riskSuccesses,
        lost_risk_score = world.lostRiskScore,
        time_alive = world.timeAlive,
        hp = world.player and world.player.hp or 1,
        clean_run = world.cleanRun == true,
        assisted_run = world.assistedRun == true,
        rewarded_revive_attempted = world.rewardedReviveAttempted == true,
        rewarded_revive_used = world.rewardedReviveUsed == true,
        rewarded_revive_count = world.rewardedReviveCount or 0,
        recovered_run = world.recoveredRun == true,
        checkpoint_recovery = world.checkpointRecovery == true,
        source_graduation_archive_id = world.sourceGraduationArchiveId,
        overclock = overclock,
        created_at = createdAt or os.time(),
    })
end

function EndlessCheckpoint.serialize(raw)
    local cp = EndlessCheckpoint.normalize(raw)
    if not cp then return nil end
    return {
        version = cp.version, schema_version = EndlessCheckpoint.SCHEMA_VERSION,
        run_id = cp.runId, seed = cp.seed, endless_run_seed = cp.endlessRunSeed,
        completed_layer = cp.completedLayer, next_layer = cp.nextLayer,
        score = cp.score, wreck_data = cp.wreckData, core_count = cp.coreCount,
        run_upgrades = upgradesCopy(cp.runUpgrades), modules = modulesCopy(cp.modules),
        active_modules = modulesCopy(cp.activeModules), pending_cache = cp.pendingCache,
        active_cache = cp.activeCache, shop_purchases = cp.shopPurchases,
        counters = flatCopy(cp.counters), restarts = cp.restarts, hunt_kills = cp.huntKills,
        best_combo = cp.bestCombo, best_anti_hunt_chain = cp.bestAntiHuntChain,
        risk_successes = cp.riskSuccesses, lost_risk_score = cp.lostRiskScore,
        time_alive = cp.timeAlive, hp = cp.hp, clean_run = cp.cleanRun,
        assisted_run = cp.assistedRun, recovered_run = cp.recoveredRun,
        rewarded_revive_attempted = cp.rewardedReviveAttempted,
        rewarded_revive_used = cp.rewardedReviveUsed,
        rewarded_revive_count = cp.rewardedReviveCount,
        checkpoint_recovery = cp.checkpointRecovery,
        source_graduation_archive_id = cp.sourceGraduationArchiveId,
        overclock = cp.overclock,
        created_at = cp.createdAt,
    }
end

-- 在 World:startOverload 前恢复已经确认的层间状态。当前敌人、位置和阶段仍由
-- 正式 World/LayerPlan 重新生成，避免把刷新前的战斗瞬间伪装成可续关。
function EndlessCheckpoint.applyBeforeLayer(world, raw)
    local cp = EndlessCheckpoint.normalize(raw)
    if type(world) ~= "table" or not cp then return false end
    world.runId = cp.runId
    world.seed = cp.seed
    world.endlessRunSeed = cp.endlessRunSeed
    world.round = cp.nextLayer - 1
    world.score = cp.score
    world.wreckData = cp.wreckData
    world.coreCount = cp.coreCount
    world.runUpgrades = upgradesCopy(cp.runUpgrades)
    world.modules = modulesCopy(cp.modules)
    world.activeModules = modulesCopy(cp.activeModules)
    world.pendingCache = cp.pendingCache
    world.activeCache = cp.activeCache
    world.shopPurchases = cp.shopPurchases
    world.counters = flatCopy(cp.counters)
    world.restarts = cp.restarts
    world.huntKills = cp.huntKills
    world.bestCombo = cp.bestCombo
    world.bestAntiHuntChain = cp.bestAntiHuntChain
    world.riskSuccesses = cp.riskSuccesses
    world.lostRiskScore = cp.lostRiskScore
    world.timeAlive = cp.timeAlive
    world.player.hp = math.min(world.player.maxHp, cp.hp)
    world.energy = 0
    world.riskScore = 0
    world.endless = true
    world.recoveredRun = true
    world.checkpointRecovery = true
    world.rewardedReviveAttempted = cp.rewardedReviveAttempted == true
    world.rewardedReviveUsed = cp.rewardedReviveUsed == true
    world.rewardedReviveCount = cp.rewardedReviveCount or 0
    -- Restoring a confirmed layer-start checkpoint is part of the unified
    -- leaderboard contract.  Checkpoint recovery remains eligible; ad/retry
    -- metadata is retained for display and audit rather than silently turning
    -- an otherwise valid checkpoint continuation into a different board.
    world.assistedRun = cp.assistedRun == true
    world.cleanRun = not world.assistedRun
    world.endlessCheckpointRecovery = true
    world.endlessCheckpointSource = cp
    return true
end

-- startOverload 会清空当层抽卡池；因此恢复必须在层初始化完成后回填。
function EndlessCheckpoint.applyAfterLayerStart(world, raw)
    local cp = EndlessCheckpoint.normalize(raw)
    if type(world) ~= "table" or not cp then return false end
    if cp.overclock then EndlessOverclock.restore(world, cp.overclock) end
    if cp.overclock and cp.overclock.currentChoices then
        world.overclockChoiceOpen = true
    end
    return true
end

return EndlessCheckpoint
