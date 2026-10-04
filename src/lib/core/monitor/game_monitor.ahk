; == 游戏状态监控 ==

class GameMonitor {
    ; SetTimer 需要缓存同一 bound 回调对象才能正确启停/调速
    static _CheckTimer := ""
    static _TimeoutTimer := ""
    static _PauseWaitTimer := ""
    static _PauseWaitTickTimer := ""

    ; 自动暂停「等待倍速按钮」阶段参数
    static PauseWaitIntervalMs := 30
    static PauseWaitTimeoutMs := 8000
    static _PauseWaitDeadline := 0

    ; 私有状态
    static _GameHasStarted := false
    static _BlackScreenDetected := false
    static _ReadyForPause := false

    ; 按住开局暂停
    static _HoldPhaseActive := false
    static _HoldNoDeadline := false
    static _HoldKeepNormalWait := false
    static _HoldKey := ""

    ; 启动监控定时器
    static Start() {
        if (this._CheckTimer = "")
            this._CheckTimer := GameMonitor.CheckGameStatus.Bind(GameMonitor)
        SetTimer this._CheckTimer, 200
        EventBus.Subscribe("ForegroundClientChanged", (data) => this._HandleForegroundClientChanged(data))
    }

    static _HandleForegroundClientChanged(data) {
        Logger.Info("GameMonitor", "前台客户端变化：serverId=" data.serverId ", pid=" data.pid)
    }

    ; 调整主轮询定时器间隔
    static SetPollInterval(interval) {
        if (this._CheckTimer = "")
            this._CheckTimer := GameMonitor.CheckGameStatus.Bind(GameMonitor)
        SetTimer this._CheckTimer, interval
    }

    ; 安排/取消黑屏识别超时
    static _ScheduleTimeout(ms) {
        if (this._TimeoutTimer = "")
            this._TimeoutTimer := GameMonitor.StopSearchLoadingTimeout.Bind(GameMonitor)
        SetTimer this._TimeoutTimer, ms
    }

    ; 重置游戏运行记录
    static ResetRunRecord() {
        this._GameHasStarted := false
    }

    ; 游戏是否曾运行过
    static IsGameHasStarted() {
        return this._GameHasStarted
    }

    ; 检查游戏状态
    static CheckGameStatus() {
        GameClientRegistry.Refresh()

        static PrevAutoExit := ""
        autoExit := Config.ReadImportantFromIni("AutoExit")
        if (autoExit == "1" && PrevAutoExit != "1" && PrevAutoExit != "") {
            this._GameHasStarted := false
            Logger.Info("GameMonitor", "AutoExit 开启，重置游戏运行记录")
        }
        PrevAutoExit := autoExit

        if (autoExit == "1") {
            hasClients := GameClientRegistry.HasClients()
            if (!hasClients && GameTarget.ProcessExists())
                hasClients := true
            if (hasClients) {
                this._GameHasStarted := true
            } else {
                if (this._GameHasStarted == true) {
                    Logger.Info("GameMonitor", "检测到所有游戏客户端已退出，自动退出 AFA")
                    ExitApp
                }
            }
        }

        ; 自动开局暂停 / 自动开局二倍速（运行时读 INI，两者共用同一套进关检测状态机）
        autoPause := Config.ReadImportantFromIni("AutoBeginPause") == "1"
        if ((autoPause || Config.ReadImportantFromIni("AutoBeginSpeed") == "1") && GameTarget.IsActive()) {
            autoSpeed := Config.ReadImportantFromIni("AutoBeginSpeed") == "1"
            ; 寻找黑屏（17 点采样，允许 3 点被遮挡）
            if (this._BlackScreenDetected == false) {
                points := GameMonitor.BlackScreenPoints()
                if !points
                    return
                try oldCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
                try {
                    missCount := 0
                    for point in points {
                        if !SafePixelSearch(&FoundX, &FoundY, point.x, point.y, point.x, point.y, 0x000000, 10) {
                            missCount++
                            if (missCount > 3)
                                break
                        }
                    }
                    if (missCount <= 1) {
                        this._BlackScreenDetected := true
                        Logger.Info("GameMonitor", "检测到黑屏，可能是进入关卡前的加载，开始识别 Loading（自动暂停=" (autoPause ? "开" : "关") "，自动二倍速=" (autoSpeed ? "开" : "关") "）")
                        this._ScheduleTimeout(-8000)
                        this.SetPollInterval(100)
                    }
                } finally {
                    if (oldCtx)
                        DllCall("SetThreadDpiAwarenessContext", "ptr", oldCtx, "ptr")
                }
            }
            ; 识别 Loading（Loading... 文字区域颜色判断场景类型）
            if (this._BlackScreenDetected == true && this._ReadyForPause == false) {
                try oldCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
                try {
                    scanLines := GameMonitor.LoadingPosition()
                    if !scanLines
                        return
                    line1 := scanLines[1]
                    if SafePixelSearch(&FoundX, &FoundY, line1.lx, line1.y, line1.rx, line1.y, 0xA60000, 50) {
                        Logger.Info("GameMonitor", "识别到红色按钮，停止 Loading 搜索")
                        this._ScheduleTimeout(0)
                        this._BlackScreenDetected := false
                    } else if SafePixelSearch(&FoundX, &FoundY, line1.lx, line1.y, line1.rx, line1.y, 0x0070a3, 50) {
                        Logger.Info("GameMonitor", "识别到蓝色按钮，停止 Loading 搜索")
                        this._ScheduleTimeout(0)
                        this._BlackScreenDetected := false
                    } else {
                        allWhite := true
                        for line in scanLines {
                            if !SafePixelSearch(&FoundX, &FoundY, line.lx, line.y, line.rx, line.y, 0xFFFFFF, 0) {
                                allWhite := false
                                break
                            }
                        }
                        if (allWhite) {
                            Logger.Info("GameMonitor", "识别到白色 Loading，进入等待倍速按钮阶段")
                            this._ReadyForPause := true
                            this._ScheduleTimeout(0)
                            if (this._PauseWaitTimer = "")
                                this._PauseWaitTimer := GameMonitor.ActionBeginPause.Bind(GameMonitor)
                            SetTimer this._PauseWaitTimer, -2000
                        }
                    }
                } finally {
                    if (oldCtx)
                        DllCall("SetThreadDpiAwarenessContext", "ptr", oldCtx, "ptr")
                }
            }
        }
    }

