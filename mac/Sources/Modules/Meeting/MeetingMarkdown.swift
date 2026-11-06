import Foundation

// 读会议的 meeting.md（docs/meeting/TECH_DESIGN.md §2.3 的版式）与写周报（§4 `weekly/<yyyy-Www>.md`）。
// 只依赖 Foundation，可脱离 App 单独编译测试；读写盘、调模型在 MeetingReports.swift。
//
// meeting.md：`# 标题` + 头信息列表，然后「## 纪要」「## 速记」「## 转录」（英文界面写的是 Minutes / Notes / Transcript；
// 旧实时翻译记录的转录一节叫「## 记录」）。纪要里的小节是「### 摘要 / 决议 / 行动项 / 重点」（自由听译：要点 / 结论 / 待办）。
// 转录一行：`**10:32:05 我** 原文`（说话人可缺）、下一行可能是 `> 译文`；🔖 标记：`🔖 **10:32:05** 标记重点`。

enum MeetingMarkdown {
    static let minutesHeadings: Set<String> = ["纪要", "Minutes"]
    static let notesHeadings: Set<String> = ["速记", "Notes"]
    static let transcriptHeadings: Set<String> = ["转录", "记录", "Transcript"]
    /// 纪要里「摘要」那一节（自由听译的纪要是「要点」）。
    static let summaryHeadings: Set<String> = ["摘要", "Summary", "要点", "Key points"]
    /// 「决议」那一节（自由听译的纪要是「结论」）。
    static let decisionHeadings: Set<String> = ["决议", "Decisions", "结论"]
    /// 「行动项」那一节（会议纪要；会议库详情里换成可勾选的列表）。
    static let actionHeadings: Set<String> = ["行动项", "Action items"]
    /// 模型在没有内容时写的占位。
    static let placeholders: Set<String> = [
        "无", "暂无", "没有", "无。", "none", "none.", "n/a", "na", "-", "—", "…", "...", "nil", "tbd",
    ]

    struct Sections: Equatable {
        var minutes: String?
        var notes: String?
        var transcript: String?
    }

