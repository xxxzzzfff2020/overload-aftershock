-- InputSys.lua
-- 移动端操作(§13/§任务包B):左侧浮动虚拟摇杆 + 右侧阶段按钮 + 上下文按钮。
-- [R1] 多点触控:每个触点独立绑定用途(摇杆触点 / 按钮触点),互不干扰;
--      阶段切换清理不再合法的输入;禁用按钮点击给出失败原因;布局走安全区。
-- 桌面预览:WASD/方向键移动,快捷键触发按钮。
-- 布局函数与 Render 共享,保证绘制与命中一致。

local Config = require "Config"
local Screens = require "Screens"
local Util = require "Util"
local Viewport = require "Viewport"
local EndlessOverclock = require "EndlessOverclock"

local InputSys = {}

InputSys.touches = {}       -- id -> {x, y, role="stick"|"button"|"none", buttonId}
InputSys.stick = { active = false, id = nil, cx = 0, cy = 0, dx = 0, dy = 0 }
InputSys.pressed = {}       -- 本帧按下的按钮 id -> true
InputSys.held = {}          -- 正被触点按住的按钮 id -> true(渲染按下反馈)
InputSys.keyMove = { up = false, down = false, left = false, right = false }
InputSys.scanKey = { held = false, time = 0, fired = false }

InputSys.STICK_RADIUS = 64
local STICK_RADIUS = InputSys.STICK_RADIUS

