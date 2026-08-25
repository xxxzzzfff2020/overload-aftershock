-- Render.lua
-- 全部画面:raw NanoVG(几何图形 + 连线 + 粒子,§15)。
-- 过载 = 高亮霓虹;枯竭 = 暗化 + 视野可读。断崖切换靠整套配色/HUD瞬间替换。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local InputSys = require "InputSys"
local SafeDraw = require "SafeDraw"
local Viewport = require "Viewport"
local EnemyAI = require "EnemyAI"
local Tutorial = require "Tutorial"
local Format = require "Format"
local AssetSprites = require "AssetSprites"
local Screens = require "Screens"
local TraceHeat = require "TraceHeat"
local SaveSys = require "SaveSys"
local NeonPolish = require "NeonPolish"
local RunShopRender = require "RunShopRender"
local EndlessOverclockRender = require "EndlessOverclockRender"
local TitleRender = require "TitleRender"
local PlatformFeatures = require "PlatformFeatures"
local SignalBlackout = require "SignalBlackout"
local RewardedRevive = require "RewardedRevive"

local Render = {}

---@type NVGContextWrapper
local vg = nil
local time = 0
-- [R2] 显示设置(SaveSys.settings;reduceFx = 减少闪烁/震动)
local settings = { reduceFx = false, reduceShake = false }

function Render.setSettings(s)
    if s then settings = s end
end

local COLORS = {
    cyan = { 80, 240, 255 }, blue = { 90, 150, 255 }, yellow = { 255, 230, 90 },
    orange = { 255, 170, 60 }, green = { 120, 255, 140 }, red = { 255, 80, 80 },
    purple = { 214, 53, 255 }, surface = { 20, 42, 86 }, border = { 10, 16, 32 },
}

local function C(rgb, a)
    return nvgRGBA(rgb[1], rgb[2], rgb[3], SafeDraw.alpha(a or 255))
end

-- 字体降级保护:无字体时跳过文本(几何 UI 照常,§任务包A 5.1)
local function text(x, y, str)
    SafeDraw.text(x, y, str)
end

function Render.init(context)
    vg = context
    SafeDraw.init(vg)
    AssetSprites.load(vg)   -- 首发正式几何美术；加载失败自动几何回退
    nvgShapeAntiAlias(vg, 1)
    nvgLineCap(vg, NVG_ROUND)
    nvgLineJoin(vg, NVG_ROUND)
    nvgMiterLimit(vg, 2)
end

function Render.tick(dt)
    time = time + dt
end

-- ============================================================
-- 相机
-- ============================================================
local cam = { x = 0, y = 0, scale = 1, shakeX = 0, shakeY = 0,
    battle = { x = 0, y = 0, w = 1, h = 1 } }

-- 反猎窗口在视觉上属于"过载家族"：高亮配色、无视野锥、玩家处于强势姿态。
local function isOverloadLook(world)
    return world.phase == "layer_intro" or world.phase == "overload" or world.phase == "anti_hunt"
end

local function updateCamera(world, w, h)
    cam.battle = Viewport.battlefield(w, h)
    cam.scale = math.min(cam.battle.w, cam.battle.h) / (Config.VIEW_TILES * Config.TILE)
    local viewW, viewH = cam.battle.w / cam.scale, cam.battle.h / cam.scale
    local mapW = world.map.w * Config.TILE
    local mapH = world.map.h * Config.TILE
    local px, py = world.player.x, world.player.y
    cam.x = Util.clamp(px - viewW / 2, 0, math.max(0, mapW - viewW))
    cam.y = Util.clamp(py - viewH / 2, 0, math.max(0, mapH - viewH))
    -- 屏幕震动([R2] 减少闪烁/震动设置下关闭)
    cam.shakeX, cam.shakeY = 0, 0
    if settings.reduceShake then return end
    for _, f in ipairs(world.fx) do
        if f.kind == "shake" then
            local k = (1 - f.age / (f.dur or 0.3)) * (f.power or 6)
            cam.shakeX = cam.shakeX + (math.random() - 0.5) * 2 * k
            cam.shakeY = cam.shakeY + (math.random() - 0.5) * 2 * k
        end
    end
end

local function wx(x) return cam.battle.x + (x - cam.x) * cam.scale + cam.shakeX end
local function wy(y) return cam.battle.y + (y - cam.y) * cam.scale + cam.shakeY end
local function ws(v) return v * cam.scale end

local function reducedFlashing()
    return settings.reduceFx == true or settings.reduceFlashing == true
end

-- ============================================================
-- 地图
-- ============================================================
local function drawMap(world, w, h)
    local t = Config.TILE
    local overload = isOverloadLook(world)
    local c1 = math.max(1, math.floor(cam.x / t))
    local r1 = math.max(1, math.floor(cam.y / t))
    local c2 = math.min(world.map.w, math.ceil((cam.x + cam.battle.w / cam.scale) / t) + 1)
    local r2 = math.min(world.map.h, math.ceil((cam.y + cam.battle.h / cam.scale) / t) + 1)

    -- 地板网格(过载亮 / 枯竭近乎不可见)
    nvgBeginPath(vg)
    for r = r1, r2 do
        for c = c1, c2 do
            if not world.solid[r][c] then
                nvgRect(vg, wx((c - 1) * t) + 1, wy((r - 1) * t) + 1, ws(t) - 2, ws(t) - 2)
            end
        end
    end
    local coreMap = world.mapId == "firewall_core"
    nvgFillColor(vg, coreMap
        and (overload and nvgRGBA(31, 35, 76, 255) or nvgRGBA(20, 15, 35, 255))
        or (overload and nvgRGBA(30, 40, 70, 255) or nvgRGBA(16, 18, 26, 255)))
    nvgFill(vg)

    -- 地图B以斜向数据纹理形成独立视觉语义；只改绘制，不改变碰撞或路线。
    if coreMap then
        nvgBeginPath(vg)
        for r = r1, r2 do
            for c = c1, c2 do
                if not world.solid[r][c] and (r + c) % 2 == 0 then
                    local x1, y1 = wx((c - 1) * t), wy(r * t)
                    nvgMoveTo(vg, x1 + ws(6), y1 - ws(6))
                    nvgLineTo(vg, x1 + ws(t - 6), y1 - ws(t - 6))
                end
            end
        end
        nvgStrokeColor(vg, overload and nvgRGBA(170, 90, 255, 58)
            or nvgRGBA(110, 70, 180, 48))
        nvgStrokeWidth(vg, math.max(1, ws(1.2)))
        nvgStroke(vg)
    end

    -- 墙体
    nvgBeginPath(vg)
    for r = r1, r2 do
        for c = c1, c2 do
            if world.solid[r][c] then
                nvgRect(vg, wx((c - 1) * t), wy((r - 1) * t), ws(t), ws(t))
            end
        end
    end
    if overload then
        nvgFillColor(vg, coreMap and nvgRGBA(73, 65, 150, 255)
            or nvgRGBA(60, 80, 140, 255))
    else
        nvgFillColor(vg, coreMap and nvgRGBA(54, 43, 78, 255)
            or nvgRGBA(40, 44, 58, 255))
    end
    nvgFill(vg)
    if coreMap then
        nvgBeginPath(vg)
        for r = r1, r2 do
            for c = c1, c2 do
                if world.solid[r][c] then
                    nvgRect(vg, wx((c - 1) * t) + 1, wy((r - 1) * t) + 1,
                        ws(t) - 2, ws(t) - 2)
                end
            end
        end
        nvgStrokeColor(vg, overload and nvgRGBA(120, 220, 255, 105)
            or nvgRGBA(190, 110, 255, 95))
        nvgStrokeWidth(vg, math.max(1.25, ws(1.5)))
        nvgStroke(vg)

        local coreX, coreY = wx(world.map.w * t * 0.5), wy(world.map.h * t * 0.5)
        nvgBeginPath(vg)
        nvgCircle(vg, coreX, coreY, ws(t * 1.55))
        nvgCircle(vg, coreX, coreY, ws(t * 0.75))
        nvgStrokeColor(vg, overload and nvgRGBA(80, 240, 255, 75)
            or nvgRGBA(214, 90, 255, 68))
        nvgStrokeWidth(vg, math.max(1.5, ws(2)))
        nvgStroke(vg)
    end

    -- 关闭状态的封锁门(青色屏障)
    if not world.gateOpen then
        for _, g in ipairs(world.map.gateTiles) do
            local blink = 150 + math.floor(80 * math.sin(time * 4))
            nvgBeginPath(vg)
            nvgRect(vg, wx((g.col - 1) * t) + 2, wy((g.row - 1) * t) + 2, ws(t) - 4, ws(t) - 4)
            nvgFillColor(vg, nvgRGBA(40, 160, 200, blink))
            nvgFill(vg)
        end
    end

    -- 激光走廊
    if world.laserActive then
        for _, g in ipairs(world.map.laserTiles) do
            local blink = 120 + math.floor(100 * math.sin(time * 8))
            nvgBeginPath(vg)
            nvgRect(vg, wx((g.col - 1) * t), wy((g.row - 1) * t), ws(t), ws(t))
            nvgFillColor(vg, nvgRGBA(255, 50, 50, blink // 2))
            nvgFill(vg)
            nvgBeginPath(vg)
            local cx = wx((g.col - 0.5) * t)
            nvgMoveTo(vg, cx, wy((g.row - 1) * t))
            nvgLineTo(vg, cx, wy(g.row * t))
            nvgStrokeColor(vg, nvgRGBA(255, 60, 60, blink))
            nvgStrokeWidth(vg, ws(6))
            nvgStroke(vg)
        end
    end
end

-- 信号黑障不是手电筒：地图结构仍可读，但只有玩家附近保持“在线”。
-- L4只预告边界、信息不隐藏；L5起外圈进一步失联。减闪模式保留静态边界与节点。
local function drawSignalBlackoutField(world)
    if world.phase ~= "depleted" then return end
    local policy = SignalBlackout.getPolicy(world)
    if not policy.visualField then return end
    local radius = SignalBlackout.getBaseVisualRadius(world)
    if radius <= 0 or radius == math.huge then return end

    local px, py = wx(world.player.x), wy(world.player.y)
    local rr = ws(radius)
    local preview = policy.previewOnly == true
    local reduced = reducedFlashing()
    local pulse = reduced and 1 or (0.985 + 0.015 * math.sin(time * 2.4))
    rr = rr * pulse

    local outerAlpha = math.floor((policy.outerBlackoutAlpha or 0)
        * (reduced and 0.82 or 1))
    if outerAlpha > 0 then
        local mask = nvgRadialGradient(vg, px, py, rr * 0.62, rr * 1.04,
            nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 2, 10, outerAlpha))
        nvgBeginPath(vg)
        nvgRect(vg, cam.battle.x, cam.battle.y, cam.battle.w, cam.battle.h)
        nvgFillPaint(vg, mask)
        nvgFill(vg)
    end

    -- 048：黑障只用外侧暗幕表达，不再绘制带可见边缘的常态大圆/角色视野圈。
    -- 侦察按钮触发的单一波圈由 drawRecon 独立保留，避免两种圈混为一谈。
    -- fieldAlpha 仍参与遮罩强度，保留黑障的可读性而不是把它变成发光范围提示。
    local fieldAlpha = math.floor((policy.fieldAlpha or 150) * (reduced and 0.86 or 1))
    if outerAlpha <= 0 and fieldAlpha > 0 then
        local fallbackMask = nvgRadialGradient(vg, px, py, rr * 0.62, rr,
            nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 2, 10, math.floor(fieldAlpha * 0.55)))
        nvgBeginPath(vg)
        nvgRect(vg, cam.battle.x, cam.battle.y, cam.battle.w, cam.battle.h)
        nvgFillPaint(vg, fallbackMask)
        nvgFill(vg)
    end

    -- 048：黑障的感知范围只由暗幕表达，不再绘制常态大边界圆。
    -- 侦察按钮触发的单一波圈由 drawRecon 独立保留，避免两种圈混为一谈。
    if preview then
        SafeDraw.font(10, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.blue, 185))
        text(px, Util.clamp(py - rr - 12, cam.battle.y + 14,
            cam.battle.y + cam.battle.h - 14), "感知边界预告")
    end
end

