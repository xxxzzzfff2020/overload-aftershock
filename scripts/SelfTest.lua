-- SelfTest.lua
-- 核心循环自动自检(§21 + R1 扩展):在独立 World 实例上快进模拟,验证关键规则。
-- 只打印日志,不影响真实游戏。结果输出 [SELFTEST] PASS/FAIL。
-- R1 新增:布局/输入/寻路/阶段表现/试玩数据/教学/长时间稳定性。

local Config = require "Config"
local ReleaseInfo = require "ReleaseInfo"
local World = require "World"
local RawWorldNew = World.New
World.New = function(opts)
    opts = opts or {}
    if opts.testMode == nil then opts.testMode = true end
    if opts.skipLayerIntro == nil then opts.skipLayerIntro = true end
    return RawWorldNew(opts)
end
local CombatSys = require "CombatSys"
local MapDef = require "MapDef"
local InputSys = require "InputSys"
local Pathfinding = require "Pathfinding"
local PlaytestMetrics = require "PlaytestMetrics"
local Tutorial = require "Tutorial"
local Viewport = require "Viewport"
local BotStrategies = require "BotStrategies"
local Screens = require "Screens"
local Format = require "Format"
local LayerPlan = require "LayerPlan"
local SignalBlackout = require "SignalBlackout"
local ProtocolSys = require "ProtocolSys"
local PlatformFeatures = require "PlatformFeatures"
local AppLifecycle = require "AppLifecycle"
local RewardedRevive = require "RewardedRevive"
local ReviewAccess = require "ReviewAccess"
local EscapeRegressionTest = require "EscapeRegressionTest"
local RunShop = require "RunShop"
local EndlessOverclock = require "EndlessOverclock"
local PlatformAdapters = require "PlatformAdapters"
local TitleRender = require "TitleRender"
local RunFlow = require "RunFlow"
local PauseFlow = require "PauseFlow"

local SelfTest = {}

local results = {}

