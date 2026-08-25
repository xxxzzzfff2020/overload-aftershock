-- main.lua
-- 《过载余波》正式入口：纯 NanoVG 俯视角 2D，移动端竖屏优先。
-- 核心循环：算力过载（猎杀）⇌ 算力耗尽（潜行与诱敌），主动重启推进无尽层数。
-- 标题页、程序化音频、失焦兜底、触点超时回收与本地正式记录。

local Config = require "Config"
local World = require "World"
local Render = require "Render"
local InputSys = require "InputSys"
local AudioSys = require "AudioSys"
local SaveSys = require "SaveSys"
local Viewport = require "Viewport"
local Tutorial = require "Tutorial"
local Profiles = require "ExperimentProfiles"
local Screens = require "Screens"
local Haptics = require "Haptics"
local PlatformFeatures = require "PlatformFeatures"
local PlatformAdapters = require "PlatformAdapters"
local AppLifecycle = require "AppLifecycle"
local RewardedRevive = require "RewardedRevive"
local RunShop = require "RunShop"
local RunRecovery = require "RunRecovery"
local ChallengeCheckpoint = require "ChallengeCheckpoint"
local GraduationArchive = require "GraduationArchive"
local EndlessCheckpoint = require "EndlessCheckpoint"
local EndlessOverclock = require "EndlessOverclock"
local RunFlow = require "RunFlow"
local DebugRunPreset = require "DebugRunPreset"
local PauseFlow = require "PauseFlow"

---@type NVGContextWrapper
local vg = nil
---@type table
local world = nil
local best = nil                 -- SaveSys v2 结构(round/time/tutorialDone/settings/lastExperiment)
local appState = "title"         -- "title" | "game"
local deathFlowStarted = false
local runFinalized = false
local mouseDown = false
local lastPhase = nil
local sessionSeed = 0
local lifecycle = AppLifecycle.New()
local platformInitialized = false
local platformCapabilitiesReady = false
local nextPlatformProbeAt = 0
local PLATFORM_PROBE_INTERVAL = 5
-- 暂停菜单、局内设置和无尽结束确认共享同一模态；不要各自维护 bool。
local pauseFlow = PauseFlow.new()
local pendingRecoveredRun = nil
local nextLeaderboardRetryAt = 0
local endlessRunSerial = 0
local startEndlessFromArchive
-- SDK 广告回调可能在宿主恢复/后台切换的调用栈中到达。先排队，等本帧
-- 生命周期闸门通过后才触碰 World、存档或 UI；token 幂等仍由 PlatformFeatures
-- 负责，这里额外防止旧场景回调重建已经离开的战局。
local pendingRewardedReviveResult = nil

local function recoverPendingSettlement(saveData)
    local pending = saveData and saveData.pendingRunSettlement
    -- Death-page revive offers are intentionally durable.  Do not consume the
    -- settlement marker on launch while the player still has a revive choice;
    -- the checkpoint remains the recovery source until the player explicitly
    -- retries, abandons, or successfully revives.
    if type(pending) == "table" and pending.reviveOfferPending == true then
        return false
    end
    if world ~= nil and world.phase == "dead" and type(pending) == "table" then
        local currentRunId = string.format("%d-%d",
            sessionSeed, math.floor(world.timeAlive * 1000))
        if tostring(pending.runId or pending.id or "") == currentRunId then
            return false
        end
    end
    local recorded, run = SaveSys.consumePendingRunSettlement(saveData)
    if run == nil then return false end
    saveData.tutorialDone = true
    if recorded then pendingRecoveredRun = run end
    SaveSys.saveLocalOnly(saveData)
    print("[MAIN] recovered pending run settlement: " .. tostring(run.runId))
    return recorded
end

local function submitRecoveredRun(saveData)
    if pendingRecoveredRun == nil then return false end
    local cloud = SaveSys.cloudDiagnostics()
    if cloud.enabled and (cloud.readPending or cloud.readFailed) then return false end
    local accepted, reason = PlatformFeatures.submitRun(pendingRecoveredRun, saveData)
    if accepted or reason == "feature_disabled" then
        pendingRecoveredRun = nil
    end
    return accepted
end

local function applyMergedSave(merged)
    recoverPendingSettlement(merged)
    Tutorial.init(merged.tutorialDone)
    Render.setSettings(merged.settings)
    AudioSys.applySettings(merged.settings)
    Haptics.applySettings(merged.settings)
    PlatformFeatures.retryPending(merged)
    print(string.format("[MAIN] cloud/local record merged: layer=%d score=%d",
        merged.round or 0, merged.score or 0))
end

local function initializePlatformAfterConsent()
    local consent = SaveSys.hasPrivacyConsent(best)
    PlatformFeatures.setPrivacyConsent(consent)
    if not consent then return false, "privacy_not_accepted" end
    local adapters = PlatformAdapters.detect(Config)
    if adapters.cloud ~= nil or not platformInitialized then
        SaveSys.setCloudAdapter(adapters.cloud)
    end
    PlatformFeatures.setLeaderboardAdapter(adapters.leaderboard)
    PlatformFeatures.setIdentity(adapters)
    Config.PLATFORM.identityReady = adapters.identityReady == true

    local cloudStarted, cloudReason = false, "already_initialized"
    if not platformInitialized then
        if Config.PLATFORM.cloudSave ~= true then
            platformInitialized = true
            cloudStarted, cloudReason = false, "feature_disabled"
        elseif adapters.cloud ~= nil then
            cloudStarted, cloudReason = SaveSys.initCloud(best,
                Config.PLATFORM.cloudSave, true, applyMergedSave)
        else
            cloudReason = adapters.cloudReason or "official_cloud_manager_unavailable"
        end
    end
    PlatformFeatures.retryPending(best)
    submitRecoveredRun(best)

    -- clientCloud、排行榜方法或账号 UID 可能分批晚于 Start 注入。把“云槽已
    -- 尝试初始化”和“榜单可提交/可读取”分开，避免云对象先出现却永久跳过
    -- 后续排行榜能力探测。
    platformInitialized = Config.PLATFORM.cloudSave ~= true or adapters.cloud ~= nil
    local cloudReady = Config.PLATFORM.cloudSave ~= true or adapters.cloud ~= nil
    local boardReady = Config.PLATFORM.leaderboard ~= true or adapters.leaderboard ~= nil
    local identityRequired = Config.PLATFORM.cloudSave == true
        or Config.PLATFORM.leaderboard == true
    platformCapabilitiesReady = cloudReady and boardReady
        and (not identityRequired or adapters.identityReady == true)
    nextPlatformProbeAt = os.time() + PLATFORM_PROBE_INTERVAL
    return cloudStarted, cloudReason
end

local function saveSettings()
    SaveSys.touchSettings(best)
    SaveSys.save(best)
end

-- 探针恢复决策后的统一收口：合并纪录、关闭隐私门、同步平台同意态并初始化平台。
local function applyProbeConsent(merged)
    applyMergedSave(merged)
    if not SaveSys.needsPrivacyChoice(merged) then
        local consent = SaveSys.hasPrivacyConsent(merged)
        Screens.privacyGateOpen = false
        Screens.privacyGateReturn = "title"
        PlatformFeatures.setPrivacyConsent(consent)
        if consent then
            platformCapabilitiesReady = false
            nextPlatformProbeAt = 0
            initializePlatformAfterConsent()
        end
    end
end

local debugRunActive = false

local function checkpointForCurrentRun()
    local cp = SaveSys.getChallengeCheckpoint(best)
    if not cp or world == nil then return nil end
    if tostring(cp.runId) ~= tostring(world.runId) then return nil end
    return cp
end

local function persistCheckpoint(nextLayer, state)
    if world == nil or debugRunActive or world.endless then return false end
    local cp = ChallengeCheckpoint.capture(world, nextLayer, state,
        world.runId, os.time())
    if not cp or not SaveSys.setChallengeCheckpoint(best, cp) then return false end
    local saved = SaveSys.save(best)
    world.challengeCheckpointAvailable = true
    return saved
end

-- 047：无尽层间保存独立于 ChallengeCheckpoint。只在确认层结算后写入，
-- 同时保留当前超限抽卡池，刷新后可安全重建下一层入口。
local function persistEndlessCheckpoint(nextLayer)
    if world == nil or world.endless ~= true or debugRunActive then return false end
    local cp = EndlessCheckpoint.capture(world, nextLayer, os.time())
    if not cp or not SaveSys.setEndlessCheckpoint(best, cp) then return false end
    local saved = SaveSys.flush(best)
    world.endlessCheckpointAvailable = true
    world.endlessCheckpointSaveFailed = not saved
    return saved
