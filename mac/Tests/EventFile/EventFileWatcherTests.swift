import Foundation
import XCTest

/// 增量监听：DispatchSource 盯 `.write` / `.extend`，从偏移读到文件尾、切成行交出去。真文件、真监听，回调在监听器自己的队列上。
final class EventFileWatcherTests: XCTestCase {

    private typealias Support = EventFileTestSupport

    /// 建一个从 `startOffset` 起监听 `url` 的监听器，交出来的行记进 `recorder`。
    private func makeWatcher(_ url: URL, startOffset: UInt64, recorder: EventFileLineRecorder) -> EventFileWatcher {
        let watcher = EventFileWatcher(url: url, startOffset: startOffset, queueLabel: "com.baobox.tests.eventwatcher") { lines in
            recorder.record(lines)
        }
        watcher.start()
        addTeardownBlock { watcher.stop() }
        return watcher
    }

    func testDeliversTheLinesAppendedAfterTheStartOffset() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("old\n", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 4, recorder: recorder)

        XCTAssertTrue(try Support.append("new 1\nnew 2\n", to: url) { recorder.lines.count >= 2 })
        try Support.append("new 3\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 3 })

        XCTAssertEqual(recorder.lines, ["new 1", "new 2", "new 3"], "偏移之前的行不交；空行不算一行")
    }

    func testStartsOverFromTheTopWhenTheFileGetsShorter() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("aaaa\nbbbb\n", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 10, recorder: recorder)
        XCTAssertTrue(try Support.append("cccc\n", to: url) { recorder.lines == ["cccc"] })

