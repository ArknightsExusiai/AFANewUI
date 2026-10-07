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
        ; 引擎切换项必须追加在末尾：SetHotkeyItemLabel 按 "2&" 位置寻址，往前插会改错菜单项。
        A_TrayMenu.Add()
        A_TrayMenu.Add(this.EngineSwitchLabel(), (*) => this.SwitchEngine())
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

    ; 当UI是a时显示切换到b，当UI是b时显示切换到a。欸还需要重启才能生效呀🤔。所以这里要实时显示状态————emmmmmmmmmmmmmmmmmmmm让我想想怎么办。好的后面解决了
    static EngineSwitchLabel() {
        return this.Engine = "web" ? I18n.T("切换到经典UI") : I18n.T("切换到现代UI")
    }

    ; 切换界面引擎。宿主在 Bootstrap 时建立，故写配置后需重启 AFA 才生效。应该给个明显一点的提示要求重启，就像有人没保存就以为是bug。。。
    static SwitchEngine() {
        oldLabel := this.EngineSwitchLabel()
        next := this.Engine = "web" ? "classic" : "web"
        SettingsService.UpdatePersistedValue("UiEngine", next)
        this.Engine := next
        ; 立即在托盘把名字改过来防止有人点了一次没重启以为没点到然后总共点了偶数次发现重启还是原来的UI界面（应该不会有人这样吧，但是万一呢）。
        A_TrayMenu.Rename(oldLabel, this.EngineSwitchLabel())
        Logger.Info("TrayController", "界面引擎已切换为 " next "，重启后生效")
        MessageBox.Info(I18n.T("已切换界面引擎，重启 AFA 后生效"), I18n.T("界面引擎"))
        ; 完了我感觉工作量有点大。这样引擎的切换应该算是完成了吧我去。前端的话慢慢搞咯。先把这个放进仓库里让老大看看做得怎么样。
    }
}
