import Foundation
import XCTest

/// 回放 + 跟随：后台准备、主线程回放已有行、再跟随新行；启停竞态的收紧（docs/codex-assistant/DEDUPE.md §2、§5.2 C3）。
@MainActor
final class EventFileFollowerTests: XCTestCase {

    private typealias Support = EventFileTestSupport

    /// 回调按到达顺序记下来：`replay:<行>` / `follow:<行>`。
    private final class Log {
        var entries: [String] = []
        var replayCalls = 0
        var replayed: [String] { entries.filter { $0.hasPrefix("replay:") } }
        var followed: [String] { entries.filter { $0.hasPrefix("follow:") } }
    }

    private func makeFollower(_ url: URL, limits: EventFileLog.Limits = .init(maxBytes: 1_024, keepTailLines: 100))
        -> EventFileFollower {
        let follower = EventFileFollower(url: url, limits: limits, queueLabel: "com.baobox.tests.eventfollower")
        addTeardownBlock { @MainActor in follower.stop() }
        return follower
    }

    private func start(_ follower: EventFileFollower, log: Log) {
        follower.start(
            replay: { lines in
                log.replayCalls += 1
                log.entries += lines.map { "replay:" + $0 }
            },
            follow: { lines in
                log.entries += lines.map { "follow:" + $0 }
            }
        )
    }

    func testReplaysTheExistingLinesThenFollowsNewOnes() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("a\n\nb\n", to: url)
        let follower = makeFollower(url)
        let log = Log()

        start(follower, log: log)
        XCTAssertTrue(follower.isStarted, "start() 立即记已启动，不等后台读完")
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertEqual(log.entries, ["replay:a", "replay:b"])

        XCTAssertTrue(try Support.append("c\n", to: url) { log.followed.count >= 1 })
        XCTAssertEqual(log.entries, ["replay:a", "replay:b", "follow:c"], "回放先于跟随，已有的行不会再当新行交一次")
    }

    func testCreatesAMissingFileAndFollowsIt() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("Baobox/ClaudeCode/events.jsonl")
        let follower = makeFollower(url)
        let log = Log()

        start(follower, log: log)
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertEqual(log.replayCalls, 1)
        XCTAssertEqual(log.entries, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertTrue(try Support.append("first\n", to: url) { log.followed.count >= 1 })
        XCTAssertEqual(log.entries, ["follow:first"])
    }

    func testTruncatesAnOversizedFileBeforeReplaying() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write((1...10).map { "line \($0)\n" }.joined(), to: url)
        let follower = makeFollower(url, limits: .init(maxBytes: 20, keepTailLines: 3))
        let log = Log()

        start(follower, log: log)
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertEqual(log.entries, ["replay:line 8", "replay:line 9", "replay:line 10"])
        XCTAssertEqual(Support.bytes(of: url), Data("line 8\nline 9\nline 10\n".utf8))

        XCTAssertTrue(try Support.append("line 11\n", to: url) { log.followed.count >= 1 })
        XCTAssertEqual(log.followed, ["follow:line 11"], "从截断后的大小起跟随")
    }

    func testStartWhileStartedIsIgnored() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("a\n", to: url)
        let follower = makeFollower(url)
        let log = Log()

        start(follower, log: log)
        start(follower, log: log)   // 后台还没读完时再调（原来会建出第二个监听器）
        XCTAssertTrue(Support.spin { follower.isFollowing })
        start(follower, log: log)   // 跟随中再调
        XCTAssertTrue(try Support.append("b\n", to: url) { log.followed.count >= 1 })
        Support.settle()

        XCTAssertEqual(log.replayCalls, 1)
        XCTAssertEqual(log.entries, ["replay:a", "follow:b"], "每行只交一次")
    }

    func testStopBeforeTheBackgroundReadFinishesReplaysNothingAndCreatesNoWatcher() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("a\n", to: url)
        let follower = makeFollower(url)
        let log = Log()

        start(follower, log: log)
        follower.stop()   // 同一个主线程回合里：后台准备完回到主线程时这一轮已经作废
        XCTAssertFalse(follower.isStarted)
        Support.settle()
        try Support.append("b\n", to: url)
        Support.settle()

        XCTAssertFalse(follower.isFollowing)
        XCTAssertEqual(log.replayCalls, 0)
        XCTAssertEqual(log.entries, [])
    }

    func testStopDropsLinesAlreadyQueuedForTheMainThread() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("", to: url)
        let follower = makeFollower(url)
        let log = Log()
        start(follower, log: log)
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertTrue(try Support.append("ready\n", to: url) { log.followed.count >= 1 })

        try Support.append("late\n", to: url)
        Thread.sleep(forTimeInterval: 0.5)   // 主线程不转：监听器读到这一行，回调排进主队列等着
        follower.stop()
        Support.settle()

        XCTAssertEqual(log.entries, ["follow:ready"], "stop() 之后排在主队列里的新行不再交出")
    }

    func testStartAfterStopReplaysTheWholeFileAgainAndFollowsOnce() throws {
        let root = try Support.makeSandbox(for: self)
        let url = root.appendingPathComponent("events.jsonl")
        try Support.write("a\n", to: url)
        let follower = makeFollower(url)
        let first = Log()
        start(follower, log: first)
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertTrue(try Support.append("b\n", to: url) { first.followed.count >= 1 })

        follower.stop()
        let second = Log()
        start(follower, log: second)
        follower.stop()             // 停 → 启 → 停 → 启 挤在同一个回合：只有最后一轮算数
        start(follower, log: second)
        XCTAssertTrue(Support.spin { follower.isFollowing })
        XCTAssertEqual(second.replayCalls, 1)
        XCTAssertEqual(second.entries, ["replay:a", "replay:b"])

        XCTAssertTrue(try Support.append("c\n", to: url) { second.followed.count >= 1 })
        Support.settle()
        XCTAssertEqual(second.entries, ["replay:a", "replay:b", "follow:c"])
        XCTAssertEqual(first.entries, ["replay:a", "follow:b"], "停掉的那一轮不再收到新行")
    }
}
