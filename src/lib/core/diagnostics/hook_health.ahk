; == 键盘钩子存活探针与自愈 ==
; 手法：用不依赖钩子的 GetAsyncKeyState 采样热键键位的物理按下，与依赖钩子的回调计数（NoteFire）
; 对照——物理按下却在宽限期内无同键回调即记一次未命中，连续多次判定钩子失效，落快照并按需自愈。
IsMouseKey(pureKey) {
    return pureKey ~= "i)^(lbutton|rbutton|mbutton|xbutton1|xbutton2|wheel)"
}

class HookHealth {
    ; ---- 可调参数 ----
    static PollIntervalMs := 100      ; 物理按键采样间隔
    static ReportIntervalMs := 5000   ; 异常期状态快照上报间隔
    static HeartbeatMs := 60000       ; 正常期心跳快照间隔（保留基线，便于事后比对三值是否恒等）
    static PendingGraceMs := 3000     ; 物理按下后等待同键回调的宽限。必须覆盖完整触发路径
                                      ; （失焦悬停的激活等待 + 最长一组过帧 + 采样余量），过短会误判未触发
    static MissWarnCooldownMs := 5000 ; 同键告警节流，避免按住连打时按一次刷一条
    static MissThreshold := 5         ; 连续多少次未命中判定为钩子失效（过高则真失效时按键多次才自愈）
    static FireRaceWindowMs := 250    ; 竞态窗口：探针采样晚于钩子回调，此窗口内已回调的按下视为命中、不建档
    static WatchRefreshMs := 5000     ; 监视键位表刷新间隔
    static RecoverCooldownMs := 30000 ; 两次自愈的最小间隔。重装会抢占其它进程钩子的优先级，
                                      ; 若真实原因是输入被前置钩子吞掉，反复自愈只会搅乱冲突，故压低频率
    static AutoRecover := true        ; 已确认故障模式为钩子被系统摘除，默认开启自愈

    ; ---- 运行时状态 ----
    static _Timer := ""
    static _WatchKeys := Map()        ; vk -> pureKey
    static _PrevDown := Map()         ; vk -> true/false
    static _Pending := Map()          ; vk -> {tick, key, idleKbd, fire}
    static _FireByKey := Map()        ; pureKey -> 该键热键回调累计次数
    static _FireTotal := 0            ; 全部热键回调累计次数
    static _LastFireTick := Map()     ; pureKey -> 该键最近一次回调时刻
    static _LastUpEdge := Map()       ; pureKey -> 该键最近一次"被采样到抬起"的时刻
    static _LastPressEdge := Map()    ; pureKey -> 该键最近一次被采样到按下沿的时刻
    static _LastWarnTick := Map()     ; pureKey -> 该键最近一次"未触发告警"时刻
    static _MissStreak := 0
    static _MissTotal := 0
    static _Depth := 0                ; 当前在执行的动作线程数
    static _MaxDepth := 0
    static _InFlight := Map()         ; seq -> {name, key, tick}
    static _Seq := 0
    static _NextReportTick := 0
    static _NextWatchTick := 0
    static _LastRecoverTick := 0
    static _RecoverCount := 0
    static _Suspected := false
    static _Started := false
    ; ---- 探针自证计数（按纯键名累计）----
    ; arm 建档 / raceSkip 跳过 / cleared 回调清掉 / miss 超时未触发 / discard 前提失效 / watchDrop 键已注销
    ; 判读式：arm ≈ cleared + miss + discard + watchDrop
    static _ProbeStats := Map()

    static _BumpProbe(pureKey, field) {
        if !this._ProbeStats.Has(pureKey)
            this._ProbeStats[pureKey] := {arm: 0, raceSkip: 0, cleared: 0, miss: 0, discard: 0, watchDrop: 0}
        stats := this._ProbeStats[pureKey]
        stats.%field% += 1
    }

