; == 托盘控制器 ==
; 托盘菜单与图标提示的唯一 owner

class TrayController {
    static Engine := "classic"
    static _EngineItemLabel := ""    ; 引擎切换项当前显示的文字
    static _SubscribedLocale := false
    static _SubscribedRefresh := false
    static _LastServerId := ""       ; 最近一次前台区服

    ; 建立（或重建）托盘菜单
    static Init(engine := "") {
        if (engine != "")
            this.Engine := engine
        this._RenderTooltip(this._LastServerId)
        A_TrayMenu.Delete
        A_TrayMenu.Add(I18n.T("打开设置界面"), (*) => this.OpenSettings())
        A_TrayMenu.Add(I18n.T("启用/禁用热键"), (*) => EventBus.Publish("HotkeyToggleRequested"))
        A_TrayMenu.Add(I18n.T("重启AFA"), (*) => (SingleInstance.Release(), Reload()))
        A_TrayMenu.Add(I18n.T("退出"), (*) => ExitApp())
        A_TrayMenu.Add()
        this._SubscribeLocale()
        this._SubscribeRefresh()
        this._EngineItemLabel := this.EngineSwitchLabel()
        A_TrayMenu.Add(this._EngineItemLabel, (*) => this.SwitchEngine())
        A_TrayMenu.Default := I18n.T("打开设置界面")
        this.RefreshHotkeyItem(Config.ReadCustomFromIni("SwitchHotkey"))
    }

    static OpenSettings() {
        UiShell.Show()
    }

    static SetTooltip(text) {
        A_IconTip := text
    }

    ; （启用/禁用热键）附带当前切换键
    static SetHotkeyItemLabel(text) {
        A_TrayMenu.Rename("2&", text)
    }
    static RefreshHotkeyItem(key) {
        if (StrLen(key) = 0)
            this.SetHotkeyItemLabel(I18n.T("启用/禁用热键"))
        else
            this.SetHotkeyItemLabel(I18n.T("启用/禁用热键") "(" KeyFormat.VirtualNewkeyFormat(key) ")")
    }

    ; 托盘提示带当前前台区服；切到桌面/非游戏窗口时保留上次游戏区服（否则显示“未知区服”）
    static UpdateServer(serverId) {
        if (serverId = "")
            return
        this._LastServerId := serverId
        this._RenderTooltip(serverId)
    }

    ; 提示内容的唯一渲染入口。状态取实时值；无区服时只显示状态
    static _RenderTooltip(serverId) {
        state := HotkeyService.HotkeyState ? I18n.T("热键已启用") : I18n.T("热键已禁用")
        if (StrLen(serverId) = 0)
            this.SetTooltip("AFA`n" state)
        else
            this.SetTooltip("AFA`n" this._ServerName(serverId) " - " state)
    }

    static _ServerName(serverId) {
        profile := ServerProfile.Get(serverId)
        return profile != "" ? I18n.T(profile.DisplayNameKey) : I18n.T("未知区服")
    }

    static EngineSwitchLabel() {
        return this.Engine = "web" ? I18n.T("切换到经典UI") : I18n.T("切换到现代UI")
    }

    ; 语言切换当下不重建托盘菜单
    static _SubscribeLocale() {
        if (this._SubscribedLocale)
            return
        this._SubscribedLocale := true
        EventBus.Subscribe("LocaleChanged", (*) => this.RefreshEngineItem())
    }

    ; 按当前引擎与语言刷新切换项文字
    static RefreshEngineItem() {
        if (StrLen(this._EngineItemLabel) = 0)
            return
        newLabel := this.EngineSwitchLabel()
        if (newLabel = this._EngineItemLabel)
            return
        A_TrayMenu.Rename(this._EngineItemLabel, newLabel)
        this._EngineItemLabel := newLabel
    }

    ; 运行期刷新订阅
    static _SubscribeRefresh() {
        if (this._SubscribedRefresh)
            return
        this._SubscribedRefresh := true
        EventBus.Subscribe("SwitchKeyChanged", (data) => this.RefreshHotkeyItem(data.key))
        EventBus.Subscribe("ForegroundClientChanged", (data) => this.UpdateServer(data.serverId))
        EventBus.Subscribe("HotkeyStateChanged", (*) => this._RenderTooltip(this._LastServerId))
    }

    ; 切换界面引擎
    static SwitchEngine() {
        next := this.Engine = "web" ? "classic" : "web"
        result := SettingsService.UpdatePersistedValue("UiEngine", next)
        if (!result.success) {
            Logger.Error("TrayController", "界面引擎切换失败：" result.message)
            MessageBox.Warning(I18n.T("界面引擎切换失败，详见日志"), I18n.T("界面引擎"))
            return
        }
        this.Engine := next
        ; 立即改名
        this.RefreshEngineItem()
        Logger.Info("TrayController", "界面引擎已切换为 " next "，重启后生效")
        MessageBox.Info(I18n.T("已切换界面引擎，重启 AFA 后生效"), I18n.T("界面引擎"))
    }
}
