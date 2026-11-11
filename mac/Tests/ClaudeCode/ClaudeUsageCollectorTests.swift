import Foundation
import XCTest

/// Claude Code 用量条目的收集：按文件缓存、只重新解析改过的文件，结果与改动前每次全量解析逐条相同（顺序、去重、每个字段）。
/// 基准 `fullParse` 是改动前 `ClaudeUsageStore.collectEntries` 的原样拷贝。全部在临时目录里做，不碰真实的 `~/.claude`。
final class ClaudeUsageCollectorTests: XCTestCase {

    private var base: URL!
    /// `<临时目录>/projects`
    private var root: URL!
    private let now = Date()
    /// 每次写文件都把修改时间设成不同的值（递增的秒数），免得「内容变了、修改时间没变」。
    private var mtimeTick: TimeInterval = 0

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageCollectorTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - 单个文件的解析与合并

    func testCandidatesKeepLineOrderAndDedupKeys() {
        let candidates = parse([
            assistant(id: "m1", request: "r1"),
            assistant(id: "m2", request: nil),
            assistant(id: nil, request: "r3"),
            assistant(id: nil, request: nil),
        ])
        XCTAssertEqual(candidates.map(\.dedupKey), ["m1|r1", "m2", nil, nil])
    }

    /// 一条消息按内容块拆成几行（同一个 message.id + requestId）：同一个文件里只留第一行；没有去重键的行一条不少。
    func testRepeatedKeysWithinOneFileKeepOnlyTheFirstLine() {
        let candidates = parse([
            assistant(id: "m1", request: "r1", output: 1),
            assistant(id: "m1", request: "r1", output: 2),
            assistant(id: nil, request: nil, output: 3),
            assistant(id: nil, request: nil, output: 4),
            assistant(id: "m1", request: nil, output: 5),
            assistant(id: "m1", request: nil, output: 6),
        ])
        XCTAssertEqual(candidates.map(\.entry.output), [1, 3, 4, 5])
    }

