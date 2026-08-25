-- EndlessOverclock.lua
-- 046：L11+唯一的超限资源与协议Build层。
-- 不参与L1-L10基础商店，不写正式存档，不增加主动按钮或基础技能。

local Config = require "Config"
local Viewport = require "Viewport"
local EndlessOverclock = {}

EndlessOverclock.DATA_COLOR = "purple"
EndlessOverclock.SHARD_THRESHOLD = 5
EndlessOverclock.COST_BASE = 4
EndlessOverclock.COST_STEP = 2
EndlessOverclock.CORE_OVERFLOW_COST = (Config.ENDLESS and Config.ENDLESS.coreOverflowCost) or 3
EndlessOverclock.WRECK_OVERFLOW_COST = (Config.ENDLESS and Config.ENDLESS.wreckOverflowCost) or 4
-- 每张超限卡统一封顶 Lv3。旧版本的“普通卡 +2、突破卡 Lv1”只会让
-- 后段选择在不同卡之间出现不可理解的上限差异；效果本身仍复用既有
-- `mod(level)` 参数，不新增系统或按钮。
EndlessOverclock.REPEATABLE_LEVEL_BONUS = 0
EndlessOverclock.MAX_LEVEL = 3

-- 16张轻量协议卡：每个家族四张，普通卡可叠两级，突破卡只取一次。
EndlessOverclock.CATALOG = {
    { id = "arc_relay", family = "arc", icon = "↗", name = "电弧·续链", desc = "连锁击杀后继续寻找目标", max = 3, core = false },
    { id = "arc_fork", family = "arc", icon = "Y", name = "电弧·分叉", desc = "每次连锁命中追加一条支链", max = 3, core = false },
    { id = "arc_reach", family = "arc", icon = "◎", name = "电弧·远端跳跃", desc = "连锁跳跃范围扩大", max = 3, core = false },
    { id = "arc_overload", family = "arc", icon = "ϟ", name = "电弧·过载网", desc = "突破：连锁目标数显著增加", max = 3, core = true },
    { id = "pulse_ring", family = "pulse", icon = "◎", name = "脉冲·扩环", desc = "脉冲影响范围扩大", max = 3, core = false },
    { id = "pulse_echo", family = "pulse", icon = "◉", name = "脉冲·回声", desc = "脉冲结束后追加一圈回声", max = 3, core = false },
    { id = "pulse_scatter", family = "pulse", icon = "◉", name = "脉冲·散射", desc = "脉冲向外拆成多段波", max = 3, core = false },
    { id = "pulse_break", family = "pulse", icon = "✦", name = "脉冲·破阵", desc = "突破：命中重型后触发局部扩散", max = 3, core = true },
    { id = "collapse_lock", family = "collapse", icon = "⟡", name = "崩解·折射", desc = "崩解命中后向附近目标折射", max = 3, core = false },
    { id = "collapse_cascade", family = "collapse", icon = "⌁", name = "崩解·坍缩链", desc = "目标击破后追锁下一个目标", max = 3, core = false },
    { id = "collapse_refund", family = "collapse", icon = "↺", name = "崩解·回收", desc = "击破重型后返还部分冷却", max = 3, core = false },
    { id = "collapse_core", family = "collapse", icon = "✹", name = "崩解·核心坍塌", desc = "突破：重型击破产生范围爆发", max = 3, core = true },
    { id = "signal_recon", family = "signal", icon = "⌾", name = "信号·带宽", desc = "侦察范围与余波持续时间扩大", max = 3, core = false },
    { id = "signal_decoy", family = "signal", icon = "◇", name = "信号·假回波", desc = "诱饵结束后留下短暂假信号", max = 3, core = false },
    { id = "signal_jam", family = "signal", icon = "×", name = "信号·扩散干扰", desc = "干扰同时影响附近追击者", max = 3, core = false },
    { id = "signal_cloak", family = "signal", icon = "◌", name = "信号·残影", desc = "隐身结束时留下误导残影", max = 3, core = true },
}

