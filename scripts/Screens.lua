-- Screens.lua
-- 正式首发轻量标题页：无尽闯关入口、本地记录、设置与操作说明。
-- 只负责布局与命中；绘制在 Render.drawTitle，动作在 main 处理。

local Viewport = require "Viewport"
local Util = require "Util"
local Config = require "Config"

local Screens = {}

Screens.helpOpen = false
Screens.settingsOpen = false
Screens.privacyOpen = false
Screens.recordsOpen = false
Screens.onlineLeaderboardOpen = false
Screens.onlineLeaderboardState = "idle"
Screens.onlineLeaderboardEntries = {}
Screens.myRank = nil
Screens.myRankScore = nil
Screens.privacyGateOpen = false
Screens.runRecoveryOpen = false
Screens.newChallengeConfirmOpen = false
Screens.graduationOpen = false
Screens.formalL9ConfirmOpen = false
-- 无尽暂停中的破坏性结束操作必须显式确认；此状态仅属于当前暂停会话。
Screens.endlessEndConfirmOpen = false
Screens.privacyGateReturn = "title"
Screens.documentReturn = "title"
Screens.page = 1
Screens.recordPage = 1
Screens.PAGE_SIZE = 5
Screens.leaderboardPage = 1
Screens.LEADERBOARD_PAGE_SIZE = 5
Screens.LEADERBOARD_MAX_RESULTS = 20
Screens.LEADERBOARD_LOAD_TIMEOUT_SECONDS = 12
Screens.onlineLeaderboardRequestId = 0
Screens.onlineLeaderboardDeadline = nil
Screens.onlineLeaderboardErrorMessage = nil

