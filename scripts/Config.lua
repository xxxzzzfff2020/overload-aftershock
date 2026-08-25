-- Config.lua
-- 《过载余波》首发版 - 全部可调数值集中配置(见任务书 §20)
-- 所有游戏数值禁止散落硬编码,调参只改这里。

local ReleaseInfo = require "ReleaseInfo"

local Config = {}

Config.GAME_VERSION = ReleaseInfo.GAME_VERSION

Config.DEBUG = {
    autotest = false,     -- 正式流程不自动运行研发自检
    log = false,          -- 正式候选关闭逐事件日志
    panelEnabled = false, -- 正式候选彻底关闭隐藏面板与 F1 入口
    showPaths = false,    -- 调试:绘制敌人路径
    showLOS = false,      -- 调试:绘制视野遮挡射线
    showStats = false,    -- 调试:实体数量与逻辑帧耗时
}

-- 正式首发模式：底层保留实验能力，普通玩家流程固定使用完整风险收益规则。
Config.FORMAL = {
    profile = "B",
    -- L9快速验收仅保留为源码内的负责人 QA 路径；普通玩家设置页默认不显示。
    -- 需要内部验收时必须由受控构建显式打开，不能作为正式玩家入口泄漏。
    fastReviewL9Enabled = false,
    layerIntroDuration = 3.0,
    restartChannelTime = 0.7,
    huntMarkRadius = 300.0,
    lureSenseRadius = 420.0,
    huntPreferredMinimum = 3,
    huntMarkMax = 8,
    huntStunTime = 0.45,
    overloadContactTimeLoss = 0.3,
    overloadContactLossCapPerSec = 0.9,
    heavyWarningTime = 0.75,
    heavyStrikeRange = 92.0,
    heavyStrikeCooldown = 2.8,
    readyHeatPerSec = 2.2,
}

-- 信号黑障是独立产品系统，不与诱饵/猎杀侦测半径共用调参源。
-- 043A只启用固定首发合同；无尽感知带宽成长留给后续已批准批次。
Config.SIGNAL_BLACKOUT = {
    baseRadius = 420.0,
    softRadiusMultiplier = 1.35,
    minimumRadiusFactor = 0.80,
    futureEndlessStep = 0.05,
    ghostDuration = 2.5,
    signalInterval = 2.4,
    signalDuration = 0.75,
    previewFieldAlpha = 105,
    softFieldAlpha = 145,
    fullFieldAlpha = 185,
    outerBlackoutAlpha = 82,
}

-- 独立反猎阶段：重启后停留在当前层清算追兵，不加层、不换图、不预加载下一层协议。
Config.ANTI_HUNT_PHASE = {
    -- 有可清算目标时固定保留完整 10 秒反猎窗口；零威胁样本仍走独立短收口。
    minimumVisibleDuration = 10.0,
    maximumDuration = 10.0,
    zeroThreatDelay = 1.0,
    clearedDelay = 0.5,
    ordinaryDazeTime = 0.7,
    chainWarmup = 0.8,
}

-- 标准层数与无尽。第10层通关后由玩家选择结束或继续。
Config.RUN = {
    finalLayer = 10,          -- 标准挑战最后一层
    endlessHeatStep = 1,      -- 无尽阶段每层只降低的热度档数
}

-- 046：L11+超限阶段。只在world.endless且round>=11时读取，L1-L10不受影响。
Config.ENDLESS = {
    overloadLateSpawnCutoff = 4.0,
    hordeIntervalMul = { 1.08, 1.02, 0.96, 0.90, 0.84, 0.78 },
    hordeAliveCap = { 18, 20, 22, 24, 25, 26 },
    dropGrace = { 2.15, 1.85, 1.55, 1.30, 1.10, 0.90 },
    viewMul = { 1.06, 1.09, 1.12, 1.16, 1.20, 1.24 },
    chaseMul = { 1.08, 1.10, 1.12, 1.16, 1.20, 1.24 },
    pressureLabel = { "超限起步", "超限起步", "超限起步", "构筑检验", "构筑检验", "无尽挑战" },
    -- 048：L13 起让固定岗位在约 5 格内巡逻，随后缓慢扩大，
    -- 仍复用现有敌人/视野规则，不新增敌种或全局速度。
    roamStartLayer = 13,
    roamRadiusBase = 240,
    roamRadiusStep = 12,
    roamRadiusMax = 300,
    roamRepathTime = 1.8,
    -- 048：L15 起在枯竭阶段按层增加追踪压力；间隔到 15 秒后封顶。
    trackerStartLayer = 15,
    trackerIntervalStart = 30,
    trackerIntervalFloor = 15,
    trackerAliveCap = 6,
}

