-- CombatSys.lua
-- 过载阶段战斗:连锁侵入(自动)、区域脉冲、系统崩解、标记引爆、残骸生成、防火墙摧毁。
-- 本模块在 phase == "overload" 或 "anti_hunt" 时由 World 调用；枯竭阶段技能全部锁定。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local ScoreSys = require "ScoreSys"
local RunShop = require "RunShop"
local EndlessOverclock = require "EndlessOverclock"

local CombatSys = {}

-- 标记引爆(§7.3):被标记目标在本轮过载首次被攻击时触发
local function checkMarkTrigger(world, target)
    local m = world.mark
    if not m or not m.armed or m.ref ~= target then return end
    world.mark = nil
    local O = Config.OVERLOAD
    -- 大范围连锁爆炸 + 瘫痪
    for _, e in ipairs(world.enemies) do
        if not e.dead and Util.dist(e.x, e.y, target.x, target.y) < O.markBonusRadius then
            CombatSys.damageEnemy(world, e, O.markBonusDamage, true)
            e.stun = math.max(e.stun, O.markBonusStun)
        end
    end
    -- 返还少量过载时间
    world.overloadLeft = math.min(world.overloadDuration, world.overloadLeft + O.markBonusTime)
    world:addFx("bigring", { x = target.x, y = target.y, r = O.markBonusRadius, color = "yellow", dur = 0.8 })
    world:addFx("banner", { text = "标记引爆!+" .. O.markBonusTime .. "s", dur = 1.8 })
    world:addFx("shake", { power = 14, dur = 0.5 })
    world:emit("mark_trigger", target.x, target.y)
end