-- 地图B周期扫描：预警与生效使用同一固定区域，不改变碰撞或触控坐标。
local function drawScan(world)
    local scan = world.scan
    if world.phase ~= "depleted" or not scan or not scan.zone
        or (scan.state ~= "warning" and scan.state ~= "active") then return end
    local z = scan.zone
    local t = Config.TILE
    local x1, y1 = wx((z.c1 - 1) * t), wy((z.r1 - 1) * t)
    local x2, y2 = wx(z.c2 * t), wy(z.r2 * t)
    local active = scan.state == "active"
    local jammed = SignalBlackout.scanSignalMode(world) == "jammed"
    local pulse = 0.65 + 0.35 * math.sin(time * (active and 18 or 8))
    nvgBeginPath(vg)
    nvgRect(vg, x1, y1, x2 - x1, y2 - y1)
    nvgFillColor(vg, jammed and nvgRGBA(75, 165, 205, math.floor(22 * pulse))
        or active and nvgRGBA(255, 55, 80, math.floor(75 * pulse))
        or nvgRGBA(255, 190, 45, math.floor(48 * pulse)))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgRect(vg, x1, y1, x2 - x1, y2 - y1)
    nvgStrokeColor(vg, jammed and C(COLORS.blue, 155)
        or active and C(COLORS.red, 230) or C(COLORS.yellow, 210))
    nvgStrokeWidth(vg, jammed and 1.5 or active and 4 or 2)
    nvgStroke(vg)
    if jammed then
        SafeDraw.font(10, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.blue, 205))
        text((x1 + x2) * 0.5, (y1 + y2) * 0.5, "扫描信号受扰")
    end
end

-- ============================================================
-- 实体
-- ============================================================
local function drawValueSignal(visibility, color, radius)
    if not visibility or visibility.mode ~= "signal"
        or visibility.x == nil or visibility.y == nil then return end
    local x, y = wx(visibility.x), wy(visibility.y)
    local pulse = reducedFlashing() and 1 or 0.72 + 0.28 * math.sin(time * 6)
    local signalRadius = ws(radius or 24) * pulse
    nvgBeginPath(vg)
    nvgCircle(vg, x, y, signalRadius)
    nvgStrokeColor(vg, C(color, reducedFlashing() and 190 or 220))
    nvgStrokeWidth(vg, reducedFlashing() and 2 or 3)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x - signalRadius * 0.55, y)
    nvgLineTo(vg, x + signalRadius * 0.55, y)
    nvgMoveTo(vg, x, y - signalRadius * 0.55)
    nvgLineTo(vg, x, y + signalRadius * 0.55)
    nvgStrokeColor(vg, C(color, reducedFlashing() and 155 or 190))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)
end

local function drawPickups(world)
    local overload = isOverloadLook(world)
    local pulse = 0.8 + 0.2 * math.sin(time * 5)
    -- 基础储能:精灵优先,失败回退绿色菱形(枯竭醒目,过载压暗)
    for _, c in ipairs(world.cells) do
        local visibility = SignalBlackout.classify(world, c, "cell")
        if visibility.mode == "live" then
            local x, y = wx(c.x), wy(c.y)
            local alpha = overload and 70 or 255
            if not AssetSprites.draw("obj_cell", x, y, ws(24) * pulse, 0, alpha) then
                local s = ws(10) * pulse
                nvgBeginPath(vg)
                nvgMoveTo(vg, x, y - s); nvgLineTo(vg, x + s, y)
                nvgLineTo(vg, x, y + s); nvgLineTo(vg, x - s, y)
                nvgClosePath(vg)
                nvgFillColor(vg, C(COLORS.green, alpha))
                nvgFill(vg)
            end
            if not overload and c.route == "recovery" then
                nvgBeginPath(vg)
                nvgCircle(vg, x, y, ws(17) + ws(2) * math.sin(time * 4))
                nvgStrokeColor(vg, C(COLORS.cyan, 205))
                nvgStrokeWidth(vg, math.max(1.5, ws(2)))
                nvgStroke(vg)
            end
        end
    end
    -- 高级核心
    for _, c in ipairs(world.cores) do
        local visibility = SignalBlackout.classify(world, c, "core")
        if visibility.mode == "live" then
            local x, y = wx(c.x), wy(c.y)
            local alpha = overload and 80 or 255
            if not AssetSprites.draw("obj_core", x, y, ws(28) * pulse, time * 0.6, alpha) then
                local s = ws(12) * pulse
                nvgBeginPath(vg)
                for i = 0, 5 do
                    local a = i * math.pi / 3 + time
                    local px2, py2 = x + math.cos(a) * s, y + math.sin(a) * s
                    if i == 0 then nvgMoveTo(vg, px2, py2) else nvgLineTo(vg, px2, py2) end
                end
                nvgClosePath(vg)
                nvgFillColor(vg, C(COLORS.orange, alpha))
                nvgFill(vg)
            end
        elseif visibility.mode == "signal" then
            drawValueSignal(visibility, COLORS.orange, 28)
        end
    end
    -- 残骸(深层残骸金色高亮 + 脉冲圈,§R2)
    for _, wk in ipairs(world.wrecks) do
        local visibility = SignalBlackout.classify(world, wk, "wreck")
        if visibility.mode == "live" then
            local x, y = wx(wk.x), wy(wk.y)
            local sprite = wk.deep and "obj_deepwreck" or "obj_wreck"
            if not AssetSprites.draw(sprite, x, y, ws(44), 0, 255) then
                local s = ws(20)
                nvgBeginPath(vg)
                nvgRect(vg, x - s, y - s * 0.6, s * 1.2, s * 1.2)
                nvgRect(vg, x - s * 0.1, y - s, s * 1.0, s * 0.8)
                nvgFillColor(vg, wk.deep and nvgRGBA(90, 88, 60, 255) or nvgRGBA(110, 115, 130, 255))
                nvgFill(vg)
            end
            if not overload then
                nvgBeginPath(vg)
                nvgCircle(vg, x, y, ws(wk.deep and 30 or 24))
                nvgStrokeColor(vg, C(wk.deep and COLORS.yellow or COLORS.orange,
                    150 + math.floor(80 * math.sin(time * 4))))
                nvgStrokeWidth(vg, wk.deep and 3 or 2)
                nvgStroke(vg)
            end
        elseif visibility.mode == "signal" and wk.deep then
            drawValueSignal(visibility, COLORS.yellow, 32)
        end
    end
    -- 诱饵信标
    for _, d in ipairs(world.decoys) do
        local x, y = wx(d.x), wy(d.y)
        if not AssetSprites.draw("obj_decoy", x, y, ws(20), 0, 255) then
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, ws(8))
            nvgFillColor(vg, C(COLORS.yellow, 200))
            nvgFill(vg)
        end
        local ringR = ws(30 + (time * 90) % 60)
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, ringR)
        nvgStrokeColor(vg, C(COLORS.yellow, 120))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
        local signal = SignalBlackout.decoySignal(world, d)
        if signal.inboundCount > 0 then
            -- 只显示“有信号正向诱饵汇聚”，不泄露被吸引敌人的实时坐标。
            local spokes = math.min(4, signal.inboundCount)
            for i = 1, spokes do
                local a = i * math.pi * 2 / spokes + (reducedFlashing() and 0 or time * 0.35)
                local outer = ws(42 + i * 6)
                nvgBeginPath(vg)
                nvgMoveTo(vg, x + math.cos(a) * outer, y + math.sin(a) * outer)
                nvgLineTo(vg, x + math.cos(a) * ws(22), y + math.sin(a) * ws(22))
                nvgStrokeColor(vg, C(COLORS.yellow, reducedFlashing() and 145 or 185))
                nvgStrokeWidth(vg, 2)
                nvgStroke(vg)
            end
            SafeDraw.font(9, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.yellow, 205))
            text(x, y + ws(23), "汇聚信号 " .. signal.inboundCount)
        end
    end
end

-- [R2] 追踪中继器(实验B;精灵优先,回退绿色三角塔)
local function drawRelays(world)
    for _, rl in ipairs(world.relays) do
        if not rl.dead then
            local x, y = wx(rl.x), wy(rl.y)
            local s = ws(18)
            if not AssetSprites.draw("obj_relay", x, y, ws(44), 0, 255) then
                nvgBeginPath(vg)
                nvgMoveTo(vg, x, y - s)
                nvgLineTo(vg, x + s * 0.7, y + s)
                nvgLineTo(vg, x - s * 0.7, y + s)
                nvgClosePath(vg)
                nvgFillColor(vg, nvgRGBA(30, 70, 50, 255))
                nvgFill(vg)
                nvgStrokeColor(vg, C(COLORS.green, 220))
                nvgStrokeWidth(vg, 2)
                nvgStroke(vg)
            end
            -- 血条(过载与反猎窗口可打)
            if isOverloadLook(world) and rl.hp < rl.maxHp then
                nvgBeginPath(vg)
                nvgRect(vg, x - s, y - s - ws(8), s * 2 * (rl.hp / rl.maxHp), ws(4))
                nvgFillColor(vg, C(COLORS.green, 220))
                nvgFill(vg)
            end
        end
    end
end

local function drawFirewalls(world)
    for _, f in ipairs(world.firewalls) do
        if not f.dead then
            local x, y = wx(f.x), wy(f.y)
            local s = ws(16)
            nvgBeginPath(vg)
            nvgRect(vg, x - s, y - s, s * 2, s * 2)
            nvgFillColor(vg, nvgRGBA(20, 60, 90, 255))
            nvgFill(vg)
            nvgStrokeColor(vg, C(COLORS.cyan, 170 + math.floor(80 * math.sin(time * 3))))
            nvgStrokeWidth(vg, 3)
            nvgStroke(vg)
            -- 血条
            local ratio = f.hp / f.maxHp
            nvgBeginPath(vg)
            nvgRect(vg, x - s, y - s - ws(10), s * 2 * ratio, ws(5))
            nvgFillColor(vg, C(COLORS.cyan, 220))
            nvgFill(vg)
            -- 标记高亮
            if world.mark and world.mark.ref == f then
                nvgBeginPath(vg)
                nvgCircle(vg, x, y, s * 1.8 + ws(4) * math.sin(time * 6))
                nvgStrokeColor(vg, C(COLORS.yellow, 230))
                nvgStrokeWidth(vg, 3)
                nvgStroke(vg)
            end
        end
    end
end

-- 敌人视野扇形(枯竭阶段核心可读性,§15.2)
local function drawVisionCone(world, e)
    -- 隐身已切断实时目标信息；不再显示与逻辑不一致的缩短实心侦测锥。
    if world.cloakLeft > 0 then return end
    local cfg = Config.ENEMIES[e.kind]
    local diff = world:difficulty()
    local range = cfg.viewRange * diff.viewMul
    if e.jammed > 0 or e.daze > 0 or e.stun > 0 then return end
    local half = math.rad(math.min(cfg.viewAngle, 355)) * 0.5
    local alpha = 26
    local col = { 255, 255, 160 }
    if e.state == "suspect" then col = { 255, 200, 80 }; alpha = 45
    elseif e.state == "alert" or e.state == "chase" then col = { 255, 80, 60 }; alpha = 55 end
    nvgBeginPath(vg)
    nvgMoveTo(vg, wx(e.x), wy(e.y))
    local steps = 14
    for i = 0, steps do
        local a = e.angle - half + (half * 2) * (i / steps)
        nvgLineTo(vg, wx(e.x + math.cos(a) * range), wy(e.y + math.sin(a) * range))
    end
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(col[1], col[2], col[3], alpha))
    nvgFill(vg)
end

