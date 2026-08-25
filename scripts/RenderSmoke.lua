-- RenderSmoke.lua
-- [R2] 渲染命令冒烟(§R2任务包M):不依赖真实 NanoVG 执行的可验证工具。
-- 用参数校验桩替换全部 nvg* 全局函数,对标题、隐私、暂停、双地图和死亡流程执行完整渲染数据生成:
-- 校验坐标/尺寸/透明度/文本非nil/save-restore配平,并读取 SafeDraw 单元失败。
-- 在真实 Render.init(vg) 之前运行(main Start);lupa 测试环境同样可跑。

local Config = require "Config"

local RenderSmoke = {}

-- Render 用到的全部 nvg 函数名(桩安装/还原清单)
local NVG_FUNCS = {
    "nvgBeginPath", "nvgRect", "nvgRoundedRect", "nvgCircle", "nvgArc",
    "nvgMoveTo", "nvgLineTo", "nvgClosePath", "nvgFill", "nvgStroke",
    "nvgFillColor", "nvgStrokeColor", "nvgStrokeWidth", "nvgFillPaint",
    "nvgLinearGradient", "nvgRadialGradient", "nvgImagePattern",
    "nvgRGBA", "nvgSave", "nvgRestore", "nvgScissor", "nvgTranslate", "nvgRotate", "nvgScale",
    "nvgLineCap", "nvgLineJoin", "nvgMiterLimit", "nvgText", "nvgTextBox", "nvgTextBounds",
    "nvgFontFace", "nvgFontSize", "nvgTextAlign",
    "nvgShapeAntiAlias",
    "nvgPathWinding", "nvgCreateFont", "nvgCreateImage", "nvgImageSize",
    "nvgDeleteImage", "nvgGlobalAlpha",
}
local NVG_CONSTS = {
    NVG_CW = 1, NVG_CCW = 2, NVG_HOLE = 2, NVG_SOLID = 1,
    NVG_ROUND = 1,
    NVG_ALIGN_LEFT = 1, NVG_ALIGN_CENTER = 2, NVG_ALIGN_RIGHT = 4,
    NVG_ALIGN_TOP = 8, NVG_ALIGN_MIDDLE = 16, NVG_ALIGN_BOTTOM = 32,
}

local errors = {}
local saveDepth = 0
local arcCountInPath = 0

local function bad(msg)
    if #errors < 40 then errors[#errors + 1] = msg end
    error(msg)   -- 让 SafeDraw.section 捕获并归因到单元
end

local function num(fn, v, argIdx)
    if type(v) ~= "number" then
        bad(fn .. " arg" .. argIdx .. " not number: " .. tostring(v))
    end
    if v ~= v or v == math.huge or v == -math.huge then
        bad(fn .. " arg" .. argIdx .. " NaN/inf")
    end
    return v
end

-- 构造桩:第1参为 ctx(忽略),其余按 spec 校验
local function makeStub(name, nums, extra)
    return function(_, ...)
        local args = { ... }
        for i = 1, nums do num(name, args[i], i) end
        if extra then return extra(args) end
    end
end

