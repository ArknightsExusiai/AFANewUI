; == 热键控制 ==
; 热键上下文判定（HotIf 回调），三分支：Up 变体查键级状态、鼠标键/滚轮查悬停、键盘键查活动窗口。
; - Up 变体：该键 down 已被 AFA 处理过即放行补发 up，解决"按住后拖出游戏/切走再松开"的卡键。
; - 鼠标键/滚轮：仅光标悬停在游戏窗口上时触发（不受失焦悬停开关影响）。
; - 键盘键：游戏为活动窗口，或启用 _HoverOperate（失焦悬停）时悬停在游戏上；动作层负责激活窗口。
HotkeyContext(hotkeyName) {
    pureKey := KeyForward.PureKeyName(hotkeyName)
    if (pureKey = "")
        return false
    ; 单次 HotIf 求值计时：求值本身就发生在钩子判定路径上，主线程在此停留多久直接决定钩子会不会超时。
    evalStart := Qpc()

    ; Up 变体（守卫补发型）：仅当 down 已被 AFA 处理过（DownHandled 有记录，无论放行/拦截）才放行补发 up；
    ; 游戏外主热键不触发（down 已透传）则不放行，物理 up 正常透传（不影响打字）
    if RegExMatch(hotkeyName, " Up$") {
        ; 补发 up 期间钩子会捕获 Send 注入的 up，仍放行会递归触发 Up 变体（游戏外按键失灵）；
        ; 只抑制同名键——全局布尔会在多键同松时误挡其它键的 Up 变体（卡键）
        if KeyForward.SuppressUp.Has(pureKey)
            return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, false)
        if KeyForward.DownHandled.Has(pureKey)
            return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    }
    ; 鼠标键/滚轮：悬停判定
    if (pureKey ~= "i)^(lbutton|rbutton|mbutton|xbutton1|xbutton2|wheel)")
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, IsMouseInClient())
    ; 键盘键：优先走热路径廉价校验（前台 hwnd→pid 与缓存比对），未命中才回退旧语义并异步补识别
    if GameTarget.IsForegroundCached()
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    if WinActive(GameTarget.WinTitle()) {
        GameClientRegistry.ScheduleRefresh()
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    }
    ; 失焦悬停操作开关关闭后，键盘键仅当游戏为活动窗口时才触发
    return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, HotkeyService.GetHoverOperate() && IsMouseInClient())
}

class HotkeyService {
    ; 热键状态
    static HotkeyState := true

    ; 失焦悬停路径等待窗口激活的超时：该等待期线程不可中断，必须显著小于系统低级钩子超时（默认 300ms）
    static ActivateTimeoutMs := 200

    ; 游戏失焦悬停操作开关（由 SettingsService 在保存/应用后刷新）
    static _HoverOperate := true

    static SetHoverOperate(value) {
        this._HoverOperate := value
    }

    static GetHoverOperate() {
        return this._HoverOperate
    }

    ; HotkeyContext 的统一出口：记录单次求值耗时（ctxEval）并原样回传判定结果；
    ; 热路径只多两次 QPC 读点（频率已由 Qpc() 内部缓存）
    static _TraceEval(hotkeyName, pureKey, evalStart, matched) {
        elapsedMs := QpcMs(Qpc() - evalStart)
        if (elapsedMs >= 0) {
            this._EvalCount++
            this._EvalTotalMs += elapsedMs
            if (elapsedMs > this._EvalMaxMs)
                this._EvalMaxMs := elapsedMs
            if (elapsedMs >= this.EvalWarnThresholdMs && A_TickCount >= this._NextEvalWarnTick) {
                this._NextEvalWarnTick := A_TickCount + this._TelemetryWarnCooldownMs
                Logger.Warn("Hotkey", "HotIf 求值耗时异常：本次 " Round(elapsedMs, 1) "ms（阈值 " this.EvalWarnThresholdMs
                    . "ms），hotkey=" hotkeyName "，key=" pureKey "，累计求值=" this._EvalCount "，峰值=" Round(this._EvalMaxMs, 1) "ms")
            }
        }
        return matched
    }