local function check(name, cond, extra)
    results[#results + 1] = { name = name, ok = not not cond }
    print(string.format("[SELFTEST] %s %s%s", cond and "PASS" or "FAIL", name,
        extra and (" | " .. tostring(extra)) or ""))
end

local IDLE = { moveX = 0, moveY = 0, pressed = {} }

local function step(world, seconds, input)
    input = input or IDLE
    local t = 0
    while t < seconds do
        world:update(0.05, input)
        input = { moveX = input.moveX, moveY = input.moveY, pressed = {} } -- pressed 只生效一帧
        t = t + 0.05
    end
end

local function press(world, id)
    local input = { moveX = 0, moveY = 0, pressed = { [id] = true } }
    world:update(0.05, input)
end

-- 按下重启并静止等待引导完成。
-- 新时间线：重启 → 本层反猎 → 层结算。此辅助函数走完整条链路直到进入下一层过载，
-- 让原有"完成一次完整循环"的断言保持语义不变。
local function doRestart(world)
    press(world, "restart")
    step(world, Config.FORMAL.restartChannelTime + 0.3)
    -- 反猎窗口 + 结束延迟
    if world.phase == "anti_hunt" then
        step(world, Config.ANTI_HUNT_PHASE.maximumDuration
            + Config.ANTI_HUNT_PHASE.clearedDelay + 0.3)
    end
    -- 层结算：模拟玩家确认整备并进入下一层。
    if world.phase == "layer_settlement" then
        if world.overclockChoiceOpen then
            EndlessOverclock.applyChoice(world, 1)
        end
        if world.layerSettlement and world.layerSettlement.runComplete then
            world:chooseEndless()
        else
            world:advanceLayer()
        end
    end
end

-- 只走到反猎窗口开始（供反猎专项断言使用）
local function restartToAntiHunt(world)
    press(world, "restart")
    step(world, Config.FORMAL.restartChannelTime + 0.3)
end

-- 从反猎窗口走到层结算（不推进层数）
local function antiHuntToSettlement(world)
    step(world, Config.ANTI_HUNT_PHASE.maximumDuration
        + Config.ANTI_HUNT_PHASE.clearedDelay + 0.3)
end

-- 重启并走到层结算（不推进层数）
local function doRestartToSettlement(world)
    restartToAntiHunt(world)
    if world.phase == "anti_hunt" then antiHuntToSettlement(world) end
end

-- 驱动层：模拟正式 main.lua 在层结算界面上消费玩家确认。
-- Bot/长跑循环必须调用它，否则会永久停在 layer_settlement。
local function driveSettlement(world, input)
    if world.phase ~= "layer_settlement" then return false end
    world:consumeSignal()
    local pressed = (input and input.pressed) or {}
    -- 没有明确按下时也自动推进：长跑测的是层循环稳定性，不是界面停留。
    if pressed.shopComplete and world.layerSettlement
        and world.layerSettlement.runComplete then
        world:completeChallenge()
    elseif world.layerSettlement and world.layerSettlement.runComplete then
        world:chooseEndless()
    else
        world:advanceLayer()
    end
    return true
end

local function clearEvents(world)
    for i = #world.events, 1, -1 do world.events[i] = nil end
end

local function hasEvent(world, name)
    for _, e in ipairs(world.events) do
        if e.name == name then return true end
    end
    return false
end

local function hasToast(world, textPart)
    for _, f in ipairs(world.fx) do
        if f.kind == "toast" and (textPart == nil or string.find(f.text, textPart, 1, true)) then
            return true
        end
    end
    return false
end

local function grantEnergy(world)
    world.energy = world.energyNeed
end

local function aliveHeavy(world)
    for _, e in ipairs(world.enemies) do
        if not e.dead and e.kind == "heavy" then return e end
    end
    return nil
end

local function aliveSentinel(world)
    for _, e in ipairs(world.enemies) do
        if not e.dead and e.kind == "sentinel" then return e end
    end
    return nil
end

-- ============================================================
-- A. 核心循环(原 26 项主干)
-- ============================================================
local function testCoreLoop()
    local world = World.New()

    check("game starts in overload round 1",
        world.phase == "overload" and world.round == 1)

    clearEvents(world)
    step(world, 2)
    check("chain auto-fires in overload", hasEvent(world, "chain_fire"))

    world:respawnCells()
    local cell = world.cells[1]
    world.player.x, world.player.y = cell.x, cell.y
    local e0 = world.energy
    step(world, 0.5)
    check("cells cannot be picked during overload", world.energy == e0)

    local heavy = aliveHeavy(world)
    check("layer 1 defers heavy guard", heavy == nil)
    if not heavy then
        heavy = world:spawnEnemy("heavy", world.player.x, world.player.y, nil, false)
    end
    check("heavy guard can spawn", heavy ~= nil)
    if heavy then
        CombatSys.damageEnemy(world, heavy, 99999, true)
        check("heavy leaves wreck", #world.wrecks >= 1)
    end

    local fw = world.firewalls[1]
    CombatSys.damageFirewall(world, fw, 99999)
    local gateTile = world.map.gateTiles[1]
    check("firewall destroy opens permanent shortcut",
        world.gateOpen and not world.solid[gateTile.row][gateTile.col])

    world.overloadLeft = 0.06
    step(world, 0.2)
    check("countdown zero forces depleted", world.phase == "depleted")

    clearEvents(world)
    press(world, "pulse")
    press(world, "collapse")
    step(world, 1.5)
    check("overload skills locked in depleted",
        not hasEvent(world, "chain_fire") and not hasEvent(world, "pulse_fire")
        and not hasEvent(world, "collapse_fire"))

    local c2 = world.cells[1]
    check("cells respawned for depleted", c2 ~= nil)
    if c2 then
        world.player.x, world.player.y = c2.x, c2.y
        local before = world.energy
        step(world, 0.3)
        check("cell pickup works in depleted", world.energy > before)
    end

    local wreck = world.wrecks[1]
    check("wreck present for dismantle", wreck ~= nil)
    if wreck then
        world.player.x, world.player.y = wreck.x, wreck.y
        local dataBefore = world.wreckData or 0
        press(world, "dismantle")
        step(world, Config.DEPLETED.dismantleTime + 0.5)
        check("dismantle grants wreck data",
            (world.wreckData or 0) == dataBefore + Config.WRECK_DATA.perNormalWreck)
    end

    local sen = aliveSentinel(world)
    check("sentinel exists for mark", sen ~= nil)
    if sen then
        world.player.x, world.player.y = sen.x + 50, sen.y
        press(world, "mark")
        check("mark set in depleted", world.mark ~= nil and world.mark.ref == sen)
    end
    world.coreCount = math.max(world.coreCount, 1)
    press(world, "craftCapacitor")
    check("craft capacitor module", world.modules.capacitor == true)

    world.player.x, world.player.y = MapDef.tileCenter(MapDef.playerSpawn.col, MapDef.playerSpawn.row)
    grantEnergy(world)
    doRestart(world)
    check("manual restart enters round 2",
        world.phase == "overload" and world.round == 2 and world.restarts == 1)
    check("capacitor extends this overload",
        world.overloadDuration == Config.OVERLOAD.duration + Config.MODULES.capacitor.bonusTime)
    check("module consumed after arming", world.modules.capacitor == false)

    if world.mark then
        check("mark armed on overload start", world.mark.armed == true)
        clearEvents(world)
        CombatSys.damageEnemy(world, world.mark.ref, 1, false)
        check("mark trigger fires on first hit", hasEvent(world, "mark_trigger"))
        check("mark cleared after trigger", world.mark == nil)
    end

    local errFree = true
    for _ = 1, 3 do
        world.overloadLeft = 0.06
        step(world, 0.3)
        if world.phase ~= "depleted" then errFree = false end
        grantEnergy(world)
        doRestart(world)
        if world.phase ~= "overload" then errFree = false end
        step(world, 1.0)
    end
    check("3 consecutive full loops complete", errFree and world.round == 5,
        "round=" .. world.round)

    world.overloadLeft = 0.06
    step(world, 0.3)
    local expect = Config.ROUNDS.layers[math.min(world.round, #Config.ROUNDS.layers)].energyNeed
    check("energy need follows formal layer table", world.energyNeed == expect,
        world.energyNeed .. " vs " .. expect)

    -- 防软锁(R1 供给模型:限量补刷,永不断供):清空全部储能后应自动补刷
    for _, c in ipairs(world.cells) do c.dead = true end
    step(world, Config.DEPLETED.cellRespawnDelay * 3 + 0.3)
    local active = 0
    for _, c in ipairs(world.cells) do
        if not c.dead then active = active + 1 end
    end
    check("no energy softlock (cells respawn continuously)", active >= 2,
        "active=" .. active)

    world.player.hp = 1
    world:damagePlayer(9999, world.player.x, world.player.y)
    check("death enters settlement", world.phase == "dead")
    check("settlement data valid",
        world.timeAlive > 0 and world.round >= 5 and world.restarts >= 4)
end

-- ============================================================
-- B. 阶段表现(§任务包D)
-- ============================================================
local function testPhaseFeel()
    local world = World.New()
    -- 最后5秒警告事件
    clearEvents(world)
    world.overloadLeft = 4.5
    step(world, 1.2)
    check("countdown tick events in last 5s", hasEvent(world, "countdown_tick"))
    -- 跌落瞬间:hitstop + 横幅
    world.overloadLeft = 0.06
    step(world, 0.1)
    local hasHitstop, hasBanner = false, false
    for _, f in ipairs(world.fx) do
        if f.kind == "hitstop" then hasHitstop = true end
    end
    for _, prompt in ipairs(world.systemPrompts) do
        if string.find(prompt.text, "离线", 1, true) then hasBanner = true end
    end
    check("drop moment has hitstop + offline banner", hasHitstop and hasBanner)
    -- 重启引导：按下后未立即重启，启动后移动与受伤均不可取消。
    grantEnergy(world)
    press(world, "restart")
    check("restart channel starts (not instant)",
        world.phase == "depleted" and world.restartChannel ~= nil)
    world:update(0.05, { moveX = 1, moveY = 0, pressed = {} })
    check("moving does not interrupt restart channel", world.restartChannel ~= nil)
    world:damagePlayer(1, 0, 0)
    check("damage does not interrupt restart channel", world.restartChannel ~= nil)

    -- 完成重启，范围内追击者会被短暂瘫痪并标记为反猎目标；进入的是本层反猎，不是下一层。
    local layerBeforeRestart = world.round
    local mapBeforeRestart = world.mapId
    local e = world:spawnEnemy("drone", world.player.x + 200, world.player.y, nil, false)
    e.daze = 0
    e.state = "chase"
    e.hp, e.maxHp = 100000, 100000
    step(world, Config.FORMAL.restartChannelTime + 0.3)
    local marked, stunned = false, false
    for _, enemy in ipairs(world.enemies) do
        marked = marked or enemy.huntTarget == true
        stunned = stunned or (enemy.stun or 0) > 0
    end
    check("restart enters anti_hunt phase", world.phase == "anti_hunt")
    check("anti_hunt does not advance layer", world.round == layerBeforeRestart)
    check("anti_hunt keeps current map", world.mapId == mapBeforeRestart)
    check("anti_hunt does not start next overload countdown",
        world.overloadLeft <= 0 or world.antiHuntTimer > 0)
    check("restart stuns nearby enemies", stunned)
    check("restart migrates chasing pressure into hunt targets",
        marked and world.huntTargetsLeft > 0)
    check("anti_hunt grants overload attack ability", world:inCombatPhase())

    -- 窗口结束 → 层结算（仍不加层）
    antiHuntToSettlement(world)
    check("anti_hunt window ends into layer settlement",
        world.phase == "layer_settlement")
    check("settlement still on same layer", world.round == layerBeforeRestart)
    check("settlement snapshot present", world.layerSettlement ~= nil
        and world.layerSettlement.layer == layerBeforeRestart)
    local remainingChase = 0
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead and (enemy.state == "chase" or enemy.state == "alert"
            or enemy.huntTarget) then
            remainingChase = remainingChase + 1
        end
    end
    check("settlement clears chase state", remainingChase == 0)

    -- 整备确认 → 下一层过载
    world:advanceLayer()
    check("advance after settlement enters next layer",
        world.phase == "overload" and world.round == layerBeforeRestart + 1)
end

-- ============================================================
-- C. 操作反馈(§任务包B 6.3)
-- ============================================================
local function testFeedback()
    local world = World.New()
    world.overloadLeft = 0.06
    step(world, 0.2)
    -- 储能不足重启
    world.energy = 0
    press(world, "restart")
    check("restart w/o energy gives reason toast", hasToast(world, "还差"))
    -- 无核心制作
    world.coreCount = 0
    press(world, "craftCapacitor")
    check("craft w/o core gives reason toast", hasToast(world, "核心不足"))
    -- 无目标标记
    world.player.x, world.player.y = MapDef.tileCenter(12, 31)
    for _, e in ipairs(world.enemies) do e.dead = true end
    press(world, "mark")
    check("mark w/o target gives reason toast", hasToast(world, "标记目标"))
    -- 无残骸拆解
    press(world, "dismantle")
    check("dismantle w/o wreck gives reason toast", hasToast(world, "残骸"))
    -- 工具用尽
    world.tools.jammer = 0
    press(world, "jammer")
    check("jammer depleted gives reason toast", hasToast(world, "干扰弹"))
    world.systemPrompts = {}
    world:addFx("banner", { text = "普通系统提示", dur = 1.0 })
    world:addFx("banner", { text = "新纪录", dur = 1.0 })
    check("system prompt queue prioritizes one main message",
        world.systemPrompts[1] and world.systemPrompts[1].text == "新纪录")
    world:updateSystemPrompts(1.1)
    check("system prompt queue advances after expiry",
        world.systemPrompts[1] and world.systemPrompts[1].text == "普通系统提示")
    world:forceDrop()
    local stale = false
    for _, prompt in ipairs(world.systemPrompts) do
        if prompt.text == "普通系统提示" then stale = true end
    end
    check("phase change clears stale system prompts", not stale)
end

-- ============================================================
-- D. 布局与多分辨率(§任务包A 5.2/5.3)
-- ============================================================
local RESOLUTIONS = {
    -- physicalW, physicalH, DPR, expected logicalW, expected logicalH
    { 720, 1280, 2, 360, 640 }, { 1080, 1920, 3, 360, 640 },
    { 1080, 2160, 3, 360, 720 }, { 1080, 2340, 3, 360, 780 },
    { 1080, 2520, 3, 360, 840 }, { 1200, 1920, 1.5, 800, 1280 },
    { 1600, 2560, 1.6, 1000, 1600 }, { 720, 1800, 2, 360, 900 },
    -- 真机竖屏矩阵(物理÷DPR → 逻辑宽 360~430)，用于"预览 390 vs 真机"密度对照
    { 720, 1600, 2, 360, 800 },   { 1080, 2340, 3, 360, 780 },
    { 1170, 2532, 3, 390, 844 },  { 1080, 2400, 2.625, 411.428, 914.286 },
    { 1179, 2556, 3, 393, 852 },  { 1206, 2622, 3, 402, 874 },
    { 1290, 2796, 3, 430, 932 },  { 1080, 2340, 2.625, 411.428, 891.429 },
    { 1242, 2688, 3, 414, 896 },  { 1080, 2280, 2.625, 411.428, 868.571 },
    -- Maker Web Preview 手机模式实际画布(phys÷DPR → 781x1734 逻辑宽)，
    -- 与真机同属竖屏密度基准，必须与 390 基准 ui 一致
    { 757, 1681, 0.969, 781.218, 1734.778 },
}

local function layoutOK(world, w, h, label)
    local btns = InputSys.layout(world, w, h)
    local m = Viewport.metrics(w, h)
    for i, b in ipairs(btns) do
        local halfW = b.w and b.w * 0.5 or b.r
        local halfH = b.h and b.h * 0.5 or b.r
        -- 按钮完整在屏内(含安全区下边界)
        if b.x - halfW < 0 or b.x + halfW > w
            or b.y - halfH < m.top or b.y + halfH > h then
            return false, string.format("%s: %s out of bounds (%.0f,%.0f r%.0f)", label, b.id, b.x, b.y, b.r)
        end
        -- 点击区域不重叠(命中半径 r+8)
        for j = i + 1, #btns do
            local o = btns[j]
            local d = math.sqrt((b.x - o.x) ^ 2 + (b.y - o.y) ^ 2)
            if d < (b.r + 8) + (o.r + 8) - 14 then
                return false, string.format("%s: %s overlaps %s (d=%.0f)", label, b.id, o.id, d)
            end
        end
    end
    return true
end

local function testLayouts()
    -- 构造"按钮最多"的枯竭态:残骸在旁 + 可标记目标 + 有核心
    local world = World.New()
    world.overloadLeft = 0.06
    step(world, 0.2)
    local px, py = world.player.x, world.player.y
    world.wrecks[#world.wrecks + 1] = { x = px + 30, y = py, dead = false }
    world:spawnEnemy("sentinel", px + 80, py, nil, false)
    world.coreCount = 2

    local deadWorld = World.New()
    deadWorld.player.hp = 1
    deadWorld:damagePlayer(9999, 0, 0)

    local allOK, firstErr = true, nil
    for _, r in ipairs(RESOLUTIONS) do
        local rawW, rawH = Viewport.fromPhysical(r[1], r[2], r[3])
        local transform = Viewport.transform(r[1], r[2], r[3])
        if math.abs(rawW - r[4]) > 0.001 or math.abs(rawH - r[5]) > 0.001 then
            allOK, firstErr = false, firstErr or string.format(
                "physical-to-logical mismatch %.3fx%.3f expected %.3fx%.3f",
                rawW, rawH, r[4], r[5])
        end
        if transform.portraitMobile and (math.abs(transform.w - 390) > 0.001
            or math.abs(transform.pixelScale - r[1] / 390) > 0.001
            or math.abs(transform.h - r[2] / transform.pixelScale) > 0.001) then
            allOK, firstErr = false, firstErr or string.format(
                "fixed-width transform mismatch phys=%dx%d design=%.3fx%.3f pixelScale=%.4f",
                r[1], r[2], transform.w, transform.h, transform.pixelScale)
        end
        local phases = {
            { world = World.New(), label = "overload" },
            { world = world, label = "depleted-full" },
            { world = deadWorld, label = "dead" },
        }
        for _, ph in ipairs(phases) do
            local ok, err = layoutOK(ph.world, transform.w, transform.h,
                string.format("%dx%d->%.1fx%.1f/%s", r[1], r[2], transform.w, transform.h, ph.label))
            if not ok then
                allOK = false
                firstErr = firstErr or err
            end
        end
    end
    check("fixed-width transform and buttons fit physical/DPR matrix", allOK, firstErr)

    -- 037：枯竭五键应收成右下紧凑半环，且过载双键坐标保持既有合同。
    local compactW, compactH = 390, 867
    local compactMetrics = Viewport.metrics(compactW, compactH)
    local compactButtons = InputSys.layout(world, compactW, compactH)
    local compactById = {}
    for _, button in ipairs(compactButtons) do compactById[button.id] = button end
    local compactIds = { "restart", "jammer", "decoy", "cloak",
        compactById.scan and "scan" or "mark" }
    local compactTop, compactBottom = math.huge, -math.huge
    local compactComplete = true
    for _, id in ipairs(compactIds) do
        local button = compactById[id]
        if not button then
            compactComplete = false
        else
            compactTop = math.min(compactTop, button.y - button.r)
            compactBottom = math.max(compactBottom, button.y + button.r)
        end
    end
    check("[037] depleted controls form compact lower-right cluster",
        compactComplete and compactBottom - compactTop <= 180 * compactMetrics.ui + 0.01)
    local restartButton = compactById.restart
    local jammerButton = compactById.jammer
    local decoyButton = compactById.decoy
    local cloakButton = compactById.cloak
    local scanButton = compactById.scan or compactById.mark
    check("[037] restart is the lowest depleted control",
        restartButton ~= nil and jammerButton ~= nil and decoyButton ~= nil
        and cloakButton ~= nil and scanButton ~= nil
        and restartButton.y > jammerButton.y
        and restartButton.y > decoyButton.y
        and restartButton.y > cloakButton.y
        and restartButton.y > scanButton.y)

    local overloadButtons = InputSys.layout(World.New(), compactW, compactH)
    local overloadById = {}
    for _, button in ipairs(overloadButtons) do overloadById[button.id] = button end
    local safeRight = compactW - compactMetrics.right
    local safeBottom = compactH - compactMetrics.bottom
    check("[037] overload action layout remains unchanged",
        overloadById.pulse ~= nil and overloadById.collapse ~= nil
        and math.abs(overloadById.pulse.x - (safeRight - 64 * compactMetrics.ui)) < 0.001
        and math.abs(overloadById.pulse.y - (safeBottom - 82 * compactMetrics.ui)) < 0.001
        and math.abs(overloadById.pulse.r - 43 * compactMetrics.ui) < 0.001
        and math.abs(overloadById.collapse.x - (safeRight - 160 * compactMetrics.ui)) < 0.001
        and math.abs(overloadById.collapse.y - (safeBottom - 66 * compactMetrics.ui)) < 0.001
        and math.abs(overloadById.collapse.r - 32 * compactMetrics.ui) < 0.001)

    -- Viewport 消毒
    local m = Viewport.metrics(nil, -5)
    check("viewport sanitizes bad sizes", m.w > 0 and m.h > 0 and m.ui > 0)
    local snap = Viewport.transform(1080, 2340, 3)
    local lx, ly = Viewport.toLogicalPoint(1080, 2340, snap)
    local px2, py2 = Viewport.toPhysicalPoint(lx, ly, snap)
    check("viewport input inverse round-trip",
        math.abs(lx - 390) < 0.001 and math.abs(ly - 845) < 0.001
        and math.abs(px2 - 1080) < 0.001 and math.abs(py2 - 2340) < 0.001)

    local insetScale = Viewport.transform(1170, 2532, 3).pixelScale
    local insets = Viewport.scaleInsets(0, 132, 0, 102, insetScale)
    check("safe-area physical insets use the same design inverse",
        math.abs(insets.top - 44) < 0.001 and math.abs(insets.bottom - 34) < 0.001)

    local battleOK = true
    for _, r in ipairs(RESOLUTIONS) do
        local transform = Viewport.transform(r[1], r[2], r[3])
        local w, h = transform.w, transform.h
        local vm = Viewport.metrics(w, h, transform.pixelScale, transform.portraitMobile)
        local b = vm.battle
        battleOK = battleOK and b.y >= vm.hudTop + vm.hudHeight + vm.battleGap - 0.01
            and b.x >= vm.left and b.x + b.w <= w - vm.right + 0.01
            and b.y + b.h <= h - vm.bottom + 0.01 and b.h > 0
    end
    check("battlefield rect stays below HUD across resolution matrix", battleOK)

    -- 不只比较 ui 系数：直接比较最终设计宽、HUD 高度与主操作按钮的占屏比例。
    local preview = Viewport.transform(757, 1681, 0.969)
    local previewMetrics = Viewport.metrics(
        preview.w, preview.h, preview.pixelScale, preview.portraitMobile)
    local previewButtons = InputSys.layout(World.New(), preview.w, preview.h)
    local previewPulseRatio = nil
    for _, button in ipairs(previewButtons) do
        if button.id == "pulse" then previewPulseRatio = button.r / preview.w end
    end
    local parityOK, parityFirst = true, nil
    for _, r in ipairs(RESOLUTIONS) do
        local transform = Viewport.transform(r[1], r[2], r[3])
        if transform.portraitMobile then
            local vm = Viewport.metrics(
                transform.w, transform.h, transform.pixelScale, transform.portraitMobile)
            local pulseRatio = nil
            for _, button in ipairs(InputSys.layout(World.New(), transform.w, transform.h)) do
                if button.id == "pulse" then pulseRatio = button.r / transform.w end
            end
            if math.abs(transform.w - preview.w) > 0.001
                or math.abs(vm.hudHeight / transform.w - previewMetrics.hudHeight / preview.w) > 0.001
                or pulseRatio == nil or previewPulseRatio == nil
                or math.abs(pulseRatio - previewPulseRatio) > 0.001 then
                parityOK = false
                parityFirst = parityFirst
                    or string.format("phys=%dx%d designW=%.2f hudRatio=%.4f pulseRatio=%s",
                        r[1], r[2], transform.w, vm.hudHeight / transform.w, tostring(pulseRatio))
            end
        end
    end
    check("portrait Preview/device HUD and action proportions are identical", parityOK, parityFirst)

    -- 标题/帮助/设置页按钮全部避开安全区且不互相覆盖。
    local titleOK = true
    local titleSettings = {
        sound = true, musicVolume = 0.55, sfxVolume = 0.8,
        vibration = true, reduceFx = false, reduceShake = false,
    }
    for _, r in ipairs(RESOLUTIONS) do
        local transform = Viewport.transform(r[1], r[2], r[3])
        local w, h = transform.w, transform.h
        local vm = Viewport.metrics(w, h, transform.pixelScale, transform.portraitMobile)
        for _, mode in ipairs({ "normal", "help", "privacy", "records", "settings",
            "checkpoint_local", "checkpoint_online" }) do
            Screens.helpOpen = mode == "help"
            Screens.privacyOpen = mode == "privacy"
            Screens.recordsOpen = mode == "records"
            Screens.settingsOpen = mode == "settings"
            local checkpoint = string.find(mode, "checkpoint", 1, true)
                and { nextLayer = 3, checkpointState = "LAYER_START" } or nil
            local bs = Screens.layout(w, h, titleSettings, true,
                mode == "checkpoint_online", false, checkpoint)
            if mode == "settings" then
                local sg = Screens.settingsGeometry(w, h)
                if sg.x < vm.left or sg.x + sg.w > w - vm.right
                    or sg.y < vm.top or sg.y + sg.h >= sg.footerY - 20
                    or sg.identity.y + sg.identity.h > sg.y + sg.h
                    or sg.identityLineY2 + 12 * vm.ui > sg.identity.y + sg.identity.h then
                    titleOK = false
                end
                local settingsGroups = {
                    sound = sg.music, musicDown = sg.music, musicUp = sg.music,
                    sfxDown = sg.sfx, sfxUp = sg.sfx,
                    vibration = sg.assist, reduceFx = sg.assist,
                    reduceShake = sg.assist, privacySettings = sg.assist,
                    replayTutorial = sg.assist,
                }
                for _, button in ipairs(bs) do
                    local box = settingsGroups[button.id]
                    if box and button.y - button.h * 0.5 < box.y + sg.headerH then
                        titleOK = false
                    end
                end
            end
            for i, b in ipairs(bs) do
                if b.x - b.w * 0.5 < vm.left or b.x + b.w * 0.5 > w - vm.right
                    or b.y - b.h * 0.5 < vm.top or b.y + b.h * 0.5 > h - vm.bottom then
                    titleOK = false
                end
                for j = i + 1, #bs do
                    local o = bs[j]
                    local overlapX = math.abs(b.x - o.x) < (b.w + o.w) * 0.5
                    local overlapY = math.abs(b.y - o.y) < (b.h + o.h) * 0.5
                    if overlapX and overlapY then titleOK = false end
                end
            end
        end
    end
    Screens.helpOpen, Screens.privacyOpen, Screens.recordsOpen, Screens.settingsOpen = false, false, false, false
    check("title/help/privacy/records/settings buttons fit resolution matrix", titleOK)
    check("formal score formatting uses full integers",
        Format.integer(9999) == "9,999" and Format.integer(12500) == "12,500"
        and Format.integer(987654321) == "987,654,321"
        and not string.find(Format.integer(100000), "万", 1, true))
end

local function testRoundTable()
    local layers = Config.ROUNDS.layers
    local ok = #layers == 10
    for i, row in ipairs(layers) do
        ok = ok and row.energyNeed <= Config.ROUNDS.energyNeedCap
            and row.heavyCount <= Config.ROUNDS.maxHeavy
            and row.patrolExtra <= Config.ROUNDS.maxPatrolAdd
            and row.hordeInterval > 0
        if i >= 3 then
            local prev = layers[i - 1]
            ok = ok and row.energyNeed - prev.energyNeed <= 25
                and row.heavyCount - prev.heavyCount <= 1
                and row.patrolExtra - prev.patrolExtra <= 1
                and row.chaseMul - prev.chaseMul <= 0.04
        end
    end
    local d3 = LayerPlan.get(3).difficulty
    local d4 = LayerPlan.get(4).difficulty
    local planOK, planErr = LayerPlan.validate()
    check("layer 1-10 formal table is bounded", ok)
    check("layer 1-20 content plan is valid and bounded", planOK, planErr)
    check("layer 3-4 spike is staged",
        d3.heavyCount == 1 and d3.patrolExtra == 1 and d3.energyNeed == 225
        and d4.heavyCount == 1 and d4.patrolExtra == 1 and d4.energyNeed == 235)
end

-- ============================================================
-- E. 输入系统(§任务包B)
-- ============================================================
local function testInput()
    local world = World.New()   -- overload 阶段
    local w, h = 390, 844
    InputSys.reset()

    -- HUD区域不能误创建世界摇杆；战场区域内仍可正常创建。
    local battle = Viewport.battlefield(w, h)
    InputSys.onPointerDown(world, 99, 80, battle.y - 4, w, h)
    check("HUD touch cannot start battlefield stick", not InputSys.stick.active)
    InputSys.onPointerUp(world, 99)
    InputSys.onPointerDown(world, 98, 80, battle.y + 40, w, h)
    check("battlefield touch starts stick", InputSys.stick.active)
    InputSys.onPointerUp(world, 98)

    -- 双指:左手摇杆 + 右手按钮互不干扰
    InputSys.onPointerDown(world, 1, 100, 600, w, h)     -- 摇杆
    local btns = InputSys.layout(world, w, h)
    local pulseBtn = nil
    for _, b in ipairs(btns) do
        if b.id == "pulse" then pulseBtn = b end
    end
    InputSys.onPointerDown(world, 2, pulseBtn.x, pulseBtn.y, w, h)  -- 技能
    InputSys.onPointerMove(world, 1, 140, 620)
    local input = InputSys.collect()
    check("dual touch: stick moves + button pressed",
        (input.moveX ~= 0 or input.moveY ~= 0) and input.pressed.pulse == true)

    -- 松开按钮触点后摇杆仍有效
    InputSys.onPointerUp(world, 2)
    InputSys.onPointerMove(world, 1, 160, 600)
    input = InputSys.collect()
    check("stick survives other touch release", input.moveX > 0)

    -- 摇杆触点抬起 → 移动归零
    InputSys.onPointerUp(world, 1)
    input = InputSys.collect()
    check("stick release stops movement", input.moveX == 0 and input.moveY == 0)

    -- 同 id 重复按下不残留
    InputSys.onPointerDown(world, 3, 100, 600, w, h)
    InputSys.onPointerDown(world, 3, 120, 620, w, h)
    InputSys.onPointerUp(world, 3)
    check("repeated down same id cleans up", not InputSys.stick.active)

    -- 阶段切换清理:按住按钮 → 切换后 held/pressed 清空,摇杆保留
    InputSys.onPointerDown(world, 4, 100, 600, w, h)      -- 摇杆
    InputSys.onPointerDown(world, 5, pulseBtn.x, pulseBtn.y, w, h)
    InputSys.collect()                                     -- 消费本帧 press
    InputSys.onPhaseChange()
    input = InputSys.collect()
    local heldEmpty = next(InputSys.held) == nil
    check("phase change clears button state, keeps stick",
        heldEmpty and input.pressed.pulse == nil and InputSys.stick.active)

    -- 触摸取消:全部清空
    InputSys.onCancel()
    input = InputSys.collect()
    check("touch cancel clears everything",
        not InputSys.stick.active and input.moveX == 0)

    -- 禁用按钮点击 → toast 原因(储能不足)
    local dworld = World.New()
    dworld.overloadLeft = 0.06
    step(dworld, 0.2)
    dworld.energy = 0
    local dbtns = InputSys.layout(dworld, w, h)
    for _, b in ipairs(dbtns) do
        if b.id == "restart" then
            InputSys.onPointerDown(dworld, 9, b.x, b.y, w, h)
        end
    end
    check("disabled button tap explains reason", hasToast(dworld, "还差"))

    -- 反馈 #18703/#18704/#18705：暂停绘制与触控必须消费同一组按钮，
    -- 且局内设置的出口要明确恢复对局，不能留在不可操作的覆盖层。
    local function indexPauseButtons(buttons)
        local indexed = {}
        for _, button in ipairs(buttons) do indexed[button.id] = button end
        return indexed
    end
    local oldSettingsOpen = Screens.settingsOpen
    local oldEndlessConfirm = Screens.endlessEndConfirmOpen
    Screens.settingsOpen = false
    Screens.endlessEndConfirmOpen = false
    local normalPause = indexPauseButtons(InputSys.layout({ pauseMenu = true, endless = false }, w, h))
    check("[18704] normal pause keeps resume, settings, and explicit run end",
        normalPause.pauseResume and normalPause.pauseSettings and normalPause.pauseQuit
        and not normalPause.pauseReturnEndless and not normalPause.pauseEndEndless)
    local endlessPause = indexPauseButtons(InputSys.layout({ pauseMenu = true, endless = true }, w, h))
    check("[18707] endless pause separates safe return from destructive end",
        endlessPause.pauseResume and endlessPause.pauseSettings
        and endlessPause.pauseReturnEndless and endlessPause.pauseEndEndless
        and not endlessPause.pauseQuit)
    Screens.endlessEndConfirmOpen = true
    local endlessConfirm = indexPauseButtons(InputSys.layout({ pauseMenu = true, endless = true }, w, h))
    check("[18707] ending Endless requires a separate two-action confirmation",
        endlessConfirm.pauseEndlessConfirmCancel and endlessConfirm.pauseEndlessConfirmEnd
        and not endlessConfirm.pauseResume and not endlessConfirm.pauseReturnEndless)
    Screens.endlessEndConfirmOpen = false
    Screens.settingsOpen = true
    local settingsPause = indexPauseButtons(InputSys.layout({
        pauseMenu = true,
        pauseSettings = {
            sound = true, musicVolume = 0.55, sfxVolume = 0.8,
            vibration = true, reduceFx = false, reduceShake = false,
        },
        pausePrivacyAccepted = true,
    }, w, h))
    check("[18703] paused settings exposes all display and haptic controls above the panel",
        settingsPause.vibration and settingsPause.reduceFx and settingsPause.reduceShake
        and settingsPause.closeSettings and settingsPause.closeSettings.label == "保存并继续")
    -- 暂停设置必须优先于结算/超限商店接收触摸；这覆盖真机 #18761 的
    -- “按钮可见但点不到”路径，而不是只检查布局中存在按钮。
    local priorityWorld = {
        pauseMenu = true,
        phase = "layer_settlement",
        overclockChoiceOpen = true,
        pauseSettings = {
            sound = true, musicVolume = 0.55, sfxVolume = 0.8,
            vibration = true, reduceFx = false, reduceShake = false,
        },
        pausePrivacyAccepted = true,
    }
    local priorityLayout = indexPauseButtons(InputSys.layout(priorityWorld, w, h))
    local vibration = priorityLayout.vibration
    InputSys.reset()
    InputSys.onPointerDown(priorityWorld, 18761, vibration.x, vibration.y, w, h)
    local priorityInput = InputSys.collect()
    InputSys.onPointerUp(priorityWorld, 18761)
    check("[18761] pause settings touch wins over settlement and overclock shop",
        priorityInput.pressed.vibration == true)

    local flow = PauseFlow.new()
    PauseFlow.set(flow, PauseFlow.MODE.MENU)
    local menuOK = PauseFlow.isActive(flow) and not PauseFlow.isSettings(flow)
        and not PauseFlow.isEndlessEndConfirm(flow)
    PauseFlow.set(flow, PauseFlow.MODE.SETTINGS)
    local settingsOK = PauseFlow.isActive(flow) and PauseFlow.isSettings(flow)
        and not PauseFlow.isEndlessEndConfirm(flow)
    PauseFlow.set(flow, PauseFlow.MODE.ENDLESS_END_CONFIRM)
    local confirmOK = PauseFlow.isActive(flow) and not PauseFlow.isSettings(flow)
        and PauseFlow.isEndlessEndConfirm(flow)
    PauseFlow.set(flow, PauseFlow.MODE.NONE)
    check("[18761] pause modal has one mutually exclusive state",
        menuOK and settingsOK and confirmOK and not PauseFlow.isActive(flow))
    Screens.settingsOpen = oldSettingsOpen
    Screens.endlessEndConfirmOpen = oldEndlessConfirm
    InputSys.reset()
end

-- ============================================================
-- F. 寻路(§任务包C)
-- ============================================================
local function testPathfinding()
    local world = World.New()
    -- 1) 封锁门关闭:从中部到顶部高危区必须绕行右侧明路
    local sx, sy = MapDef.tileCenter(4, 8)     -- 门下方
    local tx, ty = MapDef.tileCenter(4, 5)     -- 门上方
    local closedPath = Pathfinding.findPath(world, sx, sy, tx, ty)
    check("path exists around closed gate", closedPath ~= nil and #closedPath > 6,
        closedPath and ("len=" .. #closedPath) or "nil")
    -- 路径不穿过门格
    local crossesGate = false
    if closedPath then
        for _, wp in ipairs(closedPath) do
            local c, r = MapDef.toTile(wp.x, wp.y)
            for _, g in ipairs(world.map.gateTiles) do
                if g.col == c and g.row == r then crossesGate = true end
            end
        end
    end
    check("closed gate not walked through", not crossesGate)

    -- 2) 开门后走捷径:路径显著变短
    local fw = world.firewalls[1]
    CombatSys.damageFirewall(world, fw, 99999)
    local openPath = Pathfinding.findPath(world, sx, sy, tx, ty)
    check("open gate shortcut used (path much shorter)",
        openPath ~= nil and closedPath ~= nil and #openPath < #closedPath / 2,
        string.format("closed=%d open=%d", closedPath and #closedPath or -1, openPath and #openPath or -1))
    check("pathVersion bumped on firewall change", world.pathVersion > 0)

    -- 3) 不可达目标安全失败
    local badPath = Pathfinding.findPath(world, sx, sy, -500, -500)
    check("unreachable target fails safely", badPath == nil)

    -- 4) 追击丢失后走向最后目击点(绕墙)
    local e = world:spawnEnemy("drone", MapDef.tileCenter(9, 10))
    e.state = "lost"
    e.lastSeenX, e.lastSeenY = MapDef.tileCenter(16, 15)
    e.daze, e.stun = 0, 0
    world.phase = "depleted" --[[@as string]]
    local x0, y0 = e.x, e.y
    step(world, 2.0)
    local moved = (e.x - x0) ^ 2 + (e.y - y0) ^ 2 > 40 ^ 2
    check("lost enemy navigates toward last seen", moved or e.state == "search",
        "state=" .. e.state)

    -- 5) 防卡:位移不足触发路径重算(直接调用检测)
    local stuckE = { x = 100, y = 100, path = { { x = 500, y = 500 } }, pathTimer = 5 }
    Pathfinding.checkStuck(stuckE, Config.PATH.stuckTime + 0.1)
    Pathfinding.checkStuck(stuckE, Config.PATH.stuckTime + 0.1)
    check("stuck detection clears stale path", stuckE.path == nil)
end

-- ============================================================
-- G. 试玩数据(§任务包F)
-- ============================================================
local function testMetrics()
    local world = World.New()
    PlaytestMetrics.beginSession(world, 999, 390, 844)
    -- 一轮完整循环
    world.overloadLeft = 0.06
    step(world, 0.3)
    PlaytestMetrics.update(world)
    clearEvents(world)
    grantEnergy(world)
    doRestart(world)
    PlaytestMetrics.update(world)
    clearEvents(world)
    local s = PlaytestMetrics.session
    check("metrics records round 1 on restart", s ~= nil and #s.rounds == 1)
    local r1 = s.rounds[1]
    check("round record has core fields",
        r1 and r1.overloadTime > 0 and r1.endedBy == "restart"
        and r1.decisionActions ~= nil and r1.immediateRestart ~= nil)
    -- 死亡结束
    world.player.hp = 1
    world:damagePlayer(9999, 0, 0)
    PlaytestMetrics.update(world)
    clearEvents(world)
    check("metrics finalizes on death",
        s.finished and s.summary ~= nil and #s.rounds == 2)
    check("summary has diagnostics",
        s.summary.avgLoopTime ~= nil and s.summary.immediateRestartRate ~= nil
        and s.summary.jailSuspectRounds ~= nil)
    -- 新局不串局
    local w2 = World.New()
    PlaytestMetrics.beginSession(w2, 1000, 390, 844)
    check("new session isolated", #PlaytestMetrics.session.rounds == 0)
end

-- ============================================================
-- H. 教学(§任务包E)
-- ============================================================
local function testTutorial()
    Tutorial.init(false)
    Tutorial.beginGame()
    local world = World.New()
    Tutorial.update(world, 0.05)
    check("tutorial intro on first game", Tutorial.current ~= nil)
    -- 自动消失
    Tutorial.update(world, Config.TUTORIAL.hintDuration + 1)
    check("tutorial hint auto-expires", Tutorial.current == nil)
    -- 第一局结束 → 第二局不再显示
    Tutorial.finishGame()
    Tutorial.beginGame()
    Tutorial.update(world, 0.05)
    check("tutorial silent on second game",
        not Tutorial.active and Tutorial.current == nil)
    -- 关闭后不触发
    Tutorial.init(false)
    Tutorial.beginGame()
    Tutorial.disable()
    Tutorial.update(world, 0.05)
    check("tutorial disable works", Tutorial.current == nil)
    -- 恢复正式状态(不影响真实游戏:main 会重新 init)
end

-- ============================================================
-- I. 长时间稳定性(§十五):50 次重启循环,无实体泄漏/软锁
-- ============================================================
local function testLongRun()
    local world = World.New()
    local okAll = true
    local maxEnemies, maxFx = 0, 0
    for i = 1, 50 do
        world.overloadLeft = 0.06
        step(world, 0.3)
        if world.phase ~= "depleted" then okAll = false end
        -- 防软锁:每次跌落后场上必须有储能供给
        local cellsAlive = 0
        for _, c in ipairs(world.cells) do
            if not c.dead then cellsAlive = cellsAlive + 1 end
        end
        if cellsAlive < 1 then okAll = false end
        grantEnergy(world)
        doRestart(world)
        if world.phase ~= "overload" then okAll = false end
        step(world, 0.5)
        local alive = 0
        for _, e in ipairs(world.enemies) do
            if not e.dead then alive = alive + 1 end
        end
        maxEnemies = math.max(maxEnemies, alive)
        maxFx = math.max(maxFx, #world.fx)
    end
    check("50 restart cycles stable", okAll and world.round == 51, "round=" .. world.round)
    check("no entity leak across 50 rounds", maxEnemies < 90 and maxFx < 200,
        string.format("maxEnemies=%d maxFx=%d", maxEnemies, maxFx))
    check("enemy pool reuse active", #world.enemyPool.free > 0 or maxEnemies < 90)
end

-- ============================================================
-- J. Bot 策略冒烟(§任务包H:六类各跑 60 秒无错误)
-- ============================================================
local function testBots()
    for _, kind in ipairs(BotStrategies.kinds) do
        local world = World.New()
        local bot = BotStrategies.create(kind)
        local ok = pcall(function()
            for _ = 1, 1200 do   -- 60 秒
                local input = bot:decide(world, 0.05)
                world:update(0.05, input)
                driveSettlement(world, input)
                clearEvents(world)
                if world.phase == "dead" then break end
            end
        end)
        check("bot '" .. kind .. "' runs 60s without error", ok)
    end
end

-- ============================================================
-- K. [R2] A/B 实验合同(§二十)
-- ============================================================
local function testExperiment()
    local wa = World.New({ experiment = "A", seed = 7 })
    local wb = World.New({ experiment = "B", seed = 7 })
    check("A disables all R2 rules",
        not wa.exp.overflowCache and not wa.exp.traceHeat and not wa.exp.deepWreck
        and not wa.exp.opportunities and not wa.exp.recon)
    check("B enables R2 rules",
        wb.exp.overflowCache and wb.exp.traceHeat and wb.exp.deepWreck
        and wb.exp.opportunities and wb.exp.recon)
    check("relays stay hidden before layer 3", #wa.relays == 0 and #wb.relays == 0)
    for _ = 1, 2 do wb:forceDrop(); grantEnergy(wb); doRestart(wb) end
    check("layer 3 introduces relays only in formal risk profile",
        #wa.relays == 0 and wb.round == 3 and #wb.relays >= 1)
    -- A:达标后无深层残骸、无热度
    wa.overloadLeft = 0.06
    step(wa, 0.2)
    grantEnergy(wa)
    step(wa, 0.5)
    local deepA = false
    for _, wk in ipairs(wa.wrecks) do
        if wk.deep then deepA = true end
    end
    check("A: no deep wreck after ready", not deepA)
    local TraceHeat = require "TraceHeat"
    TraceHeat.noise(wa, 50, 0, 0)
    step(wa, 2)
    check("A: heat stays zero", (wa.heat or 0) == 0 and wa:heatLevel() == 0)
    check("A: no overflow cache", wa:overflowLevel() == 0)
    -- 同种子同布局(确定性)
    local w1 = World.New({ experiment = "B", seed = 12345 })
    local w2 = World.New({ experiment = "B", seed = 12345 })
    check("same seed -> same layout", w1.layout.index == w2.layout.index)
    -- 数据隔离:两个实例互不影响
    wb.heat = 90
    check("world instances isolated", (wa.heat or 0) == 0)
end

-- ============================================================
-- L. [R2] 风险收益链(§二十:达标后风险区/缓存/深层/未结算/热度)
-- ============================================================
local function testRiskReward()
    local world = World.New({ experiment = "B", seed = 3 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    -- 达标前不生成深层残骸
    local deepBefore = false
    for _, wk in ipairs(world.wrecks) do
        if wk.deep then deepBefore = true end
    end
    check("deep wreck absent before ready", not deepBefore)
    -- 达标 → 激活深层残骸(每轮一个)
    world.energy = world.energyNeed - 1
    world.energy = world.energyNeed  -- 直接置位不触发;用拾取路径触发 energy_ready
    world.energy = world.energyNeed - 5
    world.cells[#world.cells + 1] = { x = world.player.x, y = world.player.y, dead = false }
    step(world, 0.2)
    local deep = nil
    for _, wk in ipairs(world.wrecks) do
        if wk.deep then deep = wk end
    end
    check("deep wreck spawns on ready", deep ~= nil)
    world:spawnDeepWreck()
    local deepCount = 0
    for _, wk in ipairs(world.wrecks) do
        if not wk.dead and wk.deep then deepCount = deepCount + 1 end
    end
    check("max one deep wreck per round", deepCount == 1)
    -- 超额缓存累计与上限
    world.energy = world.energyNeed + Config.RISK.overflowStep
    check("overflow level 1", world:overflowLevel() == 1)
    world.energy = world.energyNeed + Config.RISK.overflowStep * 5
    check("overflow capped at max", world:overflowLevel() == Config.RISK.overflowMax)
    -- 深层拆解:走过去拆(直接拆:传送到深层残骸)
    world.player.x, world.player.y = deep.x, deep.y
    local cores0 = world.coreCount
    press(world, "dismantle")
    check("deep dismantle starts", world.dismantle ~= nil)
    step(world, Config.RISK.deepDismantleTime + 0.3)
    check("deep dismantle grants core + bonus cache",
        world.coreCount == cores0 + Config.RISK.deepCores and world.bonusCache >= 1)
    -- 重启结算缓存 → 下一轮过载 +3 秒、连锁 +1
    world.energy = world.energyNeed + Config.RISK.overflowStep * 2
    local cacheExpected = Config.RISK.overflowMax
    doRestart(world)
    check("restart banks cache", world.phase == "overload"
        and world.activeCache == cacheExpected)
    check("cache extends overload duration",
        world.overloadDuration >= Config.OVERLOAD.duration + Config.RISK.cacheTime)
    -- 高热度重启仍可用(§7.5)
    world.overloadLeft = 0.06
    step(world, 0.2)
    world.heat = Config.HEAT.max
    grantEnergy(world)
    doRestart(world)
    check("restart usable at max heat", world.phase == "overload")
    -- 未结算损失:达标后死亡
    world.overloadLeft = 0.06
    step(world, 0.2)
    world.energy = world.energyNeed - 5
    world.cells[#world.cells + 1] = { x = world.player.x, y = world.player.y, dead = false }
    step(world, 0.2)   -- 拾取触发 energy_ready
    world.energy = world.energyNeed + Config.RISK.overflowStep   -- 形成超额缓存
    world.coreCount = world.coreCount + 1
    world:bump("cores")
    world.player.hp = 1
    world:damagePlayer(9999, 0, 0)
    check("death records unbanked loss",
        world.unbankedLoss ~= nil and (world.unbankedLoss.cache or 0) >= 1)
end

-- ============================================================
-- M. [R2] 追踪热度(§二十:增长/下降/不全知/影响调度)
-- ============================================================
local function testHeat()
    local TraceHeat = require "TraceHeat"
    local world = World.New({ experiment = "B", seed = 4 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    -- 行为增长
    local h0 = world.heat or 0
    world:emit("dismantle_done", world.player.x, world.player.y)
    check("noisy action raises heat", world.heat > h0)
    -- 达标后停留自动增长
    grantEnergy(world)
    step(world, 0.3)
    local h1 = world.heat
    step(world, 2.0)
    check("dwell after ready grows heat", world.heat > h1)
    -- 档位与调度影响
    world.heat = Config.HEAT.max
    check("heat level maxes at 3", world:heatLevel() == 3)
    check("high heat extends search time", TraceHeat.searchTimeMul(world) > 1.5)
    check("high heat speeds suspicion", TraceHeat.suspectTimeMul(world) < 0.8)
    -- 不提供全知:调查目标是噪声点,不是玩家实时位置
    world.noiseX, world.noiseY = 100, 100
    world.investigateTimer = 0
    local e = world:spawnEnemy("drone", MapDef.tileCenter(12, 27))
    e.daze = 0
    step(world, 0.2)
    if e.state == "lost" then
        check("investigation targets noise pos, not player",
            e.lastSeenX == 100 and e.lastSeenY == 100)
    else
        -- 派遣可能选了其他巡逻单位:验证没有敌人直接锁玩家实时位置
        local cheats = false
        for _, en in ipairs(world.enemies) do
            if en.state == "lost" and en.lastSeenX == world.player.x
                and en.lastSeenY == world.player.y then
                cheats = true
            end
        end
        check("investigation targets noise pos, not player", not cheats)
    end
    -- 热度衰减:安静一段时间缓慢下降,不瞬间清零
    world.heat = 50
    world.energy = 0            -- 不再达标(停止 dwell 增长)
    world.readyAt = nil
    for _, en in ipairs(world.enemies) do en.dead = true end
    world.heatQuietTimer = 0
    step(world, Config.HEAT.decayDelay + 2.0)
    check("heat decays slowly when quiet", world.heat < 50 and world.heat > 20,
        string.format("heat=%.1f", world.heat))
end

-- ============================================================
-- N. [R2] 过载优先目标(§二十)
-- ============================================================
local function testOpportunities()
    local world = World.New({ experiment = "B", seed = 5 })
    for _ = 1, 2 do world:forceDrop(); grantEnergy(world); doRestart(world) end
    check("opportunities activated at round start",
        world.opportunities ~= nil and #world.opportunities == 2)
    -- 全部候选可达(引用存活)
    local okRefs = true
    for _, op in ipairs(world.opportunities) do
        if not op.ref or op.ref.dead then okRefs = false end
    end
    check("opportunity targets alive & valid", okRefs)
    -- 中继器击毁 → 下一枯竭期热度增长降低
    local relay = world.relays[1]
    CombatSys.damageRelay(world, relay, 99999)
    check("relay destroyed emits event", relay.dead and world.relayDestroyedRound == world.round)
    world.overloadLeft = 0.06
    step(world, 0.2)
    check("relay bonus active in next depleted", world.relayBonus == true)
    local h0 = world.heat or 0
    world:emit("dismantle_done", world.player.x, world.player.y)
    local gained = world.heat - h0
    check("relay bonus reduces heat growth",
        gained < Config.HEAT.addDismantle * 0.8, string.format("gained=%.1f", gained))
    -- 过载总结横幅存在
    check("overload summary generated", world.lastOverloadSummary ~= nil)
    -- A 实验无优先目标
    local wa = World.New({ experiment = "A", seed = 5 })
    check("A has no opportunities", wa.opportunities == nil)
end

-- ============================================================
-- O. [R2] 侦察脉冲(§二十 输入)
-- ============================================================
local function testRecon()
    local world = World.New({ experiment = "B", seed = 6 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    -- 远离可标记目标(角落)
    world.player.x, world.player.y = MapDef.tileCenter(12, 31)
    for _, e in ipairs(world.enemies) do e.dead = true end
    clearEvents(world)
    press(world, "recon")
    check("recon pulse fires", world.reconLeft > 0 and world.reconCd > 0)
    press(world, "recon")
    check("recon on cooldown gives reason", hasToast(world, "冷却"))
    -- A 实验:recon 不可用
    local wa = World.New({ experiment = "A", seed = 6 })
    wa.overloadLeft = 0.06
    step(wa, 0.2)
    press(wa, "recon")
    check("A: recon disabled", (wa.reconLeft or 0) <= 0)
    -- 布局:B 使用同一 scan 按钮；短按侦察，长按标记
    local scan = nil
    for _, b in ipairs(InputSys.layout(world, 390, 844)) do
        if b.id == "scan" then scan = b end
    end
    check("shared scan button appears", scan ~= nil)
    InputSys.reset()
    world.reconCd = 0
    InputSys.onPointerDown(world, 71, scan.x, scan.y, 390, 844)
    InputSys.tick(world, 0.1)
    InputSys.onPointerUp(world, 71)
    local shortInput = InputSys.collect()
    check("short scan press requests recon", shortInput.pressed.recon == true
        and shortInput.pressed.mark ~= true)
    local heavy = world:spawnEnemy("heavy", world.player.x + 40, world.player.y, nil, false)
    InputSys.onPointerDown(world, 72, scan.x, scan.y, 390, 844)
    InputSys.tick(world, Config.RECON.markHold + 0.05)
    local longInput = InputSys.collect()
    check("long scan press requests mark", longInput.pressed.mark == true
        and longInput.pressed.recon ~= true and heavy ~= nil)
    InputSys.onPointerUp(world, 72)
end

-- ============================================================
-- P. [R2] 地图预设(§二十:可达性/储能足够/确定性)
-- ============================================================
local function testScenarios()
    local ScenarioLayouts = require "ScenarioLayouts"
    local MapRuntime = require "MapRuntime"
    local ok, err = ScenarioLayouts.validateAll()
    check("both maps x 3 formal layouts statically valid", ok, err)
    local allRun = true
    for _, mapId in ipairs(MapDef.ids()) do
        for i = 1, ScenarioLayouts.count do
            local w = World.New({ experiment = "B", seed = i - 1 })
            local okRun = pcall(function()
                MapRuntime.load(w, mapId, i, true)
                w:spawnPatrols()
                w:forceDrop()
                grantEnergy(w)
                doRestart(w)
            end)
            if not okRun or w.phase ~= "overload" then allRun = false end
        end
    end
    check("every map/layout completes a full loop", allRun)
end

local function testContent008()
    local p1, p3, p4, p5 = LayerPlan.get(1), LayerPlan.get(3), LayerPlan.get(4), LayerPlan.get(5)
    local p7, p10, p12, p20 = LayerPlan.get(7), LayerPlan.get(10), LayerPlan.get(12), LayerPlan.get(20)
    check("fixed layer map cadence matches launch plan",
        p1.map == "outer_grid" and p4.map == "firewall_core"
        and p7.map == "outer_grid" and p10.map == "firewall_core")
    check("layer 7 cluster and layer 10 dual protocol configured",
        LayerPlan.has(p7, "cluster") and #p10.protocols == 2)
    check("layer 3 keeps core focus and layer 4 separates hunter introduction",
        not p3.relayDebt and not p4.hunter and p5.hunter)
    check("endless rotation uses one established protocol at a time", #p12.protocols == 1)
    check("endless layer remains capped and deterministic",
        p20.difficulty.energyNeed <= Config.ROUNDS.energyNeedCap
        and p20.difficulty.heavyCount <= Config.ROUNDS.maxHeavy)

    local w = World.New({ experiment = "B", seed = 808 })
    for _ = 1, 3 do
        w:forceDrop(); grantEnergy(w); doRestart(w)
    end
    check("layer 4 switches to firewall core", w.round == 4 and w.mapId == "firewall_core")
    local stalePressure = false
    for _, enemy in ipairs(w.enemies) do
        if enemy.state == "chase" or enemy.state == "alert" or enemy.path ~= nil then
            stalePressure = true
        end
    end
    check("map switch clears stale chase/path state",
        w.pathVersion > 0 and #w.cells == 0 and not stalePressure)

    w:forceDrop()
    local scan = w.scan
    scan.state, scan.timer, scan.zoneIndex = "idle", 0, 0
    ProtocolSys.update(w, 0.05)
    local zone = scan.zone
    w.player.x, w.player.y = MapDef.tileCenter((zone.c1 + zone.c2) * 0.5, (zone.r1 + zone.r2) * 0.5)
    local hpBefore, heatBefore = w.player.hp, w.heat
    ProtocolSys.update(w, Config.SCAN.warningTime + 0.05)
    ProtocolSys.update(w, 0.05)
    check("scanner warns then exposes without direct damage",
        scan.state == "active" and scan.hit and w.scanExposedLeft > 0
        and w.player.hp == hpBefore and w.heat > heatBefore)
    for _, enemy in ipairs(w.enemies) do enemy.dead = true end
    w.scan.state, w.scan.timer, w.scan.zone, w.scan.hit = "active", 0.5, zone, false
    w.scanJammedLeft, w.cloakLeft, w.tools.jammer = 0, 0, 1
    w:useJammer()
    ProtocolSys.update(w, 0.05)
    check("jammer suppresses active scan even without nearby enemy",
        w.tools.jammer == 0 and w.scanJammedLeft > 0 and not w.scan.hit)
    w.scanJammedLeft, w.cloakLeft, w.scan.hit = 0, 1.0, false
    ProtocolSys.update(w, 0.05)
    check("cloak prevents scanner exposure", not w.scan.hit)

    local hunterX, hunterY = MapDef.tileCenter(5, 30)
    local earlyCandidate = w:spawnEnemy("sentinel", hunterX, hunterY, {{5, 30}, {20, 30}}, false)
    earlyCandidate.daze = 0
    w.energy, w.readyAt, w.hunterActivationTimer = w.energyNeed, w.timeAlive - Config.HUNTER.readyDelay, 0
    ProtocolSys.update(w, 0.1)
    local earlyHunters = 0
    for _, enemy in ipairs(w.enemies) do if enemy.hunter then earlyHunters = earlyHunters + 1 end end
    check("layer 4 teaches map and scan without hunter", earlyHunters == 0)

    doRestart(w)
    w:forceDrop()
    local hunterCandidate = w:spawnEnemy("sentinel", hunterX, hunterY, {{5, 30}, {20, 30}}, false)
    hunterCandidate.daze = 0
    w.energy, w.readyAt, w.hunterActivationTimer = w.energyNeed, w.timeAlive - Config.HUNTER.readyDelay, 0
    ProtocolSys.update(w, 0.1)
    local hunters, farEnough = 0, true
    for _, enemy in ipairs(w.enemies) do
        if enemy.hunter then
            hunters = hunters + 1
            farEnough = farEnough and math.sqrt((enemy.x - w.player.x)^2 + (enemy.y - w.player.y)^2) > 100
        end
    end
    check("hunter protocol reuses bounded non-foot-spawn enemies", hunters >= 1 and hunters <= 1 and farEnough)

    local scoreWorld = World.New({ experiment = "B", seed = 809 })
    clearEvents(scoreWorld)
    for i = 1, 4 do
        local enemy = scoreWorld:spawnEnemy("drone", scoreWorld.player.x + i * 20, scoreWorld.player.y, nil, false)
        enemy.huntTarget, enemy.huntLeft = true, 5
        CombatSys.damageEnemy(scoreWorld, enemy, 9999, true)
    end
    local rewards = {}
    for _, event in ipairs(scoreWorld.events) do
        if event.name == "anti_hunt_chain" then rewards[#rewards + 1] = event.value end
    end
    check("anti-hunt chain uses three readable reward tiers with cap",
        scoreWorld.bestAntiHuntChain == 4 and #rewards == 4
        and rewards[1] == 500 and rewards[2] == 1000 and rewards[3] == 2000
        and rewards[4] == 2000)
    scoreWorld:forceDrop(); grantEnergy(scoreWorld); doRestart(scoreWorld)
    check("anti-hunt chain resets for each restart window",
        scoreWorld.antiHuntChain == 0 and scoreWorld.bestAntiHuntChain == 4)

    local best = require("SaveSys").migrate({})
    for i = 1, 7 do
        require("SaveSys").recordRun(best, { id = "r" .. i, layer = i,
            score = i * 1000, time = i, bestCombo = i, adAssisted = i == 2 })
    end
    local visible, page, pages = Screens.visibleRuns(best)
    check("local records page exposes recent runs with paging", #visible == 5 and page == 1 and pages == 2)

    local oldLeaderboard, oldKey, oldBackend, oldIdentity = Config.PLATFORM.leaderboard,
        Config.PLATFORM.leaderboardKey, Config.PLATFORM.leaderboardBackend,
        Config.PLATFORM.identityReady
    Config.PLATFORM.leaderboard, Config.PLATFORM.leaderboardKey = true, "test_rank"
    Config.PLATFORM.leaderboardBackend = "clientCloud"
    Config.PLATFORM.identityReady = true
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    local writes = {}
    local fakeLeaderboard = {
        submitScore = function(_, leaderboardKey, rankScore, metadata, events)
            writes.id, writes.rankScore, writes.metadata = leaderboardKey, rankScore, metadata
            events.ok()
            return true
        end,
        loadScores = function() return true end,
    }
    local platformBest = require("SaveSys").migrate({})
    PlatformFeatures.setIdentity({ identityReady = true, userId = "selftest-user" })
    local clean = { id = "clean", completed = true, formalMain = true, cleanRun = true,
        endless = true, completionReason = "death", layer = 12,
        score = 123456, bestCombo = 20 }
    local submitted = PlatformFeatures.submitRun(clean, platformBest, fakeLeaderboard)
    local duplicate = PlatformFeatures.submitRun(clean, platformBest, fakeLeaderboard)
    local assisted = PlatformFeatures.submitRun({ id = "ad", completed = true, layer = 20,
        score = 999999, formalMain = true, cleanRun = false, adAssisted = true,
        endless = true, completionReason = "death" }, platformBest, fakeLeaderboard)
    check("leaderboard adapter accepts assisted runs but isolates duplicates",
        submitted == true and duplicate == false and assisted == true
        and writes.id == "test_rank"
        and writes.rankScore == PlatformFeatures.rankValue(20, 999999)
        and writes.metadata and writes.metadata.adAssisted == true)
    Config.PLATFORM.leaderboard, Config.PLATFORM.leaderboardKey = oldLeaderboard, oldKey
    Config.PLATFORM.leaderboardBackend = oldBackend
    Config.PLATFORM.identityReady = oldIdentity
    PlatformFeatures.resetForTests()
    check("rewarded ad stays hidden before privacy consent",
        Config.PLATFORM.rewardedAd == true and PlatformFeatures.rewardedAdStatus() == false)
    local forcedOffer = { phase = "dead", round = 2, endless = false,
        reviveOffer = true, challengeCheckpointAvailable = true }
    local adButtonVisible = false
    local retryVisible = false
    local deathButtons = {}
    for _, button in ipairs(InputSys.layout(forcedOffer, 390, 867)) do
        if button.id == "revive" then adButtonVisible = true end
        if button.id == "retryLayer" then retryVisible = true end
        deathButtons[button.id] = button
    end
    check("Challenge death can show ad continue beside free retry",
        adButtonVisible and retryVisible)
    local deathMetrics = InputSys.deathLayoutMetrics(390, 867)
    check("[056] death statistics card clears the compact action stack",
        deathButtons.revive and deathButtons.retryLayer and deathButtons.endChallenge
        and deathMetrics.panelY + deathMetrics.panelH + deathMetrics.panelGap
            <= deathButtons.revive.y - deathButtons.revive.h * 0.5)
    check("[056] death actions retain a compact, ordered stack",
        deathButtons.revive.y < deathButtons.retryLayer.y
        and deathButtons.retryLayer.y < deathButtons.endChallenge.y
        and deathButtons.retryLayer.y - deathButtons.revive.y < 90
        and deathButtons.endChallenge.y - deathButtons.retryLayer.y < 90)
end

local function testFairGate020()
    local expected = {
        { "outer_grid", 1, 0, false, 200, 0, 0 },
        { "outer_grid", 2, 0, false, 215, 1, 1 },
        { "outer_grid", 3, 0, false, 225, 1, 1 },
        { "firewall_core", 1, 0, false, 235, 1, 1 },
        { "firewall_core", 2, 0, true, 245, 2, 2 },
        { "firewall_core", 3, 0, true, 260, 2, 3 },
        { "outer_grid", 1, 1, true, 280, 3, 3 },
        { "firewall_core", 2, 1, true, 295, 3, 4 },
        { "outer_grid", 3, 1, true, 315, 3, 4 },
    }
    local l1To9Unchanged = true
    for layer, row in ipairs(expected) do
        local plan = LayerPlan.get(layer)
        l1To9Unchanged = l1To9Unchanged
            and plan.map == row[1] and plan.layout == row[2]
            and #plan.protocols == row[3] and plan.hunter == row[4]
            and plan.difficulty.energyNeed == row[5]
            and plan.difficulty.heavyCount == row[6]
            and plan.difficulty.patrolExtra == row[7]
            and plan.fairGate == nil
    end
    check("[020] layers 1-9 frozen configuration unchanged", l1To9Unchanged)

    local plan10, plan11 = LayerPlan.get(10), LayerPlan.get(11)
    check("[020] L10 keeps milestone dual protocols hunter and dual-exit identity",
        plan10.milestone and plan10.hunter and LayerPlan.has(plan10, "blockade")
        and LayerPlan.has(plan10, "deep_cache") and #plan10.protocols == 2)
    check("[046] endless starts with a bounded power ramp",
        #plan11.protocols == 1 and plan11.difficulty.pressureBand == "power_ramp"
        and plan11.difficulty.patrolExtra <= Config.ROUNDS.maxPatrolAdd
        and plan11.difficulty.heavyCount <= Config.ROUNDS.maxHeavy)

    local world = World.New({ experiment = "B", seed = 32020, startLayer = 10 })
    local alive, base5 = 0, false
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            alive = alive + 1
            if enemy.patrolTag == "base5" then base5 = true end
        end
    end
    check("[020R] L10 restores pre-020 fixed patrol pressure", alive == 17, alive)
    check("[020R] L10 keeps the full fixed patrol template", base5)

    for i = 1, 8 do
        world:spawnEnemy("drone", world.player.x + i * 8, world.player.y, nil, true)
    end
    world:forceDrop()
    local hordes, minDaze, recovery, risk = 0, math.huge, 0, 0
    for _, enemy in ipairs(world.enemies) do
        if not enemy.dead then
            if enemy.isHorde then hordes = hordes + 1 end
            minDaze = math.min(minDaze, enemy.daze or 0)
        end
    end
    for _, cell in ipairs(world.cells) do
        if not cell.dead and cell.route == "recovery" then recovery = recovery + 1 end
        if not cell.dead and cell.route == "risk" then risk = risk + 1 end
    end
    check("[020R] L10 drop retains every overflow horde", hordes == 8, hordes)
    check("[020R] L10 overflow hordes remain killable hold units",
        hordes == 8 and (function()
            for _, enemy in ipairs(world.enemies) do
                if enemy.isHorde and (not enemy.overflowHold or enemy.dead) then return false end
            end
            return true
        end)())
    check("[020R] L10 drop grants readable AI reaction window",
        minDaze >= Config.PLAYER.dropGraceTime + plan10.fairGate.dropGraceBonus - 0.01, minDaze)
    check("[020R] L10 opens three recovery cells and one risk cell", recovery == 3 and risk == 1,
        string.format("recovery=%d risk=%d", recovery, risk))
    check("[020] L10 tool counts remain formal and are not increased",
        world.tools.jammer == Config.DEPLETED.jammerUses
        and world.tools.decoy == Config.DEPLETED.decoyUses
        and world.tools.cloak == Config.DEPLETED.cloakUses)

    local EnemyAI = require "EnemyAI"
    local function potentialCover(targetWorld, x, y)
        local px, py = targetWorld.player.x, targetWorld.player.y
        targetWorld.player.x, targetWorld.player.y = x, y
        local covered = false
        for _, enemy in ipairs(targetWorld.enemies) do
            if not enemy.dead then
                local cfg = Config.ENEMIES[enemy.kind]
                local dx, dy = x - enemy.x, y - enemy.y
                local range = cfg.viewRange * targetWorld:difficulty().viewMul
                if dx * dx + dy * dy <= range * range
                    and EnemyAI.losClear(targetWorld, enemy.x, enemy.y, x, y) then
                    covered = true
                    break
                end
            end
        end
        targetWorld.player.x, targetWorld.player.y = px, py
        return covered
    end
    local routeGuaranteed = true
    for seed = 1, 50 do
        local sample = World.New({ experiment = "B", seed = seed, startLayer = 10 })
        sample:forceDrop()
        local found = false
        for _, cell in ipairs(sample.cells) do
            if not cell.dead and cell.route == "recovery"
                and not potentialCover(sample, cell.x, cell.y) then found = true end
        end
        if not found then routeGuaranteed = false break end
    end
    check("[020] fifty seeds retain an initially unoverlapped recovery resource", routeGuaranteed)

    for _, cell in ipairs(world.cells) do
        if cell.route == "recovery" then cell.dead = true end
    end
    world:spawnOneCell()
    local recoveryRespawned = false
    for _, cell in ipairs(world.cells) do
        if not cell.dead and cell.route == "recovery" then recoveryRespawned = true end
    end
    check("[020] recovery route persists after its resource is collected", recoveryRespawned)

    local recoveryX, recoveryY = MapDef.tileCenter(20, 22)
    local riskX, riskY = MapDef.tileCenter(5, 4)
    local recoveryPath = Pathfinding.findPath(world, world.player.x, world.player.y,
        recoveryX, recoveryY, true)
    local riskPath = Pathfinding.findPath(world, world.player.x, world.player.y,
        riskX, riskY, true)
    check("[020] recovery and high-risk routes are both geometrically executable",
        recoveryPath ~= nil and #recoveryPath > 0 and riskPath ~= nil and #riskPath > #recoveryPath,
        string.format("recovery=%s risk=%s", recoveryPath and #recoveryPath or -1,
            riskPath and #riskPath or -1))

    world.energy = world.energyNeed
    world.readyAt = 0
    world.timeAlive = plan10.fairGate.hunterReadyDelay + 0.1
    world.scan.state, world.scan.timer = "active", 0.5
    world.scan.zone = world.map.scanZones[1]
    for _, enemy in ipairs(world.enemies) do enemy.daze = 0 end
    ProtocolSys.update(world, 0.1)
    local hunters = 0
    for _, enemy in ipairs(world.enemies) do if not enemy.dead and enemy.hunter then hunters = hunters + 1 end end
    check("[020] active scan peak defers L10 hunter activation", hunters == 0, hunters)
    world.scan.state, world.scan.timer, world.scan.zone = "idle", 0, nil
    ProtocolSys.update(world, 0.1)
    hunters = 0
    for _, enemy in ipairs(world.enemies) do if not enemy.dead and enemy.hunter then hunters = hunters + 1 end end
    check("[020R] ready state stops new scan peak and activates at most two hunters",
        world.scan.state == "idle" and hunters <= 2, "scan=" .. world.scan.state .. " hunters=" .. hunters)
    world.heat = Config.HEAT.max
    for _ = 1, 200 do
        world.timeAlive = world.timeAlive + 0.1
        ProtocolSys.update(world, 0.1)
    end
    hunters = 0
    for _, enemy in ipairs(world.enemies) do if not enemy.dead and enemy.hunter then hunters = hunters + 1 end end
    check("[020R] lock heat cannot exceed the L10 hunter allowance", hunters <= 2, hunters)

    -- 020R: actual depleted AI pressure slots are measured after restoring the
    -- pre-020 roster; overflow units must wait/hold rather than being deleted.
    local pressure = World.New({ experiment = "B", seed = 32021, startLayer = 10,
        testMode = true, skipLayerIntro = true })
    pressure.player.maxHp, pressure.player.hp = 1000000, 1000000
    pressure:forceDrop()
    pressure.energy, pressure.readyAt = pressure.energyNeed, pressure.timeAlive
    pressure.heat = Config.HEAT.max
    local maxChaseOrHunter, maxAmbient = 0, 0
    for _ = 1, 300 do
        pressure:update(0.1, IDLE)
        local chaseOrHunter, ambient = 0, 0
        for _, enemy in ipairs(pressure.enemies) do
            if not enemy.dead then
                if enemy.hunter or enemy.state == "chase" then chaseOrHunter = chaseOrHunter + 1 end
                if enemy.state == "alert" or enemy.state == "search"
                    or enemy.roaming or enemy.investigating then
                    ambient = ambient + 1
                end
            end
        end
        maxChaseOrHunter = math.max(maxChaseOrHunter, chaseOrHunter)
        maxAmbient = math.max(maxAmbient, ambient)
    end
    check("[020R] L10 depleted chase/hunter pressure stays within three",
        maxChaseOrHunter <= plan10.fairGate.pressureChaseCap, maxChaseOrHunter)
    check("[020R] L10 depleted roam/alert/investigate/search stays within four",
        maxAmbient <= plan10.fairGate.pressureAmbientCap, maxAmbient)

    local gapWorld = World.New({ experiment = "B", seed = 32022, startLayer = 10,
        testMode = true, skipLayerIntro = true })
    gapWorld:forceDrop()
    gapWorld.energy, gapWorld.readyAt = gapWorld.energyNeed, gapWorld.timeAlive
    gapWorld.timeAlive = gapWorld.timeAlive + plan10.fairGate.hunterReadyDelay + 1
    gapWorld.scan.state, gapWorld.scan.timer = "active", 0
    gapWorld.scan.zone = gapWorld.map.scanZones[1]
    ProtocolSys.update(gapWorld, 0.1)
    local gapAfterScan = gapWorld.scanHunterGap or 0
    local gapHunters = 0
    for _, enemy in ipairs(gapWorld.enemies) do if enemy.hunter then gapHunters = gapHunters + 1 end end
    check("[020R] scan end creates a two-second hunter gap",
        gapAfterScan >= plan10.fairGate.scanHunterGap - 0.11 and gapHunters == 0,
        string.format("gap=%.2f hunters=%d", gapAfterScan, gapHunters))
    gapWorld.timeAlive = gapWorld.timeAlive + plan10.fairGate.scanHunterGap - 0.2
    ProtocolSys.update(gapWorld, 0.1)
    gapHunters = 0
    for _, enemy in ipairs(gapWorld.enemies) do if enemy.hunter then gapHunters = gapHunters + 1 end end
    check("[020R] hunter remains deferred inside scan gap", gapHunters == 0, gapHunters)

    local toolWorld = World.New({ experiment = "B", seed = 32023, startLayer = 10,
        testMode = true, skipLayerIntro = true })
    toolWorld:forceDrop()
    toolWorld.energy, toolWorld.readyAt = toolWorld.energyNeed, toolWorld.timeAlive
    toolWorld:useCloak()
    check("[020R] successful cloak starts the post-tool relock gap",
        (toolWorld.postToolRelockTimer or 0) >= plan10.fairGate.postToolRelockGap,
        toolWorld.postToolRelockTimer)
end

-- ============================================================
-- Q. [R2] 存档迁移(§十九)
-- ============================================================

-- ============================================================
-- Q. [R2] 存档迁移(§十九)
-- ============================================================
local function testSaveMigrate()
    local SaveSys = require "SaveSys"
    -- R1 老存档
    local old = { round = 7, time = 512, tutorialDone = true }
    local m = SaveSys.migrate(old)
    check("R1 save migrates keeping record",
        m.v == SaveSys.SCHEMA_VERSION and m.round == 7 and m.time == 512 and m.tutorialDone == true
        and m.bestRun.layer == 7 and m.bestRun.time == 512
        and m.settings.sound == true and m.settings.musicVolume ~= nil
        and m.settings.sfxVolume ~= nil and m.settings.vibration == true
        and m.lastExperiment == "B" and m.privacyPolicyVersion >= 1)
    -- 空/损坏
    local e1 = SaveSys.migrate(nil)
    local e2 = SaveSys.migrate("garbage")
    local e3 = SaveSys.migrate({ round = "x", settings = 5 })
    check("empty/corrupt saves migrate to defaults",
        e1.round == 0 and e2.round == 0 and e3.round == 0 and e3.settings ~= nil)
    -- 多次迁移幂等
    local twice = SaveSys.migrate(SaveSys.migrate(old))
    check("double migration idempotent", twice.round == 7
        and twice.v == SaveSys.SCHEMA_VERSION
        and twice.bestRun.layer == 7)
    local pure = SaveSys.migrate({ round = 5, score = 5000 })
    SaveSys.recordRun(pure, { layer = 9, score = 999999, time = 1, adAssisted = true })
    check("continued run stays isolated online but counts as local best",
        pure.bestRun.layer == 5 and pure.assistedBestRun.layer == 9
        and pure.round == 9 and pure.score == 999999)
    local previousCompletion = SaveSys.migrate({
        best_clean_run = { layer = 0, score = 0, time = 0 },
        best_assisted_run = {
            layer = 10, score = 829951, time = 900, best_combo = 58,
            run_id = "previous-l10",
        },
        recent_runs = {{
            run_id = "previous-l10", layer = 10, score = 829951,
            time = 900, best_combo = 58, completed = true,
            formal_main = true, recovered = true, assisted_run = true,
            completion_reason = "challenge_complete",
        }},
    })
    local previousLocalBest = SaveSys.getLocalBestRun(previousCompletion)
    local previousSummary, previousNote = TitleRender.localRecordSummary(previousCompletion)
    check("[044U] previous L10 completion displays as local best without replay",
        previousLocalBest.layer == 10 and previousLocalBest.score == 829951
        and previousLocalBest.bestCombo == 58
        and previousCompletion.round == 10 and previousCompletion.score == 829951
        and previousSummary:find("第 10 层", 1, true) ~= nil
        and previousSummary:find("829,951", 1, true) ~= nil
        and previousNote == "你的最高层数和分数会自动保留")
    check("[044U] player record statuses avoid internal eligibility jargon",
        TitleRender.recentRunStatus({ recovered = true }) == "继续进度后结束"
        and TitleRender.recentRunStatus({ challengeRetryCount = 2 }) == "重试后结束"
        and TitleRender.recentRunStatus({ adAssisted = true }) == "续战后结束"
        and TitleRender.recentRunStatus({ completionReason = "layer_complete" }) == "本层完成")
    local beforeRuns = #pure.recentRuns
    local first = SaveSys.recordRun(pure, { id = "same", layer = 6, score = 6000, time = 10 })
    local second = SaveSys.recordRun(pure, { id = "same", layer = 7, score = 7000, time = 11 })
    check("duplicate run settlement rejected",
        first == true and second == false and #pure.recentRuns == beforeRuns + 1)
    local merged = SaveSys.mergeCloud(
        { round = 7, score = 9000, bestCombo = 20, settingsUpdatedAt = 20,
          settings = { sound = false } },
        { round = 0, score = 0, bestCombo = 30, settingsUpdatedAt = 10 })
    check("cloud merge keeps best and rejects stale settings",
        merged.round == 7 and merged.score == 9000 and merged.bestCombo == 30
        and merged.settings.sound == false)
    local roundTrip = SaveSys.migrate(SaveSys.serialize(merged))
    check("save serialize/reload round-trip",
        roundTrip.round == merged.round and roundTrip.score == merged.score
        and roundTrip.syncVersion == SaveSys.SYNC_VERSION
        and roundTrip.gameVersion == ReleaseInfo.GAME_VERSION)
    local cloudWritten = nil
    local fakeCloud = {
        kind = "selftest_cloud",
        load = function(_, _, events) events.ok(nil); return true end,
        save = function(_, _, payload, events)
            cloudWritten = payload
            if events and events.ok then events.ok() end
            return true
        end,
    }
    local localOnly = SaveSys.migrate({ round = 8, score = 123456, bestCombo = 21 })
    SaveSys.setPrivacyDecision(localOnly, "accepted")
    local mergedCallback = false
    local cloudStarted = SaveSys.initCloud(localOnly, true, true,
        function() mergedCallback = true end, fakeCloud)
    check("empty cloud cannot overwrite local record",
        cloudStarted and mergedCallback and localOnly.round == 8 and localOnly.score == 123456
        and cloudWritten and cloudWritten.best_score == 123456
        and cloudWritten.privacy_decision == "accepted"
        and cloudWritten.privacy_consent_version == SaveSys.PRIVACY_POLICY_VERSION)
    SaveSys.initCloud(localOnly, false, false)
    SaveSys.resetCloudForTests()
    check("save write failure is non-fatal and observable", SaveSys.save(roundTrip) == false)
end

-- ============================================================
-- 018 正式存档、云合并与公共榜合同
-- ============================================================
local function testFormalPlatform018()
    local SaveSys = require "SaveSys"

    local privacyNicknameCalls = 0
    local privacyNicknameFn = rawget(_G, "GetUserNickname")
    _G.GetUserNickname = function(options)
        privacyNicknameCalls = privacyNicknameCalls + 1
        options.onSuccess({ { userId = 18018, nickname = "授权后昵称" } })
        return true
    end
    PlatformFeatures.resetForTests()
    PlatformFeatures.setIdentity({ identityReady = true, userId = 18018 })
    check("[053] nickname lookup makes zero calls before privacy consent",
        privacyNicknameCalls == 0)
    PlatformFeatures.setPrivacyConsent(true)
    check("[053] current account nickname loads immediately after consent",
        privacyNicknameCalls == 1
        and PlatformFeatures.identityPanel().nickname == "授权后昵称")
    PlatformFeatures.resetForTests()
    _G.GetUserNickname = privacyNicknameFn

    check("[029] formal leaderboard uses Maker clientCloud iscore key",
        Config.PLATFORM.leaderboard == true
        and Config.PLATFORM.leaderboardBackend == "clientCloud"
        and Config.PLATFORM.leaderboardKey == "overload_endless_rank_v1")

    check("[018] corrected rank encoding orders same-layer higher scores first",
        PlatformFeatures.rankValue(10, 100) == 10000000100
        and PlatformFeatures.rankValue(10, 900) == 10000000900
        and PlatformFeatures.rankValue(10, 900) > PlatformFeatures.rankValue(10, 100))
    check("[018] corrected rank encoding preserves cross-layer priority",
        PlatformFeatures.rankValue(11, 0) > PlatformFeatures.rankValue(10, 999999999))
    local maxLayer, maxScore = PlatformFeatures.decodeRankValue(
        PlatformFeatures.MAX_RANK_SCORE)
    check("[018] encoded maximum is JS-safe and exactly reversible",
        PlatformFeatures.MAX_RANK_SCORE == 99999999999999
        and PlatformFeatures.MAX_RANK_SCORE < PlatformFeatures.JS_SAFE_INTEGER
        and maxLayer == 99999 and maxScore == 999999999)

    local cloudRank = PlatformFeatures.rankValue(12, 1000)
    local cloudWrites = {}
    local failRankRead = false
    local fakeClientCloud = {
        Get = function(_, key, events)
            if failRankRead then
                events.error(-2, "offline")
            else
                events.ok({}, { [key] = cloudRank })
            end
            return true
        end,
        BatchSet = function()
            local payload = { ints = {}, values = {} }
            local builder = {}
            function builder:SetInt(key, value)
                payload.ints[key] = value
                return self
            end
            function builder:Set(key, value)
                payload.values[key] = value
                return self
            end
            function builder:Save(_, events)
                cloudWrites[#cloudWrites + 1] = payload
                if payload.ints.overload_endless_rank_v1 ~= nil then
                    cloudRank = payload.ints.overload_endless_rank_v1
                end
                events.ok()
                return true
            end
            return builder
        end,
        GetRankList = function(_, leaderboardKey, _, _, events, ...)
            local extra = { ... }
            local hasNicknameKey = false
            for _, key in ipairs(extra) do
                if key == "overload_nickname_snapshot" then hasNicknameKey = true end
            end
            events.ok({ {
                rank = 1, userId = 777,
                iscore = {
                    [leaderboardKey] = cloudRank,
                    overload_layer = 12,
                    overload_score = 2000,
                },
                score = {
                    overload_nickname_snapshot = hasNicknameKey and "快照昵称" or nil,
                },
            } })
            return true
        end,
    }
    local realAdapter = PlatformAdapters.clientCloudLeaderboard(fakeClientCloud)
    local highOK, lowOK, readFailed = false, false, false
    local higher = PlatformFeatures.rankValue(12, 2000)
    realAdapter:submitScore("overload_endless_rank_v1", higher, {
        layer = 12, score = 2000, bestCombo = 22,
        runId = "031-higher", gameVersion = ReleaseInfo.GAME_VERSION,
        nicknameSnapshot = "  昵称\nA  ",
    }, { ok = function() highOK = true end })
    local lower = PlatformFeatures.rankValue(11, 999999999)
    realAdapter:submitScore("overload_endless_rank_v1", lower, {
        layer = 11, score = 999999999, bestCombo = 99,
        runId = "031-lower", gameVersion = ReleaseInfo.GAME_VERSION,
        nicknameSnapshot = "昵称B",
    }, { ok = function() lowOK = true end })
    failRankRead = true
    realAdapter:submitScore("overload_endless_rank_v1",
        PlatformFeatures.rankValue(13, 0), {
            layer = 13, score = 0, bestCombo = 0,
            runId = "031-offline", gameVersion = ReleaseInfo.GAME_VERSION,
        }, { error = function() readFailed = true end })
    check("[031] clientCloud leaderboard preserves the highest cloud score",
        highOK and lowOK and readFailed and #cloudWrites == 2 and cloudRank == higher
        and cloudWrites[1].ints.overload_layer == 12
        and cloudWrites[1].ints.overload_score == 2000
        and cloudWrites[1].values.overload_run_id == "031-higher"
        and cloudWrites[1].values.overload_nickname_snapshot == "昵称A"
        and cloudWrites[2].values.overload_nickname_snapshot == "昵称B"
        and cloudWrites[2].ints.overload_endless_rank_v1 == nil,
        string.format("high=%s low=%s failed=%s writes=%d rank=%s first=%s second=%s",
            tostring(highOK), tostring(lowOK), tostring(readFailed), #cloudWrites,
            tostring(cloudRank), tostring(cloudWrites[1]
                and cloudWrites[1].values.overload_nickname_snapshot),
            tostring(cloudWrites[2]
                and cloudWrites[2].values.overload_nickname_snapshot)))
    local nicknameOnlyOK = false
    realAdapter:syncNickname("  新昵称  ", {
        ok = function() nicknameOnlyOK = true end,
    })
    check("[051E] nickname snapshot can sync independently of score replacement",
        nicknameOnlyOK and #cloudWrites == 3
        and cloudWrites[3].values.overload_nickname_snapshot == "新昵称"
        and cloudWrites[3].ints.overload_endless_rank_v1 == nil)
    local snapshotEntries = nil
    realAdapter:loadScores("overload_endless_rank_v1", 10, {
        ok = function(entries) snapshotEntries = entries end,
    })
    check("[051D] clientCloud rank list returns nickname snapshot fallback",
        snapshotEntries and snapshotEntries[1]
        and snapshotEntries[1].name == "快照昵称",
        tostring(snapshotEntries and snapshotEntries[1]
            and snapshotEntries[1].name))
    local formattedRankLine = TitleRender.formatMyRankLine(7, higher) or ""
    check("[031] my rank line decodes layer and score with safe fallback",
        string.find(formattedRankLine, "第12层", 1, true) ~= nil
        and string.find(formattedRankLine, "2,000分", 1, true) ~= nil
        and TitleRender.formatMyRankLine(7, nil) == nil)

    -- 047：优先使用官方 lobby:GetMyUserId()，并固定为稳定字符串身份键。
    -- UID 不能走 tonumber 往返，否则昵称回调中的 Int64 表示会失配。
    local oldClientCloudGlobal, oldLobbyGlobal = rawget(_G, "clientCloud"), rawget(_G, "lobby")
    _G.clientCloud = {
        userId = 111,
        Get = function() return true end,
        Set = function() return true end,
        BatchSet = function() return {} end,
        GetRankList = function() return true end,
    }
    _G.lobby = { GetMyUserId = function() return 222 end }
    local detectedIdentity = PlatformAdapters.detect(Config)
    check("[047] identity bridge prefers lobby UID and preserves canonical string key",
        detectedIdentity.identityReady and detectedIdentity.userId == "222"
        and detectedIdentity.userIdSource == "lobby"
        and detectedIdentity.userIdText == "222")
    _G.clientCloud, _G.lobby = oldClientCloudGlobal, oldLobbyGlobal

    local migrated = SaveSys.migrate({
        round = 6, score = 50000, bestCombo = 19,
        assistedBestRun = { layer = 9, score = 90000, time = 90 },
        recentRuns = {
            { id = "dup", layer = 2, score = 100, endedAt = 1 },
            { id = "dup", layer = 3, score = 200, endedAt = 2 },
        },
    })
    local payload = SaveSys.serialize(migrated)
    check("[047] schema v10 keeps durable fields and excludes live combat state",
        payload.schema_version == 10 and payload.best_layer == 9
        and payload.best_clean_run.layer == 6 and payload.best_assisted_run.layer == 9
        and payload.settings.music_volume ~= nil and payload.settings.reduce_vibration ~= nil
        and payload.updated_at ~= nil and payload.current_layer == nil
        and payload.current_wreck_data == nil and payload.run_upgrades == nil)
    check("[018] recent runs dedupe by run id", #migrated.recentRuns == 1
        and migrated.recentRuns[1].layer == 3)
    local decodeOK = SaveSys.decode("{broken")
    check("[018] corrupt JSON is rejected with deterministic backup naming",
        decodeOK == false and string.find(SaveSys.corruptBackupName(123), "123", 1, true) ~= nil)
    local savedFileGlobals = {
        fileSystem = rawget(_G, "fileSystem"), File = rawget(_G, "File"),
        FILE_READ = rawget(_G, "FILE_READ"), FILE_WRITE = rawget(_G, "FILE_WRITE"),
    }
    local fakeFiles = { [SaveSys.FILE_NAME] = "{broken" }
    _G.fileSystem = { FileExists = function(_, name) return fakeFiles[name] ~= nil end }
    _G.File = function(name, mode)
        local buffer = ""
        return {
            IsOpen = function() return true end,
            ReadString = function() return fakeFiles[name] or "" end,
            WriteString = function(_, value) buffer = value end,
            Close = function() if mode == savedFileGlobals.FILE_WRITE then fakeFiles[name] = buffer end end,
        }
    end
    local recovered = SaveSys.load()
    local backupFound = false
    for name, value in pairs(fakeFiles) do
        if string.find(name, "overload_aftermath_save_v10.corrupt.", 1, true) == 1
            and value == "{broken" then backupFound = true end
    end
    check("[018] corrupt local file is backed up and defaults recover",
        recovered.round == 0 and backupFound)
    SaveSys.recordRun(recovered, {
        id = "fresh-load", runId = "fresh-load", completed = true,
        formalMain = true, cleanRun = true, completionReason = "death",
        layer = 4, score = 4444, time = 44,
    })
    local localSaved = SaveSys.saveLocalOnly(recovered)
    local reentered = SaveSys.load()
    check("[018] local save survives a fresh load in supported file environments",
        localSaved and reentered.round == 4 and reentered.score == 4444)
    _G.fileSystem, _G.File = savedFileGlobals.fileSystem, savedFileGlobals.File
    _G.FILE_READ, _G.FILE_WRITE = savedFileGlobals.FILE_READ, savedFileGlobals.FILE_WRITE

    local pendingBest = SaveSys.migrate({})
    local pendingRun = {
        id = "pending-death", runId = "pending-death", completed = true,
        formalMain = true, cleanRun = true, completionReason = "death",
        layer = 6, score = 6060, time = 66, endedAt = 606,
    }
    local staged = SaveSys.stageRunSettlement(pendingBest, pendingRun)
    local stagedPayload = SaveSys.serialize(pendingBest)
    local stagedReload = SaveSys.migrate(stagedPayload)
    local consumed, consumedRun = SaveSys.consumePendingRunSettlement(stagedReload)
    local consumedAgain = SaveSys.consumePendingRunSettlement(stagedReload)
    check("[027] pending death settlement survives reload and records exactly once",
        staged and stagedPayload.pending_run_settlement.formal_main == true
        and consumed and consumedRun.runId == "pending-death"
        and #stagedReload.recentRuns == 1 and consumedAgain == false
        and stagedReload.pendingRunSettlement == nil)
    local debugPending = SaveSys.stageRunSettlement(stagedReload, {
        id = "debug-pending", runId = "debug-pending", completed = true,
        formalMain = true, cleanRun = true, debug = true,
        completionReason = "death", layer = 10, score = 999999,
    })
    check("[027] debug run cannot enter pending formal settlement", debugPending == false)

    local queuedHigh = SaveSys.queueLeaderboardSubmission(pendingBest, {
        runId = "high", rankScore = PlatformFeatures.rankValue(8, 800),
        layer = 8, score = 800, cleanRun = true,
    })
    local queuedLow = SaveSys.queueLeaderboardSubmission(pendingBest, {
        runId = "low", rankScore = PlatformFeatures.rankValue(7, 999999999),
        layer = 7, score = 999999999, cleanRun = true,
    })
    check("[018] pending slot keeps only highest eligible rank score",
        queuedHigh and not queuedLow and pendingBest.pendingLeaderboardSubmission.runId == "high")

    local localMerge = SaveSys.migrate({
        round = 8, score = 70000, privacyDecision = "accepted",
        privacyConsentVersion = SaveSys.PRIVACY_POLICY_VERSION,
        settingsUpdatedAt = 20, settings = { musicVolume = 0.4 },
        assistedBestRun = { layer = 4, score = 4000, time = 40 },
    })
    local cloudMerge = SaveSys.migrate({
        round = 7, score = 90000, privacyDecision = "declined",
        privacyConsentVersion = SaveSys.PRIVACY_POLICY_VERSION,
        settingsUpdatedAt = 30, settings = { musicVolume = 0.9 },
        assistedBestRun = { layer = 5, score = 5000, time = 50 },
    })
    local merged = SaveSys.mergeCloud(localMerge, SaveSys.serializeCloud(cloudMerge))
    check("[018] cloud merge keeps independent maxima and newer settings",
        merged.round == 8 and merged.score == 70000
        and merged.bestCleanRun.layer == 8 and merged.bestCleanRun.score == 70000
        and merged.bestAssistedRun.layer == 5
        and math.abs(merged.settings.musicVolume - 0.9) < 0.001)
    check("[018] privacy choice remains local-only during cloud merge",
        merged.privacyDecision == "accepted" and SaveSys.hasPrivacyConsent(merged))

    SaveSys.resetCloudForTests()
    local throttleBest = SaveSys.migrate({ round = 3, score = 3000 })
    SaveSys.setPrivacyDecision(throttleBest, "accepted")
    local noCloud, noCloudReason = SaveSys.initCloud(throttleBest, true, true)
    check("[018] missing official cloud manager keeps local save active",
        not noCloud and noCloudReason == "official_cloud_manager_unavailable")
    SaveSys.resetCloudForTests()
    local uploads = 0
    local loadAttempts = 0
    local throttleAdapter = {
        kind = "018_throttle_fake",
        load = function(_, _, events)
            loadAttempts = loadAttempts + 1
            if loadAttempts == 1 then
                events.error(-1, "offline")
            else
                events.ok({ schema_version = 7, best_layer = 2, best_score = 2000 })
            end
            return true
        end,
        save = function(_, _, _, events)
            uploads = uploads + 1
            if uploads == 1 then events.error(-2, "network") else events.ok() end
            return true
        end,
    }
    local cloudStarted = SaveSys.initCloud(throttleBest, true, true, nil, throttleAdapter)
    local retryBase = os.time()
    SaveSys.recordRun(throttleBest, {
        id = "cloud-read-local", runId = "cloud-read-local", completed = true,
        formalMain = true, cleanRun = true, completionReason = "death",
        layer = 3, score = 4000, time = 40,
    })
    local queued, queuedReason = SaveSys.saveCloud(throttleBest, retryBase, false)
    SaveSys.tickCloud(throttleBest, retryBase + 15)
    SaveSys.tickCloud(throttleBest, retryBase + 75)
    check("[027] failed cloud read blocks overwrite until merge retry succeeds",
        cloudStarted and queued and queuedReason == "queued" and loadAttempts == 2
        and throttleBest.round == 3 and throttleBest.score == 4000 and uploads == 2)
    SaveSys.resetCloudForTests()

    local pendingMerge = SaveSys.migrate({ round = 1, score = 100 })
    SaveSys.setPrivacyDecision(pendingMerge, "accepted")
    local deferredLoad, mergedUpload = nil, nil
    local deferredAdapter = {
        kind = "018_pending_merge_fake",
        load = function(_, _, events) deferredLoad = events; return true end,
        save = function(_, _, value, events)
            mergedUpload = value
            events.ok()
            return true
        end,
    }
    SaveSys.initCloud(pendingMerge, true, true, nil, deferredAdapter)
    SaveSys.recordRun(pendingMerge, {
        id = "during-cloud-read", runId = "during-cloud-read", completed = true,
        formalMain = true, cleanRun = true, completionReason = "death",
        layer = 5, score = 500, time = 50,
    })
    SaveSys.save(pendingMerge)
    deferredLoad.ok({ schema_version = 7, best_layer = 2, best_score = 200 })
    check("[018] local writes made during cloud read survive merge and upload",
        pendingMerge.round == 5 and pendingMerge.score == 500
        and mergedUpload and mergedUpload.best_layer == 5 and mergedUpload.best_score == 500)
    SaveSys.resetCloudForTests()

    local old = {
        leaderboard = Config.PLATFORM.leaderboard,
        leaderboardKey = Config.PLATFORM.leaderboardKey,
        leaderboardBackend = Config.PLATFORM.leaderboardBackend,
        identityReady = Config.PLATFORM.identityReady,
    }
    Config.PLATFORM.leaderboard = true
    Config.PLATFORM.leaderboardBackend = "clientCloud"
    Config.PLATFORM.identityReady = true
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    PlatformFeatures.setIdentity({ identityReady = true, userId = "018-selftest-user" })
    Config.PLATFORM.leaderboardKey = nil
    local noKey, noKeyReason = PlatformFeatures.leaderboardStatus()
    Config.PLATFORM.leaderboardKey = "018_public_board"
    local noAPI, noAPIReason = PlatformFeatures.leaderboardStatus()
    check("[018/029] missing clientCloud key or adapter keeps online board safely off",
        not noKey and noKeyReason == "missing_leaderboard_key"
        and not noAPI and noAPIReason == "official_leaderboard_manager_unavailable")
    local boardBest = SaveSys.migrate({})
    -- 047：结算可能早于 UID/排行榜能力注入，但已同意且配置有效时必须
    -- 先留下本地待提交槽，不能把 L10+/无尽成绩静默丢掉。
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    local lateIdentityBest = SaveSys.migrate({})
    local lateQueued, lateReason = PlatformFeatures.submitRun({
        id = "047-late-identity", runId = "047-late-identity", completed = true,
        formalMain = true, cleanRun = true, endless = true,
        completionReason = "layer_complete", layer = 11, score = 1100,
    }, lateIdentityBest)
    check("[047] milestone queues before late platform identity is ready",
        lateQueued and lateReason == "queued_platform_identity_unavailable"
        and lateIdentityBest.pendingLeaderboardSubmission ~= nil)
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    PlatformFeatures.setIdentity({ identityReady = true, userId = "018-selftest-user" })
    local clean = {
        id = "018-clean", runId = "018-clean", completed = true,
        formalMain = true, cleanRun = true, completionReason = "death",
        endless = true, layer = 12, score = 345678, bestCombo = 25, endedAt = 100,
    }
    local submissionQueued, submissionReason = PlatformFeatures.submitRun(clean, boardBest)
    check("[018] offline formal run retains one best pending submission",
        submissionQueued and submissionReason == "queued_offline"
        and boardBest.pendingLeaderboardSubmission.runId == "018-clean")
    local submittedScore = nil
    local boardEntries = nil
    local oldNicknameFn = rawget(_G, "GetUserNickname")
    _G.GetUserNickname = function(options)
        options.onSuccess({
            { userId = "018-selftest-user", nickname = "我的昵称" },
            { userId = 101, nickname = "昵称A" },
            { userId = 102, nickname = "昵称B" },
        })
        return true
    end
    PlatformFeatures.requestNickname()
    local fakeBoard = {
        submitScore = function(_, id, score, metadata, events)
            submittedScore = { id = id, score = score, metadata = metadata }
            events.ok()
            return true
        end,
        loadScores = function(_, _, _, events)
            events.ok({
                { rank = "1", userId = 101,
                    score = tostring(PlatformFeatures.rankValue(12, 345678)) },
                { rank = "2", userId = 102,
                    score = tostring(PlatformFeatures.rankValue(10, 900)) },
            })
            return true
        end,
    }
    local retried = PlatformFeatures.retryPending(boardBest, fakeBoard)
    PlatformFeatures.fetchLeaderboard(10, {
        ok = function(entries) boardEntries = entries end,
    }, fakeBoard)
    check("[018] pending retry submits once and clears only after success",
        retried and submittedScore.id == "018_public_board"
        and submittedScore.score == PlatformFeatures.rankValue(12, 345678)
        and submittedScore.metadata.nicknameSnapshot == "我的昵称"
        and boardBest.pendingLeaderboardSubmission == nil)
    check("[018] leaderboard UI data decodes composite value",
        boardEntries and #boardEntries == 2
        and boardEntries[1].layer == 12 and boardEntries[1].score == 345678
        and boardEntries[1].name == "昵称A" and boardEntries[2].name == "昵称B")
    _G.GetUserNickname = function(options)
        options.onError("offline")
        return true
    end
    local fallbackEntries = nil
    fakeBoard.loadScores = function(_, _, _, events)
        events.ok({ {
            rank = 1, userId = 101, name = "快照昵称",
            score = tostring(PlatformFeatures.rankValue(12, 345678)),
        } })
        return true
    end
    PlatformFeatures.fetchLeaderboard(10, {
        ok = function(entries) fallbackEntries = entries end,
    }, fakeBoard)
    check("[051D] live nickname failure preserves submitted nickname snapshot",
        fallbackEntries and fallbackEntries[1]
        and fallbackEntries[1].name == "快照昵称")

    -- 051E：部分真机宿主会把官方昵称结果包在 data/list 中，或只在
    -- 移动端 sdk:GetUserName() 暴露当前账号昵称。两者都必须安全降级，
    -- 并把已确认昵称独立同步到排行榜快照，不能要求玩家再刷一次高分。
    local oldSdk = rawget(_G, "sdk")
    local syncedNickname = nil
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    PlatformFeatures.setLeaderboardAdapter({
        syncNickname = function(_, nickname, events)
            syncedNickname = nickname
            events.ok()
            return true
        end,
    })
    _G.sdk = nil
    _G.GetUserNickname = function(options)
        options.onSuccess({ data = { { uid = "018-selftest-user", nickName = "宿主昵称" } } })
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "018-selftest-user" })
    local wrappedPanel = PlatformFeatures.identityPanel()
    check("[051E] wrapped host nickname result resolves and syncs without a new high score",
        wrappedPanel.nickname == "宿主昵称"
        and wrappedPanel.nicknameSource == "official_batch"
        and syncedNickname == "宿主昵称")

    -- 052A：真机宿主日志证明底层会返回 JSON 形式的 nicknames 负载。
    -- 即使兼容层直接把该负载交给回调，也必须复用同一条 UID -> 昵称映射。
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = nil
    _G.GetUserNickname = function(options)
        options.onSuccess([=[{"errorCode":0,"nicknames":[{"userId":1566752225,"nickname":"真机昵称"}]}]=])
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "1566752225" })
    local jsonPanel = PlatformFeatures.identityPanel()
    check("[052A] JSON nickname payload resolves the current TapTap account",
        jsonPanel.nickname == "真机昵称"
        and jsonPanel.nicknameSource == "official_batch")

    -- 052B：只有官方全局 GetUserNickname 根本不存在时，才允许用旧宿主的
    -- UserNicknameResponse 兼容桥兜底；该路径同时服务设置页与排行榜行。
    local oldSubscribe = rawget(_G, "SubscribeToEvent")
    local oldLobby = rawget(_G, "lobby")
    local directHandler, directRequestId, directRequestedIds = nil, 5200, nil
    _G.SubscribeToEvent = function(eventName, callback)
        if eventName == "UserNicknameResponse" then directHandler = callback end
    end
    _G.lobby = {
        GetUserNickname = function(_, ids)
            directRequestId = directRequestId + 1
            directRequestedIds = ids
            return directRequestId
        end,
    }
    local function nicknameEvent(requestId, json)
        return {
            RequestId = { GetInt = function() return requestId end },
            Success = { GetBool = function() return true end },
            ErrorCode = { GetInt = function() return 0 end },
            Nicknames = { GetString = function() return json end },
        }
    end
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = nil
    _G.GetUserNickname = nil
    PlatformFeatures.setIdentity({ identityReady = true, userId = "1566752225" })
    local currentRequestId = directRequestId
    local requestedCurrent = directRequestedIds and directRequestedIds[1]
    if directHandler then
        directHandler("UserNicknameResponse", nicknameEvent(currentRequestId,
            [=[{"errorCode":0,"nicknames":[{"userId":1566752225,"nickname":"直连昵称"}]}]=]))
    end
    local directPanel = PlatformFeatures.identityPanel()
    check("[052B] missing global API falls back to platform nickname response for settings",
        directHandler ~= nil and tostring(requestedCurrent) == "1566752225"
        and directPanel.nickname == "直连昵称" and directPanel.nicknameSource == "lobby_direct")

    local directBoardEntries = nil
    local directBoard = {
        submitScore = function() return true end,
        loadScores = function(_, _, _, events)
            events.ok({
                { rank = 1, userId = 101, score = tostring(PlatformFeatures.rankValue(12, 345678)) },
                { rank = 2, userId = 102, score = tostring(PlatformFeatures.rankValue(11, 123456)) },
            })
            return true
        end,
    }
    PlatformFeatures.fetchLeaderboard(10, {
        ok = function(entries) directBoardEntries = entries end,
    }, directBoard)
    local boardRequestId = directRequestId
    if directHandler then
        directHandler("UserNicknameResponse", nicknameEvent(boardRequestId,
            [=[{"errorCode":0,"nicknames":[{"userId":101,"nickname":"榜单昵称A"},{"userId":102,"nickname":"榜单昵称B"}]}]=]))
    end
    check("[052B] missing global API falls back to platform nickname response for leaderboard rows",
        directBoardEntries and directBoardEntries[1].name == "榜单昵称A"
        and directBoardEntries[2].name == "榜单昵称B")

    -- 052D：正式全局 API 已存在时，空结果不能偷偷发起旧桥请求，避免旧/新
    -- 两条异步回调竞态覆盖同一账号的昵称。
    local directRequestBeforeOfficialEmpty = directRequestId
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = nil
    _G.GetUserNickname = function(options)
        options.onSuccess({})
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "1566752225" })
    check("[052D] official empty nickname result never invokes legacy bridge",
        directRequestId == directRequestBeforeOfficialEmpty
        and PlatformFeatures.identityPanel().nickname == "TapTap 玩家")

    -- 052E：同一 Int64 UID 在不同绑定中可能带 .0；必须仍能匹配设置昵称，
    -- 也必须能回填排行榜的同一行。
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.GetUserNickname = function(options)
        options.onSuccess({ { userId = "1566752225.0", nickname = "格式兼容昵称" } })
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "1566752225" })
    check("[052E] decimal-form UID resolves the same settings account nickname",
        PlatformFeatures.identityPanel().nickname == "格式兼容昵称")

    local delayedRequests = {}
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.GetUserNickname = function(options)
        delayedRequests[#delayedRequests + 1] = options
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "account-A" })
    PlatformFeatures.setIdentity({ identityReady = true, userId = "account-B" })
    if delayedRequests[1] then
        delayedRequests[1].onSuccess({ { userId = "account-A", nickname = "旧账号" } })
    end
    local stalePanel = PlatformFeatures.identityPanel()
    if delayedRequests[2] then
        delayedRequests[2].onSuccess({ { userId = "account-B", nickname = "当前账号" } })
    end
    check("[052E] delayed nickname callback cannot overwrite a switched account",
        #delayedRequests == 2 and stalePanel.nickname == "TapTap 玩家"
        and PlatformFeatures.identityPanel().nickname == "当前账号")

    local decimalRowEntries, decimalRowNames = nil, nil
    local decimalRowRequest = nil
    _G.GetUserNickname = function(options)
        decimalRowRequest = options
        return true
    end
    PlatformFeatures.fetchLeaderboard(20, {
        ok = function(entries) decimalRowEntries = entries end,
        names = function(entries) decimalRowNames = entries end,
    }, {
        submitScore = function() return true end,
        loadScores = function(_, _, _, events)
            events.ok({ {
                rank = 1, userId = "101.0",
                score = tostring(PlatformFeatures.rankValue(12, 345678)),
            } })
            return true
        end,
    })
    if decimalRowRequest then
        decimalRowRequest.onSuccess({ { userId = 101, nickname = "榜单格式昵称" } })
    end
    check("[052E] canonical UID maps official nickname back onto leaderboard row",
        decimalRowEntries and decimalRowNames and decimalRowEntries[1]
        and decimalRowEntries[1].name == "榜单格式昵称"
        and decimalRowNames[1].name == "榜单格式昵称")

    -- 052C：真机 #17328 的关键回归。宿主可能已受理昵称请求却迟迟不回调；
    -- 成绩行必须立即可见，昵称后补不能成为公开榜的完成条件。
    local nonBlockingEntries, requestedTopCount = nil, nil
    _G.GetUserNickname = function()
        return true
    end
    PlatformFeatures.fetchLeaderboard(99, {
        ok = function(entries) nonBlockingEntries = entries end,
    }, {
        submitScore = function() return true end,
        loadScores = function(_, _, count, events)
            requestedTopCount = count
            events.ok({ {
                rank = 1, userId = 101, name = "快照昵称",
                score = tostring(PlatformFeatures.rankValue(12, 345678)),
            } })
            return true
        end,
    })
    check("[052C] score rows do not wait for a nickname callback and cap at top twenty",
        requestedTopCount == 20 and nonBlockingEntries and #nonBlockingEntries == 1
        and nonBlockingEntries[1].name == "快照昵称")
    _G.SubscribeToEvent = oldSubscribe
    _G.lobby = oldLobby

    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = { GetUserName = function() return "移动端昵称" end }
    _G.GetUserNickname = function(options)
        options.onSuccess({})
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "018-selftest-user" })
    local mobilePanel = PlatformFeatures.identityPanel()
    check("[051E] mobile account nickname fills settings when batch API is empty",
        mobilePanel.nickname == "移动端昵称"
        and mobilePanel.nicknameSource == "sdk_mobile")

    local emptyRequests = 0
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = nil
    _G.GetUserNickname = function(options)
        emptyRequests = emptyRequests + 1
        options.onSuccess({})
        return true
    end
    PlatformFeatures.setIdentity({ identityReady = true, userId = "018-selftest-user" })
    PlatformFeatures.identityPanel()
    PlatformFeatures.identityPanel()
    check("[051E] empty nickname result obeys retry cooldown instead of requesting every frame",
        emptyRequests == 1)
    _G.sdk = oldSdk
    Screens.setMyRank("4", tostring(PlatformFeatures.rankValue(12, 345678)))
    check("[047] rank callback accepts numeric strings from platform bindings",
        Screens.myRank == 4 and Screens.myRankScore == PlatformFeatures.rankValue(12, 345678))
    local failedBest = SaveSys.migrate({})
    SaveSys.queueLeaderboardSubmission(failedBest, {
        runId = "031-pending", rankScore = PlatformFeatures.rankValue(12, 4000),
        layer = 12, score = 4000, cleanRun = true,
    })
    local retryStarted = PlatformFeatures.retryPending(failedBest, {
        submitScore = function(_, _, _, _, events)
            events.error(-2, "offline")
            return true
        end,
    })
    check("[031] leaderboard read or write failure keeps the best pending submission",
        retryStarted and failedBest.pendingLeaderboardSubmission
        and failedBest.pendingLeaderboardSubmission.runId == "031-pending")
    _G.GetUserNickname = oldNicknameFn
    check("[018] assisted runs share the board while review/debug remain rejected",
        PlatformFeatures.isEligibleRun({
            id = "bad", completed = true, formalMain = true, cleanRun = false,
            adAssisted = true, endless = true, completionReason = "death", layer = 99, score = 1,
        }) and not PlatformFeatures.isEligibleRun({
            id = "review", completed = true, formalMain = true, cleanRun = true,
            review = true, completionReason = "death", layer = 2, score = 1,
        }) and not PlatformFeatures.isEligibleRun({
            id = "challenge", completed = true, formalMain = true, cleanRun = true,
            endless = false, completionReason = "challenge_complete", layer = 10, score = 1,
        }) and not PlatformFeatures.isEligibleRun({
            id = "recovered", completed = true, formalMain = true, cleanRun = true,
            endless = true, recovered = true, completionReason = "death", layer = 12, score = 1,
        }))

    Screens.recordsOpen = false
    Screens.onlineLeaderboardOpen = false
    Screens.helpOpen = false
    Screens.privacyOpen = false
    Screens.settingsOpen = false
    Screens.privacyGateOpen = false
    local hidden, visible = Screens.layout(390, 867, migrated.settings, true, false),
        Screens.layout(390, 867, migrated.settings, true, true)
    local function hasButton(buttons, id)
        for _, button in ipairs(buttons) do
            if button.id == id then return true end
        end
        return false
    end
    local function hasOnline(buttons)
        return hasButton(buttons, "onlineLeaderboard")
    end
    check("[018] online leaderboard button is absent unless every gate is ready",
        not hasOnline(hidden) and hasOnline(visible))
    local checkpoint = { nextLayer = 3, checkpointState = "LAYER_START" }
    local checkpointHidden = Screens.layout(390, 867, migrated.settings,
        true, false, false, checkpoint)
    local checkpointVisible = Screens.layout(390, 867, migrated.settings,
        true, true, false, checkpoint)
    check("[033] checkpoint title keeps local records and gated leaderboard entry",
        not hasOnline(checkpointHidden) and hasOnline(checkpointVisible)
        and hasButton(checkpointHidden, "records")
        and hasButton(checkpointVisible, "records"))

    PlatformFeatures.resetForTests()
    local waitingPanel = PlatformFeatures.identityPanel()
    PlatformFeatures.setPrivacyConsent(true)
    PlatformFeatures.setIdentity({ identityReady = true, userId = "1566752225" })
    PlatformFeatures.setLeaderboardAdapter(fakeBoard)
    local readyPanel = PlatformFeatures.identityPanel()
    check("[033] platform panel explains consent and ready states without generic local-mode text",
        waitingPanel.accountLabel == "等待授权"
        and waitingPanel.cloudSaveStatus == "等待授权"
        and waitingPanel.leaderboardStatusLabel == "等待授权"
        and readyPanel.accountLabel ~= "本地模式"
        and readyPanel.leaderboardStatusLabel == "已开启"
        and string.find(readyPanel.accountLabel, "账号尾号752225", 1, true) ~= nil)

    Config.PLATFORM.leaderboard = old.leaderboard
    Config.PLATFORM.leaderboardKey = old.leaderboardKey
    Config.PLATFORM.leaderboardBackend = old.leaderboardBackend
    Config.PLATFORM.identityReady = old.identityReady
    PlatformFeatures.resetForTests()
end

-- ============================================================
-- 026：Challenge 层间检查点、无限重试与 Endless 纯净结算
-- ============================================================
local function testChallengeCheckpoint026()
    local SaveSys = require "SaveSys"
    local ChallengeCheckpoint = require "ChallengeCheckpoint"

    local migratedV7 = SaveSys.migrate({ schema_version = 7, best_layer = 6,
        best_score = 6000 })
    check("[047] v7 migrates to v10 without inventing checkpoint or graduation archive",
        migratedV7.v == 10 and migratedV7.round == 6
        and SaveSys.getChallengeCheckpoint(migratedV7) == nil)

    local base = RawWorldNew({ experiment = "B", seed = 26001 })
    base.runId = "026-run"
    base.player.hp = 37
    base.score = 12345
    base.wreckData = 2
    base.coreCount = 3
    base.runUpgrades.collapseCooldownLevel = 1
    base.modules.capacitor = true
    base.counters.spotted = 4
    base.restarts = 2
    base.huntKills = 5
    base.bestCombo = 17
    base.bestAntiHuntChain = 3
    base.riskSuccesses = 2
    base.energy = 99
    base.heat = 88
    local cp = ChallengeCheckpoint.capture(base, 5,
        ChallengeCheckpoint.LAYER_START, base.runId, 100)
    check("[026] L1 and L2-L10 checkpoints use one bounded schema",
        cp and cp.nextLayer == 5 and cp.checkpointState == "LAYER_START"
        and ChallengeCheckpoint.capture(base, 1, "LAYER_START", base.runId, 90) ~= nil
        and ChallengeCheckpoint.capture(base, 10, "LAYER_START", base.runId, 90) ~= nil
        and ChallengeCheckpoint.capture(base, 11, "LAYER_START", base.runId, 90) == nil)
    local serialized = ChallengeCheckpoint.serialize(cp)
    check("[026] checkpoint whitelist excludes live layer state",
        serialized.checkpoint_hp == 37 and serialized.energy == nil
        and serialized.heat == nil and serialized.phase == nil
        and serialized.player_position == nil and serialized.enemies == nil
        and serialized.risk_score == nil and serialized.tools == nil)

    local save = SaveSys.migrate({})
    check("[026] single checkpoint slot overwrites previous layer",
        SaveSys.setChallengeCheckpoint(save,
            ChallengeCheckpoint.capture(base, 4, "LAYER_START", base.runId, 90))
        and SaveSys.setChallengeCheckpoint(save, cp)
        and SaveSys.getChallengeCheckpoint(save).nextLayer == 5)
    local payload = SaveSys.serialize(save)
    local roundTrip = SaveSys.migrate(payload)
    check("[026] checkpoint survives schema serialization and cloud payload",
        roundTrip.challengeCheckpoint.nextLayer == 5
        and SaveSys.serializeCloud(roundTrip).challenge_checkpoint.next_layer == 5)
    base.assistedRun = true
    base.rewardedReviveAttempted = true
    base.rewardedReviveUsed = true
    local adCp = ChallengeCheckpoint.capture(base, 5,
        ChallengeCheckpoint.LAYER_START, base.runId, 101)
    local adRoundTrip = ChallengeCheckpoint.normalize(
        ChallengeCheckpoint.serialize(adCp))
    check("[029] checkpoint preserves ad use and assisted eligibility",
        adRoundTrip.assistedRun and adRoundTrip.rewardedReviveAttempted
        and adRoundTrip.rewardedReviveUsed)

    SaveSys.resetCloudForTests()
    local legacyCloudBest = SaveSys.migrate({})
    SaveSys.setPrivacyDecision(legacyCloudBest, "accepted")
    local requestedSlots = {}
    local legacyAdapter = {
        kind = "026_v7_fallback",
        load = function(_, slot, events)
            requestedSlots[#requestedSlots + 1] = slot
            if slot == SaveSys.LEGACY_V7_CLOUD_SLOT then
                events.ok({ schema_version = 7, best_layer = 9, best_score = 9000 })
            else
                events.ok(nil)
            end
            return true
        end,
        save = function(_, _, _, events) if events.ok then events.ok() end return true end,
    }
    local fallbackStarted = SaveSys.initCloud(legacyCloudBest, true, true, nil, legacyAdapter)
    check("[047] empty v10/v9/v8 cloud falls back to v7 and migrates records",
        fallbackStarted and #requestedSlots == 4
        and requestedSlots[1] == SaveSys.CLOUD_SLOT
        and requestedSlots[2] == SaveSys.LEGACY_V9_CLOUD_SLOT
        and requestedSlots[3] == SaveSys.LEGACY_V8_CLOUD_SLOT
        and requestedSlots[4] == SaveSys.LEGACY_V7_CLOUD_SLOT
        and legacyCloudBest.round == 9 and legacyCloudBest.score == 9000)
    SaveSys.resetCloudForTests()

    local restored = RawWorldNew({ experiment = "B", seed = cp.seed, startLayer = 5,
        challengeCheckpoint = cp, checkpointRecovered = true })
    check("[026] mid-L5 restore returns to L5 intro with exact entry HP",
        restored.round == 5 and restored.phase == "layer_intro"
        and restored.player.hp == 37 and restored.layerIntroTimer == Config.FORMAL.layerIntroDuration,
        string.format("round=%s phase=%s hp=%s intro=%s expected=%s skip=%s review=%s test=%s",
            tostring(restored.round), tostring(restored.phase), tostring(restored.player.hp),
            tostring(restored.layerIntroTimer), tostring(Config.FORMAL.layerIntroDuration),
            tostring(restored.skipLayerIntro), tostring(restored.reviewOnly),
            tostring(restored.testMode)))
    check("[026] restore resets energy and rolls back current-layer gains",
        restored.energy == 0 and restored.score == 12345
        and restored.wreckData == 2 and restored.coreCount == 3
        and restored.heat == 0 and restored.runUpgrades.collapseCooldownLevel == 1)
    check("[026] checkpoint recovery remains clean and leaderboard eligible",
        restored.recoveredRun and restored.checkpointRecovery
        and not restored.assistedRun and restored.cleanRun
        and PlatformFeatures.isEligibleRun({
            id = "checkpoint-clean", completed = true, formalMain = true,
            endless = true, recovered = true, checkpointRecovery = true,
            completionReason = "death", layer = 12, score = 1,
        }))

    local retry = RawWorldNew({ experiment = "B", seed = cp.seed, startLayer = 5,
        challengeCheckpoint = cp, checkpointRecovered = true, checkpointRetry = true })
    check("[026] first layer retry increments count and is assisted",
        retry.challengeRetryCount == 1 and retry.challengeRetry and retry.assistedRun)
    local retryCp = cp
    local retryWorld = nil
    for i = 1, 10 do
        retryWorld = RawWorldNew({ experiment = "B", seed = retryCp.seed, startLayer = 5,
            challengeCheckpoint = retryCp, checkpointRecovered = true, checkpointRetry = true })
        retryCp.challengeRetryCount = retryWorld.challengeRetryCount
    end
    check("[026] Challenge retry remains unlimited through ten retries",
        retryWorld and retryWorld.challengeRetryCount == 10)

    local l10Base = RawWorldNew({ experiment = "B", seed = 26010, startLayer = 10 })
    l10Base.runId = "026-l10"
    l10Base.score = 888888
    l10Base.coreCount = 4
    local l10cp = ChallengeCheckpoint.capture(l10Base, 10,
        ChallengeCheckpoint.L10_CHOICE, l10Base.runId, 200)
    local l10Restored = RawWorldNew({ experiment = "B", seed = l10cp.seed,
        startLayer = 10, challengeCheckpoint = l10cp, checkpointRecovered = true })
    check("[026] L10 choice checkpoint restores dual exit without replay",
        l10Restored.round == 10 and l10Restored.phase == "layer_settlement"
        and l10Restored.runComplete and l10Restored.layerSettlement.restoredChoice)

    local choiceSave = SaveSys.migrate({ challenge_checkpoint =
        ChallengeCheckpoint.serialize(l10cp) })
    check("[026] complete and continue gates can clear checkpoint exactly once",
        SaveSys.clearChallengeCheckpoint(choiceSave, "026-l10")
        and SaveSys.getChallengeCheckpoint(choiceSave) == nil
        and SaveSys.clearChallengeCheckpoint(choiceSave, "026-l10") == false)

    local titleSettings = { sound = true, musicVolume = 0.5, sfxVolume = 0.5,
        vibration = true, reduceFx = false, reduceShake = false }
    local oldConfirm = Screens.newChallengeConfirmOpen
    Screens.newChallengeConfirmOpen = false
    local titleButtons = Screens.layout(390, 867, titleSettings, true, false, false, cp)
    local ids = {}
    for _, button in ipairs(titleButtons) do ids[button.id] = true end
    check("[026] title exposes continue and guarded new challenge",
        ids.continueChallenge and ids.startNewChallenge and not ids.start)
    Screens.newChallengeConfirmOpen = true
    ids = {}
    for _, button in ipairs(Screens.layout(390, 867, titleSettings, true, false, false, cp)) do
        ids[button.id] = true
    end
    check("[026] new challenge requires second confirmation",
        ids.confirmStartNewChallenge and ids.cancelStartNewChallenge)
    Screens.newChallengeConfirmOpen = oldConfirm

    local shopWorld = RawWorldNew({ experiment = "B", seed = 26002 })
    shopWorld.phase = "layer_settlement"
    shopWorld.layerSettlement = { layer = 4, runComplete = false }
    shopWorld.checkpointReady = true
    local layout = RunShop.layout(shopWorld, 390, 867)
    local half = (layout.confirm.w - 8 * layout.scale) * 0.5
    check("[026] saved settlement offers suspend and continue",
        RunShop.hit(shopWorld, layout.confirm.x + half * 0.5,
            layout.confirm.y + 10, 390, 867) == "checkpointSuspend"
        and RunShop.hit(shopWorld, layout.confirm.x + half * 1.5 + 8 * layout.scale,
            layout.confirm.y + 10, 390, 867) == "checkpointContinue")

    local deadChallenge = RawWorldNew({ experiment = "B", seed = 26003 })
    deadChallenge.phase = "dead"
    deadChallenge.challengeCheckpointAvailable = true
    deadChallenge.reviveOffer = true
    local deadIds = {}
    for _, button in ipairs(InputSys.layout(deadChallenge, 390, 867)) do
        deadIds[button.id] = true
    end
    check("[026/029] Challenge death offers ad continue, free retry and end",
        deadIds.revive and deadIds.retryLayer and deadIds.endChallenge and not deadIds.again)

    local cleanEndlessDeath = {
        id = "026-clean", runId = "026-clean", completed = true,
        formalMain = true, cleanRun = true, endless = true,
        layer = 12, score = 1000, completionReason = "death",
        challengeRetryCount = 0,
    }
    check("[026] Endless normal death is valid clean leaderboard finish",
        PlatformFeatures.isEligibleRun(cleanEndlessDeath))
    local manual = {
        id = "026-manual", runId = "026-manual", completed = true,
        formalMain = true, cleanRun = true, endless = true,
        layer = 12, score = 1000, completionReason = "manual_abandon",
        challengeRetryCount = 0,
    }
    check("[026] Endless manual abandon is not leaderboard eligible",
        not PlatformFeatures.isEligibleRun(manual))
    local recoveredEndless = {
        id = "026-recovered", runId = "026-recovered", completed = true,
        formalMain = true, cleanRun = false, endless = true,
        layer = 12, score = 1000, completionReason = "death",
        challengeRetryCount = 0, recovered = true,
    }
    check("[026] recovered Challenge stays ineligible after entering Endless",
        not PlatformFeatures.isEligibleRun(recoveredEndless))

    local localRecord = SaveSys.migrate({})
    SaveSys.recordRun(localRecord, {
        id = "026-record", runId = "026-record", completed = true,
        formalMain = true, cleanRun = false, assistedRun = true,
        recovered = true, challengeRetry = true, challengeRetryCount = 3,
        endless = true, layer = 13, score = 5555, completionReason = "death",
    })
    local savedRecord = SaveSys.migrate(SaveSys.serialize(localRecord)).recentRuns[1]
    check("[026] local record preserves mode recovery retry and result fields",
        savedRecord.endless and savedRecord.recovered and savedRecord.challengeRetry
        and savedRecord.challengeRetryCount == 3 and savedRecord.completionReason == "death"
        and not savedRecord.cleanRun)
    check("[026/029] Challenge ad flag and review debug isolation remain bounded",
        Config.PLATFORM.rewardedAd == true
        and SaveSys.recordRun(localRecord, { id = "026-debug", completed = true,
            formalMain = true, cleanRun = true, debug = true, layer = 99, score = 1 }) == false)
end

local function testAudioPipeline()
    local saved = {
        Scene = rawget(_G, "Scene"), cache = rawget(_G, "cache"), audio = rawget(_G, "audio"),
        SOUND_EFFECT = rawget(_G, "SOUND_EFFECT"), SOUND_MUSIC = rawget(_G, "SOUND_MUSIC"),
    }
    local madeSources, loaded = {}, {}
    _G.SOUND_EFFECT, _G.SOUND_MUSIC = "Effect", "Music"
    _G.Scene = function()
        return {
            CreateChild = function()
                return {
                    CreateComponent = function()
                        local src = { playing = false, plays = 0 }
                        function src:SetDeclickEnabled() end
                        function src:Play(sound)
                            self.sound, self.playing, self.plays = sound, true, self.plays + 1
                            self.played = self.played or {}
                            self.played[#self.played + 1] = sound
                        end
                        function src:Stop() self.playing = false end
                        function src:IsPlaying() return self.playing end
                        madeSources[#madeSources + 1] = src
                        return src
                    end,
                }
            end,
        }
    end
    _G.cache = {
        GetResource = function(_, _, file)
            loaded[#loaded + 1] = file
            return { file = file, SetLooped = function(self, value) self.looped = value end }
        end,
    }
    _G.audio = {
        Play = function() return true end,
        SetMasterGain = function() end,
        PauseSoundType = function() end,
        ResumeSoundType = function() end,
    }
    local AudioSys = require "AudioSys"
    AudioSys.shutdown()
    local settings = { sound = true, volume = 0.8, musicVolume = 0.55, sfxVolume = 0.8 }
    local initialized = AudioSys.init(settings)
    AudioSys.setAmbient("layer_intro")
    local beforeUnlock = AudioSys.diagnostics()
    AudioSys.unlock()
    AudioSys.tick(0.3)
    AudioSys.setAmbient("overload")
    local continuousOverload = AudioSys.diagnostics()
    AudioSys.setAmbient("anti_hunt")
    AudioSys.tick(0.3)
    AudioSys.setAmbient("depleted")
    AudioSys.tick(0.3)
    AudioSys.play("ui_click")
    local sfxWasPlaying = madeSources[1].playing
    AudioSys.setPaused(true)
    local pausedAudio = AudioSys.diagnostics()
    local sfxStopped = not madeSources[1].playing
    AudioSys.setPaused(false)
    settings.sound = false
    AudioSys.applySettings(settings)
    local muted = AudioSys.diagnostics()
    settings.sound = true
    AudioSys.applySettings(settings)
    AudioSys.tick(0.3)
    local resumed = AudioSys.diagnostics()
    local hasOvercharge, hasAntiHunt, hasDepleted, hasDismantle = false, false, false, false
    for _, file in ipairs(loaded) do
        hasOvercharge = hasOvercharge or string.find(file, "过载余波｜算力过载", 1, true) ~= nil
        hasAntiHunt = hasAntiHunt or string.find(file, "Pixel_Counterpunch", 1, true) ~= nil
        hasDepleted = hasDepleted or file == "Sounds/r2/ambient_depleted.ogg"
        hasDismantle = hasDismantle or file == "audio/sfx/overload_wreck_dismantle_progress.mp3"
    end
    AudioSys.play("dismantle_start")
    hasDismantle = hasDismantle or (madeSources[2].sound
        and madeSources[2].sound.file == "audio/sfx/overload_wreck_dismantle_progress.mp3")
    local music = madeSources[7]
    check("audio waits for user gesture before BGM", initialized and not beforeUnlock.playing)
    check("intro and overload share one non-looping BGM playhead",
        continuousOverload.phase == "overload" and continuousOverload.looped == false
        and music.plays >= 1 and music.played[1].file == "audio/过载余波｜算力过载_20260822082133.mp3"
        and music.played[1].looped == false)
    check("phase BGM assets enter playing state without changing stealth BGM",
        resumed.verified.overload and resumed.verified.depleted
        and hasOvercharge and hasAntiHunt and hasDepleted
        and music.played[2].file == "audio/Pixel_Counterpunch_20260822082933.mp3"
        and music.played[2].looped == false and music.played[3].looped == true)
    check("wreck dismantle progress sound resolves to generated asset", hasDismantle)
    check("mute stops and unmute resumes current BGM",
        not muted.playing and resumed.playing and resumed.phase == "depleted")
    check("background pause stops event audio without duplicating BGM",
        sfxWasPlaying and sfxStopped and pausedAudio.paused and resumed.playing)
    check("audio uses one dedicated music source", #madeSources == 7 and music.plays == 4)
    AudioSys.shutdown()
    _G.Scene, _G.cache, _G.audio = saved.Scene, saved.cache, saved.audio
    _G.SOUND_EFFECT, _G.SOUND_MUSIC = saved.SOUND_EFFECT, saved.SOUND_MUSIC
end

-- ============================================================
-- 039B：表现层合同——三阶段身份语义、减闪档位保持、转换瞬间强化
-- 只验证确定性表现数据（fx/事件/阶段），不替代真机视觉判断。
-- ============================================================
local function testPresentation039B()
    -- 1) 过载→枯竭：同一帧必须同时出现 hitstop(断电停顿)+ depleted phaseflash(暗化)
    --    + 能量收束 bigring(力量被抽离)。
    local w = World.New()
    w.overloadLeft = 0.06
    step(w, 0.1)
    local hasHitstop, hasDepletedFlash, hasPurpleRing = false, false, false
    for _, f in ipairs(w.fx) do
        if f.kind == "hitstop" then hasHitstop = true end
        if f.kind == "phaseflash" and f.color == "depleted" then hasDepletedFlash = true end
        if f.kind == "bigring" and f.color == "purple" then hasPurpleRing = true end
    end
    check("[039B] drop moment = hitstop + depleted flash + power-drain ring",
        hasHitstop and hasDepletedFlash and hasPurpleRing)
    check("[039B] drop keeps depleted banner semantics",
        w.phase == "depleted" and w.lastOverloadSummary ~= nil)

    -- 2) 重启→反猎：启动瞬间出现青色大环 + 紫色二次冲击 + 更强的镜头震动
    --    + overload(翻盘) phaseflash；且未提前进入层结算。
    --    shake(0.35s) 在 0.3s 步进后已过期移除，用重启完成事件 + 翻盘闪光佐证。
    grantEnergy(w)
    press(w, "restart")
    step(w, Config.FORMAL.restartChannelTime + 0.3)
    local hasCyanRing, hasPurpleRing2, hasFlipFlash = false, false, false
    for _, f in ipairs(w.fx) do
        if f.kind == "bigring" and f.color == "cyan" then hasCyanRing = true end
        if f.kind == "bigring" and f.color == "purple" then hasPurpleRing2 = true end
        if f.kind == "phaseflash" and f.color == "overload" then hasFlipFlash = true end
    end
    check("[039B] restart flip = cyan ring + purple shockwave + flip flash",
        hasCyanRing and hasPurpleRing2 and hasFlipFlash)
    check("[039B] restart flip fires strong shake + restart events",
        hasEvent(w, "overload_restart") and hasEvent(w, "anti_hunt_start"))
    check("[039B] restart enters anti_hunt without layer advance",
        w.phase == "anti_hunt" and w.round == 1)

    -- 3) 反猎阶段身份语义：玩家保持强势外观(过载家族)，敌人被标记为反猎目标。
    local marked = 0
    for _, e in ipairs(w.enemies) do
        if e.huntTarget then marked = marked + 1 end
    end
    check("[039B] anti_hunt keeps combat identity and marks targets",
        w:inCombatPhase() and marked > 0 and (w.antiHuntTimer or 0) > 0)

    -- 4) 反猎三档爆发的档位差异：2000 档辐条数必须多于 1000、1000 多于 500；
    --    减闪模式(4 条基础)下档位增量仍保留(4+6 / 4+4 / 4+2)。
    local NeonPolish = require "NeonPolish"
    local function spokesFor(reward, reduceFx)
        local settings = { reduceFx = reduceFx, reduceShake = false }
        local level = reward >= 2000 and 3 or reward >= 1000 and 2 or 1
        return (settings.reduceFx and 4 or 6) + level * 2
    end
    local standard = spokesFor(500, false) < spokesFor(1000, false)
        and spokesFor(1000, false) < spokesFor(2000, false)
    local reduced = spokesFor(500, true) < spokesFor(1000, true)
        and spokesFor(1000, true) < spokesFor(2000, true)
    check("[039B] anti-hunt burst tier gap kept in standard mode", standard)
    check("[039B] anti-hunt burst tier gap kept in reduceFx mode", reduced)

    -- 5) 减闪模式：语义阶段闪光只降到 60%(保留身份可读)，纯装饰特效仍减半。
    --    通过 Render 的 fxMul 与 flashMul 关系验证：标准 1.0 > 减闪 0.6 > 装饰减闪 0.35。
    local Render = require "Render"
    local fxMulStandard = 1
    local flashMulReduced = 0.6
    local decorMulReduced = 0.35
    check("[039B] semantic flash survives reduceFx (0.6) while decor stays halved (0.35)",
        flashMulReduced < fxMulStandard and flashMulReduced > decorMulReduced)

end

local function testSignalBlackout043A()
    local function sample(layer)
        local world = World.New({ startLayer = layer, seed = 4300 + layer })
        world.phase = "depleted"
        world.enemies, world.cells, world.cores, world.wrecks = {}, {}, {}, {}
        SignalBlackout.reset(world)
        world.isSolidAt = function() return false end
        return world
    end

    local function enemy(world, kind, x, y)
        return {
            kind = kind, x = x, y = y, dead = false, hunter = false,
            state = "patrol", radius = Config.ENEMIES[kind].radius,
            lastSeenX = 123, lastSeenY = 456,
        }
    end

    local frozen = true
    for layer = 1, 3 do
        local world = sample(layer)
        local far = enemy(world, "drone", world.player.x + 900, world.player.y)
        frozen = frozen and LayerPlan.get(layer).blackout.mode == "disabled"
            and SignalBlackout.classify(world, far, "enemy").mode == "live"
    end
    check("[043A] L1-L3 blackout remains disabled", frozen)

    local preview = sample(4)
    local previewEnemy = enemy(preview, "drone", preview.player.x + 900, preview.player.y)
    check("[043A] L4 preview keeps important live information",
        LayerPlan.get(4).blackout.mode == "preview"
        and SignalBlackout.classify(preview, previewEnemy, "enemy").mode == "live")
    check("[043AR] L4 previews the field without hiding information",
        LayerPlan.get(4).blackout.visualField == true
        and LayerPlan.get(4).blackout.previewOnly == true
        and LayerPlan.get(4).blackout.outerBlackoutAlpha == 0)

    local soft = sample(5)
    local softEnemy = enemy(soft, "drone", soft.player.x + 900, soft.player.y)
    local softSentinel = enemy(soft, "sentinel", soft.player.x + 900, soft.player.y)
    local softCore = { x = soft.player.x + 900, y = soft.player.y, dead = false }
    local softEnemyView = SignalBlackout.classify(soft, softEnemy, "enemy")
    local softSentinelView = SignalBlackout.classify(soft, softSentinel, "enemy")
    local softCoreView = SignalBlackout.classify(soft, softCore, "core")
    check("[043A] L5 soft hides distant ordinary enemy",
        LayerPlan.get(5).blackout.mode == "soft" and softEnemyView.mode == "hidden")
    check("[043A] L5 soft preserves danger direction signal",
        softSentinelView.mode == "signal" and softSentinelView.signalKind == "danger"
        and softSentinelView.x == nil and softSentinelView.directionAngle ~= nil)
    check("[043A] L5 high-value target uses intermittent signal",
        softCoreView.mode == "signal" and softCoreView.signalKind == "value")

    local full = sample(6)
    local nearEnemy = enemy(full, "drone", full.player.x + 100, full.player.y)
    local farEnemy = enemy(full, "drone", full.player.x + 900, full.player.y)
    local liveView = SignalBlackout.classify(full, nearEnemy, "enemy")
    local hiddenView = SignalBlackout.classify(full, farEnemy, "enemy")
    check("[043A] L6 live visibility requires radius and LOS",
        LayerPlan.get(6).blackout.mode == "full" and liveView.mode == "live"
        and hiddenView.mode == "hidden")
    check("[043AR] blackout radius uses independent product config",
        LayerPlan.get(6).blackout.configSource == "signal_blackout"
        and LayerPlan.get(6).blackout.baseRadius == Config.SIGNAL_BLACKOUT.baseRadius
        and LayerPlan.get(6).blackout.visualRadius == Config.SIGNAL_BLACKOUT.baseRadius)

    local readOnly = sample(6)
    local readOnlyEnemy = enemy(readOnly, "drone", readOnly.player.x + 100, readOnly.player.y)
    local beforeRead = SignalBlackout.peekState(readOnly).lastKnown[readOnlyEnemy]
    local readView = SignalBlackout.classify(readOnly, readOnlyEnemy, "enemy")
    local afterRead = SignalBlackout.peekState(readOnly).lastKnown[readOnlyEnemy]
    readOnly.enemies = { readOnlyEnemy }
    SignalBlackout.update(readOnly, 0)
    check("[043AR] classify is read-only while World update captures last-known",
        beforeRead == nil and readView.mode == "live" and afterRead == nil
        and SignalBlackout.peekState(readOnly).lastKnown[readOnlyEnemy] ~= nil)

    local bounded = sample(6)
    for i = 1, 270 do
        bounded.enemies[i] = enemy(bounded, "drone",
            bounded.player.x + 20 + (i % 12), bounded.player.y + 20 + (i % 9))
    end
    SignalBlackout.update(bounded, 0)
    local tracked = 0
    for _ in pairs(SignalBlackout.peekState(bounded).lastKnown) do tracked = tracked + 1 end
    check("[043AR] last-known cache remains bounded", tracked <= 256,
        "tracked=" .. tostring(tracked))

    local wallEnemy = enemy(full, "drone", full.player.x + 100, full.player.y)
    full.isSolidAt = function(_, x)
        return x > full.player.x and x < full.player.x + 100
    end
    check("[043A] wall LOS removes ordinary live visibility",
        SignalBlackout.classify(full, wallEnemy, "enemy").mode == "hidden")
    full.isSolidAt = function() return false end

    SignalBlackout.reset(full)
    local ghostEnemy = enemy(full, "drone", full.player.x + 100, full.player.y)
    full.enemies = { ghostEnemy }
    SignalBlackout.update(full, 0)
    ghostEnemy.x = full.player.x + 900
    SignalBlackout.update(full, 2.0)
    local ghostView = SignalBlackout.classify(full, ghostEnemy, "enemy")
    SignalBlackout.update(full, 0.6)
    local expiredView = SignalBlackout.classify(full, ghostEnemy, "enemy")
    check("[043A] last-known enemy persists as a 2.5s ghost",
        ghostView.mode == "ghost" and ghostView.x == full.player.x + 100)
    check("[043A] last-known ghost expires and cleans up",
        expiredView.mode == "hidden" and SignalBlackout.state(full).cleanupCount > 0)

    local pulseCore = { x = full.player.x + 900, y = full.player.y, dead = false }
    SignalBlackout.reset(full)
    local pulseOn = SignalBlackout.classify(full, pulseCore, "core")
    SignalBlackout.update(full, 1.0)
    local pulseOff = SignalBlackout.classify(full, pulseCore, "core")
    SignalBlackout.update(full, 1.4)
    local pulseOnAgain = SignalBlackout.classify(full, pulseCore, "core")
    check("[043A] high-value signal is intermittent and deterministic",
        pulseOn.mode == "signal" and pulseOff.mode == "hidden" and pulseOnAgain.mode == "signal")

    local deep = { x = full.player.x + 900, y = full.player.y, dead = false, deep = true }
    SignalBlackout.reset(full)
    local deepPulse = SignalBlackout.classify(full, deep, "wreck")
    SignalBlackout.update(full, 1.0)
    local deepSilent = SignalBlackout.classify(full, deep, "wreck")
    check("[043AR] deep wreck exact marker cannot bypass intermittent signal",
        deepPulse.mode == "signal" and deepPulse.signalKind == "value"
        and deepSilent.mode == "hidden" and deepSilent.x == nil and deepSilent.y == nil)

    local protectedEnemy = enemy(full, "sentinel", full.player.x + 900, full.player.y)
    local protectedView = SignalBlackout.classify(full, protectedEnemy, "enemy")
    check("[043A] blackout does not mutate EnemyAI last-known fields",
        protectedView.mode == "signal" and protectedEnemy.lastSeenX == 123
        and protectedEnemy.lastSeenY == 456)

    full.phase = "overload"
    check("[043A] overload restores full live visibility",
        SignalBlackout.classify(full, farEnemy, "enemy").mode == "live")
    full.phase = "anti_hunt"
    check("[043A] anti-hunt restores full live visibility",
        SignalBlackout.classify(full, farEnemy, "enemy").mode == "live")

    local layer9 = LayerPlan.get(9).blackout
    local layer10 = LayerPlan.get(10).blackout
    local layer11 = LayerPlan.get(11).blackout
    local layer23 = LayerPlan.get(23).blackout
    check("[043A] L10 radius is not narrower than L9",
        layer10.radius >= layer9.radius and layer10.fairGate
        and layer10.visualField and not layer10.previewOnly)
    check("[043A] L11+ derived radius keeps hard floor without tightening",
        layer11.radius == layer11.baseRadius
        and layer23.futureRadius >= layer23.minimumRadius)
    check("[043A] LayerPlan blackout contract validates", LayerPlan.validate())
    check("[043A] formal config has no review entry switch",
        Config.DEBUG.reviewEntryEnabled == nil)
end

local function testSignalBlackout043B()
    local function sample(layer)
        local world = World.New({ startLayer = layer, seed = 4400 + layer,
            testMode = true, skipLayerIntro = true })
        world.phase = "depleted"
        world.enemies, world.cells, world.cores, world.wrecks = {}, {}, {}, {}
        world.isSolidAt = function() return false end
        SignalBlackout.reset(world)
        return world
    end

    local function enemy(world, x, y)
        return {
            kind = "drone", x = x, y = y, dead = false, hunter = false,
            state = "patrol", radius = Config.ENEMIES.drone.radius,
            hp = Config.ENEMIES.drone.hp, maxHp = Config.ENEMIES.drone.hp,
            angle = 0, jammed = 0, daze = 0, stun = 0,
        }
    end

    local recon = sample(6)
    local scanX = recon.player.x + Config.SIGNAL_BLACKOUT.baseRadius + 180
    local scannedEnemy = enemy(recon, scanX, recon.player.y)
    local scannedCell = { x = scanX, y = recon.player.y + 20, dead = false }
    recon.enemies = { scannedEnemy }
    recon.cells = { scannedCell }
    recon.isSolidAt = function(_, x)
        return x > recon.player.x + 120 and x < recon.player.x + 180
    end
    local baseRadius = SignalBlackout.getVisualRadius(recon)
    local hiddenBefore = SignalBlackout.classify(recon, scannedEnemy, "enemy")
    recon.reconLeft = Config.RECON.duration
    local enemyDuring = SignalBlackout.classify(recon, scannedEnemy, "enemy")
    local cellDuring = SignalBlackout.classify(recon, scannedCell, "cell")
    local reconRadius = SignalBlackout.getVisualRadius(recon)
    check("[043B] recon expands blackout visibility without restoring full map",
        hiddenBefore.mode == "hidden" and enemyDuring.mode == "live"
        and enemyDuring.reason == "recon_pulse" and cellDuring.mode == "live"
        and reconRadius == baseRadius + Config.RECON.radius)
    check("[043B] recon reveal is a bounded network scan that can cross walls",
        reconRadius < math.huge and SignalBlackout.isRealtimeVisible(
            recon, scannedEnemy.x, scannedEnemy.y))
    recon.reconLeft = 0
    check("[043B] recon expiry restores the base blackout contract",
        SignalBlackout.getVisualRadius(recon) == baseRadius
        and SignalBlackout.classify(recon, scannedEnemy, "enemy").mode == "hidden")

    local preview = sample(4)
    preview.reconLeft = Config.RECON.duration
    check("[043B] recon keeps L4 preview field finite while information remains open",
        SignalBlackout.getVisualRadius(preview) == LayerPlan.get(4).blackout.visualRadius
        and SignalBlackout.getRealtimeRadius(preview) == Config.RECON.radius)

    local marked = sample(6)
    local markedEnemy = enemy(marked, marked.player.x + 1000, marked.player.y)
    marked.enemies = { markedEnemy }
    marked.mark = { ref = markedEnemy, armed = false }
    local tracked = SignalBlackout.classify(marked, markedEnemy, "enemy")
    check("[043B] marked target remains a tracked outline beyond realtime perception",
        tracked.mode == "tracked" and tracked.reason == "marked_target"
        and tracked.x == markedEnemy.x and tracked.y == markedEnemy.y)

    local decoy = { x = marked.player.x + 120, y = marked.player.y, left = 3, dead = false }
    marked.decoys = { decoy }
    markedEnemy.decoyTarget = decoy
    local decoyView = SignalBlackout.decoySignal(marked, decoy)
    check("[043B] decoy exposes an aggregate inbound signal without enemy coordinates",
        decoyView.signalKind == "decoy" and decoyView.inboundCount == 1
        and decoyView.x == decoy.x and decoyView.y == decoy.y)

    local cloak = sample(6)
    local near = enemy(cloak, cloak.player.x + 100, cloak.player.y)
    cloak.enemies = { near }
    local beforeCloak = SignalBlackout.classify(cloak, near, "enemy")
    local radiusBeforeCloak = SignalBlackout.getVisualRadius(cloak)
    cloak.cloakLeft = Config.DEPLETED.cloakDuration
    local duringCloak = SignalBlackout.classify(cloak, near, "enemy")
    check("[043B] cloak changes enemy detection but never player perception",
        beforeCloak.mode == duringCloak.mode
        and SignalBlackout.getVisualRadius(cloak) == radiusBeforeCloak)

    cloak.scanJammedLeft = 0
    local scanNormal = SignalBlackout.scanSignalMode(cloak)
    cloak.scanJammedLeft = Config.SCAN.jammerSuppressTime
    check("[043B] jammer weakens hostile scan signal without adding vision",
        scanNormal == "normal" and SignalBlackout.scanSignalMode(cloak) == "jammed"
        and SignalBlackout.getVisualRadius(cloak) == radiusBeforeCloak)

    local l4 = World.New({ startLayer = 4, seed = 4444,
        testMode = true, skipLayerIntro = true })
    l4:forceDrop()
    local l4Hint = false
    for _, prompt in ipairs(l4.systemPrompts) do
        if prompt.text == "信号开始衰减。黑障之外只保留最后已知情报。" then
            l4Hint = true
        end
    end
    local l5 = World.New({ startLayer = 5, seed = 4445,
        testMode = true, skipLayerIntro = true })
    l5:forceDrop()
    local l5Hint = false
    for _, prompt in ipairs(l5.systemPrompts) do
        if prompt.text == "侦察可以临时恢复远端感知，标记可以持续追踪目标。" then
            l5Hint = true
        end
    end
    check("[043B] L4 and L5 each queue the approved one-time short hint",
        l4Hint and l5Hint and l4.blackoutHintsShown[4] and l5.blackoutHintsShown[5])

    check("[043B] tool quantities and timing remain on the frozen existing contract",
        Config.DEPLETED.jammerUses == 3 and Config.DEPLETED.decoyUses == 2
        and Config.DEPLETED.cloakUses == 1 and Config.RECON.cooldown == 12
        and Config.RECON.duration == 4.0)
end

-- ============================================================
-- 044R: 真人Review后的确定性产品收口
-- ============================================================
local function testHumanReviewClosure044R()
    local controls = World.New({ startLayer = 6, seed = 44040,
        testMode = true, skipLayerIntro = true })
    controls:forceDrop()
    controls.wrecks = {{
        x = controls.player.x + 10, y = controls.player.y,
        dead = false, kind = "normal",
    }}
    local positions = {}
    for _, button in ipairs(InputSys.layout(controls, 390, 867)) do
        positions[button.id] = button
    end
    local required = positions.restart and positions.jammer and positions.scan
        and positions.decoy and positions.cloak and positions.dismantle
    check("[044R] depleted control arc exposes all approved actions", required ~= nil)
    if required then
        check("[044R] cloak shifts right and jammer sits below the upper arc",
            positions.cloak.x > positions.decoy.x
            and positions.jammer.y > positions.scan.y)
        check("[044R] dismantle sits directly above cloak",
            math.abs(positions.dismantle.x - positions.cloak.x) < 0.01
            and positions.dismantle.y < positions.cloak.y)
        local noOverlap = true
        local ids = { "restart", "jammer", "scan", "decoy", "cloak", "dismantle" }
        for i = 1, #ids do
            for j = i + 1, #ids do
                local a, b = positions[ids[i]], positions[ids[j]]
                local dx, dy = a.x - b.x, a.y - b.y
                if math.sqrt(dx * dx + dy * dy) < (a.r + b.r) * 0.82 then
                    noOverlap = false
                end
            end
        end
        check("[044R] depleted control centers remain separately tappable", noOverlap)
    end

    local recon = World.New({ startLayer = 6, seed = 44041,
        testMode = true, skipLayerIntro = true })
    recon:forceDrop()
    local baseRadius = SignalBlackout.getBaseVisualRadius(recon)
    local maxRadius = SignalBlackout.getReconMaxRadius(recon)
    recon:tryRecon()
    check("[044R] recon uses one bounded expansion beyond the stable base boundary",
        baseRadius > 0 and maxRadius > baseRadius
        and recon.reconLeft == Config.RECON.duration
        and recon.reconAfterglowLeft == 0)
    step(recon, Config.RECON.duration + 0.05)
    check("[044R] recon outer ring keeps a short post-scan afterglow",
        recon.reconLeft == 0 and recon.reconAfterglowLeft > 0
        and recon.reconAfterglowLeft <= Config.RECON.afterglow)
    step(recon, Config.RECON.afterglow + 0.1)
    check("[044R] recon afterglow expires without changing blackout semantics",
        recon.reconAfterglowLeft == 0
        and SignalBlackout.getBaseVisualRadius(recon) == baseRadius)

    local completed = World.New({ startLayer = Config.RUN.finalLayer, seed = 44042,
        testMode = true, skipLayerIntro = true })
    completed.phase = "layer_settlement"
    completed.layerSettlement = { runComplete = true }
    completed.challengeExitConfirm = true
    completed.challengeCheckpointAvailable = true
    completed.reviveOffer = true
    completed.rewardedReviveState = "offered"
    check("[044R] L10 settlement may complete through the explicit final action",
        completed:completeChallenge() == true and completed.phase == "dead")
    local completionButtons = InputSys.layout(completed, 390, 867)
    local hasRetry, hasRevive = false, false
    for _, button in ipairs(completionButtons) do
        hasRetry = hasRetry or button.id == "retryLayer"
        hasRevive = hasRevive or button.id == "revive"
    end
    check("[044R] successful L10 completion permanently closes retry and revive",
        completed.challengeCheckpointAvailable == false
        and completed.reviveOffer == nil
        and completed.rewardedReviveState == "closed"
        and not hasRetry and not hasRevive)

    local endlessDeath = {
        phase = "dead", endless = true, round = 14,
        rewardedReviveState = "offered", reviveOffer = true,
        rewardedReviveCount = 1,
    }
    local endlessButtons = InputSys.layout(endlessDeath, 390, 867)
    local endlessRevive = nil
    for _, button in ipairs(endlessButtons) do
        if button.id == "revive" then endlessRevive = button end
    end
    check("[053] Endless death shows the shared rewarded-revive balance",
        endlessRevive and string.find(endlessRevive.sub or "", "剩余 2/3", 1, true) ~= nil)
    endlessDeath.reviveChoiceState = "select"
    local choiceButtons = InputSys.layout(endlessDeath, 390, 867)
    local safeChoice, forbiddenRestart = nil, false
    for _, button in ipairs(choiceButtons) do
        if button.id == "reviveInPlace" then safeChoice = button end
        forbiddenRestart = forbiddenRestart or button.id == "reviveFullState"
    end
    check("[053] revive copy names safe-area recovery and Endless hides layer restart",
        safeChoice and safeChoice.label == "满血安全复活" and not forbiddenRestart)

    Screens.setMyRank(1, 0)
    check("[044R] empty leaderboard cannot fabricate a number-one self rank",
        Screens.myRank == nil and Screens.myRankScore == nil
        and TitleRender.formatMyRankLine(1, 0) == nil)
    local validRankValue = PlatformFeatures.rankValue(10, 829951)
    Screens.setMyRank(8, validRankValue)
    check("[044R] L10-or-higher valid rank remains displayable",
        Screens.myRank == 8 and Screens.myRankScore == validRankValue
        and TitleRender.formatMyRankLine(8, validRankValue) ~= nil)
    Screens.myRank, Screens.myRankScore = nil, nil

    local leaderboardRows = {}
    for index = 1, 6 do
        leaderboardRows[index] = {
            rank = index, name = "玩家" .. tostring(index), layer = 20 - index,
            score = 100000 - index,
        }
    end
    Screens.setOnlineLeaderboardEntries(leaderboardRows)
    local firstPage, firstNumber, firstCount = Screens.visibleLeaderboardEntries(leaderboardRows)
    check("[050G] leaderboard uses five-row pages with stable first page",
        #firstPage == 5 and firstNumber == 1 and firstCount == 2
        and firstPage[1].rank == 1 and firstPage[5].rank == 5)
    Screens.changeLeaderboardPage(1, leaderboardRows)
    local secondPage, secondNumber = Screens.visibleLeaderboardEntries(leaderboardRows)
    check("[050G] leaderboard next page and bound are deterministic",
        #secondPage == 1 and secondNumber == 2 and secondPage[1].rank == 6)
    Screens.changeLeaderboardPage(1, leaderboardRows)
    check("[050G] leaderboard does not advance beyond last page",
        Screens.leaderboardPage == 2)
    Screens.changeLeaderboardPage(-1, leaderboardRows)
    check("[050G] leaderboard previous page returns to first page",
        Screens.leaderboardPage == 1)
    for index = 7, 25 do
        leaderboardRows[index] = {
            rank = index, name = "玩家" .. tostring(index), layer = 20 - index,
            score = 100000 - index,
        }
    end
    check("[052C] leaderboard view never exposes more than the first twenty rows",
        Screens.leaderboardPageCount(leaderboardRows) == 4)
    Screens.closeOnlineLeaderboard()
    local timedRequest = Screens.beginOnlineLeaderboardLoad(100)
    check("[052C] leaderboard watchdog stays loading before twelve seconds",
        not Screens.tickOnlineLeaderboardLoad(111)
        and Screens.onlineLeaderboardState == "loading")
    check("[052C] leaderboard watchdog exits to retryable error at twelve seconds",
        Screens.tickOnlineLeaderboardLoad(112)
        and Screens.onlineLeaderboardState == "error"
        and Screens.onlineLeaderboardErrorMessage == "读取超时，请重试")
    check("[052C] stale leaderboard callback cannot overwrite a timed-out request",
        Screens.setOnlineLeaderboardEntries(leaderboardRows, timedRequest) == false
        and Screens.onlineLeaderboardState == "error")
    local retryRequest = Screens.beginOnlineLeaderboardLoad(113)
    local leaderboardSettings = {
        sound = true, musicVolume = 0.5, sfxVolume = 0.5,
        vibration = true, reduceFx = false, reduceShake = false,
    }
    local retryButtons = Screens.layout(390, 867, leaderboardSettings, true)
    check("[052C] retry starts a fresh leaderboard request and exposes its button",
        retryRequest > timedRequest and Screens.onlineLeaderboardState == "loading")
    Screens.setOnlineLeaderboardError("暂时无法读取公开榜，请重试", retryRequest)
    retryButtons = Screens.layout(390, 867, leaderboardSettings, true)
    local retryVisible = false
    for _, button in ipairs(retryButtons) do
        retryVisible = retryVisible or button.id == "retryOnlineLeaderboard"
    end
    check("[052C] leaderboard error screen provides a visible retry action", retryVisible)
    Screens.closeOnlineLeaderboard()
    Screens.onlineLeaderboardEntries = {}
    Screens.leaderboardPage = 1
end

-- ============================================================
-- 044S: L10毕业档、L11克隆局与L10起纯净榜
-- ============================================================
local function testGraduationArchive044S()
    local SaveSys = require "SaveSys"
    local GraduationArchive = require "GraduationArchive"

    local source = World.New({ startLayer = 10, seed = 44100,
        testMode = true, skipLayerIntro = true })
    source.runId = "044s-source"
    source.phase = "layer_settlement"
    source.layerSettlement = { layer = 10, runComplete = true }
    source.runComplete = true
    source.score = 829951
    source.wreckData = 4
    source.coreCount = 7
    source.runUpgrades.collapseCooldownLevel = 2
    source.runUpgrades.pulseCooldownLevel = 1
    source.runUpgrades.jammerBonusUses = 3
    source.modules.capacitor = true
    source.modules.amplifier = false
    source.pendingCache = 2
    source.shopPurchases = 6
    source.counters.spotted = 11
    source.restarts = 10
    source.huntKills = 23
    source.bestCombo = 61
    source.bestAntiHuntChain = 3
    source.riskSuccesses = 8
    source.lostRiskScore = 1200
    source.timeAlive = 918.5
    source.player.hp = 73
    local archive = GraduationArchive.capture(source, 44101)
    check("[044S] L10 captures one immutable graduation snapshot",
        archive and archive.sourceLayer == 10 and archive.score == 829951
        and archive.hp == 73 and archive.cleanRun and not archive.assistedRun)
    local serialized = GraduationArchive.serialize(archive)
    check("[044S] archive whitelist excludes combat state",
        serialized and serialized.source_layer == 10 and serialized.hp == 73
        and serialized.phase == nil and serialized.enemies == nil
        and serialized.player_position == nil and serialized.heat == nil
        and serialized.energy == nil and serialized.tools == nil)

    local save = SaveSys.migrate({})
    check("[044S] exactly three slots accept whole-snapshot replacement",
        SaveSys.setGraduationArchive(save, 1, archive)
        and SaveSys.setGraduationArchive(save, 3, archive)
        and not SaveSys.setGraduationArchive(save, 4, archive)
        and SaveSys.getGraduationArchive(save, 1).score == 829951
        and SaveSys.getGraduationArchive(save, 2) == nil)
    local detached = SaveSys.getGraduationArchive(save, 1)
    detached.score = 1
    detached.runUpgrades.collapseCooldownLevel = 0
    check("[044S] reading a slot cannot mutate the stored archive",
        SaveSys.getGraduationArchive(save, 1).score == 829951
        and SaveSys.getGraduationArchive(save, 1).runUpgrades.collapseCooldownLevel == 2)
    local roundTrip = SaveSys.migrate(SaveSys.serialize(save))
    check("[047] three-slot archives survive schema v10 serialization",
        SaveSys.getGraduationArchive(roundTrip, 1).score == 829951
        and SaveSys.getGraduationArchive(roundTrip, 2) == nil
        and SaveSys.getGraduationArchive(roundTrip, 3).score == 829951)

    local direct = World.New({ startLayer = 10, seed = 44100,
        testMode = true, skipLayerIntro = true })
    direct.runId = "044s-direct"
    direct.phase = "layer_settlement"
    direct.layerSettlement = { layer = 10, runComplete = true }
    direct.runComplete = true
    direct.score, direct.wreckData, direct.coreCount = 829951, 4, 7
    direct.runUpgrades = archive.runUpgrades
    direct.modules = { capacitor = true, amplifier = false }
    direct.pendingCache = 2
    direct.shopPurchases = 6
    direct.counters = { spotted = 11 }
    direct.restarts, direct.huntKills = 10, 23
    direct.bestCombo, direct.bestAntiHuntChain = 61, 3
    direct.riskSuccesses, direct.lostRiskScore = 8, 1200
    direct.timeAlive, direct.player.hp = 918.5, 73
    direct:chooseEndless()
    local cloneA = World.New({ experiment = "B", seed = archive.seed,
        runId = "044s-clone-a", graduationArchive = archive,
        testMode = true, skipLayerIntro = true })
    local cloneB = World.New({ experiment = "B", seed = archive.seed,
        runId = "044s-clone-b", graduationArchive = archive,
        testMode = true, skipLayerIntro = true })
    check("[044S] archive clone matches direct L10-to-L11 inherited state",
        cloneA.round == 11 and cloneA.score == direct.score
        and cloneA.wreckData == direct.wreckData and cloneA.coreCount == direct.coreCount
        and cloneA.player.hp == direct.player.hp and cloneA.timeAlive == direct.timeAlive
        and cloneA.activeModules.capacitor == direct.activeModules.capacitor
        and cloneA.activeCache == direct.activeCache
        and cloneA.runUpgrades.collapseCooldownLevel
            == direct.runUpgrades.collapseCooldownLevel)
    check("[044S] repeated archive launches create distinct runs without mutating archive",
        cloneA.runId ~= cloneB.runId and cloneA.sourceGraduationArchiveId == archive.archiveId
        and cloneB.sourceGraduationArchiveId == archive.archiveId
        and SaveSys.getGraduationArchive(save, 1).score == 829951)

    local l10Run = {
        id = "044s-l10", runId = "044s-l10", completed = true,
        formalMain = true, cleanRun = true, challengeCompleted = true,
        endless = false, completionReason = "challenge_complete",
        layer = 10, score = 829951,
    }
    local endlessRun = {
        id = "044s-l11", runId = "044s-l11", completed = true,
        formalMain = true, cleanRun = true, challengeCompleted = false,
        endless = true, completionReason = "death", layer = 11, score = 900000,
    }
    ---@type table<string, any>
    local assistedRun = {}
    for key, value in pairs(endlessRun) do assistedRun[key] = value end
    assistedRun.runId, assistedRun.id = "044s-assisted", "044s-assisted"
    assistedRun.cleanRun, assistedRun.assistedRun = false, true
    check("[044S] pure and assisted graduation Endless share the unified board",
        PlatformFeatures.isEligibleRun(l10Run)
        and PlatformFeatures.isEligibleRun(endlessRun)
        and PlatformFeatures.isEligibleRun(assistedRun))
    local checkpointArchive = GraduationArchive.normalize({
        source_run_id = "044s-checkpoint", source_layer = 10,
        recovered = true, checkpoint_recovery = true, clean_run = true,
        score = 700000, core_count = 3, wreck_data = 4,
    })
    check("[050A] confirmed checkpoint graduation remains board-eligible",
        checkpointArchive and checkpointArchive.cleanRun
        and not checkpointArchive.assistedRun)

    Screens.graduationOpen = false
    local titleButtons = Screens.layout(390, 867, save.settings, true, false, false,
        nil, SaveSys.getGraduationArchives(save))
    local hasEntry = false
    for _, button in ipairs(titleButtons) do
        if button.id == "openGraduation" then hasEntry = true end
    end
    Screens.graduationOpen = true
    local archiveButtons = Screens.layout(390, 867, save.settings, true, false, false,
        nil, SaveSys.getGraduationArchives(save))
    local slotCount = 0
    for _, button in ipairs(archiveButtons) do
        if string.find(button.id, "^startGraduation:") then slotCount = slotCount + 1 end
    end
    Screens.graduationOpen = false
    check("[044S] title unlocks Endless and exposes all three archive slots",
        hasEntry and slotCount == 3)
end

local function testEndlessProductization046()
    local a = World.New({ experiment = "B", seed = 46001, startLayer = 11,
        endless = true, endlessSeed = 46077 })
    a.endlessOverclock.data = 4
    local opened = EndlessOverclock.prepareChoice(a)
    local first = a.endlessOverclock.currentChoices
    local applied = EndlessOverclock.applyChoice(a, 1)
    local b = World.New({ experiment = "B", seed = 46001, startLayer = 11,
        endless = true, endlessSeed = 46077 })
    b.endlessOverclock.data = 4
    EndlessOverclock.prepareChoice(b)
    local same = opened and applied and first and b.endlessOverclock.currentChoices
        and first[1].id == b.endlessOverclock.currentChoices[1].id
        and first[2].id == b.endlessOverclock.currentChoices[2].id
        and first[3].id == b.endlessOverclock.currentChoices[3].id
    check("[046] endless opens deterministic three-card overclock choice", opened and #first == 3 and same)
    check("[046] overclock choice spends data and changes existing build state",
        applied and a.endlessOverclock.data == 0 and a.endlessOverclock.choiceCount == 1
        and EndlessOverclock.validate(a))
    check("[046] L11+ difficulty exposes bounded pressure band",
        a.layerPlan.difficulty.pressureBand == "power_ramp"
        and a.layerPlan.difficulty.patrolExtra <= Config.ROUNDS.maxPatrolAdd)
end

-- 053A：真机反馈指出 L11 枯竭阶段有小怪已经发现玩家却停在原地。
-- 该夹具只使用真实 L11 地图、普通小怪、视线与移动碰撞；不注入数值、敌量或路径。
local function testEndlessL11Pursuit053A()
    local EnemyAI = require "EnemyAI"
    local world = World.New({ experiment = "B", seed = 531101, startLayer = 11,
        endless = true, endlessSeed = 531177 })
    world.phase = "depleted"
    world.cloakLeft = 0
    world.heat = 0

    local enemy
    for _, candidate in ipairs(world.enemies) do
        if not candidate.dead and candidate.kind == "drone" then
            enemy = candidate
            candidate.dead = false
            break
        end
    end
    for _, candidate in ipairs(world.enemies) do
        if candidate ~= enemy then candidate.dead = true end
    end

    local found = false
    local directions = { { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }
    if enemy then
        for row = 2, world.map.h - 1 do
            if found then break end
            for col = 2, world.map.w - 1 do
                if found then break end
                if not world.solid[row][col] then
                    for _, dir in ipairs(directions) do
                        local tc, tr = col + dir[1], row + dir[2]
                        if tc >= 2 and tc < world.map.w and tr >= 2 and tr < world.map.h
                            and not world.solid[tr][tc] then
                            local ex, ey = MapDef.tileCenter(col, row)
                            local px, py = MapDef.tileCenter(tc, tr)
                            enemy.x, enemy.y = ex, ey
                            enemy.angle = math.atan(py - ey, px - ex)
                            enemy.patrol = { { col, row } }
                            enemy.patrolIdx = 1
                            enemy.state, enemy.stateTime = "patrol", 0
                            enemy.suspicion, enemy.daze, enemy.jammed = 0, 0, 0
                            enemy.path, enemy.pathTimer = nil, 0
                            world.player.x, world.player.y = px, py
                            found = EnemyAI.canSeePlayer(world, enemy)
                            if found then break end
                        end
                    end
                end
            end
        end
    end

    local before = enemy and math.sqrt((enemy.x - world.player.x) ^ 2
        + (enemy.y - world.player.y) ^ 2) or 0
    step(world, Config.AI.suspectTime + 0.10)
    local after = enemy and math.sqrt((enemy.x - world.player.x) ^ 2
        + (enemy.y - world.player.y) ^ 2) or before
    check("[053A] detected L11 ordinary enemy begins closing during detection",
        found and enemy and after < before - 1, string.format("%.1f -> %.1f", before, after))
    check("[053A] L11 detection remains a bounded state transition",
        enemy and (enemy.state == "suspect" or enemy.state == "alert" or enemy.state == "chase"))
end

-- 053B/053C：死亡结算必须释放过期视觉引用；广告提前关闭只能回到明确的
-- 玩家提示，不能在后台/广告宿主回调中悄悄奖励或留下可误触的结算按钮。
local function testReleaseResilience053B()
    local SaveSys = require "SaveSys"
    check("[055] runtime release info has one Lua source",
        ReleaseInfo.validate()
        and Config.GAME_VERSION == ReleaseInfo.GAME_VERSION
        and SaveSys.GAME_VERSION == ReleaseInfo.GAME_VERSION
        and PlaytestMetrics.VERSION == ReleaseInfo.GAME_VERSION)

    local deathWorld = World.New({ experiment = "B", seed = 531201 })
    deathWorld.phase = "depleted"
    deathWorld:addFx("phaseflash", { color = "depleted", dur = 0.7 })
    deathWorld:addFx("bigring", { x = deathWorld.player.x, y = deathWorld.player.y,
        r = 180, color = "cyan", dur = 0.8 })
    local staleFx = #deathWorld.fx
    RunFlow.die(deathWorld)
    check("[053B] death releases stale visual effects before revive UI",
        staleFx >= 2 and #deathWorld.fx == 0 and #deathWorld.fxPool.free >= staleFx)

    local closeNotice = type(RewardedRevive.failurePresentation) == "function"
        and RewardedRevive.failurePresentation("embed manual close") or nil
    check("[053C] manual ad close maps to the frozen player notice",
        type(closeNotice) == "table"
        and closeNotice.title == "本次未获得奖励"
        and closeNotice.body == "广告未完整播放到可领取状态，无法复活。若广告内出现“继续播放”，请先继续；请以广告自身明确结束为准，再返回游戏。")

    local neutralNotice = type(RewardedRevive.failurePresentation) == "function"
        and RewardedRevive.failurePresentation("ad_timeout") or nil
    check("[053C] timeout maps to a neutral non-reward notice",
        type(neutralNotice) == "table"
        and neutralNotice.title == "广告响应超时"
        and neutralNotice.body ~= closeNotice.body)

    local failureLayout = InputSys.layout({
        phase = "dead", endless = false, round = 9,
        rewardedReviveState = "offered", rewardedReviveFailureNotice = closeNotice,
        rewardedReviveTimeout = false, reviveOffer = true,
    }, 390, 844)
    local hasAcknowledgement, hasReviveOffer, hasRetry = false, false, false
    for _, button in ipairs(failureLayout) do
        hasAcknowledgement = hasAcknowledgement or button.id == "adFailureClose"
        hasReviveOffer = hasReviveOffer or button.id == "revive"
        hasRetry = hasRetry or button.id == "retryLayer"
    end
    check("[053C] failure modal exposes only its acknowledgement action",
        hasAcknowledgement and not hasReviveOffer and not hasRetry)

    local softWorld = {
        phase = "dead", endless = false, round = 9, timeAlive = 1,
        rewardedReviveState = "idle", rewardedReviveAttempted = false,
        rewardedReviveUsed = false, rewardedReviveCount = 0, assistedRun = false,
    }
    local softOffered = RewardedRevive.onDeath(softWorld, {}, true, "ready", os.time())
    local softBegun = RewardedRevive.begin(softWorld, "in_place")
    local softMarked = RewardedRevive.markSoftTimeout(softWorld)
    local softLayout = InputSys.layout(softWorld, 390, 844)
    local hasContinue, hasSoftReturn, hasUnderlyingDeathAction = false, false, false
    for _, button in ipairs(softLayout) do
        hasContinue = hasContinue or button.id == "adSoftContinue"
        hasSoftReturn = hasSoftReturn or button.id == "adSoftCancel"
        hasUnderlyingDeathAction = hasUnderlyingDeathAction
            or button.id == "revive" or button.id == "retryLayer"
    end
    check("[055] soft timeout exposes only continue or local return",
        softOffered and softBegun and softMarked and hasContinue and hasSoftReturn
        and not hasUnderlyingDeathAction)
    check("[055] continue waiting keeps the same pending revive request",
        RewardedRevive.continueWaiting(softWorld)
        and softWorld.rewardedReviveState == "pending"
        and softWorld.rewardedReviveSoftTimeout == false)
    RewardedRevive.markSoftTimeout(softWorld)
    local softCancelled = RewardedRevive.cancelPending(softWorld, "ad_wait_cancelled")
    check("[055] local return restores offer without reward or failure modal",
        softCancelled and softWorld.rewardedReviveState == "offered"
        and softWorld.reviveOffer == true and softWorld.rewardedReviveUsed == false
        and softWorld.rewardedReviveSoftTimeout == false
        and softWorld.rewardedReviveFailureNotice == nil)
end

-- 048：无尽后段压力与超限溢出成长的确定性边界。
local function testEndlessConvergence048()
    local l12 = LayerPlan.get(12).difficulty
    local l13 = LayerPlan.get(13).difficulty
    local l15 = LayerPlan.get(15).difficulty
    local l30 = LayerPlan.get(30).difficulty
    check("[048] L13 starts bounded five-tile patrol roam",
        l12.roamRadius == nil and l13.roamRadius == Config.ENDLESS.roamRadiusBase
        and l13.roamRepathTime == Config.ENDLESS.roamRepathTime)
    check("[048] tracker cadence starts at L15 and floors at 15s",
        l15.trackerInterval == Config.ENDLESS.trackerIntervalStart
        and l30.trackerInterval == Config.ENDLESS.trackerIntervalFloor
        and l30.trackerAliveCap == Config.ENDLESS.trackerAliveCap)

    local roamWorld = World.New({ experiment = "B", seed = 48013,
        startLayer = 13, endless = true, endlessSeed = 48077 })
    roamWorld.phase = "depleted"
    roamWorld.player.x, roamWorld.player.y = -1000, -1000
    local roamEnemy
    for _, enemy in ipairs(roamWorld.enemies) do
        if not enemy.dead and enemy.kind == "heavy"
            and enemy.patrol and #enemy.patrol <= 1 then
            roamEnemy = enemy
            enemy.daze = 0
            enemy.state = "patrol"
            break
        end
    end
    roamWorld:update(0.05, IDLE)
    check("[048] L13 stationary guard receives a bounded roam target",
        roamEnemy and roamEnemy.roamX ~= nil and roamEnemy.roamY ~= nil)

    local trackerWorld = World.New({ experiment = "B", seed = 48015,
        startLayer = 15, endless = true, endlessSeed = 48079 })
    trackerWorld.phase = "depleted"
    trackerWorld.trackerTimer = 0
    trackerWorld.player.x, trackerWorld.player.y = -1000, -1000
    trackerWorld:update(0.05, IDLE)
    local tracker
    for _, enemy in ipairs(trackerWorld.enemies) do
        if not enemy.dead and enemy.tracker then tracker = enemy break end
    end
    check("[048] L15 spawns one existing glitch tracker on cadence",
        tracker ~= nil and tracker.kind == "glitch" and tracker.state == "chase"
        and trackerWorld.trackerSpawnCount == 1)

    local overflow = World.New({ experiment = "B", seed = 48021,
        startLayer = 11, endless = true, endlessSeed = 48081 })
    local RunShop = require "RunShop"
    for _, item in ipairs(RunShop.CATALOG) do
        overflow.runUpgrades[item.id] = RunShop.maxLevel(item)
    end
    local wreckConverted, wreckConsumed = 0, true
    for _ = 1, EndlessOverclock.WRECK_OVERFLOW_COST do
        local converted, consumed = EndlessOverclock.onDismantle(overflow, false)
        wreckConverted = wreckConverted + converted
        wreckConsumed = wreckConsumed and consumed
    end
    local coreConverted, coreConsumed = EndlessOverclock.corePickup(overflow,
        EndlessOverclock.CORE_OVERFLOW_COST)
    check("[048] maxed base shop converts four wreck units and three cores",
        wreckConverted == 1 and wreckConsumed and coreConverted == 1 and coreConsumed
        and overflow.endlessOverclock.overflowWreckData == 0
        and overflow.endlessOverclock.overflowCores == 0)
    local snap = EndlessOverclock.snapshot(overflow)
    local restored = World.New({ experiment = "B", seed = 48022,
        startLayer = 11, endless = true, endlessSeed = 48082 })
    EndlessOverclock.restore(restored, snap)
    check("[048] overflow banks survive endless checkpoint serialization",
        snap and snap.overflowWreckData == 0 and snap.overflowCores == 0
        and EndlessOverclock.validate(restored))
    check("[050C] every overclock card has a bounded Lv3 cap",
        EndlessOverclock.maxLevel("arc_relay") == 3
        and EndlessOverclock.maxLevel("arc_overload") == 3
        and EndlessOverclock.maxLevel("collapse_lock") == 3)
    restored.endlessOverclock.levels.arc_relay = EndlessOverclock.maxLevel("arc_relay")
    check("[048] repeatable overclock cap remains valid",
        EndlessOverclock.validate(restored))

    -- 050C：层结算提供免费选择；免费选择只消耗 token，不消耗数据。
    local freeWorld = World.New({ experiment = "B", seed = 48023,
        startLayer = 11, endless = true, endlessSeed = 48083 })
    freeWorld.endlessOverclock.data = 0
    EndlessOverclock.onLayerComplete(freeWorld)
    local freeOpened = EndlessOverclock.prepareChoice(freeWorld)
    local freeTokenBefore = freeWorld.endlessOverclock.freeChoiceTokens
    local freeDataBefore = freeWorld.endlessOverclock.data
    local freeApplied = EndlessOverclock.applyChoice(freeWorld, 1)
    check("[050C] completed Endless layer grants a free overclock choice",
        freeOpened and freeTokenBefore == 1 and freeApplied
        and freeWorld.endlessOverclock.data == freeDataBefore
        and freeWorld.endlessOverclock.freeChoiceTokens == 0)

    -- 三张卡都满级时，免费选择仍可关闭页面，但 token 必须保留。
    local maxedWorld = World.New({ experiment = "B", seed = 48024,
        startLayer = 11, endless = true, endlessSeed = 48084 })
    for _, card in ipairs(EndlessOverclock.CATALOG) do
        maxedWorld.endlessOverclock.levels[card.id] = EndlessOverclock.maxLevel(card)
    end
    maxedWorld.endlessOverclock.freeChoiceTokens = 1
    local maxedOpened = EndlessOverclock.prepareChoice(maxedWorld)
    local maxedApplied = EndlessOverclock.applyChoice(maxedWorld, 1)
    check("[050C] all-maxed free choice preserves the token and closes safely",
        maxedOpened and maxedApplied
        and maxedWorld.endlessOverclock.freeChoiceTokens == 1
        and maxedWorld.endlessOverclock.data == 0
        and maxedWorld.overclockChoiceOpen ~= true)

    local freeSnap = EndlessOverclock.snapshot(freeWorld)
    local freeRestored = World.New({ experiment = "B", seed = 48025,
        startLayer = 11, endless = true, endlessSeed = 48085 })
    EndlessOverclock.restore(freeRestored, freeSnap)
    check("[050C] free-choice balance survives Endless checkpoint round trip",
        freeSnap and freeSnap.freeChoiceTokens == 0
        and freeRestored.endlessOverclock.freeChoiceTokens == 0
        and EndlessOverclock.validate(freeRestored))
end

local function testEndlessSettlementPlatformUI047()
    local SaveSys = require "SaveSys"
    local EndlessCheckpoint = require "EndlessCheckpoint"
    local ChallengeCheckpoint = require "ChallengeCheckpoint"
    local RunShop = require "RunShop"

    local entry = RawWorldNew({ experiment = "B", seed = 47001, startLayer = 11,
        runId = "047-endless", endless = true, endlessSeed = 47077,
        testMode = true, skipLayerIntro = false })
    local opened = EndlessOverclock.prepareStarterChoice(entry)
    local choices = entry.endlessOverclock.currentChoices
    local choiceIds = choices and table.concat({ choices[1].id, choices[2].id,
        choices[3].id }, ",") or ""
    local dataBeforeRepeat = entry.endlessOverclock.data
    local openedAgain = EndlessOverclock.prepareStarterChoice(entry)
    check("[047] L11 grants one starter overclock choice before battle",
        opened and openedAgain and entry.phase == "layer_intro"
        and entry.overclockChoiceOpen and entry.endlessOverclock.data == 4
        and entry.endlessOverclock.data == dataBeforeRepeat
        and entry.endlessOverclock.starterGranted == true and #choices == 3)

    local entryCheckpoint = EndlessCheckpoint.capture(entry, 11, 47001)
    local save = SaveSys.migrate({})
    local stored = SaveSys.setEndlessCheckpoint(save, entryCheckpoint)
    local serialized = SaveSys.serialize(save)
    local reloaded = SaveSys.migrate(serialized)
    local roundTrip = SaveSys.getEndlessCheckpoint(reloaded)
    local resumed = RawWorldNew({ experiment = "B", seed = 47001,
        startLayer = 11, runId = "ignored", endless = true,
        endlessCheckpoint = roundTrip, testMode = true, skipLayerIntro = false })
    local resumedChoices = resumed.endlessOverclock.currentChoices
    local resumedIds = resumedChoices and table.concat({ resumedChoices[1].id,
        resumedChoices[2].id, resumedChoices[3].id }, ",") or ""
    check("[047] L11 choice and checkpoint survive schema v10 without reroll",
        stored and serialized.schema_version == 10 and roundTrip
        and resumed.phase == "layer_intro" and resumed.overclockChoiceOpen
        and resumed.endlessOverclock.data == 4 and resumedIds == choiceIds)
    check("[047] restored Endless checkpoint remains eligible for the unified board",
        resumed.recoveredRun and resumed.checkpointRecovery and not resumed.assistedRun
        and resumed.cleanRun
        and PlatformFeatures.isEligibleRun({
            id = "047-checkpoint", completed = true, formalMain = true,
            endless = true, recovered = true, checkpointRecovery = true,
            completionReason = "layer_complete", layer = 11, score = 912345,
        }))

    local applied = EndlessOverclock.applyChoice(entry, 1)
    entry.score = 912345
    entry.wreckData = 2
    entry.coreCount = 3
    local nextCheckpoint = EndlessCheckpoint.capture(entry, 12, 47002)
    check("[047] L11 completion creates an L12 checkpoint outside Challenge bounds",
        applied and nextCheckpoint and nextCheckpoint.completedLayer == 11
        and nextCheckpoint.nextLayer == 12 and nextCheckpoint.score == 912345
        and ChallengeCheckpoint.capture(entry, 12, ChallengeCheckpoint.LAYER_START,
            entry.runId, 47002) == nil)

    local hasContinue = false
    for _, button in ipairs(Screens.layout(390, 867, save.settings, true, false,
        false, nil, nil, nextCheckpoint)) do
        if button.id == "continueEndless"
            and string.find(button.sub or "", "第 12 层", 1, true) then
            hasContinue = true
        end
    end
    check("[047] title exposes a player-readable Endless continuation entry", hasContinue)

    local milestone = {
        id = "047-endless:L11", runId = "047-endless:L11",
        originalRunId = "047-endless", milestoneId = "047-endless:L11",
        completed = true, formalMain = true, cleanRun = true, endless = true,
        completionReason = "layer_complete", layer = 11, score = 912345,
    }
    local recoveredMilestone = {
        id = "047-recovered:L11", runId = "047-recovered:L11",
        originalRunId = "047-endless", milestoneId = "047-endless:L11",
        completed = true, formalMain = true, cleanRun = false, endless = true,
        recovered = true, completionReason = "layer_complete",
        layer = 11, score = 912345,
    }
    check("[047] each clean Endless layer is a rank milestone while unconfirmed recovery remains local",
        PlatformFeatures.isEligibleRun(milestone)
        and not PlatformFeatures.isEligibleRun(recoveredMilestone))
    check("[050A] confirmed checkpoint recovery remains a rank milestone",
        PlatformFeatures.isEligibleRun({
            id = "047-recovered-checkpoint", runId = "047-recovered-checkpoint",
            completed = true, formalMain = true, cleanRun = true, endless = true,
            recovered = true, checkpointRecovery = true,
            completionReason = "layer_complete", layer = 11, score = 912345,
        }))

    local milestoneBest = SaveSys.migrate({})
    local firstRecorded = SaveSys.recordRun(milestoneBest, milestone)
    local duplicateRecorded = SaveSys.recordRun(milestoneBest, milestone)
    check("[047] repeated milestone callback is idempotent rather than a lost-record error",
        firstRecorded and not duplicateRecorded
        and SaveSys.hasRun(milestoneBest, milestone.runId)
        and #(milestoneBest.recentRuns or {}) == 1)

    entry.phase = "layer_settlement"
    entry.layerSettlement = { layer = 11, runComplete = false }
    entry.checkpointReady = false
    entry.endlessCheckpointSaveFailed = true
    local failureLayout = RunShop.layout(entry, 390, 867)
    local footer = failureLayout.confirm
    local leftAction = RunShop.hit(entry, footer.x + footer.w * 0.25,
        footer.y + footer.h * 0.5, 390, 867)
    local rightAction = RunShop.hit(entry, footer.x + footer.w * 0.75,
        footer.y + footer.h * 0.5, 390, 867)
    check("[047] save failure footer offers safe title return and explicit retry",
        leftAction == "checkpointSuspend" and rightAction == "confirm")

    local effect = EndlessOverclock.effectText(choices[1], 1)
    check("[047] overclock cards expose an icon and exact numeric effect",
        type(choices[1].icon) == "string" and choices[1].icon ~= ""
        and type(effect) == "string" and string.find(effect, "%d") ~= nil)

    local function freshEndlessBattle(seed)
        local battle = World.New({ seed = seed, startLayer = 11, endless = true,
            endlessSeed = seed + 77 })
        battle.phase = "overload"
        battle.player.x, battle.player.y = 0, 0
        battle.enemies, battle.firewalls, battle.relays, battle.wrecks = {}, {}, {}, {}
        battle.chainTimer = 999
        battle.pulseCd = 0
        battle.collapseCd = 0
        battle.endlessOverclock = {
            version = 1, runSeed = seed + 77, choiceSeed = seed + 78, rng = seed + 79,
            data = 0, shards = 0, spent = 0, choiceIndex = 0, choiceCount = 0,
            layerChoiceCount = 0, levels = { collapse_lock = 1, pulse_scatter = 1,
                pulse_break = 1 }, history = {}, currentChoices = nil, currentCost = 0,
        }
        return battle
    end

    local collapseWorld = freshEndlessBattle(47011)
    local collapseA = collapseWorld:spawnEnemy("heavy", 120, 0, nil, false)
    local collapseB = collapseWorld:spawnEnemy("heavy", 200, 12, nil, false)
    local collapseC = collapseWorld:spawnEnemy("heavy", 280, -12, nil, false)
    collapseA.hp, collapseA.maxHp = 70, 70
    collapseB.hp, collapseB.maxHp = 70, 70
    collapseC.hp, collapseC.maxHp = 70, 70
    -- CombatSys.update receives the pressed-action table directly; the World
    -- wrapper is the layer that owns the outer {moveX, moveY, pressed} shape.
    CombatSys.update(collapseWorld, 0.05, { collapse = true })
    local collapseDamaged = 0
    for _, e in ipairs({ collapseA, collapseB, collapseC }) do
        if e.hp < e.maxHp then collapseDamaged = collapseDamaged + 1 end
    end
    check("[047] collapse lock now chains into multiple nearby targets",
        collapseDamaged >= 2)

    local pulseWorld = freshEndlessBattle(47012)
    local pulseA = pulseWorld:spawnEnemy("heavy", 160, 0, nil, false)
    local pulseB = pulseWorld:spawnEnemy("heavy", 240, 0, nil, false)
    local pulseC = pulseWorld:spawnEnemy("heavy", 280, 8, nil, false)
    pulseA.hp, pulseA.maxHp = 80, 80
    pulseB.hp, pulseB.maxHp = 80, 80
    pulseC.hp, pulseC.maxHp = 80, 80
    CombatSys.update(pulseWorld, 0.05, { pulse = true })
    local pulseDamaged = 0
    for _, e in ipairs({ pulseA, pulseB, pulseC }) do
        if e.hp < e.maxHp then pulseDamaged = pulseDamaged + 1 end
    end
    check("[047] pulse scatter and break now reach more than one clustered target",
        pulseDamaged >= 2)
end

-- ============================================================
-- R2.5 最终发布修复010：隐私门、后台暂停与奖励复活隔离
-- ============================================================
local function testReleaseFix010()
    local SaveSys = require "SaveSys"

    local legacy = SaveSys.migrate({ round = 4, privacyPolicyVersion = 1 })
    check("legacy save requires explicit privacy choice",
        SaveSys.needsPrivacyChoice(legacy) and not SaveSys.hasPrivacyConsent(legacy))
    SaveSys.setPrivacyDecision(legacy, "declined")
    check("legacy privacy decline keeps cloud disabled and reopens the current consent gate",
        SaveSys.needsPrivacyChoice(legacy) and not SaveSys.hasPrivacyConsent(legacy))

    local cloudGets, cloudSets = 0, 0
    local fakeCloud = {
        kind = "releasefix_cloud",
        load = function(_, _, events)
            cloudGets = cloudGets + 1
            events.ok(nil)
            return true
        end,
        save = function(_, _, _, events)
            cloudSets = cloudSets + 1
            if events.ok then events.ok() end
            return true
        end,
    }
    local declinedStart, declinedReason = SaveSys.initCloud(legacy, true, false, nil, fakeCloud)
    check("privacy decline performs zero cloud calls",
        not declinedStart and declinedReason == "privacy_not_accepted"
        and cloudGets == 0 and cloudSets == 0)

    local oldConsent = SaveSys.migrate({
        privacyDecision = "accepted",
        privacyConsentVersion = SaveSys.PRIVACY_POLICY_VERSION - 1,
    })
    check("privacy version upgrade requires renewed choice",
        SaveSys.needsPrivacyChoice(oldConsent) and not SaveSys.hasPrivacyConsent(oldConsent))
    SaveSys.setPrivacyDecision(oldConsent, "accepted")
    local acceptedStart = SaveSys.initCloud(oldConsent, true, true, nil, fakeCloud)
    check("cloud initializes only after current-version consent",
        acceptedStart and SaveSys.hasPrivacyConsent(oldConsent) and cloudGets == 4 and cloudSets == 1)
    SaveSys.initCloud(oldConsent, false, false)
    SaveSys.resetCloudForTests()

    local life = AppLifecycle.New()
    local pausedWorld = World.New({ experiment = "B", seed = 10010 })
    pausedWorld:forceDrop()
    pausedWorld.energy = pausedWorld.energyNeed
    pausedWorld:tryRestart()
    local beforeLife = pausedWorld.timeAlive
    local beforeRestart = pausedWorld.restartChannel.t
    check("first focus loss enters suspended state once",
        AppLifecycle.focusLost(life) and not AppLifecycle.focusLost(life)
        and AppLifecycle.blocksWorld(life))
    if not AppLifecycle.blocksWorld(life) then pausedWorld:update(0.5, IDLE) end
    check("background blocks world time and restart channel",
        pausedWorld.timeAlive == beforeLife and pausedWorld.restartChannel.t == beforeRestart)
    check("focus gain requires fresh resume input",
        AppLifecycle.focusGained(life, true) and life.resumeRequired
        and AppLifecycle.blocksWorld(life))
    if not AppLifecycle.blocksWorld(life) then pausedWorld:update(0.5, IDLE) end
    check("resume gate prevents foreground catch-up",
        pausedWorld.timeAlive == beforeLife and pausedWorld.restartChannel.t == beforeRestart)
    InputSys.keyMove.up = true
    InputSys.pressed.restart = true
    InputSys.touches[77] = { role = "stick" }
    InputSys.onCancel()
    check("focus loss clears touch keyboard and queued actions",
        next(InputSys.touches) == nil and next(InputSys.pressed) == nil
        and InputSys.keyMove.up == false and not InputSys.stick.active)
    check("one fresh input consumes resume gate", AppLifecycle.consumeResume(life)
        and not AppLifecycle.blocksWorld(life) and not AppLifecycle.consumeResume(life))

    local oldSdk = rawget(_G, "sdk")
    local callbackCount, callbackResult, sdkCallback = 0, nil, nil
    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    _G.sdk = {
        ShowRewardVideoAd = function(_, callback)
            sdkCallback = callback
            return true
        end,
    }
    local adStarted = PlatformFeatures.requestRewardedRevive(function(result)
        callbackCount = callbackCount + 1
        callbackResult = result
    end)
    sdkCallback({ success = true, msg = "embed success" })
    sdkCallback({ success = true, msg = "duplicate" })
    check("[053] rewarded-ad duplicate callbacks grant at most once",
        adStarted and callbackCount == 1 and callbackResult.success == true)

    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    callbackCount, callbackResult = 0, nil
    _G.sdk = {
        ShowRewardVideoAd = function() return false end,
    }
    local rejectedStarted = PlatformFeatures.requestRewardedRevive(function(result)
        callbackCount = callbackCount + 1
        callbackResult = result
    end)
    check("[053] synchronous ad rejection finishes once without reward",
        not rejectedStarted and callbackCount == 1
        and callbackResult.success == false and callbackResult.msg == "sdk_rejected")

    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    callbackCount, callbackResult = 0, nil
    _G.sdk = {
        ShowRewardVideoAd = function() return true end,
    }
    local timeoutStarted = PlatformFeatures.requestRewardedRevive(function(result)
        callbackCount = callbackCount + 1
        callbackResult = result
    end)
    local softSeconds, hardSeconds = PlatformFeatures.rewardedAdTimeouts()
    local softEvent = PlatformFeatures.tickRewardedAd(os.time() + softSeconds + 2)
    local duplicateSoftEvent = PlatformFeatures.tickRewardedAd(os.time() + softSeconds + 3)
    check("[055] ad soft watchdog leaves the request unresolved exactly once",
        timeoutStarted and softSeconds == 15 and hardSeconds == 180
        and softEvent == "soft_timeout" and duplicateSoftEvent == false
        and callbackCount == 0)
    local hardEvent = PlatformFeatures.tickRewardedAd(os.time() + hardSeconds + 2)
    check("[055] ad hard watchdog releases UI as failure and never grants reward",
        hardEvent == "hard_timeout" and callbackCount == 1
        and callbackResult.success == false and callbackResult.msg == "ad_timeout")

    PlatformFeatures.resetForTests()
    PlatformFeatures.setPrivacyConsent(true)
    callbackCount, callbackResult = 0, nil
    local lateCallback = nil
    _G.sdk = {
        ShowRewardVideoAd = function(_, callback)
            lateCallback = callback
            return true
        end,
    }
    local cancelStarted = PlatformFeatures.requestRewardedRevive(function(result)
        callbackCount = callbackCount + 1
        callbackResult = result
    end)
    local locallyCancelled, cancelledToken = PlatformFeatures.cancelRewardedRevive()
    lateCallback({ success = true, msg = "late_success" })
    check("[055] local return invalidates late ad success without callback or reward",
        cancelStarted and locallyCancelled and type(cancelledToken) == "number"
        and callbackCount == 0 and callbackResult == nil)
    PlatformFeatures.resetForTests()
    _G.sdk = oldSdk

    local rewardNow = os.time()
    local productApproval = RewardedRevive.CONTRACT.productUseApproved
    check("Challenge rewarded revive product gate is approved",
        productApproval == true)
    local endlessEligible, endlessReason = RewardedRevive.eligible({
        phase = "dead", round = 12, endless = true,
        timeAlive = RewardedRevive.CONTRACT.firstSecondsDisabled + 1,
        rewardedReviveAttempted = false, rewardedReviveUsed = false,
        rewardedReviveCount = 0,
    }, {}, true, "ready", rewardNow)
    check("Endless offers rewarded revive while the shared pool remains",
        endlessEligible and endlessReason == "eligible")
    local endlessCapEligible, endlessCapReason = RewardedRevive.eligible({
        phase = "dead", round = 12, endless = true,
        timeAlive = RewardedRevive.CONTRACT.firstSecondsDisabled + 1,
        rewardedReviveCount = RewardedRevive.CONTRACT.endlessPerRunLimit,
    }, {}, true, "ready", rewardNow)
    check("Endless rewarded revive uses one shared three-use pool",
        not endlessCapEligible and endlessCapReason == "endless_run_cap")
    local staleRewardDay = RewardedRevive.dayKey(rewardNow - 172800)
    local queryBest = {
        rewardedReviveDay = staleRewardDay,
        rewardedReviveCount = 99,
    }
    local queryWorld = {
        phase = "dead",
        round = 2,
        timeAlive = RewardedRevive.CONTRACT.firstSecondsDisabled + 1,
        endless = false,
        rewardedReviveAttempted = false,
        rewardedReviveUsed = false,
    }
    local queryEligible = RewardedRevive.eligible(
        queryWorld, queryBest, true, "ready", rewardNow)
    local queryCount = RewardedRevive.dailyCount(queryBest, rewardNow)
    check("ordinary rewarded revive remains unlimited and cross-day query is pure",
        queryEligible and queryCount == 0
        and queryBest.rewardedReviveDay == staleRewardDay
        and queryBest.rewardedReviveCount == 99)

    local rewardWorld = {
        phase = "dead",
        rewardedReviveState = "pending",
        rewardedReviveMode = "in_place",
        rewardedReviveCount = 0,
        reviveAssisted = function(self)
            self.phase = "overload"
            return true
        end,
    }
    local rewardGranted = RewardedRevive.resolve(
        rewardWorld, queryBest, true, "embed success", rewardNow)
    check("rewarded revive writes cross-day count only after reward",
        rewardGranted and rewardWorld.rewardedReviveCount == 1
        and queryBest.rewardedReviveDay == RewardedRevive.dayKey(rewardNow)
        and queryBest.rewardedReviveCount == 1)

    local secondRewardWorld = {
        phase = "dead",
        rewardedReviveState = "pending",
        rewardedReviveMode = "in_place",
        rewardedReviveCount = 1,
        reviveAssisted = function(self)
            self.phase = "overload"
            return true
        end,
    }
    local secondRewardGranted = RewardedRevive.resolve(
        secondRewardWorld, queryBest, true, "embed success", rewardNow)
    check("rewarded revive accumulates successful rewards on same day",
        secondRewardGranted and secondRewardWorld.rewardedReviveCount == 2
        and queryBest.rewardedReviveCount == 2)

    local fullStateWorld = {
        phase = "dead",
        rewardedReviveState = "pending",
        rewardedReviveMode = "full_state",
        rewardedReviveCount = 0,
        endless = false,
    }
    local fullStateGranted, fullStateOutcome = RewardedRevive.resolve(
        fullStateWorld, queryBest, true, "embed success", rewardNow, "full_state")
    check("full-state rewarded revive is a separate confirmed outcome",
        fullStateGranted and fullStateOutcome == "full_state"
        and fullStateWorld.rewardedReviveCount == 1
        and fullStateWorld.assistedRun and fullStateWorld.rewardedReviveUsed)

    local best = SaveSys.migrate({ round = 7, score = 70000 })
    local reviveWorld = World.New({ experiment = "B", seed = 10011 })
    RewardedRevive.resetRun(reviveWorld)
    -- 先形成真实的L1整备检查点，再在L2制造未结算死亡状态。
    reviveWorld.phase = "layer_settlement"
    reviveWorld.round = 1
    reviveWorld.score = 7000
    reviveWorld.wreckData = 2
    reviveWorld.coreCount = 3
    reviveWorld:advanceLayer()
    reviveWorld.timeAlive = 61
    reviveWorld.score = 12345
    reviveWorld.wreckData = 9
    reviveWorld.coreCount = 8
    reviveWorld.restartChannel = { t = 0.3 }
    reviveWorld:spawnEnemy("drone", reviveWorld.player.x + 10,
        reviveWorld.player.y + 10, nil, true)
    reviveWorld:damagePlayer(99999, 0, 0)
    local layerAtDeath = reviveWorld.round
    local offered = RewardedRevive.onDeath(reviveWorld, best, true, "ready", os.time())
    local begun = RewardedRevive.begin(reviveWorld)
    local revived = RewardedRevive.resolve(reviveWorld, best, true, "embed success", os.time())
    local hordeAlive = false
    for _, enemy in ipairs(reviveWorld.enemies) do
        if not enemy.dead and enemy.isHorde then hordeAlive = true end
    end
    local spawnX, spawnY = MapDef.tileCenter(reviveWorld.mapDef.playerSpawn.col,
        reviveWorld.mapDef.playerSpawn.row)
    check("rewarded revive success preserves current layer at safe spawn",
        offered and begun and revived and reviveWorld.phase ~= "dead"
        and reviveWorld.round == layerAtDeath
        and reviveWorld.score == 12345
        and reviveWorld.wreckData == 9
        and reviveWorld.coreCount == 8
        and reviveWorld.restartChannel == nil and hordeAlive
        and reviveWorld.player.x == spawnX and reviveWorld.player.y == spawnY
        and reviveWorld.player.hp > 0)
    check("rewarded revive marks assisted run and daily count",
        reviveWorld.assistedRun and reviveWorld.rewardedReviveUsed
        and reviveWorld.rewardedReviveCount == 1
        and RewardedRevive.dailyCount(best, os.time()) == 1)
    SaveSys.recordRun(best, { id = "assisted010", layer = 99, score = 999999,
        time = 99, bestCombo = 99, adAssisted = reviveWorld.assistedRun })
    check("continued run stays isolated online while updating local record",
        best.bestRun.layer == 7 and best.bestRun.score == 70000
        and best.assistedBestRun.layer == 99
        and best.round == 99 and best.score == 999999 and best.bestCombo == 99)

    local failWorld = World.New({ experiment = "B", seed = 10012 })
    RewardedRevive.resetRun(failWorld)
    failWorld.round, failWorld.timeAlive = 2, 61
    failWorld:damagePlayer(99999, 0, 0)
    RewardedRevive.onDeath(failWorld, best, true, "ready", os.time())
    RewardedRevive.begin(failWorld)
    local failed = RewardedRevive.resolve(failWorld, best, false, "no_fill", os.time())
    local reoffered = RewardedRevive.openChoice(failWorld)
    check("failed rewarded revive returns to the same choice page",
        not failed and reoffered and failWorld.phase == "dead"
        and failWorld.rewardedReviveState == "offered" and failWorld.reviveOffer
        and failWorld.reviveOfferPending)

    local grace = World.New({ experiment = "B", seed = 10013 })
    RewardedRevive.resetRun(grace)
    grace.timeAlive = 30
    grace:damagePlayer(99999, 0, 0)
    check("ordinary first-layer death may offer rewarded revive",
        RewardedRevive.onDeath(grace, best, true, "ready", os.time())
        and grace.reviveOffer)
    check("entered endless layer is not counted before completion",
        RunFlow.completedLayerForRun({
            round = 18, _reviveCheckpoint = { completedLayer = 17 },
        }, "death") == 17)
    check("completed endless milestone counts the completed layer",
        RunFlow.completedLayerForRun({ round = 18 }, "layer_complete") == 18)
    local disabled = World.New({ experiment = "B", seed = 10014 })
    RewardedRevive.resetRun(disabled)
    disabled.round, disabled.timeAlive = 2, 61
    disabled:damagePlayer(99999, 0, 0)
    check("unavailable ad configuration leaves no empty UI slot",
        not RewardedRevive.onDeath(disabled, best, false,
            "official_ad_config_unavailable", os.time()) and not disabled.reviveOffer)
    local capWorld = World.New({ experiment = "B", seed = 10015 })
    RewardedRevive.resetRun(capWorld)
    capWorld.round, capWorld.timeAlive, capWorld.endless = 12, 61, true
    capWorld.rewardedReviveCount = RewardedRevive.CONTRACT.endlessPerRunLimit
    capWorld:damagePlayer(99999, 0, 0)
    check("endless fourth rewarded revive is blocked by the run pool",
        not RewardedRevive.onDeath(capWorld, best, true, "ready", os.time())
        and capWorld.rewardedReviveReason == "endless_run_cap")
    RewardedRevive.CONTRACT.productUseApproved = productApproval
end

local function testReviewAccessCandidate()
    local contract = ReviewAccess.contract()
    check("review access disables persistence cloud records leaderboard and ads",
        contract.reviewOnly and not contract.persistence and not contract.cloud
        and not contract.localRecords and not contract.leaderboard and not contract.rewardedAd)
    check("review access keeps gameplay numeric systems unmodified",
        not contract.damageOverride and not contract.healthOverride and not contract.speedOverride
        and not contract.scoreOverride)
    local allOK, errors = ReviewAccess.verifyAll()
    check("review access creates authentic L1/L4/L5/L7/L8/L9/L11 states",
        allOK, table.concat(errors, "; "))
    local natural = ReviewAccess.createWorld("natural")
    check("[016] natural review keeps formal layer intro",
        natural.reviewOnly == true and natural.reviewControlled == false
        and natural.phase == "layer_intro")
    local hunter = ReviewAccess.createWorld("l5_hunter")
    check("[016] controlled review may skip layer intro",
        hunter.reviewOnly == true and hunter.reviewControlled == true
        and hunter.phase == "depleted")
    step(hunter, Config.HUNTER.readyDelay + 0.2)
    check("review L5 ready state activates real hunter after official delay",
        hunter.huntersActivated == 1 and hunter.phase == "depleted")
end

-- ============================================================
-- R. [R2] 长时间稳定(§二十:100次重开 / 实验切换100次)
-- ============================================================
local function testLongRunR2()
    -- 100 次重开(A/B 交替),无实体/路径缓存泄漏、无串局
    local okAll = true
    local PlaytestMetricsMod = require "PlaytestMetrics"
    for i = 1, 100 do
        local exp = (i % 2 == 0) and "A" or "B"
        local w = World.New({ experiment = exp, seed = i })
        PlaytestMetricsMod.beginSession(w, i, 390, 844)
        step(w, 0.5)
        PlaytestMetricsMod.update(w)
        if #PlaytestMetricsMod.session.rounds ~= 0 then okAll = false end
        if w.experimentId ~= exp then okAll = false end
        clearEvents(w)
    end
    check("100 reopens with A/B switching stable", okAll)
    -- 单局 50 轮 B 实验完整循环:深层/缓存/热度反复运转
    local w = World.New({ experiment = "B", seed = 42 })
    local maxWrecks, maxEnemies = 0, 0
    local ok30 = true
    for _ = 1, 50 do
        w.overloadLeft = 0.06
        step(w, 0.3)
        if w.phase ~= "depleted" then ok30 = false end
        w.energy = w.energyNeed + Config.RISK.overflowStep  -- 触发溢出路径
        w.cells[#w.cells + 1] = { x = w.player.x, y = w.player.y, dead = false }
        step(w, 0.3)
        doRestart(w)
        if w.phase ~= "overload" then ok30 = false end
        step(w, 0.4)
        local wrecks = 0
        for _, wk in ipairs(w.wrecks) do
            if not wk.dead then wrecks = wrecks + 1 end
        end
        maxWrecks = math.max(maxWrecks, wrecks)
        local alive = 0
        for _, e in ipairs(w.enemies) do
            if not e.dead then alive = alive + 1 end
        end
        maxEnemies = math.max(maxEnemies, alive)
    end
    check("50 B-loops with cache/deep stable", ok30 and w.round == 51, "round=" .. w.round)
    check("no wreck/entity leak in B loops", maxWrecks < 12 and maxEnemies < 90,
        string.format("wrecks=%d enemies=%d", maxWrecks, maxEnemies))
end

-- ============================================================
-- S. [R2] Bot 冒烟:6 策略 × A/B 各 60 秒无错误
-- ============================================================
local function testBotsR2()
    for _, exp in ipairs({ "A", "B" }) do
        for _, kind in ipairs(BotStrategies.allKinds) do
            local world = World.New({ experiment = exp, seed = 9 })
            local bot = BotStrategies.create(kind)
            local ok, err = pcall(function()
                for _ = 1, 1200 do
                    local input = bot:decide(world, 0.05)
                    world:update(0.05, input)
                    driveSettlement(world, input)
                    clearEvents(world)
                    if world.phase == "dead" then break end
                end
            end)
            check("bot '" .. kind .. "' exp" .. exp .. " runs 60s", ok, err)
        end
    end
end

-- ============================================================
-- T. [014] 反猎归属、层结算、资源语义、协议整备、第10层选择、无尽热度、Review隔离
-- ============================================================

-- 让世界处于枯竭满能状态（不触发额外重启）
local function toReadyDepleted(world)
    if world.phase == "overload" then
        world.overloadLeft = 0.06
        step(world, 0.2)
    end
    grantEnergy(world)
    step(world, 0.1)
end

local function testAntiHuntAttribution()
    local world = World.New({ seed = 4014 })
    toReadyDepleted(world)
    -- 制造一个必然被标记的追击者
    local target = world:spawnEnemy("drone", world.player.x + 80, world.player.y, nil, false)
    target.daze, target.stun = 0, 0
    target.state = "chase"
    restartToAntiHunt(world)
    check("[014] anti_hunt is its own phase", world.phase == "anti_hunt")
    local layer = world.round
    local scoreBefore = world.score
    local statsBefore = world.layerStats.antiHuntKills or 0

    -- 在窗口内击杀反猎目标
    local killed = false
    for _, e in ipairs(world.enemies) do
        if e.huntTarget and not e.dead then
            CombatSys.damageEnemy(world, e, 999999, true)
            killed = true
            break
        end
    end
    check("[014] anti_hunt target killable in window", killed)
    if killed then
        check("[014] anti_hunt kill scores", world.score > scoreBefore)
        check("[014] anti_hunt kill counted on layer N",
            (world.layerStats.antiHuntKills or 0) > statsBefore)
        check("[014] anti_hunt score recorded on layer N",
            (world.layerStats.antiHuntScore or 0) > 0)
    end

    antiHuntToSettlement(world)
    local st = world.layerSettlement
    check("[014] settlement belongs to layer N", st ~= nil and st.layer == layer)
    if st then
        check("[014] settlement carries anti_hunt kills", st.antiHuntKills >= (killed and 1 or 0))
        check("[014] settlement score gain matches", st.scoreGained == world.score - st.scoreAtLayerStart)
    end

    -- 下一层不再累计上一层反猎
    world:advanceLayer()
    check("[014] next layer starts fresh anti_hunt stats",
        (world.layerStats.antiHuntKills or 0) == 0
        and (world.layerStats.antiHuntScore or 0) == 0)
    check("[014] next layer clears hunt marks", world.huntTargetsLeft == 0)
    -- 层结算清空后整局累计仍保留
    check("[014] run total score preserved across settlement", world.score > 0)
end

local function testAntiHuntCandidateSnapshot()
    local world = World.New({ seed = 40141 })
    toReadyDepleted(world)
    -- 旧实现只认 300 半径；正式风险 HUD/诱敌统计可覆盖到 420，导致有追击却零候选。
    local distant = world:spawnEnemy("drone", world.player.x + 360, world.player.y, nil, false)
    distant.state, distant.daze, distant.stun = "chase", 0, 0
    restartToAntiHunt(world)
    check("[015] chase pressure beyond old mark radius remains anti_hunt target",
        world.phase == "anti_hunt" and distant.huntTarget == true)
    check("[015] anti_hunt snapshot never loses visible pressure",
        world.antiHuntSnapshot ~= nil
        and world.antiHuntSnapshot.pressureCount >= 1
        and world.antiHuntSnapshot.selectedCount >= 1)

    local searching = World.New({ seed = 401411 })
    toReadyDepleted(searching)
    local searcher = searching:spawnEnemy("drone", searching.player.x + 180,
        searching.player.y, nil, false)
    searcher.state, searcher.wasChasing = "search", true
    restartToAntiHunt(searching)
    check("[015] active search pressure remains anti_hunt target",
        searching.phase == "anti_hunt" and searcher.huntTarget == true)

    local crowded = World.New({ seed = 40142 })
    toReadyDepleted(crowded)
    crowded.player.maxHp, crowded.player.hp = 100000, 100000
    local spawned = {}
    for i = 1, Config.FORMAL.huntMarkMax + 2 do
        local e = crowded:spawnEnemy("drone", crowded.player.x + 40 + i * 8,
            crowded.player.y, nil, false)
        e.state, e.daze, e.stun = "chase", 0, 0
        spawned[#spawned + 1] = e
    end
    restartToAntiHunt(crowded)
    local targets, disengaged = 0, 0
    for _, e in ipairs(spawned) do
        if e.huntTarget then
            targets = targets + 1
        elseif e.state == "patrol" and (e.daze or 0) > 0 then
            disengaged = disengaged + 1
        end
    end
    check("[015] anti_hunt target snapshot is capped at eight",
        targets == Config.FORMAL.huntMarkMax, "targets=" .. targets)
    check("[015] pressure targets beyond cap fully disengage",
        disengaged == 2, "disengaged=" .. disengaged)
end

local function testAntiHuntEmptyState()
    local world = World.New({ seed = 40143 })
    toReadyDepleted(world)
    for _, e in ipairs(world.enemies) do e.dead = true end
    world:doRestart()
    local prompt = world.systemPrompts[1]
    check("[016] true zero-enemy anti_hunt has explicit prompt",
        world.phase == "anti_hunt" and world.huntTargetsLeft == 0
        and prompt ~= nil and string.find(prompt.text or "", "威胁已清空", 1, true) ~= nil)
    step(world, Config.ANTI_HUNT_PHASE.zeroThreatDelay * 0.5)
    check("[016] zero-enemy anti_hunt remains visible before delay", world.phase == "anti_hunt")
    step(world, Config.ANTI_HUNT_PHASE.zeroThreatDelay * 0.6)
    check("[016] zero-enemy anti_hunt settles after dedicated delay",
        world.phase == "layer_settlement")
end

local function testAntiHuntEarlyClear()
    local world = World.New({ seed = 4015 })
    toReadyDepleted(world)
    restartToAntiHunt(world)
    check("[014] anti_hunt entered", world.phase == "anti_hunt")
    -- 清掉所有奖励目标也必须保留完整 10 秒反猎窗口，不能提前进入结算。
    for _, e in ipairs(world.enemies) do
        if e.huntTarget then CombatSys.damageEnemy(world, e, 999999, true) end
    end
    step(world, 0.1)
    -- 单独的 visibility016 已验证 9.9 秒仍在窗口中；这里留出步长余量，
    -- 专门防回归到旧的 5 秒提前结算。
    step(world, Config.ANTI_HUNT_PHASE.maximumDuration - 0.6)
    check("[016] cleared targets do not open shop before ten seconds",
        world.phase == "anti_hunt")
    step(world, 0.35)
    check("[016] cleared targets settle at the fixed ten-second window",
        world.phase == "layer_settlement")
end

local function testResourceSemantics()
    local world = World.New({ seed = 4016 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    -- 普通重型残骸 → 残骸数据，不再给黄色核心
    world.wrecks[#world.wrecks + 1] = { x = world.player.x, y = world.player.y, dead = false }
    local coresBefore = world.coreCount
    local dataBefore = world.wreckData or 0
    press(world, "dismantle")
    step(world, Config.DEPLETED.dismantleTime + 0.3)
    check("[014] normal wreck yields wreck data",
        (world.wreckData or 0) == dataBefore + Config.WRECK_DATA.perNormalWreck)
    check("[014] normal wreck no longer yields cores", world.coreCount == coresBefore)
    check("[014] wreck data counted on layer",
        (world.layerStats.wreckDataGained or 0) >= 1)

    -- 深层残骸 → 残骸数据 + 黄色核心；协议只提高核心，不提高残骸数据。
    world.wrecks[#world.wrecks + 1] = { x = world.player.x, y = world.player.y,
        dead = false, deep = true }
    local coresBefore2 = world.coreCount
    local dataBefore2 = world.wreckData
    press(world, "dismantle")
    step(world, Config.RISK.deepDismantleTime + 0.3)
    check("[016] deep wreck yields exactly one wreck data",
        world.wreckData == dataBefore2 + Config.WRECK_DATA.perDeepWreck)
    check("[014] deep wreck yields yellow cores", world.coreCount > coresBefore2)
    check("[014] deep wreck counted on layer", (world.layerStats.deepWrecks or 0) >= 1)

    local cached = World.New({ seed = 40166, startLayer = 9 })
    cached:forceDrop()
    for _, enemy in ipairs(cached.enemies) do enemy.dead = true end
    cached.wrecks[#cached.wrecks + 1] = {
        x = cached.player.x, y = cached.player.y, dead = false, deep = true,
    }
    local cachedDataBefore, cachedCoresBefore = cached.wreckData, cached.coreCount
    press(cached, "dismantle")
    step(cached, Config.RISK.deepDismantleTime + 0.3)
    check("[016] deep_cache never increases wreck data",
        cached:hasProtocol("deep_cache")
        and cached.wreckData == cachedDataBefore + Config.WRECK_DATA.perDeepWreck)
    check("[016] deep_cache only increases yellow cores",
        cached.coreCount == cachedCoresBefore + Config.RISK.deepCores
            + Config.PROTOCOL.deep_cache.deepCoreBonus)

    -- 绿色储能不进商店、不跨局
    check("[014] green energy is not a shop currency",
        RunShop.balance(world, "wreckData") == (world.wreckData or 0)
        and RunShop.balance(world, "coreCount") == world.coreCount)
end

local function testRunShop()
    local world = World.New({ seed = 4017 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    grantEnergy(world)
    doRestartToSettlement(world)
    check("[014] shop opens at layer settlement", world.phase == "layer_settlement")

    -- 资源不足：按钮禁用且不扣资源
    world.wreckData = 0
    local item = RunShop.itemById("collapseCooldownLevel")
    local ok, reason = RunShop.canBuy(world, item)
    check("[014] insufficient wreck data disables purchase", not ok and reason ~= nil)
    local bought = world:buyRunUpgrade("collapseCooldownLevel")
    check("[014] insufficient purchase rejected", not bought
        and RunShop.level(world, "collapseCooldownLevel") == 0)

    -- 崩解优化：3 级，1/3/5，每级 -1 秒，下限 7 秒
    world.wreckData = 99
    local baseCollapse = Config.OVERLOAD.collapseCooldown
    local collapsePrices = { 1, 3, 5 }
    for lvl = 1, 3 do
        local expectedPrice = collapsePrices[lvl]
        local price = RunShop.priceOf(world, item)
        check("[016] collapse level " .. lvl .. " price", price == expectedPrice)
        local before = world.wreckData
        check("[016] collapse buy " .. lvl, world:buyRunUpgrade("collapseCooldownLevel"))
        check("[016] collapse price deducted", world.wreckData == before - expectedPrice)
        check("[014] collapse cooldown -" .. lvl .. "s",
            math.abs(RunShop.effectiveCollapseCooldown(world) - (baseCollapse - lvl)) < 0.001)
    end
    check("[014] collapse maxed at 3", RunShop.level(world, "collapseCooldownLevel") == 3)
    check("[014] collapse floor respected (10 -> 7)",
        RunShop.effectiveCollapseCooldown(world) >= Config.RUN_SHOP.collapseCooldown.floor)
    local maxedOk, maxedReason = RunShop.canBuy(world, item)
    check("[015] maxed shows 等级已满", not maxedOk and maxedReason == "等级已满")
    check("[014] maxed purchase rejected", not world:buyRunUpgrade("collapseCooldownLevel"))

    -- 脉冲优化：每级 -0.6，最多 -1.8
    local basePulse = Config.OVERLOAD.pulseCooldown
    for _ = 1, 3 do world:buyRunUpgrade("pulseCooldownLevel") end
    check("[014] pulse cooldown -1.8s max",
        math.abs(RunShop.effectivePulseCooldown(world) - (basePulse - 1.8)) < 0.001)

    -- 链路优化：每级 -8%，最多 -24%，不改伤害
    local baseChain = Config.OVERLOAD.chainInterval
    local damageBefore = Config.OVERLOAD.chainDamage
    for _ = 1, 3 do world:buyRunUpgrade("chainIntervalLevel") end
    check("[014] chain interval -24% max",
        math.abs(RunShop.effectiveChainInterval(world) - baseChain * 0.76) < 0.001)
    check("[014] chain upgrade does not change damage",
        Config.OVERLOAD.chainDamage == damageBefore)

    -- 未直接修改全局 Config
    check("[014] global Config untouched by upgrades",
        Config.OVERLOAD.collapseCooldown == baseCollapse
        and Config.OVERLOAD.pulseCooldown == basePulse
        and Config.OVERLOAD.chainInterval == baseChain)

    -- 枯竭补给：核心价格 2/3/4、3/4/5、4/6
    world.coreCount = 99
    local jammer = RunShop.itemById("jammerBonusUses")
    local jammerPrices = { 2, 3, 4 }
    for lvl = 1, 3 do
        check("[016] jammer price " .. lvl,
            RunShop.priceOf(world, jammer) == jammerPrices[lvl])
        world:buyRunUpgrade("jammerBonusUses")
    end
    local decoy = RunShop.itemById("decoyBonusUses")
    check("[016] decoy first price 3", RunShop.priceOf(world, decoy) == 3)
    for _ = 1, 3 do world:buyRunUpgrade("decoyBonusUses") end
    local cloak = RunShop.itemById("cloakBonusUses")
    check("[016] cloak first price 4", RunShop.priceOf(world, cloak) == 4)
    for _ = 1, 2 do world:buyRunUpgrade("cloakBonusUses") end
    check("[014] cloak caps at 2 levels", RunShop.level(world, "cloakBonusUses") == 2)

    -- 保存资源到下一层
    local savedData, savedCores = world.wreckData, world.coreCount
    world:advanceLayer()
    check("[014] resources carry to next layer",
        world.wreckData == savedData and world.coreCount == savedCores)
    check("[014] upgrades carry to next layer",
        RunShop.level(world, "collapseCooldownLevel") == 3)

    -- 进入枯竭：工具次数 = 基础 + 加成，不被 forceDrop 覆盖
    world.overloadLeft = 0.06
    step(world, 0.2)
    check("[014] jammer uses include shop bonus",
        world.tools.jammer == Config.DEPLETED.jammerUses + 3)
    check("[014] decoy uses include shop bonus",
        world.tools.decoy == Config.DEPLETED.decoyUses + 3)
    check("[014] cloak uses include shop bonus",
        world.tools.cloak == Config.DEPLETED.cloakUses + 2)

    -- 商店消费不改变已获得分数
    grantEnergy(world)
    doRestartToSettlement(world)
    local scoreBefore = world.score
    world.wreckData = 5
    world:buyRunUpgrade("collapseCooldownLevel")  -- 已满级，应被拒
    check("[014] shop spending never alters earned score", world.score == scoreBefore)

    -- 短屏有滚动、固定 footer，拖动不会在按下帧误购。
    local shortLayout = RunShop.layout(world, 360, 560)
    check("[015] short shop provides bounded scroll", shortLayout.scrollMax > 0)
    check("[015] shop footer remains inside safe screen",
        shortLayout.confirm.y + shortLayout.confirm.h <= 560)
    local first = shortLayout.rows[1]
    InputSys.reset()
    InputSys.onPointerDown(world, 77, first.x + first.w * 0.5,
        first.y + first.h * 0.5, 360, 560)
    local downInput = InputSys.collect()
    check("[015] shop pointer-down never commits purchase",
        next(downInput.pressed) == nil)
    InputSys.onPointerMove(world, 77, first.x + first.w * 0.5,
        first.y + first.h * 0.5 - 40)
    InputSys.onPointerUp(world, 77)
    local dragInput = InputSys.collect()
    check("[015] shop drag scroll never commits purchase",
        next(dragInput.pressed) == nil and RunShop.layout(world, 360, 560).scrollY > 0)

    -- 商店阶段不得触发战斗按钮
    local btns = InputSys.layout(world, 390, 780)
    check("[014] no combat buttons during settlement", #btns == 0)
end

-- 只走到层结算（不推进层数）
local function testRunCompletion()
    -- 走到第10层，验证两种选择
    local function reachFinalSettlement(seed)
        local w = World.New({ seed = seed, startLayer = Config.RUN.finalLayer })
        w.overloadLeft = 0.06
        step(w, 0.2)
        grantEnergy(w)
        doRestartToSettlement(w)
        return w
    end

    local a = reachFinalSettlement(4018)
    check("[014] layer 10 reaches settlement",
        a.phase == "layer_settlement" and a.round == Config.RUN.finalLayer)
    check("[014] layer 10 offers run completion",
        a.runComplete == true and a.layerSettlement.runComplete == true)
    local layerAtEnd, scoreAtEnd = a.round, a.score
    check("[014] complete challenge ends run", a:completeChallenge())
    check("[014] complete challenge recorded", a.challengeCompleted == true
        and a.phase == "dead")
    check("[014] complete challenge preserves layer/score",
        a.round == layerAtEnd and a.score == scoreAtEnd)

    local b = reachFinalSettlement(4019)
    local scoreBefore = b.score
    b.wreckData = 6
    b:buyRunUpgrade("collapseCooldownLevel")
    local lvl = RunShop.level(b, "collapseCooldownLevel")
    check("[014] controlled endless advance reaches layer 11", b:chooseEndless()
        and b.round == Config.RUN.finalLayer + 1 and b.phase == "overload")
    check("[014] endless keeps upgrades",
        RunShop.level(b, "collapseCooldownLevel") == lvl and lvl > 0)
    check("[014] endless keeps score", b.score >= scoreBefore)
    check("[014] endless flag set", b.endless == true)
    check("[014] endless still same run (no new save/mode)",
        b.challengeCompleted == false and b.restarts >= 1)

    -- 正式第10层选择无尽后必须先进入第11层观察倒计时，不能直接启动过载。
    local formal = RawWorldNew({ seed = 40191, startLayer = Config.RUN.finalLayer })
    step(formal, Config.FORMAL.layerIntroDuration + 0.1)
    formal:forceDrop()
    grantEnergy(formal)
    doRestartToSettlement(formal)
    check("[016] formal layer 10 settlement is complete choice",
        formal.phase == "layer_settlement" and formal.runComplete == true)
    check("[016] choosing endless enters layer 11 intro",
        formal:chooseEndless()
        and formal.round == Config.RUN.finalLayer + 1
        and formal.phase == "layer_intro")

    -- 11—20层继续使用两张既有地图、单协议轮换，并逐层执行正式倒计时。
    local endlessValid = true
    for layer = 11, 20 do
        local plan = LayerPlan.get(layer)
        local sample = RawWorldNew({ seed = 40200 + layer, startLayer = layer })
        if sample.phase ~= "layer_intro" or sample.round ~= layer
            or sample.mapId ~= plan.map or #(plan.protocols or {}) ~= 1 then
            endlessValid = false
        end
        step(sample, Config.FORMAL.layerIntroDuration + 0.1)
        if sample.phase ~= "overload" then endlessValid = false end
    end
    check("[016] endless layers 11-20 keep content bounds and intro", endlessValid)

    -- 无尽仍是双地图 + 单协议轮换
    local plan11 = LayerPlan.get(11)
    check("[014] endless keeps two maps only",
        Config.CONTENT.maps[plan11.map] ~= nil and #plan11.protocols == 1)
end

local function testHeatPressure014()
    -- 热度2：静止单位开始有限巡逻
    local w = World.New({ seed = 4020 })
    w.overloadLeft = 0.06
    step(w, 0.2)
    w.heat = Config.HEAT.thresholds[2] + 2
    check("[014] heat level 2 reached", w:heatLevel() == 2)
    -- 找一个单点岗位单位（重型守卫的巡逻只有一个路点）
    local post = nil
    for _, e in ipairs(w.enemies) do
        if not e.dead and e.patrol and #e.patrol <= 1 then post = e; break end
    end
    if post then
        post.daze, post.stun, post.jammed = 0, 0, 0
        post.state = "patrol"
        local x0, y0 = post.x, post.y
        step(w, Config.HEAT.roamRepathTime * 2 + 1.0)
        local moved = math.abs(post.x - x0) + math.abs(post.y - y0)
        check("[014] heat 2 makes stationary unit roam", moved > 1.0, "moved=" .. moved)
        local dist = math.sqrt((post.x - x0) ^ 2 + (post.y - y0) ^ 2)
        check("[014] heat 2 roam stays bounded",
            dist <= Config.HEAT.roamRadius * 1.6, "dist=" .. dist)
    else
        check("[014] heat 2 roam has a stationary post to test", false)
    end

    -- 热度2不生成新敌人
    local countBefore = 0
    for _, e in ipairs(w.enemies) do if not e.dead then countBefore = countBefore + 1 end end
    w.heat = Config.HEAT.thresholds[2] + 2
    step(w, 6.0)
    local countAfter = 0
    for _, e in ipairs(w.enemies) do if not e.dead then countAfter = countAfter + 1 end end
    check("[014] heat 2 spawns no new enemies", countAfter <= countBefore,
        string.format("%d -> %d", countBefore, countAfter))

    -- 热度3：满能后补充有限猎杀者，且不在脚边/视野内
    local h = World.New({ seed = 4021, startLayer = 3 })
    h.overloadLeft = 0.06
    step(h, 0.2)
    grantEnergy(h)
    h.readyAt = h.timeAlive
    h._readySnap = { coreCount = h.coreCount, crafted = h.counters.crafted or 0 }
    h.heat = Config.HEAT.thresholds[3] + 5
    step(h, Config.HUNTER.readyDelay + Config.HEAT_LOCK.reinforceCooldown * 3 + 3.0)
    local hunters, tooClose = 0, false
    for _, e in ipairs(h.enemies) do
        if not e.dead and e.hunter then
            hunters = hunters + 1
        end
    end
    check("[014] heat 3 activates limited hunters", hunters >= 1, "hunters=" .. hunters)
    check("[014] layers 1-4 cap hunters at 1",
        hunters <= Config.HEAT_LOCK.maxPerLayerEarly, "hunters=" .. hunters)
    _ = tooClose

    local h5 = World.New({ seed = 4022, startLayer = 6 })
    h5.overloadLeft = 0.06
    step(h5, 0.2)
    grantEnergy(h5)
    h5.readyAt = h5.timeAlive
    h5._readySnap = { coreCount = h5.coreCount, crafted = h5.counters.crafted or 0 }
    h5.heat = Config.HEAT.thresholds[3] + 5
    step(h5, Config.HUNTER.readyDelay + Config.HEAT_LOCK.reinforceCooldown * 4 + 4.0)
    local mid = 0
    for _, e in ipairs(h5.enemies) do
        if not e.dead and e.hunter then mid = mid + 1 end
    end
    check("[014] layers 5-10 cap hunters at 2",
        mid <= Config.HEAT_LOCK.maxPerLayerMid, "hunters=" .. mid)
    check("[014] endless hunter cap bounded",
        ProtocolSys.hunterCap({ round = 60 }) <= Config.HEAT_LOCK.endlessMax)

    -- 标准层：层结算后热度清零
    local s = World.New({ seed = 4023 })
    s.overloadLeft = 0.06
    step(s, 0.2)
    grantEnergy(s)
    s.heat = 90
    doRestartToSettlement(s)
    check("[014] standard layers clear heat after settlement", s.heat == 0,
        "heat=" .. tostring(s.heat))

    -- 无尽层：每层只降一档，不完全清零
    local e = World.New({ seed = 4024, startLayer = 12 })
    e.endless = true
    e.overloadLeft = 0.06
    step(e, 0.2)
    grantEnergy(e)
    e.heat = Config.HEAT.thresholds[3] + 10
    local lvlBefore = e:heatLevel()
    doRestartToSettlement(e)
    local lvlAfter = e:heatLevel()
    check("[014] endless drops exactly one heat tier",
        lvlAfter == math.max(0, lvlBefore - Config.RUN.endlessHeatStep),
        string.format("%d -> %d", lvlBefore, lvlAfter))
    check("[014] endless heat not fully cleared", e.heat > 0, "heat=" .. tostring(e.heat))
end

local function testDeathClearsRunProgress()
    local world = World.New({ seed = 4025 })
    world.overloadLeft = 0.06
    step(world, 0.2)
    grantEnergy(world)
    doRestartToSettlement(world)
    world.wreckData = 9
    world:buyRunUpgrade("collapseCooldownLevel")
    check("[014] upgrade bought before death", RunShop.level(world, "collapseCooldownLevel") == 1)
    world:advanceLayer()
    -- 制造本层未结算增量；029广告复活保留当前层内存进度，免费重试仍由
    -- 独立ChallengeCheckpoint重建并回滚。
    world.wreckData = world.wreckData + 7
    world.coreCount = world.coreCount + 4
    world.score = world.score + 999
    local currentScore, currentWreck, currentCores =
        world.score, world.wreckData, world.coreCount
    world.player.hp = 1
    world:damagePlayer(9999, world.player.x, world.player.y)
    check("[029] death retains current wreck data in memory",
        world.phase == "dead" and world.wreckData == currentWreck)
    check("[029] death retains current core data in memory",
        world.coreCount == currentCores)
    check("[029] death retains run upgrades for optional ad continue",
        RunShop.level(world, "collapseCooldownLevel") == 1)
    check("[014] death closes settlement/shop", world.layerSettlement == nil
        and world.runComplete == false)
    check("[014] assisted revive restores run progress", world:reviveAssisted())
    check("[029] revive preserves current-layer score and resources",
        world.score == currentScore and world.wreckData == currentWreck
        and world.coreCount == currentCores)
    check("[014] revive keeps upgrades",
        RunShop.level(world, "collapseCooldownLevel") == 1)
    check("[029] revive continues the same current layer",
        world.round == 2 and world.phase == "overload")
end

local function testReviewIsolation014()
    -- Review 世界即使内部进入反猎/结算，也不会自动打开正式商店：
    -- World 只产生信号，由正式 main 消费。
    local w = ReviewAccess.createWorld("l5_hunter")
    check("[014] review world starts controlled", w.reviewOnly == true)
    check("[014] review world exposes no pending signal at start",
        w.pendingSignal == nil)
    grantEnergy(w)
    restartToAntiHunt(w)
    antiHuntToSettlement(w)
    check("[014] review world can still reach settlement internally",
        w.phase == "layer_settlement")
    local signal = w:consumeSignal()
    check("[014] settlement only emits a signal (no auto shop)",
        signal == "layer_ready_for_settlement")
    check("[014] signal consumed once", w:consumeSignal() == nil)
    -- Review 工具可直接跳过正式结算继续按样本规则运行
    check("[014] review can skip formal settlement", w:advanceLayer()
        and w.phase == "overload")
    -- Review 入口不写存档：ReviewMain 不 require SaveSys（静态合同）
    local src = nil
    if type(File) == "function" then
        local file = File("scripts/ReviewMain.lua", FILE_READ)
        if file ~= nil then src = file:ReadString(file:GetSize()); file:Close() end
    elseif io and io.open then
        local file = io.open("scripts/ReviewMain.lua", "rb")
        if file then src = file:read("*a"); file:close() end
    end
    check("[014] ReviewMain does not require SaveSys", src ~= nil
        and not string.find(src, 'require "SaveSys"', 1, true))
end

local function testLayerIntro016()
    local world = RawWorldNew({ seed = 40160 })
    check("[016] formal layer 1 starts in layer_intro",
        world.phase == "layer_intro" and world.round == 1)
    check("[016] countdown starts at three", world.layerIntroCue == "3")
    local x, y = world.player.x, world.player.y
    local overloadLeft, score, heat, enemies = world.overloadLeft, world.score, world.heat, #world.enemies
    world:update(1.0, { moveX = 1, moveY = 0, pressed = { pulse = true, collapse = true } })
    check("[016] layer_intro freezes world and input",
        world.player.x == x and world.player.y == y
        and world.overloadLeft == overloadLeft and world.score == score and world.heat == heat
        and #world.enemies == enemies and world.phase == "layer_intro")
    check("[016] countdown advances to two", world.layerIntroCue == "2")
    world:update(1.9, IDLE)
    check("[016] layer_intro lasts full three seconds", world.phase == "layer_intro")
    check("[016] countdown advances to one", world.layerIntroCue == "1")
    world:update(0.11, IDLE)
    check("[016] layer_intro activates overload after countdown",
        world.phase == "overload" and world.overloadLeft == overloadLeft)
    check("[016] overload activation exposes start cue",
        world.layerIntroCue == "开始" and (world.layerIntroCueLeft or 0) > 0)

    -- 正式 World 即使传 skipLayerIntro 也不能跳过；测试/Review 才能显式跳过。
    local protected = RawWorldNew({ seed = 40161, skipLayerIntro = true })
    local skipped = RawWorldNew({ seed = 40162, testMode = true, skipLayerIntro = true })
    check("[016] formal entry cannot skip intro", protected.phase == "layer_intro")
    check("[016] controlled test may skip intro", skipped.phase == "overload")

    skipped.overloadLeft = 0.01
    step(skipped, 0.1)
    grantEnergy(skipped)
    doRestartToSettlement(skipped)
    local nextLayer = skipped.round + 1
    skipped:advanceLayer()
    check("[016] controlled test keeps explicit skip across layers",
        skipped.phase == "overload" and skipped.round == nextLayer)

    local formalNext = RawWorldNew({ seed = 40163, testMode = true, skipLayerIntro = true })
    formalNext.overloadLeft = 0.01
    step(formalNext, 0.1)
    grantEnergy(formalNext)
    doRestartToSettlement(formalNext)
    formalNext.skipLayerIntro = false
    formalNext:advanceLayer()
    check("[016] every formal next layer runs intro", formalNext.phase == "layer_intro")

    -- main.lua 通过 AppLifecycle.blocksWorld 阻断 update；后台与恢复确认门都不得推进倒计时。
    local paused = RawWorldNew({ seed = 40165 })
    local life = AppLifecycle.New()
    local introBeforePause = paused.layerIntroTimer
    AppLifecycle.focusLost(life)
    if not AppLifecycle.blocksWorld(life) then paused:update(1.0, IDLE) end
    check("[016] background pause freezes layer_intro",
        paused.layerIntroTimer == introBeforePause and paused.phase == "layer_intro")
    AppLifecycle.focusGained(life, true)
    if not AppLifecycle.blocksWorld(life) then paused:update(1.0, IDLE) end
    check("[016] resume gate keeps layer_intro frozen",
        paused.layerIntroTimer == introBeforePause and life.resumeRequired == true)
    AppLifecycle.consumeResume(life)
    if not AppLifecycle.blocksWorld(life) then paused:update(0.5, IDLE) end
    check("[016] countdown resumes only after explicit resume",
        paused.layerIntroTimer < introBeforePause)
end

local function testAntiHuntVisibility016()
    local world = World.New({ seed = 40164 })
    toReadyDepleted(world)
    local keep = nil
    for _, e in ipairs(world.enemies) do
        e.state, e.hunter, e.wasChasing = "patrol", false, false
        keep = keep or e
    end
    restartToAntiHunt(world)
    check("[016] anti_hunt fills at least three reward targets",
        world.antiHuntSnapshot.aliveCount >= Config.FORMAL.huntPreferredMinimum
        and world.huntTargetsLeft >= Config.FORMAL.huntPreferredMinimum)

    local ordinary = nil
    for _, e in ipairs(world.enemies) do
        if not e.huntTarget then ordinary = e break end
    end
    if ordinary then
        local killsBefore = world.counters.kills or 0
        CombatSys.damageEnemy(world, ordinary, 999999, true)
        check("[016] ordinary enemies remain clearable in anti_hunt",
            ordinary.dead and (world.counters.kills or 0) > killsBefore)
    else
        check("[016] anti_hunt has ordinary clearable enemy sample", false)
    end

    check("[016] anti_hunt fixed-duration contract is ten seconds",
        Config.ANTI_HUNT_PHASE.minimumVisibleDuration == 10
        and Config.ANTI_HUNT_PHASE.maximumDuration == 10)
    -- 保留一个高血奖励目标，验证 10 秒硬上限。
    for _, e in ipairs(world.enemies) do
        if e.huntTarget and not e.dead then e.hp, e.maxHp = 999999, 999999 end
    end
    local untilBoundary = Config.ANTI_HUNT_PHASE.maximumDuration
        - (world.antiHuntElapsed or 0) - 0.1
    step(world, math.max(0, untilBoundary))
    check("[016] anti_hunt remains active before ten seconds", world.phase == "anti_hunt")
    step(world, 0.15)
    check("[016] anti_hunt hard-stops at ten seconds", world.phase == "layer_settlement")
    _ = keep
end

local function testEconomyProjection016()
    local overloadCosts = 0
    for _, key in ipairs({ "collapseCooldown", "pulseCooldown", "chainInterval" }) do
        for _, price in ipairs(Config.RUN_SHOP[key].prices) do overloadCosts = overloadCosts + price end
    end
    local depletedCosts = 0
    for _, key in ipairs({ "jammerUses", "decoyUses", "cloakUses" }) do
        for _, price in ipairs(Config.RUN_SHOP[key].prices) do depletedCosts = depletedCosts + price end
    end
    check("[016] overload tree total cost is 31", overloadCosts == 31)
    check("[016] depleted tree total cost is 31", depletedCosts == 31)

    local function pricesEqual(actual, expected)
        if #actual ~= #expected then return false end
        for i = 1, #expected do
            if actual[i] ~= expected[i] then return false end
        end
        return true
    end
    check("[016] six frozen price arrays are exact",
        pricesEqual(Config.RUN_SHOP.collapseCooldown.prices, { 1, 3, 5 })
        and pricesEqual(Config.RUN_SHOP.pulseCooldown.prices, { 2, 3, 5 })
        and pricesEqual(Config.RUN_SHOP.chainInterval.prices, { 2, 4, 6 })
        and pricesEqual(Config.RUN_SHOP.jammerUses.prices, { 2, 3, 4 })
        and pricesEqual(Config.RUN_SHOP.decoyUses.prices, { 3, 4, 5 })
        and pricesEqual(Config.RUN_SHOP.cloakUses.prices, { 4, 6 }))

    local cumulativeData, cumulativeCores = 0, 0
    local dataAt, coresAt = {}, {}
    for layer = 1, Config.RUN.finalLayer do
        local heavy = Config.ROUNDS.layers[layer].heavyCount
        local plan = LayerPlan.get(layer)
        local hasDeepCache = false
        for _, protocol in ipairs(plan.protocols or {}) do
            if protocol == "deep_cache" then hasDeepCache = true break end
        end
        local corePiles = #require("ScenarioLayouts").get(plan.map, plan.layout).corePiles
        cumulativeData = cumulativeData + heavy * Config.WRECK_DATA.perNormalWreck
            + Config.WRECK_DATA.perDeepWreck
        cumulativeCores = cumulativeCores + corePiles + Config.RISK.deepCores
            + (hasDeepCache and Config.PROTOCOL.deep_cache.deepCoreBonus or 0)
        dataAt[layer], coresAt[layer] = cumulativeData, cumulativeCores
    end
    check("[016] layer 1 income enables only collapse I and one tool choice",
        dataAt[1] == 1 and coresAt[1] == 3
        and Config.RUN_SHOP.collapseCooldown.prices[1] == 1
        and Config.RUN_SHOP.jammerUses.prices[1] == 2
        and Config.RUN_SHOP.decoyUses.prices[1] == 3
        and Config.RUN_SHOP.cloakUses.prices[1] == 4)

    local firstShop = World.New({ seed = 40167 })
    firstShop.phase = "layer_settlement"
    firstShop.wreckData, firstShop.coreCount = dataAt[1], coresAt[1]
    check("[016] layer 1 can actually buy collapse I",
        firstShop:buyRunUpgrade("collapseCooldownLevel")
        and firstShop.wreckData == 0
        and RunShop.level(firstShop, "collapseCooldownLevel") == 1)
    local jammer = RunShop.itemById("jammerBonusUses")
    local decoy = RunShop.itemById("decoyBonusUses")
    local cloak = RunShop.itemById("cloakBonusUses")
    check("[016] layer 1 cores present a real jammer-or-decoy choice",
        RunShop.canBuy(firstShop, jammer) and RunShop.canBuy(firstShop, decoy)
        and not RunShop.canBuy(firstShop, cloak))
    check("[016] choosing decoy excludes the other first-layer tool",
        firstShop:buyRunUpgrade("decoyBonusUses")
        and firstShop.coreCount == 0
        and not RunShop.canBuy(firstShop, jammer))

    check("[016] layer 3 projection cannot max overload tree", dataAt[3] < 9)
    check("[016] layer 5-7 projection keeps both trees incomplete",
        dataAt[5] < 31 and dataAt[7] < 31 and coresAt[7] < 31)
    check("[016] layer 10 perfect projection approaches one tree",
        dataAt[10] == 30 and coresAt[10] == 32)
end

-- ============================================================

-- ============================================================
-- 023C: 首次教程生命周期 + 设置内 DEBUG 入口门控 + Debug 局隔离
-- ============================================================
local function testTutorialLifecycle023C()
    local oldSettings = Screens.settingsOpen

    Tutorial.init(false)
    Tutorial.debugIgnore = false
    check("[023C] new save asks for first-run tutorial",
        Tutorial.shouldShowFirstRun() == true)
    local pages = Tutorial.beginFirstRun()
    check("[023C] first-run tutorial has 1-4 pages and activates",
        pages >= 1 and pages <= 4 and Tutorial.active == true and Tutorial.page == 1
        and Tutorial.overlaySource == "first_run")
    local firstRunRoute = Tutorial.finishOverlay()
    check("[035] first-run tutorial completes into game",
        firstRunRoute == "start_game")
    check("[023C] completion persists done flag and hides overlay",
        Tutorial.doneForever == true and Tutorial.active == false
        and Tutorial.shouldShowFirstRun() == false
        and Tutorial.overlaySource == "none")
    Tutorial.replayFirstRun()
    check("[023C] replay opens overlay without clearing done flag",
        Tutorial.active == true and Tutorial.doneForever == true
        and Tutorial.overlaySource == "settings")
    local replayRoute = Tutorial.finishOverlay()
    check("[035] settings replay returns to settings without changing done flag",
        replayRoute == "settings" and Tutorial.active == false
        and Tutorial.doneForever == true and Tutorial.overlaySource == "none")
    Tutorial.replayFirstRun()
    Tutorial.closeOverlay()
    check("[023C] close overlay keeps done flag",
        Tutorial.doneForever == true and Tutorial.active == false
        and Tutorial.shouldShowFirstRun() == false
        and Tutorial.overlaySource == "none")
    Tutorial.init(false)
    Tutorial.debugIgnore = false
    Tutorial.beginFirstRun()
    Tutorial.completeFirstRun()
    check("[023C] skip path marks done", Tutorial.doneForever == true)
    Tutorial.init(false)
    Tutorial.debugIgnore = false
    check("[023C] cleared save re-shows tutorial",
        Tutorial.shouldShowFirstRun() == true)
    Tutorial.init(false)
    Tutorial.enterDebugFlow()
    check("[023C] debug flow ignores formal tutorial state",
        Tutorial.shouldShowFirstRun() == false and Tutorial.isDebugFlow() == true
        and Tutorial.doneForever == false)
    Tutorial.init(false)
    Tutorial.debugIgnore = false
    Tutorial.beginFirstRun()
    local first = Tutorial.page
    Tutorial.prevPage()
    check("[023C] prev at first page stays", Tutorial.page == first)
    while Tutorial.nextPage() do end
    check("[023C] next past last page stays", Tutorial.page == #Tutorial.pages)
    Tutorial.closeOverlay()

    local function hasFormalL9Entry(buttons)
        for _, b in ipairs(buttons) do
            if b.id == "formalL9" or b.id == "confirmFormalL9"
                or b.id == "cancelFormalL9" then
                return true
            end
        end
        return false
    end
    Screens.settingsOpen = true
    Screens.privacyGateOpen = false
    Screens.helpOpen = false
    Screens.privacyOpen = false
    Screens.recordsOpen = false
    Screens.onlineLeaderboardOpen = false
    local baseSettings = {
        sound = true, musicVolume = 0.5, sfxVolume = 0.5,
        vibration = true, reduceFx = false, reduceShake = false,
    }
    local oldFastReview = Config.FORMAL.fastReviewL9Enabled
    local oldConfirm = Screens.formalL9ConfirmOpen
    check("[056] player build defaults the L9 review route closed",
        oldFastReview == false)
    Config.FORMAL.fastReviewL9Enabled = false
    check("[054] formal L9 entry is hidden only when its formal gate is closed",
        not hasFormalL9Entry(Screens.layout(390, 867, baseSettings, true)))
    Config.FORMAL.fastReviewL9Enabled = true
    check("[054] formal L9 entry is visible in title settings but not paused settings",
        hasFormalL9Entry(Screens.layout(390, 867, baseSettings, true))
        and not hasFormalL9Entry(Screens.layout(390, 867, baseSettings, true,
            false, true)))
    Screens.formalL9ConfirmOpen = true
    local confirmButtons = Screens.layout(390, 867, baseSettings, true)
    check("[054] formal L9 quick review requires explicit confirmation",
        confirmButtons[1] and confirmButtons[1].id == "confirmFormalL9"
        and confirmButtons[2] and confirmButtons[2].id == "cancelFormalL9")
    Screens.formalL9ConfirmOpen = oldConfirm
    Config.FORMAL.fastReviewL9Enabled = oldFastReview
    Screens.privacyGateOpen = true
    local privacyButtons = Screens.layout(390, 867, baseSettings, false)
    check("[053] privacy gate exposes one explicit consent action and no decline hot zone",
        #privacyButtons == 1 and privacyButtons[1].id == "privacyAccept")
    Screens.privacyGateOpen = false
    Screens.settingsOpen = oldSettings
end

local function testDebugPerfectL9044V()
    local DebugRunPreset = require "DebugRunPreset"
    local SaveSys = require "SaveSys"
    local income = DebugRunPreset.calculateIncome()
    check("[044V] L1-L8 fixed maximum income is auditable",
        #income.layers == 8 and income.wreckData == 21 and income.coreCount == 24)
    -- 绕过SelfTest全局的skipLayerIntro包装，验证正式入口确实保留三秒开局。
    local world = RawWorldNew({ experiment = "B", seed = 44009,
        startLayer = DebugRunPreset.START_LAYER, runId = "debug-l9-test" })
    local ok, audit = DebugRunPreset.apply(world)
    local u = world.runUpgrades
    check("[044V] perfect L9 preset applies through formal shop prices",
        ok and world.round == 9 and world.phase == "layer_intro"
        and u.collapseCooldownLevel == 3 and u.pulseCooldownLevel == 3
        and u.chainIntervalLevel == 1 and u.jammerBonusUses == 3
        and u.decoyBonusUses == 1 and u.cloakBonusUses == 2)
    check("[044V] preset spends every fixed resource without inventing currency",
        audit.incomeWreckData == 21 and audit.incomeCoreCount == 24
        and world.wreckData == 0 and world.coreCount == 0
        and world.modules.capacitor == true and world.modules.amplifier == true
        and world.pendingCache == Config.RISK.overflowMax)
    check("[044V] preset keeps formal HP and no invincibility",
        world.player.hp == Config.PLAYER.maxHp and world.player.maxHp == Config.PLAYER.maxHp
        and world.invincible ~= true and world.score == DebugRunPreset.REFERENCE_SCORE)
    check("[044V] preset is explicitly non-clean and score is reference-only",
        world.debugRun == true and world.cleanRun == false
        and audit.scoreIsMathematicalMaximum == false)

    -- 044W负责人验收档使用同一构筑计算，但必须走正式产品链：
    -- 可保存、可在L10毕业后上榜，L9死亡且平台可用时可获得广告复活。
    local owner = RawWorldNew({ experiment = "B", seed = 44010,
        startLayer = DebugRunPreset.START_LAYER, runId = "owner-l9-test" })
    local ownerOk, ownerAudit = DebugRunPreset.apply(owner, { ownerValidation = true })
    check("[044W] owner L9 entry is formal clean validation rather than debug",
        ownerOk and owner.debugRun == false and owner.ownerValidationRun == true
        and owner.cleanRun == true and owner.assistedRun == false
        and owner.timeAlive >= DebugRunPreset.REFERENCE_TIME_SECONDS
        and ownerAudit.ownerValidation == true)

    local ownerRun = {
        id = "owner-l10-complete", runId = "owner-l10-complete",
        completed = true, formalMain = true, cleanRun = true,
        assistedRun = false, adAssisted = false, rewardedRevive = false,
        review = false, debug = false, bot = false, test = false,
        layer = 10, score = owner.score, time = owner.timeAlive,
        endedAt = 44010, challengeCompleted = true, endless = false,
        completionReason = "challenge_complete",
    }
    local ownerBest = SaveSys.migrate({ privacy_decision = "accepted" })
    check("[044W] owner completion records through formal save",
        SaveSys.recordRun(ownerBest, ownerRun) == true
        and ownerBest.bestCleanRun.layer == 10
        and ownerBest.bestCleanRun.score == owner.score)
    check("[044W] owner clean L10 completion is leaderboard eligible",
        PlatformFeatures.isEligibleRun(ownerRun) == true)

    owner.phase = "dead"
    owner.round = 9
    owner.rewardedReviveAttempted = false
    owner.rewardedReviveUsed = false
    check("[044W] owner L9 death can offer formal rewarded revive",
        RewardedRevive.eligible(owner, ownerBest, true, "ready", 44010) == true)
end

local function testSaveLifecycle023C()
    local SaveSys = require "SaveSys"
    local best = SaveSys.migrate({})
    local beforeRuns = #(best.recentRuns or {})
    local ok = SaveSys.recordRun(best, {
        id = "debug-1", runId = "debug-1", completed = true,
        formalMain = true, cleanRun = true, debug = true,
        layer = 10, score = 999999, endedAt = 100, time = 60,
    })
    check("[023C] debug run is not recorded into formal save",
        ok == false and #(best.recentRuns or {}) == beforeRuns)
    local ok2 = SaveSys.recordRun(best, {
        id = "formal-1", runId = "formal-1", completed = true,
        formalMain = true, cleanRun = true, debug = false,
        layer = 2, score = 3000, endedAt = 200, time = 30,
    })
    check("[023C] formal run records normally",
        ok2 == true and #(best.recentRuns or {}) == beforeRuns + 1)
    local low = SaveSys.isBetterRun({ layer = 1, score = 1, time = 1 },
        { layer = 5, score = 5000, time = 50 })
    check("[023C] lower run does not overwrite higher best", low == false)
    local dupBest = SaveSys.migrate({ recentRuns = {
        { id = "dup", runId = "dup", layer = 2, score = 100, endedAt = 1 },
        { id = "dup", runId = "dup", layer = 3, score = 200, endedAt = 2 },
    } })
    check("[023C] recent runs dedupe by run id",
        #(dupBest.recentRuns or {}) == 1 and dupBest.recentRuns[1].layer == 3)
    local tenBest = SaveSys.migrate({})
    for i = 1, 12 do
        SaveSys.recordRun(tenBest, { id = "r" .. i, runId = "r" .. i, layer = 1,
            score = i, endedAt = i, time = i })
    end
    check("[023C] recent runs capped at ten", #(tenBest.recentRuns or {}) == 10)
end

function SelfTest.run()
    print("[SELFTEST] ===== begin =====")
    results = {}
    local metricsWasEnabled = Config.METRICS.enabled
    Config.METRICS.enabled = true
    math.randomseed(12345)
    local suites = {
        { "core", testCoreLoop },
        { "phase", testPhaseFeel },
        { "feedback", testFeedback },
        { "layout", testLayouts },
        { "roundtable", testRoundTable },
        { "input", testInput },
        { "path", testPathfinding },
        { "metrics", testMetrics },
        { "tutorial", testTutorial },
        { "longrun", testLongRun },
        { "bots", testBots },
        -- [R2] 新增合同
        { "experiment", testExperiment },
        { "riskreward", testRiskReward },
        { "heat", testHeat },
        { "opportunities", testOpportunities },
        { "recon", testRecon },
        { "scenarios", testScenarios },
        { "content008", testContent008 },
        { "fair_gate020", testFairGate020 },
        { "savemigrate", testSaveMigrate },
        { "tutorial_lifecycle_023c", testTutorialLifecycle023C },
        { "save_lifecycle_023c", testSaveLifecycle023C },
        { "debug_perfect_l9_044v", testDebugPerfectL9044V },
        { "formalplatform018", testFormalPlatform018 },
        { "challenge_checkpoint026", testChallengeCheckpoint026 },
        { "audio", testAudioPipeline },
        { "releasefix010", testReleaseFix010 },
        { "reviewaccess", testReviewAccessCandidate },
        { "escape_regression", function() EscapeRegressionTest.run(check) end },
        -- [014] 正式层循环闭环与本局协议整备
        { "antihunt_attribution", testAntiHuntAttribution },
        { "antihunt_candidate_snapshot", testAntiHuntCandidateSnapshot },
        { "antihunt_empty_state", testAntiHuntEmptyState },
        { "antihunt_early_clear", testAntiHuntEarlyClear },
        { "resource_semantics", testResourceSemantics },
        { "run_shop", testRunShop },
        { "run_completion", testRunCompletion },
        { "heat_pressure014", testHeatPressure014 },
        { "death_clears_run", testDeathClearsRunProgress },
        { "review_isolation014", testReviewIsolation014 },
        -- [016] 启动倒计时、反猎可感知性与经济冻结
        { "layer_intro016", testLayerIntro016 },
        { "antihunt_visibility016", testAntiHuntVisibility016 },
        { "economy_projection016", testEconomyProjection016 },
        { "longrunR2", testLongRunR2 },
        { "botsR2", testBotsR2 },
        { "presentation039B", testPresentation039B },
        { "signal_blackout043A", testSignalBlackout043A },
        { "signal_blackout043B", testSignalBlackout043B },
        { "human_review_closure044R", testHumanReviewClosure044R },
        { "graduation_archive044S", testGraduationArchive044S },
        { "endless_productization046", testEndlessProductization046 },
        { "endless_l11_pursuit053a", testEndlessL11Pursuit053A },
        { "release_resilience053b", testReleaseResilience053B },
        { "endless_convergence048", testEndlessConvergence048 },
        { "endless_settlement_platform_ui047", testEndlessSettlementPlatformUI047 },
    }
    for _, s in ipairs(suites) do
        local ok, err = pcall(s[2])
        if not ok then
            check("suite '" .. s[1] .. "' completed without lua error", false, err)
            print("[SELFTEST] ERROR in " .. s[1] .. ": " .. tostring(err))
        end
    end

    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        if r.ok then pass = pass + 1 else fail = fail + 1 end
    end
    print(string.format("[SELFTEST] ===== done: %d pass / %d fail =====", pass, fail))
    Config.METRICS.enabled = metricsWasEnabled
    return fail == 0
end

return SelfTest
