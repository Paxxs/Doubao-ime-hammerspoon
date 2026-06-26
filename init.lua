-- ============================================
-- 右 Command 一键豆包语音输入（带诊断日志版）
-- 放到 ~/.hammerspoon/init.lua
--
-- 设计：脚本只负责【切输入法】，不碰语音触发。语音由豆包自己的 FN 触发。
--   按一下右 ⌘  -> 记住当前输入法，切到豆包
--   （此时你自己按 FN 唤起豆包语音、说话、再按 FN 结束）
--   再按一下右 ⌘ -> 切回原来的输入法
--
--   完整操作：右⌘(切豆包) → FN(开说) → 说话 → FN(停) → 右⌘(切回)
--
-- 为什么这么拆：豆包语音要求「按 FN 那一刻豆包已经是当前输入法」。
--   如果让同一个键既切输入法又触发语音，切换和触发抢在一起，豆包认不出。
--   拆成两个键后，FN 永远是在「已切到豆包之后」按的，和手动使用完全一样，所以稳。
--   右 ⌘（keycode 54）只用来切输入法；左 ⌘（55，日常快捷键）不受影响。
--
-- 诊断日志：
--   每次触发的完整上下文都会写到 ~/.hammerspoon/fn-doubao-voice.log。
--   出问题时直接看这个文件就能定位原因。
--   终端快速查看：  tail -n 50 ~/.hammerspoon/fn-doubao-voice.log
-- ============================================
require("hs.ipc") -- 开启命令行 hs，方便调试/验证

-- 豆包输入法（语音拼音模式）的 source id
local DOUBAO_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"

-- 兜底输入法：万一开始语音时没读到当前输入法，结束后切回这个
-- 默认微信输入法；用别的主输入法的话改这里
local FALLBACK_SOURCE_ID = "com.tencent.inputmethod.wetype.pinyin"

-- 守护式切回：豆包语音面板收尾时会把输入法“夺回”它自己，导致切不回原输入法。
-- 切回后在这个窗口内持续盯着，被夺走就立刻再夺回，直到豆包放手或窗口结束。
local RESTORE_GUARD_SECONDS = 1.5 -- 守护总时长
local RESTORE_GUARD_INTERVAL = 0.1 -- 每隔多久检查一次
local RESTORE_GUARD_STABLE = 0.5 -- 连续稳定这么久没被夺走，就提前收工

-- 触发键 keycode：54 = 右 Command。（左 Command 是 55，不会触发。）
-- 想换别的触发键改这里即可，但要和豆包里设的「语音唤起方式」保持一致。
local KEYCODE_TRIGGER = 54

-- ============================================
-- 诊断日志
-- ============================================
local LOG_FILE = os.getenv("HOME") .. "/.hammerspoon/fn-doubao-voice.log"
local LOG_MAX_BYTES = 512 * 1024 -- 超过就轮转一份 .1，避免无限增长

local hsLog = hs.logger.new("FnDoubaoVoice", "info") -- 同步一份到 HS 控制台

-- 带毫秒的时间戳，方便和“我刚才那一下”对上
local function nowStr()
    local t = hs.timer.secondsSinceEpoch()
    local whole = math.floor(t)
    local ms = math.floor((t - whole) * 1000)
    return os.date("%Y-%m-%d %H:%M:%S", whole) .. string.format(".%03d", ms)
end

local function rotateIfNeeded()
    local attrs = hs.fs.attributes(LOG_FILE)
    if attrs and attrs.size and attrs.size > LOG_MAX_BYTES then
        os.rename(LOG_FILE, LOG_FILE .. ".1")
    end
end

