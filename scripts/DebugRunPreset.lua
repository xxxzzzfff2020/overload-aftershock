-- DebugRunPreset.lua
-- 负责人专用 L9 高配起点。所有资源和升级均由正式 L1-L8 固定收益、
-- 正式商店价格计算。默认仍可作为隔离Debug样本；ownerValidation=true时
-- 用作正式验收档，接通检查点、成绩、毕业档、榜单与Challenge广告复活。

local Config = require "Config"
local LayerPlan = require "LayerPlan"
local ScenarioLayouts = require "ScenarioLayouts"
local RunShop = require "RunShop"

local DebugRunPreset = {}

DebugRunPreset.START_LAYER = 9
-- 016T 确定性样本里到达 L8 的高分参考，不是数学满分。
DebugRunPreset.REFERENCE_SCORE = 603239
-- 模拟已完整经历L1-L8的累计时间，确保L9死亡遵守正式“前60秒禁用”合同
-- 时不会被误判成新局前60秒。只用于负责人验收档。
DebugRunPreset.REFERENCE_TIME_SECONDS = 12 * 60

local PURCHASE_PLAN = {
    { id = "collapseCooldownLevel", levels = 3 },
    { id = "pulseCooldownLevel", levels = 3 },
    { id = "chainIntervalLevel", levels = 1 },
    { id = "jammerBonusUses", levels = 3 },
    { id = "cloakBonusUses", levels = 2 },
    { id = "decoyBonusUses", levels = 1 },
}

local function hasProtocol(plan, protocol)
    for _, value in ipairs(plan.protocols or {}) do
        if value == protocol then return true end
    end
    return false
end

-- 返回 L1-L8 吃完全部固定重型残骸、深层残骸和核心堆后的资源审计。
function DebugRunPreset.calculateIncome()
    local audit = { layers = {}, wreckData = 0, coreCount = 0 }
    for layer = 1, DebugRunPreset.START_LAYER - 1 do
        local plan = LayerPlan.get(layer)
        local layout = ScenarioLayouts.get(plan.map, plan.layout)
        local wreck = plan.difficulty.heavyCount * Config.WRECK_DATA.perNormalWreck
            + Config.WRECK_DATA.perDeepWreck
        local cores = #layout.corePiles + Config.RISK.deepCores
        if hasProtocol(plan, "deep_cache") then
            cores = cores + Config.PROTOCOL.deep_cache.deepCoreBonus
        end
        audit.layers[#audit.layers + 1] = {
            layer = layer, wreckData = wreck, coreCount = cores,
        }
        audit.wreckData = audit.wreckData + wreck
        audit.coreCount = audit.coreCount + cores
    end
    return audit
end

-- 将正式可得资源按固定购买计划花完：过载树 21 数据，枯竭工具 22 核心，
-- 余下 2 核心合法制作扩容与链路放大器；L8 超额缓存按可达上限 2 带入 L9。
function DebugRunPreset.apply(world, options)
    if type(world) ~= "table" then return false, "invalid_world" end
    options = type(options) == "table" and options or {}
    local ownerValidation = options.ownerValidation == true
    local audit = DebugRunPreset.calculateIncome()
    world.runUpgrades = RunShop.newUpgrades()
    world.wreckData = audit.wreckData
    world.coreCount = audit.coreCount
    world.shopPurchases = 0
    for _, purchase in ipairs(PURCHASE_PLAN) do
        for _ = 1, purchase.levels do
            local ok, reason = RunShop.buy(world, purchase.id)
            if not ok then return false, reason or ("buy_failed:" .. purchase.id) end
        end
    end
    if world.coreCount < 2 then return false, "module_core_shortfall" end
    world.coreCount = world.coreCount - 2
    world.modules = { capacitor = true, amplifier = true }
    world.activeModules = { capacitor = false, amplifier = false }
    world.pendingCache = Config.RISK.overflowMax
    world.activeCache = 0
    world.score = DebugRunPreset.REFERENCE_SCORE
    world.restarts = DebugRunPreset.START_LAYER - 1
    world.debugRun = not ownerValidation
    world.ownerValidationRun = ownerValidation
    world.cleanRun = ownerValidation
    world.assistedRun = false
    if ownerValidation then
        world.timeAlive = math.max(world.timeAlive or 0,
            DebugRunPreset.REFERENCE_TIME_SECONDS)
    end
    world.layerStats = world.layerStats or {}
    world.layerStats.scoreAtLayerStart = world.score
    world.debugPresetAudit = {
        sourceLayers = "L1-L8_FIXED_MAX",
        incomeWreckData = audit.wreckData,
        incomeCoreCount = audit.coreCount,
        remainingWreckData = world.wreckData,
        remainingCoreCount = world.coreCount,
        referenceScore = DebugRunPreset.REFERENCE_SCORE,
        referenceTimeSeconds = ownerValidation
            and DebugRunPreset.REFERENCE_TIME_SECONDS or 0,
        ownerValidation = ownerValidation,
        scoreIsMathematicalMaximum = false,
    }
    return true, world.debugPresetAudit
end

return DebugRunPreset
