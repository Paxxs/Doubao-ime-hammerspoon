-- ============================================
-- 按住左 Option -> 切到豆包输入法 -> 按住左 Command（开始录音）
-- 松开左 Option -> 松开左 Command（结束录音）-> 2s 后恢复原输入法
-- 放到 ~/.hammerspoon/init.lua
-- ============================================
local log = hs.logger.new("LeftOptIME", "debug")
local alert = hs.alert

-- 目标输入法
local TARGET_INPUT_SOURCE = "豆包输入法"

-- 按住左 Option 后，多久再按下左 Command 开始录音（秒）
local CMD_PRESS_DELAY = 0.30

-- 松开左 Option 后，延迟多久恢复原输入法（秒）
local RESTORE_IME_DELAY = 2.0

-- 触发键：左 Option 的物理 keycode
local KEYCODE_LEFT_OPTION = 58

-- 状态变量
local previousInputSource = nil
local leftOptIsDown = false
local cmdPressTimer = nil
local restoreImeTimer = nil
local cmdIsHeld = false -- 我们是否正按住合成的左 Command
local synthesizingKey = false -- 正在发送合成事件（按下/松开左 Cmd）

local function nowSource()
    local method = hs.keycodes.currentMethod()
    if method ~= nil then
        return {
            kind = "method",
            value = method
        }
    end

    local layout = hs.keycodes.currentLayout()
    if layout ~= nil then
        return {
            kind = "layout",
            value = layout
        }
    end

    return nil
end

local function debugCurrentInputState(prefix)
    log.df("[%s] currentMethod   = %s", prefix, tostring(hs.keycodes.currentMethod()))
    log.df("[%s] currentLayout   = %s", prefix, tostring(hs.keycodes.currentLayout()))
    log.df("[%s] currentSourceID = %s", prefix, tostring(hs.keycodes.currentSourceID()))
end

-- 按下左 Command 并保持（开始录音）
local function pressLeftCmd()
    if cmdIsHeld then
        log.df("左 Command 已处于按住状态，忽略重复按下")
        return
    end
    synthesizingKey = true
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.cmd, true):post()
    cmdIsHeld = true
    log.df("已按下左 Command（开始录音）")
    hs.timer.doAfter(0.05, function()
        synthesizingKey = false
    end)
end

-- 松开左 Command（结束录音）
local function releaseLeftCmd()
    if not cmdIsHeld then
        log.df("左 Command 并未按住，无需松开")
        return
    end
    synthesizingKey = true
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.cmd, false):post()
    cmdIsHeld = false
    log.df("已松开左 Command（结束录音）")
    hs.timer.doAfter(0.05, function()
        synthesizingKey = false
    end)
end

local function cancelCmdTimer()
    if cmdPressTimer then
        cmdPressTimer:stop()
        cmdPressTimer = nil
        log.df("已取消待执行的左 Command 定时器")
    end
end

local function cancelRestoreImeTimer()
    if restoreImeTimer then
        restoreImeTimer:stop()
        restoreImeTimer = nil
        log.df("已取消待执行的输入法恢复定时器")
    end
end

local function switchToTargetIME()
    local current = nowSource()
    previousInputSource = current

    if current == nil then
        log.df("无法识别当前输入来源，跳过记录")
    end

    debugCurrentInputState("before switch")

    if current ~= nil and current.kind == "method" and current.value == TARGET_INPUT_SOURCE then
        log.df("当前已经是目标输入法，无需切换: %s", TARGET_INPUT_SOURCE)
        return
    end

    local ok = hs.keycodes.setMethod(TARGET_INPUT_SOURCE)
    log.df("切换到目标输入法: %s, 结果: %s", TARGET_INPUT_SOURCE, tostring(ok))
end

local function restorePreviousIME()
    if not previousInputSource then
        log.df("没有记录到之前的输入来源，跳过恢复")
        return
    end

    local old = previousInputSource
    log.df("准备恢复之前输入来源: kind=%s, value=%s", tostring(old.kind), tostring(old.value))

    local ok = false
    if old.kind == "method" then
        ok = hs.keycodes.setMethod(old.value)
        log.df("恢复之前输入法 method: %s, 结果: %s", tostring(old.value), tostring(ok))
    elseif old.kind == "layout" then
        ok = hs.keycodes.setLayout(old.value)
        log.df("恢复之前键盘布局 layout: %s, 结果: %s", tostring(old.value), tostring(ok))
    else
        log.df("未知的输入来源类型，无法恢复: %s", hs.inspect(old))
    end

    previousInputSource = nil
end

local function scheduleRestorePreviousIME()
    cancelRestoreImeTimer()

    restoreImeTimer = hs.timer.doAfter(RESTORE_IME_DELAY, function()
        restoreImeTimer = nil
        log.df("延迟 %.2f 秒后，开始恢复之前输入法", RESTORE_IME_DELAY)
        restorePreviousIME()
    end)

    log.df("已安排 %.2f 秒后恢复之前输入法", RESTORE_IME_DELAY)
end

local function onLeftOptDown()
    if leftOptIsDown then
        log.df("左 Option 已处于按下状态，忽略重复事件")
        return
    end

    leftOptIsDown = true
    log.df("检测到左 Option 按下")

    -- 新一轮开始时，取消上一次尚未执行的恢复动作
    cancelRestoreImeTimer()

    switchToTargetIME()

    cancelCmdTimer()
    cmdPressTimer = hs.timer.doAfter(CMD_PRESS_DELAY, function()
        cmdPressTimer = nil

        if leftOptIsDown then
            log.df("延迟结束，左 Option 仍按着，按下左 Command 开始录音")
            pressLeftCmd()
        else
            log.df("延迟结束时左 Option 已松开，不再按下左 Command")
        end
    end)
end

local function onLeftOptUp()
    if not leftOptIsDown then
        log.df("左 Option 当前并非按下状态，忽略松开事件")
        return
    end

    leftOptIsDown = false
    log.df("检测到左 Option 松开")

    cancelCmdTimer()
    releaseLeftCmd()

    -- 延迟恢复原输入法
    scheduleRestorePreviousIME()
end

-- 监听左 Option 的 flagsChanged：按内部状态翻转，不依赖 flags.alt 的真假
local function handleLeftOptFlagsChanged(event)
    -- 忽略我们自己合成的左 Command 事件
    if synthesizingKey then
        return false
    end

    local keycode = event:getKeyCode()
    if keycode ~= KEYCODE_LEFT_OPTION then
        return false
    end

    if leftOptIsDown then
        onLeftOptUp()
    else
        onLeftOptDown()
    end

    return false
end

-- 避免回调异常导致 watcher 看起来"死掉"
local function safeEventHandler(event)
    local ok, result = xpcall(function()
        return handleLeftOptFlagsChanged(event)
    end, debug.traceback)

    if not ok then
        log.ef("eventtap 回调报错:\n%s", tostring(result))
        return false
    end

    return result
end

-- 放到全局，尽量避免 reload / GC 等边缘情况
_G.leftOptWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, safeEventHandler)
_G.leftOptWatcher:start()

alert.show("LeftOptIME 脚本已启动")
log.i(string.format("目标输入法: %s", TARGET_INPUT_SOURCE))
log.i(string.format("左 Option keycode=%d", KEYCODE_LEFT_OPTION))
log.i(string.format("恢复输入法延迟=%.2f 秒", RESTORE_IME_DELAY))
