import Foundation
import XCTest

/// 快速入口空着的时候（docs/launcher/REQUIREMENTS.md §3.7、TECH_DESIGN.md §8.4、§5.6）：「选中的 / 刚复制的」两行的去重、
/// 「刚复制」的时间窗口、标题、空状态各类行的拼接顺序和上限；读选区的流程（后台读、80 ms 封顶、过期的丢掉），
/// 取词函数注入（真的 AX 要辅助功能权限，测不了）。
final class LauncherContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 刚复制的：时间窗口

    func testRecentCopyWindowIsFiveMinutes() {
        XCTAssertEqual(LauncherContextRules.recentCopyWindow, 300)
        XCTAssertTrue(LauncherContextRules.isRecentCopy(at: now, now: now))
        XCTAssertTrue(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(-299), now: now))
        XCTAssertTrue(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(-300), now: now), "正好 5 分钟还算")
        XCTAssertFalse(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(-301), now: now))
        XCTAssertFalse(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(-86_400), now: now))
        XCTAssertFalse(LauncherContextRules.isRecentCopy(at: nil, now: now), "没有时间的不算")
    }

    func testRecentCopyToleratesASmallClockSkewOnly() {
        XCTAssertTrue(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(30), now: now), "系统时间被往回调了一点")
        XCTAssertFalse(LauncherContextRules.isRecentCopy(at: now.addingTimeInterval(3_600), now: now), "晚太多的不算")
    }

    func testCopiedMinutesRoundsDownAndUnderAMinuteIsNil() {
        XCTAssertNil(LauncherContextRules.copiedMinutes(age: 0))
        XCTAssertNil(LauncherContextRules.copiedMinutes(age: 59.9))
        XCTAssertNil(LauncherContextRules.copiedMinutes(age: -20), "时间稍晚于现在：显示「1 分钟内」")
        XCTAssertEqual(LauncherContextRules.copiedMinutes(age: 60), 1)
        XCTAssertEqual(LauncherContextRules.copiedMinutes(age: 179), 2)
        XCTAssertEqual(LauncherContextRules.copiedMinutes(age: 300), 5)
    }

    // MARK: - 两行去重

    func testRecentCopyIsDroppedWhenItIsTheSelection() {
        let copy = LauncherRecentCopy(content: .text("hello world"), date: now)
        XCTAssertFalse(LauncherContextRules.showsRecentCopy(copy, selection: "hello world", now: now), "相同时只留「选中的」")
        XCTAssertFalse(LauncherContextRules.showsRecentCopy(copy, selection: "  hello world\n", now: now), "去空白后相同")
        XCTAssertTrue(LauncherContextRules.showsRecentCopy(copy, selection: "hello", now: now))
        XCTAssertTrue(LauncherContextRules.showsRecentCopy(copy, selection: nil, now: now))
    }

    func testSameContentIgnoresNewlineAndSpacingDifferences() {
        XCTAssertTrue(LauncherContextRules.isSameContent("第一行\r\n第二行", "第一行\n第二行"))
        XCTAssertTrue(LauncherContextRules.isSameContent("a  b\tc", "a b c"))
        XCTAssertFalse(LauncherContextRules.isSameContent("ab", "a b"))
        XCTAssertFalse(LauncherContextRules.isSameContent("Hello", "hello"), "大小写不同算两段")
        XCTAssertFalse(LauncherContextRules.isSameContent("  ", " "), "全是空白不算相同")
    }

    func testRecentCopyNeedsTheWindowAndNonBlankText() {
        XCTAssertFalse(LauncherContextRules.showsRecentCopy(nil, selection: nil, now: now))
        let old = LauncherRecentCopy(content: .text("x"), date: now.addingTimeInterval(-600))
        XCTAssertFalse(LauncherContextRules.showsRecentCopy(old, selection: nil, now: now), "超过 5 分钟")
        let blank = LauncherRecentCopy(content: .text(" \n "), date: now)
        XCTAssertFalse(LauncherContextRules.showsRecentCopy(blank, selection: nil, now: now))
        let image = LauncherRecentCopy(content: .image, date: now.addingTimeInterval(-10))
        XCTAssertTrue(LauncherContextRules.showsRecentCopy(image, selection: "anything", now: now), "图片不和选中的文字比")
    }

    // MARK: - 标题

    func testTitleIsTheFirstLineSquashedAndTruncated() {
        XCTAssertEqual(LauncherContextRules.title("第一行\n第二行"), "第一行 第二行")
        let long = String(repeating: "字", count: 100)
        let title = LauncherContextRules.title(long)
        XCTAssertEqual(title.count, LauncherContextRules.titleLength)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(LauncherContextRules.title("  short  "), "short")
    }

    // MARK: - 读选区的结果

    func testFinalizeTreatsLateResultsAsTimedOutAndBlankAsNone() {
        let budget = LauncherContextRules.selectionBudget
        XCTAssertEqual(budget, 0.08)
        XCTAssertEqual(LauncherContextRules.finalize(.text("hi"), elapsed: 0.01, budget: budget), .text("hi"))
        XCTAssertEqual(LauncherContextRules.finalize(.text("hi"), elapsed: 0.081, budget: budget), .timedOut, "晚到的不要")
        XCTAssertEqual(LauncherContextRules.finalize(.text(" \n\t"), elapsed: 0.01, budget: budget), .none)
        XCTAssertEqual(LauncherContextRules.finalize(.none, elapsed: 0.2, budget: budget), .timedOut)
        XCTAssertEqual(LauncherContextRules.finalize(.noPermission, elapsed: 0.2, budget: budget), .noPermission)
    }

    func testOutcomeLogLabelsNeverContainTheText() {
        XCTAssertEqual(LauncherSelectionOutcome.text("secret password").logLabel, "got 15 characters")
        XCTAssertEqual(LauncherSelectionOutcome.none.logLabel, "none")
        XCTAssertEqual(LauncherSelectionOutcome.timedOut.logLabel, "timed out")
        XCTAssertEqual(LauncherSelectionOutcome.noPermission.logLabel, "no accessibility permission")
    }

    // MARK: - 空状态的拼接

    func testLayoutOrderIsContextThenSituationalThenMostUsed() {
        let layout = LauncherContextRules.layout(context: ["context/selection", "context/clipboard"],
                                                 situational: ["commands/caffeinate.toggle"],
                                                 mostUsed: ["apps/safari", "commands/screenshot.capture"])
        XCTAssertEqual(layout.all, ["context/selection", "context/clipboard", "commands/caffeinate.toggle",
                                    "apps/safari", "commands/screenshot.capture"])
    }

    func testMostUsedAloneKeepsTheOldLimitOfEight() {
        let mostUsed = (1...12).map { "apps/\($0)" }
        let layout = LauncherContextRules.layout(context: [], situational: [], mostUsed: mostUsed)
        XCTAssertEqual(layout.mostUsed, Array(mostUsed.prefix(8)))
    }

    func testTotalIsAtMostNineRows() {
        let mostUsed = (1...12).map { "apps/\($0)" }
        let one = LauncherContextRules.layout(context: ["context/selection"], situational: [], mostUsed: mostUsed)
        XCTAssertEqual(one.all.count, 9, "一行上下文 + 8 行最常用")
        let full = LauncherContextRules.layout(context: ["context/selection", "context/clipboard"],
                                               situational: (1...6).map { "commands/s\($0)" }, mostUsed: mostUsed)
        XCTAssertEqual(full.context.count, 2)
        XCTAssertEqual(full.situational, ["commands/s1", "commands/s2", "commands/s3", "commands/s4"], "情景建议最多 4 条")
        XCTAssertEqual(full.mostUsed, ["apps/1", "apps/2", "apps/3"], "总共 9 行")
        XCTAssertEqual(full.all.count, LauncherContextRules.maxEmptyStateRows)
    }

    func testACommandThatIsBothSituationalAndMostUsedAppearsOnceAsSituational() {
        let layout = LauncherContextRules.layout(context: [],
                                                 situational: ["commands/caffeinate.toggle", "commands/focushealth.focus"],
                                                 mostUsed: ["commands/focushealth.focus", "apps/safari", "commands/caffeinate.toggle"])
        XCTAssertEqual(layout.situational, ["commands/caffeinate.toggle", "commands/focushealth.focus"])
        XCTAssertEqual(layout.mostUsed, ["apps/safari"], "留在情景建议里，最常用里不再出")
    }

    func testDuplicatesWithinAGroupKeepTheFirst() {
        let layout = LauncherContextRules.layout(context: ["context/selection", "context/selection"],
                                                 situational: ["commands/a", "commands/a", "commands/b"],
                                                 mostUsed: ["apps/x", "apps/x"])
        XCTAssertEqual(layout.all, ["context/selection", "commands/a", "commands/b", "apps/x"])
    }

    // MARK: - 情景建议的次序（按紧急程度）

    /// 收集到的情景建议（收集顺序 = 模块注册顺序、模块里写的顺序）按优先级排好后的行 id。
    private func ordered(_ suggestions: [(id: String, priority: Int)]) -> [String] {
        LauncherContextRules.situationalOrder(priorities: suggestions.map(\.priority)).map { suggestions[$0].id }
    }

    func testFiveKindsShowMeetingClaudeRecordingAndTheFirstFocusRow() {
        // 注册顺序：截图 → 防休眠 → 专注 → 会议 → Claude Code；档位：会议 10、Claude 20、录屏 30、专注 40、防休眠 50。
        let collected: [(id: String, priority: Int)] = [
            ("commands/screenshot.record", 30), ("commands/caffeinate.toggle", 50),
            ("commands/focushealth.focus", 40), ("commands/focushealth.endFocus", 40),
            ("commands/meeting.startOnline", 10), ("commands/claudecode.waiting.s1", 20),
        ]
        let order = ordered(collected)
        XCTAssertEqual(order, ["commands/meeting.startOnline", "commands/claudecode.waiting.s1", "commands/screenshot.record",
                               "commands/focushealth.focus", "commands/focushealth.endFocus", "commands/caffeinate.toggle"])
        let layout = LauncherContextRules.layout(context: ["context/selection"], situational: order, mostUsed: ["apps/safari"])
        XCTAssertEqual(layout.situational, ["commands/meeting.startOnline", "commands/claudecode.waiting.s1",
                                            "commands/screenshot.record", "commands/focushealth.focus"],
                       "四条上限：会议、Claude、录屏、专注的第一条；结束专注、防休眠被挤掉")
    }

    func testSamePriorityKeepsTheOrderTheModulesGave() {
        XCTAssertEqual(ordered([("commands/focushealth.focus", 40), ("commands/focushealth.endFocus", 40)]),
                       ["commands/focushealth.focus", "commands/focushealth.endFocus"], "暂停专注在结束专注前面")
        XCTAssertEqual(ordered([("commands/caffeinate.toggle", 50), ("commands/meeting.join", 10),
                                ("commands/meeting.startOnline", 10), ("commands/claudecode.waiting.new", 20),
                                ("commands/claudecode.waiting.old", 20)]),
                       ["commands/meeting.join", "commands/meeting.startOnline", "commands/claudecode.waiting.new",
                        "commands/claudecode.waiting.old", "commands/caffeinate.toggle"],
                       "入会在开始记录前、新的会话在旧的前（模块给的先后）")
        XCTAssertEqual(LauncherContextRules.situationalOrder(priorities: []), [])
    }

    func testAnUnrankedSuggestionSitsWithTheLastTier() {
        let unranked = LauncherCommand(id: "other.thing", title: "Other", symbolName: "star") { _ in }
        XCTAssertEqual(unranked.suggestion.priority, 50, "不写优先级是 50，和防休眠同一档")
        XCTAssertEqual(ordered([("commands/other.thing", unranked.suggestion.priority), ("commands/caffeinate.toggle", 50),
                                ("commands/screenshot.record", 30)]),
                       ["commands/screenshot.record", "commands/other.thing", "commands/caffeinate.toggle"])
    }

    func testNothingAtAllIsAnEmptyLayout() {
        XCTAssertEqual(LauncherContextRules.layout(context: [], situational: [], mostUsed: []).all, [],
                       "什么都没有：面板照旧显示那一行提示")
    }

    // MARK: - 读选区的流程（注入取词函数）

    @MainActor
    func testFetcherDeliversAQuickResult() {
        let fetcher = LauncherSelectionFetcher(budget: 0.08, grace: 0.04, queue: DispatchQueue(label: "test.fetch"))
        let done = expectation(description: "delivered")
        var results: [LauncherSelectionRead] = []
        fetcher.start({ budget in
            XCTAssertEqual(budget, 0.08, "取词函数拿到的是时限")
            return .text("选中的一段")
        }) { read in
            results.append(read)
            done.fulfill()
        }
        XCTAssertTrue(fetcher.isReading)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results.map(\.outcome), [.text("选中的一段")])
        XCTAssertLessThan(results[0].milliseconds, 80)
        XCTAssertFalse(fetcher.isReading)
    }

    @MainActor
    func testFetcherTreatsAReadPastTheBudgetAsTimedOut() {
        // 取词函数 30 ms 才回来、时限 10 ms、宽限 200 ms：后台读完时按超时交（硬上限），不交那段文字。
        let fetcher = LauncherSelectionFetcher(budget: 0.01, grace: 0.2, queue: DispatchQueue(label: "test.fetch"))
        let done = expectation(description: "delivered")
        var results: [LauncherSelectionOutcome] = []
        fetcher.start({ _ in
            Thread.sleep(forTimeInterval: 0.03)
            return .text("too late")
        }) { read in
            results.append(read.outcome)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results, [.timedOut])
    }

    @MainActor
    func testFetcherGivesUpOnAStuckReaderAndDeliversOnlyOnce() {
        // 取词函数卡住 300 ms：时限 + 宽限（20 + 20 ms）一到就交一个超时，之后回来的不要。
        let fetcher = LauncherSelectionFetcher(budget: 0.02, grace: 0.02, queue: DispatchQueue(label: "test.fetch"))
        let first = expectation(description: "timed out")
        var results: [LauncherSelectionRead] = []
        let began = Date()
        fetcher.start({ _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .text("stuck")
        }) { read in
            results.append(read)
            first.fulfill()
        }
        wait(for: [first], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.25, "没等卡住的那次")
        XCTAssertEqual(results.map(\.outcome), [.timedOut])
        // 等卡住的那次回来：不再交第二次。
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(results.count, 1)
    }

    @MainActor
    func testCancelledReadIsNeverDelivered() {
        let fetcher = LauncherSelectionFetcher(budget: 0.05, grace: 0.02, queue: DispatchQueue(label: "test.fetch"))
        var delivered = 0
        fetcher.start({ _ in
            Thread.sleep(forTimeInterval: 0.01)
            return .text("x")
        }) { _ in delivered += 1 }
        fetcher.cancel()
        XCTAssertFalse(fetcher.isReading)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(delivered, 0, "面板收起后什么都不交（兜底超时也不交）")
    }

    @MainActor
    func testANewReadSupersedesTheOldOne() {
        let fetcher = LauncherSelectionFetcher(budget: 0.08, grace: 0.04, queue: DispatchQueue(label: "test.fetch"))
        var outcomes: [LauncherSelectionOutcome] = []
        let done = expectation(description: "second delivered")
        fetcher.start({ _ in
            Thread.sleep(forTimeInterval: 0.02)
            return .text("first")
        }) { read in outcomes.append(read.outcome) }
        fetcher.start({ _ in .text("second") }) { read in
            outcomes.append(read.outcome)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(outcomes, [.text("second")], "再次呼出：上一次的不要")
    }

    @MainActor
    func testNoPermissionAndBlankPassThrough() {
        let fetcher = LauncherSelectionFetcher(budget: 0.08, grace: 0.04, queue: DispatchQueue(label: "test.fetch"))
        var outcomes: [LauncherSelectionOutcome] = []
        let first = expectation(description: "no permission")
        fetcher.start({ _ in .noPermission }) { read in
            outcomes.append(read.outcome)
            first.fulfill()
        }
        wait(for: [first], timeout: 2)
        let second = expectation(description: "blank")
        fetcher.start({ _ in .text("   \n") }) { read in
            outcomes.append(read.outcome)
            second.fulfill()
        }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(outcomes, [.noPermission, .none])
    }
}
