-- World.lua
-- 核心玩法状态机:过载 ⇌ 枯竭 断崖切换、轮次、资源、残骸、标记、组件、防软锁。
-- 纯逻辑模块:不依赖渲染/引擎事件,可在 SelfTest 中独立驱动。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local EnemyAI = require "EnemyAI"
local CombatSys = require "CombatSys"
local Pathfinding = require "Pathfinding"
local Profiles = require "ExperimentProfiles"
local ScenarioLayouts = require "ScenarioLayouts"
local TraceHeat = require "TraceHeat"
local ScoreSys = require "ScoreSys"
local LayerPlan = require "LayerPlan"
local SignalBlackout = require "SignalBlackout"
local ProtocolSys = require "ProtocolSys"
local RunShop = require "RunShop"
local RunFlow = require "RunFlow"
local ChallengeCheckpoint = require "ChallengeCheckpoint"
local GraduationArchive = require "GraduationArchive"
local EndlessOverclock = require "EndlessOverclock"
local EndlessCheckpoint = require "EndlessCheckpoint"

-- 事件 → 试玩计数器映射(§任务包F:统计不影响玩法,只累计)
local EVENT_COUNTERS = {
    enemy_alert = "spotted",
    enemy_chase = "chased",
    player_escaped = "escaped",
    cell_pickup = "cells",
    core_pickup = "cores",
    dismantle_done = "dismantled",
    mark_set = "marks",
    craft_done = "crafted",
    jammer_used = "jammer",
    decoy_placed = "decoy",
    cloak_on = "cloak",
    heavy_down = "heavyKills",
    firewall_down = "nodes",
    mark_trigger = "markTriggers",
    -- [R2] 风险收益链
    relay_down = "relays",
    deep_done = "deepDone",
    deep_start = "deepTries",
    recon_pulse = "recon",
    heat_up = "heatUps",
    heat_investigate = "investigations",
    scan_hit = "scanHits",
    hunter_protocol = "hunterActivations",
    anti_hunt_chain = "antiHuntKills",
    map_switch = "mapSwitches",
    milestone_10 = "milestones",
    wreck_data = "wreckData",
    shop_purchase = "shopPurchases",
    heat_lock_hunter = "lockHunters",
    anti_hunt_start = "antiHuntWindows",
}

-- 事件 → 追踪热度噪声(§R2任务包C 8.1;仅实验B枯竭阶段生效,TraceHeat 内部判断)
local HEAT_EVENTS = {
    dismantle_done = "addDismantle",
    jammer_used = "addJammer",
    decoy_placed = "addDecoy",
    mark_set = "addMark",
    craft_done = "addCraft",
    enemy_alert = "addSpotted",
    recon_pulse = "addRecon",
}

local World = {}
World.__index = World

-- [R2] opts = { experiment = "A"|"B", seed = number, startLayer = number? }
-- 每个 World 实例持有自己的实验 flags 与布局(测试/模拟互不串)
function World.New(opts)
    local self = setmetatable({}, World)
    self:init(opts)
    return self
end

function World:init(opts)
    opts = opts or {}
    self.experimentId = opts.experiment or Profiles.selected
    self.exp = Profiles.flags(self.experimentId)
    self.seed = opts.seed or 0
    self.endlessRunSeed = opts.endlessSeed or self.seed
    -- 启动倒计时只允许测试或 Review 受控样本显式跳过；正式入口不传这些标志。
    self.reviewOnly = opts.reviewOnly == true
    self.testMode = opts.testMode == true
    self.skipLayerIntro = opts.skipLayerIntro == true and (self.reviewOnly or self.testMode)
    -- World 是可复现性的边界：相同 seed 重新创建必须得到相同布局、刷点与机会。
    math.randomseed(self.seed)
    self.layout = nil
    self.map, self.mapDef, self.mapId = nil, nil, nil
    self.solid = nil
    self.gateOpen = false
    self.laserActive = true
    self.layerPlan = nil
    self.protocols = {}
    self.protocolLabel = ""

    -- 阶段时间线：layer_intro → overload → depleted →(重启)→ anti_hunt → layer_settlement
    self.phase = "none" --[[@as string]] -- layer_intro | overload | depleted | anti_hunt | layer_settlement | dead
    self.phaseBeforeDeath = nil
    self.phaseTimeBeforeDeath = nil
    self.layerIntroTimer = 0
    self.layerIntroCue = nil
    -- startLayer仅供隔离Review候选创建真实层起点；正式main从不传入，默认仍从第1层开始。
    local startLayer = math.max(1, math.floor(tonumber(opts.startLayer) or 1))
    self.round = startLayer - 1
    self.restarts = 0
    self.timeAlive = 0
    self.phaseTime = 0
    -- 正式流程信号：由 main.lua 消费并打开结算/整备。Review 入口可以直接忽略。
    self.pendingSignal = nil
    self.antiHuntTimer = 0
    self.antiHuntElapsed = 0
    self.antiHuntResolveTimer = nil
    self.antiHuntResolved = false
    self.antiHuntSnapshot = nil
    self.layerSettlement = nil       -- 层结算快照(Render 读取)
    self.runComplete = false         -- 第10层通关已达成
    self.endless = opts.endless == true -- 已选择继续无尽
    self.challengeCompleted = false  -- 本局记录"完成挑战"
    self.runId = opts.runId
    self.cleanRun = true
    self.recoveredRun = false
    self.checkpointRecovery = false
    self.challengeRetry = false
    self.challengeRetryCount = 0
    self.challengeCheckpointAvailable = false
    self.checkpointReady = false
    -- 本局协议整备：升级只在本局有效，死亡随 World 丢弃，不写存档/云/榜。
    self.runUpgrades = RunShop.newUpgrades()
    self.wreckData = 0               -- 残骸数据(拆解普通重型残骸产出)
    self.shopPurchases = 0

    self.player = {
        x = 0, y = 0, hp = Config.PLAYER.maxHp, maxHp = Config.PLAYER.maxHp,
        radius = Config.PLAYER.radius, faceAngle = 0, moving = false,
        hurtFlash = 0,
    }

    self.enemies = {}
    self.enemyPool = Util.newPool()
    self.cells = {}              -- 基础储能组件掉落物
    self.cores = {}              -- 高级核心掉落物(地图堆 + 残骸产出)
    self.wrecks = {}             -- 重型残骸
    self.decoys = {}
    self.fx = {}                 -- 视觉特效(Render 读取)
    self.fxPool = Util.newPool()
    self.systemPrompts = {}      -- 高优先级系统提示；只推进队首，避免提示互相覆盖/未显示即过期
    self.events = {}             -- 音频/日志事件队列(main 驱动 AudioSys)
    SignalBlackout.attach(self)
    self.blackoutHintsShown = {} -- L4/L5短提示仅在本局各出现一次；不写Checkpoint/存档
    self.rewardedReviveState = "idle"
    self.rewardedReviveReason = nil
    self.rewardedReviveAttempted = false
    self.rewardedReviveUsed = false
    self.rewardedReviveCount = 0
    self.rewardedReviveMode = nil
    self.rewardedReviveTimeout = false
    self.rewardedReviveSoftTimeout = false
    self.reviveOffer = false
    self.reviveChoiceState = nil
    self.reviveChoiceMode = nil
    self.assistedRun = false

    self.energy = 0
    self.coreCount = 0
    self.energyNeed = Config.DEPLETED.restartEnergyBase
    self.modules = { capacitor = false, amplifier = false }  -- 已制作,下轮生效
    self.activeModules = { capacitor = false, amplifier = false } -- 本轮生效
    self.tools = { jammer = 0, decoy = 0, cloak = 0 }
    self.cloakLeft = 0
    self.mark = nil              -- { kind="enemy"|"firewall", ref=..., armed=bool }

    self.overloadLeft = 0
    self.overloadDuration = Config.OVERLOAD.duration
    self.pulseCd = 0
    self.collapseCd = 0
    self.chainTimer = 0
    self.hordeTimer = 0
    self.trackerTimer = 0
    self.trackerSpawnCount = 0
    self.overloadContactWindow = 0
    self.overloadContactLoss = 0

    self.dismantle = nil         -- { wreck=..., t=0 }
    self.restartChannel = nil    -- { t } 正式重启读条，启动后不可取消
    self.lastWarnSecond = -1

    -- 正式计分与反猎统计
    ScoreSys.init(self)
    self.huntTargetsLeft = 0
    self.antiHuntChain = 0
    self.readyRiskTimer = 0
    self.readyLureTimer = 0
    -- 每层统计（层结算读取，结算后清空；整局累计仍在 counters/score 中）
    self.layerStats = self:newLayerStats()

    -- [R1] 寻路缓存版本与统计
    self.pathVersion = 0
    self.pathSearches = 0
    -- [R1] 试玩计数器(整局累计;每轮切片由 PlaytestMetrics 完成)
    self.counters = {}

    -- [R2] 追踪热度(实验B;A 恒为 0)
    self.heat = 0
    self.heatQuietTimer = 0
    self.noiseX, self.noiseY = nil, nil
    self.investigateTimer = 0
    self.relayBonus = false            -- 本枯竭阶段:中继器已毁 → 热度增长降低
    self.relayDestroyedRound = 0
    -- [R2] 超额缓存与未结算收益
    self.pendingCache = 0              -- 重启结算后的缓存等级(下一轮过载生效)
    self.activeCache = 0               -- 本轮过载生效的缓存等级
    self.bonusCache = 0                -- 深层残骸赚到的缓存(本轮枯竭,未结算)
    self.readyAt = nil                 -- 本轮达到重启阈值的时刻(timeAlive)
    self.unbankedLoss = nil            -- 死亡时的未结算损失(结算页/metrics 读取)
    self.deepSpawnedRound = 0          -- 深层残骸每轮最多激活一次
    -- [R2] 侦察脉冲
    self.reconCd = 0
    self.reconLeft = 0
    self.reconAfterglowLeft = 0
    -- [R2] 过载优先目标
    self.opportunities = nil           -- { {kind, ref, label, benefit, done}, ... }
    self.lastOverloadSummary = nil     -- 跌落时的"你为枯竭留下了什么"
    self._ovSnap = nil                 -- 过载开始时的计数器快照(算成果)

    self.firewalls, self.relays = {}, {}
    local graduationArchive = GraduationArchive.normalize(opts.graduationArchive)
    local endlessCheckpoint = not graduationArchive
        and EndlessCheckpoint.normalize(opts.endlessCheckpoint) or nil
    local challengeCheckpoint = not graduationArchive and not endlessCheckpoint
        and ChallengeCheckpoint.normalize(opts.challengeCheckpoint) or nil
    if graduationArchive then
        GraduationArchive.applyBeforeLayer(self, graduationArchive)
    elseif endlessCheckpoint then
        EndlessCheckpoint.applyBeforeLayer(self, endlessCheckpoint)
    elseif challengeCheckpoint then
        ChallengeCheckpoint.applyBeforeLayer(self, challengeCheckpoint,
            opts.checkpointRecovered == true, opts.checkpointRetry == true)
    end

    -- 复活只允许回到最近一次已确认的层结算检查点。首层尚无结算，
    -- 因而初始检查点只包含空白本局状态；正式广告合同本身也禁止首层复活。
    self:saveReviveCheckpoint(self.round)
    self:startOverload(graduationArchive ~= nil
        or endlessCheckpoint ~= nil
        or (challengeCheckpoint ~= nil and challengeCheckpoint.nextLayer > 1))
    if endlessCheckpoint then
        EndlessCheckpoint.applyAfterLayerStart(self, endlessCheckpoint)
    end
    if challengeCheckpoint
        and challengeCheckpoint.checkpointState == ChallengeCheckpoint.L10_CHOICE then
        ChallengeCheckpoint.enterL10Choice(self)
    end
