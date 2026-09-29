; == 区服元数据与识别 ==

class ServerProfile {

    static ExeName := "Arknights.exe"

    ; 区服元数据表（按 id 查找用，枚举顺序见 Order）
    static Profiles := Map(
        "CN", {Id: "CN", DisplayNameKey: "国服", Company: "HyperGryph", Product: "Arknights", DirectoryHint: "Arknights Game", Locale: "zh-CN", ScanPaths: ["Arknights Game\Arknights.exe", "games\Arknights\Arknights.exe"]},
        "BILI", {Id: "BILI", DisplayNameKey: "哔哩哔哩服", Company: "HyperGryph", Product: "Arknights", DirectoryHint: "Arknights bilibili", Locale: "zh-CN", ScanPaths: ["Arknights bilibili\games\Arknights\Arknights.exe"]},
        "TC", {Id: "TC", DisplayNameKey: "繁中服", Company: "Gryphline", Product: "Arknights_TC", DirectoryHint: "Arknights_TC", Locale: "zh-Hant"},
        "JP", {Id: "JP", DisplayNameKey: "日服", Company: "Yostar", Product: "Arknights_JP", DirectoryHint: "Arknights_JP", Locale: "ja-JP"},
        "KR", {Id: "KR", DisplayNameKey: "韩服", Company: "Yostar", Product: "Arknights_KR", DirectoryHint: "Arknights_KR", Locale: "ko-KR"},
        "EN", {Id: "EN", DisplayNameKey: "国际服", Company: "Yostar", Product: "Arknights_EN", DirectoryHint: "Arknights_EN", Locale: "en-US"}
    )

    ; 区服优先级 / 枚举序（新增区服需同步登记）
    static Order := ["CN", "BILI", "TC", "JP", "KR", "EN"]

    ; 按 serverId 获取元数据
    static Get(serverId) {
        if this.Profiles.Has(serverId)
            return this.Profiles[serverId]
        return ""
    }

    ; 已知区服 id 列表
    static Ids() {
        result := []
        for id in this.Order
            result.Push(id)
        return result
    }

    ; 全部游戏路径配置项的有序列表
    ; 返回 Array<{key, serverId, name}>
    static AllGamePathEntries() {
        entries := [{key: "GamePath", serverId: "", name: ""}]
        for serverId in this.Ids() {
            profile := this.Get(serverId)
            entries.Push({
                key: "GamePath" serverId,
                serverId: serverId,
                name: profile != "" ? I18n.T(profile.DisplayNameKey) : serverId
            })
        }
        return entries
    }

    ; 从可执行文件完整路径推断区服
    ; 返回 {serverId, company, product, registryRoot, source}
    static FromExePath(exePath) {
        if (exePath = "")
            return this._Unknown("", "")

        SplitPath(exePath, &fileName, &exeDir)
        if (StrLower(fileName) != StrLower(this.ExeName)) {
            ; 只接受名为 Arknights.exe 的文件（游戏目录请用 FromGameDir）
            return this._Unknown("", "")
        }

        ; XelLauncher 链接运行环境的渠道段
        xelServerId := this._DetectXelLinkedRuntime(exeDir)
        if (xelServerId != "") {
            profile := this.Get(xelServerId)
            return {
                serverId: xelServerId,
                company: profile.Company,
                product: profile.Product,
                registryRoot: "HKCU\Software\" profile.Company "\" profile.Product,
                source: "xel_linked_runtime"
            }
        }

        ; 安装目录特征
        for serverId in this.Order {
            profile := this.Get(serverId)
            if (profile.DirectoryHint != "" && InStr(exeDir, profile.DirectoryHint, false)) {
                ; 渠道文件校正（仅目录特征判定为 CN 时）
                if (serverId = "CN") {
                    deployed := this._DetectDeployedChannel(exeDir)
                    if (deployed != "")
                        serverId := deployed
                }
                profile := this.Get(serverId)
                return {
                    serverId: serverId,
                    company: profile.Company,
                    product: profile.Product,
                    registryRoot: "HKCU\Software\" profile.Company "\" profile.Product,
                    source: "directory_hint"
                }
            }
        }

        ; app.info
        appInfo := this._ReadAppInfo(exeDir)
        if (appInfo.company != "" && appInfo.product != "") {
            for serverId in this.Order {
                profile := this.Get(serverId)
                if (StrLower(profile.Company) = StrLower(appInfo.company)
                    && StrLower(profile.Product) = StrLower(appInfo.product)) {
                    return {
                        serverId: serverId,
                        company: appInfo.company,
                        product: appInfo.product,
                        registryRoot: "HKCU\Software\" appInfo.company "\" appInfo.product,
                        source: "app_info"
                    }
                }
            }
            ; app.info 有值但不在内置表：按新服处理
            return {
                serverId: "Unknown",
                company: appInfo.company,
                product: appInfo.product,
                registryRoot: "HKCU\Software\" appInfo.company "\" appInfo.product,
                source: "app_info_unknown"
            }
        }

        ; 注册表存在性
        for serverId in this.Order {
            if (this._RegistryHasKeyboardSetting(serverId)) {
                profile := this.Get(serverId)
                return {
                    serverId: serverId,
                    company: profile.Company,
                    product: profile.Product,
                    registryRoot: "HKCU\Software\" profile.Company "\" profile.Product,
                    source: "registry"
                }
            }
        }

        ; 无法识别
        return this._Unknown("", "")
    }

