import Foundation
import XCTest

/// 输入分类的两个新标记（像命令、带时间的句子）和它们在建议计划里的位置（docs/launcher/TECH_DESIGN.md §5.4、§5.6，PR 10）。
final class LauncherCommandReminderPlanTests: XCTestCase {

    private var clock: LauncherCalcContext { LauncherCalcTestSupport.context() }

    /// `pasted`：放进来的原文（控制器核对过输入框还是它才交进来，同引擎：这时按字面处理、不拆前缀）。
    private func plan(_ input: String, calculation: Bool = false, clock: LauncherCalcContext? = nil,
                      pasted: String? = nil) -> LauncherSuggestionPlan {
        let placed = pasted.flatMap { LauncherPlacedText($0)?.still(in: input) }
        return LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(input, literal: placed != nil), hasCalculation: calculation,
                                             hasRecognition: false, placed: placed, clock: clock)
    }

    // MARK: - 分类

    func testCommandIsAFlagOnPlainText() {
        let result = LauncherInputClassifier.classify("git status")
        XCTAssertEqual(result.kinds, [.plainText, .command], "像命令时不再算英文短语")
        XCTAssertEqual(result.command, "git status")
        XCTAssertEqual(LauncherInputClassifier.classify("$ npm run build").command, "npm run build")
        let long = "docker run --rm -it -v \"$PWD\":/work -w /work node:20 sh -c 'npm ci && npm run build && npm test'"
        XCTAssertEqual(LauncherInputClassifier.classify(long).kinds, [.plainText, .command], "长命令也按普通文字算")
    }

    func testLinksEmailsColorsAndPathsAreNeverCommands() {
        for text in ["https://example.com/a?b=c", "me@baobox.dev", "#17A398", "~/Downloads", "/usr/bin/git status"] {
            XCTAssertNil(LauncherInputClassifier.classify(text).command, text)
        }
        XCTAssertEqual(LauncherInputClassifier.classify("open the door").kinds, [.word])
    }

    func testReminderOnlyWithAClock() {
        let text = "20 分钟后提醒我取快递"
        XCTAssertEqual(LauncherInputClassifier.classify(text).kinds, [.plainText])
        XCTAssertNil(LauncherInputClassifier.classify(text).reminder)
        let result = LauncherInputClassifier.classify(text, clock: clock)
        XCTAssertEqual(result.kinds, [.plainText, .reminder])
        XCTAssertEqual(result.reminder?.text, "取快递")
        XCTAssertEqual(result.reminder?.date, LauncherCalcTestSupport.now.addingTimeInterval(20 * 60))
    }

    func testReminderOnALongSentenceKeepsLongText() {
        let text = "明天下午三点" + String(repeating: "和产品经理开会讨论上线", count: 8)
        let result = LauncherInputClassifier.classify(text, clock: clock)
        XCTAssertEqual(result.kinds, [.longText, .reminder])
    }

    // MARK: - 计划

    func testCommandRunsFromTheTopOfTheFallbackGroup() {
        let result = plan("git status")
        XCTAssertEqual(result.leading, [])
        XCTAssertEqual(result.fallbackLeading, [.runInTerminal("git status")])
        XCTAssertEqual(result.fallbackKinds, [.plainText, .command])
        XCTAssertEqual(result.rankedFallbackLimit, LauncherSuggestionRanking.maxRows - 1, "占兜底建议的一个名额")
        XCTAssertEqual(plan("$ ls").fallbackLeading, [.runInTerminal("ls")])
    }

    func testReminderGoesToTheTop() {
        let result = plan("明天下午三点开会", clock: clock)
        guard case .reminder(let draft)? = result.top.first else { return XCTFail("没出提醒") }
        XCTAssertEqual(draft.text, "开会")
        XCTAssertEqual(result.top.count, 1)
        XCTAssertEqual(result.fallbackKinds, [.plainText, .reminder])
        XCTAssertEqual(plan("明天下午三点开会").top, [], "没给「现在」不认")
    }

    func testNeitherWithACalculationOrAPrefix() {
        XCTAssertEqual(plan("git status", calculation: true).fallbackLeading, [])
        XCTAssertEqual(plan("明天下午三点开会", calculation: true, clock: clock).top, [])
        XCTAssertEqual(plan("c git status"), .none)
        XCTAssertEqual(plan("> 明天下午三点开会", clock: clock), .none)
    }

    func testMultiLinePasteIsNotACommand() {
        let pasted = "git status\ngit push"
        XCTAssertEqual(plan("git status git push", pasted: pasted).fallbackLeading, [], "多行的原文不是一条命令")
    }

    func testReminderList() {
        XCTAssertTrue(plan("提醒").showsReminders)
        XCTAssertTrue(plan("Reminders").showsReminders)
        XCTAssertTrue(plan("提醒", calculation: true).showsReminders)
        XCTAssertFalse(plan("提醒我").showsReminders)
        XCTAssertFalse(plan("c 提醒").showsReminders)
    }
}
