import Foundation
import XCTest

/// 派生数据的磁盘缓存文件（#164 PR6，docs/codex-assistant/DEDUPE-P2.md §2.4 类 7）：flush 同步写完、文件 = 默认 JSONEncoder 的输出、
/// 防抖合并多次落盘且到点才取快照、flush 取消排着的落盘、排在前面的旧快照不会盖掉 flush 写的新快照（串行写盘）、
/// 没有文件时不读不写、坏文件读回 nil、主人不在了就不写。都在临时目录里做，防抖传零点几秒；
/// 防抖经 `DispatchQueue.main` 到点，测试转主线程 RunLoop 等它（`spinMainRunLoop` 在 CLISessionTestSupport.swift）。
@MainActor
final class CLICacheFileTests: XCTestCase {

    // MARK: - 夹具

    /// 临时目录下的缓存文件（父目录还不存在：写盘时现建）。
    private func cacheURL() throws -> URL {
        try makeSessionTestDirectory(self)
            .appendingPathComponent("support", isDirectory: true)
            .appendingPathComponent("cache.json")
    }

    private func makeFile(_ url: URL?, debounce: TimeInterval = 0.1) -> CLICacheFile<[String: CacheTestRecord]> {
        CLICacheFile(url: url, queueLabel: "com.baobox.tests.clicachefile", debounce: debounce)
    }

