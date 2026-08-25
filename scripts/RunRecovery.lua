-- RunRecovery.lua
-- 024D 运行保护（Run Suspension Recovery）：非主动中断（后台/失焦/挂起）时冻结
-- 当前 Run 并生成本地快照；重新进入后可选择继续或放弃。纯逻辑模块，无引擎依赖，
-- 可在 lupa 无头环境测试（同 Viewport/SaveSys 风格）。
--
-- 边界（合同 024D，不可越过）：
--   * 快照只写本地文件，绝不写平台云槽 / recentRuns / best；
--   * 只保留最近一次快照（写入覆盖；clear 删除）；不允许多恢复点、不云同步、不跨设备；
--   * 主动退出路径必须 clear()，不生成恢复点；
--   * 未确认的实时恢复标记 recovered=true；正式层间 checkpoint 恢复另带
--     checkpointRecovery=true，并按产品合同保留统一榜资格。

local RunRecovery = {}

local SNAPSHOT_NAME = "overload_run_snapshot_v1.json"
local SNAPSHOT_VERSION = 1

-- 快照可能来自引擎绑定对象或测试环境 Python 包装(userdata)，统一按"可索引"判断。
local function isReadableTable(v)
    return v ~= nil and (type(v) == "table" or type(v) == "userdata")
end

-- 兼容 Lua table 与 lupa/引擎 userdata 包装的安全取值（缺键不抛错）。
local function safeGet(t, key)
    if not isReadableTable(t) then return nil end
    local ok, value = pcall(function() return t[key] end)
    if not ok then return nil end
    return value
end

-- 合同允许快照的字段白名单：防止把成绩/云/结算字段带进快照。
local PLAYER_KEYS = { "x", "y", "hp", "maxHp", "radius", "faceAngle", "moving" }
local TOOL_KEYS = { "jammer", "decoy", "cloak" }
local ENEMY_KEYS = { "kind", "x", "y", "state", "hp", "maxHp", "patrol", "patrolIdx",
    "suspicion", "lastSeenX", "lastSeenY", "wasChasing", "angle", "daze", "stun",
    "jammed", "dead", "pathTick", "fired", "wave" }
local UPGRADE_KEYS = { "pulseCooldownLevel", "collapseCooldownLevel", "chainIntervalLevel",
    "jammerBonusUses", "decoyBonusUses", "cloakBonusUses", "scanRangeLevel" }
local MAP_KEYS = { "mapId", "layoutIndex", "gateOpen", "laserActive" }

local function pick(source, keys)
    local out = {}
    for _, key in ipairs(keys or {}) do
        if source[key] ~= nil then out[key] = source[key] end
    end
    return out
end

