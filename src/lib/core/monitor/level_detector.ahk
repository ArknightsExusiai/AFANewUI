; == 关卡检测投票状态机 ==

class LevelDetector {
    ; 3 个对象命中 ≥2 置位
    static VoteThreshold := 2

    static _PollTimer := ""       ; 轮询定时器回调（须缓存同一对象）
    static _PollCount := 0        ; 轮询计数（节流 debug 明细）
    static _GuardActive := false  ; 守卫轮询是否开启
    static _InLevel := false      ; 关卡状态（私有）

    ; 检测对象：区域用相对比例定位（LX/RX = ww 比例，UY/DY = wh 比例）
    ; Colors: [{C: 0xRRGGBB 目标颜色, V: 容差 0-255}]，多个颜色 OR
    static Objects := [
        ; 关卡内文本（右下角；白/浅灰两色 OR，低分辨率 <1600×900 时容差放宽到 20）
        {Name: "TextInLevel",
         Colors: [{C: 0xFFFFFF, V: 2}, {C: 0x9B9B9B, V: 2}],
         LX: 0.9300, RX: 0.9420, UY: 0.7833, DY: 0.8465},
        ; 退出按钮（左上角；灰阶 + 其他模式深红/黄绿共 12 色 OR）
        {Name: "ExitButton",
         Colors: [{C: 0x868686, V: 5}, {C: 0x8C8C8C, V: 5}, {C: 0xB72518, V: 5}, {C: 0xBF2719, V: 5},
            {C: 0xD0CF67, V: 5}, {C: 0xD9D86B, V: 5}, {C: 0x555555, V: 5}, {C: 0x515151, V: 5},
            {C: 0x74180F, V: 5}, {C: 0x6F160F, V: 5}, {C: 0x848341, V: 5}, {C: 0x7E7E3F, V: 5}],
         LX: 0.0531, RX: 0.0535, UY: 0.0299, DY: 0.0750},
        ; 暂停按钮（右上角；白/浅灰两色 OR）
        {Name: "PauseButton",
         Colors: [{C: 0xFFFFFF, V: 2}, {C: 0xF5F5F5, V: 2}],
         LX: 0.9297, RX: 0.9453, UY: 0.0590, DY: 0.0590}
    ]

    ; 关卡状态 getter
    static IsInLevel() {
        return this._InLevel
    }

    ; 设置关卡状态并发布事实事件
    static _SetInLevel(newVal) {
        if (this._InLevel = newVal)
            return
        this._InLevel := newVal
        EventBus.Publish("InLevelChanged", {inLevel: newVal})
    }

    ; 守卫开关：开启→启动轮询；关闭→停止轮询
    static SetGuardEnabled(enabled) {
        if (this._GuardActive = enabled)
            return
        this._GuardActive := enabled
        Logger.Info("LevelDetector", "关卡守卫 " (enabled ? "开启" : "关闭"))
        if enabled {
            if (this._PollTimer = "")
                this._PollTimer := LevelDetector.Poll.Bind(LevelDetector)
            SetTimer this._PollTimer, 333
        } else if (this._PollTimer != "") {
            SetTimer this._PollTimer, 0
        }
    }

    ; 守卫开关同步（设置保存/应用/取消/重置后调用）
    static SyncGuardSetting() {
        if (Config.ReadImportantFromIni("InLevelGuard") != "1") {
            this.SetGuardEnabled(false)
            this._SetInLevel(true)
            return
        }
        this.SetGuardEnabled(true)
    }

    ; 启动投票定时器
    static Init() {
        EventBus.Subscribe("SettingsChanged", (data) => this._HandleSettingsChanged(data))
        EventBus.Subscribe("SettingsSaved", (*) => this.SyncGuardSetting())
        EventBus.Subscribe("SettingsApplied", (*) => this.SyncGuardSetting())
        EventBus.Subscribe("SettingsReset", (*) => this.SyncGuardSetting())
        if (Config.ReadImportantFromIni("InLevelGuard") != "1") {
            this._SetInLevel(true)
            return
        }
        this.SetGuardEnabled(true)
    }

    ; 处理单键设置变更
    static _HandleSettingsChanged(data) {
        if (data.key = "InLevelGuard")
            this.SyncGuardSetting()
    }

    ; 轮询投票
    static Poll() {
        this._PollCount += 1
        ; 游戏进程不存在 → 复位关卡状态
        if !GameTarget.Exists() {
            this._SetInLevel(false)
            return
        }
        ; 游戏窗口未激活 → 跳过（保持现有状态）
        if !GameTarget.IsActive()
            return
        oldCtx := 0
        try oldCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
        try {
            if !SafeWinGetClientPos(&ww, &wh) {
                this._SetInLevel(false)
                return
            }
            ; 单次捕获客户区位图（替代逐点 PixelSearch）
            if !SafeCaptureClientRect(&bits, &cw, &ch) {
                _LogSearchError("ScreenCapture", "客户区位图捕获失败")
                this._SetInLevel(false)
                return
            }
            hitCount := 0
            detail := ""
            for obj in this.Objects {
                matched := this._MatchObject(obj, ww, wh, cw, ch, bits)
                if matched
                    hitCount++
                detail .= obj.Name ": " (matched ? "✓" : "✗") "  "
            }
            newVal := hitCount >= this.VoteThreshold
            if (newVal != this._InLevel)
                Logger.Info("LevelDetector", "关卡状态切换：" (newVal ? "进入关卡" : "退出关卡") "（识别结果 " hitCount "/" this.Objects.Length " " detail "）")
            ; 轮询明细：每 20 次或状态变化记一条
            if (newVal != this._InLevel || Mod(this._PollCount, 20) = 0)
                Logger.Debug("LevelDetector", "识别结果 " hitCount "/" this.Objects.Length " " detail)
            this._SetInLevel(newVal)
        } finally {
            if (oldCtx)
                DllCall("SetThreadDpiAwarenessContext", "ptr", oldCtx, "ptr")
        }
    }

    ; 匹配单个对象：在捕获位图（BGRA）内扫描区域，任一目标颜色命中即算对象命中
    static _MatchObject(obj, ww, wh, cw, ch, bits) {
        x1 := Max(0, Min(Round(ww * obj.LX), Round(ww * obj.RX)))
        x2 := Min(cw - 1, Max(Round(ww * obj.LX), Round(ww * obj.RX)))
        y1 := Max(0, Min(Round(wh * obj.UY), Round(wh * obj.DY)))
        y2 := Min(ch - 1, Max(Round(wh * obj.UY), Round(wh * obj.DY)))
        if (x1 > x2 || y1 > y2)
            return false
        for color in obj.Colors {
            v := color.V
            if (obj.Name = "TextInLevel" && (ww < 1600 || wh < 900))
                v := Max(v, 20)
            cr := (color.C >> 16) & 0xFF
            cg := (color.C >> 8) & 0xFF
            cb := color.C & 0xFF
            loop (y2 - y1 + 1) {
                rowBase := ((y1 + A_Index - 1) * cw + x1) * 4
                found := false
                loop (x2 - x1 + 1) {
                    i := rowBase + (A_Index - 1) * 4
                    pB := NumGet(bits, i, "UChar")
                    pG := NumGet(bits, i + 1, "UChar")
                    pR := NumGet(bits, i + 2, "UChar")
                    if (Abs(pR - cr) <= v && Abs(pG - cg) <= v && Abs(pB - cb) <= v) {
                        found := true
                        break
                    }
                }
                if found
                    return true
            }
        }
        return false
    }
}

