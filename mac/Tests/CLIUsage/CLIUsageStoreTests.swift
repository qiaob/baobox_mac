import Combine
import Foundation
import XCTest

/// 用量 Store 基类（#164 PR4，docs/codex-assistant/DEDUPE-P2.md §2.4 类 8）：刷新发布、进行中再请求合并成补一轮、
/// 事件节流与窗口末尾补刷、定时刷新、设置的读取时机、额度提醒钩子、来源覆盖周窗口、报表 / 调用统计的回调线程。
/// 假来源的条目由测试放进去，收集可以停住（复现「刷新进行中」）；后台收集经 `DispatchQueue.main` 回写，
/// 测试转主线程 RunLoop 等它（`spinMainRunLoop` 在 CLISessionTestSupport.swift）。节流与定时器用零点几秒的短间隔。
@MainActor
final class CLIUsageStoreTests: XCTestCase {

    // MARK: - 夹具

    /// 一条 sonnet 用量，时间 = 现在 + `offset` 秒（负数在过去）。
    private func usage(_ offset: TimeInterval, input: Int = 900) -> CLIUsageEntry {
        CLIUsageEntry(timestamp: Date().addingTimeInterval(offset), modelID: "sonnet", projectPath: "/work/app",
                      input: input, output: 0)
    }