-- 正式计分。时间本身不产分，只有有效战斗、潜行和风险行为计分。
Config.SCORE = {
    comboWindow = 2.4,
    multiplierStepKills = 3,
    multiplierMax = 5.0,
    normalKill = 100,
    sentinelKill = 220,
    heavyKill = 900,
    firewall = 700,
    relay = 600,
    markTrigger = 350,
    multiChain = 80,
    lastSeconds = 150,
    huntKill = 400,
    stealthCell = 70,
    cleanDismantle = 350,
    hotDeep = 900,
    markTarget = 250,
    escape = 300,
    dangerResource = 160,
    readyResourceRisk = 100,
    readyDwellRisk = 120,
    lurePerEnemyRisk = 180,
    restart = 500,
}

-- 教学提示(§任务包E + 023C首次教程生命周期)
Config.TUTORIAL = {
    enabled = true,             -- 总开关
    hintDuration = 4.5,         -- 局内轻量提示显示时长(秒,既有机制)
    -- 023C:首次教程(新档第一局开始前全屏图文,完成后持久化 tutorial_completed)
    firstRunPages = true,
    overlayPages = {
        {
            title = "过载：现在轮到你追它们",
            body = "30秒内火力全开。主动追击，尽量清场并积累连杀。\n倒计时结束后，你会失去这股力量。",
            scene = "hunt",
            badge = "1/4", accent = "overload",
            -- 025:图例使用游戏内真实单位(精灵缺失自动几何回退)
            icons = {
                { sprite = "player_overload", label = "你（猎人）" },
                { sprite = "enemy_drone", label = "巡逻无人机" },
                { sprite = "enemy_sentinel", label = "安保机械" },
                { sprite = "enemy_glitch", label = "数据畸变体" },
                { sprite = "enemy_heavy", label = "重型守卫" },
                { sprite = "obj_wreck", label = "残骸（高价值目标）" },
            },
        },
        {
            title = "枯竭：现在它们开始追你",
            body = "过载结束后，你无法正面清场。躲开追击，收集储能；\n隐身、诱饵和干扰是脱身工具。",
            scene = "depleted",
            badge = "2/4", accent = "depleted",
            icons = {
                { sprite = "player_depleted", label = "你（猎物）" },
                { sprite = "obj_cell", label = "储能（绿）" },
                { sprite = "obj_core", label = "数据核心" },
                { sprite = "obj_wreck", label = "残骸（可拆解）" },
                { sprite = "icon_cloak", label = "隐身" },
                { sprite = "icon_decoy", label = "诱饵" },
                { sprite = "icon_jammer", label = "干扰" },
            },
        },
        {
            title = "能重启了，但你也可以再贪一点",
            body = "储能满后可以立即重启。继续诱敌能带来更高反猎收益，\n但被击倒会失去这次机会。",
            scene = "choose",
            badge = "3/4", accent = "depleted",
            icons = {
                { sprite = "icon_energy", label = "储能满" },
                { sprite = "icon_restart", label = "安全重启" },
                { sprite = "icon_heat1", label = "追踪热度" },
                { sprite = "icon_hunt", label = "反猎收益" },
                { sprite = "icon_unbanked", label = "未结算风险" },
            },
        },
        {
            title = "按住重启，清算所有追兵",
            body = "在危险时按住重启0.7秒。完成重启后，刚才追你的敌人\n会变成高分目标。\n先做猎人，再做猎物，最后完成反猎。",
            scene = "antihunt",
            badge = "4/4", accent = "overload",
            icons = {
                { sprite = "icon_restart", label = "按住重启 0.7 秒" },
                { sprite = "enemy_heavy", label = "追兵变目标" },
                { sprite = "icon_hunt", label = "反猎击杀 +分" },
                { sprite = "icon_chain", label = "清算连击" },
            },
        },
    },
    maxPages = 4,
    restartChannelTime = 0.7,
}


