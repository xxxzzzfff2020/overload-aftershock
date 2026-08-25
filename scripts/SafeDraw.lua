-- SafeDraw.lua
-- NanoVG 安全绘制封装(§任务包A 5.1):
-- - 字体加载失败时的降级(仍绘制几何 UI,文本静默跳过,只警告一次)
-- - 参数消毒:nil/负数尺寸、越界透明度、圆角超限
-- - 模块边界有界保护:整段绘制单元 pcall,单元失败不拖垮整帧
-- 不逐像素 pcall;只在初始化与"绘制单元"边界做保护。

local SafeDraw = {}

---@type NVGContextWrapper
local vg = nil
local fontOK = false
local warned = {}          -- 每类告警只打印一次
local sectionFail = {}     -- 每个绘制单元的失败只打印一次

local function warnOnce(tag, msg)
    if not warned[tag] then
        warned[tag] = true
        print("[SafeDraw] WARN " .. tag .. ": " .. tostring(msg))
    end
end

-- 初始化:创建字体,失败进入降级模式(游戏不黑屏,§5.1)
function SafeDraw.init(context)
    vg = context
    fontOK = false
    local ok, ret = pcall(nvgCreateFont, vg, "sans", "Fonts/MiSans-Regular.ttf")
    if ok and ret ~= -1 then
        fontOK = true
    else
        warnOnce("font", "font load failed, text rendering degraded (game keeps running)")
    end
    return fontOK
end

function SafeDraw.hasFont() return fontOK end

-- 数值消毒
function SafeDraw.num(v, fallback)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return fallback or 0
    end
    return v
end

function SafeDraw.alpha(a)
    a = SafeDraw.num(a, 255)
    if a < 0 then return 0 end
    if a > 255 then return 255 end
    return math.floor(a)
end

-- 安全矩形:负宽高跳过(但始终 BeginPath,防止后续 Fill 误填旧路径),圆角钳制
function SafeDraw.rect(x, y, w, h, r)
    nvgBeginPath(vg)
    x, y = SafeDraw.num(x), SafeDraw.num(y)
    w, h = SafeDraw.num(w), SafeDraw.num(h)
    if w <= 0 or h <= 0 then return end
    if r and r > 0 then
        local maxR = math.min(w, h) * 0.5
        if r > maxR then r = maxR end
        nvgRoundedRect(vg, x, y, w, h, r)
    else
        nvgRect(vg, x, y, w, h)
    end
end

function SafeDraw.circle(x, y, r)
    x, y, r = SafeDraw.num(x), SafeDraw.num(y), SafeDraw.num(r)
    if r <= 0 then return end
    nvgBeginPath(vg)
    nvgCircle(vg, x, y, r)
end

-- 安全文本:字体降级时静默跳过(几何 UI 仍在)
function SafeDraw.text(x, y, str)
    if not fontOK then return end
    if str == nil then return end
    nvgText(vg, SafeDraw.num(x), SafeDraw.num(y), tostring(str), nil)
end

-- 设置字体属性(降级时跳过,防 nvgFontFace 未创建字体的告警刷屏)
function SafeDraw.font(size, align)
    if not fontOK then return end
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, math.max(1, SafeDraw.num(size, 14)))
    if align then nvgTextAlign(vg, align) end
end

-- 绘制单元保护:fn 抛错时恢复 NanoVG 状态,整帧其余单元继续。
-- 每个单元失败只打印一次日志(不每帧刷屏)。
function SafeDraw.section(name, fn, ...)
    nvgSave(vg)
    local ok, err = pcall(fn, ...)
    nvgRestore(vg)
    if not ok and not sectionFail[name] then
        sectionFail[name] = true
        print("[SafeDraw] ERROR in draw section '" .. name .. "': " .. tostring(err))
    end
    return ok
end

-- 供测试:重置一次性告警状态
function SafeDraw.resetWarnings()
    warned = {}
    sectionFail = {}
end

-- [R2] 供 RenderSmoke:读取绘制单元失败详情(name → err)
function SafeDraw.getFailures()
    return sectionFail
end

return SafeDraw