local function drawEnemy(world, e, visibility)
    local cfg = Config.ENEMIES[e.kind]
    local ghost = visibility and visibility.mode == "ghost"
    local tracked = visibility and visibility.mode == "tracked"
    local drawX = visibility and visibility.x or e.x
    local drawY = visibility and visibility.y or e.y
    local x, y = wx(drawX), wy(drawY)
    local r = ws(e.radius)
    local col = cfg.color
    local alpha = ghost and (reducedFlashing() and 72 or 105)
        or tracked and (reducedFlashing() and 125 or 165) or 255
    if not ghost and not tracked and e.hitFlash and e.hitFlash > 0 then
        col = { 255, 255, 255 }
    end
    -- [R2] 精灵优先(受击白闪时仍走几何以保留反馈)
    if not (e.hitFlash and e.hitFlash > 0)
        and AssetSprites.draw("enemy_" .. e.kind, x, y, r * 2.6, e.angle + math.pi / 2, alpha) then
        goto sprite_done
    end
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    nvgRotate(vg, e.angle + math.pi / 2)
    nvgBeginPath(vg)
    if e.kind == "drone" then
        nvgMoveTo(vg, 0, -r); nvgLineTo(vg, r * 0.8, r * 0.8); nvgLineTo(vg, -r * 0.8, r * 0.8)
        nvgClosePath(vg)
    elseif e.kind == "sentinel" then
        nvgRect(vg, -r * 0.85, -r * 0.85, r * 1.7, r * 1.7)
    elseif e.kind == "glitch" then
        for i = 0, 7 do
            local a = i * math.pi / 4
            local rr = (i % 2 == 0) and r or r * 0.55
            local jx = math.sin(time * 13 + i) * r * 0.12
            local px2, py2 = math.cos(a) * rr + jx, math.sin(a) * rr
            if i == 0 then nvgMoveTo(vg, px2, py2) else nvgLineTo(vg, px2, py2) end
        end
        nvgClosePath(vg)
    else -- heavy
        for i = 0, 5 do
            local a = i * math.pi / 3
            local px2, py2 = math.cos(a) * r, math.sin(a) * r
            if i == 0 then nvgMoveTo(vg, px2, py2) else nvgLineTo(vg, px2, py2) end
        end
        nvgClosePath(vg)
    end
    nvgFillColor(vg, nvgRGBA(col[1], col[2], col[3], alpha))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 70))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)
    nvgRestore(vg)
    ::sprite_done::

    if not ghost and not tracked then
        if e.kind == "heavy" or e.kind == "sentinel" then
            local ratio = Util.clamp(e.hp / e.maxHp, 0, 1)
            nvgBeginPath(vg)
            nvgRect(vg, x - r, y - r - ws(10), r * 2 * ratio, ws(4))
            nvgFillColor(vg, nvgRGBA(255, 120, 120, 220))
            nvgFill(vg)
        end

        if e.jammed > 0 then
            SafeDraw.font(ws(18), NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.blue, 230))
            text(x, y - r - ws(16), "×")
        elseif e.daze > 0 or e.stun > 0 then
            for i = 0, 2 do
                local a = time * 4 + i * math.pi * 2 / 3
                nvgBeginPath(vg)
                nvgCircle(vg, x + math.cos(a) * r * 0.7,
                    y - r - ws(12) + math.sin(a) * ws(4), ws(2.4))
                nvgFillColor(vg, nvgRGBA(160, 205, 255, 210))
                nvgFill(vg)
            end
        elseif world.phase == "depleted" then
            if e.state == "suspect" then
                SafeDraw.font(ws(20), NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, C(COLORS.yellow, 240))
                text(x, y - r - ws(18), "?")
                local prog = Util.clamp(e.suspicion / Config.AI.suspectTime, 0, 1)
                if prog > 0.02 then
                    nvgBeginPath(vg)
                    nvgArc(vg, x, y, r + ws(7), -math.pi / 2,
                        -math.pi / 2 + prog * math.pi * 2, NVG_CW)
                    nvgStrokeColor(vg, C(COLORS.yellow, 220))
                    nvgStrokeWidth(vg, 3)
                    nvgStroke(vg)
                end
            elseif e.state == "alert" or e.state == "chase" then
                SafeDraw.font(ws(22), NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, C(COLORS.red, 255))
                text(x, y - r - ws(18), "!")
            end
        end

        if e.huntTarget and (e.huntLeft or 0) > 0 then
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, r * 1.9 + ws(4) * math.sin(time * 8))
            nvgStrokeColor(vg, C(COLORS.yellow, 245))
            nvgStrokeWidth(vg, 4)
            nvgStroke(vg)
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, r * 2.25)
            nvgStrokeColor(vg, C(COLORS.cyan, 170))
            nvgStrokeWidth(vg, 2)
            nvgStroke(vg)
            AssetSprites.draw("icon_hunt", x, y - r * 2.3, ws(18), 0, 255)
            NeonPolish.drawHuntTarget(vg, x, y, r, time, settings)
        elseif e.hunter then
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, r * 1.75 + ws(5) * math.max(0, e.hunterPulse or 0))
            nvgStrokeColor(vg, C(COLORS.red, 220))
            nvgStrokeWidth(vg, 3)
            nvgStroke(vg)
            AssetSprites.draw("icon_alert", x, y - r * 2.0, ws(17), 0, 255)
        end

        if world.mark and world.mark.ref == e then
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, r * 1.6 + ws(3) * math.sin(time * 6))
            nvgStrokeColor(vg, C(COLORS.yellow, 240))
            nvgStrokeWidth(vg, 3)
            nvgStroke(vg)
        end
        NeonPolish.drawPursuit(vg, world, e, x, y, r, wx, wy, ws, time, settings)
    elseif tracked then
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, r * 1.7)
        nvgStrokeColor(vg, C(COLORS.yellow, 210))
        nvgStrokeWidth(vg, 2.5)
        nvgStroke(vg)
    end
end

local function drawDangerSignal(world, visibility)
    if not visibility or visibility.mode ~= "signal"
        or visibility.signalKind ~= "danger" or not visibility.directionAngle then return end
    local battle = cam.battle
    local centerX, centerY = battle.x + battle.w * 0.5, battle.y + battle.h * 0.5
    local halfW, halfH = math.max(12, battle.w * 0.5 - 18), math.max(12, battle.h * 0.5 - 18)
    local cosine, sine = math.cos(visibility.directionAngle), math.sin(visibility.directionAngle)
    local edgeScale = math.min(halfW / math.max(math.abs(cosine), 0.001),
        halfH / math.max(math.abs(sine), 0.001))
    local x, y = centerX + cosine * edgeScale, centerY + sine * edgeScale
    local alpha = reducedFlashing() and 155 or 220
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    nvgRotate(vg, visibility.directionAngle)
    nvgBeginPath(vg)
    nvgMoveTo(vg, ws(14), 0)
    nvgLineTo(vg, ws(-10), ws(-8))
    nvgLineTo(vg, ws(-7), 0)
    nvgLineTo(vg, ws(-10), ws(8))
    nvgClosePath(vg)
    nvgFillColor(vg, C(COLORS.red, alpha))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgCircle(vg, 0, 0, ws(15))
    nvgStrokeColor(vg, C(COLORS.yellow, alpha))
    nvgStrokeWidth(vg, reducedFlashing() and 1.5 or 2.5)
    nvgStroke(vg)
    nvgRestore(vg)
end

local threatLevel

local function drawPlayer(world)
    local p = world.player
    local x, y = wx(p.x), wy(p.y)
    local r = ws(p.radius)
    local overload = isOverloadLook(world)
    if overload then
        -- 霓虹光环
        local glow = nvgRadialGradient(vg, x, y, r, r * 3.2,
            nvgRGBA(80, 240, 255, 90), nvgRGBA(80, 240, 255, 0))
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, r * 3.2)
        nvgFillPaint(vg, glow)
        nvgFill(vg)
        -- 048：不绘制会被误认成视野边界的角色双层环；保留柔光和节点，
        -- 侦察按钮触发的真实波圈仍由 drawRecon 独立绘制。
        for i = 0, 3 do
            local a = time * (settings.reduceFx and 0.6 or 1.8) + i * math.pi * 0.5
            nvgBeginPath(vg)
            nvgCircle(vg, x + math.cos(a) * r * 1.8, y + math.sin(a) * r * 1.8, r * 0.16)
            nvgFillColor(vg, C(COLORS.cyan, 230))
            nvgFill(vg)
        end
    elseif world.energy >= world.energyNeed then
        -- 048：满能状态只保留角色本体的低亮，不再添加常态感知圈。
    end
    local alpha = 255
    if world.cloakLeft > 0 then alpha = 90 end
    -- [R2] 精灵优先(带朝向旋转),失败回退几何圆
    local sprite = overload and "player_overload" or "player_depleted"
    if not AssetSprites.draw(sprite, x, y, r * 2.6, p.faceAngle + math.pi / 2, alpha) then
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, r)
        -- 039B：枯竭玩家用低饱和蓝灰 + 细暗描边，与过载高亮青形成“有/无力量”的静帧差异。
        nvgFillColor(vg, overload and nvgRGBA(120, 250, 255, alpha) or nvgRGBA(64, 92, 128, alpha))
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgStrokeWidth(vg, overload and 3 or 1.5)
        nvgStroke(vg)
        -- 朝向
        nvgBeginPath(vg)
        nvgMoveTo(vg, x, y)
        nvgLineTo(vg, x + math.cos(p.faceAngle) * r * 1.5, y + math.sin(p.faceAngle) * r * 1.5)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
    end
    -- 受击闪红
    if p.hurtFlash > 0 then
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, r * 1.4)
        nvgStrokeColor(vg, nvgRGBA(255, 60, 60, 200))
        nvgStrokeWidth(vg, 3)
        nvgStroke(vg)
    end
    if world.phase == "depleted" and threatLevel(world) >= 2 then
        -- 被发现时使用统一警报框，不写内部 AI 状态。
        local br = r * 1.65
        nvgBeginPath(vg)
        nvgMoveTo(vg, x - br, y - br * 0.55); nvgLineTo(vg, x - br, y - br)
        nvgLineTo(vg, x - br * 0.55, y - br)
        nvgMoveTo(vg, x + br, y - br * 0.55); nvgLineTo(vg, x + br, y - br)
        nvgLineTo(vg, x + br * 0.55, y - br)
        nvgStrokeColor(vg, C(COLORS.red, 230))
        nvgStrokeWidth(vg, 3)
        nvgStroke(vg)
    end
    NeonPolish.drawCloak(vg, world, x, y, r, time, settings)
    -- 拆解读条
    if world.dismantle then
        local ratio = world.dismantle.t / Config.DEPLETED.dismantleTime
        nvgBeginPath(vg)
        nvgRect(vg, x - ws(30), y - r - ws(22), ws(60), ws(8))
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 180))
        nvgFill(vg)
        nvgBeginPath(vg)
        nvgRect(vg, x - ws(30), y - r - ws(22), ws(60) * ratio, ws(8))
        nvgFillColor(vg, C(COLORS.orange, 255))
        nvgFill(vg)
    end
    -- 重启引导读条(§任务包D:重启中的可视环)
    if world.restartChannel then
        local prog = Util.clamp(world.restartChannel.t / Config.FORMAL.restartChannelTime, 0, 1)
        nvgBeginPath(vg)
        nvgArc(vg, x, y, r * 1.9, -math.pi / 2, -math.pi / 2 + prog * math.pi * 2, NVG_CW)
        nvgStrokeColor(vg, C(COLORS.cyan, 240))
        nvgStrokeWidth(vg, 4)
        nvgStroke(vg)
        NeonPolish.drawRestart(vg, prog, x, y, r, time, settings)
    end
end

-- ============================================================
-- 特效
-- ============================================================
local function drawFx(world)
    for _, f in ipairs(world.fx) do
        local t01 = f.age / (f.dur or 1)
        local fade = math.floor(255 * (1 - t01))
        if NeonPolish.drawAntiHuntFx(vg, f, t01, wx, wy, ws, settings) then
            -- 已由程序化反猎层级绘制。
        elseif f.kind == "chain" then
            nvgStrokeColor(vg, nvgRGBA(120, 250, 255, fade))
            nvgStrokeWidth(vg, 3)
            for _, s in ipairs(f.segs) do
                nvgBeginPath(vg)
                local mx = (s.x1 + s.x2) / 2 + math.random(-8, 8)
                local my = (s.y1 + s.y2) / 2 + math.random(-8, 8)
                nvgMoveTo(vg, wx(s.x1), wy(s.y1))
                nvgLineTo(vg, wx(mx), wy(my))
                nvgLineTo(vg, wx(s.x2), wy(s.y2))
                nvgStroke(vg)
            end
        elseif f.kind == "beam" then
            nvgBeginPath(vg)
            nvgMoveTo(vg, wx(f.x1), wy(f.y1))
            nvgLineTo(vg, wx(f.x2), wy(f.y2))
            nvgStrokeColor(vg, nvgRGBA(255, 120, 255, fade))
            nvgStrokeWidth(vg, ws(8) * (1 - t01) + 2)
            nvgStroke(vg)
        elseif f.kind == "ring" or f.kind == "bigring" then
            nvgBeginPath(vg)
            nvgCircle(vg, wx(f.x), wy(f.y), ws((f.r or 100) * t01))
            nvgStrokeColor(vg, C(COLORS[f.color] or COLORS.cyan, fade))
            nvgStrokeWidth(vg, f.kind == "bigring" and 5 or 3)
            nvgStroke(vg)
        elseif f.kind == "burst" then
            for i = 1, 6 do
                local a = i * math.pi / 3 + f.age * 6
                local d = ws(30 * t01)
                nvgBeginPath(vg)
                nvgCircle(vg, wx(f.x) + math.cos(a) * d, wy(f.y) + math.sin(a) * d, ws(4) * (1 - t01))
                nvgFillColor(vg, C(COLORS[f.color] or COLORS.cyan, fade))
                nvgFill(vg)
            end
        elseif f.kind == "hitspark" then
            nvgBeginPath(vg)
            nvgCircle(vg, wx(f.x), wy(f.y), ws(10) * (1 - t01))
            nvgFillColor(vg, C(COLORS[f.color] or COLORS.red, fade))
            nvgFill(vg)
        elseif f.kind == "pickup" or f.kind == "score" then
            SafeDraw.font(ws(16), NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS[f.color] or COLORS.green, fade))
            local drift = f.kind == "score" and 34 or 20
            text(wx(f.x), wy(f.y) - ws(drift) * t01, f.text or "+")
        elseif f.kind == "zap" then
            nvgBeginPath(vg)
            nvgMoveTo(vg, wx(f.x1), wy(f.y1))
            nvgLineTo(vg, wx(f.x2), wy(f.y2))
            nvgStrokeColor(vg, C(COLORS.blue, fade))
            nvgStrokeWidth(vg, 3)
            nvgStroke(vg)
        elseif f.kind == "alertmark" and f.ref and not f.ref.dead then
            SafeDraw.font(ws(26), NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.red, fade))
            text(wx(f.ref.x), wy(f.ref.y - f.ref.radius - 30), "!")
        end
    end
