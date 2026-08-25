-- MapDef.lua
-- 两张固定首发地图。地图B由固定几何指令生成ASCII表，不含随机地图生成逻辑。

local Config = require "Config"

local MapDef = {}

local OUTER_ROWS = {
    "########################", "#......................#", "#.##.##.##....##.##.##.#",
    "#a##.##.##.##.##.##.##a#", "#......................#", "###GG######LL######..###",
    "###GG######LL######..###", "#......................#", "#.####.###....###.####.#",
    "#.#..#.#........#.#..#.#", "#.#..#.#..####..#.#..#.#", "#.F..#.#..#..#..#.#..F.#",
    "#.#..#.#..#..#..#.#..#.#", "#.#..#.#..####..#.#..#.#", "#.#..#.#........#.#..#.#",
    "#.####.###....###.####.#", "#......................#", "#.####.####..####.####.#",
    "#......#........#......#", "###.####...##...####.###", "#......................#",
    "#.####....######....##.#", "#.#..#....#....#....#..#", "#.#..#....#....#....#..#",
    "#.#..#....######....#..#", "#.#..#..............#..#", "#......................#",
    "#..####..........####..#", "#..#................#..#", "#..#................#..#",
    "#..#....P...........#..#", "#..#................#..#", "#......................#",
    "########################",
}

local function fixedCoreRows()
    local w, h = 24, 34
    local grid = {}
    for r = 1, h do
        grid[r] = {}
        for c = 1, w do
            grid[r][c] = (r == 1 or r == h or c == 1 or c == w) and "#" or "."
        end
    end
    local function skipped(value, gaps)
        for _, gap in ipairs(gaps or {}) do if value == gap then return true end end
        return false
    end
    local function wallH(row, c1, c2, gaps)
        for c = c1, c2 do if not skipped(c, gaps) then grid[row][c] = "#" end end
    end
    local function wallV(col, r1, r2, gaps)
        for r = r1, r2 do if not skipped(r, gaps) then grid[r][col] = "#" end end
    end
    wallH(6, 4, 21, { 7, 8, 17, 18 })
    wallH(27, 4, 21, { 7, 8, 17, 18 })
    wallV(4, 6, 27, { 12, 13, 21, 22 })
    wallV(21, 6, 27, { 12, 13, 21, 22 })
    wallH(12, 9, 16, { 12, 13 })
    wallH(21, 9, 16, { 12, 13 })
    wallV(9, 12, 21, { 16, 17 })
    wallV(16, 12, 21, { 16, 17 })
    wallH(9, 6, 9); wallH(9, 16, 19)
    wallH(24, 6, 9); wallH(24, 16, 19)
    grid[6][12], grid[6][13] = "G", "G"
    grid[27][12], grid[27][13] = "L", "L"
    grid[16][5], grid[16][20] = "F", "F"
    grid[31][12] = "P"
    local rows = {}
    for r = 1, h do rows[r] = table.concat(grid[r]) end
    return rows
end

local MAPS = {
    outer_grid = {
        id = "outer_grid", name = "外围网格", rows = OUTER_ROWS,
        playerSpawn = { col = 12, row = 31 },
        firewalls = {
            { id = 1, col = 3, row = 12, name = "防火墙·闸门", effect = "gate", desc = "摧毁后打开左侧永久捷径" },
            { id = 2, col = 22, row = 12, name = "防火墙·激光", effect = "laser", desc = "摧毁后关闭中央激光走廊" },
        },
        scanZones = {},
    },
    firewall_core = {
        id = "firewall_core", name = "防火墙核心", rows = fixedCoreRows(),
        playerSpawn = { col = 12, row = 31 },
        firewalls = {
            { id = 1, col = 5, row = 16, name = "核心闸门", effect = "gate", desc = "摧毁后打开北侧直达通路" },
            { id = 2, col = 20, row = 16, name = "扫描供能节点", effect = "laser", desc = "摧毁后关闭南侧激光带" },
        },
        scanZones = {
            { id = 1, c1 = 5, r1 = 15, c2 = 20, r2 = 18 },
            { id = 2, c1 = 11, r1 = 7, c2 = 14, r2 = 26 },
        },
    },
}

function MapDef.get(id) return MAPS[id or "outer_grid"] or MAPS.outer_grid end
function MapDef.ids() return { "outer_grid", "firewall_core" } end

function MapDef.parse(id)
    local def = MapDef.get(id)
    local rows, h, w = def.rows, #def.rows, 24
    local solid, gateTiles, laserTiles = {}, {}, {}
    for r = 1, h do
        local line = rows[r] or ""
        assert(#line == w, string.format("MapDef %s row %d width %d ~= %d", def.id, r, #line, w))
        solid[r] = {}
        for c = 1, w do
            local ch = string.sub(line, c, c)
            local isSolid = ch == "#"
            if ch == "G" then
                isSolid = true
                gateTiles[#gateTiles + 1] = { col = c, row = r }
            elseif ch == "L" then
                laserTiles[#laserTiles + 1] = { col = c, row = r }
            end
            solid[r][c] = isSolid
        end
    end
    return {
        id = def.id, name = def.name, w = w, h = h, solid = solid,
        gateTiles = gateTiles, laserTiles = laserTiles, scanZones = def.scanZones,
    }
end

function MapDef.tileCenter(col, row)
    local t = Config.TILE
    return (col - 0.5) * t, (row - 0.5) * t
end

function MapDef.toTile(x, y)
    local t = Config.TILE
    return math.floor(x / t) + 1, math.floor(y / t) + 1
end

-- 兼容只读旧引用；新代码应通过 get(mapId) 取地图专属字段。
MapDef.rows = MAPS.outer_grid.rows
MapDef.playerSpawn = MAPS.outer_grid.playerSpawn
MapDef.firewalls = MAPS.outer_grid.firewalls
MapDef.MAPS = MAPS

return MapDef
