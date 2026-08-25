-- EscapeRegressionTest.lua
-- 可脱战黄金基线回归：只由启动自测调用，不参与正式玩家更新或渲染。

local Config = require "Config"
local EnemyAI = require "EnemyAI"
local Util = require "Util"
local World = require "World"

local EscapeRegressionTest = {}

local IDLE = { moveX = 0, moveY = 0, pressed = {} }

local function step(world, seconds, input)
    input = input or IDLE
    local elapsed = 0
    while elapsed < seconds and world.phase ~= "dead" do
        world:update(0.05, input)
        input = { moveX = input.moveX, moveY = input.moveY, pressed = {} }
        elapsed = elapsed + 0.05
    end
end

local function closeChaser(kind, offset)
    local world = World.New({ experiment = "B", seed = 42001 })
    world:forceDrop()
    world.enemies = {}
    world.enemyPool = Util.newPool()
    world.player.hp = world.player.maxHp
    local p = world.player
    local enemy = world:spawnEnemy(kind or "drone", p.x - (offset or 5), p.y,
        { { 4, 4 }, { 5, 4 } }, false)
    enemy.daze, enemy.stun, enemy.jammed = 0, 0, 0
    enemy.state, enemy.stateTime, enemy.suspicion = "chase", 0, 0
    enemy.lastSeenX, enemy.lastSeenY = p.x, p.y
    enemy.wasChasing, enemy.angle = true, 0
    return world, enemy
end

function EscapeRegressionTest.run(check)
    local cloakWorld, cloakEnemy = closeChaser("drone", 5)
    local cloakOriginX = cloakWorld.player.x
    cloakWorld:useCloak()
    step(cloakWorld, Config.AI.loseTime + 0.25,
        { moveX = 1, moveY = 0, pressed = {} })
    check("cloak breaks close ordinary real-time tracking",
        cloakEnemy.state == "lost" or cloakEnemy.state == "search",
        "state=" .. tostring(cloakEnemy.state))
    check("cloak preserves last exposed position instead of live player",
        math.abs((cloakEnemy.lastSeenX or -9999) - cloakOriginX) < 1
        and cloakWorld.player.x > cloakOriginX + 100)
    check("cloak escape remains dangerous rather than invincible",
        cloakWorld.player.hp > 0 and cloakWorld.player.hp < cloakWorld.player.maxHp,
        "hp=" .. tostring(cloakWorld.player.hp))

    local decoyWorld, decoyEnemy = closeChaser("drone", 5)
    decoyWorld:useDecoy()
    local decoy = decoyWorld.decoys[1]
    step(decoyWorld, 0.1, { moveX = 1, moveY = 0, pressed = {} })
    check("decoy redirects an active ordinary chase",
        decoyEnemy.state == "decoyed" and decoyEnemy.decoyTarget == decoy)
    step(decoyWorld, 0.9, { moveX = 1, moveY = 0, pressed = {} })
    check("decoy opens a measurable separation window",
        Util.dist(decoyWorld.player.x, decoyWorld.player.y, decoyEnemy.x, decoyEnemy.y) > 100)

    local contactWorld, contactEnemy = closeChaser("drone", 5)
    contactWorld:useDecoy()
    step(contactWorld, 1.0)
    check("standing on decoy remains punishable",
        contactWorld.player.hp < contactWorld.player.maxHp
        and contactEnemy.state == "decoyed")

    local falseSignalX, falseSignalY = decoy.x, decoy.y
    step(decoyWorld, Config.DEPLETED.decoyDuration + 0.2,
        { moveX = 1, moveY = 0, pressed = {} })
    check("expired decoy becomes lost/search at false signal",
        decoyEnemy.state ~= "decoyed"
        and math.abs((decoyEnemy.lastSeenX or -9999) - falseSignalX) < 1
        and math.abs((decoyEnemy.lastSeenY or -9999) - falseSignalY) < 1)

    local hunterWorld, hunter = closeChaser("sentinel", 80)
    hunter.hunter = true
    local hunterLastX, hunterLastY = hunter.lastSeenX, hunter.lastSeenY
    hunterWorld:useCloak()
    step(hunterWorld, 0.8, { moveX = 1, moveY = 0, pressed = {} })
    check("cloaked hunter follows last exposed position without omniscience",
        hunter.lastSeenX == hunterLastX and hunter.lastSeenY == hunterLastY
        and hunter.lastSeenX ~= hunterWorld.player.x)

    local losWorld, losEnemy = closeChaser("drone", 80)
    local p = losWorld.player
    local foundBlocked = false
    for row = 2, losWorld.map.h - 1 do
        for col = 2, losWorld.map.w - 1 do
            if losWorld.solid[row][col]
                and not losWorld.solid[row][col - 1] and not losWorld.solid[row][col + 1] then
                local ex, ey = (col - 1.5) * Config.TILE, (row - 0.5) * Config.TILE
                local px, py = (col + 0.5) * Config.TILE, (row - 0.5) * Config.TILE
                losEnemy.x, losEnemy.y, p.x, p.y = ex, ey, px, py
                foundBlocked = not EnemyAI.losClear(losWorld, ex, ey, px, py)
                if foundBlocked then break end
            end
        end
        if foundBlocked then break end
    end
    check("wall LOS still blocks live target information", foundBlocked)
end

return EscapeRegressionTest
