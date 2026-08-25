-- PlaytestMetrics.lua
-- 试玩数据记录(§任务包F / [R2]§任务包L):每局/每轮结构化数据 + 自动诊断。
-- 纯观察者:读取 world.counters / world.events / world 只读字段,绝不修改玩法。
-- 写文件失败只打一次日志并继续;引擎外(测试环境)自动跳过文件写入。
-- [R2] 新增:实验ID/盲测、达标时间线、深层残骸、超额缓存、热度、未结算损失、
--          过载优先目标成果、诊断标签(无明显抉择/假冒险/有效冒险/冒险失败/坐牢/无感准备)。

local Config = require "Config"
local ReleaseInfo = require "ReleaseInfo"

local Metrics = {}

local FILE_NAME = "overload_playtest_sessions.json"
local VERSION = ReleaseInfo.GAME_VERSION
local COMMIT = "overnight-listing-candidate-008"

Metrics.session = nil          -- 当前局
Metrics.lastSummary = nil      -- 最近一局摘要(结算页读取)
Metrics.VERSION = VERSION
local saveFailedOnce = false

local function snap(counters)
    local t = {}
    for k, v in pairs(counters) do t[k] = v end
    return t
end

local function diff(now, base)
    local d = {}
    for k, v in pairs(now) do
        local delta = v - (base[k] or 0)
        if delta ~= 0 then d[k] = delta end
    end
    return d
end

local function get(t, k) return (t and t[k]) or 0 end
local function r1(v) return math.floor(v * 10 + 0.5) / 10 end

-- ============================================================
-- 生命周期
-- ============================================================
function Metrics.beginSession(world, seed, vw, vh, blind)
    if not Config.METRICS.enabled then return end
    Metrics.session = {
        version = VERSION,
        commit = COMMIT,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        seed = seed or 0,
        experiment = world.experimentId,       -- [R2] 实际实验 ID(盲测也记录真名)
        blind = blind == true,
        layout = world.layout and world.layout.name or "?",
        viewport = { w = vw or 0, h = vh or 0 },
        rounds = {},
        finished = false,
        _snapRoundStart = snap(world.counters),
        _snapOverloadEnd = nil,
        _snapReady = nil,
        _roundStartAt = 0,
        _overloadEndAt = nil,
        _readyAt = nil,
        _curRound = world.round,
        _deepSpawnedThisRound = false,
        -- beginSession 发生在 World.New 之后；World.New 的初始 overload_start 仍可能
        -- 留在事件队列里。记录当前层，避免把该旧事件按当前时刻重置层起点。
        _lastStartedRound = world.round,
    }
end

