-- NeonPolish.lua
-- 首发有界表现强化：仅使用 NanoVG 线条、基础几何与色块，不承载玩法状态。

local Config = require "Config"
local Util = require "Util"

local NeonPolish = {}

local PAL = {
    cyan = { 80, 240, 255 }, blue = { 90, 150, 255 }, magenta = { 230, 70, 255 },
    purple = { 160, 74, 230 }, red = { 255, 70, 78 }, amber = { 255, 185, 66 },
    yellow = { 255, 232, 100 }, white = { 242, 250, 255 },
}

local function rgba(c, a)
    return nvgRGBA(c[1], c[2], c[3], math.floor(Util.clamp(a or 255, 0, 255)))
end

local function strokeLine(vg, x1, y1, x2, y2, color, alpha, width)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x1, y1)
    nvgLineTo(vg, x2, y2)
    nvgStrokeColor(vg, rgba(color, alpha))
    nvgStrokeWidth(vg, width)
    nvgStroke(vg)
end

local function segmentedLine(vg, x1, y1, x2, y2, color, alpha, width, segments, phase)
    local count = segments or 7
    local offset = phase or 0
    for i = 0, count - 1 do
        if (i + offset) % 2 == 0 then
            local a = i / count
            local b = math.min(1, (i + 0.64) / count)
            strokeLine(vg, x1 + (x2 - x1) * a, y1 + (y2 - y1) * a,
                x1 + (x2 - x1) * b, y1 + (y2 - y1) * b, color, alpha, width)
        end
    end
end

function NeonPolish.drawWorldBase(vg, world, battle, time, settings)
    -- 039B：三阶段用独立基色构成身份语义，忽略HUD文字也能一眼区分：
    --   过载=青(强权)、枯竭=暗紫(失能)、反猎=品红/黄(清算)。
    -- 反猎不再简单复用“过载亮青”，而是暖色品红基线 + 黄色分片，与过载拉开色温。
    local phase = world.phase
    local overload = phase == "overload"
    local antiHunt = phase == "anti_hunt"
    local primary = overload and PAL.cyan or antiHunt and PAL.magenta or PAL.purple
    local secondary = overload and PAL.magenta or antiHunt and PAL.yellow or PAL.red
    nvgBeginPath(vg)
    nvgRect(vg, battle.x, battle.y, battle.w, battle.h)
    nvgFillColor(vg, overload and nvgRGBA(3, 9, 18, 72)
        or antiHunt and nvgRGBA(16, 4, 22, 96)
        or nvgRGBA(2, 2, 8, 138))
    nvgFill(vg)

    local spacing = 26
    local drift = settings.reduceFx and 0 or (time * (overload and 9 or antiHunt and 12 or 4)) % spacing
    for y = battle.y + drift, battle.y + battle.h, spacing do
        strokeLine(vg, battle.x, y, battle.x + battle.w, y, primary,
            overload and 16 or antiHunt and 24 or 11, 1)
    end

    local sliceCount = settings.reduceFx and 2 or 5
    for i = 1, sliceCount do
        local seed = i * 73 + math.floor(time * (settings.reduceFx and 0.25 or 1.2))
        local y = battle.y + (seed * 31) % math.max(1, math.floor(battle.h))
        local x = battle.x + (seed * 47) % math.max(1, math.floor(battle.w * 0.72))
        local len = 18 + (seed % 43)
        strokeLine(vg, x, y, math.min(battle.x + battle.w, x + len), y,
            (i % 3 == 0) and secondary or primary, overload and 32 or antiHunt and 40 or 22, 1.2)
    end
end

function NeonPolish.drawMapEdges(vg, world, wx, wy, ws, time, settings)
    local t = Config.TILE
    local phase = world.phase
    local overload = phase == "overload"
    local antiHunt = phase == "anti_hunt"
    local primary = overload and PAL.cyan or antiHunt and PAL.magenta or PAL.purple
    local mapB = world.mapId == "firewall_core"
    local nodeStep = settings.reduceFx and 11 or 7
    for r = 1, world.map.h do
        for c = 1, world.map.w do
            if world.solid[r][c] then
                local x, y, size = wx((c - 1) * t), wy((r - 1) * t), ws(t)
                nvgBeginPath(vg)
                nvgRect(vg, x + 1, y + 1, size - 2, size - 2)
                nvgStrokeColor(vg, rgba(primary, mapB and 88 or 62))
                nvgStrokeWidth(vg, math.max(1.1, ws(1.15)))
                nvgStroke(vg)
                if (r * 5 + c * 3) % nodeStep == 0 then
                    nvgBeginPath(vg)
                    nvgCircle(vg, x + size * 0.5, y + size * 0.5,
                        math.max(1.5, ws(1.8 + 0.45 * math.sin(time * 2 + r + c))))
                    nvgFillColor(vg, rgba(mapB and PAL.magenta or primary,
                        overload and 125 or antiHunt and 150 or 82))
                    nvgFill(vg)
                end
            end
        end
    end
end

