; == 托盘控制器 ==
; 托盘菜单与图标提示的唯一 owner。与界面引擎无关：classic 与 web 都经此初始化与更新。

class TrayController {
    static Engine := "classic"

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
}