end

-- 将“本局广告已尝试/已使用”写回同一Challenge层间检查点，避免免费重试或
-- 跨刷新恢复后重新获得广告次数。这里只写资格标记，不写当前战斗状态。
local function persistRewardedStateInCheckpoint()
    if world == nil or debugRunActive then return false end
    local cp
    local setter
    local saver
    if world.endless == true then
        cp = SaveSys.getEndlessCheckpoint(best)
        if not cp or tostring(cp.runId) ~= tostring(world.runId) then return false end
        setter = SaveSys.setEndlessCheckpoint
        saver = SaveSys.flush
    else
        cp = checkpointForCurrentRun()
        setter = SaveSys.setChallengeCheckpoint
        saver = SaveSys.save
    end
    if not cp then return false end
    cp.assistedRun = world.assistedRun == true or world.rewardedReviveUsed == true
    cp.rewardedReviveAttempted = world.rewardedReviveAttempted == true
    cp.rewardedReviveUsed = world.rewardedReviveUsed == true
    cp.rewardedReviveCount = math.max(0, math.floor(tonumber(world.rewardedReviveCount) or 0))
    cp.createdAt = os.time()
    if not setter(best, cp) then return false end
    return saver(best)
end

local function syncPausePresentation()
    local active = PauseFlow.isActive(pauseFlow)
    Screens.settingsOpen = PauseFlow.isSettings(pauseFlow)
    Screens.endlessEndConfirmOpen = PauseFlow.isEndlessEndConfirm(pauseFlow)
    -- 设置页也是暂停的一部分；不能因为打开设置就让背景音恢复。
    AudioSys.setPaused(active)
    if world ~= nil then
        world.pauseMenu = active or nil
        if active then
            world.pauseSettings = best and best.settings or {}
            world.pausePrivacyAccepted = SaveSys.hasPrivacyConsent(best)
        end
    end
end

local function setPauseMode(mode)
    PauseFlow.set(pauseFlow, mode)
    syncPausePresentation()
    -- 每次模态切换都清理旧触点，避免打开设置的手指被下一层按钮复用。
    InputSys.onCancel()
end

local function setPaused(value)
    setPauseMode(value == true and PauseFlow.MODE.MENU or PauseFlow.MODE.NONE)
end

local function isPaused()
    return PauseFlow.isActive(pauseFlow)
end

-- 正式 L9 快速验收：跳过L1-L8的手动游玩，但资源、数值、地图和结算
-- 均复用正式链路。它不是调试局，必须保持存档、毕业档和平台资格。
local function beginFormalL9ReviewRun()
    RunRecovery.clear()
    pendingRewardedReviveResult = nil
    Screens.runRecoveryOpen = false
    Screens.formalL9ConfirmOpen = false
    setPauseMode(PauseFlow.MODE.NONE)
    debugRunActive = false
    Tutorial.closeOverlay()
    sessionSeed = os.time() % 1000000
    math.randomseed(sessionSeed)
    Profiles.select(Config.FORMAL.profile, false)
    world = World.New({
        experiment = Config.FORMAL.profile,
        seed = sessionSeed,
        startLayer = DebugRunPreset.START_LAYER,
        runId = string.format("formal-l9-%d-%d", sessionSeed, os.time()),
    })
    local applied, audit = DebugRunPreset.apply(world, { ownerValidation = true })
    if not applied then
        print("[MAIN] formal L9 review preset failed: " .. tostring(audit))
        world = nil
        Screens.settingsOpen = true
        return false
    end
    -- 与正式新挑战一致，快速验收会替换当前挑战检查点；无尽检查点保持不变。
    SaveSys.clearChallengeCheckpoint(best)
    RewardedRevive.resetRun(world)
    local checkpointSaved = persistCheckpoint(
        DebugRunPreset.START_LAYER, ChallengeCheckpoint.LAYER_START)
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    AudioSys.setAmbient(world.phase)
    world:addFx("banner", {
        text = "快速验收 · 从 L9 开始 · 正式模式",
        dur = 2.6,
    })
    if not checkpointSaved then
        world:addFx("toast", { text = "检查点写入失败，请返回后重试", dur = 3.0 })
    end
    print(string.format(
        "[MAIN] FORMAL L9 REVIEW seed=%d map=%s layout=%s data=%d cores=%d score=%d checkpoint=%s",
        sessionSeed, world.mapId, world.layout.name,
        audit.incomeWreckData, audit.incomeCoreCount, audit.referenceScore,
        tostring(checkpointSaved)))
    return true
end

local function newGame(seedOverride)
    -- 024D：主动开始新局 = 放弃上次中断，清除运行快照。
    RunRecovery.clear()
    pendingRewardedReviveResult = nil
    Screens.runRecoveryOpen = false
    setPauseMode(PauseFlow.MODE.NONE)
    debugRunActive = false
    sessionSeed = seedOverride or (os.time() % 1000000)
    math.randomseed(sessionSeed)
    Profiles.select(Config.FORMAL.profile, false)
    world = World.New({ experiment = Config.FORMAL.profile, seed = sessionSeed })
    world.runId = string.format("challenge-%d-%d", sessionSeed, os.time())
    SaveSys.clearChallengeCheckpoint(best)
    SaveSys.clearEndlessCheckpoint(best)
    persistCheckpoint(1, ChallengeCheckpoint.LAYER_START)
    RewardedRevive.resetRun(world)
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    AudioSys.setAmbient(world.phase)
    print(string.format("[MAIN] new formal game seed=%d map=%s layout=%s",
        sessionSeed, world.mapId, world.layout.name))
end

local function resumeEndless()
    local cp = SaveSys.getEndlessCheckpoint(best)
    if not cp then return false end
    RunRecovery.clear()
    pendingRewardedReviveResult = nil
    Screens.runRecoveryOpen = false
    Screens.graduationOpen = false
    setPauseMode(PauseFlow.MODE.NONE)
    debugRunActive = false
    sessionSeed = cp.seed
    math.randomseed(sessionSeed)
    Profiles.select(Config.FORMAL.profile, false)
    world = World.New({
        experiment = Config.FORMAL.profile,
        seed = cp.seed,
        startLayer = cp.nextLayer,
        runId = cp.runId,
        endless = true,
        endlessSeed = cp.endlessRunSeed,
        endlessCheckpoint = cp,
    })
    local rewardedAttempted = world.rewardedReviveAttempted == true
    local rewardedUsed = world.rewardedReviveUsed == true
    local rewardedCount = math.max(0, math.floor(tonumber(world.rewardedReviveCount) or 0))
    local recoveredAssisted = world.assistedRun == true
    RewardedRevive.resetRun(world)
    -- Resuming a saved layer boundary is the canonical continuation path.
    -- Carry only the durable ad/revive metadata; checkpoint recovery itself is
    -- valid for the unified board.
    world.rewardedReviveAttempted = rewardedAttempted
    world.rewardedReviveUsed = rewardedUsed
    world.rewardedReviveCount = rewardedCount
    world.assistedRun = recoveredAssisted or rewardedUsed
    world.cleanRun = not world.assistedRun
    world.recoveredRun = true
    world.checkpointRecovery = true
    world.endless = true
    world.endlessCheckpointAvailable = true
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    AudioSys.setAmbient(world.phase)
    world:addFx("banner", { text = "无尽存档已恢复 · 从第 " .. tostring(cp.nextLayer) .. " 层继续", dur = 2.4 })
    return true
end

local function resumeChallenge(retry, reviveMode)
    local cp = SaveSys.getChallengeCheckpoint(best)
    if not cp then return false end
    pendingRewardedReviveResult = nil
    setPauseMode(PauseFlow.MODE.NONE)
    sessionSeed = cp.seed
    math.randomseed(sessionSeed)
    Profiles.select(Config.FORMAL.profile, false)
    world = World.New({
        experiment = Config.FORMAL.profile,
        seed = cp.seed,
        startLayer = cp.nextLayer,
        challengeCheckpoint = cp,
        checkpointRecovered = true,
        checkpointRetry = retry == true,
    })
    world.challengeCheckpointAvailable = true
    if retry == true then
        cp.challengeRetryCount = world.challengeRetryCount
        cp.createdAt = os.time()
        SaveSys.setChallengeCheckpoint(best, cp)
        SaveSys.save(best)
    end
    local rewardedAttempted = world.rewardedReviveAttempted == true
    local rewardedUsed = world.rewardedReviveUsed == true
    local rewardedCount = math.max(0, math.floor(tonumber(world.rewardedReviveCount) or 0))
    local checkpointAssisted = world.assistedRun == true
    RewardedRevive.resetRun(world)
    world.rewardedReviveAttempted = rewardedAttempted
    world.rewardedReviveUsed = rewardedUsed
    world.rewardedReviveCount = rewardedCount
    world.rewardedReviveState = rewardedUsed and "revived" or "idle"
    world.rewardedReviveMode = reviveMode
    -- A plain checkpoint resume remains eligible.  Explicit retry and either
    -- rewarded path are assisted; checkpoint recovery itself is not.
    world.assistedRun = retry == true or reviveMode == "ad_full_state"
        or checkpointAssisted or rewardedUsed
    world.cleanRun = not world.assistedRun
    world.recoveredRun = true
    world.checkpointRecovery = true
    world.challengeRetry = world.challengeRetryCount > 0
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    Screens.newChallengeConfirmOpen = false
    Screens.graduationOpen = false
    AudioSys.setAmbient(world.phase)
    return true