-- 统一日志出口：写文件 + 写控制台。绝不让日志本身抛错影响主流程
local function flog(level, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then
        msg = tostring(fmt)
    end

    local line = string.format("[%s] %-5s %s\n", nowStr(), level, msg)

    pcall(function()
        rotateIfNeeded()
        local f = io.open(LOG_FILE, "a")
        if f then
            f:write(line)
            f:close()
        end
    end)

    if level == "ERROR" then
        hsLog.e(msg)
    elseif level == "WARN" then
        hsLog.w(msg)
    else
        hsLog.i(msg)
    end
end

-- 当前最前台 App，是判断“焦点在哪/语音落到哪”的关键上下文
local function frontCtx()
    local app = hs.application.frontmostApplication()
    if not app then
        return "front=?(nil)"
    end
    return string.format("front=%s[%s]", tostring(app:name()), tostring(app:bundleID()))
end

-- ============================================
-- 状态
-- ============================================
local savedSourceID = nil -- 切到豆包前的原输入法，切回时用
local triggerHeld = false -- 右 ⌘ 是否按住中，用来去重（按下/抬起会各来一次 flagsChanged）

-- 记录脚本最近一次主动切换，用来在“输入法变化监听”里区分是脚本干的还是外部干的
local lastScriptSwitchTo = nil
local lastScriptSwitchAt = 0
local function noteScriptSwitch(target)
    lastScriptSwitchTo = target
    lastScriptSwitchAt = hs.timer.secondsSinceEpoch()
end

-- 守护定时器：放全局，reload 时能被清掉
local function cancelRestoreGuard()
    if _G.fnVoiceRestoreGuard then
        _G.fnVoiceRestoreGuard:stop()
        _G.fnVoiceRestoreGuard = nil
    end
end

-- 切回 target 后启动守护：窗口期内被豆包夺走就再夺回；稳定一段时间或超时就停。
-- noteSwitch 用来把“夺回”标记成脚本行为（避免被自己的输入法监听误判为外部）。
local function startRestoreGuard(target, noteSwitch)
    cancelRestoreGuard()
    local startAt = hs.timer.secondsSinceEpoch()
    local lastFlipAt = startAt
    local reasserts = 0

    _G.fnVoiceRestoreGuard = hs.timer.doEvery(RESTORE_GUARD_INTERVAL, function()
        local now = hs.timer.secondsSinceEpoch()
        local cur = hs.keycodes.currentSourceID()
        if cur ~= target then
            reasserts = reasserts + 1
            lastFlipAt = now
            noteSwitch(target)
            hs.keycodes.currentSourceID(target)
            flog("WARN", "  守护：被夺到 %s，已夺回 %s（第 %d 次）", tostring(cur), tostring(target), reasserts)
        elseif now - lastFlipAt >= RESTORE_GUARD_STABLE then
            -- 稳定住了，豆包放手了，提前收工
            cancelRestoreGuard()
            if reasserts > 0 then
                flog("INFO", "  守护结束：已稳定在 %s（共夺回 %d 次）", tostring(target), reasserts)
            end
            return
        end

        if now - startAt >= RESTORE_GUARD_SECONDS then
            cancelRestoreGuard()
            flog(cur == target and "INFO" or "WARN",
                "  守护超时结束：最终=%s（共夺回 %d 次）", tostring(cur), reasserts)
        end
    end)
end

-- 切到目标输入法，并“扣住”当前这枚右 ⌘ 几十毫秒做校验 + 补切，
-- 确认真的切过去了再放行。
--   背景：实测 hs.keycodes.currentSourceID(id) 会“假成功”（返回 true 但没切动），
--   且这种失败几乎只发生在「正处理触发键事件的回调里同步切换」时（约 1/3 概率）。
--   读回是诚实的、切换在 usleep 期间也能生效，所以这里短暂等待 + 校验 + 重试即可补稳。
-- 返回：是否最终命中、用了几次、总等待毫秒
local SWITCH_MAX_ATTEMPTS = 6
local SWITCH_WAIT_US = 10000 -- 没立刻切到时，每次重试前等 10ms
local function switchAndConfirm(target)
    -- 先切、立刻读回校验：命中就零延迟返回；没立刻切到（少见）才等一下再补切。
    local waitedMs = 0
    for attempt = 1, SWITCH_MAX_ATTEMPTS do
        noteScriptSwitch(target)
        hs.keycodes.currentSourceID(target)
        if hs.keycodes.currentSourceID() == target then
            return true, attempt, waitedMs
        end
        hs.timer.usleep(SWITCH_WAIT_US)
        waitedMs = waitedMs + SWITCH_WAIT_US / 1000
    end
    return hs.keycodes.currentSourceID() == target, SWITCH_MAX_ATTEMPTS, waitedMs
end

-- 把 source id 转成屏幕提示用的友好名字
local function friendlyName(id)
    if id == DOUBAO_SOURCE_ID then return "豆包" end
    if id == "com.tencent.inputmethod.wetype.pinyin" then return "微信" end
    if type(id) == "string" and id:find("keylayout.ABC") then return "ABC（英文）" end
    if type(id) == "string" and id:find("wetype") then return "微信" end
    return id or "原输入法"
end

-- 屏幕中央弹个短提示，每次切换给视觉反馈
local function toast(msg, seconds)
    hs.alert.closeAll(0) -- 清掉上一个，避免快速来回切时叠加
    hs.alert.show(msg, seconds or 1)
end

-- 切到豆包：记住当前输入法，切过去并校验。之后由用户自己按 FN 唤起豆包语音。
local function switchToDoubao()
    cancelRestoreGuard()

    local before = hs.keycodes.currentSourceID()
    savedSourceID = before

    -- 已经在豆包上，就别把豆包记成“原输入法”，否则切不回去
    local guarded = false
    if savedSourceID == nil or savedSourceID == DOUBAO_SOURCE_ID then
        savedSourceID = FALLBACK_SOURCE_ID
        guarded = true
    end

    local hit, attempts, waitedMs = switchAndConfirm(DOUBAO_SOURCE_ID)
    toast(hit and "🎤 豆包 · 按 FN 说话" or "⚠️ 切豆包失败", hit and 1.2 or 1.5)
    flog(hit and "INFO" or "WARN",
        "▶ 切到豆包 | %s | 原输入法=%s%s | 命中=%s（%d 次/扣%.0fms）| 现在按 FN 说话",
        frontCtx(), tostring(before),
        guarded and "(读到空/豆包，改用 FALLBACK)" or "",
        tostring(hit), attempts, waitedMs)

    -- 延迟读回，确认没被外部改回去（持续监控用）
    hs.timer.doAfter(0.12, function()
        local cur = hs.keycodes.currentSourceID()
        local stillOk = cur == DOUBAO_SOURCE_ID
        flog(stillOk and "DEBUG" or "WARN",
            "  切换校验 +120ms：当前=%s 仍在豆包=%s", tostring(cur), tostring(stillOk))
    end)
end

-- 切回原输入法（用户语音说完、按 FN 停掉之后再按右 ⌘）。
local function switchBack()
    local back = savedSourceID or FALLBACK_SOURCE_ID
    local hit, attempts, waitedMs = switchAndConfirm(back)
    toast("⌨️ 已切回 " .. friendlyName(back), 0.9)
    flog(hit and "INFO" or "WARN",
        "■ 切回 %s | %s | 命中=%s（%d 次/扣%.0fms）",
        tostring(back), frontCtx(), tostring(hit), attempts, waitedMs)
    -- 守护：万一豆包还想把输入法夺回去，窗口期内夺回来
    startRestoreGuard(back, noteScriptSwitch)
end

-- 右 ⌘ = 纯输入法开关，按现在“在不在豆包”来决定方向（读实时状态，不靠会和豆包错位的布尔）。
local function onTriggerDown()
    local cur = hs.keycodes.currentSourceID()
    if cur == DOUBAO_SOURCE_ID then
        flog("INFO", "右⌘↓ | 当前在豆包 ⇒ 切回原输入法 | %s", frontCtx())
        switchBack()
    else
        flog("INFO", "右⌘↓ | 当前=%s ⇒ 切到豆包 | %s", tostring(cur), frontCtx())
        switchToDoubao()
    end
end

-- 临时诊断开关：记录每一个 flagsChanged（含非触发键），
-- 用来判断“按了没反应”的那一下，事件到底有没有到达脚本、是不是 keycode=54。
-- 排查完可把它改回 false 降噪。
local DEBUG_ALL_FLAGS = false

local function handleFlagsChanged(event)
    local kc = event:getKeyCode()

    if DEBUG_ALL_FLAGS then
        local f = event:getFlags()
        flog("DEBUG", "flagsChanged: keycode=%s cmd=%s (期望右⌘=%d) | %s",
            tostring(kc), tostring(f.cmd and true or false), KEYCODE_TRIGGER, frontCtx())
    end

    if kc ~= KEYCODE_TRIGGER then
        return false
    end

    -- flagsChanged 报的是变化后的状态：右 ⌘ 按下时 cmd=true，抬起时 cmd=false
    local isDown = event:getFlags().cmd and true or false

    if isDown and not triggerHeld then
        triggerHeld = true
        onTriggerDown()
    elseif isDown and triggerHeld then
        -- 上一次抬起没收到，这次按下会被忽略 —— 这是“按了没反应”的一种成因
        flog("WARN", "右⌘↓ 但 triggerHeld 已为真（上一次抬起可能丢失），本次按下被忽略 | %s", frontCtx())
    elseif not isDown then
        triggerHeld = false
    end

    -- 关键：永远放行，绝不吞掉这枚右 ⌘
    return false
end

-- 包一层，避免回调异常导致 watcher 看起来“死掉”
local function safeHandler(event)
    local ok, result = xpcall(function()
        return handleFlagsChanged(event)
    end, debug.traceback)

    if not ok then
        flog("ERROR", "eventtap 回调报错:\n%s", tostring(result))
        return false
    end

    return result
end

-- ============================================
-- 事件监听 + 自愈看门狗
-- ============================================
-- 放到全局，尽量避免 reload / GC 等边缘情况
_G.fnVoiceWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, safeHandler)
_G.fnVoiceWatcher:start()

