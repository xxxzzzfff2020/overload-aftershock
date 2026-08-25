-- AudioSys.lua
-- 正式原创音频：短音效 + 分阶段 BGM。
-- 事件音效 + 分阶段环境音；全部 pcall 保护，任何加载/播放失败静音降级，
-- 不影响游戏。设置提供总音量与静音开关(SaveSys.settings)。
-- 引擎外(lupa 测试环境)Scene/cache 不存在 → 自动降级为日志占位。

local AudioSys = {}

-- 事件名 → 音频文件(assets/Sounds/r2/;资源根为 assets,引用时省略 assets/)
local SOUND_MAP = {
    ui_click = "Sounds/r2/ui_click.wav",
    layer_intro_start = nil,
    layer_intro_tick = "Sounds/r2/countdown_tick.wav",
    overload_start = "Sounds/r2/overload_start.wav",
    chain_fire = "Sounds/r2/chain_fire.wav",
    pulse_fire = "Sounds/r2/pulse_fire.wav",
    collapse_fire = "Sounds/r2/collapse_fire.wav",
    countdown_tick = "Sounds/r2/countdown_tick.wav",
    overload_end = "Sounds/r2/overload_end.wav",
    enemy_alert = "Sounds/r2/enemy_alert.wav",
    player_escaped = "Sounds/r2/player_escaped.wav",
    cell_pickup = "Sounds/r2/cell_pickup.wav",
    core_pickup = "Sounds/r2/core_pickup.wav",
    dismantle_done = "Sounds/r2/dismantle_done.wav",
    -- 残骸拆解是 2–3 秒的持续读条；使用温和的一次性进度声，避免中断时留下循环音。
    dismantle_start = "audio/sfx/overload_wreck_dismantle_progress.mp3",
    heat_up = "Sounds/r2/heat_up.wav",
    energy_ready = "Sounds/r2/energy_ready.wav",
    restart_channel = "Sounds/r2/restart_channel.wav",
    overload_restart = "Sounds/r2/overload_restart.wav",
    mark_set = "Sounds/r2/mark_set.wav",
    mark_trigger = "Sounds/r2/mark_trigger.wav",
    craft_done = "Sounds/r2/craft_done.wav",
    player_hurt = "Sounds/r2/player_hurt.wav",
    player_dead = "Sounds/r2/player_dead.wav",
    -- 次级事件复用主音效(控制文件数量)
    enemy_kill = "Sounds/r2/enemy_kill.wav",
    heavy_down = "Sounds/r2/heavy_kill.wav",
    combo_up = "Sounds/r2/combo_up.wav",
    hunt_target = "Sounds/r2/hunt_target.wav",
    hunt_kill = "Sounds/r2/hunt_chain.wav",
    anti_hunt_chain = "Sounds/r2/hunt_chain.wav",
    hunter_protocol = "Sounds/r2/hunt_target.wav",
    scan_warning = "Sounds/r2/countdown_tick.wav",
    scan_hit = "Sounds/r2/enemy_alert.wav",
    protocol_start = "Sounds/r2/mark_set.wav",
    map_switch = "Sounds/r2/overload_start.wav",
    milestone_10 = "Sounds/r2/new_record.wav",
    new_record = "Sounds/r2/new_record.wav",
    firewall_down = "Sounds/r2/mark_trigger.wav",
    relay_down = "Sounds/r2/dismantle_done.wav",
    deep_done = "Sounds/r2/core_pickup.wav",
    jammer_used = "Sounds/r2/mark_set.wav",
    decoy_placed = "Sounds/r2/mark_set.wav",
    cloak_on = "Sounds/r2/restart_channel.wav",
    recon_pulse = "Sounds/r2/heat_up.wav",
    -- [014] 反猎阶段 / 层结算 / 协议整备（复用既有音效，不新增资源）
    anti_hunt_start = "Sounds/r2/hunt_target.wav",
    anti_hunt_cleared = "Sounds/r2/combo_up.wav",
    anti_hunt_timeout = "Sounds/r2/overload_end.wav",
    layer_settled = "Sounds/r2/overload_restart.wav",
    shop_purchase = "Sounds/r2/craft_done.wav",
    wreck_data = "Sounds/r2/dismantle_done.wav",
    challenge_complete = "Sounds/r2/new_record.wav",
    endless_start = "Sounds/r2/overload_start.wav",
    heat_lock_hunter = "Sounds/r2/hunt_target.wav",
    cloak_off = nil, enemy_chase = nil, enemy_lost = nil,
    cache_applied = nil, deep_spawn = nil, deep_start = nil, heat_investigate = nil,
}