end

function World:emit(name, x, y, value)
    self.events[#self.events + 1] = { name = name, x = x, y = y, value = value }
    local counter = EVENT_COUNTERS[name]
    if counter then self:bump(counter) end
    ScoreSys.onEvent(self, name, value)
    -- [R2] 噪声行为 → 追踪热度(TraceHeat 内部判断实验/阶段)
    local heatKey = HEAT_EVENTS[name]
    if heatKey then
        TraceHeat.noise(self, Config.HEAT[heatKey], x or self.player.x, y or self.player.y)
    end
    if name == "player_escaped" then
        self:addFx("toast", { text = "已摆脱追击", dur = 1.2 })
    end
    if Config.DEBUG.log then print("[EVT] " .. name) end
end

-- [R2] 热度档位(0隐匿/1暴露/2追踪/3锁定;实验A恒0)
function World:heatLevel()
    if not self.exp.traceHeat then return 0 end
    return TraceHeat.level(self)
end

-- [R2] 当前储能超额可形成的缓存等级(仅显示与结算;实验A恒0)
function World:overflowLevel()
    if not self.exp.overflowCache then return 0 end
    if self.energy < self.energyNeed then return 0 end
    local lvl = math.floor((self.energy - self.energyNeed) / Config.RISK.overflowStep)
    return Util.clamp(lvl, 0, Config.RISK.overflowMax)
end

-- [R2] 重启时实际结算的缓存等级(储能超额 + 深层残骸加成,受上限)
function World:totalCacheLevel()
    if not self.exp.overflowCache then return 0 end
    return Util.clamp(self:overflowLevel() + self.bonusCache, 0, Config.RISK.overflowMax)
end

function World:bump(name, n)
    self.counters[name] = (self.counters[name] or 0) + (n or 1)
end

-- ============================================================
-- 每层统计。反猎得分与击杀归属第 N 层；层结算后清空，整局累计不受影响。
-- ============================================================
function World:newLayerStats()
    return {
        scoreAtLayerStart = self.score or 0,
        scoreGained = 0,
        normalKills = 0,
        heavyKills = 0,
        antiHuntKills = 0,
        antiHuntScore = 0,
        maxCombo = 0,
        coresGained = 0,
        wreckDataGained = 0,
        wrecksDismantled = 0,
        normalWrecksDismantled = 0,
        deepWrecks = 0,
        heatPeak = 0,
        toolsUsed = 0,
    }
end

function World:beginLayerStats()
    self.layerStats = self:newLayerStats()
end

-- 累加本层统计。层结算尚未打开前的所有增量都归属当前层。
function World:layerStat(name, n)
    local st = self.layerStats
    if not st then return end
    st[name] = (st[name] or 0) + (n or 1)
end

function World:layerStatMax(name, value)
    local st = self.layerStats
    if not st then return end
    if (value or 0) > (st[name] or 0) then st[name] = value end
end

-- 正式流程信号：World 只产生信号，由正式 main.lua 消费。
-- Review 入口不读取该字段，World 内部状态因此不会自动弹出正式商店。
function World:signal(name)
    self.pendingSignal = name
end

function World:consumeSignal()
    local s = self.pendingSignal
    self.pendingSignal = nil
    return s
end

-- 保存“协议整备已确认”后的安全检查点。只保存明确允许跨复活保留的
-- 已结算状态；当前层风险、临时资源、反猎链与未完成目标均不进入检查点。
function World:saveReviveCheckpoint(completedLayer)
    return RunFlow.saveReviveCheckpoint(self, completedLayer)
end

function World:chasingCount(radius)
    local count = 0
    local p = self.player
    local maxDist2 = radius and radius * radius or nil
    for _, e in ipairs(self.enemies) do
        if not e.dead and (e.state == "chase" or e.state == "alert") then
            if not maxDist2 or Util.dist2(e.x, e.y, p.x, p.y) <= maxDist2 then
                count = count + 1
            end
        end
    end
    return count
end

function World:interfereOverload(amount)
    if not self:inCombatPhase() then return end
    if self.overloadContactWindow <= 0 then
        self.overloadContactWindow = 1.0
        self.overloadContactLoss = 0
    end
    local room = Config.FORMAL.overloadContactLossCapPerSec - self.overloadContactLoss
    local loss = math.min(amount, math.max(0, room))
    if loss <= 0 then return end
    self.overloadContactLoss = self.overloadContactLoss + loss
    -- 反猎阶段不消耗过载倒计时（那是下一层的资源），只做接触反馈。
    if self.phase == "overload" then
        self.overloadLeft = math.max(0, self.overloadLeft - loss)
    end
end

-- 玩家处于"拥有过载攻击能力"的阶段：过载本体与本层结尾的反猎窗口。
function World:inCombatPhase()
    return self.phase == "overload" or self.phase == "anti_hunt"
end

function World:feedback(text)
    -- 同文案短时间内不重复弹
    for _, f in ipairs(self.fx) do
        if f.kind == "toast" and f.text == text then return end
    end
    self:addFx("toast", { text = text, dur = 1.4 })
end

local function promptPriority(text)
    text = tostring(text or "")
    if string.find(text, "新纪录", 1, true) then return 120 end
    if string.find(text, "离线", 1, true) or string.find(text, "断电", 1, true) then return 110 end
    if string.find(text, "重启条件", 1, true) then return 100 end
    if string.find(text, "反猎启动", 1, true) then return 95 end
    if string.find(text, "已结算", 1, true) then return 90 end
    if string.find(text, "标记引爆", 1, true) then return 80 end
    return 40
end

function World:clearTransientPrompts()
    self.systemPrompts = {}
    for _, f in ipairs(self.fx) do
        if f.kind == "toast" or f.kind == "score" then f.dead = true end
    end
    Util.compact(self.fx, self.fxPool)
end

-- 死亡结算保留战局，供广告安全复活读取；但不能让战斗特效/嵌套链路继续
-- 持有旧实体或渲染数据。完整释放 FX table 也会清除池化对象上的子表引用。
function World:clearTransientEffects()
    self.systemPrompts = {}
    for _, f in ipairs(self.fx) do f.dead = true end
    Util.compact(self.fx, self.fxPool)
end

function World:updateSystemPrompts(dt)
    local current = self.systemPrompts[1]
    if not current then return end
    current.age = current.age + dt
    if current.age >= current.dur then table.remove(self.systemPrompts, 1) end
end

function World:addFx(kind, t)
    -- 特效上限(§性能):极端情况下丢弃最旧特效,防止无界增长
    if #self.fx >= 300 then
        local oldest = table.remove(self.fx, 1)
        if oldest ~= nil then self.fxPool:release(oldest) end
    end
    t = t or {}
    t.kind = kind
    t.age = 0
    if kind == "banner" then
        t.dur = t.dur or 1.8
        t.priority = t.priority or promptPriority(t.text)
        local inserted = false
        for i, current in ipairs(self.systemPrompts) do
            if t.priority > current.priority then
                table.insert(self.systemPrompts, i, t)
                inserted = true
                break
            end
        end
        if not inserted then self.systemPrompts[#self.systemPrompts + 1] = t end
        while #self.systemPrompts > 6 do table.remove(self.systemPrompts) end
        return t
    end
    self.fx[#self.fx + 1] = t
    return t
end

-- ============================================================
-- 难度(§11)
-- ============================================================
function World:difficulty()
    local plan = self.layerPlan or LayerPlan.get(math.max(1, self.round))
    return ProtocolSys.adjustDifficulty(self, plan.difficulty)
end

function World:hasProtocol(id)
    return ProtocolSys.has(self, id)
end

function World:spawnEnemy(kind, x, y, patrolLoop, isHorde)
    local cfg = Config.ENEMIES[kind]
    local e = self.enemyPool:acquire()
    e.kind = kind
    e.x, e.y = x, y
    e.hp, e.maxHp = cfg.hp, cfg.hp
    e.radius = cfg.radius
    e.angle = math.random() * math.pi * 2
    e.state = "patrol"
    e.stateTime = 0
    e.suspicion = 0
    e.stun = 0
    e.daze = 0
    e.jammed = 0
    e.attackCd = 0
    e.dead = false
    e.isHorde = isHorde or false
    e.tracker = false
    e.patrol = patrolLoop
    e.patrolIdx = 1
    e.lastSeenX, e.lastSeenY = nil, nil
    e.decoyTarget = nil
    e.wanderTimer = 0
    e.roamTimer = 0
    e.roamX, e.roamY = nil, nil
    if self.layerPlan and self.layerPlan.fairGate then
        e.roaming = false
        e.investigating = false
        e.pressureWait = 0
        e.overflowHold = false
    end
    e.hitFlash = 0
    e.huntTarget = false
    e.huntLeft = 0
    e.hunter = false
    e.hunterScanTimer = 0
    e.hunterPulse = 0
    e.heavyWindup = 0
    e.guardTarget = nil
    e.path, e.pathIdx, e.pathTimer = nil, 1, 0
    e.pathTx, e.pathTy, e.pathVersion = nil, nil, -1
    e.stuckClock, e.stuckX, e.stuckY = 0, x, y
    e.wasChasing = false
    e.loseTimer = 0
    self.enemies[#self.enemies + 1] = e
    return e
end

-- 常驻巡逻单位:按当前轮次目标数量补齐(不清除现有存活单位)
function World:spawnPatrols()
    local diff = self:difficulty()
    local lay = self.layout
    local gate = self.layerPlan and self.layerPlan.fairGate or nil
    -- 基础巡逻(路线组合来自布局预设,§R2任务包F)
    local patrolIndices = gate and gate.basePatrolIndices or nil
    local function spawnBase(i)
        local p = lay.patrols[i]
        if not p then return end
        if not self:hasPatrolUnit("base" .. i) then
            local wp = p.loop[1]
            local x, y = MapDef.tileCenter(wp[1], wp[2])
            local e = self:spawnEnemy(p.kind, x, y, p.loop, false)
            e.patrolTag = "base" .. i
        end
    end
    if patrolIndices then
        for _, i in ipairs(patrolIndices) do spawnBase(i) end
    else
        for i = 1, #lay.patrols do spawnBase(i) end
    end
    -- 轮次追加巡逻
    for i = 1, diff.patrolExtra do
        local p = lay.extraPatrols[((i - 1) % #lay.extraPatrols) + 1]
        local tag = "extra" .. i
        if not self:hasPatrolUnit(tag) then
            local wp = p.loop[1]
            local x, y = MapDef.tileCenter(wp[1], wp[2])
            local e = self:spawnEnemy(p.kind, x, y, p.loop, false)
            e.patrolTag = tag
        end
    end
    -- 重型守卫(岗位顺序来自布局预设)
    local heavyAlive = 0
    for _, e in ipairs(self.enemies) do
        if e.kind == "heavy" and not e.dead then heavyAlive = heavyAlive + 1 end
    end
    for i = 1, diff.heavyCount - heavyAlive do
        local post = lay.heavyPosts[((i - 1) % #lay.heavyPosts) + 1]
        local x, y = MapDef.tileCenter(post[1], post[2])
        local e = self:spawnEnemy("heavy", x, y, { post }, false)
        e.patrolTag = "heavy" .. i .. "_" .. self.round
    end

    -- L10 only: lock the initial patrol phase, angle and optional deterministic
    -- position jitter into one auditable opening template.
    if gate and self.round == 10 and not self.fairOpeningTemplateApplied then
        local jitter = gate.openingPositionJitter or 0
        local patrolIndex = math.max(1, math.floor(gate.openingPatrolIndex or 1))
        local offsets = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
        local enemyIndex = 0
        for _, enemy in ipairs(self.enemies) do
            if not enemy.dead and not enemy.isHorde then
                enemyIndex = enemyIndex + 1
                if enemy.patrol and #enemy.patrol > 0 then
                    enemy.patrolIdx = math.min(patrolIndex, #enemy.patrol)
                    if gate.openingAngleMode == "path" and #enemy.patrol >= 2 then
                        local current = enemy.patrol[enemy.patrolIdx]
                        local nextIndex = enemy.patrolIdx % #enemy.patrol + 1
                        local nextPoint = enemy.patrol[nextIndex]
                        enemy.angle = math.atan(nextPoint[2] - current[2],
                            nextPoint[1] - current[1])
                    else
                        enemy.angle = 0
                    end
                else
                    enemy.angle = 0
                end
                if jitter ~= 0 then
                    local offset = offsets[(enemyIndex - 1) % #offsets + 1]
                    enemy.x = enemy.x + offset[1] * jitter
                    enemy.y = enemy.y + offset[2] * jitter
                end
            end
        end
        self.fairOpeningTemplateApplied = true
    end
end

function World:hasPatrolUnit(tag)
    for _, e in ipairs(self.enemies) do
        if not e.dead and e.patrolTag == tag then return true end
    end
    return false
end

-- ============================================================
-- [R2] 过载优先目标(§R2任务包D):重型残骸 / 防火墙捷径 / 追踪中继器,
-- 每轮从可用类别中激活两类。不硬性互斥,靠距离与时间压力形成取舍。
-- ============================================================
function World:pickOpportunities()
    self.opportunities = nil
    if not self.exp.opportunities then return end
    local p = self.player
    local cands = {}
    -- 目标1:重型守卫(最近存活)
    local heavy, hd = nil, math.huge
    for _, e in ipairs(self.enemies) do
        if not e.dead and e.kind == "heavy" then
            local d = Util.dist2(e.x, e.y, p.x, p.y)
            if d < hd then heavy, hd = e, d end
        end
    end
    if heavy then
        cands[#cands + 1] = { kind = "heavy", ref = heavy,
            label = "重型守卫", benefit = "击毁 → 枯竭期可拆解高级残骸" }
    end
    -- 目标2:防火墙节点(最近存活)
    local fw, fd = nil, math.huge
    for _, f in ipairs(self.firewalls) do
        if not f.dead then
            local d = Util.dist2(f.x, f.y, p.x, p.y)
            if d < fd then fw, fd = f, d end
        end
    end
    if fw then
        cands[#cands + 1] = { kind = "firewall", ref = fw,
            label = fw.name, benefit = "击毁 → " .. fw.desc }
    end
    -- 目标3:追踪中继器
    for _, rl in ipairs(self.relays) do
        if not rl.dead then
            cands[#cands + 1] = { kind = "relay", ref = rl,
                label = "追踪中继器", benefit = "击毁 → 下一枯竭期追踪增长 -40%" }
            break
        end
    end
    if #cands == 0 then return end
    -- 激活两类(不足两类则全部)
    while #cands > 2 do
        table.remove(cands, math.random(#cands))
    end
    -- 坐标快照(目标死亡后 ref 可能被对象池回收清空,读取只走 op.x/op.y/op.done)
    for _, op in ipairs(cands) do
        op.x, op.y = op.ref.x, op.ref.y
        op.done = false
    end
    self.opportunities = cands
end

-- 每帧维护机会状态:完成标记 + 移动目标坐标刷新(过载阶段)
function World:updateOpportunities()
    if not self.opportunities then return end
    for _, op in ipairs(self.opportunities) do
        if not op.done then
            local ref = op.ref
            if ref == nil or ref.dead or ref.x == nil then
                op.done = true
                op.ref = nil
            else
                op.x, op.y = ref.x, ref.y
            end
        end
    end
end

-- [R2] 中继器被摧毁(仅过载阶段可被攻击)
function World:onRelayDestroyed(rl)
    rl.dead = true
    self.relayDestroyedRound = self.round
    self:addFx("bigring", { x = rl.x, y = rl.y, r = 150, color = "green", dur = 0.6 })
    self:addFx("banner", { text = "追踪中继器已摧毁:下一枯竭期追踪增长降低", dur = 2.0 })
    self:emit("relay_down", rl.x, rl.y)
end

-- ============================================================
-- 阶段切换(核心合同 §2 / §5.2 / §15.3)
--
-- 正式阶段时间线（每层）：
--   overload（过载，硬倒计时）
--     → depleted（枯竭，搜集储能 / 诱敌）
--     → 主动重启读条 → anti_hunt（反猎，本层结尾，不加层不换图）
--     → layer_settlement（层结算）
--     → 协议整备（由正式 main 打开）
--     → 下一层 overload
-- ============================================================

-- 进入下一层的过载阶段。层号在此处 +1，地图/协议/难度在此处应用。
-- carryOver=true 表示这是由层推进进入（非本局第一层），需要播报组件/缓存生效。
function World:startOverload(carryOver)
    return RunFlow.startOverload(self, carryOver)
end

-- 地图、敌人和 HUD 已经准备完成后，只切换正式过载能力与计时。
function World:activateOverload()
    return RunFlow.activateOverload(self)
end

function World:updateLayerIntro(dt)
    return RunFlow.updateLayerIntro(self, dt)
end

-- ============================================================
-- 反猎阶段（本层结尾）。重启完成后立刻进入：
--   不加层、不加载下一层地图、不应用下一层协议、不启动下一层过载倒计时；
--   保持当前层地图，把当前追击者转为反猎目标，玩家获得过载攻击能力，
--   普通刷怪停止，本层反猎计时开始。
-- ============================================================
function World:startAntiHunt()
    return RunFlow.startAntiHunt(self)
end

-- 反猎窗口结束：清理当前层敌人、攻击、特效与追击状态，保存本层统计，进入层结算。
function World:finishAntiHunt()
    return RunFlow.finishAntiHunt(self)
end

-- 层结算快照。反猎得分与击杀已经在本层统计里，不再记入第 N+1 层。
function World:buildLayerSettlement()
    return RunFlow.buildLayerSettlement(self)
end

-- 正式流程：整备完成后推进到下一层。层结算统计在此清空。
function World:advanceLayer()
    return RunFlow.advanceLayer(self)
end

-- 第10层选择"继续无尽"：保留本局升级、资源与分数，启用无尽热度规则。
function World:chooseEndless()
    return RunFlow.chooseEndless(self)
end

-- 第10层选择"完成挑战"：正常结束本局，记录完成挑战，进入整局结算。
function World:completeChallenge()
    return RunFlow.completeChallenge(self)
end

-- 协议整备购买。只在层结算阶段可用；消费不改变已获得的分数，也不提供分数倍率。
function World:buyRunUpgrade(itemId)
    return RunFlow.buyRunUpgrade(self, itemId)
end

-- 强制跌落:同一瞬间完成全部剥夺(§5.2 禁止平滑过渡)
function World:forceDrop()
    -- 在强制断电前由World保存最后可见状态；Render永远不写游戏状态。
    SignalBlackout.capture(self)
    self:clearTransientPrompts()
    self.phase = "depleted"
    self.phaseTime = 0
    self.chainTimer = 0
    self.pulseCd, self.collapseCd = 0, 0
    self.dismantle = nil
    self.restartChannel = nil
    self.readyRiskTimer = 0
    self.readyLureTimer = 0
    self.lastLureAward = 0
    self.activeModules.capacitor = false
    self.activeModules.amplifier = false
    -- 下一次重启需求来自正式层表，避免与敌群压力在同一层同时指数增长。
    self.energyNeed = self:difficulty().energyNeed
    -- 工具补充：本层次数 = Config 基础次数 + 本局协议整备加成。
    -- 必须走 RunShop.effective*，否则 forceDrop 会把升级效果覆盖掉。
    self.tools.jammer = RunShop.effectiveJammerUses(self)
    self.tools.decoy = RunShop.effectiveDecoyUses(self)
    self.tools.cloak = RunShop.effectiveCloakUses(self)
    -- 敌群处理:远处割草怪回收,近处短暂失神(§17/§18.1,不凭空清屏)
    local p = self.player
    -- 第1轮宽容度:失神加时,首次跌落不至于立刻被围死(§13.5)
    local fairGate = self.layerPlan and self.layerPlan.fairGate or nil
    local endless = self.endless == true and self.round >= 11
    local endlessIndex = endless and math.min(6, math.max(1, self.round - 10)) or 1
    local grace = Config.PLAYER.dropGraceTime
        + ((self.round == 1) and Config.ROUNDS.firstDropGraceBonus or 0)
        + (fairGate and fairGate.dropGraceBonus or 0)
        + (endless and (Config.ENDLESS.dropGrace[endlessIndex] or 0) or 0)
    if fairGate or endless then
        for _, e in ipairs(self.enemies) do
            if not e.dead then
                e.daze = grace
                e.state = "patrol"
                e.suspicion = 0
                e.stateTime = 0
                e.roaming = false
                e.investigating = false
                e.pressureWait = 0
                if e.isHorde then
                    -- 020R overflow behavior: keep every L10 Horde alive and
                    -- return it to a killable hold point instead of deleting it.
                    local col, row = MapDef.toTile(e.x, e.y)
                    e.patrol = { { col, row } }
                    e.patrolIdx = 1
                    e.state = "return"
                    e.overflowHold = true
                end
            end
        end
    else
        for _, e in ipairs(self.enemies) do
            if not e.dead then
                if e.isHorde and Util.dist(e.x, e.y, p.x, p.y) > Config.AI.hordeDespawnDist then
                    e.dead = true
                else
                    e.daze = grace
                    e.state = "patrol"
                    e.suspicion = 0
                    e.stateTime = 0
                end
            end
        end
    end
    self:respawnCells()
    -- [R2] 本枯竭阶段状态复位:达标/未结算/深层/侦察/热度峰值
    self.readyAt = nil
    self.bonusCache = 0
    self._readySnap = nil
    self.reconLeft = 0
    self.reconAfterglowLeft = 0
    self.heatPeakRound = self.heat or 0
    -- [R2] 中继器效果结转:本轮过载击毁 → 本枯竭期热度增长降低
    self.relayBonus = self.exp.opportunities and (self.relayDestroyedRound == self.round)
    ProtocolSys.onForceDrop(self)
    -- [R2] 过载成果总结(§9.3:你为枯竭阶段留下了什么)
    if self.exp.opportunities and self._ovSnap then
        local parts = {}
        local wrecksGot = (self.counters.heavyKills or 0) - self._ovSnap.heavyKills
        local nodesGot = (self.counters.nodes or 0) - self._ovSnap.nodes
        if wrecksGot > 0 then parts[#parts + 1] = "残骸 x" .. wrecksGot end
        if nodesGot > 0 then parts[#parts + 1] = "路线捷径 x" .. nodesGot end
        if self.relayBonus then parts[#parts + 1] = "追踪增长 -40%" end
        if #parts > 0 then
            self.lastOverloadSummary = "本轮为枯竭留下:" .. table.concat(parts, " · ")
        else
            self.lastOverloadSummary = "本轮未完成任何优先目标"
        end
        self:addFx("banner", { text = self.lastOverloadSummary, dur = 2.6 })
    end
    self.opportunities = nil
    -- 断崖表现(§任务包D 8.2):0.15s 视觉冲击停顿(仅视觉,不影响逻辑计时)+ 离线横幅
    -- 039B：追加一道从玩家位置扩散的能量收束环（复用既有bigring），
    -- 让“力量被抽离”在过载→枯竭切换瞬间有明确的静帧可读语义。
    self:addFx("hitstop", { dur = 0.15 })
    self:addFx("phaseflash", { color = "depleted", dur = 0.7 })
    self:addFx("bigring", { x = self.player.x, y = self.player.y,
        r = Config.FORMAL.huntMarkRadius * 0.9, color = "purple", dur = 0.55 })
    self:addFx("banner", { text = "协处理器离线 — 搜集储能以重启", dur = 2.4 })
    if self.round == 4 and not self.blackoutHintsShown[4] then
        self.blackoutHintsShown[4] = true
        self:addFx("banner", {
            text = "信号开始衰减。黑障之外只保留最后已知情报。",
            dur = 3.4,
        })
    elseif self.round == 5 and not self.blackoutHintsShown[5] then
        self.blackoutHintsShown[5] = true
        self:addFx("banner", {
            text = "侦察可以临时恢复远端感知，标记可以持续追踪目标。",
            dur = 3.6,
        })
    end
    self:emit("overload_end")
    if Config.DEBUG.log then
        print(string.format("[WORLD] Round %d DEPLETED (need=%d)", self.round, self.energyNeed))
    end
end

-- 在远离玩家的刷新点补刷一个储能(带抖动;§18.2 供给无限但节流,永不软锁)
function World:spawnOneCell(spots, route)
    local p = self.player
    local fairGate = self.layerPlan and self.layerPlan.fairGate or nil
    if not spots and fairGate then
        local recoveryAlive = 0
        for _, cell in ipairs(self.cells) do
            if not cell.dead and cell.route == "recovery" then recoveryAlive = recoveryAlive + 1 end
        end
        if recoveryAlive < (fairGate.recoveryCellSlots or 0) then
            spots, route = fairGate.recoveryCellSpots, "recovery"
        else
            spots, route = fairGate.riskCellSpots, "risk"
        end
    end
    spots = spots or self.layout.cellSpots
    local pick = nil
    for _ = 1, 10 do
        local s = spots[math.random(#spots)]
        local x, y = MapDef.tileCenter(s[1], s[2])
        if Util.dist(x, y, p.x, p.y) >= Config.DEPLETED.cellMinPlayerDist then
            pick = s
            break
        end
    end
    pick = pick or spots[math.random(#spots)]
    local x, y = MapDef.tileCenter(pick[1], pick[2])
    -- 恢复线使用经LOS审计的格心，避免随机抖动把唯一安全点推回巡逻视野；
    -- 风险线与其它层仍保留原有抖动和不确定性。
    if route ~= "recovery" then
        x = x + (math.random() - 0.5) * Config.TILE * 0.6
        y = y + (math.random() - 0.5) * Config.TILE * 0.6
    end
    self.cells[#self.cells + 1] = { x = x, y = y, dead = false, route = route }
end

-- 基础储能刷新(防软锁 §18.2):跌落时铺满限量,之后限量补刷
function World:respawnCells()
    for _, c in ipairs(self.cells) do c.dead = true end
    Util.compact(self.cells)
    for _ = 1, Config.DEPLETED.maxActiveCells do
        self:spawnOneCell()
    end
    self.cellSpawnTimer = Config.DEPLETED.cellRespawnDelay
end

function World:die()
    return RunFlow.die(self)
end

-- 激励成功后的安全复活：不重启层、不重复结算任何分数，只清理当前围攻与积压攻击。
function World:reviveAssisted()
    return RunFlow.reviveAssisted(self)
end

-- ============================================================
-- 伤害
-- ============================================================
function World:damagePlayer(amount, srcX, srcY)
    if self.phase == "layer_intro" or self.phase == "dead"
        or self.phase == "layer_settlement" then return end
    local mul = self:inCombatPhase() and Config.PLAYER.overloadDamageTaken
        or Config.PLAYER.depletedDamageTaken
    local p = self.player
    p.hp = p.hp - amount * mul
    p.hurtFlash = 0.25
    self:bump("damageTaken", amount * mul)
    -- 正式重启启动后不可取消；玩家仍持续受伤，读条前归零则死亡。
    self:emit("player_hurt", srcX, srcY)
    if p.hp <= 0 then
        p.hp = 0
        self:die()
    end
end

-- ============================================================
-- 玩家移动 + 碰撞(圆 vs 格,分轴)
-- ============================================================
function World:isSolidAt(x, y)
    local c, r = MapDef.toTile(x, y)
    if c < 1 or r < 1 or c > self.map.w or r > self.map.h then return true end
    return self.solid[r][c]
end

function World:circleBlocked(x, y, radius)
    -- 采样圆周 4 向 + 4 斜角
    local r = radius
    if self:isSolidAt(x - r, y) or self:isSolidAt(x + r, y)
        or self:isSolidAt(x, y - r) or self:isSolidAt(x, y + r) then
        return true
    end
    local d = r * 0.7071
    return self:isSolidAt(x - d, y - d) or self:isSolidAt(x + d, y - d)
        or self:isSolidAt(x - d, y + d) or self:isSolidAt(x + d, y + d)
end

function World:moveCircle(ent, dx, dy)
    if dx ~= 0 then
        local nx = ent.x + dx
        if not self:circleBlocked(nx, ent.y, ent.radius) then ent.x = nx end
    end
    if dy ~= 0 then
        local ny = ent.y + dy
        if not self:circleBlocked(ent.x, ny, ent.radius) then ent.y = ny end
    end
end

-- 卡墙修正(§18.5):若中心落入实心格,推回最近地面格
function World:unstuck(ent)
    if not self:isSolidAt(ent.x, ent.y) then return end
    local c, r = MapDef.toTile(ent.x, ent.y)
    for radius = 1, 6 do
        for dr = -radius, radius do
            for dc = -radius, radius do
                local nc, nr = c + dc, r + dr
                if nc >= 1 and nr >= 1 and nc <= self.map.w and nr <= self.map.h
                    and not self.solid[nr][nc] then
                    ent.x, ent.y = MapDef.tileCenter(nc, nr)
                    return
                end
            end
        end
    end
end

-- ============================================================
-- 防火墙摧毁 → 永久路线改变(§7.2)
-- ============================================================
function World:onFirewallDestroyed(fw)
    fw.dead = true
    if fw.effect == "gate" then
        self.gateOpen = true
        for _, t in ipairs(self.map.gateTiles) do
            self.solid[t.row][t.col] = false
        end
        self:addFx("banner", { text = "捷径已打开!", dur = 2.2 })
    elseif fw.effect == "laser" then
        self.laserActive = false
        self:addFx("banner", { text = "激光走廊已关闭!", dur = 2.2 })
    end
    self:addFx("ring", { x = fw.x, y = fw.y, r = 180, color = "cyan", dur = 0.6 })
    self:emit("firewall_down", fw.x, fw.y)
    if self.mark and self.mark.ref == fw then self.mark = nil end
    -- 地形通行性变化 → 全部敌人路径缓存失效(§任务包C 7.1)
    Pathfinding.invalidate(self)
end

-- ============================================================
-- 标记(§7.3):枯竭阶段设置,下一轮过载首击引爆
-- ============================================================
function World:findMarkTarget()
    local p = self.player
    local best, bestD = nil, Config.DEPLETED.markRange
    for _, e in ipairs(self.enemies) do
        if not e.dead and (e.kind == "heavy" or e.kind == "sentinel") then
            local d = Util.dist(e.x, e.y, p.x, p.y)
            if d < bestD then best, bestD = e, d end
        end
    end
    for _, f in ipairs(self.firewalls) do
        if not f.dead then
            local d = Util.dist(f.x, f.y, p.x, p.y)
            if d < bestD then best, bestD = f, d end
        end
    end
    return best
end

function World:trySetMark()
    if self.phase ~= "depleted" then
        self:feedback("只能在算力耗尽阶段标记")
        return
    end
    local target = self:findMarkTarget()
    if not target then
        self:feedback("范围内没有可标记目标")
        return
    end
    self.mark = { ref = target, armed = false }
    self:addFx("ring", { x = target.x, y = target.y, r = 60, color = "yellow", dur = 0.5 })
    self:emit("mark_set", target.x, target.y)
end

-- ============================================================
-- 工具(§8.4-8.6)
-- ============================================================
function World:deferPressureRelock()
    local gate = self.layerPlan and self.layerPlan.fairGate
    if gate and gate.postToolRelockGap then
        self.postToolRelockTimer = math.max(self.postToolRelockTimer or 0,
            gate.postToolRelockGap)
    end
end

function World:useJammer()
    if self.phase ~= "depleted" then return end
    if self.tools.jammer <= 0 then
        self:feedback("干扰弹已用完")
        return
    end
    local p = self.player
    local gate = self.layerPlan and self.layerPlan.fairGate
    local jammerRange = Config.DEPLETED.jammerRange
        * (1 + EndlessOverclock.mod(self, "signal_jam") * 0.18)
    local best, bestD = nil, jammerRange
    for _, e in ipairs(self.enemies) do
        if not e.dead then
            local d = Util.dist(e.x, e.y, p.x, p.y)
            if d < bestD then best, bestD = e, d end
        end
    end
    if not best then
        if self.mapId == "firewall_core" and self.scan
            and (self.scan.state == "warning" or self.scan.state == "active") then
            self.tools.jammer = self.tools.jammer - 1
            self:layerStat("toolsUsed", 1)
            ProtocolSys.onJammer(self)
            self:deferPressureRelock()
            self:emit("jammer_used", p.x, p.y)
            self:addFx("toast", { text = "扫描信号已干扰", dur = 1.2 })
            return
        end
        self:feedback("范围内没有敌人")
        return
    end
    self.tools.jammer = self.tools.jammer - 1
    self:layerStat("toolsUsed", 1)
    best.jammed = Config.DEPLETED.jammerDuration
    best.state = "patrol"
    best.suspicion = 0
    if gate then
        best.pressureWait = Config.DEPLETED.jammerDuration
        best.roaming = false
        best.investigating = false
    end
    self:addFx("zap", { x1 = p.x, y1 = p.y, x2 = best.x, y2 = best.y, color = "blue", dur = 0.3 })
    ProtocolSys.onJammer(self)
    self:deferPressureRelock()
    self:emit("jammer_used", best.x, best.y)
end

function World:useDecoy()
    if self.phase ~= "depleted" then return end
    if self.tools.decoy <= 0 then
        self:feedback("诱饵信标已用完")
        return
    end
    self.tools.decoy = self.tools.decoy - 1
    self:layerStat("toolsUsed", 1)
    local p = self.player
    local decoyDuration = Config.DEPLETED.decoyDuration
        * (1 + EndlessOverclock.mod(self, "signal_decoy") * 0.16)
    self.decoys[#self.decoys + 1] = { x = p.x, y = p.y, left = decoyDuration, dead = false }
    if EndlessOverclock.mod(self, "signal_decoy") >= 2 then
        self:addFx("ring", { x = p.x, y = p.y, r = 92, color = "purple", dur = 0.7 })
    end
    self:deferPressureRelock()
    self:addFx("toast", { text = "诱饵已部署 · 立刻移动脱离", dur = 1.2 })
    self:emit("decoy_placed", p.x, p.y)
end

function World:useCloak()
    if self.phase ~= "depleted" then return end
    if self.cloakLeft > 0 then return end
    if self.tools.cloak <= 0 then
        self:feedback("光学隐身已用完")
        return
    end
    self.tools.cloak = self.tools.cloak - 1
    self:layerStat("toolsUsed", 1)
    self.cloakLeft = Config.DEPLETED.cloakDuration
        * (1 + EndlessOverclock.mod(self, "signal_cloak") * 0.2)
    local gate = self.layerPlan and self.layerPlan.fairGate
    if gate then
        -- L10 fair-gate escape semantics: an ordinary active chase immediately
        -- continues from the last exposed point as search; ordinary alert units
        -- return to patrol and wait for the relock window to end. Hunters keep
        -- their existing last-point semantics.
        for _, enemy in ipairs(self.enemies) do
            if not enemy.dead and not enemy.hunter then
                if enemy.state == "chase" then
                    enemy.state = "search"
                    enemy.stateTime = 0
                    enemy.wanderTimer = 0
                    enemy.lastSeenX, enemy.lastSeenY = self.player.x, self.player.y
                    enemy.wasChasing = true
                    enemy.investigating = false
                    Pathfinding.clear(enemy)
                elseif enemy.state == "alert" then
                    enemy.state = "patrol"
                    enemy.stateTime = 0
                    enemy.suspicion = 0
                    enemy.pressureWait = 0.8
                    enemy.roaming = false
                    enemy.investigating = false
                end
            end
        end
    end
    self:deferPressureRelock()
    self:addFx("toast", { text = "光学断链 · 离开最后暴露位置", dur = 1.2 })
    self:emit("cloak_on")
end

-- ============================================================
-- 制作(§12)
-- ============================================================
function World:craft(which)
    if self.phase ~= "depleted" then
        self:feedback("只能在算力耗尽阶段制作")
        return
    end
    local m = Config.MODULES[which]
    if not m then return end
    if self.modules[which] then
        self:feedback(m.name .. " 已装配")
        return
    end
    if self.coreCount < m.cost then
        self:feedback("核心不足(需要 " .. m.cost .. " 核心)")
        return
    end
    self.coreCount = self.coreCount - m.cost
    self.modules[which] = true
    self:addFx("banner", { text = m.name .. " 已装配(下轮生效)", dur = 1.8 })
    self:emit("craft_done")
end

-- ============================================================
-- 拆解(§7.1)
-- ============================================================
function World:nearestWreck()
    local p = self.player
    for _, w in ipairs(self.wrecks) do
        if not w.dead and Util.dist(w.x, w.y, p.x, p.y) < Config.DEPLETED.interactRange then
            return w
        end
    end
    return nil
end

function World:startDismantle()
    if self.phase ~= "depleted" then
        self:feedback("过载中无法拆解")
        return
    end
    local w = self:nearestWreck()
    if not w then
        self:feedback("附近没有可拆解的残骸")
        return
    end
    self.dismantle = { wreck = w, t = 0 }
    -- [R2] 深层残骸:开始拆解会惊动附近敌人 + 提高热度(§7.3)
    if w.deep then
        local R = Config.RISK
        for _, e in ipairs(self.enemies) do
            if not e.dead and e.jammed <= 0
                and Util.dist(e.x, e.y, w.x, w.y) < R.deepAlertRadius then
                if e.state == "patrol" or e.state == "return" then
                    e.state = "suspect"
                    e.stateTime = 0
                    e.suspicion = R.deepAlertSuspicion
                end
            end
        end
        TraceHeat.noise(self, Config.HEAT.addDeepDismantle, w.x, w.y)
        self:emit("deep_start", w.x, w.y)
    end
    self:emit("dismantle_start", w.x, w.y)
end

-- [R2] 深层数据残骸(§7.3):达标后激活,每轮最多一个,位于高危位置
function World:spawnDeepWreck()
    if not self.exp.deepWreck then return end
    if self.deepSpawnedRound == self.round then return end
    self.deepSpawnedRound = self.round
    local p = self.player
    local spots = self.layout.deepSpots
    -- 选距玩家最远的候选(保证"远处的明确高收益目标")
    local pick, bestD = nil, -1
    for _, s in ipairs(spots) do
        local x, y = MapDef.tileCenter(s[1], s[2])
        local d = Util.dist(x, y, p.x, p.y)
        if d > bestD then pick, bestD = s, d end
    end
    if not pick then return end
    local x, y = MapDef.tileCenter(pick[1], pick[2])
    self.wrecks[#self.wrecks + 1] = { x = x, y = y, dead = false, deep = true }
    self:addFx("banner", { text = "检测到深层数据残骸(高危区域,高收益)", dur = 2.4 })
    self:addFx("ring", { x = x, y = y, r = 120, color = "yellow", dur = 1.0 })
    self:emit("deep_spawn", x, y)
end

-- 主动重启:先经过短暂引导读条(移动/受伤中断,§任务包D/I)
function World:tryRestart()
    if self.phase ~= "depleted" then return end
    if self.energy < self.energyNeed then
        self:feedback("储能不足,还差 " .. (self.energyNeed - self.energy))
        return
    end
    if self.restartChannel then return end
    local t = Config.FORMAL.restartChannelTime
    if t <= 0 then
        self:doRestart()
        return
    end
    self.restartChannel = { t = 0 }
    self:emit("restart_channel")
end

function World:doRestart()
    self.restartChannel = nil
    self.restarts = self.restarts + 1
    local riskBanked = ScoreSys.bankRestart(self)
    self:addFx("toast", { text = string.format("未结算风险分已结算 +%d", riskBanked), dur = 1.5 })
    -- 结算超额缓存：被计入缓存的储能一并消耗，余数继续结转。
    local cache = self:totalCacheLevel()
    local overflowUsed = math.min(self:overflowLevel(), cache) * Config.RISK.overflowStep
    self.energy = self.energy - self.energyNeed - overflowUsed
    if self.energy < 0 then self.energy = 0 end
    self.pendingCache = cache
    self.bonusCache = 0
    self.readyAt = nil
    self._readySnap = nil
    self:emit("overload_restart")
    -- 重启完成后进入本层反猎，而不是直接跳到下一层。
    self:startAntiHunt()
end

-- [R2] 侦察脉冲(§R2任务包E:复用标记按钮位,无常驻新按钮)
function World:tryRecon()
    if not self.exp.recon then return end
    if self.phase ~= "depleted" then return end
    if self.reconCd > 0 then
        self:feedback(string.format("侦察冷却中 %.0f 秒", math.ceil(self.reconCd)))
        return
    end
    self.reconCd = Config.RECON.cooldown
    self.reconLeft = Config.RECON.duration
    self.reconAfterglowLeft = 0
    self:emit("recon_pulse", self.player.x, self.player.y)
end

-- ============================================================
-- 主更新
-- ============================================================
---@param dt number
---@param input table  -- { moveX, moveY, pressed = { pulse, collapse, jammer, decoy, cloak, restart, dismantle, mark, craftCapacitor, craftAmplifier } }
function World:update(dt, input)
    if self.phase == "dead" then
        self.phaseTime = self.phaseTime + dt
        -- 结算页不能让旧 FX 永久停留；正常死亡路径会先清空，保留这段作为
        -- 防御性兜底，兼容历史存档/异常中断后进入 dead 的世界对象。
        for _, f in ipairs(self.fx) do
            f.age = f.age + dt
            if f.age >= (f.dur or 1) then f.dead = true end
        end
        Util.compact(self.fx, self.fxPool)
        self:updateSystemPrompts(dt)
        return
    end
    -- 层结算：正式流程在这里等待玩家确认整备，世界逻辑冻结（不再刷怪/受伤/计时）。
    -- 但特效/提示仍要老化，否则整备期间的 toast 永不消失，反馈也会被去重卡住。
    if self.phase == "layer_settlement" then
        self.phaseTime = self.phaseTime + dt
        RunShop.tick(self, dt)
        for _, f in ipairs(self.fx) do
            f.age = f.age + dt
            if f.age >= (f.dur or 1) then f.dead = true end
        end
        Util.compact(self.fx, self.fxPool)
        self:updateSystemPrompts(dt)
        return
    end
    -- 启动倒计时：地图与 HUD 已完成绘制，但整个世界模拟冻结。这里只推进受生命周期
    -- 闸门控制的阶段计时，因此切后台时不会流逝，也不会累计生存时间、分数或热度。
    if self.phase == "layer_intro" then
        self.phaseTime = self.phaseTime + dt
        self:updateLayerIntro(dt)
        return
    end
    self.timeAlive = self.timeAlive + dt
    self.phaseTime = self.phaseTime + dt
    local p = self.player
    local pressed = input.pressed or {}

    -- 移动
    local mx, my = input.moveX or 0, input.moveY or 0
    local mlen = math.sqrt(mx * mx + my * my)
    if mlen > 1 then mx, my = mx / mlen, my / mlen end
    p.moving = mlen > 0.15
    if p.moving then
        p.faceAngle = math.atan(my, mx)
        local spd = Config.PLAYER.moveSpeed
        if self:inCombatPhase() then
            spd = spd * Config.PLAYER.overloadSpeedBonus
        else
            spd = spd * Config.DEPLETED.moveSpeedFactor
        end
        self:moveCircle(p, mx * spd * dt, my * spd * dt)
    end
    self:unstuck(p)
    if p.hurtFlash > 0 then p.hurtFlash = p.hurtFlash - dt end

    -- 激光走廊伤害(§7.2:过载可硬闯,枯竭危险)
    if self.laserActive then
        local c, r = MapDef.toTile(p.x, p.y)
        for _, t in ipairs(self.map.laserTiles) do
            if t.col == c and t.row == r then
                local dps = self:inCombatPhase() and Config.DEPLETED.laserOverloadDamagePerSec
                    or Config.DEPLETED.laserDamagePerSec
                self:damagePlayer(dps * dt, p.x, p.y)
                break
            end
        end
    end

    -- 环境伤害可能在本帧直接击杀玩家；死亡后不得继续执行阶段逻辑或完成重启。
    if self.phase == "dead" then
        ScoreSys.update(self, dt)
        for _, f in ipairs(self.fx) do
            f.age = f.age + dt
            if f.age >= (f.dur or 1) then f.dead = true end
        end
        Util.compact(self.fx, self.fxPool)
        return
    end

    if self.phase == "overload" then
        self:updateOverload(dt, pressed)
    elseif self.phase == "anti_hunt" then
        self:updateAntiHunt(dt, pressed)
    elseif self.phase == "depleted" then
        self:updateDepleted(dt, input, pressed)
    end
    -- 反猎结束可能在本帧切到层结算，此后不再执行常规逐帧逻辑。
    if self.phase == "layer_settlement" or self.phase == "dead" then
        self:updateSystemPrompts(dt)
        return
    end

    -- [R2] 侦察计时(冷却跨阶段持续)与追踪热度
    if self.reconCd > 0 then self.reconCd = self.reconCd - dt end
    if self.reconLeft > 0 then
        self.reconLeft = math.max(0, self.reconLeft - dt)
        if self.reconLeft <= 0 then
            self.reconAfterglowLeft = Config.RECON.afterglow or 0.5
        end
    elseif self.reconAfterglowLeft > 0 then
        self.reconAfterglowLeft = math.max(0, self.reconAfterglowLeft - dt)
    end
    ProtocolSys.update(self, dt)
    TraceHeat.update(self, dt)

    if self.areaAnnouncement and self.areaAnnouncement.left > 0 then
        self.areaAnnouncement.left = math.max(0, self.areaAnnouncement.left - dt)
    end
    if self.layerIntroCueLeft and self.layerIntroCueLeft > 0 then
        self.layerIntroCueLeft = math.max(0, self.layerIntroCueLeft - dt)
    end

    ScoreSys.update(self, dt)
    if self.overloadContactWindow > 0 then
        self.overloadContactWindow = self.overloadContactWindow - dt
        if self.overloadContactWindow <= 0 then self.overloadContactLoss = 0 end
    end
    -- 反猎窗口由 updateAntiHunt 统一管理 huntLeft 与剩余目标数；
    -- 其它阶段只做兜底清理，防止残留标记跨阶段生效。
    if self.phase ~= "anti_hunt" then
        for _, e in ipairs(self.enemies) do
            if e.huntTarget then
                e.huntLeft = math.max(0, (e.huntLeft or 0) - dt)
                if e.huntLeft <= 0 then
                    e.huntTarget = false
                    self.huntTargetsLeft = math.max(0, self.huntTargetsLeft - 1)
                end
            end
        end
    end

    -- 敌人 AI(内部按阶段分流)
    EnemyAI.update(self, dt)
    SignalBlackout.update(self, dt)

    -- 诱饵计时
    for _, d in ipairs(self.decoys) do
        d.left = d.left - dt
        if d.left <= 0 then d.dead = true end
    end
    Util.compact(self.decoys)

    -- 特效计时
    for _, f in ipairs(self.fx) do
        f.age = f.age + dt
        if f.age >= (f.dur or 1) then f.dead = true end
    end
    Util.compact(self.fx, self.fxPool)
    self:updateSystemPrompts(dt)

    -- 尸体回收
    Util.compact(self.enemies, self.enemyPool)
end

function World:updateOverload(dt, pressed)
    -- 硬倒计时(§5.2)
    self.overloadLeft = self.overloadLeft - dt
    local wholeSec = math.ceil(self.overloadLeft)
    if self.overloadLeft <= Config.OVERLOAD.lastWarnTime and wholeSec ~= self.lastWarnSecond then
        self.lastWarnSecond = wholeSec
        if wholeSec >= 1 then self:emit("countdown_tick") end
    end
    if self.overloadLeft <= 0 then
        self.overloadLeft = 0
        self:forceDrop()   -- 归零同一帧断崖切换,之后本函数不再执行
        return
    end

    CombatSys.update(self, dt, pressed)
    self:updateOpportunities()

    -- 割草怪持续刷新
    local diff = self:difficulty()
    local alive = 0
    for _, e in ipairs(self.enemies) do
        if not e.dead and e.isHorde then alive = alive + 1 end
    end
    self.hordeTimer = self.hordeTimer - dt
    local endlessActive = self.endless == true and self.round >= 11
    local endlessIndex = endlessActive and math.min(6, math.max(1, self.round - 10)) or 1
    local aliveCap = endlessActive and (Config.ENDLESS.hordeAliveCap[endlessIndex]
        or Config.ROUNDS.hordeMaxAlive) or Config.ROUNDS.hordeMaxAlive
    local lateCutoff = endlessActive and Config.ENDLESS.overloadLateSpawnCutoff or -1
    if self.hordeTimer <= 0 and alive < aliveCap
        and (not endlessActive or self.overloadLeft > lateCutoff) then
        self.hordeTimer = diff.hordeInterval
        self:spawnHordeBatch()
    end
end

-- 反猎窗口逐帧。玩家保留完整过载攻击能力；普通刷怪停止；
-- 有目标时固定展示完整 10 秒；真正零敌人仍走独立 1 秒无威胁收口。
function World:updateAntiHunt(dt, pressed)
    return RunFlow.updateAntiHunt(self, dt, pressed)
end

function World:spawnHordeBatch()
    local p = self.player
    -- 选距玩家 300~900 的出生口
    local candidates = {}
    for _, g in ipairs(self.layout.hordeGates) do
        local x, y = MapDef.tileCenter(g[1], g[2])
        local d = Util.dist(x, y, p.x, p.y)
        if d > 300 and d < 900 then candidates[#candidates + 1] = { x = x, y = y } end
    end
    if #candidates == 0 then
        for _, g in ipairs(self.layout.hordeGates) do
            local x, y = MapDef.tileCenter(g[1], g[2])
            candidates[#candidates + 1] = { x = x, y = y }
        end
    end
    local current = 0
    for _, e in ipairs(self.enemies) do
        if not e.dead and e.isHorde then current = current + 1 end
    end
    local batch = ProtocolSys.hordeBatch(self)
    if self.endless and self.round >= 11 then
        local idx = math.min(6, math.max(1, self.round - 10))
        batch = math.min(batch, math.max(0,
            (Config.ENDLESS.hordeAliveCap[idx] or Config.ROUNDS.hordeMaxAlive) - current))
    end
    for i = 1, batch do
        local c = candidates[math.random(#candidates)]
        local kind = (math.random() < 0.75) and "drone" or "glitch"
        local e = self:spawnEnemy(kind, c.x + math.random(-20, 20), c.y + math.random(-20, 20), nil, true)
        e.state = "chase"  -- 割草怪直奔玩家
    end
end

-- 048：L15+枯竭阶段的递进追踪压力。复用 glitch 敌人，
-- 不新增敌种、不注入玩家坐标作弊；只在生成瞬间记录一次最后暴露点。
function World:updateEndlessTracker(dt)
    if self.phase ~= "depleted" or self.endless ~= true
        or (self.round or 0) < 15 then return end
    local diff = self:difficulty()
    local interval = diff.trackerInterval
    if not interval then return end
    self.trackerTimer = (self.trackerTimer or interval) - dt
    if self.trackerTimer > 0 then return end

    local alive, candidates = 0, {}
    for _, e in ipairs(self.enemies) do
        if not e.dead and e.tracker then alive = alive + 1 end
    end
    local cap = diff.trackerAliveCap or 6
    if alive >= cap then
        self.trackerTimer = 1.0
        return
    end
    local p = self.player
    for _, g in ipairs(self.layout.hordeGates or {}) do
        local x, y = MapDef.tileCenter(g[1], g[2])
        local d = Util.dist(x, y, p.x, p.y)
        if d > 300 and d < 900 then candidates[#candidates + 1] = { x = x, y = y } end
    end
    if #candidates == 0 then
        for _, g in ipairs(self.layout.hordeGates or {}) do
            local x, y = MapDef.tileCenter(g[1], g[2])
            candidates[#candidates + 1] = { x = x, y = y }
        end
    end
    if #candidates == 0 then
        self.trackerTimer = 1.0
        return
    end
    local c = candidates[math.random(#candidates)]
    local e = self:spawnEnemy("glitch", c.x + math.random(-20, 20),
        c.y + math.random(-20, 20), nil, false)
    e.tracker = true
    e.state = "chase"
    e.stateTime = 0
    e.wasChasing = true
    e.lastSeenX, e.lastSeenY = p.x, p.y
    self.trackerSpawnCount = (self.trackerSpawnCount or 0) + 1
    self.trackerTimer = interval
    self:emit("endless_tracker_spawn", e.x, e.y)
    self:addFx("toast", { text = "追踪信号接入", dur = 1.1 })
end

function World:updateDepleted(dt, input, pressed)
    local p = self.player

    if self.cloakLeft > 0 then
        self.cloakLeft = self.cloakLeft - dt
        if self.cloakLeft <= 0 then
            if EndlessOverclock.mod(self, "signal_cloak") > 0 then
                self:addFx("ring", { x = self.player.x, y = self.player.y,
                    r = 84, color = "purple", dur = 0.65 })
                self:addFx("toast", { text = "残影已释放", dur = 0.9 })
            end
            self:emit("cloak_off")
        end
    end

    -- 工具与交互
    if pressed.jammer then self:useJammer() end
    if pressed.decoy then self:useDecoy() end
    if pressed.cloak then self:useCloak() end
    if pressed.mark then self:trySetMark() end
    if pressed.recon then self:tryRecon() end
    if pressed.dismantle then self:startDismantle() end
    if pressed.craftCapacitor then self:craft("capacitor") end
    if pressed.craftAmplifier then self:craft("amplifier") end
    if pressed.restart then self:tryRestart() end
    if self.phase ~= "depleted" then return end -- 重启已发生

    -- 正式重启读条：启动后不可主动取消，移动和普通受伤都不会打断。
    if self.restartChannel then
        self.restartChannel.t = self.restartChannel.t + dt
        if self.restartChannel.t >= Config.FORMAL.restartChannelTime then
            self:doRestart()
            return
        end
    end

    self:updateEndlessTracker(dt)

    -- 满能继续停留会提高追踪压力；风险分只由实际追击数量和有效风险节拍产生。
    if self.readyAt then
        local chasing = self:chasingCount(Config.FORMAL.lureSenseRadius)
        self.readyLureTimer = self.readyLureTimer + dt
        self.readyRiskTimer = self.readyRiskTimer + dt
        if self.readyLureTimer >= 0.5 then
            self.readyLureTimer = self.readyLureTimer - 0.5
            ScoreSys.onReadyLure(self, chasing)
        end
        if chasing > 0 and self.readyRiskTimer >= 4.0 then
            self.readyRiskTimer = self.readyRiskTimer - 4.0
            ScoreSys.onReadyRiskAction(self)
        end
    end

    -- 拆解读条(移动/远离则中断,§7.1;[R2] 深层残骸读条更长、收益更高)
    if self.dismantle then
        local d = self.dismantle
        local needTime = d.wreck.deep and Config.RISK.deepDismantleTime
            or Config.DEPLETED.dismantleTime
        if p.moving or d.wreck.dead
            or Util.dist(d.wreck.x, d.wreck.y, p.x, p.y) > Config.DEPLETED.interactRange * 1.3 then
            self.dismantle = nil
        else
            d.t = d.t + dt
            if d.t >= needTime then
                d.wreck.dead = true
                if d.wreck.deep then
                    -- [R2] 深层残骸:高级核心 + 缓存等级(未结算,重启后才生效)
                    local R = Config.RISK
                    local protocolBonus = self:hasProtocol("deep_cache")
                        and Config.PROTOCOL.deep_cache.deepCoreBonus or 0
                    local gained = R.deepCores + protocolBonus
                    local dataGained = Config.WRECK_DATA.perDeepWreck
                    local wreckConverted, wreckConsumed = EndlessOverclock.onDismantle(self, true)
                    local coreConverted, coreConsumed = EndlessOverclock.corePickup(self, gained)
                    if not wreckConsumed then self.wreckData = (self.wreckData or 0) + dataGained end
                    if not coreConsumed then self.coreCount = self.coreCount + gained end
                    self:layerStat("coresGained", gained)
                    self:layerStat("wreckDataGained", dataGained)
                    self:layerStat("wrecksDismantled", 1)
                    self:layerStat("deepWrecks", 1)
                    self.bonusCache = Util.clamp(self.bonusCache + R.deepCacheBonus, 0, R.overflowMax)
                    local wreckText = wreckConsumed
                        and (wreckConverted > 0 and ("超限数据 +" .. wreckConverted)
                            or ("残骸溢出 " .. EndlessOverclock.overflowSummary(self)))
                        or ("残骸数据 +" .. dataGained)
                    local coreText = coreConsumed
                        and (coreConverted > 0 and ("核心→超限 +" .. coreConverted)
                            or "核心已进入超限折算")
                        or ("黄色核心 +" .. gained)
                    self:addFx("pickup", { x = d.wreck.x, y = d.wreck.y,
                        text = string.format("%s · %s · 缓存 +%d", wreckText, coreText, R.deepCacheBonus),
                        color = "yellow", dur = 1.4 })
                    self:addFx("banner", { text = "深层残骸拆解成功(未结算:重启后生效)", dur = 2.0 })
                    if not wreckConsumed then self:emit("wreck_data", d.wreck.x, d.wreck.y, dataGained) end
                    self:emit("deep_done", d.wreck.x, d.wreck.y)
                else
                    -- 普通重型残骸：产出残骸数据（本局协议整备货币），不再产出黄色核心。
                    local gained = Config.WRECK_DATA.perNormalWreck
                    local wreckConverted, wreckConsumed = EndlessOverclock.onDismantle(self, false)
                    local coreConverted, coreConsumed = 0, false
                    if Config.DEPLETED.dismantleCores > 0 then
                        coreConverted, coreConsumed = EndlessOverclock.corePickup(
                            self, Config.DEPLETED.dismantleCores)
                    end
                    if not wreckConsumed then self.wreckData = (self.wreckData or 0) + gained end
                    self:layerStat("wreckDataGained", gained)
                    self:layerStat("wrecksDismantled", 1)
                    self:layerStat("normalWrecksDismantled", 1)
                    self.energy = self.energy + Config.DEPLETED.coreEnergyValue
                    if Config.DEPLETED.dismantleCores > 0 and not coreConsumed then
                        self.coreCount = self.coreCount + Config.DEPLETED.dismantleCores
                        self:layerStat("coresGained", Config.DEPLETED.dismantleCores)
                    end
                    local wreckText = wreckConsumed
                        and (wreckConverted > 0 and ("超限数据 +" .. wreckConverted)
                            or ("残骸溢出 " .. EndlessOverclock.overflowSummary(self)))
                        or ("+" .. gained .. " 残骸数据")
                    local coreText = coreConsumed and (coreConverted > 0
                        and ("核心→超限 +" .. coreConverted) or "核心已进入超限折算") or nil
                    self:addFx("pickup", { x = d.wreck.x, y = d.wreck.y,
                        text = coreText and (wreckText .. " · " .. coreText) or wreckText,
                        color = wreckConsumed and "cyan" or "orange", dur = 1.0 })
                    if not wreckConsumed then self:emit("wreck_data", d.wreck.x, d.wreck.y, gained) end
                end
                self:emit("dismantle_done", d.wreck.x, d.wreck.y)
                self.dismantle = nil
            end
        end
    end
    Util.compact(self.wrecks)

    -- 储能限量补刷(§18.2:供给无限、节流,永不断供)
    local activeCells = 0
    for _, c in ipairs(self.cells) do
        if not c.dead then activeCells = activeCells + 1 end
    end
    if activeCells < Config.DEPLETED.maxActiveCells then
        self.cellSpawnTimer = (self.cellSpawnTimer or 0) - dt
        if self.cellSpawnTimer <= 0 then
            self.cellSpawnTimer = Config.DEPLETED.cellRespawnDelay
            self:spawnOneCell()
        end
    end

    -- 储能拾取(枯竭独占,§5.3/§6.3;自动拾取 §13)
    local energyBefore = self.energy
    for _, c in ipairs(self.cells) do
        if not c.dead and Util.dist(c.x, c.y, p.x, p.y) < Config.DEPLETED.interactRange then
            c.dead = true
            self.energy = self.energy + Config.DEPLETED.cellValue
            self:addFx("pickup", { x = c.x, y = c.y, text = "+" .. Config.DEPLETED.cellValue, color = "green", dur = 0.8 })
            self:emit("cell_pickup", c.x, c.y)
        end
    end
    for _, c in ipairs(self.cores) do
        if not c.dead and Util.dist(c.x, c.y, p.x, p.y) < Config.DEPLETED.interactRange then
            c.dead = true
            local converted, consumed = EndlessOverclock.corePickup(self, 1)
            if not consumed then
                self.coreCount = self.coreCount + 1
                self:layerStat("coresGained", 1)
            end
            self.energy = self.energy + Config.DEPLETED.coreEnergyValue
            self:addFx("pickup", { x = c.x, y = c.y,
                text = consumed and (converted > 0 and ("核心→超限 +" .. converted)
                    or ("核心溢出 " .. EndlessOverclock.overflowSummary(self))) or "+1 核心",
                color = consumed and "cyan" or "orange", dur = 1.0 })
            self:emit("core_pickup", c.x, c.y)
        end
    end
    Util.compact(self.cells)
    Util.compact(self.cores)
    -- 储能首次充足提示(§16;[R2] 同时给出"继续冒险"提示 + 激活深层残骸)
    if energyBefore < self.energyNeed and self.energy >= self.energyNeed then
        self:addFx("banner", { text = "重启条件已满足!", dur = 2.0 })
        if self.exp.overflowCache then
            self:addFx("toast", { text = "继续搜集可强化下一轮(超额缓存/深层残骸)", dur = 2.6 })
        end
        if not self.readyAt then
            self.readyAt = self.timeAlive
        self._readySnap = { coreCount = self.coreCount,
                crafted = self.counters.crafted or 0 }
        end
        self:spawnDeepWreck()
        self:emit("energy_ready")
    end
end

return World