    /// 固定锚点：约三天前的那个星期几、那个小时 —— 窗口起点离现在远，刚才的用量一定落在窗口里。
    private func anchorAboutThreeDaysAgo() -> CLIUsageWeeklyAnchor {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86_400)
        let calendar = Calendar.current
        return CLIUsageWeeklyAnchor(fixed: true,
                                    clampingWeekday: calendar.component(.weekday, from: threeDaysAgo),
                                    hour: calendar.component(.hour, from: threeDaysAgo))
    }

    private func settings(budget: Int = 0, weeklyBudget: Int = 0,
                          anchor: CLIUsageWeeklyAnchor = CLIUsageSettings.unset.anchor) -> CLIUsageSettings {
        CLIUsageSettings(budget: budget, weeklyBudget: weeklyBudget, anchor: anchor)
    }

    /// 新建 Store；测试结束时停掉定时器与补刷，并等最后一轮跑完，免得串到下一个测试的计数里。
    private func makeStore(collectHours: Int = 180, autoRefreshInterval: TimeInterval = 300,
                           eventThrottle: TimeInterval = 60) -> RecordingUsageStore {
        let store = RecordingUsageStore(collectHours: collectHours, autoRefreshInterval: autoRefreshInterval,
                                        eventThrottle: eventThrottle)
        addTeardownBlock {
            MainActor.assumeIsolated {
                store.stopAutoRefresh()
                spinMainRunLoop { !store.isRefreshing }
            }
        }
        return store
    }

    /// 刷新一次并等它（含补的那一轮）跑完。
    private func refreshed<Source>(_ store: CLIUsageStore<Source>) {
        store.refresh()
        spinMainRunLoop { !store.isRefreshing }
    }

    // MARK: - 刷新

    func testRefreshPublishesTheThreeValuesAndStopsTheSpinner() {
        let entries = [usage(-120, input: 900), usage(-60, input: 100)]
        FakeUsageSource.box.reset(entries)
        let store = makeStore()
        XCTAssertNil(store.fiveHourWindow)
        XCTAssertFalse(store.isRefreshing)

        store.refresh()
        XCTAssertTrue(store.isRefreshing, "转圈马上亮")
        spinMainRunLoop { !store.isRefreshing }

        XCTAssertEqual(FakeUsageSource.box.collectedHours, [180], "默认收集近 180 小时")
        XCTAssertEqual(store.fiveHourWindow, AnthropicCalc.activeWindow(from: entries))
        XCTAssertEqual(store.fiveHourWindow?.totals.input, 1_000)
        XCTAssertEqual(store.todayTotals, AnthropicCalc.todayTotals(from: entries))
        XCTAssertNotNil(store.weeklyWindow)
        XCTAssertEqual(store.weeklyWindow, AnthropicCalc.weeklyWindow(from: entries, anchor: CLIUsageSettings.unset.anchor))
        XCTAssertEqual(store.hookCalls, [], "没设预算：不提醒")
    }

    func testRefreshCollectsTheHoursGivenAtInitAndPublishesNilsWithoutUsage() {
        FakeUsageSource.box.reset()
        let store = makeStore(collectHours: 24)
        store.settings = settings(budget: 1, weeklyBudget: 1)

        refreshed(store)

        XCTAssertEqual(FakeUsageSource.box.collectedHours, [24])
        XCTAssertNil(store.fiveHourWindow)
        XCTAssertNil(store.todayTotals)
        XCTAssertNil(store.weeklyWindow, "滚动块口径：没有用量就没有周窗口")
        XCTAssertEqual(store.hookCalls, [], "没有窗口：不查预算")
    }

    /// 进行中再来的请求不丢（Codex 原来直接丢，DEDUPE-P2 §7 D6）：这一轮结束后补一轮，来几次都只补一轮；转圈中间不熄。
    func testRequestsDuringARefreshAddExactlyOneMorePassAndKeepTheSpinnerOn() {
        FakeUsageSource.box.reset([usage(-60, input: 100)])
        let store = makeStore()
        var spinner: [Bool] = []
        let subscription = store.$isRefreshing.sink { spinner.append($0) }
        let hold = FakeUsageSource.box.holdNextCollection()

        store.refresh()
        XCTAssertTrue(hold.waitUntilReached(), "第一轮已经取了条目，停在收集里")
        FakeUsageSource.box.entries = [usage(-60, input: 100), usage(-30, input: 200)]
        store.refresh()
        store.refresh()
        store.refresh()
        XCTAssertEqual(FakeUsageSource.box.collections, 1, "进行中：只记一笔")
        hold.release()
        spinMainRunLoop { !store.isRefreshing }
        subscription.cancel()

        XCTAssertEqual(FakeUsageSource.box.collections, 2, "补了一轮，只补一轮")
        XCTAssertEqual(store.fiveHourWindow?.totals.input, 300, "最后发布的是补的那一轮")
        XCTAssertEqual(spinner.first, false)
        XCTAssertEqual(spinner.last, false)
        XCTAssertFalse(spinner.dropFirst().dropLast().contains(false), "两轮之间转圈没熄：\(spinner)")
    }

    // MARK: - 设置与额度提醒

    /// 先发布、再提醒、最后熄转圈（Claude 原来的先后；Codex 原来先熄转圈再提醒，同一个主线程回合里看不出）。
    func testRemindersComeAfterPublishingAndBeforeTheSpinnerStops() {
        FakeUsageSource.box.reset([usage(-60, input: 900)])
        let store = makeStore()
        store.settings = settings(budget: 1_000, weeklyBudget: 1_000)

        refreshed(store)

        XCTAssertEqual(store.hookCalls, ["reached 5h 90%", "reached week 90%"], "先 5 小时后周")
        XCTAssertEqual(store.reachedStates, [
            RecordingUsageStore.ReachedState(isRefreshing: true, publishedWindowIsTheOneReported: true),
            RecordingUsageStore.ReachedState(isRefreshing: true, publishedWindowIsTheOneReported: true),
        ])
    }

    func testBudgetHooksFireOncePerWindowAndReportAWindowChange() {
        // 用量放在「将来」：窗口从它的整点起算，照样是活跃窗口 —— 换一批条目就换了一个窗口，不用真的等 5 小时。
        FakeUsageSource.box.reset([usage(60, input: 900)])
        let store = makeStore()
        store.settings = settings(budget: 1_000, weeklyBudget: 1_100)

        refreshed(store)
        XCTAssertEqual(store.hookCalls, ["reached 5h 90%", "reached week 82%"])

        refreshed(store)
        XCTAssertEqual(store.hookCalls.count, 2, "同一个窗口不再提醒")

        FakeUsageSource.box.entries = [usage(2 * 3_600, input: 950)]
        refreshed(store)
        XCTAssertEqual(Array(store.hookCalls.dropFirst(2)),
                       ["changed 5h", "reached 5h 95%", "changed week", "reached week 86%"],
                       "每个窗口先报换了窗口、再报到线")
    }

    /// 锚点在刷新开始时读、预算在结果回来时读（两个 Store 原来都是这样）。
    func testTheAnchorIsReadWhenARefreshStartsAndTheBudgetsWhenItsResultArrives() {
        FakeUsageSource.box.reset([usage(-60, input: 900)])
        let store = makeStore()
        let fixed = anchorAboutThreeDaysAgo()
        store.settings = settings(anchor: fixed)
        let hold = FakeUsageSource.box.holdNextCollection()

        store.refresh()
        XCTAssertTrue(hold.waitUntilReached())
        store.settings = settings(budget: 1_000, weeklyBudget: 1_000)   // 改成滚动块 + 设了预算
        hold.release()
        spinMainRunLoop { !store.isRefreshing }

        XCTAssertEqual(store.weeklyWindow?.start,
                       AnthropicCalc.weekAnchorStart(before: Date(), weekday: fixed.weekday, hour: fixed.hour),
                       "周窗口按刷新开始时的固定锚点算")
        XCTAssertEqual(store.hookCalls, ["reached 5h 90%", "reached week 90%"], "预算用的是结果回来时的")
    }

    // MARK: - 事件节流

    /// 第一次马上刷；间隔里来的不马上刷，在间隔结束时补一次（只补一次）—— Codex 原来间隔里的直接丢（D6）。
    func testAnEventRefreshesNowAndEventsInsideTheIntervalRefreshOnceAtItsEnd() {
        FakeUsageSource.box.reset()
        let store = makeStore(eventThrottle: 0.4)
        let started = Date()

        store.refreshThrottledFromEvent()
        XCTAssertTrue(store.isRefreshing, "第一次马上刷")
        spinMainRunLoop { !store.isRefreshing }
        store.refreshThrottledFromEvent()   // 间隔里：排一次补刷
        store.refreshThrottledFromEvent()   // 已经排了：不再排
        XCTAssertFalse(store.isRefreshing, "间隔里的不马上刷")
        XCTAssertEqual(FakeUsageSource.box.collections, 1)

        spinMainRunLoop { FakeUsageSource.box.collections == 2 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.35, "补刷在间隔结束时")
        spinMainRunLoop { !store.isRefreshing }
        spinMainRunLoop(for: 0.6)
        XCTAssertEqual(FakeUsageSource.box.collections, 2, "只补一次")
    }

    func testAnEventAfterTheIntervalRefreshesNow() {
        FakeUsageSource.box.reset()
        let store = makeStore(eventThrottle: 0.3)
        store.refreshThrottledFromEvent()
        spinMainRunLoop { !store.isRefreshing }
        spinMainRunLoop(for: 0.4)

        store.refreshThrottledFromEvent()
        XCTAssertTrue(store.isRefreshing, "过了间隔：马上刷")
        spinMainRunLoop { !store.isRefreshing }
        XCTAssertEqual(FakeUsageSource.box.collections, 2)
    }

    /// 补刷到点时上一轮还没完：并进「这一轮结束后补一轮」，不另起一轮、也不丢。
    func testATrailingRefreshThatLandsDuringARefreshBecomesTheOneExtraPass() {
        FakeUsageSource.box.reset()
        let store = makeStore(eventThrottle: 0.3)
        let hold = FakeUsageSource.box.holdNextCollection()

        store.refreshThrottledFromEvent()   // 马上刷，停在收集里
        XCTAssertTrue(hold.waitUntilReached())
        store.refreshThrottledFromEvent()   // 0.3 秒后补刷 —— 那时这一轮还停着
        spinMainRunLoop(for: 0.5)
        XCTAssertEqual(FakeUsageSource.box.collections, 1, "补刷撞上进行中的那一轮：只记一笔")
        hold.release()
        spinMainRunLoop { !store.isRefreshing }

        XCTAssertEqual(FakeUsageSource.box.collections, 2, "这一轮结束后补一轮")
    }

    func testStopAutoRefreshCancelsAPendingTrailingRefresh() {
        FakeUsageSource.box.reset()
        let store = makeStore(eventThrottle: 0.3)
        store.refreshThrottledFromEvent()
        spinMainRunLoop { !store.isRefreshing }
        store.refreshThrottledFromEvent()   // 排了补刷

        store.stopAutoRefresh()
        spinMainRunLoop(for: 0.7)

        XCTAssertEqual(FakeUsageSource.box.collections, 1, "停了就不补")
        XCTAssertFalse(store.isRefreshing)
    }

    // MARK: - 定时刷新

    func testAutoRefreshRefreshesRightAwayAndOnEveryTickUntilStopped() {
        FakeUsageSource.box.reset()
        let store = makeStore(autoRefreshInterval: 0.2)

        store.startAutoRefresh()
        XCTAssertTrue(store.isRefreshing, "立刻刷一次")
        spinMainRunLoop { FakeUsageSource.box.collections >= 3 }
        store.stopAutoRefresh()
        spinMainRunLoop { !store.isRefreshing }
        let afterStop = FakeUsageSource.box.collections
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(FakeUsageSource.box.collections, afterStop, "停了定时器不再刷")
    }

    // MARK: - 来源

    /// 周窗口走来源：默认实现在固定锚点下没有用量也给一个 0 用量的窗口（Claude）；来源覆盖成「没有用量返回 nil」时用覆盖的（Codex）。
    func testASourceCanOverrideTheWeeklyWindow() {
        let fixed = settings(anchor: anchorAboutThreeDaysAgo())
        FakeUsageSource.box.reset()
        let plain = makeStore()
        plain.settings = fixed
        refreshed(plain)
        XCTAssertNotNil(plain.weeklyWindow, "默认实现")
        XCTAssertEqual(plain.weeklyWindow?.totals, .zero)

        FakeCodexLikeUsageSource.box.reset()
        let codexLike = CodexLikeUsageStore()
        codexLike.settings = fixed
        refreshed(codexLike)
        XCTAssertNil(codexLike.weeklyWindow, "来源覆盖的周窗口生效")

        let entries = [usage(-60)]
        FakeCodexLikeUsageSource.box.entries = entries
        refreshed(codexLike)
        XCTAssertNotNil(codexLike.weeklyWindow)
        XCTAssertEqual(codexLike.weeklyWindow, AnthropicCalc.weeklyWindow(from: entries, anchor: fixed.anchor))
    }

    func testReportAndInvocationStatsAreComputedInTheBackgroundAndCallBackOnTheMainThread() {
        FakeUsageSource.box.reset([usage(-3_600, input: 100), usage(-60, input: 200)])
        let store = makeStore()

        var report: CLIUsageReport<AnthropicStyleTable>?
        var reportOnMain: Bool?
        store.report(days: 7) { result in
            reportOnMain = Thread.isMainThread
            report = result
        }
        spinMainRunLoop { report != nil }
        XCTAssertEqual(reportOnMain, true)
        XCTAssertEqual(FakeUsageSource.box.collectedHours, [168], "报表收集近 days × 24 小时")
        XCTAssertEqual(report?.byModel.map(\.label), ["sonnet"])
        XCTAssertEqual(report?.byModel.first?.totals.input, 300)

        var stats: FakeInvocationStats?
        var statsOnMain: Bool?
        store.invocationStats(days: 30) { result in
            statsOnMain = Thread.isMainThread
            stats = result
        }
        spinMainRunLoop { stats != nil }
        XCTAssertEqual(statsOnMain, true)
        XCTAssertEqual(stats, FakeInvocationStats(days: 30, computedOnMainThread: false))
        XCTAssertFalse(store.isRefreshing, "报表与调用统计不碰转圈")
    }

    /// 模块里的 Store 都是非泛型子类，@Published 在泛型基类里：经子类实例改，界面照样收到变化（DEDUPE-P2 §6 R10）。
    func testChangesThroughASubclassReachObjectWillChange() {
        FakeUsageSource.box.reset([usage(-60)])
        let store = makeStore()
        var changes = 0
        let subscription = store.objectWillChange.sink { _ in changes += 1 }

        refreshed(store)
        subscription.cancel()

        XCTAssertEqual(changes, 5, "转圈亮、三个值、转圈熄")
    }
}

