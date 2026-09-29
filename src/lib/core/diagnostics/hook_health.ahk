; == 键盘钩子存活探针与自愈 ==

IsMouseKey(pureKey) {
    return pureKey ~= "i)^(lbutton|rbutton|mbutton|xbutton1|xbutton2|wheel)"
}

class HookHealth {
    ; ---- 可调参数 ----
    static PollIntervalMs := 100
    static ReportIntervalMs := 5000
    static HeartbeatMs := 60000
    static PendingGraceMs := 3000
    static MissWarnCooldownMs := 5000
    static MissThreshold := 5
    static FireRaceWindowMs := 250
    static WatchRefreshMs := 5000
    static RecoverCooldownMs := 30000
    static AutoRecover := true

    ; ---- 运行时状态 ----
    static _Timer := ""
    static _WatchKeys := Map()        ; vk -> pureKey
    static _PrevDown := Map()         ; vk -> true/false
    static _Pending := Map()          ; vk -> {tick, key, idleKbd, fire, fgHwnd}
    static _FireByKey := Map()        ; pureKey -> 回调累计次数
    static _FireTotal := 0
    static _LastFireTick := Map()     ; pureKey -> 最近回调时刻
    static _LastUpEdge := Map()       ; pureKey -> 最近采样到抬起的时刻
    static _LastPressEdge := Map()    ; pureKey -> 最近采样到按下沿的时刻
    static _LastWarnTick := Map()     ; pureKey -> 最近告警时刻
    static _MissStreak := 0
    static _MissTotal := 0
    static _Depth := 0                ; 在执行的动作线程数
    static _MaxDepth := 0
    static _InFlight := Map()         ; seq -> {name, key, tick}
    static _Seq := 0
    static _NextReportTick := 0
    static _NextWatchTick := 0
    static _LastRecoverTick := 0
    static _RecoverCount := 0
    static _Suspected := false
    static _Started := false
    ; ---- 探针自证计数（按纯键名）----
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

    static _IsWatchedKey(pureKey) {
        for _, watchedKey in this._WatchKeys {
            if (watchedKey = pureKey)
                return true
        }
        return false
    }

    ; 前台窗口句柄
    static _ForegroundHwnd() {
        return DllCall("GetForegroundWindow", "Ptr")
    }

    ; 启动探针（须在 HotkeyOn 之后调用）
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

    ; 热键回调发生
    static NoteFire(pureKey) {
        if (pureKey == "")
            return
        this._FireTotal++
        this._FireByKey[pureKey] := this._FireByKey.Get(pureKey, 0) + 1
        this._LastFireTick[pureKey] := A_TickCount
        if (this._ClearPendingFor(pureKey))
            this._BumpProbe(pureKey, "cleared")
        if (this._Suspected)
            this._NoteHit()
    }

    static FireTotal() {
        return this._FireTotal
    }

    ; 动作线程进入；返回的句柄必须在 finally 里交给 ExitAction
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

    ; 移除该键全部挂起观测，返回是否确实清掉了
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

    ; 采样物理按下沿（GetAsyncKeyState 不经过本进程钩子）
    static _SamplePhysicalKeys(now) {
        for vk, pureKey in this._WatchKeys {
            isDown := (DllCall("GetAsyncKeyState", "Int", vk, "Short") & 0x8000) != 0
            wasDown := this._PrevDown.Has(vk) && this._PrevDown[vk]
            this._PrevDown[vk] := isDown
            if (!isDown) {
                this._LastUpEdge[pureKey] := now
                continue
            }
            if (wasDown)
                continue
            if (!this._ShouldArm(pureKey))
                continue
            lastUp := this._LastUpEdge.Get(pureKey, 0)
            this._LastPressEdge[pureKey] := now
            lastFire := this._LastFireTick.Get(pureKey, 0)
            if (lastFire != 0 && lastFire > lastUp && now - lastFire < this.FireRaceWindowMs) {
                this._BumpProbe(pureKey, "raceSkip")
                continue
            }
            this._Pending[vk] := {tick: now, key: pureKey, idleKbd: A_TimeIdleKeyboard
                , fire: this._FireByKey.Get(pureKey, 0), fgHwnd: this._ForegroundHwnd()}
            this._BumpProbe(pureKey, "arm")
        }
    }

    ; 是否把这次物理按下计入观测
    static _ShouldArm(pureKey) {
        if (!GameTarget.IsForegroundCached())
            return false
        if (GameKeys.IsInjectedPressPending(pureKey))
            return false
        if (KeyForward.SuppressUp.Has(pureKey))
            return false
        return true
    }

    ; 结算挂起按下
    static _ResolvePending(now) {
        if (this._Pending.Count = 0)
            return
        settled := []
        for vk, info in this._Pending {
            if (now - info.tick < this.PendingGraceMs)
                continue
            if (this._FireByKey.Get(info.key, 0) > info.fire) {
                settled.Push(vk)
                continue
            }
            if !this._IsWatchedKey(info.key) {
                this._BumpProbe(info.key, "watchDrop")
                settled.Push(vk)
                continue
            }
            if (this._Depth > 0)
                continue
            if (info.HasOwnProp("fgHwnd") && info.fgHwnd != this._ForegroundHwnd()) {
                this._BumpProbe(info.key, "discard")
                settled.Push(vk)
                continue
            }
            if (IsMouseKey(info.key) && !IsMouseInClient()) {
                this._BumpProbe(info.key, "discard")
                settled.Push(vk)
                continue
            }
            lastWarn := this._LastWarnTick.Get(info.key, 0)
            if (lastWarn != 0 && now - lastWarn < this.MissWarnCooldownMs)
                continue
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

    ; 热键回调恢复
    static _NoteHit() {
        this._MissStreak := 0
        if (!this._Suspected)
            return
        this._Suspected := false
        this._NextReportTick := 0
        Logger.Warn("HookHealth", "热键回调已恢复 | " this._Snapshot())
    }

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

    ; ---- 周期快照 ----
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
            . ", hold=[" HoldGuard.Snapshot() "]"
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

    ; 耗时统一一位小数定长输出
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

    ; 键位集合变更时立即重建监视表
    static RefreshWatchKeysNow() {
        this._RebuildWatchKeys()
        this._NextWatchTick := A_TickCount + this.WatchRefreshMs
    }

    ; 监视键位表（vk -> pureKey）
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
        stale := []
        for vk, _ in this._PrevDown {
            if (!next.Has(vk))
                stale.Push(vk)
        }
        for vk in stale {
            if (this._PrevDown.Has(vk))
                this._PrevDown.Delete(vk)
        }
        ; 清理已下线键位的抬起记录
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
