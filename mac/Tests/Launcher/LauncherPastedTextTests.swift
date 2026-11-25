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
        // 结果必须一样。上面几条用例 + 一批随机的输入框文字（原文上加减字、加减空白）。
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

    /// 守住「每次查询不重复归一」：约 1 MB 的原文放进来后，查询入口（拆前缀 + 出哪些建议）比同一段字直接查多花的时间，
    /// 要远小于归一一次的时间（以前每次查询要把原文和输入框各归一一遍：1 MB 单行从约 43 ms 涨到约 180 ms）。
    /// 用同一台机器上归一一次的耗时当尺子，机器快慢都不影响。
    func testQueryingALargePlacedTextDoesNotNormalizeItAgain() {
        // 词之间一个空格、首尾没有空白：输入框里的样子（换行变空格）正好就是归一后的原文。
        let paragraph = Array(repeating: "快速入口 placed text", count: 400).joined(separator: " ")
        let multiline = Array(repeating: paragraph, count: 100).joined(separator: "\n")     // 约 1 MB，带换行
        let singleLine = Array(repeating: paragraph, count: 100).joined(separator: " ")     // 约 1 MB，一行
        func best(_ body: () -> Void) -> TimeInterval {
            var times: [TimeInterval] = []
            for _ in 0..<5 {
                let start = Date()
                body()
                times.append(Date().timeIntervalSince(start))
            }
            return times.min() ?? 0
        }
        let field = multiline.replacingOccurrences(of: "\n", with: " ")
        let normalizeOnce = best { _ = LauncherPastedText.normalized(field) }
        XCTAssertGreaterThan(normalizeOnce, 0)

        // 单行：放进来的和直接查的走同一段分类，差别只在查询入口自己。
        guard let placedLine = LauncherPlacedText(singleLine), placedLine.matches(fieldText: singleLine) else {
            return XCTFail("放进来后输入框里就是它")
        }
        let lineTyped = best {
            _ = LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(singleLine, literal: true), hasCalculation: false,
                                              hasRecognition: false)
        }
        let linePlaced = best {
            _ = LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(singleLine, literal: true), hasCalculation: false,
                                              hasRecognition: false, placed: placedLine)
        }
        XCTAssertLessThan(linePlaced - lineTyped, normalizeOnce / 2, "单行：查询入口不再归一")

        // 多行：建议用原文分类，对照组直接拿原文查，差别同样只在查询入口。
        guard let placed = LauncherPlacedText(multiline), placed.matches(fieldText: field),
              let original = placed.suggestionText else { return XCTFail("放进来后输入框里就是它") }
        let typed = best {
            _ = LauncherSuggestionPolicy.plan(for: LauncherQuery(sourceID: nil, text: original), hasCalculation: false,
                                              hasRecognition: false)
        }
        let placedQuery = best {
            _ = LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(field, literal: true), hasCalculation: false,
                                              hasRecognition: false, placed: placed)
        }
        XCTAssertLessThan(placedQuery - typed, normalizeOnce / 2, "多行：查询入口不再归一")

        // 第一次改动：删一个字 —— 比长度就知道不是它，不看内容；开头多了一个字 —— 逐字比，第一个字就停。
        XCTAssertEqual(field, singleLine)
        let shorter = String(field.dropLast())
        let rejectShorter = best { _ = placed.matches(fieldText: shorter) }
        XCTAssertFalse(placed.matches(fieldText: shorter))
        XCTAssertLessThan(rejectShorter, normalizeOnce / 20, "短了：不归一")
        let prefixed = "x" + field
        let rejectPrefixed = best { _ = placed.matches(fieldText: prefixed) }
        XCTAssertFalse(placed.matches(fieldText: prefixed))
        XCTAssertLessThan(rejectPrefixed, normalizeOnce / 20, "第一处不同就停")
    }
}
