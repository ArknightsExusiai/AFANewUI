; == 界面引擎分派（classic / web） ==
; 设置界面的启动与显示统一走这里，调用方不需要知道当前用的是哪套引擎。

class UiShell {
    static Engine := "classic"
    static _Subscribed := false

    ; 启动设置界面。托盘引擎无关，先于引擎分派初始化。
    static Start() {
        this.Engine := Constants.NormalizeUiEngine(Config.GetImportant("UiEngine"))
        this._Subscribe()
        TrayController.Init(this.Engine)
        Logger.Info("UiShell", "设置界面引擎：" this.Engine)
        if (this.Engine = "web") {
            Logger.Warn("UiShell", "UiEngine=web 尚未接入，本次使用经典界面")
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
