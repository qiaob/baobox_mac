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

    /// 现状，PR4 会修（docs/codex-assistant/DEDUPE.md §5.2 C1）：一行分两次写、监听恰好在两次之间读了一次 →
    /// 两截各自当成一行交出去（调用方解析 JSON 都失败，这条事件就丢了）。修好后应只交一次完整的 `{"a":1}` —— 届时把断言翻过来。
    func testHandsOutALineWrittenInTwoPiecesAsTwoFragments() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("ready\n", to: url) { recorder.lines == ["ready"] })

        try Support.append("{\"a\":", to: url)
        XCTAssertTrue(Support.spin { recorder.batches.count >= 2 })
        try Support.append("1}\n", to: url)
        XCTAssertTrue(Support.spin { recorder.batches.count >= 3 })

        XCTAssertEqual(recorder.batches, [["ready"], ["{\"a\":"], ["1}"]])
    }

    /// 现状，PR4 会修（§5.2 C1）：同一次读到的内容里只要有一处不是合法 UTF-8（比如切在汉字中间），整批都解不出来，
    /// 同一批里写完整了的行也一起丢掉。这里把完整的一行和坏字节放在同一次写入里，不论监听什么时候醒来，那一行都交不出来；
    /// 之后的行照常交出。修好后 `complete` 应该照常交出 —— 届时把断言翻过来。
    func testLosesACompleteLineReadInTheSameBatchAsABrokenCharacter() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let recorder = EventFileLineRecorder()
        _ = makeWatcher(url, startOffset: 0, recorder: recorder)
        XCTAssertTrue(try Support.append("ready\n", to: url) { recorder.lines == ["ready"] })

        var chunk = Data("{\"complete\":1}\n{\"t\":\"".utf8)
        chunk.append(contentsOf: [0xE6, 0x88])   // 「成」的前两个字节，第三个字节永远不来
        chunk.append(Data("\"}\n".utf8))
        try Support.append(chunk, to: url)
        var next = 0
        let delivered = Support.spin {
            if recorder.lines.contains(where: { $0.hasPrefix("{\"next\"") }) { return true }
            next += 1
            try? Support.append("{\"next\":\(next)}\n", to: url)
            Support.settle(for: 0.05)
            return false
        }

        XCTAssertTrue(delivered, "坏字节之后写的行照常交出")
        XCTAssertFalse(recorder.lines.contains("{\"complete\":1}"))
    }
}
