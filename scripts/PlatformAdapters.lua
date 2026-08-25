-- PlatformAdapters.lua
-- 官方 clientCloud 桥。兼容旧二进制仅注册 clientScore 的情况，并把
-- clientCloud/clientScore 视为引擎注入的不透明对象（可能是 table 或 userdata）。
-- 存档经 Get/Set（values 表），排行榜经 BatchSet():SetInt + GetRankList。

local PlatformAdapters = {}
local NICKNAME_SNAPSHOT_KEY = "overload_nickname_snapshot"

-- 排行榜本身不携带昵称。这里保存的只是由官方 GetUserNickname 成功返回的
-- 昵称快照，用于实时昵称查询失败时兜底；它不是玩家可编辑资料，也不是权威昵称。
local function sanitizeNicknameSnapshot(value)
    if type(value) ~= "string" then return nil end
    -- 不使用 locale-sensitive 的 %c；部分运行环境会把 UTF-8 高位字节误判
    -- 为控制字符，导致中文昵称被截坏。这里只移除 ASCII 控制码。
    value = value:gsub("%z", ""):gsub("[\1-\31\127]", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    local ok, cut = pcall(utf8.offset, value, 25)
    if not ok then return nil end
    if cut then value = value:sub(1, cut - 1) end
    return value ~= "" and value or nil
end

-- 诊断日志只在 clientCloud 注入状态变化时打印一次，避免 HandleUpdate 每帧刷屏。
local lastCloudState = nil

local function forwardError(events, code, reason)
    if events and events.error then events.error(code, reason) end
end

local function forwardTimeout(events)
    if events and events.timeout then events.timeout() end
end

local function safeMember(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

-- UID 是账号身份键，不是可计算数值。排行榜和昵称回调可能分别回传
-- `1566752225`、`"1566752225"` 或 `"1566752225.0"`；一旦经过 tonumber
-- 往返就会造成同一账号的键不一致。官方 clientCloud/昵称 API 均接受字符串。
local function canonicalUserId(value)
    if value == nil then return nil end
    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    -- 部分宿主把 Int64 UID 作为带小数位的字符串返回；只规整明确的整数
    -- 小数表示，不对任意文本 UID 做数值转换。
    if text:match("^%d+%.0+$") then text = text:gsub("%.0+$", "") end
    return text ~= "" and text or nil
end

local function validUserId(value)
    local text = canonicalUserId(value)
    return text ~= nil and text ~= "0" and text ~= "nil"
end

local function resolveCloudObject()
    local cloud = rawget(_G, "clientCloud")
    if cloud ~= nil then return cloud, "clientCloud" end

    -- 与官方 EnginePreview 兼容层一致：旧二进制可能只注册 clientScore。
    local legacy = rawget(_G, "clientScore")
    if legacy ~= nil then return legacy, "clientScore" end
    return nil, "none"
end

local function resolveUserId(cloud)
    -- 官方示例把 lobby:GetMyUserId() 作为当前账号的同步身份来源；
    -- clientCloud.userId 作为兼容回退。这样不会因云对象晚注入/类型不同
    -- 而在结算瞬间误判为本地匿名局。
    local lobby = rawget(_G, "lobby")
    if type(safeMember(lobby, "GetMyUserId")) == "function" then
        local ok, value = pcall(function()
            return lobby:GetMyUserId()
        end)
        if ok and validUserId(value) then
            return canonicalUserId(value), "lobby"
        end
    end
    local rawUserId = safeMember(cloud, "userId")
    if validUserId(rawUserId) then
        return canonicalUserId(rawUserId), "clientCloud"
    end
    return nil, "none"
end

function PlatformAdapters.detect(config)
    local platform = config and config.PLATFORM or {}
    local cloud, cloudSource = resolveCloudObject()
    local hasSaveCloud = type(safeMember(cloud, "Get")) == "function"
        and type(safeMember(cloud, "Set")) == "function"
    local hasLeaderboardCloud = hasSaveCloud
        and type(safeMember(cloud, "BatchSet")) == "function"
        and type(safeMember(cloud, "GetRankList")) == "function"

    -- 身份：云对象的 userId 存在且非空即视为已登录的正式平台身份。
    local rawUserId, userIdSource = resolveUserId(cloud)
    local identityReady = validUserId(rawUserId)

    -- 昵称：官方全局 GetUserNickname 存在时才可用。
    local nicknameFn = rawget(_G, "GetUserNickname")

    -- 诊断：同时记录来源和能力。对象是引擎绑定，不能限定必须为 Lua table。
    local cloudState = "absent"
    if cloud ~= nil then
        if hasSaveCloud then
            cloudState = hasLeaderboardCloud and "injected" or "save_only"
        else
            cloudState = "object"
        end
    end
    local stateSignature = table.concat({ cloudSource, cloudState, tostring(rawUserId),
        tostring(userIdSource) }, ":")
    if stateSignature ~= lastCloudState then
        lastCloudState = stateSignature
        local uidTail = validUserId(rawUserId)
            and string.sub(tostring(rawUserId), -6) or "none"
        print(string.format("[PLATFORM] detect source=%s cloud=%s type=%s uid_tail=%s leaderboard=%s",
            cloudSource, cloudState, type(cloud), uidTail,
            tostring(platform.leaderboard == true)))
        if cloudState == "absent" then
            print("[PLATFORM] clientCloud/clientScore 均未注入；当前运行环境没有官方跨刷新存档通道")
        elseif cloudSource == "clientScore" then
            print("[PLATFORM] 使用旧版 clientScore 兼容云通道")
        elseif cloudState == "object" then
            print("[PLATFORM] 云对象已注入但缺少 Get/Set，等待宿主完成初始化")
        end
    end

    local result = {
        cloud = nil,
        leaderboard = nil,
        cloudReason = "official_cloud_manager_unavailable",
        leaderboardReason = "official_leaderboard_manager_unavailable",
        identityReady = identityReady,
        userId = identityReady and rawUserId or nil,
        userIdText = identityReady and rawUserId or nil,
        userIdSource = userIdSource,
        nicknameFn = nicknameFn,
        cloudSource = cloudSource,
    }
    if not hasSaveCloud then
        result.cloudReason = cloud == nil and "client_cloud_unavailable"
            or "client_cloud_methods_unavailable"
        result.leaderboardReason = result.cloudReason
        return result
    end

    result.cloud = PlatformAdapters.clientCloudSave(cloud)
    result.cloudReason = cloudSource == "clientScore"
        and "client_score_compatibility" or "client_cloud_official"
    if platform.leaderboard == true and hasLeaderboardCloud then
        local lb = PlatformAdapters.clientCloudLeaderboard(cloud)
        if lb then
            result.leaderboard = lb
            result.leaderboardReason = result.cloudReason
        end
    end
    return result
end

function PlatformAdapters.clientCloudSave(cloud)
    local adapter = { kind = "client_cloud_official" }
    function adapter:load(slot, events)
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:Get(slot, {
                ok = function(values)
                    local payload = type(values) == "table" and values[slot] or nil
                    finish("ok", payload)
                end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_load_failed"))
            return false
        end
        return true
    end
    function adapter:save(slot, payload, events)
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:Set(slot, payload, {
                ok = function() finish("ok") end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_save_failed"))
            return false
        end
        return true
    end
    return adapter
end

function PlatformAdapters.clientCloudLeaderboard(cloud)
    local adapter = { kind = "client_cloud_leaderboard_official" }
    function adapter:syncNickname(nickname, events)
        local nicknameSnapshot = sanitizeNicknameSnapshot(nickname)
        if not nicknameSnapshot then
            forwardError(events, -1, "invalid_nickname_snapshot")
            return false
        end
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:BatchSet()
                :Set(NICKNAME_SNAPSHOT_KEY, nicknameSnapshot)
                :Save("过载余波昵称同步", {
                    ok = function() finish("ok") end,
                    error = function(code, reason) finish("error", code, reason) end,
                    timeout = function() finish("timeout") end,
                })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "nickname_snapshot_sync_failed"))
            return false
        end
        return true
    end
    function adapter:submitScore(leaderboardKey, rankScore, metadata, events)
        metadata = type(metadata) == "table" and metadata or {}
        local nicknameSnapshot = sanitizeNicknameSnapshot(metadata.nicknameSnapshot)
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        -- clientCloud:SetInt 是替换语义，不是“保留最高”。先读取云端现值，
        -- 只在新复合分更高时同步排行榜键及其配套展示字段。
        local function writeHigherScore()
            local ok, err = pcall(function()
                local builder = cloud:BatchSet()
                    :SetInt(leaderboardKey, rankScore)
                    :SetInt("overload_layer", metadata.layer)
                    :SetInt("overload_score", metadata.score)
                    :SetInt("overload_combo", metadata.bestCombo or 0)
                    :Set("overload_run_id", metadata.runId)
                    :Set("overload_version", metadata.gameVersion)
                    :Set("overload_assisted", metadata.assistedRun == true
                        or metadata.adAssisted == true)
                    :Set("overload_checkpoint_recovery", metadata.checkpointRecovery == true)
                if nicknameSnapshot then
                    builder:Set(NICKNAME_SNAPSHOT_KEY, nicknameSnapshot)
                end
                builder:Save("过载余波成绩结算", {
                    ok = function() finish("ok") end,
                    error = function(code, reason) finish("error", code, reason) end,
                    timeout = function() finish("timeout") end,
                })
            end)
            if not ok then finish("error", -1, tostring(err)) end
        end

        -- 分数没有刷新时仍允许更新昵称快照。这样玩家更名或首次昵称查询较晚
        -- 返回时，不必故意打出更高分才能让榜单获得可读兜底名。
        local function writeNicknameOnly(current)
            if not nicknameSnapshot then
                finish("ok", { keptExisting = true, rankScore = current })
                return
            end
            local ok, err = pcall(function()
                cloud:BatchSet()
                    :Set(NICKNAME_SNAPSHOT_KEY, nicknameSnapshot)
                    :Save("过载余波昵称同步", {
                        ok = function()
                            finish("ok", { keptExisting = true, rankScore = current })
                        end,
                        error = function(code, reason) finish("error", code, reason) end,
                        timeout = function() finish("timeout") end,
                    })
            end)
            if not ok then finish("error", -1, tostring(err)) end
        end

        local ok, invoked = pcall(function()
            return cloud:Get(leaderboardKey, {
                ok = function(_, iscores)
                    local current = type(iscores) == "table"
                        and tonumber(iscores[leaderboardKey]) or 0
                    if current and current >= rankScore then
                        writeNicknameOnly(current)
                        return
                    end
                    writeHigherScore()
                end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_score_read_failed"))
            return false
        end
        return true
    end
    function adapter:loadScores(leaderboardKey, count, events)
        local finished = false
        local requestedCount = math.max(1, math.min(20, math.floor(tonumber(count) or 20)))
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:GetRankList(leaderboardKey, 0, requestedCount, {
                ok = function(rankList)
                    local entries = {}
                    for index, item in ipairs(rankList or {}) do
                        item = type(item) == "table" and item or {}
                        local integerScores = item.iscore or item.iscores or {}
                        local values = item.score or item.scores or {}
                        local rankScore = tonumber(integerScores[leaderboardKey]
                            or item.rankScore or item.score) or 0
                        entries[#entries + 1] = {
                            rank = tonumber(item.rank) or index,
                            userId = canonicalUserId(item.userId or item.player),
                            name = sanitizeNicknameSnapshot(values[NICKNAME_SNAPSHOT_KEY]),
                            -- WASM/移动宿主可能把 Int64 绑定回传成 string；
                            -- 统一转 number 后再交给复合分解码器。
                            rankScore = rankScore,
                            layer = tonumber(integerScores.overload_layer
                                or item.layer),
                            gameScore = tonumber(integerScores.overload_score
                                or item.gameScore or item.score),
                        }
                    end
                    finish("ok", entries)
                end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            }, "overload_layer", "overload_score", NICKNAME_SNAPSHOT_KEY)
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_rank_list_failed"))
            return false
        end
        return true
    end
    function adapter:myRank(userId, leaderboardKey, events)
        if type(cloud.GetUserRank) ~= "function" then
            if events and events.error then events.error(-1, "GetUserRank_unavailable") end
            return false
        end
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:GetUserRank(userId, leaderboardKey, {
                ok = function(rank, scoreValue)
                    finish("ok", tonumber(rank), tonumber(scoreValue))
                end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_user_rank_failed"))
            return false
        end
        return true
    end
    function adapter:total(leaderboardKey, events)
        if type(cloud.GetRankTotal) ~= "function" then
            if events and events.error then events.error(-1, "GetRankTotal_unavailable") end
            return false
        end
        local finished = false
        local function finish(kind, ...)
            if finished then return end
            finished = true
            local callback = events and events[kind]
            if type(callback) == "function" then callback(...) end
        end
        local ok, invoked = pcall(function()
            return cloud:GetRankTotal(leaderboardKey, {
                ok = function(total) finish("ok", total) end,
                error = function(code, reason) finish("error", code, reason) end,
                timeout = function() finish("timeout") end,
            })
        end)
        if not ok or invoked == false then
            finish("error", -1, tostring(invoked or "client_cloud_rank_total_failed"))
            return false
        end
        return true
    end
    return adapter
end

PlatformAdapters.normalizeUserId = canonicalUserId

return PlatformAdapters
