-- ReviewMain.lua
-- REVIEW ONLY / NON-RELEASE：016T集中产品Review临时main入口。
-- 正式基线为3ae62eb；本入口不加载SaveSys、PlatformFeatures、排行榜或广告。

local AppLifecycle = require "AppLifecycle"
local AudioSys = require "AudioSys"
local Haptics = require "Haptics"
local InputSys = require "InputSys"
local Render = require "Render"
local ReviewAccess = require "ReviewAccess"
local RunShop = require "RunShop"
local Tutorial = require "Tutorial"
local Viewport = require "Viewport"

---@type NVGContextWrapper
local vg = nil
---@type table
local world = nil
local sample = nil
local appState = "review_menu"
local lastPhase = nil
local mouseDown = false
local lifecycle = AppLifecycle.New()

-- Review候选仅使用内存默认值，不读取或写入任何正式玩家数据。
local settings = {
    sound = true,
    musicVolume = 0.55,
    sfxVolume = 0.8,
    vibration = true,
    reduceFx = false,
    reduceShake = false,
}
local best = {
    round = 0,
    score = 0,
    bestCombo = 0,
    bestRun = { layer = 0, score = 0, time = 0 },
    recentRuns = {},
    settings = settings,
    tutorialDone = true,
}

local function logContract()
    local contract = ReviewAccess.contract()
    local blocked = { "persistence", "cloud", "localRecords", "leaderboard", "rewardedAd",
        "invincibility", "damageOverride", "healthOverride", "speedOverride",
        "enemyCountOverride", "priceOverride", "scoreRuleOverride" }
    for _, key in ipairs(blocked) do
        assert(contract[key] == false, "review isolation contract failed: " .. key)
    end
    print(string.format(
        "[016T_REVIEW] contract reviewOnly=%s release=%s safeState=%s source=%s",
        tostring(contract.reviewOnly), tostring(contract.releaseCandidate),
        tostring(contract.safeCheckpointInjection), tostring(contract.safeCheckpointSource)))
end

local function returnToReviewMenu()
    appState = "review_menu"
    world = nil
    sample = nil
    lastPhase = nil
    InputSys.reset()
    AudioSys.setPaused(false)
    AudioSys.setAmbient(nil, true)
end

local function startSample(id)
    AudioSys.unlock()
    AudioSys.play("ui_click")
    Haptics.light()
    world, sample = ReviewAccess.createWorld(id)
    -- 实际Review候选不得借SelfTest的testMode运行；测试桩只在SelfTest进程内存在。
    assert(world.testMode == false, "016T Review runtime must not use testMode")
    appState = "game"
    lastPhase = world.phase
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    AudioSys.setAmbient(world.phase, true)
    print(string.format(
        "[016T_REVIEW] START sample=%s layer=%d map=%s phase=%s seed=%d persistence=false route=%s",
        sample.id, world.round, world.mapId, world.phase, sample.seed, sample.route))
end

local function validatePhase()
    if not world or not sample then return end
    local ok = ReviewAccess.assertPhase(world, sample)
    assert(ok, "016T review runtime assertion failed: " .. sample.id .. "/" .. world.phase)
end

-- 与正式main相同的协议整备输入路径；唯一差异是结果不写存档/云/榜。
local function handleSettlementInput(frameInput)
    local pressed = frameInput.pressed
    for id in pairs(pressed) do
        local itemId = string.match(tostring(id), "^buy:(.+)$")
        if itemId then
            local ok = world:buyRunUpgrade(itemId)
            if ok then RunShop.pulse(world, itemId) end
        end
    end
    if not pressed.shopConfirm and not pressed.shopComplete then return false end
    AudioSys.play("ui_click")
    Haptics.light()
    local settlement = world.layerSettlement
    local runComplete = settlement and settlement.runComplete
    if pressed.shopComplete and runComplete then
        assert(world:completeChallenge() == true, "review complete challenge failed")
        print("[016T_REVIEW_RUNTIME] PASS complete_challenge layer=10 phase=dead")
    elseif runComplete then
        local before = ReviewAccess.snapshotRun(world)
        assert(world:chooseEndless() == true, "review continue endless failed")
        local ok = ReviewAccess.assertRunRetained(world, before, sample)
        assert(ok, "review endless retention assertion failed")
    else
        assert(world:advanceLayer() == true, "review advance layer failed")
    end
    InputSys.reset()
    lastPhase = world.phase
    AudioSys.setAmbient(world.phase, true)
    validatePhase()
    return true
end

function Start()
    graphics.windowTitle = "过载余波 · 016T REVIEW ONLY"
    print("=== Overload Aftermath 016T REVIEW ONLY / NON-RELEASE ===")
    logContract()
    vg = nvgCreate(1)
    if vg == nil then
        print("ERROR: nvgCreate failed")
        return
    end
    Render.init(vg)
    Render.setSettings(settings)
    AudioSys.init(settings)
    Haptics.applySettings(settings)
    Tutorial.init(true)

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
    SubscribeToEvent("InputFocus", "HandleInputFocus")
