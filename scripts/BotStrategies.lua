-- BotStrategies.lua
-- 多策略 Bot(§任务包H / [R2]§任务包J):保守/贪婪/激进/随机 + 理性诊断。
-- [R2] 修正:达到重启阈值后必须真实分化——保守尽快安全重启(目标立即重启率70-100%),
--   贪婪主动做深层残骸/超额缓存/组件(目标20-60%),激进高热度继续行动,随机两种都出现。
-- 纯逻辑模块:只产生 World:update 的 input,不进入玩家运行路径。

local Util = require "Util"
local Pathfinding = require "Pathfinding"
local Config = require "Config"

local Bots = {}

-- ============================================================
-- 通用工具
-- ============================================================
local function nearest(list, x, y, filter)
    local best, bestD = nil, math.huge
    for _, it in ipairs(list) do
        if not it.dead and (filter == nil or filter(it)) then
            local d = Util.dist2(it.x, it.y, x, y)
            if d < bestD then best, bestD = it, d end
        end
    end
    return best, math.sqrt(bestD)
end

local function chasedBy(world)
    for _, e in ipairs(world.enemies) do
        if not e.dead and (e.state == "chase" or e.state == "alert") then
            return e
        end
    end
    return nil
end

local function dangerNear(world, x, y, r)
    for _, e in ipairs(world.enemies) do
        if not e.dead and e.daze <= 0 and e.jammed <= 0
            and Util.dist(e.x, e.y, x, y) < r then
            return true
        end
    end
    return false
end

local function deepWreckOf(world)
    for _, wk in ipairs(world.wrecks) do
        if not wk.dead and wk.deep then return wk end
    end
    return nil
end

local function activeHuntTarget(world)
    return nearest(world.enemies, world.player.x, world.player.y, function(enemy)
        return enemy.huntTarget and (enemy.huntLeft or 0) > 0
    end)
end

-- 寻路移动:bot 自带路径缓存(伪实体走 Pathfinding 的节流接口)
local function navInput(world, bot, tx, ty)
    local p = world.player
    local nav = bot.nav
    nav.x, nav.y = p.x, p.y
    nav.radius = p.radius
    if nav.pathTimer and nav.pathTimer > 0 then nav.pathTimer = nav.pathTimer - bot.dt end
    Pathfinding.requestPath(world, nav, tx, ty)
    local path = nav.path
    local wpx, wpy = tx, ty
    if path and #path > 0 then
        local idx = nav.pathIdx or 1
        while idx <= #path and Util.dist(path[idx].x, path[idx].y, p.x, p.y) < 20 do
            idx = idx + 1
        end
        nav.pathIdx = idx
        if idx <= #path then wpx, wpy = path[idx].x, path[idx].y end
    end
    local dx, dy, len = Util.norm(wpx - p.x, wpy - p.y)
    if len < 4 then return 0, 0 end
    return dx, dy
end

-- 过载阶段通用打法:游走 + 常按技能(优先目标附近时凑过去)
local function overloadInput(world, bot, pressed)
    local p = world.player
    -- [R2] 有优先目标时朝最近的未完成机会移动(贪婪/激进更主动;
    -- 血量护栏 + 200px 站距,靠技能输出,不站桩挨打)
    if bot.pursueOpportunity and world.opportunities and p.hp > 45 then
        for _, op in ipairs(world.opportunities) do
            if not op.done and op.x then
                if world.pulseCd <= 0 and dangerNear(world, p.x, p.y, 180) then
                    pressed.pulse = true
                end
                if world.collapseCd <= 0 then pressed.collapse = true end
                local d = Util.dist(op.x, op.y, p.x, p.y)
                if d > 210 then
                    return navInput(world, bot, op.x, op.y)
                end
                -- 站距内:绕目标游走(保持技能覆盖,躲直线接触)
                bot.jitterT = (bot.jitterT or 0) - bot.dt
                if bot.jitterT <= 0 then
                    bot.jitterT = 0.6 + bot.rand() * 0.6
                    local a = bot.rand() * 6.28318
                    bot.jx, bot.jy = math.cos(a), math.sin(a)
                end
                return bot.jx or 0, bot.jy or 0
            end
        end
    end
    bot.jitterT = (bot.jitterT or 0) - bot.dt
    if bot.jitterT <= 0 then
        bot.jitterT = 1.2 + bot.rand() * 0.8
        local a = bot.rand() * 6.28318
        bot.jx, bot.jy = math.cos(a), math.sin(a)
    end
    if world.pulseCd <= 0 and dangerNear(world, p.x, p.y, 180) then
        pressed.pulse = true
    end
    if world.collapseCd <= 0 and bot.rand() < 0.3 then
        pressed.collapse = true
    end
    return bot.jx or 0, bot.jy or 0
