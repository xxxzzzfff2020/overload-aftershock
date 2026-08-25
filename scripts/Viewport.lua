-- Viewport.lua
-- portrait raw NanoVG 分辨率合同:模式 A(固定 390 设计宽,高度随 surface 比例延展)。
-- Render/Input/Safe Area 共用同一个 snapshot，避免 Maker Web Preview 与真机使用不同坐标密度。
-- 横屏仍保留模式 B 逻辑尺寸，不在本批改变横屏产品行为。

local Viewport = {}
local currentSnapshot = nil
local DESIGN_WIDTH = 390

local function getDpr()
    local dpr = 1
    if graphics and graphics.GetDPR then
        local ok, value = pcall(function() return graphics:GetDPR() end)
        if ok and type(value) == "number" and value > 0 then dpr = value end
    end
    return dpr
end

function Viewport.scaleInsets(left, top, right, bottom, pixelScale)
    pixelScale = (type(pixelScale) == "number" and pixelScale > 0) and pixelScale or 1
    return {
        left = math.max(0, (left or 0) / pixelScale),
        top = math.max(0, (top or 0) / pixelScale),
        right = math.max(0, (right or 0) / pixelScale),
        bottom = math.max(0, (bottom or 0) / pixelScale),
        source = "official",
    }
end

-- 官方安全区返回物理像素；用物理→设计缩放转换，与触摸逆变换一致。
-- 无引擎/桌面/接口不可用时返回 nil，由启发式兜底。
local function officialInsets(w, h, pixelScale)
    if type(GetSafeAreaInsets) ~= "function" then return nil end
    local ok, rect = pcall(GetSafeAreaInsets, false)
    if not ok or rect == nil or rect.min == nil or rect.max == nil then return nil end
    local inset = Viewport.scaleInsets(rect.min.x, rect.min.y, rect.max.x, rect.max.y, pixelScale)
    -- TapTap 原生退出胶囊是归一化坐标；只扩张顶部，不改变左右布局。
    local runtimeSdk = rawget(_G, "sdk")
    if runtimeSdk and runtimeSdk.GetNativeExitMenuRect then
        local menuOK, menu = pcall(function() return runtimeSdk:GetNativeExitMenuRect() end)
        if menuOK and type(menu) == "table" and type(menu.bottom) == "number" then
            inset.top = math.max(inset.top, menu.bottom * h)
        end
    end
    if inset.left == 0 and inset.top == 0 and inset.right == 0 and inset.bottom == 0 then
        return nil
    end
    return inset
end

-- 从引擎读取原始逻辑尺寸(main 每帧调用;测试环境不调用此函数)。
function Viewport.logicalSize()
    local dpr = getDpr()
    local physicalW, physicalH = graphics:GetWidth(), graphics:GetHeight()
    if physicalW <= 0 then physicalW = 360 * dpr end
    if physicalH <= 0 then physicalH = 640 * dpr end
    return physicalW / dpr, physicalH / dpr, dpr, physicalW, physicalH
end

-- 纯数值物理→逻辑换算，供矩阵测试与运行时同一实现复用。
function Viewport.fromPhysical(physicalW, physicalH, dpr)
    dpr = (type(dpr) == "number" and dpr > 0) and dpr or 1
    return physicalW / dpr, physicalH / dpr
end

-- 纯数值 surface 变换。portrait 统一为 390 设计宽，高度按真实宽高比延展。
function Viewport.transform(physicalW, physicalH, dpr)
    dpr = (type(dpr) == "number" and dpr > 0) and dpr or 1
    physicalW = (type(physicalW) == "number" and physicalW > 0) and physicalW or 360 * dpr
    physicalH = (type(physicalH) == "number" and physicalH > 0) and physicalH or 640 * dpr
    local logicalW, logicalH = Viewport.fromPhysical(physicalW, physicalH, dpr)
    local portraitMobile = logicalH >= logicalW * 1.15
    local designScale = portraitMobile and (logicalW / DESIGN_WIDTH) or 1
    if designScale <= 0 then designScale = 1 end
    local designW, designH = logicalW / designScale, logicalH / designScale
    return {
        physicalW = physicalW,
        physicalH = physicalH,
        logicalW = logicalW,
        logicalH = logicalH,
        dpr = dpr,
        designW = designW,
        designH = designH,
        w = designW,
        h = designH,
        designScale = designScale,
        pixelScale = dpr * designScale,
        portraitMobile = portraitMobile,
    }
end

function Viewport.toLogicalPoint(x, y, snapshot)
    local scale = (snapshot and snapshot.pixelScale) or (snapshot and snapshot.dpr) or getDpr()
    return x / scale, y / scale
end

function Viewport.toPhysicalPoint(x, y, snapshot)
    local scale = (snapshot and snapshot.pixelScale) or (snapshot and snapshot.dpr) or getDpr()
    return x * scale, y * scale
