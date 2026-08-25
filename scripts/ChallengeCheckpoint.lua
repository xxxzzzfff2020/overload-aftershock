-- ChallengeCheckpoint.lua
-- 1.1 Challenge 层间检查点：只保存已经确认的层间状态。
-- 明确不保存当前敌人/位置/阶段/热度/能量进度/本层未确认收益。

local RunShop = require "RunShop"

local ChallengeCheckpoint = {}
ChallengeCheckpoint.VERSION = 1
ChallengeCheckpoint.LAYER_START = "LAYER_START"
ChallengeCheckpoint.L10_CHOICE = "L10_CHOICE"

local UPGRADE_KEYS = {
    "collapseCooldownLevel", "pulseCooldownLevel", "chainIntervalLevel",
    "jammerBonusUses", "decoyBonusUses", "cloakBonusUses",
}

local function integer(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return math.max(0, math.floor(n))
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
    source = type(source) == "table" and source or {}
    for _, key in ipairs(UPGRADE_KEYS) do out[key] = integer(source[key], 0) end
    return out
end

local function moduleCopy(source)
    source = type(source) == "table" and source or {}
    return { capacitor = source.capacitor == true, amplifier = source.amplifier == true }
end

function ChallengeCheckpoint.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local state = raw.checkpoint_state or raw.checkpointState
    if state ~= ChallengeCheckpoint.LAYER_START and state ~= ChallengeCheckpoint.L10_CHOICE then
        return nil
    end
    local nextLayer = integer(raw.next_layer or raw.nextLayer, 0)
    if nextLayer < 1 or nextLayer > 10 then return nil end
    if state == ChallengeCheckpoint.L10_CHOICE and nextLayer ~= 10 then return nil end
    local runId = raw.run_id or raw.runId
    if runId == nil or tostring(runId) == "" then return nil end
    return {
        version = integer(raw.version, ChallengeCheckpoint.VERSION),
        schemaVersion = integer(raw.schema_version or raw.schemaVersion, 8),
        runId = tostring(runId),
        seed = integer(raw.seed, 0),
        nextLayer = nextLayer,
        checkpointState = state,
        score = integer(raw.score, 0),
        wreckData = integer(raw.wreck_data or raw.wreckData, 0),
        coreCount = integer(raw.core_count or raw.coreCount, 0),
        runUpgrades = upgradesCopy(raw.run_upgrades or raw.runUpgrades),
        modules = moduleCopy(raw.modules),
        activeModules = moduleCopy(raw.active_modules or raw.activeModules),
        shopPurchases = integer(raw.shop_purchases or raw.shopPurchases, 0),
        counters = flatCopy(raw.counters),
        restarts = integer(raw.restarts, 0),
        huntKills = integer(raw.hunt_kills or raw.huntKills, 0),
        bestCombo = integer(raw.best_combo or raw.bestCombo, 0),
        bestAntiHuntChain = integer(
            raw.best_anti_hunt_chain or raw.bestAntiHuntChain, 0),
        riskSuccesses = integer(raw.risk_successes or raw.riskSuccesses, 0),
        checkpointHp = math.max(1, tonumber(raw.checkpoint_hp or raw.checkpointHp) or 1),
        challengeRetryCount = integer(
            raw.challenge_retry_count or raw.challengeRetryCount, 0),
        assistedRun = raw.assisted_run == true or raw.assistedRun == true,
        rewardedReviveAttempted = raw.rewarded_revive_attempted == true
            or raw.rewardedReviveAttempted == true,
        rewardedReviveUsed = raw.rewarded_revive_used == true
            or raw.rewardedReviveUsed == true,
        rewardedReviveCount = integer(raw.rewarded_revive_count or raw.rewardedReviveCount, 0),
        createdAt = integer(raw.created_at or raw.createdAt, 0),
    }
end

function ChallengeCheckpoint.capture(world, nextLayer, state, runId, createdAt)
    if type(world) ~= "table" then return nil end
    return ChallengeCheckpoint.normalize({
        version = ChallengeCheckpoint.VERSION,
        schema_version = 8,
        run_id = runId or world.runId,
        seed = world.seed,
        next_layer = nextLayer,
        checkpoint_state = state or ChallengeCheckpoint.LAYER_START,
        score = world.score,
        wreck_data = world.wreckData,
        core_count = world.coreCount,
        run_upgrades = world.runUpgrades,
        modules = world.modules,
        active_modules = world.activeModules,
        shop_purchases = world.shopPurchases,
        counters = world.counters,
        restarts = world.restarts,
        hunt_kills = world.huntKills,
        best_combo = world.bestCombo,
        best_anti_hunt_chain = world.bestAntiHuntChain,
        risk_successes = world.riskSuccesses,
        checkpoint_hp = world.player and world.player.hp or 1,
        challenge_retry_count = world.challengeRetryCount,
        assisted_run = world.assistedRun == true,
        rewarded_revive_attempted = world.rewardedReviveAttempted == true,
        rewarded_revive_used = world.rewardedReviveUsed == true,
        rewarded_revive_count = world.rewardedReviveCount or 0,
        created_at = createdAt or os.time(),
    })
end

function ChallengeCheckpoint.serialize(raw)
    local cp = ChallengeCheckpoint.normalize(raw)
    if not cp then return nil end
    return {
        version = ChallengeCheckpoint.VERSION,
        schema_version = 8,
        run_id = cp.runId,
        seed = cp.seed,
        next_layer = cp.nextLayer,
        checkpoint_state = cp.checkpointState,
        score = cp.score,
        wreck_data = cp.wreckData,
        core_count = cp.coreCount,
        run_upgrades = upgradesCopy(cp.runUpgrades),
        modules = moduleCopy(cp.modules),
        active_modules = moduleCopy(cp.activeModules),
        shop_purchases = cp.shopPurchases,
        counters = flatCopy(cp.counters),
        restarts = cp.restarts,
        hunt_kills = cp.huntKills,
        best_combo = cp.bestCombo,
        best_anti_hunt_chain = cp.bestAntiHuntChain,
        risk_successes = cp.riskSuccesses,
        checkpoint_hp = cp.checkpointHp,
        challenge_retry_count = cp.challengeRetryCount,
        assisted_run = cp.assistedRun,
        rewarded_revive_attempted = cp.rewardedReviveAttempted,
        rewarded_revive_used = cp.rewardedReviveUsed,
        rewarded_revive_count = cp.rewardedReviveCount,
        created_at = cp.createdAt,
    }
end

-- 在 World:startOverload 前回填，确保模块与层起点按正式流程初始化。
function ChallengeCheckpoint.applyBeforeLayer(world, raw, recovered, retry)
    local cp = ChallengeCheckpoint.normalize(raw)
    if type(world) ~= "table" or not cp then return false end
    world.runId = cp.runId
    world.seed = cp.seed
    world.round = cp.nextLayer - 1
    world.score = cp.score
    world.wreckData = cp.wreckData
    world.coreCount = cp.coreCount
    world.runUpgrades = upgradesCopy(cp.runUpgrades)
    world.modules = moduleCopy(cp.modules)
    world.activeModules = moduleCopy(cp.activeModules)
    world.shopPurchases = cp.shopPurchases
    world.counters = flatCopy(cp.counters)
    world.restarts = cp.restarts
    world.huntKills = cp.huntKills
    world.bestCombo = cp.bestCombo
    world.bestAntiHuntChain = cp.bestAntiHuntChain
    world.riskSuccesses = cp.riskSuccesses
    world.player.hp = math.min(world.player.maxHp, cp.checkpointHp)
    world.energy = 0
    world.riskScore = 0
    world.challengeRetryCount = cp.challengeRetryCount + (retry == true and 1 or 0)
    world.challengeRetry = world.challengeRetryCount > 0
    world.recoveredRun = recovered == true
    world.checkpointRecovery = recovered == true
    world.rewardedReviveAttempted = cp.rewardedReviveAttempted == true
    world.rewardedReviveUsed = cp.rewardedReviveUsed == true
    world.rewardedReviveCount = cp.rewardedReviveCount or 0
    -- A confirmed layer checkpoint is a deterministic layer-start restore and
    -- is allowed to remain a clean run.  Only an ad/retry flag carried by the
    -- checkpoint (or a newly requested retry) makes the run assisted.
    world.assistedRun = cp.assistedRun == true or world.rewardedReviveUsed
        or world.challengeRetryCount > 0
    world.cleanRun = not world.assistedRun
    return true
end

function ChallengeCheckpoint.enterL10Choice(world)
    if type(world) ~= "table" then return false end
    for _, enemy in ipairs(world.enemies or {}) do enemy.dead = true end
    world.phase = "layer_settlement"
    world.phaseTime = 0
    world.runComplete = true
    world.challengeCompleted = false
    world.layerSettlement = {
        layer = 10, scoreAtLayerStart = world.score, scoreGained = 0,
        totalScore = world.score, normalKills = 0, heavyKills = 0,
        antiHuntKills = 0, antiHuntScore = 0, maxCombo = 0,
        wrecksDismantled = 0, normalWrecksDismantled = 0,
        coresGained = 0, deepWrecks = 0, heatPeak = 0,
        wreckDataGained = 0, toolsUsed = 0,
        wreckData = world.wreckData, coreCount = world.coreCount,
        runComplete = true, restoredChoice = true,
    }
    RunShop.open(world)
    return true
end

return ChallengeCheckpoint
