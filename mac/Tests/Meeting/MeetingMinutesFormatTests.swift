import Foundation
import XCTest

/// 纪要模板与会议纪要固定格式（docs/meeting/ENGINE.md §5.4）：模板存储值、重点窗口、输入行、行动项的宽松解析。
final class MeetingMinutesFormatTests: XCTestCase {

    func testTemplateStorageValuesRoundTrip() {
        XCTAssertEqual(MeetingMinutesTemplate.content.storageValue, "content")
        for style in MeetingMinutesStyle.allCases {
            XCTAssertEqual(MeetingMinutesTemplate.meeting(style).storageValue, style.rawValue)
            XCTAssertEqual(MeetingMinutesTemplate(storageValue: style.rawValue), .meeting(style))
        }
        XCTAssertEqual(MeetingMinutesTemplate(storageValue: "content"), .content)
        XCTAssertEqual(MeetingMinutesTemplate(storageValue: nil), .meeting(.standard), "旧 meta.json 没有模板：按默认会议纪要")
        XCTAssertEqual(MeetingMinutesTemplate(storageValue: "weekly"), .meeting(.standard))
        XCTAssertEqual(MeetingMinutesStyle.allCases.map(\.rawValue), ["standard", "standup", "oneOnOne", "interview"])
    }

    func testHeadingsFollowTheMinutesLanguage() {
        XCTAssertEqual(MeetingMinutesFormat.headings(chinese: true), ["摘要", "决议", "行动项", "重点"])
        XCTAssertEqual(MeetingMinutesFormat.headings(chinese: false), ["Summary", "Decisions", "Action items", "Highlights"])
    }

    func testHighlightWindowIsTwentySecondsBeforeToFiveSecondsAfterAMark() {
        let mark = localDate(10, 1, 0)
        XCTAssertTrue(MeetingMinutesFormat.isHighlighted(localDate(10, 0, 40), marks: [mark]))
        XCTAssertFalse(MeetingMinutesFormat.isHighlighted(localDate(10, 0, 39), marks: [mark]))
        XCTAssertTrue(MeetingMinutesFormat.isHighlighted(localDate(10, 1, 5), marks: [mark]))
        XCTAssertFalse(MeetingMinutesFormat.isHighlighted(localDate(10, 1, 6), marks: [mark]))
        XCTAssertTrue(MeetingMinutesFormat.isHighlighted(localDate(10, 5, 0), marks: [mark, localDate(10, 5, 10)]))
        XCTAssertFalse(MeetingMinutesFormat.isHighlighted(localDate(10, 1, 0), marks: []))
    }

    func testRowPutsTheHighlightBeforeTheSpeaker() {
        XCTAssertEqual(MeetingMinutesFormat.row(clock: "10:32", text: "好的", speaker: "对方", highlighted: true),
                       "[10:32] 【重点】对方：好的")
        XCTAssertEqual(MeetingMinutesFormat.row(clock: "10:32", text: "好的", speaker: nil, highlighted: false), "[10:32] 好的")
        XCTAssertEqual(MeetingMinutesFormat.row(clock: "10:32", text: "好的", speaker: "", highlighted: false), "[10:32] 好的")
    }

    private func item(_ text: String, owner: String? = nil, due: String? = nil, done: Bool = false)
        -> MeetingMinutesFormat.ActionItem {
        MeetingMinutesFormat.ActionItem(text: text, owner: owner, due: due, done: done)
    }

    func testActionItemsWithOwnerAndDueInBothLanguages() {
        let minutes = """
        ## 行动项
        - [ ] 张三：整理发布说明（截止：周五）
        - [x] 李四: 发邮件 (due: Friday)
        * [ ] 更新文档
        1. [ ] 王五：准备材料，截止：下周一
        - [X] **赵六**：写测试。
        """
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(minutes), [
            item("整理发布说明", owner: "张三", due: "周五"),
            item("发邮件", owner: "李四", due: "Friday", done: true),
            item("更新文档"),
            item("准备材料", owner: "王五", due: "下周一"),
            item("写测试", owner: "赵六", done: true),
        ])
    }

    func testCheckboxesAnywhereCountButPlainBulletsAndOtherMarksDoNot() {
        let minutes = """
        ### 摘要
        - 普通的一条，不是行动项
        [ ] 没有列表符号也认
        - [-] 半勾的不算
        - [ab] 也不算
        ### 重点
        + [ ] 别的小节下面也认
        """
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(minutes).map(\.text), ["没有列表符号也认", "别的小节下面也认"])
    }

    func testPlaceholdersAndCopiedTemplatesAreSkipped() {
        let minutes = """
        - [ ] 无
        - [ ] None.
        - [ ] 事项
        - [ ] 负责人：事项（截止：…）
        - [ ] task
        - [ ]
        """
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(minutes), [])
    }

    func testPlaceholderOwnersAndDueDatesAreDropped() {
        let minutes = """
        - [ ] 未指定：跟进崩溃（截止：待定）
        - [ ] Owner: review the PR (due: TBD)
        - [ ] 负责人：王五：排期（截止：周三）
        """
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(minutes), [
            item("跟进崩溃"),
            item("review the PR"),
            item("排期", owner: "王五", due: "周三"),
        ])
    }

    func testAColonInsideTheTaskIsNotAnOwner() {
        let minutes = """
        - [ ] 先看日志，再定：要不要回滚
        - [ ] 这一段说明写得非常非常非常非常长超过二十个字了：后面才是事
        """
        XCTAssertEqual(MeetingMinutesFormat.parseActionItems(minutes), [
            item("先看日志，再定：要不要回滚"),
            item("这一段说明写得非常非常非常非常长超过二十个字了：后面才是事"),
        ])
    }
}
