; web 引擎宿主（WebView2）：创建承载窗口与控制器、映射静态资源目录、承载前端页面。
; 本类只订阅事件、不发布事件；界面失败一律回落经典界面。

class WebHost {
    static VIRTUAL_HOST := "afa.app"
    static CREATE_TIMEOUT_MS := 15000
    static READY_TIMEOUT_MS := 8000

    static Gui := ""
    static Controller := ""
    static CoreWV := ""
    static Ready := false      ; 控制器已创建并已导航，不代表页面已加载
    static PageReady := false  ; 前端已上报 ready

    static _Activated := false
    static _FellBack := false
    static _Notified := false
    static _ReadyFn := ""

    ; 入口。安检！安检！通过则由 web 引擎接管并返回 true；否则返回 false，false就会让调用的那个地方自己处理回落经典界面。
    static Activate() {
        if (this._Activated)
            return !this._FellBack
        this._Activated := true
        reason := ""
        if (!this._CheckViable(&reason)) {
            this._FellBack := true
            Logger.Warn("WebHost", "web 引擎不可用：" reason)
            this._Notify()
            return false
        }
        EventBus.Subscribe("SettingsShowRequested", (*) => this.Show())
        EventBus.Subscribe("LocaleChanged", (*) => this._OnLocaleChanged())
        Logger.Info("WebHost", "web 引擎已就绪，Runtime=" WebViewRuntime.GetVersion())
        if (Config.ReadImportantFromIni("AutoOpenSettings") = "1")
            this.Show()
        return true
    }

    static Show() {
        if (this._FellBack) {
            GuiManager.Show()
            return
        }
        if (this.Ready && this.Gui != "") {
            this.Gui.Show()
            this._FillController()
            return
        }
        this._Start()
    }

    static RequestHide() {
        if (this.Gui != "")
            this.Gui.Hide()
    }

    static _Start() {
        try {
            this.Gui := Gui("+Resize", this._WindowTitle())
            this.Gui.OnEvent("Close", (*) => this._OnClose())
            this.Gui.OnEvent("Size", (*) => this._FillController())
            ; 控制器必须在窗口可见时创建：隐藏窗口的客户区为 0，库的自动 Fill 会写入 0 尺寸视口，
            ; 渲染合成器不启动，之后显示也无法恢复（表现为页面全空白）。
            this.Gui.Show("w760 h620")
        } catch Error as e {
            this._Fallback("创建承载窗口失败：" e.Message)
            return
        }
        try {
            Theme.Attach(this.Gui)
        } catch Error as e {
            Logger.Warn("WebHost", "窗口主题登记失败（继续）：" e.Message)
        }
        try {
            this.Controller := WebView2.CreateControllerAsync(this.Gui.Hwnd, , this._UserDataDir()).await2(this.CREATE_TIMEOUT_MS)
            this.CoreWV := this.Controller.CoreWebView2
        } catch Error as e {
            this._Fallback("WebView2 控制器创建失败：" e.Message)
            return
        }
        try {
            settings := this.CoreWV.Settings
            settings.IsWebMessageEnabled := true
            settings.AreDefaultContextMenusEnabled := false
            settings.IsStatusBarEnabled := false
            settings.IsSwipeNavigationEnabled := false
        } catch Error as e {
            Logger.Warn("WebHost", "WebView2 设置部分失败（继续加载）：" e.Message)
        }
        try {
            ; accessKind 1 = ALLOW；传 0（DENY）会拒绝虚拟源下的全部资源，页面全空白。
            this.CoreWV.SetVirtualHostNameToFolderMapping(this.VIRTUAL_HOST, this._AssetsDir(), 1)
        } catch Error as e {
            this._Fallback("虚拟源映射失败：" e.Message)
            return
        }
        try {
            this.CoreWV.add_WebMessageReceived(ObjBindMethod(this, "_OnWebMessageReceived"))
        } catch Error as e {
            Logger.Warn("WebHost", "绑定前端消息失败（界面将无法与内核通信）：" e.Message)
        }
        try {
            this.CoreWV.Navigate("https://" this.VIRTUAL_HOST "/index.html")
        } catch Error as e {
            this._Fallback("页面导航失败：" e.Message)
            return
        }
        this.Ready := true
        this.PageReady := false
        this._ArmReadyTimeout()
        if (Config.ReadImportantFromIni("DebugEnabled") = "1") {
            try this.CoreWV.OpenDevToolsWindow()
        }
        Logger.Info("WebHost", "web 引擎已启动")
    }

    static _CheckViable(&reason) {
        if (!WebViewRuntime.IsAvailable()) {
            reason := "未安装 WebView2 Runtime"
            return false
        }
        if (!this._EnsureAssets()) {
            reason := "界面资源缺失：" this._AssetsDir()
            return false
        }
        return true
    }

