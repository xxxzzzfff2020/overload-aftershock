-- ReleaseInfo.lua
-- 正式运行时发布信息的唯一来源。Maker 项目元数据/构建号由发布前流程另行校验，
-- 不在游戏脚本中猜测或写入项目配置。

local ReleaseInfo = {}

ReleaseInfo.GAME_VERSION = "1.1.11"
ReleaseInfo.CHANNEL = "formal"
ReleaseInfo.UPDATES = {
    {
        version = ReleaseInfo.GAME_VERSION,
        title = "正式候选",
        notes = "广告、账号、云档和排行榜可靠性收口。",
    },
}

function ReleaseInfo.validate()
    local latest = ReleaseInfo.UPDATES[1]
    return type(ReleaseInfo.GAME_VERSION) == "string"
        and ReleaseInfo.GAME_VERSION ~= ""
        and type(latest) == "table"
        and latest.version == ReleaseInfo.GAME_VERSION
end

return ReleaseInfo
