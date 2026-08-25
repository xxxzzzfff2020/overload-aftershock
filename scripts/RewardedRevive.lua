-- RewardedRevive.lua
-- 统一激励复活合同：
--   普通模式：保留“本层从头开始”，广告复活不设本局次数上限；
--   无尽模式：同一 Run 共用 3 次广告复活，不提供本层从头开始；
--   广告成功只由 SDK result.success == true 决定，失败可重新选择；
--   所有广告复活局带 assisted 标记，统一榜单保留该元数据。

local RewardedRevive = {}

RewardedRevive.RESERVED_COMPATIBILITY_NOTICE =
    "Runtime-gated rewarded revive. Only success callbacks grant the selected revive."

RewardedRevive.CONTRACT = {
    placement = "death_revive",
    -- nil 表示普通模式不设本局上限；不要把 nil 改成一个伪造的每日上限。
    perRunLimit = nil,
    endlessPerRunLimit = 3,
    dailyHardCap = nil,
    firstLayerDisabled = false,
    firstSecondsDisabled = 0,
    productUseApproved = true,
    compatibilityNotice = RewardedRevive.RESERVED_COMPATIBILITY_NOTICE,
}

local function dayKey(now)
    return os.date("%Y-%m-%d", now or os.time())
end

local function dailyCountValue(best, now)
    if type(best) ~= "table" then return 0 end
    if best.rewardedReviveDay ~= dayKey(now) then return 0 end
    return math.max(0, math.floor(tonumber(best.rewardedReviveCount) or 0))
end

local function recordDailyReward(best, now)
    if type(best) ~= "table" then return 0 end
    local count = dailyCountValue(best, now)
    best.rewardedReviveDay = dayKey(now)
    best.rewardedReviveCount = count + 1
    return best.rewardedReviveCount
end

local function reviveCount(world)
    return math.max(0, math.floor(tonumber(world and world.rewardedReviveCount) or 0))
end

-- 广告 SDK 只有统一回调，且不能由游戏主动取消。客户端可以结束本地等待，
-- 但必须使旧请求失效；失败提示必须原样映射到玩家界面，绝不能根据 msg
-- 推测“其实看完了”并错误发奖。
-- 这里返回新 table，避免 UI 侧把冻结文案误写回全局合同。
function RewardedRevive.failurePresentation(reason)
    reason = tostring(reason or "ad_failed")
    if reason == "embed manual close" then
        return {
            kind = "manual_close",
            title = "本次未获得奖励",
            body = "广告未完整播放到可领取状态，无法复活。若广告内出现“继续播放”，请先继续；请以广告自身明确结束为准，再返回游戏。",
        }
    end
    if reason == "ad_timeout" then
        return {
            kind = "timeout",
            title = "广告响应超时",
            body = "广告未返回结果，本次未获得复活。请确认返回后重新选择。",
        }
    end
    return {
        kind = "unavailable",
        title = "广告暂不可用",
        body = "本次未获得复活，请稍后重试。",
    }
end

function RewardedRevive.dismissFailure(world)
    if type(world) ~= "table" then return false end
    world.rewardedReviveFailureNotice = nil
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    return true
end

-- SDK 长时间未返回时，保留当前有效请求并把选择权交给玩家。软超时不是失败，
-- 更不能触发奖励；继续等待后仍可接受该请求唯一一次有效的 success 回调。
function RewardedRevive.markSoftTimeout(world)
    if type(world) ~= "table" or world.rewardedReviveState ~= "pending" then
        return false
    end
    world.rewardedReviveSoftTimeout = true
    return true
end

function RewardedRevive.continueWaiting(world)
    if type(world) ~= "table" or world.rewardedReviveState ~= "pending"
        or world.rewardedReviveSoftTimeout ~= true then
        return false
    end
    world.rewardedReviveSoftTimeout = false
    return true
end