-- 试玩数据记录(§任务包F)
Config.METRICS = {
    enabled = false,                 -- 研发统计不进入正式候选；SelfTest 会显式临时启用
    keepSessions = 20,               -- 最多保留最近 N 局([R2] 10→20,§十九)
    quickRestartWindow = 10,         -- 达到最低储能后 N 秒内重启记为"立即重启"
    jailDepletedTime = 45,           -- 枯竭超过 N 秒纳入坐牢疑似判断
    jailMinActions = 3,              -- 枯竭有效行为低于 N 纳入坐牢疑似判断
}

-- 平台能力降级方案：身份或clientCloud能力不可用时不显示空壳入口；
-- 本地存档与本地纪录始终可用。
Config.PLATFORM = {
    -- 024C：正式身份与平台能力。identityReady 由 PlatformFeatures 在 clientCloud 可用时
    -- 自动探测（有 userId 即为有效身份）；cloudSave 在隐私同意后才真正初始化。
    identityReady = false,
    cloudSave = true,
    leaderboard = true,
    -- Maker/UrhoX Lua排行榜基于clientCloud iscores键，不使用小游戏
    -- tap.getLeaderboardManager() 的后台排行榜ID。
    leaderboardBackend = "clientCloud",
    leaderboardKey = "overload_endless_rank_v1",
    -- 新应用广告状态由 Maker get_ad_config 管理。UrhoX 正式接口
    -- sdk:ShowRewardVideoAd(callback) 不接收广告位 ID，禁止把后台 ID 硬编码进 Lua。
    rewardedAd = true,
    leaderboardName = "过载余波·无尽挑战榜",
    cloudArchiveName = "overload_aftermath_save_v10.json",
    clientCloudCompatibility = false,
    supportContact = nil,
    privacyUrl = nil,
    subjectQualification = nil,
    rewardedRevive = {
        placement = "death_revive",
        perRunLimit = nil, -- 普通模式无限
        endlessPerRunLimit = 3,
        dailyHardCap = nil, -- 不在客户端伪造额外日上限
        firstLayerDisabled = false,
        firstSecondsDisabled = 0,
        -- SDK 接受请求后可能没有终态回调：15 秒给玩家本地返回选择，
        -- 180 秒才按失败收口。两者都绝不代表观看成功。
        softTimeoutSeconds = 15,
        hardTimeoutSeconds = 180,
    },
}

-- 1.1 canonical：旧024D“任意失焦恢复当前战斗状态”已废弃。
-- RunRecovery源码继续保留给026复用序列化、run_id/seed和损坏备份底座，
-- 但正式运行路径不得保存或恢复位置、敌人、热度和阶段。
Config.RECOVERY = {
    deprecatedRealtime = false,
    focusLossSnapshot = false,
    currentEnemyRestore = false,
    currentPositionRestore = false,
    currentHeatRestore = false,
    currentPhaseRestore = false,
}

-- 024C：局内暂停。
Config.PAUSE = {
    enabled = true,
    keyboard = { "KEY_ESCAPE", "KEY_P" },
}

-- 寻路(§任务包C)
Config.PATH = {
    repathInterval = 0.45,           -- 单个敌人路径刷新最小间隔(秒)
    repathMoveThreshold = 72,        -- 目标移动超过该距离才重算(世界像素)
    stuckTime = 1.2,                 -- 位移不足持续 N 秒判定卡住并强制重算
    stuckMinMove = 10,               -- stuckTime 内位移低于该值算"位移不足"
    maxSearchNodes = 900,            -- A* 单次扩展节点上限(24x34=816 格,全图可覆盖)
    separationDist = 22,             -- 敌人间最小间距(防完全重叠)
    separationPush = 60,             -- 分离推力(像素/秒)
}