end

-- ============================================================
-- HUD(§14)
-- ============================================================
local function drawBar(x, y, w2, h2, ratio, colFill, colBack)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w2, h2)
    nvgFillColor(vg, colBack)
    nvgFill(vg)
    if ratio > 0 then
        nvgBeginPath(vg)
        nvgRect(vg, x, y, math.max(2, w2 * Util.clamp(ratio, 0, 1)), h2)
        nvgFillColor(vg, colFill)
        nvgFill(vg)
    end
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w2, h2)
    nvgStrokeColor(vg, C(COLORS.border, 230))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
end

local function drawHudPanel(x, y, w2, h2, accent)
    -- BrawlForge：锐角暗蓝面板、硬阴影、黑色外框与底部强调线。
    nvgBeginPath(vg)
    nvgRect(vg, x + 3, y + 3, w2, h2)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 70))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w2, h2)
    nvgFillColor(vg, nvgRGBA(16, 34, 70, 232))
    nvgFill(vg)
    nvgStrokeColor(vg, C(COLORS.border, 255))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgRect(vg, x + 2, y + h2 - 4, w2 - 4, 3)
    nvgFillColor(vg, C(accent or COLORS.cyan, 220))
    nvgFill(vg)
end

-- 枯竭威胁等级(§任务包D 8.3):0 安全 / 1 视野边缘 / 2 被盯上 / 3 被追击
threatLevel = function(world)
    if world.phase ~= "depleted" then return 0 end
    local lvl = 0
    for _, e in ipairs(world.enemies) do
        if not e.dead and e.jammed <= 0 and e.daze <= 0 and e.stun <= 0 then
            if e.state == "chase" or e.state == "alert" then return 3 end
            if e.state == "suspect" then lvl = math.max(lvl, 2) end
            if lvl < 1 and EnemyAI.nearViewEdge(world, e) then lvl = 1 end
        end
    end
    return lvl
end
Render.threatLevel = threatLevel

local function drawHUD(world, w, h, best)
    local antiHunt = (world.phase == "anti_hunt")
    local intro = (world.phase == "layer_intro")
    local overload = (world.phase == "overload") or antiHunt or intro
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local top = m.hudTop
    local gap = 6 * s
    local safeW = m.safeW
    local sideW = math.max(96 * s, math.min(132 * s, (safeW - 120 * s) * 0.5))
    local centerW = math.max(88 * s, safeW - sideW * 2 - gap * 2)
    local panelH = 76 * s
    local leftX = m.left
    local centerX = leftX + sideW + gap
    local rightX = centerX + centerW + gap
    local p = world.player

    drawHudPanel(leftX, top, sideW, panelH, COLORS.blue)
    drawHudPanel(centerX, top, centerW, panelH, overload and COLORS.cyan or COLORS.purple)
    drawHudPanel(rightX, top, sideW, panelH, world.phase == "depleted" and COLORS.yellow or COLORS.red)

    -- 左上：只保留层数、总分和倍率/连杀。
    SafeDraw.font(12 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(213, 226, 255, 255))
    text(leftX + 8, top + 8, "层数  " .. Format.layer(world.round))
    local scoreText = Format.integer(world.score)
    local scoreFont = (#scoreText >= 11 and 10 or #scoreText >= 9 and 12 or 15) * s
    SafeDraw.font(scoreFont)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
    text(leftX + 8 * s, top + 27 * s, "分数  " .. scoreText)
    SafeDraw.font(11 * s)
    nvgFillColor(vg, C(COLORS.cyan, 230))
    text(leftX + 8 * s, top + 52 * s,
        string.format("%s  连杀 %d", Format.multiplier(world.multiplier), world.comboKills))

    -- 中上固定三层：阶段名称 → 协议/超限摘要 → 核心数值/状态 → 阶段进度条。
    SafeDraw.font(11 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, antiHunt and C(COLORS.yellow) or overload and C(COLORS.cyan) or C(COLORS.purple))
    local phaseName = intro and "系统启动" or antiHunt and "反猎清算" or overload and "算力过载" or "算力耗尽"
    local shortProtocols = {}
    if world:hasProtocol("cluster") then shortProtocols[#shortProtocols + 1] = "集群" end
    if world:hasProtocol("blockade") then shortProtocols[#shortProtocols + 1] = "封锁" end
    if world:hasProtocol("deep_cache") then shortProtocols[#shortProtocols + 1] = "深缓存" end
    local protocolLabel = #shortProtocols > 0 and ("协议 " .. table.concat(shortProtocols, "/")) or nil
    text(centerX + centerW * 0.5, top + 7 * s, phaseName)
    -- 协议与超限数据各占第二行左右两端，不再与阶段标题抢同一基线。
    if protocolLabel then
        SafeDraw.font(7.5 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, C(COLORS.blue, 235))
        text(centerX + 8 * s, top + 20 * s, protocolLabel)
    end
    if world.endless == true and world.round >= 11 and world.endlessOverclock then
        SafeDraw.font(7.5 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
        nvgFillColor(vg, C(COLORS.cyan, 245))
        text(centerX + centerW - 8 * s, top + 20 * s,
            "超限 " .. tostring(world.endlessOverclock.data or 0))
    end
    if intro then
        local left = math.max(0, world.layerIntroTimer or 0)
        SafeDraw.font(17 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
        text(centerX + centerW * 0.5, top + 31 * s, "观察地图")
        drawBar(centerX + 8 * s, top + 60 * s, centerW - 16 * s, 8 * s,
            1 - left / math.max(0.001, Config.FORMAL.layerIntroDuration),
            C(COLORS.cyan), nvgRGBA(22, 42, 70, 255))
    elseif antiHunt then
        -- 反猎窗口：显示本层剩余窗口时间与剩余目标，不显示下一层过载倒计时。
        local left = math.max(0, world.antiHuntTimer or 0)
        SafeDraw.font(25 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, C(COLORS.yellow))
        text(centerX + centerW * 0.5, top + 30 * s, string.format("%.1f", left))
        drawBar(centerX + 8 * s, top + 60 * s, centerW - 16 * s, 8 * s,
            left / math.max(0.001, Config.ANTI_HUNT_PHASE.maximumDuration),
            C(COLORS.yellow), nvgRGBA(58, 46, 16, 255))
    elseif overload then
        local left = math.max(0, world.overloadLeft)
        local warn = left <= Config.OVERLOAD.lastWarnTime
        SafeDraw.font(warn and 28 * s or 25 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, warn and C(COLORS.red) or nvgRGBA(255, 255, 255, 255))
        text(centerX + centerW * 0.5, top + 30 * s, string.format("%.1f", left))
        drawBar(centerX + 8 * s, top + 60 * s, centerW - 16 * s, 8 * s,
            left / math.max(0.001, world.overloadDuration), C(COLORS.cyan), nvgRGBA(22, 42, 70, 255))
    else
        local ready = world.energy >= world.energyNeed
        local progress = world.energy / math.max(1, world.energyNeed)
        local status = string.format("%d / %d", world.energy, world.energyNeed)
        if world.restartChannel then
            progress = world.restartChannel.t / Config.FORMAL.restartChannelTime
            status = string.format("重启 %.0f%%", Util.clamp(progress, 0, 1) * 100)
        elseif ready then
            status = "待启动"
        end
        SafeDraw.font(17 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, ready and C(COLORS.green) or nvgRGBA(255, 255, 255, 255))
        text(centerX + centerW * 0.5, top + 31 * s, status)
        drawBar(centerX + 8 * s, top + 60 * s, centerW - 16 * s, 8 * s,
            progress, ready and C(COLORS.green) or C(COLORS.purple), nvgRGBA(30, 25, 62, 255))
    end

    -- 右上：HP、储能、热度和未结算风险。
    SafeDraw.font(9 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
    text(rightX + 7 * s, top + 7 * s, string.format("HP %d", math.ceil(p.hp)))
    drawBar(rightX + 7 * s, top + 19 * s, sideW - 14 * s, 7 * s, p.hp / p.maxHp,
        C(COLORS.red), nvgRGBA(55, 18, 30, 255))
    local energyRatio = world.energy / math.max(1, world.energyNeed)
    text(rightX + 7 * s, top + 31 * s, string.format("储能 %d/%d  核%d",
        world.energy, world.energyNeed, world.coreCount))
    drawBar(rightX + 7 * s, top + 43 * s, sideW - 14 * s, 7 * s, energyRatio,
        C(COLORS.green), nvgRGBA(14, 45, 31, 255))
    if world.phase == "depleted" then
        local heatLvl = world:heatLevel()
        AssetSprites.draw("icon_heat" .. heatLvl, rightX + 15 * s, top + 62 * s, 17 * s, 0, 240)
        SafeDraw.font(9 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.yellow, 235))
        text(rightX + 26 * s, top + 62 * s,
            string.format("热%d  风险%s", heatLvl, Format.integer(world.riskScore)))
    else
        AssetSprites.draw("icon_hunt", rightX + 15 * s, top + 62 * s, 17 * s, 0, 240)
        SafeDraw.font(9 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.cyan, 235))
        -- 反猎窗口关注剩余目标与残骸数据；过载阶段沿用目标数与最高倍率。
        if antiHunt then
            local chain = world.antiHuntChain or 0
            local rewards = Config.ANTI_HUNT.rewards
            local reward = rewards and rewards[math.min(math.max(1, chain), #rewards)] or 0
            text(rightX + 26 * s, top + 62 * s,
                chain > 0 and string.format("目标%d  清算连击%d  +%d",
                    world.huntTargetsLeft, chain, reward)
                or string.format("目标%d  清算连击0", world.huntTargetsLeft))
        else
            text(rightX + 26 * s, top + 62 * s,
                string.format("目标%d  最高x%.1f", world.huntTargetsLeft, world.maxMultiplier))
        end
    end

    if world.cloakLeft > 0 then
        SafeDraw.font(11 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(180, 220, 255, 235))
        text(w * 0.5, top + panelH + 6 * s, string.format("隐身 %.1fs", world.cloakLeft))
    end
end

-- [R2] 过载优先目标标记(§9.3:世界标记 + 屏幕边缘指示,不用任务弹窗)
local function drawOpportunities(world, w, h)
    if world.phase ~= "overload" or not world.opportunities then return end
    local p = world.player
    local b = cam.battle
    for _, op in ipairs(world.opportunities) do
        if not op.done and op.x then
            local x, y = wx(op.x), wy(op.y)
            -- 世界标记:菱形指示 + 脉冲圈
            local col = (op.kind == "relay") and COLORS.green
                or (op.kind == "firewall") and COLORS.cyan or COLORS.orange
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, ws(40) + ws(6) * math.sin(time * 4))
            nvgStrokeColor(vg, C(col, 160))
            nvgStrokeWidth(vg, 2)
            nvgStroke(vg)
            SafeDraw.font(13, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(col, 235))
            text(x, y - ws(52), "◈ " .. op.label)
            -- 靠近时显示对下一阶段的收益(§9.3)
            if Util.dist(op.x, op.y, p.x, p.y) < 340 then
                SafeDraw.font(11)
                nvgFillColor(vg, nvgRGBA(220, 235, 255, 210))
                text(x, y - ws(52) + 16, op.benefit)
            end
            -- 屏幕外:边缘方向箭头
            if x < b.x or y < b.y or x > b.x + b.w or y > b.y + b.h then
                local dx, dy = op.x - p.x, op.y - p.y
                local a = math.atan(dy, dx)
                local ex = b.x + b.w / 2 + math.cos(a) * (math.min(b.w, b.h) * 0.38)
                local ey = b.y + b.h / 2 + math.sin(a) * (math.min(b.w, b.h) * 0.38)
                nvgSave(vg)
                nvgTranslate(vg, ex, ey)
                nvgRotate(vg, a)
                nvgBeginPath(vg)
                nvgMoveTo(vg, 12, 0); nvgLineTo(vg, -6, -8); nvgLineTo(vg, -6, 8)
                nvgClosePath(vg)
                nvgFillColor(vg, C(col, 200))
                nvgFill(vg)
                nvgRestore(vg)
            end
        end
    end
end

-- [R2] 深层残骸方向指示(枯竭;高收益目标可感知,§7.3)
local function drawDeepMarker(world, w, h)
    if world.phase ~= "depleted" then return end
    local p = world.player
    local b = cam.battle
    for _, wk in ipairs(world.wrecks) do
        if not wk.dead and wk.deep then
            local visibility = SignalBlackout.classify(world, wk, "wreck")
            local markerX, markerY = visibility.x, visibility.y
            local x, y = markerX and wx(markerX) or nil, markerY and wy(markerY) or nil
            if visibility.mode == "live"
                and Util.dist(wk.x, wk.y, p.x, p.y) < Config.DEPLETED.interactRange * 2.2 then
                local coreGain = Config.RISK.deepCores + (world:hasProtocol("deep_cache")
                    and Config.PROTOCOL.deep_cache.deepCoreBonus or 0)
                SafeDraw.font(10, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, C(COLORS.yellow, 245))
                text(x, y - ws(48), string.format(
                    "预计 残骸数据 +%d · 黄色核心 +%d · 缓存 +%d",
                    Config.WRECK_DATA.perDeepWreck, coreGain, Config.RISK.deepCacheBonus))
            end
            local exact = visibility.mode == "live"
            local signal = visibility.mode == "signal" and visibility.signalKind == "value"
            if (exact or signal) and x and y
                and (x < b.x or y < b.y or x > b.x + b.w or y > b.y + b.h) then
                local a = math.atan(markerY - p.y, markerX - p.x)
                local ex = b.x + b.w / 2 + math.cos(a) * (math.min(b.w, b.h) * 0.36)
                local ey = b.y + b.h / 2 + math.sin(a) * (math.min(b.w, b.h) * 0.36)
                nvgSave(vg)
                nvgTranslate(vg, ex, ey)
                nvgRotate(vg, a)
                nvgBeginPath(vg)
                nvgMoveTo(vg, 14, 0); nvgLineTo(vg, -7, -9); nvgLineTo(vg, -7, 9)
                nvgClosePath(vg)
                nvgFillColor(vg, C(COLORS.yellow, exact and 210 or 155))
                nvgFill(vg)
                nvgRestore(vg)
                SafeDraw.font(11, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, C(COLORS.yellow, exact and 220 or 170))
                text(ex, ey + 18, exact and "深层残骸" or "高价值信号")
            end
        end
    end
end

-- 043B：侦察已成为SignalBlackout的真实可见性输入。这里仅强化扫描波与
-- 被侦察揭示的敌人朝向，不再用全图资源箭头建立第二套平行透视逻辑。
local function drawRecon(world, w, h)
    local activeLeft = math.max(0, world.reconLeft or 0)
    local afterglowLeft = math.max(0, world.reconAfterglowLeft or 0)
    if world.phase ~= "depleted" or (activeLeft <= 0 and afterglowLeft <= 0) then return end
    local p = world.player
    local px, py = wx(p.x), wy(p.y)
    local R = SignalBlackout.getReconMaxRadius(world)
    local duration = math.max(0.01, Config.RECON.duration or 4)
    local expandTime = math.max(0.01, Config.RECON.expandTime or 0.65)
    local elapsed = math.max(0, duration - activeLeft)
    local expand = Util.clamp(elapsed / expandTime, 0, 1)
    expand = 1 - (1 - expand) * (1 - expand)
    local ringRadius = R * (0.18 + 0.82 * expand)
    local fade = activeLeft > 0 and math.min(1, elapsed / 0.18 + 0.2)
        or Util.clamp(afterglowLeft / math.max(0.01, Config.RECON.afterglow or 0.5), 0, 1)
    -- 仅对本次扫描新增揭示的敌人显示短期朝向。
    for _, e in ipairs(world.enemies) do
        local visibility = SignalBlackout.classify(world, e, "enemy")
        if not e.dead and visibility.mode == "live" and visibility.reason == "recon_pulse" then
            local x, y = wx(e.x), wy(e.y)
            nvgBeginPath(vg)
            nvgMoveTo(vg, x, y)
            nvgLineTo(vg, x + math.cos(e.angle) * ws(60), y + math.sin(e.angle) * ws(60))
            nvgStrokeColor(vg, nvgRGBA(255, 120, 120, math.floor(150 * fade)))
            nvgStrokeWidth(vg, 2)
            nvgStroke(vg)
        end
    end
    -- 单一圆形虚线侦察圈；每段弧使用独立 path，禁止 NanoVG 在段间
    -- 自动补直线。结束后以完整真圆外圈淡出0.5秒。
    local rr = ws(activeLeft > 0 and ringRadius or R)
    nvgStrokeColor(vg, C(COLORS.blue,
        math.floor((activeLeft > 0 and 155 or 110) * fade)))
    nvgStrokeWidth(vg, reducedFlashing() and 1.5 or 2)
    if activeLeft > 0 then
        local segments = 18
        for i = 0, segments - 1 do
            local a0 = i * math.pi * 2 / segments
            nvgBeginPath(vg)
            nvgArc(vg, px, py, rr, a0,
                a0 + math.pi * 1.25 / segments, NVG_CW)
            nvgStroke(vg)
        end
    else
        nvgBeginPath(vg)
        nvgCircle(vg, px, py, rr)
        nvgStroke(vg)
    end
end

local function drawButtons(world, w, h)
    for _, b in ipairs(InputSys.layout(world, w, h)) do
        local alpha = b.enabled and 220 or 90
        local held = InputSys.held[b.id] and b.enabled
        if b.w and b.h then
            local x, y = b.x - b.w * 0.5, b.y - b.h * 0.5
            local primary = b.id == "again" or b.id == "retryLayer" or b.id == "revive"
                or b.id == "reviveInPlace" or b.id == "reviveFullState"
                or b.id == "confirmReviveInPlace" or b.id == "confirmReviveFullState"
                or b.id == "adFailureClose" or b.id == "adTimeoutClose"
                or b.id == "adSoftContinue"
            drawHudPanel(x, y, b.w, b.h, primary and COLORS.cyan or COLORS.blue)
            if primary then
                nvgBeginPath(vg)
                nvgRoundedRect(vg, x + 3, y + 3, b.w - 6, b.h - 8, 8)
                nvgFillColor(vg, nvgRGBA(31, 120, 190, 155))
                nvgFill(vg)
            end
            if b.sub then
                SafeDraw.font(primary and 15 or 13, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
                text(b.x, b.y - 8, b.label)
                SafeDraw.font(10, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(200, 220, 255, 230))
                text(b.x, b.y + 13, b.sub)
            else
                SafeDraw.font(primary and 17 or 14, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
                text(b.x, b.y, b.label)
            end
        else
            local r = held and b.r * 1.08 or b.r
            local function octagon(ox, oy, rr)
                nvgBeginPath(vg)
                for i = 0, 7 do
                    local a = math.pi / 8 + i * math.pi / 4
                    local px, py = ox + math.cos(a) * rr, oy + math.sin(a) * rr
                    if i == 0 then nvgMoveTo(vg, px, py) else nvgLineTo(vg, px, py) end
                end
                nvgClosePath(vg)
            end
            octagon(b.x + 4, b.y + 4, r)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(alpha * 0.45)))
            nvgFill(vg)
            octagon(b.x, b.y, r)
            local fill = held and { 45, 102, 200 } or { 20, 42, 86 }
            if not b.enabled then fill = { 57, 71, 107 } end
            nvgFillColor(vg, nvgRGBA(fill[1], fill[2], fill[3], alpha))
            nvgFill(vg)
            nvgStrokeColor(vg, b.enabled and C(COLORS.cyan, alpha) or nvgRGBA(120, 130, 150, alpha))
            nvgStrokeWidth(vg, held and 3 or 2)
            nvgLineJoin(vg, NVG_ROUND)
            nvgStroke(vg)
            -- 底部强调线，形成锐角战斗 HUD 层级。
            nvgBeginPath(vg)
            nvgMoveTo(vg, b.x - r * 0.55, b.y + r * 0.72)
            nvgLineTo(vg, b.x + r * 0.55, b.y + r * 0.72)
            nvgStrokeColor(vg, b.enabled and C(COLORS.blue, alpha) or nvgRGBA(80, 90, 110, alpha))
            nvgStrokeWidth(vg, 3)
            nvgLineCap(vg, NVG_ROUND)
            nvgStroke(vg)
            -- 按钮图标有独立留白区，文字与副信息同步放大。
            local iconName = AssetSprites.BUTTON_ICONS[b.id]
            local hasIcon = iconName and AssetSprites.get(iconName) ~= nil
            if hasIcon then
                AssetSprites.draw(iconName, b.x, b.y - b.r * 0.32, b.r * 0.7, 0,
                    b.enabled and 255 or 110)
                SafeDraw.font(b.r * 0.32, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, b.enabled and 255 or 120))
                text(b.x, b.y + b.r * 0.24, b.label)
            else
                SafeDraw.font(b.r * 0.42, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, b.enabled and 255 or 120))
                text(b.x, b.y - (b.sub and b.r * 0.16 or 0), b.label)
            end
            if b.sub then
                SafeDraw.font(b.r * (hasIcon and 0.26 or 0.3))
                nvgFillColor(vg, nvgRGBA(200, 220, 255, b.enabled and 220 or 120))
                text(b.x, b.y + b.r * (hasIcon and 0.58 or 0.34), b.sub)
            end
        end
    end
    -- 摇杆
    local s = InputSys.stick
    if s.active then
        nvgBeginPath(vg)
        nvgCircle(vg, s.cx, s.cy, InputSys.STICK_RADIUS)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 70))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
        nvgBeginPath(vg)
        nvgCircle(vg, s.cx + s.dx, s.cy + s.dy, 26)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 90))
        nvgFill(vg)
    end
