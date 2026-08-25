-- RunShopRender.lua
-- 016T层结算与协议整备的程序化NanoVG绘制；逻辑/命中仍由RunShop负责。

local InputSys = require "InputSys"
local SafeDraw = require "SafeDraw"
local Viewport = require "Viewport"
local Format = require "Format"
local RunShop = require "RunShop"
local EndlessOverclockRender = require "EndlessOverclockRender"

local RunShopRender = {}
---@type NVGContextWrapper
local vg = nil
local COLORS = {
    cyan = { 80, 240, 255 }, yellow = { 255, 230, 90 },
    orange = { 255, 170, 60 }, green = { 120, 255, 140 },
    blue = { 90, 150, 255 }, purple = { 214, 53, 255 }, red = { 255, 78, 95 },
    border = { 10, 16, 32 },
}
local function C(rgb, a)
    return nvgRGBA(rgb[1], rgb[2], rgb[3], SafeDraw.alpha(a or 255))
end
local function text(x, y, value) SafeDraw.text(x, y, value) end
local function drawHudPanel(x, y, w, h, accent)
    nvgBeginPath(vg); nvgRect(vg, x + 3, y + 3, w, h)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 70)); nvgFill(vg)
    nvgBeginPath(vg); nvgRect(vg, x, y, w, h)
    nvgFillColor(vg, nvgRGBA(16, 34, 70, 232)); nvgFill(vg)
    nvgStrokeColor(vg, C(COLORS.border, 255)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    nvgBeginPath(vg); nvgRect(vg, x + 2, y + h - 4, w - 4, 3)
    nvgFillColor(vg, C(accent or COLORS.cyan, 220)); nvgFill(vg)
end

local function drawShopIcon(itemId, x, y, size, color, alpha)
    local r = size * 0.5
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x - r, y - r, size, size, size * 0.22)
    nvgFillColor(vg, nvgRGBA(8, 18, 42, alpha))
    nvgFill(vg)
    nvgStrokeColor(vg, C(color, alpha))
    nvgStrokeWidth(vg, math.max(1.5, size * 0.07))
    nvgStroke(vg)
    nvgBeginPath(vg)
    if itemId == "collapseCooldownLevel" then
        nvgMoveTo(vg, x - r * 0.5, y - r * 0.55)
        nvgLineTo(vg, x + r * 0.1, y - r * 0.05)
        nvgLineTo(vg, x - r * 0.18, y + r * 0.05)
        nvgLineTo(vg, x + r * 0.5, y + r * 0.58)
    elseif itemId == "pulseCooldownLevel" then
        nvgCircle(vg, x, y, r * 0.28)
        nvgCircle(vg, x, y, r * 0.62)
    elseif itemId == "chainIntervalLevel" then
        nvgCircle(vg, x - r * 0.36, y, r * 0.23)
        nvgCircle(vg, x + r * 0.36, y, r * 0.23)
        nvgMoveTo(vg, x - r * 0.12, y)
        nvgLineTo(vg, x + r * 0.12, y)
    elseif itemId == "jammerBonusUses" then
        nvgMoveTo(vg, x - r * 0.5, y - r * 0.42)
        nvgLineTo(vg, x + r * 0.5, y + r * 0.42)
        nvgMoveTo(vg, x + r * 0.5, y - r * 0.42)
        nvgLineTo(vg, x - r * 0.5, y + r * 0.42)
    elseif itemId == "decoyBonusUses" then
        nvgCircle(vg, x, y, r * 0.25)
        nvgMoveTo(vg, x - r * 0.62, y + r * 0.5)
        nvgLineTo(vg, x, y - r * 0.62)
        nvgLineTo(vg, x + r * 0.62, y + r * 0.5)
    else
        nvgRoundedRect(vg, x - r * 0.42, y - r * 0.48, r * 0.84, r * 0.96, r * 0.38)
        nvgMoveTo(vg, x - r * 0.22, y)
        nvgLineTo(vg, x + r * 0.22, y)
    end
    nvgStrokeColor(vg, C(color, alpha))
    nvgStrokeWidth(vg, math.max(1.5, size * 0.085))
    nvgStroke(vg)