end

function Stop()
    AudioSys.shutdown()
    if vg ~= nil then
        nvgDelete(vg)
        vg = nil
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end
    if lifecycle.suspended then return end
    Render.tick(dt)
    AudioSys.tick(dt)
    Haptics.tick(dt)
    if lifecycle.resumeRequired or appState ~= "game" or world == nil then return end

    InputSys.tick(world, dt)
    local frameInput = InputSys.collect()
    if world.phase == "layer_settlement" then
        handleSettlementInput(frameInput)
        world:update(dt, frameInput)
        Haptics.drain(world)
        AudioSys.drain(world)
        return
    end

    if world.phase == "dead" then
        if frameInput.pressed.again then
            startSample(sample.id)
            return
        elseif frameInput.pressed.title then
            returnToReviewMenu()
            return
        end
    end

    world:update(dt, frameInput)
    world:consumeSignal()
    if world.phase ~= lastPhase then
        local previous = lastPhase
        lastPhase = world.phase
        InputSys.onPhaseChange()
        AudioSys.setAmbient(world.phase, true)
        print(string.format("[016T_REVIEW] PHASE sample=%s %s->%s layer=%d",
            sample.id, tostring(previous), tostring(world.phase), world.round))
        validatePhase()
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
    if appState == "review_menu" or world == nil then
        ReviewAccess.drawMenu(vg, w, h)
    else
        Render.draw(world, w, h, best)
        ReviewAccess.drawWatermark(vg, w, h, sample)
    end
    if lifecycle.resumeRequired then Render.drawResumeGate(w, h) end
    nvgRestore(vg)
    nvgEndFrame(vg)
end

local function consumeResumeInput()
    if not AppLifecycle.consumeResume(lifecycle) then return false end
    InputSys.reset()
    mouseDown = false
    AudioSys.setPaused(false)
    return true
end

local MENU_KEYS = {
    [KEY_1] = "natural",
    [KEY_2] = "l1_climax",
    [KEY_3] = "l6_economy",
    [KEY_4] = "l10_branch",
}

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    if lifecycle.suspended then return end
    if consumeResumeInput() then return end
    local key = eventData:GetInt("Key")
    if appState == "review_menu" then
        local id = MENU_KEYS[key]
        if id then startSample(id) end
        return
    end
    if key == KEY_F1 or key == KEY_ESCAPE then
        returnToReviewMenu()
        return
    end
    if world then InputSys.onKey(world, key, true) end
end

---@param eventType string
---@param eventData KeyUpEventData
function HandleKeyUp(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or appState ~= "game" or world == nil then return end
    InputSys.onKey(world, eventData:GetInt("Key"), false)
end

local function pointerDown(id, x, y)
    if lifecycle.suspended then return false end
    if consumeResumeInput() then return true end
    local viewport = Viewport.capture()
    local w, h = viewport.w, viewport.h
    if appState == "review_menu" then
        local action = ReviewAccess.hit(x, y, w, h)
        if action then startSample(action) end
        return true
    end
    if world then InputSys.onPointerDown(world, id, x, y, w, h) end
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
    if AppLifecycle.blocksWorld(lifecycle) or appState ~= "game" or world == nil then return end
    local viewport = Viewport.capture()
    local x, y = Viewport.toLogicalPoint(eventData:GetInt("X"), eventData:GetInt("Y"), viewport)
    InputSys.onPointerMove(world, eventData:GetInt("TouchID"), x, y)
end

---@param eventType string
---@param eventData TouchEndEventData
function HandleTouchEnd(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or appState ~= "game" or world == nil then return end
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
    if AppLifecycle.blocksWorld(lifecycle) or appState ~= "game" or world == nil then return end
    InputSys.onPointerUp(world, -1)
end

---@param eventType string
---@param eventData MouseMoveEventData
function HandleMouseMove(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or appState ~= "game" or world == nil or not mouseDown then return end
    local viewport = Viewport.capture()
    local mp = input.mousePosition
    local x, y = Viewport.toLogicalPoint(mp.x, mp.y, viewport)
    InputSys.onPointerMove(world, -1, x, y)
end

---@param eventType string
---@param eventData InputFocusEventData
function HandleInputFocus(eventType, eventData)
    local focus = eventData:GetBool("Focus")
    if not focus then
        if AppLifecycle.focusLost(lifecycle) then
            InputSys.onCancel()
            mouseDown = false
            AudioSys.setPaused(true)
        end
    else
        local needsGate = appState == "game" and world ~= nil
        if AppLifecycle.focusGained(lifecycle, needsGate) then
            InputSys.onCancel()
            mouseDown = false
            if not lifecycle.resumeRequired then AudioSys.setPaused(false) end
        end
    end
end
