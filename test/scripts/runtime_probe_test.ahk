#Requires AutoHotkey v2.0
#ErrorStdOut "UTF-8"
#Warn All, Off

; 运行期冒烟测试：钩子健康探针（HookHealth）与热键回调链路

#Include ../../src/lib/base/logger.ahk
#Include ../../src/lib/base/version.ahk
#Include ../../src/lib/base/message_box.ahk
#Include ../../src/lib/base/single_instance.ahk
#Include ../../src/lib/base/token_protector.ahk
#Include ../../src/lib/base/hotkey_schema.ahk
#Include ../../src/lib/base/constants.ahk
#Include ../../src/lib/base/config.ahk
#Include ../../src/lib/base/theme.ahk
#Include ../../src/lib/base/eventbus.ahk
#Include ../../src/lib/base/i18n.ahk
#Include ../../src/lib/base/changelog_format.ahk
#Include ../../src/lib/base/metrics.ahk
#Include ../../src/lib/base/locales/zh_hans.ahk
#Include ../../src/lib/base/locales/ja_jp.ahk
#Include ../../src/lib/base/locales/ko_kr.ahk
#Include ../../src/lib/base/locales/en_us.ahk
#Include ../../src/lib/base/locales/zh_hant.ahk
#Include ../../src/lib/base/server_profile.ahk
#Include ../../src/lib/base/game_target.ahk
#Include ../../src/lib/base/file_extractor.ahk
#Include ../../src/lib/base/timing.ahk
#Include ../../src/lib/base/window.ahk
#Include ../../src/lib/base/key_format.ahk
#Include ../../src/lib/base/tray.ahk
#Include ../../src/lib/base/version_utils.ahk
#Include ../../src/lib/base/touch_injection.ahk
#Include ../../src/lib/base/custom_hotkey_store.ahk
#Include ../../src/lib/core/game/game_client_registry.ahk
#Include ../../src/lib/core/diagnostics/log_exporter.ahk
#Include ../../src/lib/core/diagnostics/hook_health.ahk
#Include ../../src/lib/core/launch/app_context.ahk
#Include ../../src/lib/core/launch/game_auto_start.ahk
#Include ../../src/lib/core/hotkey/timing_service.ahk
#Include ../../src/lib/core/hotkey/game_keys.ahk
#Include ../../src/lib/core/hotkey/hotkey_actions.ahk
#Include ../../src/lib/core/hotkey/custom_script.ahk
#Include ../../src/lib/core/monitor/level_detector.ahk
#Include ../../src/lib/ui/key_bind.ahk
#Include ../../src/lib/core/hotkey/hotkey_service.ahk
#Include ../../src/lib/core/settings/hotkey_conflict_validator.ahk
#Include ../../src/lib/core/settings/settings_service.ahk
#Include ../../src/lib/core/updater/github_token_service.ahk
#Include ../../src/lib/core/updater/release_repository.ahk
#Include ../../src/lib/core/updater/version_checker.ahk
#Include ../../src/lib/core/updater/downloader.ahk
#Include ../../src/lib/core/updater/self_replacer.ahk
#Include ../../src/lib/core/updater/updater_manager.ahk
#Include ../../src/lib/ui/updater_ui.ahk
#Include ../../src/lib/core/launch/game_launcher.ahk
#Include ../../src/lib/ui/changelog_ui.ahk
#Include ../../src/lib/core/changelog/changelog_checker.ahk
#Include ../../src/lib/ui/status_bar.ahk
#Include ../../src/lib/ui/gui.ahk
#Include ../../src/lib/ui/custom_key_editor.ahk
#Include ../../src/lib/core/monitor/game_monitor.ahk

; SAMPLE=采样载体
global SAMPLE_VK := 0x83         ; F20
global SAMPLE_KEY := "f20"
global REG_VK := 0x77            ; F8
global REG_KEY := "f8"
global REG_HK := "^F8"

global PassCount := 0
global FailCount := 0
global FiredCount := 0

Say(line) {
    FileAppend(line "`n", "*")
}

Ok(label) {
    global PassCount
    PassCount++
    Say("[ok]   " label)
}

