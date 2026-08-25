-- ExperimentProfiles.lua
-- [R2] A/B 实验配置(§R2任务包A):统一代码 + 功能开关,禁止复制 World/AI/Render。
-- 实验A CONTROL_R1:保持 R1 (a2a1766) 核心玩法与数值,不启用任何 R2 风险规则。
-- 实验B RISK_REWARD_R2:启用 超额缓存/追踪热度/深层残骸/过载优先目标/侦察脉冲。
-- World.New{experiment=...} 把所选 profile 的 flags 拷贝进 world.exp,
-- 之后所有玩法判断只读 world.exp(每个 World 实例独立,测试/模拟互不串)。

local Profiles = {}

Profiles.list = {
    A = {
        id = "A",
        name = "CONTROL_R1",
        label = "方案 1",
        -- R2 功能开关(A 全关 = R1 合同)
        overflowCache = false,   -- 储能超额缓存
        traceHeat = false,       -- 追踪热度
        deepWreck = false,       -- 深层数据残骸
        opportunities = false,   -- 过载优先目标(含追踪中继器)
        recon = false,           -- 侦察脉冲
    },
    B = {
        id = "B",
        name = "RISK_REWARD_R2",
        label = "方案 2",
        overflowCache = true,
        traceHeat = true,
        deepWreck = true,
        opportunities = true,
        recon = true,
    },
}

-- 会话级选择状态(真实游戏用;World 只在 init 时拷贝一份)
Profiles.selected = "B"      -- 当前实验 id
Profiles.blind = false       -- 是否盲测(UI 只显示 方案1/方案2,数据记录真实 id)

function Profiles.get(id)
    return Profiles.list[id] or Profiles.list.B
end

-- 拷贝 flags(防 World 修改共享表)
function Profiles.flags(id)
    local p = Profiles.get(id)
    local t = {}
    for k, v in pairs(p) do t[k] = v end
    return t
end

-- 选择进入方式(§6.2)
function Profiles.select(id, blind)
    Profiles.selected = (id == "A" or id == "B") and id or "B"
    Profiles.blind = blind == true
end

function Profiles.selectRandom()
    local id = (math.random() < 0.5) and "A" or "B"
    Profiles.select(id, true)
    return id
end

-- UI 显示名:盲测时隐藏 A/B 真名
function Profiles.displayName(id)
    id = id or Profiles.selected
    local p = Profiles.get(id)
    if Profiles.blind then return p.label end
    return "实验 " .. p.id
end

return Profiles