local function flatCopy(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

local function normalizeEnemy(raw)
    if type(raw) ~= "table" then return nil end
    local e = pick(raw, ENEMY_KEYS)
    if e.kind == nil then return nil end
    if type(e.patrol) == "table" then
        local loop = {}
        for _, p in ipairs(e.patrol) do loop[#loop + 1] = { p[1], p[2] } end
        e.patrol = loop
    end
    return e
end

-- 从 World 提取合同允许的运行时快照。不读取/写入任何成绩、云、结算字段。
function RunRecovery.extract(world, meta)
    if type(world) ~= "table" then return nil end
    meta = meta or {}
    local snapshot = {
        version = SNAPSHOT_VERSION,
        run_id = meta.run_id or world.runId or nil,
        seed = meta.seed or world.seed or 0,
        layer = math.floor(tonumber(world.round) or 0),
        phase = world.phase or "none",
        phaseTime = world.phaseTime or 0,
        timeAlive = world.timeAlive or 0,
        player = pick(world.player or {}, PLAYER_KEYS),
        energy = world.energy or 0,
        energyNeed = world.energyNeed or 0,
        coreCount = world.coreCount or 0,
        wreckData = world.wreckData or 0,
        heat = world.heat or 0,
        heatQuietTimer = world.heatQuietTimer or 0,
        tools = pick(world.tools or {}, TOOL_KEYS),
        cloakLeft = world.cloakLeft or 0,
        runUpgrades = pick(world.runUpgrades or {}, UPGRADE_KEYS),
        shopPurchases = world.shopPurchases or 0,
        modules = { capacitor = world.modules and world.modules.capacitor or false,
            amplifier = world.modules and world.modules.amplifier or false },
        activeModules = { capacitor = world.activeModules and world.activeModules.capacitor or false,
            amplifier = world.activeModules and world.activeModules.amplifier or false },
        map = pick(world, MAP_KEYS),
        -- 存活敌人精简表（dead 的排除，重建后由种子补齐巡逻队）
        enemies = {},
        run_mode = { recovered = true },
    }
    if world.layout and world.layout.index ~= nil then
        snapshot.map.layoutIndex = world.layout.index
    end
    for _, e in ipairs(world.enemies or {}) do
        if type(e) == "table" and not e.dead then
            local ne = normalizeEnemy(e)
            if ne then snapshot.enemies[#snapshot.enemies + 1] = ne end
        end
    end
    -- 复活检查点（RunFlow 已维护）是"本局已确认状态"的官方副本，随快照保存，
    -- 恢复时直接回填，保证 layer_settlement/分数归属不依赖序列化全表。
    snapshot.reviveCheckpoint = flatCopy(world._reviveCheckpoint or {})
    return snapshot
end

-- 恢复时把快照回填到重建的 World。
-- world 必须先按 snapshot.seed 创建（World.New 保证同 seed 可复现地图/刷点）。
function RunRecovery.apply(world, snapshot)
    if type(world) ~= "table" or not isReadableTable(snapshot) then return false end
    local sg = function(key) return safeGet(snapshot, key) end
    local layer = sg("layer")
    if layer ~= nil then world.round = layer end
    local phase = sg("phase")
    if phase ~= nil then world.phase = phase end
    local phaseTime = sg("phaseTime")
    if phaseTime ~= nil then world.phaseTime = phaseTime end
    local timeAlive = sg("timeAlive")
    if timeAlive ~= nil then world.timeAlive = timeAlive end
    local player = sg("player")
    if isReadableTable(player) then
        for _, key in ipairs({ "x", "y", "hp", "maxHp", "radius", "faceAngle" }) do
            local v = safeGet(player, key)
            if v ~= nil then world.player[key] = v end
        end
    end
    local energy = sg("energy")
    if energy ~= nil then world.energy = energy end
    local energyNeed = sg("energyNeed")
    if energyNeed ~= nil then world.energyNeed = energyNeed end
    local coreCount = sg("coreCount")
    if coreCount ~= nil then world.coreCount = coreCount end
    local wreckData = sg("wreckData")
    if wreckData ~= nil then world.wreckData = wreckData end
    local heat = sg("heat")
    if heat ~= nil then world.heat = heat end
    local heatQuietTimer = sg("heatQuietTimer")
    if heatQuietTimer ~= nil then world.heatQuietTimer = heatQuietTimer end
    local tools = sg("tools")
    if isReadableTable(tools) then
        for _, key in ipairs({ "jammer", "decoy", "cloak" }) do
            local v = safeGet(tools, key)
            if v ~= nil then world.tools[key] = v end
        end
    end
    local cloakLeft = sg("cloakLeft")
    if cloakLeft ~= nil then world.cloakLeft = cloakLeft end
    local runUpgrades = sg("runUpgrades")
    if isReadableTable(runUpgrades) then
        for _, key in ipairs(UPGRADE_KEYS) do
            local v = safeGet(runUpgrades, key)
            if v ~= nil then world.runUpgrades[key] = v end
        end
    end
    local shopPurchases = sg("shopPurchases")
    if shopPurchases ~= nil then world.shopPurchases = shopPurchases end
    local modules = sg("modules")
    if isReadableTable(modules) then
        world.modules = world.modules or {}
        local cap = safeGet(modules, "capacitor")
        local amp = safeGet(modules, "amplifier")
        if cap ~= nil then world.modules.capacitor = cap end
        if amp ~= nil then world.modules.amplifier = amp end
    end
    local activeModules = sg("activeModules")
    if isReadableTable(activeModules) then
        world.activeModules = world.activeModules or {}
        local cap = safeGet(activeModules, "capacitor")
        local amp = safeGet(activeModules, "amplifier")
        if cap ~= nil then world.activeModules.capacitor = cap end
        if amp ~= nil then world.activeModules.amplifier = amp end
    end
    local gateOpen = sg("gateOpen")
    if gateOpen ~= nil then world.gateOpen = gateOpen end
    local laserActive = sg("laserActive")
    if laserActive ~= nil then world.laserActive = laserActive end
    local map = sg("map")
    if isReadableTable(map) then
        local mapId = safeGet(map, "mapId")
        if mapId ~= nil then world.mapId = mapId end
        local layoutIndex = safeGet(map, "layoutIndex")
        if layoutIndex ~= nil and world.layout then world.layout.index = layoutIndex end
    end
    -- 敌人：快照中的存活敌人在重建世界（seed 同源）中按 kind 就近替换。
    local enemies = sg("enemies")
    if isReadableTable(enemies) then
        local okLen, count = pcall(function() return #enemies end)
        if okLen and count and count > 0 then
            local byKind = {}
            for i = 1, count do
                local ne = safeGet(enemies, i)
                if isReadableTable(ne) then
                    local k = tostring(safeGet(ne, "kind"))
                    byKind[k] = byKind[k] or {}
                    byKind[k][#byKind[k] + 1] = ne
                end
            end
            local idxByKind = {}
            for _, e in ipairs(world.enemies or {}) do
                if type(e) == "table" and not e.dead then
                    local k = tostring(e.kind)
                    local idx = (idxByKind[k] or 0) + 1
                    idxByKind[k] = idx
                    local ne = byKind[k] and byKind[k][idx]
                    if ne then
                        local v = safeGet(ne, "x")
                        if v ~= nil then e.x = v end
                        v = safeGet(ne, "y")
                        if v ~= nil then e.y = v end
                        v = safeGet(ne, "hp")
                        if v ~= nil then e.hp = v end
                        v = safeGet(ne, "state")
                        if v ~= nil then e.state = v end
                        v = safeGet(ne, "suspicion")
                        if v ~= nil then e.suspicion = v end
                        v = safeGet(ne, "wasChasing")
                        if v ~= nil then e.wasChasing = v end
                        v = safeGet(ne, "angle")
                        if v ~= nil then e.angle = v end
                        v = safeGet(ne, "patrolIdx")
                        if v ~= nil then e.patrolIdx = v end
                    end
                end
            end
        end
    end
    -- 复活检查点回填：分数归属/结算状态由 main 后续流程接管。
    local reviveCheckpoint = sg("reviveCheckpoint")
    if isReadableTable(reviveCheckpoint) then
        local cp = {}
        pcall(function()
            for k, v in pairs(reviveCheckpoint) do cp[k] = v end
        end)
        world._reviveCheckpoint = cp
    end
    local runId = sg("run_id")
    if runId ~= nil then world.runId = runId end
    local runMode = sg("run_mode")
    if isReadableTable(runMode) then world.runMode = runMode end
    return true
end

-- 写本地快照文件（尽力而为；失败返回 reason，不阻塞游戏）。
function RunRecovery.save(world, meta)
    local snapshot = RunRecovery.extract(world, meta)
    if snapshot == nil then return false, "no_world" end
    local raw
    local okEncode = pcall(function()
        raw = cjson.encode(snapshot)
    end)
    if not okEncode then return false, "encode_failed" end
    local okWrite = pcall(function()
        local file = File(SNAPSHOT_NAME, FILE_WRITE)
        if not file:IsOpen() then error("open failed") end
        file:WriteString(raw)
        file:Close()
    end)
    if not okWrite then return false, "write_failed" end
    return true
end

-- 读取快照；损坏/缺失返回 nil。损坏时尽力备份 .bak 后返回 nil（安全回退）。
function RunRecovery.load()
    local raw = nil
    local okRead = pcall(function()
        if not fileSystem or not fileSystem.FileExists or not fileSystem:FileExists(SNAPSHOT_NAME) then
            return
        end
        local file = File(SNAPSHOT_NAME, FILE_READ)
        if not file:IsOpen() then return end
        raw = file:ReadString()
        file:Close()
    end)
    if not okRead or raw == nil or raw == "" then
        return nil
    end
    local okDecode, snapshot = pcall(cjson.decode, raw)
    -- 兼容引擎绑定对象与 lupa Python 包装(均为可索引 userdata,type 非 table)。
    local readable = okDecode and snapshot ~= nil
        and (type(snapshot) == "table" or type(snapshot) == "userdata")
        and snapshot["version"] ~= nil
    if not readable then
        RunRecovery.backupCorrupt(raw)
        return nil
    end
    if snapshot["version"] ~= SNAPSHOT_VERSION then
        RunRecovery.backupCorrupt(raw)
        return nil
    end
    return snapshot
end

-- 损坏快照备份（尽力）。
function RunRecovery.backupCorrupt(raw)
    local name = SNAPSHOT_NAME .. ".corrupt." .. tostring(os.time() or 0) .. ".json"
    pcall(function()
        local file = File(name, FILE_WRITE)
        if file:IsOpen() then
            file:WriteString(raw or "")
            file:Close()
        end
    end)
end

-- 是否存在可用快照（只检查文件存在；内容损坏由 load() 兜底）。
function RunRecovery.has()
    local exists = false
    pcall(function()
        if fileSystem and fileSystem.FileExists then
            exists = fileSystem:FileExists(SNAPSHOT_NAME)
        end
    end)
    return exists
end

-- 清除快照（主动退出/结算/重开/放弃恢复）。
function RunRecovery.clear()
    local removed = false
    if fileSystem ~= nil and type(fileSystem.Delete) == "function" then
        local ok = pcall(function() return fileSystem:Delete(SNAPSHOT_NAME) end)
        if ok then removed = true end
    end
    if not removed and type(os.remove) == "function" then
        local ok = pcall(os.remove, SNAPSHOT_NAME)
        if ok then removed = true end
    end
    return removed
end

-- 用快照重建 World：先按 seed 重建可复现基线，再回填快照字段。
-- opts 额外透传（experiment 等）；失败返回 nil。
function RunRecovery.rebuild(snapshot, opts)
    if not isReadableTable(snapshot) then return nil end
    local World = require "World"
    local seed = math.floor(tonumber(snapshot.seed) or 0)
    local world = World.New({
        experiment = (opts and opts.experiment) or nil,
        seed = seed,
        startLayer = math.max(1, snapshot.layer or 1),
    })
    if not world then return nil end
    RunRecovery.apply(world, snapshot)
    return world
end

return RunRecovery