    static _ProbeKeyStats(pureKey) {
        if !this._ProbeStats.Has(pureKey)
            return "arm=0,cleared=0"
        stats := this._ProbeStats[pureKey]
        return "arm=" stats.arm ",raceSkip=" stats.raceSkip ",cleared=" stats.cleared
            . ",miss=" stats.miss ",discard=" stats.discard ",watchDrop=" stats.watchDrop
    }

    static _ProbeSnapshot() {
        parts := ""
        for key, stats in this._ProbeStats {
            parts .= (parts = "" ? "" : " ") key "(arm=" stats.arm ",raceSkip=" stats.raceSkip
                . ",cleared=" stats.cleared ",miss=" stats.miss ",discard=" stats.discard
                . ",watchDrop=" stats.watchDrop ")"
        }
        return (parts = "" ? "(无)" : parts)
    }

    ; 该纯键名当前是否仍在监视表里（表是 vk -> pureKey，故按键名反查）
    static _IsWatchedKey(pureKey) {
        for _, watchedKey in this._WatchKeys {
            if (watchedKey = pureKey)
                return true
        }
        return false
    }

    ; 当前前台窗口句柄（建档时留档，结算时比对：换过窗口就作废该次观测）
    static _ForegroundHwnd() {
        return DllCall("GetForegroundWindow", "Ptr")
    }

    ; 启动探针（由 App.Bootstrap 在 HotkeyOn 之后调用，保证 ActiveHotkeys 已就绪）
    static Start() {
        if (this._Started)
            return
        this._Started := true
        this._RebuildWatchKeys()
        if (this._Timer = "")
            this._Timer := HookHealth._Poll.Bind(HookHealth)
        SetTimer this._Timer, this.PollIntervalMs
        Logger.Info("HookHealth", "钩子健康探针已启动，采样=" this.PollIntervalMs "ms，监视键位=" this._WatchKeyNames())
    }

    ; 热键回调发生（任何一次进入热键线程都应调用），供物理按下对照。
    ; pureKey 必传：命中判定只看同键回调，否则别的键触发会被误记为本次命中的证据
    static NoteFire(pureKey) {
        if (pureKey == "")
            return
        this._FireTotal++
        this._FireByKey[pureKey] := this._FireByKey.Get(pureKey, 0) + 1
        this._LastFireTick[pureKey] := A_TickCount
        ; 同键回调既然已经真实发生，立即结算并清掉该键挂起的按键，绝不误报为未触发
        if (this._ClearPendingFor(pureKey))
            this._BumpProbe(pureKey, "cleared")
        if (this._Suspected)
            this._NoteHit()
    }

    static FireTotal() {
        return this._FireTotal
    }

    ; 动作线程进入：返回句柄，调用方必须在 finally 里 ExitAction(句柄)；pureKey 仅供快照展示
    static EnterAction(name, pureKey) {
        this.NoteFire(pureKey)
        seq := ++this._Seq
        this._InFlight[seq] := {name: name, key: pureKey, tick: A_TickCount}
        this._Depth++
        if (this._Depth > this._MaxDepth)
            this._MaxDepth := this._Depth
        return seq
    }

    ; 动作线程退出
    static ExitAction(seq) {
        if (this._InFlight.Has(seq))
            this._InFlight.Delete(seq)
        if (this._Depth > 0)
            this._Depth--
    }

    ; 某键发生真实回调：移除该键全部挂起观测，返回是否确实清掉了（供自证计数）
    static _ClearPendingFor(pureKey) {
        if (this._Pending.Count = 0)
            return false
        stale := []
        for vk, info in this._Pending {
            if (info.key = pureKey)
                stale.Push(vk)
        }
        if (stale.Length = 0)
            return false
        for vk in stale
            this._Pending.Delete(vk)
        return true
    }

