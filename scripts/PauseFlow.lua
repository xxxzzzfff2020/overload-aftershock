-- PauseFlow.lua
-- 局内暂停的唯一状态源。渲染、输入、音频和破坏性无尽确认都从同一模态派生，
-- 避免“设置页仍在、世界冻结、音频却恢复”这类分裂状态。

local PauseFlow = {}

PauseFlow.MODE = {
    NONE = "none",
    MENU = "menu",
    SETTINGS = "settings",
    ENDLESS_END_CONFIRM = "endless_end_confirm",
}

local VALID = {
    [PauseFlow.MODE.NONE] = true,
    [PauseFlow.MODE.MENU] = true,
    [PauseFlow.MODE.SETTINGS] = true,
    [PauseFlow.MODE.ENDLESS_END_CONFIRM] = true,
}

function PauseFlow.new()
    return { mode = PauseFlow.MODE.NONE }
end

function PauseFlow.set(state, mode)
    if type(state) ~= "table" then return PauseFlow.MODE.NONE end
    state.mode = VALID[mode] and mode or PauseFlow.MODE.NONE
    return state.mode
end

function PauseFlow.mode(state)
    return type(state) == "table" and state.mode or PauseFlow.MODE.NONE
end

function PauseFlow.isActive(state)
    return PauseFlow.mode(state) ~= PauseFlow.MODE.NONE
end

function PauseFlow.isSettings(state)
    return PauseFlow.mode(state) == PauseFlow.MODE.SETTINGS
end

function PauseFlow.isEndlessEndConfirm(state)
    return PauseFlow.mode(state) == PauseFlow.MODE.ENDLESS_END_CONFIRM
end

return PauseFlow