end

-- ============================================================
-- 层结算 + 协议整备（正式流程；Review 入口不会进入该阶段）
-- 层结算不播放长动画、不阻塞街机节奏：一屏直接给出本层增量与两组升级。
-- ============================================================
local function drawLayerSettlement(world, w, h)
    return RunShopRender.draw(vg, world, w, h)
end

local function drawOverlays(world, w, h, best)
    local m = Viewport.metrics(w, h)
    -- 阶段切换全屏闪光/暗化 + 冲击停顿 + toast
    -- [R2] 减少闪烁:全屏闪光类特效强度减半
    local fxMul = settings.reduceFx and 0.35 or 1
    local central = nil
    local edgeToast = nil
    local function classifyBanner(raw)
        local s = tostring(raw or "")
        if string.find(s, "新纪录", 1, true) then return "新纪录", 120 end
        if string.find(s, "离线", 1, true) or string.find(s, "断电", 1, true) then return "算力离线", 110 end
        if string.find(s, "重启条件", 1, true) then return "储能完成", 100 end
        if string.find(s, "反猎启动", 1, true) then return "反猎开始", 95 end
        if string.find(s, "反猎连算", 1, true) then return s, 96 end
        if string.find(s, "已结算", 1, true) then return "风险分结算", 90 end
        if string.find(s, "标记引爆", 1, true) then return "标记引爆", 80 end
        if string.find(s, "深层", 1, true) then return nil, 0, "发现深层残骸" end
        if string.find(s, "捷径", 1, true) then return nil, 0, "捷径已打开" end
        if string.find(s, "激光", 1, true) then return nil, 0, "激光已关闭" end
        if string.find(s, "模块", 1, true) or string.find(s, "缓存", 1, true) then return nil, 0, "强化已生效" end
        if string.find(s, "本轮", 1, true) then return nil, 0, "过载成果已记录" end
        if string.find(s, "协议", 1, true) then return nil, 0, s end
        if string.find(s, "里程碑", 1, true) then return "第10层里程碑", 115 end
        return nil, 0, nil
    end
    local queued = world.systemPrompts and world.systemPrompts[1]
    if queued then
        local label, priority, edge = classifyBanner(queued.text)
        if label then
            central = { text = label, priority = priority,
                age = queued.age or 0, dur = queued.dur or 1 }
        elseif edge then
            edgeToast = { text = edge, age = queued.age or 0, dur = queued.dur or 1 }
        end
    end
    for _, f in ipairs(world.fx) do
        if f.kind == "phaseflash" then
            local t01 = f.age / (f.dur or 0.5)
            -- 039B：阶段闪光承载“身份切换”语义，减闪模式只降到 60% 而非 35%，
            -- 保证过载→枯竭断电、重启→反猎翻盘在减闪下仍一眼可辨；纯装饰闪光仍减半。
            local flashMul = settings.reduceFx and 0.6 or 1
            local a = math.floor(160 * (1 - t01) * flashMul)
            nvgBeginPath(vg)
            nvgRect(vg, 0, 0, w, h)
            if f.color == "overload" then
                nvgFillColor(vg, nvgRGBA(120, 250, 255, a))
            else
                nvgFillColor(vg, nvgRGBA(0, 0, 0, a + 40))
            end
            nvgFill(vg)
        elseif f.kind == "hitstop" then
            -- 0.15s 视觉冲击停顿:白闪→瞬间压暗(仅视觉,逻辑照常)
            local t01 = f.age / (f.dur or 0.15)
            nvgBeginPath(vg)
            nvgRect(vg, 0, 0, w, h)
            if t01 < 0.4 then
                nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(200 * (1 - t01 / 0.4) * fxMul)))
            else
                nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(140 * (1 - t01))))
            end
            nvgFill(vg)
        elseif f.kind == "toast" then
            if not edgeToast or f.age < edgeToast.age then
                edgeToast = { text = tostring(f.text), age = f.age, dur = f.dur or 1 }
            end
        end
    end

    -- 中央同时只显示一条高优先级短提示。
    if central then
        local t01 = central.age / central.dur
        local a = math.floor(255 * math.min(1, (1 - t01) * 4))
        local pw, ph = math.min(230, w * 0.62), 44
        local px, py = (w - pw) * 0.5, m.battle.y + 18 * m.ui
        drawHudPanel(px, py, pw, ph, COLORS.yellow)
        SafeDraw.font(21, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.yellow, a))
        text(w * 0.5, py + ph * 0.5, central.text)
    end

    if world.phase == "layer_intro" then
        local cue = world.layerIntroCue or tostring(math.max(1,
            math.ceil(world.layerIntroTimer or Config.FORMAL.layerIntroDuration)))
        local panelW, panelH = math.min(220, w * 0.58), 88
        local px, py = (w - panelW) * 0.5, h * 0.40
        drawHudPanel(px, py, panelW, panelH, COLORS.cyan)
        SafeDraw.font(13, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(205, 226, 255, 235))
        text(w * 0.5, py + 20, string.format("第 %d 层 · %s", world.round,
            world.mapDef and world.mapDef.name or ""))
        if world.layerPlan and world.layerPlan.fairGate then
            SafeDraw.font(10.5, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(116, 235, 255, 230))
            text(w * 0.5, py + 39, world.layerPlan.fairGate.routeHint)
        end
        SafeDraw.font(38, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.cyan, 255))
        text(w * 0.5, py + (world.layerPlan and world.layerPlan.fairGate and 67 or 57), cue)
    elseif world.layerIntroCueLeft and world.layerIntroCueLeft > 0 then
        SafeDraw.font(36, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.cyan, math.floor(255 * math.min(1,
            world.layerIntroCueLeft / 0.2))))
        text(w * 0.5, h * 0.46, "开始")
    end

    if world.areaAnnouncement and world.areaAnnouncement.left > 0
        and world.phase ~= "layer_intro" then
        local a = math.floor(255 * math.min(1, world.areaAnnouncement.left / 0.35))
        SafeDraw.font(28, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.cyan, a))
        text(w * 0.5, h * 0.43, world.areaAnnouncement.text)
        SafeDraw.font(13)
        nvgFillColor(vg, nvgRGBA(210, 230, 255, a))
        text(w * 0.5, h * 0.43 + 34, world.areaAnnouncement.sub or "")
    end

    NeonPolish.drawCountdown(vg, world, w, h, settings)
    NeonPolish.drawThreatVignette(vg, world, w, h, threatLevel(world), settings)

    -- 顶部边缘只显示一条低优先级 Toast 或教学提示。
    local hint = Tutorial.current
    local edge = hint and { text = hint.text, alpha = math.floor(240 * math.min(1, hint.left / 0.5)) }
        or (edgeToast and { text = edgeToast.text,
            alpha = math.floor(230 * math.min(1, (1 - edgeToast.age / edgeToast.dur) * 4)) })
    if edge then
        local y = m.battle.y + 70 * m.ui
        local pw = math.min(w * 0.9, 330)
        drawHudPanel((w - pw) * 0.5, y, pw, 30, COLORS.cyan)
        SafeDraw.font(12, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(220, 240, 255, edge.alpha))
        text(w / 2, y + 14, edge.text)
    end

    -- 死亡结算：只展示正式局内成绩与本地最佳记录。
    if world.phase == "dead" then
        nvgBeginPath(vg)
        nvgRect(vg, 0, 0, w, h)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 180))
        nvgFill(vg)
        local panelW = math.min(460, w - m.left - m.right - 20)
        local deathLayout = InputSys.deathLayoutMetrics(w, h)
        local panelH = deathLayout.panelH
        local px, py = (w - panelW) * 0.5, deathLayout.panelY
        NeonPolish.drawDeathPanel(vg, px, py, panelW, panelH, time, settings)
        local cx2 = w * 0.5
        local newRecord = best.bestRun and best.bestRun.layer == world.round
            and best.bestRun.score == world.score
        local completed = world.challengeCompleted == true
        SafeDraw.font(30, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, completed and C(COLORS.green) or C(COLORS.red))
        text(cx2, py + 22, completed and "完成挑战" or "连接中断")
        if newRecord then
            SafeDraw.font(15)
            nvgFillColor(vg, C(COLORS.yellow))
            text(cx2, py + 60, "◆ 新纪录 ◆")
        end
        SafeDraw.font(21)
        nvgFillColor(vg, C(COLORS.cyan, 250))
        text(cx2, py + 94, string.format("第 %d 层     %s 分", world.round, Format.integer(world.score)))

        local lx, rx = px + 22, px + panelW * 0.53
        local y0 = py + 148
        local dy = math.min(31, math.max(27, (panelH - 198) / 5))
        SafeDraw.font(14, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(213, 226, 255, 245))
        text(lx, y0, string.format("最高倍率   x%.1f", world.maxMultiplier))
        text(lx, y0 + dy, string.format("最高连杀   %d", world.bestCombo))
        text(lx, y0 + dy * 2, string.format("反猎击杀   %d", world.huntKills))
        text(lx, y0 + dy * 3, string.format("完成重启   %d", world.restarts))
        text(rx, y0, string.format("冒险成功   %d", world.riskSuccesses))
        text(rx, y0 + dy, "丢失风险   " .. Format.integer(world.lostRiskScore or 0))
        text(rx, y0 + dy * 2, string.format("历史层数   %d", best.round or 0))
        text(rx, y0 + dy * 3, "历史高分   " .. Format.integer(best.score or 0))
        SafeDraw.font(13, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(157, 166, 198, 240))
        text(cx2, py + panelH - 54, string.format("生存 %d:%02d   通关 %d 次",
            math.floor(world.timeAlive / 60), math.floor(world.timeAlive % 60),
            best.challengeClears or 0))
        if world.rewardedReviveState ~= "pending"
            and type(world.rewardedReviveFailureNotice) ~= "table"
            and world.rewardedReviveTimeout ~= true
            and (world.reviveChoiceState == "select"
            or world.reviveChoiceState == "confirm_in_place"
            or world.reviveChoiceState == "confirm_full_state") then
            -- Product-facing copy deliberately avoids implementation terms:
            -- players choose what the ad will restore before playback starts.
            local mw = math.min(350, w - 28)
            local mh = world.reviveChoiceState == "select" and 238 or 188
            local mx, my = (w - mw) * 0.5, py + 74
            drawHudPanel(mx, my, mw, mh, COLORS.cyan)
            SafeDraw.font(20, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            nvgFillColor(vg, C(COLORS.cyan, 255))
            local title = world.reviveChoiceState == "select" and "选择复活方式"
                or (world.reviveChoiceState == "confirm_in_place"
                    and "确认安全复活" or "确认回到本层开始")
            text(cx2, my + 18, title)
            SafeDraw.font(12, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(205, 220, 248, 240))
            if world.reviveChoiceState == "select" then
                local limit = math.max(0, math.floor(tonumber(
                    Config.PLATFORM.rewardedRevive.endlessPerRunLimit) or 3))
                local used = math.max(0,
                    math.floor(tonumber(world.rewardedReviveCount) or 0))
                local countLine = world.endless == true
                    and string.format("本局剩余 %d/%d 次 · 取消不消耗次数",
                        math.max(0, limit - used), limit)
                    or "普通模式不限次数 · 取消不播放广告"
                text(cx2, my + 55, countLine)
                text(cx2, my + 78, "安全复活：满血传送安全区，保留当前状态")
                if world.endless ~= true then
                    text(cx2, my + 101, "回到本层开始：初始潜行，重置本层进度")
                end
            elseif world.reviveChoiceState == "confirm_in_place" then
                text(cx2, my + 58, "观看广告后满血传送到安全区")
                text(cx2, my + 80, "保留算力/热度/分数/敌人，道具不补充")
            else
                text(cx2, my + 58, "观看广告后回到本层初始潜行状态")
                text(cx2, my + 80, "本层当前进度不保留；仅普通闯关可用")
            end
        end

        -- 广告层是独占交互：结果尚未回来时不可触碰死页/复活/重试按钮；
        -- 失败后同样先展示原因与“确认返回”，避免玩家误以为已获得奖励。
        local failureNotice = world.rewardedReviveFailureNotice
        if type(failureNotice) ~= "table" and world.rewardedReviveTimeout == true then
            failureNotice = RewardedRevive.failurePresentation("ad_timeout")
        end
        if world.rewardedReviveState == "pending" or type(failureNotice) == "table" then
            nvgBeginPath(vg)
            nvgRect(vg, 0, 0, w, h)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, 210))
            nvgFill(vg)
            local modalW = math.min(356, w - 28)
            local isPending = world.rewardedReviveState == "pending"
            local isSoftTimeout = isPending and world.rewardedReviveSoftTimeout == true
            local modalH = isPending and (isSoftTimeout and 244 or 202) or 262
            local modalX = (w - modalW) * 0.5
            local modalY = math.max(m.top + 50, h * 0.28)
            drawHudPanel(modalX, modalY, modalW, modalH,
                isPending and COLORS.yellow or COLORS.red)
            SafeDraw.font(22, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            nvgFillColor(vg, isPending and C(COLORS.yellow, 255) or C(COLORS.red, 255))
            text(cx2, modalY + 24, isPending and (isSoftTimeout and "广告响应较慢" or "广告处理中")
                or failureNotice.title)
            if isPending then
                local spinnerY = modalY + 94
                nvgBeginPath(vg)
                nvgCircle(vg, cx2, spinnerY, 22)
                nvgStrokeColor(vg, C(COLORS.yellow, 210))
                nvgStrokeWidth(vg, 3)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgArc(vg, cx2, spinnerY, 22, time * 4,
                    time * 4 + math.pi * 1.25, NVG_CW)
                nvgStrokeColor(vg, C(COLORS.cyan, 255))
                nvgStrokeWidth(vg, 4)
                nvgStroke(vg)
                SafeDraw.font(13, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                nvgFillColor(vg, nvgRGBA(215, 230, 255, 245))
                if isSoftTimeout then
                    text(cx2, modalY + 132, "暂未收到广告结果，你可以继续等待。")
                    text(cx2, modalY + 156, "若确认返回，本次不会获得复活。")
                    text(cx2, modalY + 180, "确认返回不会消耗本局次数。")
                else
                    text(cx2, modalY + 140, "请等待广告播放结束或返回结果")
                    text(cx2, modalY + 164, "请勿重复点击或切换复活方式")
                end
            else
                SafeDraw.font(13, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                nvgFillColor(vg, nvgRGBA(222, 234, 255, 245))
                if failureNotice.kind == "manual_close" then
                    text(cx2, modalY + 78, "广告未完整播放到可领取状态，无法复活。")
                    text(cx2, modalY + 105, "若广告内出现“继续播放”，请先继续；")
                    text(cx2, modalY + 132, "请以广告自身明确结束为准，再返回游戏。")
                elseif failureNotice.kind == "timeout" then
                    text(cx2, modalY + 84, "广告未返回结果，本次未获得复活。")
                    text(cx2, modalY + 112, "请确认返回后重新选择。")
                else
                    text(cx2, modalY + 96, "本次未获得复活，请稍后重试。")
                end
                SafeDraw.font(12, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                nvgFillColor(vg, C(COLORS.yellow, 240))
                text(cx2, modalY + modalH - 48, "不会消耗复活次数")
            end
        end
    end
end

-- ============================================================
-- 正式首发标题页：单一闯关入口与设置。
-- ============================================================
-- 023C 首次教程 overlay：明暗两阶段图形化教学（每页一个核心阶段）。
-- 390x867 下保持大字与图形可读；按钮足够大；文本短直白、便于后续翻译。
-- 024C: 暂停遮罩(游戏世界冻结,只绘制暂停菜单与提示)
function Render.drawPauseOverlay(w, h, best, world)
    if vg == nil then return end
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(4, 8, 18, 210))
    nvgFill(vg)
    local endingEndless = Screens.endlessEndConfirmOpen == true
    local endless = world and world.endless == true
    SafeDraw.font(30 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(225, 240, 255, 255))
    text(cx, h * 0.24, endingEndless and "结束本次无尽？" or "已暂停")
    SafeDraw.font(12 * s)
    nvgFillColor(vg, nvgRGBA(160, 185, 220, 230))
    text(cx, h * 0.30, endingEndless
        and "当前无尽进度将被删除，之后无法从本层继续"
        or "游戏已冻结 · 敌人与计时不会推进")
    local layout = Screens.pauseMenuLayout(w, h, endless, endingEndless)
    for _, b in ipairs(layout) do
        local x, y = b.x - b.w * 0.5, b.y - b.h * 0.5
        local bAccent = (b.id == "pauseResume" or b.id == "pauseReturnEndless")
            and COLORS.cyan
            or (b.id == "pauseQuit" or b.id == "pauseEndEndless"
                or b.id == "pauseEndlessConfirmEnd") and COLORS.red or COLORS.blue
        drawHudPanel(x, y, b.w, b.h, bAccent)
        SafeDraw.font(b.sub and 14 * s or 15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        text(b.x, b.y - (b.sub and 8 * s or 0), b.label)
        if b.sub then
            SafeDraw.font(10 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(190, 215, 245, 220))
            text(b.x, b.y + 13 * s, b.sub)
        end
    end
    -- 暂停中打开设置：绘制设置面板与按钮(与标题页同布局,可点)
    if Screens.settingsOpen then
        local g = Screens.settingsGeometry(w, h)
        drawHudPanel(g.x, g.y, g.w, g.h, COLORS.purple)
        SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 245))
        text(cx, g.y + g.titleH * 0.48, "设置")
        local function drawSettingsButtons()
            local privacyAccepted = best and SaveSys.hasPrivacyConsent(best) or false
            local onlineAvailable = PlatformFeatures.leaderboardStatus()
            local buttons = Screens.layout(w, h, best and best.settings or {},
                privacyAccepted, onlineAvailable, true)
            for _, b in ipairs(buttons) do
                local bx, by = b.x - b.w * 0.5, b.y - b.h * 0.5
                local bAccent = b.id == "closeSettings" and COLORS.purple or COLORS.blue
                drawHudPanel(bx, by, b.w, b.h, bAccent)
                SafeDraw.font(b.sub and 12 * s or 13 * s,
                    NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
                text(b.x, b.y - (b.sub and 6 * s or 0), b.label)
                if b.sub then
                    SafeDraw.font(10 * s)
                    nvgFillColor(vg, nvgRGBA(190, 215, 245, 220))
                    text(b.x, b.y + 11 * s, b.sub)
                end
            end
        end
        local function group(box, label, accent)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, box.x, box.y, box.w, box.h, 7 * s)
            nvgFillColor(vg, nvgRGBA(12, 27, 56, 230))
            nvgFill(vg)
            nvgStrokeColor(vg, C(accent, 145))
            nvgStrokeWidth(vg, 1.5)
            nvgStroke(vg)
            SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
            nvgFillColor(vg, C(accent, 235))
            text(box.x + 10 * s, box.y + 8 * s, label)
        end
        group(g.music, "音乐", COLORS.cyan)
        group(g.sfx, "音效", COLORS.blue)
        group(g.assist, "显示与震动", COLORS.blue)
        SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(210, 228, 255, 235))
        text(g.music.x + 10 * s, g.musicToggleY, "总开关")
        SafeDraw.font(13 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(245, 250, 255, 250))
        text(cx, g.musicVolumeY,
            string.format("%d%%", math.floor((best.settings.musicVolume or 0.55) * 100 + 0.5)))
        text(cx, g.sfxVolumeY,
            string.format("%d%%", math.floor((best.settings.sfxVolume or 0.8) * 100 + 0.5)))
        -- 分组底板与说明先画，最后再画实际控件。此前反过来导致震动、
        -- 减闪、减震等按钮被不透明面板完全盖住（反馈 #18703）。
        drawSettingsButtons()
    end
end

-- 教程迷你战场示意窗：用游戏内真实精灵绘制各阶段场景（猎人→猎物→抉择→反猎）。
-- 每个元素下方都有文字标签，元素四列分散布局；精灵缺失自动几何回退。
-- 窗内坐标全部按逻辑尺寸缩放，390×867 不裁切、不压按钮。
local function drawTutorialScene(page, accentColor, cx, m, s)
    local scene = page and page.scene or "hunt"
    -- 大视窗：占满安全宽度，高度 ~170s，顶部在正文之下
    local gridW = math.min(m.safeW - 16, 340 * s)
    local gridH = 170 * s
    local gx0 = cx - gridW * 0.5
    local topY = m.h * 0.205
    local gy0 = topY + 10 * s
    -- 窗底(带圆角边框)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, gx0 - 6 * s, topY - 6 * s, gridW + 12 * s, gridH + 12 * s, 10 * s)
    nvgFillColor(vg, nvgRGBA(8, 12, 26, 160))
    nvgFill(vg)
    nvgStrokeColor(vg, C(accentColor, 90))
    nvgStrokeWidth(vg, 2 * s)
    nvgStroke(vg)
    -- 地面网格
    nvgBeginPath(vg)
    nvgRect(vg, gx0, gy0, gridW, gridH)
    nvgFillColor(vg, nvgRGBA(12, 18, 34, 150))
    nvgFill(vg)
    local cell = 24 * s
    nvgStrokeColor(vg, nvgRGBA(90, 120, 180, 55))
    nvgStrokeWidth(vg, 1)
    local c = 0
    while c * cell < gridW do
        nvgBeginPath(vg); nvgMoveTo(vg, gx0 + c * cell, gy0)
        nvgLineTo(vg, gx0 + c * cell, gy0 + gridH); nvgStroke(vg)
        c = c + 1
    end
    local r = 0
    while r * cell < gridH do
        nvgBeginPath(vg); nvgMoveTo(vg, gx0, gy0 + r * cell)
        nvgLineTo(vg, gx0 + gridW, gy0 + r * cell); nvgStroke(vg)
        r = r + 1
    end

    local cy = gy0 + gridH * 0.46
    local function sprite(name, x, y, size, rot)
        if not AssetSprites.draw(name, x, y, size, rot or 0, 255) then
            nvgBeginPath(vg)
            nvgCircle(vg, x, y, size * 0.28)
            nvgFillColor(vg, C(accentColor, 230))
            nvgFill(vg)
        end
    end
    -- 元素下方标签
    local function tag(x, y, label, color)
        SafeDraw.font(10.5 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, color or nvgRGBA(225, 238, 255, 240))
        text(x, y, label)
    end
    -- 元素列横坐标（四列分散）
    local cols = { -gridW * 0.31, -gridW * 0.10, gridW * 0.10, gridW * 0.31 }
    local itemY = cy - 6 * s
    local labelY = cy + 42 * s
    -- 追踪/视线箭头
    local function arrow(x0, y0, x1, y1, color)
        local dx, dy = x1 - x0, y1 - y0
        local len = math.max(1, math.sqrt(dx * dx + dy * dy))
        local ux, uy = dx / len, dy / len
        nvgBeginPath(vg)
        nvgMoveTo(vg, x0 + ux * 16 * s, y0 + uy * 16 * s)
        nvgLineTo(vg, x1 - ux * 12 * s, y1 - uy * 12 * s)
        nvgStrokeColor(vg, C(color, 220))
        nvgStrokeWidth(vg, 3 * s)
        nvgStroke(vg)
        nvgBeginPath(vg)
        local hx, hy = x1 - ux * 12 * s, y1 - uy * 12 * s
        nvgMoveTo(vg, hx, hy)
        nvgLineTo(vg, hx - ux * 9 * s + uy * 6 * s, hy - uy * 9 * s - ux * 6 * s)
        nvgLineTo(vg, hx - ux * 9 * s - uy * 6 * s, hy - uy * 9 * s + ux * 6 * s)
        nvgClosePath(vg)
        nvgFillColor(vg, C(color, 220))
        nvgFill(vg)
    end
    -- 敌方视野锥
    local function visionCone(x, y, angleDeg, radius, color)
        local half = math.rad(30)
        local a = math.rad(angleDeg)
        nvgBeginPath(vg)
        nvgMoveTo(vg, x, y)
        nvgLineTo(vg, x + math.cos(a - half) * radius, y + math.sin(a - half) * radius)
        nvgLineTo(vg, x + math.cos(a + half) * radius, y + math.sin(a + half) * radius)
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], 42))
        nvgFill(vg)
    end
    -- 元素顶部小标题(场景名,窗内左上)
    SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, C(accentColor, 220))
    local sceneNames = {
        hunt = "过载 · 主动追击",
        depleted = "枯竭 · 潜行脱身",
        choose = "满能 · 二选一",
        antihunt = "反猎 · 清算追兵",
    }
    text(gx0 + 10 * s, topY + 20 * s, sceneNames[scene] or "")

    if scene == "hunt" then
        -- 猎人：玩家追敌，4 列：你 / 无人机 / 安保机械 / 残骸
        sprite("player_overload", cx + cols[1], itemY, 46 * s)
        tag(cx + cols[1], labelY, "你 · 猎人", C(accentColor, 250))
        arrow(cx + cols[1] + 20 * s, itemY - 6 * s, cx + cols[2] - 14 * s, itemY - 6 * s, accentColor)
        sprite("enemy_drone", cx + cols[2], itemY, 40 * s)
        tag(cx + cols[2], labelY, "巡逻无人机")
        sprite("enemy_sentinel", cx + cols[3], itemY, 44 * s)
        tag(cx + cols[3], labelY, "安保机械")
        sprite("obj_wreck", cx + cols[4], itemY, 34 * s)
        tag(cx + cols[4], labelY, "残骸 · 高分目标", nvgRGBA(255, 200, 90, 250))
    elseif scene == "depleted" then
        -- 猎物：被追，4 列：你 / 追兵 / 储能 / 残骸
        sprite("player_depleted", cx + cols[1], itemY, 46 * s)
        tag(cx + cols[1], labelY, "你 · 猎物", C(accentColor, 250))
        visionCone(cx + cols[2], itemY, 180, 44 * s, { 255, 90, 70 })
        sprite("enemy_drone", cx + cols[2], itemY, 42 * s)
        tag(cx + cols[2], labelY, "追兵")
        sprite("obj_cell", cx + cols[3], itemY, 30 * s)
        tag(cx + cols[3], labelY, "储能 · 收集", nvgRGBA(120, 255, 150, 250))
        sprite("obj_wreck", cx + cols[4], itemY, 32 * s)
        tag(cx + cols[4], labelY, "残骸 · 拆解", nvgRGBA(255, 200, 90, 250))
    elseif scene == "choose" then
        -- 满能抉择：立即重启 / 继续诱敌 / 热度 / 未结算
        sprite("player_depleted", cx + cols[1], itemY, 44 * s)
        nvgBeginPath(vg)
        nvgCircle(vg, cx + cols[1], itemY, 32 * s)
        nvgStrokeColor(vg, C({ 120, 255, 140 }, 220))
        nvgStrokeWidth(vg, 3 * s)
        nvgStroke(vg)
        tag(cx + cols[1], labelY, "立即重启", nvgRGBA(150, 255, 170, 250))
        arrow(cx + cols[1] + 24 * s, itemY, cx + cols[2] - 16 * s, itemY, { 120, 255, 140 })
        sprite("enemy_heavy", cx + cols[2], itemY, 50 * s)
        tag(cx + cols[2], labelY, "继续诱敌")
        sprite("icon_heat1", cx + cols[3], itemY, 30 * s)
        tag(cx + cols[3], labelY, "追踪热度 ↑", nvgRGBA(255, 170, 90, 250))
        sprite("icon_unbanked", cx + cols[4], itemY, 30 * s)
        tag(cx + cols[4], labelY, "未结算风险", nvgRGBA(255, 140, 130, 250))
    else
        -- 反猎：按住重启，追兵变高分目标
        sprite("player_overload", cx + cols[1], itemY, 46 * s)
        nvgBeginPath(vg)
        nvgCircle(vg, cx + cols[1], itemY, 36 * s)
        nvgStrokeColor(vg, C(accentColor, 230))
        nvgStrokeWidth(vg, 3 * s)
        nvgStroke(vg)
        nvgBeginPath(vg)
        nvgCircle(vg, cx + cols[1], itemY, 44 * s)
        nvgStrokeColor(vg, C(accentColor, 120))
        nvgStrokeWidth(vg, 2 * s)
        nvgStroke(vg)
        tag(cx + cols[1], labelY, "按住重启 0.7 秒", C(accentColor, 250))
        arrow(cx + cols[1] + 24 * s, itemY, cx + cols[2] - 14 * s, itemY, accentColor)
        sprite("enemy_heavy", cx + cols[2], itemY, 50 * s)
        nvgBeginPath(vg)
        nvgCircle(vg, cx + cols[2], itemY, 32 * s)
        nvgStrokeColor(vg, C(COLORS.yellow, 230))
        nvgStrokeWidth(vg, 3 * s)
        nvgStroke(vg)
        tag(cx + cols[2], labelY, "追兵变目标", nvgRGBA(255, 200, 80, 250))
        sprite("icon_hunt", cx + cols[3], itemY, 30 * s)
        tag(cx + cols[3], labelY, "反猎 +分", nvgRGBA(255, 200, 80, 250))
        sprite("icon_chain", cx + cols[4], itemY, 30 * s)
        tag(cx + cols[4], labelY, "清算连击")
    end