function Screens.settingsGeometry(w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local compact = h < 720
    local panelW = math.min(330 * s, m.safeW - 20)
    local footerY = h - m.bottom - 58 * s
    local panelY = compact and math.max(m.top + 92 * s, h * 0.16)
        or math.max(m.top + 122 * s, h * 0.20)
    -- 设置页第三行只保留正式“查看教程”入口。
    -- 025:面板底部预留"账号与在线能力"信息区，避免与第三行按钮在 390×867 下挤压。
    -- 短屏(如 320x640)下面板高度受 footer 约束,下限 330s 自适应收缩,
    -- 保证 identity 信息区与第三行按钮都留在 footer 之上(统一 ui=1.10 后)。
    local panelBottomGap = compact and 24 * s or 38 * s
    local panelH = math.max(330 * s,
        math.min(500 * s, footerY - panelY - panelBottomGap))
    local gap = 7 * s
    local titleH = 38 * s
    local contentH = panelH - titleH - gap * 5 - 10 * s
    -- 033: 每个分组保留独立标题带，控件只排在标题带之下。
    -- 短屏时 music 区至少保留 80s 高度，账号区增加到可读的两行状态高度。
    local headerH = (compact and 21 or 24) * s
    local musicH = math.max(contentH * 0.25, 80 * s)
    local sfxH = contentH * 0.17
    local assistH = contentH * 0.36
    local identityH = contentH - musicH - sfxH - assistH
    local gx = (w - panelW) * 0.5 + 10 * s
    local gw = panelW - 20 * s
    local y = panelY + titleH + gap
    local music = { x = gx, y = y, w = gw, h = musicH }
    y = y + musicH + gap
    local sfx = { x = gx, y = y, w = gw, h = sfxH }
    y = y + sfxH + gap
    local assist = { x = gx, y = y, w = gw, h = assistH }
    y = y + assistH + gap
    local identity = { x = gx, y = y, w = gw, h = identityH }

    local bodyInset = 4 * s
    local musicBodyY = music.y + headerH + bodyInset
    local musicBodyH = music.h - headerH - bodyInset * 2
    local musicRowGap = 4 * s
    local musicControlH = math.min(34 * s, (musicBodyH - musicRowGap) * 0.5)
    local musicToggleY = musicBodyY + musicControlH * 0.5
    local musicVolumeY = musicBodyY + musicBodyH - musicControlH * 0.5

    local sfxBodyY = sfx.y + headerH + bodyInset
    local sfxBodyH = sfx.h - headerH - bodyInset * 2
    local sfxControlH = math.min(34 * s, sfxBodyH)
    local sfxVolumeY = sfxBodyY + sfxBodyH * 0.5

    local assistGap = 5 * s
    local assistBodyY = assist.y + headerH + bodyInset
    local assistBodyH = assist.h - headerH - bodyInset * 2
    local assistRowH = math.min(36 * s, (assistBodyH - assistGap * 2) / 3)
    local assistY1 = assistBodyY + assistRowH * 0.5
    local assistY2 = assistY1 + assistRowH + assistGap
    local assistY3 = assistY2 + assistRowH + assistGap
    return {
        x = (w - panelW) * 0.5, y = panelY, w = panelW, h = panelH,
        footerY = footerY, titleH = titleH, music = music, sfx = sfx,
        assist = assist, identity = identity, headerH = headerH,
        musicControlH = musicControlH, musicToggleY = musicToggleY,
        musicVolumeY = musicVolumeY, sfxControlH = sfxControlH,
        sfxVolumeY = sfxVolumeY, assistRowH = assistRowH,
        assistY1 = assistY1, assistY2 = assistY2, assistY3 = assistY3,
        identityLineY1 = identity.y + headerH + 3 * s,
        identityLineY2 = identity.y + headerH + 17 * s,
    }
end

-- 标题页按钮布局(逻辑像素;settings 用于显示开关状态)
function Screens.layout(w, h, settings, privacyAccepted, onlineLeaderboardAvailable, inPause,
    challengeCheckpoint, graduationArchives, endlessCheckpoint)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    local btns = {}
    local function add(id, label, sub, x, y, bw, bh)
        btns[#btns + 1] = {
            id = id, label = label, sub = sub, x = x, y = y,
            w = bw, h = bh, r = math.min(bw, bh) * 0.5, shape = "rect",
        }
    end
    if Screens.privacyGateOpen then
        local bw = math.min(280 * s, m.safeW - 28)
        add("privacyAccept", "了解并同意", "继续游戏并启用在线功能", cx,
            h - m.bottom - 88 * s, bw, 58 * s)
        return btns
    end
    if Screens.formalL9ConfirmOpen then
        local bw = math.min(300 * s, m.safeW - 28)
        add("confirmFormalL9", "从 L9 开始快速验收",
            "正式规则 · 自动带入 L1–L8 收益", cx, h * 0.54, bw, 62 * s)
        add("cancelFormalL9", "取消", "返回设置", cx, h * 0.64, 180 * s, 50 * s)
        return btns
    end
    if Screens.recordsOpen then
        local navW = math.min(116 * s, (w - m.left - m.right - 36) / 2)
        add("prevRecords", "上一页", nil, cx - navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
        add("nextRecords", "下一页", nil, cx + navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
        add("closeRecords", "返回", nil, cx, h - m.bottom - 62 * s, 164 * s, 50 * s)
        return btns
    end
    if Screens.onlineLeaderboardOpen then
        local navW = math.min(116 * s, (w - m.left - m.right - 36) / 2)
        if Screens.onlineLeaderboardState == "error" then
            add("retryOnlineLeaderboard", "重新读取排行榜", "本地记录不受影响",
                cx, h - m.bottom - 124 * s, math.min(236 * s, m.safeW - 28), 48 * s)
        else
            add("prevOnlineLeaderboard", "上一页", nil,
                cx - navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
            add("nextOnlineLeaderboard", "下一页", nil,
                cx + navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
        end
        add("closeOnlineLeaderboard", "返回", nil, cx,
            h - m.bottom - 62 * s, 164 * s, 50 * s)
        return btns
    end
    if Screens.graduationOpen then
        local panelW = math.min(300 * s, m.safeW - 24)
        local slots = type(graduationArchives) == "table" and graduationArchives or {}
        for index = 1, 3 do
            local archive = slots[index]
            local label = archive and ("档位 " .. tostring(index))
                or ("档位 " .. tostring(index) .. " · 空")
            local sub = archive and string.format("第10层 · %d分 · 可参与排行榜",
                math.floor(archive.score or 0))
                or "完成L10后可保存"
            add("startGraduation:" .. tostring(index), label, sub,
                cx, h * (0.39 + index * 0.105), panelW, 62 * s)
        end
        add("closeGraduation", "返回标题", nil, cx,
            h - m.bottom - 62 * s, 164 * s, 50 * s)
        return btns
    end
    if Screens.helpOpen or Screens.privacyOpen then
        local navW = math.min(116 * s, (w - m.left - m.right - 36) / 2)
        add("prevPage", "上一页", nil, cx - navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
        add("nextPage", "下一页", nil, cx + navW * 0.55, h - m.bottom - 124 * s, navW, 48 * s)
        add("closeDocument", "返回", nil, cx, h - m.bottom - 62 * s, 164 * s, 50 * s)
        return btns
    end
    if Screens.settingsOpen then
        local g = Screens.settingsGeometry(w, h)
        local stepW = 48 * s
        add("sound", settings.sound and "开" or "关", nil,
            g.music.x + g.music.w - 53 * s, g.musicToggleY,
            88 * s, g.musicControlH)
        add("musicDown", "−", nil, g.music.x + 32 * s, g.musicVolumeY,
            stepW, g.musicControlH)
        add("musicUp", "+", nil, g.music.x + g.music.w - 32 * s, g.musicVolumeY,
            stepW, g.musicControlH)
        add("sfxDown", "−", nil, g.sfx.x + 32 * s, g.sfxVolumeY,
            stepW, g.sfxControlH)
        add("sfxUp", "+", nil, g.sfx.x + g.sfx.w - 32 * s, g.sfxVolumeY,
            stepW, g.sfxControlH)
        local assistGap = 6 * s
        local assistW = (g.assist.w - assistGap * 3) / 2
        add("vibration", settings.vibration == false and "震动 关" or "震动 开", nil,
            g.assist.x + assistGap + assistW * 0.5, g.assistY1,
            assistW, g.assistRowH)
        add("reduceFx", settings.reduceFx and "减闪 开" or "减闪 关", nil,
            g.assist.x + assistGap * 2 + assistW * 1.5, g.assistY1,
            assistW, g.assistRowH)
        add("reduceShake", settings.reduceShake and "减震 开" or "减震 关", nil,
            g.assist.x + assistGap + assistW * 0.5, g.assistY2,
            assistW, g.assistRowH)
        if inPause ~= true then
            add("privacySettings", privacyAccepted and "隐私说明" or "授权在线功能", nil,
                g.assist.x + assistGap * 2 + assistW * 1.5, g.assistY2,
                assistW, g.assistRowH)
        end
        -- 第三行保留教程，并在正式验收开关打开时加入L9快速入口；暂停设置内隐藏。
        if inPause ~= true then
            if Config.FORMAL.fastReviewL9Enabled == true then
                add("replayTutorial", "查看教程", nil,
                    g.assist.x + assistGap + assistW * 0.5, g.assistY3,
                    assistW, g.assistRowH)
                add("formalL9", "快速验收 · L9", "正式模式",
                    g.assist.x + assistGap * 2 + assistW * 1.5, g.assistY3,
                    assistW, g.assistRowH)
            else
                add("replayTutorial", "查看教程", nil,
                    g.assist.x + g.assist.w * 0.5, g.assistY3,
                    g.assist.w - assistGap * 2, g.assistRowH)
            end
        end
        -- 标题设置返回标题；局内暂停设置则直接恢复对局，避免“保存并返回”
        -- 被理解成无响应或返回到另一层菜单。
        add("closeSettings", inPause == true and "保存并继续" or "保存并返回", nil,
            cx, g.footerY, g.w, 52 * s)
        return btns
    end
    local primaryW = math.min(270 * s, w - m.left - m.right - 28)
    local hasGraduation = false
    for index = 1, 3 do
        if type(graduationArchives) == "table" and type(graduationArchives[index]) == "table" then
            hasGraduation = true
            break
        end
    end
    local function addRecordButtons(y)
        if onlineLeaderboardAvailable then
            local recordW = math.min(142 * s, (primaryW - 10 * s) * 0.5)
            add("records", "本地记录", nil, cx - recordW * 0.55,
                y, recordW, 48 * s)
            add("onlineLeaderboard", "排行榜", nil, cx + recordW * 0.55,
                y, recordW, 48 * s)
        else
            add("records", "本地记录", nil, cx, y,
                math.min(164 * s, primaryW), 48 * s)
        end
    end
    local hasEndlessCheckpoint = type(endlessCheckpoint) == "table"
    local endlessNextLayer = hasEndlessCheckpoint and tonumber(
        endlessCheckpoint.nextLayer or endlessCheckpoint.next_layer) or nil
    if type(challengeCheckpoint) == "table" then
        if Screens.newChallengeConfirmOpen then
            add("confirmStartNewChallenge", "确认开始新挑战", "将删除现有层间检查点",
                cx, h * 0.55, primaryW, 64 * s)
            add("cancelStartNewChallenge", "保留旧进度", nil,
                cx, h * 0.66, math.min(164 * s, primaryW), 48 * s)
        else
            local nextLayer = tonumber(challengeCheckpoint.nextLayer
                or challengeCheckpoint.next_layer) or 1
            local state = challengeCheckpoint.checkpointState
                or challengeCheckpoint.checkpoint_state
            local sub = state == "L10_CHOICE" and "返回第10层双出口"
                or string.format("从第 %d 层起点继续", nextLayer)
            add("continueChallenge", "继续挑战", sub, cx, h * 0.50, primaryW, 62 * s)
            add("startNewChallenge", "开始新挑战", "需再次确认",
                cx, h * 0.60, math.min(180 * s, primaryW), 46 * s)
            if hasGraduation then
                add("openGraduation", "无尽模式", "从L10毕业档开始L11",
                    cx, h * 0.69, primaryW, 52 * s)
            end
            if hasEndlessCheckpoint then
                add("continueEndless", "继续无尽",
                    string.format("从第 %d 层继续", endlessNextLayer or 11),
                    cx, h * 0.77, primaryW, 52 * s)
            end
            local recordY = hasEndlessCheckpoint and h * 0.84
                or (hasGraduation and h * 0.77 or h * 0.71)
            addRecordButtons(recordY)
        end
        local secondaryW = math.min(110 * s, (w - m.left - m.right - 40) / 3)
        local gap = 8 * s
        add("help", "操作说明", nil, cx - secondaryW - gap,
            h - m.bottom - 62 * s, secondaryW, 50 * s)
        add("privacy", "隐私说明", nil, cx,
            h - m.bottom - 62 * s, secondaryW, 50 * s)
        add("settings", "设置", nil, cx + secondaryW + gap,
            h - m.bottom - 62 * s, secondaryW, 50 * s)
        return btns
    end
    local startY = hasEndlessCheckpoint and h * 0.56
        or (hasGraduation and h * 0.50 or h * 0.55)
    if hasEndlessCheckpoint then
        add("continueEndless", "继续无尽",
            string.format("从第 %d 层继续", endlessNextLayer or 11), cx,
            h * 0.45, primaryW, 58 * s)
    end
    add("start", "开始行动", "从第1层开始挑战", cx, startY, primaryW, 64 * s)
    if hasGraduation then
        add("openGraduation", "无尽模式", "从L10毕业档开始L11",
            cx, hasEndlessCheckpoint and h * 0.66 or h * 0.61, primaryW, 56 * s)
    end
    addRecordButtons(hasEndlessCheckpoint and h * 0.76
        or (hasGraduation and h * 0.71 or h * 0.66))
    local secondaryW = math.min(110 * s, (w - m.left - m.right - 40) / 3)
    local gap = 8 * s
    add("help", "操作说明", nil, cx - secondaryW - gap,
        h - m.bottom - 62 * s, secondaryW, 50 * s)
    add("privacy", "隐私说明", nil, cx,
        h - m.bottom - 62 * s, secondaryW, 50 * s)
    add("settings", "设置", nil, cx + secondaryW + gap,
        h - m.bottom - 62 * s, secondaryW, 50 * s)
    return btns
end

-- 命中:返回按钮 id 或 nil
function Screens.hit(x, y, w, h, settings, privacyAccepted, onlineLeaderboardAvailable,
    challengeCheckpoint, graduationArchives, endlessCheckpoint)
    for _, b in ipairs(Screens.layout(w, h, settings, privacyAccepted,
        onlineLeaderboardAvailable, false, challengeCheckpoint, graduationArchives,
        endlessCheckpoint)) do
        if x >= b.x - b.w * 0.5 - 6 and x <= b.x + b.w * 0.5 + 6
            and y >= b.y - b.h * 0.5 - 6 and y <= b.y + b.h * 0.5 + 6 then
            return b.id
        end
    end
    return nil
end

-- 023C 首次教程 overlay 布局：上一步 / 下一步(末页=完成) / 跳过
-- 暂停菜单布局是绘制与命中唯一来源。无尽模式把“安全返回标题”和
-- “结束本次无尽”分开，后一项只能从确认态提交。
function Screens.pauseMenuLayout(w, h, endless, endlessEndConfirm)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    local bw = math.min(220 * s, m.safeW - 40)
    local bh = endless and 62 * s or 54 * s
    local gap = endless and 12 * s or 14 * s
    local y0 = endless and h * 0.31 or h * 0.36
    local btns = {}
    local function add(id, label, sub, y)
        btns[#btns + 1] = { id = id, label = label, x = cx, y = y,
            sub = sub, w = bw, h = bh, r = bh * 0.5, shape = "rect" }
    end
    if endlessEndConfirm == true then
        add("pauseEndlessConfirmCancel", "返回暂停菜单", "保留当前无尽进度",
            h * 0.46)
        add("pauseEndlessConfirmEnd", "确认结束本次无尽", "删除当前无尽进度，无法继续",
            h * 0.57)
        return btns
    end
    add("pauseResume", "继续", nil, y0)
    add("pauseSettings", "设置", nil, y0 + (bh + gap))
    if endless == true then
        add("pauseReturnEndless", "返回标题", "保留进度 · 可从本层起点继续",
            y0 + (bh + gap) * 2)
        add("pauseEndEndless", "结束本次无尽", "删除进度 · 需要确认",
            y0 + (bh + gap) * 3)
    else
        add("pauseQuit", "结束本局并返回标题", nil, y0 + (bh + gap) * 2)
    end
    return btns
end

function Screens.tutorialLayout(w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local cx = w * 0.5
    local btnW = math.min(150 * s, (w - m.left - m.right - 24) * 0.42)
    local btnH = 46 * s
    local y = h - m.bottom - 96 * s
    local Tutorial = require "Tutorial"
    local last = Tutorial.page >= #Tutorial.pages
    local btns = {}
    local function add(id, label, x, bw)
        btns[#btns + 1] = {
            id = id, label = label, sub = nil, x = x, y = y,
            w = bw, h = btnH, r = math.min(bw, btnH) * 0.5, shape = "rect",
        }
    end
    local gap = 10 * s
    local totalW = btnW * 3 + gap * 2
    local x0 = cx - totalW * 0.5 + btnW * 0.5
    add("tutorialPrev", "上一步", x0, btnW)
    add("tutorialSkip", "跳过", x0 + btnW + gap, btnW)
    add("tutorialNext", last and "完成" or "下一步", x0 + (btnW + gap) * 2, btnW)
    return btns
end

function Screens.tutorialHit(x, y, w, h)
    for _, b in ipairs(Screens.tutorialLayout(w, h)) do
        if x >= b.x - b.w * 0.5 - 6 and x <= b.x + b.w * 0.5 + 6
            and y >= b.y - b.h * 0.5 - 6 and y <= b.y + b.h * 0.5 + 6 then
            return b.id
        end
    end
    return nil
end

function Screens.beginOnlineLeaderboardLoad(now)
    Screens.onlineLeaderboardRequestId = Screens.onlineLeaderboardRequestId + 1
    Screens.onlineLeaderboardOpen = true
    Screens.onlineLeaderboardState = "loading"
    Screens.onlineLeaderboardEntries = {}
    Screens.myRank = nil
    Screens.myRankScore = nil
    Screens.leaderboardPage = 1
    Screens.onlineLeaderboardErrorMessage = nil
    Screens.onlineLeaderboardDeadline = (tonumber(now) or os.time())
        + Screens.LEADERBOARD_LOAD_TIMEOUT_SECONDS
    return Screens.onlineLeaderboardRequestId
end

function Screens.isOnlineLeaderboardRequestCurrent(requestId)
    return Screens.onlineLeaderboardOpen == true
        and requestId == Screens.onlineLeaderboardRequestId
end

function Screens.setOnlineLeaderboardEntries(entries, requestId)
    if requestId ~= nil and not Screens.isOnlineLeaderboardRequestCurrent(requestId) then
        return false
    end
    Screens.onlineLeaderboardEntries = type(entries) == "table" and entries or {}
    Screens.onlineLeaderboardState = "ready"
    Screens.leaderboardPage = 1
    Screens.onlineLeaderboardDeadline = nil
    Screens.onlineLeaderboardErrorMessage = nil
    return true
end

function Screens.setMyRank(rank, scoreValue)
    local numericRank = tonumber(rank)
    local numericScore = tonumber(scoreValue)
    local valid = numericRank and numericRank >= 1
        and numericScore and numericScore > 0
    Screens.myRank = valid and numericRank or nil
    Screens.myRankScore = valid and numericScore or nil
end

function Screens.setOnlineLeaderboardError(message, requestId)
    if requestId ~= nil and not Screens.isOnlineLeaderboardRequestCurrent(requestId) then
        return false
    end
    Screens.onlineLeaderboardEntries = {}
    Screens.onlineLeaderboardState = "error"
    Screens.leaderboardPage = 1
    Screens.onlineLeaderboardDeadline = nil
    Screens.onlineLeaderboardErrorMessage = message or "暂时无法读取公开榜，请重试"
    return true
end

function Screens.tickOnlineLeaderboardLoad(now)
    if Screens.onlineLeaderboardOpen ~= true
        or Screens.onlineLeaderboardState ~= "loading"
        or type(Screens.onlineLeaderboardDeadline) ~= "number"
        or (tonumber(now) or os.time()) < Screens.onlineLeaderboardDeadline then
        return false
    end
    Screens.onlineLeaderboardRequestId = Screens.onlineLeaderboardRequestId + 1
    Screens.onlineLeaderboardEntries = {}
    Screens.onlineLeaderboardState = "error"
    Screens.leaderboardPage = 1
    Screens.onlineLeaderboardDeadline = nil
    Screens.onlineLeaderboardErrorMessage = "读取超时，请重试"
    return true
end

function Screens.closeOnlineLeaderboard()
    Screens.onlineLeaderboardRequestId = Screens.onlineLeaderboardRequestId + 1
    Screens.onlineLeaderboardOpen = false
    Screens.onlineLeaderboardState = "idle"
    Screens.onlineLeaderboardEntries = {}
    Screens.myRank = nil
    Screens.myRankScore = nil
    Screens.leaderboardPage = 1
    Screens.onlineLeaderboardDeadline = nil
    Screens.onlineLeaderboardErrorMessage = nil
end

-- 操作说明文案(Render 绘制)
Screens.HELP_LINES = {
    "【目标】完成第10层通关挑战",
    "  也可选择继续无尽闯关",
    "【移动】左半屏拖动",
    "  桌面使用WASD或方向键",
    "【过载】自动连锁清敌",
    "  空格脉冲，K键崩解",
    "  最后5秒完成目标有额外分",
    "【枯竭】绕开敌人视野",
    "  搜储能、拆残骸、标记目标",
    "  1干扰 2诱饵 3隐身 E拆解",
    "  Q侦察，长按Q标记",
    "【满能】可立即重启",
    "  也可继续诱敌积累风险分",
    "【重启】读条0.7秒，不可取消",
    "  读条时仍会受到伤害",
    "【流程】第N层枯竭 → 重启读条",
    "  → 本层反猎 → 层结算 → 协议整备",
    "  确认整备后才进入第N+1层过载",
    "【反猎】重启后是本层结尾",
    "  追兵变成反猎目标，10秒窗口",
    "  连续反猎奖励500 / 1,000 / 2,000",
    "  后续封顶2,000 · 每层重置",
    "  全部清算或窗口结束进入结算",
    "【整备】每层结算后可升级",
    "  残骸数据换过载协议冷却",
    "  黄色核心换枯竭工具次数",
    "  资源可保存到下一层",
    "【资源】拆普通残骸得残骸数据",
    "  地图核心与深层残骸得黄色核心",
    "【地图】第4层进入防火墙核心",
    "  扫描区可用掩体、隐身或干扰规避",
    "【协议】集群/封锁/深层缓存",
    "  改变敌群、路线与风险收益",
    "【热度】追踪档守卫开始巡逻",
    "  锁定档满能后会补充猎杀者",
    "  隐身、诱饵、干扰和墙体可摆脱",
    "【风险】只在重启成功后入账",
    "  重启前死亡会丢失全部风险分",
    "【无尽】第11层起热度只降一档",
}

Screens.PRIVACY_LINES = {
    "【首次进入】请先阅读并确认本说明",
    "  同意后继续游戏并启用在线功能",
    "【本地记录】优先保存在当前设备",
    "  用于保留最高完成层、分数、连杀",
    "  最近10局记录以及游戏设置",
    "【云端同步】仅在你同意之后",
    "  登录后会在服务可用时自动同步",
    "【数据分析】本版本不上传试玩分析数据",
    "  正常游玩不主动上传运行日志",
    "  主动提交反馈时可能附带诊断信息",
    "【奖励复活】仅在你同意后、点击观看时调用",
    "  普通关：本局不限次数；无尽：本局共3次",
    "  广告前可选：满血安全复活 / 回到本层开始 / 取消",
    "  安全复活保留算力、热度、分数与敌人状态",
    "  完整观看并获得奖励后才会复活",
    "  关闭或失败不会消耗复活次数",
    "  普通关仍可免费本层从头开始",
    "【排行榜】完成第10层即可参与最高层挑战榜",
    "  榜单按已完成层数优先、同层比较分数",
    "【TapTap账号】同意后可读取昵称与账号标识",
    "  用于云同步、本人记录和公共榜展示",
    "  不读取头像、好友关系或广告标识",
    "【设备能力】只按设置播放音频",
    "  并在支持时请求短震动",
    "  拒绝震动不影响完整游玩",
    "【不收集】位置、通讯录、相册",
    "  相机、麦克风等无关信息",
    "【网络】核心流程可离线使用",
    "【删除】清除本地数据可移除本地记录",
    "  云端记录可通过游戏页反馈联系处理",
    "【变更】隐私说明有重要变化时",
    "  会重新请求你的明确选择",
    "【TapTap服务】相关数据处理同时遵循TapTap规则",
    "【联系】通过游戏页开发者反馈",
    "  联系《过载余波》项目方",
}

function Screens.documentLines()
    return Screens.privacyOpen and Screens.PRIVACY_LINES or Screens.HELP_LINES
end

function Screens.pageCount()
    return math.max(1, math.ceil(#Screens.documentLines() / Screens.PAGE_SIZE))
end

function Screens.changePage(delta)
    local count = Screens.pageCount()
    Screens.page = ((Screens.page - 1 + delta) % count) + 1
end

function Screens.visibleDocumentLines()
    local lines = Screens.documentLines()
    local count = Screens.pageCount()
    Screens.page = math.max(1, math.min(count, Screens.page))
    local first = (Screens.page - 1) * Screens.PAGE_SIZE + 1
    local out = {}
    for i = first, math.min(#lines, first + Screens.PAGE_SIZE - 1) do
        out[#out + 1] = lines[i]
    end
    return out, Screens.page, count
end

function Screens.recordPageCount(best)
    return math.max(1, math.ceil(#(best.recentRuns or {}) / 5))
end

function Screens.changeRecordPage(delta, best)
    local count = Screens.recordPageCount(best)
    Screens.recordPage = ((Screens.recordPage - 1 + delta) % count) + 1
end

function Screens.visibleRuns(best)
    local runs = best.recentRuns or {}
    local count = Screens.recordPageCount(best)
    Screens.recordPage = math.max(1, math.min(count, Screens.recordPage))
    local out = {}
    local newestIndex = #runs - (Screens.recordPage - 1) * 5
    for i = newestIndex, math.max(1, newestIndex - 4), -1 do out[#out + 1] = runs[i] end
    return out, Screens.recordPage, count
end

-- 在线榜只请求一批公开成绩，页面在这批结果内提供稳定的表格分页。
-- 不改变平台提交/查询合同，也不伪造空榜排名。
function Screens.leaderboardPageCount(entries)
    local entryCount = #(type(entries) == "table" and entries or {})
    entryCount = math.min(entryCount, Screens.LEADERBOARD_MAX_RESULTS)
    return math.max(1, math.ceil(entryCount / Screens.LEADERBOARD_PAGE_SIZE))
end

function Screens.changeLeaderboardPage(delta, entries)
    local count = Screens.leaderboardPageCount(entries or Screens.onlineLeaderboardEntries)
    Screens.leaderboardPage = math.max(1, math.min(count,
        Screens.leaderboardPage + (tonumber(delta) or 0)))
end

function Screens.visibleLeaderboardEntries(entries)
    entries = type(entries) == "table" and entries or {}
    local count = Screens.leaderboardPageCount(entries)
    Screens.leaderboardPage = math.max(1, math.min(count, Screens.leaderboardPage))
    local first = (Screens.leaderboardPage - 1) * Screens.LEADERBOARD_PAGE_SIZE + 1
    local out = {}
    local visibleCount = math.min(#entries, Screens.LEADERBOARD_MAX_RESULTS)
    for i = first, math.min(visibleCount, first + Screens.LEADERBOARD_PAGE_SIZE - 1) do
        out[#out + 1] = entries[i]
    end
    return out, Screens.leaderboardPage, count
end

return Screens
