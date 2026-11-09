import AppKit
import os

private let reportsLog = Logger(subsystem: "com.baobox.app", category: "meeting.reports")

/// 会议库里的「重新生成纪要」（需求 §4）：读回 meeting.md 的转录、🔖 标记与速记，按这场的模板交给本地模型重写纪要，
/// 只换掉纪要一节（速记、转录原样），行动项重新解析（同一条之前勾过完成的保留勾选）。一次只做一场。
@MainActor
final class MeetingMinutesRegenerator: ObservableObject {
    static let shared = MeetingMinutesRegenerator()
    private init() {}

    /// 正在重新生成的会议。
    @Published private(set) var running: Set<String> = []

    /// 记录中、整理中的不行；正在重新生成别的也要等它做完。
    func canRegenerate(_ record: MeetingRecord) -> Bool {
        running.isEmpty && record.meta.status != .recording && record.meta.status != .summarizing
            && record.id != MeetingSessionController.shared.meetingID
    }

    func regenerate(_ id: String) {
        let store = MeetingStore.shared
        guard let record = store.record(id), canRegenerate(record) else { return }
        let route = AIService.shared.route(for: .meetingMinutes)
        guard AIService.shared.isReady(route, local: .generation) else {
            MeetingLibraryModel.shared.flash(L("meeting.regenerate.noModel"))
            return
        }
        // 「整理中」只在内存里（`running`）：不写进 meta.json —— 中途退出的话旧纪要还在文件里，启动修复不该把它降成「仅转录」。
        running.insert(id)
        store.loadMarkdown(id) { text in
            MeetingMinutesRegenerator.shared.generate(id, markdown: text, record: record)
        }
    }

    private func generate(_ id: String, markdown: String?, record: MeetingRecord) {
        guard let markdown else {
            fail(id, message: L("meeting.regenerate.unreadable"))
            return
        }
        let transcript = MeetingMarkdown.transcript(markdown, start: record.meta.start)
        guard !transcript.lines.isEmpty else {
            fail(id, message: L("meeting.regenerate.empty"))
            return
        }
        let lines = transcript.lines.map {
            LiveTranslateMinutes.Line(time: $0.time, text: $0.text, speaker: $0.speaker,
                                      highlighted: LiveTranslateMeetingMinutes.isHighlighted($0.time, marks: transcript.marks))
        }
        let template = LiveTranslateMinutesTemplate(storageValue: record.meta.template)
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        let notes = transcript.notes
        // 走本地时通用模型常驻到写完；选了云端模型就不加载本地模型。
        let keepsLocal = AIService.shared.route(for: .meetingMinutes) == .local
        Task {
            if keepsLocal { AIService.shared.beginLocalKeepAlive(.generation) }
            defer { if keepsLocal { AIService.shared.endLocalKeepAlive(.generation) } }
            do {
                let minutes = try await LiveTranslateMinutes.generate(lines: lines, chinese: chinese, template: template,
                                                                      notes: notes)
                let updated = MeetingMarkdown.replacingMinutes(in: markdown, with: minutes,
                                                               heading: L("livetranslate.record.doc.minutes"))
                MeetingStore.shared.writeMarkdown(id, text: updated) { succeeded in
                    MeetingMinutesRegenerator.shared.written(id, succeeded: succeeded, minutes: minutes, markdown: updated,
                                                             template: template)
                }
            } catch {
                reportsLog.error("regenerate minutes failed: \(error.localizedDescription, privacy: .public)")
                MeetingMinutesRegenerator.shared.fail(id, message: L("meeting.regenerate.failed \(error.localizedDescription)"))
            }
        }
    }

    private func written(_ id: String, succeeded: Bool, minutes: String, markdown: String,
                         template: LiveTranslateMinutesTemplate) {
        guard succeeded else {
            fail(id, message: L("meeting.regenerate.writeFailed"))
            return
        }
        running.remove(id)
        MeetingStore.shared.update(id) { meta in
            meta.status = .summarized
            guard case .meeting = template else { return }
            let done = Set(meta.actionItems.filter(\.done).map(\.text))
            meta.actionItems = LiveTranslateMeetingMinutes.parseActionItems(minutes).map {
                MeetingActionItem(text: $0.text, owner: $0.owner, due: $0.due, done: $0.done || done.contains($0.text))
            }
        }
        MeetingLibraryModel.shared.setText(id, markdown)
        MeetingLibraryModel.shared.flash(L("meeting.regenerate.done"))
    }

    /// 没生成出来：文件、状态都没动过，只提示一句。
    private func fail(_ id: String, message: String) {
        running.remove(id)
        MeetingLibraryModel.shared.flash(message)
    }
}