local byId = {}
for _, card in ipairs(EndlessOverclock.CATALOG) do byId[card.id] = card end

local function normalizeSeed(value)
    local n = math.floor(tonumber(value) or 1)
    n = n % 2147483647
    if n <= 0 then n = 1 end
    return n
end

local function nextRand(state)
    state.rng = (state.rng * 1103515245 + 12345) % 2147483647
    return state.rng
end

local function state(world)
    if type(world.endlessOverclock) ~= "table" then
        local seed = normalizeSeed(world.endlessRunSeed or world.seed or 1)
        world.endlessOverclock = {
            version = 1,
            runSeed = seed,
            choiceSeed = normalizeSeed(seed * 48271 + 17),
            rng = normalizeSeed(seed * 16807 + 23),
            data = 0,
            shards = 0,
            overflowCores = 0,
            overflowWreckData = 0,
            spent = 0,
            choiceIndex = 0,
            choiceCount = 0,
            layerChoiceCount = 0,
            freeChoiceTokens = 0,
            levels = {},
            history = {},
            currentChoices = nil,
            currentCost = 0,
            lastGainReason = nil,
        }
    end
    return world.endlessOverclock
end

function EndlessOverclock.beginLayer(world)
    local s = EndlessOverclock.ensure(world)
    if not s then return nil end
    s.layerChoiceCount = 0
    s.currentChoices = nil
    s.currentCost = 0
    world.overclockChoiceOpen = false
    return s
end

function EndlessOverclock.isActive(world)
    return world and world.endless == true and (world.round or 0) >= 11
end

function EndlessOverclock.ensure(world)
    if not EndlessOverclock.isActive(world) then return nil end
    return state(world)
end

function EndlessOverclock.protocol(id)
    return byId[id]
end

function EndlessOverclock.level(world, id)
    local s = EndlessOverclock.ensure(world)
    return s and (s.levels[id] or 0) or 0
end

function EndlessOverclock.has(world, id)
    return EndlessOverclock.level(world, id) > 0
end

function EndlessOverclock.gain(world, amount, reason)
    local s = EndlessOverclock.ensure(world)
    if not s then return 0 end
    local gained = math.max(0, math.floor(tonumber(amount) or 0))
    if gained <= 0 then return 0 end
    s.data = s.data + gained
    s.lastGainReason = reason or "action"
    world:addFx("pickup", { x = world.player.x, y = world.player.y,
        text = "+" .. gained .. " 超限数据", color = "cyan", dur = 1.2 })
    world:emit("overclock_data", world.player.x, world.player.y, gained)
    return gained
end

function EndlessOverclock.onEnemyKilled(world, enemy)
    local s = EndlessOverclock.ensure(world)
    if not s then return end
    s.shards = s.shards + (enemy and enemy.kind == "heavy" and 2 or 1)
    while s.shards >= EndlessOverclock.SHARD_THRESHOLD do
        s.shards = s.shards - EndlessOverclock.SHARD_THRESHOLD
        EndlessOverclock.gain(world, 1, "击破")
    end
end

function EndlessOverclock.onDismantle(world, deep)
    local RunShop = require "RunShop"
    local baseFull = true
    for _, item in ipairs(RunShop.CATALOG) do
        if item.currency == "wreckData"
            and RunShop.level(world, item.id) < RunShop.maxLevel(item) then
            baseFull = false
            break
        end
    end
    if not baseFull then return 0, false end
    local units = deep and Config.WRECK_DATA.perDeepWreck
        or Config.WRECK_DATA.perNormalWreck
    local s = EndlessOverclock.ensure(world)
    s.overflowWreckData = (s.overflowWreckData or 0) + math.max(0, math.floor(units or 0))
    local converted = math.floor(s.overflowWreckData / EndlessOverclock.WRECK_OVERFLOW_COST)
    s.overflowWreckData = s.overflowWreckData % EndlessOverclock.WRECK_OVERFLOW_COST
    if converted > 0 then
        EndlessOverclock.gain(world, converted,
            deep and "深层残骸·溢出折算" or "残骸数据·溢出折算")
    end
    return converted, true