    ; 自动开局暂停：进入「等待倍速按钮」阶段
    static ActionBeginPause() {
        autoPause := Config.ReadImportantFromIni("AutoBeginPause") == "1"
        autoSpeed := Config.ReadImportantFromIni("AutoBeginSpeed") == "1"
        Logger.Info("GameMonitor", "等待倍速按钮阶段开始（自动暂停=" (autoPause ? "开" : "关") "，自动二倍速=" (autoSpeed ? "开" : "关") "）")
        this._PauseWaitDeadline := A_TickCount + this.PauseWaitTimeoutMs
        this._PauseWaitTick()
    }

    ; 按住开局暂停
    static BeginPauseHold(holdMode := true, pureKey := "") {
        keepNormalWait := holdMode && (this._ReadyForPause || this._BlackScreenDetected)
        this._HoldPhaseActive := true
        this._HoldNoDeadline := holdMode
        this._HoldKeepNormalWait := keepNormalWait
        this._HoldKey := holdMode ? pureKey : ""
        if holdMode {
            if !keepNormalWait
                this._PauseWaitDeadline := 0
        } else {
            this._PauseWaitDeadline := A_TickCount + this.PauseWaitTimeoutMs
        }
        this._ReadyForPause := true
        Logger.Info("GameMonitor", "按住开局暂停：直接进入等待倍速按钮阶段（保留常规等待=" (keepNormalWait ? "是" : "否") "，超时=" (this._HoldNoDeadline ? "不设上限" : "沿用常规") "）")
        this._PauseWaitTick()
    }

    static EndPauseHold() {
        if !this._HoldPhaseActive {
            Logger.Info("GameMonitor", "按住开局暂停：松开时等待阶段已结束，无需取消")
            return
        }
        keepNormalWait := this._HoldKeepNormalWait
        this._HoldPhaseActive := false
        this._HoldNoDeadline := false
        this._HoldKeepNormalWait := false
        this._HoldKey := ""
        if keepNormalWait {
            Logger.Info("GameMonitor", "按住开局暂停：松开，常规自动暂停路径仍在等待，保留")
            return
        }
        Logger.Info("GameMonitor", "按住开局暂停：松开，取消本次识别")
        this._ResetPauseWait()
    }