    ; ---- 采样主循环 ----
    static _Poll() {
        now := A_TickCount
        ; 立即刷新会把 _NextWatchTick 推后，故用 > 0 判定是否已安排
        if (this._NextWatchTick > 0 && now >= this._NextWatchTick) {
            this._NextWatchTick := 0
            this._RebuildWatchKeys()
        }
        this._SamplePhysicalKeys(now)
        this._ResolvePending(now)
        if (now >= this._NextReportTick) {
            this._NextReportTick := now + (this._Suspected ? this.ReportIntervalMs : this.HeartbeatMs)
            this._Report()
        }
    }

    ; 采样物理按下沿。GetAsyncKeyState 由系统维护、不经过本进程钩子，故"钩子已死但按键仍在"可被观测
    static _SamplePhysicalKeys(now) {
        for vk, pureKey in this._WatchKeys {
            isDown := (DllCall("GetAsyncKeyState", "Int", vk, "Short") & 0x8000) != 0
            wasDown := this._PrevDown.Has(vk) && this._PrevDown[vk]
            this._PrevDown[vk] := isDown
            if (!isDown) {
                ; 只要这次采样看到按键是抬起的，就刷新抬起时刻，作为新一次按下的判据基准
                if (wasDown)
                    this._LastUpEdge[pureKey] := now
                continue
            }
            if (wasDown)
                continue
            ; 新的物理按下沿：只在"本应触发热键"的条件下建档，避免误报
            if (!this._ShouldArm(pureKey))
                continue
            ; 该键刚回调过、且此后没见过它抬起 ⇒ 本次按下的回调已先于采样执行，不建档
            lastUp := this._LastUpEdge.Get(pureKey, 0)
            this._LastPressEdge[pureKey] := now
            lastFire := this._LastFireTick.Get(pureKey, 0)
            if (lastFire != 0 && lastFire > lastUp && now - lastFire < this.FireRaceWindowMs) {
                this._BumpProbe(pureKey, "raceSkip")
                continue
            }
            ; fire：按下瞬间的回调计数快照（结算按计数差判定，不能用 Has——历史触发过就永远为真）；
            ; fgHwnd：留档前台窗口供结算比对；idleKbd 仅备查（判定钩子存活要看快照三值是否恒等）
            this._Pending[vk] := {tick: now, key: pureKey, idleKbd: A_TimeIdleKeyboard
                , fire: this._FireByKey.Get(pureKey, 0), fgHwnd: this._ForegroundHwnd()}
            this._BumpProbe(pureKey, "arm")
        }
    }

    ; 是否把这次物理按下计入观测：游戏须为前台，且不是 AFA 自己注入或正在补发 up 的按键
    static _ShouldArm(pureKey) {
        if (!GameTarget.IsForegroundCached())
            return false
        if (GameKeys.IsInjectedPressPending(pureKey))
            return false
        if (KeyForward.SuppressUp.Has(pureKey))
            return false
        return true
    }