-- 世界与地图
Config.TILE = 48                    -- 每格世界像素
Config.VIEW_TILES = 10.5            -- 短边可见格数(决定相机缩放)

-- 玩家
Config.PLAYER = {
    maxHp = 100,
    radius = 16,
    moveSpeed = 220,                -- 世界像素/秒
    overloadSpeedBonus = 1.1,       -- 过载阶段移速倍率
    depletedDamageTaken = 1.25,     -- 枯竭阶段仍脆弱，但避免跨层伤害累积在3—5层形成硬墙
    overloadDamageTaken = 0.5,      -- 过载阶段受伤倍率(强势感)
    restartHeal = 70,               -- 成功重启进行系统修复，奖励完成整套循环
    dropGraceTime = 1.5,            -- 强制跌落瞬间敌人短暂失神时长(防秒杀,§18.1)
}

-- 过载阶段
Config.OVERLOAD = {
    duration = 30,                  -- 初始过载时长(秒)
    chainInterval = 0.65,           -- 连锁侵入自动攻击间隔
    chainRange = 280.0,               -- 首目标锁定半径
    chainJumpRange = 190.0,           -- 连锁跳跃半径
    chainTargets = 4,               -- 基础连锁目标数
    chainDamage = 35,
    chainHeavyFactor = 0.15,        -- 连锁对重型伤害倍率(明显偏弱)
    chainFirewallDamage = 8,
    pulseCooldown = 6,
    pulseRadius = 210,
    pulseDamage = 60,
    pulseStun = 1.2,
    pulseHeavyFactor = 0.3,
    collapseCooldown = 10,
    collapseRange = 320.0,            -- 自动索敌半径(重型/防火墙/标记优先)
    collapseDamage = 250,
    collapseNormalDamage = 120,
    markBonusDamage = 180,          -- 标记引爆额外范围伤害
    markBonusRadius = 240,
    markBonusStun = 2.0,
    markBonusTime = 2.0,            -- 标记引爆返还的过载时间(秒)
    lastWarnTime = 5,               -- 倒计时最后 N 秒警告
}

-- 枯竭阶段
-- [R1 调参] restartEnergyBase 100→180、cellValue 20→15:
--   Bot 实测原循环约 40-42s(枯竭仅 ~12s),低于 65-100s 目标;
--   提高需求 + 降低单件价值 → 枯竭段需要走访更多点位(依据 §任务包I 13.1)。
Config.DEPLETED = {
    restartEnergyBase = 200,        -- 第1轮重启所需储能
    cellValue = 15,                 -- 基础储能组件价值
    coreEnergyValue = 20,           -- 拾取高级核心附带的储能
    dismantleTime = 2.0,            -- 残骸拆解读条
    dismantleCores = 0,             -- 普通重型残骸不再产出黄色核心(改为产出残骸数据)
    jammerUses = 3,                 -- 干扰弹次数/每轮
    jammerDuration = 4,
    jammerRange = 260.0,              -- 自动选取最近敌人的半径
    decoyUses = 2,                  -- 诱饵信标次数/每轮
    decoyDuration = 6,
    decoyRadius = 300.0,              -- 吸引半径
    cloakUses = 1,                  -- 光学隐身次数/每轮(方案A)
    cloakDuration = 3,
    cloakDetectFactor = 0.25,       -- 隐身时敌人视距倍率(贴脸仍会暴露)
    markRange = 200.0,                -- 标记交互半径
    interactRange = 90,             -- 拆解/拾取交互半径
    laserDamagePerSec = 35,         -- 未关闭的激光走廊伤害(枯竭)
    laserOverloadDamagePerSec = 8,  -- 过载阶段激光伤害(可硬闯)
    -- [R1 调参] 储能限量补刷:同屏最多 N 个,拾取后在远处补刷 → 枯竭段需要跨图走位,
    --   循环时长从 ~45s 拉向 65-100s 目标(§任务包I 13.1)。供给无限但节流,无软锁。
    maxActiveCells = 4,             -- 同时存在的储能上限([R2 调参] 5→4:拉长搜集路径)
    cellRespawnDelay = 0.8,         -- 补刷间隔(秒)
    cellMinPlayerDist = 420.0,      -- 补刷点与玩家的最小距离(尽力满足)
                                    -- [R2 调参] 340→420:保守循环中位数 59s→目标 65-90s 带内
    moveSpeedFactor = 0.85,         -- 枯竭阶段移速倍率(压低节奏,潜行感)
}

