; == 状态栏悬停说明 ==

class StatusBarHints {
    static MainGui := ""
    static SepLine := ""        ; 主题色指示块
    static TextCtrl := ""       ; 说明文本控件
    static Started := false
    static RotateIntervalMs := 10000
    static _Hints := Map()      ; 控件 HWND → {Key, Args}
    static _HoverHwnd := 0
    static _HoverKey := ""
    static _CurrentKey := ""
    static _CurrentArgs := []
    static _CurrentText := ""
    static _TipItems := [
        "悬停到任意控件即可查看功能说明",
        "修改设置后记得保存或应用哦",
        "遇到问题可在「日志」页导出日志压缩包，然后到GitHub Issues或者加入QQ群反馈",
        "使用满意的话欢迎上GitHub给AFA点个Star，非常感谢~"
    ]
    static _LastTip := ""
    static _RotateCallback := ObjBindMethod(this, "_OnRotate")
    static _MsgRegistered := false
    static _GreetingShown := false

    ; 创建状态栏并启动轮播
    static Init(mainGui) {
        if (this.Started && this.MainGui = mainGui)
            return
        SetTimer(this._RotateCallback, 0)
        this.Started := true
        this.MainGui := mainGui
        this._HoverHwnd := 0
        this._HoverKey := ""
        this._CurrentKey := ""
        this._CurrentArgs := []
        this._CurrentText := ""
        this._LastTip := ""
        this.SepLine := Theme.Add(mainGui, "Text", "x0 y+-6 w28 h13 BackgroundAccent")
        this.TextCtrl := Theme.Add(mainGui, "Text", "x+4 yp-2 w660 cText", "")
        GuiManager._SetOverlayZ(this.SepLine, 0)
        if !this._MsgRegistered {
            this._MsgRegistered := true
            OnMessage(0x0200, ObjBindMethod(this, "OnMouseMove"))
        }
        this._Rotate()
        SetTimer(this._RotateCallback, this.RotateIntervalMs)
    }

    ; 主窗口重建前调用
    static Reset() {
        SetTimer(this._RotateCallback, 0)
        this.Started := false
        this.MainGui := ""
        this.SepLine := ""
        this.TextCtrl := ""
        this._Hints := Map()
        this._HoverHwnd := 0
        this._HoverKey := ""
        this._CurrentKey := ""
        this._CurrentArgs := []
        this._CurrentText := ""
        this._LastTip := ""
    }

    ; 登记控件说明
    static Register(ctrl, descKey, argsProvider := "") {
        if (IsObject(ctrl))
            this._Hints[ctrl.Hwnd] := {Key: descKey, Args: argsProvider}
    }

    ; 进程级 WM_MOUSEMOVE（0x0200）
    static OnMouseMove(wParam, lParam, msg, hwnd) {
        if !IsObject(this.MainGui)
            return
        try {
            MouseGetPos(, , &winHwnd, &ctrlHwnd, 2)
            if (ctrlHwnd = this._HoverHwnd)
                return
            this._HoverHwnd := ctrlHwnd
            if (winHwnd != this.MainGui.Hwnd || !this._Hints.Has(ctrlHwnd)) {
                this._HoverKey := ""
                return
            }
            entry := this._Hints[ctrlHwnd]
            this._HoverKey := entry.Key
            args := IsObject(entry.Args) ? entry.Args() : []
            this._SetText(entry.Key, args*)
        } catch Error as e {
            Logger.Debug("StatusBarHints", "OnMouseMove 跳过: " e.Message)
        }
    }

    ; 首次打开设置窗口时的时段问候
    static ShowGreetingOnce() {
        if (this._GreetingShown || !IsObject(this.TextCtrl))
            return
        this._GreetingShown := true
        this._SetText(this._GreetingFor(A_Hour))
        SetTimer(this._RotateCallback, this.RotateIntervalMs)
    }

    ; 按当前小时返回问候语键
    static _GreetingFor(hour) {
        if (hour >= 6 && hour < 11)
            return "早上好！博士！新的一天也要活力满满哦！"
        if (hour >= 11 && hour < 13)
            return "中午好！博士！"
        if (hour >= 13 && hour < 18)
            return "下午好！博士！需要慵懒的时候就要保持慵懒……"
        if (hour >= 18 && hour < 23)
            return "晚上好！博士！要记得好好放松哦"
        if (hour >= 23 || hour < 4)
            return "夜猫子出没中——"
        return "博士……你是刚醒还是没睡？要注意身体哦"
    }

    ; 界面语言切换后刷新当前文本
    static OnLocaleChanged() {
        if (this._CurrentKey = "" || !IsObject(this.TextCtrl))
            return
        this._SetText(this._CurrentKey, this._CurrentArgs*)
    }

    ; 内部：显示指定键的说明（文本未变化时跳过重绘）
    static _SetText(key, args*) {
        text := I18n.T(key, args*)
        if (text = this._CurrentText)
            return
        this._CurrentText := text
        this._CurrentKey := key
        this._CurrentArgs := []
        this._CurrentArgs.Push(args*)
        try this.TextCtrl.Text := text
    }

    ; 定时器回调：悬停在有说明的控件上时暂停轮播
    static _OnRotate() {
        if (this._HoverKey != "")
            return
        this._Rotate()
    }

    ; 内部：从 _TipItems 随机取一条（排除上一条）
    static _Rotate() {
        if (this._TipItems.Length = 0)
            return
        candidates := []
        for item in this._TipItems {
            if (item != this._LastTip)
                candidates.Push(item)
        }
        if (candidates.Length = 0)
            return
        this._LastTip := candidates[Random(1, candidates.Length)]
        this._SetText(this._LastTip)
    }
}
