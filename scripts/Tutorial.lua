-- Tutorial.lua
-- 023C 首次教程生命周期：
--   - 仅新档(本地存档 tutorial_completed=false)第一次点击"开始游戏"时全屏显示；
--   - 完成/跳过立即持久化 tutorial_completed=true（第二局、刷新、重进均不重复）；
--   - 清除本地存档后重新出现；隐私拒绝不影响教程与完整单机；
--   - 设置页"查看教程"手动重看，不修改已完成状态；
--   - Debug/Review/Bot/QA 入口不得修改正式教程状态。
-- 视觉原则：每页一个核心阶段、图形优先、短文案、390x867 可读（最多4页）。

local Config = require "Config"
local Util = require "Util"

local Tutorial = {}

-- 首次教程 overlay 状态（由 main 驱动显示/隐藏）
Tutorial.active = false          -- 是否处于教程 overlay
Tutorial.page = 1                -- 当前页 1..n
Tutorial.pages = {}              -- 当前页数据（来自 Config.TUTORIAL.overlayPages）
Tutorial.doneForever = false     -- 正式教程已完成标记（镜像 best.tutorialDone）
Tutorial.debugIgnore = false     -- Debug/Review/Bot 局期间置 true：不读也不改正式状态
Tutorial.overlaySource = "none" -- "first_run" | "settings" | "none"

-- 轻量情境提示（保留既有机制，供局内使用；与首次教程互不干扰）
local HINTS = {
    intro = "左侧拖动移动 · 过载自动连锁",
    lastSeconds = "即将断电 · 提前寻找安全路线",
    firstDrop = "绕开视野 · 搜集绿色储能",
    firstWreck = "靠近残骸后按住拆解",
    energyReady = "可立即重启 · 或继续冒险",
    firstCore = "数据核心可用于下一轮强化",
    firstMark = "标记将在下一轮首次命中时引爆",
    lure = "满能后可继续诱敌 · 重启反猎可爆分",
    antiHunt = "本层结尾 · 在窗口内清算反猎目标",
    settlement = "层结算 · 用残骸数据和核心整备协议",
    relayDebt = "中继器未清理会提高下一轮压力",
    scan = "扫描区会暴露位置 · 掩体/隐身/干扰可规避",
}
Tutorial.hintActive = false
Tutorial.current = nil           -- { text, left }
local shown = {}                 -- 本局已展示过的提示 id

function Tutorial.init(seenFlag)
    Tutorial.doneForever = seenFlag == true
    Tutorial.debugIgnore = false
end

-- 标记调试入口不参与正式教程状态（Debug/Review/Bot/QA）
function Tutorial.enterDebugFlow()
    Tutorial.debugIgnore = true
    Tutorial.active = false
    Tutorial.overlaySource = "none"
    Tutorial.current = nil
end

function Tutorial.isDebugFlow() return Tutorial.debugIgnore == true end

-- 是否需要在开始新正式局前弹出首次教程
function Tutorial.shouldShowFirstRun()
    return Config.TUTORIAL.enabled == true
        and Config.TUTORIAL.firstRunPages ~= false
        and not Tutorial.debugIgnore
        and not Tutorial.doneForever
end