    ; 结算挂起的物理按下：宽限期已过且确认没有同键回调才算"未触发"。
    ; 告警冷却记在键级持久表 _LastWarnTick（不随 _Pending 销毁），同键冷却期内不重复告警。
    static _ResolvePending(now) {
        if (this._Pending.Count = 0)
            return
        settled := []
        for vk, info in this._Pending {
            if (now - info.tick < this.PendingGraceMs)
                continue
            ; 计数比按下时刻增长 = 宽限期内确有该键回调（迟到命中，如失焦悬停激活耗时较长）⇒ 不记未命中
            if (this._FireByKey.Get(info.key, 0) > info.fire) {
                settled.Push(vk)
                continue
            }
            ; 该键已不在监视表（热键被禁用/分组注销）⇒ 没有回调是正确的，作废（即时刷新之外的第二道防线）
            if !this._IsWatchedKey(info.key) {
                this._BumpProbe(info.key, "watchDrop")
                settled.Push(vk)
                continue
            }
            if (this._Depth > 0)
                continue                    ; 同键重入被 MaxThreadsPerHotkey 正常屏蔽，不算异常
            ; 前台窗口变了 ⇒ 建档时成立的前提已失效，不能据此判"未触发"（否则切窗即误报）
            if (info.HasOwnProp("fgHwnd") && info.fgHwnd != this._ForegroundHwnd()) {
                this._BumpProbe(info.key, "discard")
                settled.Push(vk)
                continue
            }
            ; 同理：鼠标键还要求光标在游戏客户区内，光标移出后不触发也是设计如此
            if (IsMouseKey(info.key) && !IsMouseInClient()) {
                this._BumpProbe(info.key, "discard")
                settled.Push(vk)
                continue
            }
            lastWarn := this._LastWarnTick.Get(info.key, 0)
            if (lastWarn != 0 && now - lastWarn < this.MissWarnCooldownMs)
                continue                    ; 冷却期内不重复告警
            settled.Push(vk)
            this._LastWarnTick[info.key] := now
            this._MissTotal++
            this._MissStreak++
            this._BumpProbe(info.key, "miss")
            Logger.Warn("HookHealth", "物理按下未触发热键：key=" info.key
                . "，按下瞬间 idleKbd=" info.idleKbd "ms"
                . "，监听 " this.PendingGraceMs "ms 内无对应回调"
                . "，连续未命中=" this._MissStreak "，累计=" this._MissTotal
                . "，该键自证=" this._ProbeKeyStats(info.key))
            if (this._MissStreak >= this.MissThreshold)
                this._OnSuspected()
        }
        for vk in settled {
            if (this._Pending.Has(vk))
                this._Pending.Delete(vk)
        }
    }

    ; 热键回调恢复：清零连击计数；此前若已判定失效则落一条恢复日志，便于与自愈记录对照
    static _NoteHit() {
        this._MissStreak := 0
        if (!this._Suspected)
            return
        this._Suspected := false
        this._NextReportTick := 0
        Logger.Warn("HookHealth", "热键回调已恢复 | " this._Snapshot())
    }

    ; 连续未命中达阈值：落一份完整现场快照，并按需自愈
    static _OnSuspected() {
        firstHit := !this._Suspected
        this._Suspected := true
        Logger.Warn("HookHealth", "键盘钩子疑似失效（连续 " this._MissStreak " 次物理按下无热键回调） | " this._Snapshot())
        if (firstHit)
            Logger.Warn("HookHealth", "判读指引：三值 idle/idleKbd/idlePhys 恒等=钩子已被系统摘除；depth/inflight 不归零=动作线程泄漏；三值有差异且残留表非空=状态残留")
        if (!this.AutoRecover)
            return
        if (this._LastRecoverTick != 0 && A_TickCount - this._LastRecoverTick < this.RecoverCooldownMs)
            return
        this._LastRecoverTick := A_TickCount
        this._RecoverCount++
        Logger.Warn("HookHealth", "钩子自愈：已强制重装键盘钩子并抢占优先级（第 " this._RecoverCount " 次）"
            . "——若真实原因是输入被其它进程的前置钩子吞掉，本操作会改变钩子链优先级顺序；"
            . "连续未命中=" this._MissStreak "，冷却=" this.RecoverCooldownMs "ms，累计自愈=" this._RecoverCount)
        try {
            InstallKeybdHook(true, true)
            Logger.Warn("HookHealth", "钩子自愈完成（第 " this._RecoverCount " 次自愈），热键应即刻恢复")
        } catch Error as e {
            Logger.Exception("HookHealth", e, "重装键盘钩子失败")
        }
        this._MissStreak := 0
    }

    ; ---- 周期快照：正常期按心跳留基线，异常期提高到 ReportIntervalMs 保证现场完整 ----
    static _Report() {
        if (this._Suspected) {
            Logger.Warn("HookHealth", "现场快照 | " this._Snapshot())
            return
        }
        Logger.Debug("HookHealth", "心跳 | " this._Snapshot())
    }

