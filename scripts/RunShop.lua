-- RunShop.lua
-- 本局协议整备。纯逻辑 + 布局/命中，绘制在 Render.drawRunShop。
--
-- 设计边界（不要越界）：
--   * 只在本局有效：升级存放在 world.runUpgrades，死亡随 World 一起丢弃。
--   * 不写 SaveSys、不上传 clientCloud、不影响排行榜资格。
--   * 不随机、不刷新商品、不设品质、不做三选一。
--   * 实际数值一律用 effective* 基于 Config 基础值计算，绝不修改全局 Config。
--   * 消费不改变已经获得的分数，也不提供任何分数倍率。
--
-- 两种资源：
--   残骸数据 wreckData —— 拆解普通重型残骸获得，用于过载协议。
--   黄色核心 coreCount —— 地图核心堆与深层残骸获得，用于枯竭补给。

local Config = require "Config"

local RunShop = {}

-- 商品目录。顺序即显示顺序，两组分别对应两种资源。
RunShop.CATALOG = {
    {
        id = "collapseCooldownLevel",
        group = "overload",
        currency = "wreckData",
        name = "崩解优化",
        spec = "collapseCooldown",
        unit = "秒",
        desc = "降低系统崩解冷却",
    },
    {
        id = "pulseCooldownLevel",
        group = "overload",
        currency = "wreckData",
        name = "脉冲优化",
        spec = "pulseCooldown",
        unit = "秒",
        desc = "降低区域脉冲冷却",
    },
    {
        id = "chainIntervalLevel",
        group = "overload",
        currency = "wreckData",
        name = "链路优化",
        spec = "chainInterval",
        unit = "秒",
        desc = "加快连锁攻击频率（不提高单次伤害）",
    },
    {
        id = "jammerBonusUses",
        group = "depleted",
        currency = "coreCount",
        name = "干扰次数",
        spec = "jammerUses",
        unit = "次",
        desc = "提高后续枯竭阶段干扰弹基础次数",
    },
    {
        id = "decoyBonusUses",
        group = "depleted",
        currency = "coreCount",
        name = "诱饵次数",
        spec = "decoyUses",
        unit = "次",
        desc = "提高后续枯竭阶段诱饵信标基础次数",
    },
    {
        id = "cloakBonusUses",
        group = "depleted",
        currency = "coreCount",
        name = "隐身次数",
        spec = "cloakUses",
        unit = "次",
        desc = "提高后续枯竭阶段光学隐身基础次数",
    },
}

RunShop.GROUP_NAMES = {
    overload = "过载协议 · 残骸数据",
    depleted = "枯竭补给 · 黄色核心",
}

RunShop.CURRENCY_NAMES = {
    wreckData = "残骸数据",
    coreCount = "黄色核心",
}

-- ============================================================
-- 本局升级状态
-- ============================================================

function RunShop.newUpgrades()
    return {
        collapseCooldownLevel = 0,
        pulseCooldownLevel = 0,
        chainIntervalLevel = 0,
        jammerBonusUses = 0,
        decoyBonusUses = 0,
        cloakBonusUses = 0,
    }
end

local function upgrades(world)
    if not world.runUpgrades then world.runUpgrades = RunShop.newUpgrades() end
    return world.runUpgrades
end
RunShop.upgrades = upgrades

function RunShop.level(world, id)
    return upgrades(world)[id] or 0
end

local function specOf(item)
    return Config.RUN_SHOP[item.spec]
end

function RunShop.maxLevel(item)
    return specOf(item).maxLevel
end

-- 下一级价格；已满级返回 nil。
function RunShop.priceOf(world, item)
    local spec = specOf(item)
    local lvl = RunShop.level(world, item.id)
    if lvl >= spec.maxLevel then return nil end
    return spec.prices[lvl + 1]
end

function RunShop.balance(world, currency)
    if currency == "wreckData" then return world.wreckData or 0 end
    return world.coreCount or 0
end