-- 打开首次教程（点击"开始游戏"时调用；返回当前总页数）
function Tutorial.beginFirstRun()
    Tutorial.pages = {}
    for _, page in ipairs(Config.TUTORIAL.overlayPages or {}) do
        Tutorial.pages[#Tutorial.pages + 1] = page
    end
    if #Tutorial.pages == 0 then
        Tutorial.completeFirstRun()
        return 0
    end
    Tutorial.active = true
    Tutorial.overlaySource = "first_run"
    Tutorial.page = 1
    return #Tutorial.pages
end

-- 完成（含跳过）：立即置 doneForever；由 main 负责写档。
function Tutorial.completeFirstRun()
    Tutorial.active = false
    Tutorial.overlaySource = "none"
    Tutorial.doneForever = true
    return true
end

-- 手动重看（设置页"查看教程"）：不清除已完成状态，不重复自动弹出。
function Tutorial.replayFirstRun()
    Tutorial.pages = {}
    for _, page in ipairs(Config.TUTORIAL.overlayPages or {}) do
        Tutorial.pages[#Tutorial.pages + 1] = page
    end
    if #Tutorial.pages == 0 then return 0 end
    Tutorial.active = true
    Tutorial.overlaySource = "settings"
    Tutorial.page = 1
    return #Tutorial.pages
end

-- 结束当前 overlay，并给 main 一个可判定的导航目标。
-- 首次教程才写入完成状态；设置页回看只关闭 overlay，不改变存档语义。
function Tutorial.finishOverlay()
    local source = Tutorial.overlaySource
    Tutorial.active = false
    Tutorial.overlaySource = "none"
    if source == "first_run" then
        Tutorial.doneForever = true
        return "start_game"
    end
    if source == "settings" then return "settings" end
    return "none"
end

-- 关闭 overlay（不修改完成状态）
function Tutorial.closeOverlay()
    Tutorial.active = false
    Tutorial.overlaySource = "none"
end

function Tutorial.nextPage()
    if Tutorial.page < #Tutorial.pages then
        Tutorial.page = Tutorial.page + 1
        return true
    end
    return false
end

function Tutorial.prevPage()
    if Tutorial.page > 1 then
        Tutorial.page = Tutorial.page - 1
        return true
    end
    return false
end

-- 局内轻量提示（既有机制）
function Tutorial.beginGame()
    shown = {}
    Tutorial.current = nil
    Tutorial.hintActive = Config.TUTORIAL.enabled
        and not Tutorial.doneForever and not Tutorial.debugIgnore
end

-- 该局结束(死亡):教学视为已完成,后续局不再显示
function Tutorial.finishGame()
    if Tutorial.hintActive then
        Tutorial.doneForever = true
        Tutorial.hintActive = false
    end
    Tutorial.current = nil
    return Tutorial.doneForever
end

function Tutorial.isDone() return Tutorial.doneForever end

-- 调试面板:关闭教学
function Tutorial.disable()
    Tutorial.hintActive = false
    Tutorial.current = nil
    Tutorial.active = false
    Tutorial.overlaySource = "none"
end

local function show(id)
    if shown[id] then return end
    shown[id] = true
    Tutorial.current = { text = HINTS[id], left = Config.TUTORIAL.hintDuration }
end

-- 每帧:检查触发条件(在 AudioSys.drain 清空 events 前调用)
function Tutorial.update(world, dt)
    if Tutorial.current then
        Tutorial.current.left = Tutorial.current.left - dt
        if Tutorial.current.left <= 0 then Tutorial.current = nil end
    end
    if not Tutorial.hintActive then return end

    -- 1) 开局
    if not shown.intro and world.round == 1 and world.phase == "overload" then
        show("intro")
    end
    -- 2) 第一次进入最后5秒
    if world.phase == "overload" and world.overloadLeft <= Config.OVERLOAD.lastWarnTime
        and world.overloadLeft > 0 then
        show("lastSeconds")
    end
    -- 3/5/6/7) 事件触发
    for _, ev in ipairs(world.events) do
        if ev.name == "overload_end" then show("firstDrop")
        elseif ev.name == "energy_ready" then show("energyReady")
        elseif ev.name == "core_pickup" or ev.name == "dismantle_done" then show("firstCore")
        elseif ev.name == "mark_set" then show("firstMark")
        elseif ev.name == "hunter_protocol" then show("lure")
        elseif ev.name == "anti_hunt_start" then show("antiHunt")
        elseif ev.name == "layer_settled" then show("settlement")
        elseif ev.name == "protocol_start" and world:hasProtocol("blockade") then show("relayDebt")
        elseif ev.name == "scan_warning" then show("scan")
        end
    end
    -- 4) 第一次看到残骸(枯竭阶段,残骸进入约一屏范围)
    if not shown.firstWreck and world.phase == "depleted" then
        local p = world.player
        for _, wk in ipairs(world.wrecks) do
            if not wk.dead and Util.dist(wk.x, wk.y, p.x, p.y) < 360 then
                show("firstWreck")
                break
            end
        end
    end
end

return Tutorial
