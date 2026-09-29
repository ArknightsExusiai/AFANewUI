; == 游戏启动器 ==

class GameLauncher {
    ; 初始化启动器
    static Init() {
        EventBus.Subscribe("AppStartCompleted", (*) => this.OnAppStarted())
        EventBus.Subscribe("CheckGamePathClick", (*) => this.CheckGamePath())
    }

    ; 确认是否自动启动
    static OnAppStarted() {
        if (Config.GetImportant("AutoRunGame") == "1") {
            this.Launch()
        }
    }

    ; 识别游戏路径（运行中实例为权威，合并目录特征扫描结果）
    static CheckGamePath() {
        cleanedPaths := this._CleanUpGamePaths()

        GameClientRegistry.Refresh()
        clients := GameClientRegistry.GetClients()
        firstPath := ""
        detected := false
        defaultGamePath := Config.GetImportant("GamePath")
        identified := Map()  ; 已由运行中客户端识别的区服

        for client in clients {
            if (client.exePath = "")
                continue
            detected := true
            if (firstPath = "" && defaultGamePath = "")
                firstPath := client.exePath
            if (client.serverId != "" && client.serverId != "Unknown") {
                identified[client.serverId] := true
                key := "GamePath" client.serverId
                SettingsService.UpdatePersistedValue(key, client.exePath)
                Logger.Info("GameLauncher", "识别到 " client.serverId " 游戏路径：" client.exePath)
            } else if (defaultGamePath = "") {
                SettingsService.UpdatePersistedValue("GamePath", client.exePath)
                Logger.Info("GameLauncher", "识别到未知区服游戏路径：" client.exePath)
            }
        }

        ; 未运行的区服按目录特征扫描
        installed := ServerProfile.FindInstalledPaths()
        for serverId, path in installed {
            detected := true
            if (firstPath = "" && defaultGamePath = "")
                firstPath := path
            if (identified.Has(serverId))
                continue
            key := "GamePath" serverId
            SettingsService.UpdatePersistedValue(key, path)
            Logger.Info("GameLauncher", "扫描识别到 " serverId " 游戏路径：" path)
        }

        if (detected) {
            EventBus.Publish("GamePathDetected", {path: firstPath, clients: clients, installed: installed})
            return
        }
        message := I18n.T("未检测到游戏进程，且未在常见目录找到游戏路径。`n请先启动游戏，或手动填写游戏路径。")
        if (cleanedPaths.Length > 0) {
            Logger.Info("GameLauncher", "识别失败，但已清理 " cleanedPaths.Length " 条无效路径记录")
            message .= "`n`n" I18n.T("未检测到有效游戏路径，已清除下列无效路径记录：`n{2}", cleanedPaths.Length, this._JoinPaths(cleanedPaths))
        }
        MessageBox.Warning(message, I18n.T("识别失败"))
    }

    ; 路径数组拼成多行文本
    static _JoinPaths(paths) {
        text := ""
        for path in paths
            text .= (text = "" ? "" : "`n") path
        return text
    }

    ; 清除无效的游戏路径配置，返回被清除的路径数组
    ; 判定须与 SettingsService 保存校验同源（FileExist + FromExePath）
    static _CleanUpGamePaths() {
        cleaned := []
        for entry in ServerProfile.AllGamePathEntries() {
            path := Config.GetImportant(entry.key)
            if (path = "")
                continue
            reason := ""
            if !FileExist(path)
                reason := I18n.T("路径不存在")
            else if InStr(FileExist(path), "D")
                reason := I18n.T("路径不正确")   ; 目录不是可执行文件
            else {
                info := ServerProfile.FromExePath(path)
                if (info.serverId = "" || info.serverId = "Unknown")
                    reason := I18n.T("路径不正确")
            }
            if (reason = "")
                continue
            label := entry.name != "" ? entry.name " " : ""
            result := SettingsService.UpdatePersistedValue(entry.key, "")
            if (!result.success) {
                Logger.Warn("GameLauncher", "清除无效游戏路径失败（" entry.key "）：" result.message)
                continue
            }
            cleaned.Push("[" reason "] " label path)
            Logger.Info("GameLauncher", "已清除无效游戏路径记录（" entry.key "，" reason "）：" path)
        }
        return cleaned
    }

    ; 启动游戏
    static Launch() {
        gamePath := Config.GetImportant("GamePath")

        if GameClientRegistry.HasClients() || GameTarget.ProcessExists() {
            Logger.Info("GameLauncher", "游戏已在运行，跳过启动")
            return { success: true, message: I18n.T("游戏已在运行") }
        }

        if (gamePath = "" || gamePath = "游戏路径") {
            Logger.Warn("GameLauncher", "游戏路径未配置")
            return { success: false, message: I18n.T("游戏路径未配置，请在设置中指定") }
        }

        if !FileExist(gamePath) {
            Logger.Warn("GameLauncher", "游戏文件不存在：" gamePath)
            return { success: false, message: I18n.T("游戏文件不存在，请检查路径配置") }
        }

        try {
            Run(gamePath)
            Logger.Info("GameLauncher", "游戏已启动：" gamePath)
            return { success: true, message: I18n.T("游戏启动成功") }
        } catch Error as e {
            Logger.Error("GameLauncher", "启动失败：" e.Message)
            return { success: false, message: I18n.T("启动失败：{1}", e.Message) }
        }
    }

    ; 通过 WMI 查询进程路径
    static _GetProcessPathByWmi(pid) {
        try {
            wmi := ComObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
            query := "SELECT ExecutablePath FROM Win32_Process WHERE ProcessId = " pid
            for process in wmi.ExecQuery(query) {
                path := Trim(process.ExecutablePath)
                if (path != "")
                    return path
            }
            return ""
        } catch Error as e {
            Logger.Error("GameLauncher", "WMI 查询失败: " e.Message)
            return ""
        }
    }

    ; 等待游戏启动完成
    static WaitForGame(timeout := 60000) {
        startTime := A_TickCount
        while (A_TickCount - startTime < timeout) {
            if GameClientRegistry.HasClients() || GameTarget.ProcessExists() {
                Logger.Info("GameLauncher", "检测到游戏进程已启动")
                return true
            }
            Sleep(1000)
        }
        Logger.Warn("GameLauncher", "等待游戏启动超时")
        return false
    }
}
