import Foundation
import XCTest

/// hook / 事件触发的用量刷新节流：60 秒内只放行一次，被拦下的请求不顺延（DEDUPE.md §5.1 B1「节流不变」）。
final class CLIUsageRefreshThrottleTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testFirstRequestIsAllowed() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.lastAllowed, .distantPast)
        XCTAssertTrue(throttle.allow(at: at(0)))
        XCTAssertEqual(throttle.lastAllowed, at(0))
    }

    func testRequestsWithinTheIntervalAreDropped() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertTrue(throttle.allow(at: at(0)))
        XCTAssertFalse(throttle.allow(at: at(1)))
        XCTAssertFalse(throttle.allow(at: at(59.999)))
        XCTAssertEqual(throttle.lastAllowed, at(0), "被拦下的请求不改记录")
    }

    func testRequestExactlyOneIntervalLaterIsAllowed() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertTrue(throttle.allow(at: at(0)))
        XCTAssertTrue(throttle.allow(at: at(60)), "满 60 秒（≥）就放行")
    }

    /// 被拦下的请求不顺延窗口：0 秒放行、30 秒被拦，60 秒照样放行（不是等到 90 秒）。
    func testDroppedRequestsDoNotExtendTheWindow() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertTrue(throttle.allow(at: at(0)))
        XCTAssertFalse(throttle.allow(at: at(30)))
        XCTAssertTrue(throttle.allow(at: at(60)))
        XCTAssertFalse(throttle.allow(at: at(100)), "窗口从上次放行（60 秒）算起")
        XCTAssertTrue(throttle.allow(at: at(120)))
    }

    /// 回合中途等确认（Notification）刚刷过，60 秒内回合结束（Stop）的那次被拦下 —— 记录现状：不补刷，等下一次事件或 5 分钟的定时器。
    func testStopRightAfterANotificationRefreshIsDropped() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertTrue(throttle.allow(at: at(10)), "Notification")
        XCTAssertFalse(throttle.allow(at: at(40)), "Stop")
    }

    func testSeparateInstancesDoNotShareState() {
        var first = CLIUsageRefreshThrottle(interval: 60)
        var second = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertTrue(first.allow(at: at(0)))
        XCTAssertTrue(second.allow(at: at(1)))
    }
}
