-- SaveSys.lua
-- 正式存档 Schema v10：本地先行、损坏备份、榜单资格隔离、云端可合并。
-- 只持久化已确认的 Challenge / Endless 层间检查点；不保存当前战斗状态。
-- 024C：WASM 下本地 File 是内存文件系统（刷新即丢，官方文档实证），
-- 跨刷新持久化唯一官方通道是 clientCloud；本地文件只作会话内缓存与损坏备份。

local SaveSys = {}
local ReleaseInfo = require "ReleaseInfo"
local ChallengeCheckpoint = require "ChallengeCheckpoint"
local GraduationArchive = require "GraduationArchive"
local EndlessCheckpoint = require "EndlessCheckpoint"

local FILE_NAME = "overload_aftermath_save_v10.json"
local LEGACY_V9_FILE_NAME = "overload_aftermath_save_v9.json"
local LEGACY_V8_FILE_NAME = "overload_aftermath_save_v8.json"
local LEGACY_V7_FILE_NAME = "overload_aftermath_save_v7.json"
local LEGACY_FILE_NAME = "overload_best.json"
local CLOUD_SLOT = "overload_aftermath_save_v10.json"
local LEGACY_V9_CLOUD_SLOT = "overload_aftermath_save_v9.json"
local LEGACY_V8_CLOUD_SLOT = "overload_aftermath_save_v8.json"
local LEGACY_V7_CLOUD_SLOT = "overload_aftermath_save_v7.json"
-- 026:隐私决策(同意/拒绝)独立云槽。WASM 本地文件刷新即丢，
-- 同意与拒绝都必须跨刷新持久化：点完立即写本槽，启动探针先读本槽恢复决策。
-- 键名含政策版本：政策实质更新时换键名 → 自然重新询问。
local PRIVACY_SLOT = "overload_aftermath_privacy_v3.json"
local SCHEMA_VERSION = 10
local SYNC_VERSION = 3
local GAME_VERSION = ReleaseInfo.GAME_VERSION
local PRIVACY_POLICY_VERSION = 3
local CLOUD_UPLOAD_INTERVAL = 60
local CLOUD_READ_RETRY_INTERVAL = 15
local PRIVACY_RETRY_INTERVAL = 5
local PRIVACY_REQUEST_TIMEOUT = 15

local cloudAdapter = nil
local cloudEnabled = false
local cloudBusy = false
local cloudReadPending = false
local cloudReadFailed = false
local lastCloudReadAttemptAt = -1
local cloudMergeCallback = nil
local cloudForcePending = false
local cloudDirty = false
local cloudGeneration = 0
local pendingCloud = nil
local lastCloudUploadAt = -1
local cloudLog = {}
-- 050A: expose the last local/cloud outcome without changing the legacy
-- boolean return contract used by the game flow.  A local write succeeding
-- does not imply that a cloud upload has completed.
local lastSaveStatus = {
    localOK = false,
    cloudState = "disabled",
    cloudReason = "not_attempted",
    at = 0,
}
local cloudProbeState = "idle" -- idle | busy | done
local lastCloudProbeAttemptAt = -1
-- 026+：隐私决策(同意/拒绝)在 clientCloud 就绪前先暂存，每帧补写，
-- 避免"Start 时平台全局未注入导致隐私槽从未写入、刷新后必弹"。
local pendingPrivacyDecision = nil
local privacySaveBusy = false
local lastPrivacySaveAttemptAt = -1

