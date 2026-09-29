; == 更新公告多语言裁剪 ==

class ChangelogFormat {
    static LocalizeBody(body, locale := "") {
        if (locale = "")
            locale := I18n.GetCurrent()
        body := this._StripCollapseTags(body)
        section := this._ExtractSection(body, locale)
        if (section != "")
            return section
        section := this._ExtractSection(body, "zh-Hans")
        if (section != "")
            return section
        return body
    }

    ; 剥离 <details>/<summary> 折叠标签，保留内部内容
    static _StripCollapseTags(body) {
        body := RegExReplace(body, "<summary>[^<>]*</summary>", "")
        body := RegExReplace(body, "<details[^>]*>", "")
        body := RegExReplace(body, "</details>", "")
        return body
    }

    static _ExtractSection(body, locale) {
        marker := "<!-- afa:lang " locale " -->"
        start := InStr(body, marker, false)
        if (start = 0)
            return ""
        start += StrLen(marker)
        nextMatch := RegExMatch(body, "<!-- afa:lang [A-Za-z0-9-]+ -->", &m, start)
        section := (nextMatch > 0) ? SubStr(body, start, m.Pos[0] - start) : SubStr(body, start)
        return this._TrimLeadingNewlines(section)
    }

    static _TrimLeadingNewlines(s) {
        Loop {
            if (SubStr(s, 1, 2) = "`r`n") {
                s := SubStr(s, 3)
            } else if (SubStr(s, 1, 1) = "`r" || SubStr(s, 1, 1) = "`n") {
                s := SubStr(s, 2)
            } else {
                break
            }
        }
        return s
    }
}