    /// 盘上的快照；没有文件或解不开时为 nil。
    private func stored(_ url: URL) -> [String: CacheTestRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: CacheTestRecord].self, from: data)
    }

    private func snapshot(_ titles: String...) -> [String: CacheTestRecord] {
        Dictionary(uniqueKeysWithValues: titles.enumerated().map { offset, title in
            ("/work/app/\(title).jsonl", CacheTestRecord(modified: 1_794_297_600 + Double(offset), size: Int64(offset), title: title))
        })
    }

    // MARK: - 读写

    func testFlushHasWrittenTheFileWhenItReturnsAndANewInstanceLoadsIt() throws {
        let url = try cacheURL()
        let file = makeFile(url)

        file.flush(snapshot("修登录页", "写周报"))

        XCTAssertEqual(stored(url), snapshot("修登录页", "写周报"), "flush 返回时已经写好，父目录也建了")
        XCTAssertEqual(file.load(), snapshot("修登录页", "写周报"))
        XCTAssertEqual(makeFile(url).load(), snapshot("修登录页", "写周报"), "下次启动（新实例）从它读起")
    }

    func testTheFileIsWhatTheDefaultJSONEncoderWrites() throws {
        // 缓存文件的格式不变（与抽出来之前同一种写法），升级后旧缓存照读，不用全量重扫。
        // 默认 JSONEncoder 不排键：同一个值编两次，对象里键的先后都可能不同（字典的遍历顺序每个实例不一样），
        // 所以比的是长度（同样紧凑、同样的数字与字符串写法）和解出来的 JSON 对象。
        let url = try cacheURL()
        let value = snapshot("a", "b", "c")

        makeFile(url).flush(value)

        let written = try Data(contentsOf: url)
        let expected = try JSONEncoder().encode(value)
        XCTAssertEqual(written.count, expected.count)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: written) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
    }

    func testAMissingOrUnreadableFileLoadsAsNil() throws {
        let url = try cacheURL()
        XCTAssertNil(makeFile(url).load(), "还没有文件")

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(makeFile(url).load(), "坏文件当没有")

        try Data(#"{"/work/app/a.jsonl": {"title": "缺字段"}}"#.utf8).write(to: url)
        XCTAssertNil(makeFile(url).load(), "形状不对（旧格式）也当没有")
    }

    // MARK: - 防抖落盘

    func testSavesWithinTheDebounceCollapseIntoOneWriteOfTheLatestSnapshot() throws {
        let url = try cacheURL()
        let file = makeFile(url)
        let owner = CacheTestOwner(snapshot("一"))

        file.scheduleSave { owner.take() }
        owner.value = snapshot("一", "二")
        file.scheduleSave { owner.take() }
        owner.value = snapshot("一", "二", "三")
        file.scheduleSave { owner.take() }
        XCTAssertNil(stored(url), "防抖期内不写")

        spinMainRunLoop { self.stored(url) != nil }
        spinMainRunLoop(for: 0.3)   // 前两次要是没被取消，这时也该到点了

        XCTAssertEqual(stored(url), snapshot("一", "二", "三"))
        XCTAssertEqual(owner.takes, 1, "三次合并成一次，快照只取一次")
    }

    func testAScheduledSaveTakesTheSnapshotWhenItFires() throws {
        let url = try cacheURL()
        let file = makeFile(url)
        let owner = CacheTestOwner(snapshot("排的时候"))

        file.scheduleSave { owner.take() }
        owner.value = snapshot("到点的时候")
        spinMainRunLoop { self.stored(url) != nil }

        XCTAssertEqual(stored(url), snapshot("到点的时候"), "到点才取快照（期间的改动一起写下）")
    }

    func testFlushCancelsThePendingSave() throws {
        let url = try cacheURL()
        let file = makeFile(url)
        let owner = CacheTestOwner(snapshot("排着的"))

        file.scheduleSave { owner.take() }
        file.flush(snapshot("退出时的"))
        XCTAssertEqual(stored(url), snapshot("退出时的"))

        spinMainRunLoop(for: 0.3)   // 过了防抖
        XCTAssertEqual(stored(url), snapshot("退出时的"), "排着的那次取消了，不会在 flush 之后再写一遍")
        XCTAssertEqual(owner.takes, 0)
    }

    /// #170（DEDUPE.md §5.2 C6）：防抖到点的那次已经在写盘队列上写着旧快照，这时退出 flush 新快照 ——
    /// 写盘队列是串行的，flush 等旧的写完才写，旧快照不会反过来盖掉新的（并发队列上会：最近文件索引原来就是这样）。
    func testAnOlderQueuedWriteNeverOverwritesAFlush() throws {
        let url = try cacheURL()
        let file = CLICacheFile<GatedSnapshot>(url: url, queueLabel: "com.baobox.tests.clicachefile.gated", debounce: 0.05)
        let gate = EncodeGate()

        file.scheduleSave { GatedSnapshot(label: "旧", gate: gate) }
        spinMainRunLoop { gate.isEncoding }   // 防抖到点：旧快照在写盘队列上编码到一半，停住
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.release() }
        file.flush(GatedSnapshot(label: "新", gate: nil))

        XCTAssertEqual(storedLabel(url), "新", "flush 返回时：旧的先写完，新的后写")
        spinMainRunLoop(for: 0.5)
        XCTAssertEqual(storedLabel(url), "新", "旧快照没有反过来盖掉新的")
    }

    private func storedLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(GatedSnapshot.self, from: data))?.label
    }

    // MARK: - 不写的情况

    func testWithoutAURLNothingIsReadOrWritten() throws {
        let directory = try makeSessionTestDirectory(self)
        let file = makeFile(nil, debounce: 0.05)
        let owner = CacheTestOwner(snapshot("a"))

        XCTAssertNil(file.load())
        file.scheduleSave { owner.take() }
        file.flush(snapshot("b"))
        spinMainRunLoop(for: 0.3)

        XCTAssertEqual(owner.takes, 0, "防抖都没排")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], "什么也没写")
    }

    func testASaveWhoseOwnerIsGoneWritesNothing() throws {
        // 调用方弱引用自己：索引释放了，排着的那次到点也不写（同抽出来之前）。
        let url = try cacheURL()
        let file = makeFile(url, debounce: 0.05)

        file.scheduleSave { nil }
        spinMainRunLoop(for: 0.3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - 测试用的快照

/// 缓存记录的样子（同会话索引：修改时间、大小、再加几个字段）。
struct CacheTestRecord: Codable, Sendable, Equatable {
    let modified: Double
    let size: Int64
    let title: String
}

/// 缓存的主人：防抖到点时取它的当前值，并记下取了几次。
@MainActor
final class CacheTestOwner {
    var value: [String: CacheTestRecord]
    private(set) var takes = 0

    init(_ value: [String: CacheTestRecord]) {
        self.value = value
    }

    func take() -> [String: CacheTestRecord]? {
        takes += 1
        return value
    }
}

/// 编码时可以停住的快照：复现「旧快照已经交给写盘队列、还没写完」。`gate` 不编码。
struct GatedSnapshot: Codable, Sendable {
    let label: String
    let gate: EncodeGate?

    init(label: String, gate: EncodeGate?) {
        self.label = label
        self.gate = gate
    }

    private enum CodingKeys: String, CodingKey { case label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        gate = nil
    }

    func encode(to encoder: Encoder) throws {
        gate?.stopHere()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
    }
}

/// 停住一次编码，直到测试放行。
final class EncodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private let released = DispatchSemaphore(value: 0)

    /// 写盘队列已经在编码、停在这里了。
    var isEncoding: Bool { lock.withLock { reached } }

    func release() {
        released.signal()
    }

    /// 写盘队列上：记下已停住，等放行（最多 10 秒，测试失败时不至于一直卡住）。
    fileprivate func stopHere() {
        lock.withLock { reached = true }
        _ = released.wait(timeout: .now() + 10)
    }
}
