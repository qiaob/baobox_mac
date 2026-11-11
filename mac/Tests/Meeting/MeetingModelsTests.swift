import Foundation
import XCTest

/// 会议的数据模型（meta.json / index.json）：外部可改的文件，解析全程容错（docs/meeting/TECH_DESIGN.md §4）。
final class MeetingModelsTests: XCTestCase {

    private func decode(_ json: String) -> MeetingMeta? {
        MeetingMeta.decode(Data(json.utf8))
    }

    func testMetaRoundTripsThroughJSON() throws {
        let meta = MeetingMeta(
            id: "abc", type: .online, title: "设计评审", start: localDate(10, 0, 0), end: localDate(10, 45, 0),
            attendees: ["张三", "李四"], calendar: MeetingCalendarRef(eventID: "e1", seriesKey: "ext:s1", calendar: "工作"),
            status: .summarized, template: "standup", highlights: [MeetingHighlight(t: 30, text: "重点")],
            actionItems: [MeetingActionItem(id: "i1", text: "整理发布说明", owner: "张三", due: "周五", done: true)])
        let data = try XCTUnwrap(meta.encoded())
        XCTAssertEqual(MeetingMeta.decode(data), meta)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"start\" : \"\(MeetingDates.string(localDate(10, 0, 0)))\""), "时间写成本地时区的 ISO 8601")
        XCTAssertTrue(text.contains("\"v\" : 1"))
    }

    func testMetaDecodingIsLenient() throws {
        let meta = try XCTUnwrap(decode("""
            {"v": "2", "id": "  m1  ", "type": "webinar", "title": 42, "start": "2026-11-10T02:00:05.250Z",
             "end": 1794276000, "attendees": ["张三", 7, "  ", " 李四 "], "calendar": {},
             "status": "archived", "highlights": [{"t": -5, "text": "早"}, {"t": "12.5"}, "坏的"],
             "actionItems": [{"text": "写测试", "done": "yes"}, {"owner": "没有事项"}, {"text": "发版", "done": 0}]}
            """))
        XCTAssertEqual(meta.v, 2)
        XCTAssertEqual(meta.id, "m1")
        XCTAssertEqual(meta.type, .offline, "认不出的类型按线下")
        XCTAssertEqual(meta.title, "")
        XCTAssertEqual(meta.start, Date(timeIntervalSince1970: 1_794_276_005.25))
        XCTAssertEqual(meta.end, Date(timeIntervalSince1970: 1_794_276_000))
        XCTAssertEqual(meta.attendees, ["张三", "李四"])
        XCTAssertNil(meta.calendar, "空的日历引用为 nil")
        XCTAssertEqual(meta.status, .transcribed, "认不出的状态按仅转录")
        XCTAssertEqual(meta.template, "standard")
        XCTAssertEqual(meta.highlights, [MeetingHighlight(t: 0, text: "早"), MeetingHighlight(t: 12.5, text: "")])
        XCTAssertEqual(meta.actionItems.map(\.text), ["写测试", "发版"], "没有事项文字的跳过")
        XCTAssertEqual(meta.actionItems.map(\.done), [true, false])
        XCTAssertEqual(meta.openActionItemCount, 1)
    }

    func testMetaWithoutIDOrStartStillDecodesForTheScannerToRepair() throws {
        let meta = try XCTUnwrap(decode("{}"))
        XCTAssertEqual(meta.id, "")
        XCTAssertEqual(meta.start, .distantPast)
        XCTAssertNil(decode("[]"), "不是 JSON 对象")
        XCTAssertNil(decode(""))
        XCTAssertNil(decode("{\"id\": \"m1\""), "写到一半")
    }

    func testDurationIsNeverNegative() {
        var meta = MeetingMeta(type: .online, title: "t", start: localDate(10, 0, 0))
        XCTAssertNil(meta.duration)
        meta.end = localDate(10, 30, 0)
        XCTAssertEqual(meta.duration, 1800)
        meta.end = localDate(9, 0, 0)
        XCTAssertEqual(meta.duration, 0)
    }

    func testDatesParseWithOrWithoutFractionalSecondsInAnyZone() {
        XCTAssertEqual(MeetingDates.date("2026-11-10T10:00:05+08:00"), Date(timeIntervalSince1970: 1_794_276_005))
        XCTAssertEqual(MeetingDates.date(" 2026-11-10T02:00:05Z "), Date(timeIntervalSince1970: 1_794_276_005))
        XCTAssertEqual(MeetingDates.date("2026-11-10T02:00:05.5Z"), Date(timeIntervalSince1970: 1_794_276_005.5))
        XCTAssertNil(MeetingDates.date(""))
        XCTAssertNil(MeetingDates.date("2026-11-10"))
        XCTAssertEqual(MeetingDates.date(MeetingDates.string(localDate(10, 0, 5))), localDate(10, 0, 5))
    }

    func testRecordNeedsADirAndAMetaWithIDAndStart() throws {
        let json = """
            [{"dir": "2026/2026-11-10 10-00 周会", "meta": {"id": "m1", "type": "online", "title": "周会",
              "start": "2026-11-10T10:00:00+08:00", "status": "recording"}},
             {"meta": {"id": "m2", "start": "2026-11-10T10:00:00+08:00"}},
             {"dir": "2026/x", "meta": {"title": "没有 id"}}]
            """
        let elements = try JSONDecoder().decode([MeetingLenient.Element<MeetingRecord>].self, from: Data(json.utf8))
        XCTAssertEqual(elements.map { $0.value?.id }, ["m1", nil, nil])
        XCTAssertEqual(elements.first?.value?.meta.status, .recording)
        XCTAssertNil(MeetingLibraryScanner.decodeIndex(Data(json.utf8)), "有一条坏的就整份重建")
    }

    func testCalendarRefFromAnEvent() {
        let event = MeetingEventInfo(title: "周会", start: localDate(10, 0, 0), end: localDate(11, 0, 0),
                                     seriesKey: "ext:s1", eventID: "e1", calendarTitle: "工作")
        XCTAssertEqual(MeetingCalendarRef(event: event), MeetingCalendarRef(eventID: "e1", seriesKey: "ext:s1", calendar: "工作"))
        XCTAssertTrue(MeetingCalendarRef().isEmpty)
    }
}
