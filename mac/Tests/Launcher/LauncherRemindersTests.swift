import Foundation
import XCTest

/// 一次性提醒的模型和规则（docs/launcher/TECH_DESIGN.md §5.6）：`reminders.json` 的读写容错、到点、晚了多久、哪一天。
final class LauncherRemindersTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder(_ id: String, in seconds: TimeInterval, _ text: String = "取快递") -> LauncherReminder {
        LauncherReminder(id: id, date: now.addingTimeInterval(seconds), text: text, created: now)
    }

    // MARK: - 读写

    func testRoundTrip() throws {
        let list = [reminder("a", in: 600), reminder("b", in: 60, "开会")]
        let data = try XCTUnwrap(LauncherReminderBook.encode(list))
        XCTAssertEqual(LauncherReminderBook.decode(data), [list[1], list[0]], "读回来按到点时刻排")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"version\":1"), text)
    }

    func testDecodeIsTolerant() throws {
        let json = """
        {"version": 9, "extra": true, "reminders": [
          {"id": "ok", "date": 1800000600, "text": "  取快递  ", "created": 1800000000},
          {"id": "noCreated", "date": 1800000700, "text": "开会"},
          {"id": "ok", "date": 1800000800, "text": "重复的 id"},
          {"id": "", "date": 1800000600, "text": "空 id"},
          {"id": "badDate", "date": "明天", "text": "x"},
          {"id": "boolDate", "date": true, "text": "x"},
          {"id": "emptyText", "date": 1800000600, "text": "   "},
          {"id": "noText", "date": 1800000600},
          "不是对象", 42
        ]}
        """
        let decoded = LauncherReminderBook.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map(\.id), ["ok", "noCreated"])
        XCTAssertEqual(decoded.first?.text, "取快递")
        XCTAssertEqual(decoded.last?.created, decoded.last?.date, "没有 created 时当成到点时刻")
    }

    func testDecodeGarbage() {
        for text in ["", "[]", "42", "{\"reminders\": {}}", "{\"reminders\": null}", "not json"] {
            XCTAssertEqual(LauncherReminderBook.decode(Data(text.utf8)), [], text)
        }
    }

    func testLongTextIsCut() throws {
        let long = reminder("long", in: 60, String(repeating: "字", count: 500))
        let data = try XCTUnwrap(LauncherReminderBook.encode([long]))
        XCTAssertEqual(LauncherReminderBook.decode(data).first?.text.count, LauncherReminderBook.maxTextLength)
    }

    // MARK: - 规则

    func testInsertingSortsAndCaps() {
        var list: [LauncherReminder] = []
        for index in 0..<LauncherReminderBook.maxCount {
            list = LauncherReminderBook.inserting(reminder("r\(index)", in: TimeInterval(1_000 + index)), into: list)
        }
        XCTAssertEqual(list.count, LauncherReminderBook.maxCount)
        let latest = reminder("latest", in: 1_000_000)
        list = LauncherReminderBook.inserting(latest, into: list)
        XCTAssertEqual(list.count, LauncherReminderBook.maxCount)
        XCTAssertEqual(list.last, latest, "刚加的那条不删，删的是别的里最晚的")
        XCTAssertFalse(list.contains { $0.id == "r\(LauncherReminderBook.maxCount - 1)" })
        let soon = reminder("soon", in: 1)
        list = LauncherReminderBook.inserting(soon, into: list)
        XCTAssertEqual(list.first, soon)
        XCTAssertEqual(LauncherReminderBook.inserting(soon, into: [soon]).count, 1, "同一个 id 只留一条")
    }

    func testSplitDueAndPending() {
        let list = [reminder("future", in: 60), reminder("past", in: -60), reminder("now", in: 0)]
        let split = LauncherReminderBook.split(list, now: now)
        XCTAssertEqual(split.due.map(\.id), ["past", "now"])
        XCTAssertEqual(split.pending.map(\.id), ["future"])
    }

    func testLateness() {
        XCTAssertNil(LauncherReminderBook.lateness(of: reminder("a", in: -10), now: now), "差几秒不算晚")
        XCTAssertEqual(LauncherReminderBook.lateness(of: reminder("a", in: -600), now: now), 600)
        XCTAssertEqual(LauncherReminderLateness(seconds: 59), .minutes(1))
        XCTAssertEqual(LauncherReminderLateness(seconds: 12 * 60 + 30), .minutes(12))
        XCTAssertEqual(LauncherReminderLateness(seconds: 3 * 3_600 + 59), .hours(3))
        XCTAssertEqual(LauncherReminderLateness(seconds: 50 * 3_600), .days(2))
    }

    func testListQuery() {
        for text in ["提醒", " 提醒 ", "reminders", "Reminders", "REMINDER"] {
            XCTAssertTrue(LauncherReminderBook.isListQuery(text), text)
        }
        for text in ["提醒我", "提 醒", "remind", "健康提醒", ""] {
            XCTAssertFalse(LauncherReminderBook.isListQuery(text), text)
        }
    }

    func testDayLabel() {
        let cal = Calendar(identifier: .gregorian)
        var shanghai = cal
        shanghai.timeZone = LauncherCalcTestSupport.shanghai
        let base = LauncherCalcTestSupport.now // 2026-11-23 10:00 +08:00
        func day(_ hours: Double) -> LauncherReminderDay {
            LauncherReminderDay.of(base.addingTimeInterval(hours * 3_600), now: base, calendar: shanghai)
        }
        XCTAssertEqual(day(13.9), .today)
        XCTAssertEqual(day(14.1), .tomorrow)
        XCTAssertEqual(day(38.1), .dayAfterTomorrow)
        XCTAssertEqual(day(24 * 5), .date(sameYear: true))
        XCTAssertEqual(day(24 * 45), .date(sameYear: false))
    }
}