-- 战术组件(§12 选两种)
Config.MODULES = {
    capacitor = { name = "扩容模块", desc = "下一轮过载 +5 秒", cost = 1, bonusTime = 5 },
    amplifier = { name = "链路放大器", desc = "下一轮连锁 +2 跳", cost = 1, bonusJumps = 2 },
}

-- 敌人(4 种,§10)
Config.ENEMIES = {
    drone = {   -- 巡逻无人机
        hp = 30, radius = 13, speed = 150, chaseSpeed = 215,
        viewRange = 230, viewAngle = 55, damage = 10, attackCd = 0.8,
        color = { 255, 120, 80 },
    },
    sentinel = { -- 安保机械
        hp = 90, radius = 19, speed = 75, chaseSpeed = 130,
        viewRange = 330, viewAngle = 100, damage = 16, attackCd = 1.0,
        color = { 255, 190, 60 },
    },
    glitch = {  -- 数据畸变体
        hp = 40, radius = 14, speed = 110, chaseSpeed = 170,
        viewRange = 170, viewAngle = 360, damage = 12, attackCd = 0.9,
        color = { 200, 100, 255 },
    },
    heavy = {   -- 重型守卫
        hp = 500, radius = 22, speed = 55, chaseSpeed = 95,
        viewRange = 260, viewAngle = 120, damage = 26, attackCd = 1.4,
        color = { 255, 60, 90 },
    },
}

-- 敌人 AI 计时
Config.AI = {
    suspectTime = 0.6,      -- 发现可疑目标→警戒 所需持续看见时间
    alertTime = 0.35,       -- 警戒→追击 延迟
    loseTime = 1.6,         -- 追丢后进入搜索前的记忆时间
    searchTime = 3.5,       -- 原地/小范围搜索时长
    hordeDespawnDist = 520, -- 跌落时,距玩家超过该距离的割草怪渐隐回收
}

-- 防火墙节点(§7.2)
Config.FIREWALL = {
    hp = 60,
}

-- 轮次难度(§11 / §20)
Config.ROUNDS = {
    energyNeedCap = 400,          -- [R1 新增] 需求上限:防止超过地图储能供给能力(§18 防软锁)
    maxPatrolAdd = 6,
    maxHeavy = 4,
    hordeBatch = 2,               -- 每次刷新只数
    hordeMaxAlive = 26,           -- 同屏割草怪上限(对象池容量参考)
    -- 第1—10层采用显式节奏表，避免第3层同时叠加储能、巡逻、重型、视距、
    -- 追击和刷新倍率。第10层后沿用第10层安全上限，保持无尽模式可操作。
    layers = {
        { energyNeed = 200, viewMul = 0.85, chaseMul = 1.00, hordeInterval = 1.10, heavyCount = 0, patrolExtra = 0 },
        { energyNeed = 215, viewMul = 0.94, chaseMul = 1.00, hordeInterval = 1.08, heavyCount = 1, patrolExtra = 1 },
        { energyNeed = 225, viewMul = 0.96, chaseMul = 1.02, hordeInterval = 1.08, heavyCount = 1, patrolExtra = 1 },
        -- 第4—6层先分别学习地图B/扫描、猎杀和强化反猎，不与基础曲线同步陡升。
        { energyNeed = 235, viewMul = 0.98, chaseMul = 1.03, hordeInterval = 1.06, heavyCount = 1, patrolExtra = 1 },
        { energyNeed = 245, viewMul = 1.00, chaseMul = 1.04, hordeInterval = 1.04, heavyCount = 2, patrolExtra = 2 },
        { energyNeed = 260, viewMul = 1.04, chaseMul = 1.07, hordeInterval = 1.00, heavyCount = 2, patrolExtra = 3 },
        -- 第7—10层协议本身已经改变压力，基础敌群只做缓慢增长。
        { energyNeed = 280, viewMul = 1.08, chaseMul = 1.10, hordeInterval = 0.96, heavyCount = 3, patrolExtra = 3 },
        { energyNeed = 295, viewMul = 1.10, chaseMul = 1.12, hordeInterval = 0.94, heavyCount = 3, patrolExtra = 4 },
        { energyNeed = 315, viewMul = 1.14, chaseMul = 1.14, hordeInterval = 0.90, heavyCount = 3, patrolExtra = 4 },
        -- 第10层恢复020前的可见敌量；枯竭压力由状态槽位仲裁，而不是删掉全阶段敌人。
        { energyNeed = 335, viewMul = 1.18, chaseMul = 1.17, hordeInterval = 0.86, heavyCount = 4, patrolExtra = 5 },
    },
    -- [R1 新增] 第一轮宽容度(§任务包I 13.5,不删除潜行威胁,只放缓第一次跌落)
    firstDropGraceBonus = 1.0,    -- 第1轮跌落时敌人失神额外加时(秒)
    firstRoundViewMul = 0.85,     -- 第1轮敌人视距倍率
}

