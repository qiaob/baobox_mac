import Foundation
import XCTest

/// 输入分类的两个新标记（像命令、带时间的句子）和它们在建议计划里的位置（docs/launcher/TECH_DESIGN.md §5.4「像命令」「带时间的句子」，第 10 步）。
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

    /// 完整显示放不下 6 行的命令不出「在终端里运行」（第 10 步验证后定）。
    func testCommandsTooLongToShowWholeGetNoRunRow() {
        let fits = "curl -fsSL " + String(repeating: "a", count: LauncherConfirmText.commandColumns * 6 - 11)
        XCTAssertEqual(LauncherConfirmText.commandLines(fits)?.count, 6)
        XCTAssertEqual(plan(fits).fallbackLeading, [.runInTerminal(fits)], "正好 6 行")
        let tooLong = fits + "b"
        XCTAssertNotNil(LauncherInputClassifier.classify(tooLong).command, "仍认得是命令")
        XCTAssertEqual(plan(tooLong).fallbackLeading, [], "只是不出那一行")
        XCTAssertEqual(plan(tooLong).rankedFallbackLimit, LauncherSuggestionRanking.maxRows, "不占名额")
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

    /// 第 9 步起放进来的文字（⌘V、拖放、「选中的 / 刚复制的」）按字面处理、不拆前缀，单行的也记成原文
    /// （`LauncherPlacedText`，控制器核对过输入框还是它才交给查询，同引擎：`parse(_:literal: true)`）：像命令、带时间的句子照常认 ——
    /// 单行的分类读输入框里的文字（`suggestionText` 只给带换行的），带换行的读原文。
    func testPlacedTextIsClassifiedLikeTypedText() {
        func placed(_ text: String, original: String? = nil) -> LauncherSuggestionPlan {
            let placedText = LauncherPlacedText(original ?? text)?.still(in: text)
            XCTAssertNotNil(placedText, "输入框里的文字还是放进来的原文：\(text)")
            return LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(text, literal: placedText != nil), hasCalculation: false,
                                                 hasRecognition: false, placed: placedText, clock: clock)
        }
        XCTAssertEqual(placed("git status").fallbackLeading, [.runInTerminal("git status")], "贴进一条命令")
        XCTAssertEqual(placed("$ npm run build").fallbackLeading, [.runInTerminal("npm run build")])
        XCTAssertEqual(placed("  kubectl get pods -n pv-workers  ").fallbackLeading,
                       [.runInTerminal("kubectl get pods -n pv-workers")], "首尾空白去掉")
        guard case .reminder(let draft)? = placed("20 分钟后提醒我取快递").top.first else { return XCTFail("放进来的句子没认出提醒") }
        XCTAssertEqual(draft.text, "取快递")
        XCTAssertEqual(placed("git status git push", original: "git status\ngit push").fallbackLeading, [],
                       "带换行的原文不是一条命令")
        XCTAssertTrue(placed("提醒").showsReminders)
        // 像前缀开头的一句话放进来不拆前缀，照常有兜底建议（第 9 步的规则没被这一步改坏）。
        XCTAssertNotNil(placed("c is a language").fallbackKinds)
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