-- ============================================================
-- 生效数值（基于 Config 基础值计算，不修改 Config）
-- ============================================================

-- 生效数值的纯函数形式：显式传入等级，不读也不改 world.runUpgrades。
-- effectText 用它算"升级后"的预览值，避免临时改状态。
local function valueAtLevel(itemId, level)
    local R = Config.RUN_SHOP
    if itemId == "collapseCooldownLevel" then
        return math.max(R.collapseCooldown.floor,
            Config.OVERLOAD.collapseCooldown - level * R.collapseCooldown.perLevel)
    elseif itemId == "pulseCooldownLevel" then
        return math.max(R.pulseCooldown.floor,
            Config.OVERLOAD.pulseCooldown - level * R.pulseCooldown.perLevel)
    elseif itemId == "chainIntervalLevel" then
        return math.max(R.chainInterval.floor,
            Config.OVERLOAD.chainInterval * (1 - level * R.chainInterval.perLevel))
    elseif itemId == "jammerBonusUses" then
        return Config.DEPLETED.jammerUses + level
    elseif itemId == "decoyBonusUses" then
        return Config.DEPLETED.decoyUses + level
    end
    return Config.DEPLETED.cloakUses + level
end
RunShop.valueAtLevel = valueAtLevel

function RunShop.effectiveCollapseCooldown(world)
    return valueAtLevel("collapseCooldownLevel",
        world and RunShop.level(world, "collapseCooldownLevel") or 0)
end

function RunShop.effectivePulseCooldown(world)
    return valueAtLevel("pulseCooldownLevel",
        world and RunShop.level(world, "pulseCooldownLevel") or 0)
end

function RunShop.effectiveChainInterval(world)
    return valueAtLevel("chainIntervalLevel",
        world and RunShop.level(world, "chainIntervalLevel") or 0)
end

-- 每次进入枯竭时的工具基础次数 = Config 基础次数 + 本局加成。
-- forceDrop 必须走这三个函数，否则升级效果会被基础份额覆盖掉。
function RunShop.effectiveJammerUses(world)
    return valueAtLevel("jammerBonusUses", RunShop.level(world, "jammerBonusUses"))
end

function RunShop.effectiveDecoyUses(world)
    return valueAtLevel("decoyBonusUses", RunShop.level(world, "decoyBonusUses"))
end

function RunShop.effectiveCloakUses(world)
    return valueAtLevel("cloakBonusUses", RunShop.level(world, "cloakBonusUses"))
end

-- 升级前/后效果文案。返回 beforeText, afterText（满级时 afterText 为 nil）。
function RunShop.effectText(world, item)
    local lvl = RunShop.level(world, item.id)
    local spec = specOf(item)
    local function fmt(level)
        local v = valueAtLevel(item.id, level)
        if item.unit == "秒" then
            return string.format(item.id == "chainIntervalLevel" and "%.2f 秒" or "%.1f 秒", v)
        end
        return string.format("%d 次", v)
    end
    local before = fmt(lvl)
    if lvl >= spec.maxLevel then return before, nil end
    return before, fmt(lvl + 1)
end

-- ============================================================
-- 购买
-- ============================================================

-- 返回 ok, reason。reason 可直接作为禁用原因文案。
function RunShop.canBuy(world, item)
    if world.checkpointReady then return false, "检查点已确认" end
    local spec = specOf(item)
    if RunShop.level(world, item.id) >= spec.maxLevel then
        return false, "等级已满"
    end
    local price = RunShop.priceOf(world, item)
    local balance = RunShop.balance(world, item.currency)
    if balance < price then
        local unit = item.currency == "wreckData" and "数据" or "核心"
        return false, string.format("还差 %d %s", price - balance, unit)
    end
    return true, nil
end

