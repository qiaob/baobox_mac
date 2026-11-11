import Foundation
import XCTest

/// 日历事件的时间判断（docs/meeting/TECH_DESIGN.md §5）：下一场、手动开始绑哪场、会前提醒、「已开始」、暂停提醒、问过的记一笔。
final class MeetingScheduleTests: XCTestCase {
    private let now = localDate(10, 0, 0)
    private let zoom = MeetingLink(provider: .zoom, url: URL(fileURLWithPath: "/zoom"))

    private func event(_ title: String, start: Date, end: Date, link: Bool = false, id: String? = nil) -> MeetingCalendarEvent {
        MeetingCalendarEvent(info: MeetingEventInfo(title: title, start: start, end: end, eventID: id),
                             link: link ? zoom : nil)
    }

    func testOccurrenceKeyCombinesTheEventAndItsStart() {
        let start = Date(timeIntervalSince1970: 1_794_276_000)
        XCTAssertEqual(MeetingSchedule.occurrenceKey(eventID: "e1", title: "周会", start: start), "e1|1794276000")
        XCTAssertEqual(MeetingSchedule.occurrenceKey(eventID: "", title: "周会", start: start), "title:周会|1794276000")
        XCTAssertEqual(MeetingSchedule.occurrenceKey(eventID: nil, title: "周会", start: start.addingTimeInterval(0.4)),
                       "title:周会|1794276000")
    }

    func testOngoingAndUpcoming() {
        let past = event("过去的", start: localDate(8, 0, 0), end: localDate(9, 0, 0))
        let ongoing = event("进行中", start: localDate(9, 30, 0), end: localDate(10, 30, 0))
        let later = event("稍后", start: localDate(11, 0, 0), end: localDate(12, 0, 0))
        let soon = event("马上", start: localDate(10, 5, 0), end: localDate(10, 35, 0))
        XCTAssertTrue(ongoing.isOngoing(at: now))
        XCTAssertFalse(event("刚结束", start: localDate(9, 0, 0), end: now).isOngoing(at: now))
        XCTAssertEqual(MeetingSchedule.ongoing([later, ongoing, past], at: now).map(\.info.title), ["进行中"])
        XCTAssertEqual(MeetingSchedule.upcoming([later, ongoing, soon], at: now).map(\.info.title), ["马上", "稍后"])
    }

    func testNextPrefersAMeetingThatJustStartedWithALink() {
        let started = event("刚开始", start: localDate(9, 50, 0), end: localDate(10, 30, 0))
        let startedWithLink = event("刚开始有链接", start: localDate(9, 46, 0), end: localDate(10, 30, 0), link: true)
        let longAgo = event("开了很久", start: localDate(9, 40, 0), end: localDate(11, 0, 0), link: true)
        let upcoming = event("稍后", start: localDate(10, 10, 0), end: localDate(11, 0, 0))
        XCTAssertEqual(MeetingSchedule.next([upcoming, started, startedWithLink, longAgo], at: now)?.info.title, "刚开始有链接")
        XCTAssertEqual(MeetingSchedule.next([upcoming, started], at: now)?.info.title, "刚开始")
        XCTAssertEqual(MeetingSchedule.next([upcoming, longAgo], at: now)?.info.title, "稍后", "开始超过 15 分钟的不算下一场")
        XCTAssertNil(MeetingSchedule.next([longAgo], at: now))
    }

    func testBindingCandidateIsOngoingOrWithinFiveMinutesPreferringALinkThenTheNearest() {
        let ongoing = event("进行中", start: localDate(9, 30, 0), end: localDate(10, 30, 0))
        let soon = event("五分钟后", start: localDate(10, 5, 0), end: localDate(10, 30, 0))
        let tooLate = event("六分钟后", start: localDate(10, 6, 0), end: localDate(10, 30, 0), link: true)
        let soonWithLink = event("三分钟后有链接", start: localDate(10, 3, 0), end: localDate(10, 30, 0), link: true)
        XCTAssertEqual(MeetingSchedule.bindingCandidate([ongoing, soon, tooLate], at: now)?.info.title, "五分钟后")
        XCTAssertEqual(MeetingSchedule.bindingCandidate([ongoing, soon, soonWithLink], at: now)?.info.title, "三分钟后有链接")
        XCTAssertEqual(MeetingSchedule.bindingCandidate([ongoing, tooLate], at: now)?.info.title, "进行中")
        XCTAssertNil(MeetingSchedule.bindingCandidate([tooLate], at: now))
    }

