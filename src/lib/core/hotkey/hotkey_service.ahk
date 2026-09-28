; == 热键控制 ==

HotkeyContext(hotkeyName) {
    pureKey := KeyForward.PureKeyName(hotkeyName)
    if (pureKey = "")
        return false
    evalStart := Qpc()

    ; Up 变体（守卫补发型）
    if RegExMatch(hotkeyName, " Up$") {
        if KeyForward.SuppressUp.Has(pureKey)
            return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, false)
        if KeyForward.DownHandled.Has(pureKey)
            return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    }
    ; 鼠标键/滚轮：悬停判定
    if (pureKey ~= "i)^(lbutton|rbutton|mbutton|xbutton1|xbutton2|wheel)")
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, IsMouseInClient())
    ; 键盘键：优先热路径廉价校验，未命中才回退 WinActive 判定并异步补识别
    if GameTarget.IsForegroundCached()
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    if WinActive(GameTarget.WinTitle()) {
        GameClientRegistry.ScheduleRefresh()
        return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, true)
    }
    return HotkeyService._TraceEval(hotkeyName, pureKey, evalStart, HotkeyService.GetHoverOperate() && IsMouseInClient())
}

class HotkeyService {
    static HotkeyState := true

    static ActivateTimeoutMs := 200

    static _HoverOperate := true

    static SetHoverOperate(value) {
        this._HoverOperate := value
    }

    static GetHoverOperate() {
        return this._HoverOperate
    }

    ; HotkeyContext 的统一出口：记录单次求值耗时并原样回传判定结果
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
    static EvalWarnThresholdMs := 50
    static _NextEvalWarnTick := 0
    static _TelemetryWarnCooldownMs := 10000

    ; 键位集合变更后通知探针立即重建监视表
    static _NotifyWatchKeysChanged() {
        HookHealth.RefreshWatchKeysNow()
    }

    static Init() {
        HotkeyService._BuildActionCallbacks()
        HotkeyService._SubscribeEvents()
    }

    ; 由 Schema + ActionBindings 生成 ActionCallbacks
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