end

local function backToTitle()
    -- 1.1：返回标题不隐式删除 Challenge 层间检查点；删除只发生在明确结束/新挑战。
    RunRecovery.clear()
    pendingRewardedReviveResult = nil
    setPauseMode(PauseFlow.MODE.NONE)
    Screens.runRecoveryOpen = false
    appState = "title"
    local wasSpecialRun = debugRunActive
    debugRunActive = false
    if wasSpecialRun then
        -- 恢复进入验收前的正式教程完成态。
        Tutorial.init(best and best.tutorialDone)
    else
        Tutorial.closeOverlay()
    end
    Screens.helpOpen = false
    Screens.settingsOpen = false
    Screens.privacyOpen = false
    Screens.recordsOpen = false
    Screens.onlineLeaderboardOpen = false
    Screens.onlineLeaderboardState = "idle"
    Screens.onlineLeaderboardEntries = {}
    Screens.leaderboardPage = 1
    Screens.page = 1
    Screens.recordPage = 1
    Screens.newChallengeConfirmOpen = false
    Screens.graduationOpen = false
    Screens.formalL9ConfirmOpen = false
    Screens.endlessEndConfirmOpen = false
    InputSys.reset()
end

function Start()
    graphics.windowTitle = "过载余波"
    print("=== Overload Aftermath formal mode starting ===")

    vg = nvgCreate(1)
    if vg == nil then
        print("ERROR: nvgCreate failed")
        return
    end

    best = SaveSys.load()
    recoverPendingSettlement(best)
    -- 1.1 canonical：废弃024D任意失焦实时恢复，启动时只清理旧快照。
    -- RunRecovery源码继续保留给026复用，但正式路径不再load/rebuild当前战斗状态。
    RunRecovery.clear()
    -- 025：WASM 本地文件是内存文件系统，刷新即丢。本地尚无隐私决策时，
    -- 用官方 clientCloud 只读探针恢复云端"已同意"与纪录，避免刷新重复弹隐私/教程。
    -- 本地已有决策（含拒绝）时零云调用；探针失败(平台未就绪)由 HandleUpdate 每帧重试。
    -- 回调在合并落地后统一收口：关闭隐私门、同步平台同意态并初始化平台（幂等）。
    SaveSys.probeCloudConsent(best,
        PlatformAdapters.detect(Config).cloud, Config, applyProbeConsent)
    Screens.privacyGateOpen = SaveSys.needsPrivacyChoice(best)
    Screens.privacyGateReturn = "title"
    Screens.runRecoveryOpen = false
    PlatformFeatures.setPrivacyConsent(SaveSys.hasPrivacyConsent(best))
    Tutorial.init(best.tutorialDone)
    Profiles.select(Config.FORMAL.profile, false)
    print(string.format("[MAIN] best record: layer=%d score=%d combo=%d tutorialDone=%s",
        best.bestRun.layer, best.bestRun.score, best.bestCombo, tostring(best.tutorialDone)))

    -- 正式运行路径不加载自检、Bot、研发统计或隐藏调试模块。
    Render.init(vg)
    Render.setSettings(best.settings)
    AudioSys.init(best.settings)
    Haptics.applySettings(best.settings)
    -- 只有当前政策版本已明确同意，才允许云或其他平台能力初始化。
    if not Screens.privacyGateOpen then initializePlatformAfterConsent() end

    SubscribeToEvent(vg, "NanoVGRender", "HandleRender")
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("KeyUp", "HandleKeyUp")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("TouchMove", "HandleTouchMove")
    SubscribeToEvent("TouchEnd", "HandleTouchEnd")
    SubscribeToEvent("MouseButtonDown", "HandleMouseDown")
    SubscribeToEvent("MouseButtonUp", "HandleMouseUp")
    SubscribeToEvent("MouseMove", "HandleMouseMove")
    -- [R2] 失焦/最小化:清空触点(无 touch-cancel 事件的兜底,§14.1)
    SubscribeToEvent("InputFocus", "HandleInputFocus")
    -- 分辨率证据：窗口/设备尺寸变化时重算 Viewport 快照，并打印真实物理/逻辑/DPR，
    -- 供预览(390 逻辑)与真机(物理÷DPR)对照，不改变任何游戏规则。
    SubscribeToEvent("ScreenMode", "HandleScreenMode")
    Viewport.logViewportEvidence("START")
end

-- 屏幕尺寸/DPR 变化(旋转、宿主缩放、真机窗口)时刷新布局，避免沿用旧快照。
---@param eventType string
---@param eventData ScreenModeEventData
function HandleScreenMode(eventType, eventData)
    Viewport.capture()
    Viewport.logViewportEvidence("SCREEN_MODE")
end

function Stop()
    if best ~= nil then SaveSys.flush(best) end
    AudioSys.shutdown()
    if vg ~= nil then
        nvgDelete(vg)
        vg = nil
    end
end

-- 教程结束后的导航取决于打开来源：首次教程进入L1，设置回看返回设置。
-- 未知来源采取安全关闭，绝不意外创建新Run。
local function finishTutorialOverlay()
    local route = Tutorial.finishOverlay()
    if route == "settings" then
        Screens.settingsOpen = true
        return
    end
    if route ~= "start_game" then return end
    best.tutorialDone = Tutorial.isDone()
    -- 首次教学完成属于一次性状态，强制提交，避免 60 秒云节流窗口内刷新后重复展示。
    SaveSys.flush(best)
    newGame()
end

-- 标题页动作
local function loadOnlineLeaderboard()
    local ready = PlatformFeatures.leaderboardStatus()
    if not ready then return false end
    local requestId = Screens.beginOnlineLeaderboardLoad(os.time())
    local started = PlatformFeatures.fetchLeaderboard(Screens.LEADERBOARD_MAX_RESULTS, {
        ok = function(entries)
            Screens.setOnlineLeaderboardEntries(entries, requestId)
        end,
        -- Nicknames are optional enrichment.  Rows are already visible before
        -- this callback arrives; retain the current request token so a late
        -- name response can never overwrite a newer view.
        names = function(entries)
            if Screens.isOnlineLeaderboardRequestCurrent(requestId) then
                Screens.onlineLeaderboardEntries = entries
            end
        end,
        error = function()
            Screens.setOnlineLeaderboardError("暂时无法读取公开榜，请重试", requestId)
        end,
        timeout = function()
            Screens.setOnlineLeaderboardError("读取超时，请重试", requestId)
        end,
        myRank = function(rank, scoreValue)
            if Screens.isOnlineLeaderboardRequestCurrent(requestId) then
                Screens.setMyRank(rank, scoreValue)
            end
        end,
    })
    if not started then
        Screens.setOnlineLeaderboardError("暂时无法读取公开榜，请重试", requestId)
    end
    return started
end

