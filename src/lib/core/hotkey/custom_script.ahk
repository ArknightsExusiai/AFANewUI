; == 自定义按键功能引擎 ==
; 「功能码 + 参数文本」模型；触发时零解析、零 IO（O(1) 缓存查表）。

class CustomScriptEngine {
    ; 运行时编译缓存：Map(id -> {valid, steps, type, message})
    static _Runtime := Map()

    static _Builtins := ""

    static _InitBuiltins() {
        if IsObject(this._Builtins)
            return
        this._Builtins := Map(
            "click", ObjBindMethod(this, "_BuiltinClick")
        )
    }

    ; 校验 + 编译「功能 + 参数」，纯函数
    ; 返回 {success, steps: Array<{F, A: Array}>, message}
    static Validate(func, arg) {
        if func != "click"
            return {success: false, steps: [], message: I18n.T("无法识别的功能：{1}", func)}
        arg := Trim(arg)
        if arg = ""
            return {success: true, steps: [], message: ""}
        if RegExMatch(arg, "[\x{3000}\x{FF01}-\x{FF5E}]")
            return {success: false, steps: [], message: I18n.T("包含全角字符，请使用半角符号：{1}", arg)}
        if !RegExMatch(arg, "i)^\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)$", &m)
            return {success: false, steps: [], message: I18n.T("click 需要两个 0-1 之间的小数参数：click(x, y)")}
        x := this._ParseRatio(m[1])
        y := this._ParseRatio(m[2])
        ; 不能用 x = "" 判错：AHK 数值比较会把空字符串当 0，(0, 0) 会被误判
        if !IsNumber(x) || !IsNumber(y)
            return {success: false, steps: [], message: I18n.T("click 坐标需为 0-1 之间、最多 4 位小数")}
        return {success: true, steps: [{F: "click", A: [x, y]}], message: ""}
    }

    ; 内部：解析 0-1 比例小数（最多 4 位）
    static _ParseRatio(text) {
        value := Float(text)
        if value < 0 || value > 1
            return ""
        if RegExMatch(text, "\.(\d+)", &dm) && StrLen(dm[1]) > 4
            return ""
        return value
    }

    ; 从存储文件直读全部条目并刷新编译缓存（慢路径）
    static Reload() {
        this._InitBuiltins()
        this._Runtime := Map()
        for entry in Config.ReadCustomHotkeys() {
            id := "CustomHotkey" entry.Index
            record := {valid: true, steps: [], type: entry.Type, message: ""}
            result := this.Validate(entry.Func, entry.Arg)
            if (!result.success) {
                record.valid := false
                record.message := result.message
                Logger.Warn("CustomScript", "功能校验失败：id=" id ", " result.message)
            } else {
                record.steps := result.steps
            }
            this._Runtime[id] := record
        }
        Logger.Info("CustomScript", "已加载自定义功能缓存，数量=" this._Runtime.Count)
    }

    ; 供 HotkeyService 注册时判断：缓存存在且参数合法
    static IsRegistered(id) {
        if !this._Runtime.Has(id)
            return false
        return this._Runtime[id].valid
    }

    ; 热键触发入口；combat 类型先走关卡守卫
    static RunById(id, ThisHotkey) {
        if !this._Runtime.Has(id) {
            Logger.Warn("CustomScript", "未缓存的按键触发：" id)
            return
        }
        entry := this._Runtime[id]
        if !entry.valid || entry.steps.Length = 0
            return
        Logger.Debug("CustomScript", "触发自定义功能：" id "，步骤数=" entry.steps.Length)
        if entry.type = "combat" && !GuardInLevel("CustomScript:" id, ThisHotkey)
            return
        this.Execute(entry.steps)
        if !InStr(ThisHotkey, "Wheel")
            PureKeyWait(ThisHotkey)
    }

    ; 执行预编译步骤；finally 无条件还原光标
    static Execute(steps) {
        if steps.Length = 0
            return
        Thread "NoTimers"
        if !SafeWinGetClientPos(&ww, &wh) {
            Thread "NoTimers", false
            return
        }
        MouseGetPos(&origX, &origY)
        ctx := {ww: ww, wh: wh, origX: origX, origY: origY}
        try {
            for step in steps {
                if !GameTarget.Exists()
                    break
                this._Builtins[step.F].Call(ctx, step.A*)
            }
        } finally {
            MouseMove ctx.origX, ctx.origY
            Thread "NoTimers", false
        }
    }

    ; ── 内置功能（签名统一为 (ctx, args*)） ──

    ; click：比例 → 客户端像素 → Send 左键点击
    static _BuiltinClick(ctx, fx, fy) {
        x := Round(fx * ctx.ww)
        y := Round(fy * ctx.wh)
        BlockInput "MouseMove"
        MouseMove x, y
        USleep(TimingService.GetCurrentDelay())
        Send "{LButton Down}"
        MouseMove x, y
        Send "{LButton Up}"
        USleep(TimingService.GetCurrentDelay())
        MouseMove ctx.origX, ctx.origY
        BlockInput "MouseMoveOff"
    }
}