end

function EndlessOverclock.onLayerComplete(world)
    if not EndlessOverclock.isActive(world) then return end
    local s = EndlessOverclock.ensure(world)
    -- 每层结算固定给一次免费选择；数据只负责额外升级，不再把正常层间
    -- 选择挡在“数据不足”状态后面。
    s.freeChoiceTokens = (s.freeChoiceTokens or 0) + 1
    EndlessOverclock.gain(world, 1, "层结算")
end

function EndlessOverclock.corePickup(world, amount)
    local s = EndlessOverclock.ensure(world)
    if not s then return 0, false end
    -- 基础商店未满时保留黄色核心；满级以后才折算为超限数据。
    local RunShop = require "RunShop"
    local remaining = false
    for _, item in ipairs(RunShop.CATALOG) do
        if item.currency == "coreCount" and RunShop.level(world, item.id) < RunShop.maxLevel(item) then
            remaining = true
            break
        end
    end
    if remaining then return 0, false end
    local units = math.max(0, math.floor(tonumber(amount) or 1))
    s.overflowCores = (s.overflowCores or 0) + units
    local converted = math.floor(s.overflowCores / EndlessOverclock.CORE_OVERFLOW_COST)
    s.overflowCores = s.overflowCores % EndlessOverclock.CORE_OVERFLOW_COST
    if converted > 0 then EndlessOverclock.gain(world, converted, "核心·溢出折算") end
    return converted, true
end

function EndlessOverclock.overflowSummary(world)
    local s = EndlessOverclock.ensure(world)
    if not s then return "" end
    return string.format("残骸 %d/%d · 核心 %d/%d", s.overflowWreckData or 0,
        EndlessOverclock.WRECK_OVERFLOW_COST, s.overflowCores or 0,
        EndlessOverclock.CORE_OVERFLOW_COST)
end

function EndlessOverclock.maxLevel(cardOrId)
    local card = type(cardOrId) == "table" and cardOrId or byId[cardOrId]
    if not card then return 0 end
    return EndlessOverclock.MAX_LEVEL
end

local function cardAvailable(s, card)
    return (s.levels[card.id] or 0) < EndlessOverclock.maxLevel(card)
end

function EndlessOverclock.cost(world)
    local s = EndlessOverclock.ensure(world)
    return s and (EndlessOverclock.COST_BASE + s.choiceCount * EndlessOverclock.COST_STEP) or 0
end

