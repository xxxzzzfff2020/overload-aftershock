-- 046：无尽超限协议选择层。仅在L11+层结算显示，不改变基础商店布局。
local SafeDraw = require "SafeDraw"
local Viewport = require "Viewport"
local Format = require "Format"
local EndlessOverclock = require "EndlessOverclock"

local Render = {}
local vg
local CYAN = { 80, 240, 255 }
local PURPLE = { 214, 53, 255 }
local WHITE = { 235, 242, 255 }
local MUTED = { 174, 198, 230 }

local function color(rgb, a) return nvgRGBA(rgb[1], rgb[2], rgb[3], SafeDraw.alpha(a or 255)) end
local function label(x, y, value) SafeDraw.text(x, y, value) end

local function stroke(rgb, width)
    nvgStrokeColor(vg, color(rgb, 255))
    nvgStrokeWidth(vg, width)
end

local function fill(rgb)
    nvgFillColor(vg, color(rgb, 255))
end

local function drawIconGlyph(card, bx, by, size)
    local cx, cy = bx + size * 0.5, by + size * 0.5
    local family = card.family or "arc"
    if family == "signal" then
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, size * 0.24); stroke(CYAN, 2 * (size / 52)); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, size * 0.10); fill(CYAN); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx + size * 0.13, cy - size * 0.10, size * 0.06); fill(PURPLE); nvgFill(vg)
        nvgBeginPath(vg); nvgMoveTo(vg, cx - size * 0.12, cy + size * 0.05)
        nvgLineTo(vg, cx + size * 0.10, cy - size * 0.10)
        stroke(PURPLE, 2 * (size / 52)); nvgStroke(vg)
    elseif family == "pulse" then
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, size * 0.24); stroke(CYAN, 2 * (size / 52)); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, size * 0.15); stroke(PURPLE, 1.8 * (size / 52)); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, size * 0.08); fill(CYAN); nvgFill(vg)
        nvgBeginPath(vg); nvgMoveTo(vg, cx - size * 0.18, cy)
        nvgLineTo(vg, cx + size * 0.20, cy)
        stroke(CYAN, 2 * (size / 52)); nvgStroke(vg)
    elseif family == "collapse" then
        nvgBeginPath(vg); nvgMoveTo(vg, cx - size * 0.14, cy)
        nvgLineTo(vg, cx, cy - size * 0.12)
        nvgLineTo(vg, cx + size * 0.16, cy - size * 0.03)
        nvgLineTo(vg, cx + size * 0.06, cy + size * 0.12)
        nvgClosePath(vg)
        fill(CYAN); nvgFill(vg)
        nvgBeginPath(vg); nvgMoveTo(vg, cx - size * 0.02, cy - size * 0.03)
        nvgLineTo(vg, cx + size * 0.18, cy - size * 0.12)
        nvgMoveTo(vg, cx + size * 0.02, cy + size * 0.02)
        nvgLineTo(vg, cx + size * 0.20, cy + size * 0.12)
        stroke(PURPLE, 2 * (size / 52)); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx - size * 0.16, cy, size * 0.05); fill(PURPLE); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx + size * 0.22, cy - size * 0.13, size * 0.05); fill(CYAN); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx + size * 0.23, cy + size * 0.12, size * 0.05); fill(CYAN); nvgFill(vg)
    else
        nvgBeginPath(vg); nvgMoveTo(vg, cx - size * 0.16, cy + size * 0.10)
        nvgLineTo(vg, cx - size * 0.03, cy - size * 0.10)
        nvgLineTo(vg, cx + size * 0.10, cy + size * 0.02)
        nvgLineTo(vg, cx + size * 0.20, cy - size * 0.10)
        stroke(CYAN, 2 * (size / 52)); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx + size * 0.20, cy - size * 0.10, size * 0.05); fill(PURPLE); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx - size * 0.18, cy + size * 0.10, size * 0.05); fill(CYAN); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx - size * 0.03, cy - size * 0.10, size * 0.04); fill(PURPLE); nvgFill(vg)
    end
