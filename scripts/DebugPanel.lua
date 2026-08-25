-- DebugPanel.lua
-- 仅调试模式的隐藏面板(§任务包G):快速复现场景 + 可视化开关。
-- 隐藏入口:2 秒内在屏幕左上角 60x60 区域连点 5 次,或桌面按 F1。
-- 正式试玩默认不显示;Config.DEBUG.panelEnabled = false 可彻底禁用。

local Config = require "Config"
local MapDef = require "MapDef"

local DebugPanel = {}

DebugPanel.open = false
local tapTimes = {}          -- 左上角连点时间戳(用 world.timeAlive 累计的本地时钟)
local clock = 0

local SEEDS = { 12345, 2026, 777, 4242, 99999 }
local seedIdx = 1
DebugPanel.request = nil

-- 面板按钮定义:{ id, label }
local ACTIONS = {
    { id = "seed",       label = "换种子" },
    { id = "last5",      label = "跳到最后5秒" },
    { id = "drop",       label = "强制枯竭" },
    { id = "energy20",   label = "储能=差20" },
    { id = "wreck",      label = "生成残骸" },
    { id = "heavy",      label = "生成重型" },
    { id = "firewall",   label = "开/关防火墙" },
    { id = "core",       label = "+1核心" },
    { id = "craft",      label = "制作扩容" },
    { id = "mark",       label = "标记最近" },
    { id = "restart",    label = "强制重启" },
    { id = "round",      label = "轮次+1" },
    { id = "calm",       label = "清除追击" },
    { id = "paths",      label = "显示路径" },
    { id = "los",        label = "显示视线" },
    { id = "stats",      label = "显示统计" },
    { id = "export",     label = "导出诊断" },
    { id = "tutorial",   label = "关闭教学" },
    -- [R2] 实验/风险收益调试
    { id = "exp",        label = "切换实验A/B" },
    { id = "heat",       label = "热度+20" },
    { id = "deep",       label = "生成深层残骸" },
    { id = "ready",      label = "储能=达标" },
    { id = "close",      label = "关闭面板" },
}

function DebugPanel.tick(dt)
    clock = clock + dt
end