end

-- 枯竭防身:被追时用工具
local function selfDefense(world, bot, pressed)
    local chaser = chasedBy(world)
    if not chaser then return end
    local p = world.player
    local d = Util.dist(chaser.x, chaser.y, p.x, p.y)
    if d < 220 and world.tools.jammer > 0 and bot.rand() < 0.3 then
        pressed.jammer = true
    elseif d < 160 and world.tools.cloak > 0 and world.cloakLeft <= 0 and bot.rand() < 0.2 then
        pressed.cloak = true
    elseif d < 200 and world.tools.decoy > 0 and bot.rand() < 0.1 then
        pressed.decoy = true
    end
end

-- 站定重启(引导读条期间不动)
local function doRestart(world, pressed)
    if not world.restartChannel then pressed.restart = true end
    return 0, 0
end

-- 走向残骸并拆解(返回 moveX,moveY;nil 表示没有目标)
local function goDismantle(world, bot, pressed, wreck)
    if not wreck then return nil end
    local p = world.player
    local d = Util.dist(wreck.x, wreck.y, p.x, p.y)
    if d < 70 then
        if not world.dismantle then pressed.dismantle = true end
        return 0, 0
    end
    return navInput(world, bot, wreck.x, wreck.y)
end

-- ============================================================
-- 策略实现:返回 moveX, moveY(pressed 直接写入)
-- ============================================================
local strategies = {}

-- 保守型(§15.1):达标后尽快在安全时机重启;不去深层残骸;少量顺路收益
function strategies.cautious(world, bot, pressed)
    local p = world.player
    if world.phase == "overload" then return overloadInput(world, bot, pressed) end
    selfDefense(world, bot, pressed)
    if world.energy >= world.energyNeed then
        local chaser = chasedBy(world)
        if chaser then
            -- 被追:先用工具解围再重启(远离追击者)
            if world.tools.jammer > 0 then pressed.jammer = true end
            local dx, dy = Util.norm(p.x - chaser.x, p.y - chaser.y)
            return dx, dy
        end
        -- 顺路收益:极近的储能(<120px)捡了再走
        local cell, cd = nearest(world.cells, p.x, p.y)
        if cell and cd < 120 then return navInput(world, bot, cell.x, cell.y) end
        return doRestart(world, pressed)
    end
    -- 目标:最安全的储能(跳过附近有威胁的;高危区顶部 y < 8 格不去)
    local cell = nearest(world.cells, p.x, p.y, function(c)
        return c.y > 8 * 48 and not dangerNear(world, c.x, c.y, 200)
    end)
    if not cell then
        cell = nearest(world.cells, p.x, p.y, function(c) return c.y > 8 * 48 end)
    end
    if not cell then cell = nearest(world.cells, p.x, p.y) end
    if cell then return navInput(world, bot, cell.x, cell.y) end
    return 0, 0
end

