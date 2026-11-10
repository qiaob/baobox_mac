import Foundation

// 纪要模板与会议纪要固定格式的纯逻辑（docs/meeting/TECH_DESIGN.md §2.3）：模板、输入行的排版（说话人、【重点】）、
// 行动项的宽松解析。本文件只依赖 Foundation，可脱离 App 单独编译测试；提示词与生成在 MeetingMinutesGenerator.swift。

/// 纪要模板。
enum MeetingMinutesTemplate: Equatable {
    /// 自由听译：要点 / 结论 / 待办（实时翻译原来的纪要，一字不改）。
    case content
    /// 会议纪要：摘要 / 决议 / 行动项 / 重点，输出格式固定；按会议类型换各节的侧重。
    case meeting(MeetingMinutesStyle)

    /// 存进会议库 meta.json 的 `template`：content / standard / standup / oneOnOne / interview。
    var storageValue: String {
        switch self {
        case .content: return "content"
        case .meeting(let style): return style.rawValue
        }
    }

    init(storageValue: String?) {
        if let value = storageValue, let style = MeetingMinutesStyle(rawValue: value) {
            self = .meeting(style)
        } else if storageValue == "content" {
            self = .content
        } else {
            self = .meeting(.standard)
        }
    }
}

/// 会议纪要的类型：默认 / 站会 / 1:1 / 面试。
enum MeetingMinutesStyle: String, CaseIterable, Codable {
    case standard
    case standup
    case oneOnOne
    case interview
}

/// 会议纪要的固定格式：四节标题、喂给模型的一行怎么写、行动项怎么从输出里读回来。
enum MeetingMinutesFormat {
    /// 「## 摘要 / ## 决议 / ## 行动项 / ## 重点」（英文界面用英文标题）。
    static func headings(chinese: Bool) -> [String] {
        chinese ? ["摘要", "决议", "行动项", "重点"] : ["Summary", "Decisions", "Action items", "Highlights"]
    }

    /// 🔖 标在某一时刻：它之前 20 秒、之后 5 秒内开始的句子算「重点」（标的多半是刚说完的那段）。
    static let highlightBefore: TimeInterval = 20
    static let highlightAfter: TimeInterval = 5

    static func isHighlighted(_ time: Date, marks: [Date]) -> Bool {
        marks.contains { mark in
            let offset = time.timeIntervalSince(mark)
            return offset >= -highlightBefore && offset <= highlightAfter
        }
    }

    /// 喂给模型的一行：`[10:32] 【重点】我：……`。说话人、重点都可缺。
    static func row(clock: String, text: String, speaker: String?, highlighted: Bool) -> String {
        var row = "[\(clock)] "
        if highlighted { row += "【重点】" }
        if let speaker, !speaker.isEmpty { row += speaker + "：" }
        return row + text
    }

    /// 解析出来的一条行动项（负责人 / 截止缺失照样收）。
    struct ActionItem: Equatable {
        var text: String
        var owner: String?
        var due: String?
        var done: Bool
    }

    /// 从纪要里读行动项：所有 `- [ ] ` 开头的行（`*`、`+`、`•`、`1.` 也认，`[x]` 记为已完成），不看在哪一节下。
    /// 每行再宽松地拆「负责人：事项（截止：…）」—— 负责人、截止缺了照收；「无」「None」这类占位行跳过。
    static func parseActionItems(_ minutes: String) -> [ActionItem] {
        var items: [ActionItem] = []
        for raw in minutes.components(separatedBy: .newlines) {
            guard let (body, done) = checkbox(in: raw) else { continue }
            if let item = actionItem(from: body, done: done) {
                items.append(item)
            }
        }
        return items
    }

    /// 「- [ ] 正文」→（正文, 是否勾了）；不是勾选框行返回 nil。
    private static func checkbox(in raw: String) -> (String, Bool)? {
        var line = Substring(raw.trimmingCharacters(in: .whitespaces))
        // 列表符号：- * + • 或「1.」「1)」。
        if let first = line.first, "-*+•".contains(first) {
            line = line.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        } else if let digitsEnd = line.firstIndex(where: { !$0.isNumber }), digitsEnd != line.startIndex,
                  line[digitsEnd] == "." || line[digitsEnd] == ")" {
            line = line[line.index(after: digitsEnd)...].drop(while: { $0 == " " || $0 == "\t" })
        }
        guard line.first == "[" else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let mark = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard mark.count <= 1 else { return nil }
        let done = ["x", "X", "✓", "√", "✔"].contains(mark)
        guard mark.isEmpty || done else { return nil }
        let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (body, done)
    }

    /// 「无」这类占位，以及模型照抄提示词里格式示例时的「事项」「task」。
    private static let placeholders: Set<String> = [
        "无", "暂无", "没有", "无行动项", "无。", "none", "none.", "n/a", "na", "-", "—", "…", "...", "tbd", "nil",
        "事项", "task",
    ]
    private static let ownerPlaceholders: Set<String> = [
        "未指定", "待定", "无", "未知", "不明", "未明确", "待分配", "负责人", "tbd", "unassigned", "unknown", "none", "n/a",
        "owner", "someone",
    ]
    private static let duePlaceholders: Set<String> = [
        "无", "未提及", "未定", "待定", "未知", "不明", "未说明", "未明确", "none", "n/a", "tbd", "unknown", "-", "—", "…", "...",
    ]

    private static func actionItem(from body: String, done: Bool) -> ActionItem? {
        var text = body.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !placeholders.contains(text.lowercased()) else { return nil }
        // 模型偶尔把模板里的「负责人：」原样带出来。
        for label in ["负责人：", "负责人:", "Owner:", "owner:", "Owner："] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }

        var due: String?
        if let range = dueRange(in: text) {
            let value = String(text[range.value]).trimmingCharacters(in: .whitespaces)
            due = duePlaceholders.contains(value.lowercased()) || value.isEmpty ? nil : value
            text = String(text[..<range.whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        var owner: String?
        if let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            let prefix = text[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // 冒号前像个人名（不长、不带句读）才当负责人；否则冒号是事项里本来就有的。
            if !prefix.isEmpty, prefix.count <= 20, !rest.isEmpty,
               !prefix.contains(where: { "，。；;,!?！？".contains($0) }) {
                owner = ownerPlaceholders.contains(prefix.lowercased()) ? nil : prefix
                text = rest
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " 。.;；,，"))
        guard !text.isEmpty, !placeholders.contains(text.lowercased()) else { return nil }
        return ActionItem(text: text, owner: owner, due: due, done: done)
    }

    /// 行末的截止时间：「（截止：周五）」「(due: Friday)」「(deadline Nov 8)」，或不带括号的「，截止：周五」。
    /// 返回整段与其中的值的范围。
    private static let duePatterns: [NSRegularExpression] = [
        #"[（(]\s*(?:截止(?:时间|日期)?|期限|due(?:\s*date)?|deadline|by)\s*[:：]?\s*([^）)]*)[）)]\s*[。.]?\s*$"#,
        #"[，,;；]\s*(?:截止(?:时间|日期)?|期限|due(?:\s*date)?|deadline)\s*[:：]\s*(.+?)\s*[。.]?\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func dueRange(in text: String) -> (whole: Range<String.Index>, value: Range<String.Index>)? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in duePatterns {
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let whole = Range(match.range, in: text),
                  let value = Range(match.range(at: 1), in: text) else { continue }
            return (whole, value)
        }
        return nil
    }
}