Bad(label, detail := "") {
    global FailCount
    FailCount++
    Say("[FAIL] " label (detail = "" ? "" : " | " detail))
}

Eq(label, actual, expected, detail := "") {
    if (String(actual) = String(expected))
        Ok(label)
    else
        Bad(label, "期望=" expected " 实际=" actual (detail = "" ? "" : " | " detail))
}

Truthy(label, value, detail := "") {
    if (value)
        Ok(label)
    else
        Bad(label, detail)
}

FakeAction(*) {
    global FiredCount
    FiredCount++
}

ProbeReset() {
    HookHealth._PrevDown := Map()
    HookHealth._Pending := Map()
    HookHealth._LastUpEdge := Map()
    HookHealth._LastPressEdge := Map()
    HookHealth._LastFireTick := Map()
    HookHealth._FireByKey := Map()
    HookHealth._LastWarnTick := Map()
    HookHealth._ProbeStats := Map()
    HookHealth._Depth := 0
    HookHealth._MissTotal := 0
    HookHealth._MissStreak := 0
}

SampleDiag() {
    isDown := (DllCall("GetAsyncKeyState", "Int", SAMPLE_VK, "Short") & 0x8000) != 0
    return "isDown=" (isDown ? "true" : "false")
        . " ShouldArm=" (HookHealth._ShouldArm(SAMPLE_KEY) ? "true" : "false")
        . " Injected=" (GameKeys.IsInjectedPressPending(SAMPLE_KEY) ? "true" : "false")
        . " PrevDown=" (HookHealth._PrevDown.Has(SAMPLE_VK) && HookHealth._PrevDown[SAMPLE_VK] ? "true" : "false")
}

ProbeStatsOf(pureKey) {
    return HookHealth._ProbeStats.Has(pureKey) ? HookHealth._ProbeStats[pureKey] : ""
}

ProbeBar(stats, field) {
    return stats = "" ? 0 : stats.%field%
}

; 采样前必须同时满足：_PrevDown 为空（否则不进按下沿分支，断言会以"全 0"假性通过）、
; 自注入标记已清（否则 _ShouldArm 恒为 false）
PreparePhysicalPress() {
    HookHealth._PrevDown := Map()
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
    GameKeys.InjectedPressKeys := Map()
}

SendProbeDown() {
    prevLevel := SendLevel(1)
    SendEvent "{F20 Down}"
    SendLevel(prevLevel)
}

SendProbeUp() {
    prevLevel := SendLevel(1)
    SendEvent "{F20 Up}"
    SendLevel(prevLevel)
}

; 抬起 → 采样（刷新抬起基准）→ 清按下沿状态
ReleaseProbeKey() {
    SendProbeUp()
    Sleep 120
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
    HookHealth._PrevDown := Map()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    Sleep 60
}

; 造一条已过宽限期的挂起观测；arm 计数必须一并补上，否则自证不变式会被测试自身破坏
ArmStale(pureKey, vk, fireSnapshot := 0, fgHwnd := 0, graceExtraMs := 200) {
    if (fgHwnd = 0)
        fgHwnd := HookHealth._ForegroundHwnd()
    HookHealth._Pending := Map(vk, {tick: A_TickCount - HookHealth.PendingGraceMs - graceExtraMs
        , key: pureKey, idleKbd: 0, fire: fireSnapshot, fgHwnd: fgHwnd})
    HookHealth._BumpProbe(pureKey, "arm")
}

; 符号存在性只能靠动态解引用判：Func("名字") 对不存在的名字抛 Invalid base，
; 而直接书写未定义标识符、或给函数传错参数个数都是加载期错误（try 捕不到）。
; 另注：Func 对象也有 HasMethod() 且恒为 false，必须用 Type() 区分类与函数。
CheckGlobalSymbols(refs) {
    for ref in refs {
        dotPos := InStr(ref, ".", true)          ; 必须区分大小写：默认不区分会把小写 y/k 当点号
        name := dotPos ? SubStr(ref, 1, dotPos - 1) : ref
        symbol := dotPos ? SubStr(ref, dotPos + 1) : ""
        try {
            holder := %name%
        } catch {
            Bad("符号 " ref, "标识符未定义（动态解引用即抛错）")
            continue
        }
        if (symbol = "") {
            Ok("全局函数 " ref)
            continue
        }
        if (Type(holder) = "Class") {
            if holder.HasMethod(symbol)
                Ok("类方法 " ref)
            else
                Bad("类方法 " ref, "类存在但没有该方法")
            continue
        }
        Bad("符号 " ref, Type(holder) " 没有成员 " symbol)
    }
}