-- 首发内容编排：固定双地图、三协议、扫描和猎杀。层数/地图/协议选择由 LayerPlan
-- 统一解释；数值仍从 ROUNDS.layers 读取，避免多处真相源。
Config.CONTENT = {
    maps = {
        outer_grid = { name = "外围网格", short = "外围" },
        firewall_core = { name = "防火墙核心", short = "核心" },
    },
    fixedLayers = {
        { map = "outer_grid", layout = 1, protocols = {}, hunter = false },
        { map = "outer_grid", layout = 2, protocols = {}, hunter = false },
        { map = "outer_grid", layout = 3, protocols = {}, hunter = false },
        { map = "firewall_core", layout = 1, protocols = {}, hunter = false },
        { map = "firewall_core", layout = 2, protocols = {}, hunter = true },
        { map = "firewall_core", layout = 3, protocols = {}, hunter = true },
        { map = "outer_grid", layout = 1, protocols = { "cluster" }, hunter = true },
        { map = "firewall_core", layout = 2, protocols = { "blockade" }, hunter = true },
        { map = "outer_grid", layout = 3, protocols = { "deep_cache" }, hunter = true },
        { map = "firewall_core", layout = 3,
          protocols = { "blockade", "deep_cache" }, hunter = true, milestone = true,
          -- 020R：只对L10生效的公平完成门。恢复固定敌量，枯竭按压力槽位排队。
          fairGate = {
              openingTemplateId = "firewall_core-layout-3-fixed-v1",
              openingPositionJitter = 0.0,
              openingAngleMode = "path",
              openingPatrolIndex = 1,
              basePatrolIndices = { 1, 2, 3, 4, 5, 6, 7, 8 },
              recoveryCellSpots = { {20,13}, {20,22} },
              riskCellSpots = { {7,7}, {18,7}, {5,13}, {5,22}, {7,26}, {18,26} },
              recoveryCellSlots = 3,
              dropGraceBonus = 2.0,
              pressureChaseCap = 3,
              pressureAmbientCap = 4,
              scanFirstDelay = 8.0,
              scanInterval = 13.0,
              staggerScanAndHunter = true,
              scanHunterGap = 2.0,
              hunterReadyDelay = 7.0,
              hunterCap = 2,
              postToolRelockGap = 2.0,
              routeHint = "右侧青环：恢复路线 · 上层深层：高风险收益",
          } },
    },
    protocolNames = {
        cluster = "集群协议",
        blockade = "封锁协议",
        deep_cache = "深层缓存协议",
    },
}