end

-- 布局度量:输入逻辑宽高,输出安全区与 UI 缩放
-- 返回 {
--   w, h            原始逻辑尺寸
--   top, bottom     上/下安全内边距(刘海/状态栏/手势区,保守估计)
--   left, right     左/右安全内边距
--   ui              UI 缩放系数(以 390 宽为基准,窄屏缩小、宽屏温和放大)
-- }
local function computeMetrics(w, h, pixelScale, portraitOverride)
    w = (type(w) == "number" and w > 0) and w or 360
    h = (type(h) == "number" and h > 0) and h or 640
    local aspect = h / w
    local m = { w = w, h = h }
    local official = officialInsets(w, h, pixelScale or getDpr())
    if official then
        m.top = math.max(8, official.top)
        m.bottom = math.max(8, official.bottom)
        m.left = math.max(6, official.left)
        m.right = math.max(6, official.right)
        m.safeAreaSource = official.source
    else
        -- 桌面与不支持平台的保守兜底；真机优先使用上面的官方接口。
        if aspect >= 1.9 then
            m.top, m.bottom = 34, 24
        elseif aspect >= 1.5 then
            m.top, m.bottom = 20, 14
        else
            m.top, m.bottom = 8, 8
        end
        m.left, m.right = 6, 6
        m.safeAreaSource = "heuristic"
    end
    -- portrait 的 w 已是固定 390 设计宽；ui 只表达产品内的手机可读性增益。
    local portraitMobile = portraitOverride
    if portraitMobile == nil then portraitMobile = h >= w * 1.15 end
    local base
    if portraitMobile then
        base = 390 / 390
    else
        base = math.min(w, h) / 390
    end
    local mobileBoost = portraitMobile and 1.10 or 1.0
    local s = base * mobileBoost
    if s < 0.9 then s = 0.9 end
    if s > 1.35 then s = 1.35 end
    m.ui = s
    m.portraitMobile = portraitMobile
    m.safeW = math.max(1, w - m.left - m.right)
    m.safeH = math.max(1, h - m.top - m.bottom)
    m.controlGap = math.max(8, 10 * s)
    -- 顶部 HUD 与世界层彻底分离。战场矩形是相机、世界绘制裁剪和
    -- 游戏内触控判定共享的唯一坐标边界；HUD/Toast/全屏反馈不受此裁剪。
    m.hudTop = m.top + 6 * s
    m.hudHeight = 76 * s
    m.battleGap = math.max(8, 10 * s)
    m.battle = {
        x = m.left,
        y = m.hudTop + m.hudHeight + m.battleGap,
        w = m.safeW,
        h = math.max(1, h - m.bottom - (m.hudTop + m.hudHeight + m.battleGap)),
    }
    return m
end


function Viewport.metrics(w, h, pixelScale, portraitOverride)
    if currentSnapshot and currentSnapshot.w == w and currentSnapshot.h == h then
        return currentSnapshot
    end
    return computeMetrics(w, h, pixelScale, portraitOverride)
end

-- 每个 Render/Input 事件捕获一次不可变快照；Render、Screens、InputSys 在该事件内
-- 通过 metrics(w,h) 取得同一个对象，安全区和缩放不会各算一套。
function Viewport.capture()
    local _, _, dpr, physicalW, physicalH = Viewport.logicalSize()
    local transform = Viewport.transform(physicalW, physicalH, dpr)
    currentSnapshot = nil
    local snapshot = computeMetrics(
        transform.designW, transform.designH, transform.pixelScale, transform.portraitMobile)
    for key, value in pairs(transform) do snapshot[key] = value end
    snapshot.w, snapshot.h = transform.designW, transform.designH
    currentSnapshot = snapshot
    return snapshot
end

function Viewport.current()
    return currentSnapshot
end

-- 打印真实帧缓冲、逻辑尺寸、设计尺寸和两级缩放证据。
function Viewport.logViewportEvidence(tag)
    if not graphics or not graphics.GetWidth then return end
    local ok, m = pcall(Viewport.capture)
    if not ok or not m then return end
    print(string.format(
        "[VIEWPORT] %s phys=%dx%d dpr=%.3g logical=%.2fx%.2f design=%.2fx%.2f designScale=%.4f pixelScale=%.4f ui=%.4f safe=%s portrait=%s",
        tag or "?", m.physicalW or 0, m.physicalH or 0, m.dpr or 1,
        m.logicalW, m.logicalH, m.w, m.h, m.designScale, m.pixelScale, m.ui,
        tostring(m.safeAreaSource), tostring(m.portraitMobile)))
end

function Viewport.battlefield(w, h)
    return Viewport.metrics(w, h).battle
end

function Viewport.containsBattlePoint(x, y, w, h)
    local b = Viewport.battlefield(w, h)
    return x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
end

return Viewport
