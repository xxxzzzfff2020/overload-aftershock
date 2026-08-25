-- AppLifecycle.lua
-- 前后台与恢复输入门的纯状态机。主循环只读取 blocksWorld，避免后台补算或旧输入泄漏。

local AppLifecycle = {}

function AppLifecycle.New()
    return {
        focused = true,
        suspended = false,
        resumeRequired = false,
        focusLosses = 0,
        resumes = 0,
    }
end

function AppLifecycle.focusLost(state)
    if state.suspended then return false end
    state.focused = false
    state.suspended = true
    state.resumeRequired = false
    state.focusLosses = (state.focusLosses or 0) + 1
    return true
end

function AppLifecycle.focusGained(state, requireResumeInput)
    if state.focused and not state.suspended then return false end
    state.focused = true
    state.suspended = false
    state.resumeRequired = requireResumeInput == true
    return true
end

function AppLifecycle.consumeResume(state)
    if state.suspended or not state.resumeRequired then return false end
    state.resumeRequired = false
    state.resumes = (state.resumes or 0) + 1
    return true
end

function AppLifecycle.beginSession(state)
    if state.focused and not state.suspended then state.resumeRequired = false end
end

function AppLifecycle.blocksWorld(state)
    return state.suspended == true or state.resumeRequired == true
end

return AppLifecycle