    static _Snapshot() {
        return "idle=" A_TimeIdle ", idleKbd=" A_TimeIdleKeyboard ", idlePhys=" A_TimeIdlePhysical
            . ", fire=" this._FireTotal ", miss=" this._MissTotal "/" this._MissStreak
            . ", depth=" this._Depth "(max " this._MaxDepth ")"
            . ", recover=" this._RecoverCount
            . ", ctxEval=" this._FmtMs(HotkeyService._EvalMaxMs) "/" this._FmtMs(this._AvgMs(HotkeyService._EvalTotalMs, HotkeyService._EvalCount)) "ms(max/avg, n=" HotkeyService._EvalCount ")"
            . ", probe=[" this._ProbeSnapshot() "]（arm≈cleared+miss+discard+watchDrop 为正常）"
            . ", inflight=[" this._InFlightNames() "]"
            . ", SuppressUp=[" this._KeyList(KeyForward.SuppressUp) "]"
            . ", DownHandled=[" this._KeyList(KeyForward.DownHandled) "]"
            . ", Intercepted=[" this._KeyList(KeyForward.InterceptedKeys) "]"
            . ", InjectedPress=[" this._KeyList(GameKeys.InjectedPressKeys) "]"
    }

    static _AvgMs(totalMs, count) {
        return count > 0 ? totalMs / count : 0
    }

    ; 耗时统一一位小数定长输出：直接拼浮点会出现 0.30000000000000004 这类噪声，事后解析也不稳定
    static _FmtMs(valueMs) {
        return Format("{:.1f}", valueMs)
    }

    static _InFlightNames() {
        parts := "", now := A_TickCount
        for _, info in this._InFlight
            parts .= (parts = "" ? "" : " ") info.name "/" info.key "+" (now - info.tick) "ms"
        return parts
    }

    static _KeyList(source) {
        parts := ""
        for key, _ in source
            parts .= (parts = "" ? "" : " ") key
        return parts
    }

    static _WatchKeyNames() {
        parts := ""
        for _, pureKey in this._WatchKeys
            parts .= (parts = "" ? "" : " ") pureKey
        return parts
    }

    ; 键位集合变更时由 HotkeyService 调用，立即重建监视表。必须即时：定时刷新要等 5s，
    ; 而 HotkeyOff/EnableByTab 立刻清空 ActiveHotkeys，空窗期内会为"本不该有回调"的按下建档并误报
    static RefreshWatchKeysNow() {
        this._RebuildWatchKeys()
        this._NextWatchTick := A_TickCount + this.WatchRefreshMs
    }

    ; 监视键位表 = 当前已注册热键的纯键名（vk -> pureKey）
    static _RebuildWatchKeys() {
        next := Map()
        for _, hotkeyValue in HotkeyService.ActiveHotkeys {
            pureKey := KeyForward.PureKeyName(hotkeyValue)
            if (pureKey == "" || InStr(pureKey, "wheel"))
                continue
            vk := 0
            try {
                vk := GetKeyVK(pureKey)
            } catch Error {
                continue
            }
            if (vk = 0 || next.Has(vk))
                continue
            next[vk] := pureKey
        }
        this._WatchKeys := next
        ; 清理已下线键位的采样状态，避免 Map 无限增长
        stale := []
        for vk, _ in this._PrevDown {
            if (!next.Has(vk))
                stale.Push(vk)
        }
        for vk in stale {
            if (this._PrevDown.Has(vk))
                this._PrevDown.Delete(vk)
        }
        ; 键位下线的抬起记录已无意义，顺手清理
        if (this._LastUpEdge.Count > 0) {
            known := Map()
            for _, pureKey in next
                known[pureKey] := true
            for key, _ in this._LastUpEdge {
                if !known.Has(key) {
                    try this._LastUpEdge.Delete(key)
                    catch UnsetItemError {
                    }
                }
            }
        }
    }
}