function EndlessOverclock.prepareChoice(world)
    local s = EndlessOverclock.ensure(world)
    if not s or s.currentChoices or s.layerChoiceCount >= 1 then return false, "choice_already_open" end
    local free = (s.freeChoiceTokens or 0) > 0
    local cost = free and 0 or EndlessOverclock.cost(world)
    if not free and s.data < cost then return false, "超限数据不足" end
    local choices = { _state = s }
    local seen = {}
    local attempts = 0
    while #choices < 3 and attempts < 80 do
        attempts = attempts + 1
        local cardIndex = (nextRand(s) - 1) % #EndlessOverclock.CATALOG + 1
        local card = EndlessOverclock.CATALOG[cardIndex]
        if card and cardAvailable(s, card) and not seen[card.id] then
            seen[card.id] = true
            choices[#choices + 1] = card
        end
    end
    -- 三张卡都满级时仍展示选择页，明确告诉玩家“已满级”；点击后
    -- 保留免费 token、不扣数据，避免无尽流程被卡在不可操作的空页。
    if #choices < 3 then
        for _, card in ipairs(EndlessOverclock.CATALOG) do
            if not seen[card.id] then
                seen[card.id] = true
                choices[#choices + 1] = card
                if #choices == 3 then break end
            end
        end
    end
    choices._state = nil
    if #choices < 3 then return false, "可用协议不足" end
    s.currentChoices = choices
    s.currentCost = cost
    s.choiceMode = free and "free" or "data"
    s.layerChoiceCount = s.layerChoiceCount + 1
    world.overclockChoiceOpen = true
    world:addFx("banner", { text = "超限数据已就绪 · 选择一项协议", dur = 2.0 })
    return true
end

-- L11 入场合同：一次性给出 4 点超限数据并在战斗开始前强制三选一。
-- 该状态会进入 EndlessCheckpoint，刷新后不会重新抽牌或重复发放。
function EndlessOverclock.prepareStarterChoice(world)
    local s = EndlessOverclock.ensure(world)
    if not s then return false, "endless_inactive" end
    if s.starterGranted then
        return s.currentChoices ~= nil, "already_granted"
    end
    s.data = s.data + 4
    s.starterGranted = true
    s.entryChoice = true
    local opened, reason = EndlessOverclock.prepareChoice(world)
    if not opened then
        s.data = s.data - 4
        s.starterGranted = false
        s.entryChoice = false
        return false, reason
    end
    return true
end

-- 只序列化超限层间状态，不带卡片引用，避免 Lua table 共享到存档对象。
function EndlessOverclock.snapshot(world)
    local s = EndlessOverclock.ensure(world)
    if not s then return nil end
    local out = {
        version = s.version, runSeed = s.runSeed, choiceSeed = s.choiceSeed,
        rng = s.rng, data = s.data, shards = s.shards, spent = s.spent,
        overflowCores = s.overflowCores or 0,
        overflowWreckData = s.overflowWreckData or 0,
        choiceIndex = s.choiceIndex, choiceCount = s.choiceCount,
        layerChoiceCount = s.layerChoiceCount, starterGranted = s.starterGranted == true,
        freeChoiceTokens = s.freeChoiceTokens or 0,
        entryChoice = s.entryChoice == true, choiceMode = s.choiceMode,
        currentCost = s.currentCost,
        lastGainReason = s.lastGainReason, levels = {}, history = {}, currentChoices = nil,
    }
    for id, level in pairs(s.levels or {}) do out.levels[id] = level end
    for index, item in ipairs(s.history or {}) do
        out.history[index] = { layer = item.layer, id = item.id, cost = item.cost }
    end
    if s.currentChoices then
        out.currentChoices = {}
        for index, card in ipairs(s.currentChoices) do
            out.currentChoices[index] = { id = card.id }
        end
    end
    return out
end

function EndlessOverclock.restore(world, raw)
    local s = EndlessOverclock.ensure(world)
    if not s or type(raw) ~= "table" then return false end
    s.version = tonumber(raw.version) or 1
    s.runSeed = normalizeSeed(raw.runSeed)
    s.choiceSeed = normalizeSeed(raw.choiceSeed)
    s.rng = normalizeSeed(raw.rng)
    s.data = math.max(0, math.floor(tonumber(raw.data) or 0))
    s.shards = math.max(0, math.floor(tonumber(raw.shards) or 0))
    s.overflowCores = math.max(0, math.floor(tonumber(raw.overflowCores) or 0))
        % EndlessOverclock.CORE_OVERFLOW_COST
    s.overflowWreckData = math.max(0, math.floor(tonumber(raw.overflowWreckData) or 0))
        % EndlessOverclock.WRECK_OVERFLOW_COST
    s.spent = math.max(0, math.floor(tonumber(raw.spent) or 0))
    s.choiceIndex = math.max(0, math.floor(tonumber(raw.choiceIndex) or 0))
    s.choiceCount = math.max(0, math.floor(tonumber(raw.choiceCount) or 0))
    s.layerChoiceCount = math.max(0, math.floor(tonumber(raw.layerChoiceCount) or 0))
    s.freeChoiceTokens = math.max(0, math.floor(tonumber(raw.freeChoiceTokens) or 0))
    s.starterGranted = raw.starterGranted == true
    s.entryChoice = raw.entryChoice == true
    if raw.choiceMode == "free" or raw.choiceMode == "data"
        or raw.choiceMode == "starter" then
        s.choiceMode = raw.choiceMode
    else
        s.choiceMode = nil
    end
    s.currentCost = math.max(0, math.floor(tonumber(raw.currentCost) or 0))
    s.lastGainReason = raw.lastGainReason
    s.levels, s.history, s.currentChoices = {}, {}, nil
    for id, level in pairs(type(raw.levels) == "table" and raw.levels or {}) do
        if byId[id] then
            s.levels[id] = math.min(EndlessOverclock.maxLevel(byId[id]),
                math.max(0, math.floor(tonumber(level) or 0)))
        end
    end
    for index, item in ipairs(type(raw.history) == "table" and raw.history or {}) do
        if type(item) == "table" and byId[item.id] then
            s.history[index] = { layer = math.floor(tonumber(item.layer) or 0),
                id = item.id, cost = math.max(0, math.floor(tonumber(item.cost) or 0)) }
        end
    end
    if type(raw.currentChoices) == "table" and #raw.currentChoices == 3 then
        s.currentChoices = {}
        for index, item in ipairs(raw.currentChoices) do
            local id = type(item) == "table" and item.id or item
            if not byId[id] then
                s.currentChoices = nil
                break
            end
            s.currentChoices[index] = byId[id]
        end
    end
    world.overclockChoiceOpen = s.currentChoices ~= nil
    return true
end

local EFFECT_TEXT = {
    arc_relay = function(level) return string.format("连锁窗口 +%.1f 秒", level * 0.35) end,
    arc_fork = function(level) return string.format("每次连锁 +%d 条支链", level) end,
    arc_reach = function(level) return string.format("连锁范围 +%d%%", level * 14) end,
    arc_overload = function(level) return string.format("突破：连锁目标上限 +%d", level * 2) end,
    pulse_ring = function(level) return string.format("脉冲半径 +%d%%", level * 22) end,
    pulse_echo = function(level) return string.format("结束后追加 %d 圈回声", level) end,
    pulse_scatter = function(level) return string.format("向外追加 %d 段波", level * 2) end,
    pulse_break = function(level) return string.format("突破：重型命中后扩散强度 +%d%%", level * 25) end,
    collapse_lock = function(level) return string.format("命中后再折射 %d 个目标", level) end,
    collapse_cascade = function(level) return string.format("击破后追锁 %d 次", level) end,
    collapse_refund = function(level) return string.format("重型击破返还冷却 %d%%", level * 12) end,
    collapse_core = function(level) return string.format("突破：重型击破范围爆发 +%d%%", level * 20) end,
    signal_recon = function(level) return string.format("侦察范围 +%d%% · 余波 +%.1f 秒", level * 22, level * 0.5) end,
    signal_decoy = function(level) return string.format("诱饵假信号持续 %.1f 秒", level * 0.8) end,
    signal_jam = function(level) return string.format("干扰额外影响 %d 个追击者", level) end,
    signal_cloak = function(level) return string.format("突破：隐身结束留下残影 · Lv%d", level) end,
}

function EndlessOverclock.effectText(cardOrId, level)
    local id = type(cardOrId) == "table" and cardOrId.id or cardOrId
    local fn = EFFECT_TEXT[id]
    return fn and fn(math.max(1, tonumber(level) or 1))
        or (type(cardOrId) == "table" and cardOrId.desc or "改变现有能力")
end

function EndlessOverclock.applyChoice(world, index)
    local s = EndlessOverclock.ensure(world)
    if not s or not s.currentChoices then return false, "当前没有超限选择" end
    local card = s.currentChoices[math.floor(tonumber(index) or 0)]
    if not card then return false, "无效协议" end
    local level = s.levels[card.id] or 0
    if level >= EndlessOverclock.maxLevel(card) then
        s.currentChoices, s.currentCost, s.choiceMode = nil, 0, nil
        world.overclockChoiceOpen = false
        world:addFx("banner", { text = card.name .. " · 已满级 · 选择点保留", dur = 1.8 })
        return true, card, "maxed_token_preserved"
    end
    if s.data < s.currentCost then return false, "超限数据不足" end
    local wasFree = s.choiceMode == "free"
    s.data = s.data - s.currentCost
    if wasFree then s.freeChoiceTokens = math.max(0, (s.freeChoiceTokens or 0) - 1) end
    s.spent = s.spent + s.currentCost
    s.choiceIndex = s.choiceIndex + 1
    s.choiceCount = s.choiceCount + 1
    s.levels[card.id] = (s.levels[card.id] or 0) + 1
    s.history[#s.history + 1] = { layer = world.round, id = card.id, cost = s.currentCost }
    s.currentChoices, s.currentCost, s.choiceMode = nil, 0, nil
    world.overclockChoiceOpen = false
    world:addFx("phaseflash", { color = "overload", dur = 0.35 })
    world:addFx("banner", { text = card.name .. " · Lv" .. s.levels[card.id], dur = 1.8 })
    world:emit("overclock_choice", world.player.x, world.player.y, card.id)
    return true, card
end

function EndlessOverclock.hit(world, x, y, w, h)
    local s = EndlessOverclock.ensure(world)
    if not s or not s.currentChoices then return nil end
    local m = Viewport.metrics(w, h)
    local scale = m.ui
    local layout = EndlessOverclock.choiceLayout(w, h)
    local cardW, cardH, x0, y0, gap = layout.cardW, layout.cardH,
        layout.x, layout.y, layout.gap
    for i = 1, 3 do
        local y1 = y0 + (i - 1) * (cardH + gap)
        if x >= x0 and x <= x0 + cardW and y >= y1 and y <= y1 + cardH then return "overclock:" .. i end
    end
    return nil
end

function EndlessOverclock.choiceLayout(w, h)
    local m = Viewport.metrics(w, h)
    local scale = m.ui
    local cardW = math.min(344 * scale, m.safeW - 28 * scale)
    local cardH = 88 * scale
    local gap = 8 * scale
    local x = (w - cardW) * 0.5
    local y = m.top + 122 * scale
    return { scale = scale, cardW = cardW, cardH = cardH, gap = gap, x = x, y = y,
        titleTop = y - 108 * scale, titleHeight = 96 * scale }
end

function EndlessOverclock.mod(world, id)
    return EndlessOverclock.level(world, id)
end

function EndlessOverclock.reconRadiusMultiplier(world)
    return 1 + EndlessOverclock.mod(world, "signal_recon") * 0.22
end

function EndlessOverclock.protocolSummary(world)
    local s = EndlessOverclock.ensure(world)
    if not s then return "" end
    local names = {}
    for _, card in ipairs(EndlessOverclock.CATALOG) do
        local lv = s.levels[card.id] or 0
        if lv > 0 then names[#names + 1] = card.name .. " Lv" .. lv end
    end
    return table.concat(names, " · ")
end

function EndlessOverclock.validate(world)
    if not EndlessOverclock.isActive(world) then return true end
    local s = state(world)
    if s.data < 0 or s.spent < 0 or s.choiceCount < 0 then return false, "invalid overclock balances" end
    if s.currentChoices and #s.currentChoices ~= 3 then return false, "choice pool must have 3 cards" end
    for _, card in ipairs(EndlessOverclock.CATALOG) do
        if (s.levels[card.id] or 0) > EndlessOverclock.maxLevel(card) then
            return false, "protocol over level " .. card.id
        end
    end
    return true
end

return EndlessOverclock