-- “确认返回”已经是玩家对软超时的确认，不再叠加第二个失败确认弹窗。
-- 调用方必须先让 PlatformFeatures 使本地请求 token 失效，再调用本函数。
function RewardedRevive.cancelPending(world, reason)
    if type(world) ~= "table" or world.rewardedReviveState ~= "pending" then
        return false, "not_pending"
    end
    world.rewardedReviveState = "offered"
    world.rewardedReviveReason = reason or "ad_wait_cancelled"
    world.reviveOffer = true
    world.reviveOfferPending = true
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    return true, world.rewardedReviveReason
end

function RewardedRevive.resetRun(world)
    if type(world) ~= "table" then return end
    world.rewardedReviveState = "idle"
    world.rewardedReviveReason = nil
    world.rewardedReviveAttempted = false
    world.rewardedReviveUsed = false
    world.rewardedReviveCount = 0
    world.rewardedReviveMode = nil
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    world.reviveOffer = false
    world.reviveOfferPending = false
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.assistedRun = false
end

function RewardedRevive.eligible(world, best, platformReady, platformReason, now)
    if type(world) ~= "table" or world.phase ~= "dead" then return false, "not_dead" end
    if RewardedRevive.CONTRACT.productUseApproved ~= true then
        return false, "product_not_approved"
    end
    -- 完成挑战是主动结束本局，不是死亡：不提供复活。
    if world.challengeCompleted == true then return false, "challenge_completed" end
    if platformReady ~= true then return false, platformReason or "feature_unavailable" end
    if RewardedRevive.CONTRACT.firstLayerDisabled == true
        and (world.round or 0) <= 1 then
        return false, "first_layer_grace"
    end
    local graceSeconds = math.max(0,
        tonumber(RewardedRevive.CONTRACT.firstSecondsDisabled) or 0)
    if graceSeconds > 0 and (world.timeAlive or 0) < graceSeconds then
        return false, "opening_grace"
    end
    if world.endless == true
        and reviveCount(world) >= RewardedRevive.CONTRACT.endlessPerRunLimit then
        return false, "endless_run_cap"
    end
    -- 普通模式明确为无限广告复活；best 中的日计数只作历史统计，不作资格门。
    return true, "eligible"
end

function RewardedRevive.onDeath(world, best, platformReady, platformReason, now)
    local ok, reason = RewardedRevive.eligible(world, best, platformReady, platformReason, now)
    if not ok then
        world.rewardedReviveState = "settlement"
        world.rewardedReviveReason = reason
        world.rewardedReviveSoftTimeout = false
        world.reviveOffer = false
        world.reviveOfferPending = false
        world.reviveChoiceState = nil
        return false, reason
    end
    world.rewardedReviveState = "offered"
    world.rewardedReviveReason = nil
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    world.reviveOffer = true
    world.reviveOfferPending = true
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    return true, "offered"
end

function RewardedRevive.openChoice(world)
    if type(world) ~= "table" or world.rewardedReviveState ~= "offered"
        or world.reviveOffer ~= true then
        return false, "not_offered"
    end
    world.reviveChoiceState = "select"
    world.reviveChoiceMode = nil
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    return true, "choice_open"
end

function RewardedRevive.selectChoice(world, mode)
    if type(world) ~= "table" or world.reviveChoiceState ~= "select" then
        return false, "choice_not_open"
    end
    if mode ~= "in_place" and mode ~= "full_state" then
        return false, "invalid_choice"
    end
    if mode == "full_state" and world.endless == true then
        return false, "endless_full_state_unavailable"
    end
    world.reviveChoiceMode = mode
    world.reviveChoiceState = mode == "in_place"
        and "confirm_in_place" or "confirm_full_state"
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    return true, world.reviveChoiceState
end

function RewardedRevive.cancelChoice(world)
    if type(world) ~= "table" then return false end
    if world.rewardedReviveState ~= "offered" then return false end
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    return true
end

