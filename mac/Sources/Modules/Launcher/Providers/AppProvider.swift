import AppKit
import os

// 快速入口的 App 来源（docs/launcher/TECH_DESIGN.md §6.1）：启动后在后台扫一遍几个应用目录建索引（含搜索键），
// 建完回主线程换上；之后监视这几个目录，有变化 2 秒后重扫。面板呼出时只拿内存里的快照，打字路径上不碰磁盘。

/// 索引里的一个 App。
struct LauncherAppRecord: Sendable {
    /// .app 的路径，也是条目 id（使用记录、别名按它记）。
    let path: String
    /// 列表里显示的名字（系统显示名，跟着系统语言）。
    let title: String
    /// 系统显示名、CFBundleDisplayName、CFBundleName、文件名去重后各一个；第一个是标题。
    let searchKeys: [LauncherSearchKey]
}

@MainActor
final class LauncherAppProvider {
    static let sourceID = "apps"
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    /// 扫这几个目录，各两层深（`/Applications/Foo.app`、`/Applications/某文件夹/Foo.app`）。
    nonisolated static var defaultDirectories: [String] {
        [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
            "/System/Library/CoreServices/Applications",
        ]
    }
    /// 目录有变化后等多久重扫（装 / 卸 App 时会连着来好几个事件）。
    static let rescanDelay: TimeInterval = 2

    /// 当前索引的面板条目（建完索引时一次建好，呼出时直接拿）。
    private(set) var items: [LauncherItem] = []

    private let directories: [String]
    /// 不进索引的 bundle id：Baobox 自己。
    private let excludedBundleID: String?
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.apps", qos: .utility)
    private var scanning = false
    private var rescanRequested = false
    private var rescanWork: DispatchWorkItem?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var started = false
    private let icons = NSCache<NSString, NSImage>()

    init(directories: [String] = LauncherAppProvider.defaultDirectories,
         excludedBundleID: String? = Bundle.main.bundleIdentifier) {
        self.directories = directories
        self.excludedBundleID = excludedBundleID
        icons.countLimit = 400
    }

    /// `activate()` 时调：后台建索引，之后监视目录。
    func start() {
        guard !started else { return }
        started = true
        scan()
    }

    /// 退出时调：停掉目录监视。
    func stop() {
        started = false
        rescanWork?.cancel()
        rescanWork = nil
        cancelWatchers()
    }

    /// App 的图标（文件、文件夹行也用这一份缓存）：只在行要显示时取，按路径缓存。取软链指向的那个
    /// （`/Applications/Safari.app` 是软链，直接取会带上替身的小箭头）。
    func icon(forPath path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        icons.setObject(image, forKey: path as NSString)
        return image
    }

    /// ⏎：打开 App；已经在运行的由系统切过去。
    static func openApp(path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
            if let error {
                log.error("open app failed: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 建索引

    private func scan() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        let directories = directories
        let excluded = excludedBundleID
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let records = Self.buildIndex(directories: directories, excludingBundleID: excluded)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishScan(records, milliseconds: milliseconds)
                }
            }
        }
    }

    private func finishScan(_ records: [LauncherAppRecord], milliseconds: Double) {
        scanning = false
        Self.log.notice("app index: \(records.count, privacy: .public) apps in \(Int(milliseconds.rounded()), privacy: .public) ms")
        let source = L("launcher.source.app")
        items = records.map { record in
            let path = record.path
            let candidate = LauncherCandidate(sourceID: Self.sourceID, entryID: path, searchKeys: record.searchKeys)
            return LauncherItem(candidate: candidate,
                                row: LauncherRow(id: candidate.key, title: record.title, source: source, icon: .file(path)),
                                run: { LauncherAppProvider.openApp(path: path) })
        }
        guard started else { return }
        // 每扫一次重建监视：目录被删了又建（`~/Applications`）也能接上新的那个。
        watch()
        if rescanRequested {
            rescanRequested = false
            scan()
        }
    }

    /// 扫目录建索引（后台跑；探针也直接调它测耗时）。同一个 App 经不同路径出现两次（目录里套了软链）只算一次。
    nonisolated static func buildIndex(directories: [String], excludingBundleID: String?) -> [LauncherAppRecord] {
        let fileManager = FileManager()
        var seen: Set<String> = []
        var records: [LauncherAppRecord] = []
        for directory in directories {
            for url in appURLs(in: URL(fileURLWithPath: directory, isDirectory: true), depth: 2, fileManager: fileManager) {
                let resolved = url.resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted,
                      let record = makeRecord(url, excludingBundleID: excludingBundleID, fileManager: fileManager)
                else { continue }
                records.append(record)
            }
        }
        return records.sorted { $0.path < $1.path }
    }

    /// 目录里的 .app：`depth` = 往下几层（1 = 只看这一层）。不进 .app 包里面，跳过点开头的文件；目录不存在、读不了都当没有。
    /// 不用 `.skipsHiddenFiles`：`/Applications/Safari.app` 是指向系统 Cryptex 的软链，带着「隐藏」标记（`ls -lO` 可见），
    /// 用它就搜不到 Safari（2026-11-23 macOS 27 实测）。
    nonisolated private static func appURLs(in directory: URL, depth: Int, fileManager: FileManager) -> [URL] {
        guard depth > 0,
              let children = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [])
        else { return [] }
        var result: [URL] = []
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            if LauncherAppNames.isAppBundleName(child.lastPathComponent) {
                result.append(child)
            } else if depth > 1, (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.append(contentsOf: appURLs(in: child, depth: depth - 1, fileManager: fileManager))
            }
        }
        return result
    }

    /// 一个 App 的索引条目。Info.plist 读不出来也照样收（用显示名和文件名）；是 Baobox 自己时返回 nil。
    nonisolated private static func makeRecord(_ url: URL, excludingBundleID: String?,
                                               fileManager: FileManager) -> LauncherAppRecord? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        if let excludingBundleID, let bundleID = info["CFBundleIdentifier"] as? String, bundleID == excludingBundleID {
            return nil
        }
        let path = url.path
        let names = LauncherAppNames.searchNames([
            fileManager.displayName(atPath: path),
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            url.lastPathComponent,
        ])
        guard let title = names.first else { return nil }
        return LauncherAppRecord(path: path, title: title, searchKeys: names.map { LauncherSearchKey($0) })
    }

    // MARK: - 目录监视

    private func watch() {
        cancelWatchers()
        for directory in directories {
            let descriptor = Darwin.open(directory, O_EVTONLY)
            guard descriptor >= 0 else { continue }   // 目录不存在就跳过
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .delete, .rename, .link],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan() }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func cancelWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
    }

    private func scheduleRescan() {
        guard started else { return }
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.rescanWork = nil
                self?.scan()
            }
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDelay, execute: work)
    }
}