local function handleTitleAction(id)
    AudioSys.unlock()
    AudioSys.play("ui_click")
    Haptics.light()
    if id == "privacyAccept" then
        local decision = "accepted"
        SaveSys.setPrivacyDecision(best, decision)
        SaveSys.saveLocalOnly(best)
        -- 当前隐私版本只有“了解并同意”一条继续路径；记录会独立落盘，
        -- 刷新时可由平台槽恢复，避免重复弹窗。
        SaveSys.persistPrivacyDecision(best, decision,
            PlatformAdapters.detect(Config).cloud)
        Screens.privacyGateOpen = false
        local returnTo = Screens.privacyGateReturn
        Screens.privacyGateReturn = "title"
        platformCapabilitiesReady = false
        nextPlatformProbeAt = 0
        initializePlatformAfterConsent()
        if returnTo == "settings" then
            Screens.settingsOpen = true
        end
    elseif Screens.privacyGateOpen then
        return
    elseif id == "start" then
        -- 023C 首次教程：仅新档第一次开始游戏自动显示；完成/跳过即保存。
        -- 第二局、刷新、重进不再自动重复；手动重看不清除已完成状态。
        if Tutorial.shouldShowFirstRun() then
            Tutorial.beginFirstRun()
            return
        end
        newGame()
    elseif id == "continueChallenge" then
        resumeChallenge(false)
    elseif id == "continueEndless" then
        resumeEndless()
    elseif id == "openGraduation" then
        Screens.graduationOpen = true
        Screens.helpOpen = false
        Screens.privacyOpen = false
        Screens.settingsOpen = false
        Screens.recordsOpen = false
        Screens.onlineLeaderboardOpen = false
    elseif id == "closeGraduation" then
        Screens.graduationOpen = false
    elseif string.find(tostring(id), "^startGraduation:") then
        local slot = tonumber(string.match(tostring(id), "^startGraduation:(%d+)$"))
        if slot and startEndlessFromArchive then startEndlessFromArchive(slot) end
    elseif id == "startNewChallenge" then
        Screens.newChallengeConfirmOpen = true
    elseif id == "confirmStartNewChallenge" then
        SaveSys.clearChallengeCheckpoint(best)
        SaveSys.clearEndlessCheckpoint(best)
        SaveSys.save(best)
        Screens.newChallengeConfirmOpen = false
        if Tutorial.shouldShowFirstRun() then
            Tutorial.beginFirstRun()
        else
            newGame()
        end
    elseif id == "cancelStartNewChallenge" then
        Screens.newChallengeConfirmOpen = false
    elseif id == "tutorialPrev" then
        Tutorial.prevPage()
    elseif id == "tutorialNext" then
        if not Tutorial.nextPage() then
            finishTutorialOverlay()
        end
    elseif id == "tutorialSkip" or id == "tutorialDone" then
        finishTutorialOverlay()
    elseif id == "replayTutorial" then
        Tutorial.replayFirstRun()
    elseif id == "formalL9" then
        Screens.settingsOpen = false
        Screens.formalL9ConfirmOpen = true
    elseif id == "confirmFormalL9" then
        beginFormalL9ReviewRun()
    elseif id == "cancelFormalL9" then
        Screens.formalL9ConfirmOpen = false
        Screens.settingsOpen = true
    elseif id == "help" then
        Screens.helpOpen = true
        Screens.settingsOpen = false
        Screens.privacyOpen = false
        Screens.recordsOpen = false
        Screens.onlineLeaderboardOpen = false
        Screens.page = 1
    elseif id == "privacy" then
        Screens.privacyOpen = true
        Screens.documentReturn = "title"
        Screens.helpOpen = false
        Screens.settingsOpen = false
        Screens.recordsOpen = false
        Screens.onlineLeaderboardOpen = false
        Screens.page = 1
    elseif id == "settings" then
        Screens.settingsOpen = true
        Screens.helpOpen = false
        Screens.privacyOpen = false
        Screens.recordsOpen = false
        Screens.onlineLeaderboardOpen = false
    elseif id == "records" then
        Screens.recordsOpen = true
        Screens.helpOpen = false
        Screens.privacyOpen = false
        Screens.settingsOpen = false
        Screens.onlineLeaderboardOpen = false
        Screens.recordPage = 1
    elseif id == "onlineLeaderboard" then
        Screens.helpOpen = false
        Screens.privacyOpen = false
        Screens.settingsOpen = false
        Screens.recordsOpen = false
        loadOnlineLeaderboard()
    elseif id == "closeOnlineLeaderboard" then
        PlatformFeatures.cancelLeaderboardFetch()
        Screens.closeOnlineLeaderboard()
    elseif id == "retryOnlineLeaderboard" then
        PlatformFeatures.cancelLeaderboardFetch()
        loadOnlineLeaderboard()
    elseif id == "prevOnlineLeaderboard" then
        Screens.changeLeaderboardPage(-1, Screens.onlineLeaderboardEntries)
    elseif id == "nextOnlineLeaderboard" then
        Screens.changeLeaderboardPage(1, Screens.onlineLeaderboardEntries)
    elseif id == "closeDocument" then
        local returnTo = Screens.documentReturn
        Screens.helpOpen = false
        Screens.privacyOpen = false
        Screens.page = 1
        Screens.documentReturn = "title"
        if returnTo == "settings" then Screens.settingsOpen = true end
    elseif id == "prevPage" then
        Screens.changePage(-1)
    elseif id == "nextPage" then
        Screens.changePage(1)
    elseif id == "closeRecords" then
        Screens.recordsOpen = false
        Screens.recordPage = 1
    elseif id == "prevRecords" then
        Screens.changeRecordPage(-1, best)
    elseif id == "nextRecords" then
        Screens.changeRecordPage(1, best)
    elseif id == "closeSettings" then
        Screens.settingsOpen = false
        saveSettings()
    elseif id == "privacySettings" then
        Screens.settingsOpen = false
        if SaveSys.hasPrivacyConsent(best) then
            Screens.privacyOpen = true
            Screens.documentReturn = "settings"
            Screens.page = 1
        else
            Screens.privacyGateOpen = true
            Screens.privacyGateReturn = "settings"
        end
    elseif id == "sound" then
        best.settings.sound = not best.settings.sound
        AudioSys.applySettings(best.settings)
        saveSettings()
    elseif id == "vibration" then
        best.settings.vibration = not (best.settings.vibration ~= false)
        Haptics.applySettings(best.settings)
        saveSettings()
    elseif id == "musicDown" or id == "musicUp" then
        local delta = id == "musicUp" and 0.1 or -0.1
        best.settings.musicVolume = math.max(0, math.min(1,
            (best.settings.musicVolume or 0.55) + delta))
        AudioSys.applySettings(best.settings)
        saveSettings()
    elseif id == "sfxDown" or id == "sfxUp" then
        local delta = id == "sfxUp" and 0.1 or -0.1
        best.settings.sfxVolume = math.max(0, math.min(1,
            (best.settings.sfxVolume or 0.8) + delta))
        AudioSys.applySettings(best.settings)
        saveSettings()
    elseif id == "reduceFx" then
        best.settings.reduceFx = not best.settings.reduceFx
        Render.setSettings(best.settings)
        saveSettings()
    elseif id == "reduceShake" then
        best.settings.reduceShake = not best.settings.reduceShake
        Render.setSettings(best.settings)
        Haptics.applySettings(best.settings)
        saveSettings()
    end
end

local function buildRun(completionOverride, milestoneLayer, milestoneId)
    local completionReason = completionOverride
        or (world.challengeCompleted == true and "challenge_complete" or "death")
    local baseRunId = world.runId or string.format("%d-%d", sessionSeed,
        math.floor(world.timeAlive * 1000))
    -- 排行榜和本地记录只统计已完成层。进入新层后死亡不能虚增一层；
    -- 最近一次复活检查点保存了进入当前层之前的已完成层数。
    local effectiveLayer = RunFlow.completedLayerForRun(
        world, completionReason, milestoneLayer)
    local effectiveRunId = milestoneId or baseRunId
    return {
        id = effectiveRunId,
        runId = effectiveRunId,
        milestoneId = milestoneId,
        originalRunId = baseRunId,
        completed = true,
        formalMain = true,
        cleanRun = not debugRunActive and world.assistedRun ~= true
            and (world.challengeRetryCount or 0) == 0
            and (world.recoveredRun ~= true or world.checkpointRecovery == true),
        assistedRun = world.assistedRun == true,
        adAssisted = world.rewardedReviveUsed == true,
        recovered = world.recoveredRun == true,
        checkpointRecovery = world.checkpointRecovery == true,
        challengeRetry = world.challengeRetry == true,
        challengeRetryCount = world.challengeRetryCount or 0,
        reviveOfferPending = world.reviveOfferPending == true,
        rewardedRevive = world.rewardedReviveUsed == true,
        review = false,
        debug = debugRunActive,
        bot = false,
        test = false,
        layer = effectiveLayer,
        score = world.score,
        time = world.timeAlive,
        endedAt = os.time(),
        bestCombo = world.bestCombo,
        huntKills = world.huntKills,
        restarts = world.restarts,
        riskSuccesses = world.riskSuccesses,
        lostRiskScore = world.lostRiskScore,
        bestAntiHuntChain = world.bestAntiHuntChain or 0,
        -- 完成挑战：第10层通关后主动结束本局，不是死亡。
        challengeCompleted = world.challengeCompleted == true,
        endless = world.endless == true,
        completionReason = completionReason,
        overclockData = world.endlessOverclock and world.endlessOverclock.data or 0,
        overclockChoices = world.endlessOverclock and world.endlessOverclock.choiceCount or 0,
        gameVersion = Config.GAME_VERSION,
    }
