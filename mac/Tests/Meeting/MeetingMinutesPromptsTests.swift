import Foundation
import XCTest

/// 纪要的提示词与切段（docs/meeting/ENGINE.md §5.4）：token 估算、切段预算、合并截断、`tidy`、`clip`、输入行、提示词的骨架。
final class MeetingMinutesPromptsTests: XCTestCase {

    func testTokenEstimateCountsCJKOneEachAndOtherTextAtAboutThreeAndAHalfCharacters() {
        XCTAssertEqual(MeetingMinutesPrompts.tokens(""), 0)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("会议纪要"), 4)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("a"), 1, "宁多勿少：一个字符也算一个")
        XCTAssertEqual(MeetingMinutesPrompts.tokens("abc"), 1)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("abcd"), 2)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("abcdefg"), 2)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("中文ab"), 3)
        XCTAssertEqual(MeetingMinutesPrompts.tokens("한국"), 2, "韩文按中日韩算")
        XCTAssertEqual(MeetingMinutesPrompts.tokens("ＡＢ"), 2, "全角字符按中日韩算")
    }

    func testChunkStartsANewPartWhenTheNextRowWouldGoOverBudget() {
        // 每行 3 个汉字 = 3 token，加换行 1 = 4。
        let rows = ["一二三", "四五六", "七八九"]
        XCTAssertEqual(MeetingMinutesPrompts.chunk(rows, budget: 10), ["一二三\n四五六", "七八九"])
        XCTAssertEqual(MeetingMinutesPrompts.chunk(rows, budget: 12), ["一二三\n四五六\n七八九"])
        XCTAssertEqual(MeetingMinutesPrompts.chunk(rows, budget: 3), ["一二三", "四五六", "七八九"],
                       "一行就超预算也自成一段，不丢")
        XCTAssertEqual(MeetingMinutesPrompts.chunk([], budget: 10), [])
    }

    func testChunkDefaultBudgetIsTheInputBudget() {
        XCTAssertEqual(MeetingMinutesPrompts.inputBudget, 2200)
        let row = String(repeating: "字", count: 99)                // 100 token 一行
        XCTAssertEqual(MeetingMinutesPrompts.chunk(Array(repeating: row, count: 22)).count, 1)
        XCTAssertEqual(MeetingMinutesPrompts.chunk(Array(repeating: row, count: 23)).count, 2)
    }

    func testFitKeepsTheFirstLinesOfEachPartWithinAnEvenShareOfTheBudget() {
        let line = "- " + String(repeating: "要", count: 50)        // 51 token，加换行 52
        let note = [line, line, line].joined(separator: "\n")
        // 两段平分 300 → 每段 150：留两行（104），第三行（156）不要。
        XCTAssertEqual(MeetingMinutesPrompts.fit([note, "- 短\n\n- 也短"], chinese: true, budget: 300),
                       "第 1 段：\n\(line)\n\(line)\n\n第 2 段：\n- 短\n- 也短")
        // 每段至少 120。
        XCTAssertEqual(MeetingMinutesPrompts.fit([note], chinese: false, budget: 10), "Part 1:\n\(line)\n\(line)")
    }

    func testTidyDropsATopLevelTitleAndDemotesSectionHeadings() {
        let raw = "\n# 会议纪要\n## 摘要\n- 一条\n### 已经是三级\n#没有空格\n\n"
        XCTAssertEqual(MeetingMinutesPrompts.tidy(raw), "### 摘要\n- 一条\n### 已经是三级\n#没有空格")
    }

    func testClipKeepsWholeNonBlankLinesWithinTheBudget() {
        let text = "一\n\n   \n二二\n三三三\n四"
        XCTAssertEqual(MeetingMinutesPrompts.clip(text, budget: 5), "一\n二二")
        XCTAssertEqual(MeetingMinutesPrompts.clip(text, budget: 100), "一\n二二\n三三三\n四")
        XCTAssertEqual(MeetingMinutesPrompts.clip(text, budget: 1), "")
    }

    func testMeetingBudgetLeavesRoomForTheNotesButNeverDropsBelow800() {
        XCTAssertEqual(MeetingMinutesPrompts.notesBudget, 400)
        XCTAssertEqual(MeetingMinutesPrompts.meetingBudget(notes: ""), 2200)
        XCTAssertEqual(MeetingMinutesPrompts.meetingBudget(notes: String(repeating: "记", count: 400)), 1800)
        XCTAssertEqual(MeetingMinutesPrompts.meetingBudget(notes: String(repeating: "记", count: 1500)), 800)
    }

    func testInputRowsForBothTemplates() {
        let lines = [
            MeetingMinutesPrompts.Line(time: localDate(10, 32, 5), text: "大家好", speaker: "我", highlighted: true),
            MeetingMinutesPrompts.Line(time: localDate(10, 33, 59), text: "收到", speaker: "", highlighted: false),
            MeetingMinutesPrompts.Line(time: localDate(9, 5, 0), text: "Hi", speaker: nil, highlighted: false),
        ]
        XCTAssertEqual(MeetingMinutesPrompts.contentRows(lines), ["[10:32] 大家好", "[10:33] 收到", "[09:05] Hi"],
                       "自由听译不写说话人和重点")
        XCTAssertEqual(MeetingMinutesPrompts.meetingRows(lines), ["[10:32] 【重点】我：大家好", "[10:33] 收到", "[09:05] Hi"])
    }

    func testContentPromptsSayWhichPartAndEndWithNoThink() {
        let notes = MeetingMinutesPrompts.notesPrompt("[10:00] 大家好", part: 2, of: 3, chinese: true)
        XCTAssertTrue(notes.contains("实时字幕记录的第 2/3 段"))
        XCTAssertTrue(notes.hasSuffix("记录：\n[10:00] 大家好\n/no_think"))
        let english = MeetingMinutesPrompts.notesPrompt("[10:00] Hi", part: 1, of: 2, chinese: false)
        XCTAssertTrue(english.contains("Below is part 1 of 2 of a live transcript"))
        XCTAssertTrue(english.hasSuffix("Transcript:\n[10:00] Hi\n/no_think"))

        let direct = MeetingMinutesPrompts.minutesPrompt("BODY", fromNotes: false, chinese: true)
        XCTAssertTrue(direct.contains("### 要点\n- 最重要的几条内容，每条一句\n### 结论\n"))
        XCTAssertTrue(direct.hasSuffix("记录：\nBODY\n/no_think"))
        let merged = MeetingMinutesPrompts.minutesPrompt("BODY", fromNotes: true, chinese: false)
        XCTAssertTrue(merged.contains("Below are notes taken part by part"))
        XCTAssertTrue(merged.contains("Only include what the notes say"))
        XCTAssertTrue(merged.hasSuffix("Notes:\nBODY\n/no_think"))
    }

    func testMeetingPromptHasTheFourSectionsTheStyleFocusAndTheNotes() {
        let standup = MeetingMinutesPrompts.meetingPrompt("BODY", fromNotes: false, notes: "速记一行", style: .standup,
                                                          chinese: true)
        XCTAssertTrue(standup.contains("## 摘要\n- 会议的主要内容，3～6 条，每条一句\n## 决议\n"))
        XCTAssertTrue(standup.contains("## 行动项\n- [ ] 负责人：事项（截止：…）\n## 重点\n"))
        XCTAssertTrue(standup.contains("\n这是一场站会："))
        XCTAssertTrue(standup.hasSuffix("会议速记（记录者在会上手记的，可作参考）：\n速记一行\n\n记录：\nBODY\n/no_think"))

        let standard = MeetingMinutesPrompts.meetingPrompt("BODY", fromNotes: true, notes: "", style: .standard,
                                                           chinese: true)
        XCTAssertTrue(standard.contains("请优先写进纪要。\n请整理成简体中文的会议纪要"), "默认类型没有侧重那一行")
        XCTAssertTrue(standard.hasSuffix("\n分段要点：\nBODY\n/no_think"), "没有速记就不带那一段")

        let interview = MeetingMinutesPrompts.meetingPrompt("BODY", fromNotes: false, notes: "", style: .interview,
                                                            chinese: false)
        XCTAssertTrue(interview.contains("## Summary\n- the main points"))
        XCTAssertTrue(interview.contains("## Highlights\n"))
        XCTAssertTrue(interview.contains("\nThis is an interview:"))
        XCTAssertTrue(interview.hasSuffix("\n\nTranscript:\nBODY\n/no_think"))

        let notes = MeetingMinutesPrompts.meetingNotesPrompt("BODY", part: 1, of: 4, chinese: true)
        XCTAssertTrue(notes.contains("实时转录的第 1/4 段"))
        XCTAssertTrue(notes.contains("标了【重点】的一定要保留"))
    }
}
