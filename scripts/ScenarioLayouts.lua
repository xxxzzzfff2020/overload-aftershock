-- ScenarioLayouts.lua
-- 两张固定地图各3套正式内容布局。只改变资源、巡逻、重型和中继位置，不随机生成地形。

local Config = require "Config"
local MapDef = require "MapDef"

local Layouts = {}

local function patrol(kind, points) return { kind = kind, loop = points } end

local OUTER = {
    {
        name = "基础巡逻",
        cellSpots = { {9,10},{16,10},{9,15},{16,15},{2,17},{23,17},{12,19},{13,19},{9,21},{16,21},{3,27},{22,27} },
        corePiles = { {2,4},{23,4} }, heavyPosts = { {6,2},{19,2},{12,2},{12,5} },
        patrols = {
            patrol("sentinel",{{3,8},{22,8}}), patrol("sentinel",{{2,9},{2,16},{2,9}}),
            patrol("sentinel",{{23,9},{23,16},{23,9}}), patrol("drone",{{9,10},{16,10},{16,15},{9,15}}),
            patrol("drone",{{9,19},{16,19}}), patrol("drone",{{8,21},{17,21},{17,27},{8,27}}),
            patrol("drone",{{2,2},{23,2}}), patrol("glitch",{{12,17}}),
        },
        extraPatrols = { patrol("glitch",{{12,8}}), patrol("drone",{{2,21},{23,21}}), patrol("sentinel",{{9,19},{16,19}}) },
        deepSpots = { {2,2},{23,2},{12,2} }, relaySpots = { {12,5},{6,5} }, dangerRows = 7,
    },
    {
        name = "重型残骸",
        cellSpots = { {3,27},{22,27},{8,27},{17,27},{12,27},{9,21},{16,21},{2,21},{23,21},{12,19},{2,17},{23,17} },
        corePiles = { {2,4},{23,4} }, heavyPosts = { {12,2},{6,2},{19,2},{12,5} },
        patrols = {
            patrol("sentinel",{{3,8},{22,8}}), patrol("drone",{{8,21},{17,21},{17,27},{8,27}}),
            patrol("drone",{{2,21},{2,27},{23,27},{23,21}}), patrol("drone",{{9,19},{16,19}}),
            patrol("glitch",{{12,27}}), patrol("drone",{{2,2},{23,2}}),
            patrol("sentinel",{{2,9},{2,16}}), patrol("sentinel",{{23,9},{23,16}}),
        },
        extraPatrols = { patrol("drone",{{9,10},{16,10},{16,15},{9,15}}), patrol("glitch",{{12,8}}), patrol("sentinel",{{9,19},{16,19}}) },
        deepSpots = { {12,2},{2,2},{23,2} }, relaySpots = { {12,5},{19,5} }, dangerRows = 7,
    },
    {
        name = "中继器封锁",
        cellSpots = { {12,8},{12,17},{12,19},{13,19},{12,21},{12,27},{9,10},{16,10},{9,15},{16,15},{9,21},{16,21} },
        corePiles = { {2,4},{23,4} }, heavyPosts = { {12,2},{12,5},{6,2},{19,2} },
        patrols = {
            patrol("sentinel",{{3,8},{22,8}}), patrol("drone",{{9,10},{16,10},{16,15},{9,15}}),
            patrol("drone",{{9,19},{16,19}}), patrol("glitch",{{12,17}}),
            patrol("glitch",{{12,8}}), patrol("drone",{{2,2},{23,2}}),
            patrol("sentinel",{{2,9},{2,16}}), patrol("sentinel",{{23,9},{23,16}}),
        },
        extraPatrols = { patrol("drone",{{2,21},{23,21}}), patrol("drone",{{2,17},{23,17}}), patrol("sentinel",{{9,19},{16,19}}) },
        deepSpots = { {2,2},{23,2},{2,4} }, relaySpots = { {6,5},{19,5} }, dangerRows = 7,
    },
}