-- 单轮诊断标签(§17.1:只写数据,不改玩法)
local function diagnoseRound(r)
    local tags = {}
    if r.endedBy == "restart" then
        if r.immediateRestart and r.deepTried == 0 then
            tags[#tags + 1] = "no_choice"          -- 达标立即重启,未尝试高风险目标
        elseif not r.immediateRestart then
            local gained = (r.gainAfterReady and
                (r.gainAfterReady.cores + r.gainAfterReady.crafted + r.gainAfterReady.marks) or 0)
                + (r.cacheLevel or 0)
            if gained > 0 then
                tags[#tags + 1] = "effective_risk" -- 达标后停留并有收益,成功重启
            else
                tags[#tags + 1] = "fake_risk"      -- 达标后停留较久但无新收益
            end
        end
    elseif r.endedBy == "death" and r.dwellAfterReady > 0 then
        tags[#tags + 1] = "risk_failed"            -- 达标后继续行动,死亡损失未结算收益
    end
    if r.jailSuspect then tags[#tags + 1] = "jail_suspect" end
    return tags
end

local function closeRound(world, s, endedBy)
    local now = world.timeAlive
    local overloadDur = (s._overloadEndAt or now) - s._roundStartAt
    local depletedDur = s._overloadEndAt and (now - s._overloadEndAt) or 0
    local oDiff = diff(s._snapOverloadEnd or snap(world.counters), s._snapRoundStart)
    local dDiff = diff(snap(world.counters), s._snapOverloadEnd or s._snapRoundStart)
    local r = {
        round = s._curRound,
        overloadTime = r1(overloadDur),
        depletedTime = r1(depletedDur),
        endedBy = endedBy,     -- "restart" | "death"
        -- 过载段
        kills = get(oDiff, "kills"),
        heavyKills = get(oDiff, "heavyKills"),
        nodes = get(oDiff, "nodes"),
        relays = get(oDiff, "relays"),          -- [R2] 中继器击毁
        wrecksSpawned = get(oDiff, "heavyKills"),
        markTriggered = get(oDiff, "markTriggers") > 0,
        -- 枯竭段
        spotted = get(dDiff, "spotted"),
        chased = get(dDiff, "chased"),
        escaped = get(dDiff, "escaped"),
        damageTaken = math.floor(get(dDiff, "damageTaken") + get(oDiff, "damageTaken") + 0.5),
        cells = get(dDiff, "cells"),
        cores = get(dDiff, "cores"),
        dismantled = get(dDiff, "dismantled"),
        jammer = get(dDiff, "jammer"),
        decoy = get(dDiff, "decoy"),
        cloak = get(dDiff, "cloak"),
        marks = get(dDiff, "marks"),
        crafted = get(dDiff, "crafted"),
        -- [R2] 风险收益链
        recon = get(dDiff, "recon"),
        deepTried = get(dDiff, "deepTries"),
        deepDone = get(dDiff, "deepDone"),
        heatUps = get(dDiff, "heatUps"),
        investigations = get(dDiff, "investigations"),
        channelCancelled = get(dDiff, "channelCancelled"),  -- 重启犹豫(读条又放弃)
        heatPeak = math.floor((world.heatPeakRound or 0) + 0.5),
        cacheLevel = 0,   -- 重启结算的缓存等级(overload_restart 时补写)
    }
    r.decisionActions = r.jammer + r.decoy + r.cloak + r.dismantled + r.marks
        + r.crafted + r.cores + r.recon
    if s._readyAt then
        r.readyAt = r1(s._readyAt - (s._overloadEndAt or s._roundStartAt))  -- 跌落后多久达标
        r.dwellAfterReady = r1(now - s._readyAt)
        r.immediateRestart = (endedBy == "restart")
            and r.dwellAfterReady <= Config.METRICS.quickRestartWindow
        local aDiff = diff(snap(world.counters), s._snapReady or snap(world.counters))
        r.gainAfterReady = {
            cores = get(aDiff, "cores"),
            crafted = get(aDiff, "crafted"),
            marks = get(aDiff, "marks"),
            deep = get(aDiff, "deepDone"),
            cache = world:totalCacheLevel(),
            damageTaken = math.floor(get(aDiff, "damageTaken") + 0.5),
            spotted = get(aDiff, "spotted"),
        }
    else
        r.readyAt = -1
        r.dwellAfterReady = 0
        r.immediateRestart = false
    end
    -- 坐牢疑似(§10.3:仅提示)
    local jailScore = 0
    if r.depletedTime > Config.METRICS.jailDepletedTime then jailScore = jailScore + 1 end
    if r.decisionActions < Config.METRICS.jailMinActions then jailScore = jailScore + 1 end
    if r.cells == 0 and r.cores == 0 and r.depletedTime > 20 then jailScore = jailScore + 1 end
    if r.chased >= 3 and r.escaped == 0 then jailScore = jailScore + 1 end
    r.jailSuspect = jailScore >= 2
    -- [R2] 死亡时的未结算损失
    if endedBy == "death" and world.unbankedLoss then
        r.unbankedLoss = world.unbankedLoss
    end
    r.tags = diagnoseRound(r)
    s.rounds[#s.rounds + 1] = r
    return r
end

-- 每帧调用(main / 测试驱动):消费 world.events 中的关键节拍
-- 必须在 AudioSys.drain 清空 events 之前调用
function Metrics.update(world)
    local s = Metrics.session
    if not s or s.finished then return end
    for _, ev in ipairs(world.events) do
        local name = ev.name
        if name == "overload_end" then
            s._overloadEndAt = world.timeAlive
            s._snapOverloadEnd = snap(world.counters)
        elseif name == "energy_ready" then
            if not s._readyAt then
                s._readyAt = world.timeAlive
                s._snapReady = snap(world.counters)
            end
        elseif name == "overload_restart" then
            -- 新时间线：重启结束本层的"过载→枯竭→重启"循环，随后是本层反猎与层结算。
            -- 下一层的 activeCache 要到 startOverload 才生效，这里读已结算的 pendingCache。
            local r = closeRound(world, s, "restart")
            r.cacheLevel = world.pendingCache or 0
            -- 上一轮为下一轮备好的准备(下一轮是否触发在下一条 round 记录中可见)
            r.nextRoundHasModule = world.activeModules.capacitor or world.activeModules.amplifier
                or world.modules.capacitor or world.modules.amplifier
            r.nextRoundHasMark = world.mark ~= nil
            -- [R2] 无感准备诊断:上一轮有准备但本轮标记/组件都没触发
            local prev = s.rounds[#s.rounds - 1]
            if prev and (prev.nextRoundHasModule or prev.nextRoundHasMark) then
                if not r.markTriggered and (world.activeModules.capacitor ~= true)
                    and (world.activeModules.amplifier ~= true) and (r.cacheLevel == 0) then
                    r.tags[#r.tags + 1] = "unnoticed_prep"
                end
            end
        elseif name == "overload_start" then
            -- 层推进到位后才开始记录新一轮（层号此时已是新层）。
            if world.round ~= s._lastStartedRound then
                s._lastStartedRound = world.round
                s._curRound = world.round
                s._roundStartAt = world.timeAlive
                s._snapRoundStart = snap(world.counters)
                s._snapOverloadEnd = nil
                s._overloadEndAt = nil
                s._readyAt = nil
                s._snapReady = nil
            end
        elseif name == "player_dead" then
            closeRound(world, s, "death")
            Metrics.endSession(world)
        end
    end
end

-- 汇总诊断
local function summarize(world, s)
    local loops, depleted = {}, {}
    local immediate, continueN, withReady = 0, 0, 0
    local totalDecisions, jails = 0, 0
    local deepTried, deepDone = 0, 0
    local extraCores, extraCache, extraDeep = 0, 0, 0
    local cacheTotal = 0
    local heatPeakSum = 0
    local unbankedCores, unbankedCache = 0, 0
    for _, r in ipairs(s.rounds) do
        if r.endedBy == "restart" then
            loops[#loops + 1] = r.overloadTime + r.depletedTime
            withReady = withReady + 1
            if r.immediateRestart then immediate = immediate + 1
            else continueN = continueN + 1 end
        end
        depleted[#depleted + 1] = r.depletedTime
        totalDecisions = totalDecisions + (r.decisionActions or 0)
        if r.jailSuspect then jails = jails + 1 end
        deepTried = deepTried + (r.deepTried or 0)
        deepDone = deepDone + (r.deepDone or 0)
        if r.gainAfterReady then
            extraCores = extraCores + r.gainAfterReady.cores
            extraCache = extraCache + (r.gainAfterReady.cache or 0)
            extraDeep = extraDeep + (r.gainAfterReady.deep or 0)
        end
        cacheTotal = cacheTotal + (r.cacheLevel or 0)
        heatPeakSum = heatPeakSum + (r.heatPeak or 0)
        if r.unbankedLoss then
            unbankedCores = unbankedCores + (r.unbankedLoss.cores or 0)
            unbankedCache = unbankedCache + (r.unbankedLoss.cache or 0)
        end
    end
    local function avg(t)
        if #t == 0 then return 0 end
        local sum = 0
        for _, v in ipairs(t) do sum = sum + v end
        return r1(sum / #t)
    end
    return {
        experiment = s.experiment,
        totalTime = r1(world.timeAlive),
        finalRound = world.round,
        restarts = world.restarts,
        deathCause = "hp",
        firstLoopDone = world.restarts >= 1,
        avgLoopTime = avg(loops),
        avgDepletedTime = avg(depleted),
        immediateRestarts = immediate,
        continueRestarts = continueN,
        immediateRestartRate = withReady > 0
            and math.floor(immediate / withReady * 100 + 0.5) or 0,
        avgDecisionActions = #s.rounds > 0 and r1(totalDecisions / #s.rounds) or 0,
        jailSuspectRounds = jails,
        deepTried = deepTried,
        deepDone = deepDone,
        extraCoresFromRisk = extraCores,
        extraCacheFromRisk = extraCache,
        extraDeepFromRisk = extraDeep,
        cacheTotal = cacheTotal,
        avgHeatPeak = #s.rounds > 0 and r1(heatPeakSum / #s.rounds) or 0,
        unbankedCoresLost = unbankedCores,
        unbankedCacheLost = unbankedCache,
    }
end

function Metrics.endSession(world)
    local s = Metrics.session
    if not s or s.finished then return end
    s.finished = true
    s.summary = summarize(world, s)
    Metrics.lastSummary = s.summary
    local sm = s.summary
    print(string.format(
        "[METRICS] exp=%s time=%.0fs round=%d loop=%.0fs immRestart=%d%% cont=%d deep=%d/%d cache=%d lost=%d",
        tostring(sm.experiment), sm.totalTime, sm.finalRound, sm.avgLoopTime,
        sm.immediateRestartRate, sm.continueRestarts, sm.deepDone, sm.deepTried,
        sm.cacheTotal, sm.unbankedCoresLost))
    Metrics.saveSessions(s)
end

local function exportSession(s)
    local out = {}
    for k, v in pairs(s) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" then out[k] = v end
    end
    return out
end

-- [R2] 按实验筛选摘要(§十九:实验A/B记录共存,可分开看)
function Metrics.filterSummaries(sessions, expId)
    local t = {}
    for _, s in ipairs(sessions or {}) do
        if s.summary and (expId == nil or s.experiment == expId) then
            t[#t + 1] = s.summary
        end
    end
    return t
end

-- 写文件:保留最近 N 局;失败不崩溃、只警告一次
function Metrics.saveSessions(s)
    if fileSystem == nil or File == nil or cjson == nil then return end
    local ok, err = pcall(function()
        local sessions = {}
        if fileSystem:FileExists(FILE_NAME) then
            local rf = File(FILE_NAME, FILE_READ)
            if rf:IsOpen() then
                local okD, data = pcall(cjson.decode, rf:ReadString())
                rf:Close()
                if okD and type(data) == "table" then sessions = data end
            end
        end
        sessions[#sessions + 1] = exportSession(s)
        while #sessions > Config.METRICS.keepSessions do
            table.remove(sessions, 1)
        end
        local wf = File(FILE_NAME, FILE_WRITE)
        if wf:IsOpen() then
            wf:WriteString(cjson.encode(sessions))
            wf:Close()
        end
    end)
    if not ok and not saveFailedOnce then
        saveFailedOnce = true
        print("[METRICS] save failed (game continues): " .. tostring(err))
    end
end

return Metrics