    ; 热键域内部状态
    static _ActiveTab := "keyBind"
    static _Group := "combatQuick"
    static _SwitchKey := ""

    ; ---- 判定路径耗时观测（ctxEval）----
    static _EvalCount := 0
    static _EvalTotalMs := 0.0
    static _EvalMaxMs := 0.0
    static EvalWarnThresholdMs := 50    ; 单次 HotIf 求值超过此值记 WARN（远离系统钩子超时红线）
    static _NextEvalWarnTick := 0
    static _TelemetryWarnCooldownMs := 10000

    ; 键位集合变更后通知探针立即重建监视表（定时刷新要等 5s，空窗期内会误报未触发）；
    ; 直接调用而非发事件——只有探针一个消费者，发事件会让两侧先后顺序不确定
    static _NotifyWatchKeysChanged() {
        HookHealth.RefreshWatchKeysNow()
    }

    ; 初始化热键服务
    static Init() {
        HotkeyService._BuildActionCallbacks()
        HotkeyService._SubscribeEvents()
    }

    ; 由 Schema + ActionBindings 生成 ActionCallbacks（行为标志只在 HotkeySchema，函数引用只在 ActionBindings）
    static _BuildActionCallbacks() {
        this.ActionCallbacks := Map()
        for item in HotkeySchema.Items {
            if !this.ActionBindings.Has(item.id)
                continue
            profile := {Fn: this.ActionBindings[item.id]}
            if (item.guarded)
                profile.Guarded := true
            if (item.onUp)
                profile.OnUp := true
            if (item.noActivate)
                profile.NoActivate := true
            this.ActionCallbacks[item.id] := profile
        }
    }

    ; 内部：订阅热键事件（保留旧事件兼容，同时接入新事件契约）
    static _SubscribeEvents() {
        ; Legacy 旧事件（兼容保留闭环，勿新增发布者）
        EventBus.Subscribe("HotkeyOff", (*) => this.HotkeyOff())          ; Legacy
        EventBus.Subscribe("UnsetSwitchKey", (*) => this.UnsetSwitchKey()) ; Legacy
        EventBus.Subscribe("SetSwitchKey", (*) => this.SetSwitchKey())     ; Legacy
        ; 新事件契约
        EventBus.Subscribe("GameKeysChanged", (data) => this._HandleGameKeysChanged(data))
        EventBus.Subscribe("GameClientsChanged", (data) => this._HandleGameClientsChanged(data))
        EventBus.Subscribe("ForegroundClientChanged", (data) => this._HandleForegroundClientChanged(data))
        EventBus.Subscribe("ActiveTabChangeRequested", (data) => this._HandleActiveTabChangeRequested(data))
        EventBus.Subscribe("HotkeyToggleRequested", (*) => this.SwitchHotkey())
        EventBus.Subscribe("InLevelChanged", (data) => this._HandleInLevelChanged(data))
        EventBus.Subscribe("SettingsChanged", (data) => this._HandleSettingsChanged(data))
        EventBus.Subscribe("SettingsSaved", (*) => this._HandleSettingsSavedOrApplied())
        EventBus.Subscribe("SettingsApplied", (*) => this._HandleSettingsSavedOrApplied())
        EventBus.Subscribe("SettingsReset", (*) => this._HandleSettingsSavedOrApplied())
    }

    ; 处理关卡状态变化（目前仅记录调试日志；守卫判定走 LevelDetector.IsInLevel() getter）
    static _HandleInLevelChanged(data) {
        Logger.Debug("Hotkey", "关卡状态变化：inLevel=" data.inLevel)
    }

