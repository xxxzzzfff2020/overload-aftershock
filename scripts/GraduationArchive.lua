-- GraduationArchive.lua
-- L10 毕业档：保存直接进入 L11 会继承的层间确认态。
-- 不保存敌人、位置、热度、阶段或本层未确认收益。

local RunShop = require "RunShop"

local GraduationArchive = {}
GraduationArchive.VERSION = 1
GraduationArchive.SLOT_COUNT = 3

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
    source = type(source) == "table" and source or {}
    for _, key in ipairs(UPGRADE_KEYS) do out[key] = integer(source[key], 0) end
    return out
end

local function moduleCopy(source)
    source = type(source) == "table" and source or {}
    return { capacitor = source.capacitor == true, amplifier = source.amplifier == true }
end

function GraduationArchive.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local sourceRunId = raw.source_run_id or raw.sourceRunId or raw.run_id or raw.runId
    if sourceRunId == nil or tostring(sourceRunId) == "" then return nil end
    local sourceLayer = integer(raw.source_layer or raw.sourceLayer or raw.layer, 0)
    if sourceLayer ~= 10 then return nil end
    -- A confirmed layer checkpoint is a normal, board-eligible continuation.
    -- Only an unconfirmed/realtime recovery is assisted; do not downgrade a
    -- checkpoint archive merely because it carries recovered=true metadata.
    local checkpointRecovery = raw.checkpoint_recovery == true
        or raw.checkpointRecovery == true
    local invalidRecovery = (raw.recovered == true or raw.recoveredRun == true)
        and not checkpointRecovery
    local assisted = raw.assisted_run == true or raw.assistedRun == true
        or invalidRecovery
        or raw.challenge_retry == true
        or integer(raw.challenge_retry_count or raw.challengeRetryCount, 0) > 0
        or raw.rewarded_revive_used == true or raw.rewardedReviveUsed == true
    return {
        version = integer(raw.version, GraduationArchive.VERSION),
        schemaVersion = integer(raw.schema_version or raw.schemaVersion, 9),
        archiveId = tostring(raw.archive_id or raw.archiveId
            or ("graduation:" .. tostring(sourceRunId))),
        sourceRunId = tostring(sourceRunId),
        seed = integer(raw.seed, 0),
        sourceLayer = sourceLayer,
        score = integer(raw.score, 0),
        wreckData = integer(raw.wreck_data or raw.wreckData, 0),
        coreCount = integer(raw.core_count or raw.coreCount, 0),
        runUpgrades = upgradesCopy(raw.run_upgrades or raw.runUpgrades),
        modules = moduleCopy(raw.modules),
        activeModules = moduleCopy(raw.active_modules or raw.activeModules),
        pendingCache = integer(raw.pending_cache or raw.pendingCache, 0),
        activeCache = integer(raw.active_cache or raw.activeCache, 0),
        shopPurchases = integer(raw.shop_purchases or raw.shopPurchases, 0),
        counters = flatCopy(raw.counters),
        restarts = integer(raw.restarts, 0),
        huntKills = integer(raw.hunt_kills or raw.huntKills, 0),
        bestCombo = integer(raw.best_combo or raw.bestCombo, 0),
        bestAntiHuntChain = integer(
            raw.best_anti_hunt_chain or raw.bestAntiHuntChain, 0),
        riskSuccesses = integer(raw.risk_successes or raw.riskSuccesses, 0),
        lostRiskScore = integer(raw.lost_risk_score or raw.lostRiskScore, 0),
        timeAlive = math.max(0, finite(raw.time_alive or raw.timeAlive, 0)),
        hp = math.max(1, finite(raw.hp or raw.checkpoint_hp or raw.checkpointHp, 1)),
        challengeRetryCount = integer(
            raw.challenge_retry_count or raw.challengeRetryCount, 0),
        assistedRun = assisted,
        cleanRun = (raw.clean_run == true or raw.cleanRun == true)
            and not assisted,
        rewardedReviveAttempted = raw.rewarded_revive_attempted == true
            or raw.rewardedReviveAttempted == true,
        rewardedReviveUsed = raw.rewarded_revive_used == true
            or raw.rewardedReviveUsed == true,
        createdAt = integer(raw.created_at or raw.createdAt, 0),
    }
end