    ; 「等待倍速按钮」单拍：命中则暂停并收尾，未命中则重新排程下一拍
    static _PauseWaitTick() {
        try oldCtx := DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")
        try {
            if !GameTarget.Exists() {
                Logger.Warn("GameMonitor", "等待倍速按钮：等待期间游戏窗口已不存在")
                this._ResetPauseWait()
                return
            }
            if !GameTarget.IsActive() {
                Logger.Info("GameMonitor", "等待倍速按钮：游戏已切出前台，放弃本次检测")
                this._ResetPauseWait()
                return
            }
            if (this._HoldNoDeadline && this._HoldKey != "" && !HoldGuard.IsHolding(this._HoldKey)) {
                Logger.Info("GameMonitor", "按住开局暂停：按住周期已结束，取消识别")
                this.EndPauseHold()
                return
            }
            if (!this._HoldNoDeadline && this._PauseWaitDeadline != 0 && A_TickCount > this._PauseWaitDeadline) {
                Logger.Info("GameMonitor", "等待倍速按钮：8 秒内未识别到倍速按钮，放弃本次检测")
                this._ResetPauseWait()
                return
            }
            PosC := SpeedButtonPositionColor()
            if !PosC {
                Logger.Warn("GameMonitor", "等待倍速按钮：游戏窗口不存在")
                this._ResetPauseWait()
                return
            }
            if !SafePixelSearch(&FoundX, &FoundY, PosC.PBCRX, PosC.PBCUY, PosC.PBCLX, PosC.PBCDY, 0xffffff, 10) {
                SetTimer this._PauseWaitTimerTick(), -this.PauseWaitIntervalMs
                return
            }
            Logger.Info("GameMonitor", "等待倍速按钮：命中白色像素（x=" Round(FoundX) " y=" Round(FoundY) "），进入进关后处理")
            autoPause := Config.ReadImportantFromIni("AutoBeginPause") == "1"
            autoSpeed := Config.ReadImportantFromIni("AutoBeginSpeed") == "1"
            ; 忽略「启用开局自动暂停」开关，且代理指挥也保持暂停
            forcedPause := this._HoldPhaseActive
            needPause := autoPause || forcedPause
            if needPause {
                GameKeys.SendDown("pauseBattle")
                USleep(50)
                GameKeys.SendUp("pauseBattle")
                Logger.Info("GameMonitor", forcedPause ? "按住开局暂停：已暂停（按住触发，忽略自动暂停开关）" : "自动暂停：已暂停")
            }
            ; 后置代理指挥识别，识别到代理指挥时取消暂停
            isProxy := false
            TobC := TakeOverButtonPositions()
            if !TobC {
                Logger.Warn("GameMonitor", "等待倍速按钮：游戏窗口不存在（代理指挥识别）")
                this._ResetPauseWait()
                return
            }
            ; 接管代理按钮右侧边缘
            takeoverHit := SafeImageSearch(&OutputVarX, &OutputVarY, TobC.ImageRegion.RLX, TobC.ImageRegion.RUY, TobC.ImageRegion.RRX, TobC.ImageRegion.RDY, "*90 " FileExtractor.TakeOver1Path) || SafeImageSearch(&OutputVarX, &OutputVarY, TobC.ImageRegion.RLX, TobC.ImageRegion.RUY, TobC.ImageRegion.RRX, TobC.ImageRegion.RDY, "*90 " FileExtractor.TakeOver2Path)
            if takeoverHit
                isProxy := true
            ; 接管代理按钮「手」图标拇指
            handHit := SafeImageSearch(&OutputVarX, &OutputVarY, TobC.ImageRegion.HLX, TobC.ImageRegion.HUY, TobC.ImageRegion.HRX, TobC.ImageRegion.HDY, "*90 " FileExtractor.TakeOver3Path)
            if !handHit
                isProxy := false
            Logger.Info("GameMonitor", "代理指挥判定：接管按钮=" (takeoverHit ? "命中" : "未命中") "，手图标=" (handHit ? "命中" : "未命中") "，判定=" (isProxy ? "代理" : "非代理"))
            if needPause {
                if (isProxy && forcedPause) {
                    Logger.Info("GameMonitor", "代理指挥，但本次为按住触发，保持暂停")
                } else if isProxy {
                    GameKeys.SendDown("pauseBattle")
                    USleep(50)
                    GameKeys.SendUp("pauseBattle")
                    Logger.Info("GameMonitor", "代理指挥，取消暂停")
                } else {
                    Logger.Info("GameMonitor", "非代理指挥，保持暂停")
                }
            }
            ; 开局自动二倍速：非代理作战时切一次倍速
            if (autoSpeed && !isProxy) {
                Logger.Info("GameMonitor", "开局自动二倍速：开始注入倍速键（自动暂停=" (autoPause ? "开" : "关") "，按住触发=" (forcedPause ? "是" : "否") "）")
                GameKeys.Tap("changeSpeed")
                Logger.Info("GameMonitor", "开局自动二倍速：已切换倍速")
            } else {
                Logger.Info("GameMonitor", "开局自动二倍速：跳过（二倍速开关=" (autoSpeed ? "开" : "关") "，代理判定=" (isProxy ? "代理" : "非代理") "）")
            }
            this._ResetPauseWait()
        } finally {
            if (oldCtx)
                DllCall("SetThreadDpiAwarenessContext", "ptr", oldCtx, "ptr")
        }
    }