end

local function recordEndlessMilestone(layer)
    if world == nil or world.endless ~= true or debugRunActive then return false end
    layer = math.floor(tonumber(layer) or 0)
    if layer < 10 then return false end
    world.endlessMilestones = world.endlessMilestones or {}
    if world.endlessMilestones[layer] then return true end
    local baseRunId = world.runId or string.format("%d-%d", sessionSeed,
        math.floor(world.timeAlive * 1000))
    local milestoneId = baseRunId .. ":L" .. tostring(layer)
    local run = buildRun("layer_complete", layer, milestoneId)
    run.completed = true
    -- 050A: keep a durable settlement marker before mutating the visible
    -- milestone.  If the process dies or the local write fails, the marker is
    -- recoverable on the next launch and the same run id remains idempotent.
    if not SaveSys.stageRunSettlement(best, run) then return false end
    local recorded = SaveSys.recordRun(best, run)
    -- 写盘失败后重试时，同一里程碑已在内存记录中；这是幂等重试，
    -- 不是重复结算。只有设备存档真正成功后才标记本层已完成事务。
    if not recorded and not SaveSys.hasRun(best, milestoneId) then return false end
    if not SaveSys.flush(best) then return false end
    SaveSys.clearPendingRunSettlement(best, milestoneId)
    if not SaveSys.flush(best) then
        -- Keep the marker if the cleanup write fails; the next launch can
        -- safely consume it without duplicating the recent run.
        SaveSys.stageRunSettlement(best, run)
        return false
    end
    PlatformFeatures.submitRun(run, best)
    world.endlessMilestones[layer] = true
    return true
end

local function finalizeRun(completionOverride)
    if runFinalized or world == nil then return false end
    local run = buildRun(completionOverride)
    if debugRunActive then
        -- 023C: 调试局不写正式存档、不上榜、不更新最佳记录、不触发复活/广告。
        runFinalized = true
        return true
    end
    local isNewRecord = run.cleanRun and SaveSys.isBetterRun(run, best.bestRun)
    local oldChallengeCheckpoint = SaveSys.getChallengeCheckpoint(best)
    local oldEndlessCheckpoint = SaveSys.getEndlessCheckpoint(best)
    if not SaveSys.stageRunSettlement(best, run) then
        world:feedback("本局结算准备失败，请重试")
        return false
    end
    local recorded = SaveSys.recordRun(best, run)
    if not recorded and not SaveSys.hasRun(best, run.runId) then
        world:feedback("本局结算失败，请重试")
        return false
    end
    best.tutorialDone = Tutorial.finishGame()
    -- Phase 1: write the new run while the pending marker/checkpoint still
    -- exists.  A failed write leaves all recovery material intact.
    if not SaveSys.flush(best) then
        world:feedback("本地存档失败，请重试")
        return false
    end
    -- Phase 2: only after the new state is durable do we remove replayable
    -- settlement/checkpoint material, then verify that cleanup itself landed.
    SaveSys.clearPendingRunSettlement(best, run.runId)
    SaveSys.clearChallengeCheckpoint(best, run.runId)
    if world.endless == true then
        SaveSys.clearEndlessCheckpoint(best, world.runId)
    end
    if not SaveSys.flush(best) then
        -- Restore the current settlement marker and the prior checkpoint so a
        -- refresh cannot lose the run or strand the player without recovery.
        SaveSys.stageRunSettlement(best, run)
        if oldChallengeCheckpoint then
            SaveSys.setChallengeCheckpoint(best, oldChallengeCheckpoint)
        end
        if oldEndlessCheckpoint then
            SaveSys.setEndlessCheckpoint(best, oldEndlessCheckpoint)
        end
        world:feedback("结算清理未完成，请重试")
        return false
    end
    -- 024D：本局已结算，运行快照不再有效。  This is intentionally after
    -- both durable writes, never before them.
    RunRecovery.clear()
    PlatformFeatures.submitRun(run, best)
    if isNewRecord then
        world:addFx("banner", { text = "新纪录", dur = 2.0 })
        world:emit("new_record")
    end
    runFinalized = true
    return true
end

startEndlessFromArchive = function(slot)
    local archive = SaveSys.getGraduationArchive(best, slot)
    if not archive then return false end
    RunRecovery.clear()
    Screens.runRecoveryOpen = false
    Screens.graduationOpen = false
    debugRunActive = false
    sessionSeed = archive.seed
    endlessRunSerial = endlessRunSerial + 1
    local runId = string.format("endless-%d-%d-%d",
        sessionSeed, os.time(), endlessRunSerial)
    Profiles.select(Config.FORMAL.profile, false)
    world = World.New({
        experiment = Config.FORMAL.profile,
        seed = archive.seed,
        startLayer = 11,
        runId = runId,
        graduationArchive = archive,
        endless = true,
        endlessSeed = (archive.seed or 1) + endlessRunSerial * 7919,
    })
    SaveSys.clearEndlessCheckpoint(best)
    local starterReady, starterReason = EndlessOverclock.prepareStarterChoice(world)
    if not starterReady then
        world:feedback("超限构筑准备失败，请返回标题重试")
        print("[MAIN] starter overclock failed: " .. tostring(starterReason))
    end
    persistEndlessCheckpoint(11)
    local assisted = world.assistedRun == true
    RewardedRevive.resetRun(world)
    world.assistedRun = assisted
    world.cleanRun = not assisted
    world.endless = true
    world.graduationArchiveRun = true
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    AudioSys.setAmbient(world.phase)
    world:addFx("banner", { text = "毕业档已克隆 · 从L11挑战", dur = 2.4 })
    world:emit("endless_start")
    return true
end

-- 测试局的L10→L11只克隆内存快照，不创建/覆盖三个正式毕业档。
-- 快照强制标为非纯净，作为第二道保险；最终结算仍由debugRunActive拒写。
local function startDebugEndlessFromCurrent()
    local archive = GraduationArchive.capture(world, os.time())
    if not archive then
        if world then world:feedback("测试档快照失败，请重试") end
        return false
    end
    archive.assistedRun = true
    archive.cleanRun = false
    world:completeChallenge()
    finalizeRun("challenge_complete")
    endlessRunSerial = endlessRunSerial + 1
    local runId = string.format("debug-endless-%d-%d-%d",
        sessionSeed, os.time(), endlessRunSerial)
    world = World.New({
        experiment = Config.FORMAL.profile,
        seed = archive.seed,
        startLayer = 11,
        runId = runId,
        graduationArchive = archive,
        endless = true,
        endlessSeed = (archive.seed or 1) + endlessRunSerial * 7919,
    })
    RewardedRevive.resetRun(world)
    world.debugRun = true
    world.assistedRun = true
    world.cleanRun = false
    world.endless = true
    world.graduationArchiveRun = true
    deathFlowStarted = false
    runFinalized = false
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    Tutorial.beginGame()
    appState = "game"
    AudioSys.setAmbient(world.phase)
    world:addFx("banner", { text = "测试档已克隆 · 从L11继续", dur = 2.4 })
    world:emit("endless_start")
    return true
end

local function openGraduationSave(action)
    if debugRunActive then
        world:feedback("测试局不会写入正式毕业档")
        return false
    end
    local archive = GraduationArchive.capture(world, os.time())
    if not archive then
        world:feedback("毕业档快照失败，请重试")
        return false
    end
    world.graduationArchiveOpen = true
    world.graduationAction = action
    world.graduationArchivePending = archive
    world.graduationArchiveSlots = SaveSys.getGraduationArchives(best)
    return true
end

local function commitGraduationSlot(slot)
    if debugRunActive then
        if world then world:feedback("测试局禁止写入正式毕业档") end
        return false
    end
    local archive = world and world.graduationArchivePending
    local action = world and world.graduationAction
    if not archive or not SaveSys.setGraduationArchive(best, slot, archive) then
        if world then world:feedback("毕业档保存失败，请重试") end
        return false
    end
    -- WASM本地文件系统可能只提供会话内落盘；SaveSys仍会在平台能力可用时
    -- 排队同步。这里不能因本地文件返回false而把玩家锁死在L10结算页。
    SaveSys.save(best)
    world.graduationArchiveOpen = false
    world.graduationArchivePending = nil
    world.graduationArchiveSlots = nil
    world.graduationAction = nil
    SaveSys.clearChallengeCheckpoint(best, world.runId)
    world:completeChallenge()
    finalizeRun("challenge_complete")
    if action == "endless" then
        return startEndlessFromArchive(slot)
    end
    backToTitle()
    return true
