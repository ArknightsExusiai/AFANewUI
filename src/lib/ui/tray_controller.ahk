; == 托盘控制器 ==
; 托盘菜单与图标提示的唯一 owner。与界面引擎无关：classic 与 web 都经此初始化与更新。

class TrayController {
    static Engine := "classic"
    static _EngineItemLabel := ""    ; 引擎切换项当前显示的文字（改名以它为准，与语言变化解耦）
    static _SubscribedLocale := false

    ; 建立（或重建）托盘菜单。不传 engine 时沿用上次的引擎。
    static Init(engine := "") {
        if (engine != "")
            this.Engine := engine
        A_IconTip := "AFA`n" I18n.T("热键已启用")
        A_TrayMenu.Delete
        A_TrayMenu.Add(I18n.T("打开设置界面"), (*) => this.OpenSettings())
        A_TrayMenu.Add(I18n.T("启用/禁用热键"), (*) => EventBus.Publish("HotkeyToggleRequested"))
        A_TrayMenu.Add(I18n.T("重启AFA"), (*) => (SingleInstance.Release(), Reload()))
        A_TrayMenu.Add(I18n.T("退出"), (*) => ExitApp())
        ; 引擎切换项必须追加在末尾：SetHotkeyItemLabel 按 "2&" 位置寻址，往前插会改错菜单项。
        A_TrayMenu.Add()
        this._SubscribeLocale()
        this._EngineItemLabel := this.EngineSwitchLabel()
        A_TrayMenu.Add(this._EngineItemLabel, (*) => this.SwitchEngine())
        A_TrayMenu.Default := I18n.T("打开设置界面")
    }

    static OpenSettings() {
        UiShell.Show()
    }

    static SetTooltip(text) {
        A_IconTip := text
    }

    ; 托盘第 2 项（启用/禁用热键）附带当前切换键
    static SetHotkeyItemLabel(text) {
        A_TrayMenu.Rename("2&", text)
    }

    ; 托盘提示带当前前台区服；切到桌面/非游戏窗口时保留上次游戏区服（否则显示“未知区服”）
    static UpdateServer(serverId) {
        if (serverId = "")
            return
        serverName := I18n.T("未知区服")
        profile := ServerProfile.Get(serverId)
        if (profile != "")
            serverName := I18n.T(profile.DisplayNameKey)
        state := HotkeyService.HotkeyState ? I18n.T("热键已启用") : I18n.T("热键已禁用")
        A_IconTip := "AFA`n" serverName " - " state
    }

    ; 菜单项文字显示的是"点下去会切到哪"那一侧，故当前是 web 时显示经典。
    static EngineSwitchLabel() {
        return this.Engine = "web" ? I18n.T("切换到经典UI") : I18n.T("切换到现代UI")
    }

    ; 语言切换当下不重建托盘菜单（整体重建要等保存/应用后的 GuiManager.Init），故引擎项自己跟一次，避免卡在旧语言。
    static _SubscribeLocale() {
        if (this._SubscribedLocale)
            return
        this._SubscribedLocale := true
        EventBus.Subscribe("LocaleChanged", (*) => this.RefreshEngineItem())
    }

    ; 按当前引擎与语言刷新切换项文字；改名以"实际显示的那串文字"为依据。
    static RefreshEngineItem() {
        if (StrLen(this._EngineItemLabel) = 0)
            return
        newLabel := this.EngineSwitchLabel()
        if (newLabel = this._EngineItemLabel)
            return
        A_TrayMenu.Rename(this._EngineItemLabel, newLabel)
        this._EngineItemLabel := newLabel
    }

    ; 切换界面引擎。宿主在 Bootstrap 时建立，故写配置后需重启 AFA 才生效。
    static SwitchEngine() {
        next := this.Engine = "web" ? "classic" : "web"
        result := SettingsService.UpdatePersistedValue("UiEngine", next)
        if (!result.success) {
            Logger.Error("TrayController", "界面引擎切换失败：" result.message)
            MessageBox.Warning(I18n.T("界面引擎切换失败，详见日志"), I18n.T("界面引擎"))
            return
        }
        this.Engine := next
        ; 立即改名，避免用户误以为未点击生效。
        this.RefreshEngineItem()
        Logger.Info("TrayController", "界面引擎已切换为 " next "，重启后生效")
        MessageBox.Info(I18n.T("已切换界面引擎，重启 AFA 后生效"), I18n.T("界面引擎"))
    }
}