Config.PROTOCOL = {
    cluster = {
        hordeBatchMul = 1.6,
        normalKillMul = 0.85,
        highComboBonus = 90,
        minDepletedPatrols = 8,
    },
    blockade = {
        patrolExtra = 0,
        relayCount = 2,
        nodeScoreMul = 1.45,
        debtHeatPerRelay = 5,
    },
    deep_cache = {
        deepScoreMul = 1.25,
        riskScoreMul = 1.20,
        readyHeatMul = 1.20,
        deepCoreBonus = 1,
    },
}

Config.SCAN = {
    firstDelay = 7.0,
    interval = 11.0,
    warningTime = 2.0,
    activeTime = 1.0,
    heatAdd = 12,
    exposeTime = 2.0,
    jammerSuppressTime = 4.0,
}

Config.HUNTER = {
    readyDelay = 5.0,
    activationCooldown = 8.0,
    scanInterval = 2.4,
    scanRange = 230,
    -- 上限统一由 Config.HEAT_LOCK 按层数解释（见 ProtocolSys.hunterCap）。
}

Config.ANTI_HUNT = {
    rewards = { 500, 1000, 2000 },
    rewardCap = 2000,
}

-- 本局协议整备(RunShop)。只在本局有效，死亡清零，不写入存档、不上传云、不影响榜单资格。
-- 实际数值一律基于 Config 基础值计算，不直接修改全局 Config。
Config.RUN_SHOP = {
    -- 过载协议：消耗残骸数据(wreckData)
    collapseCooldown = {
        maxLevel = 3,
        prices = { 1, 3, 5 },       -- 残骸数据
        perLevel = 1.0,             -- 每级冷却 -1.0 秒
        floor = 7.0,               -- 冷却安全下限(基础10秒 → 最低7秒)
    },
    pulseCooldown = {
        maxLevel = 3,
        prices = { 2, 3, 5 },
        perLevel = 0.6,             -- 每级冷却 -0.6 秒(最多 -1.8)
        floor = 3.0,               -- 冷却安全下限
    },
    chainInterval = {
        maxLevel = 3,
        prices = { 2, 4, 6 },
        perLevel = 0.08,            -- 每级间隔 -8%(最多 -24%)
        floor = 0.40,              -- 间隔安全下限(秒)
    },
    -- 枯竭补给：消耗黄色核心(coreCount)，永久提高本局后续枯竭阶段的工具基础次数
    jammerUses = { maxLevel = 3, prices = { 2, 3, 4 }, perLevel = 1 },
    decoyUses  = { maxLevel = 3, prices = { 3, 4, 5 }, perLevel = 1 },
    cloakUses  = { maxLevel = 2, prices = { 4, 6 },    perLevel = 1 },
}

-- 残骸数据：拆解普通重型残骸产出的本局升级货币(不跨局、不上云)
Config.WRECK_DATA = {
    perNormalWreck = 1,             -- 每具普通重型残骸产出
    perDeepWreck = 1,               -- 深层缓存协议不得放大该产出
}

-- 重启反馈(§任务包D 8.4:重启瞬间对周围敌人的入侵干扰,不清屏)
Config.RESTART_FX = {
    jamRadius = 260.0,            -- 干扰半径
    jamDuration = 1.2,            -- 周围敌人短暂被干扰时长(秒)
}

-- ============================================================
-- [R2] A/B 实验与风险收益(以下全部数值仅实验B启用,§R2任务包B/C/D/E)
-- ============================================================