function RunShop.buy(world, itemId)
    local item = RunShop.itemById(itemId)
    if not item then return false, "无此项目" end
    local ok, reason = RunShop.canBuy(world, item)
    if not ok then return false, reason end
    local price = RunShop.priceOf(world, item)
    if item.currency == "wreckData" then
        world.wreckData = (world.wreckData or 0) - price
    else
        world.coreCount = (world.coreCount or 0) - price
    end
    local u = upgrades(world)
    u[item.id] = (u[item.id] or 0) + 1
    local _, after = RunShop.effectText(world, item)
    world.shopPurchases = (world.shopPurchases or 0) + 1
    return true, string.format("%s Lv%d 已生效", item.name, u[item.id])
end

function RunShop.itemById(id)
    for _, item in ipairs(RunShop.CATALOG) do
        if item.id == id then return item end
    end
    return nil
end

-- ============================================================
-- 布局与命中（逻辑像素；Render 与输入共用同一份，绘制与命中一致）
-- ============================================================

-- 整备 UI 只保存瞬态展示状态，不进入存档或玩法数值。
local function uiState(world)
    if not world.shopUi then
        world.shopUi = { scrollY = 0, pulseId = nil, pulseLeft = 0, hintLeft = 0 }
    end
    return world.shopUi
end

function RunShop.open(world)
    local ui = uiState(world)
    ui.scrollY = 0
    ui.pulseId, ui.pulseLeft = nil, 0
    if not world.shopHintShown then
        world.shopHintShown = true
        ui.hintLeft = 3.2
    else
        ui.hintLeft = 0
    end
end

function RunShop.tick(world, dt)
    local ui = uiState(world)
    ui.pulseLeft = math.max(0, (ui.pulseLeft or 0) - dt)
    ui.hintLeft = math.max(0, (ui.hintLeft or 0) - dt)
    if ui.pulseLeft <= 0 then ui.pulseId = nil end
end

function RunShop.pulse(world, itemId)
    local ui = uiState(world)
    ui.pulseId = itemId
    ui.pulseLeft = 0.65
end

-- 返回固定标题区、可滚动卡片视口和固定底部确认按钮。所有坐标均为模式 B
-- 的逻辑像素，Render 与 InputSys 共用，避免滚动后绘制/命中错位。
function RunShop.layout(world, w, h)
    local Viewport = require "Viewport"
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local panelW = math.min(430 * s, m.safeW - 12)
    local panelX = (w - panelW) * 0.5
    local panelY = m.top + 8 * s
    local confirmH = 56 * s
    local confirmY = h - m.bottom - confirmH - 8 * s
    local panelH = math.max(180 * s, confirmY - panelY - 8 * s)
    local headerH = math.min(106 * s, math.max(92 * s, panelH - 64 * s))
    local viewport = {
        x = panelX + 7 * s,
        y = panelY + headerH,
        w = panelW - 14 * s,
        h = math.max(60 * s, panelH - headerH - 7 * s),
    }
    local groupH, rowH, gap = 24 * s, 88 * s, 7 * s
    local contentH = groupH * 2 + rowH * 6 + gap * 7
    local scrollMax = math.max(0, contentH - viewport.h)
    local ui = uiState(world)
    ui.scrollY = math.max(0, math.min(ui.scrollY or 0, scrollMax))

    local rows, groupLabels = {}, {}
    local contentY = 0
    local lastGroup = nil
    for _, item in ipairs(RunShop.CATALOG) do
        if item.group ~= lastGroup then
            lastGroup = item.group
            groupLabels[#groupLabels + 1] = {
                group = item.group,
                y = viewport.y + contentY - ui.scrollY + groupH * 0.5,
            }
            contentY = contentY + groupH + gap
        end
        local enabled, reason = RunShop.canBuy(world, item)
        local before, after = RunShop.effectText(world, item)
        local balance = RunShop.balance(world, item.currency)
        local price = RunShop.priceOf(world, item)
        rows[#rows + 1] = {
            item = item,
            x = viewport.x,
            y = viewport.y + contentY - ui.scrollY,
            w = viewport.w,
            h = rowH,
            enabled = enabled,
            reason = reason,
            price = price,
            balance = balance,
            shortage = price and math.max(0, price - balance) or 0,
            before = before,
            after = after,
            level = RunShop.level(world, item.id),
            maxLevel = RunShop.maxLevel(item),
            pulsing = ui.pulseId == item.id and ui.pulseLeft > 0,
            pulse = ui.pulseId == item.id and math.min(1, ui.pulseLeft / 0.65) or 0,
        }
        contentY = contentY + rowH + gap
    end

    return {
        panel = { x = panelX, y = panelY, w = panelW, h = panelH },
        headerH = headerH,
        scale = s,
        groups = groupLabels,
        rows = rows,
        viewport = viewport,
        scrollY = ui.scrollY,
        scrollMax = scrollMax,
        hintLeft = ui.hintLeft or 0,
        confirm = { x = panelX, y = confirmY, w = panelW, h = confirmH },
    }