    ; 处理游戏按键变更：总开关开启时才重建，修复“禁用后被注册表变更恢复”的 bug
    static _HandleGameKeysChanged(data) {
        if (!this.HotkeyState)
            return
        Logger.Info("Hotkey", "收到 GameKeysChanged，重建热键")
        this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 处理游戏客户端集合变化：拦截并集可能需要变化，重建热键
    static _HandleGameClientsChanged(data) {
        if (!this.HotkeyState)
            return
        Logger.Info("Hotkey", "收到 GameClientsChanged，重建热键")
        this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 处理前台客户端变化：当前映射随前台切换，无需重建热键（热键全局唯一一套）
    static _HandleForegroundClientChanged(data) {
        Logger.Debug("Hotkey", "前台客户端变化：serverId=" data.serverId ", pid=" data.pid)
    }

    ; 处理 UI 标签页切换请求
    static _HandleActiveTabChangeRequested(data) {
        ; “其他设置”/“自定义按键”是管理型标签页，不改变热键组；自定义按键的生效范围由其“按键类型”决定
        if (data.tabName = "other" || data.tabName = "customKeys")
            return
        this._ActiveTab := data.tabName
        if (this._ActiveTab = "strongHoldProtocol")
            this._Group := "strongHoldProtocol"
        else
            this._Group := "combatQuick"
        if (this.HotkeyState)
            this.EnableByTab(this._ActiveTab)
        EventBus.Publish("HotkeyGroupChanged", {group: this._Group})
    }

    ; 处理设置变更：HoverOperate/SwitchHotkey 等热键相关配置即时刷新
    static _HandleSettingsChanged(data) {
        if (data.key = "HoverOperate")
            this.SetHoverOperate(data.value == "1")
        else if (data.key = "SwitchHotkey")
            this.SetSwitchKey()
        else if (Config.AllHotkeys.Has(data.key) && this.HotkeyState)
            this.EnableByTab(this._ActiveTab)
    }

    ; 处理保存/应用/重置完成：从 INI 刷新热键相关配置并重建热键
    static _HandleSettingsSavedOrApplied() {
        this.SetHoverOperate(Config.ReadCustomFromIni("HoverOperate") == "1")
        if (this.HotkeyState)
            this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 当前激活的功能标签页（供设置域临时处理器重建热键）
    static GetActiveTab() {
        return this._ActiveTab
    }

    ; 热键动作绑定表（id -> 动作函数引用；Guarded/OnUp/NoActivate 行为标志由 HotkeySchema 提供，不在此重复）
    static ActionBindings := Map(
        ; 常规作战
        "PressPause", HotkeyActions.ActionPressPause.Bind(HotkeyActions),
        "ReleasePause", HotkeyActions.ActionReleasePause.Bind(HotkeyActions),
        "GameSpeed", HotkeyActions.ActionGameSpeed.Bind(HotkeyActions),
        "PauseSelect", HotkeyActions.ActionPauseSelect.Bind(HotkeyActions),
        "Skill", HotkeyActions.ActionSkill.Bind(HotkeyActions),
        "Retreat", HotkeyActions.ActionRetreat.Bind(HotkeyActions),
        "SwitchView", HotkeyActions.ActionSwitchView.Bind(HotkeyActions),
        "16ms", HotkeyActions.Action16ms.Bind(HotkeyActions),
        "33ms", HotkeyActions.Action33ms.Bind(HotkeyActions),
        "166ms", HotkeyActions.Action166ms.Bind(HotkeyActions),
        "OneClickSkill", HotkeyActions.ActionOneClickSkill.Bind(HotkeyActions),
        "OneClickRetreat", HotkeyActions.ActionOneClickRetreat.Bind(HotkeyActions),
        "PauseSkill", HotkeyActions.ActionPauseSkill.Bind(HotkeyActions),
        "PauseRetreat", HotkeyActions.ActionPauseRetreat.Bind(HotkeyActions),
        "AutoBeginPauseSwitch", HotkeyActions.ActionBeginPauseSwitch.Bind(HotkeyActions),
        "AutoBeginSpeedSwitch", HotkeyActions.ActionBeginSpeedSwitch.Bind(HotkeyActions),
        ; 快捷操作
        "LButtonClick", HotkeyActions.ActionLButtonClick.Bind(HotkeyActions),
        "Harvest", HotkeyActions.ActionHarvest.Bind(HotkeyActions),
        "CeaseOperations", HotkeyActions.ActionCeaseOperations.Bind(HotkeyActions),
        "Skip", HotkeyActions.ActionSkip.Bind(HotkeyActions),
        "CollectCollectibles", HotkeyActions.ActionCollectCollectibles.Bind(HotkeyActions),
        "Back", HotkeyActions.ActionBack.Bind(HotkeyActions),
        ; 卫戍协议
        "CheckEnemies", HotkeyActions.ActionCheckEnemies.Bind(HotkeyActions),
        "DispatchCenter", HotkeyActions.ActionDispatchCenter.Bind(HotkeyActions),
        "Freeze", HotkeyActions.ActionFreeze.Bind(HotkeyActions),
        "Refresh", HotkeyActions.ActionRefresh.Bind(HotkeyActions),
        "Ready", HotkeyActions.ActionReady.Bind(HotkeyActions),
        "StrongHoldProtocolLButtonClick", HotkeyActions.ActionLButtonClick.Bind(HotkeyActions),
        "Upgrade", HotkeyActions.ActionUpgrade.Bind(HotkeyActions),
        "Sell", HotkeyActions.ActionSell.Bind(HotkeyActions),
        "StrongHoldProtocolRetreat", HotkeyActions.ActionStrongHoldProtocolRetreat.Bind(HotkeyActions),
        "StrongHoldProtocolOneClickRetreat", HotkeyActions.ActionStrongHoldProtocolOneClickRetreat.Bind(HotkeyActions),
        "OneClickSell", HotkeyActions.ActionOneClickSell.Bind(HotkeyActions),
        "OneClickPurchase", HotkeyActions.ActionOneClickPurchase.Bind(HotkeyActions),
        "StrongHoldProtocolBack", HotkeyActions.ActionBack.Bind(HotkeyActions)
    )

    ; 热键回调映射表（由 HotkeySchema.Items + ActionBindings 自动生成）
    static ActionCallbacks := Map()

    ; 已激活热键映射表
    static ActiveHotkeys := Map()

    ; 自定义按键注册信息（重建热键时由 _BuildCustomProfiles 刷新）：id -> {key, group, profile}
    static CustomProfiles := Map()

    ; 已激活启用/禁用热键快捷键
    static ActiveSwitchHotkey := ""

    ; 包装动作回调：失焦悬停时先激活游戏窗口
    ; 判定层只管"是否触发"，此处只管副作用；用闭包捕获 fn 作回调
    static _WrapAction(fn) {
        Wrapped(ThisHotkey) {
            ; 整个热键线程（含激活等待段）纳入在飞统计，用于观测线程泄漏（#MaxThreads 默认 10）
            probe := HookHealth.EnterAction(IsObject(fn) ? fn.Name : fn, KeyForward.PureKeyName(ThisHotkey))
            try {
                ; 防御性检查：窗口不存在则跳过（正常路径已由判定层保证存在）
                if !GameTarget.Exists() {
                    Logger.Warn("Hotkey", "动作跳过：目标游戏窗口不存在（key=" KeyForward.PureKeyName(ThisHotkey) "）")
                    return
                }
                ; WinActivate/WinWaitActive 期间线程不可中断，等待期无法为钩子求值 HotIf，
                ; 是钩子超时的第二大来源。故前台时直接跳过激活，仅失焦路径等待且超时压到 200ms
                if !GameTarget.IsActive() {
                    GameTarget.Activate()
                    ; 激活超时则跳过动作，避免按键发往非游戏窗口
                    if !GameTarget.WaitActive(HotkeyService.ActivateTimeoutMs) {
                        Logger.Warn("Hotkey", "动作跳过：激活游戏窗口超时（key=" KeyForward.PureKeyName(ThisHotkey) "）")
                        return
                    }
                }
                try {
                    fn(ThisHotkey)
                } catch Error as e {
                    ; 记录异常而非静默，动作内部出错需可排查
                    Logger.Error("Hotkey", "动作执行失败：fn=" (IsObject(fn) ? fn.Name : fn) ", error=" e.Message)
                }
            } finally {
                HookHealth.ExitAction(probe)
            }
        }
        return Wrapped
    }

    ; 观测包装：只做在飞统计，不激活窗口（noActivate 动作的触发前提不含前台）
    static _WrapObserved(fn, label := "") {
        Wrapped(ThisHotkey) {
            probe := HookHealth.EnterAction(label != "" ? label : (IsObject(fn) ? fn.Name : fn), KeyForward.PureKeyName(ThisHotkey))
            try {
                fn(ThisHotkey)
            } finally {
                HookHealth.ExitAction(probe)
            }
        }
        return Wrapped
    }

    ; 注册单个热键（profile.OnUp=松开时触发；profile.Guarded=拦截键需注册 Up 变体补发透传）。
    ; 行为标志用 HasOwnProp 判断——直接访问不存在的属性会抛 PropertyError
    static _RegisterOne(hotkeyValue, profile, pattern) {
        callback := profile.HasOwnProp("NoActivate")
            ? this._WrapObserved(profile.Fn)
            : this._WrapAction(profile.Fn)
        if (profile.HasOwnProp("OnUp") && !InStr(hotkeyValue, "Wheel")) {
            ; 松开暂停：功能在松开时触发（Up 变体注册）
            reg := (hotkeyValue ~= pattern) ? hotkeyValue " Up" : "~" hotkeyValue " Up"
            Hotkey(reg, callback, "On")
            HotkeyService.ActiveHotkeys.Set(reg, reg)
            return
        }
        intercept := hotkeyValue ~= pattern
        reg := intercept ? hotkeyValue : "~" hotkeyValue
        Hotkey(reg, callback, "On")
        HotkeyService.ActiveHotkeys.Set(reg, reg)
        ; 有守卫的拦截键（非滚轮）：注册 Up 变体，松开时由 KeyForward.ActionUpForward 补发 key up。
        ; 类静态方法必须 Bind(KeyForward)——方法的 MinParams 含 self，直接传引用会报 Invalid callback function
        if (profile.HasOwnProp("Guarded") && intercept && !InStr(hotkeyValue, "Wheel")) {
            Hotkey(hotkeyValue " Up", KeyForward.ActionUpForward.Bind(KeyForward), "On")
            HotkeyService.ActiveHotkeys.Set(hotkeyValue " Up", hotkeyValue " Up")
        }
    }

    ; 启用热键
    static HotkeyOn(*) {
        KeyForward.DownHandled.Clear()  ; 重建前清空运行时标记（保留 CaseSense）
        KeyForward.SuppressUp.Clear()
        KeyForward.InterceptedKeys.Clear()
        GameKeys.InjectedPressKeys.Clear()
        HotIf(HotkeyContext)
        pattern := GameKeys.GetInterceptPattern()
        for keyVar, _ in Constants.KeyNames {
            hotkeyValue := Config.ReadHotkeyFromIni(keyVar)
            if (hotkeyValue != "" && this.ActionCallbacks.Has(keyVar)) {
                try this._RegisterOne(hotkeyValue, this.ActionCallbacks[keyVar], pattern)
                catch Error as e
                    Logger.Error("Hotkey", "注册热键失败：key=" keyVar ", value=" hotkeyValue ", callback=" this.ActionCallbacks[keyVar].Fn.Name ", error=" e.Message)
            }
        }
        HotIf
        ; 自定义按键：启动默认常规作战组 + 全局类型（与标准热键同一判定上下文）
        this._BuildCustomProfiles()
        this._EnableCustomGroup("combatQuick")
        this._EnableCustomGroup("all")
        this._NotifyWatchKeysChanged()
        Logger.Info("Hotkey", "热键已启用，数量=" this.ActiveHotkeys.Count ", 明细: " this._BuildDetailList(Constants.KeyNames))
    }

    ; 禁用热键
    static HotkeyOff(silent := false, *) {
        HotIf(HotkeyContext)
        for _ , hotkeyValue in HotkeyService.ActiveHotkeys {
            try Hotkey(hotkeyValue, , "Off")
            catch Error as e
                Logger.Error("Hotkey", "关闭热键失败：" hotkeyValue " - " e.Message)
        }
        HotkeyService.ActiveHotkeys := Map()
        KeyForward.DownHandled.Clear()
        KeyForward.SuppressUp.Clear()
        KeyForward.InterceptedKeys.Clear()
        GameKeys.InjectedPressKeys.Clear()
        HotIf
        this._NotifyWatchKeysChanged()
        if !silent
            Logger.Info("Hotkey", "热键已禁用")
    }

    ; 启用指定组的热键
    static EnableGroup(groupMap) {
        HotIf(HotkeyContext)
        pattern := GameKeys.GetInterceptPattern()
        for keyVar, _ in groupMap {
            hotkeyValue := Config.ReadHotkeyFromIni(keyVar)
            if (hotkeyValue != "" && this.ActionCallbacks.Has(keyVar)) {
                try this._RegisterOne(hotkeyValue, this.ActionCallbacks[keyVar], pattern)
                catch Error as e
                    Logger.Error("Hotkey", "注册热键失败：key=" keyVar ", value=" hotkeyValue ", callback=" this.ActionCallbacks[keyVar].Fn.Name ", error=" e.Message)
            }
        }
        HotIf
        this._NotifyWatchKeysChanged()
    }

    ; 禁用指定组的热键
    static DisableGroup(groupMap) {
        HotIf(HotkeyContext)
        pattern := GameKeys.GetInterceptPattern()
        for keyVar, _ in groupMap {
            hotkeyValue := Config.ReadHotkeyFromIni(keyVar)
            if (hotkeyValue != "") {
                try Hotkey(hotkeyValue, , "Off")
                try Hotkey("~" hotkeyValue, , "Off")
                ; 仅注销并删除实际注册过的 Up 变体（与 _RegisterOne 同规则派生，保持 ActiveHotkeys 与实际注册一致）
                if (this.ActionCallbacks.Has(keyVar)) {
                    profile := this.ActionCallbacks[keyVar]
                    if ((profile.HasOwnProp("OnUp") || profile.HasOwnProp("Guarded")) && !InStr(hotkeyValue, "Wheel") && hotkeyValue ~= pattern) {
                        try Hotkey(hotkeyValue " Up", , "Off")
                        this.ActiveHotkeys.Delete(hotkeyValue " Up")
                    }
                }
                this.ActiveHotkeys.Delete(hotkeyValue)
                this.ActiveHotkeys.Delete("~" hotkeyValue)
                this.ActiveHotkeys.Delete("~" hotkeyValue " Up")
            }
        }
        HotIf
        this._NotifyWatchKeysChanged()
    }

    ; 构建热键明细列表（用于日志）
    static _BuildDetailList(keyMap) {
        list := ""
        for keyVar, _ in keyMap {
            hotkeyValue := Config.ReadHotkeyFromIni(keyVar)
            if (hotkeyValue != "" && this.ActionCallbacks.Has(keyVar))
                list .= keyVar "=" hotkeyValue ", "
        }
        if (list != "")
            return SubStr(list, 1, -2)
        return "(无)"
    }

    ; 构建当前活跃标签页的热键明细列表（用于日志）
    static _BuildDetailForActiveTab(tabName) {
        if (tabName = "keyBind" || tabName = "quick")
            return "战斗=" this._BuildDetailList(Constants.CombatHotkeys) " | 快捷=" this._BuildDetailList(Constants.QuickHotkeys)
        else if (tabName = "strongHoldProtocol")
            return "卫戍=" this._BuildDetailList(Constants.StrongHoldHotkeys)
        return ""
    }

    ; 根据标签页启用对应热键组
    static EnableByTab(tabName) {
        this.HotkeyOff(true)  ; 先静默禁用所有热键，重建完成后记录最终状态
        this._BuildCustomProfiles()
        ; 防御：customKeys 为管理型标签页（正常不会作为参数传入），按当前组重建
        if (tabName = "customKeys")
            tabName := this._ActiveTab
        if (tabName = "keyBind" || tabName = "quick") {
            this.EnableGroup(Constants.CombatHotkeys)
            this.EnableGroup(Constants.QuickHotkeys)
            this._EnableCustomGroup("combatQuick")
        }
        else if (tabName = "strongHoldProtocol") {
            this.EnableGroup(Constants.StrongHoldHotkeys)
            this._EnableCustomGroup("strongHoldProtocol")
        }
        this._EnableCustomGroup("all")  ; 全局类型任何标签下都注册
        Logger.Info("Hotkey", "热键已重建，数量=" this.ActiveHotkeys.Count ", 标签页=" tabName
            ", 明细: " this._BuildDetailForActiveTab(tabName) ", 自定义: " this._BuildCustomDetailList())
    }

    ; 内部：从存储文件读取自定义按键并构建注册信息（慢路径：含文件 IO 与功能校验，重建热键前调用）
    static _BuildCustomProfiles() {
        CustomScriptEngine.Reload()
        this.CustomProfiles := Map()
        for entry in Config.ReadCustomHotkeys() {
            id := "CustomHotkey" entry.Index
            meta := HotkeySchema.CustomTypeProfiles.Has(entry.Type)
                ? HotkeySchema.CustomTypeProfiles[entry.Type]
                : HotkeySchema.CustomTypeProfiles["global"]
            if entry.Key = "" || !CustomScriptEngine.IsRegistered(id) {
                Logger.Info("Hotkey", "跳过自定义按键注册：" id "（未绑定或参数非法）")
                continue
            }
            profile := {Fn: CustomScriptEngine.RunById.Bind(CustomScriptEngine, id)}
            if meta.Guarded
                profile.Guarded := true
            this.CustomProfiles[id] := {key: entry.Key, group: meta.Group, profile: profile}
        }
    }

    ; 内部：注册指定生效组的自定义按键（"all" | "combatQuick" | "strongHoldProtocol"）
    static _EnableCustomGroup(group) {
        HotIf(HotkeyContext)
        pattern := GameKeys.GetInterceptPattern()
        for id, info in this.CustomProfiles {
            if info.group = group || info.group = "all" {
                try this._RegisterOne(info.key, info.profile, pattern)
                catch Error as e
                    Logger.Error("Hotkey", "注册自定义热键失败：key=" id ", value=" info.key ", error=" e.Message)
            }
        }
        HotIf
        this._NotifyWatchKeysChanged()
    }

    ; 构建自定义按键明细列表（用于日志）
    static _BuildCustomDetailList() {
        list := ""
        for id, info in this.CustomProfiles
            list .= (list = "" ? "" : ", ") id "=" info.key
        if list = ""
            return "(无)"
        return list
    }

    ; 切换热键启用/禁用（只发布事实，托盘文案/图标由 UI 订阅更新）
    static SwitchHotkey(*) {
        if(this.HotkeyState == true) {
            this.HotkeyOff()
            this.HotkeyState := false
            EventBus.Publish("HotkeyStateChanged", {enabled: false})
            Logger.Info("Hotkey", "用户禁用热键")
            return
        }
        if(this.HotkeyState == false) {
            this.HotkeyState := true
            ; 根据内部保存的标签页启用对应热键组
            this.EnableByTab(this._ActiveTab)
            EventBus.Publish("HotkeyStateChanged", {enabled: true})
            Logger.Info("Hotkey", "用户启用热键")
            return
        }
    }

    ; 设置热键启用/禁用快捷键
    static SetSwitchKey() {
        HotIf(HotkeyContext)
        switchKey := Config.ReadCustomFromIni("SwitchHotkey")
        if (switchKey != "") {
            try {
                Hotkey(switchKey, HotkeyService.SwitchHotkey.Bind(HotkeyService), "On")
                this.ActiveSwitchHotkey := switchKey
            } catch Error as e {
                Logger.Error("Hotkey", "注册SwitchKey失败：key=" switchKey ", callback=" this.SwitchHotkey.Name ", error=" e.Message)
            }
        }
        HotIf
        this._SwitchKey := switchKey
        EventBus.Publish("SwitchKeyChanged", {key: switchKey})
    }
    ; 解除设置热键启用/禁用快捷键
    static UnsetSwitchKey() {
        switchKey := this.ActiveSwitchHotkey
        if (switchKey != "") {
            HotIf(HotkeyContext)
            try Hotkey(switchKey, HotkeyService.SwitchHotkey.Bind(HotkeyService), "Off")
            catch Error as e
                Logger.Error("Hotkey", "关闭SwitchKey失败：" switchKey " - " e.Message)
            HotIf
        }
        this._SwitchKey := ""
        EventBus.Publish("SwitchKeyChanged", {key: ""})
    }
}