HasMethodInSource(relPaths, memberName) {
    for relPath in relPaths {
        text := FileExist(relPath) ? FileRead(relPath, "UTF-8") : ""
        if (text != "" && InStr(text, "static " memberName "("))
            return true
    }
    return false
}

; 源码级方法存在性：守住"方法群被整段删除"（运行时反射覆盖不到未被触发的路径，如 _Poll）
CheckSourceMethods(members, relPaths) {
    for member in members {
        if HasMethodInSource(relPaths, member)
            Ok("源码方法 HookHealth." member)
        else
            Bad("源码方法 HookHealth." member, "源码里找不到 `static " member "(`——疑似方法被删")
    }
}

; 自证不变式：每次建档最终落进 cleared/miss/discard/watchDrop，或仍挂在 _Pending 未结算；
; 同键告警冷却期内的挂起项按设计既不结算也不移除，也算合法未结算。
CheckProbeInvariant(context) {
    totalArm := 0, totalSettled := 0
    for _, stats in HookHealth._ProbeStats {
        totalArm += stats.arm
        totalSettled += stats.cleared + stats.miss + stats.discard + stats.watchDrop
    }
    unsettled := totalArm - totalSettled
    if (unsettled < 0) {
        Bad("自证不变式（" context "）", "已结算计数之和超过建档数：arm=" totalArm " settled=" totalSettled
            . " 快照=" HookHealth._ProbeSnapshot())
        return
    }
    cooldownHeld := 0
    now := A_TickCount
    for vk, info in HookHealth._Pending {
        lastWarn := HookHealth._LastWarnTick.Get(info.key, 0)
        if (lastWarn != 0 && now - lastWarn < HookHealth.MissWarnCooldownMs)
            cooldownHeld++
    }
    allowed := HookHealth._Pending.Count + cooldownHeld
    if (unsettled > allowed) {
        Bad("自证不变式（" context "）", "有观测只记账却不结算：未结算=" unsettled
            . " 允许=" allowed "（挂起项=" HookHealth._Pending.Count " 冷却节流=" cooldownHeld "）"
            . " 快照=" HookHealth._ProbeSnapshot())
        return
    }
    Ok("自证不变式（" context "）：arm=" totalArm " 已结算=" totalSettled
        . " 未结算=" unsettled "（挂起项=" HookHealth._Pending.Count " 冷却节流=" cooldownHeld "）")
}

