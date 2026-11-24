import Foundation
import XCTest

/// 挂着图片时的建议（docs/launcher/TECH_DESIGN.md §5.5）：图片动作的排序、打字筛选、识别出的二维码和文字怎么换成行。
final class LauncherImageSuggestionsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 照各模块的声明：截图的四个图片动作 + 划词助手「翻译」用在图里的文字上（档位 15）。
    private let candidates = [
        LauncherSuggestionCandidate(id: "screenshot.image.ocr", traits: LauncherSuggestionTraits(priority: 10)),
        LauncherSuggestionCandidate(id: "screenshot.image.pin", traits: LauncherSuggestionTraits(priority: 20)),
        LauncherSuggestionCandidate(id: "screenshot.image.preview", traits: LauncherSuggestionTraits(priority: 30)),
        LauncherSuggestionCandidate(id: "screenshot.image.save", traits: LauncherSuggestionTraits(priority: 40)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.translate", traits: LauncherSuggestionTraits(priority: 15)),
    ]

    private func order(_ records: LauncherUsageRecords = LauncherUsageRecords()) -> [String] {
        LauncherImageSuggestionRanking.order(candidates, records: records, now: now)
            .map { candidates[$0].id.components(separatedBy: ".").last ?? "" }
    }

    private func records(_ uses: [(id: String, count: Int)], prefix: String = LauncherImageSuggestionRanking.usageKeyPrefix)
        -> LauncherUsageRecords {
        var records = LauncherUsageRecords()
        for use in uses {
            for _ in 0..<use.count { records.recordUse(of: prefix + use.id, at: now.addingTimeInterval(-3_600)) }
        }
        return records
    }

    // MARK: - 排序

    func testDefaultOrderFollowsThePriorities() {
        XCTAssertEqual(order(), ["ocr", "translate", "pin", "preview", "save"])
    }

    func testOftenUsedMovesUp() {
        // 「保存成文件」用了 7 次（使用分 300）：40 − 30 = 10，同分看原档位，排在取字（10）后面。
        XCTAssertEqual(order(records([("screenshot.image.save", 7)])), ["ocr", "save", "translate", "pin", "preview"])
        // 用过一次（100 分，往前挪 1）只在同一档里往前。
        XCTAssertEqual(order(records([("screenshot.image.preview", 1)])), ["ocr", "translate", "pin", "preview", "save"])
    }

    func testTextUsageDoesNotCountForImages() {
        // 文字的兜底建议记在 `textaction/` 下：对文字常用翻译，不等于对图片也常用。
        let textUses = records([("selectiontranslate.text.translate", 7)], prefix: LauncherSuggestionRanking.usageKeyPrefix)
        XCTAssertEqual(order(textUses), ["ocr", "translate", "pin", "preview", "save"])
        XCTAssertEqual(LauncherImageSuggestionRanking.usageKey(for: "screenshot.image.ocr"), "imageaction/screenshot.image.ocr")
    }

    func testKindsDoNotMatterForImages() {
        // 声明时写了「只对单词」的文字动作，用在图里的文字上照样排（图片不分类别）。
        let wordOnly = [LauncherSuggestionCandidate(id: "learn", traits: LauncherSuggestionTraits(kinds: [.word], priority: 10,
                                                                                                    boostedKinds: [.word]))]
        XCTAssertEqual(LauncherImageSuggestionRanking.order(wordOnly, records: LauncherUsageRecords(), now: now), [0])
        XCTAssertEqual(LauncherImageSuggestionRanking.order([], records: LauncherUsageRecords(), now: now), [])
    }

    // MARK: - 打字筛选

    func testFilterKeepsEverythingWhenEmpty() {
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "取字", filter: ""))
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "取字", filter: "  "))
    }

    func testFilterMatchesTitlesLikeTheSearch() {
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "取字", filter: "取"))
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "取字", filter: "qz"), "拼音首字母")
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "钉在屏幕上", filter: "ping"), "拼音全拼从音节开头")
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "翻译图里的文字", filter: "翻译"))
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "Save as file", filter: "save"))
        XCTAssertTrue(LauncherImageSuggestionFilter.keeps(title: "Pin to screen", filter: "pts"), "按顺序跳字")
        XCTAssertFalse(LauncherImageSuggestionFilter.keeps(title: "取字", filter: "保存"))
        XCTAssertFalse(LauncherImageSuggestionFilter.keeps(title: "Preview", filter: "xyz"))
    }

    // MARK: - 识别出的内容

    func testCodesAreTrimmedDedupedAndCapped() {
        XCTAssertEqual(LauncherRecognizedContent.codes([" https://a.com ", "", "  ", "https://a.com", "B", "C", "D"]),
                       ["https://a.com", "B", "C"])
        XCTAssertEqual(LauncherRecognizedContent.codes([]), [])
    }

    func testWebURLOnlyForHTTP() {
        XCTAssertEqual(LauncherRecognizedContent.webURL(in: "https://github.com/qiaob")?.absoluteString, "https://github.com/qiaob")
        XCTAssertEqual(LauncherRecognizedContent.webURL(in: "example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertNil(LauncherRecognizedContent.webURL(in: "WIFI:S:home;T:WPA;P:secret;;"))
        XCTAssertNil(LauncherRecognizedContent.webURL(in: "weixin://dl/scan"))
        XCTAssertNil(LauncherRecognizedContent.webURL(in: "otpauth://totp/me?secret=ABC"))
        XCTAssertNil(LauncherRecognizedContent.webURL(in: "6901234567892"), "条码数字")
        XCTAssertNil(LauncherRecognizedContent.webURL(in: "hello world"))
    }

    func testRecognizedText() {
        XCTAssertNil(LauncherRecognizedContent.text(" \n "))
        XCTAssertEqual(LauncherRecognizedContent.text("\n第一行\n第二行\n"), "第一行\n第二行")
        XCTAssertEqual(LauncherRecognizedContent.textTitle("第一行\n第二行"), "第一行 第二行")
        XCTAssertEqual(LauncherRecognizedContent.textTitle(String(repeating: "长", count: 100)).count,
                       LauncherRecognizedContent.textTitleLength)
        XCTAssertEqual(LauncherRecognizedContent.wordCount("快速入口 Quick Access 2026"), 7)
    }
}