local function installStubs()
    errors = {}
    saveDepth = 0
    arcCountInPath = 0
    local saved = {}
    local G = _G
    for _, n in ipairs(NVG_FUNCS) do saved[n] = G[n] end
    for k in pairs(NVG_CONSTS) do saved[k] = G[k] end

    for k, v in pairs(NVG_CONSTS) do G[k] = G[k] or v end
    G.nvgBeginPath = function()
        arcCountInPath = 0
    end
    G.nvgRect = makeStub("nvgRect", 4)
    G.nvgRoundedRect = makeStub("nvgRoundedRect", 5)
    G.nvgCircle = makeStub("nvgCircle", 3)
    G.nvgArc = function(_, ...)
        local args = { ... }
        for i = 1, 5 do num("nvgArc", args[i], i) end
        arcCountInPath = arcCountInPath + 1
        -- 项目内的虚线圆弧必须各自开新path。多段不相连圆弧放在
        -- 同一path会被NanoVG自动用直线连接，导致真机上的跨屏多边形。
        if arcCountInPath > 1 then bad("multiple nvgArc calls in one path") end
    end
    G.nvgMoveTo = makeStub("nvgMoveTo", 2)
    G.nvgLineTo = makeStub("nvgLineTo", 2)
    G.nvgClosePath = makeStub("nvgClosePath", 0)
    G.nvgFill = makeStub("nvgFill", 0)
    G.nvgStroke = makeStub("nvgStroke", 0)
    G.nvgFillColor = function(_, c)
        if c == nil then bad("nvgFillColor nil color") end
    end
    G.nvgStrokeColor = function(_, c)
        if c == nil then bad("nvgStrokeColor nil color") end
    end
    G.nvgStrokeWidth = makeStub("nvgStrokeWidth", 1)
    G.nvgFillPaint = function(_, pnt)
        if pnt == nil then bad("nvgFillPaint nil paint") end
    end
    G.nvgLinearGradient = makeStub("nvgLinearGradient", 4, function() return { paint = true } end)
    G.nvgRadialGradient = makeStub("nvgRadialGradient", 4, function() return { paint = true } end)
    G.nvgImagePattern = makeStub("nvgImagePattern", 5, function() return { paint = true } end)
    G.nvgRGBA = function(r, g, b, a)
        for i, v in ipairs({ r, g, b, a }) do
            if type(v) ~= "number" or v ~= v then bad("nvgRGBA arg" .. i .. " bad") end
            if v < 0 or v > 255 then bad("nvgRGBA arg" .. i .. " out of range: " .. v) end
        end
        return { r = r, g = g, b = b, a = a }
    end
    G.nvgSave = function() saveDepth = saveDepth + 1 end
    G.nvgRestore = function()
        saveDepth = saveDepth - 1
        if saveDepth < 0 then bad("nvgRestore without save") end
    end
    G.nvgScissor = makeStub("nvgScissor", 4)
    G.nvgTranslate = makeStub("nvgTranslate", 2)
    G.nvgRotate = makeStub("nvgRotate", 1)
    G.nvgScale = makeStub("nvgScale", 2)
    G.nvgLineCap = makeStub("nvgLineCap", 1)
    G.nvgLineJoin = makeStub("nvgLineJoin", 1)
    G.nvgMiterLimit = makeStub("nvgMiterLimit", 1)
    G.nvgShapeAntiAlias = makeStub("nvgShapeAntiAlias", 1)
    G.nvgText = function(_, x, y, str)
        num("nvgText", x, 1)
        num("nvgText", y, 2)
        if str == nil then bad("nvgText nil string") end
    end
    G.nvgTextBox = function(_, x, y, width, str)
        num("nvgTextBox", x, 1)
        num("nvgTextBox", y, 2)
        num("nvgTextBox", width, 3)
        if str == nil then bad("nvgTextBox nil string") end
    end
    G.nvgTextBounds = function(_, x, y, str)
        num("nvgTextBounds", x, 1)
        num("nvgTextBounds", y, 2)
        if str == nil then bad("nvgTextBounds nil string") end
        return 0
    end
    G.nvgFontFace = function(_, face)
        if type(face) ~= "string" then bad("nvgFontFace bad face") end
    end
    G.nvgFontSize = makeStub("nvgFontSize", 1)
    G.nvgTextAlign = makeStub("nvgTextAlign", 1)
    G.nvgPathWinding = makeStub("nvgPathWinding", 1)
    G.nvgCreateFont = function() return 1 end        -- 字体成功 → 文本路径全部走到
    G.nvgCreateImage = function() return 1 end       -- 图片成功 → 精灵路径全部走到
    G.nvgImageSize = function() return 64, 64 end
    G.nvgDeleteImage = function() end
    G.nvgGlobalAlpha = makeStub("nvgGlobalAlpha", 1)
    return saved
