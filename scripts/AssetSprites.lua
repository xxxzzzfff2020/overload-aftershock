-- AssetSprites.lua
-- 首发正式简约几何赛博美术：由 qa/generators/gen_assets.py 可复现生成的透明 PNG。
-- 全部 pcall 保护:任何图片加载失败 → 该精灵回退到几何绘制(handle=0),
-- 绝不因美术缺失黑屏。Render.init 时调用 load(vg)。

local AssetSprites = {}

-- 名称 → 资源路径(资源根 assets,引用省略 assets/)
local FILES = {
    player_depleted = "Textures/r2/player_depleted.png",
    player_overload = "Textures/r2/player_overload.png",
    enemy_drone = "Textures/r2/enemy_drone.png",
    enemy_sentinel = "Textures/r2/enemy_sentinel.png",
    enemy_glitch = "Textures/r2/enemy_glitch.png",
    enemy_heavy = "Textures/r2/enemy_heavy.png",
    obj_firewall = "Textures/r2/obj_firewall.png",
    obj_relay = "Textures/r2/obj_relay.png",
    obj_wreck = "Textures/r2/obj_wreck.png",
    obj_deepwreck = "Textures/r2/obj_deepwreck.png",
    obj_cell = "Textures/r2/obj_cell.png",
    obj_core = "Textures/r2/obj_core.png",
    obj_decoy = "Textures/r2/obj_decoy.png",
    bg_tile = "Textures/r2/bg_tile.png",
    icon_chain = "Textures/r2/icon_chain.png",
    icon_pulse = "Textures/r2/icon_pulse.png",
    icon_collapse = "Textures/r2/icon_collapse.png",
    icon_jammer = "Textures/r2/icon_jammer.png",
    icon_decoy = "Textures/r2/icon_decoy.png",
    icon_cloak = "Textures/r2/icon_cloak.png",
    icon_recon = "Textures/r2/icon_recon.png",
    icon_restart = "Textures/r2/icon_restart.png",
    icon_capacitor = "Textures/r2/icon_capacitor.png",
    icon_amplifier = "Textures/r2/icon_amplifier.png",
    icon_dismantle = "Textures/r2/icon_dismantle.png",
    icon_alert = "Textures/r2/icon_alert.png",
    icon_unbanked = "Textures/r2/icon_unbanked.png",
    icon_energy = "Textures/r2/icon_energy.png",
    icon_hunt = "Textures/r2/icon_hunt.png",
    icon_heavy = "Textures/r2/icon_heavy.png",
    icon_firewall = "Textures/r2/icon_firewall.png",
    icon_relay = "Textures/r2/icon_relay.png",
    icon_deep = "Textures/r2/icon_deep.png",
    icon_heat0 = "Textures/r2/icon_heat0.png",
    icon_heat1 = "Textures/r2/icon_heat1.png",
    icon_heat2 = "Textures/r2/icon_heat2.png",
    icon_heat3 = "Textures/r2/icon_heat3.png",
}

-- 按钮 id → 图标名(drawButtons 用)
AssetSprites.BUTTON_ICONS = {
    pulse = "icon_pulse", collapse = "icon_collapse",
    jammer = "icon_jammer", decoy = "icon_decoy", cloak = "icon_cloak",
    mark = "icon_recon", recon = "icon_recon",
    restart = "icon_restart", dismantle = "icon_dismantle",
    craftCapacitor = "icon_capacitor", craftAmplifier = "icon_amplifier",
}

AssetSprites.STATE_ICONS = {
    energy = "icon_energy", heat = "icon_heat0", risk = "icon_unbanked",
    hunt = "icon_hunt", heavy = "icon_heavy", firewall = "icon_firewall",
    relay = "icon_relay", deep = "icon_deep",
}

local handles = {}       -- name -> image handle (>0 有效)
local sizes = {}         -- name -> { w, h }, 保持非方形 PNG 的原始比例
local vg = nil
local loadedCount = 0

function AssetSprites.load(context)
    vg = context
    handles = {}
    sizes = {}
    loadedCount = 0
    for name, path in pairs(FILES) do
        local ok, h = pcall(nvgCreateImage, vg, path, 0)
        if ok and type(h) == "number" and h > 0 then
            handles[name] = h
            local sizeOK, iw, ih = pcall(nvgImageSize, vg, h)
            if sizeOK and type(iw) == "number" and type(ih) == "number"
                and iw > 0 and ih > 0 then
                sizes[name] = { w = iw, h = ih }
            else
                sizes[name] = { w = 1, h = 1 }
            end
            loadedCount = loadedCount + 1
        else
            handles[name] = 0
        end
    end
    print(string.format("[SPRITES] loaded %d/%d images (missing fall back to shapes)",
        loadedCount, AssetSprites.total()))
    return loadedCount
end

function AssetSprites.total()
    local n = 0
    for _ in pairs(FILES) do n = n + 1 end
    return n
end

function AssetSprites.count() return loadedCount end

-- 注册表查询：教程图例等静态表引用精灵名时，用于校验名称真实存在（025）。
function AssetSprites.has(name)
    return FILES[name] ~= nil
end

-- 有效句柄或 nil(nil = 用几何回退)
function AssetSprites.get(name)
    local h = handles[name]
    if h and h > 0 then return h end
    return nil
end

-- 居中绘制精灵(可旋转/半透明)。size 是最长边,自动保持 PNG 原始比例。
function AssetSprites.draw(name, x, y, size, rot, alpha)
    local h = AssetSprites.get(name)
    if not h then return false end
    nvgSave(vg)
    nvgTranslate(vg, x, y)
    if rot and rot ~= 0 then nvgRotate(vg, rot) end
    local source = sizes[name] or { w = 1, h = 1 }
    local aspect = source.w / math.max(1, source.h)
    local drawW, drawH
    if aspect >= 1 then
        drawW, drawH = size, size / aspect
    else
        drawW, drawH = size * aspect, size
    end
    local paint = nvgImagePattern(vg, -drawW * 0.5, -drawH * 0.5,
        drawW, drawH, 0, h, (alpha or 255) / 255)
    nvgBeginPath(vg)
    nvgRect(vg, -drawW * 0.5, -drawH * 0.5, drawW, drawH)
    nvgFillPaint(vg, paint)
    nvgFill(vg)
    nvgRestore(vg)
    return true
end

-- 平铺背景(bg_tile;screenW/H 逻辑像素,offset 用于随相机缓移)
function AssetSprites.drawTiledBg(w, h, offX, offY)
    local img = AssetSprites.get("bg_tile")
    if not img then return false end
    local tile = 128
    local ox = -(offX or 0) % tile - tile
    local oy = -(offY or 0) % tile - tile
    local paint = nvgImagePattern(vg, ox, oy, tile, tile, 0, img, 1.0)
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillPaint(vg, paint)
    nvgFill(vg)
    return true
end

return AssetSprites
