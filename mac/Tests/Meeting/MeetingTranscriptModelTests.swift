import Foundation
import XCTest

/// meeting.md 的模型与排版（docs/meeting/ENGINE.md §5.4）：两种版式的整份输出（金样）、与 `MeetingMarkdown` 的往返、
/// 「改为」、速记、纪要决策表、喂给模型的行。
final class MeetingTranscriptModelTests: XCTestCase {

    // MARK: - 造文档

    private func meetingSpec(title: String = "线上会议", kind: String = "线上会议", attendees: [String] = [],
                             calendar: String? = nil, speakers: Bool = true,
                             style: MeetingMinutesStyle = .standard) -> MeetingTranscriptSpec {
        var spec = MeetingTranscriptSpec(
            fileURL: URL(fileURLWithPath: "/Meetings/2026/2026-11-10 10-00 \(title)/meeting.md"),
            displayName: "2026-11-10 10-00 \(title)",
            header: MeetingTranscriptSpec.Header(title: title, kind: kind, start: localDate(10, 0, 0),
                                                 attendees: attendees, calendar: calendar))
        spec.speakers = speakers
        spec.template = .meeting(style)
        spec.summarizes = true
        spec.notifiesMinutes = false
        return spec
    }

    private func freeListeningSpec(summarizes: Bool = true) -> MeetingTranscriptSpec {
        var spec = MeetingTranscriptSpec(fileURL: URL(fileURLWithPath: "/Meetings/2026/2026-11-10 10-00 自由听译/meeting.md"),
                                         displayName: "2026-11-10 10-00 自由听译")
        spec.summarizes = summarizes
        return spec
    }

    private let freeRun = MeetingEngineRun(source: "麦克风", speech: "简体中文", target: "English")

    // MARK: - 金样（照探针里那份文档收到的调用逐个重放）

    func testMeetingLayoutWithEventHeaderNotesAndMarkMatchesTheGolden() {
        var model = MeetingTranscriptModel(
            spec: meetingSpec(title: "设计评审", attendees: ["张三", "李四", "王五"], calendar: "工作"),
            start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        let one = engineLine("1-2", Speech.one, at: localDate(10, 0, 2), speaker: .me)
        let two = engineLine("1-3", Speech.two, at: localDate(10, 0, 5))
        let three = engineLine("1-4", Speech.three, at: localDate(10, 0, 9), speaker: .them)
        model.update(one)
        model.update(two)
        model.mark(at: localDate(10, 0, 6))
        model.setNotes("  决定：周五发布  \n")
        model.update(three)
        // 收尾冲刷：引擎把字幕条上的几句再报一遍（内容没变）。
        XCTAssertFalse(model.update(one))
        XCTAssertFalse(model.update(two))
        XCTAssertFalse(model.update(three))
        model.finish(at: localDate(10, 0, 11), summarizes: true, terminating: false, ready: true)
        XCTAssertEqual(model.minutes, .generating)
        model.minutes = .done(Speech.minutes)

        XCTAssertEqual(model.render(), MeetingTranscriptGoldens.eventHeader)
    }

    func testMeetingLayoutWithLaneMuteNotesMatchesTheGolden() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        let lines = [engineLine("1-2", Speech.one, at: localDate(10, 0, 2), speaker: .me),
                     engineLine("1-3", Speech.two, at: localDate(10, 0, 7), speaker: .them),
                     engineLine("1-4", Speech.three, at: localDate(10, 0, 14), speaker: .me)]
        model.update(lines[0])
        model.note(.microphoneMuted, at: localDate(10, 0, 4))
        model.update(lines[1])
        model.note(.microphoneUnmuted, at: localDate(10, 0, 9))
        model.note(.systemMuted, at: localDate(10, 0, 11))
        model.update(lines[2])
        model.note(.systemUnmuted, at: localDate(10, 0, 16))
        lines.forEach { model.update($0) }
        model.finish(at: localDate(10, 0, 18), summarizes: true, terminating: false, ready: true)
        model.minutes = .done(Speech.minutes)

        XCTAssertEqual(model.render(), MeetingTranscriptGoldens.muteNotes)
    }

    func testMeetingLayoutWhenTheAppQuitsMatchesTheGolden() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        let one = engineLine("1-2", Speech.one, at: localDate(10, 0, 2), speaker: .me)
        let two = engineLine("1-3", Speech.two, at: localDate(10, 0, 6), speaker: .them)
        model.update(one)
        model.update(two)
        model.update(one)
        model.update(two)
        model.update(engineLine("1-4", "那我们周五", at: localDate(10, 0, 9), speaker: .me))
        model.finish(at: localDate(10, 0, 10), summarizes: true, terminating: true, ready: true)
        XCTAssertEqual(model.minutes, .interrupted)