end

local function drawResourcePill(x, y, width, label, value, color, s)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, width, 24 * s, 12 * s)
    nvgFillColor(vg, nvgRGBA(7, 18, 40, 235))
    nvgFill(vg)
    nvgStrokeColor(vg, C(color, 210))
    nvgStrokeWidth(vg, 1.5 * s)
    nvgStroke(vg)
    nvgBeginPath(vg)
    nvgCircle(vg, x + 13 * s, y + 12 * s, 5 * s)
    nvgFillColor(vg, C(color, 245))
    nvgFill(vg)
    SafeDraw.font(9.5 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(216, 229, 250, 245))
    text(x + 24 * s, y + 12 * s, label)
    SafeDraw.font(11 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, C(color, 255))
    text(x + width - 9 * s, y + 12 * s, tostring(value))
end

local function drawLevelDots(row, x, y, s, color, alpha)
    for i = 1, row.maxLevel do
        nvgBeginPath(vg)
        nvgCircle(vg, x + (i - 1) * 11 * s, y, 3.2 * s)
        if i <= row.level then
            nvgFillColor(vg, C(color, alpha))
            nvgFill(vg)
        else
            nvgStrokeColor(vg, nvgRGBA(130, 151, 188, alpha))
            nvgStrokeWidth(vg, 1.2 * s)
            nvgStroke(vg)
        end
    end
end

local function upgradeSummary(archive)
    local u = type(archive) == "table" and archive.runUpgrades or {}
    return string.format("崩%d 脉%d 链%d · 干%d 诱%d 隐%d",
        tonumber(u.collapseCooldownLevel) or 0, tonumber(u.pulseCooldownLevel) or 0,
        tonumber(u.chainIntervalLevel) or 0, tonumber(u.jammerBonusUses) or 0,
        tonumber(u.decoyBonusUses) or 0, tonumber(u.cloakBonusUses) or 0)
end