    /// 按「## 」二级标题拆成纪要 / 速记 / 转录（认不出的二级标题归进转录）；每节去掉首尾空行，空的为 nil。
    static func sections(_ markdown: String) -> Sections {
        var minutes: [String] = []
        var notes: [String] = []
        var transcript: [String] = []
        var current: Int?
        var sawMinutes = false
        var sawNotes = false
        var sawTranscript = false
        for line in markdown.components(separatedBy: "\n") {
            if let heading = level2Heading(line) {
                if minutesHeadings.contains(heading) {
                    current = 0
                    sawMinutes = true
                } else if notesHeadings.contains(heading) {
                    current = 1
                    sawNotes = true
                } else {
                    current = 2
                    sawTranscript = true
                    if !transcriptHeadings.contains(heading), !transcript.isEmpty {
                        transcript.append(line)
                    }
                }
                continue
            }
            switch current {
            case 0: minutes.append(line)
            case 1: notes.append(line)
            case 2: transcript.append(line)
            default: break
            }
        }
        func block(_ lines: [String], _ present: Bool) -> String? {
            guard present else { return nil }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return Sections(minutes: block(minutes, sawMinutes), notes: block(notes, sawNotes),
                        transcript: block(transcript, sawTranscript))
    }

    /// `## 标题` → 「标题」；不是二级标题为 nil（`### ` 不算）。
    static func level2Heading(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        return line.dropFirst(3).trimmingCharacters(in: .whitespaces)
    }

    private static func level3Heading(_ line: String) -> String? {
        guard line.hasPrefix("### ") else { return nil }
        return line.dropFirst(4).trimmingCharacters(in: .whitespaces)
    }

    /// 纪要里某几节（`### 标题`）下面的行。
    static func lines(under headings: Set<String>, in minutes: String) -> [String] {
        var inside = false
        var result: [String] = []
        for line in minutes.components(separatedBy: "\n") {
            if let heading = level3Heading(line) ?? level2Heading(line) {
                inside = headings.contains(heading)
                continue
            }
            if inside { result.append(line) }
        }
        return result
    }

    /// 去掉纪要里的某几节（`### 标题` 连同下面的行，到下一个小标题为止）。
    static func removingSubsections(_ headings: Set<String>, from minutes: String) -> String {
        var skipping = false
        var kept: [String] = []
        for line in minutes.components(separatedBy: "\n") {
            if let heading = level3Heading(line) ?? level2Heading(line) {
                skipping = headings.contains(heading)
                if skipping { continue }
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 列表项的正文（`- ` / `* ` / `• ` / `1. ` 开头）；不是列表项为 nil。
    static func bulletText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" || $0 == "、" }), dot != trimmed.startIndex,
           trimmed[..<dot].allSatisfy(\.isNumber) {
            return String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func isPlaceholder(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: " 。.;；,，"))
        return cleaned.isEmpty || placeholders.contains(cleaned.lowercased()) || placeholders.contains(text.lowercased())
    }

    /// 纪要的摘要：「### 摘要」（或「### 要点」）那一节的内容；没有这一节就取纪要开头几行（不含小标题）。
    static func summary(fromMinutes minutes: String, maxLines: Int = 6) -> String {
        var body = lines(under: summaryHeadings, in: minutes)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isPlaceholder(bulletText($0) ?? $0) }
        if body.isEmpty {
            body = minutes.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && level3Heading($0) == nil && level2Heading($0) == nil }
        }
        return body.prefix(maxLines).joined(separator: "\n")
    }

    /// 一行摘要（系列时间线用）：摘要的第一条，去掉列表符号。
    static func oneLineSummary(fromMinutes minutes: String) -> String {
        let first = summary(fromMinutes: minutes, maxLines: 1)
        return bulletText(first) ?? first
    }

    /// 「### 决议」（或「### 结论」）下面的各条，去掉「无」这类占位。
    static func decisions(fromMinutes minutes: String) -> [String] {
        lines(under: decisionHeadings, in: minutes).compactMap { line in
            guard let text = bulletText(line)?.replacingOccurrences(of: "**", with: ""), !isPlaceholder(text) else {
                return nil
            }
            return text
        }
    }

    // MARK: - 转录（重新生成纪要用）

    struct TranscriptLine: Equatable {
        var time: Date
        var text: String
        /// 「我」「对方」（按记录时的界面语言）；没标为 nil。
        var speaker: String?
    }

    struct Transcript: Equatable {
        var lines: [TranscriptLine]
        var marks: [Date]
        var notes: String
    }

    /// 从 meeting.md 读回转录的句子、🔖 标记与速记。时刻只有「时:分:秒」：按会议开始那天算，跨过午夜的往后挪一天。
    static func transcript(_ markdown: String, start: Date, calendar: Calendar = .current) -> Transcript {
        let parts = sections(markdown)
        var clock = DayClock(start: start, calendar: calendar)
        var lines: [TranscriptLine] = []
        var marks: [Date] = []
        for raw in (parts.transcript ?? "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let mark = markPattern?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
               let time = clock.date(from: line, match: mark) {
                marks.append(time)
                continue
            }
            guard let match = linePattern?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  let time = clock.date(from: line, match: match),
                  let textRange = Range(match.range(at: 5), in: line) else { continue }
            let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var speaker: String?
            if let speakerRange = Range(match.range(at: 4), in: line) {
                let value = String(line[speakerRange]).trimmingCharacters(in: .whitespaces)
                speaker = value.isEmpty ? nil : value
            }
            lines.append(TranscriptLine(time: time, text: text, speaker: speaker))
        }
        return Transcript(lines: lines, marks: marks, notes: parts.notes ?? "")
    }

    /// `**10:32:05 我** 原文` / `**10:32:05** 原文`。
    private static let linePattern = try? NSRegularExpression(
        pattern: #"^\*\*(\d{1,2}):(\d{2}):(\d{2})(?:\s+([^*]+?))?\*\*\s*(.*)$"#)
    /// `🔖 **10:32:05** 标记重点`。
    private static let markPattern = try? NSRegularExpression(pattern: #"^🔖\s*\*\*(\d{1,2}):(\d{2}):(\d{2})\*\*"#)

    /// 「时:分:秒」→ 日期：从会议开始那天起，一直往后（比上一句早了半天以上就是过了午夜）。
    private struct DayClock {
        let start: Date
        let calendar: Calendar
        var dayOffset = 0
        var previous: Date?

        init(start: Date, calendar: Calendar) {
            self.start = start
            self.calendar = calendar
        }

        mutating func date(from line: String, match: NSTextCheckingResult) -> Date? {
            func number(_ index: Int) -> Int? {
                guard let range = Range(match.range(at: index), in: line) else { return nil }
                return Int(line[range])
            }
            guard let hour = number(1), let minute = number(2), let second = number(3),
                  hour < 24, minute < 60, second < 60 else { return nil }
            let day = calendar.startOfDay(for: start)
            let seconds = TimeInterval(hour * 3600 + minute * 60 + second)
            var date = day.addingTimeInterval(seconds + Double(dayOffset) * 86_400)
            // 开始前一小时以前的时刻：已经是第二天了（23:50 开始、00:05 说的话）。
            while date < start.addingTimeInterval(-3600) {
                dayOffset += 1
                date = date.addingTimeInterval(86_400)
            }
            if let previous, date < previous.addingTimeInterval(-12 * 3600) {
                dayOffset += 1
                date = date.addingTimeInterval(86_400)
            }
            previous = date
            return date
        }
    }

    /// 换掉纪要一节的内容（重新生成纪要）。没有纪要一节就加在第一个二级标题前面（都没有就加在最后），标题用 `heading`。
    static func replacingMinutes(in markdown: String, with minutes: String, heading: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let body = ["", minutes.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if let start = lines.firstIndex(where: { level2Heading($0).map(minutesHeadings.contains) ?? false }) {
            let end = lines[(start + 1)...].firstIndex(where: { level2Heading($0) != nil }) ?? lines.endIndex
            lines.replaceSubrange((start + 1)..<end, with: body)
        } else if let first = lines.firstIndex(where: { level2Heading($0) != nil }) {
            lines.insert(contentsOf: ["## " + heading] + body, at: first)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: ["## " + heading] + body)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 周报

/// 会议周报（需求 §4）：本周（ISO 周，周一到周日）各会议的决议与未完成行动项，规则汇总；概述段由模型写（没装模型就没有这一段）。
enum MeetingWeeklyReport {
    /// 周报里用到的文案（调用方按界面语言给；纯逻辑不碰本地化）。
    struct Labels {
        var title: String
        var overview: String
        var meetings: String
        var decisions: String
        var openItems: String
        var none: String
        var listSeparator: String
        /// 截止时间 →「（截止：周五）」。
        var due: (String) -> String
        var dateTime: (Date) -> String
        var duration: (TimeInterval) -> String
    }

    struct Entry {
        var record: MeetingRecord
        /// 纪要那一节（没有为 nil）。
        var minutes: String?
    }

    static func isoCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 某天所在的 ISO 周：「2026-W45」与那一周（周一 0 点到下周一 0 点）。
    static func week(containing date: Date, calendar: Calendar) -> (key: String, interval: DateInterval) {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = components.yearForWeekOfYear ?? calendar.component(.year, from: date)
        let week = components.weekOfYear ?? 1
        let key = String(format: "%04d-W%02d", year, week)
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return (key, interval)
        }
        let start = calendar.startOfDay(for: date)
        return (key, DateInterval(start: start, duration: 7 * 86_400))
    }

    /// 这一周的会议（线上 / 线下，自由听译不算），按开始时间正序。
    static func meetings(in records: [MeetingRecord], during interval: DateInterval) -> [MeetingRecord] {
        records.filter { $0.meta.type != .free && interval.contains($0.meta.start) && $0.meta.start < interval.end }
            .sorted { $0.meta.start < $1.meta.start }
    }

    /// 一条行动项的一行：`负责人：事项（截止：…）`。
    static func itemLine(_ item: MeetingActionItem, labels: Labels) -> String {
        var line = item.owner.map { $0 + "：" } ?? ""
        line += item.text
        if let due = item.due, !due.isEmpty {
            line += labels.due(due)
        }
        return line
    }

    /// 喂给模型写概述的材料：各会议的标题、决议、未完成行动项（纯文本）。
    static func overviewInput(_ entries: [Entry], labels: Labels) -> String {
        entries.map { entry in
            var parts = ["# " + entry.record.meta.title + "（" + labels.dateTime(entry.record.meta.start) + "）"]
            let decisions = entry.minutes.map(MeetingMarkdown.decisions(fromMinutes:)) ?? []
            parts += decisions.map { "- " + labels.decisions + "：" + $0 }
            parts += entry.record.meta.actionItems.filter { !$0.done }.map { "- " + labels.openItems + "：" + itemLine($0, labels: labels) }
            return parts.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// 周报全文。`overview` 为 nil（没装模型 / 没写出来）就没有概述一节。
    static func compose(entries: [Entry], overview: String?, labels: Labels) -> String {
        var out = "# " + labels.title + "\n\n"
        if let overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "## " + labels.overview + "\n\n" + overview.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }

        out += "## " + labels.meetings + "\n\n"
        if entries.isEmpty {
            out += labels.none + "\n\n"
        } else {
            for entry in entries {
                let meta = entry.record.meta
                var line = "- " + labels.dateTime(meta.start) + " " + meta.title
                if let duration = meta.duration, duration >= 60 {
                    line += " · " + labels.duration(duration)
                }
                if !meta.attendees.isEmpty {
                    line += " · " + meta.attendees.joined(separator: labels.listSeparator)
                }
                out += line + "\n"
            }
            out += "\n"
        }

        out += "## " + labels.decisions + "\n\n"
        var anyDecision = false
        for entry in entries {
            let decisions = entry.minutes.map(MeetingMarkdown.decisions(fromMinutes:)) ?? []
            guard !decisions.isEmpty else { continue }
            anyDecision = true
            out += "### " + entry.record.meta.title + "（" + labels.dateTime(entry.record.meta.start) + "）\n\n"
            out += decisions.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        }
        if !anyDecision { out += labels.none + "\n\n" }

        out += "## " + labels.openItems + "\n\n"
        var anyItem = false
        for entry in entries {
            for item in entry.record.meta.actionItems where !item.done {
                anyItem = true
                out += "- [ ] " + itemLine(item, labels: labels) + " — " + entry.record.meta.title
                    + "（" + labels.dateTime(entry.record.meta.start) + "）\n"
            }
        }
        out += anyItem ? "\n" : labels.none + "\n"
        return out
    }
}