end

-- 协议整备输入。购买、确认与第10层选择都在这里处理；
-- World 只负责校验与生效，正式入口负责界面推进与本局收尾。
local function handleSettlementInput(input)
    local pressed = input.pressed
    if world.overclockChoiceOpen then
        for id in pairs(pressed) do
            local index = tonumber(string.match(tostring(id), "^overclock:(%d+)$"))
            if index then
                local ok, reason = EndlessOverclock.applyChoice(world, index)
                if not ok and reason then world:feedback(reason) end
                if ok and world.endless == true then
                    -- L11入场选择发生在本层开战前，快照仍必须指向L11；
                    -- 后续超限选择发生在层结算，才指向下一层。
                    local nextLayer = world.phase == "layer_intro"
                        and (world.round or 11) or ((world.round or 10) + 1)
                    local saved = persistEndlessCheckpoint(nextLayer)
                    if not saved then world:feedback("本层构筑已选，但存档失败；请重试保存") end
                end
                InputSys.reset()
                return
            end
        end
        return
    end
    if world.graduationArchiveOpen == true then
        if pressed.graduationCancel then
            world.graduationArchiveOpen = false
            world.graduationArchivePending = nil
            world.graduationArchiveSlots = nil
            world.graduationAction = nil
            InputSys.reset()
            return
        end
        for id in pairs(pressed) do
            local slot = tonumber(string.match(tostring(id), "^graduationSlot:(%d+)$"))
            if slot then
                commitGraduationSlot(slot)
                InputSys.reset()
                return
            end
        end
        return
    end
    if world.checkpointReady then
        if pressed.checkpointContinue then
            world.checkpointReady = false
            world:advanceLayer()
            InputSys.reset()
            lastPhase = world.phase
            AudioSys.setAmbient(world.phase)
        elseif pressed.checkpointSuspend then
            world.checkpointReady = false
            backToTitle()
        end
        return
    end
    if world.endless == true and world.endlessCheckpointSaveFailed == true
        and pressed.checkpointSuspend then
        -- 保存失败不得把玩家锁在整备页。内存中的本层成绩和无尽
        -- 快照仍保留至本会话标题页，玩家可选择稍后再尝试持久化。
        backToTitle()
        InputSys.reset()
        return
    end
    local st = world.layerSettlement
    local runComplete = st and st.runComplete
    if runComplete and world.challengeExitConfirm == true then
        -- 二次确认态屏蔽购买与其他整备动作：左键确认结算，右键返回选择。
        if pressed.shopComplete then
            AudioSys.play("ui_click")
            Haptics.light()
            if debugRunActive then
                world:completeChallenge()
                finalizeRun("challenge_complete")
                backToTitle()
                InputSys.reset()
                return
            else
                openGraduationSave("settle")
            end
            InputSys.reset()
            lastPhase = world.phase
            AudioSys.setAmbient(world.phase)
        elseif pressed.shopConfirm then
            AudioSys.play("ui_click")
            Haptics.light()
            world.challengeExitConfirm = false
            world:feedback("已返回第10层完成选择")
        end
        return
    end
    for id in pairs(pressed) do
        local itemId = string.match(tostring(id), "^buy:(.+)$")
        if itemId then
            local ok = world:buyRunUpgrade(itemId)
            if ok then
                RunShop.pulse(world, itemId)
                local settlementAfterPurchase = world.layerSettlement
                if settlementAfterPurchase and settlementAfterPurchase.runComplete then
                    persistCheckpoint(10, ChallengeCheckpoint.L10_CHOICE)
                end
            end
        end
    end
    if not pressed.shopConfirm and not pressed.shopComplete then return end
    AudioSys.play("ui_click")
    Haptics.light()
    if pressed.shopComplete and runComplete then
        -- 第一次点击只进入明确的二次确认，不立即结束15—20分钟构筑。
        world.challengeExitConfirm = true
        world:feedback("再次确认将结算本局，且不能继续L11")
        return
    end
    if runComplete then
        -- 继续无尽也先保存不可编辑毕业档；原Challenge在L10结算，
        -- 再从该档克隆新的L11 Run，避免一个run_id重复提交。
        if debugRunActive then
            startDebugEndlessFromCurrent()
        else
            openGraduationSave("endless")
        end
    else
        local checkpointSaved
        if world.endless == true then
            checkpointSaved = persistEndlessCheckpoint((world.round or 10) + 1)
        else
            checkpointSaved = persistCheckpoint(world.round + 1, ChallengeCheckpoint.LAYER_START)
        end
        if checkpointSaved then
            world.checkpointReady = true
            world:addFx("toast", { text = "第 " .. tostring(world.round + 1)
                .. " 层检查点已保存", dur = 1.6 })
        else
            world:feedback("检查点保存失败，请重试")
        end
    end
    InputSys.reset()
    lastPhase = world.phase
    AudioSys.setAmbient(world.phase)
end

local function handleRewardedReviveResult(result)
    if world == nil or world.rewardedReviveState ~= "pending" then return end
    local success = type(result) == "table" and result.success == true
    local reason = type(result) == "table" and result.msg or "ad_failed"
    local mode = world.rewardedReviveMode or "in_place"
    local revived, outcome = RewardedRevive.resolve(world, best, success, reason, os.time(), mode)
    if revived then
        persistRewardedStateInCheckpoint()
        SaveSys.clearPendingRunSettlement(best)
        SaveSys.flush(best)
        if outcome == "full_state" then
            -- Full-state revival is a deterministic layer-start rebuild.  It
            -- keeps the run's score/build checkpoint, but drops the dead
            -- combat snapshot and starts the layer in stealth.
            resumeChallenge(false, "ad_full_state")
        else
            deathFlowStarted = false
            runFinalized = false
            lastPhase = world.phase
            InputSys.reset()
            AudioSys.setAmbient(world.phase, true)
        end
    else
        -- Failure/cancel/timeout returns to the same death page.  Keep the
        -- durable offer marker and checkpoint so refresh cannot silently
        -- record-and-delete the run before the player chooses again.
        -- RewardedRevive 已根据回调类型生成玩家可见提示；仅兼容旧存档中
        -- 尚无提示字段的 timeout 状态，不能覆盖“提前关闭”的免责文案。
        if type(world.rewardedReviveFailureNotice) ~= "table" then
            world.rewardedReviveTimeout = reason == "ad_timeout"
        end
        persistRewardedStateInCheckpoint()
        SaveSys.flush(best)
        InputSys.reset()
    end
end

local function queueRewardedReviveResult(result)
    if world == nil or world.rewardedReviveState ~= "pending" then return false end
    -- 同一请求只接收最先抵达的结果。PlatformFeatures 同样有 token 防重，
    -- 双层保护可覆盖同步回调、超时和迟到回调交错的宿主实现。
    if pendingRewardedReviveResult ~= nil then return false end
    pendingRewardedReviveResult = { world = world, result = result }
    return true
end