local CORE = {
    {
        name = "核心环线",
        cellSpots = { {7,7},{18,7},{5,13},{20,13},{7,26},{18,26},{5,22},{20,22},{12,13},{13,20},{8,17},{17,17} },
        corePiles = { {12,17},{13,17} }, heavyPosts = { {6,8},{19,8},{6,25},{19,25} },
        patrols = {
            patrol("sentinel",{{7,7},{18,7},{20,13},{20,22},{18,26},{7,26},{5,22},{5,13}}),
            patrol("sentinel",{{12,13},{13,13},{13,20},{12,20}}),
            patrol("drone",{{5,4},{20,4}}), patrol("drone",{{5,30},{20,30}}),
            patrol("drone",{{5,17},{8,17},{17,17},{20,17}}), patrol("glitch",{{12,17}}),
            patrol("drone",{{12,7},{12,11}}), patrol("drone",{{12,22},{12,26}}),
        },
        extraPatrols = { patrol("glitch",{{7,17}}), patrol("sentinel",{{18,17}}), patrol("drone",{{7,26},{18,26}}) },
        deepSpots = { {12,17},{5,4},{20,4} }, relaySpots = { {7,17},{18,17} }, dangerRows = 7,
    },
    {
        name = "交叉走廊",
        cellSpots = { {5,4},{20,4},{7,7},{18,7},{5,17},{20,17},{7,26},{18,26},{5,30},{20,30},{12,13},{13,20} },
        corePiles = { {12,16},{13,17} }, heavyPosts = { {19,8},{6,25},{6,8},{19,25} },
        patrols = {
            patrol("sentinel",{{5,17},{8,17},{17,17},{20,17}}), patrol("sentinel",{{12,7},{12,26}}),
            patrol("drone",{{7,7},{18,7}}), patrol("drone",{{7,26},{18,26}}),
            patrol("drone",{{5,13},{5,22}}), patrol("drone",{{20,13},{20,22}}),
            patrol("glitch",{{12,17}}), patrol("glitch",{{13,20}}),
        },
        extraPatrols = { patrol("sentinel",{{12,13},{13,20}}), patrol("drone",{{5,4},{20,4}}), patrol("drone",{{5,30},{20,30}}) },
        deepSpots = { {12,17},{5,4},{20,4} }, relaySpots = { {7,17},{18,17} }, dangerRows = 7,
    },
    {
        name = "双路封控",
        cellSpots = { {7,7},{18,7},{5,13},{20,13},{5,22},{20,22},{7,26},{18,26},{12,13},{13,13},{12,20},{13,20} },
        corePiles = { {12,17},{13,17} }, heavyPosts = { {6,8},{19,25},{19,8},{6,25} },
        patrols = {
            patrol("sentinel",{{7,7},{18,7},{20,13},{20,22},{18,26},{7,26},{5,22},{5,13}}),
            patrol("sentinel",{{5,17},{20,17}}), patrol("sentinel",{{12,7},{12,26}}),
            patrol("drone",{{5,4},{20,4}}), patrol("drone",{{5,30},{20,30}}),
            patrol("glitch",{{12,17}}), patrol("drone",{{12,13},{13,20}}), patrol("glitch",{{18,17}}),
        },
        extraPatrols = { patrol("sentinel",{{7,17},{18,17}}), patrol("drone",{{7,26},{18,26}}), patrol("drone",{{7,7},{18,7}}) },
        deepSpots = { {12,17},{5,4},{20,4} }, relaySpots = { {7,17},{18,17} }, dangerRows = 7,
    },
}

local BY_MAP = { outer_grid = OUTER, firewall_core = CORE }
Layouts.count = 3

function Layouts.pick(mapOrSeed, seedOrNil, explicitIndex)
    local mapId, seed
    if type(mapOrSeed) == "string" then mapId, seed = mapOrSeed, seedOrNil or 0
    else mapId, seed = "outer_grid", mapOrSeed or 0 end
    local list = BY_MAP[mapId] or OUTER
    local idx = explicitIndex or ((math.floor(seed) % #list) + 1)
    return Layouts.get(mapId, idx)
end

function Layouts.get(mapOrIdx, idxOrNil)
    local mapId, idx
    if type(mapOrIdx) == "string" then mapId, idx = mapOrIdx, idxOrNil
    else mapId, idx = "outer_grid", mapOrIdx end
    local source = (BY_MAP[mapId] or OUTER)[idx]
    assert(source, "invalid layout " .. tostring(mapId) .. ":" .. tostring(idx))
    return {
        mapId = mapId, index = idx, name = source.name,
        cellSpots = source.cellSpots, corePiles = source.corePiles,
        heavyPosts = source.heavyPosts, patrols = source.patrols,
        extraPatrols = source.extraPatrols, deepSpots = source.deepSpots,
        relaySpots = source.relaySpots, dangerRows = source.dangerRows,
        hordeGates = mapId == "firewall_core"
            and { {7,7},{18,7},{5,17},{20,17},{7,26},{18,26},{12,33} }
            or { {2,8},{23,8},{12,17},{2,27},{23,27},{12,2},{2,21},{23,21},{12,33} },
        safeCellSpots = { {12,29},{8,29},{16,29} },
    }
end

local function reachableSet(map, spawn)
    local seen, queue = {}, { { spawn.col, spawn.row } }
    seen[spawn.row * 64 + spawn.col] = true
    local head = 1
    while queue[head] do
        local c, r = queue[head][1], queue[head][2]
        head = head + 1
        for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            local nc, nr = c + d[1], r + d[2]
            if nc >= 1 and nr >= 1 and nc <= map.w and nr <= map.h
                and not map.solid[nr][nc] and not seen[nr * 64 + nc] then
                seen[nr * 64 + nc] = true
                queue[#queue + 1] = { nc, nr }
            end
        end
    end
    return seen
end

function Layouts.validate(mapId, idx)
    local layout, def, map = Layouts.get(mapId, idx), MapDef.get(mapId), MapDef.parse(mapId)
    local reach = reachableSet(map, def.playerSpawn)
    local function checkPoints(points, label)
        for _, p in ipairs(points) do
            if not reach[p[2] * 64 + p[1]] then
                return false, string.format("%s %s (%d,%d) unreachable", mapId, label, p[1], p[2])
            end
        end
        return true
    end
    for _, row in ipairs({
        { layout.cellSpots, "cell" }, { layout.corePiles, "core" },
        { layout.heavyPosts, "heavy" }, { layout.deepSpots, "deep" },
        { layout.relaySpots, "relay" }, { layout.safeCellSpots, "safe" },
    }) do
        local ok, err = checkPoints(row[1], row[2]); if not ok then return false, err end
    end
    for _, p in ipairs(layout.patrols) do
        local ok, err = checkPoints(p.loop, "patrol"); if not ok then return false, err end
    end
    if #layout.cellSpots < Config.DEPLETED.maxActiveCells + 2 then return false, "too few cells" end
    return true
end

function Layouts.validateAll()
    for _, mapId in ipairs(MapDef.ids()) do
        for idx = 1, 3 do
            local ok, err = Layouts.validate(mapId, idx)
            if not ok then return false, err end
        end
    end
    return true
end

return Layouts