local AMBIENT = {
    -- 同一首曲从 3 秒预观察连续进入 30 秒过载；非循环，阶段结束时自然切回潜行氛围。
    layer_intro = { file = "audio/过载余波｜算力过载_20260822082133.mp3", loop = false },
    overload = { file = "audio/过载余波｜算力过载_20260822082133.mp3", loop = false },
    depleted = "Sounds/r2/ambient_depleted.ogg",
    -- 反猎固定为 10 秒，使用独立的原创反转曲；不循环，清算后立即回到结算氛围。
    anti_hunt = { file = "audio/Pixel_Counterpunch_20260822082933.mp3", loop = false },
    layer_settlement = "Sounds/r2/ambient_depleted.ogg",
}

local POOL_SIZE = 6           -- 同时播放的音效上限(§性能:同一音效不无限叠加)
local DEDUP_WINDOW = 0.06     -- 同名事件在窗口内只播一次

local ready = false           -- 引擎音频可用
local scene = nil
local sources = {}            -- 音效 SoundSource 池
local poolIdx = 1
local ambientSource = nil
local ambientName = nil
local ambientPhase = nil
local ambientLoop = nil
local logged = {}
local lastPlay = {}           -- name -> clock
local clock = 0
local paused = false
local userGestureUnlocked = false
local verifyAmbientAt = nil
local verifiedAmbient = {}
local settings = { sound = true, volume = 0.8, musicVolume = 0.55, sfxVolume = 0.8 }

local function logOnce(key, message)
    if logged[key] then return end
    logged[key] = true
    print(message)
end

-- 初始化(main 在 Start 中调用一次;失败 → 静音降级)
function AudioSys.init(userSettings)
    if userSettings then settings = userSettings end
    ready = false
    userGestureUnlocked = false
    verifyAmbientAt = nil
    logged = {}
    verifiedAmbient = {}
    sources = {}
    local ok, err = pcall(function()
        if Scene == nil or cache == nil then error("no engine audio env") end
        scene = Scene()
        local node = scene:CreateChild("AudioNode")
        for i = 1, POOL_SIZE do
            sources[i] = node:CreateComponent("SoundSource")
            sources[i].soundType = SOUND_EFFECT or "Effect"
        end
        ambientSource = node:CreateComponent("SoundSource")
        ambientSource.soundType = SOUND_MUSIC or "Music"
        ambientSource.gain = 0.35
        ambientSource:SetDeclickEnabled(true)
        ready = true
    end)
    if not ready then
        print("[AUDIO] init degraded to silent: " .. tostring(err))
    end
    AudioSys.applySettings()
    return ready
end

-- 应用音量/静音设置(设置页调用)
function AudioSys.applySettings(userSettings)
    if userSettings then settings = userSettings end
    if not ready then return end
    pcall(function()
        local fallback = settings.volume or 0.8
        local sfxGain = settings.sound and (settings.sfxVolume or fallback) or 0
        local musicGain = settings.sound and (settings.musicVolume or fallback * 0.7) or 0
        audio:SetMasterGain(SOUND_EFFECT or "Effect", sfxGain)
        audio:SetMasterGain(SOUND_MUSIC or "Music", musicGain)
        if not settings.sound and ambientSource then
            ambientSource:Stop()
        elseif settings.sound and userGestureUnlocked and ambientPhase
            and ambientSource and not ambientSource:IsPlaying() then
            AudioSys.setAmbient(ambientPhase, true)
        end
    end)
end

-- 浏览器自动播放策略要求在真实用户手势后才启动音频。
function AudioSys.unlock()
    if userGestureUnlocked then return ready end
    userGestureUnlocked = true
    if not ready then return false end
    local ok, err = pcall(function()
        if audio and audio.Play then audio:Play() end
    end)
    if not ok then logOnce("audio_play", "[AUDIO] audio device start failed: " .. tostring(err)) end
    if ambientPhase and settings.sound and not paused then AudioSys.setAmbient(ambientPhase, true) end
    return ok
end

function AudioSys.setPaused(value)
    paused = value == true
    if not ready or not ambientSource then return end
    pcall(function()
        if paused then
            -- 事件音效不跨后台续播，避免恢复后补出已经失效的攻击/提示声。
            for _, src in ipairs(sources) do src:Stop() end
            if audio and audio.PauseSoundType then
                audio:PauseSoundType(SOUND_MUSIC or "Music")
            else
                ambientSource:Stop()
            end
        elseif ambientPhase and settings.sound and userGestureUnlocked then
            if audio and audio.ResumeSoundType then audio:ResumeSoundType(SOUND_MUSIC or "Music") end
            if not ambientSource:IsPlaying() then AudioSys.setAmbient(ambientPhase, true) end
        end
    end)