// MARK: - 假来源与假 Store

/// 假来源的状态：放进去的条目、每次收集要的小时数（= 跑了几轮刷新 / 报表）、可以停住的下一次收集。
/// 来源全是静态成员、没法按实例传参，所以每个测试开头 `reset`。后台线程读写，都在锁里。
final class FakeUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [CLIUsageEntry] = []
    private var hours: [Int] = []
    private var pendingHold: FakeCollectHold?

    func reset(_ entries: [CLIUsageEntry] = []) {
        lock.withLock {
            storedEntries = entries
            hours = []
            pendingHold = nil
        }
    }

    var entries: [CLIUsageEntry] {
        get { lock.withLock { storedEntries } }
        set { lock.withLock { storedEntries = newValue } }
    }

    /// 每次收集要的小时数，按先后。
    var collectedHours: [Int] { lock.withLock { hours } }
    var collections: Int { collectedHours.count }

    /// 让下一次收集取完条目后停住，直到测试放行。
    func holdNextCollection() -> FakeCollectHold {
        let hold = FakeCollectHold()
        lock.withLock { pendingHold = hold }
        return hold
    }

    /// 后台线程：记一笔、取当时的条目；要停就停在这里（停住期间改的条目留给下一轮）。
    func collect(hours requested: Int) -> [CLIUsageEntry] {
        let (entries, hold): ([CLIUsageEntry], FakeCollectHold?) = lock.withLock {
            hours.append(requested)
            defer { pendingHold = nil }
            return (storedEntries, pendingHold)
        }
        hold?.stopHere()
        return entries
    }
}