end

function RunShop.scrollBy(world, delta, w, h)
    local ui = uiState(world)
    local lay = RunShop.layout(world, w, h)
    ui.scrollY = math.max(0, math.min((ui.scrollY or 0) + delta, lay.scrollMax))
    return ui.scrollY
end

function RunShop.graduationLayout(world, w, h)
    local Viewport = require "Viewport"
    local m = Viewport.metrics(w, h)
    local s = m.ui
    local panelW = math.min(360 * s, m.safeW - 20)
    local panelH = math.min(430 * s, m.safeH - 28)
    local panel = { x = (w - panelW) * 0.5, y = m.top + (m.safeH - panelH) * 0.5,
        w = panelW, h = panelH }
    local cards = {}
    local cardH, gap = 82 * s, 8 * s
    local y = panel.y + 62 * s
    for index = 1, 3 do
        cards[index] = { x = panel.x + 12 * s, y = y, w = panel.w - 24 * s,
            h = cardH, slot = index }
        y = y + cardH + gap
    end
    return {
        panel = panel,
        cards = cards,
        cancel = { x = panel.x + 12 * s, y = panel.y + panel.h - 54 * s,
            w = panel.w - 24 * s, h = 42 * s },
        scale = s,
    }
end

local function contains(rect, x, y)
    return x >= rect.x and x <= rect.x + rect.w
        and y >= rect.y and y <= rect.y + rect.h
end

-- 返回 "buy:<itemId>" / "confirm" / "complete" / nil。
-- 固定 footer 优先；卡片只有在可滚动视口内可命中。
function RunShop.hit(world, x, y, w, h)
    if world.graduationArchiveOpen == true then
        local modal = RunShop.graduationLayout(world, w, h)
        if contains(modal.cancel, x, y) then return "graduationCancel" end
        for _, card in ipairs(modal.cards) do
            if contains(card, x, y) then return "graduationSlot:" .. tostring(card.slot) end
        end
        return nil
    end
    local lay = RunShop.layout(world, w, h)
    local c = lay.confirm
    if contains(c, x, y) then
        if world.endless == true and world.endlessCheckpointSaveFailed == true
            and world.checkpointReady ~= true then
            local half = (c.w - 8 * lay.scale) * 0.5
            if x <= c.x + half then return "checkpointSuspend" end
            if x >= c.x + half + 8 * lay.scale then return "confirm" end
            return nil
        end
        if world.checkpointReady then
            local half = (c.w - 8 * lay.scale) * 0.5
            if x <= c.x + half then return "checkpointSuspend" end
            if x >= c.x + half + 8 * lay.scale then return "checkpointContinue" end
            return nil
        end
        local st = world.layerSettlement
        if st and st.runComplete then
            local half = (c.w - 8 * lay.scale) * 0.5
            if x <= c.x + half then return "complete" end
            if x >= c.x + half + 8 * lay.scale then return "confirm" end
            return nil
        end
        return "confirm"
    end
    if not contains(lay.viewport, x, y) then return nil end
    for _, row in ipairs(lay.rows) do
        if contains(row, x, y) then return "buy:" .. row.item.id, row end
    end
    return nil
end

return RunShop