function RewardedRevive.begin(world, mode)
    if type(world) ~= "table" or world.rewardedReviveState ~= "offered"
        or world.reviveOffer ~= true then
        return false, "not_offered"
    end
    mode = mode or world.reviveChoiceMode or "in_place"
    if mode ~= "in_place" and mode ~= "full_state" then return false, "invalid_choice" end
    if mode == "full_state" and world.endless == true then
        return false, "endless_full_state_unavailable"
    end
    world.rewardedReviveAttempted = true
    world.rewardedReviveState = "pending"
    world.rewardedReviveMode = mode
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.reviveOffer = false
    world.reviveOfferPending = true
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    return true, "pending"
end

function RewardedRevive.skip(world, reason)
    if type(world) ~= "table" then return false end
    if world.rewardedReviveState == "revived" then return false end
    world.rewardedReviveState = "settlement"
    world.rewardedReviveReason = reason or "skipped"
    world.reviveOffer = false
    world.reviveOfferPending = false
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.rewardedReviveSoftTimeout = false
    return true
end

function RewardedRevive.resolve(world, best, success, reason, now, mode)
    if type(world) ~= "table" or world.rewardedReviveState ~= "pending" then
        return false, "not_pending"
    end
    mode = mode or world.rewardedReviveMode or "in_place"
    if success ~= true then
        -- 广告失败/取消/无回调超时不得吞掉死亡页；允许玩家再次选择。
        world.rewardedReviveState = "offered"
        world.rewardedReviveReason = reason or "ad_failed"
        world.reviveOffer = true
        world.reviveOfferPending = true
        world.reviveChoiceState = nil
        world.reviveChoiceMode = nil
        world.rewardedReviveTimeout = tostring(world.rewardedReviveReason) == "ad_timeout"
        world.rewardedReviveSoftTimeout = false
        world.rewardedReviveFailureNotice = RewardedRevive.failurePresentation(
            world.rewardedReviveReason)
        return false, world.rewardedReviveReason
    end

    if mode == "full_state" then
        -- 主流程随后通过 layer checkpoint 重建本层初始潜行态。
        world.rewardedReviveCount = reviveCount(world) + 1
    else
        -- Call explicitly with the world receiver.  The QA harness and the
        -- runtime both expose this as a method, but the harness may bind a
        -- plain Lua/Python function differently from a colon call.  Require
        -- a successful boolean result either way; never grant on an error or
        -- a truthy non-boolean value.
        local revivedOK = false
        if world.reviveAssisted ~= nil then
            local ok, result = pcall(function()
                return world:reviveAssisted()
            end)
            revivedOK = ok and result == true
        end
        if not revivedOK then
            world.rewardedReviveState = "offered"
            world.rewardedReviveReason = "revive_failed"
            world.reviveOffer = true
            world.reviveOfferPending = true
            world.rewardedReviveTimeout = false
            world.rewardedReviveSoftTimeout = false
            world.rewardedReviveFailureNotice = RewardedRevive.failurePresentation("revive_failed")
            return false, "revive_failed"
        end
        world.rewardedReviveCount = reviveCount(world) + 1
    end

    recordDailyReward(best, now)
    world.rewardedReviveUsed = true
    world.assistedRun = true
    world.rewardedReviveState = "revived"
    world.rewardedReviveReason = "reward_granted"
    world.rewardedReviveMode = mode
    world.reviveOffer = false
    world.reviveOfferPending = false
    world.reviveChoiceState = nil
    world.reviveChoiceMode = nil
    world.rewardedReviveTimeout = false
    world.rewardedReviveSoftTimeout = false
    world.rewardedReviveFailureNotice = nil
    if mode == "full_state" then return true, "full_state" end
    return true, "in_place"
end

function RewardedRevive.dailyCount(best, now)
    return dailyCountValue(best, now)
end

function RewardedRevive.dayKey(now) return dayKey(now) end

return RewardedRevive