end

local function restoreStubs(saved)
    for k, v in pairs(saved) do _G[k] = v end
end

-- ============================================================
-- 场景组装与执行
-- ============================================================
function RenderSmoke.run()
    print("[SMOKE] ===== render command smoke begin =====")
    local Render = require "Render"
    local SafeDraw = require "SafeDraw"
    local World = require "World"
    local ReviewAccess = require "ReviewAccess"
    local DebugPanel = require "DebugPanel"
    local Screens = require "Screens"
    local PlatformFeatures = require "PlatformFeatures"
    local EndlessOverclock = require "EndlessOverclock"
    local saved = installStubs()

    local results = {}
    local function scenario(name, fn)
        SafeDraw.resetWarnings()
        errors = {}
        saveDepth = 0
        arcCountInPath = 0
        local ok, err = pcall(fn)
        local fails = {}
        for sec, e in pairs(SafeDraw.getFailures()) do
            fails[#fails + 1] = sec .. ": " .. tostring(e)
        end
        local pass = ok and #errors == 0 and #fails == 0 and saveDepth == 0
        results[#results + 1] = { name = name, pass = pass }
        if not pass then
            print(string.format("[SMOKE] FAIL %s | err=%s | args=%s | sections=%s | saveDepth=%d",
                name, tostring(err), errors[1] or "-", fails[1] or "-", saveDepth))
        else
            print("[SMOKE] PASS " .. name)
        end
    end

    local okAll, prepErr = pcall(function()
        local fake = { fakeCtx = true }
        Render.init(fake)            -- 桩环境初始化(字体/图片句柄=1)
        local w, h = 390, 844
        local best = {
            bestRun = { layer = 0, score = 0, time = 0 },
            bestCleanRun = { layer = 0, score = 0, time = 0 },
            bestAssistedRun = {
                layer = 10, score = 829951, time = 900, bestCombo = 58,
                runId = "previous-l10",
            },
            round = 10,
            score = 829951,
            bestCombo = 58,
            time = 200,
            settings = { sound = true, reduceFx = false },
            lastExperiment = "B",
            tutorialDone = false,
            privacyDecision = "accepted",
            privacyConsentVersion = 3,
            recentRuns = {
                { id = "a", layer = 10, score = 829951, bestCombo = 58,
                    recovered = true, assistedRun = true },
                { id = "b", layer = 4, score = 204960, bestCombo = 9,
                    challengeRetryCount = 1 },
            },
        }

        -- 1 标题页
        scenario("title", function() Render.drawTitle(w, h, best) end)
        best.graduationArchives = {
            [1] = {
                version = 1, schemaVersion = 9, archiveId = "smoke-graduation",
                sourceRunId = "smoke-source", sourceLayer = 10, seed = 44,
                score = 829951, wreckData = 3, coreCount = 5, hp = 73,
                cleanRun = true, assistedRun = false, createdAt = 44,
                runUpgrades = { collapseCooldownLevel = 2, pulseCooldownLevel = 1,
                    chainIntervalLevel = 1, jammerBonusUses = 3,
                    decoyBonusUses = 1, cloakBonusUses = 1 },
                modules = {}, activeModules = {}, counters = {},
            },
        }
        scenario("title-endless-unlocked", function() Render.drawTitle(w, h, best) end)
        Screens.graduationOpen = true
        scenario("title-graduation-archive-picker", function() Render.drawTitle(w, h, best) end)
        Screens.graduationOpen = false
        best.endlessCheckpoint = {
            version = 1, schemaVersion = 10, runId = "smoke-endless-checkpoint",
            seed = 47, endlessRunSeed = 47047, completedLayer = 11, nextLayer = 12,
            score = 912345, wreckData = 2, coreCount = 3, hp = 77,
            runUpgrades = {}, modules = {}, activeModules = {}, counters = {},
            cleanRun = false, assistedRun = true, recoveredRun = true,
            checkpointRecovery = true, overclock = {}, createdAt = 47,
        }
        scenario("title-endless-checkpoint", function() Render.drawTitle(w, h, best) end)
        best.endlessCheckpoint = nil
        best.challengeCheckpoint = {
            version = 1, schemaVersion = 8, runId = "smoke-checkpoint", seed = 26,
            nextLayer = 5, checkpointState = "LAYER_START", checkpointHp = 63,
            runUpgrades = {}, modules = {}, activeModules = {}, counters = {}, createdAt = 1,
        }
        scenario("title-challenge-checkpoint", function() Render.drawTitle(w, h, best) end)
        Screens.newChallengeConfirmOpen = true
        scenario("title-new-challenge-confirm", function() Render.drawTitle(w, h, best) end)
        Screens.newChallengeConfirmOpen = false
        best.challengeCheckpoint = nil
        Screens.privacyGateOpen = true
        scenario("privacy-consent-gate", function() Render.drawTitle(w, h, best) end)
        Screens.privacyGateOpen = false
        Screens.helpOpen = true
        scenario("help-page", function() Render.drawTitle(w, h, best) end)
        Screens.helpOpen, Screens.privacyOpen = false, true
        scenario("privacy-page", function() Render.drawTitle(w, h, best) end)
        Screens.privacyOpen, Screens.settingsOpen = false, true
        scenario("settings-page", function() Render.drawTitle(w, h, best) end)
        Screens.settingsOpen = false

        -- #18703/#18704/#18705：局内暂停设置与无尽结束确认必须走到真实
        -- 渲染路径，防止按钮分层或新增菜单状态引入运行时异常。
        local paused = World.New({ experiment = "B", seed = 18703,
            testMode = true, skipLayerIntro = true })
        paused.pauseMenu = true
        paused.pauseSettings = best.settings
        paused.pausePrivacyAccepted = true
        Screens.settingsOpen = true
        scenario("pause-settings-actions", function() Render.draw(paused, w, h, best) end)
        Screens.settingsOpen = false
        local endlessPaused = World.New({ experiment = "B", seed = 18707,
            startLayer = 12, endless = true, runId = "smoke-pause-endless",
            testMode = true, skipLayerIntro = true })
        endlessPaused.pauseMenu = true
        Screens.endlessEndConfirmOpen = false
        scenario("pause-endless-safe-return", function() Render.draw(endlessPaused, w, h, best) end)
        Screens.endlessEndConfirmOpen = true
        scenario("pause-endless-destructive-confirm", function() Render.draw(endlessPaused, w, h, best) end)
        Screens.endlessEndConfirmOpen = false
        Screens.recordsOpen = true
        scenario("records-page", function() Render.drawTitle(w, h, best) end)
        Screens.recordsOpen = false
        local oldLeaderboard, oldLeaderboardKey, oldLeaderboardBackend, oldIdentity =
            Config.PLATFORM.leaderboard, Config.PLATFORM.leaderboardKey,
            Config.PLATFORM.leaderboardBackend, Config.PLATFORM.identityReady
        Config.PLATFORM.leaderboard = true
        Config.PLATFORM.leaderboardBackend = "clientCloud"
        Config.PLATFORM.leaderboardKey = "render_smoke_board"
        Config.PLATFORM.identityReady = true
        PlatformFeatures.resetForTests()
        PlatformFeatures.setPrivacyConsent(true)
        PlatformFeatures.setLeaderboardAdapter({
            submitScore = function() return true end,
            loadScores = function() return true end,
        })
        Screens.beginOnlineLeaderboardLoad(100)
        scenario("online-leaderboard-loading", function() Render.drawTitle(w, h, best) end)
        Screens.setOnlineLeaderboardError("读取超时，请重试")
        scenario("online-leaderboard-retryable-error", function() Render.drawTitle(w, h, best) end)
        Screens.setOnlineLeaderboardEntries({
            { rank = 1, name = "玩家A", layer = 12, score = 345678 },
            { rank = 2, name = "玩家B", layer = 10, score = 900 },
        })
        Screens.setMyRank(7, PlatformFeatures.rankValue(12, 345678))
        scenario("online-leaderboard-page", function() Render.drawTitle(w, h, best) end)
        Screens.setOnlineLeaderboardEntries({})
        Screens.setMyRank(1, 0)
        scenario("online-leaderboard-empty-no-fake-rank", function()
            Render.drawTitle(w, h, best)
        end)
        Screens.closeOnlineLeaderboard()
        Screens.myRank, Screens.myRankScore = nil, nil
        Config.PLATFORM.leaderboard, Config.PLATFORM.leaderboardKey = oldLeaderboard, oldLeaderboardKey
        Config.PLATFORM.leaderboardBackend = oldLeaderboardBackend
        Config.PLATFORM.identityReady = oldIdentity
        PlatformFeatures.resetForTests()
        -- 2 启动观察倒计时
        local intro = World.New({ experiment = "B", seed = 100 })
        scenario("layer-intro", function() Render.draw(intro, w, h, best) end)
        -- 3 过载普通
        local wo = World.New({ experiment = "B", seed = 1,
            testMode = true, skipLayerIntro = true })
        scenario("overload", function() Render.draw(wo, w, h, best) end)
        -- 3 最后5秒
        wo.overloadLeft = 4.2
        scenario("last5s", function() Render.draw(wo, w, h, best) end)
        -- 4 强制跌落瞬间(hitstop/横幅在场)
        wo:forceDrop()
        scenario("drop", function() Render.draw(wo, w, h, best) end)
        -- 5 枯竭潜行
        wo:update(0.05, { moveX = 0, moveY = 0, pressed = {} })
        scenario("depleted", function() Render.draw(wo, w, h, best) end)
        -- 6 被发现(追击 + 警戒弧)
        local foundEnemy = nil
        for _, e in ipairs(wo.enemies) do
            if not e.dead then foundEnemy = e break end
        end
        if foundEnemy then
            foundEnemy.state = "chase"
            foundEnemy.suspicion = 0.4
        end
        scenario("spotted", function() Render.draw(wo, w, h, best) end)
        -- 追击工具反馈：隐身断链、诱饵转向、丢失点搜索。
        if foundEnemy then
            wo.cloakLeft = 1.2
            foundEnemy.lastSeenX, foundEnemy.lastSeenY = wo.player.x - 80, wo.player.y
            scenario("cloak-break", function() Render.draw(wo, w, h, best) end)
            wo.cloakLeft = 0
            local decoy = { x = wo.player.x + 120, y = wo.player.y + 40, left = 1.2 }
            wo.decoys = { decoy }
            foundEnemy.state, foundEnemy.decoyTarget = "decoyed", decoy
            foundEnemy.lastSeenX, foundEnemy.lastSeenY = decoy.x, decoy.y
            scenario("decoy-redirect", function() Render.draw(wo, w, h, best) end)
            wo.decoys = {}
            foundEnemy.state, foundEnemy.decoyTarget = "search", nil
            scenario("lost-search", function() Render.draw(wo, w, h, best) end)
            foundEnemy.state = "chase"
        end
        -- 7 储能达标(达标横幅 + 溢出条)
        wo.energy = wo.energyNeed + 50
        wo:update(0.05, { moveX = 0, moveY = 0, pressed = {} })
        scenario("energy-ready", function() Render.draw(wo, w, h, best) end)
        -- 8 深层残骸在场
        wo.deepSpawnedRound = 0
        wo:spawnDeepWreck()
        scenario("deep-wreck", function() Render.draw(wo, w, h, best) end)
        -- 9 热度最高档
        wo.heat = Config.HEAT.max
        scenario("heat-max", function() Render.draw(wo, w, h, best) end)
        -- 10 重启读条
        wo.restartChannel = { t = Config.FORMAL.restartChannelTime * 0.5 }
        scenario("restart-channel-half", function() Render.draw(wo, w, h, best) end)
        wo.restartChannel = { t = Config.FORMAL.restartChannelTime * 0.95 }
        scenario("restart-channel-critical", function() Render.draw(wo, w, h, best) end)
        wo.restartChannel = nil
        -- 11 组件触发(重启后进入本层反猎 → 层结算 → 下一层)
        wo.modules.capacitor = true
        wo.energy = wo.energyNeed
        wo:doRestart()
        scenario("anti-hunt-window", function() Render.draw(wo, w, h, best) end)
        -- 反猎窗口结束 → 层结算 + 协议整备（正式独占界面）
        wo.antiHuntTimer = 0
        wo.antiHuntResolveTimer = nil
        wo:finishAntiHunt()
        scenario("layer-settlement-shop", function() Render.draw(wo, w, h, best) end)
        wo.checkpointReady = true
        scenario("layer-settlement-checkpoint-ready", function() Render.draw(wo, w, h, best) end)
        wo.checkpointReady = false
        -- 资源充足 / 资源不足 两种商店状态都要能画
        wo.wreckData, wo.coreCount = 9, 9
        scenario("shop-affordable", function() Render.draw(wo, w, h, best) end)
        wo.wreckData, wo.coreCount = 0, 0
        scenario("shop-insufficient", function() Render.draw(wo, w, h, best) end)
        -- 短屏必须走裁剪/滚动布局，固定底部按钮仍在屏内。
        scenario("shop-short-screen", function() Render.draw(wo, 360, 560, best) end)
        local RunShop = require "RunShop"
        RunShop.scrollBy(wo, 180, 360, 560)
        scenario("shop-short-screen-scrolled", function() Render.draw(wo, 360, 560, best) end)
        -- 满级状态
        wo.wreckData = 99
        for _ = 1, 3 do wo:buyRunUpgrade("collapseCooldownLevel") end
        scenario("shop-maxed", function() Render.draw(wo, w, h, best) end)

        -- 047：L11入场的强制超限三选一，以及写盘失败后的可恢复底部动作。
        local endless = World.New({ experiment = "B", seed = 47011,
            startLayer = 11, runId = "smoke-endless-047", endless = true,
            endlessSeed = 47047, testMode = true, skipLayerIntro = false })
        EndlessOverclock.prepareStarterChoice(endless)
        scenario("endless-l11-starter-overclock-choice", function()
            Render.draw(endless, w, h, best)
        end)
        EndlessOverclock.applyChoice(endless, 1)
        endless.phase = "overload"
        endless:forceDrop()
        endless.energy = endless.energyNeed
        endless:doRestart()
        if endless.phase == "anti_hunt" then
            endless.antiHuntTimer = 0
            endless.antiHuntResolveTimer = nil
            endless:finishAntiHunt()
        end
        endless.endlessCheckpointSaveFailed = true
        scenario("endless-settlement-save-failure-actions", function()
            Render.draw(endless, w, h, best)
        end)

        wo:advanceLayer()
        scenario("module-active", function() Render.draw(wo, w, h, best) end)
        -- 12 标记引爆特效
        wo:addFx("bigring", { x = wo.player.x, y = wo.player.y, r = 240, color = "yellow", dur = 0.8 })
        wo:addFx("banner", { text = "标记引爆!+2s", dur = 1.8 })
        scenario("mark-trigger", function() Render.draw(wo, w, h, best) end)
        -- 反猎三档必须消费真实奖励值形成递增线绘层级。
        for _, reward in ipairs({ 500, 1000, 2000 }) do
            wo:addFx("anti_hunt_burst", {
                x = wo.player.x + reward / 40, y = wo.player.y, reward = reward, dur = 0.72,
            })
        end
        scenario("anti-hunt-levels", function() Render.draw(wo, w, h, best) end)
        -- 减闪/减震保留全部信息层，但降低脉冲、扫描与震动强度。
        local normalSettings = best.settings
        local reduced = { sound = true, reduceFx = true, reduceShake = true }
        Render.setSettings(reduced)
        scenario("reduced-fx-shake", function() Render.draw(wo, w, h, best) end)
        Render.setSettings(normalSettings)
        -- 13 死亡结算
        wo.player.hp = 1
        wo:damagePlayer(9999, 0, 0)
        scenario("dead-settle", function() Render.draw(wo, w, h, best) end)
        wo.challengeCheckpointAvailable = true
        scenario("dead-challenge-retry", function() Render.draw(wo, w, h, best) end)
        wo.reviveOffer = true
        scenario("dead-challenge-ad-and-free-retry", function() Render.draw(wo, w, h, best) end)
        wo.reviveOffer = false
        wo.rewardedReviveState = "pending"
        scenario("dead-ad-pending", function() Render.draw(wo, w, h, best) end)
        wo.rewardedReviveSoftTimeout = true
        scenario("dead-ad-soft-timeout", function() Render.draw(wo, w, h, best) end)
        wo.rewardedReviveSoftTimeout = false
        wo.rewardedReviveState = "settlement"
        wo.challengeCheckpointAvailable = false
        scenario("resume-gate", function()
            Render.draw(wo, w, h, best)
            Render.drawResumeGate(w, h)
        end)
        -- 正式渲染不得因QA模块状态而出现调试UI
        DebugPanel.open = true
        scenario("debug-disabled", function() Render.draw(wo, w, h, best) end)
        DebugPanel.open = false

        -- 第4层只展示地图B扫描；第5层再单独展示猎杀标记。
        -- 新时间线：重启 → 本层反猎 → 层结算 → 整备确认后才推进层数。
        local function advanceOneLayer(world)
            world.energy = world.energyNeed
            world:doRestart()
            if world.phase == "anti_hunt" then
                world.antiHuntTimer = 0
                world.antiHuntResolveTimer = nil
                world:finishAntiHunt()
            end
            if world.phase == "layer_settlement" then
                if world.layerSettlement and world.layerSettlement.runComplete then
                    world:chooseEndless()
                else
                    world:advanceLayer()
                end
            end
        end

        local core = World.New({ experiment = "B", seed = 8,
            testMode = true, skipLayerIntro = true })
        for _ = 1, 3 do
            core:forceDrop()
            advanceOneLayer(core)
        end
        core:forceDrop()
        core.scan.state = "active"
        core.scan.zone = core.map.scanZones[1]
        scenario("layer4-firewall-core-scan-only", function() Render.draw(core, w, h, best) end)
        core.scanJammedLeft = Config.SCAN.jammerSuppressTime
        scenario("layer4-blackout-jammed-scan", function() Render.draw(core, w, h, best) end)
        core.scanJammedLeft = 0
        Render.setSettings({ sound = true, reduceFx = true, reduceShake = true })
        scenario("layer4-blackout-preview-reduced", function() Render.draw(core, w, h, best) end)
        Render.setSettings(best.settings)
        advanceOneLayer(core)
        core:forceDrop()
        local hunter = core.enemies[1]
        if hunter then hunter.hunter = true; hunter.hunterPulse = 0.5 end
        scenario("layer5-hunter-intro", function() Render.draw(core, w, h, best) end)

        local fullBlackout = World.New({ experiment = "B", seed = 4306,
            startLayer = 6, testMode = true, skipLayerIntro = true })
        fullBlackout:forceDrop()
        scenario("layer6-signal-blackout", function() Render.draw(fullBlackout, w, h, best) end)
        fullBlackout.reconLeft = Config.RECON.duration
        local decoy = {
            x = fullBlackout.player.x + 70, y = fullBlackout.player.y,
            left = Config.DEPLETED.decoyDuration, dead = false,
        }
        fullBlackout.decoys = { decoy }
        local trackedEnemy = fullBlackout.enemies[1]
        if trackedEnemy then
            trackedEnemy.decoyTarget = decoy
            trackedEnemy.x = fullBlackout.player.x + Config.SIGNAL_BLACKOUT.baseRadius + 120
            trackedEnemy.y = fullBlackout.player.y
            fullBlackout.mark = { ref = trackedEnemy, armed = false }
        end
        scenario("layer6-blackout-recon-mark-decoy", function()
            Render.draw(fullBlackout, w, h, best)
        end)
        fullBlackout.reconLeft = 0
        fullBlackout.reconAfterglowLeft = Config.RECON.afterglow
        scenario("layer6-blackout-recon-single-ring-afterglow", function()
            Render.draw(fullBlackout, w, h, best)
        end)

        -- 第10层通关选择界面（完成挑战 / 继续无尽）与完成挑战结算页
        local final = World.New({ experiment = "B", seed = 10,
            startLayer = Config.RUN.finalLayer, testMode = true, skipLayerIntro = true })
        final:forceDrop()
        scenario("layer10-fair-gate-blackout", function() Render.draw(final, w, h, best) end)
        Render.setSettings({ sound = true, reduceFx = true, reduceShake = true })
        scenario("layer10-fair-gate-blackout-reduced", function() Render.draw(final, w, h, best) end)
        Render.setSettings(best.settings)
        final.energy = final.energyNeed
        final:doRestart()
        if final.phase == "anti_hunt" then
            final.antiHuntTimer = 0
            final.antiHuntResolveTimer = nil
            final:finishAntiHunt()
        end
        scenario("layer10-run-complete-choice", function() Render.draw(final, w, h, best) end)
        final.challengeExitConfirm = true
        scenario("layer10-run-complete-confirmation", function() Render.draw(final, w, h, best) end)
        final.graduationArchiveOpen = true
        final.graduationAction = "endless"
        final.graduationArchiveSlots = best.graduationArchives
        scenario("layer10-graduation-slot-picker", function() Render.draw(final, w, h, best) end)
        final.graduationArchiveOpen = false
        final:completeChallenge()
        scenario("challenge-complete-settle", function() Render.draw(final, w, h, best) end)

        -- 非发布 Review 包：菜单覆盖标准、短屏和高屏；每个受控样本
        -- 都使用实际 World/LayerPlan 配置渲染，禁止用静态假图代替。
        scenario("review-menu-standard", function()
            ReviewAccess.drawMenu(fake, 390, 844)
        end)
        scenario("review-menu-short", function()
            ReviewAccess.drawMenu(fake, 360, 640)
        end)
        scenario("review-menu-tall", function()
            ReviewAccess.drawMenu(fake, 360, 840)
        end)

        for _, sample in ipairs(ReviewAccess.samples()) do
            local reviewWorld, reviewState = ReviewAccess.createWorld(sample.id)
            scenario("review-" .. sample.id, function()
                Render.draw(reviewWorld, w, h, best)
                ReviewAccess.drawWatermark(fake, w, h, reviewState)
            end)
        end
    end)

    restoreStubs(saved)
    -- 桩环境退出:标记 Render 需要真实重新 init(main 会再调 Render.init(vg))
    if not okAll then
        print("[SMOKE] harness error: " .. tostring(prepErr))
    end

    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        if r.pass then pass = pass + 1 else fail = fail + 1 end
    end
    if not okAll then fail = fail + 1 end
    print(string.format("[SMOKE] ===== done: %d pass / %d fail =====", pass, fail))
    return fail == 0, results
end

return RenderSmoke
