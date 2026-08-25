-- TitleRender.lua
-- 正式标题、隐私、记录、帮助与设置页的程序化NanoVG绘制。

local SafeDraw = require "SafeDraw"
local Viewport = require "Viewport"
local Format = require "Format"
local AssetSprites = require "AssetSprites"
local Screens = require "Screens"
local SaveSys = require "SaveSys"
local PlatformFeatures = require "PlatformFeatures"

local TitleRender = {}
---@type NVGContextWrapper
local vg = nil
local time = 0
local COLORS = {
    cyan = { 80, 240, 255 }, blue = { 90, 150, 255 }, yellow = { 255, 230, 90 },
    purple = { 214, 53, 255 }, red = { 255, 80, 80 }, border = { 10, 16, 32 },
}
local function C(rgb, a)
    return nvgRGBA(rgb[1], rgb[2], rgb[3], SafeDraw.alpha(a or 255))
end
local function playerFallback(userId)
    local value = tostring(userId or "")
    if value == "" then return "TapTap玩家" end
    return "玩家·尾号" .. string.sub(value, -6)
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

function TitleRender.formatMyRankLine(rank, rankScore)
    if type(rank) ~= "number" then return nil end
    local layer, score = PlatformFeatures.decodeRankValue(rankScore)
    if not layer or not score or layer < 10 then return nil end
    return string.format("我的排名  第 %d 名 · 第%d层 · %s分",
        rank, layer, Format.integer(score))
end

function TitleRender.localRecordSummary(best)
    local localBest = SaveSys.getLocalBestRun(best)
    return string.format("最高纪录  第 %d 层 · %s 分 · 连杀 %d",
        localBest.layer or 0, Format.integer(localBest.score or 0),
        localBest.bestCombo or (best and best.bestCombo) or 0),
        "你的最高层数和分数会自动保留",
        localBest
end

function TitleRender.recentRunStatus(run)
    run = type(run) == "table" and run or {}
    if run.completionReason == "layer_complete" then return "本层完成" end
    if run.recovered then return "继续进度后结束" end
    if (run.challengeRetryCount or 0) > 0 then
        return "重试后结束"
    end
    if run.adAssisted then return "续战后结束" end
    if run.challengeCompleted then return "第10层通关" end
    if run.endless then return "无尽挑战结束" end
    return "挑战结束"
end