        XCTAssertEqual(model.render(), MeetingTranscriptGoldens.quitInterrupted)
    }

    func testFreeListeningLayoutWithATranslationMatchesTheGolden() {
        var model = MeetingTranscriptModel(spec: freeListeningSpec(), start: localDate(10, 0, 5), run: freeRun,
                                           labels: .zhHans)
        let first = engineLine("1-2", "第一句，没开保存。", at: localDate(10, 0, 2))
        let second = engineLine("1-3", "第二句，也没开保存。", at: localDate(10, 0, 4))
        let translated = engineLine("1-4", Speech.one, at: localDate(10, 0, 7), translation: "Hi all, release plan.")
        model.update(first)
        model.update(second)
        model.update(engineLine("1-4", Speech.one, at: localDate(10, 0, 7)))
        XCTAssertTrue(model.update(translated), "译文回来：同一 key 覆盖")
        [first, second, translated].forEach { model.update($0) }
        model.finish(at: localDate(10, 0, 9), summarizes: true, terminating: false, ready: true)
        model.minutes = .done(Speech.minutes)

        XCTAssertEqual(model.render(), MeetingTranscriptGoldens.freeListening)
    }

    /// 重启后的「改为」一行。重启前的句子在结束时以新的运行次数又报了一遍（键不同）：那是引擎的 #149，文档照收到的写。
    func testFreeListeningLayoutAcrossARestartMatchesTheGolden() {
        var model = MeetingTranscriptModel(spec: freeListeningSpec(), start: localDate(10, 0, 11), run: freeRun,
                                           labels: .zhHans)
        let texts = [(2, "第一句，没开保存。", localDate(10, 0, 2), ""),
                     (3, "第二句，也没开保存。", localDate(10, 0, 4), ""),
                     (4, Speech.one, localDate(10, 0, 7), "Hi all, release plan."),
                     (5, Speech.two, localDate(10, 0, 13), ""),
                     (6, Speech.three, localDate(10, 0, 15), "")]
        for run in ["1", "1"] {
            for (id, text, time, translation) in texts {
                model.update(engineLine("\(run)-\(id)", text, at: time, translation: translation))
            }
        }
        XCTAssertTrue(model.continueWith(MeetingEngineRun(source: "麦克风", speech: "English", target: "English"),
                                         at: localDate(10, 0, 16)))
        let after = engineLine("2-8", "And this is after the restart, in English.", at: localDate(10, 0, 18))
        model.update(after)
        for (id, text, time, translation) in texts {
            model.update(engineLine("2-\(id)", text, at: time, translation: translation))
        }
        model.update(after)
        model.finish(at: localDate(10, 0, 20), summarizes: true, terminating: false, ready: true)
        model.minutes = .done(Speech.minutes)

        XCTAssertEqual(model.render(), MeetingTranscriptGoldens.freeListeningRestart)
    }

    // MARK: - 与 MeetingMarkdown 往返（会议库、重新生成纪要、周报按同一版式读回）

    func testMeetingDocumentReadsBackThroughMeetingMarkdown() {
        var model = MeetingTranscriptModel(spec: meetingSpec(title: "设计评审"), start: localDate(10, 0, 0), run: onlineRun,
                                           labels: .zhHans)
        model.update(engineLine("1-1", Speech.one, at: localDate(10, 0, 2), translation: "Hi all.", speaker: .me))
        model.update(engineLine("1-2", Speech.two, at: localDate(10, 0, 5)))
        model.note(.paused, at: localDate(10, 0, 6))
        model.mark(at: localDate(10, 0, 7))
        model.continueWith(englishRun, at: localDate(10, 0, 8))
        model.update(engineLine("2-1", "Then we ship on Friday.", at: localDate(10, 0, 9), speaker: .them))
        model.setNotes("决定：周五发布\n风险：测试时间不够")
        model.finish(at: localDate(10, 0, 11), summarizes: true, terminating: false, ready: true)
        model.minutes = .done(Speech.minutes)
        let markdown = model.render()

        let sections = MeetingMarkdown.sections(markdown)
        XCTAssertEqual(sections.minutes, Speech.minutes)
        XCTAssertEqual(sections.notes, "决定：周五发布\n风险：测试时间不够")
        let transcript = MeetingMarkdown.transcript(markdown, start: localDate(10, 0, 0))
        XCTAssertEqual(transcript.lines, [
            MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 2), text: Speech.one, speaker: "我"),
            MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 5), text: Speech.two, speaker: nil),
            MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 9), text: "Then we ship on Friday.", speaker: "对方"),
        ], "说明行、「改为」、译文都不算句子")
        XCTAssertEqual(transcript.marks, [localDate(10, 0, 7)])
        XCTAssertEqual(transcript.notes, "决定：周五发布\n风险：测试时间不够")
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(sections.minutes ?? "").map(\.text), ["整理发布说明"])
        XCTAssertEqual(MeetingMarkdown.decisions(fromMinutes: sections.minutes ?? ""), ["周五发布 0.0.9"])
    }

    func testFreeListeningDocumentReadsBackThroughMeetingMarkdown() {
        var model = MeetingTranscriptModel(spec: freeListeningSpec(), start: localDate(10, 0, 5), run: freeRun,
                                           labels: .zhHans)
        model.update(engineLine("1-1", "第一句", at: localDate(10, 0, 6), translation: "First."))
        let markdown = model.render()

        let sections = MeetingMarkdown.sections(markdown)
        XCTAssertEqual(sections.minutes, "停止后用本地 AI 整理（要点、结论、待办），写在这里。")
        XCTAssertNil(sections.notes)
        XCTAssertEqual(sections.transcript, "**10:00:06** 第一句\n> First.")
        XCTAssertEqual(MeetingMarkdown.transcript(markdown, start: localDate(10, 0, 5)).lines,
                       [MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 6), text: "第一句", speaker: nil)])
    }

    func testRegeneratedMinutesReplaceOnlyTheMinutesSection() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-1", Speech.one, at: localDate(10, 0, 2), speaker: .me))
        model.setNotes("速记一行")
        model.finish(at: localDate(10, 0, 9), summarizes: true, terminating: false, ready: false)
        let markdown = model.render()
        XCTAssertEqual(MeetingMarkdown.sections(markdown).minutes, MeetingTranscriptModel.Labels.zhHans.minutesNoModel)

        let replaced = MeetingMarkdown.replacingMinutes(in: markdown, with: Speech.minutes, heading: "纪要")
        let sections = MeetingMarkdown.sections(replaced)
        XCTAssertEqual(sections.minutes, Speech.minutes)
        XCTAssertEqual(sections.notes, "速记一行")
        XCTAssertEqual(sections.transcript, MeetingMarkdown.sections(markdown).transcript)
    }

    // MARK: - 内容

    func testUpdateWithTheSameContentIsNoChangeAndALaterResultReplacesTheLine() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        XCTAssertFalse(model.hasContent)
        XCTAssertTrue(model.update(engineLine("1-1", "大家好", at: localDate(10, 0, 1), speaker: .me)))
        XCTAssertTrue(model.hasContent)
        XCTAssertFalse(model.update(engineLine("1-1", "大家好", at: localDate(10, 0, 3), speaker: .me)), "只看文字和说话人")
        XCTAssertTrue(model.update(engineLine("1-1", "大家好！", at: localDate(10, 0, 2), speaker: .them)), "纠错回来")

        XCTAssertTrue(model.render().hasSuffix("## 转录\n\n**10:00:02 对方** 大家好！\n\n"))
    }

    func testNotesAreTrimmedAndCountAsContent() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        XCTAssertTrue(model.setNotes("\n  议程：发布计划  \n"))
        XCTAssertEqual(model.notes, "议程：发布计划")
        XCTAssertTrue(model.hasContent, "只有速记也算有内容（会议记了速记就留下）")
        XCTAssertFalse(model.setNotes("议程：发布计划\n"), "去掉空白后没变")
        XCTAssertTrue(model.setNotes(""))
        XCTAssertFalse(model.hasContent)
    }

    func testContinueWithOnlyWritesAChangeLineWhenTheRunReallyChanged() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-1", "大家好", at: localDate(10, 0, 1), speaker: .me))
        XCTAssertFalse(model.continueWith(onlineRun, at: localDate(10, 0, 2)))
        XCTAssertTrue(model.continueWith(englishRun, at: localDate(10, 0, 3)))
        XCTAssertFalse(model.continueWith(englishRun, at: localDate(10, 0, 4)))
        let translated = MeetingEngineRun(source: "麦克风", speech: "English", target: "简体中文")
        XCTAssertTrue(model.continueWith(translated, at: localDate(10, 0, 5)))

        let markdown = model.render()
        XCTAssertTrue(markdown.hasSuffix("""
            **10:00:01 我** 大家好

            *10:00:03 改为：麦克风 + 系统声音 · 说：English · 译成：不翻译*

            *10:00:05 改为：麦克风 · 说：English · 译成：简体中文*


            """))
        XCTAssertTrue(markdown.contains("- 音源：麦克风 + 系统声音\n- 说：简体中文 · 译成：不翻译\n"), "文件头写开始时那一次")
    }

    func testItemsAreOrderedByTimeThenByWhenTheyWereWritten() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.mark(at: localDate(10, 0, 5))
        model.update(engineLine("1-2", "后说的", at: localDate(10, 0, 6), speaker: .them))
        model.update(engineLine("1-1", "先说的", at: localDate(10, 0, 5), speaker: .me))
        model.note(.paused, at: localDate(10, 0, 5))

        XCTAssertTrue(model.render().hasSuffix("""
            🔖 **10:00:05** 标记重点

            **10:00:05 我** 先说的

            *10:00:05 暂停记录*

            **10:00:06 对方** 后说的


            """))
    }

    func testSpeakersAreOnlyWrittenWhenTheMeetingMarksThem() {
        var model = MeetingTranscriptModel(spec: meetingSpec(title: "线下会议", kind: "线下会议", speakers: false),
                                           start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-1", "大家好", at: localDate(10, 0, 1), speaker: .me))
        XCTAssertTrue(model.render().hasSuffix("**10:00:01** 大家好\n\n"))
        XCTAssertNil(model.minutesInput.first?.speaker)
    }

    func testEveryNoteHasItsOwnLine() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        for (index, note) in MeetingTranscriptNote.allCases.enumerated() {
            model.note(note, at: localDate(10, 0, index))
        }
        XCTAssertTrue(model.render().hasSuffix("""
            *10:00:00 暂停记录*

            *10:00:01 继续记录*

            *10:00:02 麦克风静音（不录你的声音）*

            *10:00:03 麦克风恢复*

            *10:00:04 系统声音静音（不录对方的声音）*

            *10:00:05 系统声音恢复*


            """))
    }

    func testLongMeetingsShowHoursAndMinutes() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.finish(at: localDate(11, 5, 30), summarizes: true, terminating: false, ready: false)
        XCTAssertTrue(model.render().contains("- 结束：2026-11-10 11:05:30（1小时5分钟）\n"))
    }

    // MARK: - 纪要

    func testMinutesDecisionTable() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-1", String(repeating: "长", count: 30), at: localDate(10, 0, 1)))
        model.setNotes(String(repeating: "记", count: 9))         // 30 + 9 = 39 字

        XCTAssertEqual(model.decideMinutes(summarizes: false, terminating: true, ready: true), .off)
        XCTAssertEqual(model.decideMinutes(summarizes: true, terminating: true, ready: false), .interrupted)
        XCTAssertEqual(model.decideMinutes(summarizes: true, terminating: false, ready: false), .noModel)
        XCTAssertEqual(model.decideMinutes(summarizes: true, terminating: false, ready: true), .tooShort)
        model.setNotes(String(repeating: "记", count: 10))        // 40 字：够了
        XCTAssertEqual(model.decideMinutes(summarizes: true, terminating: false, ready: true), .generating)
    }

    func testOnlyOriginalTextCountsTowardsTheMinimumNotTranslations() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-1", "短句", at: localDate(10, 0, 1), translation: String(repeating: "x", count: 100)))
        XCTAssertEqual(model.decideMinutes(summarizes: true, terminating: false, ready: true), .tooShort)
    }

    func testMinutesSectionForEveryState() {
        func section(_ minutes: MeetingTranscriptModel.Minutes, template: MeetingMinutesStyle? = .standard) -> String? {
            let spec = template.map { meetingSpec(style: $0) } ?? freeListeningSpec()
            var model = MeetingTranscriptModel(spec: spec, start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
            model.minutes = minutes
            return MeetingMarkdown.sections(model.render()).minutes
        }
        XCTAssertNil(section(.off))
        XCTAssertEqual(section(.later), "会议结束后用本地 AI 整理（摘要、决议、行动项、重点），写在这里。")
        XCTAssertEqual(section(.later, template: nil), "停止后用本地 AI 整理（要点、结论、待办），写在这里。")
        XCTAssertEqual(section(.generating), "正在用本地 AI 整理纪要…")
        XCTAssertEqual(section(.done("### 摘要\n- 一条")), "### 摘要\n- 一条")
        XCTAssertEqual(section(.failed("请求超时")), "纪要没整理出来：请求超时")
        XCTAssertEqual(section(.noModel), MeetingTranscriptModel.Labels.zhHans.minutesNoModel)
        XCTAssertEqual(section(.tooShort), "内容太少，没有整理纪要。")
        XCTAssertEqual(section(.interrupted), "纪要没整理完（Baobox 退出了）。")
    }

    func testMinutesStartAsLaterOnlyWhenSummarizing() {
        let on = MeetingTranscriptModel(spec: freeListeningSpec(summarizes: true), start: localDate(10, 0, 0), run: freeRun,
                                        labels: .zhHans)
        XCTAssertEqual(on.minutes, .later)
        XCTAssertEqual(on.minutes.outcome, .generating)
        let off = MeetingTranscriptModel(spec: freeListeningSpec(summarizes: false), start: localDate(10, 0, 0), run: freeRun,
                                         labels: .zhHans)
        XCTAssertEqual(off.minutes, .off)
        XCTAssertFalse(off.render().contains("## 纪要"))
    }

    func testMinutesOutcomeMapping() {
        XCTAssertEqual(MeetingTranscriptModel.Minutes.off.outcome, .off)
        XCTAssertEqual(MeetingTranscriptModel.Minutes.later.outcome, .generating)
        XCTAssertEqual(MeetingTranscriptModel.Minutes.generating.outcome, .generating)
        XCTAssertEqual(MeetingTranscriptModel.Minutes.done("a").outcome, .done("a"))
        XCTAssertEqual(MeetingTranscriptModel.Minutes.failed("b").outcome, .failed("b"))
        XCTAssertEqual(MeetingTranscriptModel.Minutes.noModel.outcome, .noModel)
        XCTAssertEqual(MeetingTranscriptModel.Minutes.tooShort.outcome, .tooShort)
        XCTAssertEqual(MeetingTranscriptModel.Minutes.interrupted.outcome, .interrupted)
    }

    func testMinutesInputCarriesSpeakersAndHighlightsInTimeOrder() {
        var model = MeetingTranscriptModel(spec: meetingSpec(), start: localDate(10, 0, 0), run: onlineRun, labels: .zhHans)
        model.update(engineLine("1-3", "标记后 5 秒", at: localDate(10, 1, 5), speaker: .them))
        model.update(engineLine("1-1", "标记前 21 秒", at: localDate(10, 0, 39), speaker: .me))
        model.update(engineLine("1-2", "标记前 20 秒", at: localDate(10, 0, 40)))
        model.update(engineLine("1-4", "标记后 6 秒", at: localDate(10, 1, 6), speaker: .me))
        model.mark(at: localDate(10, 1, 0))

        XCTAssertEqual(model.minutesInput, [
            MeetingMinutesPrompts.Line(time: localDate(10, 0, 39), text: "标记前 21 秒", speaker: "我", highlighted: false),
            MeetingMinutesPrompts.Line(time: localDate(10, 0, 40), text: "标记前 20 秒", speaker: nil, highlighted: true),
            MeetingMinutesPrompts.Line(time: localDate(10, 1, 5), text: "标记后 5 秒", speaker: "对方", highlighted: true),
            MeetingMinutesPrompts.Line(time: localDate(10, 1, 6), text: "标记后 6 秒", speaker: "我", highlighted: false),
        ])
        XCTAssertEqual(MeetingMinutesPrompts.meetingRows(model.minutesInput), [
            "[10:00] 我：标记前 21 秒", "[10:00] 【重点】标记前 20 秒", "[10:01] 【重点】对方：标记后 5 秒", "[10:01] 我：标记后 6 秒",
        ])
    }

    func testStatusAfterEachMinutesOutcome() {
        XCTAssertEqual(MeetingStatus.after(.generating), .summarizing)
        XCTAssertEqual(MeetingStatus.after(.done("纪要")), .summarized)
        XCTAssertEqual(MeetingStatus.after(.failed("出错")), .failed)
        for outcome in [MeetingMinutesOutcome.off, .noModel, .tooShort, .interrupted] {
            XCTAssertEqual(MeetingStatus.after(outcome), .transcribed, "\(outcome)")
        }
    }
}
