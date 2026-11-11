import Foundation
import XCTest

/// 读 meeting.md（会议库详情、重新生成纪要、周报）与写周报（docs/meeting/TECH_DESIGN.md §2.3、§4）。
final class MeetingMarkdownTests: XCTestCase {

    private let document = """
    # 设计评审

    - 类型：线上会议
    - 开始：2026-11-10 10:00:00

    ## 纪要

    ### 摘要
    - 回顾了上周进度
    - 无
    ### 决议
    - **周五**发布 0.0.9
    - 无
    ### 行动项
    - [ ] 张三：整理发布说明（截止：周五）

    ## 速记

    议程：发布计划

    ## 转录

    **10:00:02 我** 大家好
    > Hi all

    *10:00:04 暂停记录*

    🔖 **10:00:05** 标记重点

    **10:00:06** 没有说话人的一句

    ## 附录

    多出来的一节
    """

    func testSectionsSplitByLevelTwoHeadingsAndUnknownOnesGoToTheTranscript() {
        let sections = MeetingMarkdown.sections(document)
        XCTAssertEqual(sections.minutes, """
            ### 摘要
            - 回顾了上周进度
            - 无
            ### 决议
            - **周五**发布 0.0.9
            - 无
            ### 行动项
            - [ ] 张三：整理发布说明（截止：周五）
            """)
        XCTAssertEqual(sections.notes, "议程：发布计划")
        XCTAssertEqual(sections.transcript, """
            **10:00:02 我** 大家好
            > Hi all

            *10:00:04 暂停记录*

            🔖 **10:00:05** 标记重点

            **10:00:06** 没有说话人的一句

            ## 附录

            多出来的一节
            """)
    }

    func testSectionsAcceptEnglishAndLegacyHeadingsAndMissingOrEmptySectionsAreNil() {
        let english = MeetingMarkdown.sections("# Live\n\n## Minutes\n\n### Key points\n- one\n\n## Notes\n\n\n## Transcript\n\n**10:00:00** hi\n")
        XCTAssertEqual(english.minutes, "### Key points\n- one")
        XCTAssertNil(english.notes, "空的一节为 nil")
        XCTAssertEqual(english.transcript, "**10:00:00** hi")

        let legacy = MeetingMarkdown.sections("# 实时翻译记录\n\n## 记录\n\n**10:00:00** 你好\n")
        XCTAssertNil(legacy.minutes)
        XCTAssertNil(legacy.notes)
        XCTAssertEqual(legacy.transcript, "**10:00:00** 你好")
    }

    func testHeadingHelpers() {
        XCTAssertEqual(MeetingMarkdown.level2Heading("##  纪要 "), "纪要")
        XCTAssertNil(MeetingMarkdown.level2Heading("### 摘要"))
        XCTAssertNil(MeetingMarkdown.level2Heading("##纪要"))
        let minutes = MeetingMarkdown.sections(document).minutes ?? ""
        XCTAssertEqual(MeetingMarkdown.lines(under: ["行动项"], in: minutes), ["- [ ] 张三：整理发布说明（截止：周五）"])
        XCTAssertEqual(MeetingMarkdown.removingSubsections(["行动项", "摘要"], from: minutes),
                       "### 决议\n- **周五**发布 0.0.9\n- 无")
    }

    func testBulletTextAndPlaceholders() {
        XCTAssertEqual(MeetingMarkdown.bulletText("  - 一条 "), "一条")
        XCTAssertEqual(MeetingMarkdown.bulletText("* 二"), "二")
        XCTAssertEqual(MeetingMarkdown.bulletText("• 三"), "三")
        XCTAssertEqual(MeetingMarkdown.bulletText("+ 四"), "四")
        XCTAssertEqual(MeetingMarkdown.bulletText("12. 五"), "五")
        XCTAssertEqual(MeetingMarkdown.bulletText("3) 六"), "六")
        XCTAssertEqual(MeetingMarkdown.bulletText("4、七"), "七")
        XCTAssertNil(MeetingMarkdown.bulletText("普通的一行"))
        XCTAssertNil(MeetingMarkdown.bulletText(".5 不是编号"))

        for placeholder in ["无", "无。", "None.", "N/A", "  ", "—", "…"] {
            XCTAssertTrue(MeetingMarkdown.isPlaceholder(placeholder), placeholder)
        }
        XCTAssertFalse(MeetingMarkdown.isPlaceholder("有内容"))
    }

