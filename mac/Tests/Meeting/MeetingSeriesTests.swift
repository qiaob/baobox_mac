import Foundation
import XCTest

/// 会议系列与会前简报（docs/meeting/TECH_DESIGN.md §4）：系列键、规范化标题、同系列、上一场与未完成行动项。
final class MeetingSeriesTests: XCTestCase {

    private func record(_ id: String, type: MeetingType = .online, title: String, start: Date, seriesKey: String? = nil,
                        status: MeetingStatus = .summarized, items: [MeetingActionItem] = []) -> MeetingRecord {
        let calendar = seriesKey.map { MeetingCalendarRef(seriesKey: $0) }
        return MeetingRecord(dir: "2026/" + id, meta: MeetingMeta(id: id, type: type, title: title, start: start,
                                                                calendar: calendar, status: status, actionItems: items))
    }

    func testSeriesKeyUsesTheRecurringIDOrTheNormalizedTitle() {
        XCTAssertEqual(MeetingSeries.key(title: "周会", recurringID: " abc "), "ext:abc")
        XCTAssertEqual(MeetingSeries.key(title: "周会 第3期", recurringID: ""), "title:周会")
        XCTAssertNil(MeetingSeries.key(title: "  ", recurringID: nil))
    }

    func testNormalizedTitleDropsDatesNumbersAndPunctuation() {
        XCTAssertEqual(MeetingSeries.normalizedTitle("产品周会 2026年11月6日"), "产品周会")
        XCTAssertEqual(MeetingSeries.normalizedTitle("第 3 期 · 设计评审"), "设计评审")
        XCTAssertEqual(MeetingSeries.normalizedTitle("Sprint #12 Review (W45)"), "sprint review")
        XCTAssertEqual(MeetingSeries.normalizedTitle("周四站会"), "站会")
        XCTAssertEqual(MeetingSeries.normalizedTitle("Q4 OKR v2.1"), "okr")
        XCTAssertEqual(MeetingSeries.normalizedTitle("2026-11-06"), "2026-11-06", "去完什么也不剩：退回原标题")
    }

    func testSameSeriesBySeriesKeyOrByNameButNotTwoDifferentRecurringEvents() {
        let weekly = record("a", title: "周会", start: localDate(10, 0, 0, day: 3), seriesKey: "ext:w")
        XCTAssertTrue(MeetingSeries.matches(seriesKey: "ext:w", title: "完全不同的名字", record: weekly))
        XCTAssertFalse(MeetingSeries.matches(seriesKey: "ext:other", title: "周会", record: weekly), "两个不同的重复事件同名也不算")
        XCTAssertTrue(MeetingSeries.matches(seriesKey: nil, title: "周会 11月10日", record: weekly))
        XCTAssertTrue(MeetingSeries.matches(seriesKey: "title:周会", title: "周会", record: weekly))
        let untitled = record("b", title: "线上会议", start: localDate(10, 0, 0, day: 3))
        XCTAssertFalse(MeetingSeries.matches(seriesKey: nil, title: "线上会议", record: untitled), "默认标题不按同名归")
        XCTAssertTrue(MeetingSeries.isDefaultTitle(" Online Meeting "))
    }

    func testSeriesRecordsAndTimelineSkipFreeListening() {
        let first = record("1", title: "周会", start: localDate(10, 0, 0, day: 3))
        let second = record("2", title: "周会", start: localDate(10, 0, 0, day: 10))
        let free = record("f", type: .free, title: "周会", start: localDate(9, 0, 0, day: 5))
        let other = record("o", title: "一对一", start: localDate(9, 0, 0, day: 4))
        let all = [second, free, other, first]
        XCTAssertEqual(MeetingSeries.records(in: all, seriesKey: nil, title: "周会").map(\.id), ["1", "2"])
        XCTAssertEqual(MeetingSeries.timeline(of: second, in: all).map(\.id), ["1", "2"])
        XCTAssertEqual(MeetingSeries.timeline(of: free, in: all).map(\.id), ["f"])
        let lonely = record("x", title: "只开过一次", start: localDate(9, 0, 0))
        XCTAssertEqual(MeetingSeries.timeline(of: lonely, in: all).map(\.id), ["x"], "不在列表里的也带上它自己")
    }

    func testBriefingHasThePreviousMeetingAndAllOpenItemsOfTheSeries() {
        let old = record("old", title: "周会", start: localDate(10, 0, 0, day: 3),
                         items: [MeetingActionItem(id: "i1", text: "旧的待办"), MeetingActionItem(id: "i2", text: "做完了", done: true)])
        let recent = record("recent", title: "周会", start: localDate(10, 0, 0, day: 9),
                            items: [MeetingActionItem(id: "i3", text: "新的待办", owner: "张三")])
        let earlyStart = record("early", title: "周会", start: localDate(9, 40, 0))
        let recording = record("rec", title: "周会", start: localDate(9, 50, 0), status: .recording)
        let briefing = MeetingBriefing.make(seriesKey: nil, title: "周会", start: localDate(10, 0, 0),
                                            records: [recording, earlyStart, recent, old])

        XCTAssertEqual(briefing.previous?.id, "recent", "提前几分钟开的同一场不算上一场；记录中的不算")
        XCTAssertEqual(briefing.openItems.map(\.item.text), ["旧的待办", "新的待办"])
        XCTAssertEqual(briefing.openItems.map(\.meetingID), ["old", "recent"])
        XCTAssertFalse(briefing.isEmpty)

        let excluding = MeetingBriefing.make(seriesKey: nil, title: "周会", start: localDate(10, 0, 0, day: 10),
                                             records: [recent], excluding: "recent")
        XCTAssertTrue(excluding.isEmpty, "正在记录的那场自己不是上一场")
    }
}