function GraduationArchive.capture(world, createdAt)
    if type(world) ~= "table" or integer(world.round, 0) ~= 10 then return nil end
    return GraduationArchive.normalize({
        version = GraduationArchive.VERSION,
        schema_version = 9,
        archive_id = string.format("graduation:%s:%s", tostring(world.runId or "run"),
            tostring(createdAt or os.time())),
        source_run_id = world.runId,
        source_layer = 10,
        seed = world.seed,
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
        challenge_retry_count = world.challengeRetryCount,
        assisted_run = world.assistedRun == true,
        clean_run = world.assistedRun ~= true
            and (world.recoveredRun ~= true or world.checkpointRecovery == true)
            and (world.challengeRetryCount or 0) == 0
            and world.rewardedReviveUsed ~= true,
        rewarded_revive_attempted = world.rewardedReviveAttempted == true,
        rewarded_revive_used = world.rewardedReviveUsed == true,
        created_at = createdAt or os.time(),
    })
end

function GraduationArchive.serialize(raw)
    local a = GraduationArchive.normalize(raw)
    if not a then return nil end
    return {
        version = GraduationArchive.VERSION,
        schema_version = 9,
        archive_id = a.archiveId,
        source_run_id = a.sourceRunId,
        source_layer = a.sourceLayer,
        seed = a.seed,
        score = a.score,
        wreck_data = a.wreckData,
        core_count = a.coreCount,
        run_upgrades = upgradesCopy(a.runUpgrades),
        modules = moduleCopy(a.modules),
        active_modules = moduleCopy(a.activeModules),
        pending_cache = a.pendingCache,
        active_cache = a.activeCache,
        shop_purchases = a.shopPurchases,
        counters = flatCopy(a.counters),
        restarts = a.restarts,
        hunt_kills = a.huntKills,
        best_combo = a.bestCombo,
        best_anti_hunt_chain = a.bestAntiHuntChain,
        risk_successes = a.riskSuccesses,
        lost_risk_score = a.lostRiskScore,
        time_alive = a.timeAlive,
        hp = a.hp,
        challenge_retry_count = a.challengeRetryCount,
        assisted_run = a.assistedRun,
        clean_run = a.cleanRun,
        rewarded_revive_attempted = a.rewardedReviveAttempted,
        rewarded_revive_used = a.rewardedReviveUsed,
        created_at = a.createdAt,
    }
end

function GraduationArchive.normalizeSlots(raw)
    local slots = {}
    for index = 1, GraduationArchive.SLOT_COUNT do
        local value = nil
        if type(raw) == "table" then
            value = raw[index] or raw[tostring(index)] or raw["slot" .. tostring(index)]
        end
        slots[index] = GraduationArchive.normalize(value)
    end
    return slots
end

-- 在 World:startOverload 前回填；新局 runId 由调用者提供，永不复用原毕业局 ID。
function GraduationArchive.applyBeforeLayer(world, raw)
    local a = GraduationArchive.normalize(raw)
    if type(world) ~= "table" or not a then return false end
    world.seed = a.seed
    world.round = 10
    world.score = a.score
    world.wreckData = a.wreckData
    world.coreCount = a.coreCount
    world.runUpgrades = upgradesCopy(a.runUpgrades)
    world.modules = moduleCopy(a.modules)
    world.activeModules = moduleCopy(a.activeModules)
    world.pendingCache = a.pendingCache
    world.activeCache = a.activeCache
    world.shopPurchases = a.shopPurchases
    world.counters = flatCopy(a.counters)
    world.restarts = a.restarts
    world.huntKills = a.huntKills
    world.bestCombo = a.bestCombo
    world.bestAntiHuntChain = a.bestAntiHuntChain
    world.riskSuccesses = a.riskSuccesses
    world.lostRiskScore = a.lostRiskScore
    world.timeAlive = a.timeAlive
    world.player.hp = math.min(world.player.maxHp, a.hp)
    world.energy = 0
    world.riskScore = 0
    world.endless = true
    world.graduationArchiveRun = true
    world.sourceGraduationArchiveId = a.archiveId
    world.challengeRetryCount = a.challengeRetryCount
    world.challengeRetry = a.challengeRetryCount > 0
    world.rewardedReviveAttempted = a.rewardedReviveAttempted
    world.rewardedReviveUsed = a.rewardedReviveUsed
    world.assistedRun = a.assistedRun == true or not a.cleanRun
    world.cleanRun = not world.assistedRun
    world.recoveredRun = false
    world.checkpointRecovery = false
    return true
end

return GraduationArchive