    func testSummaryAndDecisionsSkipPlaceholders() {
        let minutes = MeetingMarkdown.sections(document).minutes ?? ""
        XCTAssertEqual(MeetingMarkdown.summary(fromMinutes: minutes), "- 回顾了上周进度")
        XCTAssertEqual(MeetingMarkdown.oneLineSummary(fromMinutes: minutes), "回顾了上周进度")
        XCTAssertEqual(MeetingMarkdown.decisions(fromMinutes: minutes), ["周五发布 0.0.9"])

        // 没有「摘要 / 要点」那一节：取纪要开头几行（不含小标题）。
        let loose = "### 其他\n第一行\n\n第二行\n第三行"
        XCTAssertEqual(MeetingMarkdown.summary(fromMinutes: loose, maxLines: 2), "第一行\n第二行")
        // 自由听译的纪要：要点 / 结论。
        let content = "### 要点\n- 定了时间\n### 结论\n- 周五发布\n### 待办\n- 无"
        XCTAssertEqual(MeetingMarkdown.oneLineSummary(fromMinutes: content), "定了时间")
        XCTAssertEqual(MeetingMarkdown.decisions(fromMinutes: content), ["周五发布"])
    }

    func testTranscriptReadsLinesSpeakersMarksAndNotes() {
        let transcript = MeetingMarkdown.transcript(document, start: localDate(10, 0, 0))
        XCTAssertEqual(transcript.lines, [
            MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 2), text: "大家好", speaker: "我"),
            MeetingMarkdown.TranscriptLine(time: localDate(10, 0, 6), text: "没有说话人的一句", speaker: nil),
        ])
        XCTAssertEqual(transcript.marks, [localDate(10, 0, 5)])
        XCTAssertEqual(transcript.notes, "议程：发布计划")
    }

    func testTranscriptTimesPastMidnightMoveToTheNextDay() {
        let markdown = "## 转录\n\n**23:59:50 我** 快到零点了\n\n**00:00:10 对方** 过了零点\n\n**25:00:00** 坏时刻\n"
        let transcript = MeetingMarkdown.transcript(markdown, start: localDate(23, 50, 0))
        XCTAssertEqual(transcript.lines.map(\.time), [localDate(23, 59, 50), localDate(0, 0, 10, day: 11)])
        XCTAssertEqual(transcript.lines.map(\.text), ["快到零点了", "过了零点"])
    }

    func testReplacingMinutesReplacesOrInsertsTheSection() {
        let replaced = MeetingMarkdown.replacingMinutes(in: document, with: "\n### 摘要\n- 新的\n", heading: "纪要")
        XCTAssertEqual(MeetingMarkdown.sections(replaced).minutes, "### 摘要\n- 新的")
        XCTAssertEqual(MeetingMarkdown.sections(replaced).notes, "议程：发布计划")

        let noMinutes = "# 标题\n\n- 开始：…\n\n## 转录\n\n**10:00:00** 你好\n"
        XCTAssertEqual(MeetingMarkdown.replacingMinutes(in: noMinutes, with: "- 一条", heading: "纪要"),
                       "# 标题\n\n- 开始：…\n\n## 纪要\n\n- 一条\n\n## 转录\n\n**10:00:00** 你好\n")

        XCTAssertEqual(MeetingMarkdown.replacingMinutes(in: "# 只有标题", with: "- 一条", heading: "Minutes"),
                       "# 只有标题\n\n## Minutes\n\n- 一条\n")
    }

    // MARK: - 周报

    private func weeklyLabels() -> MeetingWeeklyReport.Labels {
        MeetingWeeklyReport.Labels(
            title: "周报", overview: "概述", meetings: "会议", decisions: "决议", openItems: "未完成的行动项", none: "无",
            listSeparator: "、", due: { "（截止：\($0)）" }, dateTime: { _ in "周二 10:00" }, duration: { "\(Int($0) / 60) 分钟" })
    }

    private func record(_ id: String, type: MeetingType = .online, title: String, start: Date, end: Date? = nil,
                        attendees: [String] = [], items: [MeetingActionItem] = []) -> MeetingRecord {
        MeetingRecord(dir: "2026/" + id, meta: MeetingMeta(id: id, type: type, title: title, start: start, end: end,
                                                           attendees: attendees, status: .summarized, actionItems: items))
    }

    func testWeekIsTheISOWeekFromMondayToMonday() {
        let calendar = MeetingWeeklyReport.isoCalendar()
        let week = MeetingWeeklyReport.week(containing: localDate(10, 0, 0), calendar: calendar)    // 2026-11-10 周二
        XCTAssertEqual(week.key, "2026-W46")
        XCTAssertEqual(week.interval.start, localDate(0, 0, 0, day: 9))
        XCTAssertEqual(week.interval.end, localDate(0, 0, 0, day: 16))
    }

    func testWeeklyMeetingsSkipFreeListeningAndOtherWeeks() {
        let interval = DateInterval(start: localDate(0, 0, 0, day: 9), end: localDate(0, 0, 0, day: 16))
        let records = [
            record("b", title: "周会", start: localDate(15, 0, 0, day: 12)),
            record("a", type: .offline, title: "一对一", start: localDate(9, 0, 0, day: 10)),
            record("free", type: .free, title: "自由听译", start: localDate(11, 0, 0, day: 10)),
            record("old", title: "上周的", start: localDate(9, 0, 0, day: 6)),
            record("next", title: "下周的", start: localDate(0, 0, 0, day: 16)),
        ]
        XCTAssertEqual(MeetingWeeklyReport.meetings(in: records, during: interval).map(\.id), ["a", "b"])
    }

    func testComposeListsMeetingsDecisionsAndOpenItems() {
        let labels = weeklyLabels()
        let review = record("r", title: "设计评审", start: localDate(10, 0, 0), end: localDate(10, 45, 0),
                            attendees: ["张三", "李四"],
                            items: [MeetingActionItem(text: "整理发布说明", owner: "张三", due: "周五"),
                                    MeetingActionItem(text: "已经做完的", done: true)])
        let standup = record("s", title: "站会", start: localDate(9, 0, 0), end: localDate(9, 0, 30))
        let entries = [MeetingWeeklyReport.Entry(record: standup, minutes: nil),
                       MeetingWeeklyReport.Entry(record: review, minutes: "### 决议\n- 周五发布\n- 无")]

        XCTAssertEqual(MeetingWeeklyReport.itemLine(review.meta.actionItems[0], labels: labels), "张三：整理发布说明（截止：周五）")
        XCTAssertEqual(MeetingWeeklyReport.overviewInput(entries, labels: labels), """
            # 站会（周二 10:00）

            # 设计评审（周二 10:00）
            - 决议：周五发布
            - 未完成的行动项：张三：整理发布说明（截止：周五）
            """)
        XCTAssertEqual(MeetingWeeklyReport.compose(entries: entries, overview: "  这周定了发布。 ", labels: labels), """
            # 周报

            ## 概述

            这周定了发布。

            ## 会议

            - 周二 10:00 站会
            - 周二 10:00 设计评审 · 45 分钟 · 张三、李四

            ## 决议

            ### 设计评审（周二 10:00）

            - 周五发布

            ## 未完成的行动项

            - [ ] 张三：整理发布说明（截止：周五） — 设计评审（周二 10:00）


            """)
    }

    func testComposeWithNothingThisWeek() {
        XCTAssertEqual(MeetingWeeklyReport.compose(entries: [], overview: nil, labels: weeklyLabels()),
                       "# 周报\n\n## 会议\n\n无\n\n## 决议\n\n无\n\n## 未完成的行动项\n\n无\n")
    }
}
