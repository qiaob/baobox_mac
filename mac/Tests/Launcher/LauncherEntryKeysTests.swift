import Foundation
import XCTest

/// 别的模块交来的条目（剪贴板、片段）的搜索键与缓存（docs/launcher/TECH_DESIGN.md §3.2、§5.2）。
final class LauncherEntryKeysTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func spec(_ id: String, _ title: String, _ text: String, pinyin: Bool = false,
                      secondsAgo: TimeInterval? = nil, source: String = "clipboard") -> LauncherEntryKeySpec {
        LauncherEntryKeySpec(sourceID: source, entryID: id, title: title, searchText: text, pinyin: pinyin,
                             date: secondsAgo.map { now.addingTimeInterval(-$0) })
    }

    // MARK: - 建哪些键

    func testKeyIsSourceSlashEntry() {
        XCTAssertEqual(spec("42", "a", "a").key, "clipboard/42")
        XCTAssertEqual(spec("42", "a", "a").key, LauncherCandidate.key(sourceID: "clipboard", entryID: "42"))
    }

    func testClipboardEntryWhoseTitleStartsTheTextGetsOneKey() {
        let keys = spec("1", "docker run", "docker run\n  -it ubuntu").makeKeys()
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.original.text, "docker run\n  -it ubuntu")
        XCTAssertNil(keys.first?.fullPinyin, "不转拼音")
    }

    func testSameTitleAndTextGetsOneKey() {
        XCTAssertEqual(spec("1", "hello", "hello").makeKeys().count, 1)
        XCTAssertEqual(spec("1", "hello", "").makeKeys().map(\.original.text), ["hello"], "没有全文就只有标题")
    }

    func testTitleNotAtTheStartOfTheTextGetsTwoKeys() {
        let keys = spec("1", "签名", "best regards").makeKeys()
        XCTAssertEqual(keys.map(\.original.text), ["签名", "best regards"])
        XCTAssertNil(keys[0].fullPinyin, "这个来源不转拼音")
    }

    func testSnippetTitleGetsPinyinButTheTextDoesNot() {
        let keys = spec("1", "邮件签名", "sig\n此致敬礼", pinyin: true, source: "snippets").makeKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].fullPinyin?.text, "youjianqianming")
        XCTAssertEqual(keys[0].initials?.text, "yjqm")
        XCTAssertEqual(keys[1].original.text, "sig\n此致敬礼")
        XCTAssertNil(keys[1].fullPinyin, "全文一律不转拼音")
    }

    func testPinyinTitleThatStartsTheTextStillGetsItsOwnKey() {
        // 转拼音时标题单独一个键（带拼音），全文另一个键（不带）。
        let keys = spec("1", "微信号", "微信号 abc", pinyin: true, source: "snippets").makeKeys()
        XCTAssertEqual(keys.map(\.original.text), ["微信号", "微信号 abc"])
        XCTAssertEqual(keys[0].initials?.text, "wxh")
    }

    func testClipboardPinyinIsOff() {
        XCTAssertEqual(LauncherEntryKeySpec.titlePinyinOffSourceIDs, ["clipboard"])
    }

    func testSameTextIgnoresTheDate() {
        let a = spec("1", "x", "x y", secondsAgo: 10)
        let b = spec("1", "x", "x y", secondsAgo: 99)
        XCTAssertTrue(a.hasSameText(as: b))
        XCTAssertFalse(a.hasSameText(as: spec("1", "x", "x z")))
        XCTAssertFalse(a.hasSameText(as: spec("2", "x", "x y")))
        XCTAssertFalse(a.hasSameText(as: spec("1", "x", "x y", pinyin: true)))
    }

    // MARK: - 缓存

    func testCacheReusesKeysUntilTheTextChanges() {
        var cache = LauncherEntryKeyCache()
        let first = spec("1", "token", "token abc")
        XCTAssertNil(cache.keys(for: first))
        XCTAssertEqual(cache.missing([first]), [first])

        XCTAssertEqual(cache.build([first]), 1)
        XCTAssertEqual(cache.keys(for: first), first.makeKeys())
        XCTAssertEqual(cache.keys(for: spec("1", "token", "token abc", secondsAgo: 5)), first.makeKeys(),
                       "时间变了（剪贴板去重时刷新时间戳）不用重建")
        XCTAssertTrue(cache.missing([first]).isEmpty)

        let edited = spec("1", "token", "token xyz")
        XCTAssertNil(cache.keys(for: edited), "内容改了（片段被编辑）要重建")
        XCTAssertEqual(cache.missing([first, edited]), [edited])
        cache.insert(edited, keys: edited.makeKeys())
        XCTAssertEqual(cache.count, 1, "同一个条目键换掉旧的")
        XCTAssertNil(cache.keys(for: first))
    }

    func testRetainDropsEntriesThatAreGone() {
        var cache = LauncherEntryKeyCache()
        let a = spec("a", "a", "a")
        let b = spec("b", "b", "b")
        cache.build([a, b])
        cache.retain([a.key])
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.keys(for: a))
        XCTAssertNil(cache.keys(for: b))
        cache.retain([])
        XCTAssertEqual(cache.count, 0)
    }

    func testMissingKeepsTheGivenOrder() {
        var cache = LauncherEntryKeyCache()
        let specs = (0..<5).map { spec("\($0)", "t\($0)", "t\($0)") }
        cache.build([specs[1], specs[3]])
        XCTAssertEqual(cache.missing(specs).map(\.key), ["clipboard/0", "clipboard/2", "clipboard/4"])
    }

    // MARK: - 先建哪些

    func testSplitBuildsTheNewestFirst() {
        let specs = [
            spec("old", "o", "o", secondsAgo: 3_600),
            spec("newest", "n", "n", secondsAgo: 1),
            spec("mid", "m", "m", secondsAgo: 60),
            spec("older", "x", "x", secondsAgo: 7_200),
        ]
        let (now, later) = LauncherEntryKeyCache.split(specs, budget: 2)
        XCTAssertEqual(now.map(\.key), ["clipboard/newest", "clipboard/mid"])
        XCTAssertEqual(later.map(\.key), ["clipboard/old", "clipboard/older"])
    }

    func testSplitUnderBudgetBuildsEverythingNow() {
        let specs = (0..<3).map { spec("\($0)", "t", "t", secondsAgo: TimeInterval($0)) }
        let (now, later) = LauncherEntryKeyCache.split(specs, budget: 3)
        XCTAssertEqual(now, specs, "没超预算时原样、不重排")
        XCTAssertTrue(later.isEmpty)
        XCTAssertEqual(LauncherEntryKeyCache.split([], budget: 200).now, [])
    }

    func testSplitTreatsUndatedAsNewestAndKeepsOrderOnTies() {
        let specs = [
            spec("a", "a", "a", secondsAgo: 5),
            spec("b", "b", "b"),
            spec("c", "c", "c", secondsAgo: 5),
            spec("d", "d", "d"),
        ]
        let (now, later) = LauncherEntryKeyCache.split(specs, budget: 3)
        XCTAssertEqual(now.map(\.key), ["clipboard/b", "clipboard/d", "clipboard/a"])
        XCTAssertEqual(later.map(\.key), ["clipboard/c"])
        XCTAssertEqual(LauncherEntryKeyCache.split(specs, budget: -1).later.count, 4, "负数当 0")
    }

    func testBackgroundBatchBuildsTheSameKeys() {
        let specs = [spec("1", "a", "a b"), spec("2", "签名", "sig", pinyin: true, source: "snippets")]
        let built = LauncherEntryKeyCache.makeKeys(specs)
        XCTAssertEqual(built.map(\.spec), specs)
        XCTAssertEqual(built.map(\.keys), specs.map { $0.makeKeys() })
    }

    // MARK: - 性能（只防退化；Debug 下的上限放宽）

    func testBuildingTwoThousandClipboardKeysStaysCheap() {
        let sample = "kubectl --context=staging get pods -n workers | grep adhoc 复制的一段中文说明 1234567890 "
        let specs = (0..<2000).map { index -> LauncherEntryKeySpec in
            let text = String((sample + "\(index) " + sample).prefix(200))
            return spec("\(index)", LauncherEntryText.parts(text).title, text, secondsAgo: TimeInterval(index))
        }
        let start = Date()
        var cache = LauncherEntryKeyCache()
        cache.build(specs)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(cache.count, 2000)
        XCTAssertLessThan(elapsed, 2.0, "Debug 下 2000 条不转拼音的键应在 2 秒内建完（Release 实测见 TECH_DESIGN §5.2）")
        let again = Date()
        XCTAssertTrue(cache.missing(specs).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.5, "全部命中缓存时只比文字")
    }
}