-- 广告失败/取消后的确认按钮与 Render 的全屏模态共用同一安全区锚点，
-- 避免窄屏设备上按钮落入死页统计区或被底部安全区裁切。
function InputSys.rewardedModalActionY(w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    return Util.clamp(h * 0.70, m.top + 260 * s, h - m.bottom - 46 * s)
end

-- 死亡结算的统计卡与主操作组共享这一套锚点，避免小屏上“观看广告复活”
-- 压住生存时间等底部统计。三枚行动按钮从下向上紧凑排列，绘制和命中区
-- 均由同一输入布局消费；不改变任何复活、重试或广告语义。
function InputSys.deathLayoutMetrics(w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local bottom = h - m.bottom
    local gap = 12 * s
    local tertiaryH = 50 * s
    local secondaryH = 54 * s
    local primaryH = 58 * s
    local tertiaryY = bottom - 16 * s - tertiaryH * 0.5
    local secondaryY = tertiaryY - tertiaryH * 0.5 - gap - secondaryH * 0.5
    local primaryY = secondaryY - secondaryH * 0.5 - gap - primaryH * 0.5
    local actionTop = primaryY - primaryH * 0.5
    local panelGap = 26 * s
    local panelTopFloor = m.top + 10 * s
    local panelH = math.min(430, math.max(280, actionTop - panelTopFloor - panelGap))
    local panelY = math.max(panelTopFloor, actionTop - panelH - panelGap)
    return {
        primaryY = primaryY,
        secondaryY = secondaryY,
        tertiaryY = tertiaryY,
        panelY = panelY,
        panelH = panelH,
        actionTop = actionTop,
        panelGap = panelGap,
    }
end

-- ============================================================
-- 按钮布局(逻辑像素)。返回数组:{ id, label, sub, x, y, r, enabled, reason }
-- reason:禁用时点击给出的原因文案(§6.3 不允许静默无响应)
-- ============================================================
function InputSys.layout(world, w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local btns = {}
    -- 暂停菜单覆盖战斗/结算输入；main 只通过 world.pauseMenu 投影该模态。
    if world and world.pauseMenu then
        -- 暂停中打开设置：与标题页同布局，隐藏教程与隐私入口。
        if Screens.settingsOpen then
            local settingsLayout = Screens.layout(w, h, world.pauseSettings or {},
                world.pausePrivacyAccepted == true, false, true)
            for _, b in ipairs(settingsLayout) do
                -- Screens 标题页按钮默认没有 enabled 字段；暂停输入层必须把
                -- nil 解释为可用，否则按钮会“看得见但永远不触发”。
                b.enabled = b.enabled ~= false
                btns[#btns + 1] = b
            end
            return btns
        end
        -- 反馈 #18704/#18705：暂停页绘制与触控以前各自维护一套布局，
        -- 一旦菜单扩展就可能出现“看得见但点不到”或相反。始终复用
        -- Screens 的单一布局来源。
        local pauseLayout = Screens.pauseMenuLayout(w, h, world.endless == true,
            Screens.endlessEndConfirmOpen == true)
        for _, b in ipairs(pauseLayout) do
            b.enabled = true
            btns[#btns + 1] = b
        end
        return btns
    end
    local function add(id, label, sub, x, y, r, enabled, reason)
        btns[#btns + 1] = { id = id, label = label, sub = sub, x = x, y = y, r = r,
            enabled = enabled ~= false, reason = reason }
    end
    local right = w - m.right
    local bottom = h - m.bottom
    -- 过载/反猎右下操作区沿用既有双键布局；按钮随移动端密度放大并保持安全区内。
    local bx, by = right - 64 * s, bottom - 82 * s      -- 主按钮位
    local sx, sy = right - 160 * s, bottom - 66 * s     -- 左下

    if world.phase == "overload" or world.phase == "anti_hunt" then
        -- 反猎窗口沿用过载操作区：脉冲与崩解，玩家不需要重新学一套按钮。
        add("pulse", "脉冲", world.pulseCd > 0 and string.format("%.0f", math.ceil(world.pulseCd)) or nil,
            bx, by, 43 * s, world.pulseCd <= 0,
            string.format("脉冲冷却中 %.0f 秒", math.ceil(world.pulseCd)))
        add("collapse", "崩解", world.collapseCd > 0 and string.format("%.0f", math.ceil(world.collapseCd)) or nil,
            sx, sy, 32 * s, world.collapseCd <= 0,
            string.format("崩解冷却中 %.0f 秒", math.ceil(world.collapseCd)))
    elseif world.phase == "layer_intro" or world.phase == "layer_settlement" then
        -- 启动观察倒计时与层结算都不接受战斗输入；整备按钮另由 RunShop 提供。
        return btns
    elseif world.phase == "depleted" then
        -- 037: 枯竭阶段采用紧凑右下半环。重启作为最低主键，四个辅助工具
        -- 环绕其上方/左侧；保留原按钮半径与命中扩张，只收紧中心间距，
        -- 避免五键纵向侵入战场中部。Render消费同一布局，画面与触控同步。
        local restartX, restartY = right - 59 * s, bottom - 53 * s
        -- 044R: 四个辅助工具收成紧凑上拱。侦察/诱饵承担上沿，隐身
        -- 右移、干扰下移；重启仍是最低主锚点。绘制与命中继续共享此布局。
        local jammerX, jammerY = right - 145 * s, bottom - 57 * s
        local scanX, scanY = right - 160 * s, bottom - 129 * s
        local decoyX, decoyY = right - 104 * s, bottom - 156 * s
        local cloakX, cloakY = right - 35 * s, bottom - 136 * s
        local chargeSub = nil
        if world.restartChannel then
            chargeSub = string.format("%.0f%%",
                world.restartChannel.t / Config.FORMAL.restartChannelTime * 100)
        else
            chargeSub = world.energy .. "/" .. world.energyNeed
        end
        add("restart", world.restartChannel and "重启中" or "重启", chargeSub,
            restartX, restartY, 43 * s, world.energy >= world.energyNeed,
            "储能不足,还差 " .. math.max(0, world.energyNeed - world.energy))
        add("jammer", "干扰", "x" .. world.tools.jammer, jammerX, jammerY, 30 * s,
            world.tools.jammer > 0, "干扰弹已用完")
        add("decoy", "诱饵", "x" .. world.tools.decoy, decoyX, decoyY, 30 * s,
            world.tools.decoy > 0, "诱饵信标已用完")
        add("cloak", "隐身", "x" .. world.tools.cloak, cloakX, cloakY, 30 * s,
            world.tools.cloak > 0 and world.cloakLeft <= 0,
            world.cloakLeft > 0 and "隐身进行中" or "光学隐身已用完")
        -- 上下文按钮(靠近才出现)：固定在隐身正上方，保持同一操作列，
        -- 不再作为远离主操作群的离群第六键。
        if world:nearestWreck() and not world.dismantle then
            add("dismantle", "拆解", nil, cloakX, bottom - 211 * s, 32 * s, true)
        end
        local markTarget = world:findMarkTarget()
        if world.exp.recon then
            local sub = markTarget and "长按标记" or (world.reconCd > 0
                and string.format("%.0f", math.ceil(world.reconCd)) or "短按")
            add("scan", "侦察", sub, scanX, scanY, 30 * s,
                markTarget ~= nil or world.reconCd <= 0,
                string.format("侦察冷却中 %.0f 秒", math.ceil(math.max(0, world.reconCd))))
        elseif markTarget then
            add("mark", "标记", nil, scanX, scanY, 30 * s, true)
        end
    elseif world.phase == "dead" then
        -- 结算按钮使用矩形点击区,主次层级由 Render 统一绘制。
        local deathLayout = InputSys.deathLayoutMetrics(w, h)
        local checkpointAvailable = false
        pcall(function() checkpointAvailable = world.challengeCheckpointAvailable == true end)
        local adPending = false
        pcall(function() adPending = world.rewardedReviveState == "pending" end)
        -- Some headless layout probes provide a minimal world table rather
        -- than a full World instance.  Treat optional revive fields as absent
        -- instead of indexing a missing userdata/table key.
        local reviveTimeout = false
        local reviveSoftTimeout = false
        local failureNotice = nil
        local reviveOffer = false
        local endlessRun = false
        local rewardedReviveCount = 0
        local choice = nil
        pcall(function()
            reviveTimeout = world.rewardedReviveTimeout == true
            reviveSoftTimeout = world.rewardedReviveSoftTimeout == true
            failureNotice = world.rewardedReviveFailureNotice
            reviveOffer = world.reviveOffer == true
            endlessRun = world.endless == true
            rewardedReviveCount = math.max(0,
                math.floor(tonumber(world.rewardedReviveCount) or 0))
            choice = world.reviveChoiceState
        end)
        local endlessLimit = math.max(0,
            math.floor(tonumber(Config.PLATFORM.rewardedRevive.endlessPerRunLimit) or 3))
        local endlessRemaining = math.max(0, endlessLimit - rewardedReviveCount)
        local reviveCountText = endlessRun
            and string.format("本局剩余 %d/%d 次", endlessRemaining, endlessLimit)
            or "普通模式不限次数"
        local function rect(id, label, sub, y, width, height)
            width, height = width or 270 * s, height or 54 * s
            btns[#btns + 1] = {
                id = id, label = label, sub = sub,
                x = w * 0.5, y = y, w = width, h = height,
                r = height * 0.5, enabled = true,
            }
        end
        if adPending then
            -- 常规等待保持独占交互。15 秒软超时时才提供两个明确动作：
            -- 继续等待不改变当前请求；确认返回由 main 使本地 token 失效。
            if reviveSoftTimeout then
                local actionY = InputSys.rewardedModalActionY(w, h)
                rect("adSoftContinue", "继续等待", "广告可能仍在播放，继续等待结果",
                    actionY - 36 * s, 286 * s, 52 * s)
                rect("adSoftCancel", "确认返回", "本次不发放复活，不消耗次数",
                    actionY + 36 * s, 286 * s, 52 * s)
            end
        elseif type(failureNotice) == "table" then
            rect("adFailureClose", "确认返回", "返回复活选择",
                InputSys.rewardedModalActionY(w, h), 270 * s, 56 * s)
        elseif reviveTimeout then
            rect("adTimeoutClose", "确认返回", "广告未返回结果，本次未发放复活",
                bottom - 80 * s, 270 * s, 56 * s)
        elseif choice == "select" then
            rect("reviveInPlace", "满血安全复活",
                "传送安全区 · 保留当前状态 · 道具不补充", bottom - 244 * s, 320 * s, 58 * s)
            if not endlessRun then
                rect("reviveFullState", "回到本层开始",
                    "观看广告 · 初始潜行 · 重置本层进度", bottom - 174 * s, 320 * s, 58 * s)
            end
            rect("reviveCancel", "取消", reviveCountText, bottom - 104 * s, 220 * s, 50 * s)
        elseif choice == "confirm_in_place" then
            rect("confirmReviveInPlace", "确认安全复活",
                "观看广告 · 满血传送到安全区", bottom - 174 * s, 320 * s, 60 * s)
            rect("cancelReviveConfirm", "返回选择", "不播放广告", bottom - 94 * s, 220 * s, 50 * s)
        elseif choice == "confirm_full_state" then
            rect("confirmReviveFullState", "确认回到本层开始",
                "观看广告 · 初始潜行 · 重置本层进度", bottom - 174 * s, 320 * s, 60 * s)
            rect("cancelReviveConfirm", "返回选择", "不播放广告", bottom - 94 * s, 220 * s, 50 * s)
        elseif reviveOffer and Config.PLATFORM.rewardedAd == true then
            rect("revive", "观看广告复活", reviveCountText .. " · 先选择方式",
                deathLayout.primaryY, 300 * s, 58 * s)
            if checkpointAvailable and not endlessRun
                and (world.round or 0) <= Config.RUN.finalLayer then
                rect("retryLayer", "本层从头开始", "免费 · 放弃本层进度",
                    deathLayout.secondaryY, 250 * s, 54 * s)
                rect("endChallenge", "结束挑战", nil,
                    deathLayout.tertiaryY, 210 * s, 50 * s)
            else
                rect("again", "再来一局", nil,
                    deathLayout.secondaryY, 210 * s, 54 * s)
                rect("title", "返回标题", nil,
                    deathLayout.tertiaryY, 210 * s, 50 * s)
            end
        elseif checkpointAvailable and not endlessRun
            and (world.round or 0) <= Config.RUN.finalLayer then
            rect("retryLayer", "本层从头开始", "免费 · 放弃本层进度",
                deathLayout.secondaryY, 250 * s, 54 * s)
            rect("endChallenge", "结束挑战", nil,
                deathLayout.tertiaryY, 210 * s, 50 * s)
        else
            rect("again", "再来一局", nil,
                deathLayout.secondaryY, 210 * s, 54 * s)
            rect("title", "返回标题", nil,
                deathLayout.tertiaryY, 210 * s, 50 * s)
        end
    end
    -- 024C: 局内暂停按钮(战斗 HUD 右上,清晰但不抢眼;模态界面不显示)
    if world.pauseMenu ~= true and (world.phase == "overload" or world.phase == "anti_hunt"
        or world.phase == "depleted") then
        btns[#btns + 1] = {
            id = "pause", label = "II", sub = nil,
            x = w - m.right - 24 * s, y = m.battle.y + 24 * s, r = 16 * s,
            enabled = true,
        }
    end
    return btns
end

-- ============================================================
-- 事件接入(由 main 订阅后转发,坐标为逻辑像素)
-- ============================================================
local function findButton(world, x, y, w, h)
    for _, b in ipairs(InputSys.layout(world, w, h)) do
        if b.w and b.h then
            if x >= b.x - b.w * 0.5 and x <= b.x + b.w * 0.5
                and y >= b.y - b.h * 0.5 and y <= b.y + b.h * 0.5 then
                return b
            end
        elseif Util.dist(x, y, b.x, b.y) <= b.r + 8 then
            return b
        end
    end
    return nil
end

function InputSys.onPointerDown(world, id, x, y, w, h)
    -- 同 id 重复按下(异常序列):先按抬起处理,防旧绑定残留
    if InputSys.touches[id] then InputSys.onPointerUp(world, id) end
    local t = { x = x, y = y, role = "none", idle = 0 }
    InputSys.touches[id] = t
    -- 暂停是最上层模态。即使暂停恰好发生在结算/超限选择时，
    -- 也必须先消费暂停设置按钮，不能被底层商店命中测试截走。
    if world and world.pauseMenu == true then
        local b = findButton(world, x, y, w, h)
        if b then
            t.role = "button"
            t.buttonId = b.id
            if b.enabled then
                InputSys.pressed[b.id] = true
                InputSys.held[b.id] = true
            elseif world.feedback and b.reason then
                world:feedback(b.reason)
            end
        end
        return
    end
    -- 协议整备界面独占输入。卡片和底部按钮都采用“按下候选、抬起提交”；
    -- pointer-down 不产生购买，保证手指开始滚动时不会误扣资源。
    if world.overclockChoiceOpen == true
        or world.phase == "layer_settlement" then
        local RunShop = require "RunShop"
        local action = EndlessOverclock.hit(world, x, y, w, h)
            or (world.phase == "layer_settlement" and RunShop.hit(world, x, y, w, h))
        t.role = "shop"
        t.buttonId = action
        t.downX, t.downY = x, y
        t.lastY = y
        t.viewW, t.viewH = w, h
        t.dragging = false
        if action then InputSys.held[action] = true end
        return
    end
    if world.phase == "layer_intro" then return end
    local b = findButton(world, x, y, w, h)
    if b then
        t.role = "button"
        t.buttonId = b.id
        if b.enabled then
            if b.id ~= "scan" then InputSys.pressed[b.id] = true end
            InputSys.held[b.id] = true
        elseif world and world.feedback and b.reason then
            world:feedback(b.reason)   -- 禁用按钮:给出原因(§6.3)
        end
        return
    end
    -- 左半屏按下 → 浮动摇杆(每次只绑定一个摇杆触点)
    local s = InputSys.stick
    if not s.active and x < w * 0.55 and Viewport.containsBattlePoint(x, y, w, h) then
        t.role = "stick"
        s.active = true
        s.id = id
        s.cx, s.cy = x, y
        s.dx, s.dy = 0, 0
    end
end

function InputSys.onPointerMove(world, id, x, y)
    local t = InputSys.touches[id]
    if not t then return end
    t.x, t.y = x, y
    t.idle = 0
    if t.role == "shop" then
        local dx, dy = x - (t.downX or x), y - (t.downY or y)
        if not t.dragging and dx * dx + dy * dy > 10 * 10 then
            t.dragging = true
            if t.buttonId then InputSys.held[t.buttonId] = nil end
            t.buttonId = nil
        end
        if t.dragging and world and world.phase == "layer_settlement" then
            local RunShop = require "RunShop"
            RunShop.scrollBy(world, (t.lastY or y) - y, t.viewW, t.viewH)
        end
        t.lastY = y
        return
    end
    if t.role == "stick" then
        local s = InputSys.stick
        if s.active and s.id == id then
            local dx, dy = x - s.cx, y - s.cy
            local _, _, len = Util.norm(dx, dy)
            if len > STICK_RADIUS then
                dx, dy = dx / len * STICK_RADIUS, dy / len * STICK_RADIUS
            end
            s.dx, s.dy = dx, dy
        end
    end
    -- 按钮触点滑出按钮不取消本次 press(press 已在按下帧生效),只清 held 反馈
end

function InputSys.onPointerUp(world, id)
    local t = InputSys.touches[id]
    InputSys.touches[id] = nil
    if not t then return end
    if t.role == "shop" then
        if t.buttonId then InputSys.held[t.buttonId] = nil end
        if not t.dragging and t.buttonId and world
            and (world.phase == "layer_settlement" or world.overclockChoiceOpen == true) then
            local RunShop = require "RunShop"
            local action = EndlessOverclock.hit(world, t.x, t.y, t.viewW, t.viewH)
                or (world.phase == "layer_settlement"
                    and RunShop.hit(world, t.x, t.y, t.viewW, t.viewH))
            if action == t.buttonId then
                if action == "confirm" then
                    InputSys.pressed.shopConfirm = true
                elseif action == "complete" then
                    InputSys.pressed.shopComplete = true
                else
                    InputSys.pressed[action] = true
                end
            end
        end
    elseif t.role == "stick" then
        local s = InputSys.stick
        if s.id == id then
            s.active = false
            s.id = nil
            s.dx, s.dy = 0, 0
        end
    elseif t.role == "button" and t.buttonId then
        -- 侦察短按在抬起时生效；离开枯竭阶段后残留触点不得再触发。
        if t.buttonId == "scan" and not t.scanFired
            and world and world.phase == "depleted" then
            InputSys.pressed.recon = true
        end
        InputSys.held[t.buttonId] = nil
    end
end

-- [R2] 触点超时回收(§14.1:引擎无 touch-cancel 事件时的兜底;
-- 来电/系统中断丢失 TouchEnd 的触点在超时后自动抬起,恢复后需重新按下)
function InputSys.tick(world, dt)
    local timeout = Config.INPUT.touchTimeout
    local stale = nil
    -- 长按标记只在枯竭阶段有意义；其它阶段不查询标记目标。
    local markPhase = world.phase == "depleted"
    for id, t in pairs(InputSys.touches) do
        t.idle = (t.idle or 0) + dt
        if markPhase and t.role == "button" and t.buttonId == "scan" and not t.scanFired then
            t.hold = (t.hold or 0) + dt
            if t.hold >= Config.RECON.markHold and world:findMarkTarget() then
                t.scanFired = true
                InputSys.pressed.mark = true
            end
        end
        if t.idle > timeout then
            stale = stale or {}
            stale[#stale + 1] = id
        end
    end
    if stale then
        for _, id in ipairs(stale) do
            local t = InputSys.touches[id]
            if t and t.role == "shop" then t.dragging = true end
            InputSys.onPointerUp(world, id)
        end
    end
    local sk = InputSys.scanKey
    if markPhase and sk.held and not sk.fired then
        sk.time = sk.time + dt
        if sk.time >= Config.RECON.markHold and world:findMarkTarget() then
            sk.fired = true
            InputSys.pressed.mark = true
        end
    end
end

-- 系统取消触摸 / 窗口失焦:清空全部触点(§6.2)
function InputSys.onCancel()
    InputSys.touches = {}
    InputSys.stick.active = false
    InputSys.stick.id = nil
    InputSys.stick.dx, InputSys.stick.dy = 0, 0
    InputSys.held = {}
    InputSys.pressed = {}
    InputSys.keyMove = { up = false, down = false, left = false, right = false }
    InputSys.scanKey = { held = false, time = 0, fired = false }
end

-- 阶段切换:清理不再合法的输入(§6.2)。
-- 保留摇杆(两个阶段移动都合法),清掉待处理按钮与按住状态(旧阶段按钮已不存在)。
function InputSys.onPhaseChange()
    InputSys.pressed = {}
    InputSys.held = {}
    InputSys.scanKey = { held = false, time = 0, fired = false }
    for id, t in pairs(InputSys.touches) do
        if t.role == "button" or t.role == "shop" then InputSys.touches[id] = nil end
    end
end

-- 键盘(桌面预览)
function InputSys.onKey(world, key, down)
    if world.overclockChoiceOpen == true then
        if down and (key == KEY_1 or key == KEY_2 or key == KEY_3) then
            InputSys.pressed["overclock:" .. tostring(key == KEY_1 and 1 or key == KEY_2 and 2 or 3)] = true
        end
        return
    end
    if world.phase == "layer_intro" then
        if not down and key == KEY_Q then
            InputSys.scanKey = { held = false, time = 0, fired = false }
        end
        return
    end
    local km = InputSys.keyMove
    if key == KEY_W or key == KEY_UP then km.up = down
    elseif key == KEY_S or key == KEY_DOWN then km.down = down
    elseif key == KEY_A or key == KEY_LEFT then km.left = down
    elseif key == KEY_D or key == KEY_RIGHT then km.right = down
    end
    if not down then
        if key == KEY_Q and InputSys.scanKey.held then
            if not InputSys.scanKey.fired then InputSys.pressed.recon = true end
            InputSys.scanKey = { held = false, time = 0, fired = false }
        end
        return
    end
    local P = InputSys.pressed
    if key == KEY_SPACE then
        if world.phase == "overload" or world.phase == "anti_hunt" then P.pulse = true
        elseif world.phase == "depleted" then P.restart = true
        elseif world.phase == "layer_settlement" then P.shopConfirm = true
        elseif world.phase == "dead" then P.again = true end
    elseif key == KEY_K then P.collapse = true
    elseif key == KEY_1 then P.jammer = true
    elseif key == KEY_2 then P.decoy = true
    elseif key == KEY_3 then P.cloak = true
    elseif key == KEY_E then P.dismantle = true
    elseif key == KEY_Q then
        if world.phase == "depleted" and world.exp.recon then
            InputSys.scanKey = { held = true, time = 0, fired = false }
        else
            P.mark = true
        end
    elseif key == KEY_R then P.again = true
    end
end

-- ============================================================
-- 汇总本帧输入(main 每帧调用,取完即清 pressed)
-- ============================================================
function InputSys.collect()
    local s = InputSys.stick
    local mx, my = 0, 0
    if s.active then
        mx, my = s.dx / STICK_RADIUS, s.dy / STICK_RADIUS
    end
    local km = InputSys.keyMove
    if km.up then my = my - 1 end
    if km.down then my = my + 1 end
    if km.left then mx = mx - 1 end
    if km.right then mx = mx + 1 end
    local pressed = InputSys.pressed
    InputSys.pressed = {}
    return { moveX = mx, moveY = my, pressed = pressed }
end

function InputSys.reset()
    InputSys.touches = {}
    InputSys.stick.active = false
    InputSys.stick.id = nil
    InputSys.stick.dx, InputSys.stick.dy = 0, 0
    InputSys.pressed = {}
    InputSys.held = {}
    InputSys.keyMove = { up = false, down = false, left = false, right = false }
    InputSys.scanKey = { held = false, time = 0, fired = false }
end

return InputSys