end

function AudioSys.tick(dt)
    clock = clock + dt
    if verifyAmbientAt and clock >= verifyAmbientAt then
        verifyAmbientAt = nil
        local phase = ambientPhase
        local ok, playing = pcall(function()
            return ambientSource and ambientSource:IsPlaying()
        end)
        if ok and playing then
            if phase and not verifiedAmbient[phase] then
                verifiedAmbient[phase] = true
                print("[AUDIO] ambient playing: " .. phase .. " -> " .. tostring(ambientName))
            end
        else
            logOnce("ambient_not_playing_" .. tostring(phase),
                "[AUDIO] ambient failed to enter playing state: " .. tostring(ambientName))
        end
    end
end

local function loadSound(file)
    local ok, snd = pcall(function() return cache:GetResource("Sound", file) end)
    if not ok then
        logOnce("load_error_" .. tostring(file),
            "[AUDIO] sound load error: " .. tostring(file) .. " | " .. tostring(snd))
        return nil
    end
    if snd == nil then
        logOnce("missing_" .. tostring(file), "[AUDIO] missing sound: " .. tostring(file))
    end
    return snd
end

function AudioSys.play(name)
    local file = SOUND_MAP[name]
    if not file then return end
    if paused or not ready or not settings.sound or not userGestureUnlocked then return end
    -- 去重:同事件短窗口只播一次(§性能)
    if lastPlay[name] and clock - lastPlay[name] < DEDUP_WINDOW then return end
    lastPlay[name] = clock
    local ok, err = pcall(function()
        local snd = loadSound(file)
        if snd == nil then return end
        local src = sources[poolIdx]
        poolIdx = poolIdx % POOL_SIZE + 1
        src:Play(snd)
    end)
    if not ok then logOnce("play_error_" .. name, "[AUDIO] sound play error: " .. name .. " | " .. tostring(err)) end
end

-- 环境音：按阶段切换。预观察与过载共享同一非循环曲目，枯竭保持原有循环氛围。
function AudioSys.setAmbient(phase, force)
    local spec = AMBIENT[phase]
    local file = type(spec) == "table" and spec.file or spec
    local looped = type(spec) ~= "table" or spec.loop ~= false
    -- 预观察 → 过载共用同一曲目时不重置播放头，确保前 3 秒自然接入后续战斗段。
    if not force and ambientName == file and ambientLoop == looped then
        ambientPhase = phase
        if ready and ambientSource and ambientSource:IsPlaying() then
            verifiedAmbient[phase] = true
        end
        return
    end
    ambientPhase = phase
    ambientName = file
    ambientLoop = looped
    if not ready then return end
    local ok, err = pcall(function()
        if paused or not file or not settings.sound or not userGestureUnlocked then
            ambientSource:Stop()
            return
        end
        if ambientSource:IsPlaying() then ambientSource:Stop() end
        local snd = loadSound(file)
        if snd then
            snd:SetLooped(looped)
            ambientSource:Play(snd)
            verifyAmbientAt = clock + 0.25
        else
            ambientSource:Stop()
        end
    end)
    if not ok then
        logOnce("ambient_play_error_" .. tostring(phase),
            "[AUDIO] ambient play error: " .. tostring(file) .. " | " .. tostring(err))
    end
end

function AudioSys.drain(world)
    for i = 1, #world.events do
        AudioSys.play(world.events[i].name)
        world.events[i] = nil
    end
    AudioSys.setAmbient(world.phase)
end

function AudioSys.shutdown()
    if ambientSource then pcall(function() ambientSource:Stop() end) end
    sources = {}
    ambientSource, scene = nil, nil
    ambientName = nil
    ambientPhase = nil
    ambientLoop = nil
    paused = false
    userGestureUnlocked = false
    verifyAmbientAt = nil
    ready = false
end

function AudioSys.diagnostics()
    local playing = false
    if ready and ambientSource then
        pcall(function() playing = ambientSource:IsPlaying() end)
    end
    return {
        ready = ready, unlocked = userGestureUnlocked, paused = paused,
        phase = ambientPhase, file = ambientName, looped = ambientLoop, playing = playing,
        verified = { overload = verifiedAmbient.overload == true,
            depleted = verifiedAmbient.depleted == true },
    }
end

return AudioSys
