import Foundation
import XCTest

/// 粘贴进来的原文：带换行才记、输入框里的文字还是它才用（docs/launcher/TECH_DESIGN.md §5.4）。
final class LauncherPastedTextTests: XCTestCase {

    func testOnlyMultilineTextIsWorthKeeping() {
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("第一行\n第二行"))
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("a\r\nb"))
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("a\u{2028}b"), "Unicode 行分隔符也算")
        XCTAssertFalse(LauncherPastedText.isWorthKeeping("one line"))
        XCTAssertFalse(LauncherPastedText.isWorthKeeping("tab\tonly"))
        XCTAssertFalse(LauncherPastedText.isWorthKeeping(""))
    }

    func testNormalized() {
        XCTAssertEqual(LauncherPastedText.normalized("  a \n\n b\t\tc  "), "a b c")
        XCTAssertEqual(LauncherPastedText.normalized("line one\r\nline two"), "line one line two")
        XCTAssertEqual(LauncherPastedText.normalized("   "), "")
        XCTAssertEqual(LauncherPastedText.normalized("中文　全角空格"), "中文 全角空格")
    }

    func testFieldTextAfterThePasteMatches() {
        // 单行输入框把 \n 换成一个空格、\r\n 换成两个空格（探针实测），制表符留着。
        let original = "第一段：快速入口\n\n第二段：放进任何东西\r\n第三段\twith tab"
        let field = "第一段：快速入口  第二段：放进任何东西  第三段\twith tab"
        XCTAssertTrue(LauncherPastedText.matches(original: original, fieldText: field))
        XCTAssertEqual(LauncherPastedText.original(original, matching: field), original)
        XCTAssertEqual(LauncherPastedText.original("\n  a\nb  \n", matching: "a b"), "a\nb", "首尾空白去掉，中间的换行留着")
    }

    func testAnyEditDropsTheOriginal() {
        let original = "Dear team,\nthe release is on Friday.\nThanks"
        XCTAssertNil(LauncherPastedText.original(original, matching: "Dear team, the release is on Friday. Thank"))
        XCTAssertNil(LauncherPastedText.original(original, matching: "Dear team, the release is on Monday. Thanks"))
        XCTAssertNil(LauncherPastedText.original(original, matching: "x Dear team, the release is on Friday. Thanks"),
                     "粘在已有文字后面的也不算")
        XCTAssertNil(LauncherPastedText.original(original, matching: ""))
    }

    func testNothingToUse() {
        XCTAssertNil(LauncherPastedText.original(nil, matching: "abc"))
        XCTAssertNil(LauncherPastedText.original("single line", matching: "single line"), "单行的不用记")
        XCTAssertNil(LauncherPastedText.original("\n\n", matching: ""), "全是空白")
    }

    func testWhitespaceOnlyDifferencesStillMatch() {
        XCTAssertTrue(LauncherPastedText.matches(original: "a\nb", fieldText: "  a   b "))
        XCTAssertFalse(LauncherPastedText.matches(original: "a\nb", fieldText: "ab"), "空白没了不算一样")
    }

    // MARK: - 放进来时算好、之后只看输入框（LauncherPlacedText，第 9 步复查后加）

    func testPlacedTextIsPreparedOnceWhenItIsPutIn() {
        let placed = LauncherPlacedText("\n  第一段\n第二段  \n")
        XCTAssertEqual(placed?.normalized, "第一段 第二段")
        XCTAssertEqual(placed?.suggestionText, "第一段\n第二段", "带换行的：建议用去首尾空白的原文")
        XCTAssertNil(LauncherPlacedText("one line")?.suggestionText, "单行的和输入框里的一样，不用换")
        XCTAssertNotNil(LauncherPlacedText("one line"), "单行的也记（按字面处理）")
        XCTAssertNil(LauncherPlacedText(" \n\t "), "全是空白：没东西可用")
        XCTAssertNil(LauncherPlacedText(""))
    }

    func testPlacedMatchesAgreesWithTheRuleItReplaces() {
        // 规则的定义是 `LauncherPastedText.matches`（两边各归一一次再比）；`LauncherPlacedText.matches` 只归一输入框、先比长度，
        // 只会更严（同一个字的合成 / 分解两种编码、空白后紧跟组合字符时它判不等）。这里的文字不含组合字符，两边必须一样：
        // 上面几条用例 + 一批随机的输入框文字（原文上加减字、加减空白）。
        let cases: [(String, String)] = [
            ("第一段：快速入口\n\n第二段：放进任何东西\r\n第三段\twith tab", "第一段：快速入口  第二段：放进任何东西  第三段\twith tab"),
            ("Dear team,\nthe release is on Friday.\nThanks", "Dear team, the release is on Friday. Thank"),
            ("Dear team,\nthe release is on Friday.\nThanks", "Dear team, the release is on Monday. Thanks"),
            ("Dear team,\nthe release is on Friday.\nThanks", "x Dear team, the release is on Friday. Thanks"),
            ("a\nb", "  a   b "), ("a\nb", "ab"), ("a b", "a  b"), ("c is a language", "c is a language"),
            ("c is a language", "c is a languages"), ("中文　全角空格", "中文 全角空格"), ("abc", ""), ("abc", "   abc   "),
        ]
        for (original, field) in cases {
            XCTAssertEqual(LauncherPlacedText(original)?.matches(fieldText: field),
                           LauncherPastedText.matches(original: original, fieldText: field), "\(original) | \(field)")
        }
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "b", "字", " ", "  ", "\n", "\r\n", "\t", "　", "é", "😀"]
        for _ in 0..<2_000 {
            let original = (0..<Int.random(in: 1...8, using: &generator)).map { _ in pieces.randomElement(using: &generator) ?? "" }
                .joined()
            var field = original
            switch Int.random(in: 0...4, using: &generator) {
            case 0: field = original.replacingOccurrences(of: "\n", with: " ")
            case 1: field += pieces.randomElement(using: &generator) ?? ""
            case 2: field = String(field.dropLast())
            case 3: field = (pieces.randomElement(using: &generator) ?? "") + field
            default: break
            }
            guard let placed = LauncherPlacedText(original) else {
                XCTAssertTrue(LauncherPastedText.normalized(original).isEmpty)
                continue
            }
            XCTAssertEqual(placed.matches(fieldText: field), LauncherPastedText.matches(original: original, fieldText: field),
                           "\(original.debugDescription) | \(field.debugDescription)")
        }
    }

    /// 守住「每次查询不重复归一」，数调用次数、不靠计时：约 1 MB 的原文放进来时归一一次；之后的查询入口（拆前缀 + 出哪些建议）
    /// 和核对输入框都一次也不调 `LauncherPastedText.normalized`。以前每次查询要把原文和输入框各归一一遍。
    func testQueryingALargePlacedTextNeverNormalizesAgain() throws {
        #if DEBUG
        // 词之间一个空格、首尾没有空白：输入框里的样子（换行变空格）正好就是归一后的原文。
        let paragraph = Array(repeating: "快速入口 placed text", count: 400).joined(separator: " ")
        let multiline = Array(repeating: paragraph, count: 100).joined(separator: "\n")     // 约 1 MB，带换行
        let field = Array(repeating: paragraph, count: 100).joined(separator: " ")          // 输入框里的样子，也是单行的原文
        XCTAssertGreaterThan(field.utf8.count, 900_000)

        var calls = LauncherPastedText.normalizedCallCount
        guard let placed = LauncherPlacedText(multiline), let placedLine = LauncherPlacedText(field) else {
            return XCTFail("放进来的不是空白")
        }
        XCTAssertEqual(LauncherPastedText.normalizedCallCount - calls, 2, "放进来时各归一一次")

        calls = LauncherPastedText.normalizedCallCount
        XCTAssertTrue(placed.matches(fieldText: field), "控制器核对：输入框里就是它")
        XCTAssertTrue(placedLine.matches(fieldText: field))
        for _ in 0..<3 {
            for verified in [placed, placedLine] {
                let query = LauncherQuery.parse(field, literal: true)
                XCTAssertNil(query.sourceID)
                let plan = LauncherSuggestionPolicy.plan(for: query, hasCalculation: false, hasRecognition: false, placed: verified)
                XCTAssertNotNil(plan.fallbackKinds)
            }
        }
        XCTAssertEqual(LauncherPastedText.normalizedCallCount - calls, 0, "核对和查询入口都不归一")
        XCTAssertEqual(LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(field, literal: true), hasCalculation: false,
                                                     hasRecognition: false, placed: placed).text,
                       multiline, "带换行的：交给动作的是放进来时算好的原文")
        #else
        throw XCTSkip("归一的调用计数只在 DEBUG 编译里有")
        #endif
    }

    /// 第一次改动：删一个字 —— 比长度就知道不是它，输入框一个字都不读；开头多了一个字 —— 读到第一个字就停；
    /// 末尾多打一个字 —— 要读完一遍（每段放进来的文字最多一次，之后不再核对）。
    func testTheFirstEditIsRejectedCheaply() {
        let paragraph = Array(repeating: "快速入口 placed text", count: 400).joined(separator: " ")
        guard let placed = LauncherPlacedText(paragraph) else { return XCTFail("放进来的不是空白") }
        XCTAssertEqual(placed.check(fieldText: String(paragraph.dropLast())), .init(matches: false, charactersRead: 0))
        XCTAssertEqual(placed.check(fieldText: "x" + paragraph), .init(matches: false, charactersRead: 1))
        XCTAssertEqual(placed.check(fieldText: paragraph + "s"), .init(matches: false, charactersRead: paragraph.count + 1))
        XCTAssertEqual(placed.check(fieldText: paragraph), .init(matches: true, charactersRead: paragraph.count))
    }

    // MARK: - 记下原文之后一定落定（LauncherPlacement，第 9 步复查后加）

    /// 复查找到的漏洞：输入框不在编辑时按 ⌘V —— 先记下剪贴板里的文字，粘贴什么都没做、也没有文字变化的回调。
    /// 落定时对着此刻的输入框（还是手打的 `f readme`）核对：对不上，原文作废，下一次查询照常拆前缀。
    func testPasteThatChangedNothingDropsTheRecordedText() {
        var placement = LauncherPlacement()
        placement.begin("c is a language")
        XCTAssertNil(placement.current, "记下的还没核对，不算数")
        XCTAssertFalse(placement.settle(fieldText: "f readme"), "没变：不用再查")
        XCTAssertNil(placement.current, "输入框不是它：作废")
        XCTAssertEqual(LauncherQuery.parse("f readme", literal: placement.current != nil), LauncherQuery(sourceID: "files", text: "readme"))
        XCTAssertFalse(placement.settle(fieldText: "c is a language"), "落定过一次就没有待定的了")
        XCTAssertNil(placement.current)
    }

    func testPasteThatReplacedTheFieldIsCheckedOnTheCallback() {
        var placement = LauncherPlacement()
        placement.begin("first line\nc second")
        placement.fieldChanged(to: "first line c second")     // 粘贴后的回调
        XCTAssertEqual(placement.current?.original, "first line\nc second")
        XCTAssertFalse(placement.settle(fieldText: "first line c second"), "回调里已经核对过")
        placement.fieldChanged(to: "first line c seconds")    // 接着打字
        XCTAssertNil(placement.current, "一改动就作废")
        placement.fieldChanged(to: "first line c second")     // 删回去
        XCTAssertNil(placement.current, "作废了就不再算数（同原来）")
    }

    func testPastingTheSameTextOverItselfTakesEffectWithoutACallback() {
        var placement = LauncherPlacement()
        // 手打的 `c is a language`，全选后再贴一次同样的字：文字没变、没有回调。
        placement.begin("c is a language")
        XCTAssertTrue(placement.settle(fieldText: "c is a language"), "落定后变成放进来的：要再查一次")
        XCTAssertEqual(placement.current?.original, "c is a language")
    }

    func testAFailedPasteKeepsTheEarlierPlacedText() {
        var placement = LauncherPlacement()
        placement.begin("A quick fix")
        placement.fieldChanged(to: "A quick fix")
        // 再按 ⌘V，这次粘贴没成（输入框不在编辑）：框里还是先前放进来的那段，它照旧算数。
        placement.begin("something else")
        XCTAssertFalse(placement.settle(fieldText: "A quick fix"))
        XCTAssertEqual(placement.current?.original, "A quick fix")
        // 空白或没有文字：不记，原来的照旧。
        placement.begin("  \n ")
        XCTAssertFalse(placement.settle(fieldText: "A quick fix"))
        XCTAssertEqual(placement.current?.original, "A quick fix")
        placement.clear()
        XCTAssertNil(placement.current)
    }
}
