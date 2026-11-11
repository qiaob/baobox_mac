import Foundation
import XCTest

/// 通知内核的判断和记账（docs/notify-core/DESIGN.md §4 PR 5）：去重、合并计数、来源开关、勿扰时攒不攒、摘要、历史。
/// 按 #108 搬家时的现状写，不顺手改语义：现状里有几处看着别扭（同 key 换了标题直接丢、计数并到最近一条同标题上），
/// 测试照样钉住，要改另开 issue。
final class NotifyLedgerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func notice(_ title: String, source: String = "claudecode", level: Notice.Level = .bubble,
                        key: String? = nil, feedback: Bool = false) -> Notice {
        Notice(source: source, level: level, title: title, dedupeKey: key, isUserFeedback: feedback)
    }

    /// 按 NotifyCenter 的出厂设置投一条：来源开着、历史最多 50 条、不在勿扰。
    @discardableResult
    private func post(_ ledger: inout NotifyLedger, _ notice: Notice, at seconds: TimeInterval,
                      sourceEnabled: Bool = true, historyLimit: Int = 50, suppressed: Bool = false,
                      onAction: ((String) -> Void)? = nil) -> NotifyLedger.Decision {
        ledger.post(notice, onAction: onAction, at: at(seconds), sourceEnabled: sourceEnabled,
                    historyLimit: historyLimit, isSuppressed: { suppressed })
    }

    private func titles(_ ledger: NotifyLedger) -> [String] {
        ledger.history.map(\.title)
    }

    private func heldTitles(_ ledger: NotifyLedger) -> [String] {
        ledger.held.map(\.notice.title)
    }

    // MARK: - 去重

    /// 同来源同 key 30 秒内只放行一次：29.9 秒那条丢，30.1 秒那条出。
    func testSameKeyIsDroppedWithin30SecondsAndShownAfterwards() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("会议开始了", source: "meeting", key: "started.1"), at: 0), .deliver)
        XCTAssertEqual(post(&ledger, notice("会议开始了", source: "meeting", key: "started.1"), at: 29.9), .drop(.duplicate))
        XCTAssertEqual(post(&ledger, notice("会议开始了", source: "meeting", key: "started.1"), at: 30.1), .deliver)
        XCTAssertEqual(titles(ledger), ["会议开始了", "会议开始了"])
    }

    /// 窗口是「不到 30 秒」：正好 30 秒就放行。
    func testExactly30SecondsLaterIsShownAgain() {
        var ledger = NotifyLedger()
        post(&ledger, notice("a", key: "k"), at: 0)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 30), .deliver)
    }

    /// 窗口从上一次放行算起，被挡下的不顺延：0 秒出、20 秒挡、31 秒照样出；之后的窗口从 31 秒算。
    func testDroppedDuplicatesDoNotExtendTheWindow() {
        var ledger = NotifyLedger()
        post(&ledger, notice("a", key: "k"), at: 0)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 20), .drop(.duplicate))
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 31), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 60), .drop(.duplicate))
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 61), .deliver)
    }

    /// 去重按「来源 + key」：换来源、换 key 都不算重复；不带 key 的从不去重。
    func testDedupeIsPerSourceAndKeyAndNeedsAKey() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("a", source: "meeting", key: "k"), at: 0), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", source: "dictation", key: "k"), at: 1), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", source: "meeting", key: "k2"), at: 2), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", source: "meeting"), at: 3), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", source: "meeting"), at: 4), .deliver)
        XCTAssertEqual(ledger.history.count, 5)
        XCTAssertEqual(ledger.history.map(\.mergeCount), [1, 1, 1, 1, 1])
    }

    // MARK: - 合并计数

    /// 被挡下的并进历史里那一条的计数，不另起一条。
    func testDuplicatesAreCountedOnTheShownEntry() {
        var ledger = NotifyLedger()
        post(&ledger, notice("Claude 在等你确认", key: "waiting"), at: 0)
        post(&ledger, notice("Claude 在等你确认", key: "waiting"), at: 5)
        post(&ledger, notice("Claude 在等你确认", key: "waiting"), at: 10)
        XCTAssertEqual(ledger.history, [
            .init(date: at(0), source: "claudecode", level: .bubble, title: "Claude 在等你确认", mergeCount: 3),
        ])
    }

    /// 同 key、标题不同：第二条直接丢；历史里找不到同标题的那条，也就不加计数（设计稿 §4 PR 5 举的例子）。
    func testDuplicateWithADifferentTitleIsDroppedWithoutCounting() {
        var ledger = NotifyLedger()
        post(&ledger, notice("会议纪要已生成", source: "meeting", key: "minutes.a"), at: 0)
        XCTAssertEqual(post(&ledger, notice("会议纪要没生成", source: "meeting", key: "minutes.a"), at: 5), .drop(.duplicate))
        XCTAssertEqual(titles(ledger), ["会议纪要已生成"])
        XCTAssertEqual(ledger.history.map(\.mergeCount), [1])
    }

    /// 计数记在历史里最近一条「同来源同标题」的上，不看 key：中间插进一条同标题、别的 key 的，计数就记到它头上。
    func testCountGoesToTheNewestEntryWithTheSameSourceAndTitle() {
        var ledger = NotifyLedger()
        post(&ledger, notice("提醒", key: "a"), at: 0)
        post(&ledger, notice("提醒", key: "b"), at: 1)
        XCTAssertEqual(post(&ledger, notice("提醒", key: "a"), at: 2), .drop(.duplicate))
        XCTAssertEqual(ledger.history.map(\.date), [at(1), at(0)])
        XCTAssertEqual(ledger.history.map(\.mergeCount), [2, 1], "记到 1 秒那条（key b）上")
    }

    /// 原来那条已经被裁出历史：挡下的照样丢，计数无处可记。
    func testDuplicateOfATrimmedEntryIsDroppedWithoutCounting() {
        var ledger = NotifyLedger()
        post(&ledger, notice("a", key: "k"), at: 0, historyLimit: 1)
        post(&ledger, notice("b"), at: 1, historyLimit: 1)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 2, historyLimit: 1), .drop(.duplicate))
        XCTAssertEqual(ledger.history, [
            .init(date: at(1), source: "claudecode", level: .bubble, title: "b", mergeCount: 1),
        ])
    }

    // MARK: - 来源开关

    /// 来源关掉：直接丢，勿扰中、alert 也一样；不进历史、不攒、不开去重窗口（重新打开后同 key 马上能出）。
    func testDisabledSourceIsDroppedWithoutATrace() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 0, sourceEnabled: false), .drop(.sourceDisabled))
        XCTAssertEqual(post(&ledger, notice("b"), at: 1, sourceEnabled: false, suppressed: true), .drop(.sourceDisabled))
        XCTAssertEqual(post(&ledger, notice("c", level: .alert), at: 2, sourceEnabled: false), .drop(.sourceDisabled))
        XCTAssertTrue(ledger.history.isEmpty)
        XCTAssertTrue(ledger.held.isEmpty)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 3), .deliver, "关着时那条没开去重窗口")
    }

    // MARK: - 勿扰

    /// 不在勿扰：三个级别都现在出。
    func testWithoutSuppressionEveryLevelIsDelivered() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("a", level: .ambient), at: 0), .deliver)
        XCTAssertEqual(post(&ledger, notice("b", level: .bubble), at: 1), .deliver)
        XCTAssertEqual(post(&ledger, notice("c", level: .alert), at: 2), .deliver)
        XCTAssertTrue(ledger.held.isEmpty)
    }

    /// 勿扰时 bubble、ambient 攒起来（按投递顺序），照样记进历史。
    func testWhileSuppressedBubbleAndAmbientAreHeld() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("b1"), at: 0, suppressed: true), .hold)
        XCTAssertEqual(post(&ledger, notice("a1", level: .ambient), at: 1, suppressed: true), .hold)
        XCTAssertEqual(post(&ledger, notice("b2"), at: 2, suppressed: true), .hold)
        XCTAssertEqual(heldTitles(ledger), ["b1", "a1", "b2"])
        XCTAssertEqual(titles(ledger), ["b2", "a1", "b1"])
    }

    /// 勿扰时 alert 和操作回执（任何级别）照常出，不攒。
    func testWhileSuppressedAlertAndUserFeedbackAreDelivered() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("AI 今日额度用完了", level: .alert), at: 0, suppressed: true), .deliver)
        XCTAssertEqual(post(&ledger, notice("已暂停专注", feedback: true), at: 1, suppressed: true), .deliver)
        XCTAssertEqual(post(&ledger, notice("已关闭防休眠", level: .ambient, feedback: true), at: 2, suppressed: true), .deliver)
        XCTAssertTrue(ledger.held.isEmpty)
        XCTAssertEqual(ledger.history.count, 3)
    }

    /// 勿扰只在走到最后一步时问一次：来源关了、被去重挡下的不问；alert 也问（问完照常出）。
    func testSuppressionIsAskedOnlyForNoticesThatGetThatFar() {
        var ledger = NotifyLedger()
        var asked = 0
        func send(_ notice: Notice, at seconds: TimeInterval, sourceEnabled: Bool = true) -> NotifyLedger.Decision {
            ledger.post(notice, onAction: nil, at: at(seconds), sourceEnabled: sourceEnabled, historyLimit: 50,
                        isSuppressed: { asked += 1; return true })
        }
        XCTAssertEqual(send(notice("a", key: "k"), at: 0), .hold)
        XCTAssertEqual(send(notice("a", key: "k"), at: 1), .drop(.duplicate))
        XCTAssertEqual(send(notice("b"), at: 2, sourceEnabled: false), .drop(.sourceDisabled))
        XCTAssertEqual(send(notice("c", level: .alert), at: 3), .deliver)
        XCTAssertEqual(asked, 2)
    }

    /// 攒着的也算放行过：勿扰中同 key 再来一条被挡下，不会攒两条；勿扰解除后 30 秒内同 key 照样挡。
    func testHeldNoticesOpenTheDedupeWindow() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 0, suppressed: true), .hold)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 10, suppressed: true), .drop(.duplicate))
        XCTAssertEqual(heldTitles(ledger), ["a"])
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 20), .drop(.duplicate))
        XCTAssertEqual(ledger.history.map(\.mergeCount), [3])
    }

    /// 攒着的连同投稿方的回调一起留着；出摘要时一起丢掉，回调从来不调。
    func testHeldCallbacksAreKeptUntilTheDigestAndNeverCalled() {
        var ledger = NotifyLedger()
        var calls: [String] = []
        post(&ledger, notice("a"), at: 0, suppressed: true, onAction: { calls.append($0) })
        XCTAssertNotNil(ledger.held.first?.onAction)
        XCTAssertEqual(ledger.flush(isSuppressed: false), .digest(.init(count: 1, titles: ["a"])))
        XCTAssertTrue(ledger.held.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - 摘要

    /// 还在勿扰：接着等，攒着的不动。
    func testFlushWhileStillSuppressedKeepsWaiting() {
        var ledger = NotifyLedger()
        post(&ledger, notice("a"), at: 0, suppressed: true)
        post(&ledger, notice("b"), at: 1, suppressed: true)
        XCTAssertEqual(ledger.flush(isSuppressed: true), .stillSuppressed)
        XCTAssertEqual(heldTitles(ledger), ["a", "b"])
    }

    /// 勿扰解除：条数 = 攒了几条，正文是前 3 个标题（按投递顺序，用「、」连），攒着的清空；摘要不进历史。
    func testDigestCountsEverythingAndListsTheFirstThreeTitles() {
        var ledger = NotifyLedger()
        for (index, title) in ["喝水", "站立", "护眼", "会议纪要已生成", "Codex 完成了"].enumerated() {
            post(&ledger, notice(title), at: TimeInterval(index), suppressed: true)
        }
        let historyBefore = ledger.history
        guard case .digest(let digest) = ledger.flush(isSuppressed: false) else {
            return XCTFail("勿扰解除后应当出摘要")
        }
        XCTAssertEqual(digest, .init(count: 5, titles: ["喝水", "站立", "护眼"]))
        XCTAssertEqual(digest.body, "喝水、站立、护眼")
        XCTAssertTrue(ledger.held.isEmpty)
        XCTAssertEqual(ledger.history, historyBefore)
        XCTAssertEqual(ledger.flush(isSuppressed: false), .nothingHeld, "出过摘要就没东西了")
    }

    /// 攒了不到 3 条：有几条列几条；只攒了 1 条也出摘要（不原样补发）。
    func testDigestOfFewerThanThreeListsThemAll() {
        var ledger = NotifyLedger()
        post(&ledger, notice("a"), at: 0, suppressed: true)
        XCTAssertEqual(ledger.flush(isSuppressed: false), .digest(.init(count: 1, titles: ["a"])))
        post(&ledger, notice("b"), at: 1, suppressed: true)
        post(&ledger, notice("c"), at: 2, suppressed: true)
        guard case .digest(let digest) = ledger.flush(isSuppressed: false) else {
            return XCTFail("勿扰解除后应当出摘要")
        }
        XCTAssertEqual(digest.count, 2)
        XCTAssertEqual(digest.body, "b、c")
    }

    /// 没攒着东西：勿扰不勿扰都是 nothingHeld（NotifyCenter 据此停掉定时器）；直接出的不攒。
    func testFlushWithNothingHeld() {
        var ledger = NotifyLedger()
        XCTAssertEqual(ledger.flush(isSuppressed: false), .nothingHeld)
        XCTAssertEqual(ledger.flush(isSuppressed: true), .nothingHeld)
        post(&ledger, notice("a"), at: 0)
        post(&ledger, notice("b", level: .alert), at: 1, suppressed: true)
        XCTAssertEqual(ledger.flush(isSuppressed: false), .nothingHeld)
    }

    // MARK: - 历史

    /// 新的在前，超过上限从最旧的裁掉。每条记投递时刻、来源、级别、标题，计数从 1 起。
    func testHistoryKeepsTheNewestFirstAndTrimsTheOldest() {
        var ledger = NotifyLedger()
        for index in 0..<5 {
            let source = index.isMultiple(of: 2) ? "meeting" : "dictation"
            post(&ledger, notice("t\(index)", source: source, level: .ambient), at: TimeInterval(index * 10), historyLimit: 3)
        }
        XCTAssertEqual(ledger.history, [
            .init(date: at(40), source: "meeting", level: .ambient, title: "t4", mergeCount: 1),
            .init(date: at(30), source: "dictation", level: .ambient, title: "t3", mergeCount: 1),
            .init(date: at(20), source: "meeting", level: .ambient, title: "t2", mergeCount: 1),
        ])
    }

    /// 上限按每次投递时传进来的算：调小以后，下一条进来时一次裁到新上限；再调大，已经裁掉的回不来。
    func testLimitChangesApplyOnTheNextPost() {
        var ledger = NotifyLedger()
        for index in 0..<4 {
            post(&ledger, notice("t\(index)"), at: TimeInterval(index), historyLimit: 5)
        }
        post(&ledger, notice("t4"), at: 4, historyLimit: 2)
        XCTAssertEqual(titles(ledger), ["t4", "t3"])
        post(&ledger, notice("t5"), at: 5, historyLimit: 5)
        XCTAssertEqual(titles(ledger), ["t5", "t4", "t3"])
    }

    /// 上限 0：一条都不留，被挡下的也就无处计数；判断照旧（照样放行、照样去重）。
    func testZeroLimitKeepsNoHistory() {
        var ledger = NotifyLedger()
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 0, historyLimit: 0), .deliver)
        XCTAssertEqual(post(&ledger, notice("a", key: "k"), at: 1, historyLimit: 0), .drop(.duplicate))
        XCTAssertTrue(ledger.history.isEmpty)
    }

    // MARK: - 模型

    /// 不指定样式按级别：ambient → toast、bubble → card、alert → sticky；指定了以指定的为准。
    func testResolvedStyleFollowsTheLevelUnlessSet() {
        XCTAssertEqual(Notice(source: "s", level: .ambient, title: "t").resolvedStyle, .toast)
        XCTAssertEqual(Notice(source: "s", level: .bubble, title: "t").resolvedStyle, .card)
        XCTAssertEqual(Notice(source: "s", level: .alert, title: "t").resolvedStyle, .sticky)
        XCTAssertEqual(Notice(source: "s", level: .alert, title: "t", style: .toast).resolvedStyle, .toast)
    }
}
