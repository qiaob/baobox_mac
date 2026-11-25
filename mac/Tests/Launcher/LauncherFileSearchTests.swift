import Foundation
import XCTest

/// 快速入口按名字搜文件：什么时候搜、过滤噪音、同名副本、排序，以及和其余来源一起排（docs/launcher/TECH_DESIGN.md §6.4）。
final class LauncherFileSearchTests: XCTestCase {

    private let home = "/Users/me"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ input: String, hasCalculation: Bool = false) -> LauncherFileSearchRequest? {
        LauncherFilePolicy.request(for: LauncherQuery.parse(input), hasCalculation: hasCalculation)
    }

    private func hit(_ path: String, folder: Bool = false, daysAgo: Double = 0, usedDaysAgo: Double? = nil) -> LauncherFileHit {
        LauncherFileHit(path: path, isDirectory: folder,
                        lastUsed: usedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
                        modified: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func process(_ hits: [LauncherFileHit], _ request: LauncherFileSearchRequest,
                         limit: Int = LauncherFileFilter.maxResults) -> [String] {
        LauncherFileFilter.process(hits, request: request, home: home, limit: limit).map(\.hit.path)
    }

    // MARK: - 什么时候搜

    func testFilesPrefixSearchesFromOneCharacter() {
        XCTAssertEqual(request("f a"), .nameContains(["a"]))
        XCTAssertEqual(request("f 发票"), .nameContains(["发票"]))
        XCTAssertNil(request("f "), "只打了前缀")
    }

    func testUnscopedNeedsThreeCharactersHanCountsTwo() {
        XCTAssertNil(request("ab"))
        XCTAssertEqual(request("abc"), .nameContains(["abc"]))
        XCTAssertNil(request("发"))
        XCTAssertEqual(request("发票"), .nameContains(["发票"]))
        XCTAssertEqual(LauncherFilePolicy.weightedLength("发票ab"), 6)
    }

    func testMultipleWordsAllRequired() {
        XCTAssertEqual(request("tech design"), .nameContains(["tech", "design"]))
        XCTAssertEqual(request("f  周报   2026 "), .nameContains(["周报", "2026"]))
    }

    func testNoSearchForCalculationsOtherPrefixesAndJunk() {
        XCTAssertNil(request("12*(3+4)", hasCalculation: true))
        XCTAssertEqual(request("f 12*(3+4)", hasCalculation: true), .nameContains(["12*(3+4)"]), "f 前缀下算式也照搜")
        XCTAssertNil(request("a safari"))
        XCTAssertNil(request("c docker"))
        XCTAssertNil(request("> 截图"))
        XCTAssertNil(request(String(repeating: "x", count: 256)))
        XCTAssertNil(LauncherFilePolicy.request(for: LauncherQuery(sourceID: nil, text: "abc\ndef"), hasCalculation: false))
    }

    func testSlashFragmentSearchesTheExactLastSegment() {
        XCTAssertEqual(request("png-final/8-prefix-c-light.png"),
                       .exactName("8-prefix-c-light.png", pathSuffix: "png-final/8-prefix-c-light.png"))
        XCTAssertEqual(request("f docs/launcher/TECH_DESIGN.md"),
                       .exactName("TECH_DESIGN.md", pathSuffix: "docs/launcher/TECH_DESIGN.md"))
        XCTAssertEqual(request("a b/c d.txt"), nil, "a 前缀不搜文件")
        XCTAssertEqual(request("my docs/c d.txt"), .exactName("c d.txt", pathSuffix: "my docs/c d.txt"), "名字里能有空格")
    }

    func testSlashWithoutAFileNameDoesNotSearch() {
        for input in ["docs/launcher", "1/2.5", "24/7", "https://example.com/a/b.md", "a//b.md", "./b.md", "../b.md",
                      "a/b.", "a/.env", "a/b.toolongextension", "f /Users/me/a.md", "f ~/a.md", "abc/"] {
            XCTAssertNil(request(input), input)
        }
    }

    func testLooksLikeFileName() {
        XCTAssertTrue(LauncherFilePolicy.looksLikeFileName("a.png"))
        XCTAssertTrue(LauncherFilePolicy.looksLikeFileName("archive.tar.gz"))
        XCTAssertTrue(LauncherFilePolicy.looksLikeFileName("x.mp4"))
        XCTAssertFalse(LauncherFilePolicy.looksLikeFileName("README"))
        XCTAssertFalse(LauncherFilePolicy.looksLikeFileName(".zshrc"))
        XCTAssertFalse(LauncherFilePolicy.looksLikeFileName("2.5"))
        XCTAssertFalse(LauncherFilePolicy.looksLikeFileName("a.p-g"))
    }

    // MARK: - 噪音

    func testExcludedPaths() {
        for path in [
            "/Users/me/Library/Caches/x.json", "/Users/me/Library",
            "/Users/me/proj/node_modules/react/README.md", "/Users/me/proj/node_modules",
            "/Users/me/proj/.git/config", "/Users/me/x/DerivedData/a.swift", "/Users/me/x/deriveddata/a.swift",
            "/Users/me/x/build/out.txt", "/Users/me/x/Build/out.txt", "/Users/me/mac/build.noindex/Release/x.txt",
            "/Users/me/x/.build/debug/y", "/Users/me/ios/Pods/Alamofire/README.md", "/Users/me/.Trash/old.pdf",
            "/Users/me/Vendor/mitmproxy.noindex/README.txt", "/Users/me/scratch.noindex",
            "/Users/me/Applications/Foo.app/Contents/Info.plist", "/Users/me/Applications/Foo.app",
            "/Users/me/Downloads/Bar.APP", "/Users/me/.cache/x.txt", "/Users/me/p/App.xcodeproj/project.pbxproj",
            "/Users/me/Pictures/Photos Library.photoslibrary/database/x.db",
        ] {
            XCTAssertTrue(LauncherFileFilter.isExcluded(path: path, home: home), path)
        }
    }

    func testKeptPaths() {
        for path in [
            "/Users/me/Downloads/发票.pdf", "/Users/me/cmb/worktrees/a/docs/TECH_DESIGN.md", "/Users/me/Library2/x.txt",
            "/Users/me/p/App.xcodeproj", "/Users/me/Documents/Deck.key", "/Users/me/proj/.env", "/Users/me/builder/x.txt",
            "/Users/me/v1.2/notes.md",
        ] {
            XCTAssertFalse(LauncherFileFilter.isExcluded(path: path, home: home), path)
        }
    }

    func testCanonicalPathDropsTheDataVolumePrefix() {
        XCTAssertEqual(LauncherFileFilter.canonicalPath("/System/Volumes/Data/Users/me/Library/x.plist", home: home),
                       "/Users/me/Library/x.plist", "Spotlight 交回数据卷上的写法")
        XCTAssertEqual(LauncherFileFilter.canonicalPath("/System/Volumes/Data/Users/me", home: home), "/Users/me")
        XCTAssertEqual(LauncherFileFilter.canonicalPath("/Users/me/a.txt", home: home), "/Users/me/a.txt")
        XCTAssertEqual(LauncherFileFilter.canonicalPath("/System/Volumes/Data/opt/x", home: home), "/System/Volumes/Data/opt/x",
                       "主目录以外的不动")
        XCTAssertEqual(LauncherFileFilter.canonicalPath("/System/Volumes/Data/Users/meow/x", home: home),
                       "/System/Volumes/Data/Users/meow/x")
    }

    func testProcessDropsNoise() {
        let hits = [hit("/Users/me/Library/Caches/readme.txt"), hit("/Users/me/p/node_modules/x/README.md"),
                    hit("/Users/me/p/README.md")]
        XCTAssertEqual(process(hits, .nameContains(["readme"])), ["/Users/me/p/README.md"])
    }

    // MARK: - 同名副本

    func testSameNameKeepsNewestThreeCopies() {
        let hits = (0..<8).map { hit("/Users/me/cmb/worktrees/w\($0)/docs/TECH_DESIGN.md", daysAgo: Double($0)) }
            + [hit("/Users/me/notes/TECH_DESIGN_v2.md", daysAgo: 30)]
        let paths = process(hits.shuffled(), .nameContains(["TECH_DESIGN"]))
        XCTAssertEqual(paths, ["/Users/me/cmb/worktrees/w0/docs/TECH_DESIGN.md",
                               "/Users/me/cmb/worktrees/w1/docs/TECH_DESIGN.md",
                               "/Users/me/cmb/worktrees/w2/docs/TECH_DESIGN.md",
                               "/Users/me/notes/TECH_DESIGN_v2.md"])
    }

    func testCopiesPreferTouchedThenSpotlightOverScannedOnly() {
        // 验证者构造的数据：扫的目录里 3 份更新的副本，原来会把 Spotlight 的副本全挤掉。
        var scanned = (0..<3).map { hit("/private/tmp/c\($0)/x.txt", daysAgo: Double($0) * 0.1) }
        for index in scanned.indices { scanned[index].origins = [.scanned] }
        var spotlight = [hit("/Users/me/a/x.txt", daysAgo: 20), hit("/Users/me/b/x.txt", daysAgo: 30)]
        for index in spotlight.indices { spotlight[index].origins = [.spotlight] }
        var copied = hit("/Users/me/old/x.txt", daysAgo: 90)
        copied.origins = [.clipboard]
        let kept = process(scanned + spotlight + [copied], .nameContains(["x.txt"]))
        XCTAssertEqual(Set(kept), ["/Users/me/old/x.txt", "/Users/me/a/x.txt", "/Users/me/b/x.txt"],
                       "碰过的 → Spotlight → 只来自扫的目录的，档内新的在前")
        let onlyScanned = process(scanned + [hit("/Users/me/a/y.txt")], .nameContains(["x.txt"]))
        XCTAssertEqual(onlyScanned.filter { $0.hasSuffix("/x.txt") }.count, 3, "只有扫的目录里有时照样留 3 份")
    }

    func testCopiesUseLastUsedWhenNewer() {
        let hits = [hit("/Users/me/a/x.txt", daysAgo: 1), hit("/Users/me/b/x.txt", daysAgo: 2),
                    hit("/Users/me/c/x.txt", daysAgo: 3), hit("/Users/me/d/x.txt", daysAgo: 400, usedDaysAgo: 0.5)]
        XCTAssertEqual(process(hits, .nameContains(["x.txt"])), ["/Users/me/d/x.txt", "/Users/me/a/x.txt", "/Users/me/b/x.txt"],
                       "最近打开过的旧文件算新的")
    }

    func testSameNameIgnoresCase() {
        let hits = (0..<5).map { hit("/Users/me/\($0)/\($0 % 2 == 0 ? "README.md" : "readme.md")", daysAgo: Double($0)) }
        XCTAssertEqual(process(hits, .nameContains(["readme"])).count, 3)
    }

    // MARK: - 排序

    func testTierFirstThenRecency() {
        let hits = [
            hit("/Users/me/a/old-readme.txt", daysAgo: 0),        // 词首
            hit("/Users/me/a/README.md", daysAgo: 50),             // 开头
            hit("/Users/me/a/readme", folder: true, daysAgo: 90),  // 完全相等
            hit("/Users/me/a/myreadme.txt", daysAgo: 0),           // 包含
            hit("/Users/me/b/README.txt", daysAgo: 1),             // 开头，更新
        ]
        XCTAssertEqual(process(hits, .nameContains(["readme"])), [
            "/Users/me/a/readme", "/Users/me/b/README.txt", "/Users/me/a/README.md", "/Users/me/a/old-readme.txt",
            "/Users/me/a/myreadme.txt",
        ])
    }

    func testLimit() {
        let hits = (0..<100).map { hit("/Users/me/f/file\($0).txt", daysAgo: Double($0)) }
        XCTAssertEqual(process(hits, .nameContains(["file"])).count, LauncherFileFilter.maxResults)
        XCTAssertEqual(process(hits, .nameContains(["file"]), limit: 2), ["/Users/me/f/file0.txt", "/Users/me/f/file1.txt"])
    }

    func testTierScore() {
        func tier(_ name: String, _ words: String...) -> Int {
            LauncherFileFilter.tierScore(name: name, queries: words.map { LauncherMatchQuery(LauncherFileFilter.folded($0)) },
                                         whole: words.count > 1 ? LauncherMatchQuery(words.joined(separator: " ")) : nil)
        }
        XCTAssertEqual(tier("readme", "readme"), 1000)
        XCTAssertEqual(tier("README.md", "readme"), 800)
        XCTAssertEqual(tier("old-readme.txt", "readme"), 600)
        XCTAssertEqual(tier("myreadme.txt", "readme"), 400)
    }

    func testTierScoreTakesTheWorstWordUnlessTheWholeMatches() {
        let queries = ["design", "tech"].map { LauncherMatchQuery($0) }
        XCTAssertEqual(LauncherFileFilter.tierScore(name: "tech-design-notes.md", queries: queries), 600)
        XCTAssertEqual(LauncherFileFilter.tierScore(name: "tech design notes.md", queries: queries,
                                                    whole: LauncherMatchQuery("tech design")), 800, "连起来整体是开头")
    }

    func testTierScoreFoldsDiacriticsAndFallsBackToContains() {
        XCTAssertEqual(LauncherFileFilter.tierScore(name: "Résumé 2026.pdf",
                                                    queries: [LauncherMatchQuery(LauncherFileFilter.folded("resume"))]), 800)
        XCTAssertEqual(LauncherFileFilter.tierOf(nil), 400)
        XCTAssertEqual(LauncherFileFilter.tierOf(150), 400, "跳字也按包含算（后端已保证包含）")
        XCTAssertEqual(LauncherFileFilter.tierOf(799), 800)
        XCTAssertEqual(LauncherFileFilter.tierOf(700), 800)
        XCTAssertEqual(LauncherFileFilter.tierOf(699), 600)
    }

    // MARK: - 片段

    func testFragmentKeepsOnlyPathsEndingWithIt() {
        let request = LauncherFileSearchRequest.exactName("8-prefix-c-light.png", pathSuffix: "png-final/8-prefix-c-light.png")
        let hits = [hit("/Users/me/x/png-final/8-prefix-c-light.png", daysAgo: 2),
                    hit("/Users/me/x/png-draft/8-prefix-c-light.png"),
                    hit("/Users/me/y/PNG-Final/8-prefix-c-light.PNG", daysAgo: 1),
                    hit("/Users/me/x/my-png-final/8-prefix-c-light.png")]
        let results = LauncherFileFilter.process(hits, request: request, home: home)
        XCTAssertEqual(results.map(\.hit.path), ["/Users/me/y/PNG-Final/8-prefix-c-light.PNG",
                                                 "/Users/me/x/png-final/8-prefix-c-light.png"],
                       "整段在一段的边界上结尾、不分大小写；新的在前")
        XCTAssertTrue(results.allSatisfy(\.pinned))
        XCTAssertTrue(results.allSatisfy { $0.tierScore == 1000 })
    }

    // MARK: - 先顶着用的旧结果

    func testStillMatches() {
        XCTAssertTrue(LauncherFileFilter.stillMatches(name: "README.md", request: .nameContains(["read"])))
        XCTAssertTrue(LauncherFileFilter.stillMatches(name: "Résumé.pdf", request: .nameContains(["resu", "pdf"])))
        XCTAssertFalse(LauncherFileFilter.stillMatches(name: "area.txt", request: .nameContains(["read"])))
        XCTAssertFalse(LauncherFileFilter.stillMatches(name: "a.png", request: .exactName("a.png", pathSuffix: "x/a.png")))
    }

    // MARK: - 和其余来源一起排

    private func fileCandidate(_ path: String, tier: Int, daysAgo: Double = 0) -> LauncherCandidate {
        LauncherCandidate(sourceID: "files", entryID: path,
                          searchKeys: [LauncherSearchKey((path as NSString).lastPathComponent, pinyin: false)],
                          date: now.addingTimeInterval(-daysAgo * 86_400), presetMatchScore: tier)
    }

    private func app(_ name: String) -> LauncherCandidate {
        LauncherCandidate(sourceID: "apps", entryID: "/Applications/\(name).app", searchKeys: [LauncherSearchKey(name)])
    }

    func testPresetScoreReplacesMatching() {
        let file = fileCandidate("/Users/me/a b.txt", tier: 800)
        let result = LauncherRanking.rank([file], query: "a b", records: LauncherUsageRecords(), now: now)
        XCTAssertEqual(result.items.first?.matchScore, 800, "多个词的查询整体匹配不上搜索键，也照样出")
        XCTAssertEqual(LauncherRanking.rank([file], query: "", records: LauncherUsageRecords(), now: now)
            .items.first?.matchScore, 0, "查询为空时是 0")
    }

    func testFilesRankAfterGoodAppMatchesButAboveWeakOnes() {
        let candidates = [fileCandidate("/Users/me/notes", tier: 800), app("Notes"), app("Keynote"),
                          fileCandidate("/Users/me/Notes Archive", tier: 800, daysAgo: 1)]
        let keys = LauncherRanking.rank(candidates, query: "note", records: LauncherUsageRecords(), now: now,
                                        sourceLimits: ["files": 5]).keys
        XCTAssertEqual(keys, ["apps//Applications/Notes.app", "files//Users/me/notes", "files//Users/me/Notes Archive",
                              "apps//Applications/Keynote.app"],
                       "开头匹配的 App（799）> 开头那一档的文件（480，同档新的在前）> 只是包含的 App（397）")
    }

    func testFileUsageLiftsIt() {
        var records = LauncherUsageRecords()
        records.recordUse(of: "files//Users/me/b.txt", at: now)
        let candidates = [fileCandidate("/Users/me/a.txt", tier: 800), fileCandidate("/Users/me/b.txt", tier: 800, daysAgo: 9)]
        XCTAssertEqual(LauncherRanking.rank(candidates, query: "txt", records: records, now: now).keys.first,
                       "files//Users/me/b.txt", "常开的文件排前面")
    }

    // MARK: - 只来自自己扫的目录的（PR 11）

    private func scannedOnly(_ path: String, tier: Int, daysAgo: Double = 0) -> LauncherCandidate {
        var candidate = fileCandidate(path, tier: tier, daysAgo: daysAgo)
        candidate.limitGroup = LauncherFileFilter.limitGroup(for: .scanned)
        return candidate
    }

    private func rankUnscoped(_ candidates: [LauncherCandidate], _ query: String,
                              records: LauncherUsageRecords = LauncherUsageRecords()) -> [String] {
        LauncherRanking.rank(candidates, query: query, records: records, now: now, sourceLimits: ["files": 5],
                             groupLimits: [LauncherFileFilter.scannedOnlyGroup: LauncherFileFilter.unscopedScannedOnlyLimit]).keys
    }

    func testScannedOnlyMeansOnlyFromTheScannedFolders() {
        XCTAssertEqual(LauncherFileFilter.limitGroup(for: .scanned), LauncherFileFilter.scannedOnlyGroup)
        XCTAssertNil(LauncherFileFilter.limitGroup(for: [.scanned, .spotlight]), "同时还来自别的来源的不算")
        XCTAssertNil(LauncherFileFilter.limitGroup(for: [.scanned, .clipboard]))
        XCTAssertNil(LauncherFileFilter.limitGroup(for: .spotlight))
        XCTAssertNil(LauncherFileFilter.limitGroup(for: [.known]))
    }

    func testScannedOnlyFilesTakeAtMostTwoRowsWhenUnscoped() {
        let scanned = (0..<4).map { scannedOnly("/private/tmp/c/s\($0)-safari.png", tier: 600) }
        let others = (0..<4).map { fileCandidate("/Users/me/o\($0)-safari.gif", tier: 600, daysAgo: 30) }
        let few = rankUnscoped(scanned + others.prefix(2), "safari")
        XCTAssertEqual(few.count, 4)
        XCTAssertEqual(few.filter { $0.hasPrefix("files//private/tmp/") }.count, 2, "只来自自己扫的目录的最多 2 行")
        XCTAssertEqual(Array(few.prefix(2)), ["files//Users/me/o0-safari.gif", "files//Users/me/o1-safari.gif"],
                       "同一档里排在别的文件后面（哪怕它们新得多）")
        let many = rankUnscoped(scanned + others, "safari")
        XCTAssertEqual(many.count, 5, "文件总共仍是最多 5 行")
        XCTAssertEqual(many.filter { $0.hasPrefix("files//private/tmp/") }.count, 1, "别的文件先占，剩下的位置才给它")
    }

    func testScannedOnlyStillWinsAHigherTier() {
        let keys = rankUnscoped([fileCandidate("/Users/me/my-safari.gif", tier: 600, daysAgo: 30),
                                 scannedOnly("/private/tmp/c/safari.png", tier: 1000)], "safari")
        XCTAssertEqual(keys.first, "files//private/tmp/c/safari.png", "只在同一档里往后排")
    }

    func testScannedOnlyFillsWhenNothingElseMatches() {
        let keys = rankUnscoped((0..<4).map { scannedOnly("/private/tmp/c/x\($0).log", tier: 400) }, "x")
        XCTAssertEqual(keys.count, 2, "别的来源一个都没有时也只出 2 行")
    }

    func testNoGroupLimitsMeansTheOldOrder() {
        let candidates = [scannedOnly("/private/tmp/c/new-safari.png", tier: 600),
                          fileCandidate("/Users/me/old-safari.gif", tier: 600, daysAgo: 30)]
        XCTAssertEqual(LauncherRanking.rank(candidates, query: "safari", records: LauncherUsageRecords(), now: now).keys,
                       ["files//private/tmp/c/new-safari.png", "files//Users/me/old-safari.gif"],
                       "f 前缀下（不传组的限额）照旧按新旧排、不限行数")
    }

    func testFilesSourceLimit() {
        let candidates = (0..<10).map { fileCandidate("/Users/me/f\($0).txt", tier: 800, daysAgo: Double($0)) }
        XCTAssertEqual(LauncherRanking.rank(candidates, query: "f", records: LauncherUsageRecords(), now: now,
                                            sourceLimits: ["files": 5]).items.count, 5)
    }
}