local function drawGraduationModal(world, w, h)
    if world.graduationArchiveOpen ~= true then return end
    local modal = RunShop.graduationLayout(world, w, h)
    local s, panel = modal.scale, modal.panel
    nvgBeginPath(vg); nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 218)); nvgFill(vg)
    drawHudPanel(panel.x, panel.y, panel.w, panel.h, COLORS.purple)
    SafeDraw.font(17 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, C(COLORS.cyan, 255))
    text(panel.x + panel.w * 0.5, panel.y + 24 * s, "保存 L10 毕业档")
    SafeDraw.font(9.5 * s)
    nvgFillColor(vg, nvgRGBA(188, 207, 238, 230))
    text(panel.x + panel.w * 0.5, panel.y + 45 * s,
        world.graduationAction == "endless"
            and "选择槽位后从L11开启新的无尽局"
            or "选择槽位后结算并返回标题")
    local slots = type(world.graduationArchiveSlots) == "table"
        and world.graduationArchiveSlots or {}
    for index, card in ipairs(modal.cards) do
        local archive = slots[index]
        drawHudPanel(card.x, card.y, card.w, card.h,
            archive and COLORS.cyan or COLORS.blue)
        SafeDraw.font(13 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(245, 248, 255, 250))
        text(card.x + 10 * s, card.y + 8 * s, "档位 " .. tostring(index))
        if archive then
            SafeDraw.font(10.5 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
            nvgFillColor(vg, C(COLORS.cyan, 250))
            text(card.x + card.w - 10 * s, card.y + 9 * s, "可参与排行榜")
            SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
            nvgFillColor(vg, C(COLORS.yellow, 245))
            text(card.x + 10 * s, card.y + 31 * s,
                string.format("第10层 · %s分 · HP %d",
                    Format.integer(archive.score or 0), math.floor(archive.hp or 0)))
            SafeDraw.font(9.2 * s)
            nvgFillColor(vg, nvgRGBA(181, 202, 235, 230))
            text(card.x + 10 * s, card.y + 53 * s, upgradeSummary(archive)
                .. string.format(" · 数据%d 核心%d",
                    archive.wreckData or 0, archive.coreCount or 0))
            SafeDraw.font(8.8 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, C(COLORS.red, 220))
            text(card.x + card.w - 9 * s, card.y + card.h - 7 * s, "点击将覆盖")
        else
            SafeDraw.font(11 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(174, 198, 230, 230))
            text(card.x + 10 * s, card.y + card.h * 0.57, "空档 · 点击保存")
        end
    end
    drawHudPanel(modal.cancel.x, modal.cancel.y, modal.cancel.w, modal.cancel.h, COLORS.blue)
    SafeDraw.font(13 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(245, 248, 255, 250))
    text(modal.cancel.x + modal.cancel.w * 0.5,
        modal.cancel.y + modal.cancel.h * 0.5, "返回L10选择")
end

function RunShopRender.draw(vgContext, world, w, h)
    vg = vgContext
    local st = world.layerSettlement
    if not st then return end
    local m = Viewport.metrics(w, h)
    local lay = RunShop.layout(world, w, h)
    local s = lay.scale
    local panel = lay.panel

    -- 全屏压暗：整备期间世界层不再是交互焦点。
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 196))
    nvgFill(vg)

    drawHudPanel(panel.x, panel.y, panel.w, panel.h, COLORS.cyan)

    -- 标题：本层完成 + 本层新增分数
    SafeDraw.font(17 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, C(COLORS.cyan, 250))
    text(panel.x + 10 * s, panel.y + 7 * s,
        string.format("第 %d 层完成 · 协议整备", st.layer))
    SafeDraw.font(12 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFillColor(vg, C(COLORS.yellow, 245))
    text(panel.x + panel.w - 10 * s, panel.y + 9 * s,
        string.format("本层 +%s", Format.integer(st.scoreGained)))

    -- 两种资源使用独立图标胶囊，余额购买后即时刷新。
    local pillGap = 7 * s
    local pillW = (panel.w - 20 * s - pillGap) * 0.5
    drawResourcePill(panel.x + 10 * s, panel.y + 31 * s, pillW,
        "残骸数据", world.wreckData or 0, COLORS.orange, s)
    drawResourcePill(panel.x + 10 * s + pillW + pillGap, panel.y + 31 * s, pillW,
        "黄色核心", world.coreCount or 0, COLORS.yellow, s)

    -- 本层统计收口成两层：战斗结果优先，探索收益次级。
    SafeDraw.font(9.2 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(184, 202, 232, 240))
    local statY = panel.y + 61 * s
    text(panel.x + 10 * s, statY, string.format(
        "击破 普通 %d · 重型 %d · 反猎 %d（+%s） · 最高连杀 %d",
        st.normalKills, st.heavyKills, st.antiHuntKills,
        Format.integer(st.antiHuntScore), st.maxCombo))
    nvgFillColor(vg, nvgRGBA(145, 165, 198, 225))
    text(panel.x + 10 * s, statY + 13 * s, string.format(
        "回收 普通残骸 %d · 深层残骸 %d · 残骸数据 +%d · 黄色核心 +%d · 热度 %d",
        st.normalWrecksDismantled or 0, st.deepWrecks, st.wreckDataGained,
        st.coresGained, st.heatPeak))
    if lay.hintLeft > 0 then
        SafeDraw.font(9.5 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.cyan, math.floor(235 * math.min(1, lay.hintLeft * 2))))
        text(panel.x + panel.w * 0.5, panel.y + 94 * s,
            "点击整卡升级 · 上下拖动浏览 · 底部进入下一层")
    end

    -- 卡片区裁剪滚动；固定 header 与 footer 永远不参与滚动。
    nvgSave(vg)
    nvgScissor(vg, lay.viewport.x, lay.viewport.y, lay.viewport.w, lay.viewport.h)
    for _, g in ipairs(lay.groups) do
        SafeDraw.font(10.5 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, g.group == "overload" and C(COLORS.orange, 240) or C(COLORS.yellow, 240))
        text(panel.x + 10 * s, g.y, RunShop.GROUP_NAMES[g.group])
    end

    -- 六张正式能力卡：程序化图标、等级点、说明、前后效果和明确购买状态。
    for _, row in ipairs(lay.rows) do
        local maxed = row.level >= row.maxLevel
        local accent = maxed and COLORS.green
            or (row.enabled and (row.item.group == "overload" and COLORS.orange or COLORS.yellow))
            or COLORS.border
        local alpha = (row.enabled or maxed) and 250 or 140
        drawHudPanel(row.x, row.y, row.w, row.h, accent)
        if row.pulsing then
            local pulse = 0.35 + 0.65 * math.abs(math.sin((1 - row.pulse) * math.pi * 4))
            nvgBeginPath(vg)
            nvgRoundedRect(vg, row.x - 2 * s, row.y - 2 * s,
                row.w + 4 * s, row.h + 4 * s, 8 * s)
            nvgStrokeColor(vg, C(COLORS.cyan, math.floor(240 * pulse)))
            nvgStrokeWidth(vg, 3 * s)
            nvgStroke(vg)
        elseif InputSys.held["buy:" .. row.item.id] then
            nvgBeginPath(vg)
            nvgRoundedRect(vg, row.x + 2, row.y + 2, row.w - 4, row.h - 4, 5 * s)
            nvgFillColor(vg, nvgRGBA(45, 102, 200, 105))
            nvgFill(vg)
        end

        local iconX, iconY = row.x + 31 * s, row.y + row.h * 0.5
        drawShopIcon(row.item.id, iconX, iconY, 42 * s, accent, alpha)
        local tx = row.x + 60 * s
        SafeDraw.font(12 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(235, 242, 255, alpha))
        text(tx, row.y + 8 * s, row.item.name)
        drawLevelDots(row, tx, row.y + 29 * s, s, accent, alpha)
        SafeDraw.font(8.8 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(154, 177, 214, alpha))
        text(tx + 42 * s, row.y + 24 * s,
            string.format("Lv %d / %d", row.level, row.maxLevel))
        SafeDraw.font(8.8 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(177, 195, 225, alpha))
        text(tx, row.y + 40 * s, row.item.desc)

        SafeDraw.font(9.3 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(207, 220, 245, alpha))
        text(tx, row.y + 57 * s, "当前 " .. row.before)
        if row.after then
            nvgFillColor(vg, row.enabled and C(accent, 250) or nvgRGBA(142, 160, 190, 190))
            text(tx + 86 * s, row.y + 57 * s, "升级 → " .. row.after)
        end

        SafeDraw.font(10.2 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
        if maxed then
            nvgFillColor(vg, C(COLORS.green, 255))
            text(row.x + row.w - 9 * s, row.y + 20 * s, "等级已满")
            SafeDraw.font(8.8 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
            text(row.x + row.w - 9 * s, row.y + 38 * s, "已完成")
        elseif row.enabled then
            local unit = row.item.currency == "wreckData" and "数据" or "核心"
            local priceX = row.x + row.w - 9 * s
            nvgFillColor(vg, C(accent, 255))
            text(priceX, row.y + 20 * s, string.format("%d %s", row.price, unit))
            SafeDraw.font(8.8 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
            text(priceX, row.y + 39 * s, "点击整卡升级  ↑")
        else
            local statusX = row.x + row.w - 9 * s
            nvgFillColor(vg, nvgRGBA(154, 164, 184, 225))
            text(statusX, row.y + 20 * s, row.reason or "资源不足")
            SafeDraw.font(8.8 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
            text(statusX, row.y + 39 * s, string.format("持有 %d", row.balance or 0))
        end
        if row.pulsing then
            SafeDraw.font(9.2 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, C(COLORS.cyan, 255))
            text(row.x + row.w - 9 * s, row.y + row.h - 8 * s, "升级完成")
        end
    end
    nvgRestore(vg)

    -- 确认按钮：第10层给出两种选择，其余层直接进入下一层。
    local c = lay.confirm
    if world.endless == true and world.endlessCheckpointSaveFailed == true
        and world.checkpointReady ~= true then
        local half = (c.w - 8 * s) * 0.5
        drawHudPanel(c.x, c.y, half, c.h, COLORS.yellow)
        drawHudPanel(c.x + half + 8 * s, c.y, half, c.h, COLORS.cyan)
        SafeDraw.font(14 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        text(c.x + half * 0.5, c.y + c.h * 0.5 - 7 * s, "返回标题")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 - 7 * s, "重试保存")
        SafeDraw.font(9 * s)
        nvgFillColor(vg, nvgRGBA(196, 212, 240, 230))
        text(c.x + half * 0.5, c.y + c.h * 0.5 + 11 * s, "不会卡在本页")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 + 11 * s, "成功后可进入下一层")
    elseif world.checkpointReady then
        local half = (c.w - 8 * s) * 0.5
        drawHudPanel(c.x, c.y, half, c.h, COLORS.yellow)
        drawHudPanel(c.x + half + 8 * s, c.y, half, c.h, COLORS.cyan)
        SafeDraw.font(14 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        text(c.x + half * 0.5, c.y + c.h * 0.5 - 7 * s, "暂存并离开")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 - 7 * s, "继续下一层")
        SafeDraw.font(9 * s)
        nvgFillColor(vg, nvgRGBA(196, 212, 240, 230))
        text(c.x + half * 0.5, c.y + c.h * 0.5 + 11 * s, "返回标题")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 + 11 * s, "3秒倒计时")
    elseif st.runComplete then
        local half = (c.w - 8 * s) * 0.5
        drawHudPanel(c.x, c.y, half, c.h, COLORS.green)
        drawHudPanel(c.x + half + 8 * s, c.y, half, c.h, COLORS.cyan)
        SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        local confirming = world.challengeExitConfirm == true
        text(c.x + half * 0.5, c.y + c.h * 0.5 - 7 * s,
            confirming and "确认结算" or "结算本局")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 - 7 * s,
            confirming and "返回选择" or "进入无尽")
        SafeDraw.font(9 * s)
        nvgFillColor(vg, nvgRGBA(196, 212, 240, 230))
        text(c.x + half * 0.5, c.y + c.h * 0.5 + 11 * s,
            "返回标题，不可继续L11")
        text(c.x + half * 1.5 + 8 * s, c.y + c.h * 0.5 + 11 * s,
            confirming and "继续保留本次构筑" or "保留升级与分数，从L11继续")
    else
        drawHudPanel(c.x, c.y, c.w, c.h, COLORS.cyan)
        SafeDraw.font(16 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
        text(c.x + c.w * 0.5, c.y + c.h * 0.5 - 7 * s,
            string.format("进入第 %d 层", st.layer + 1))
        SafeDraw.font(9 * s)
        nvgFillColor(vg, nvgRGBA(196, 212, 240, 230))
        text(c.x + c.w * 0.5, c.y + c.h * 0.5 + 11 * s, "资源可保存到下一层")
    end

    drawGraduationModal(world, w, h)
    EndlessOverclockRender.drawChoice(vg, world, w, h)

    -- 整备期间的操作反馈（资源不足 / 已生效）走同一条 toast 通道。
    for _, f in ipairs(world.fx) do
        if f.kind == "toast" then
            local a = math.floor(230 * math.min(1, (1 - f.age / (f.dur or 1)) * 4))
            SafeDraw.font(11 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.yellow, a))
            text(w * 0.5, m.top + 2 * s, tostring(f.text))
            break
        end
    end
end


return RunShopRender