local function consumeQueuedRewardedReviveResult()
    local pending = pendingRewardedReviveResult
    if pending == nil then return false end
    if lifecycle.suspended or lifecycle.resumeRequired then return false end
    pendingRewardedReviveResult = nil
    if appState ~= "game" or world ~= pending.world
        or world.rewardedReviveState ~= "pending" then
        return false
    end
    handleRewardedReviveResult(pending.result)
    return true
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end
    local now = os.time()
    -- SDK 不保证终态回调。soft timeout 只在当前死亡页提供本地选择，
    -- 不会结束请求或发奖；hard timeout 仍由 PlatformFeatures 结算失败。
    -- 即使后台也持续 tick，确保恢复时不会留下永不结束的本地等待。
    local rewardedAdEvent = PlatformFeatures.tickRewardedAd(now)
    if rewardedAdEvent == "soft_timeout" and appState == "game" and world ~= nil
        and world.rewardedReviveState == "pending" then
        RewardedRevive.markSoftTimeout(world)
        InputSys.reset()
    end
    if Screens.tickOnlineLeaderboardLoad(now) then
        PlatformFeatures.cancelLeaderboardFetch()
    end
    if lifecycle.suspended then return end
    Render.tick(dt)
    AudioSys.tick(dt)
    Haptics.tick(dt)
    -- 广告 soft/hard timeout 都绝不发奖；PlatformFeatures 丢弃失效请求的迟到回调。
    SaveSys.tickCloud(best, now)
    if now >= nextLeaderboardRetryAt then
        nextLeaderboardRetryAt = now + 60
        PlatformFeatures.retryPending(best)
        submitRecoveredRun(best)
    end
    -- 026+: clientCloud 延迟就绪兜底。平台对象可能先于 UID、排行榜方法或
    -- 昵称接口注入；按短间隔重新探测，而不是在第一帧把本地模式永久锁死。
    local needsPlatformProbe = SaveSys.hasPendingPrivacyDecision()
        or SaveSys.needsPrivacyChoice(best)
        or (SaveSys.hasPrivacyConsent(best) and not platformCapabilitiesReady)
    local cloudAdapter = nil
    if needsPlatformProbe and now >= nextPlatformProbeAt then
        nextPlatformProbeAt = now + PLATFORM_PROBE_INTERVAL
        cloudAdapter = PlatformAdapters.detect(Config).cloud
        SaveSys.retryPendingPrivacy(cloudAdapter)
        if SaveSys.needsPrivacyChoice(best) then
            SaveSys.probeCloudConsent(best, cloudAdapter, Config, applyProbeConsent)
        elseif SaveSys.hasPrivacyConsent(best) and not platformCapabilitiesReady then
            initializePlatformAfterConsent()
        end
    end
    if lifecycle.resumeRequired then return end
    if consumeQueuedRewardedReviveResult() then return end
    if appState == "title" or world == nil then return end
    InputSys.tick(world, dt)     -- [R2] 触点超时回收
    local input = InputSys.collect()
    if input.pressed.pause then
        if not isPaused() then setPaused(true) end
    end

    -- 层结算 / 协议整备：正式入口在这里消费 World 产生的信号并处理整备输入。
    -- 世界逻辑此时由 World:update 冻结，不会自行推进层数。
    if isPaused() then
        -- pauseFlow 是唯一状态源；Render 与 Input 共享同一套可见按钮。
        syncPausePresentation()
        -- 无尽结束确认是破坏性操作，必须先在独立确认态消费输入。
        if PauseFlow.isEndlessEndConfirm(pauseFlow) then
            if input.pressed.pauseEndlessConfirmCancel then
                setPauseMode(PauseFlow.MODE.MENU)
            elseif input.pressed.pauseEndlessConfirmEnd and world.endless == true then
                setPaused(false)
                -- 不在确认前删除检查点：finalizeRun 的两阶段落盘成功后才会
                -- 清理本次无尽检查点，失败时仍可回到暂停页继续或重试。
                RewardedRevive.skip(world, "endless_ended")
                if finalizeRun("endless_end") then
                    backToTitle()
                else
                    setPaused(true)
                end
            end
        elseif input.pressed.pauseResume then
            setPaused(false)
        elseif input.pressed.pauseSettings then
            setPauseMode(PauseFlow.MODE.SETTINGS)
        elseif input.pressed.pauseReturnEndless and world.endless == true then
            -- 只返回已有、已落盘的层间检查点；不捕获半局位置/敌人/拾取物，
            -- 避免把未确认战斗状态复制为可利用的存档。
            local checkpoint = SaveSys.getEndlessCheckpoint(best)
            if checkpoint and tostring(checkpoint.runId) == tostring(world.runId) then
                setPaused(false)
                backToTitle()
            else
                world:feedback("当前无尽进度尚未保存，请先完成本层或稍后重试")
            end
        elseif input.pressed.pauseEndEndless and world.endless == true then
            setPauseMode(PauseFlow.MODE.ENDLESS_END_CONFIRM)
        elseif input.pressed.pauseQuit then
            setPaused(false)
            if not runFinalized then
                SaveSys.clearChallengeCheckpoint(best, world.runId)
                RewardedRevive.skip(world, "paused_quit")
                finalizeRun("manual_abandon")
            end
            backToTitle()
        else
            -- 暂停设置内点击:复用标题页设置动作(限无副作用项)
            for id in pairs(input.pressed) do
                if id == "sound" or id == "vibration" or id == "musicDown"
                    or id == "musicUp" or id == "sfxDown" or id == "sfxUp"
                    or id == "reduceFx" or id == "reduceShake" then
                    handleTitleAction(id)
                elseif id == "closeSettings" then
                    saveSettings()
                    -- 局内设置的明确出口是“保存并继续”，不再回到一个看起来
                    -- 没有变化的暂停页；统一模态会同步清理遗留触点。
                    setPaused(false)
                end
            end
        end
        return
    end

    -- 047: L11 入场超限三选一是一个冻结式确认层。它可能发生在
    -- layer_intro，而不是协议整备；在选择完成前不得推进倒计时或战斗。
    if world.overclockChoiceOpen == true then
        handleSettlementInput(input)
        world.pauseMenu = nil
        Haptics.drain(world)
        AudioSys.drain(world)
        return
    end

    if world.phase == "layer_settlement" then
        handleSettlementInput(input)
        world.pauseMenu = nil
        Haptics.drain(world)
        AudioSys.drain(world)
        return
    end

    if world.phase == "dead" then
        if not deathFlowStarted then
            deathFlowStarted = true
            -- 完成挑战和调试局都不提供复活；直接收口。
            if world.challengeCompleted or debugRunActive then
                finalizeRun()
            elseif not world.endless and world.round <= Config.RUN.finalLayer
                and checkpointForCurrentRun() ~= nil then
                -- Challenge死亡同时保留：广告续战、免费检查点重试、结束挑战。
                world.challengeCheckpointAvailable = true
                local ready, reason = PlatformFeatures.rewardedAdStatus()
                local offered = RewardedRevive.onDeath(world, best, ready, reason, os.time())
                if offered then
                    local pendingRun = buildRun()
                    if SaveSys.stageRunSettlement(best, pendingRun) then SaveSys.flush(best) end
                end
            else
                local ready, reason = PlatformFeatures.rewardedAdStatus()
                local offered = RewardedRevive.onDeath(world, best, ready, reason, os.time())
                if offered then
                    local pendingRun = buildRun()
                    if SaveSys.stageRunSettlement(best, pendingRun) then
                        SaveSys.flush(best)
                    end
                else
                    finalizeRun()
                end
            end
        end
        if input.pressed.adSoftContinue
            and world.rewardedReviveState == "pending"
            and world.rewardedReviveSoftTimeout == true then
            RewardedRevive.continueWaiting(world)
            InputSys.reset()
            return
        elseif input.pressed.adSoftCancel
            and world.rewardedReviveState == "pending"
            and world.rewardedReviveSoftTimeout == true then
            -- “确认返回”只取消本地等待。SDK 本身无取消 API，但旧 callback
            -- 已被 PlatformFeatures 的 completed/token 门失效，不能再发奖。
            local cancelled = PlatformFeatures.cancelRewardedRevive()
            if cancelled and RewardedRevive.cancelPending(world, "ad_wait_cancelled") then
                pendingRewardedReviveResult = nil
                persistRewardedStateInCheckpoint()
                SaveSys.flush(best)
            end
            InputSys.reset()
            return
        elseif input.pressed.adFailureClose
            and type(world.rewardedReviveFailureNotice) == "table" then
            RewardedRevive.dismissFailure(world)
            InputSys.reset()
            return
        elseif input.pressed.adTimeoutClose and world.rewardedReviveTimeout == true then
            world.rewardedReviveTimeout = false
            world.rewardedReviveReason = "ad_timeout"
            InputSys.reset()
            return
        elseif input.pressed.reviveCancel and world.reviveChoiceState == "select" then
            RewardedRevive.cancelChoice(world)
            InputSys.reset()
            return
        elseif input.pressed.cancelReviveConfirm
            and (world.reviveChoiceState == "confirm_in_place"
                or world.reviveChoiceState == "confirm_full_state") then
            world.reviveChoiceState = "select"
            world.reviveChoiceMode = nil
            InputSys.reset()
            return
        elseif input.pressed.reviveInPlace and world.reviveChoiceState == "select" then
            RewardedRevive.selectChoice(world, "in_place")
            InputSys.reset()
            return
        elseif input.pressed.reviveFullState and world.reviveChoiceState == "select"
            and world.endless ~= true then
            RewardedRevive.selectChoice(world, "full_state")
            InputSys.reset()
            return
        elseif (input.pressed.confirmReviveInPlace
                and world.reviveChoiceState == "confirm_in_place")
            or (input.pressed.confirmReviveFullState
                and world.reviveChoiceState == "confirm_full_state") then
            local mode = world.reviveChoiceState == "confirm_full_state"
                and "full_state" or "in_place"
            local begun, beginReason = RewardedRevive.begin(world, mode)
            if begun then
                persistRewardedStateInCheckpoint()
                local started, reason = PlatformFeatures.requestRewardedRevive(
                    queueRewardedReviveResult)
                if not started then
                    queueRewardedReviveResult({ success = false,
                        msg = reason or beginReason or "ad_request_failed" })
                end
            else
                world:feedback(beginReason or "复活选择已失效，请重试")
            end
            return
        elseif input.pressed.revive and world.rewardedReviveState == "offered" then
            local opened = RewardedRevive.openChoice(world)
            if not opened then world:feedback("复活选择已失效，请重试") end
            InputSys.reset()
            return
        elseif input.pressed.retryLayer and world.challengeCheckpointAvailable
            and world.rewardedReviveState ~= "pending" then
            RewardedRevive.skip(world, "checkpoint_retry")
            persistRewardedStateInCheckpoint()
            SaveSys.clearPendingRunSettlement(best, world.runId)
            SaveSys.save(best)
            resumeChallenge(true)
            return
        elseif input.pressed.endChallenge and world.challengeCheckpointAvailable
            and world.rewardedReviveState ~= "pending" then
            SaveSys.clearChallengeCheckpoint(best, world.runId)
            RewardedRevive.skip(world, "challenge_ended")
            finalizeRun("death")
            backToTitle()
            return
        end
        if input.pressed.again then
            if not runFinalized then
                RewardedRevive.skip(world, "player_skipped")
                finalizeRun()
            end
            newGame()
            return
        elseif input.pressed.title then
            if not runFinalized then
                RewardedRevive.skip(world, "player_skipped")
                finalizeRun()
            end
            backToTitle()
            return
        end
    end

    world.pauseMenu = nil
    world:update(dt, input)

    -- 反猎结束会在 World 内部切到层结算；正式入口在下一帧消费信号并打开界面。
    local signal = world:consumeSignal()
    if signal == "layer_ready_for_settlement" then
        if world.endless == true then
            -- 每一层完成都建立独立里程碑。失败只提示，不把玩家锁死在
            -- 结算页；下一层按钮仍可再次触发同一事务。
            local milestoneSaved = recordEndlessMilestone(world.round)
            local checkpointSaved = persistEndlessCheckpoint((world.round or 10) + 1)
            if not milestoneSaved or not checkpointSaved then
                world.endlessCheckpointSaveFailed = true
                world:feedback("本层已结算，但存档未完成；请重试保存")
            else
                world.endlessCheckpointSaveFailed = false
            end
        elseif world.round == Config.RUN.finalLayer then
            persistCheckpoint(10, ChallengeCheckpoint.L10_CHOICE)
        end
        InputSys.onPhaseChange()
        AudioSys.setAmbient(world.phase)
    end

    -- 阶段切换:清理不再合法的输入状态
    if world.phase ~= lastPhase then
        lastPhase = world.phase
        InputSys.onPhaseChange()
    end

    Tutorial.update(world, dt)
    Haptics.drain(world)
    AudioSys.drain(world)