        // 截断（启动时超限清理就是这样原地重写）后写进比原偏移短的内容：偏移归零，从头读。
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("z\n".utf8))
        try handle.close()

        XCTAssertTrue(Support.spin { recorder.lines.count >= 2 })
        XCTAssertEqual(recorder.lines, ["cccc", "z"])
    }

    func testDeliversNothingAfterStop() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        let watcher = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("before\n", to: url) { recorder.lines == ["before"] })

        watcher.stop()
        try Support.append("after\n", to: url)
        Support.settle()
        try Support.append("after again\n", to: url)
        Support.settle()

        XCTAssertEqual(recorder.lines, ["before"])
    }

    // MARK: - 半行与坏字节（docs/codex-assistant/DEDUPE.md §5.2 C1）

    /// 一行分两次写、监听恰好在两次之间读了一次（`drainNow()` 确定性地造出这一刻）：前半截先不交，后半截到了交一次完整的行。
    /// PR2 时两截各自当成一行交出去，调用方解析 JSON 都失败，这条事件就丢了。
    func testKeepsALineWrittenInTwoPiecesUntilItIsComplete() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        let watcher = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("ready\n", to: url) { recorder.lines == ["ready"] })

        try Support.append("{\"a\":", to: url)
        watcher.drainNow()
        XCTAssertEqual(recorder.batches, [["ready"]], "没写完的半行先不交")
        try Support.append("1}\n", to: url)
        XCTAssertTrue(Support.spin { recorder.batches.count >= 2 })

        XCTAssertEqual(recorder.batches, [["ready"], ["{\"a\":1}"]])
    }

    /// 切点落在汉字中间：读到的那一刻最后几个字节不是合法 UTF-8，照样先留着，补齐之后整行交出。
    func testKeepsALineCutInsideACharacterUntilTheRestArrives() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        let watcher = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("ready\n", to: url) { recorder.lines == ["ready"] })

        var head = Data("{\"t\":\"".utf8)
        head.append(contentsOf: [0xE6, 0x88])   // 「成」（E6 88 90）的前两个字节
        try Support.append(head, to: url)
        watcher.drainNow()
        XCTAssertEqual(recorder.batches, [["ready"]])
        var rest = Data([0x90])
        rest.append(Data("\"}\n".utf8))
        try Support.append(rest, to: url)
        XCTAssertTrue(Support.spin { recorder.batches.count >= 2 })

        XCTAssertEqual(recorder.batches, [["ready"], ["{\"t\":\"成\"}"]])
    }

    /// 一次读到几行完整的加半行：完整的一起交，半行留到下次。开始监听时就一次读到（监听器开始时先把已经写进来的读一遍）。
    func testDeliversTheCompleteLinesOfOneReadAndKeepsTheTrailingPiece() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("{\"a\":1}\n{\"b\":2}\n{\"c\":", to: url)
        let recorder = EventFileLineRecorder()
        let watcher = makeWatcher(url, startOffset: 0, recorder: recorder)
        watcher.drainNow()   // start() 已在队列上跑完

        XCTAssertEqual(recorder.batches, [["{\"a\":1}", "{\"b\":2}"]], "两行一起交，半行留着")
        try Support.append("3}\n", to: url)
        XCTAssertTrue(Support.spin { recorder.batches.count >= 2 })

        XCTAssertEqual(recorder.batches, [["{\"a\":1}", "{\"b\":2}"], ["{\"c\":3}"]])
    }

    /// 同一次读到的内容里有一行带坏字节：只丢那一行，同一批里完整的行照常交出（PR2 时整批都解不出来、一起丢）。
    func testABrokenLineDoesNotTakeTheCompleteLinesReadWithItDown() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("ready\n", to: url) { recorder.lines == ["ready"] })

        var chunk = Data("{\"complete\":1}\n{\"t\":\"".utf8)
        chunk.append(contentsOf: [0xE6, 0x88])   // 「成」的前两个字节，第三个字节永远不来
        chunk.append(Data("\"}\n{\"after\":2}\n".utf8))
        try Support.append(chunk, to: url)
        XCTAssertTrue(Support.spin { recorder.lines.contains("{\"after\":2}") })

        XCTAssertEqual(recorder.lines, ["ready", "{\"complete\":1}", "{\"after\":2}"], "只丢坏的那一行")
    }

    // MARK: - 文件被删 / 被换掉之后接着跟随（§5.2 C2）

    func testFollowsTheFileAgainAfterItIsDeletedAndWrittenAgain() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("before\n", to: url) { recorder.lines == ["before"] })

        try FileManager.default.removeItem(at: url)
        try Support.appendLikeShell("after\n", to: url)   // 脚本的 >> 建出一个新文件
        XCTAssertTrue(Support.spin { recorder.lines.count >= 2 })
        try Support.append("after again\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 3 })

        XCTAssertEqual(recorder.lines, ["before", "after", "after again"], "新文件从头读，之后照常跟随")
    }

    /// 整个目录被删（用户清掉了 `Baobox/AITools/`）：监听器把目录建回来 —— Codex 的 notify 脚本不 `mkdir -p`，
    /// 没有目录它的 `>>` 写不进去 —— 等脚本建出文件后接着跟随。
    func testRecreatesTheDirectoryWhenItIsRemovedAndFollowsTheNewFile() throws {
        let root = try Support.makeSandbox(for: self)
        let directory = root.appendingPathComponent("AITools", isDirectory: true)
        let url = directory.appendingPathComponent("codex-events.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("before\n", to: url) { recorder.lines == ["before"] })

        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(Support.spin { FileManager.default.fileExists(atPath: directory.path) }, "目录建回来了")
        try Support.appendLikeShell("after\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 2 })

        XCTAssertEqual(recorder.lines, ["before", "after"])
    }

    /// 文件被换成另一个（原子保存 = 写临时文件再改名盖过去，旧文件收到 `.delete`）：跟随换上来的文件，从头读。
    func testFollowsTheNewFileWhenTheFileIsReplaced() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("before\n", to: url) { recorder.lines == ["before"] })

        try Data("replaced\n".utf8).write(to: url, options: .atomic)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 2 })
        try Support.append("after\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 3 })

        XCTAssertEqual(recorder.lines, ["before", "replaced", "after"])
    }

    /// 文件被改名挪走（`.rename`）：跟随路径上的新文件，挪走的旧文件不再跟。
    func testFollowsThePathAfterTheFileIsRenamedAway() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        let rotated = root.appendingPathComponent("events.jsonl.1")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("before\n", to: url) { recorder.lines == ["before"] })

        try FileManager.default.moveItem(at: url, to: rotated)
        try Support.appendLikeShell("new file\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 2 })
        try Support.append("old file\n", to: rotated)
        try Support.append("new file again\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines.count >= 3 })

        XCTAssertEqual(recorder.lines, ["before", "new file", "new file again"])
    }

    /// 开始监听时文件不在：建回父目录、等文件出现，出现的是新文件 —— 不管 `startOffset` 是多少都从头读。文件本身不由监听器建。
    func testWaitsForAMissingFileAndReadsItFromTheTop() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("Baobox/AITools/codex-events.jsonl")
        let recorder = EventFileLineRecorder()
        let watcher = makeWatcher(url, startOffset: 100, recorder: recorder)
        watcher.drainNow()   // start() 已在队列上跑完

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "父目录建好了")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try Support.appendLikeShell("first\n", to: url)
        XCTAssertTrue(Support.spin { recorder.lines == ["first"] })
    }

    // MARK: - 描述符（DEDUPE.md §6 PR2 第 5 条）

    /// 起 20 个监听器（10 个盯文件、10 个因为文件不在而盯父目录）再停掉、紧接着放掉引用（follower 的 `stop()` 就是这样）：
    /// 描述符全部关掉。PR2 时 `stop()` 排的块弱引用 self，块执行时对象已经没了，一个也不关。
    func testStopClosesEveryDescriptor() throws {
        let root = try Support.makeSandbox(for: self)
        let waiting = root.appendingPathComponent("waiting", isDirectory: true)
        var watchers: [EventFileWatcher] = []
        for index in 0..<10 {
            let url = root.appendingPathComponent("events-\(index).jsonl")
            try Support.write("", to: url)
            watchers.append(EventFileWatcher(url: url, startOffset: 0, queueLabel: "com.baobox.tests.eventwatcher") { _ in })
        }
        for index in 0..<10 {
            let url = waiting.appendingPathComponent("missing-\(index).jsonl")
            watchers.append(EventFileWatcher(url: url, startOffset: 0, queueLabel: "com.baobox.tests.eventwatcher") { _ in })
        }
        watchers.forEach { $0.start() }
        watchers.forEach { $0.drainNow() }   // 都开始监听了
        XCTAssertEqual(Support.openDescriptorCount(under: root), 20)

        watchers.forEach { $0.stop() }
        watchers.removeAll()

        XCTAssertTrue(Support.spin { Support.openDescriptorCount(under: root) == 0 }, "stop() 之后描述符数回落到 0")
    }

    /// 没调 `stop()` 就放掉了监听器：照样关描述符。
    func testReleasingAWatcherWithoutStoppingItClosesItsDescriptor() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        var watcher: EventFileWatcher? = EventFileWatcher(url: url, startOffset: 0, queueLabel: "com.baobox.tests.eventwatcher") { _ in }
        watcher?.start()
        watcher?.drainNow()
        XCTAssertEqual(Support.openDescriptorCount(under: root), 1)

        watcher = nil

        XCTAssertTrue(Support.spin { Support.openDescriptorCount(under: root) == 0 })
    }
}
