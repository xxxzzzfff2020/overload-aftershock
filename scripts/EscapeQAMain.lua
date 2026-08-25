-- EscapeQAMain.lua
-- TECH QA ONLY：单追击者真实规则脱身验证入口，不读写存档/云/纪录/成绩。

local AppLifecycle = require "AppLifecycle"
local AudioSys = require "AudioSys"
local Config = require "Config"
local Haptics = require "Haptics"
local InputSys = require "InputSys"
local Render = require "Render"
local SafeDraw = require "SafeDraw"
local Tutorial = require "Tutorial"
local Util = require "Util"
local Viewport = require "Viewport"
local World = require "World"

---@type NVGContextWrapper
local vg = nil
---@type table
local world = nil
---@type table
local qaEnemy = nil
local qaPassed = false
local mouseDown = false
local lifecycle = AppLifecycle.New()

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

local function createQAWorld()
    local w = World.New({ experiment = Config.FORMAL.profile, seed = 42001, startLayer = 1 })
    w:forceDrop()
    w.enemies = {}
    w.enemyPool = Util.newPool()
    w.player.hp = w.player.maxHp
    local p = w.player
    local enemy = w:spawnEnemy("drone", p.x - 76, p.y,
        { { 4, 4 }, { 5, 4 } }, false)
    enemy.daze, enemy.stun, enemy.jammed = 0, 0, 0
    enemy.state, enemy.stateTime, enemy.suspicion = "chase", 0, 0
    enemy.lastSeenX, enemy.lastSeenY = p.x, p.y
    enemy.wasChasing, enemy.angle = true, 0
    w.reviewOnly = true
    w.reviewSampleId = "tech_escape"
    w.reviewControlled = true
    w:addFx("banner", { text = "TECH QA · 真实追击 · 使用工具后持续移动", dur = 2.5 })
    return w, enemy
end

local function resetQA()
    world, qaEnemy = createQAWorld()
    qaPassed = false
    InputSys.reset()
    AppLifecycle.beginSession(lifecycle)
    AudioSys.setAmbient(world.phase, true)
    print(string.format(
        "[ESCAPE_QA] START enemy=drone state=%s distance=%.1f hp=%d invincible=false",
        qaEnemy.state, Util.dist(world.player.x, world.player.y, qaEnemy.x, qaEnemy.y),
        world.player.hp))
end

local function verifyEscape()
    if qaPassed or not world or not qaEnemy or qaEnemy.dead or world.phase == "dead" then return end
    local escapedState = qaEnemy.state == "lost" or qaEnemy.state == "search"
        or qaEnemy.state == "return" or qaEnemy.state == "patrol"
    local distance = Util.dist(world.player.x, world.player.y, qaEnemy.x, qaEnemy.y)
    if qaEnemy.wasChasing and escapedState and distance > 100 then
        qaPassed = true
        world:addFx("banner", { text = "TECH QA PASS · 已摆脱追击", dur = 4.0 })
        print(string.format(
            "[ESCAPE_QA] PASS state=%s distance=%.1f hp=%.1f cloak=%s decoy=%s",
            qaEnemy.state, distance, world.player.hp,
            tostring(world.cloakLeft > 0), tostring(qaEnemy.decoyTarget ~= nil)))
    end
end

function Start()
    graphics.windowTitle = "过载余波 · TECH ESCAPE QA ONLY"
    print("=== Overload Aftermath TECH ESCAPE QA ONLY starting ===")
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
    resetQA()

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
    if vg ~= nil then nvgDelete(vg); vg = nil end
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
    if lifecycle.resumeRequired or not world then return end

    InputSys.tick(world, dt)
    local frameInput = InputSys.collect()
    if world.phase == "dead" then
        if frameInput.pressed.again or frameInput.pressed.title then resetQA() end
        return
    end
    world:update(dt, frameInput)
    verifyEscape()
    Haptics.drain(world)
    AudioSys.drain(world)
end

local function drawQAStatus(w, h)
    local viewport = Viewport.metrics(w, h)
    local s = viewport.ui
    SafeDraw.font(10 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, qaPassed and nvgRGBA(100, 255, 170, 245)
        or nvgRGBA(255, 205, 90, 245))
    local status = qaPassed and "TECH QA PASS · 真实规则已脱战"
        or "TECH QA ONLY · 单追击者 · 无无敌/数值覆盖"
    if settings.reduceFx and settings.reduceShake then status = status .. " · 减闪减震" end
    SafeDraw.text(viewport.left + 8 * s, h - viewport.bottom - 10 * s, status)
end

function HandleRender(eventType, eventData)
    if vg == nil or not world then return end
    local viewport = Viewport.capture()
    local w, h = viewport.w, viewport.h
    nvgBeginFrame(vg, viewport.logicalW, viewport.logicalH, viewport.dpr)
    nvgSave(vg)
    nvgScale(vg, viewport.designScale, viewport.designScale)
    Render.draw(world, w, h, best)
    drawQAStatus(w, h)
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

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    if lifecycle.suspended or consumeResumeInput() then return end
    local key = eventData:GetInt("Key")
    if key == KEY_F1 or key == KEY_ESCAPE then resetQA(); return end
    if key == KEY_R then
        settings.reduceFx = not settings.reduceFx
        settings.reduceShake = settings.reduceFx
        Render.setSettings(settings)
        Haptics.applySettings(settings)
        world:addFx("banner", {
            text = settings.reduceFx and "TECH QA · 减闪减震开启" or "TECH QA · 标准表现",
            dur = 2.0,
        })
        return
    end
    InputSys.onKey(world, key, true)
end

---@param eventType string
---@param eventData KeyUpEventData
function HandleKeyUp(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or not world then return end
    InputSys.onKey(world, eventData:GetInt("Key"), false)
end

local function pointerDown(id, x, y)
    if lifecycle.suspended then return false end
    if consumeResumeInput() then return true end
    local viewport = Viewport.capture()
    InputSys.onPointerDown(world, id, x, y, viewport.w, viewport.h)
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
    if AppLifecycle.blocksWorld(lifecycle) or not world then return end
    local viewport = Viewport.capture()
    local x, y = Viewport.toLogicalPoint(eventData:GetInt("X"), eventData:GetInt("Y"), viewport)
    InputSys.onPointerMove(world, eventData:GetInt("TouchID"), x, y)
end

---@param eventType string
---@param eventData TouchEndEventData
function HandleTouchEnd(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or not world then return end
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
    if AppLifecycle.blocksWorld(lifecycle) or not world then return end
    InputSys.onPointerUp(world, -1)
end

---@param eventType string
---@param eventData MouseMoveEventData
function HandleMouseMove(eventType, eventData)
    if AppLifecycle.blocksWorld(lifecycle) or not world or not mouseDown then return end
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
    elseif AppLifecycle.focusGained(lifecycle, world ~= nil) then
        InputSys.onCancel()
        mouseDown = false
        if not lifecycle.resumeRequired then AudioSys.setPaused(false) end
    end
end