-- 贪婪型(§15.2):达标后主动冒险——深层残骸/超额缓存/组件,压力超阈值才撤
function strategies.greedy(world, bot, pressed)
    local p = world.player
    bot.pursueOpportunity = true
    if world.phase == "overload" then return overloadInput(world, bot, pressed) end
    selfDefense(world, bot, pressed)
    local pressure = chasedBy(world) ~= nil
    local ready = world.energy >= world.energyNeed
    local heatLvl = world:heatLevel()
    -- 撤退条件:血低 / 锁定档 / 被追且储能已够
    if ready and (p.hp < 40 or heatLvl >= 3 or (pressure and p.hp < 70)) then
        return doRestart(world, pressed)
    end
    if not ready then
        -- 达标前:残骸(普通)> 储能
        local preWreck = nearest(world.wrecks, p.x, p.y, function(w) return not w.deep end)
        if preWreck then
            local mx, my = goDismantle(world, bot, pressed, preWreck)
            return mx, my
        end
        local cell = nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
        return 0, 0
    end
    -- 达标后(真正的"继续冒险"分支,§15.2)
    -- 追加撤退线:热度追踪档以上且血不满 → 见好就收
    if ready and heatLvl >= 2 and p.hp < 60 then
        return doRestart(world, pressed)
    end
    -- 1. 深层残骸(高收益;接近时先用工具压制周边警戒)
    local deep = deepWreckOf(world)
    if deep and p.hp >= 55 then
        local d = Util.dist(deep.x, deep.y, p.x, p.y)
        if d < 240 and dangerNear(world, deep.x, deep.y, 280) then
            if world.tools.jammer > 0 then pressed.jammer = true
            elseif world.tools.cloak > 0 and world.cloakLeft <= 0 then pressed.cloak = true end
        end
        if d < 70 then
            if not world.dismantle then pressed.dismantle = true end
            return 0, 0
        end
        return navInput(world, bot, deep.x, deep.y)
    end
    -- 2. 普通残骸
    local wreck = nearest(world.wrecks, p.x, p.y, function(w) return not w.deep end)
    if wreck then
        local d = Util.dist(wreck.x, wreck.y, p.x, p.y)
        if d < 70 then
            if not world.dismantle then pressed.dismantle = true end
            return 0, 0
        end
        return navInput(world, bot, wreck.x, wreck.y)
    end
    -- 3. 制作组件
    if world.coreCount >= 1 and not world.modules.capacitor then
        pressed.craftCapacitor = true
    elseif world.coreCount >= 1 and not world.modules.amplifier then
        pressed.craftAmplifier = true
    end
    -- 4. 标记(顺手)
    if not world.mark and world:findMarkTarget() then
        pressed.mark = true
    end
    -- 5. 超额缓存:未满级继续吃储能(实验B;A 无缓存则跳过)
    if world.exp.overflowCache and world:overflowLevel() < Config.RISK.overflowMax then
        local cell = nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
    end
    -- 6. 核心堆
    local core = nearest(world.cores, p.x, p.y)
    if core and world.coreCount < 2 then
        return navInput(world, bot, core.x, core.y)
    end
    -- 7. 无事可做:重启
    return doRestart(world, pressed)
end

-- 激进型(§15.3):追求最大收益,高热度继续行动,预期早死(不故意自杀)
function strategies.aggressive(world, bot, pressed)
    local p = world.player
    bot.pursueOpportunity = true
    if world.phase == "overload" then return overloadInput(world, bot, pressed) end
    local ready = world.energy >= world.energyNeed
    -- 先确保能进入真正的达标后决策；风险行为不能被达标前绕路冒充。
    if not ready then
        local cell = nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
        return 0, 0
    end
    -- 只有濒死才撤
    if ready and p.hp < 25 then
        return doRestart(world, pressed)
    end
    -- 深层残骸最优先
    local deep = deepWreckOf(world)
    if deep then
        local d = Util.dist(deep.x, deep.y, p.x, p.y)
        if d < 70 then
            if not world.dismantle then pressed.dismantle = true end
            return 0, 0
        end
        return navInput(world, bot, deep.x, deep.y)
    end
    -- 核心 > 储能,哪个近去哪个
    local cell = nearest(world.cells, p.x, p.y)
    local core = nearest(world.cores, p.x, p.y)
    local target = cell
    if core and (not cell or Util.dist2(core.x, core.y, p.x, p.y) < Util.dist2(cell.x, cell.y, p.x, p.y)) then
        target = core
    end
    -- 全部吃完且已达标:重启
    if not target and ready then return doRestart(world, pressed) end
    if target then return navInput(world, bot, target.x, target.y) end
    return 0, 0
