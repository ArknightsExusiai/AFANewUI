; == 界面引擎分派（classic / web） ==
; 设置界面的启动与显示统一走这里，调用方不需要知道当前用的是哪套引擎。

class UiShell {
    static Engine := "classic"
    static _Subscribed := false

    ; 启动设置界面。托盘引擎无关，先于引擎分派初始化。
    ; 引擎初始化失败只允许回落到经典界面，异常不得向外传播：
    ; Bootstrap() 在分派之后还要初始化 UpdateUI / GameMonitor / HookMonitor。
    static Start() {
        this.Engine := "classic"
        try {
            this.Engine := Constants.NormalizeUiEngine(Config.GetImportant("UiEngine"))
            this._Subscribe()
            TrayController.Init(this.Engine)
            Logger.Info("UiShell", "设置界面引擎：" this.Engine)
            if (this.Engine = "web") {
                Logger.Warn("UiShell", "UiEngine=web 尚未接入，本次使用经典界面")
                this.Engine := "classic"
            }
        } catch Error as e {
            Logger.Error("UiShell", "界面引擎初始化失败，回落到经典界面：" e.Message)
            this.Engine := "classic"
        }
        GuiManager.Start()
    }

    static Show() {
        GuiManager.Show()
    }

    static _Subscribe() {
        if (this._Subscribed)
            return
        this._Subscribed := true
        EventBus.Subscribe("SettingsShowRequested", (*) => this.Show())
    }
}
