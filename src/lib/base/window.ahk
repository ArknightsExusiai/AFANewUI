; == 窗口工具 ==

; 获取游戏窗口 Client 区域尺寸（窗口不存在返回 false）
SafeWinGetClientPos(&ww, &wh) {
    try {
        WinGetClientPos ,, &ww, &wh, GameTarget.WinTitle()
        return true
    } catch TargetError {
        return false
    }
}

; 安全像素搜索（GDI 失败按未命中处理，不打断调用方定时器）
SafePixelSearch(&FoundX, &FoundY, LX, UY, RX, DY, ColorID, Variation := 0) {
    if _SearchRectOffScreen(LX, UY, RX, DY) {
        FoundX := "", FoundY := ""
        _LogSearchError("PixelSearch", "搜索区域完全在可见桌面之外")
        return false
    }
    try {
        return PixelSearch(&FoundX, &FoundY, LX, UY, RX, DY, ColorID, Variation)
    } catch OSError as e {
        FoundX := "", FoundY := ""
        _LogSearchError("PixelSearch", e.Message, e.Number)
        return false
    }
}

; 安全图像搜索；选项（容差/缩放）前缀拼在 ImageFile 内（如 "*90 " path）
SafeImageSearch(&FoundX, &FoundY, LX, UY, RX, DY, ImageFile) {
    if _SearchRectOffScreen(LX, UY, RX, DY) {
        FoundX := "", FoundY := ""
        _LogSearchError("ImageSearch", "搜索区域完全在可见桌面之外")
        return false
    }
    try {
        return ImageSearch(&FoundX, &FoundY, LX, UY, RX, DY, ImageFile)
    } catch OSError as e {
        FoundX := "", FoundY := ""
        _LogSearchError("ImageSearch", e.Message, e.Number)
        return false
    } catch ValueError as e {
        FoundX := "", FoundY := ""
        _LogSearchError("ImageSearch", e.Message)
        return false
    }
}

; 单次捕获游戏客户区位图（BGRA，自顶向下），供内存颜色扫描
SafeCaptureClientRect(&bits, &width, &height) {
    hwnd := 0, hdc := 0, memdc := 0, bmp := 0, old := 0
    try {
        hwnd := WinExist(GameTarget.WinTitle())
        if !hwnd
            return false
        rect := Buffer(16)
        if !DllCall("user32\GetClientRect", "Ptr", hwnd, "Ptr", rect)
            return false
        w := NumGet(rect, 8, "Int")
        h := NumGet(rect, 12, "Int")
        if (w <= 0 || h <= 0)
            return false
        ; 客户区原点的屏幕坐标（POINT(0,0) → ClientToScreen）
        pt := Buffer(8)
        NumPut("Int", 0, pt, 0)
        NumPut("Int", 0, pt, 4)
        if !DllCall("user32\ClientToScreen", "Ptr", hwnd, "Ptr", pt)
            return false
        ox := NumGet(pt, 0, "Int")
        oy := NumGet(pt, 4, "Int")
        hdc := DllCall("user32\GetDC", "Ptr", 0, "Ptr")  ; 屏幕 DC
        if !hdc
            return false
        memdc := DllCall("gdi32\CreateCompatibleDC", "Ptr", hdc, "Ptr")
        if !memdc
            return false
        bmp := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", hdc, "Int", w, "Int", h, "Ptr")
        if !bmp
            return false
        old := DllCall("gdi32\SelectObject", "Ptr", memdc, "Ptr", bmp, "Ptr")
        if !DllCall("gdi32\BitBlt", "Ptr", memdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdc, "Int", ox, "Int", oy, "UInt", 0x00CC0020)  ; SRCCOPY
            return false
        ; BITMAPINFOHEADER（40 字节）：biSize/biWidth/biHeight(负=自顶向下)/biPlanes/biBitCount/biCompression
        bmi := Buffer(40)
        NumPut("UInt", 40, bmi, 0)
        NumPut("UInt", w, bmi, 4)
        NumPut("UInt", -h, bmi, 8)
        NumPut("UShort", 1, bmi, 12)
        NumPut("UShort", 32, bmi, 14)
        NumPut("UInt", 0, bmi, 16)  ; BI_RGB
        bits := Buffer(w * h * 4)
        scan := DllCall("gdi32\GetDIBits", "Ptr", memdc, "Ptr", bmp, "UInt", 0, "UInt", h, "Ptr", bits, "Ptr", bmi, "UInt", 0)
        if (scan != h)
            return false
        width := w, height := h
        return true
    } catch {
        return false
    } finally {
        if bmp {
            if old
                DllCall("gdi32\SelectObject", "Ptr", memdc, "Ptr", old)
            DllCall("gdi32\DeleteObject", "Ptr", bmp)
        }
        if memdc
            DllCall("gdi32\DeleteDC", "Ptr", memdc)
        if hdc
            DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", hdc)
    }
}

; 判断搜索矩形是否完全在虚拟屏幕之外（不确定时返回 false，交 PixelSearch 自身兜底）
_SearchRectOffScreen(FX1, FY1, FX2, FY2) {
    try {
        x1 := Min(FX1, FX2), x2 := Max(FX1, FX2)
        y1 := Min(FY1, FY2), y2 := Max(FY1, FY2)
        ox := 0, oy := 0
        if (A_CoordModePixel != "Screen") {
            fg := DllCall("GetForegroundWindow", "Ptr")
            if (fg && !DllCall("IsIconic", "Ptr", fg)) {
                if (A_CoordModePixel = "Window") {
                    WinGetPos &wx, &wy,,, "ahk_id " fg
                } else { ; Client
                    WinGetClientPos &wx, &wy,,, "ahk_id " fg
                }
                ox := wx, oy := wy
            }
        }
        x1 += ox, x2 += ox, y1 += oy, y2 += oy
        vx := DllCall("GetSystemMetrics", "Int", 76)  ; SM_XVIRTUALSCREEN
        vy := DllCall("GetSystemMetrics", "Int", 77)  ; SM_YVIRTUALSCREEN
        vr := vx + DllCall("GetSystemMetrics", "Int", 78)  ; SM_CXVIRTUALSCREEN
        vb := vy + DllCall("GetSystemMetrics", "Int", 79)  ; SM_CYVIRTUALSCREEN
        return (x2 < vx || x1 > vr || y2 < vy || y1 > vb)
    } catch TargetError {
        return false
    } catch OSError {
        return false
    }
}

; 搜索失败日志（60 秒节流）
_LogSearchError(kind, message, code := "") {
    static _NextWarnTick := 0
    if (A_TickCount < _NextWarnTick)
        return
    _NextWarnTick := A_TickCount + 60000
    detail := kind " 失败：" message (code != "" ? "（错误码 " code "）" : "")
    Logger.Warn("ScreenSearch", detail)
}

; 判断鼠标是否在游戏 Client 区域内
IsMouseInClient() {
    MouseGetPos , &ypos, &hwnd
    gameHwnd := WinExist(GameTarget.WinTitle())
    if !(hwnd == gameHwnd)
        return false
    if ypos < 0
        return false
    return true
}
