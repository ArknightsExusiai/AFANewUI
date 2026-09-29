; == UI 度量与字体 ==

class Metrics {
    static FontFor(locale) {
        switch locale {
            case "zh-Hant": return "Microsoft JhengHei UI"
            case "ja-JP": return "Yu Gothic UI"
            case "ko-KR": return "Malgun Gothic"
            case "en-US": return "Segoe UI"
            case "zh-Hans": return "Microsoft YaHei UI"
            default: return "Microsoft YaHei UI"
        }
    }

    static IconFont() {
        return "Segoe MDL2 Assets"
    }

    ; 估算文本渲染像素宽度（fontSize 为像素字号，s9 ≈ 12px）；0x2E80 起 CJK/全角计 1.0em，空格 0.3em，窄字母 0.35em，其余 0.55em
    static TextWidth(text, fontSize := 12) {
        width := 0.0
        for char in StrSplit(text) {
            code := Ord(char)
            if (code >= 0x2E80)
                width += 1.0
            else if (char = " ")
                width += 0.3
            else if (char = "i" || char = "l" || char = "I" || char = "j"
                || char = "f" || char = "t" || char = "." || char = ","
                || char = ":" || char = ";" || char = "(" || char = ")"
                || char = "[" || char = "]" || char = "'")
                width += 0.35
            else
                width += 0.55
        }
        return Ceil(width * fontSize)
    }
}