function NeonPolish.drawPursuit(vg, world, e, x, y, r, wx, wy, ws, time, settings)
    if world.phase ~= "depleted" then return end
    local pulse = settings.reduceFx and 0 or math.sin(time * 7) * 0.5 + 0.5
    if e.state == "decoyed" and e.decoyTarget then
        local tx, ty = wx(e.decoyTarget.x), wy(e.decoyTarget.y)
        segmentedLine(vg, x, y, tx, ty, PAL.yellow, 210, 2.4, 10,
            math.floor(time * (settings.reduceFx and 2 or 8)))
        nvgBeginPath(vg)
        nvgCircle(vg, tx, ty, ws(16) + pulse * ws(5))
        nvgStrokeColor(vg, rgba(PAL.yellow, 185))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
        strokeLine(vg, x - r * 0.8, y - r * 1.55, x + r * 0.8, y - r * 1.55,
            PAL.yellow, 235, 2.5)
    elseif e.state == "chase" or e.state == "alert" then
        local tx = e.lastSeenX and wx(e.lastSeenX) or wx(world.player.x)
        local ty = e.lastSeenY and wy(e.lastSeenY) or wy(world.player.y)
        local dx, dy = tx - x, ty - y
        local d = math.max(1, math.sqrt(dx * dx + dy * dy))
        local len = math.min(d, ws(72))
        strokeLine(vg, x, y, x + dx / d * len, y + dy / d * len,
            PAL.red, 150 + pulse * 60, 2.2)
        for i = 0, 2 do
            local a = i * math.pi * 2 / 3 + time * (settings.reduceFx and 0.3 or 1.5)
            strokeLine(vg, x + math.cos(a) * r * 1.45, y + math.sin(a) * r * 1.45,
                x + math.cos(a) * r * (1.8 + pulse * 0.15),
                y + math.sin(a) * r * (1.8 + pulse * 0.15), PAL.red, 190, 2)
        end
    elseif (e.state == "lost" or e.state == "search") and e.lastSeenX then
        local tx, ty = wx(e.lastSeenX), wy(e.lastSeenY)
        segmentedLine(vg, x, y, tx, ty, PAL.amber, 125, 1.5, 8,
            math.floor(time * 2))
        local k = ws(7)
        strokeLine(vg, tx - k, ty, tx + k, ty, PAL.amber, 180, 1.5)
        strokeLine(vg, tx, ty - k, tx, ty + k, PAL.amber, 180, 1.5)
    end
end

function NeonPolish.drawCloak(vg, world, x, y, r, time, settings)
    if world.cloakLeft <= 0 then return end
    local pulse = settings.reduceFx and 0 or math.sin(time * 9) * 0.5 + 0.5
    for i = 0, 5 do
        local a0 = i * math.pi / 3 + time * (settings.reduceFx and 0.15 or 0.65)
        local a1 = a0 + math.pi / 7
        nvgBeginPath(vg)
        nvgArc(vg, x, y, r * (1.55 + 0.18 * pulse), a0, a1, NVG_CW)
        nvgStrokeColor(vg, rgba((i % 2 == 0) and PAL.blue or PAL.white, 125))
        nvgStrokeWidth(vg, 1.8)
        nvgStroke(vg)
    end
    strokeLine(vg, x - r * 1.35, y - r * 0.85, x - r * 0.45, y - r * 0.85,
        PAL.cyan, 160, 2)
    strokeLine(vg, x + r * 0.45, y + r * 0.85, x + r * 1.35, y + r * 0.85,
        PAL.cyan, 160, 2)
end

function NeonPolish.drawRestart(vg, progress, x, y, r, time, settings)
    progress = Util.clamp(progress, 0, 1)
    local pulse = settings.reduceFx and 0 or (math.sin(time * (7 + progress * 12)) * 0.5 + 0.5)
    for ring = 1, 3 do
        local rr = r * (1.65 + ring * 0.38 - progress * 0.16 * ring)
        nvgBeginPath(vg)
        nvgArc(vg, x, y, rr, -math.pi / 2,
            -math.pi / 2 + math.pi * 2 * progress, NVG_CW)
        nvgStrokeColor(vg, rgba(ring == 2 and PAL.magenta or PAL.cyan,
            95 + ring * 35 + pulse * 25))
        nvgStrokeWidth(vg, math.max(1.5, 4.5 - ring))
        nvgStroke(vg)
    end
    local rays = settings.reduceFx and 4 or 8
    for i = 0, rays - 1 do
        local a = i * math.pi * 2 / rays + time * 0.35
        local outer = r * (3.4 - progress * 0.9)
        local inner = outer - r * (0.45 + progress * 0.4)
        strokeLine(vg, x + math.cos(a) * outer, y + math.sin(a) * outer,
            x + math.cos(a) * inner, y + math.sin(a) * inner,
            (i % 3 == 0) and PAL.magenta or PAL.cyan, 80 + progress * 150, 1.6)
    end
end

function NeonPolish.drawHuntTarget(vg, x, y, r, time, settings)
    local pulse = settings.reduceFx and 0 or math.sin(time * 8) * 0.5 + 0.5
    local rr = r * (2.35 + pulse * 0.14)
    for i = 0, 3 do
        local a = i * math.pi / 2
        local x1, y1 = x + math.cos(a) * rr, y + math.sin(a) * rr
        local x2, y2 = x + math.cos(a) * (rr + r * 0.52), y + math.sin(a) * (rr + r * 0.52)
        strokeLine(vg, x1, y1, x2, y2, (i % 2 == 0) and PAL.cyan or PAL.yellow, 235, 2.5)
    end