    func testCandidatesSkipLinesWithoutUsageAndFallBackToFileValues() {
        let mtime = Date(timeIntervalSince1970: 1_790_000_000)
        let candidates = parse([
            json(["type": "user", "message": ["content": "hi"]]),
            json(["type": "summary", "summary": "x"]),
            json(["type": "assistant", "message": ["id": "no-usage"]]),
            "{not json",
            "[1, 2, 3]",
            "",
            assistant(id: "m1", request: "r1", cwd: nil, timestamp: nil),
            assistant(id: "m2", request: "r2", cwd: "", timestamp: "garbage"),
        ], mtime: mtime, fallbackProjectPath: "/Users/me/proj")

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.entry.timestamp), [mtime, mtime], "没有 / 解析不了的时间戳用文件的修改时间")
        XCTAssertEqual(candidates.map(\.entry.projectPath), ["/Users/me/proj", "/Users/me/proj"], "没有 / 空的 cwd 用目录名")
    }

    func testCompleteLastLineWithoutNewlineCountsButAHalfLineDoesNot() {
        let complete = assistant(id: "m1", request: "r1")
        let lastWithoutNewline = Data((complete + "\n" + assistant(id: "m2", request: "r2")).utf8)
        XCTAssertEqual(ClaudeUsageCollector.candidates(in: lastWithoutNewline, mtime: now, fallbackProjectPath: "/p").count, 2)

        let half = String(assistant(id: "m3", request: "r3").prefix(40))
        let halfLine = Data((complete + "\n" + half).utf8)
        XCTAssertEqual(ClaudeUsageCollector.candidates(in: halfLine, mtime: now, fallbackProjectPath: "/p").count, 1)
    }

    func testMergeKeepsTheFirstOccurrenceInTraversalOrder() {
        func candidate(_ key: String?, _ input: Int) -> ClaudeUsageCollector.Candidate {
            .init(dedupKey: key, entry: CLIUsageEntry(timestamp: now, modelID: "m", projectPath: "/p", input: input, output: 0))
        }
        let merged = ClaudeUsageCollector.merge([
            [candidate("k1", 1), candidate(nil, 2), candidate("k1", 3)],
            [candidate("k1", 4), candidate("k2", 5), candidate(nil, 6)],
        ])
        XCTAssertEqual(merged.map(\.input), [1, 2, 5, 6])
    }

    // MARK: - 缓存

    func testUnchangedFilesAreReusedNotReparsed() throws {
        try write([assistant(id: "a1", request: "r")], to: "-Users-me-proj/a.jsonl")
        try write([assistant(id: "b1", request: "r")], to: "-Users-me-proj/b.jsonl")
        try write([assistant(id: "c1", request: "r")], to: "-Users-me-other/c.jsonl")
        let collector = makeCollector()

        let first = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(first.parsedFiles, 3)
        XCTAssertEqual(first.reusedFiles, 0)
        XCTAssertEqual(first.entries, fullParse(hours: 180))
        XCTAssertEqual(first.entries.count, 3)

        let second = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(second.parsedFiles, 0)
        XCTAssertEqual(second.reusedFiles, 3)
        XCTAssertEqual(second.entries, first.entries)
        XCTAssertEqual(collector.cachedFileCount, 3)
    }

    /// 遍历在前的文件后来追加了一条重复的（同一个 message.id + requestId）：去重改留前面那份，在后的文件（直接用缓存）里那条不再算。
    /// 证明去重每轮在合并时重做，没有跟着缓存走。
    func testAppendingADuplicateToAnEarlierFileMovesTheDedupWinner() throws {
        let a = try write([assistant(id: "a1", request: "r")], to: "-Users-me-proj/a.jsonl")
        let b = try write([assistant(id: "b1", request: "r")], to: "-Users-me-proj/b.jsonl")
        let (earlier, later) = try ordered(a, b)

        try append([assistant(id: "dup", request: "r", output: 111)], to: later)
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries, fullParse(hours: 180))

        try append([assistant(id: "dup", request: "r", output: 999)], to: earlier)
        let after = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(after.parsedFiles, 1, "只重新解析追加了的那个文件")
        XCTAssertEqual(after.entries, fullParse(hours: 180))
        XCTAssertEqual(after.entries.filter { $0.output == 999 }.count, 1)
        XCTAssertEqual(after.entries.filter { $0.output == 111 }.count, 0)
    }

    func testRewrittenSmallerFileIsReparsed() throws {
        let url = try write([assistant(id: "a1", request: "r"), assistant(id: "a2", request: "r"), assistant(id: "a3", request: "r")],
                            to: "-Users-me-proj/a.jsonl")
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries.count, 3)

        try rewrite(url, [assistant(id: "a2", request: "r")], hoursAgo: 1)
        let after = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(after.parsedFiles, 1)
        XCTAssertEqual(after.entries, fullParse(hours: 180))
        XCTAssertEqual(after.entries.count, 1)
    }

    /// 改写成同样大小（数字换成同样位数的）、修改时间变了：照样重新解析。
    func testSameSizeRewriteWithANewModificationTimeIsReparsed() throws {
        let before = assistant(id: "a1", request: "r", output: 123)
        let after = assistant(id: "a1", request: "r", output: 456)
        XCTAssertEqual(before.utf8.count, after.utf8.count)
        try write([before], to: "-Users-me-proj/a.jsonl")
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries.map(\.output), [123])

        try write([after], to: "-Users-me-proj/a.jsonl")
        let collected = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(collected.parsedFiles, 1)
        XCTAssertEqual(collected.entries.map(\.output), [456])
        XCTAssertEqual(collected.entries, fullParse(hours: 180))
    }

    /// 删掉一个文件：它出缓存；它占着的去重键放开，别的文件里同一条用量重新算进来。
    func testDeletedFileLeavesTheCacheAndUnblocksADuplicateElsewhere() throws {
        let a = try write([assistant(id: "dup", request: "r", output: 1)], to: "-Users-me-proj/a.jsonl")
        let b = try write([assistant(id: "dup", request: "r", output: 2)], to: "-Users-me-proj/b.jsonl")
        let (earlier, later) = try ordered(a, b)
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries.map(\.output), [earlier == a ? 1 : 2])

        try FileManager.default.removeItem(at: earlier)
        let after = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(after.parsedFiles, 0, "剩下的文件没变，直接用缓存")
        XCTAssertEqual(after.entries, fullParse(hours: 180))
        XCTAssertEqual(after.entries.map(\.output), [later == a ? 1 : 2], "在后的那份重新算进来")
        XCTAssertEqual(collector.cachedFileCount, 1)
    }

    func testFilesOlderThanTheWindowAreSkippedAndDroppedFromTheCache() throws {
        let url = try write([assistant(id: "a1", request: "r")], to: "-Users-me-proj/a.jsonl", hoursAgo: 2)
        try write([assistant(id: "b1", request: "r")], to: "-Users-me-proj/b.jsonl", hoursAgo: 2)
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries.count, 2)
        XCTAssertEqual(collector.cachedFileCount, 2)

        try setModified(url, hoursAgo: 200)
        let aged = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(aged.entries, fullParse(hours: 180))
        XCTAssertEqual(aged.entries.count, 1)
        XCTAssertEqual(collector.cachedFileCount, 1, "超出 180 小时的文件出缓存")

        try setModified(url, hoursAgo: 1)
        let back = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(back.parsedFiles, 1)
        XCTAssertEqual(back.entries, fullParse(hours: 180))
    }

    /// 报表看 30 天：180 小时以外的文件照样解析（与原来一样），但不进缓存；菜单刷新随后照样对。
    func testReportWindowParsesOlderFilesWithoutCachingThem() throws {
        try write([assistant(id: "old", request: "r")], to: "-Users-me-proj/old.jsonl", hoursAgo: 300)
        try write([assistant(id: "new", request: "r")], to: "-Users-me-proj/new.jsonl", hoursAgo: 1)
        let collector = makeCollector()

        let report = collector.collect(sinceHoursAgo: 720, now: now)
        XCTAssertEqual(report.entries, fullParse(hours: 720))
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(collector.cachedFileCount, 1, "只缓存 180 小时以内的")

        let again = collector.collect(sinceHoursAgo: 720, now: now)
        XCTAssertEqual(again.parsedFiles, 1, "旧文件每次都解析")
        XCTAssertEqual(again.reusedFiles, 1)
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries, fullParse(hours: 180))
    }

    /// 报表窗口比保留窗口短（7 天 = 168 小时）：落在 168–180 小时之间的文件这一轮不解析，缓存照留，下次菜单刷新直接用。
    func testShorterReportWindowKeepsCachedFilesBetweenTheTwoWindows() throws {
        try write([assistant(id: "edge", request: "r")], to: "-Users-me-proj/edge.jsonl", hoursAgo: 175)
        let collector = makeCollector()
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).parsedFiles, 1)

        let week = collector.collect(sinceHoursAgo: 168, now: now)
        XCTAssertEqual(week.entries, fullParse(hours: 168))
        XCTAssertEqual(week.entries.count, 0)
        XCTAssertEqual(collector.cachedFileCount, 1)

        let menu = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(menu.parsedFiles, 0)
        XCTAssertEqual(menu.reusedFiles, 1)
        XCTAssertEqual(menu.entries, fullParse(hours: 180))
    }

    /// 读不了的文件这次跳过、不进缓存，能读了下次照常算进来（修改时间没变也一样）。
    func testUnreadableFileIsSkippedAndRetriedLater() throws {
        let url = try write([assistant(id: "a1", request: "r")], to: "-Users-me-proj/a.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let collector = makeCollector()

        let blocked = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(blocked.entries, fullParse(hours: 180))
        XCTAssertEqual(blocked.entries.count, 0)
        XCTAssertEqual(collector.cachedFileCount, 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let readable = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(readable.entries.count, 1)
        XCTAssertEqual(readable.entries, fullParse(hours: 180))
    }

    /// 隐藏项目、隐藏文件、别的扩展名、名叫 x.jsonl 的目录、直接放在 projects 下的文件：和全量解析一样跳过。
    func testNonSessionEntriesAreIgnoredLikeTheFullParse() throws {
        try write([assistant(id: "ok", request: "r")], to: "-Users-me-proj/a.jsonl")
        try write([assistant(id: "hidden-file", request: "r")], to: "-Users-me-proj/.hidden.jsonl")
        try write([assistant(id: "hidden-dir", request: "r")], to: ".hidden-proj/a.jsonl")
        try write([assistant(id: "txt", request: "r")], to: "-Users-me-proj/notes.txt")
        try write([assistant(id: "stray", request: "r")], to: "stray.jsonl")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-me-proj/dir.jsonl"),
                                                withIntermediateDirectories: true)
        let collector = makeCollector()

        let collected = collector.collect(sinceHoursAgo: 180, now: now)
        XCTAssertEqual(collected.entries, fullParse(hours: 180))
        XCTAssertEqual(collected.entries.count, 1)
        XCTAssertEqual(collector.collect(sinceHoursAgo: 180, now: now).entries, collected.entries)
    }

    // MARK: - 差分：增量连续刷新若干轮 vs 每轮全量解析

    /// 随机改动（固定种子，可复现）：新建、追加（含跨文件的重复用量）、改写变小、打乱行序（同样大小）、删除、过期、回到窗口、只改修改时间。
    /// 每轮比一次菜单刷新（180 小时）；每 10 轮再比一次报表窗口（720 小时），之后的菜单刷新照样要对。
    func testIncrementalMatchesTheFullParseAcrossRandomEdits() throws {
        var rng = FixtureRNG(seed: 0x5EED_0109)
        let projects = ["-Users-me-proj", "-Users-me-other", "-Users-me-third"]
        var files: [URL: [String]] = [:]
        var aged = Set<URL>()
        let collector = makeCollector()
        var totalReused = 0
        var totalParsed = 0

        for round in 0..<60 {
            let editCount = round == 0 ? 6 : Int.random(in: 1...3, using: &rng)
            for _ in 0..<editCount {
                let existing = files.keys.sorted { $0.path < $1.path }
                let pick = existing.randomElement(using: &rng)
                switch files.isEmpty ? 0 : Int.random(in: 0..<8, using: &rng) {
                case 0:   // 新建
                    let project = projects.randomElement(using: &rng) ?? projects[0]
                    let lines = (0..<Int.random(in: 1...8, using: &rng)).map { _ in randomLine(&rng) }
                    let url = try write(lines, to: "\(project)/s\(round)-\(Int.random(in: 0..<1_000, using: &rng)).jsonl")
                    files[url] = lines
                case 1:   // 追加
                    guard let url = pick, var lines = files[url] else { continue }
                    let more = (0..<Int.random(in: 1...4, using: &rng)).map { _ in randomLine(&rng) }
                    try append(more, to: url, hoursAgo: aged.contains(url) ? 200 : 1)
                    lines += more
                    files[url] = lines
                case 2:   // 改写变小
                    guard let url = pick, let lines = files[url], lines.count > 1 else { continue }
                    let kept = lines.filter { _ in Bool.random(using: &rng) }
                    try rewrite(url, kept, hoursAgo: aged.contains(url) ? 200 : 1)
                    files[url] = kept
                case 3:   // 打乱行序：大小不变、内容变了（修改时间也变）
                    guard let url = pick, let lines = files[url] else { continue }
                    let shuffled = lines.shuffled(using: &rng)
                    try rewrite(url, shuffled, hoursAgo: aged.contains(url) ? 200 : 1)
                    files[url] = shuffled
                case 4:   // 删除
                    guard let url = pick else { continue }
                    try FileManager.default.removeItem(at: url)
                    files[url] = nil
                    aged.remove(url)
                case 5:   // 过期（修改时间挪到 200 小时前）
                    guard let url = pick else { continue }
                    try setModified(url, hoursAgo: 200)
                    aged.insert(url)
                case 6:   // 回到窗口里
                    guard let url = aged.sorted(by: { $0.path < $1.path }).randomElement(using: &rng) else { continue }
                    try setModified(url, hoursAgo: 1)
                    aged.remove(url)
                default:  // 只改修改时间
                    guard let url = pick else { continue }
                    try setModified(url, hoursAgo: aged.contains(url) ? 200 : 1)
                }
            }

            let collected = collector.collect(sinceHoursAgo: 180, now: now)
            totalReused += collected.reusedFiles
            totalParsed += collected.parsedFiles
            XCTAssertEqual(collected.entries, fullParse(hours: 180), "第 \(round) 轮")
            if round % 10 == 9 {
                XCTAssertEqual(collector.collect(sinceHoursAgo: 720, now: now).entries, fullParse(hours: 720), "第 \(round) 轮（报表窗口）")
            }
        }
        XCTAssertGreaterThan(totalReused, totalParsed, "缓存确实在用：直接复用的文件比重新解析的多")
    }

    /// 菜单刷新与报表同时在跑：结果都与全量解析一致（缓存的读写在锁里）。
    func testConcurrentCollectionsAgreeWithTheFullParse() throws {
        var rng = FixtureRNG(seed: 42)
        for index in 0..<6 {
            let lines = (0..<20).map { _ in randomLine(&rng) }
            try write(lines, to: "-Users-me-proj/c\(index).jsonl", hoursAgo: index.isMultiple(of: 3) ? 300 : 1)
        }
        let collector = makeCollector()
        let expected = (menu: fullParse(hours: 180), report: fullParse(hours: 720))
        let results = ResultBox(count: 16)
        let now = self.now

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let entries = collector.collect(sinceHoursAgo: index.isMultiple(of: 2) ? 180 : 720, now: now).entries
            results.set(index, entries)
        }
        for index in 0..<16 {
            XCTAssertEqual(results.get(index), index.isMultiple(of: 2) ? expected.menu : expected.report, "#\(index)")
        }
    }

    // MARK: - 基准：改动前的全量解析（原样拷贝）

    /// 改动前 `ClaudeUsageStore.collectEntries(sinceHoursAgo:)` 的原样拷贝，只把根目录、「现在」、目录名 → 路径改成参数。
    private func fullParse(hours: Int) -> [CLIUsageEntry] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(hours) * 3_600)
        var entries: [CLIUsageEntry] = []
        var seenKeys = Set<String>()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mungedName = projectDir.lastPathComponent
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff { continue }
                autoreleasepool {
                    guard let data = try? Data(contentsOf: file) else { return }

                    for lineData in data.split(separator: 0x0A) {
                        guard let object = CLIJSONL.parseObject(Data(lineData)),
                              (object["type"] as? String) == "assistant",
                              let message = object["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { continue }

                        let messageID = message["id"] as? String
                        let requestID = object["requestId"] as? String
                        if let messageID, let requestID {
                            let key = messageID + "|" + requestID
                            if seenKeys.contains(key) { continue }
                            seenKeys.insert(key)
                        } else if let messageID {
                            if seenKeys.contains(messageID) { continue }
                            seenKeys.insert(messageID)
                        }

                        let ts = object["timestamp"] as? String
                        let date = ts.flatMap { CLIJSONL.parseDate($0) } ?? mtime ?? Date()
                        let modelID = message["model"] as? String ?? ""
                        let projectPath = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            ?? Self.demunge(mungedName)

                        entries.append(CLIUsageEntry(
                            timestamp: date,
                            modelID: modelID,
                            projectPath: projectPath,
                            input: CLIUsageEntry.tokenCount(usage["input_tokens"]),
                            output: CLIUsageEntry.tokenCount(usage["output_tokens"]),
                            cacheWrite: CLIUsageEntry.tokenCount(usage["cache_creation_input_tokens"]),
                            cacheRead: CLIUsageEntry.tokenCount(usage["cache_read_input_tokens"])
                        ))
                    }
                }
            }
        }
        return entries
    }

    // MARK: - 夹具

    private static func demunge(_ dir: String) -> String {
        dir.replacingOccurrences(of: "-", with: "/")
    }

    private func makeCollector() -> ClaudeUsageCollector {
        ClaudeUsageCollector(projectsDir: root, retentionHours: 180, fallbackProjectPath: { Self.demunge($0) })
    }

    private func parse(_ lines: [String], mtime: Date? = nil, fallbackProjectPath: String = "/p") -> [ClaudeUsageCollector.Candidate] {
        ClaudeUsageCollector.candidates(in: Data((lines.joined(separator: "\n") + "\n").utf8),
                                        mtime: mtime ?? now, fallbackProjectPath: fallbackProjectPath)
    }

    /// 同一个项目目录里的两个文件按收集器的遍历顺序排好（与它、与基准同样的列目录调用；比文件名，不比路径前缀）。
    private func ordered(_ first: URL, _ second: URL) throws -> (earlier: URL, later: URL) {
        let names = try FileManager.default.contentsOfDirectory(
            at: first.deletingLastPathComponent(),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent)
        let firstIndex = try XCTUnwrap(names.firstIndex(of: first.lastPathComponent))
        let secondIndex = try XCTUnwrap(names.firstIndex(of: second.lastPathComponent))
        return firstIndex < secondIndex ? (first, second) : (second, first)
    }

    /// 写一个会话文件（覆盖），修改时间设成 now 往前 `hoursAgo` 小时、再加一个递增的秒数。
    @discardableResult
    private func write(_ lines: [String], to relativePath: String, hoursAgo: Double = 1) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rewrite(url, lines, hoursAgo: hoursAgo)
        return url
    }

    private func rewrite(_ url: URL, _ lines: [String], hoursAgo: Double) throws {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        try setModified(url, hoursAgo: hoursAgo)
    }

    private func append(_ lines: [String], to url: URL, hoursAgo: Double = 1) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try setModified(url, hoursAgo: hoursAgo)
    }

    private func setModified(_ url: URL, hoursAgo: Double) throws {
        mtimeTick += 1
        let date = now.addingTimeInterval(-hoursAgo * 3_600 + mtimeTick)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// 一行带 usage 的 assistant（JSON，键排好序）。nil 的字段不写。
    private func assistant(id: String?, request: String?, model: String? = "claude-sonnet-4-5", cwd: String? = "/Users/me/proj",
                           timestamp: String? = "2026-11-10T03:00:00.000Z",
                           input: Any = 10, output: Any = 20, cacheWrite: Any = 30, cacheRead: Any = 40) -> String {
        var message: [String: Any] = [
            "usage": ["input_tokens": input, "output_tokens": output,
                      "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead],
            "content": [["type": "text", "text": "hello"]],
        ]
        if let id { message["id"] = id }
        if let model { message["model"] = model }
        var object: [String: Any] = ["type": "assistant", "sessionId": "s", "message": message]
        if let request { object["requestId"] = request }
        if let cwd { object["cwd"] = cwd }
        if let timestamp { object["timestamp"] = timestamp }
        return json(object)
    }

    private func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 随机一行：大多是用量（去重键从一个小池子里抽，跨文件重复；也有只有 message.id 的、什么都没有的），夹着别的行和坏行。
    private func randomLine(_ rng: inout FixtureRNG) -> String {
        switch Int.random(in: 0..<12, using: &rng) {
        case 0:
            return json(["type": "user", "message": ["content": "q"]])
        case 1:
            return "{broken"
        default:
            let pool = ["d1", "d2", "d3", "d4", "d5"]
            let id: String?
            let request: String?
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: (id, request) = (nil, nil)
            case 1: (id, request) = (pool.randomElement(using: &rng), nil)
            case 2: (id, request) = ("u\(rng.next() % 100_000)", "r")
            default: (id, request) = (pool.randomElement(using: &rng), "r")
            }
            let timestamp: String? = Int.random(in: 0..<8, using: &rng) == 0
                ? nil
                : Self.isoFormatter.string(from: now.addingTimeInterval(-Double.random(in: 0...(200 * 3_600), using: &rng)))
            let cwd = ["/Users/me/proj", "/Users/me/other", "", nil].randomElement(using: &rng) ?? nil
            let model = ["claude-opus-4-5-20251101", "claude-sonnet-4-5", "claude-haiku-4-5", "mystery", nil]
                .randomElement(using: &rng) ?? nil
            let output: Any = Int.random(in: 0..<10, using: &rng) == 0 ? "77" as Any : Int.random(in: 0...5_000, using: &rng) as Any
            return assistant(id: id, request: request, model: model, cwd: cwd, timestamp: timestamp,
                             input: Int.random(in: 0...5_000, using: &rng), output: output,
                             cacheWrite: Int.random(in: 0...5_000, using: &rng), cacheRead: Int.random(in: 0...50_000, using: &rng))
        }
    }
}

/// 固定种子的随机数（SplitMix64），差分测试可复现。
private struct FixtureRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 并发测试收结果用。
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[CLIUsageEntry]]

    init(count: Int) {
        values = Array(repeating: [], count: count)
    }

    func set(_ index: Int, _ entries: [CLIUsageEntry]) {
        lock.lock()
        values[index] = entries
        lock.unlock()
    }

    func get(_ index: Int) -> [CLIUsageEntry] {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}