    ; 编译版由资源提取阶段提供页面，当前只在源码运行时可用。
    static _EnsureAssets() {
        if (A_IsCompiled)
            return false
        return StrLen(FileExist(this._AssetsDir() "\index.html")) > 0
    }

    static _AssetsDir() {
        return A_ScriptDir "\lib\ui\web\app"
    }

    ; 库的默认用户数据目录是本机共享的 Edge 用户数据根，多应用会互相干扰，故指定应用私有目录。
    static _UserDataDir() {
        return A_AppData "\ArknightsFrameAssistant\PC\webview2"
    }

    static _WindowTitle() {
        return I18n.T("明日方舟帧操小助手 ArknightsFrameAssistant - {1}", Version.Get())
    }

    static _OnClose() {
        if (Config.ReadImportantFromIni("ExitOnWindowClose") = "1") {
            ExitApp()
            return
        }
        this.RequestHide()
    }

    static _OnLocaleChanged() {
        if (this.Gui != "")
            this.Gui.Title := this._WindowTitle()
    }

    ; 让控制器填满当前客户区：创建时窗口可能尚未布局完成，库的自动 Fill 会拿到 0 尺寸，
    ; 故每次显示与尺寸变化后都要重新 Fill，否则内容区为 0 宽、页面空白。
    ; 打开时闪一下的问题出自这里吗？不确定欸。。。
    static _FillController() {
        if (this.Controller = "")
            return
        try this.Controller.Fill()
    }

    static _OnWebMessageReceived(sender, args) {
        try {
            text := this._ExtractMessageText(args)
            if (text = "ready")
                this._OnPageReady()
            else if (StrLen(text) > 0)
                Logger.Debug("WebHost", "收到前端消息：" text)
        } catch Error as e {
            Logger.Error("WebHost", "处理前端消息失败：" e.Message)
        }
    }

    static _OnPageReady() {
        if (this.PageReady)
            return
        this.PageReady := true
        this._DisarmReadyTimeout()
        Logger.Info("WebHost", "界面已上报 ready")
    }

    ; 前端 postMessage(字符串) 时 WebMessageAsJson 是带引号的 JSON 字符串字面量，需还原。
    static _ExtractMessageText(args) {
        try {
            json := args.WebMessageAsJson
            if (StrLen(json) > 0)
                return this._UnwrapJsonString(json)
        }
        try
            return args.TryGetWebMessageAsString()
        return ""
    }

    static _UnwrapJsonString(json) {
        if (SubStr(json, 1, 1) = '"' && SubStr(json, -1) = '"')
            return SubStr(json, 2, -2)
        return json
    }

    static _ArmReadyTimeout() {
        this._DisarmReadyTimeout()
        this._ReadyFn := ObjBindMethod(this, "_OnReadyTimeout")
        SetTimer(this._ReadyFn, -this.READY_TIMEOUT_MS)
    }

    ; SetTimer 的启动与取消必须用同一函数对象，故函数对象缓存在静态属性上。
    static _DisarmReadyTimeout() {
        if (!IsObject(this._ReadyFn))
            return
        SetTimer(this._ReadyFn, 0)
        this._ReadyFn := ""
    }

    static _OnReadyTimeout() {
        this._ReadyFn := ""
        if (this.PageReady || this._FellBack)
            return
        Logger.Warn("WebHost", "界面未在 " this.READY_TIMEOUT_MS " ms 内上报 ready")
        this._Notify(I18n.T("界面未能加载，可切回经典UI"))
    }

    ; 再次保证能正常使用
    ; 运行期失败：提示一次、销毁窗口并回落经典界面。预检失败不走这里（由 UiShell 接住）。
    static _Fallback(reason) {
        this._FellBack := true
        Logger.Warn("WebHost", "web 引擎回落经典界面：" reason)
        this._Notify()
        this._DestroyGui()
        GuiManager.Start()
    }

    static _DestroyGui() {
        this._DisarmReadyTimeout()
        try {
            if (this.Controller != "")
                this.Controller.Close()
        }
        if (this.Gui != "") {
            try Theme.Destroy(this.Gui)
            try this.Gui.Destroy()
        }
        this.Gui := ""
        this.Controller := ""
        this.CoreWV := ""
        this.Ready := false
    }

    ; 托盘通知
    ; 提示一次
    static _Notify(message := "") {
        if (this._Notified)
            return
        this._Notified := true
        text := StrLen(message) > 0 ? message : I18n.T("现代UI（WebView2）不可用，已回退到经典UI，详见日志")
        try TrayTip(text, I18n.T("界面引擎"))
    }
}