/// 会议周报（需求 §4）：本周（ISO 周）各会议的决议与未完成行动项，规则汇总；装了本地模型就再写一段概述（没装跳过），
/// 存进会议库 `weekly/<yyyy-Www>.md` 并打开。
@MainActor
final class MeetingWeeklyReporter {
    static let shared = MeetingWeeklyReporter()
    private init() {}

    private(set) var isRunning = false

    func generate() {
        guard !isRunning else {
            toast(L("meeting.weekly.running"))
            return
        }
        let now = Date()
        let calendar = MeetingWeeklyReport.isoCalendar()
        let week = MeetingWeeklyReport.week(containing: now, calendar: calendar)
        let meetings = MeetingWeeklyReport.meetings(in: MeetingStore.shared.records, during: week.interval)
        guard !meetings.isEmpty else {
            toast(L("meeting.weekly.empty"))
            return
        }
        isRunning = true
        toast(L("meeting.weekly.generating"))
        MeetingStore.shared.loadMarkdowns(meetings.map(\.id)) { texts in
            let entries = meetings.map { record in
                MeetingWeeklyReport.Entry(record: record,
                                          minutes: texts[record.id].flatMap { MeetingMarkdown.sections($0).minutes })
            }
            MeetingWeeklyReporter.shared.compose(entries, key: week.key, interval: week.interval)
        }
    }

    private func compose(_ entries: [MeetingWeeklyReport.Entry], key: String, interval: DateInterval) {
        let labels = Self.labels(key: key, interval: interval)
        Task {
            var overview: String?
            let route = AIService.shared.route(for: .meetingWeekly)
            if AIService.shared.isReady(route, local: .generation) {
                do {
                    overview = try await Self.overview(entries, labels: labels, route: route)
                } catch {
                    reportsLog.error("weekly overview failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let text = MeetingWeeklyReport.compose(entries: entries, overview: overview, labels: labels)
            MeetingStore.shared.writeWeekly(key, text: text) { url in
                MeetingWeeklyReporter.shared.isRunning = false
                guard let url else {
                    MeetingWeeklyReporter.shared.toast(L("meeting.weekly.failed"))
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func labels(key: String, interval: DateInterval) -> MeetingWeeklyReport.Labels {
        let last = interval.end.addingTimeInterval(-1)
        let range = MeetingText.shortDay(interval.start) + " – " + MeetingText.shortDay(last)
        return MeetingWeeklyReport.Labels(
            title: L("meeting.weekly.title \(key) \(range)"),
            overview: L("meeting.weekly.overview"),
            meetings: L("meeting.weekly.meetings"),
            decisions: L("meeting.weekly.decisions"),
            openItems: L("meeting.weekly.openItems"),
            none: L("meeting.weekly.none"),
            listSeparator: L("livetranslate.record.doc.listSeparator"),
            due: { L("meeting.actions.due \($0)") },
            dateTime: { MeetingText.dateTime($0) },
            duration: { MeetingText.duration($0) })
    }

    /// 让本地模型（Qwen3-1.7B）写一段 2–4 句的本周概述。材料超出上下文就截断。
    private static func overview(_ entries: [MeetingWeeklyReport.Entry],
                                 labels: MeetingWeeklyReport.Labels, route: AIRoute) async throws -> String? {
        let material = LiveTranslateMinutes.clip(MeetingWeeklyReport.overviewInput(entries, labels: labels), budget: 2400)
        guard !material.isEmpty else { return nil }
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        // 提示词是给模型看的，不是界面文案：按语言写死两套。末尾 /no_think 关掉 Qwen3 的「思考」。
        let prompt: String
        if chinese {
            prompt = """
            你是会议助理。下面是本周各场会议的决议与未完成的行动项。请用简体中文写一段 2–4 句的本周概述：主要进展、关键决定、需要跟进的事。
            只写材料里有的内容，不要编造；不要列表，不要标题，不要输出别的内容。

            材料：
            \(material)
            /no_think
            """
        } else {
            prompt = """
            You are a meeting assistant. Below are this week's decisions and open action items from each meeting. \
            Write a 2–4 sentence overview of the week in English: main progress, key decisions, what needs follow-up. \
            Only use what the material says; no lists, no headings, nothing else.

            Material:
            \(material)
            /no_think
            """
        }
        // 走哪个模型按「周报概述」这个功能选的（默认本地，docs/ai-service/DESIGN.md §5.4）；走本地时模型常驻到写完。
        let keepsLocal = route == .local
        if keepsLocal { AIService.shared.beginLocalKeepAlive(.generation) }
        defer { if keepsLocal { AIService.shared.endLocalKeepAlive(.generation) } }
        let answer = try await AIService.shared.generate(prompt, maxTokens: 400, sampling: .summary, route: route,
                                                         timeout: 60).text
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func toast(_ text: String) {
        NotifyCenter.shared.post(PetNotification(source: MeetingSessionController.source, level: .ambient, title: text,
                                                 icon: "doc.text"))
    }
}