    func testReminderIsDueFromTheLeadTimeUntilTwoMinutesAfterTheStart() {
        let inOneMinute = event("一分钟后", start: localDate(10, 1, 0), end: localDate(11, 0, 0), id: "a")
        let inThreeMinutes = event("三分钟后", start: localDate(10, 3, 0), end: localDate(11, 0, 0), id: "b")
        let startedOneMinuteAgo = event("开始一分钟", start: localDate(9, 59, 0), end: localDate(11, 0, 0), id: "c")
        let startedThreeMinutesAgo = event("开始三分钟", start: localDate(9, 57, 0), end: localDate(11, 0, 0), id: "d")
        let all = [inThreeMinutes, startedThreeMinutesAgo, inOneMinute, startedOneMinuteAgo]

        XCTAssertEqual(MeetingSchedule.reminderDue(all, at: now, leadMinutes: 1, prompted: { _ in false }).map(\.info.title),
                       ["开始一分钟", "一分钟后"])
        XCTAssertEqual(MeetingSchedule.reminderDue(all, at: now, leadMinutes: 5, prompted: { _ in false }).map(\.info.title),
                       ["开始一分钟", "一分钟后", "三分钟后"])
        XCTAssertEqual(MeetingSchedule.reminderDue(all, at: now, leadMinutes: 5,
                                                   prompted: { $0 == inOneMinute.occurrenceKey }).map(\.info.title),
                       ["开始一分钟", "三分钟后"], "问过的不再问")
        XCTAssertEqual(MeetingSchedule.reminderDue(all, at: now, leadMinutes: 0, prompted: { _ in false }), [], "0 = 关")
    }

    func testStartedWithLinkNeedsALinkAndLessThanFifteenMinutes() {
        let withLink = event("有链接", start: localDate(9, 50, 0), end: localDate(10, 30, 0), link: true)
        let noLink = event("没链接", start: localDate(9, 50, 0), end: localDate(10, 30, 0))
        let longAgo = event("开了很久", start: localDate(9, 45, 0), end: localDate(10, 30, 0), link: true)
        XCTAssertEqual(MeetingSchedule.startedWithLink([withLink, noLink, longAgo], at: now, prompted: { _ in false })
                        .map(\.info.title), ["有链接"])
        XCTAssertEqual(MeetingSchedule.startedWithLink([withLink], at: now, prompted: { _ in true }), [])
    }

    func testPausedUntil() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        XCTAssertEqual(MeetingSchedule.pausedUntil(.hour, from: now, calendar: calendar), localDate(11, 0, 0))
        XCTAssertEqual(MeetingSchedule.pausedUntil(.today, from: now, calendar: calendar), localDate(0, 0, 0, day: 11))
        XCTAssertEqual(MeetingSchedule.pausedUntil(.untilTomorrow, from: now, calendar: calendar), localDate(0, 0, 0, day: 12))
    }

    func testPromptLedgerKeepsTheLaterExpiryAndPrunes() {
        var ledger = MeetingPromptLedger()
        ledger.insert("a", until: localDate(11, 0, 0))
        ledger.insert("a", until: localDate(10, 30, 0))
        XCTAssertEqual(ledger.entries["a"], localDate(11, 0, 0), "不缩短")
        ledger.insert("b", until: localDate(10, 0, 0))
        XCTAssertTrue(ledger.contains("a", at: now))
        XCTAssertFalse(ledger.contains("b", at: now), "到点就过期")
        XCTAssertFalse(ledger.contains("c", at: now))
        XCTAssertTrue(ledger.prune(at: now))
        XCTAssertFalse(ledger.prune(at: now))
        XCTAssertEqual(Array(ledger.entries.keys), ["a"])
    }

    func testPromptLedgerStorageRoundTripsAndToleratesJunk() {
        var ledger = MeetingPromptLedger()
        ledger.insert("a", until: Date(timeIntervalSince1970: 1_794_276_000))
        XCTAssertEqual(MeetingPromptLedger(storage: ledger.storage), ledger)
        let loaded = MeetingPromptLedger(storage: ["int": 1_794_276_000, "double": 1_794_276_000.5, "text": "坏的",
                                                   "infinite": Double.infinity] as [String: Any])
        XCTAssertEqual(loaded.entries, ["int": Date(timeIntervalSince1970: 1_794_276_000),
                                        "double": Date(timeIntervalSince1970: 1_794_276_000.5)])
        XCTAssertEqual(MeetingPromptLedger(storage: "不是字典").entries, [:])
        XCTAssertEqual(MeetingPromptLedger(storage: nil).entries, [:])
    }
}
