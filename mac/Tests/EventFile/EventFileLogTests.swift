import Foundation
import XCTest

/// 事件文件的维护：建文件、超限截断、读全部。
final class EventFileLogTests: XCTestCase {

    private typealias Support = EventFileTestSupport

    // MARK: - prepare

    func testPrepareCreatesTheDirectoryAndAnEmptyFile() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("Baobox/AITools/codex-events.jsonl")

        EventFileLog.prepare(url, limits: .init(maxBytes: 100, keepTailLines: 10))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Support.bytes(of: url), Data())
    }

    func testPrepareLeavesAFileWithinTheLimitAlone() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        let original = Data("a\n\nb".utf8)   // 5 字节：空行、末尾没换行都原样留着
        try Support.write(original, to: url)

        EventFileLog.prepare(url, limits: .init(maxBytes: 5, keepTailLines: 1))   // 正好等于上限不算超

        XCTAssertEqual(Support.bytes(of: url), original)
    }

    func testPrepareKeepsOnlyTheLastLinesOnceOverTheLimit() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        var original = Data("1\n2\n\n3\n4\n".utf8)
        original.append(contentsOf: [0x7B, 0xE6, 0x88, 0x0A])   // 一行坏的 UTF-8：按字节切，原样保留
        original.append(Data("\n6".utf8))                       // 空行 + 末尾没换行的一行
        try Support.write(original, to: url)

        EventFileLog.prepare(url, limits: .init(maxBytes: 5, keepTailLines: 3))

        var expected = Data("4\n".utf8)
        expected.append(contentsOf: [0x7B, 0xE6, 0x88, 0x0A])
        expected.append(Data("6\n".utf8))
        XCTAssertEqual(Support.bytes(of: url), expected, "空行不算一行也不保留；每行都以换行结尾")
    }

    /// 同一个 URL 实例第二次 prepare 时要看到文件现在的大小（URL 会缓存 resourceValues，follower 停了再启动就是这种情况）。
    func testPrepareSeesTheCurrentSizeWhenTheSameURLIsReused() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        let limits = EventFileLog.Limits(maxBytes: 10, keepTailLines: 1)
        try Support.write("a\n", to: url)

        EventFileLog.prepare(url, limits: limits)
        XCTAssertEqual(Support.bytes(of: url), Data("a\n".utf8))

        try Support.append("bbbbb\ncccccc\n", to: url)
        EventFileLog.prepare(url, limits: limits)

        XCTAssertEqual(Support.bytes(of: url), Data("cccccc\n".utf8))
    }

    // MARK: - readAll

    func testReadAllReturnsTheNonEmptyLinesAndTheSizeInBytes() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        let text = "{\"a\":1}\n\n{\"t\":\"完成\"}\n"
        try Support.write(text, to: url)

        let result = EventFileLog.readAll(url)

        XCTAssertEqual(result.lines, ["{\"a\":1}", "{\"t\":\"完成\"}"])
        XCTAssertEqual(result.size, UInt64(text.utf8.count))
    }

    func testReadAllOfAMissingFileIsEmpty() throws {
        let root = try Support.makeSandbox(for: self)

        let result = EventFileLog.readAll(root.appendingPathComponent("missing.jsonl"))

        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.size, 0)
    }

    /// 现状，PR4 会修（docs/codex-assistant/DEDUPE.md §5.2 C1）：最后一行写到一半、切在汉字中间时整个文件解不成 UTF-8，
    /// 前面完整的行也一起丢了，大小却算到了文件尾。修好后应返回 `["{\"a\":1}"]`、大小只算到最后一个换行（8）—— 届时把断言翻过来。
    func testReadAllLosesEveryLineWhenTheLastOneIsCutInsideACharacter() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        var data = Data("{\"a\":1}\n".utf8)
        data.append(contentsOf: [0xE6, 0x88])   // 「成」（E6 88 90）的前两个字节
        try Support.write(data, to: url)

        let result = EventFileLog.readAll(url)

        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.size, 10)
    }
}
