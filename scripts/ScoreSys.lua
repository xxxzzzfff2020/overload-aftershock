-- ScoreSys.lua
-- 正式模式计分：战斗倍率、枯竭基础分与重启后才结算的风险分。

local Config = require "Config"
local MapDef = require "MapDef"
local ProtocolSys = require "ProtocolSys"

local ScoreSys = {}

local function addPopup(world, amount, pending)
    world:addFx("score", {
        x = world.player.x,
        y = world.player.y,
        text = string.format("%s+%d", pending and "风险 " or "", amount),
        dur = 0.9,
        color = pending and "yellow" or "cyan",
    })
end

local function addBanked(world, base, useMultiplier)
    local amount = math.floor(base * (useMultiplier and world.multiplier or 1))
    world.score = world.score + amount
    addPopup(world, amount, false)
    return amount
end

-- 玩家处于"过载攻击能力"阶段：过载本体与本层结尾的反猎窗口。
-- 反猎得分计入本层，World:finishAntiHunt 之前的所有增量都归属第 N 层。
local function combatPhase(world)
    return world.phase == "overload" or world.phase == "anti_hunt"
end

local function addRisk(world, amount)
    amount = math.floor(amount * ProtocolSys.scoreMultiplier(world, "risk"))
    world.riskScore = world.riskScore + amount
    world.riskActions = world.riskActions + 1
    addPopup(world, amount, true)
end

function ScoreSys.init(world)
    world.score = 0
    world.riskScore = 0
    world.multiplier = 1.0
    world.maxMultiplier = 1.0
    world.comboKills = 0
    world.bestCombo = 0
    world.comboLeft = 0
    world.huntKills = 0
    world.huntMarked = 0
    world.riskActions = 0
    world.riskSuccesses = 0
    world.luredPeak = 0
    world.lastLureAward = 0
    world.lostRiskScore = 0
    world.antiHuntChain = 0
    world.bestAntiHuntChain = 0
end

function ScoreSys.update(world, dt)
    if combatPhase(world) then
        if world.comboLeft > 0 then
            world.comboLeft = math.max(0, world.comboLeft - dt)
        elseif world.comboKills > 0 then
            world.comboKills = 0
            world.multiplier = math.max(1.0, world.multiplier - 0.5 * dt)
        end
    end
end