function TitleRender.draw(vgContext, w, h, best, elapsed)
    vg = vgContext
    time = elapsed or 0
    if vg == nil then return end
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    local privacyAccepted = SaveSys.hasPrivacyConsent(best)
    local onlineLeaderboardAvailable = PlatformFeatures.leaderboardStatus()
    local localBest = SaveSys.getLocalBestRun(best)
    -- 暗色网络空间背景 + 低亮扫描线。
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    local bg = nvgLinearGradient(vg, 0, 0, 0, h,
        nvgRGBA(7, 16, 34, 255), nvgRGBA(8, 8, 18, 255))
    nvgFillPaint(vg, bg)
    nvgFill(vg)
    AssetSprites.drawTiledBg(w, h, time * 6, time * 3)
    nvgBeginPath(vg)
    for y = 0, h, 12 do nvgRect(vg, 0, y, w, 1) end
    nvgFillColor(vg, nvgRGBA(80, 160, 255, 12))
    nvgFill(vg)
    SafeDraw.section("title", function()
        -- 程序化故障 Logo：不依赖额外标题图片，小屏仍清晰。
        local titleY = m.top + h * 0.105
        SafeDraw.font(44 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, C(COLORS.blue, 115))
        text(cx + 3, titleY + 1, "过 载 余 波")
        nvgFillColor(vg, C(COLORS.red, 90))
        text(cx - 3, titleY - 1, "过 载 余 波")
        nvgFillColor(vg, C(COLORS.cyan))
        text(cx, titleY, "过 载 余 波")
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx - math.min(150, w * 0.38), titleY + 32)
        nvgLineTo(vg, cx + math.min(150, w * 0.38), titleY + 32)
        nvgStrokeColor(vg, C(COLORS.cyan, 160))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
        SafeDraw.font(12 * s)
        nvgFillColor(vg, nvgRGBA(160, 180, 210, 220))
        text(cx, titleY + 50 * s, "30秒前你是灾难 · 30秒后你是猎物")

        if Screens.privacyGateOpen then
            local pw = math.min(430, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.205, pw, h * 0.47, COLORS.cyan)
            SafeDraw.font(18 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.cyan, 250))
            text(cx, h * 0.245, "隐私与在线功能")
            SafeDraw.font(12 * s)
            nvgFillColor(vg, nvgRGBA(225, 238, 255, 245))
            local gateLines = {
                "游戏会在本地保存纪录与设置。",
                "确认后可使用云同步、排行榜和广告复活。",
                "普通关可观看广告复活，无尽每局共3次。",
                "不观看仍可免费本层从头开始。",
                "TapTap昵称仅用于账号状态与排行榜展示。",
                "隐私说明有重要变化时会再次提示确认。",
            }
            local y0 = h * 0.315
            for i, line in ipairs(gateLines) do
                text(cx, y0 + (i - 1) * math.min(42 * s, h * 0.05), line)
            end
            SafeDraw.font(10 * s)
            nvgFillColor(vg, nvgRGBA(150, 180, 215, 230))
            text(cx, h * 0.58, "详细内容可随时在标题页或设置中查看")
        elseif Screens.formalL9ConfirmOpen then
            local pw = math.min(360 * s, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.28, pw, h * 0.43, COLORS.yellow)
            SafeDraw.font(18 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.yellow, 250))
            text(cx, h * 0.33, "快速验收 · L9")
            SafeDraw.font(12 * s)
            nvgFillColor(vg, nvgRGBA(225, 238, 255, 245))
            text(cx, h * 0.39, "自动带入 L1–L8 的固定收益和正式构筑")
            text(cx, h * 0.435, "从第9层开始，敌人、地图、协议与数值保持正式规则")
            nvgFillColor(vg, C(COLORS.yellow, 235))
            text(cx, h * 0.48, "本局会写入正式成绩，并可生成毕业档")
            SafeDraw.font(10 * s)
            nvgFillColor(vg, nvgRGBA(170, 195, 225, 235))
            text(cx, h * 0.515, "会替换当前挑战检查点；平台能力按正式条件生效")
        elseif Screens.graduationOpen then
            local pw = math.min(360 * s, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.245, pw, h * 0.49, COLORS.cyan)
            SafeDraw.font(17 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.cyan, 250))
            text(cx, h * 0.275, "无尽模式 · 选择毕业档")
            SafeDraw.font(9.5 * s)
            nvgFillColor(vg, nvgRGBA(174, 200, 234, 230))
            text(cx, h * 0.308, "每次都从原档克隆新的L11局，原档不会被修改")
        elseif Screens.recordsOpen then
            local pw = math.min(430, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.205, pw, h * 0.59, COLORS.yellow)
            SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.yellow, 245))
            text(cx, h * 0.235, "本地成绩")
            SafeDraw.font(10.8 * s)
            nvgFillColor(vg, nvgRGBA(225, 238, 255, 240))
            local summary, note = TitleRender.localRecordSummary(best)
            text(cx, h * 0.272, summary)
            nvgFillColor(vg, nvgRGBA(160, 195, 230, 225))
            text(cx, h * 0.303, note)
            local runs, page, pages = Screens.visibleRuns(best)
            local y0 = h * 0.34
            for i, run in ipairs(runs) do
                local mode = run.endless and "无尽" or "挑战"
                local status = TitleRender.recentRunStatus(run)
                local rowY = y0 + (i - 1) * 52 * s
                local rowX, rowW, rowH = (w - pw) * 0.5 + 12 * s,
                    pw - 24 * s, 44 * s
                nvgBeginPath(vg); nvgRoundedRect(vg, rowX, rowY, rowW, rowH, 5 * s)
                nvgFillColor(vg, nvgRGBA(10, 25, 53, 220)); nvgFill(vg)
                nvgStrokeColor(vg, C(COLORS.blue, 105)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
                SafeDraw.font(10.5 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(224, 238, 255, 245))
                text(rowX + 10 * s, rowY + 14 * s, mode .. " · " .. status)
                SafeDraw.font(10.5 * s, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, C(COLORS.cyan, 240))
                text(rowX + rowW - 10 * s, rowY + 14 * s,
                    string.format("第%d层", run.layer or 0))
                SafeDraw.font(10 * s, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(174, 200, 232, 235))
                text(rowX + 10 * s, rowY + 32 * s,
                    Format.integer(run.score or 0) .. " 分")
            end
            if #runs == 0 then
                SafeDraw.font(12 * s)
                nvgFillColor(vg, nvgRGBA(150, 170, 200, 220))
                text(cx, h * 0.46, "完成一局后将在这里记录成绩")
            end
            SafeDraw.font(11 * s)
            nvgFillColor(vg, nvgRGBA(160, 190, 225, 235))
            text(cx, h - m.bottom - 162 * s, string.format("%d / %d", page, pages))
        elseif Screens.onlineLeaderboardOpen then
            local pw = math.min(430, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.205, pw, h * 0.59, COLORS.cyan)
            SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, C(COLORS.cyan, 245))
            text(cx, h * 0.235, "过载余波·最高层挑战榜")
            SafeDraw.font(9.5 * s)
            nvgFillColor(vg, nvgRGBA(155, 190, 225, 225))
            text(cx, h * 0.268, "第10层起可上榜 · 仅显示前20名 · 层数优先")
            if Screens.onlineLeaderboardState == "loading" then
                SafeDraw.font(12 * s)
                nvgFillColor(vg, nvgRGBA(170, 195, 225, 235))
                text(cx, h * 0.46, "正在读取公开榜……")
            elseif Screens.onlineLeaderboardState == "error" then
                SafeDraw.font(12 * s)
                nvgFillColor(vg, C(COLORS.red, 235))
                text(cx, h * 0.46,
                    Screens.onlineLeaderboardErrorMessage or "暂时无法读取公开榜，请重试")
                SafeDraw.font(10 * s)
                nvgFillColor(vg, nvgRGBA(160, 190, 225, 225))
                text(cx, h * 0.50, "本地记录不受影响，可立即重试")
            else
                local entries = Screens.onlineLeaderboardEntries or {}
                local rows, page, pages = Screens.visibleLeaderboardEntries(entries)
                local panelX = (w - pw) * 0.5
                local tableX, tableY = panelX + 12 * s, h * 0.305
                local tableW = pw - 24 * s
                local headerH, rowH = 27 * s, 42 * s
                local tableH = headerH + rowH * Screens.LEADERBOARD_PAGE_SIZE
                local colW = {
                    tableW * 0.16, tableW * 0.40, tableW * 0.18, tableW * 0.26,
                }
                local colX = { tableX }
                for i = 1, #colW - 1 do colX[i + 1] = colX[i] + colW[i] end

                -- 表头与固定行框：保留空行，避免空榜伪造排名，也让翻页结构稳定。
                nvgBeginPath(vg); nvgRect(vg, tableX, tableY, tableW, tableH)
                nvgFillColor(vg, nvgRGBA(8, 21, 46, 235)); nvgFill(vg)
                nvgStrokeColor(vg, C(COLORS.cyan, 185)); nvgStrokeWidth(vg, 1.4); nvgStroke(vg)
                nvgBeginPath(vg); nvgRect(vg, tableX, tableY, tableW, headerH)
                nvgFillColor(vg, nvgRGBA(24, 62, 100, 245)); nvgFill(vg)
                for i = 1, #colW - 1 do
                    nvgBeginPath(vg); nvgMoveTo(vg, colX[i + 1], tableY)
                    nvgLineTo(vg, colX[i + 1], tableY + tableH)
                    nvgStrokeColor(vg, nvgRGBA(90, 180, 235, 115)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
                end
                for i = 1, Screens.LEADERBOARD_PAGE_SIZE do
                    local rowY = tableY + headerH + (i - 1) * rowH
                    if i % 2 == 0 then
                        nvgBeginPath(vg); nvgRect(vg, tableX, rowY, tableW, rowH)
                        nvgFillColor(vg, nvgRGBA(15, 34, 66, 150)); nvgFill(vg)
                    end
                    nvgBeginPath(vg); nvgMoveTo(vg, tableX, rowY)
                    nvgLineTo(vg, tableX + tableW, rowY)
                    nvgStrokeColor(vg, nvgRGBA(70, 130, 190, 105)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
                end

                local function tableCell(value, index, y, color, fontSize)
                    SafeDraw.font(fontSize * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgFillColor(vg, color)
                    text(colX[index] + colW[index] * 0.5, y, value)
                end
                local headers = { "排名", "玩家", "层数", "分数" }
                for i, header in ipairs(headers) do
                    tableCell(header, i, tableY + headerH * 0.5,
                        nvgRGBA(220, 242, 255, 245), 9.5)
                end
                for i, entry in ipairs(rows) do
                    entry = type(entry) == "table" and entry or {}
                    local rank = tonumber(entry.rank) or ((page - 1)
                        * Screens.LEADERBOARD_PAGE_SIZE + i)
                    local name = entry.name or playerFallback(entry.userId)
                    local rowY = tableY + headerH + (i - 0.5) * rowH
                    local rankColor = rank <= 3 and C(COLORS.yellow, 245)
                        or nvgRGBA(232, 242, 255, 240)
                    tableCell("#" .. tostring(rank), 1, rowY, rankColor, 9.2)
                    tableCell(tostring(name), 2, rowY, nvgRGBA(225, 238, 255, 240), 8.8)
                    tableCell("第" .. tostring(entry.layer or 0) .. "层", 3, rowY,
                        nvgRGBA(195, 220, 250, 235), 8.8)
                    tableCell(Format.integer(entry.score or 0), 4, rowY,
                        nvgRGBA(225, 238, 255, 240), 8.8)
                end
                if #rows == 0 then
                    SafeDraw.font(11 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgFillColor(vg, nvgRGBA(155, 180, 215, 225))
                    text(cx, tableY + headerH + rowH * 2.5, "暂无公开成绩")
                end

                local tableBottom = tableY + tableH
                SafeDraw.font(10 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(175, 205, 235, 235))
                text(cx, tableBottom + 20 * s, string.format("第 %d / %d 页", page, pages))
                -- 024C: 我的排名(仅正式身份时显示)
                local myRankLine = TitleRender.formatMyRankLine(
                    Screens.myRank, Screens.myRankScore)
                if myRankLine then
                    SafeDraw.font(10.5 * s)
                    nvgFillColor(vg, C(COLORS.yellow, 235))
                    text(cx, tableBottom + 43 * s, myRankLine)
                elseif Screens.onlineLeaderboardState == "ready" then
                    SafeDraw.font(9.5 * s)
                    nvgFillColor(vg, nvgRGBA(160, 190, 225, 225))
                    text(cx, tableBottom + 43 * s, "成绩已保存；同步完成后会显示排名")
                end
            end
        elseif Screens.helpOpen or Screens.privacyOpen then
            local pw = math.min(430, w - m.left - m.right - 24)
            drawHudPanel((w - pw) * 0.5, h * 0.225, pw, h * 0.56, COLORS.blue)
            SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(225, 238, 255, 240))
            text(cx, h * 0.255, Screens.privacyOpen and "隐私说明" or "操作说明")
            local lines, page, pages = Screens.visibleDocumentLines()
            SafeDraw.font(12 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            local y0 = h * 0.31
            local lineGap = math.min(45 * s, h * 0.058)
            for i, line in ipairs(lines) do
                text(cx, y0 + (i - 1) * lineGap, line)
            end
            SafeDraw.font(11 * s)
            nvgFillColor(vg, nvgRGBA(160, 190, 225, 235))
            text(cx, h - m.bottom - 162 * s, string.format("%d / %d", page, pages))
        elseif Screens.settingsOpen then
            local g = Screens.settingsGeometry(w, h)
            drawHudPanel(g.x, g.y, g.w, g.h, COLORS.purple)
            SafeDraw.font(15 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 245))
            text(cx, g.y + g.titleH * 0.48, "设置")
            local function group(box, label, accent)
                nvgBeginPath(vg)
                nvgRoundedRect(vg, box.x, box.y, box.w, box.h, 7 * s)
                nvgFillColor(vg, nvgRGBA(12, 27, 56, 220))
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
            -- 024C: 账号与在线能力信息区(设置面板底部;不阻塞离线游玩)
            -- 025: 移入面板独立 identity 区域,与第三行按钮彻底分离,390×867 不挤压。
            local idp = PlatformFeatures.identityPanel()
            local ib = g.identity
            group(ib, "TapTap账号", COLORS.cyan)
            SafeDraw.font(9.2 * s, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(190, 212, 240, 220))
            text(ib.x + 10 * s, g.identityLineY1,
                "账号：" .. idp.accountLabel)
            text(ib.x + 10 * s, g.identityLineY2,
                string.format("云同步：%s · 排行榜：%s",
                    idp.cloudSaveStatus, idp.leaderboardStatusLabel))
        else
            local recordW = math.min(290, w - m.left - m.right - 36)
            local challengeCp = SaveSys.getChallengeCheckpoint(best)
            local endlessCp = SaveSys.getEndlessCheckpoint(best)
            local hasCheckpoint = challengeCp ~= nil or endlessCp ~= nil
            drawHudPanel((w - recordW) * 0.5, h * 0.28, recordW,
                hasCheckpoint and 108 or 92, COLORS.yellow)
            SafeDraw.font(12 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(213, 226, 255, 235))
            text(cx, h * 0.28 + 22 * s, "本地最高纪录")
            local recordText = Format.integer(localBest.score or 0)
            SafeDraw.font((#recordText >= 11 and 14 or #recordText >= 9 and 16 or 18) * s)
            nvgFillColor(vg, C(COLORS.yellow, 245))
            text(cx, h * 0.28 + 52 * s, string.format("第 %d 层   %s 分",
                localBest.layer or 0, recordText))
            SafeDraw.font(11 * s)
            nvgFillColor(vg, nvgRGBA(157, 166, 198, 230))
            text(cx, h * 0.28 + 76 * s, string.format("最佳连杀 %d",
                localBest.bestCombo or best.bestCombo or 0))
            if endlessCp then
                SafeDraw.font(10 * s)
                nvgFillColor(vg, C(COLORS.cyan, 235))
                text(cx, h * 0.28 + 91 * s,
                    string.format("无尽进度：可从第 %d 层继续", endlessCp.nextLayer))
            elseif challengeCp then
                SafeDraw.font(10 * s)
                nvgFillColor(vg, C(COLORS.cyan, 235))
                local label = challengeCp.checkpointState == "L10_CHOICE"
                    and "挑战进度：第10层完成选择"
                    or string.format("挑战进度：可从第 %d 层继续", challengeCp.nextLayer)
                text(cx, h * 0.28 + 91 * s, label)
            end
        end

        -- 锐角按钮：黑色外框、暗蓝表面和底部强调线。
        for _, b in ipairs(Screens.layout(w, h, best.settings, privacyAccepted,
            onlineLeaderboardAvailable, false, SaveSys.getChallengeCheckpoint(best),
            SaveSys.getGraduationArchives(best), SaveSys.getEndlessCheckpoint(best))) do
            local x, y = b.x - b.w * 0.5, b.y - b.h * 0.5
            local accent = (b.id == "start" or b.id == "continueChallenge"
                    or b.id == "confirmStartNewChallenge" or b.id == "openGraduation"
                    or b.id == "confirmFormalL9"
                    or string.find(b.id, "^startGraduation:") ~= nil) and COLORS.cyan
                or (b.id == "closeDocument" or b.id == "closeSettings" or b.id == "closeRecords")
                    and COLORS.purple or COLORS.blue
            drawHudPanel(x, y, b.w, b.h, accent)
            if b.id == "start" or b.id == "continueChallenge"
                or b.id == "confirmStartNewChallenge" then
                nvgBeginPath(vg)
                nvgRect(vg, x + 3, y + 3, b.w - 6, b.h - 9)
                nvgFillColor(vg, nvgRGBA(31, 120, 190, 155))
                nvgFill(vg)
            end
            SafeDraw.font(b.sub and 15 * s or 13 * s, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 250))
            text(b.x, b.y - (b.sub and 7 * s or 0), b.label)
            if b.sub then
                SafeDraw.font(11 * s)
                nvgFillColor(vg, nvgRGBA(190, 215, 245, 220))
                text(b.x, b.y + 13 * s, b.sub)
            end
        end
    end)
end


return TitleRender
