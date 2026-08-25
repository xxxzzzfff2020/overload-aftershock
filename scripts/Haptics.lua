-- Haptics.lua
-- TapTap 官方震动接口封装。桌面/WASM拒绝或接口缺失时静默降级，绝不影响游戏。

local Haptics = {}

local settings = { vibration = true, reduceShake = false }
local available = nil
local lastAt = {}
local clock = 0

local COOLDOWN = {
    light = 0.12,
    medium = 0.22,
    heavy = 0.45,
}

function Haptics.applySettings(userSettings)
    if userSettings then settings = userSettings end
end

function Haptics.tick(dt)
    clock = clock + (dt or 0)
end

local function vibrate(kind)
    if settings.vibration == false then return false end
    if settings.reduceShake and kind == "heavy" then kind = "medium" end
    local cd = COOLDOWN[kind] or 0.2
    if lastAt[kind] and clock - lastAt[kind] < cd then return false end
    lastAt[kind] = clock
    -- 平台 sdk 只在 TapTap 运行时存在；桌面/WASM 下静默降级。
    local runtimeSdk = rawget(_G, "sdk")
    if not runtimeSdk or not runtimeSdk.VibrateShort then
        available = false
        return false
    end
    local ok, accepted = pcall(function() return runtimeSdk:VibrateShort(kind) end)
    available = ok and accepted == true
    return available
end

function Haptics.light() return vibrate("light") end
function Haptics.medium() return vibrate("medium") end
function Haptics.heavy() return vibrate("heavy") end
function Haptics.isAvailable() return available end

local EVENT_KIND = {
    energy_ready = "light",
    combo_up = "light",
    shop_purchase = "light",
    anti_hunt_cleared = "medium",
    anti_hunt_chain = "light",
    anti_hunt_start = "medium",
    enemy_alert = "medium",
    heavy_down = "medium",
    player_hurt = "medium",
    overload_end = "heavy",
    overload_restart = "heavy",
    challenge_complete = "heavy",
    player_dead = "heavy",
}

function Haptics.drain(world)
    if not world or not world.events then return end
    for _, event in ipairs(world.events) do
        local kind = EVENT_KIND[event.name]
        if kind then vibrate(kind) end
    end
end

return Haptics
