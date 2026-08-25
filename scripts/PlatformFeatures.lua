-- PlatformFeatures.lua
-- 平台能力降级壳：统一正式榜保留合法来源元数据；研发、主动放弃和异常局除外。

local Config = require "Config"
local SaveSys = require "SaveSys"

local PlatformFeatures = {}
PlatformFeatures.REWARDED_REVIVE_COMPATIBILITY_NOTICE =
    "Rewarded revive is runtime-gated; only success callbacks grant the chosen revive."
PlatformFeatures.REWARDED_REVIVE_PRODUCT_USE_APPROVED = true
local LAYER_CAP = 99999
local SCORE_CAP = 999999999
local RANK_BASE = 1000000000
local MAX_RANK_SCORE = LAYER_CAP * RANK_BASE + SCORE_CAP
local JS_SAFE_INTEGER = 9007199254740991
local LEADERBOARD_MIN_LAYER = 10

local leaderboardAdapter = nil
local privacyConsent = false
local submitted = {}
local submitting = {}
local leaderboardGeneration = 0
-- 激励视频请求的运行期防护：UrhoX 只公开统一 callback，且不保证
-- exactly-once/必回调。token + completed 令迟到、重复和跨页面回调失效。
local rewardedRequestSerial = 0
local rewardedRequest = nil
local identity = {
    ready = false,
    userId = nil,
    userIdText = nil,
    nickname = nil,
    nicknameRequested = false,
    nicknameRetryAt = 0,
    nicknameSource = "none",
    nicknameSyncing = false,
    nicknameSyncedValue = nil,
    identitySource = "local_mode",
    nicknameDiagnostic = "not_requested",
    nicknameRequestGeneration = 0,
}

local function setNicknameDiagnostic(value)
    value = tostring(value or "unknown")
    if identity.nicknameDiagnostic ~= value then
        identity.nicknameDiagnostic = value
        -- 不输出完整 UID 或昵称，只记录能力链状态，供真机日志诊断。
        print("[PLATFORM] nickname=" .. value)
    end
end