end

-- 高分型：反猎目标优先，枯竭满能后主动维持追击与风险分，濒死才兑现。
function strategies.highscore(world, bot, pressed)
    local p = world.player
    bot.pursueOpportunity = true
    if world.phase == "overload" then
        local hunt = activeHuntTarget(world)
        if hunt then
            local d = Util.dist(hunt.x, hunt.y, p.x, p.y)
            if world.collapseCd <= 0 then pressed.collapse = true end
            if world.pulseCd <= 0 and d < Config.OVERLOAD.pulseRadius then pressed.pulse = true end
            if d > 150 then return navInput(world, bot, hunt.x, hunt.y) end
        end
        return overloadInput(world, bot, pressed)
    end
    local ready = world.energy >= world.energyNeed
    if not ready then
        local cell = nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
        return 0, 0
    end
    selfDefense(world, bot, pressed)
    if p.hp < 32 or (world.riskScore or 0) >= 9000 then return doRestart(world, pressed) end
    local deep = deepWreckOf(world)
    if deep and p.hp > 48 then
        local mx, my = goDismantle(world, bot, pressed, deep)
        return mx, my
    end
    local chaser = chasedBy(world)
    if chaser then
        -- 保持可控距离诱敌，不靠墙挂机；风险过高时才结算。
        local dx, dy = Util.norm(p.x - chaser.x, p.y - chaser.y)
        return dx, dy
    end
    local enemy = nearest(world.enemies, p.x, p.y, function(e) return e.kind ~= "heavy" end)
    if enemy then return navInput(world, bot, enemy.x, enemy.y) end
    return doRestart(world, pressed)
end

-- 随机型(§15.4):有限随机 + 立即重启/继续冒险两种行为都出现
local RAND_BTN = { "pulse", "collapse", "jammer", "decoy", "cloak", "restart",
    "dismantle", "mark", "recon", "craftCapacitor", "craftAmplifier" }