end

function Render.drawTutorialOverlay(w, h)
    if vg == nil then return end
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    local page = Tutorial.pages[Tutorial.page]
    local accent = (page and page.accent == "depleted") and "depleted" or "overload"
    local accentColor = accent == "depleted" and { 120, 140, 255 } or { 80, 240, 255 }
    -- 背景：明(过载) / 暗(枯竭) 两阶段氛围
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    if accent == "depleted" then
        local bg = nvgLinearGradient(vg, 0, 0, 0, h,
            nvgRGBA(6, 8, 20, 255), nvgRGBA(14, 16, 30, 255))
        nvgFillPaint(vg, bg)
    else
        local bg = nvgLinearGradient(vg, 0, 0, 0, h,
            nvgRGBA(16, 34, 78, 255), nvgRGBA(24, 42, 92, 255))
        nvgFillPaint(vg, bg)
    end
    nvgFill(vg)

    -- 中央图形：优先使用游戏内真实单位图例（025）；无精灵时几何回退。
    local icons = page and page.icons or nil
    local function drawLegend()
        if not icons or #icons == 0 then
            -- 几何回退：过载 = 追击箭头 + 能量环；枯竭 = 潜行眼 + 储能
            local gy = h * 0.34
            if accent == "overload" then
                nvgBeginPath(vg)
                nvgMoveTo(vg, cx - 46 * s, gy - 40 * s)
                nvgLineTo(vg, cx + 46 * s, gy - 40 * s)
                nvgLineTo(vg, cx + 46 * s, gy - 56 * s)
                nvgLineTo(vg, cx + 78 * s, gy - 24 * s)
                nvgLineTo(vg, cx + 46 * s, gy + 8 * s)
                nvgLineTo(vg, cx + 46 * s, gy - 8 * s)
                nvgLineTo(vg, cx - 46 * s, gy - 8 * s)
                nvgClosePath(vg)
                nvgFillColor(vg, C(accentColor, 230))
                nvgFill(vg)
                nvgBeginPath(vg)
                nvgCircle(vg, cx, gy + 52 * s, 26 * s)
                nvgStrokeColor(vg, C(accentColor, 200))
                nvgStrokeWidth(vg, 4 * s)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgCircle(vg, cx, gy + 52 * s, 8 * s)
                nvgFillColor(vg, C({ 120, 255, 140 }, 235))
                nvgFill(vg)
            else
                nvgBeginPath(vg)
                nvgEllipse(vg, cx - 40 * s, gy - 30 * s, 34 * s, 20 * s)
                nvgStrokeColor(vg, C(accentColor, 220))
                nvgStrokeWidth(vg, 4 * s)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgCircle(vg, cx - 40 * s, gy - 30 * s, 6 * s)
                nvgFillColor(vg, C(accentColor, 235))
                nvgFill(vg)
                nvgBeginPath(vg)
                nvgRoundedRect(vg, cx + 8 * s, gy - 44 * s, 44 * s, 70 * s, 6 * s)
                nvgStrokeColor(vg, C({ 120, 255, 140 }, 230))
                nvgStrokeWidth(vg, 3 * s)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgRect(vg, cx + 15 * s, gy - 30 * s, 30 * s, 18 * s)
                nvgFillColor(vg, C({ 120, 255, 140 }, 235))
                nvgFill(vg)
            end
            return
        end
        -- 真实单位图例：两列网格全部展示（025；最多 4 行，390×867 不裁切、不压底部按钮）。
        local cols = 2
        local rows = math.ceil(#icons / cols)
        local itemH = 32 * s
        local totalH = rows * itemH + (rows - 1) * 5 * s
        local gy = h * 0.465 - totalH * 0.5
        local colW = math.min(165 * s, (w - m.left - m.right - 40) * 0.5)
        local x0 = cx - (colW * 2 + 14 * s) * 0.5 + colW * 0.5
        local iconSize = 26 * s
        for i = 1, #icons do
            local row = math.floor((i - 1) / cols) + 1
            local col = (i - 1) % cols + 1
            local x = x0 + (col - 1) * (colW + 14 * s)
            local y = gy + (row - 1) * (itemH + 6 * s) + itemH * 0.5
            local drawn = AssetSprites.draw(icons[i].sprite, x - colW * 0.5 + iconSize * 0.5,
                y, iconSize, 0, 235)
            if not drawn then
                nvgBeginPath(vg)
                nvgCircle(vg, x - colW * 0.5 + iconSize * 0.5, y, 9 * s)
                nvgFillColor(vg, C(accentColor, 230))
                nvgFill(vg)
            end
            SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(225, 238, 255, 235))
            text(x - colW * 0.5 + iconSize + 8 * s, y, icons[i].label)
        end
    end

    -- 标题保留单行，但按真实字形宽度收缩，避免 390 设计宽裁字。
    local title = page and page.title or ""
    local titleSize = 28 * s
    local titleMaxWidth = math.max(80, m.safeW - 20 * s)
    SafeDraw.font(titleSize, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    if type(nvgTextBounds) == "function" then
        local measured = nvgTextBounds(vg, 0, 0, title, nil)
        if type(measured) == "number" and measured > titleMaxWidth then
            titleSize = math.max(19 * s, titleSize * titleMaxWidth / measured)
            SafeDraw.font(titleSize, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        end
    end
    nvgFillColor(vg, C(accentColor, 255))
    text(cx, h * 0.085, title)

    -- 正文由 NanoVG 在安全宽度内换行；保留原文案，不依赖 WebView 的放大宽度。
    SafeDraw.font(14 * s, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(230, 242, 255, 250))
    local body = page and page.body or ""
    local bodyX = m.left + 12 * s
    local bodyWidth = math.max(80, m.safeW - 24 * s)
    nvgTextBox(vg, bodyX, h * 0.112, bodyWidth, body, nil)

    -- 迷你战场示意窗：直接绘制游戏内真实怪物与标的（场景随页签变化）
    drawTutorialScene(page, accentColor, cx, m, s)

    -- 页数徽标（场景窗下方）
    SafeDraw.font(12 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(170, 190, 235, 220))
    text(cx, h * 0.435, string.format("%s", page and page.badge or ""))

    -- 底部按钮：上一步 / 下一步(完成) / 跳过
    local layout = Screens.tutorialLayout(w, h)
    for _, b in ipairs(layout) do
        local x, y = b.x - b.w * 0.5, b.y - b.h * 0.5
        local bAccent = b.id == "tutorialNext" and COLORS.cyan
            or b.id == "tutorialSkip" and COLORS.purple or COLORS.blue
        drawHudPanel(x, y, b.w, b.h, bAccent)
        SafeDraw.font(14 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        text(b.x, b.y, b.label)
    end
end

function Render.drawTitle(w, h, best)
    return TitleRender.draw(vg, w, h, best, time)
end

function Render.drawResumeGate(w, h)
    if vg == nil then return end
    local m = Viewport.metrics(w, h)
    local s = m.ui
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(3, 7, 18, 205))
    nvgFill(vg)
    local pw = math.min(320 * s, m.safeW - 28)
    local ph = 132 * s
    local px, py = (w - pw) * 0.5, (h - ph) * 0.5
    drawHudPanel(px, py, pw, ph, COLORS.cyan)
    SafeDraw.font(20 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, C(COLORS.cyan, 250))
    text(w * 0.5, py + 43 * s, "游戏已暂停")
    SafeDraw.font(13 * s)
    nvgFillColor(vg, nvgRGBA(230, 242, 255, 245))
    text(w * 0.5, py + 84 * s, "点击或按键继续")
end

-- ============================================================
-- 主绘制
-- ============================================================
function Render.draw(world, w, h, best)
    if vg == nil then return end
    updateCamera(world, w, h)
    -- 背景
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    if world.phase == "layer_intro" or world.phase == "overload" or world.phase == "anti_hunt" then
        local bg = nvgLinearGradient(vg, 0, 0, 0, h,
            nvgRGBA(18, 26, 52, 255), nvgRGBA(10, 14, 30, 255))
        nvgFillPaint(vg, bg)
    else
        nvgFillColor(vg, nvgRGBA(8, 9, 14, 255))
    end
    nvgFill(vg)
    -- 世界层只允许进入中央战场矩形。裁剪在任何地图/实体/粒子绘制之前生效，
    -- 不是靠 HUD 背景遮盖；相机与世界坐标也使用同一 battle rect。
    local battle = cam.battle
    nvgSave(vg)
    nvgScissor(vg, battle.x, battle.y, battle.w, battle.h)
    SafeDraw.section("world", function()
        SafeDraw.section("bg", function()
            AssetSprites.drawTiledBg(w, h, cam.x * cam.scale * 0.4, cam.y * cam.scale * 0.4)
            if world.phase == "depleted" then
                nvgBeginPath(vg)
                nvgRect(vg, battle.x, battle.y, battle.w, battle.h)
                nvgFillColor(vg, nvgRGBA(0, 0, 0, 110))
                nvgFill(vg)
            end
            NeonPolish.drawWorldBase(vg, world, battle, time, settings)
        end)
        SafeDraw.section("map", drawMap, world, w, h)
        SafeDraw.section("map_neon", NeonPolish.drawMapEdges,
            vg, world, wx, wy, ws, time, settings)
        SafeDraw.section("signal_blackout", drawSignalBlackoutField, world)
        SafeDraw.section("scan", drawScan, world)
        if world.phase == "depleted" then
            SafeDraw.section("cones", function()
                for _, e in ipairs(world.enemies) do
                    local visibility = SignalBlackout.classify(world, e, "enemy")
                    if not e.dead and visibility.mode == "live" then
                        drawVisionCone(world, e)
                    end
                end
            end)
        end
        SafeDraw.section("pickups", drawPickups, world)
        SafeDraw.section("firewalls", drawFirewalls, world)
        SafeDraw.section("relays", drawRelays, world)
        SafeDraw.section("enemies", function()
            for _, e in ipairs(world.enemies) do
                if not e.dead then
                    local visibility = SignalBlackout.classify(world, e, "enemy")
                    if visibility.mode == "live" or visibility.mode == "ghost"
                        or visibility.mode == "tracked" then
                        drawEnemy(world, e, visibility)
                    elseif visibility.mode == "signal" then
                        drawDangerSignal(world, visibility)
                    end
                end
            end
        end)
        SafeDraw.section("player", drawPlayer, world)
        SafeDraw.section("fx", drawFx, world)
        SafeDraw.section("opportunities", drawOpportunities, world, w, h)
        SafeDraw.section("deepmarker", drawDeepMarker, world, w, h)
        SafeDraw.section("recon", drawRecon, world, w, h)
    end)
    nvgRestore(vg)
    SafeDraw.section("hud", drawHUD, world, w, h, best)
    if world.pauseMenu == true then
        SafeDraw.section("pause", Render.drawPauseOverlay, w, h, best, world)
        return
    end
    if world.phase == "layer_settlement" then
        -- 层结算/协议整备是独占界面：不绘制战斗按钮，避免误触。
        SafeDraw.section("settlement", drawLayerSettlement, world, w, h)
    elseif world.phase == "dead" then
        SafeDraw.section("overlays", drawOverlays, world, w, h, best)
        SafeDraw.section("buttons", drawButtons, world, w, h)
    else
        SafeDraw.section("buttons", drawButtons, world, w, h)
        SafeDraw.section("overlays", drawOverlays, world, w, h, best)
    end
    -- L11入场的首个超限选择发生在layer_intro；结算页已有RunShopRender负责。
    -- 这里放在最顶层，确保卡片覆盖战场且选择前不会推进倒计时。
    if world.overclockChoiceOpen == true and world.phase ~= "layer_settlement" then
        SafeDraw.section("overclock_choice", EndlessOverclockRender.drawChoice,
            vg, world, w, h)
    end
end

return Render