end

function HandleRender(eventType, eventData)
    if vg == nil then return end
    local viewport = Viewport.capture()
    local w, h = viewport.w, viewport.h
    nvgBeginFrame(vg, viewport.logicalW, viewport.logicalH, viewport.dpr)
    nvgSave(vg)
    nvgScale(vg, viewport.designScale, viewport.designScale)
    if Tutorial.active then
        Render.drawTutorialOverlay(w, h)
    elseif appState == "title" or world == nil then
        Render.drawTitle(w, h, best)
    else
        Render.draw(world, w, h, best)
    end
    if lifecycle.resumeRequired then Render.drawResumeGate(w, h) end
    nvgRestore(vg)
    nvgEndFrame(vg)
end

local function consumeResumeInput()
    if not AppLifecycle.consumeResume(lifecycle) then return false end
    InputSys.reset()
    mouseDown = false
    -- 若恢复前已打开暂停模态，恢复输入闸门只消耗这次唤醒点击，
    -- 不能意外让已暂停的设置页恢复背景音。
    AudioSys.setPaused(isPaused())
    return true
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    if lifecycle.suspended then return end
    if consumeResumeInput() then return end
    local key = eventData:GetInt("Key")
    if Tutorial.active then
        if key == KEY_RETURN or key == KEY_SPACE then handleTitleAction("tutorialNext") end
        return
    end
    if appState == "title" then
        if key == KEY_RETURN or key == KEY_SPACE then handleTitleAction("start") end
        return
    end
    if world == nil then return end
    -- 024C: Esc / P 切换暂停(仅战斗阶段;结算/死亡界面由自身按钮处理)
    if key == KEY_ESCAPE or key == KEY_P then
        local combat = world.phase == "overload" or world.phase == "anti_hunt"
            or world.phase == "depleted"
        if isPaused() then
            setPaused(false)
        elseif combat then
            setPaused(true)
        end
        return
    end
    InputSys.onKey(world, key, true)
end

---@param eventType string
---@param eventData KeyUpEventData
function HandleKeyUp(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) then return end
    if appState == "title" or world == nil then return end
    InputSys.onKey(world, eventData:GetInt("Key"), false)
end

local function pointerDown(id, x, y)
    if lifecycle.suspended then return false end
    if consumeResumeInput() then return true end
    local viewport = Viewport.capture()
    local w, h = viewport.w, viewport.h
    if Tutorial.active then
        local action = Screens.tutorialHit(x, y, w, h)
        if action then handleTitleAction(action) end
        return false
    end
    if appState == "title" then
        local onlineAvailable = PlatformFeatures.leaderboardStatus()
        local action = Screens.hit(x, y, w, h, best.settings,
            SaveSys.hasPrivacyConsent(best), onlineAvailable,
            SaveSys.getChallengeCheckpoint(best), SaveSys.getGraduationArchives(best),
            SaveSys.getEndlessCheckpoint(best))
        if action then handleTitleAction(action) end
        return false
    end
    InputSys.onPointerDown(world, id, x, y, w, h)
    return false
end

---@param eventType string
---@param eventData TouchBeginEventData
function HandleTouchBegin(eventType, eventData)
    local viewport = Viewport.capture()
    local x, y = Viewport.toLogicalPoint(eventData:GetInt("X"), eventData:GetInt("Y"), viewport)
    pointerDown(eventData:GetInt("TouchID"), x, y)
end

---@param eventType string
---@param eventData TouchMoveEventData
function HandleTouchMove(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) then return end
    if appState == "title" or world == nil then return end
    local viewport = Viewport.capture()
    local x, y = Viewport.toLogicalPoint(eventData:GetInt("X"), eventData:GetInt("Y"), viewport)
    InputSys.onPointerMove(world, eventData:GetInt("TouchID"), x, y)
end

---@param eventType string
---@param eventData TouchEndEventData
function HandleTouchEnd(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) then return end
    if appState == "title" or world == nil then return end
    InputSys.onPointerUp(world, eventData:GetInt("TouchID"))
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleMouseDown(eventType, eventData)
    if eventData:GetInt("Button") ~= MOUSEB_LEFT then return end
    mouseDown = true
    local viewport = Viewport.capture()
    local mp = input.mousePosition
    local x, y = Viewport.toLogicalPoint(mp.x, mp.y, viewport)
    if pointerDown(-1, x, y) then mouseDown = false end
end

---@param eventType string
---@param eventData MouseButtonUpEventData
function HandleMouseUp(eventType, eventData)
    if eventData:GetInt("Button") ~= MOUSEB_LEFT then return end
    mouseDown = false
    if AppLifecycle.blocksWorld(lifecycle) then return end
    if appState == "title" or world == nil then return end
    InputSys.onPointerUp(world, -1)
end

---@param eventType string
---@param eventData MouseMoveEventData
function HandleMouseMove(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) then return end
    if appState == "title" or world == nil or not mouseDown then return end
    local viewport = Viewport.capture()
    local mp = input.mousePosition
    local x, y = Viewport.toLogicalPoint(mp.x, mp.y, viewport)
    InputSys.onPointerMove(world, -1, x, y)
end

-- [R2] 窗口失焦/最小化/应用切后台:清空全部触点,恢复后需重新按下(§14.1)
---@param eventType string
---@param eventData InputFocusEventData
function HandleInputFocus(eventType, eventData)
    local focus = eventData:GetBool("Focus")
    if not focus then
        if AppLifecycle.focusLost(lifecycle) then
            SaveSys.flush(best)
            InputSys.onCancel()
            mouseDown = false
            AudioSys.setPaused(true)
        end
    else
        local needsGate = appState == "game" and world ~= nil
        if AppLifecycle.focusGained(lifecycle, needsGate) then
            InputSys.onCancel()
            mouseDown = false
            if not lifecycle.resumeRequired then AudioSys.setPaused(isPaused()) end
        end
    end
end
