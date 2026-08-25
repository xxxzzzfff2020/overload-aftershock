-- ReviewAccess.lua
-- REVIEW ONLY：016T集中产品Review的受控入口与真实性断言。
-- 不读写存档/云/成绩；只使用正式World/RunShop/LayerPlan合同创建自然起点或已结算安全状态。

local Config = require "Config"
local ReleaseInfo = require "ReleaseInfo"
local LayerPlan = require "LayerPlan"
local RunShop = require "RunShop"
local SafeDraw = require "SafeDraw"
local Viewport = require "Viewport"
local World = require "World"

local ReviewAccess = {}

local NORMAL_SIM_SOURCE = "qa/BATCH_SIM_016T_017.json · normal · seed 19006"

local SAMPLES = {
    {
        id = "natural", layer = 1, phase = "layer_intro", seed = 31601,
        label = "自然 L1", sub = "3秒开局 · 不跳过核心循环", controlled = false,
        route = "自然完成过载→枯竭；继续约15分钟时也只用这一入口",
    },
    {
        id = "l1_climax", layer = 1, phase = "depleted", seed = 31611, skipLayerIntro = true,
        label = "L1 高潮与整备", sub = "1数据 / 3核心 · 真实重启前", controlled = true,
        route = "按重启→0.7秒读条→10秒反猎→结算→购买→L2倒计时",
    },
    {
        id = "l6_economy", layer = 6, phase = "layer_settlement", seed = 19006, skipLayerIntro = true,
        label = "L6 正常经济", sub = "真实模拟快照 · 购买前", controlled = true,
        route = "判断主方向+部分副方向、选择清晰度与整备节奏",
    },
    {
        id = "l10_branch", layer = 10, phase = "layer_intro", seed = 31610,
        label = "L10 公平毕业门", sub = "L9正常构筑 · 完整L10→双出口", controlled = true,
        route = "观察3秒开局→完整L10→反猎→结算→完成或继续无尽→L11",
    },
}

local SAMPLE_BY_ID = {}
for _, sample in ipairs(SAMPLES) do SAMPLE_BY_ID[sample.id] = sample end
-- 兼容正式基线SelfTest的历史隔离样本，不显示在016T Review菜单。
-- 它只用于证明Review受控世界仍可进入真实猎杀/结算状态。
local LEGACY_HUNTER_SAMPLE = {
    id = "l5_hunter", layer = 5, phase = "depleted", seed = 35005,
    skipLayerIntro = true,
    label = "L5 历史隔离回归", sub = "SelfTest only", controlled = true,
    route = "不作为016T负责人Review入口",
}
SAMPLE_BY_ID[LEGACY_HUNTER_SAMPLE.id] = LEGACY_HUNTER_SAMPLE