function strategies.random(world, bot, pressed)
    bot.jitterT = (bot.jitterT or 0) - bot.dt
    if bot.jitterT <= 0 then
        bot.jitterT = 0.5 + bot.rand() * 1.0
        local a = bot.rand() * 6.28318
        bot.jx, bot.jy = math.cos(a), math.sin(a)
    end
    if bot.rand() < 0.08 then
        pressed[RAND_BTN[math.floor(bot.rand() * #RAND_BTN) + 1]] = true
    end
    if world.phase == "overload" then return overloadInput(world, bot, pressed) end
    -- 每局固定抛硬币:这局是"立即重启派"还是"继续冒险派"
    if bot.coin == nil then bot.coin = bot.rand() < 0.5 end
    if world.energy < world.energyNeed then
        local cell = nearest(world.cells, world.player.x, world.player.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
    elseif world.phase == "depleted" then
        if bot.coin then
            return doRestart(world, pressed)
        else
            local deep = deepWreckOf(world)
            if deep then
                local d = Util.dist(deep.x, deep.y, world.player.x, world.player.y)
                if d < 70 then
                    if not world.dismantle then pressed.dismantle = true end
                    return 0, 0
                end
                return navInput(world, bot, deep.x, deep.y)
            end
            if world:overflowLevel() < Config.RISK.overflowMax then
                local cell = nearest(world.cells, world.player.x, world.player.y)
                if cell then return navInput(world, bot, cell.x, cell.y) end
            end
            return doRestart(world, pressed)
        end
    end
    return bot.jx or 0, bot.jy or 0
end

-- [R2] 理性诊断型(§15.5):简单效用比较"继续冒险 vs 立即重启"。仅诊断用。
function strategies.rational(world, bot, pressed)
    local p = world.player
    bot.pursueOpportunity = true
    if world.phase == "overload" then return overloadInput(world, bot, pressed) end
    selfDefense(world, bot, pressed)
    local ready = world.energy >= world.energyNeed
    if not ready then
        local cell = nearest(world.cells, p.x, p.y, function(c)
            return not dangerNear(world, c.x, c.y, 180)
        end) or nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
        return 0, 0
    end
    -- 效用:继续冒险的价值 - 风险
    local deep = deepWreckOf(world)
    local heatLvl = world:heatLevel()
    local util = 0
    if deep then
        local d = Util.dist(deep.x, deep.y, p.x, p.y)
        util = util + 2.0 - d / 800          -- 深层收益,越远越不值
    end
    if world.exp.overflowCache then
        util = util + (Config.RISK.overflowMax - world:overflowLevel()) * 0.6
    end
    if world.coreCount >= 1 and not world.modules.capacitor then util = util + 0.5 end
    util = util - heatLvl * 0.9              -- 热度风险
    util = util - (1 - p.hp / p.maxHp) * 2.0 -- 生命风险
    if chasedBy(world) then util = util - 1.5 end
    if util > 0.6 then
        if deep then
            local d = Util.dist(deep.x, deep.y, p.x, p.y)
            if d < 70 then
                if not world.dismantle then pressed.dismantle = true end
                return 0, 0
            end
            return navInput(world, bot, deep.x, deep.y)
        end
        if world.coreCount >= 1 and not world.modules.capacitor then
            pressed.craftCapacitor = true
        end
        local cell = nearest(world.cells, p.x, p.y)
        if cell then return navInput(world, bot, cell.x, cell.y) end
    end
    return doRestart(world, pressed)
end

-- ============================================================
-- 对外接口
-- ============================================================
function Bots.create(kind)
    assert(strategies[kind], "unknown bot kind: " .. tostring(kind))
    local bot = {
        kind = kind,
        dt = 0.05,
        nav = { x = 0, y = 0, radius = 16, avoidLaser = true },  -- Pathfinding 伪实体(避开激光走廊)
        rand = math.random,
        jitterT = 0, jx = 0, jy = 0,
    }
    function bot:decide(world, dt)
        self.dt = dt
        local pressed = {}
        -- 反猎窗口：沿用过载行为，追杀反猎目标。
        if world.phase == "anti_hunt" then
            local mx, my = overloadInput(world, self, pressed)
            return { moveX = mx or 0, moveY = my or 0, pressed = pressed }
        end
        -- 层结算/协议整备：Bot 不做购买决策，直接确认推进，避免长跑卡在界面上。
        if world.phase == "layer_settlement" then
            pressed.shopConfirm = true
            return { moveX = 0, moveY = 0, pressed = pressed }
        end
        -- 扫描预警/生效时先离开高亮区域；所有策略共用，避免Bot把通道延迟当玩法。
        if world.phase == "depleted" and world.scan and world.scan.zone
            and (world.scan.state == "warning" or world.scan.state == "active") then
            local c = math.floor(world.player.x / Config.TILE) + 1
            local r = math.floor(world.player.y / Config.TILE) + 1
            local z = world.scan.zone
            if c >= z.c1 and c <= z.c2 and r >= z.r1 and r <= z.r2 then
                local safe = nearest(world.cells, world.player.x, world.player.y, function(cell)
                    local cc = math.floor(cell.x / Config.TILE) + 1
                    local rr = math.floor(cell.y / Config.TILE) + 1
                    return cc < z.c1 or cc > z.c2 or rr < z.r1 or rr > z.r2
                end)
                if safe then
                    local mx, my = navInput(world, self, safe.x, safe.y)
                    return { moveX = mx or 0, moveY = my or 0, pressed = pressed }
                end
            end
        end
        local mx, my = strategies[self.kind](world, self, pressed)
        return { moveX = mx or 0, moveY = my or 0, pressed = pressed }
    end
    return bot
end

Bots.kinds = { "cautious", "greedy", "aggressive", "highscore", "random", "rational" }
Bots.allKinds = { "cautious", "greedy", "aggressive", "highscore", "random", "rational" }

return Bots
