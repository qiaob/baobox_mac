import Foundation
import XCTest

/// hook / 事件触发的用量刷新节流：60 秒内只马上放行一次；窗口里来的请求在窗口结束时补刷一次，只补一次、不叠加（DEDUPE.md §5.1 B1）。
final class CLIUsageRefreshThrottleTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testFirstRequestRefreshesNow() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.lastAllowed, .distantPast)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.lastAllowed, at(0))
        XCTAssertFalse(throttle.trailingPending)
    }

    /// 窗口里第一次被拦下：在窗口结束（上次放行 + 60 秒）时补一次；之后再来的不再排（不叠加），也不改窗口。
    func testRequestsInsideTheWindowScheduleOneTrailingRefreshAtTheWindowEnd() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.request(at: at(10)), .trailing(at: at(60)))
        XCTAssertEqual(throttle.request(at: at(40)), .alreadyScheduled)
        XCTAssertEqual(throttle.request(at: at(59.999)), .alreadyScheduled)
        XCTAssertEqual(throttle.lastAllowed, at(0), "被拦下的请求不改窗口")
        XCTAssertTrue(throttle.trailingPending)
    }

    func testRequestExactlyOneIntervalLaterRefreshesNow() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.request(at: at(60)), .now, "满 60 秒（≥）就马上放行")
    }

    /// 补刷到点：放行一次，下一个窗口从补刷的时刻算起。
    func testTrailingRefreshFiresOnceAndRestartsTheWindow() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.request(at: at(10)), .trailing(at: at(60)))

        XCTAssertTrue(throttle.fireTrailing(at: at(60)))
        XCTAssertFalse(throttle.fireTrailing(at: at(60)), "只补一次")
        XCTAssertEqual(throttle.lastAllowed, at(60))
        XCTAssertFalse(throttle.trailingPending)

        XCTAssertEqual(throttle.request(at: at(70)), .trailing(at: at(120)), "窗口从补刷（60 秒）算起")
        XCTAssertTrue(throttle.fireTrailing(at: at(120)))
        XCTAssertEqual(throttle.request(at: at(180)), .now)
    }

    /// 回合中途等确认（Notification）刚刷过，30 秒后回合结束（Stop）：那次被拦下，但在窗口结束时补刷到。
    func testStopRightAfterANotificationIsRefreshedAtTheWindowEnd() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(10)), .now, "Notification")
        XCTAssertEqual(throttle.request(at: at(40)), .trailing(at: at(70)), "Stop")
        XCTAssertTrue(throttle.fireTrailing(at: at(70)))
    }

    /// 补刷的定时器晚了（主线程忙、电脑睡了），窗口已过时又来了请求：马上放行并取消补刷，定时器到点时不再刷第二次。
    func testRequestAfterTheWindowSupersedesALateTrailingRefresh() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.request(at: at(30)), .trailing(at: at(60)))
        XCTAssertEqual(throttle.request(at: at(65)), .now)
        XCTAssertFalse(throttle.trailingPending)
        XCTAssertFalse(throttle.fireTrailing(at: at(66)))
        XCTAssertEqual(throttle.lastAllowed, at(65))
    }

    func testFiringWithoutAPendingTrailingRefreshDoesNothing() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertFalse(throttle.fireTrailing(at: at(0)))
        XCTAssertEqual(throttle.lastAllowed, .distantPast)
        XCTAssertEqual(throttle.request(at: at(1)), .now)
    }

    /// 系统时钟往回拨了一小时：补刷时刻落在「未来」，调用方把延迟夹到 60 秒以内；补刷之后窗口跟着新时钟走。
    func testClockMovedBackRecoversAfterTheTrailingRefresh() {
        var throttle = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(throttle.request(at: at(0)), .now)
        XCTAssertEqual(throttle.request(at: at(-3_600)), .trailing(at: at(60)))
        XCTAssertTrue(throttle.fireTrailing(at: at(-3_540)))
        XCTAssertEqual(throttle.request(at: at(-3_480)), .now)
    }

    func testSeparateInstancesDoNotShareState() {
        var first = CLIUsageRefreshThrottle(interval: 60)
        var second = CLIUsageRefreshThrottle(interval: 60)
        XCTAssertEqual(first.request(at: at(0)), .now)
        XCTAssertEqual(second.request(at: at(1)), .now)
    }
}
