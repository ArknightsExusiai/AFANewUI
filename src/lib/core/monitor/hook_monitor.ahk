; 键盘钩子存活检测
class HookMonitor {
    static PollMs := 30          ; 采样间隔
    static StaleMs := 1000
    static IdleGateMs := 1000
    static RecoverCooldownMs := 5000    ; 两次重装钩子之间的最小间隔

    static _Cache := Map()       ; reg -> {key, vk}
    static _Down := Map()        ; pureKey -> 上一拍是否按下
    static _Seen := Map()        ; vk -> 本拍已处理的 tick
    static _Timer := ""
    static _Streak := 0
    static _LastRecoverTick := 0

    static _PollCount := 0

    static Init() {
        this._Down.CaseSense := false
        if (this._Timer = "")
            this._Timer := HookMonitor.Poll.Bind(HookMonitor)
        SetTimer this._Timer, this.PollMs
    }

    static Poll() {
        if (!GameTarget.IsForegroundCached()) {
            this._Down.Clear()
            this._Streak := 0
            return
        }
        this._PollCount += 1
        ; 无输入期间键态不可能变化，采样整轮跳过
        if (A_TimeIdle > this.IdleGateMs) {
            if (this._PollCount >= 200) {
                Logger.Debug("HookMonitor", "跳过：无输入 idle=" A_TimeIdle "ms")
                this._PollCount := 0
            }
            return
        }

        now := A_TickCount
        checked := 0
        edges := ""
        missed := false
        for reg, _ in HotkeyService.ActiveHotkeys {
            entry := this._Resolve(reg)
            if (!entry || this._Seen.Get(entry.vk, 0) = now)   ; 同一键的 down/Up 变体只查一次
                continue
            this._Seen[entry.vk] := now
            checked++

            state := DllCall("GetAsyncKeyState", "Int", entry.vk, "Short")
            down := (state & 0x8000) != 0
            was := this._Down.Get(entry.key, 0)
            this._Down[entry.key] := down ? 1 : 0
            if (!down)
                continue
            if (was)
                continue

            mark := entry.key "+down"
            if (GameKeys.IsInjectedPressPending(entry.key)) {   ; 这次按击是 AFA 自己注入的
                edges .= (edges = "" ? "" : " ") mark ":inj"
                continue
            }
            ; 钩子活着时，按击被观测到的同时它必然已同步刷新过时间戳
            if (A_TimeIdleKeyboard > this.StaleMs) {
                edges .= (edges = "" ? "" : " ") mark ":miss"
                if (!missed) {
                    missed := true
                    if (++this._Streak >= 2)
                        this._Suspect(entry.key)
                }
            } else {
                edges .= (edges = "" ? "" : " ") mark ":ok"
                this._Streak := 0
            }
        }
        if (this._PollCount >= 200) {
            Logger.Debug("HookMonitor", "键=" checked " 沿=[" edges "] streak=" this._Streak
                . " idle=" A_TimeIdle "ms idleKbd=" A_TimeIdleKeyboard "ms")
            this._PollCount := 0
        }
    }

    ; 解析注册项为 {key, vk}
    static _Resolve(reg) {
        if (this._Cache.Has(reg))
            return this._Cache[reg]
        entry := false
        pureKey := KeyForward.PureKeyName(reg)
        if (pureKey != "" && !IsMouseKey(pureKey)) {
            try vk := GetKeyVK(pureKey)
            catch
                vk := 0
            if (vk != 0)
                entry := {key: pureKey, vk: vk}
        }
        this._Cache[reg] := entry
        return entry
    }

    static _Suspect(pureKey) {
        this._Streak := 0
        cooling := A_TickCount - this._LastRecoverTick < this.RecoverCooldownMs
        Logger.Warn("HookMonitor", "键盘钩子疑似被系统摘除：键=" pureKey "，物理按下但 idleKbd=" A_TimeIdleKeyboard "ms"
            . (cooling ? "（冷却中，仅记录）" : "，重装钩子"))
        if (cooling)
            return
        this._LastRecoverTick := A_TickCount
        InstallKeybdHook(true, true)
    }
}
