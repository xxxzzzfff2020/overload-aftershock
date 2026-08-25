-- MapRuntime.lua
-- 固定地图切换与实体清理。只在层边界调用，保留分数、层数、本局统计和设置。

local Config = require "Config"
local Util = require "Util"
local MapDef = require "MapDef"
local ScenarioLayouts = require "ScenarioLayouts"
local Pathfinding = require "Pathfinding"

local MapRuntime = {}

local function releaseAll(list, pool)
    for _, item in ipairs(list or {}) do item.dead = true end
    Util.compact(list or {}, pool)
end

function MapRuntime.load(world, mapId, layoutIndex, initial)
    releaseAll(world.enemies, world.enemyPool)
    releaseAll(world.fx, world.fxPool)
    world.cells, world.cores, world.wrecks, world.decoys = {}, {}, {}, {}
    world.systemPrompts = {}
    world.opportunities, world.mark, world.dismantle, world.restartChannel = nil, nil, nil, nil
    world.relays, world.firewalls = {}, {}
    world.gateOpen, world.laserActive = false, true
    world.pathSearches = 0

    local def = MapDef.get(mapId)
    world.mapId = def.id
    world.mapDef = def
    world.map = MapDef.parse(def.id)
    world.solid = world.map.solid
    world.layout = ScenarioLayouts.get(def.id, layoutIndex)
    Pathfinding.invalidate(world)

    local px, py = MapDef.tileCenter(def.playerSpawn.col, def.playerSpawn.row)
    world.player.x, world.player.y = px, py
    world.player.faceAngle = -math.pi * 0.5

    for _, f in ipairs(def.firewalls) do
        local x, y = MapDef.tileCenter(f.col, f.row)
        world.firewalls[#world.firewalls + 1] = {
            id = f.id, x = x, y = y, hp = Config.FIREWALL.hp, maxHp = Config.FIREWALL.hp,
            effect = f.effect, name = f.name, desc = f.desc, dead = false,
        }
    end
    local relayCount = world.protocols and world.protocols.blockade
        and Config.PROTOCOL.blockade.relayCount or 1
    if world.exp.opportunities and world.round >= 3 then
        for i = 1, math.min(relayCount, #world.layout.relaySpots) do
            local s = world.layout.relaySpots[i]
            local x, y = MapDef.tileCenter(s[1], s[2])
            world.relays[#world.relays + 1] = {
                x = x, y = y, hp = Config.OPPORTUNITY.relayHp,
                maxHp = Config.OPPORTUNITY.relayHp, dead = false, isRelay = true,
            }
        end
    end
    for _, p in ipairs(world.layout.corePiles) do
        local x, y = MapDef.tileCenter(p[1], p[2])
        world.cores[#world.cores + 1] = { x = x, y = y, dead = false }
    end
    world.areaAnnouncement = {
        text = def.name,
        sub = world.layout.name,
        left = initial and 0 or 2.4,
    }
    return true
end

return MapRuntime
