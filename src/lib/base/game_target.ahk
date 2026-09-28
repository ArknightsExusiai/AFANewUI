; == 游戏目标 ==
; 「当前目标游戏窗口」唯一 owner；只持有状态与查询 API，绑定 / 仲裁由 core/game/game_client_registry.ahk 驱动。

class GameTarget {
    ; ── 状态 ──
    static _Hwnd := 0
    static _Pid := 0
    static _ExePath := ""
    static _ServerId := ""

    ; ── 绑定 / 解绑 ──

    ; 绑定目标客户端实例
    static Bind(hwnd, pid, exePath, serverId) {
        if (this._Hwnd = hwnd && this._Pid = pid && this._ExePath = exePath && this._ServerId = serverId)
            return
        Logger.Debug("GameTarget", "绑定目标窗口 hwnd=" hwnd " pid=" pid " serverId=" serverId " exe=" exePath)
        this._Hwnd := hwnd
        this._Pid := pid
        this._ExePath := exePath
        this._ServerId := serverId
    }

    ; 解绑，回到 ahk_exe 宽松回退
    static Unbind() {
        if (this._Hwnd != 0)
            Logger.Debug("GameTarget", "解绑目标窗口 hwnd=" this._Hwnd " pid=" this._Pid " serverId=" this._ServerId)
        this._Hwnd := 0
        this._Pid := 0
        this._ExePath := ""
        this._ServerId := ""
    }

    ; ── 查询 ──

    static Hwnd() {
        return this._Hwnd
    }

    static Pid() {
        return this._Pid
    }

    static ExePath() {
        return this._ExePath
    }

    ; 前台客户端的区服 id；未绑定时为 ""
    static ServerId() {
        return this._ServerId
    }

    static IsBound() {
        return this._Hwnd != 0
    }

    ; 目标窗口标题（未绑定时回退 ahk_exe）
    static WinTitle() {
        if (this._Hwnd)
            return "ahk_id " this._Hwnd
        return "ahk_exe " ServerProfile.ExeName
    }

    static Exists() {
        return WinExist(this.WinTitle()) != 0
    }

    ; 是否存在任意区服的游戏进程
    static ProcessExists() {
        return ProcessExist(ServerProfile.ExeName) != 0
    }

    static IsActive() {
        return WinActive(this.WinTitle()) != 0
    }

    ; 热路径廉价校验：前台窗口是否即缓存客户端
    static IsForegroundCached() {
        if (!this.IsBound())
            return false
        fgHwnd := DllCall("GetForegroundWindow", "Ptr")
        if (fgHwnd != this._Hwnd)
            return false
        fgPid := 0
        DllCall("GetWindowThreadProcessId", "Ptr", fgHwnd, "UInt*", &fgPid)
        return fgPid = this._Pid
    }

    ; 等待目标窗口成为前台
    static WaitActive(timeout := 500) {
        return WinWaitActive(this.WinTitle(), , timeout) != 0
    }

    ; 激活目标窗口
    static Activate() {
        try {
            WinActivate(this.WinTitle())
        } catch TargetError {
            return false
        }
        return true
    }
}
