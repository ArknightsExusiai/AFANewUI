; == 托盘提示工具 ==

; 隐藏 TrayTip
HideTrayTip() {
    TrayTip
}

; 显示 TrayTip
ShowTrayTip(message, title := "", options := "") {
    Logger.Debug("Tray", "弹出托盘提示 title=" title " message=" SubStr(message, 1, 120))
    TrayTip(message, title, options)
}