-- macOS 偶尔会因回调超时把 eventtap 杀掉，之后右 ⌘ 就彻底收不到了。
-- 看门狗定期检查，发现被禁用就自动重启并记录 —— 这一类故障会在日志里留痕。
cancelRestoreGuard() -- 清掉上次 reload 可能残留的守护定时器
if _G.fnVoiceWatchdog then
    _G.fnVoiceWatchdog:stop()
    _G.fnVoiceWatchdog = nil
end
_G.fnVoiceWatchdog = hs.timer.doEvery(5, function()
    if _G.fnVoiceWatcher and not _G.fnVoiceWatcher:isEnabled() then
        flog("WARN", "检测到 eventtap 被禁用（可能被系统因回调超时杀掉），自动重启")
        _G.fnVoiceWatcher:start()
    end
end)

-- 早先版本有个“切 App 自动结束会话”的监听，实测它会被 iShot 等工具的瞬时抢前台误触发，
-- 擅自把状态改了、和豆包错位，导致要按好几下。已移除——清理掉可能的残留。
if _G.fnVoiceAppWatcher then
    _G.fnVoiceAppWatcher:stop()
    _G.fnVoiceAppWatcher = nil
end

-- 决定性探针：监听“所有”输入法变化，区分是脚本切的还是外部（macOS/豆包/手动）切的。
-- 标“外部?!”的就是脚本之外有人在拽输入法 —— 这正是“切不过去/回不去”的元凶嫌疑。
local lastProbeSource = nil
hs.keycodes.inputSourceChanged(function()
    local cur = hs.keycodes.currentSourceID()
    -- 降噪：同一个值的重复上报直接跳过（既减少刷屏，也减轻主线程文件 IO）
    if cur == lastProbeSource then
        return
    end
    lastProbeSource = cur
    local dt = hs.timer.secondsSinceEpoch() - lastScriptSwitchAt
    local byScript = (cur == lastScriptSwitchTo and dt < 0.6)
    flog(byScript and "DEBUG" or "WARN",
        "⇄ 输入法变为 %s（%s）| %s",
        tostring(cur), byScript and "脚本" or "外部?!", frontCtx())
end)

-- ============================================
-- 启动横幅 + 一条会话起始标记，方便日志按 reload 分段
-- ============================================
hs.alert.show("右⌘ 输入法开关已启动（按右⌘切豆包/切回，语音用 FN）")
flog("INFO", "==== 配置已加载 | 豆包=%s | 兜底=%s | 当前输入法=%s ====",
    DOUBAO_SOURCE_ID, FALLBACK_SOURCE_ID,
    tostring(hs.keycodes.currentSourceID()))