    ; 内部：订阅热键事件
    static _SubscribeEvents() {
        EventBus.Subscribe("HotkeyOff", (*) => this.HotkeyOff())          ; Legacy
        EventBus.Subscribe("UnsetSwitchKey", (*) => this.UnsetSwitchKey()) ; Legacy
        EventBus.Subscribe("SetSwitchKey", (*) => this.SetSwitchKey())     ; Legacy
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

    ; 处理关卡状态变化
    static _HandleInLevelChanged(data) {
        Logger.Debug("Hotkey", "关卡状态变化：inLevel=" data.inLevel)
    }

    ; 处理游戏按键变更
    static _HandleGameKeysChanged(data) {
        if (!this.HotkeyState)
            return
        Logger.Info("Hotkey", "收到 GameKeysChanged，重建热键")
        this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 处理游戏客户端集合变化
    static _HandleGameClientsChanged(data) {
        if (!this.HotkeyState)
            return
        Logger.Info("Hotkey", "收到 GameClientsChanged，重建热键")
        this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 处理前台客户端变化
    static _HandleForegroundClientChanged(data) {
        Logger.Debug("Hotkey", "前台客户端变化：serverId=" data.serverId ", pid=" data.pid)
    }

    ; 处理 UI 标签页切换请求
    static _HandleActiveTabChangeRequested(data) {
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

    ; 处理设置变更
    static _HandleSettingsChanged(data) {
        if (data.key = "HoverOperate")
            this.SetHoverOperate(data.value == "1")
        else if (data.key = "SwitchHotkey")
            this.SetSwitchKey()
        else if (Config.AllHotkeys.Has(data.key) && this.HotkeyState)
            this.EnableByTab(this._ActiveTab)
    }

    ; 处理保存/应用/重置完成
    static _HandleSettingsSavedOrApplied() {
        this.SetHoverOperate(Config.ReadCustomFromIni("HoverOperate") == "1")
        if (this.HotkeyState)
            this.EnableByTab(this._ActiveTab)
        this.SetSwitchKey()
    }

    ; 当前激活的功能标签页
    static GetActiveTab() {
        return this._ActiveTab
    }

    ; 热键动作绑定表（id -> 动作函数引用）
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

    ; 热键回调映射表
    static ActionCallbacks := Map()

    static ActiveHotkeys := Map()

    ; 自定义按键注册信息：id -> {key, group, profile}
    static CustomProfiles := Map()

    static ActiveSwitchHotkey := ""

    ; 包装动作回调：失焦悬停时先激活游戏窗口
    static _WrapAction(fn) {
        Wrapped(ThisHotkey) {
            probe := HookHealth.EnterAction(IsObject(fn) ? fn.Name : fn, KeyForward.PureKeyName(ThisHotkey))
            try {
                if !GameTarget.Exists() {
                    Logger.Warn("Hotkey", "动作跳过：目标游戏窗口不存在（key=" KeyForward.PureKeyName(ThisHotkey) "）")
                    return
                }
                if !GameTarget.IsActive() {
                    GameTarget.Activate()
                    if !GameTarget.WaitActive(HotkeyService.ActivateTimeoutMs) {
                        Logger.Warn("Hotkey", "动作跳过：激活游戏窗口超时（key=" KeyForward.PureKeyName(ThisHotkey) "）")
                        return
                    }
                }
                try {
                    fn(ThisHotkey)
                } catch Error as e {
                    Logger.Error("Hotkey", "动作执行失败：fn=" (IsObject(fn) ? fn.Name : fn) ", error=" e.Message)
                }
            } finally {
                HookHealth.ExitAction(probe)
            }
        }
        return Wrapped
    }

    ; 观测包装：只做在飞统计，不激活窗口
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

    ; 注册单个热键
    static _RegisterOne(hotkeyValue, profile, pattern) {
        callback := profile.HasOwnProp("NoActivate")
            ? this._WrapObserved(profile.Fn)
            : this._WrapAction(profile.Fn)
        if (profile.HasOwnProp("OnUp") && !InStr(hotkeyValue, "Wheel")) {
            reg := (hotkeyValue ~= pattern) ? hotkeyValue " Up" : "~" hotkeyValue " Up"
            Hotkey(reg, callback, "On")
            HotkeyService.ActiveHotkeys.Set(reg, reg)
            return
        }
        intercept := hotkeyValue ~= pattern
        reg := intercept ? hotkeyValue : "~" hotkeyValue
        Hotkey(reg, callback, "On")
        HotkeyService.ActiveHotkeys.Set(reg, reg)
        ; 有守卫的拦截键（非滚轮）注册 Up 变体；类静态方法须 Bind(KeyForward)
        if (profile.HasOwnProp("Guarded") && intercept && !InStr(hotkeyValue, "Wheel")) {
            Hotkey(hotkeyValue " Up", KeyForward.ActionUpForward.Bind(KeyForward), "On")
            HotkeyService.ActiveHotkeys.Set(hotkeyValue " Up", hotkeyValue " Up")
        }
    }

    ; 启用热键
    static HotkeyOn(*) {
        KeyForward.DownHandled.Clear()
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
        ; 自定义按键：默认常规作战组 + 全局类型
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
                ; 仅注销实际注册过的 Up 变体
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

    ; 构建热键明细列表（日志用）
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

    ; 构建当前标签页的热键明细列表（日志用）
    static _BuildDetailForActiveTab(tabName) {
        if (tabName = "keyBind" || tabName = "quick")
            return "战斗=" this._BuildDetailList(Constants.CombatHotkeys) " | 快捷=" this._BuildDetailList(Constants.QuickHotkeys)
        else if (tabName = "strongHoldProtocol")
            return "卫戍=" this._BuildDetailList(Constants.StrongHoldHotkeys)
        return ""
    }

    ; 根据标签页启用对应热键组
    static EnableByTab(tabName) {
        this.HotkeyOff(true)
        this._BuildCustomProfiles()
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
        this._EnableCustomGroup("all")
        Logger.Info("Hotkey", "热键已重建，数量=" this.ActiveHotkeys.Count ", 标签页=" tabName
            ", 明细: " this._BuildDetailForActiveTab(tabName) ", 自定义: " this._BuildCustomDetailList())
    }

    ; 内部：读取自定义按键并构建注册信息（慢路径）
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

    ; 内部：注册指定生效组的自定义按键
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

    ; 构建自定义按键明细列表（日志用）
    static _BuildCustomDetailList() {
        list := ""
        for id, info in this.CustomProfiles
            list .= (list = "" ? "" : ", ") id "=" info.key
        if list = ""
            return "(无)"
        return list
    }

    ; 切换热键启用/禁用
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