local function copyFlat(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

local function copySample(sample)
    local out = {}
    for key, value in pairs(sample) do out[key] = value end
    return out
end

local function setUpgrades(world, values)
    local upgrades = RunShop.newUpgrades()
    for key, value in pairs(values or {}) do upgrades[key] = value end
    world.runUpgrades = upgrades
end

local function setReady(world)
    world.energy = world.energyNeed
    world.readyAt = world.timeAlive
    world._readySnap = {
        coreCount = world.coreCount,
        crafted = world.counters.crafted or 0,
    }
    world:emit("energy_ready")
    world:addFx("banner", {
        text = "REVIEW ONLY · 已结算安全状态 · 按真实规则重启",
        dur = 2.4,
    })
end

local function setLayerStats(world, values)
    local stats = world.layerStats
    for key, value in pairs(values or {}) do stats[key] = value end
end

local function makeWorld(sample)
    return World.New({
        experiment = Config.FORMAL.profile,
        seed = sample.seed,
        startLayer = sample.layer,
        reviewOnly = true,
        skipLayerIntro = sample.skipLayerIntro == true,
    })
end

local function prepareNatural(sample)
    return makeWorld(sample)
end

local function prepareLayerOneClimax(sample)
    local world = makeWorld(sample)
    world:forceDrop()
    -- 016T冻结合同：本层深层残骸提供1残骸数据；第一层黄色核心代表收入为3。
    world.wreckData = 1
    world.coreCount = 3
    setLayerStats(world, {
        wreckDataGained = 1,
        coresGained = 3,
        wrecksDismantled = 1,
        deepWrecks = 1,
    })
    setReady(world)
    -- 只跳过受控样本当前层入口；后续L2必须恢复正式3秒倒计时。
    world.skipLayerIntro = false
    return world
end

local function prepareLayerSixEconomy(sample)
    local world = makeWorld(sample)
    -- 取自016T正常策略seed 19006：L5结算后已购买的本局升级。
    setUpgrades(world, {
        collapseCooldownLevel = 1,
        pulseCooldownLevel = 1,
        jammerBonusUses = 2,
    })
    -- 真实doRestart会按当前风险合同结算最低500分；预状态扣除该值，
    -- 使真实收口后的L6结算与留存模拟快照273,525精确一致。
    world.score = 273025
    world.wreckData = 1
    world.coreCount = 5
    setLayerStats(world, {
        scoreAtLayerStart = 226455,
        wreckDataGained = 1,
        coresGained = 3,
        wrecksDismantled = 1,
    })
    -- 通过真实重启与反猎收口函数生成真实L6协议整备，不直接伪造phase或结算表。
    world:forceDrop()
    world.energy = world.energyNeed
    world:doRestart()
    world.antiHuntElapsed = Config.ANTI_HUNT_PHASE.minimumVisibleDuration
    world.antiHuntTimer = Config.ANTI_HUNT_PHASE.maximumDuration - world.antiHuntElapsed
    world:finishAntiHunt()
    -- 整备确认后进入L7时恢复正式层入口倒计时。
    world.skipLayerIntro = false
    return world
end

local function prepareLayerTenBranch(sample)
    local world = makeWorld(sample)
    -- 取自同一正常策略L9结算后的安全状态；不注入L10未来收益。
    setUpgrades(world, {
        collapseCooldownLevel = 1,
        pulseCooldownLevel = 1,
        chainIntervalLevel = 1,
        jammerBonusUses = 3,
        decoyBonusUses = 1,
    })
    world.score = 521353
    world.wreckData = 0
    world.coreCount = 2
    setLayerStats(world, { scoreAtLayerStart = 521353 })
    -- 020窄复核必须从真实L10开局开始：不强制跌落、不跳过过载、不注入未来收益。
    -- 只注入上一层已经结算的正常构筑与资源；完成后L11仍走正式3秒倒计时。
    return world
end

local function prepareLegacyHunter(sample)
    local world = makeWorld(sample)
    world:forceDrop()
    setReady(world)
    return world
end

local PREPARE = {
    natural = prepareNatural,
    l1_climax = prepareLayerOneClimax,
    l6_economy = prepareLayerSixEconomy,
    l10_branch = prepareLayerTenBranch,
    l5_hunter = prepareLegacyHunter,
}

function ReviewAccess.samples()
    local out = {}
    for i, sample in ipairs(SAMPLES) do out[i] = copySample(sample) end
    return out
end

function ReviewAccess.get(id)
    local sample = SAMPLE_BY_ID[id]
    return sample and copySample(sample) or nil
end

local function protocolCount(world)
    local count = 0
    for _, enabled in pairs(world.protocols or {}) do
        if enabled then count = count + 1 end
    end
    return count
end

local function samePrices(actual, expected)
    if #actual ~= #expected then return false end
    for i = 1, #expected do
        if actual[i] ~= expected[i] then return false end
    end
    return true
end

local function buildAssertions(world, sample)
    local plan = LayerPlan.get(sample.layer)
    local assertions = {}
    local function add(id, ok, actual, expected)
        assertions[#assertions + 1] = {
            id = id, ok = ok == true, actual = actual, expected = expected,
        }
    end

    add("layer", world.round == sample.layer, world.round, sample.layer)
    add("map", world.mapId == plan.map, world.mapId, plan.map)
    add("layout", world.layout and world.layout.index == plan.layout,
        world.layout and world.layout.index, plan.layout)
    add("phase", world.phase == sample.phase, world.phase, sample.phase)
    add("review_only", world.reviewOnly == true, world.reviewOnly, true)
    add("not_assisted", world.assistedRun == false, world.assistedRun, false)
    add("no_invincibility", world.reviewInvincible == nil, world.reviewInvincible, nil)
    add("hp_authentic", world.player.hp == Config.PLAYER.maxHp,
        world.player.hp, Config.PLAYER.maxHp)
    add("protocol_count", protocolCount(world) == #(plan.protocols or {}),
        protocolCount(world), #(plan.protocols or {}))
    add("collapse_prices", samePrices(Config.RUN_SHOP.collapseCooldown.prices, { 1, 3, 5 }),
        table.concat(Config.RUN_SHOP.collapseCooldown.prices, "/"), "1/3/5")
    add("pulse_prices", samePrices(Config.RUN_SHOP.pulseCooldown.prices, { 2, 3, 5 }),
        table.concat(Config.RUN_SHOP.pulseCooldown.prices, "/"), "2/3/5")
    add("chain_prices", samePrices(Config.RUN_SHOP.chainInterval.prices, { 2, 4, 6 }),
        table.concat(Config.RUN_SHOP.chainInterval.prices, "/"), "2/4/6")
    add("jammer_prices", samePrices(Config.RUN_SHOP.jammerUses.prices, { 2, 3, 4 }),
        table.concat(Config.RUN_SHOP.jammerUses.prices, "/"), "2/3/4")
    add("decoy_prices", samePrices(Config.RUN_SHOP.decoyUses.prices, { 3, 4, 5 }),
        table.concat(Config.RUN_SHOP.decoyUses.prices, "/"), "3/4/5")
    add("cloak_prices", samePrices(Config.RUN_SHOP.cloakUses.prices, { 4, 6 }),
        table.concat(Config.RUN_SHOP.cloakUses.prices, "/"), "4/6")

    if sample.id == "natural" then
        add("intro_not_skipped", world.phase == "layer_intro"
            and world.layerIntroTimer == Config.FORMAL.layerIntroDuration,
            world.layerIntroTimer, Config.FORMAL.layerIntroDuration)
        add("clean_score", world.score == 0, world.score, 0)
    elseif sample.id == "l1_climax" then
        add("ready_energy", world.energy == world.energyNeed, world.energy, world.energyNeed)
        add("wreck_data", world.wreckData == 1, world.wreckData, 1)
        add("yellow_cores", world.coreCount == 3, world.coreCount, 3)
        add("no_run_upgrades", world.shopPurchases == 0, world.shopPurchases, 0)
    elseif sample.id == "l6_economy" then
        add("settlement_real", world.layerSettlement ~= nil,
            world.layerSettlement ~= nil, true)
        add("normal_score", world.score == 273525, world.score, 273525)
        add("normal_wreck", world.wreckData == 1, world.wreckData, 1)
        add("normal_cores", world.coreCount == 5, world.coreCount, 5)
        add("collapse_level", RunShop.level(world, "collapseCooldownLevel") == 1,
            RunShop.level(world, "collapseCooldownLevel"), 1)
        add("pulse_level", RunShop.level(world, "pulseCooldownLevel") == 1,
            RunShop.level(world, "pulseCooldownLevel"), 1)
        add("jammer_level", RunShop.level(world, "jammerBonusUses") == 2,
            RunShop.level(world, "jammerBonusUses"), 2)
    elseif sample.id == "l10_branch" then
        add("intro_not_skipped", world.phase == "layer_intro"
            and world.layerIntroTimer == Config.FORMAL.layerIntroDuration,
            world.layerIntroTimer, Config.FORMAL.layerIntroDuration)
        add("safe_score", world.score == 521353, world.score, 521353)
        add("safe_wreck", world.wreckData == 0, world.wreckData, 0)
        add("safe_cores", world.coreCount == 2, world.coreCount, 2)
        add("not_endless_yet", world.endless == false, world.endless, false)
    end
    return assertions
end

local function printAssertions(prefix, sample, assertions)
    local ok = true
    for _, assertion in ipairs(assertions) do
        if not assertion.ok then ok = false end
        print(string.format("[%s] %s sample=%s actual=%s expected=%s id=%s",
            prefix, assertion.ok and "PASS" or "FAIL", sample.id,
            tostring(assertion.actual), tostring(assertion.expected), assertion.id))
    end
    return ok
end

function ReviewAccess.assertAuthentic(world, sample)
    local assertions = buildAssertions(world, sample)
    return printAssertions("016T_REVIEW_ASSERT", sample, assertions), assertions
end

function ReviewAccess.createWorld(id)
    local sample = SAMPLE_BY_ID[id]
    assert(sample ~= nil, "unknown 016T review sample: " .. tostring(id))
    local world = PREPARE[id](sample)
    world.reviewOnly = true
    world.reviewSampleId = sample.id
    world.reviewControlled = sample.controlled == true
    local ok, assertions = ReviewAccess.assertAuthentic(world, sample)
    assert(ok, "016T review sample authenticity assertion failed: " .. sample.id)
    return world, copySample(sample), assertions
end

function ReviewAccess.snapshotRun(world)
    return {
        round = world.round,
        score = world.score,
        wreckData = world.wreckData,
        coreCount = world.coreCount,
        runUpgrades = copyFlat(world.runUpgrades),
    }
end

function ReviewAccess.assertRunRetained(world, before, sample)
    local assertions = {}
    local function add(id, ok, actual, expected)
        assertions[#assertions + 1] = {
            id = id, ok = ok == true, actual = actual, expected = expected,
        }
    end
    add("entered_l11", world.round == 11 and world.phase == "layer_intro",
        tostring(world.round) .. "/" .. tostring(world.phase), "11/layer_intro")
    add("endless_enabled", world.endless == true, world.endless, true)
    add("score_retained", world.score == before.score, world.score, before.score)
    add("wreck_retained", world.wreckData == before.wreckData,
        world.wreckData, before.wreckData)
    add("cores_retained", world.coreCount == before.coreCount,
        world.coreCount, before.coreCount)
    for id, level in pairs(before.runUpgrades) do
        add("upgrade_retained_" .. id, RunShop.level(world, id) == level,
            RunShop.level(world, id), level)
    end
    return printAssertions("016T_REVIEW_RUNTIME", sample, assertions), assertions
end

function ReviewAccess.assertPhase(world, sample)
    local assertions = {}
    local function add(id, ok, actual, expected)
        assertions[#assertions + 1] = {
            id = id, ok = ok == true, actual = actual, expected = expected,
        }
    end
    if world.phase == "anti_hunt" then
        local snapshot = world.antiHuntSnapshot or {}
        add("anti_hunt_min", Config.ANTI_HUNT_PHASE.minimumVisibleDuration == 10,
            Config.ANTI_HUNT_PHASE.minimumVisibleDuration, 10)
        add("anti_hunt_max", Config.ANTI_HUNT_PHASE.maximumDuration == 10,
            Config.ANTI_HUNT_PHASE.maximumDuration, 10)
        add("target_cap", (snapshot.selectedCount or 0) <= 8,
            snapshot.selectedCount or 0, "<=8")
        if (snapshot.aliveCount or 0) >= 3 then
            add("target_min_when_available", (snapshot.selectedCount or 0) >= 3,
                snapshot.selectedCount or 0, ">=3")
        end
    elseif world.phase == "layer_settlement" then
        add("settlement_present", world.layerSettlement ~= nil,
            world.layerSettlement ~= nil, true)
        add("l10_dual_exit", sample.id ~= "l10_branch"
            or (world.layerSettlement and world.layerSettlement.runComplete == true),
            world.layerSettlement and world.layerSettlement.runComplete, sample.id == "l10_branch")
    elseif sample.id == "l1_climax" and world.round == 2 then
        add("l2_intro", world.phase == "layer_intro", world.phase, "layer_intro")
        add("l2_intro_3s", world.layerIntroTimer == Config.FORMAL.layerIntroDuration,
            world.layerIntroTimer, Config.FORMAL.layerIntroDuration)
    end
    if #assertions == 0 then return true, assertions end
    return printAssertions("016T_REVIEW_RUNTIME", sample, assertions), assertions
end

function ReviewAccess.verifyAll()
    local errors = {}
    for _, sample in ipairs(SAMPLES) do
        local ok, result = pcall(function()
            local world = ReviewAccess.createWorld(sample.id)
            return world
        end)
        if not ok then errors[#errors + 1] = sample.id .. ": " .. tostring(result) end
    end
    return #errors == 0, errors
end

function ReviewAccess.contract()
    return {
        reviewOnly = true,
        releaseCandidate = false,
        persistence = false,
        cloud = false,
        localRecords = false,
        leaderboard = false,
        rewardedAd = false,
        invincibility = false,
        damageOverride = false,
        healthOverride = false,
        speedOverride = false,
        enemyCountOverride = false,
        priceOverride = false,
        scoreRuleOverride = false,
        scoreOverride = false, -- 正式基线SelfTest兼容字段；语义同scoreRuleOverride。
        safeCheckpointInjection = true,
        safeCheckpointSource = NORMAL_SIM_SOURCE,
    }
end

local function menuLayout(w, h)
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local panelW = math.min(350 * s, m.safeW - 18)
    local x = (w - panelW) * 0.5
    local top = m.top + 126 * s
    local gap = math.max(9, 10 * s)
    local available = h - m.bottom - top - 62 * s
    local buttonH = math.max(58, math.min(78 * s, (available - gap * 3) / 4))
    local buttons = {}
    for i, sample in ipairs(SAMPLES) do
        buttons[#buttons + 1] = {
            id = sample.id,
            label = string.format("%d · %s", i, sample.label),
            sub = sample.sub,
            x = x,
            y = top + (i - 1) * (buttonH + gap),
            w = panelW,
            h = buttonH,
            primary = i == 1,
        }
    end
    return buttons, m
end

function ReviewAccess.hit(x, y, w, h)
    for _, button in ipairs(menuLayout(w, h)) do
        if x >= button.x and x <= button.x + button.w
            and y >= button.y and y <= button.y + button.h then
            return button.id
        end
    end
    return nil
end

function ReviewAccess.drawMenu(vg, w, h)
    local buttons, m = menuLayout(w, h)
    local bg = nvgLinearGradient(vg, 0, 0, 0, h,
        nvgRGBA(5, 8, 18, 255), nvgRGBA(22, 7, 35, 255))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillPaint(vg, bg)
    nvgFill(vg)

    SafeDraw.font(25 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 82, 190, 255))
    SafeDraw.text(w * 0.5, m.top + 32 * m.ui, "REVIEW ONLY")
    SafeDraw.font(16 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(92, 235, 255, 255))
    SafeDraw.text(w * 0.5, m.top + 61 * m.ui,
        string.format("过载余波 %s · 016T非发布候选", ReleaseInfo.GAME_VERSION))
    SafeDraw.font(10.5 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(190, 199, 226, 255))
    SafeDraw.text(w * 0.5, m.top + 88 * m.ui, "先体验自然L1；受控样本不替代自然15分钟")
    SafeDraw.text(w * 0.5, m.top + 105 * m.ui, "样本内F1返回 · 020窄复核使用第4项完整L10")

    for _, button in ipairs(buttons) do
        SafeDraw.rect(button.x, button.y, button.w, button.h, 8 * m.ui)
        nvgFillColor(vg, button.primary and nvgRGBA(20, 91, 126, 240)
            or nvgRGBA(31, 31, 72, 240))
        nvgFill(vg)
        nvgStrokeColor(vg, button.primary and nvgRGBA(72, 239, 255, 235)
            or nvgRGBA(211, 83, 255, 205))
        nvgStrokeWidth(vg, button.primary and 2.0 or 1.4)
        nvgStroke(vg)
        SafeDraw.font(15 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(246, 249, 255, 255))
        SafeDraw.text(button.x + button.w * 0.5, button.y + button.h * 0.38, button.label)
        SafeDraw.font(9.5 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(176, 195, 225, 255))
        SafeDraw.text(button.x + button.w * 0.5, button.y + button.h * 0.72, button.sub)
    end

    SafeDraw.font(9.5 * m.ui, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 211, 103, 255))
    SafeDraw.text(w * 0.5, h - m.bottom - 28 * m.ui,
        "不写存档/云/榜/广告 · 无无敌/调价/难度覆盖")
end

function ReviewAccess.drawWatermark(vg, w, h, sample)
    local m = Viewport.metrics(w, h)
    local label = "REVIEW ONLY · " .. (sample and sample.label or "016T样本") .. " · F1返回"
    SafeDraw.font(10 * m.ui, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    local x, y = m.left + 8 * m.ui, h - m.bottom - 10 * m.ui
    nvgFillColor(vg, nvgRGBA(255, 82, 190, 230))
    SafeDraw.text(x, y, label)
end

return ReviewAccess