-- 面板布局(逻辑像素):两列小按钮
function DebugPanel.layout(w, _h)
    local btns = {}
    local bw, bh, gap = 120, 34, 8
    local cols = 2
    local x0 = w - (bw * cols + gap * (cols + 1)) - 4
    local y0 = 90
    for i, a in ipairs(ACTIONS) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        btns[#btns + 1] = {
            id = a.id, label = a.label,
            x = x0 + gap + col * (bw + gap),
            y = y0 + gap + row * (bh + gap),
            w = bw, h = bh,
        }
    end
    return btns, { x = x0, y = y0, w = bw * cols + gap * 3 + 8, h = #ACTIONS / cols * (bh + gap) + gap * 2 }
end

-- 触点处理:返回 true 表示事件被面板消费(不再传给游戏输入)
function DebugPanel.onPointerDown(world, x, y, w, h)
    if not Config.DEBUG.panelEnabled then return false end
    -- 隐藏入口:左上角 60x60 连点 5 次(2 秒窗口)
    if not DebugPanel.open and x < 60 and y < 60 then
        tapTimes[#tapTimes + 1] = clock
        while #tapTimes > 0 and clock - tapTimes[1] > 2.0 do
            table.remove(tapTimes, 1)
        end
        if #tapTimes >= 5 then
            tapTimes = {}
            DebugPanel.open = true
            print("[DEBUG] panel opened")
            return true
        end
        return false   -- 未达 5 连点:不消费(角落也可能是正常操作)
    end
    if not DebugPanel.open then return false end
    for _, b in ipairs(DebugPanel.layout(w, h)) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            DebugPanel.act(world, b.id)
            return true
        end
    end
    return false       -- 点在面板外:让游戏正常响应
end

function DebugPanel.toggle()
    if not Config.DEBUG.panelEnabled then return end
    DebugPanel.open = not DebugPanel.open
end

function DebugPanel.act(world, id)
    local D = Config.DEBUG
    if id == "close" then
        DebugPanel.open = false
    elseif id == "seed" then
        seedIdx = seedIdx % #SEEDS + 1
        DebugPanel.request = { kind = "restartSeed", seed = SEEDS[seedIdx] }
    elseif id == "last5" then
        if world.phase == "overload" then
            world.overloadLeft = math.min(world.overloadLeft, 5.2)
        end
    elseif id == "drop" then
        if world.phase == "overload" then world:forceDrop() end
    elseif id == "energy20" then
        world.energy = math.max(0, world.energyNeed - 20)
    elseif id == "wreck" then
        local c, r = MapDef.toTile(world.player.x, world.player.y)
        local x, y = MapDef.tileCenter(c, r)
        world.wrecks[#world.wrecks + 1] = { x = x + 60, y = y, dead = false }
    elseif id == "heavy" then
        world:spawnEnemy("heavy", world.player.x + 200, world.player.y, nil, false)
    elseif id == "firewall" then
        local fw = nil
        for _, f in ipairs(world.firewalls) do
            if not f.dead then fw = f break end
        end
        if fw then world:onFirewallDestroyed(fw) end
    elseif id == "core" then
        world.coreCount = world.coreCount + 1
    elseif id == "craft" then
        world.coreCount = math.max(world.coreCount, 1)
        world:craft("capacitor")
    elseif id == "mark" then
        world:trySetMark()
    elseif id == "restart" then
        if world.phase == "depleted" then
            world.energy = math.max(world.energy, world.energyNeed)
            world:doRestart()
        end
    elseif id == "round" then
        -- 调试快进整层：过载 → 枯竭 → 重启 → 反猎 → 层结算 → 下一层。
        if world.phase == "overload" then
            world:forceDrop()
        end
        if world.phase == "depleted" then
            world.energy = math.max(world.energy, world.energyNeed)
            world:doRestart()
        end
        if world.phase == "anti_hunt" then
            world.antiHuntTimer = 0
            world.antiHuntResolveTimer = nil
            world:finishAntiHunt()
        end
        if world.phase == "layer_settlement" then
            if world.layerSettlement and world.layerSettlement.runComplete then
                world:chooseEndless()
            else
                world:advanceLayer()
            end
        end
    elseif id == "calm" then
        for _, e in ipairs(world.enemies) do
            if not e.dead then
                e.state = "patrol"
                e.suspicion = 0
                e.loseTimer = 0
            end
        end
    elseif id == "paths" then
        D.showPaths = not D.showPaths
    elseif id == "los" then
        D.showLOS = not D.showLOS
    elseif id == "stats" then
        D.showStats = not D.showStats
    elseif id == "export" then
        local PlaytestMetrics = require "PlaytestMetrics"
        local s = PlaytestMetrics.session
        if s then
            print(string.format("[DEBUG] session rounds=%d time=%.0f counters:", #s.rounds, world.timeAlive))
            for k, v in pairs(world.counters) do
                print(string.format("[DEBUG]   %s = %s", k, tostring(v)))
            end
        end
    elseif id == "tutorial" then
        local Tutorial = require "Tutorial"
        Tutorial.disable()
        world:addFx("banner", { text = "教学提示已关闭", dur = 1.2 })
    elseif id == "exp" then
        local Profiles = require "ExperimentProfiles"
        local other = (world.experimentId == "A") and "B" or "A"
        Profiles.select(other, false)
        -- 请求 main 用同一 seed 新建 World；避免旧热度/深层/指标串入新实验。
        DebugPanel.request = { kind = "switchExperiment", experiment = other, seed = world.seed }
    elseif id == "heat" then
        local TraceHeat = require "TraceHeat"
        TraceHeat.noise(world, 20, world.player.x, world.player.y)
        world:addFx("banner", { text = string.format("热度 = %.0f", world.heat or 0), dur = 1.2 })
    elseif id == "deep" then
        world.deepSpawnedRound = 0   -- 允许重复生成
        world:spawnDeepWreck()
    elseif id == "ready" then
        world.energy = world.energyNeed
    end
end

-- 调试统计信息(showStats 用;由 main 每帧填充逻辑耗时)
DebugPanel.frameMs = 0

function DebugPanel.statsText(world)
    local alive = 0
    for _, e in ipairs(world.enemies) do
        if not e.dead then alive = alive + 1 end
    end
    return string.format("enemies=%d fx=%d cells=%d paths=%d frame=%.1fms",
        alive, #world.fx, #world.cells, world.pathSearches or 0, DebugPanel.frameMs)
end

-- 便于测试:重置
function DebugPanel.reset()
    DebugPanel.open = false
    tapTimes = {}
    DebugPanel.request = nil
end

function DebugPanel.consumeRequest()
    local r = DebugPanel.request
    DebugPanel.request = nil
    return r
end

return DebugPanel
