import Foundation
import XCTest

/// 快速入口的建议：什么时候出哪些、兜底建议怎么排、字数、标题里的引用、网页搜索地址（docs/launcher/TECH_DESIGN.md §5.4）。
final class LauncherSuggestionsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ input: String, calculation: Bool = false, recognition: Bool = false) -> LauncherSuggestionPlan {
        LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(input), hasCalculation: calculation,
                                      hasRecognition: recognition)
    }

    // MARK: - 出哪些

    func testNothingForEmptyScopedOrPathInput() {
        for input in ["", "   ", "a 微信", "c docker", "> 截图", "/Users/qiao", "~/Downloads", " ~ "] {
            XCTAssertEqual(plan(input), .none, input)
        }
    }

    func testURLGetsOpenRowAndURLFallback() throws {
        let result = plan("example.com/path")
        XCTAssertEqual(result.text, "example.com/path")
        XCTAssertEqual(result.leading, [.openURL(try XCTUnwrap(URL(string: "https://example.com/path")))])
        XCTAssertEqual(result.fallbackKinds, [.url])
    }

    func testURLKeepsItsOpenRowNextToTextRecognition() throws {
        XCTAssertEqual(plan("https://example.com/?utm_source=x", recognition: true).leading,
                       [.openURL(try XCTUnwrap(URL(string: "https://example.com/?utm_source=x")))])
    }

    func testAmbiguousLinkOpensFromTheTopOfTheFallbackGroup() throws {
        for (input, address) in [("Safari.app", "https://Safari.app"), ("logo.ai", "https://logo.ai"),
                                 ("main.cc", "https://main.cc"), ("claude.ai", "https://claude.ai"),
                                 ("1.2.3.4", "http://1.2.3.4")] {
            let result = plan(input)
            XCTAssertEqual(result.leading, [], "不排最前：\(input)")
            XCTAssertEqual(result.fallbackLeading, [.openURL(try XCTUnwrap(URL(string: address)))], input)
            XCTAssertEqual(result.fallbackKinds, [.plainText], input)
            XCTAssertEqual(result.rankedFallbackLimit, LauncherSuggestionRanking.maxRows - 1, "占掉兜底建议的一个名额")
        }
        for (input, address) in [("https://claude.ai", "https://claude.ai"), ("claude.ai/chat", "https://claude.ai/chat"),
                                 ("192.168.1.1:3000", "http://192.168.1.1:3000")] {
            let result = plan(input)
            XCTAssertEqual(result.leading, [.openURL(try XCTUnwrap(URL(string: address)))], input)
            XCTAssertEqual(result.fallbackLeading, [], input)
            XCTAssertEqual(result.fallbackKinds, [.url], input)
            XCTAssertEqual(result.rankedFallbackLimit, LauncherSuggestionRanking.maxRows)
        }
    }

    func testEmailAndColor() {
        XCTAssertEqual(plan("mailto:me@baobox.dev").leading, [.email("me@baobox.dev")])
        XCTAssertEqual(plan("mailto:me@baobox.dev").fallbackKinds, [.email])
        guard case .color(let color)? = plan("#17A398").leading.first else { return XCTFail("没认出颜色") }
        XCTAssertEqual(color.hexString, "#17A398")
        XCTAssertEqual(plan("#17A398").fallbackKinds, [.color])
    }

    func testWordHasNoLeadingRowButWordFallback() {
        XCTAssertEqual(plan("serendipity").leading, [])
        XCTAssertEqual(plan("serendipity").fallbackKinds, [.word])
        XCTAssertEqual(plan("hello", recognition: true).fallbackKinds, [.word], "识别器把单词误认成别的也不影响")
    }

    func testLongTextGetsWordCountUnlessRecognized() {
        let long = String(repeating: "快速入口放进任何东西都有建议。", count: 8)
        let result = plan(long)
        XCTAssertEqual(result.leading, [.wordCount(LauncherTextStats.count(long))])
        XCTAssertEqual(result.fallbackKinds, [.longText])

        let recognized = plan(long, recognition: true)
        XCTAssertEqual(recognized.leading, [], "长串 JSON / Base64 不出字数")
        XCTAssertEqual(recognized.fallbackKinds, [.plainText], "也不把总结、润色提前")
    }

    func testCalculationKeepsOnlyThePlainFallback() {
        let result = plan("12*(3+4)", calculation: true)
        XCTAssertEqual(result.leading, [])
        XCTAssertEqual(result.fallbackKinds, [.plainText])
        XCTAssertEqual(plan("now", calculation: true).fallbackKinds, [.plainText], "单词也按普通文字算，不提前「学习」")
    }

    func testPlainText() {
        XCTAssertEqual(plan("随便什么").leading, [])
        XCTAssertEqual(plan("随便什么").fallbackKinds, [.plainText])
        XCTAssertEqual(plan("  随便什么  ").text, "随便什么")
    }

    func testFallbackNeedsTwoCharacters() {
        XCTAssertNil(plan("我").fallbackKinds)
        XCTAssertNil(plan("a").fallbackKinds)
        XCTAssertNil(plan("1", calculation: true).fallbackKinds)
        XCTAssertEqual(plan("我们").fallbackKinds, [.plainText])
        XCTAssertEqual(plan("ab").fallbackKinds, [.word])
    }

    // MARK: - 兜底建议的排序

    /// 和各模块的声明一样：剪贴板先注册（存为片段、钉成贴卡、二维码），划词助手后注册（翻译、学习、解释、总结、润色），
    /// 最后是快速入口自己的上网搜、搜文件。
    private let candidates: [LauncherSuggestionCandidate] = [
        LauncherSuggestionCandidate(id: "clipboard.text.saveSnippet", traits: LauncherSuggestionTraits(priority: 50)),
        LauncherSuggestionCandidate(id: "clipboard.text.pinCard", traits: LauncherSuggestionTraits(priority: 50)),
        LauncherSuggestionCandidate(id: "clipboard.text.qrCode",
                                    traits: LauncherSuggestionTraits(priority: 50, boostedKinds: [.url])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.translate", traits: LauncherSuggestionTraits(priority: 10)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.learn",
                                    traits: LauncherSuggestionTraits(kinds: [.word], priority: 10, boostedKinds: [.word])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.explain", traits: LauncherSuggestionTraits(priority: 20)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.summarize",
                                    traits: LauncherSuggestionTraits(kinds: [.plainText, .longText], priority: 20,
                                                                     boostedKinds: [.longText])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.polish",
                                    traits: LauncherSuggestionTraits(kinds: [.plainText, .longText], priority: 60,
                                                                     boostedKinds: [.longText])),
        LauncherSuggestionRanking.webSearch,
        LauncherSuggestionRanking.findFiles,
    ]

    private func order(_ kinds: Set<LauncherTextKind>, records: LauncherUsageRecords = LauncherUsageRecords(),
                       limit: Int = LauncherSuggestionRanking.maxRows) -> [String] {
        LauncherSuggestionRanking.order(candidates, kinds: kinds, records: records, now: now, limit: limit)
            .map { candidates[$0].id.components(separatedBy: ".").last ?? "" }
    }

    func testPlainTextOrderIsTheApprovedList() {
        XCTAssertEqual(order([.plainText]),
                       ["translate", "explain", "summarize", "webSearch", "findFiles", "saveSnippet", "pinCard", "qrCode"],
                       "润色排第 9，不出")
    }

    func testWordPutsLearnFirstAndSkipsSummaryAndPolish() {
        XCTAssertEqual(order([.word]),
                       ["learn", "translate", "explain", "webSearch", "findFiles", "saveSnippet", "pinCard", "qrCode"])
    }

    func testLongTextPutsSummaryAndPolishFirst() {
        XCTAssertEqual(order([.longText]),
                       ["summarize", "polish", "translate", "explain", "webSearch", "findFiles", "saveSnippet", "pinCard"])
    }

    func testURLPutsQRCodeFirst() {
        XCTAssertEqual(order([.url]),
                       ["qrCode", "translate", "explain", "webSearch", "findFiles", "saveSnippet", "pinCard"])
    }

    func testEmailAndColorGetTheGeneralOnes() {
        let expected = ["translate", "explain", "webSearch", "findFiles", "saveSnippet", "pinCard", "qrCode"]
        XCTAssertEqual(order([.email]), expected)
        XCTAssertEqual(order([.color]), expected)
    }

    func testLimit() {
        XCTAssertEqual(order([.plainText], limit: 3), ["translate", "explain", "summarize"])
        XCTAssertEqual(order([.plainText], limit: 0), [])
        XCTAssertEqual(order([.plainText], limit: -1), [])
    }

    func testNothingApplies() {
        XCTAssertEqual(order([]), [])
        XCTAssertEqual(LauncherSuggestionRanking.order([], kinds: [.plainText], records: LauncherUsageRecords(), now: now), [])
    }

    private func records(_ uses: [(id: String, count: Int, daysAgo: Double)]) -> LauncherUsageRecords {
        var records = LauncherUsageRecords()
        for use in uses {
            for _ in 0..<use.count {
                records.recordUse(of: LauncherSuggestionRanking.usageKey(for: use.id),
                                  at: now.addingTimeInterval(-use.daysAgo * 86_400))
            }
        }
        return records
    }

    func testOftenUsedMovesUpAtMostThreeTiers() {
        // 润色用了 7 次（使用分 300）：60 − 30 = 30，和上网搜同分，原来的优先级小的（上网搜）在前。
        let used = records([("selectiontranslate.text.polish", 7, 0)])
        XCTAssertEqual(order([.plainText], records: used),
                       ["translate", "explain", "summarize", "webSearch", "polish", "findFiles", "saveSnippet", "pinCard"])
    }

    func testUsedOnceOnlyReordersWithinATier() {
        // 二维码用过一次（100 分 → 往前挪 10）：50 − 10 = 40，和搜文件同分，搜文件在前；但已经在存为片段、钉成贴卡前面。
        let used = records([("clipboard.text.qrCode", 1, 0)])
        XCTAssertEqual(order([.plainText], records: used),
                       ["translate", "explain", "summarize", "webSearch", "findFiles", "qrCode", "saveSnippet", "pinCard"])
    }

    func testUsageDecays() {
        // 钉成贴卡用了 7 次、但是 28 天前：300 × 0.25 = 75 → 往前挪 7.5，排在存为片段前面、搜文件后面。
        let used = records([("clipboard.text.pinCard", 7, 28)])
        XCTAssertEqual(order([.plainText], records: used),
                       ["translate", "explain", "summarize", "webSearch", "findFiles", "pinCard", "saveSnippet", "qrCode"])
    }

    func testUsageCanBeatABoost() {
        // 单词：一直用翻译、不用学习 —— 翻译 10 − 30 = −20，排到学习（提前后是 0）前面。
        let used = records([("selectiontranslate.text.translate", 8, 0)])
        XCTAssertEqual(Array(order([.word], records: used).prefix(2)), ["translate", "learn"])
    }

    func testUsageKey() {
        XCTAssertEqual(LauncherSuggestionRanking.usageKey(for: "clipboard.text.qrCode"), "textaction/clipboard.text.qrCode")
        XCTAssertEqual(LauncherSuggestionRanking.webSearch.id, "launcher.webSearch")
        XCTAssertEqual(LauncherSuggestionRanking.findFiles.id, "launcher.findFiles")
    }

    // MARK: - 字数

    func testTextStats() {
        XCTAssertEqual(LauncherTextStats.count("Hello world"), LauncherTextStats(words: 2, characters: 11))
        XCTAssertEqual(LauncherTextStats.count("你好世界"), LauncherTextStats(words: 4, characters: 4))
        XCTAssertEqual(LauncherTextStats.count("我用 Baobox 3 年了。").words, 6)
        XCTAssertEqual(LauncherTextStats.count("don't stop, it’s fine").words, 4)
        XCTAssertEqual(LauncherTextStats.count("こんにちは").words, 5)
        XCTAssertEqual(LauncherTextStats.count("안녕 하세요").words, 5)
        XCTAssertEqual(LauncherTextStats.count("1,234.5 元").words, 4, "数字里的标点把它断开：1、234、5、元")
        XCTAssertEqual(LauncherTextStats.count("  ...  "), LauncherTextStats(words: 0, characters: 7))
        XCTAssertEqual(LauncherTextStats.count(""), LauncherTextStats(words: 0, characters: 0))
        XCTAssertEqual(LauncherTextStats.count("👍🏽 ok").characters, 4, "字符按看到的字算")
    }

    // MARK: - 标题里的引用

    func testQuote() {
        XCTAssertEqual(LauncherSuggestionText.quote("hello"), "hello")
        XCTAssertEqual(LauncherSuggestionText.quote("  hello \t  world  "), "hello world")
        let exact = String(repeating: "字", count: 24)
        XCTAssertEqual(LauncherSuggestionText.quote(exact), exact)
        XCTAssertEqual(LauncherSuggestionText.quote(exact + "多"), String(repeating: "字", count: 23) + "…")
        XCTAssertEqual(LauncherSuggestionText.quote(String(repeating: "a", count: 1000)).count, 24)
        XCTAssertEqual(LauncherSuggestionText.quote("abcdef", maxLength: 4), "abc…")
        XCTAssertEqual(LauncherSuggestionText.quote("https://example.com/a/very/long/path?with=query",
                                                    maxLength: LauncherSuggestionText.leadingQuoteLength),
                       "https://example.com/a/very/long/path?with=query")
    }

    // MARK: - 网页搜索

    func testGoogleURL() {
        let google = LauncherWebSearch.defaultEngine
        XCTAssertEqual(google, LauncherWebSearch.google)
        XCTAssertEqual(google.url(for: "hello world")?.absoluteString, "https://www.google.com/search?q=hello%20world")
        XCTAssertEqual(google.url(for: "C++ & 中文?")?.absoluteString,
                       "https://www.google.com/search?q=C%2B%2B%20%26%20%E4%B8%AD%E6%96%87%3F")
        XCTAssertEqual(google.url(for: "a/b#c=d")?.absoluteString, "https://www.google.com/search?q=a%2Fb%23c%3Dd")
        XCTAssertEqual(google.url(for: "  line one \n line two ")?.absoluteString,
                       "https://www.google.com/search?q=line%20one%20line%20two")
        XCTAssertNil(google.url(for: "   "))
    }

    func testLongQueriesAreCut() {
        let url = LauncherWebSearch.google.url(for: String(repeating: "a", count: 5000))
        XCTAssertEqual(url?.absoluteString.count, "https://www.google.com/search?q=".count + 500)
    }
}