-- 追踪热度(§R2任务包C):4档 隐匿/暴露/追踪/锁定
Config.HEAT = {
    max = 100,
    thresholds = { 25, 55, 80 },     -- 暴露 / 追踪 / 锁定 分界
    -- 增长(枯竭阶段行为)
    addDismantle = 8,
    addDeepDismantle = 16,
    addJammer = 6,
    addDecoy = 5,
    addMark = 6,
    addCraft = 8,
    addSpotted = 10,
    addRecon = 4,
    dwellPerSec = 1.5,               -- 达到重启阈值后停留,每秒
    dangerZonePerSec = 1.0,          -- 高危区(顶部)停留,每秒
    -- 衰减
    decayPerSec = 2.4,               -- 满足条件时缓慢衰减(不能瞬间清零)
    decayDelay = 3.0,                -- 无噪声/未被发现 N 秒后才开始衰减
    -- 影响(§8.3:只改 AI 调度,不改敌人生命/伤害)
    searchTimeMul = { 1.0, 1.25, 1.6, 2.0 },   -- 各档搜索持续时间倍率
    suspectTimeMul = { 1.0, 0.9, 0.75, 0.6 },  -- 各档警戒累积加速(越小越快被盯上)
    investigateInterval = { 0, 0, 9.0, 5.5 },  -- 追踪/锁定档:每 N 秒派最近巡逻单位调查噪声点
    -- 热度2(追踪)：单点/静止单位开始在有限区域巡逻，调查派遣更靠近最后暴露点。
    -- 不生成新敌人、不全知追踪。
    roamRadius = 190.0,              -- 静止单位临时巡逻的最大半径(围绕原锚点)
    roamRepathTime = 2.2,            -- 临时巡逻点刷新间隔(秒)
    investigateCloseFactor = 0.55,   -- 热度2起调查点向最后暴露点靠近的比例(0=噪声点,1=完全贴上)
}

-- 热度3(锁定)：满能后激活或补充有限猎杀者。复用现有 Sentinel/Hunter，不新增敌人种类。
Config.HEAT_LOCK = {
    minSpawnDistance = 260.0,        -- 不在玩家脚边转化猎杀者
    maxPerLayerEarly = 1,            -- 第1—4层最多
    maxPerLayerMid = 2,              -- 第5—10层最多
    endlessBase = 2,                 -- 无尽起始上限
    endlessStepLayers = 6,           -- 无尽每 N 层上限 +1
    endlessMax = 4,                  -- 无尽上限的绝对上限
    reinforceCooldown = 9.0,         -- 锁定档补充猎杀者的最小间隔(秒)
}

-- 风险收益(§R2任务包B):超额缓存 + 深层残骸 + 未结算收益
Config.RISK = {
    overflowStep = 45,               -- 达标后每额外 45 基础储能 = 1 级缓存
    overflowMax = 2,                 -- 缓存等级上限
    cacheTime = 3,                   -- 1级:下一轮过载 +3 秒
    cacheChainTargets = 1,           -- 2级:下一轮连锁目标 +1
    deepDismantleTime = 3.0,         -- 深层残骸拆解读条(移动/受伤中断)
    deepCores = 1,                   -- 深层残骸产出高级核心
    deepCacheBonus = 1,              -- 深层残骸额外 +1 缓存等级(仍受上限)
    deepMinPlayerDist = 460.0,       -- 激活点与玩家的最小距离(尽力满足)
    deepAlertRadius = 380.0,         -- 开始拆解时提升附近敌人警戒的半径
    deepAlertSuspicion = 0.45,       -- 提升的警戒量(秒,直接加到 suspicion)
}

-- 过载优先目标(§R2任务包D):每轮从三类机会中激活两类
Config.OPPORTUNITY = {
    relayHp = 50,                    -- 追踪中继器耐久
    relayHeatMul = 0.6,              -- 击毁后:下一枯竭阶段热度增长 ×0.6(降低40%)
}

-- 侦察脉冲(§R2任务包E:复用标记按钮,无常驻新按钮)
Config.RECON = {
    cooldown = 12,                   -- 冷却(秒)
    duration = 4.0,                  -- 显示时长
    expandTime = 0.65,               -- 044R: 单一虚线侦察圈扩张时长
    afterglow = 0.5,                 -- 044R: 侦察结束后范围外圈淡出停留
    radius = 460.0,                  -- 侦察半径(资源方向/敌人巡逻朝向)
    heatAdd = 4,                     -- 触发轻微提高热度
    markHold = 0.55,                 -- 同一按钮长按达到此时长时标记范围内目标
}

-- 输入兜底(§R2任务包I 14.1:无 touch-cancel 事件时的超时回收)
Config.INPUT = {
    touchTimeout = 12,               -- 触点超过 N 秒无任何移动/抬起 → 回收
}

return Config
