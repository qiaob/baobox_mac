import Foundation

/// 停止后整理纪要（本地 Qwen3-1.7B，上下文 4096）：记录短就一次整理；长了按段先各提要点，再合并成一份。
/// 提示词、输入行与切段是纯逻辑（`MeetingMinutesPrompts`，docs/meeting/ENGINE.md §5.2），这里只管走哪个模型、调它。
enum MeetingMinutesGenerator {
    /// 纪要走哪个模型：「设置 → AI」里「会议纪要」选的（默认本地，docs/ai-service/DESIGN.md §5.4）。整个 App 只有这里问 `.meetingMinutes`。
    @MainActor
    static var route: AIRoute { AIService.shared.route(for: .meetingMinutes) }

    /// 此刻能不能整理：收尾时判「没有模型」、字幕与同传设置页「停止后整理纪要」的提示、会议库「重新生成」都看它。
    @MainActor
    static var isReady: Bool { AIService.shared.isReady(route, local: .generation) }

    typealias Line = MeetingMinutesPrompts.Line

    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? { L("livetranslate.record.doc.minutesEmpty") }
    }

    /// `template`：`.content`（自由听译）就是原来的要点 / 结论 / 待办；`.meeting` 出固定格式的会议纪要
    /// （摘要 / 决议 / 行动项 / 重点，见 `MeetingMinutesFormat`），`notes`（会议速记）作为上下文附在前面。
    @MainActor
    static func generate(lines: [Line], chinese: Bool, template: MeetingMinutesTemplate = .content,
                         notes: String = "") async throws -> String {
        // 走本地（内置或本机大模型）时那个模型常驻到写完；给纪要选了云端模型就不加载本地模型（出错退回时才现加载）。
        let kept = AIService.shared.localBackend(for: route, local: .generation)
        kept?.beginKeepAlive()
        defer { kept?.endKeepAlive() }
        if case .meeting(let style) = template {
            return try await generateMeeting(lines: lines, chinese: chinese, style: style, notes: notes)
        }
        let chunks = MeetingMinutesPrompts.chunk(MeetingMinutesPrompts.contentRows(lines))
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var notes: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                notes.append(try await ask(MeetingMinutesPrompts.notesPrompt(part, part: index + 1, of: chunks.count,
                                                                             chinese: chinese),
                                           maxTokens: 500))
            }
            body = MeetingMinutesPrompts.fit(notes, chinese: chinese)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = MeetingMinutesPrompts.tidy(
            try await ask(MeetingMinutesPrompts.minutesPrompt(body, fromNotes: fromNotes, chinese: chinese), maxTokens: 900))
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    @MainActor
    private static func ask(_ prompt: String, maxTokens: Int) async throws -> String {
        // 走哪个模型按「会议纪要」这个功能选的（默认本地，docs/ai-service/DESIGN.md §5.4）；云端每段最多等 120 秒。
        try await AIService.shared.generate(prompt, maxTokens: maxTokens, sampling: .summary,
                                            route: route, timeout: 120).text
    }

    /// 会议纪要：每行带说话人与【重点】；长了先逐段提要点（重点必留），再按会议类型整理成固定的四节。
    @MainActor
    private static func generateMeeting(lines: [Line], chinese: Bool, style: MeetingMinutesStyle,
                                        notes: String) async throws -> String {
        let rows = MeetingMinutesPrompts.meetingRows(lines)
        // 速记占一部分预算（最多约 400 token），记录相应少放一点，整份仍在上下文 4096 以内。
        let context = MeetingMinutesPrompts.clip(notes, budget: MeetingMinutesPrompts.notesBudget)
        let budget = MeetingMinutesPrompts.meetingBudget(notes: context)
        let chunks = MeetingMinutesPrompts.chunk(rows, budget: budget)
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var parts: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                parts.append(try await ask(MeetingMinutesPrompts.meetingNotesPrompt(part, part: index + 1, of: chunks.count,
                                                                                    chinese: chinese),
                                           maxTokens: 500))
            }
            body = MeetingMinutesPrompts.fit(parts, chinese: chinese, budget: budget)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = MeetingMinutesPrompts.tidy(
            try await ask(MeetingMinutesPrompts.meetingPrompt(body, fromNotes: fromNotes, notes: context, style: style,
                                                              chinese: chinese), maxTokens: 900))
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }
}