local function sanitizeNickname(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("%z", ""):gsub("[\1-\31\127]", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    local ok, cut = pcall(utf8.offset, value, 25)
    if not ok then return nil end
    if cut then value = value:sub(1, cut - 1) end
    return value ~= "" and value or nil
end

-- 账号 UID 用字符串作为唯一身份键。不要把它转换为 number：宿主可能把
-- 同一 Int64 值在不同回调中表示成 `123`、`"123"` 或 `"123.0"`。
local function canonicalUserId(value)
    if value == nil then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text:match("^%d+%.0+$") then text = text:gsub("%.0+$", "") end
    return text ~= "" and text or nil
end

local function sameUserId(left, right)
    local leftKey, rightKey = canonicalUserId(left), canonicalUserId(right)
    return leftKey ~= nil and leftKey == rightKey
end

local function decodeNicknameJson(value)
    if type(value) ~= "string" or not value:match("^%s*[%[{]") then return nil end
    local codec = rawget(_G, "cjson")
    if type(codec) ~= "table" or type(codec.decode) ~= "function" then
        -- UrhoX exposes cjson as a global.  Some host bridges do not mirror
        -- that global into _G, so read it through the Lua environment too.
        local ok, exposed = pcall(function()
            return cjson
        end)
        if ok then codec = exposed end
    end
    if type(codec) ~= "table" or type(codec.decode) ~= "function" then return nil end
    local ok, decoded = pcall(codec.decode, value)
    return ok and decoded or nil
end

-- 官方返回为 { {userId=..., nickname=...}, ... }。部分宿主兼容层曾返回
-- data/list/users/nicknames 包装或 UID->昵称映射；这里仅做结构兼容，不把
-- 昵称当作排行榜自身字段，也不会据 msg 等非权威字段猜测昵称。
local function parseNicknameResult(result, requestedIds)
    local names = {}
    local anonymous = {}
    local visited = {}
    local requestedKeys = {}
    for _, userId in ipairs(requestedIds) do
        local key = canonicalUserId(userId)
        if key then requestedKeys[key] = true end
    end
    local idKeys = { "userId", "user_id", "uid", "player", "id" }
    local nameKeys = { "nickname", "nickName", "name", "userName" }
    local function visit(value, keyHint, depth)
        if depth > 4 then return end
        if type(value) == "string" then
            local decoded = decodeNicknameJson(value)
            if decoded ~= nil then
                visit(decoded, keyHint, depth + 1)
                return
            end
            local nickname = sanitizeNickname(value)
            if nickname then
                local key = canonicalUserId(keyHint)
                if key then
                    names[key] = nickname
                else
                    anonymous[#anonymous + 1] = nickname
                end
            end
            return
        end
        if type(value) ~= "table" or visited[value] then return end
        visited[value] = true
        local userId, nickname = nil, nil
        for _, key in ipairs(idKeys) do
            if value[key] ~= nil then userId = value[key] break end
        end
        for _, key in ipairs(nameKeys) do
            nickname = sanitizeNickname(value[key])
            if nickname then break end
        end
        if nickname then
            if userId ~= nil then
                local key = canonicalUserId(userId)
                if key then names[key] = nickname else anonymous[#anonymous + 1] = nickname end
            else
                anonymous[#anonymous + 1] = nickname
            end
        end
        local wrappers = {
            data = true, list = true, users = true, nicknames = true,
            result = true, response = true, payload = true, body = true, value = true,
        }
        for key, child in pairs(value) do
            if type(key) == "number" then
                visit(child, nil, depth + 1)
            elseif wrappers[key] then
                visit(child, nil, depth + 1)
            elseif type(key) == "string" then
                local normalizedKey = canonicalUserId(key)
                if key:match("^%d+$") or (normalizedKey and requestedKeys[normalizedKey]) then
                    visit(child, normalizedKey, depth + 1)
                end
            end
        end
    end
    visit(result, nil, 0)
    if #requestedIds == 1 then
        local key = canonicalUserId(requestedIds[1])
        if not names[key] and #anonymous == 1 then names[key] = anonymous[1] end
    end
    return names
end

-- 少数旧宿主没有注入官方全局 GetUserNickname，但仍暴露同一平台的
-- lobby:GetUserNickname + UserNicknameResponse 兼容桥。它只在官方入口根本
-- 不存在时兜底；一旦官方请求已受理，空结果、失败或超时都不能由旧桥覆盖。
local directNicknameRequests = {}
local directNicknameEarlyResponses = {}
local directNicknameBridgeInstalled = false
local directNicknameCallInFlight = 0

local function eventVariantValue(eventData, key, getterName)
    local okVariant, variant = pcall(function() return eventData[key] end)
    if not okVariant or variant == nil then return nil end
    if type(variant) ~= "userdata" and type(variant) ~= "table" then return variant end
    local okGetter, getter = pcall(function() return variant[getterName] end)
    if not okGetter or type(getter) ~= "function" then return nil end
    local okValue, value = pcall(function() return getter(variant) end)
    return okValue and value or nil
end

local function cleanupDirectNicknameRequests()
    local now = os.time()
    for requestId, pending in pairs(directNicknameRequests) do
        if now - (pending.createdAt or now) > 30 then
            directNicknameRequests[requestId] = nil
            if type(pending.error) == "function" then pending.error("timeout") end
        end
    end
    for requestId, response in pairs(directNicknameEarlyResponses) do
        if now - (response.createdAt or now) > 30 then
            directNicknameEarlyResponses[requestId] = nil
        end
    end
end

local function finishDirectNicknameRequest(requestId, response)
    local pending = requestId and directNicknameRequests[requestId] or nil
    if not pending then return false end
    directNicknameRequests[requestId] = nil
    if response.success then
        local names = parseNicknameResult(response.payload, pending.userIds)
        if type(pending.ok) == "function" then pending.ok(names) end
    elseif type(pending.error) == "function" then
        pending.error(response.errorCode or "error")
    end
    return true
end

local function ensureDirectNicknameBridge()
    if directNicknameBridgeInstalled then return true end
    local subscribe = rawget(_G, "SubscribeToEvent")
    if type(subscribe) ~= "function" then return false end
    local ok = pcall(function()
        subscribe("UserNicknameResponse", function(_, eventData)
            local requestId = tonumber(eventVariantValue(eventData, "RequestId", "GetInt"))
            local success = eventVariantValue(eventData, "Success", "GetBool") == true
            local response = {
                createdAt = os.time(),
                success = success,
                payload = eventVariantValue(eventData, "Nicknames", "GetString"),
                errorCode = eventVariantValue(eventData, "ErrorCode", "GetInt") or "error",
            }
            if finishDirectNicknameRequest(requestId, response) then return end
            -- 兼容宿主在 lobby:GetUserNickname 返回 requestId 前同步派发事件的极端
            -- 情况；只在本模块正发起直连请求的调用栈内暂存，绝不截获别的查询。
            if requestId and directNicknameCallInFlight > 0 then
                directNicknameEarlyResponses[requestId] = response
            end
        end)
    end)
    if ok then directNicknameBridgeInstalled = true end
    return ok
end

local function requestDirectNicknames(userIds, events)
    cleanupDirectNicknameRequests()
    if type(userIds) ~= "table" or #userIds == 0 or not ensureDirectNicknameBridge() then
        return false
    end
    local lobby = rawget(_G, "lobby")
    local okMethod, method = pcall(function() return lobby and lobby.GetUserNickname end)
    if not okMethod or type(method) ~= "function" then return false end
    local normalizedIds = {}
    for index, userId in ipairs(userIds) do
        normalizedIds[index] = canonicalUserId(userId) or userId
    end
    directNicknameCallInFlight = directNicknameCallInFlight + 1
    local okRequest, requestId = pcall(function() return lobby:GetUserNickname(normalizedIds) end)
    directNicknameCallInFlight = math.max(0, directNicknameCallInFlight - 1)
    requestId = tonumber(requestId)
    if not okRequest or requestId == nil or requestId < 0 then return false end
    directNicknameRequests[requestId] = {
        createdAt = os.time(),
        userIds = userIds,
        ok = events and events.ok,
        error = events and events.error,
    }
    local early = directNicknameEarlyResponses[requestId]
    if early then
        directNicknameEarlyResponses[requestId] = nil
        finishDirectNicknameRequest(requestId, early)
    end
    return true
end

local function currentSdkNickname()
    local sdk = rawget(_G, "sdk")
    if sdk == nil then return nil end
    local okMethod, method = pcall(function() return sdk.GetUserName end)
    if not okMethod or method == nil then return nil end
    local ok, value = pcall(function() return sdk:GetUserName() end)
    if not ok then return nil end
    return sanitizeNickname(value)
end

local function syncCurrentNickname()
    local nickname = sanitizeNickname(identity.nickname)
    if not privacyConsent or not nickname or identity.nicknameSyncing
        or identity.nicknameSyncedValue == nickname then return end
    local adapter = leaderboardAdapter
    if type(adapter) ~= "table" or type(adapter.syncNickname) ~= "function" then return end
    identity.nicknameSyncing = true
    local settled = false
    local function finish(success)
        if settled then return end
        settled = true
        identity.nicknameSyncing = false
        if success then identity.nicknameSyncedValue = nickname end
    end
    local ok, invoked = pcall(function()
        return adapter:syncNickname(nickname, {
            ok = function() finish(true) end,
            error = function() finish(false) end,
            timeout = function() finish(false) end,
        })
    end)
    if not ok or invoked == false then finish(false) end
end

local function acceptNickname(value, source)
    local nickname = sanitizeNickname(value)
    if not nickname then return false end
    identity.nickname = nickname
    identity.nicknameSource = source or "unknown"
    identity.nicknameRequested = false
    identity.nicknameRetryAt = 0
    setNicknameDiagnostic("resolved:" .. identity.nicknameSource)
    syncCurrentNickname()
    return true
end

local COMPLETION_REASONS = {
    death = true,
    endless_end = true,
    layer_complete = true,
    challenge_complete = true,
}

local function leaderboardKey()
    if Config.PLATFORM.leaderboardBackend ~= "clientCloud" then return nil end
    local key = Config.PLATFORM.leaderboardKey
    if type(key) ~= "string" or key == "" then return nil end
    return key
end

local function isInteger(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function runId(run)
    return type(run) == "table" and (run.runId or run.id) or nil
end

function PlatformFeatures.isEligibleRun(run)
    local id = runId(run)
    local invalidRecovery = run and (run.recovered == true or run.recoveredRun == true)
        and run.checkpointRecovery ~= true
    return type(run) == "table" and run.completed == true and id ~= nil
        and run.formalMain == true
        -- The product now has one unified board.  Ad-assisted runs and
        -- ordinary checkpoint resumes are valid; only retry/recovery/debug
        -- paths remain excluded.
        and invalidRecovery ~= true and run.challengeRetry ~= true
        and math.max(0, math.floor(tonumber(run.challengeRetryCount) or 0)) == 0
        and run.interrupted ~= true and run.manualAbandon ~= true
        and run.review ~= true and run.debug ~= true and run.bot ~= true and run.test ~= true
        and COMPLETION_REASONS[run.completionReason] == true
        and ((run.endless == true and (run.completionReason == "death"
                or run.completionReason == "endless_end"
                or (run.completionReason == "layer_complete"
                    and run.layer >= LEADERBOARD_MIN_LAYER)))
            or (run.endless ~= true and run.challengeCompleted == true
                and run.completionReason == "challenge_complete"))
        and isInteger(run.layer) and run.layer >= 1 and run.layer <= LAYER_CAP
        and isInteger(run.score) and run.score >= 0 and run.score <= SCORE_CAP
end

local function configuredStatus()
    if not privacyConsent then return false, "privacy_not_accepted" end
    if Config.PLATFORM.leaderboard ~= true then return false, "feature_disabled" end
    if not PlatformFeatures.identityStatus() then return false, "platform_identity_unavailable" end
    if Config.PLATFORM.leaderboardBackend ~= "clientCloud" then
        return false, "unsupported_leaderboard_backend"
    end
    if leaderboardKey() == nil then return false, "missing_leaderboard_key" end
    return true, "configured"
end

function PlatformFeatures.leaderboardStatus(adapterOverride)
    local configured, reason = configuredStatus()
    if not configured then return false, reason end
    local adapter = adapterOverride or leaderboardAdapter
    if type(adapter) ~= "table" or type(adapter.submitScore) ~= "function"
        or type(adapter.loadScores) ~= "function" then
        return false, "official_leaderboard_manager_unavailable"
    end
    return true, "ready"
end

function PlatformFeatures.setPrivacyConsent(value)
    privacyConsent = value == true
    if privacyConsent then
        PlatformFeatures.requestNickname()
        syncCurrentNickname()
    else
        -- 使授权撤回前发出的异步昵称回调失效；保留已解析快照，避免再次
        -- 授权时无意义地闪回匿名名。
        identity.nicknameRequestGeneration = (identity.nicknameRequestGeneration or 0) + 1
        identity.nicknameRequested = false
    end
end

function PlatformFeatures.setLeaderboardAdapter(adapter)
    leaderboardAdapter = adapter
    syncCurrentNickname()
end

-- ============================================================
-- 024C：平台身份（昵称/脱敏UID）与广告就绪状态
-- ============================================================
function PlatformFeatures.setIdentity(adapterResult)
    local nextReady = type(adapterResult) == "table" and adapterResult.identityReady == true
    local nextUserId = nextReady and canonicalUserId(adapterResult.userId) or nil
    local nextUserIdText = nextReady and canonicalUserId(adapterResult.userIdText
        or adapterResult.userId) or nil
    nextReady = nextReady and nextUserId ~= nil and nextUserIdText ~= nil
    local sameIdentity = nextReady and identity.ready
        and identity.userIdText ~= nil and identity.userIdText == nextUserIdText
    identity.ready = nextReady
    identity.userId = nextUserId
    identity.userIdText = nextUserIdText
    -- HandleUpdate 会在宿主晚注入时重复探测；同一账号不能因此反复清空
    -- 已返回的昵称或制造一连串重复查询。
    if not sameIdentity then
        identity.nicknameRequestGeneration = (identity.nicknameRequestGeneration or 0) + 1
        identity.nickname = nil
        identity.nicknameRequested = false
        identity.nicknameRetryAt = 0
        identity.nicknameSource = "none"
        identity.nicknameSyncing = false
        identity.nicknameSyncedValue = nil
        setNicknameDiagnostic("not_requested")
    end
    identity.identitySource = identity.ready
        and "taptap_account" or "local_mode"
    if identity.ready then PlatformFeatures.requestNickname() end
end

function PlatformFeatures.identityStatus()
    return identity.ready == true
end

function PlatformFeatures.identityPanel()
    if identity.ready and identity.nickname == nil then
        PlatformFeatures.requestNickname()
    end
    local masked = identity.ready and (identity.userIdText or tostring(identity.userId or "")) or nil
    if masked then
        masked = string.sub(masked, -6)
    end
    local accountStatus = not privacyConsent and "等待授权"
        or (identity.ready and "已登录" or "暂未连接")
    local accountLabel = accountStatus
    if identity.ready then
        accountLabel = identity.nickname or "TapTap 玩家"
        if masked then accountLabel = accountLabel .. " · 账号尾号" .. masked end
    end

    local cloud = SaveSys.cloudDiagnostics()
    local cloudStatus
    if not privacyConsent then
        cloudStatus = "等待授权"
    elseif Config.PLATFORM.cloudSave ~= true then
        cloudStatus = "功能关闭"
    elseif not identity.ready then
        cloudStatus = "等待账号"
    elseif type(cloud.adapterKind) ~= "string" or cloud.adapterKind == "" then
        cloudStatus = "暂不可用"
    elseif cloud.readPending or cloud.busy then
        cloudStatus = "同步中"
    elseif cloud.readFailed then
        cloudStatus = "等待重试"
    else
        cloudStatus = "已连接"
    end

    local leaderboardReady, leaderboardReason = PlatformFeatures.leaderboardStatus()
    local leaderboardLabel = "未就绪"
    if leaderboardReady then
        leaderboardLabel = "已开启"
    elseif leaderboardReason == "privacy_not_accepted" then
        leaderboardLabel = "等待授权"
    elseif leaderboardReason == "feature_disabled" then
        leaderboardLabel = "功能关闭"
    elseif leaderboardReason == "platform_identity_unavailable" then
        leaderboardLabel = "等待账号"
    elseif leaderboardReason == "unsupported_leaderboard_backend"
        or leaderboardReason == "missing_leaderboard_key" then
        leaderboardLabel = "暂不可用"
    elseif leaderboardReason == "official_leaderboard_manager_unavailable" then
        leaderboardLabel = "暂不可用"
    end
    return {
        nickname = identity.ready and (identity.nickname or "TapTap 玩家") or nil,
        uidMasked = masked,
        loginStatus = accountStatus,
        accountLabel = accountLabel,
        localSaveStatus = "本地档案",
        cloudSaveStatus = cloudStatus,
        leaderboardStatus = leaderboardReady,
        leaderboardStatusLabel = leaderboardLabel,
        leaderboardReason = leaderboardReason,
        privacyAccepted = privacyConsent,
        identitySource = identity.identitySource,
        nicknameDiagnostic = identity.nicknameDiagnostic,
        nicknameSource = identity.nicknameSource,
    }
end

-- 昵称查询（官方 GetUserNickname；失败静默降级为"—"）
function PlatformFeatures.requestNickname()
    local fn = rawget(_G, "GetUserNickname")
    local now = os.time()
    if not privacyConsent then
        setNicknameDiagnostic("waiting_consent")
        return
    end
    if identity.nickname and identity.nickname ~= "" then
        syncCurrentNickname()
        return
    end
    if not identity.ready or not identity.userId then
        setNicknameDiagnostic("identity_unavailable")
        return
    end
    if identity.nicknameRequested or now < (identity.nicknameRetryAt or 0) then return end
    identity.nicknameRequested = true
    identity.nicknameRetryAt = now + 10
    setNicknameDiagnostic("requesting")
    local requestedUserId = identity.userId
    local requestedIdText = canonicalUserId(identity.userIdText or identity.userId)
    identity.nicknameRequestGeneration = (identity.nicknameRequestGeneration or 0) + 1
    local requestGeneration = identity.nicknameRequestGeneration
    local directFallbackStarted = false
    local function stillCurrentAccount()
        return privacyConsent and identity.nicknameRequestGeneration == requestGeneration
            and sameUserId(identity.userId, requestedUserId)
            and canonicalUserId(identity.userIdText or identity.userId) == requestedIdText
    end
    local function settleWithoutOfficialNickname(reason)
        if not stillCurrentAccount() then return end
        if acceptNickname(currentSdkNickname(), "sdk_mobile") then return end
        identity.nicknameRequested = false
        -- 平台对象可能在启动后晚于身份注入。若接口尚不可用，不把它当成
        -- 真实空结果进入十秒冷却，后续首次可用查询必须立即有机会成功。
        identity.nicknameRetryAt = reason == "api_unavailable" and 0 or os.time() + 10
        setNicknameDiagnostic(reason)
    end
    local function resolveFromDirectBridge(reason)
        if directFallbackStarted then return end
        directFallbackStarted = true
        local started = requestDirectNicknames({ requestedUserId }, {
            ok = function(names)
                if not stillCurrentAccount() then return end
                local matched = names[requestedIdText]
                if not acceptNickname(matched, "lobby_direct") then
                    settleWithoutOfficialNickname(reason)
                end
            end,
            error = function()
                settleWithoutOfficialNickname(reason)
            end,
        })
        if not started then settleWithoutOfficialNickname(reason) end
    end
    if type(fn) ~= "function" then
        resolveFromDirectBridge("api_unavailable")
        return
    end
    local ok, invoked = pcall(function()
        return fn({
            userIds = { requestedUserId },
            onSuccess = function(nicknames)
                if not stillCurrentAccount() then return end
                local names = parseNicknameResult(nicknames, { requestedUserId })
                local matched = names[requestedIdText]
                if not acceptNickname(matched, "official_batch") then
                    -- 官方主链返回空或不完整数据时，不让非标准事件桥覆盖
                    -- 已有身份快照；保留错误状态，按节流稍后重试。
                    settleWithoutOfficialNickname("empty_result")
                end
            end,
            onError = function(errorCode)
                settleWithoutOfficialNickname("error:" .. tostring(errorCode or "unknown"))
            end,
        })
    end)
    if not ok or invoked == false then
        settleWithoutOfficialNickname(not ok and "invoke_error" or "invoke_rejected")
    end
end

function PlatformFeatures.rewardedAdStatus()
    if PlatformFeatures.REWARDED_REVIVE_PRODUCT_USE_APPROVED ~= true then
        return false, "product_not_approved"
    end
    if not privacyConsent then return false, "privacy_not_accepted" end
    if Config.PLATFORM.rewardedAd ~= true then return false, "feature_disabled" end
    -- The host binding may expose sdk as a Lua table or userdata.  Do not
    -- reject a real device solely because its binding type differs; verify
    -- the method is readable and let the protected invocation below decide
    -- whether it is callable.
    local sdk = rawget(_G, "sdk")
    local sdkType = type(sdk)
    if sdk == nil or (sdkType ~= "table" and sdkType ~= "userdata") then
        return false, "sdk_unavailable"
    end
    local methodOK, method = pcall(function() return sdk.ShowRewardVideoAd end)
    if not methodOK or method == nil then return false, "sdk_unavailable" end
    -- 广告后台开通状态以 get_ad_config 同步进 .project/settings.json 的 @runtime.ad.status 为准。
    -- 运行期无法读本地工程文件，此处由正式功能开关承载（Config.PLATFORM.rewardedAd）。
    return true, "ready"
end

-- 软超时只打开本地“继续等待 / 确认返回”选择，不能结束请求；硬超时才按
-- 失败结算。配置意外倒置时保持 hard > soft，避免请求永远没有最终收口。
function PlatformFeatures.rewardedAdTimeouts()
    local cfg = Config.PLATFORM and Config.PLATFORM.rewardedRevive or {}
    local soft = math.max(1, math.floor(tonumber(cfg.softTimeoutSeconds) or 15))
    local hard = math.max(1, math.floor(tonumber(cfg.hardTimeoutSeconds) or 180))
    if hard <= soft then hard = soft + 1 end
    return soft, hard
end

-- 请求播放奖励视频。只有完整播放且 success==true 才走回调 success；
-- 取消/失败/无填充/超时均 success=false。watchdog 是客户端 UI 兜底，
-- 不是 SDK 合同；超时后迟到回调会被 token 丢弃，绝不发奖。
function PlatformFeatures.requestRewardedRevive(callback)
    local ready, reason = PlatformFeatures.rewardedAdStatus()
    if not ready then
        print("[ADS] rewarded revive blocked reason=" .. tostring(reason))
        return false, reason
    end
    if rewardedRequest ~= nil then
        print("[ADS] rewarded revive blocked reason=request_in_progress")
        return false, "request_in_progress"
    end
    local sdk = rawget(_G, "sdk")
    rewardedRequestSerial = rewardedRequestSerial + 1
    local token = rewardedRequestSerial
    local completed = false
    local completedResult = nil
    local startedAt = os.time()
    local function settle(result)
        if completed or rewardedRequest == nil or rewardedRequest.token ~= token then
            return false
        end
        completed = true
        local raw = type(result) == "table" and result or {}
        completedResult = {
            success = raw.success == true,
            msg = tostring(raw.msg or (raw.success == true and "ad_success" or "ad_failed")),
            extra = tostring(raw.extra or ""),
            requestToken = token,
        }
        print(string.format("[ADS] rewarded revive callback token=%d success=%s msg=%s",
            token, tostring(completedResult.success), tostring(completedResult.msg)))
        rewardedRequest = nil
        if type(callback) == "function" then callback(completedResult) end
        return true
    end
    local function cancel()
        if completed or rewardedRequest == nil or rewardedRequest.token ~= token then
            return false
        end
        -- SDK 没有公开取消 API。这里只废弃本地请求，后续回调会因 completed/
        -- token 闸门返回 false，绝不能恢复 UI 或发奖。
        completed = true
        rewardedRequest = nil
        return true
    end
    rewardedRequest = {
        token = token, startedAt = startedAt, settle = settle, cancel = cancel,
        softTimeoutNotified = false,
    }
    -- 设备日志中的这一条是 SDK 调用边界：有它而没有 accepted/callback，
    -- 才能明确归因到宿主调用本身或其同步异常，而不是玩家失败提示层。
    print(string.format("[ADS] rewarded revive request start token=%d", token))
    local ok, accepted = pcall(function()
        return sdk:ShowRewardVideoAd(function(result) settle(result) end)
    end)
    if not ok then
        print("[ADS] rewarded revive invoke failed: " .. tostring(accepted))
        settle({ success = false, msg = "sdk_call_failed" })
        return false, "sdk_call_failed"
    end
    -- SDK 可能同步回调；如果已结算，不能再因 boolean 返回值重复回调。
    if accepted == false and not completed then
        print(string.format("[ADS] rewarded revive rejected token=%d", token))
        settle({ success = false, msg = "sdk_rejected" })
        return false, "sdk_rejected"
    end
    if completed then return true, "completed", token end
    print(string.format("[ADS] rewarded revive accepted token=%d", token))
    return true, "playing", token
end

-- 每帧由正式入口调用。SDK 没有公开取消 API，因此软超时仅通知 UI；硬超时
-- 和显式本地取消才结束等待。它们都不会被当成观看成功，迟到回调会被丢弃。
function PlatformFeatures.tickRewardedAd(now)
    local active = rewardedRequest
    if active == nil then return false end
    local current = tonumber(now) or os.time()
    local elapsed = math.max(0, current - (active.startedAt or current))
    local softTimeout, hardTimeout = PlatformFeatures.rewardedAdTimeouts()
    if elapsed >= hardTimeout then
        local token = active.token
        print(string.format("[ADS] rewarded revive hard timeout token=%d elapsed=%d", token, elapsed))
        active.settle({ success = false, msg = "ad_timeout" })
        return "hard_timeout", token
    end
    if elapsed >= softTimeout and active.softTimeoutNotified ~= true then
        active.softTimeoutNotified = true
        print(string.format("[ADS] rewarded revive soft timeout token=%d elapsed=%d", active.token, elapsed))
        return "soft_timeout", active.token
    end
    return false
end

-- 仅结束本地等待；不调用 callback，不把取消伪装为广告失败结果。由调用方按
-- 当前页面/战局上下文恢复 UI，SDK 迟到回调则被此 token 失效门拒绝。
function PlatformFeatures.cancelRewardedRevive()
    local active = rewardedRequest
    if active == nil or type(active.cancel) ~= "function" then
        return false, "no_active_request"
    end
    local token = active.token
    if not active.cancel() then return false, "request_already_settled" end
    print(string.format("[ADS] rewarded revive local wait cancelled token=%d", token))
    return true, token
end

function PlatformFeatures.rankValue(layer, score)
    local safeLayer = math.max(0, math.min(LAYER_CAP, math.floor(tonumber(layer) or 0)))
    local safeScore = math.max(0, math.min(SCORE_CAP, math.floor(tonumber(score) or 0)))
    return safeLayer * RANK_BASE + safeScore
end

function PlatformFeatures.decodeRankValue(rankScore)
    if not isInteger(rankScore) or rankScore < 0 or rankScore > MAX_RANK_SCORE then
        return nil, nil, "invalid_rank_score"
    end
    local layer = math.floor(rankScore / RANK_BASE)
    local score = rankScore - layer * RANK_BASE
    if layer > LAYER_CAP or score > SCORE_CAP then return nil, nil, "out_of_range" end
    return layer, score, nil
end

local function pendingFromRun(run)
    -- Unified board: L10+ formal results are valid, including ad-assisted
    -- and ordinary checkpoint-continuation runs.  Diagnostic flags are kept
    -- for display/analytics but are not used to silently drop a valid score.
    if not isInteger(run.layer) or run.layer < LEADERBOARD_MIN_LAYER then return nil end
    return {
        runId = tostring(run.milestoneId or run.milestone_id or runId(run)),
        originalRunId = tostring(run.originalRunId or run.original_run_id or runId(run)),
        rankScore = PlatformFeatures.rankValue(run.layer, run.score),
        layer = run.layer,
        score = run.score,
        bestCombo = math.max(0, math.floor(run.bestCombo or 0)),
        endedAt = math.max(0, math.floor(run.endedAt or 0)),
        completionReason = run.completionReason,
        cleanRun = run.cleanRun == true,
        assistedRun = run.assistedRun == true,
        adAssisted = run.adAssisted == true or run.rewardedRevive == true
            or run.rewardedReviveUsed == true,
        checkpointRecovery = run.checkpointRecovery == true,
    }
end

local function submitPending(best, pending, adapter)
    local id = tostring(pending.runId)
    if submitted[id] then return false, "duplicate_run" end
    if submitting[id] then return false, "submission_in_progress" end
    submitting[id] = true
    local finished = false
    local finishedKind = nil
    local function finishOnce(kind)
        if finished then return false end
        finished = true
        finishedKind = kind
        submitting[id] = nil
        if kind == "ok" then
            submitted[id] = true
            SaveSys.clearPendingLeaderboardSubmission(best, id)
            SaveSys.save(best)
        else
            SaveSys.saveLocalOnly(best)
        end
        return true
    end
    local ok, invoked, invokeReason = pcall(function()
        return adapter:submitScore(leaderboardKey(), pending.rankScore, {
            runId = id,
            originalRunId = pending.originalRunId,
            layer = pending.layer,
            score = pending.score,
            bestCombo = pending.bestCombo,
            cleanRun = pending.cleanRun == true,
            assistedRun = pending.assistedRun == true,
            adAssisted = pending.adAssisted == true,
            checkpointRecovery = pending.checkpointRecovery == true,
            gameVersion = Config.GAME_VERSION,
            -- 只传递官方昵称查询成功后的快照；实时查询仍是榜单展示权威。
            nicknameSnapshot = identity.nickname,
        }, {
            ok = function() finishOnce("ok") end,
            error = function() finishOnce("error") end,
            timeout = function() finishOnce("timeout") end,
        })
    end)
    if not ok then
        submitting[id] = nil
        return false, tostring(invokeReason or invoked)
    end
    -- Some host bindings invoke the callback synchronously and still return
    -- false.  The callback is the authoritative settlement; do not report a
    -- false submission or lose the already-settled result in that case.
    if finished then return true, "completed_" .. tostring(finishedKind) end
    if invoked == false then
        submitting[id] = nil
        return false, tostring(invokeReason or invoked)
    end
    return true, "submitting"
end

function PlatformFeatures.submitRun(run, best, adapterOverride)
    if not PlatformFeatures.isEligibleRun(run) then return false, "ineligible_run" end
    local id = tostring(runId(run))
    if submitted[id] or submitting[id] then return false, "duplicate_run" end
    local pending = pendingFromRun(run)
    if pending == nil then return true, "below_leaderboard_min_layer" end

    -- 结算瞬间可能正处于 clientCloud 读档、UID 或排行榜方法晚注入窗口。
    -- 只要隐私与产品配置已允许，就先把成绩写进本地 pending 槽；不能因为
    -- 平台尚未 ready 而把已经完成的 L10+/无尽里程碑静默丢掉。
    if not privacyConsent then return false, "privacy_not_accepted" end
    if Config.PLATFORM.leaderboard ~= true then return false, "feature_disabled" end
    if Config.PLATFORM.leaderboardBackend ~= "clientCloud" then
        return false, "unsupported_leaderboard_backend"
    end
    if leaderboardKey() == nil then return false, "missing_leaderboard_key" end
    SaveSys.queueLeaderboardSubmission(best, pending)
    SaveSys.save(best)

    local configured, reason = configuredStatus()
    if not configured then return true, "queued_" .. tostring(reason) end
    local adapter = adapterOverride or leaderboardAdapter
    if type(adapter) ~= "table" or type(adapter.submitScore) ~= "function" then
        return true, "queued_offline"
    end
    local current = best.pendingLeaderboardSubmission
    if type(current) ~= "table" then return false, "no_pending_submission" end
    return submitPending(best, current, adapter)
end

function PlatformFeatures.retryPending(best, adapterOverride)
    local configured, reason = configuredStatus()
    if not configured then return false, reason end
    local pending = best and best.pendingLeaderboardSubmission
    if type(pending) ~= "table" then return false, "nothing_pending" end
    local adapter = adapterOverride or leaderboardAdapter
    if type(adapter) ~= "table" or type(adapter.submitScore) ~= "function" then
        return false, "official_leaderboard_manager_unavailable"
    end
    return submitPending(best, pending, adapter)
end

function PlatformFeatures.fetchLeaderboard(count, events, adapterOverride)
    local ready, reason = PlatformFeatures.leaderboardStatus(adapterOverride)
    if not ready then return false, reason end
    PlatformFeatures.requestNickname()
    leaderboardGeneration = leaderboardGeneration + 1
    local generation = leaderboardGeneration
    local delivered = false
    local function current() return generation == leaderboardGeneration end
    local function deliver(kind, ...)
        if delivered or not current() then return end
        delivered = true
        local fn = events and events[kind]
        if type(fn) == "function" then fn(...) end
    end
    local adapter = adapterOverride or leaderboardAdapter
    local key = leaderboardKey()
    local requestedCount = math.max(1, math.min(20, math.floor(tonumber(count) or 20)))
    local myId = identity.ready and identity.userId or nil
    if myId and type(adapter.myRank) == "function" and events and events.myRank then
        local rankDelivered = false
        local function deliverRank(rank, scoreValue)
            if rankDelivered or not current() then return end
            rankDelivered = true
            if events.myRank then events.myRank(rank, scoreValue) end
        end
        local rankOK, rankInvoked = pcall(function()
            return adapter:myRank(myId, key, {
                ok = function(rank, scoreValue) deliverRank(rank, scoreValue) end,
                error = function() deliverRank(nil) end,
                timeout = function() deliverRank(nil) end,
            })
        end)
        if not rankOK or rankInvoked == false then deliverRank(nil) end
    end
    local ok, invoked, invokeReason = pcall(function()
        return adapter:loadScores(key, requestedCount, {
            ok = function(rawEntries)
                local entries = {}
                for index, raw in ipairs(rawEntries or {}) do
                    raw = type(raw) == "table" and raw or {}
                    local rankScore = tonumber(raw.rankScore or raw.score)
                    local layer, score = tonumber(raw.layer), tonumber(raw.gameScore)
                    if not layer or score == nil then
                        layer, score = PlatformFeatures.decodeRankValue(rankScore)
                    end
                    if layer and score then
                        entries[#entries + 1] = {
                            rank = tonumber(raw.rank) or index,
                            name = raw.name,
                            userId = canonicalUserId(raw.userId),
                            layer = layer,
                            score = score,
                            rankScore = rankScore or PlatformFeatures.rankValue(layer, score),
                        }
                    end
                end
                for _, entry in ipairs(entries) do
                    if sameUserId(entry.userId, identity.userId)
                        and identity.nickname then entry.name = identity.nickname end
                end
                local nicknameFn = rawget(_G, "GetUserNickname")
                local userIds = {}
                local uniqueUserIds = {}
                for _, entry in ipairs(entries) do
                    if entry.userId ~= nil then
                        userIds[#userIds + 1] = entry.userId
                        local key = canonicalUserId(entry.userId)
                        if key then uniqueUserIds[key] = true end
                    end
                end
                if #userIds == 0 then
                    deliver("ok", entries)
                    return
                end
                -- The score rows are already valid data.  Nicknames are
                -- enrichment only: a late/empty nickname callback must never
                -- leave the public leaderboard on its loading screen.
                deliver("ok", entries)
                local namesDelivered = false
                local function finishNames()
                    if namesDelivered or not current() then return end
                    namesDelivered = true
                    if type(events) == "table" and type(events.names) == "function" then
                        events.names(entries)
                    end
                end
                local function applyLiveNames(names)
                    local resolved = {}
                    for _, entry in ipairs(entries) do
                        local liveName = names[canonicalUserId(entry.userId)]
                        if liveName and liveName ~= "" then
                            entry.name = liveName
                            resolved[tostring(entry.userId)] = true
                        end
                    end
                    local count = 0
                    for _ in pairs(resolved) do count = count + 1 end
                    return count
                end
                local uniqueCount = 0
                for _ in pairs(uniqueUserIds) do uniqueCount = uniqueCount + 1 end
                local directLookupStarted = false
                local function requestDirectThenDeliver()
                    if directLookupStarted then return end
                    directLookupStarted = true
                    local started = requestDirectNicknames(userIds, {
                        ok = function(names)
                            applyLiveNames(names)
                            finishNames()
                        end,
                        error = finishNames,
                    })
                    if not started then finishNames() end
                end
                if type(nicknameFn) ~= "function" then
                    requestDirectThenDeliver()
                    return
                end
                local nicknameOK, nicknameInvoked = pcall(function()
                    return nicknameFn({
                        userIds = userIds,
                        onSuccess = function(nicknames)
                            local names = parseNicknameResult(nicknames, userIds)
                            applyLiveNames(names)
                            finishNames()
                        end,
                        onError = finishNames,
                    })
                end)
                if not nicknameOK or nicknameInvoked == false then finishNames() end
            end,
            error = function(code, message)
                deliver("error", code, message)
            end,
            timeout = function()
                deliver("timeout")
            end,
        })
    end)
    if not ok or invoked == false then return false, tostring(invokeReason or invoked) end
    return true, "loading"
end

-- The underlying clientCloud request has no cancellation contract.  Invalidate
-- local callbacks when the player leaves or retries so a late response cannot
-- overwrite a newer leaderboard view.
function PlatformFeatures.cancelLeaderboardFetch()
    leaderboardGeneration = leaderboardGeneration + 1
end

function PlatformFeatures.resetForTests()
    submitted = {}
    submitting = {}
    directNicknameRequests = {}
    directNicknameEarlyResponses = {}
    directNicknameBridgeInstalled = false
    directNicknameCallInFlight = 0
    leaderboardGeneration = leaderboardGeneration + 1
    rewardedRequestSerial = rewardedRequestSerial + 1
    rewardedRequest = nil
    privacyConsent = false
    leaderboardAdapter = nil
    identity.ready = false
    identity.userId = nil
    identity.userIdText = nil
    identity.nickname = nil
    identity.nicknameRequested = false
    identity.nicknameRetryAt = 0
    identity.nicknameSource = "none"
    identity.nicknameSyncing = false
    identity.nicknameSyncedValue = nil
    identity.identitySource = "local_mode"
    identity.nicknameDiagnostic = "not_requested"
    identity.nicknameRequestGeneration = 0
end

PlatformFeatures.LAYER_CAP = LAYER_CAP
PlatformFeatures.SCORE_CAP = SCORE_CAP
PlatformFeatures.RANK_BASE = RANK_BASE
PlatformFeatures.MAX_RANK_SCORE = MAX_RANK_SCORE
PlatformFeatures.JS_SAFE_INTEGER = JS_SAFE_INTEGER
PlatformFeatures.getLeaderboardKey = leaderboardKey

return PlatformFeatures
