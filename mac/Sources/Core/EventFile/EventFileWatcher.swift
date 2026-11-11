import Foundation

/// 事件文件：hook / notify 脚本往一个只追加的文件里一行写一个 JSON，Baobox 启动时回放已有的行、之后跟随新写进来的行。
///
/// Claude Code 助手（`events.jsonl`，见 `ClaudeLiveStatus`）与 Codex 助手（`codex-events.jsonl`，见 `CodexNotify`）共用这一份；
/// 两个模块只留「一行事件怎么处理」。纯 Foundation，不引用任何模块类型，整个目录编进 `BaoboxTests`
/// （docs/codex-assistant/DEDUPE.md §4.2）。
///
/// 读行的规矩（DEDUPE.md §5.2 C1）：只消费到最后一个换行，后面没写完的半行留到下一次（脚本的一行可能分几次 `write` 落盘）；
/// 先按字节切行再逐行解码，一行里有坏字节只丢那一行。监听盯的是路径：文件被删 / 被挪走 / 被换成新文件之后，
/// 接着跟随路径上的新文件（§5.2 C2）。

// MARK: - 增量监听（非 @MainActor，独占后台串行队列）

/// 盯一个只会追加的事件文件，把新写进来的完整行交出去。
///
/// 自有串行队列：打开、读取、偏移都只在这个队列上，无需锁；`onLines` 也在这个队列上调（调用方自己切主线程）。
///
/// 盯的是路径而不是打开时的那个文件：收到 `.delete` / `.rename`（被删、被挪走、被别的文件换掉）时先把旧文件剩下的行读完，
/// 再接着盯路径上的新文件、从头读。路径上暂时没有文件时建回父目录（Codex 的 notify 脚本不 `mkdir -p`，目录没了就写不进来），
/// 盯着父目录等文件出现，不轮询。文件本身由脚本的 `>>` 建出来 —— 这里不建：`FileManager.createFile` 遇到已有的文件会整个换掉，
/// 正好撞上脚本刚写的第一行就会把它丢掉。
final class EventFileWatcher {
    private let url: URL
    private var offset: UInt64
    private let onLines: ([String]) -> Void
    private let queue: DispatchQueue
    /// 正在盯的东西：事件文件本身，或者（路径上没有文件时）它的父目录。取消回调里关掉各自的描述符。
    private var source: DispatchSourceFileSystemObject?
    /// 盯的是事件文件时就是它的描述符（`O_EVTONLY`，读也用它：读到的一定是正在盯的那个文件，被删 / 被挪走之后照样读得到）；
    /// 盯父目录时为 -1。
    private var fileDescriptor: Int32 = -1

    /// `startOffset`：从文件的这个位置往后才算新行（通常 = `EventFileLog.readAll` 读到的大小）。
    init(url: URL, startOffset: UInt64, queueLabel: String, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// 没调 `stop()` 就被释放（调用方直接放掉了监听器）：照样取消，取消回调在队列上关描述符。
    deinit {
        source?.cancel()
    }

    /// 开始监听：路径上有文件就从 `startOffset` 起跟随（先把开始监听之前已经写进来的读一遍）；
    /// 没有就建回父目录、等文件出现后从头读。已经在监听时什么也不做。
    func start() {
        queue.async { [weak self] in
            guard let self, self.source == nil else { return }
            self.attach()
        }
    }

    /// 停止监听并关掉描述符（取消回调里关，同样在这个队列上）。
    ///
    /// 块里强引用 self：调用方通常紧接着就放掉最后一个引用，`[weak self]` 的话块执行时对象已经没了，
    /// `cancel()` 不会被调、描述符就漏了（PR2 时的写法，DEDUPE.md §6 PR2 第 5 条）。
    func stop() {
        queue.async { [self] in
            self.detach()
        }
    }

    /// 立刻在监听器的队列上读一次，等它读完再返回。给测试用：确定性地在两次写入之间读一次。
    /// 不能在 `onLines` 里调（同一个队列，会死锁）。
    func drainNow() {
        queue.sync {
            self.drain()
        }
    }

    // MARK: 盯文件 / 盯目录（都在 queue 上）

    /// 路径上有文件就盯文件，没有就等它出现。
    private func attach() {
        let fd = open(url.path, O_EVTONLY)
        if fd >= 0 {
            follow(fd)
        } else {
            waitForFile()
        }
    }

    private func detach() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    /// 盯住已经打开的事件文件，从 `offset` 起读。
    private func follow(_ fd: Int32) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, !src.isCancelled else { return }
            self.fileChanged(src.data)
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        fileDescriptor = fd
        src.resume()

        // 打开之后、开始监听之前文件已经被删 / 被换掉：kqueue 不补发那次事件，现在就换过去。
        guard isSameNode(fd, atPath: url.path) else {
            fileChanged(.delete)
            return
        }
        // 打开之前已经写进来的（脚本建出新文件就写了第一行；或者回放读完之后又写进来的）。
        drain()
    }