/// 停住一次收集：复现「刷新进行中」。
final class FakeCollectHold: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// 测试线程：等后台那一轮停到这里。
    func waitUntilReached(timeout: TimeInterval = 5) -> Bool {
        reached.wait(timeout: .now() + timeout) == .success
    }

    func release() {
        released.signal()
    }

    /// 后台线程：通知已停住，等放行（最多 10 秒，测试失败时不至于一直卡住）。
    func stopHere() {
        reached.signal()
        _ = released.wait(timeout: .now() + 10)
    }
}

/// 假的调用统计：问的天数，以及是不是在主线程上算的。
struct FakeInvocationStats: Equatable, Sendable {
    let days: Int
    let computedOnMainThread: Bool
}

/// 两个假来源共用的部分：条目从 `box` 收，报表用 Anthropic 口径的测试定价表。
protocol FakeUsageSourceShape: CLIUsageSource where Table == AnthropicStyleTable, InvocationStats == FakeInvocationStats {
    static var box: FakeUsageBox { get }
}

extension FakeUsageSourceShape {
    static func collectEntries(sinceHoursAgo hours: Int) -> [CLIUsageEntry] {
        box.collect(hours: hours)
    }

    static func buildReport(from entries: [CLIUsageEntry]) -> CLIUsageReport<AnthropicStyleTable> {
        AnthropicCalc.buildReport(from: entries, order: .byCost, locale: Locale(identifier: "en_US_POSIX"), projectBucket: pathBucket)
    }