local function nonnegativeInteger(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback or 0 end
    return math.max(0, math.floor(n))
end

local function bounded01(value, fallback)
    local n = tonumber(value)
    if not n then return fallback end
    return math.max(0, math.min(1, n))
end

local function nowValue(value)
    return nonnegativeInteger(value or os.time(), 0)
end

local function normalizeRun(run)
    if type(run) ~= "table" then return nil end
    local runId = run.run_id or run.runId or run.id
    if runId ~= nil then
        runId = tostring(runId)
        if runId == "" then runId = nil end
    end
    local normalized = {
        id = runId,
        runId = runId,
        layer = nonnegativeInteger(run.layer or run.round, 0),
        score = nonnegativeInteger(run.score, 0),
        time = math.max(0, tonumber(run.time or run.survival_time) or 0),
        endedAt = nonnegativeInteger(run.ended_at or run.endedAt, 0),
        bestCombo = nonnegativeInteger(run.best_combo or run.bestCombo, 0),
        huntKills = nonnegativeInteger(run.hunt_kills or run.huntKills, 0),
        restarts = nonnegativeInteger(run.restarts, 0),
        riskSuccesses = nonnegativeInteger(run.risk_successes or run.riskSuccesses, 0),
        lostRiskScore = nonnegativeInteger(run.lost_risk_score or run.lostRiskScore, 0),
        bestAntiHuntChain = nonnegativeInteger(
            run.best_anti_hunt_chain or run.bestAntiHuntChain, 0),
        adAssisted = run.ad_assisted == true or run.adAssisted == true,
        assistedRun = run.assisted_run == true or run.assistedRun == true,
        cleanRun = run.clean_run == true or run.cleanRun == true,
        challengeCompleted = run.challenge_completed == true or run.challengeCompleted == true,
        endless = run.endless == true,
        completed = run.completed == true,
        formalMain = run.formal_main == true or run.formalMain == true,
        completionReason = run.completion_reason or run.completionReason,
        milestoneId = run.milestone_id or run.milestoneId,
        originalRunId = run.original_run_id or run.originalRunId,
        recovered = run.recovered == true or run.recovered_run == true
            or run.recoveredRun == true,
        checkpointRecovery = run.checkpoint_recovery == true
            or run.checkpointRecovery == true,
        challengeRetry = run.challenge_retry == true or run.challengeRetry == true,
        challengeRetryCount = nonnegativeInteger(
            run.challenge_retry_count or run.challengeRetryCount, 0),
        reviveOfferPending = run.revive_offer_pending == true
            or run.reviveOfferPending == true,
        gameVersion = tostring(run.game_version or run.gameVersion or GAME_VERSION),
        debug = run.debug == true or run.debugRun == true,
        review = run.review == true,
        bot = run.bot == true,
        test = run.test == true,
    }
    -- A normal layer-checkpoint resume is a supported continuation path and
    -- remains eligible for the unified board.  Only a RunRecovery restore
    -- (or an explicit retry/assisted run) downgrades the record.
    if normalized.adAssisted or normalized.assistedRun or normalized.challengeRetry
        or normalized.challengeRetryCount > 0
        or (normalized.recovered and not normalized.checkpointRecovery) then
        normalized.cleanRun = false
    end
    return normalized
end

local function normalizeBestRun(run, fallbackLayer, fallbackScore, fallbackTime)
    run = type(run) == "table" and run or {}
    local runId = run.run_id or run.runId or run.id
    if runId ~= nil then runId = tostring(runId) end
    return {
        layer = nonnegativeInteger(run.layer or run.round, nonnegativeInteger(fallbackLayer, 0)),
        score = nonnegativeInteger(run.score, nonnegativeInteger(fallbackScore, 0)),
        time = math.max(0, tonumber(run.time or run.survival_time or fallbackTime) or 0),
        bestCombo = nonnegativeInteger(run.best_combo or run.bestCombo, 0),
        endedAt = nonnegativeInteger(run.ended_at or run.endedAt, 0),
        runId = runId,
    }
end

local function betterLocalRun(candidate, current)
    candidate = candidate or { layer = 0, score = 0, time = 0 }
    current = current or { layer = 0, score = 0, time = 0 }
    if candidate.layer ~= current.layer then return candidate.layer > current.layer end
    if candidate.score ~= current.score then return candidate.score > current.score end
    if candidate.time ~= current.time then return candidate.time > current.time end
    return (candidate.endedAt or 0) < (current.endedAt or math.huge)
end

local function selectLocalBest(best)
    best = type(best) == "table" and best or {}
    local selected = normalizeBestRun(best.bestCleanRun or best.bestRun)
    local assisted = normalizeBestRun(best.bestAssistedRun or best.assistedBestRun)
    if betterLocalRun(assisted, selected) then selected = assisted end
    for _, run in ipairs(best.recentRuns or {}) do
        if run.debug ~= true and run.review ~= true and run.bot ~= true and run.test ~= true then
            local candidate = normalizeBestRun(run)
            if betterLocalRun(candidate, selected) then selected = candidate end
        end
    end
    return normalizeBestRun(selected)
end

local function normalizeSettings(source)
    source = type(source) == "table" and source or {}
    local legacyVolume = bounded01(source.volume, 0.8)
    return {
        sound = source.sound ~= false,
        volume = legacyVolume,
        musicVolume = bounded01(source.music_volume or source.musicVolume,
            legacyVolume * 0.7),
        sfxVolume = bounded01(source.sfx_volume or source.sfxVolume, legacyVolume),
        vibration = source.vibration ~= false,
        reduceFx = source.reduce_flashing == true or source.reduceFx == true,
        reduceShake = source.reduce_vibration == true or source.reduceShake == true,
    }
end

local function linkAliases(best)
    best.bestRun = best.bestCleanRun
    best.assistedBestRun = best.bestAssistedRun
    best.localBestRun = selectLocalBest(best)
    best.round = best.localBestRun.layer
    best.score = best.localBestRun.score
    best.time = best.localBestRun.time
    best.bestCombo = math.max(nonnegativeInteger(best.bestCombo, 0),
        best.localBestRun.bestCombo or 0)
    return best
end

local function defaults()
    local best = {
        v = SCHEMA_VERSION,
        bestCleanRun = normalizeBestRun(nil, 0, 0, 0),
        bestAssistedRun = normalizeBestRun(nil, 0, 0, 0),
        round = 0,
        score = 0,
        bestCombo = 0,
        challengeClears = 0,
        recentRuns = {},
        pendingRunSettlement = nil,
        pendingLeaderboardSubmission = nil,
        challengeCheckpoint = nil,
        graduationArchives = GraduationArchive.normalizeSlots(nil),
        endlessCheckpoint = nil,
        updatedAt = 0,
        tutorialDone = false,
        lastExperiment = "B",
        syncVersion = SYNC_VERSION,
        gameVersion = GAME_VERSION,
        privacyPolicyVersion = PRIVACY_POLICY_VERSION,
        privacyDecision = nil,
        privacyConsentVersion = 0,
        rewardedReviveDay = "",
        rewardedReviveCount = 0,
        settingsUpdatedAt = 0,
        settings = normalizeSettings(nil),
    }
    return linkAliases(best)
end

local function runKey(run, fallback)
    local id = run and (run.runId or run.id)
    if id then return "id:" .. tostring(id) end
    return string.format("value:%s:%s:%s:%s:%s", tostring(run and run.layer),
        tostring(run and run.score), tostring(run and run.time),
        tostring(run and run.endedAt), tostring(fallback or ""))
end

local function normalizeRecent(runs)
    local result, positions = {}, {}
    for index, raw in ipairs(type(runs) == "table" and runs or {}) do
        local run = normalizeRun(raw)
        if run then
            local key = runKey(run, index)
            local previous = positions[key]
            if previous then
                if (run.endedAt or 0) >= (result[previous].endedAt or 0) then
                    result[previous] = run
                end
            else
                result[#result + 1] = run
                positions[key] = #result
            end
        end
    end
    table.sort(result, function(a, b)
        if (a.endedAt or 0) ~= (b.endedAt or 0) then
            return (a.endedAt or 0) < (b.endedAt or 0)
        end
        return runKey(a) < runKey(b)
    end)
    while #result > 10 do table.remove(result, 1) end
    return result
end

local function normalizePending(raw)
    if type(raw) ~= "table" then return nil end
    local runId = raw.run_id or raw.runId or raw.id
    local rankScore = tonumber(raw.rank_score or raw.rankScore)
    if runId == nil or not rankScore or rankScore < 0 or rankScore % 1 ~= 0 then return nil end
    return {
        runId = tostring(runId),
        originalRunId = raw.original_run_id or raw.originalRunId,
        rankScore = rankScore,
        layer = nonnegativeInteger(raw.layer, 0),
        score = nonnegativeInteger(raw.score, 0),
        bestCombo = nonnegativeInteger(raw.best_combo or raw.bestCombo, 0),
        endedAt = nonnegativeInteger(raw.ended_at or raw.endedAt, 0),
        completionReason = raw.completion_reason or raw.completionReason,
        cleanRun = raw.clean_run == true or raw.cleanRun == true,
        assistedRun = raw.assisted_run == true or raw.assistedRun == true,
        adAssisted = raw.ad_assisted == true or raw.adAssisted == true,
        checkpointRecovery = raw.checkpoint_recovery == true
            or raw.checkpointRecovery == true,
    }
end

function SaveSys.migrate(data)
    local best = defaults()
    if type(data) ~= "table" then return best end

    local legacyLayer = nonnegativeInteger(data.best_layer or data.round, 0)
    local legacyScore = nonnegativeInteger(data.best_score or data.score, 0)
    local legacyTime = math.max(0, tonumber(data.time) or 0)
    local clean = data.best_clean_run or data.bestCleanRun or data.bestRun
    local assisted = data.best_assisted_run or data.bestAssistedRun or data.assistedBestRun
    best.bestCleanRun = normalizeBestRun(clean, legacyLayer, legacyScore, legacyTime)
    best.bestAssistedRun = normalizeBestRun(assisted, 0, 0, 0)
    best.round = math.max(legacyLayer, best.bestCleanRun.layer)
    best.score = math.max(legacyScore, best.bestCleanRun.score)
    best.bestCombo = nonnegativeInteger(data.best_combo or data.bestCombo, 0)
    best.challengeClears = nonnegativeInteger(data.challenge_clears or data.challengeClears, 0)
    best.recentRuns = normalizeRecent(data.recent_runs or data.recentRuns)
    best.pendingRunSettlement = normalizeRun(
        data.pending_run_settlement or data.pendingRunSettlement)
    best.pendingLeaderboardSubmission = normalizePending(
        data.pending_leaderboard_submission or data.pendingLeaderboardSubmission)
    best.challengeCheckpoint = ChallengeCheckpoint.normalize(
        data.challenge_checkpoint or data.challengeCheckpoint)
    best.graduationArchives = GraduationArchive.normalizeSlots(
        data.graduation_archives or data.graduationArchives)
    best.endlessCheckpoint = EndlessCheckpoint.normalize(
        data.endless_checkpoint or data.endlessCheckpoint)
    best.updatedAt = nonnegativeInteger(data.updated_at or data.updatedAt, 0)
    best.tutorialDone = data.tutorial_done == true or data.tutorialDone == true
    if data.last_experiment == "A" or data.last_experiment == "B" then
        best.lastExperiment = data.last_experiment
    elseif data.lastExperiment == "A" or data.lastExperiment == "B" then
        best.lastExperiment = data.lastExperiment
    end
    best.settings = normalizeSettings(data.settings)
    best.settingsUpdatedAt = nonnegativeInteger(
        data.settings_updated_at or data.settingsUpdatedAt, 0)
    best.syncVersion = math.max(SYNC_VERSION,
        nonnegativeInteger(data.sync_version or data.syncVersion, 0))
    best.gameVersion = tostring(data.game_version or data.gameVersion or GAME_VERSION)
    best.privacyPolicyVersion = PRIVACY_POLICY_VERSION
    local privacyDecision = data.privacy_decision or data.privacyDecision
    if privacyDecision == "accepted" or privacyDecision == "declined" then
        best.privacyDecision = privacyDecision
    end
    best.privacyConsentVersion = nonnegativeInteger(
        data.privacy_consent_version or data.privacyConsentVersion, 0)
    best.rewardedReviveDay = type(data.rewarded_revive_day or data.rewardedReviveDay) == "string"
        and (data.rewarded_revive_day or data.rewardedReviveDay) or ""
    best.rewardedReviveCount = nonnegativeInteger(
        data.rewarded_revive_count or data.rewardedReviveCount, 0)
    return linkAliases(best)
end

function SaveSys.isBetterRun(candidate, current)
    candidate = candidate or { layer = 0, score = 0, time = 0 }
    current = current or { layer = 0, score = 0, time = 0 }
    if candidate.layer ~= current.layer then return candidate.layer > current.layer end
    if candidate.score ~= current.score then return candidate.score > current.score end
    if candidate.time ~= current.time then return candidate.time > current.time end
    return (candidate.endedAt or 0) < (current.endedAt or math.huge)
end

function SaveSys.getLocalBestRun(best)
    return selectLocalBest(best)
end

function SaveSys.hasRun(best, runId)
    if type(best) ~= "table" or runId == nil then return false end
    local expected = tostring(runId)
    for _, existing in ipairs(best.recentRuns or {}) do
        if tostring(existing.runId or existing.id or "") == expected then return true end
    end
    return false
end

function SaveSys.recordRun(best, rawRun)
    if type(best) ~= "table" then return false end
    local run = normalizeRun(rawRun)
    if not run then return false end
    -- 023C: Debug/Review/Bot/QA 局一律不进入正式记录（成绩隔离）。
    if run.debug == true or run.review == true or run.bot == true or run.test == true then
        return false
    end
    best.recentRuns = best.recentRuns or {}
    if run.runId and SaveSys.hasRun(best, run.runId) then return false end
    best.recentRuns[#best.recentRuns + 1] = run
    best.recentRuns = normalizeRecent(best.recentRuns)
    best.bestCombo = math.max(best.bestCombo or 0, run.bestCombo or 0)
    if run.challengeCompleted then
        best.challengeClears = (best.challengeClears or 0) + 1
    end

    if not run.cleanRun then
        if SaveSys.isBetterRun(run, best.bestAssistedRun or best.assistedBestRun) then
            best.bestAssistedRun = normalizeBestRun(run)
        end
        linkAliases(best)
        return true
    end

    if SaveSys.isBetterRun(run, best.bestCleanRun or best.bestRun) then
        best.bestCleanRun = normalizeBestRun(run)
    end
    best.round = math.max(best.round or 0, run.layer)
    best.score = math.max(best.score or 0, run.score)
    linkAliases(best)
    return true
end

function SaveSys.queueLeaderboardSubmission(best, raw)
    if type(best) ~= "table" then return false end
    local candidate = normalizePending(raw)
    if not candidate then return false end
    local current = normalizePending(best.pendingLeaderboardSubmission)
    if current and current.rankScore >= candidate.rankScore then return false end
    best.pendingLeaderboardSubmission = candidate
    return true
end

function SaveSys.clearPendingLeaderboardSubmission(best, runId)
    if type(best) ~= "table" or type(best.pendingLeaderboardSubmission) ~= "table" then
        return false
    end
    if runId and tostring(best.pendingLeaderboardSubmission.runId) ~= tostring(runId) then
        return false
    end
    best.pendingLeaderboardSubmission = nil
    return true
end

function SaveSys.stageRunSettlement(best, rawRun)
    if type(best) ~= "table" then return false end
    local run = normalizeRun(rawRun)
    if not run or run.runId == nil or run.completed ~= true then return false end
    if run.formalMain ~= true or run.debug or run.review or run.bot or run.test then
        return false
    end
    best.pendingRunSettlement = run
    return true
end

function SaveSys.clearPendingRunSettlement(best, runId)
    if type(best) ~= "table" or type(best.pendingRunSettlement) ~= "table" then
        return false
    end
    if runId and tostring(best.pendingRunSettlement.runId) ~= tostring(runId) then
        return false
    end
    best.pendingRunSettlement = nil
    return true
end

function SaveSys.consumePendingRunSettlement(best)
    if type(best) ~= "table" or type(best.pendingRunSettlement) ~= "table" then
        return false, nil
    end
    local run = normalizeRun(best.pendingRunSettlement)
    if not run then return false, nil end
    -- A death-page rewarded-revive offer is an unresolved user choice, not a
    -- completed settlement.  Keep it durable across refresh and let the
    -- active run flow consume it only after the player explicitly chooses a
    -- retry, a revive, or an end-of-run action.
    if run.reviveOfferPending == true then
        return false, run
    end
    local recorded = SaveSys.recordRun(best, run)
    -- A retry after the first durable phase may see the run already in
    -- recentRuns.  That is an idempotent success, not a reason to discard the
    -- pending marker.  Only clear it after recordRun succeeded or proved that
    -- the same run was already recorded; malformed/failed data remains for a
    -- later recovery attempt.
    if recorded or SaveSys.hasRun(best, run.runId) then
        best.pendingRunSettlement = nil
        return true, run
    end
    return false, run
end

local function mergeBestRun(localRun, cloudRun)
    if SaveSys.isBetterRun(cloudRun, localRun) then return normalizeBestRun(cloudRun) end
    return normalizeBestRun(localRun)
end

function SaveSys.mergeCloud(localData, cloudData)
    local localBest = SaveSys.migrate(localData)
    if type(cloudData) ~= "table" then return localBest end
    local cloudBest = SaveSys.migrate(cloudData)
    local localUpdatedAt = localBest.updatedAt
    local cloudUpdatedAt = cloudBest.updatedAt
    local localPendingRun = normalizeRun(localBest.pendingRunSettlement)
    local cloudPendingRun = normalizeRun(cloudBest.pendingRunSettlement)
    if localPendingRun and cloudPendingRun
        and tostring(localPendingRun.runId) ~= tostring(cloudPendingRun.runId) then
        SaveSys.recordRun(localBest, cloudPendingRun)
        localBest.pendingRunSettlement = localPendingRun
    elseif cloudPendingRun and not localPendingRun then
        localBest.pendingRunSettlement = cloudPendingRun
    end
    localBest.bestCleanRun = mergeBestRun(localBest.bestCleanRun, cloudBest.bestCleanRun)
    localBest.bestAssistedRun = mergeBestRun(
        localBest.bestAssistedRun, cloudBest.bestAssistedRun)
    localBest.round = math.max(localBest.round, cloudBest.round)
    localBest.score = math.max(localBest.score, cloudBest.score)
    localBest.bestCombo = math.max(localBest.bestCombo, cloudBest.bestCombo)
    localBest.challengeClears = math.max(localBest.challengeClears, cloudBest.challengeClears)
    local combined = {}
    for _, run in ipairs(cloudBest.recentRuns) do combined[#combined + 1] = run end
    for _, run in ipairs(localBest.recentRuns) do combined[#combined + 1] = run end
    localBest.recentRuns = normalizeRecent(combined)
    localBest.tutorialDone = localBest.tutorialDone or cloudBest.tutorialDone
    if cloudUpdatedAt > localUpdatedAt then
        localBest.lastExperiment = cloudBest.lastExperiment
    end
    if cloudBest.settingsUpdatedAt > localBest.settingsUpdatedAt then
        localBest.settings = normalizeSettings(cloudBest.settings)
        localBest.settingsUpdatedAt = cloudBest.settingsUpdatedAt
    end
    local localPending = normalizePending(localBest.pendingLeaderboardSubmission)
    local cloudPending = normalizePending(cloudBest.pendingLeaderboardSubmission)
    if cloudPending and (not localPending or cloudPending.rankScore > localPending.rankScore) then
        localBest.pendingLeaderboardSubmission = cloudPending
    end
    local localCheckpoint = ChallengeCheckpoint.normalize(localBest.challengeCheckpoint)
    local cloudCheckpoint = ChallengeCheckpoint.normalize(cloudBest.challengeCheckpoint)
    if cloudCheckpoint and (not localCheckpoint
        or cloudCheckpoint.createdAt > localCheckpoint.createdAt
        or (cloudCheckpoint.runId == localCheckpoint.runId
            and cloudCheckpoint.createdAt == localCheckpoint.createdAt
            and cloudCheckpoint.challengeRetryCount > localCheckpoint.challengeRetryCount)) then
        localBest.challengeCheckpoint = cloudCheckpoint
    end
    local localArchives = GraduationArchive.normalizeSlots(localBest.graduationArchives)
    local cloudArchives = GraduationArchive.normalizeSlots(cloudBest.graduationArchives)
    for index = 1, GraduationArchive.SLOT_COUNT do
        local localArchive, cloudArchive = localArchives[index], cloudArchives[index]
        if cloudArchive and (not localArchive
            or cloudArchive.createdAt > localArchive.createdAt
            or (cloudArchive.createdAt == localArchive.createdAt
                and cloudArchive.archiveId > localArchive.archiveId)) then
            localArchives[index] = cloudArchive
        end
    end
    localBest.graduationArchives = localArchives
    local localEndless = EndlessCheckpoint.normalize(localBest.endlessCheckpoint)
    local cloudEndless = EndlessCheckpoint.normalize(cloudBest.endlessCheckpoint)
    if cloudEndless and (not localEndless
        or cloudEndless.createdAt > localEndless.createdAt
        or (cloudEndless.createdAt == localEndless.createdAt
            and cloudEndless.nextLayer > localEndless.nextLayer)) then
        localBest.endlessCheckpoint = cloudEndless
    end
    localBest.updatedAt = math.max(localBest.updatedAt, cloudBest.updatedAt)
    localBest.syncVersion = math.max(localBest.syncVersion, cloudBest.syncVersion, SYNC_VERSION)
    localBest.gameVersion = GAME_VERSION
    -- privacyDecision: 本地决策保留；本地未定时可继承云端"同意"(WASM 刷新后恢复)。
    -- 拒绝状态绝不入云(serializeCloud 剥离),因此云端只可能出现 accepted。
    if localBest.privacyDecision ~= "accepted"
        and cloudBest.privacyDecision == "accepted"
        and tonumber(cloudBest.privacyConsentVersion or 0) == PRIVACY_POLICY_VERSION then
        localBest.privacyDecision = "accepted"
        localBest.privacyConsentVersion = PRIVACY_POLICY_VERSION
        localBest.privacyPolicyVersion = PRIVACY_POLICY_VERSION
    end
    return linkAliases(localBest)
end

function SaveSys.touchSettings(best, timestamp)
    best.settingsUpdatedAt = math.max(best.settingsUpdatedAt or 0, nowValue(timestamp))
end

function SaveSys.getChallengeCheckpoint(best)
    return type(best) == "table"
        and ChallengeCheckpoint.normalize(best.challengeCheckpoint) or nil
end

function SaveSys.setChallengeCheckpoint(best, checkpoint)
    if type(best) ~= "table" then return false end
    local normalized = ChallengeCheckpoint.normalize(checkpoint)
    if not normalized then return false end
    best.challengeCheckpoint = normalized
    return true
end

function SaveSys.clearChallengeCheckpoint(best, runId)
    if type(best) ~= "table" or best.challengeCheckpoint == nil then return false end
    local cp = ChallengeCheckpoint.normalize(best.challengeCheckpoint)
    if runId and cp and tostring(cp.runId) ~= tostring(runId) then return false end
    best.challengeCheckpoint = nil
    return true
end

function SaveSys.getEndlessCheckpoint(best)
    return type(best) == "table"
        and EndlessCheckpoint.normalize(best.endlessCheckpoint) or nil
end

function SaveSys.setEndlessCheckpoint(best, checkpoint)
    if type(best) ~= "table" then return false end
    local normalized = EndlessCheckpoint.normalize(checkpoint)
    if not normalized then return false end
    best.endlessCheckpoint = normalized
    best.updatedAt = nowValue()
    return true
end

function SaveSys.clearEndlessCheckpoint(best, runId)
    if type(best) ~= "table" or best.endlessCheckpoint == nil then return false end
    local cp = EndlessCheckpoint.normalize(best.endlessCheckpoint)
    if runId and cp and tostring(cp.runId) ~= tostring(runId) then return false end
    best.endlessCheckpoint = nil
    best.updatedAt = nowValue()
    return true
end

function SaveSys.getGraduationArchives(best)
    return GraduationArchive.normalizeSlots(type(best) == "table"
        and best.graduationArchives or nil)
end

function SaveSys.getGraduationArchive(best, slot)
    local index = math.floor(tonumber(slot) or 0)
    if index < 1 or index > GraduationArchive.SLOT_COUNT then return nil end
    return SaveSys.getGraduationArchives(best)[index]
end

function SaveSys.setGraduationArchive(best, slot, archive)
    if type(best) ~= "table" then return false end
    local index = math.floor(tonumber(slot) or 0)
    if index < 1 or index > GraduationArchive.SLOT_COUNT then return false end
    local normalized = GraduationArchive.normalize(archive)
    if not normalized then return false end
    local slots = SaveSys.getGraduationArchives(best)
    -- 覆盖是整个不可编辑快照替换，不做字段级合并。
    slots[index] = normalized
    best.graduationArchives = slots
    best.updatedAt = nowValue()
    return true
end

function SaveSys.hasPrivacyConsent(best)
    return type(best) == "table" and best.privacyDecision == "accepted"
        and tonumber(best.privacyConsentVersion) == PRIVACY_POLICY_VERSION
end

function SaveSys.needsPrivacyChoice(best)
    if type(best) ~= "table" then return true end
    -- 正式入口只有“了解并同意”一条继续路径。旧版本留下的 declined
    -- 仍可迁移读取，但必须重新展示当前隐私说明，不能永久锁死在线能力。
    return best.privacyDecision ~= "accepted"
        or tonumber(best.privacyConsentVersion) ~= PRIVACY_POLICY_VERSION
end

function SaveSys.setPrivacyDecision(best, decision)
    if decision ~= "accepted" and decision ~= "declined" then return false end
    best.privacyDecision = decision
    best.privacyConsentVersion = PRIVACY_POLICY_VERSION
    best.privacyPolicyVersion = PRIVACY_POLICY_VERSION
    best.updatedAt = nowValue()
    return true
end

local function serializeBestRun(run)
    run = normalizeBestRun(run)
    return {
        layer = run.layer, score = run.score, time = run.time,
        best_combo = run.bestCombo,
        ended_at = run.endedAt, run_id = run.runId,
    }
end

local function serializeRecentRun(raw)
    local run = normalizeRun(raw) or {}
    return {
        run_id = run.runId,
        layer = run.layer,
        score = run.score,
        time = run.time,
        ended_at = run.endedAt,
        best_combo = run.bestCombo,
        hunt_kills = run.huntKills,
        restarts = run.restarts,
        risk_successes = run.riskSuccesses,
        lost_risk_score = run.lostRiskScore,
        best_anti_hunt_chain = run.bestAntiHuntChain,
        ad_assisted = run.adAssisted,
        assisted_run = run.assistedRun,
        clean_run = run.cleanRun,
        challenge_completed = run.challengeCompleted,
        endless = run.endless,
        completed = run.completed,
        formal_main = run.formalMain,
        completion_reason = run.completionReason,
        milestone_id = run.milestoneId,
        original_run_id = run.originalRunId,
        recovered = run.recovered,
        checkpoint_recovery = run.checkpointRecovery,
        challenge_retry = run.challengeRetry,
        challenge_retry_count = run.challengeRetryCount,
        revive_offer_pending = run.reviveOfferPending,
        game_version = run.gameVersion,
    }
end

local function serializePending(raw)
    local pending = normalizePending(raw)
    if not pending then return nil end
    return {
        run_id = pending.runId,
        original_run_id = pending.originalRunId,
        rank_score = pending.rankScore,
        layer = pending.layer,
        score = pending.score,
        best_combo = pending.bestCombo,
        ended_at = pending.endedAt,
        completion_reason = pending.completionReason,
        clean_run = true,
    }
end

local function serializePendingRun(raw)
    local run = normalizeRun(raw)
    if not run or run.runId == nil or run.completed ~= true then return nil end
    return serializeRecentRun(run)
end

function SaveSys.serialize(best)
    best = SaveSys.migrate(best)
    local recent = {}
    for _, run in ipairs(best.recentRuns) do recent[#recent + 1] = serializeRecentRun(run) end
    local archives = {}
    for index = 1, GraduationArchive.SLOT_COUNT do
        archives["slot" .. tostring(index)] = GraduationArchive.serialize(
            best.graduationArchives[index])
    end
    return {
        v = SCHEMA_VERSION,
        schema_version = SCHEMA_VERSION,
        best_layer = best.round,
        best_score = best.score,
        best_combo = best.bestCombo,
        best_clean_run = serializeBestRun(best.bestCleanRun),
        best_assisted_run = serializeBestRun(best.bestAssistedRun),
        challenge_clears = best.challengeClears,
        recent_runs = recent,
        pending_run_settlement = serializePendingRun(best.pendingRunSettlement),
        pending_leaderboard_submission = serializePending(best.pendingLeaderboardSubmission),
        challenge_checkpoint = ChallengeCheckpoint.serialize(best.challengeCheckpoint),
        graduation_archives = archives,
        endless_checkpoint = EndlessCheckpoint.serialize(best.endlessCheckpoint),
        updated_at = best.updatedAt,
        tutorial_done = best.tutorialDone,
        last_experiment = best.lastExperiment,
        sync_version = best.syncVersion,
        game_version = GAME_VERSION,
        privacy_policy_version = best.privacyPolicyVersion,
        privacy_decision = best.privacyDecision,
        privacy_consent_version = best.privacyConsentVersion,
        rewarded_revive_day = best.rewardedReviveDay,
        rewarded_revive_count = best.rewardedReviveCount,
        settings_updated_at = best.settingsUpdatedAt,
        settings = {
            sound = best.settings.sound,
            volume = best.settings.volume,
            music_volume = best.settings.musicVolume,
            sfx_volume = best.settings.sfxVolume,
            vibration = best.settings.vibration,
            reduce_vibration = best.settings.reduceShake,
            reduce_flashing = best.settings.reduceFx,
        },
    }
end

function SaveSys.serializeCloud(best)
    local payload = SaveSys.serialize(best)
    -- 024C: 隐私"同意"状态随云存档同步(同意本身即授权;WASM 本地无持久存储,
    -- 刷新后从云恢复同意状态以避免重复询问)。"拒绝"状态绝不初始化云(零云调用)。
    -- 隐私策略版本变化仍会触发重新询问(needsPrivacyChoice 检查 consent version)。
    if best.privacyDecision ~= "accepted" then
        payload.privacy_decision = nil
        payload.privacy_consent_version = nil
    end
    payload.rewarded_revive_day = nil
    payload.rewarded_revive_count = nil
    return payload
end

function SaveSys.decode(raw)
    if type(raw) ~= "string" or raw == "" then return false, "empty" end
    local ok, data = pcall(cjson.decode, raw)
    if not ok or type(data) ~= "table" then return false, "invalid_json" end
    return true, SaveSys.migrate(data)
end

local BACKUP_PREFIX = "overload_aftermath_save_v10.backup."
local BACKUP_KEEP = 3           -- 最近合法备份最多保留 3 份
local MAX_FILE_ATTEMPTS = 20

-- readRaw 前向声明：writeAtomic 在函数体内引用，须先声明再赋值。
local readRaw

-- 尽力删除文件：WASM 内存文件系统/沙箱不支持 os.remove 时静默忽略。
local function tryRemove(name)
    if name == nil then return false end
    if fileSystem ~= nil and type(fileSystem.Delete) == "function" then
        local ok = pcall(function() return fileSystem:Delete(name) end)
        if ok then return true end
    end
    if type(os.remove) == "function" then
        local ok = pcall(os.remove, name)
        if ok then return true end
    end
    if fileSystem ~= nil and type(fileSystem.DeleteFile) == "function" then
        local ok = pcall(function() fileSystem:DeleteFile(name) end)
        if ok then return true end
    end
    return false
end

-- 单次尽力写：写临时文件 → 读回校验 → 尝试原子替换。
-- 不支持重命名/读回的受限环境退化为"截断直写"（跨刷新持久性由平台决定，不在这里造假）。
local function writeAtomic(name, raw)
    local tempName = name .. ".tmp"
    local written = false
    local ok = pcall(function()
        local file = File(tempName, FILE_WRITE)
        if not file:IsOpen() then error("open failed") end
        file:WriteString(raw)
        file:Close()
        written = true
    end)
    if not ok or not written then return false end
    -- 读回校验仅在受支持的文件环境执行；缺失 read 能力时仍保证写入成功，
    -- 由引擎平台决定跨刷新持久性（不在这里用内存数据冒充）。
    local canReadBack = fileSystem ~= nil and type(fileSystem.FileExists) == "function"
        and File ~= nil and type(File) == "function"
    if canReadBack then
        local readBack, verifyRaw = readRaw(tempName)
        if readBack and verifyRaw ~= raw then return false end
    end
    -- 原子替换：优先走引擎 FileSystem:Rename（沙箱中 os.rename 被移除）；
    -- 备选 os.rename（受限测试环境）；都不支持时退化为截断直写。
    if fileSystem ~= nil and type(fileSystem.Rename) == "function" then
        local renameOK, result = pcall(function() return fileSystem:Rename(tempName, name) end)
        if renameOK and result then
            if name ~= FILE_NAME and name ~= LEGACY_FILE_NAME then tryRemove(tempName) end
            return true
        end
    elseif type(os.rename) == "function" then
        local renameOK, result = pcall(os.rename, tempName, name)
        if renameOK and result then
            if name ~= FILE_NAME and name ~= LEGACY_FILE_NAME then tryRemove(tempName) end
            return true
        end
    end
    -- 无原子替换：直接截断覆盖目标。
    local direct = false
    local ok2 = pcall(function()
        local file = File(name, FILE_WRITE)
        if not file:IsOpen() then error("open failed") end
        file:WriteString(raw)
        file:Close()
        direct = true
    end)
    tryRemove(tempName)
    return ok2 and direct
end

local function writeRaw(name, raw)
    return writeAtomic(name, raw)
end

readRaw = function(name)
    local raw = nil
    local ok = pcall(function()
        if not fileSystem:FileExists(name) then return end
        local file = File(name, FILE_READ)
        if not file:IsOpen() then return end
        raw = file:ReadString()
        file:Close()
    end)
    return ok and raw ~= nil, raw
end

function SaveSys.corruptBackupName(timestamp)
    return string.format("overload_aftermath_save_v10.corrupt.%d.json", nowValue(timestamp))
end

local function backupCorrupt(raw)
    local backupName = SaveSys.corruptBackupName()
    if writeRaw(backupName, raw or "") then
        print("[SaveSys] corrupt save backed up: " .. backupName)
        return backupName
    end
    print("[SaveSys] corrupt save backup failed (continuing with defaults)")
    return nil
end

local function backupRecentValid(name, raw)
    local timestamp = nowValue()
    local backupName = BACKUP_PREFIX .. timestamp .. "." .. tostring(#tostring(raw)) .. ".json"
    if not writeAtomic(backupName, raw) then return nil end
    -- 轮换：只保留最近 BACKUP_KEEP 份合法备份。
    if fileSystem ~= nil and type(fileSystem.ScanDir) == "function" then
        local ok, files = pcall(fileSystem.ScanDir, fileSystem, ".", "*.json", SCAN_FILES, false)
        if ok and type(files) == "table" then
            local backups = {}
            for _, entry in ipairs(files) do
                local nameEntry = tostring(entry or "")
                if string.find(nameEntry, BACKUP_PREFIX, 1, true) == 1 then
                    backups[#backups + 1] = nameEntry
                end
            end
            table.sort(backups)
            for i = 1, math.max(0, #backups - BACKUP_KEEP) do tryRemove(backups[i]) end
        end
    end
    return backupName
end

-- 024C：隐私同意后的启动读取。本地缓存先行渲染，随后 initCloud 异步合并云端。
-- 返回 (localBest, cloudInitStarted)
function SaveSys.loadWithCloudStart(config)
    local best = SaveSys.load()
    local ok, reason = false, "disabled"
    if config and config.PLATFORM and config.PLATFORM.cloudSave == true
        and SaveSys.hasPrivacyConsent(best) then
        -- cloud adapter 由 main 在 initializePlatformAfterConsent 设置后调用 initCloud
    end
    return best, ok, reason
end

function SaveSys.load()
    local exists, raw = readRaw(FILE_NAME)
    if exists then
        local ok, best = SaveSys.decode(raw)
        if ok then
            -- 最近一个合法备份：每次成功加载都保留上一版，供跨刷新回滚审计。
            backupRecentValid(FILE_NAME, raw)
            return best
        end
        backupCorrupt(raw)
        return defaults()
    end
    local legacyExists, legacyRaw = readRaw(LEGACY_V9_FILE_NAME)
    if legacyExists then
        local ok, best = SaveSys.decode(legacyRaw)
        if ok then
            SaveSys.saveLocalOnly(best)
            return best
        end
        backupCorrupt(legacyRaw)
    end
    legacyExists, legacyRaw = readRaw(LEGACY_V8_FILE_NAME)
    if legacyExists then
        local ok, best = SaveSys.decode(legacyRaw)
        if ok then
            SaveSys.saveLocalOnly(best)
            return best
        end
        backupCorrupt(legacyRaw)
    end
    legacyExists, legacyRaw = readRaw(LEGACY_V7_FILE_NAME)
    if legacyExists then
        local ok, best = SaveSys.decode(legacyRaw)
        if ok then
            SaveSys.saveLocalOnly(best)
            return best
        end
        backupCorrupt(legacyRaw)
    end
    legacyExists, legacyRaw = readRaw(LEGACY_FILE_NAME)
    if legacyExists then
        local ok, best = SaveSys.decode(legacyRaw)
        if ok then
            SaveSys.saveLocalOnly(best)
            return best
        end
        backupCorrupt(legacyRaw)
    end
    return defaults()
end

-- 026：隐私决策独立持久化。WASM 本地文件刷新即丢，同意/拒绝都必须
-- 写入独立隐私云槽（零初始化，只是写一条决策记录），刷新后由探针恢复。
-- 平台通道暂不可用时先暂存（pendingPrivacyDecision），由 retryPendingPrivacy
-- 每帧补写，直到确认写进云槽；本地决策始终即时生效。
function SaveSys.persistPrivacyDecision(best, decision, adapter)
    if decision ~= "accepted" and decision ~= "declined" then return false end
    pendingPrivacyDecision = {
        decision = decision,
        version = PRIVACY_POLICY_VERSION,
    }
    if type(adapter) ~= "table" or type(adapter.save) ~= "function" then
        print("[SaveSys] privacy decision staged (cloud adapter unavailable, will retry)")
        return true
    end
    if privacySaveBusy then return true end
    privacySaveBusy = true
    lastPrivacySaveAttemptAt = nowValue()
    local ok, invoked = pcall(function()
        return adapter:save(PRIVACY_SLOT, {
            privacy_decision = decision,
            privacy_consent_version = PRIVACY_POLICY_VERSION,
            privacy_policy_version = PRIVACY_POLICY_VERSION,
        }, {
            ok = function()
                privacySaveBusy = false
                if pendingPrivacyDecision
                    and pendingPrivacyDecision.decision == decision
                    and pendingPrivacyDecision.version == PRIVACY_POLICY_VERSION then
                    pendingPrivacyDecision = nil
                end
                print("[SaveSys] privacy decision persisted to cloud slot")
            end,
            error = function(code, reason)
                privacySaveBusy = false
                print("[SaveSys] privacy persist error (staged for retry): "
                    .. tostring(code) .. " " .. tostring(reason))
            end,
            timeout = function()
                privacySaveBusy = false
                print("[SaveSys] privacy persist timeout (staged for retry)")
            end,
        })
    end)
    if not ok or invoked == false then
        privacySaveBusy = false
        print("[SaveSys] privacy persist invoke failed (staged for retry)")
    end
    return true
end

function SaveSys.hasPendingPrivacyDecision()
    return pendingPrivacyDecision ~= nil
end

-- 026+：补写暂存的隐私决策（clientCloud 延迟就绪时不丢失）。
-- adapterOverride 用于接收本帧刚探测到的最小 Get/Set 通道；不初始化主云能力。
-- 返回 (true, "none"|"saving") 表示无需补写或已发起；(false, reason) 表示通道仍未就绪。
function SaveSys.retryPendingPrivacy(adapterOverride)
    if pendingPrivacyDecision == nil then return true, "none" end
    local now = nowValue()
    if privacySaveBusy then
        if lastPrivacySaveAttemptAt >= 0
            and now - lastPrivacySaveAttemptAt >= PRIVACY_REQUEST_TIMEOUT then
            privacySaveBusy = false
            print("[SaveSys] privacy save watchdog released stalled request")
        else
            return true, "saving"
        end
    end
    if lastPrivacySaveAttemptAt >= 0
        and now - lastPrivacySaveAttemptAt < PRIVACY_RETRY_INTERVAL then
        return false, "retry_wait"
    end
    local adapter = adapterOverride or cloudAdapter
    if type(adapter) ~= "table" or type(adapter.save) ~= "function" then
        return false, "cloud_adapter_unavailable"
    end
    local decision = pendingPrivacyDecision.decision
    local version = pendingPrivacyDecision.version
    privacySaveBusy = true
    lastPrivacySaveAttemptAt = now
    local ok, invoked = pcall(function()
        return adapter:save(PRIVACY_SLOT, {
            privacy_decision = decision,
            privacy_consent_version = version,
            privacy_policy_version = version,
        }, {
            ok = function()
                privacySaveBusy = false
                if pendingPrivacyDecision
                    and pendingPrivacyDecision.decision == decision
                    and pendingPrivacyDecision.version == version then
                    pendingPrivacyDecision = nil
                end
                print("[SaveSys] staged privacy decision persisted to cloud slot")
            end,
            error = function(code, reason)
                privacySaveBusy = false
                print("[SaveSys] staged privacy persist error: "
                    .. tostring(code) .. " " .. tostring(reason))
            end,
            timeout = function()
                privacySaveBusy = false
                print("[SaveSys] staged privacy persist timeout")
            end,
        })
    end)
    if not ok or invoked == false then
        privacySaveBusy = false
        return false, "invoke_failed"
    end
    return true, "saving"
end

-- v10主云槽不存在时只读回退v9、v8、v7槽；成功合并后由正常saveCloud迁入v10。
-- 任一传输失败都保留失败语义，绝不把“读不到旧槽”当成空云后覆盖。
local function loadCloudRecords(adapter, events)
    local function invoke(slot, allowLegacyFallback)
        local ok, invoked = pcall(function()
            return adapter:load(slot, {
                ok = function(payload)
                    local empty = payload == nil
                        or (type(payload) == "table" and next(payload) == nil)
                    if allowLegacyFallback == "v9" and empty then
                        invoke(LEGACY_V9_CLOUD_SLOT, "v8")
                    elseif allowLegacyFallback == "v8" and empty then
                        invoke(LEGACY_V8_CLOUD_SLOT, "v7")
                    elseif allowLegacyFallback == "v7" and empty then
                        invoke(LEGACY_V7_CLOUD_SLOT, false)
                    elseif events.ok then
                        events.ok(type(payload) == "table" and payload or nil,
                            slot ~= CLOUD_SLOT)
                    end
                end,
                error = function(code, reason)
                    if events.error then events.error(code, reason) end
                end,
                timeout = function()
                    if events.timeout then events.timeout() end
                end,
            })
        end)
        if not ok or invoked == false then
            if events.invokeFailed then events.invokeFailed(slot) end
            return false
        end
        return true
    end
    return invoke(CLOUD_SLOT, "v9")
end

-- 启动只读探针，分两步：
--   1) 读独立隐私槽恢复决策（accepted/declined 都恢复，刷新不再重复询问）；
--   2) 仅当恢复为 accepted 时才读大档合并云纪录。
-- 探针状态由本模块管理：成功完成后停止；调用失败或两级读取都失败时按冷却重试。
-- 本地已有明确决策时不发起探针。
function SaveSys.probeCloudConsent(best, adapter, config, onMerged)
    if type(best) ~= "table" then return false end
    if not SaveSys.needsPrivacyChoice(best) then return false end
    if not config or not config.PLATFORM or config.PLATFORM.cloudSave ~= true then
        return false
    end
    if type(adapter) ~= "table" or type(adapter.load) ~= "function" then return false end
    local now = nowValue()
    if cloudProbeState == "busy" then
        if lastCloudProbeAttemptAt >= 0
            and now - lastCloudProbeAttemptAt >= PRIVACY_REQUEST_TIMEOUT then
            cloudProbeState = "idle"
            print("[SaveSys] privacy cloud probe watchdog released stalled request")
        else
            return false
        end
    end
    if cloudProbeState ~= "idle" then return false end
    if lastCloudProbeAttemptAt >= 0
        and now - lastCloudProbeAttemptAt < PRIVACY_RETRY_INTERVAL then
        return false
    end
    cloudProbeState = "busy"
    lastCloudProbeAttemptAt = now
    local decisionAtStart = best.privacyDecision

    local function userChangedDecision(expected)
        return best.privacyDecision ~= nil and best.privacyDecision ~= expected
    end

    -- 成功取得明确结果（包括“云端无旧决策”）后完成本轮启动探测。
    local function finish(merged)
        cloudProbeState = "done"
        if type(merged) == "table" and merged ~= best then
            for key in pairs(best) do best[key] = nil end
            for key, value in pairs(merged) do best[key] = value end
            SaveSys.saveLocalOnly(best)
        end
        if onMerged ~= nil then onMerged(best) end
    end

    -- 传输失败不冒充“云端无数据”，释放状态并等待冷却后重试。
    local function retryLater(reason)
        cloudProbeState = "idle"
        print("[SaveSys] privacy cloud probe retry pending: " .. tostring(reason))
    end

    local function readRecords(restoredDecision)
        return loadCloudRecords(adapter, {
                ok = function(cloudPayload)
                    if userChangedDecision(restoredDecision) then
                        cloudProbeState = "done"
                        return
                    end
                    local payload = type(cloudPayload) == "table" and cloudPayload or nil
                    finish(SaveSys.mergeCloud(best, payload))
                end,
                error = function(code, reason)
                    if userChangedDecision(restoredDecision) then
                        cloudProbeState = "done"
                        return
                    end
                    retryLater(tostring(code) .. " " .. tostring(reason))
                end,
                timeout = function()
                    if userChangedDecision(restoredDecision) then
                        cloudProbeState = "done"
                        return
                    end
                    retryLater("records_timeout")
                end,
                invokeFailed = function() retryLater("records_invoke_failed") end,
            })
    end

    local ok, invoked = pcall(function()
        return adapter:load(PRIVACY_SLOT, {
            ok = function(privacyPayload)
                if userChangedDecision(decisionAtStart) then
                    cloudProbeState = "done"
                    return
                end
                local p = type(privacyPayload) == "table" and privacyPayload or nil
                local decision = p and (p.privacy_decision or p.decision) or nil
                local restored = nil
                if (decision == "accepted" or decision == "declined")
                    and tonumber(p.privacy_consent_version or p.consent_version or 0)
                        == PRIVACY_POLICY_VERSION then
                    SaveSys.setPrivacyDecision(best, decision)
                    SaveSys.saveLocalOnly(best)
                    restored = decision
                end
                if SaveSys.hasPrivacyConsent(best) then
                    readRecords(restored)
                else
                    finish(best)
                end
            end,
            error = function()
                if userChangedDecision(decisionAtStart) then
                    cloudProbeState = "done"
                    return
                end
                -- 兼容旧档：隐私专槽不存在或不可读时，再从主云档恢复 accepted。
                readRecords(nil)
            end,
            timeout = function()
                if userChangedDecision(decisionAtStart) then
                    cloudProbeState = "done"
                    return
                end
                readRecords(nil)
            end,
        })
    end)
    if not ok or invoked == false then
        retryLater("privacy_invoke_failed")
        return false
    end
    return true
end

local function saveLocal(best)
    if type(best) ~= "table" then return false end
    best.updatedAt = nowValue()
    local ok, encoded = pcall(cjson.encode, SaveSys.serialize(best))
    if not ok then
        print("[SaveSys] encode failed (ignored)")
        return false
    end
    local wrote = writeRaw(FILE_NAME, encoded)
    if not wrote then print("[SaveSys] save failed (ignored)") end
    return wrote
end

function SaveSys.saveLocalOnly(best)
    return saveLocal(best)
end

local function logCloudOnce(key, message)
    if cloudLog[key] then return end
    cloudLog[key] = true
    print(message)
end

local function replaceTable(target, source)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
end

function SaveSys.setCloudAdapter(adapter)
    cloudAdapter = adapter
end

function SaveSys.markCloudDirty(best)
    cloudGeneration = cloudGeneration + 1
    pendingCloud = SaveSys.serializeCloud(best)
    cloudDirty = true
end

function SaveSys.saveCloud(best, timestamp, force)
    if not cloudEnabled then return false, "feature_disabled" end
    if type(cloudAdapter) ~= "table" or type(cloudAdapter.save) ~= "function" then
        logCloudOnce("unavailable", "[SaveSys] official cloud adapter unavailable; local save remains active")
        return false, "official_cloud_manager_unavailable"
    end
    SaveSys.markCloudDirty(best)
    if force == true then cloudForcePending = true end
    if cloudReadPending or cloudReadFailed or cloudBusy then return true, "queued" end
    local now = nowValue(timestamp)
    if force ~= true and lastCloudUploadAt >= 0
        and now - lastCloudUploadAt < CLOUD_UPLOAD_INTERVAL then
        return true, "throttled"
    end
    local payload = pendingCloud
    local generation = cloudGeneration
    cloudBusy = true
    cloudForcePending = false
    -- 频控按“发起尝试”计时；失败也至少等待60秒再重试，避免逐帧轰炸平台。
    lastCloudUploadAt = now
    local ok, invoked, reason = pcall(function()
        return cloudAdapter:save(CLOUD_SLOT, payload, {
            ok = function()
                cloudBusy = false
                if cloudGeneration == generation then
                    cloudDirty = false
                    pendingCloud = nil
                end
            end,
            error = function(code, message)
                cloudBusy = false
                cloudDirty = true
                logCloudOnce("write", "[SaveSys] cloud save failed; local save kept: "
                    .. tostring(code) .. " " .. tostring(message))
            end,
            timeout = function()
                cloudBusy = false
                cloudDirty = true
                logCloudOnce("write_timeout", "[SaveSys] cloud save timeout; local save kept")
            end,
        })
    end)
    if not ok or invoked == false then
        cloudBusy = false
        cloudDirty = true
        return false, tostring(reason or invoked)
    end
    return true, "uploading"
end

local function beginCloudRead(best, timestamp)
    if cloudReadPending then return true, "loading" end
    cloudReadPending = true
    cloudReadFailed = false
    lastCloudReadAttemptAt = nowValue(timestamp)
    local invoked = loadCloudRecords(cloudAdapter, {
            ok = function(cloudData)
                cloudReadPending = false
                cloudReadFailed = false
                local merged = SaveSys.mergeCloud(best, cloudData)
                replaceTable(best, merged)
                saveLocal(best)
                if cloudMergeCallback then cloudMergeCallback(best) end
                SaveSys.saveCloud(best, nowValue(), true)
            end,
            error = function(code, message)
                cloudReadPending = false
                cloudReadFailed = true
                SaveSys.markCloudDirty(best)
                logCloudOnce("read", "[SaveSys] cloud load failed; retrying before upload: "
                    .. tostring(code) .. " " .. tostring(message))
            end,
            timeout = function()
                cloudReadPending = false
                cloudReadFailed = true
                SaveSys.markCloudDirty(best)
                logCloudOnce("read_timeout", "[SaveSys] cloud load timeout; retrying before upload")
            end,
            invokeFailed = function()
                cloudReadPending = false
                cloudReadFailed = true
                SaveSys.markCloudDirty(best)
            end,
        })
    if invoked == false then
        cloudReadPending = false
        cloudReadFailed = true
        SaveSys.markCloudDirty(best)
        return false, "cloud_load_invoke_failed"
    end
    return true, cloudReadFailed and "retry_pending" or "loading"
end

function SaveSys.tickCloud(best, timestamp)
    local now = nowValue(timestamp)
    if cloudReadFailed and not cloudReadPending then
        if lastCloudReadAttemptAt < 0
            or now - lastCloudReadAttemptAt >= CLOUD_READ_RETRY_INTERVAL then
            return beginCloudRead(best, now)
        end
        return false, "read_retry_wait"
    end
    if not cloudDirty or cloudBusy or cloudReadPending then return false, "idle" end
    local force = cloudForcePending
    return SaveSys.saveCloud(best, now, force)
end

function SaveSys.initCloud(best, enabled, consentGranted, onMerged, adapterOverride)
    cloudEnabled = enabled == true
    cloudBusy = false
    cloudReadPending = false
    cloudReadFailed = false
    lastCloudReadAttemptAt = -1
    cloudMergeCallback = onMerged
    cloudForcePending = false
    cloudDirty = false
    cloudGeneration = 0
    pendingCloud = nil
    lastCloudUploadAt = -1
    cloudLog = {}
    if adapterOverride ~= nil then cloudAdapter = adapterOverride end
    if not cloudEnabled then return false, "feature_disabled" end
    if consentGranted ~= true or not SaveSys.hasPrivacyConsent(best) then
        cloudEnabled = false
        return false, "privacy_not_accepted"
    end
    if type(cloudAdapter) ~= "table" or type(cloudAdapter.load) ~= "function"
        or type(cloudAdapter.save) ~= "function" then
        return false, "official_cloud_manager_unavailable"
    end
    return beginCloudRead(best, nowValue())
end

function SaveSys.save(best)
    local localOK = saveLocal(best)
    local cloudState, cloudReason = "disabled", "feature_disabled"
    if cloudEnabled then
        local cloudOK, reason = SaveSys.saveCloud(best, nowValue(), false)
        cloudReason = reason
        if cloudOK then
            cloudState = (reason == "queued" or reason == "throttled")
                and "queued" or "uploading"
        else
            cloudState = "failed"
        end
    end
    lastSaveStatus = {
        localOK = localOK,
        cloudState = cloudState,
        cloudReason = cloudReason,
        at = nowValue(),
    }
    return localOK
end

function SaveSys.flush(best)
    local localOK = saveLocal(best)
    local cloudState, cloudReason = "disabled", "feature_disabled"
    if cloudEnabled then
        local cloudOK, reason = SaveSys.saveCloud(best, nowValue(), true)
        cloudReason = reason
        cloudState = cloudOK and "uploading" or "failed"
    end
    lastSaveStatus = {
        localOK = localOK,
        cloudState = cloudState,
        cloudReason = cloudReason,
        at = nowValue(),
    }
    return localOK
end

function SaveSys.lastSaveStatus()
    return {
        localOK = lastSaveStatus.localOK == true,
        cloudState = lastSaveStatus.cloudState,
        cloudReason = lastSaveStatus.cloudReason,
        at = lastSaveStatus.at,
    }
end

function SaveSys.cloudDiagnostics()
    return {
        enabled = cloudEnabled,
        busy = cloudBusy,
        readPending = cloudReadPending,
        readFailed = cloudReadFailed,
        dirty = cloudDirty,
        generation = cloudGeneration,
        lastUploadAt = lastCloudUploadAt,
        adapterKind = type(cloudAdapter) == "table" and cloudAdapter.kind or nil,
    }
end

-- 024C：本地模式（无身份/无云）下仍完整可玩。此函数只做状态查询。
function SaveSys.isLocalMode()
    return cloudEnabled ~= true or type(cloudAdapter) ~= "table"
end

function SaveSys.resetCloudForTests()
    cloudAdapter = nil
    cloudEnabled = false
    cloudBusy = false
    cloudReadPending = false
    cloudReadFailed = false
    lastCloudReadAttemptAt = -1
    cloudMergeCallback = nil
    cloudForcePending = false
    cloudDirty = false
    cloudGeneration = 0
    pendingCloud = nil
    lastCloudUploadAt = -1
    cloudLog = {}
    lastSaveStatus = {
        localOK = false,
        cloudState = "disabled",
        cloudReason = "reset_for_tests",
        at = 0,
    }
    cloudProbeState = "idle"
    lastCloudProbeAttemptAt = -1
    pendingPrivacyDecision = nil
    privacySaveBusy = false
    lastPrivacySaveAttemptAt = -1
end

SaveSys.SCHEMA_VERSION = SCHEMA_VERSION
SaveSys.SYNC_VERSION = SYNC_VERSION
SaveSys.GAME_VERSION = GAME_VERSION
SaveSys.BACKUP_PREFIX = BACKUP_PREFIX
SaveSys.BACKUP_KEEP = BACKUP_KEEP
SaveSys.FILE_NAME = FILE_NAME
SaveSys.LEGACY_FILE_NAME = LEGACY_FILE_NAME
SaveSys.LEGACY_V9_FILE_NAME = LEGACY_V9_FILE_NAME
SaveSys.LEGACY_V8_FILE_NAME = LEGACY_V8_FILE_NAME
SaveSys.LEGACY_V7_FILE_NAME = LEGACY_V7_FILE_NAME
SaveSys.CLOUD_SLOT = CLOUD_SLOT
SaveSys.CLOUD_KEY = CLOUD_SLOT
SaveSys.LEGACY_V9_CLOUD_SLOT = LEGACY_V9_CLOUD_SLOT
SaveSys.LEGACY_V8_CLOUD_SLOT = LEGACY_V8_CLOUD_SLOT
SaveSys.LEGACY_V7_CLOUD_SLOT = LEGACY_V7_CLOUD_SLOT
SaveSys.CLOUD_UPLOAD_INTERVAL = CLOUD_UPLOAD_INTERVAL
SaveSys.PRIVACY_POLICY_VERSION = PRIVACY_POLICY_VERSION

return SaveSys
