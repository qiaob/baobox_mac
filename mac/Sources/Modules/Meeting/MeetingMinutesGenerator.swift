import Foundation

/// 停止后整理纪要（本地 Qwen3-1.7B，上下文 4096）：记录短就一次整理；长了按段先各提要点，再合并成一份。
enum MeetingMinutesGenerator {
    /// 纪要走哪个模型：「设置 → AI」里「会议纪要」选的（默认本地，docs/ai-service/DESIGN.md §5.4）。整个 App 只有这里问 `.meetingMinutes`。
    @MainActor
    static var route: AIRoute { AIService.shared.route(for: .meetingMinutes) }

    /// 此刻能不能整理：收尾时判「没有模型」、字幕与同传设置页「停止后整理纪要」的提示、会议库「重新生成」都看它。
    @MainActor
    static var isReady: Bool { AIService.shared.isReady(route, local: .generation) }

    struct Line {
        let time: Date
        let text: String
        /// 会议标说话人时的「我 / 对方」（已本地化）；没有为 nil。
        var speaker: String?
        /// 🔖 标记的那段：输入里加「【重点】」前缀加权。
        var highlighted = false
    }

    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? { L("livetranslate.record.doc.minutesEmpty") }
    }

    /// 每次喂给模型的记录最多这么多 token（估算），给提示词和输出留余量。
    private static let inputBudget = 2200

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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let rows = lines.map { "[\(formatter.string(from: $0.time))] \($0.text)" }
        let chunks = chunk(rows)
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var notes: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                notes.append(try await ask(notesPrompt(part, part: index + 1, of: chunks.count, chinese: chinese),
                                           maxTokens: 500))
            }
            body = fit(notes, chinese: chinese)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = tidy(try await ask(minutesPrompt(body, fromNotes: fromNotes, chinese: chinese), maxTokens: 900))
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let rows = lines.map {
            MeetingMinutesFormat.row(clock: formatter.string(from: $0.time), text: $0.text,
                                     speaker: $0.speaker, highlighted: $0.highlighted)
        }
        // 速记占一部分预算（最多约 400 token），记录相应少放一点，整份仍在上下文 4096 以内。
        let context = clip(notes, budget: notesBudget)
        let budget = max(800, inputBudget - tokens(context))
        let chunks = chunk(rows, budget: budget)
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var parts: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                parts.append(try await ask(meetingNotesPrompt(part, part: index + 1, of: chunks.count, chinese: chinese),
                                           maxTokens: 500))
            }
            body = fit(parts, chinese: chinese, budget: budget)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = tidy(try await ask(meetingPrompt(body, fromNotes: fromNotes, notes: context, style: style,
                                                      chinese: chinese), maxTokens: 900))
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    /// 会议速记最多占这么多 token。
    private static let notesBudget = 400

    /// 截到预算以内（按行，超出的行不要）。
    static func clip(_ text: String, budget: Int) -> String {
        var kept: [String] = []
        var size = 0
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let cost = tokens(line) + 1
            guard size + cost <= budget else { break }
            kept.append(line)
            size += cost
        }
        return kept.joined(separator: "\n")
    }

    /// 按行凑段，每段不超过 `budget`（默认 `inputBudget`）。
    static func chunk(_ rows: [String], budget: Int = inputBudget) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for row in rows {
            let cost = tokens(row) + 1
            if size + cost > budget, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(row)
            size += cost
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    /// 各段要点合起来再超预算：每段只留前面的几条，按段平分预算。
    static func fit(_ notes: [String], chinese: Bool, budget: Int = inputBudget) -> String {
        let limit = max(120, budget / max(1, notes.count))
        return notes.enumerated().map { index, note in
            var kept: [String] = []
            var size = 0
            for line in note.components(separatedBy: .newlines)
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let cost = tokens(line) + 1
                guard size + cost <= limit else { break }
                kept.append(line)
                size += cost
            }
            let title = chinese ? "第 \(index + 1) 段：" : "Part \(index + 1):"
            return title + "\n" + kept.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// 粗估 token 数：中日韩一字约一个，其余约 3.5 个字符一个（Qwen 分词的大致比例），宁多勿少。
    static func tokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other * 2 + 6) / 7
    }

    /// 模型偶尔自己加个大标题（「# 会议纪要」）：去掉；「## 」降成「### 」，和记录文件的层级对上。
    static func tidy(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("# ") }
            .map { $0.hasPrefix("## ") ? "#" + $0 : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 提示词是给模型看的，不是界面文案：按纪要语言写死两套。末尾的 /no_think 关掉 Qwen3 的「思考」。

    private static func notesPrompt(_ part: String, part index: Int, of count: Int, chinese: Bool) -> String {
        if chinese {
            return """
            你是会议记录助手。下面是一场会议 / 对话实时字幕记录的第 \(index)/\(count) 段（语音识别结果，可能有错字、中英混杂）。
            请用简体中文列出这一段讲到的要点、决定和待办，每条一行、以「- 」开头，最多 10 条。
            只写记录里有的内容，不要编造，不要输出别的内容。

            记录：
            \(part)
            /no_think
            """
        }
        return """
        You are a meeting-notes assistant. Below is part \(index) of \(count) of a live transcript of a meeting or \
        conversation (speech recognition output; it may contain errors and mixed Chinese/English).
        List the key points, decisions and action items in this part in English, one per line starting with "- ", \
        at most 10. Only include what the transcript says; do not make things up and output nothing else.

        Transcript:
        \(part)
        /no_think
        """
    }

    private static func minutesPrompt(_ body: String, fromNotes: Bool, chinese: Bool) -> String {
        if chinese {
            let intro = fromNotes
                ? "下面是一场会议 / 对话按时间顺序分段整理出的要点。"
                : "下面是一场会议 / 对话的实时字幕记录（语音识别结果，可能有错字、中英混杂）。"
            return """
            你是会议记录助手。\(intro)请整理成简体中文的会议纪要，严格按下面的格式输出，只写记录里出现过的内容，不要编造，不要输出别的内容：

            ### 要点
            - 最重要的几条内容，每条一句
            ### 结论
            - 达成的共识、做出的决定；没有就写「无」
            ### 待办
            - 谁要做什么、什么时候；没有就写「无」

            \(fromNotes ? "分段要点" : "记录")：
            \(body)
            /no_think
            """
        }
        let intro = fromNotes
            ? "Below are notes taken part by part, in order, from a meeting or conversation."
            : "Below is a live transcript of a meeting or conversation (speech recognition output; it may contain errors and mixed Chinese/English)."
        return """
        You are a meeting-notes assistant. \(intro) Write meeting minutes in English using exactly this format. \
        Only include what the \(fromNotes ? "notes say" : "transcript says"); do not make things up and output nothing else:

        ### Key points
        - the most important points, one sentence each
        ### Decisions
        - agreements and decisions made; write "None" if there are none
        ### Action items
        - who does what, by when; write "None" if there are none

        \(fromNotes ? "Notes" : "Transcript"):
        \(body)
        /no_think
        """
    }

    // MARK: 会议纪要（docs/meeting/TECH_DESIGN.md §2.3）

    private static func meetingNotesPrompt(_ part: String, part index: Int, of count: Int, chinese: Bool) -> String {
        if chinese {
            return """
            你是会议记录助手。下面是一场会议实时转录的第 \(index)/\(count) 段（语音识别结果，可能有错字、中英混杂；「我」是记录者本人，\
            「对方」是会上的其他人，按声音来源判的、可能不准；带「【重点】」的是记录者标记的重点）。
            请用简体中文列出这一段的要点、决定和行动项（谁、做什么、什么时候），标了【重点】的一定要保留，每条一行、以「- 」开头，最多 10 条。
            只写记录里有的内容，不要编造，不要输出别的内容。

            记录：
            \(part)
            /no_think
            """
        }
        return """
        You are a meeting-notes assistant. Below is part \(index) of \(count) of a live meeting transcript (speech \
        recognition output; it may contain errors and mixed Chinese/English). "我"/"Me" is the note taker and "对方"/"Them" \
        is someone else in the meeting (guessed from the audio source, may be wrong); lines marked 【重点】 were \
        highlighted by the note taker.
        List the key points, decisions and action items (who, what, by when) in this part in English, one per line \
        starting with "- ", at most 10, always keeping the highlighted ones. Only include what the transcript says; do not \
        make things up and output nothing else.

        Transcript:
        \(part)
        /no_think
        """
    }

    /// 输出固定为「## 摘要 / ## 决议 / ## 行动项 / ## 重点」四节，行动项每条「- [ ] 负责人：事项（截止：…）」；
    /// 会议类型只换各节写什么。
    private static func meetingPrompt(_ body: String, fromNotes: Bool, notes: String, style: MeetingMinutesStyle,
                                      chinese: Bool) -> String {
        let headings = MeetingMinutesFormat.headings(chinese: chinese)
        if chinese {
            let intro = fromNotes
                ? "下面是一场会议按时间顺序分段整理出的要点。"
                : "下面是一场会议的实时转录（语音识别结果，可能有错字、中英混杂）。"
            let focus: String
            switch style {
            case .standard: focus = ""
            case .standup: focus = "这是一场站会：摘要按人写每个人昨天做了什么、今天打算做什么、遇到了什么阻碍；行动项写需要跟进的阻碍和答应要做的事。\n"
            case .oneOnOne: focus = "这是一场一对一沟通：摘要写聊到的话题、双方的反馈与想法；决议写达成的共识；行动项写双方各自答应要做的事。\n"
            case .interview: focus = "这是一场面试：摘要写候选人的背景、对各个问题的回答与表现；决议只写记录里明确说到的面试结论或下一步安排；重点写候选人的亮点与顾虑。\n"
            }
            let context = notes.isEmpty ? "" : "会议速记（记录者在会上手记的，可作参考）：\n\(notes)\n\n"
            return """
            你是会议纪要助手。\(intro)「我」是记录者本人，「对方」是会上的其他人（按声音来源判的，可能不准）；\
            带「【重点】」的是记录者标记的重点，请优先写进纪要。
            \(focus)请整理成简体中文的会议纪要，严格按下面的格式输出这四节，只写记录里出现过的内容，不要编造，不要输出别的内容：

            ## \(headings[0])
            - 会议的主要内容，3～6 条，每条一句
            ## \(headings[1])
            - 达成的共识、做出的决定；没有就写「- 无」
            ## \(headings[2])
            - [ ] 负责人：事项（截止：…）
            ## \(headings[3])
            - 标了【重点】的内容和其他关键信息；没有就写「- 无」

            行动项每条一行，都以「- [ ] 」开头，把「负责人」「事项」「…」换成记录里的人名、要做的事和时间；\
            记录里没说负责人或截止时间就省掉那部分；没有行动项就写「- 无」。

            \(context)\(fromNotes ? "分段要点" : "记录")：
            \(body)
            /no_think
            """
        }
        let intro = fromNotes
            ? "Below are notes taken part by part, in order, from a meeting."
            : "Below is a live meeting transcript (speech recognition output; it may contain errors and mixed Chinese/English)."
        let focus: String
        switch style {
        case .standard: focus = ""
        case .standup: focus = "This is a stand-up: in the summary, give each person's yesterday, today and blockers; action items are blockers to follow up and commitments.\n"
        case .oneOnOne: focus = "This is a one-on-one: the summary covers the topics discussed and each side's feedback; decisions are what both agreed on; action items are what each side committed to.\n"
        case .interview: focus = "This is an interview: the summary covers the candidate's background and answers; decisions only include an outcome or next step the transcript states; highlights are the candidate's strengths and concerns.\n"
        }
        let context = notes.isEmpty ? "" : "Meeting notes (typed by the note taker during the meeting, for reference):\n\(notes)\n\n"
        return """
        You are a meeting-minutes assistant. \(intro) "我"/"Me" is the note taker and "对方"/"Them" is someone else in the \
        meeting (guessed from the audio source, may be wrong); lines marked 【重点】 were highlighted by the note taker, so \
        give them priority.
        \(focus)Write the minutes in English using exactly these four sections. Only include what the \
        \(fromNotes ? "notes say" : "transcript says"); do not make things up and output nothing else:

        ## \(headings[0])
        - the main points, 3-6 bullets, one sentence each
        ## \(headings[1])
        - agreements and decisions; write "- None" if there are none
        ## \(headings[2])
        - [ ] Owner: task (due: …)
        ## \(headings[3])
        - highlighted content and other key information; write "- None" if there is none

        Write each action item on its own line starting with "- [ ] ", replacing "Owner", "task" and "…" with the \
        person, the thing to do and the date from the transcript. Leave out the owner or due date if the transcript \
        doesn't say; write "- None" if there are no action items.

        \(context)\(fromNotes ? "Notes" : "Transcript"):
        \(body)
        /no_think
        """
    }
}