end

function Render.drawChoice(vgContext, world, w, h)
    if not world.overclockChoiceOpen then return end
    local s = EndlessOverclock.ensure(world)
    if not s or not s.currentChoices then return end
    vg = vgContext
    local layout = EndlessOverclock.choiceLayout(w, h)
    local scale = layout.scale
    local cardW, cardH, gap = layout.cardW, layout.cardH, layout.gap
    local x, y = layout.x, layout.y
    nvgBeginPath(vg); nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(4, 8, 22, 218)); nvgFill(vg)
    nvgBeginPath(vg); nvgRoundedRect(vg, x - 10 * scale, layout.titleTop,
        cardW + 20 * scale, layout.titleHeight, 10 * scale)
    nvgFillColor(vg, nvgRGBA(16, 25, 58, 248)); nvgFill(vg)
    nvgStrokeColor(vg, color(PURPLE, 240)); nvgStrokeWidth(vg, 2 * scale); nvgStroke(vg)
    SafeDraw.font(16 * scale, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, color(CYAN, 255))
    label(w * 0.5, y - 79 * scale, "超限构筑")
    SafeDraw.font(9.5 * scale, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, color(MUTED, 245))
    local costText = s.currentCost == 0 and "免费选择" or ("消耗 " .. s.currentCost .. " 数据")
    label(w * 0.5, y - 52 * scale,
        string.format("超限数据 %d · %s · 保留点 %d", s.data, costText,
            s.freeChoiceTokens or 0))
    SafeDraw.font(8.2 * scale, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, color(CYAN, 220))
    label(w * 0.5, y - 28 * scale,
        "溢出折算：" .. EndlessOverclock.overflowSummary(world))
    for i, card in ipairs(s.currentChoices) do
        local yy = y + (i - 1) * (cardH + gap)
        nvgBeginPath(vg); nvgRoundedRect(vg, x, yy, cardW, cardH, 8 * scale)
        nvgFillColor(vg, nvgRGBA(12, 24, 54, 248)); nvgFill(vg)
        nvgStrokeColor(vg, color(PURPLE, 210)); nvgStrokeWidth(vg, 2 * scale); nvgStroke(vg)

        -- 图标是卡片的第一识别点；紫色只用于边框/徽标，不承担正文可读性。
        local badge = 54 * scale
        local bx, by = x + 10 * scale, yy + (cardH - badge) * 0.5
        nvgBeginPath(vg); nvgRoundedRect(vg, bx, by, badge, badge, 9 * scale)
        nvgFillColor(vg, nvgRGBA(20, 42, 82, 250)); nvgFill(vg)
        nvgStrokeColor(vg, color(CYAN, 225)); nvgStrokeWidth(vg, 1.5 * scale); nvgStroke(vg)
        drawIconGlyph(card, bx + 3 * scale, by + 3 * scale, badge - 6 * scale)

        local tx = bx + badge + 12 * scale
        SafeDraw.font(12 * scale, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, color(WHITE, 255)); label(tx, yy + 10 * scale,
            string.format("%d · %s", i, card.name))
        local currentLevel = s.levels[card.id] or 0
        local maxed = currentLevel >= EndlessOverclock.maxLevel(card)
        SafeDraw.font(9.2 * scale, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, color(maxed and MUTED or CYAN, 245)); label(tx, yy + 35 * scale,
            maxed and "已满级 · 选择点保留"
                or EndlessOverclock.effectText(card, currentLevel + 1))
        SafeDraw.font(8.2 * scale, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, color(MUTED, 235)); label(tx, yy + cardH - 9 * scale, card.desc)
        SafeDraw.font(8.8 * scale, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
        nvgFillColor(vg, color(WHITE, 235)); label(x + cardW - 11 * scale, yy + 11 * scale,
            maxed and "已满级" or string.format("Lv %d/%d", currentLevel + 1,
                EndlessOverclock.maxLevel(card)))
    end
end

return Render