try {
    ; ---- 0. 环境就绪 -----------------------------------------------------------
    GameKeys.Init()
    HotkeyService.Init()
    HookHealth.Start()
    Eq("探针已启动（定时器已设置）", HookHealth._Timer != "" ? "true" : "false", "true")
    Eq("快捷键常量已装载", HotkeyService.ActiveHotkeys.Count, 0, "启动时不应有已注册热键")

    ; 采样载体若无法注入，后续采样断言会全部退化成假性通过，故先卡住
    SendProbeDown()
    Sleep 60
    probeDown := (DllCall("GetAsyncKeyState", "Int", SAMPLE_VK, "Short") & 0x8000) != 0
    SendProbeUp()
    Sleep 60
    Truthy("采样载体可注入且可被 GetAsyncKeyState 观测（" SAMPLE_KEY "）", probeDown
        , "请改用 F13~F24 区间中本机可用的键")

    fgHwnd := DllCall("GetForegroundWindow", "Ptr")
    fgPid := 0
    DllCall("GetWindowThreadProcessId", "Ptr", fgHwnd, "UInt*", &fgPid)
    GameTarget.Bind(fgHwnd, fgPid, A_ScriptFullPath, "Unknown")
    Truthy("游戏目标已绑定（采样建档的前提）", GameTarget.IsForegroundCached())

    ; ---- 1. 符号与源码方法存在性 -----------------------------------------------
    CheckGlobalSymbols(["IsMouseKey", "IsMouseInClient", "Qpc", "QpcMs"
        , "HotkeyContext"
        , "HookHealth.Start", "HookHealth.NoteFire", "HookHealth.FireTotal"
        , "HookHealth.EnterAction", "HookHealth.ExitAction", "HookHealth.RefreshWatchKeysNow"
        , "HookHealth._SamplePhysicalKeys", "HookHealth._ShouldArm", "HookHealth._ResolvePending"
        , "HookHealth._IsWatchedKey", "HookHealth._ForegroundHwnd"
        , "HookHealth._ProbeSnapshot", "HookHealth._ProbeKeyStats", "HookHealth._BumpProbe"
        , "KeyForward.PureKeyName", "GameTarget.IsForegroundCached", "GameKeys.Init"])
    CheckSourceMethods(["Start", "NoteFire", "FireTotal", "EnterAction", "ExitAction"
        , "_ClearPendingFor", "_ShouldArm", "_Poll", "_SamplePhysicalKeys"
        , "_ResolvePending", "_Report", "_Snapshot", "_RebuildWatchKeys", "RefreshWatchKeysNow"
        , "_WatchKeyNames", "_InFlightNames", "_KeyList"]
        , ["../../src/lib/core/diagnostics/hook_health.ahk"])

    ; ---- 2. 回调链路 -----------------------------------------------------------
    fireBefore := HookHealth.FireTotal()
    HookHealth.NoteFire(SAMPLE_KEY)
    Eq("NoteFire 递增回调总数", HookHealth.FireTotal(), fireBefore + 1)
    Eq("NoteFire 按键级计数", HookHealth._FireByKey.Get(SAMPLE_KEY, -1), 1)
    Truthy("NoteFire 记录回调时刻", HookHealth._LastFireTick.Get(SAMPLE_KEY, 0) > 0)

    probeSeq := HookHealth.EnterAction("ProbeAction", SAMPLE_KEY)
    Eq("EnterAction 递增在飞深度", HookHealth._Depth, 1)
    Eq("EnterAction 登记在飞线程", HookHealth._InFlight.Count, 1)
    HookHealth.ExitAction(probeSeq)
    Eq("ExitAction 归零深度", HookHealth._Depth, 0)
    Eq("ExitAction 清空在飞线程", HookHealth._InFlight.Count, 0)

    totalBefore := HookHealth.FireTotal()
    HookHealth.NoteFire("")
    Eq("NoteFire 忽略空键名", HookHealth.FireTotal(), totalBefore)

    ; ---- 3. 键位监视表与即时刷新 ------------------------------------------------
    HookHealth.RefreshWatchKeysNow()
    Eq("监视表与已注册热键同源", HookHealth._WatchKeys.Count, HotkeyService.ActiveHotkeys.Count
        , "监视键位=[" HookHealth._WatchKeyNames() "] 热键数=" HotkeyService.ActiveHotkeys.Count)

    HotIf(HotkeyContext)
    pattern := GameKeys.GetInterceptPattern()
    HookHealth._ProbeWatchPattern := pattern
    HotkeyService._RegisterOne(REG_HK, {Fn: FakeAction}, pattern)     ; 生产注册路径
    HookHealth.RefreshWatchKeysNow()
    Truthy("注册后监视表包含探测键", HookHealth._IsWatchedKey(REG_KEY)
        , "监视键位=[" HookHealth._WatchKeyNames() "]")
    registered := REG_HK ~= pattern ? REG_HK : "~" REG_HK
    Eq("ActiveHotkeys 记为探测键", HotkeyService.ActiveHotkeys.Get(registered, ""), registered)
    HotIf

    ; ---- 4. 抬起基准：必须跟随每次采样到抬起，而非仅在观测到跳变时记 ------------
    ; 挂在跳变上会漏记 → _LastUpEdge 冻结 → 之后每次按下都判成"已处理" → arm 恒为 0，探针静默失效
    ReleaseProbeKey()
    ProbeReset()
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
    HookHealth._SamplePhysicalKeys(A_TickCount)          ; 此刻按键是抬起的
    Truthy("抬起时采样会刷新 _LastUpEdge", HookHealth._LastUpEdge.Has(SAMPLE_KEY))

    ; ---- 5. 竞态判据：三种情形 --------------------------------------------------
    ; ① 回调新鲜 + 尚未观测到抬起 ⇒ 跳过（否则快速点按会误报"未触发"）
    ReleaseProbeKey()
    ProbeReset()
    PreparePhysicalPress()
    HookHealth._LastUpEdge[SAMPLE_KEY] := A_TickCount - 2000
    HookHealth._LastFireTick[SAMPLE_KEY] := A_TickCount - 100
    SendProbeDown()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    stats := ProbeStatsOf(SAMPLE_KEY)
    Eq("①回调新鲜时跳过建档 raceSkip", ProbeBar(stats, "raceSkip"), 1, SampleDiag())
    Eq("①回调新鲜时不建档 arm", ProbeBar(stats, "arm"), 0)

    ; ② 回调已过期（超出竞态窗口）⇒ 必须建档，否则钩子真失效会被掩盖
    ReleaseProbeKey()
    ProbeReset()
    PreparePhysicalPress()
    HookHealth._LastUpEdge[SAMPLE_KEY] := A_TickCount - 20000
    HookHealth._LastFireTick[SAMPLE_KEY] := A_TickCount - 5000
    SendProbeDown()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    stats := ProbeStatsOf(SAMPLE_KEY)
    Eq("②回调过期时仍建档 arm", ProbeBar(stats, "arm"), 1
        , "raceSkip=" ProbeBar(stats, "raceSkip"))

    ; ③ 回调早于观测到的抬起（正常新按下）⇒ 必须建档
    ReleaseProbeKey()
    ProbeReset()
    PreparePhysicalPress()
    HookHealth._LastUpEdge[SAMPLE_KEY] := A_TickCount - 50
    HookHealth._LastFireTick[SAMPLE_KEY] := A_TickCount - 5000
    SendProbeDown()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    stats := ProbeStatsOf(SAMPLE_KEY)
    Eq("③正常新按下时建档 arm", ProbeBar(stats, "arm"), 1, SampleDiag())

    ; 持续按住不得重复建档
    ProbeReset()
    HookHealth._LastFireTick[SAMPLE_KEY] := A_TickCount - 5000
    HookHealth._SamplePhysicalKeys(A_TickCount)          ; 按下沿
    Eq("按住首轮建档 arm", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "arm"), 1)
    HookHealth._SamplePhysicalKeys(A_TickCount)          ; 仍按住
    Eq("按住期间不重复建档 arm", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "arm"), 1)
    SendProbeUp()
    Sleep 120
    HookHealth._PrevDown := Map()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    Sleep 60

    ; ---- 6. 结算复核：各作废/命中路径 -------------------------------------------
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 5
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 4)                   ; fire 快照=4 < 当前 5 ⇒ 迟到命中
    HookHealth._ResolvePending(A_TickCount)
    Eq("④迟到命中不记 miss", HookHealth._MissTotal, 0)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    HookHealth._WatchKeys := Map()                       ; 模拟该键已注销
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑤键已注销记 watchDrop", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "watchDrop"), 1)
    Eq("⑤键已注销不记 miss", HookHealth._MissTotal, 0)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
    HookHealth._LastWarnTick := Map()
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑤b键盘键照常判定 miss", HookHealth._MissTotal, 1)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0, HookHealth._ForegroundHwnd() + 1)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑥切窗作废记 discard", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "discard"), 1)
    Eq("⑥切窗不记 miss", HookHealth._MissTotal, 0)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0, 0, -HookHealth.PendingGraceMs + 100)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑦宽限期内不结算", HookHealth._Pending.Count, 1)

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    HookHealth._Depth := 1                               ; 同键重入被 MaxThreadsPerHotkey 屏蔽
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑧动作在飞时不结算", HookHealth._Pending.Count, 1)
    HookHealth._Depth := 0

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    HookHealth._LastWarnTick := Map()
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑨前提成立记 miss", HookHealth._MissTotal, 1)
    Eq("⑨挂起项被清理", HookHealth._Pending.Count, 0)
    Truthy("⑨写入告警冷却时间戳", HookHealth._LastWarnTick.Has(SAMPLE_KEY))
    Eq("⑨自证 miss 计数", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "miss"), 1)
    CheckProbeInvariant("结算复核后")

    ProbeReset()
    HookHealth._FireByKey[SAMPLE_KEY] := 0
    HookHealth._LastWarnTick := Map(SAMPLE_KEY, A_TickCount)
    ArmStale(SAMPLE_KEY, SAMPLE_VK, 0)
    HookHealth._ResolvePending(A_TickCount)
    Eq("⑩冷却期内不重复计数", HookHealth._MissTotal, 0)

    ; ---- 7. 鼠标键光标前提（必须真的走到 IsMouseKey 那一行）---------------------
    Eq("IsMouseKey 识别鼠标键", IsMouseKey("xbutton2") ? "true" : "false", "true")
    Eq("IsMouseKey 不误判键盘键", IsMouseKey("f") ? "true" : "false", "false")

    ; IsMouseInClient 取真实鼠标位置、无注入点，故按当前前置分别断言
    ProbeReset()
    HookHealth._FireByKey["xbutton2"] := 0
    HookHealth._LastWarnTick := Map()
    HookHealth._WatchKeys := Map(0x06, "xbutton2")
    ArmStale("xbutton2", 0x06, 0)
    HookHealth._ResolvePending(A_TickCount)
    if IsMouseInClient() {
        Eq("⑪光标在客户区：鼠标键正常判 miss", HookHealth._MissTotal, 1
            , "probe=" HookHealth._ProbeSnapshot())
    } else {
        Eq("⑪光标不在客户区：鼠标键作废为 discard", ProbeBar(ProbeStatsOf("xbutton2"), "discard"), 1
            , "probe=" HookHealth._ProbeSnapshot())
        Eq("⑪光标不在客户区：不误报 miss", HookHealth._MissTotal, 0)
    }
    CheckProbeInvariant("鼠标键路径后")

    ; ---- 8. 连续采样下的建档行为 -----------------------------------------------
    ; 单次调用正常不代表连续采样正常（抬起基准就是这样静默失效的）。
    ; 每轮独立记账并在轮内结算，避免脚手架互相覆盖挂起表。
    loop 3 {
        n := A_Index
        ProbeReset()
        ReleaseProbeKey()
        HookHealth._FireByKey[SAMPLE_KEY] := 0
        HookHealth._LastFireTick[SAMPLE_KEY] := A_TickCount - 5000
        HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
        GameKeys.InjectedPressKeys := Map()
        SendProbeDown()
        HookHealth._SamplePhysicalKeys(A_TickCount)
        Eq("⑫连续采样第 " n " 轮建档 arm", ProbeBar(ProbeStatsOf(SAMPLE_KEY), "arm"), 1)
        HookHealth._ResolvePending(A_TickCount + HookHealth.PendingGraceMs + 1000)
        CheckProbeInvariant("连续采样第 " n " 轮后")
        SendProbeUp()
        Sleep 120
    }
    HookHealth._WatchKeys := Map(SAMPLE_VK, SAMPLE_KEY)
    HookHealth._PrevDown := Map()
    HookHealth._SamplePhysicalKeys(A_TickCount)
    ProbeReset()
    CheckProbeInvariant("连续采样收尾后")

    FileAppend("PASS: runtime probe checks (" PassCount " passed)`n", "*", "UTF-8")
    ExitApp 0
} catch as err {
    RuntimeFailure(err)
}

RuntimeFailure(err, *) {
    message := "FAIL: " err.Message " (line " err.Line ")`n"
    try FileAppend(message, "**", "UTF-8")
    try FileAppend(message, A_Temp "\AFA-runtime-probe-test-error.txt", "UTF-8")
    ExitApp 1
}