    static func invocationStats(days: Int) -> FakeInvocationStats {
        FakeInvocationStats(days: days, computedOnMainThread: Thread.isMainThread)
    }
}

/// 周窗口用默认实现的假来源（像 Claude）。
enum FakeUsageSource: FakeUsageSourceShape {
    static let box = FakeUsageBox()
}

/// 覆盖周窗口的假来源（像 Codex：一条用量都没有时返回 nil，固定锚点也一样）。
enum FakeCodexLikeUsageSource: FakeUsageSourceShape {
    static let box = FakeUsageBox()

    static func weeklyWindow(from entries: [CLIUsageEntry], anchor: CLIUsageWeeklyAnchor) -> CLIUsageWindow<AnthropicStyleTable>? {
        guard !entries.isEmpty else { return nil }
        return AnthropicCalc.weeklyWindow(from: entries, anchor: anchor)
    }
}

/// 记下设置与提醒钩子的 Store（模块里的 Store 都是非泛型子类，这里也是）。
@MainActor
final class RecordingUsageStore: CLIUsageStore<FakeUsageSource> {
    /// `budgetReached` 被调那一刻 Store 自己的样子。
    struct ReachedState: Equatable {
        let isRefreshing: Bool
        let publishedWindowIsTheOneReported: Bool
    }

    /// `readSettings()` 返回的值，测试随时改。
    var settings = CLIUsageSettings.unset
    /// 钩子调用，按先后：「changed 5h」「reached week 90%」……
    private(set) var hookCalls: [String] = []
    private(set) var reachedStates: [ReachedState] = []

    override func readSettings() -> CLIUsageSettings {
        settings
    }

    override func budgetWindowChanged(weekly: Bool) {
        hookCalls.append("changed \(weekly ? "week" : "5h")")
    }

    override func budgetReached(percent: Int, window: CLIUsageWindow<AnthropicStyleTable>, weekly: Bool) {
        hookCalls.append("reached \(weekly ? "week" : "5h") \(percent)%")
        let published = weekly ? weeklyWindow : fiveHourWindow
        reachedStates.append(ReachedState(isRefreshing: isRefreshing, publishedWindowIsTheOneReported: published == window))
    }
}

/// 用覆盖周窗口的来源的 Store（像 Codex，不覆盖提醒钩子）。
@MainActor
final class CodexLikeUsageStore: CLIUsageStore<FakeCodexLikeUsageSource> {
    var settings = CLIUsageSettings.unset

    override func readSettings() -> CLIUsageSettings {
        settings
    }
}
