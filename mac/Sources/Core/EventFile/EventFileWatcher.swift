import Foundation

/// 事件文件：hook / notify 脚本往一个只追加的文件里一行写一个 JSON，Baobox 启动时回放已有的行、之后跟随新写进来的行。
///
/// Claude Code 助手（`events.jsonl`，见 `ClaudeLiveStatus`）与 Codex 助手（`codex-events.jsonl`，见 `CodexNotify`）共用这一份；
/// 两个模块只留「一行事件怎么处理」。纯 Foundation，不引用任何模块类型，整个目录编进 `BaoboxTests`
/// （docs/codex-assistant/DEDUPE.md §4.2）。
///
/// 已知问题（DEDUPE.md §5.2 C1，PR4 修）：读到的最后一截没写完的行也照样交出去，切点落在多字节字符中间时
/// 同一批读到的行全部丢掉；`readAll` 对最后一行同样如此。这里先原样搬过来，测试把现状钉住。

// MARK: - 增量监听（非 @MainActor，独占后台串行队列）

/// 盯一个只会追加的事件文件，把新写进来的行交出去。
/// 自有串行队列：打开、读取、偏移都只在这个队列上，无需锁；`onLines` 也在这个队列上调（调用方自己切主线程）。
final class EventFileWatcher {
    private let url: URL
    private var offset: UInt64
    private let onLines: ([String]) -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?

    /// `startOffset`：从文件的这个位置往后才算新行（通常 = `EventFileLog.readAll` 读到的大小）。
    init(url: URL, startOffset: UInt64, queueLabel: String, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// `open(O_EVTONLY)` + 监听 `.write` / `.extend`。文件打不开就什么也不做。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = open(self.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: self.queue
            )
            src.setEventHandler { [weak self] in
                self?.drain()
            }
            src.setCancelHandler {
                close(fd)
            }
            self.source = src
            src.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    /// 从上次偏移读到文件末尾，切成行回调。
    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            // 文件被截断（事件文件超限清理）→ 偏移复位。
            if end < offset { offset = 0 }
            guard end > offset else { return }
            try handle.seek(toOffset: offset)
            let data = (try handle.read(upToCount: Int(end - offset))) ?? Data()
            offset = end
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if !lines.isEmpty {
                onLines(lines)
            }
        } catch {
            return
        }
    }
}

// MARK: - 文件维护（任意线程可调）

/// 事件文件的维护：启动时建文件、超限截断，读全部。
enum EventFileLog {
    /// 文件超过 `maxBytes` 字节时，只留最后 `keepTailLines` 行。
    struct Limits: Equatable, Sendable {
        var maxBytes: Int
        var keepTailLines: Int
    }

    /// 建父目录；没有文件就建空文件；超过 `limits.maxBytes` 就只留最后 `limits.keepTailLines` 行（空行不算、不保留）。启动时调一次。
    static func prepare(_ url: URL, limits: Limits) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
            return
        }
        // URL 实例会缓存 resourceValues，在后台线程读进去的缓存一直不过期：同一个 URL 停了再启动时第二次读到的
        // 还是上次的大小。以前每次启动都现算一个新 URL，碰不上；EventFileFollower 存着同一个 URL，先清掉缓存。
        var url = url
        url.removeAllCachedResourceValues()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > limits.maxBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        let tail = lines.suffix(limits.keepTailLines)
        var rebuilt = Data()
        for line in tail {
            rebuilt.append(Data(line))
            rebuilt.append(0x0A)
        }
        try? rebuilt.write(to: url)
    }

    /// 读入全部行与当前大小（供启动时回放 + 设定跟随的起点）。
    static func readAll(_ url: URL) -> (lines: [String], size: UInt64) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, UInt64(data.count))
    }
}

// MARK: - 回放 + 跟随（@MainActor）

/// 后台 `prepare` + `readAll` → 主线程 `replay(已有行)` → 从读到的大小起跟随，新行在主线程交给 `follow`。
///
/// 启停：`start()` 立即记「已启动」，已启动时再调直接返回；`stop()` 之后，后台还没读完的那一轮作废（不回放、不建监听器），
/// 已经排进主线程、还没处理的新行也不再交出去 —— 每次启停换一个代次号，过期的回调对不上号就丢掉。
@MainActor
final class EventFileFollower {
    private let url: URL
    private let limits: EventFileLog.Limits
    private let queueLabel: String
    private var watcher: EventFileWatcher?
    /// 每次 start / stop 加一；回调带着发起时的代次，对不上就是过期的。
    private var generation = 0

    /// `start()` 之后、`stop()` 之前为 true（包括后台还没读完的那一段）。
    private(set) var isStarted = false

    /// 回放完、监听器建好之后为 true。
    var isFollowing: Bool { watcher != nil }

    /// `queueLabel`：监听器串行队列的名字（各模块沿用自己原来的名字）。
    init(url: URL, limits: EventFileLog.Limits, queueLabel: String) {
        self.url = url
        self.limits = limits
        self.queueLabel = queueLabel
    }

    /// `replay`：启动时文件里已有的行（调用方据此重建状态，不发通知）；`follow`：之后新写进来的行。两个都在主线程调，
    /// 回放一定先于跟随。已启动则直接返回。
    func start(replay: @escaping ([String]) -> Void, follow: @escaping ([String]) -> Void) {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let generation = self.generation
        let url = self.url
        let limits = self.limits
        let queueLabel = self.queueLabel
        DispatchQueue.global(qos: .utility).async {
            EventFileLog.prepare(url, limits: limits)
            let (lines, size) = EventFileLog.readAll(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 后台读的这段时间里 stop() 过：这一轮作废。
                    guard self.generation == generation else { return }
                    replay(lines)
                    let watcher = EventFileWatcher(url: url, startOffset: size, queueLabel: queueLabel) { [weak self] newLines in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, self.generation == generation else { return }
                                follow(newLines)
                            }
                        }
                    }
                    watcher.start()
                    self.watcher = watcher
                }
            }
        }
    }

    func stop() {
        isStarted = false
        generation += 1
        watcher?.stop()
        watcher = nil
    }
}