    private func fileChanged(_ event: DispatchSource.FileSystemEvent) {
        // 先把这个文件里写进来的读完：被删 / 被挪走之后描述符照样读得到。
        drain()
        guard event.contains(.delete) || event.contains(.rename) else { return }
        // 被删、被挪走、被别的文件换掉（原子保存是「写临时文件再改名覆盖」，旧文件收到的是 .delete）：
        // 路径上的是另一个文件了，从头读。
        detach()
        offset = 0
        attach()
    }

    /// 路径上没有文件：建回父目录，盯着它等文件出现。之后出现的都是新文件，从头读。
    private func waitForFile() {
        offset = 0
        let directory = url.deletingLastPathComponent()
        // 目录可能正在被删（`rm -rf` 先删文件、再删目录）：刚建好 / 刚打开就没了，再来一次。
        // 连着几次都不行（比如没有权限建）就放弃，同以前「文件打不开就什么也不做」。
        for _ in 0..<3 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            watchDirectory(fd)
            // 打开之后、开始盯之前目录已经被删 / 被挪走：kqueue 不补发那次事件，重来。
            guard isSameNode(fd, atPath: directory.path) else {
                detach()
                continue
            }
            // 上面打开文件失败到这里开始盯目录之间，文件可能已经出现了。
            followIfPresent()
            return
        }
    }

    /// 盯住已经打开的父目录：目录里有条目变了就看文件来了没有；目录本身被删 / 被挪走就重来一遍（建回目录再盯）。
    private func watchDirectory(_ fd: Int32) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, !src.isCancelled else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.detach()
                self.attach()
            } else {
                self.followIfPresent()
            }
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        fileDescriptor = -1
        src.resume()
    }

    /// 盯目录时：文件出现了就改盯文件。
    private func followIfPresent() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        detach()
        follow(fd)
    }

    /// 描述符指的还是路径上的那个文件 / 目录（没被删、没被挪走、没被换掉）。
    private func isSameNode(_ fd: Int32, atPath path: String) -> Bool {
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0, stat(path, &current) == 0 else { return false }
        return opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    /// 从上次偏移读到文件末尾，只交出完整的行；偏移停在最后一个换行之后，后面没写完的半行下次再读。
    private func drain() {
        guard fileDescriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        do {
            let end = try handle.seekToEnd()
            // 文件被截断（事件文件超限清理）→ 偏移复位。
            if end < offset { offset = 0 }
            guard end > offset else { return }
            try handle.seek(toOffset: offset)
            let data = (try handle.read(upToCount: Int(end - offset))) ?? Data()
            let (lines, consumed) = EventFileLog.completeLines(in: data)
            offset += UInt64(consumed)
            if !lines.isEmpty {
                onLines(lines)
            }
        } catch {
            return
        }
    }
}

// MARK: - 文件维护（任意线程可调）

/// 事件文件的维护：启动时建文件、超限截断，读全部，切行。
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

    /// 读入全部完整的行与读到的大小（供启动时回放 + 设定跟随的起点）。大小只算到最后一个换行：
    /// 最后那截没写完的行不回放，留给跟随，等它写完了当新行交出去。
    static func readAll(_ url: URL) -> (lines: [String], size: UInt64) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let (lines, consumed) = completeLines(in: data)
        return (lines, UInt64(consumed))
    }

    /// `data` 里到最后一个换行为止的完整行：按字节切行，逐行按 UTF-8 解码 —— 解不出来的那一行丢掉，不连累别的行；空行不算。
    /// `consumed` = 消费掉的字节数（到最后一个换行为止，含这个换行）；之后没写完的半行不算在内，留给下一次。
    static func completeLines(in data: Data) -> (lines: [String], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete.split(separator: 0x0A).compactMap { String(data: Data($0), encoding: .utf8) }
        return (lines, complete.count)
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