    ; 识别 XelLauncher 链接运行环境目录的渠道段（Official→CN / Bilibili→BILI）
    static _DetectXelLinkedRuntime(exeDir) {
        if (exeDir = "" || !InStr(exeDir, ".xel-linked-runtime", false))
            return ""
        parts := StrSplit(exeDir, "\")
        for index, part in parts {
            if (part != "" && InStr(part, ".xel-linked-runtime", false)) {
                channelIndex := index + 3
                if (channelIndex > parts.Length)
                    return ""
                channel := parts[channelIndex]
                if (channel = "")
                    return ""
                if (StrLower(channel) = "official")
                    return "CN"
                if (StrLower(channel) = "bilibili")
                    return "BILI"
                return ""
            }
        }
        return ""
    }

    ; 探测游戏目录实际部署的渠道（传统切服）
    static _DetectDeployedChannel(exeDir) {
        officialMark := exeDir "\hgsdk.dll"
        biliMark := exeDir "\PCGameSDK.dll"
        biliDir := exeDir "\BLPlatform64"
        officialDeployed := FileExist(officialMark) != ""
        biliDeployed := FileExist(biliMark) != "" && InStr(FileExist(biliDir), "D") > 0
        if (officialDeployed && !biliDeployed)
            return "CN"
        if (biliDeployed && !officialDeployed)
            return "BILI"
        return ""
    }

    ; 从游戏目录推断区服
    static FromGameDir(gameDir) {
        if (gameDir = "")
            return this._Unknown("", "")
        gameDir := RTrim(gameDir, "\")
        return this.FromExePath(gameDir "\" this.ExeName)
    }

    ; 按 serverId 返回注册表根
    static RegistryRoot(serverId) {
        profile := this.Get(serverId)
        if (profile = "")
            return ""
        return "HKCU\Software\" profile.Company "\" profile.Product
    }

    ; 根据 company/product 返回注册表根
    static RegistryRootByCompanyProduct(company, product) {
        if (company = "" || product = "")
            return ""
        return "HKCU\Software\" company "\" product
    }

    ; 按已知目录特征扫描常见位置
    ; 返回 serverId → exePath（Map）
    static FindInstalledPaths() {
        result := Map()
        for serverId in this.Ids() {
            path := this._FindServerPath(serverId)
            if (path != "")
                result[serverId] := path
        }
        return result
    }

    ; 在固定磁盘常见父目录中查找指定区服的 exe
    static _FindServerPath(serverId) {
        profile := this.Get(serverId)
        if (profile = "")
            return ""
        dirName := profile.DirectoryHint
        if (dirName = "")
            return ""

        configured := Config.GetImportant("GamePath" serverId)
        if (configured != "" && FileExist(configured))
            return configured

        legacy := Config.GetImportant("GamePath")
        if (legacy != "" && FileExist(legacy)) {
            legacyInfo := this.FromExePath(legacy)
            if (legacyInfo.serverId = serverId)
                return legacy
        }

        scanPaths := profile.HasOwnProp("ScanPaths") ? profile.ScanPaths : [dirName "\Arknights.exe"]

        for drive in this._FixedDriveLetters() {
            root := drive ":\"
            for scanPath in scanPaths {
                candidate := root scanPath
                if FileExist(candidate)
                    return candidate
            }

            ; 常见启动器安装目录
            for parent in ["YostarGames", "Hypergryph Launcher", "GRYPHLINK"] {
                for scanPath in scanPaths {
                    candidate := root parent "\" scanPath
                    if FileExist(candidate)
                        return candidate
                    candidate := root parent "\games\" scanPath
                    if FileExist(candidate)
                        return candidate
                }
            }
        }
        return ""
    }

    static _FixedDriveLetters() {
        result := []
        list := DriveGetList("FIXED")
        for letter in StrSplit(list)
            result.Push(letter)
        return result
    }

    ; 某区服的注册表根是否存在
    static RegistryRootExists(serverId) {
        return this._RegistryKeyExists(this.RegistryRoot(serverId))
    }

    ; 某服注册表根下是否存在 KEYBOARD_SETTING_V* 键值
    static _RegistryHasKeyboardSetting(serverId) {
        root := this.RegistryRoot(serverId)
        if (root = "" || !this._RegistryKeyExists(root))
            return false
        try {
            Loop Reg, root, "V" {
                if (InStr(A_LoopRegName, "KEYBOARD_SETTING_V") = 1)
                    return true
            }
        } catch Error as e {
            Logger.Debug("ServerProfile", "注册表按键设置检查失败：" root " - " e.Message)
        }
        return false
    }

    ; 通过 RegOpenKeyEx 判断注册表键是否存在
    static _RegistryKeyExists(root) {
        if (root = "")
            return false
        rootHandle := 0
        subkey := ""
        if RegExMatch(root, "i)^HKCU\\", &m)
            rootHandle := 0x80000001 ; HKEY_CURRENT_USER
        else if RegExMatch(root, "i)^HKLM\\", &m)
            rootHandle := 0x80000002 ; HKEY_LOCAL_MACHINE
        else if RegExMatch(root, "i)^HKCR\\", &m)
            rootHandle := 0x80000000 ; HKEY_CLASSES_ROOT
        else if RegExMatch(root, "i)^HKU\\", &m)
            rootHandle := 0x80000003 ; HKEY_USERS
        else if RegExMatch(root, "i)^HKCC\\", &m)
            rootHandle := 0x80000005 ; HKEY_CURRENT_CONFIG
        else
            return false

        if RegExMatch(root, "i)^[A-Z]+\\", &m)
            subkey := SubStr(root, m.Len[0] + 1)
        if (subkey = "")
            return true

        phk := 0
        ; KEY_READ = 0x20019
        result := DllCall("Advapi32\RegOpenKeyExW", "Ptr", rootHandle, "Str", subkey, "UInt", 0, "UInt", 0x20019, "Ptr*", &phk, "Int")
        if (result = 0) {
            DllCall("Advapi32\RegCloseKey", "Ptr", phk)
            return true
        }
        return false
    }

    ; 读取 <exeDir>\Arknights_Data\app.info（两行分别为 companyName / productName）
    static _ReadAppInfo(exeDir) {
        result := {company: "", product: ""}
        path := exeDir "\Arknights_Data\app.info"
        if !FileExist(path)
            return result
        try {
            file := FileOpen(path, "r")
            if !IsObject(file)
                return result
            try {
                line := file.ReadLine()
                result.company := Trim(StrReplace(line, Chr(0xFEFF), ""))
                line := file.ReadLine()
                result.product := Trim(StrReplace(line, Chr(0xFEFF), ""))
            } finally {
                file.Close()
            }
        } catch Error as e {
            Logger.Warn("ServerProfile", "读取 app.info 失败：" e.Message)
        }
        return result
    }

    static _Unknown(company, product) {
        return {
            serverId: "Unknown",
            company: company,
            product: product,
            registryRoot: (company != "" && product != "") ? ("HKCU\Software\" company "\" product) : "",
            source: "unknown"
        }
    }
}