end

function NeonPolish.drawAntiHuntFx(vg, f, t01, wx, wy, ws, settings)
    if f.kind ~= "anti_hunt_burst" then return false end
    local x, y = wx(f.x), wy(f.y)
    local reward = f.reward or 500
    local level = reward >= 2000 and 3 or reward >= 1000 and 2 or 1
    local fade = 1 - t01
    -- 039B：档位差不再被减闪模式抹平。辐条数 = 基础 + 档位×2，
    -- 减闪只减少动画密度、不减少档位增量，2000档在两种模式下都明显强于500档。
    local spokes = (settings.reduceFx and 4 or 6) + level * 2
    local peak = settings.reduceFx and 0.7 or 1
    local mag = (level == 3 and 1.35 or level == 2 and 1.12 or 1) * peak
    for i = 0, spokes - 1 do
        local a = i * math.pi * 2 / spokes + level * 0.16
        local inner = ws(12 + 12 * t01)
        local outer = ws(34 + level * 10) * (0.45 + t01) * mag
        strokeLine(vg, x + math.cos(a) * inner, y + math.sin(a) * inner,
            x + math.cos(a) * outer, y + math.sin(a) * outer,
            level == 3 and PAL.magenta or level == 2 and PAL.yellow or PAL.cyan,
            235 * fade * (level == 3 and 1.1 or 1), 1.5 + level * 0.7)
    end
    for ring = 1, level do
        nvgBeginPath(vg)
        nvgCircle(vg, x, y, ws((22 + ring * 14) * t01))
        nvgStrokeColor(vg, rgba(ring == level and PAL.white or PAL.cyan, 210 * fade))
        nvgStrokeWidth(vg, 1.5 + ring * 0.8)
        nvgStroke(vg)
    end
    return true
end

function NeonPolish.drawCountdown(vg, world, w, h, settings)
    if world.phase ~= "overload" then return end
    local left = world.overloadLeft
    if left > Config.OVERLOAD.lastWarnTime or left <= 0 then return end
    local frac = left - math.floor(left)
    local pulse = math.max(0, frac - 0.55) / 0.45
    local strength = (left <= 3) and 1 or 0.55
    local a = math.floor((30 + 70 * pulse) * strength * (settings.reduceFx and 0.32 or 1))
    local edge = (left <= 3) and 26 or 16
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgRect(vg, edge, edge, w - edge * 2, h - edge * 2)
    nvgPathWinding(vg, NVG_HOLE)
    nvgFillColor(vg, nvgRGBA(255, 60, 60, a))
    nvgFill(vg)
end

function NeonPolish.drawThreatVignette(vg, world, w, h, level, settings)
    if world.phase ~= "depleted" or level < 1 then return end
    local a = (({ 22, 40, 60 })[level] or 0) * (settings.reduceFx and 0.55 or 1)
    local col = (level >= 3) and PAL.red or PAL.amber
    local grad = nvgRadialGradient(vg, w / 2, h / 2, math.min(w, h) * 0.42,
        math.max(w, h) * 0.72, rgba(col, 0), rgba(col, a))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillPaint(vg, grad)
    nvgFill(vg)
end

function NeonPolish.drawDeathPanel(vg, x, y, w, h, time, settings)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w, h)
    nvgFillColor(vg, nvgRGBA(5, 8, 18, 228))
    nvgFill(vg)
    nvgStrokeColor(vg, rgba(PAL.red, 225))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    local cut = math.min(28, w * 0.08)
    strokeLine(vg, x, y + cut, x + cut, y, PAL.red, 240, 3)
    strokeLine(vg, x + w - cut, y, x + w, y + cut, PAL.red, 240, 3)
    strokeLine(vg, x, y + h - cut, x + cut, y + h, PAL.cyan, 150, 2)
    strokeLine(vg, x + w - cut, y + h, x + w, y + h - cut, PAL.cyan, 150, 2)

    local slices = settings.reduceFx and 3 or 6
    for i = 1, slices do
        local yy = y + 18 + ((i * 71 + math.floor(time * 13)) % math.max(1, math.floor(h - 36)))
        local side = i % 2 == 0
        local sx = side and x + w - 54 or x + 8
        strokeLine(vg, sx, yy, sx + (side and 38 or 46), yy,
            i % 3 == 0 and PAL.magenta or PAL.red, 70 + i * 12, 1.4)
    end

    local cx, cy = x + w * 0.5, y + 61
    for i = 0, 5 do
        local a = i * math.pi / 3
        local inner, outer = 28, 48 + (i % 2) * 8
        strokeLine(vg, cx + math.cos(a) * inner, cy + math.sin(a) * inner,
            cx + math.cos(a) * outer, cy + math.sin(a) * outer,
            i % 2 == 0 and PAL.red or PAL.purple, 120, 1.5)
    end
end

return NeonPolish