-- 对敌人造成伤害(fullOnHeavy=true 时对重型不打折)
function CombatSys.damageEnemy(world, e, amount, _fullOnHeavy)
    if e.dead then return end
    checkMarkTrigger(world, e)
    e.hp = e.hp - amount
    e.hitFlash = 0.15
    if e.hp <= 0 then
        e.dead = true
        local wasHuntTarget = e.huntTarget == true
        world:bump("kills")
        ScoreSys.onKill(world, e)
        EndlessOverclock.onEnemyKilled(world, e)
        if wasHuntTarget then
            world.huntTargetsLeft = math.max(0, world.huntTargetsLeft - 1)
        end
        if e.kind == "heavy" then
            -- 重型残骸:过载不可拆,枯竭可拆(§7.1);落点取所在格中心保证可达(§18.3)
            local c, r = MapDef.toTile(e.x, e.y)
            local wx, wy = MapDef.tileCenter(c, r)
            if world:isSolidAt(wx, wy) then wx, wy = e.x, e.y end
            world.wrecks[#world.wrecks + 1] = { x = wx, y = wy, dead = false }
            world:addFx("bigring", { x = e.x, y = e.y, r = 120, color = "orange", dur = 0.6 })
            world:addFx("shake", { power = 8, dur = 0.3 })
            world:emit("heavy_down", e.x, e.y)
        else
            world:addFx("burst", { x = e.x, y = e.y, color = "cyan", dur = 0.4 })
            world:emit("enemy_kill", e.x, e.y)
        end
        if wasHuntTarget then world:emit("hunt_kill", e.x, e.y) end
        if world.mark and world.mark.ref == e then world.mark = nil end
    end
end

function CombatSys.damageFirewall(world, fw, amount)
    if fw.dead then return end
    checkMarkTrigger(world, fw)
    fw.hp = fw.hp - amount
    if fw.hp <= 0 then
        fw.hp = 0
        world:onFirewallDestroyed(fw)
    else
        world:addFx("hitspark", { x = fw.x, y = fw.y, color = "cyan", dur = 0.2 })
    end
end

-- [R2] 追踪中继器(实验B过载优先目标;耐久低,顺手可清)
function CombatSys.damageRelay(world, rl, amount)
    if rl.dead then return end
    rl.hp = rl.hp - amount
    if rl.hp <= 0 then
        rl.hp = 0
        world:onRelayDestroyed(rl)
    else
        world:addFx("hitspark", { x = rl.x, y = rl.y, color = "green", dur = 0.2 })
    end
end

-- 连锁侵入(§8.1):自动锁定 + 多目标跳跃
local function fireChain(world)
    local O = Config.OVERLOAD
    local p = world.player
    local maxTargets = O.chainTargets
        + (world.activeModules.amplifier and Config.MODULES.amplifier.bonusJumps or 0)
        + ((world.activeCache or 0) >= 2 and Config.RISK.cacheChainTargets or 0) -- [R2] 缓存2级
        + EndlessOverclock.mod(world, "arc_relay")
        + EndlessOverclock.mod(world, "arc_fork")
        + EndlessOverclock.mod(world, "arc_overload") * 2

    -- 候选:敌人 + 未摧毁防火墙(对防火墙伤害极低,主要靠崩解)
    local hit = {}
    local segs = {}
    local fromX, fromY = p.x, p.y
    local range = O.chainRange * (1 + EndlessOverclock.mod(world, "arc_reach") * 0.14)
    for _ = 1, maxTargets do
        local best, bestD, bestIsFw, bestIsRelay = nil, range, false, false
        for _, e in ipairs(world.enemies) do
            if not e.dead and not hit[e] then
                local d = Util.dist(e.x, e.y, fromX, fromY)
                if d < bestD then best, bestD, bestIsFw, bestIsRelay = e, d, false, false end
            end
        end
        for _, f in ipairs(world.firewalls) do
            if not f.dead and not hit[f] then
                local d = Util.dist(f.x, f.y, fromX, fromY)
                if d < bestD then best, bestD, bestIsFw, bestIsRelay = f, d, true, false end
            end
        end
        -- [R2] 中继器也是连锁候选(实验A不生成中继器,天然不参与)
        for _, rl in ipairs(world.relays) do
            if not rl.dead and not hit[rl] then
                local d = Util.dist(rl.x, rl.y, fromX, fromY)
                if d < bestD then best, bestD, bestIsFw, bestIsRelay = rl, d, false, true end
            end
        end
        if not best then break end
        hit[best] = true
        segs[#segs + 1] = { x1 = fromX, y1 = fromY, x2 = best.x, y2 = best.y }
        if bestIsFw then
            CombatSys.damageFirewall(world, best, O.chainFirewallDamage)
        elseif bestIsRelay then
            CombatSys.damageRelay(world, best, O.chainDamage)
        else
            local dmg = O.chainDamage
            if best.kind == "heavy" then dmg = dmg * O.chainHeavyFactor end
            CombatSys.damageEnemy(world, best, dmg, false)
            if not best.dead and best.kind ~= "heavy" then
                best.stun = math.max(best.stun, 0.25)
            end
        end
        fromX, fromY = best.x, best.y
        range = O.chainJumpRange * (1 + EndlessOverclock.mod(world, "arc_reach") * 0.14)
    end
    if #segs > 0 then
        world:addFx("chain", { segs = segs, dur = 0.22 })
        world:emit("chain_fire")
        if #segs >= 3 then world:emit("chain_multi", nil, nil, #segs) end
        return true
    end
    return false
end

local function selectCollapseTarget(world, fromX, fromY, range, used)
    local best, bestD, bestIsFw, bestIsRelay = nil, range, false, false
    local m = world.mark
    if m and m.armed and m.ref and not m.ref.dead and not used[m.ref]
        and Util.dist(m.ref.x, m.ref.y, fromX, fromY) < bestD then
        best, bestD, bestIsFw, bestIsRelay = m.ref, Util.dist(m.ref.x, m.ref.y, fromX, fromY),
            (m.ref.effect ~= nil), false
    end
    for _, f in ipairs(world.firewalls) do
        if not f.dead and not used[f] then
            local d = Util.dist(f.x, f.y, fromX, fromY)
            if d < bestD then best, bestD, bestIsFw, bestIsRelay = f, d, true, false end
        end
    end
    for _, rl in ipairs(world.relays) do
        if not rl.dead and not used[rl] then
            local d = Util.dist(rl.x, rl.y, fromX, fromY)
            if d < bestD then best, bestD, bestIsFw, bestIsRelay = rl, d, false, true end
        end
    end
    for _, e in ipairs(world.enemies) do
        if not e.dead and e.kind == "heavy" and not used[e] then
            local d = Util.dist(e.x, e.y, fromX, fromY)
            if d < bestD then best, bestD, bestIsFw, bestIsRelay = e, d, false, false end
        end
    end
    for _, e in ipairs(world.enemies) do
        if not e.dead and not used[e] then
            local d = Util.dist(e.x, e.y, fromX, fromY)
            if d < bestD then best, bestD, bestIsFw, bestIsRelay = e, d, false, false end
        end
    end
    return best, bestIsFw, bestIsRelay
end

local function applyPulseWave(world, originX, originY, radius, damageScale, stunScale, hit, burstState, allowBurst, waveColor)
    local O = Config.OVERLOAD
    local waveDamage = O.pulseDamage * math.max(0, damageScale or 0)
    local waveStun = O.pulseStun * math.max(0, stunScale or 0)
    local heavyScale = allowBurst == false and 0.95 or O.pulseHeavyFactor
    local hitAny = false
    local bursts = {}
    local function within(entity)
        return entity and not entity.dead and not hit[entity]
            and Util.dist(entity.x, entity.y, originX, originY) <= radius
    end
    for _, e in ipairs(world.enemies) do
        if within(e) then
            hit[e] = true
            hitAny = true
            local dmg = waveDamage
            if e.kind == "heavy" then dmg = dmg * heavyScale end
            CombatSys.damageEnemy(world, e, dmg, false)
            if not e.dead then e.stun = math.max(e.stun, waveStun) end
            if allowBurst and burstState and burstState.done and e.kind == "heavy" and not burstState.done[e] then
                burstState.done[e] = true
                bursts[#bursts + 1] = { x = e.x, y = e.y }
            end
        end
    end
    for _, f in ipairs(world.firewalls) do
        if within(f) then
            hit[f] = true
            hitAny = true
            CombatSys.damageFirewall(world, f, math.max(10, waveDamage * 0.35))
        end
    end
    for _, rl in ipairs(world.relays) do
        if within(rl) then
            hit[rl] = true
            hitAny = true
            CombatSys.damageRelay(world, rl, math.max(8, waveDamage * 0.55))
        end
    end
    if hitAny then
        world:addFx("bigring", { x = originX, y = originY, r = radius, color = waveColor or "cyan", dur = 0.5 })
    end
    return bursts, hitAny
end

-- 区域脉冲(§8.2)
local function firePulse(world)
    local O = Config.OVERLOAD
    local p = world.player
    local radius = O.pulseRadius * (1 + EndlessOverclock.mod(world, "pulse_ring") * 0.22)
    local hit = {}
    local burstState = { done = {} }
    local burstQueue = {}
    local function appendBursts(bursts)
        for _, burst in ipairs(bursts or {}) do burstQueue[#burstQueue + 1] = burst end
    end
    appendBursts((applyPulseWave(world, p.x, p.y, radius, 1, 1, hit, burstState, true, "cyan")))
    local echo = EndlessOverclock.mod(world, "pulse_echo")
    if echo > 0 then
        appendBursts((applyPulseWave(world, p.x, p.y, radius * (1.2 + echo * 0.12),
            0.28 * echo, 0.82, hit, burstState, true, "purple")))
    end
    local scatter = EndlessOverclock.mod(world, "pulse_scatter")
    if scatter > 0 then
        -- 散射不是纯特效：向外追加可命中的外圈波段。
        for i = 1, scatter * 2 do
            local waveRadius = radius * (1 + 0.22 * i)
            local waveDamage = math.max(0.18, 0.72 - i * 0.16)
            local waveStun = math.max(0.32, 0.92 - i * 0.12)
            appendBursts((applyPulseWave(world, p.x, p.y, waveRadius, waveDamage, waveStun,
                hit, burstState, true, "purple")))
        end
    end
    local breakLevel = EndlessOverclock.mod(world, "pulse_break")
    if breakLevel > 0 then
        local burstRadius = radius * (0.44 + breakLevel * 0.1)
        local burstDamage = 0.85 + breakLevel * 0.25
        for _, burst in ipairs(burstQueue) do
            applyPulseWave(world, burst.x, burst.y, burstRadius, burstDamage, 0.5,
                hit, burstState, false, "purple")
        end
    end
    world:addFx("shake", { power = 6, dur = 0.25 })
    world:emit("pulse_fire")
end

-- 系统崩解(§8.3):优先 被标记目标 > 防火墙 > 重型 > 普通
local function fireCollapse(world)
    local O = Config.OVERLOAD
    local p = world.player
    local lockCount = 1 + EndlessOverclock.mod(world, "collapse_lock")
    local range = O.collapseRange * (1 + EndlessOverclock.mod(world, "collapse_lock") * 0.12)
    local used = {}
    local segs = {}
    local fromX, fromY = p.x, p.y
    local lastTarget = nil
    local lastIsHeavy = false
    for lockIndex = 1, lockCount do
        local target, isFw, isRelay = selectCollapseTarget(world, fromX, fromY, range, used)
        if not target then break end
        used[target] = true
        segs[#segs + 1] = { x1 = fromX, y1 = fromY, x2 = target.x, y2 = target.y }
        world:addFx("beam", { x1 = fromX, y1 = fromY, x2 = target.x, y2 = target.y, dur = 0.24 })
        local scale = math.max(0.5, 1 - (lockIndex - 1) * 0.18)
        if isFw then
            CombatSys.damageFirewall(world, target, O.collapseDamage * scale)
            lastIsHeavy = false
        elseif isRelay then
            CombatSys.damageRelay(world, target, O.collapseDamage * scale)
            lastIsHeavy = false
        else
            local baseDamage = (target.kind == "heavy") and O.collapseDamage or O.collapseNormalDamage
            CombatSys.damageEnemy(world, target, baseDamage * scale, true)
            lastIsHeavy = target.kind == "heavy"
            if target.dead and target.kind == "heavy" then
                local coreLevel = EndlessOverclock.mod(world, "collapse_core")
                if coreLevel > 0 then
                    local explosionScale = 0.45 + coreLevel * 0.10
                    for _, e in ipairs(world.enemies) do
                        if not e.dead and not used[e] and Util.dist(e.x, e.y, target.x, target.y) < 150 then
                            used[e] = true
                            CombatSys.damageEnemy(world, e,
                                O.collapseNormalDamage * explosionScale, false)
                        end
                    end
                    world:addFx("bigring", { x = target.x, y = target.y,
                        r = 150 + coreLevel * 12, color = "purple", dur = 0.45 })
                end
                local cascade = EndlessOverclock.mod(world, "collapse_cascade")
                if cascade > 0 then
                    local nearest, nearestIsFw, nearestIsRelay = selectCollapseTarget(world,
                        target.x, target.y, 180, used)
                    if nearest then
                        used[nearest] = true
                        if nearestIsFw then
                            CombatSys.damageFirewall(world, nearest, O.collapseDamage * 0.35 * cascade)
                        elseif nearestIsRelay then
                            CombatSys.damageRelay(world, nearest, O.collapseDamage * 0.35 * cascade)
                        else
                            CombatSys.damageEnemy(world, nearest,
                                O.collapseNormalDamage * 0.35 * cascade, false)
                        end
                        world:addFx("burst", { x = nearest.x, y = nearest.y, color = "purple", dur = 0.5 })
                    end
                end
                if EndlessOverclock.mod(world, "collapse_refund") > 0 then
                    world.collapseRefund = EndlessOverclock.mod(world, "collapse_refund")
                end
            end
        end
        fromX, fromY = target.x, target.y
        lastTarget = target
    end
    if not lastTarget then return false end
    if #segs >= 2 then
        world:addFx("chain", { segs = segs, dur = 0.28 })
    end
    world:addFx("shake", { power = 10, dur = 0.3 })
    world:emit("collapse_fire", lastTarget.x, lastTarget.y)
    return true
end

function CombatSys.update(world, dt, pressed)
    world.pulseCd = math.max(0, world.pulseCd - dt)
    world.collapseCd = math.max(0, world.collapseCd - dt)

    -- 自动连锁。间隔由本局链路优化决定（基于 Config 基础值计算，不改 Config）。
    world.chainTimer = world.chainTimer - dt
    if world.chainTimer <= 0 then
        world.chainTimer = RunShop.effectiveChainInterval(world)
        fireChain(world)
    end

    if pressed.pulse and world.pulseCd <= 0 then
        world.pulseCd = RunShop.effectivePulseCooldown(world)
        firePulse(world)
    end
    if pressed.collapse and world.collapseCd <= 0 then
        if fireCollapse(world) then
            local refund = world.collapseRefund or 0
            world.collapseRefund = nil
            world.collapseCd = math.max(0,
                RunShop.effectiveCollapseCooldown(world) - refund * 0.6)
        end
    end
end

return CombatSys
