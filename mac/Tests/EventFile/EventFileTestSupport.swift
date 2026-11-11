import Foundation
import XCTest

/// 事件文件测试的小工具。文件一律建在系统临时目录下每个测试自己的随机目录里，用完删掉，
/// 不碰真实的事件文件（`~/Library/Application Support/Baobox/ClaudeCode/events.jsonl` 之类）。
enum EventFileTestSupport {
    /// 建一个空的临时目录，测试结束时删掉。
    static func makeSandbox(for testCase: XCTestCase) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaoboxEventFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// 像 hook / notify 脚本的 `>>` 一样追加（一次 write）。
    static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    /// 和脚本的 `printf … >> 文件` 一模一样：`O_CREAT | O_APPEND` 打开（没有就建出来，不截断、不替换），写一次，关掉。
    /// 目录不在就写不进去（Codex 的 notify 脚本不 `mkdir -p`）。
    static func appendLikeShell(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw POSIXError(.EIO) }
    }

    /// 本进程现在打开着的、路径落在 `directory` 下的描述符个数（文件和目录都算）。`directory` 是测试自己的随机目录，
    /// 别的测试、XCTest 自己开着的描述符不会混进来。
    static func openDescriptorCount(under directory: URL) -> Int {
        let marker = "/" + directory.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        var count = 0
        for name in names {
            guard let fd = Int32(name) else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { continue }
            if String(cString: path).contains(marker) { count += 1 }
        }
        return count
    }

    static func bytes(of url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    /// 转当前线程的 run loop（主线程上就是处理排进主队列的回调），直到条件成立或超时。
    @discardableResult
    static func spin(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// 什么也不等，单纯转一会儿 run loop：用来确认「这段时间里没有回调」。
    static func settle(for interval: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }

    /// 追加 `text`，直到 `delivered()` 成立或超时。
    ///
    /// 监听器的 `start()` 是异步的（在它自己的队列上打开文件），开始监听之前写进去的内容要等下一次写入才会被读到；
    /// 交不出来时再追加一个空行催一下 —— 空行不算一行，不会多交出东西。
    @discardableResult
    static func append(_ text: String, to url: URL, timeout: TimeInterval = 5,
                       until delivered: () -> Bool) throws -> Bool {
        try append(text, to: url)
        let deadline = Date().addingTimeInterval(timeout)
        while !delivered() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if !delivered() {
                try append("\n", to: url)
            }
        }
        return true
    }
}

/// 收集回调交出来的行，任意线程可调（监听器在自己的队列上回调）。
final class EventFileLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    /// 每次回调一批。
    var batches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var lines: [String] { batches.flatMap { $0 } }

    func record(_ lines: [String]) {
        lock.lock()
        recorded.append(lines)
        lock.unlock()
    }
}