function ScoreSys.onKill(world, enemy)
    if not combatPhase(world) then return end
    local previousMultiplier = world.multiplier
    world.comboKills = world.comboKills + 1
    world.comboLeft = Config.SCORE.comboWindow
    world.bestCombo = math.max(world.bestCombo, world.comboKills)
    world.multiplier = math.min(Config.SCORE.multiplierMax,
        1 + math.floor(world.comboKills / Config.SCORE.multiplierStepKills) * 0.5)
    world.maxMultiplier = math.max(world.maxMultiplier, world.multiplier)
    if world.multiplier > previousMultiplier then world:emit("combo_up") end
    if world.layerStatMax then world:layerStatMax("maxCombo", world.comboKills) end

    local base = Config.SCORE.normalKill
    if enemy.kind == "sentinel" then base = Config.SCORE.sentinelKill end
    if enemy.kind == "heavy" then base = Config.SCORE.heavyKill end
    if enemy.kind == "drone" or enemy.kind == "glitch" then
        base = math.floor(base * ProtocolSys.scoreMultiplier(world, "normalKill"))
    end
    if ProtocolSys.has(world, "cluster") and world.comboKills >= 6 then
        base = base + Config.PROTOCOL.cluster.highComboBonus
    end
    -- 过载最后 N 秒的收尾奖励只属于过载本体的硬倒计时压力，反猎窗口不适用。
    if world.phase == "overload" and world.overloadLeft <= Config.OVERLOAD.lastWarnTime then
        base = base + Config.SCORE.lastSeconds
    end
    if world.layerStat then
        if enemy.kind == "heavy" then
            world:layerStat("heavyKills", 1)
        else
            world:layerStat("normalKills", 1)
        end
    end
    local antiHuntReward = 0
    if enemy.huntTarget and (enemy.huntLeft or 0) > 0 then
        world.antiHuntChain = (world.antiHuntChain or 0) + 1
        world.bestAntiHuntChain = math.max(world.bestAntiHuntChain or 0, world.antiHuntChain)
        local rewards = Config.ANTI_HUNT.rewards
        local reward = rewards[math.min(world.antiHuntChain, #rewards)] or Config.ANTI_HUNT.rewardCap
        base = base + reward
        antiHuntReward = reward
        world.huntKills = world.huntKills + 1
        if world.layerStat then world:layerStat("antiHuntKills", 1) end
        world:addFx("banner", { text = string.format("反猎连算 x%d  +%d", world.antiHuntChain, reward), dur = 1.0 })
        world:addFx("anti_hunt_burst", {
            x = enemy.x, y = enemy.y, reward = reward, dur = 0.72,
        })
        world:emit("anti_hunt_chain", enemy.x, enemy.y, reward)
    end
    local awarded = addBanked(world, base, true)
    -- 反猎奖励按本次击杀的实际倍率折算后记入本层反猎得分。
    if antiHuntReward > 0 and world.layerStat then
        local share = base > 0 and (antiHuntReward / base) or 0
        world:layerStat("antiHuntScore", math.floor(awarded * share))
    end
end

function ScoreSys.onEvent(world, name, value)
    -- 节点/中继/标记/连锁只可能在过载与反猎窗口中发生，倍率沿用当前连杀倍率。
    if name == "firewall_down" then
        addBanked(world, Config.SCORE.firewall * ProtocolSys.scoreMultiplier(world, "node"), true)
    elseif name == "relay_down" then
        addBanked(world, Config.SCORE.relay * ProtocolSys.scoreMultiplier(world, "node"), true)
    elseif name == "mark_trigger" then
        addBanked(world, Config.SCORE.markTrigger, true)
    elseif name == "chain_multi" and (value or 0) >= 3 then
        addBanked(world, Config.SCORE.multiChain * (value - 2), true)
    elseif world.phase == "depleted" then
        local heatLevel = world:heatLevel()
        if name == "cell_pickup" or name == "core_pickup" then
            if world:chasingCount() == 0 then
                addBanked(world, Config.SCORE.stealthCell, false)
            end
            local _, row = MapDef.toTile(world.player.x, world.player.y)
            if row <= (world.layout.dangerRows or 7) then
                addBanked(world, Config.SCORE.dangerResource, false)
            end
            if world.readyAt then addRisk(world, Config.SCORE.readyResourceRisk) end
        elseif name == "dismantle_done" and world:chasingCount() == 0 then
            addBanked(world, Config.SCORE.cleanDismantle, false)
        elseif name == "deep_done" then
            addRisk(world, Config.SCORE.hotDeep + heatLevel * 150)
        elseif name == "mark_set" then
            addBanked(world, Config.SCORE.markTarget, false)
        elseif name == "player_escaped" then
            addBanked(world, Config.SCORE.escape, false)
        end
    end
end

function ScoreSys.onReadyLure(world, chasing)
    world.luredPeak = math.max(world.luredPeak, chasing)
    if chasing > world.lastLureAward then
        local added = chasing - world.lastLureAward
        world.lastLureAward = chasing
        addRisk(world, Config.SCORE.lurePerEnemyRisk * added)
    end
end

function ScoreSys.onReadyRiskAction(world)
    addRisk(world, Config.SCORE.readyDwellRisk)
end

function ScoreSys.bankRestart(world)
    local banked = world.riskScore
    world.score = world.score + banked + Config.SCORE.restart
    if banked > 0 then world.riskSuccesses = world.riskSuccesses + 1 end
    world.riskScore = 0
    world.lastLureAward = 0
    addPopup(world, banked + Config.SCORE.restart, false)
    return banked
end

function ScoreSys.loseRisk(world)
    world.lostRiskScore = world.riskScore
    world.riskScore = 0
end

return ScoreSys