    ; 「等待倍速按钮」轮询回调
    static _PauseWaitTimerTick() {
        if (this._PauseWaitTickTimer = "")
            this._PauseWaitTickTimer := GameMonitor._PauseWaitTick.Bind(GameMonitor)
        return this._PauseWaitTickTimer
    }

    ; 结束等待并回到常规轮询节奏
    static _ResetPauseWait() {
        if (this._PauseWaitTimer != "")
            SetTimer this._PauseWaitTimer, 0
        SetTimer this._PauseWaitTimerTick(), 0
        this._BlackScreenDetected := false
        this._ReadyForPause := false
        this._HoldPhaseActive := false
        this._HoldNoDeadline := false
        this._HoldKeepNormalWait := false
        this._HoldKey := ""
        this.SetPollInterval(400)
    }

    ; 获取 Loading... 三条水平扫描线位置
    static LoadingPosition() {
        if !SafeWinGetClientPos(&ww, &wh)
            return false
        ; 第一条：右下 Loading... 文字
        L1LX := ww * 0.835156, L1RX := ww * 0.976953, L1Y := wh * 0.953472
        ; 第二条：底部中央
        L2LX := ww * 0.469531, L2RX := ww * 0.526562, L2Y := wh * 0.953472
        ; 第三条：屏幕中央
        L3LX := ww * 0.413671, L3RX := ww * 0.582421, L3Y := wh * 0.520833
        return [
            {lx: L1LX, rx: L1RX, y: L1Y},
            {lx: L2LX, rx: L2RX, y: L2Y},
            {lx: L3LX, rx: L3RX, y: L3Y}
        ]
    }

    ; 获取全屏 17 点黑屏采样位置
    static BlackScreenPoints() {
        if !SafeWinGetClientPos(&ww, &wh)
            return false
        x5 := ww * 0.05, x25 := ww * 0.25, x50 := ww * 0.5, x75 := ww * 0.75, x95 := ww * 0.95
        y5 := wh * 0.05, y25 := wh * 0.25, y50 := wh * 0.5, y75 := wh * 0.75, y95 := wh * 0.95
        return [
            ; 上边（左→右 5 点）
            {x: x5, y: y5}, {x: x25, y: y5}, {x: x50, y: y5}, {x: x75, y: y5}, {x: x95, y: y5},
            ; 下边（左→右 5 点）
            {x: x5, y: y95}, {x: x25, y: y95}, {x: x50, y: y95}, {x: x75, y: y95}, {x: x95, y: y95},
            ; 左边中点、右边中点
            {x: x5, y: y50}, {x: x95, y: y50},
            ; 内部四点和正中心
            {x: x25, y: y25}, {x: x75, y: y25},
            {x: x50, y: y50},
            {x: x25, y: y75}, {x: x75, y: y75}
        ]
    }

    ; 停止搜索 Loading
    static StopSearchLoading() {
        this.SetPollInterval(400)
        this._BlackScreenDetected := false
    }

    ; 黑屏识别超时（8 秒未确认 Loading 状态）
    static StopSearchLoadingTimeout() {
        Logger.Info("GameMonitor", "黑屏识别超时（8秒未确认 Loading），并非进关卡，停止搜索")
        GameMonitor.StopSearchLoading()
    }
}
