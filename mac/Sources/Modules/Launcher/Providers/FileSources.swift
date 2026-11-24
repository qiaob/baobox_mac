import Foundation
import os

// 快速入口按名字搜文件的四个来源（docs/launcher/TECH_DESIGN.md §6.4，PR 11），并成一个后端交给 `LauncherFileProvider`：
// A Spotlight（主目录）；B 自己扫的目录（Spotlight 不建索引的地方，各模块声明 + 设置键 `launcher.files.extraRoots`）；
// C 各模块已知的文件（Claude Code 会话写过的）；D 剪贴板历史里出现过的路径。
// 什么时候准备数据：B 在 `activate()` 后几秒扫一次，之后每次呼出面板时距上次超过 30 秒就在后台重扫，扫完在主线程换表；
// C、D 每次呼出取一次（只读内存），在后台建表 / 抽路径（D 按条目键缓存），建完在主线程换表。
// 查询只读内存里的表（各在自己的后台队列上），打字路径上零磁盘 IO；存不存在只对 C、D 名字匹配上的那几条在后台查。
// 2026-11-24 用户实测：输入 `add-approval-hook.py`（在 `/private/tmp/claude-501/…/scratchpad/` 里）只出剪贴板，
// `f add-approval-hook.py` 是「没有结果」—— `/private/tmp` 不在 Spotlight 索引里。

@MainActor
final class LauncherFileSources {
    /// `activate()` 后多久第一次扫（别和启动时各模块抢）。
    static let firstScanDelay: TimeInterval = 6
    /// 呼出面板时距上次扫描超过这么久才重扫（扫一遍零点几秒，不用 FSEvents）。
    static let rescanInterval: TimeInterval = 30
    /// 用户自己加的要扫的目录（字符串数组，`~` 开头的展开；设置界面以后做）。和模块声明的合并。
    static let extraRootsKey = "launcher.files.extraRoots"
    /// 剪贴板里哪些来源的文字抽路径（片段就是收藏的剪贴板条目）。
    static let clipboardSourceIDs: Set<String> = ["clipboard", "snippets"]

    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    private weak var registry: ToolRegistry?
    private let home: String
    private let scanned = LauncherMemoryFileSearch(label: "scanned", verifiesExistence: false)
    private let known = LauncherMemoryFileSearch(label: "known", verifiesExistence: true)
    private let clipboard = LauncherMemoryFileSearch(label: "clipboard", verifiesExistence: true)
    /// 交给 `LauncherFileProvider` 的后端：四个来源并起来。
    let backend: LauncherMergedFileSearch

    private let scanQueue = DispatchQueue(label: "com.baobox.app.launcher.filescan", qos: .utility)
    private let buildQueue = DispatchQueue(label: "com.baobox.app.launcher.filesources", qos: .utility)
    /// 剪贴板路径的缓存，只在 `buildQueue` 上用。
    private let clipboardIndex = LauncherClipboardPathIndexBox()
    private var lastScanStarted: Date?
    /// 有一次扫描在后台跑。
    private(set) var scanning = false
    /// 上一次交来的已知文件：没变就不重建表。
    private var lastKnownFiles: [LauncherKnownFile]?

    init(registry: ToolRegistry?, home: String = NSHomeDirectory(),
         spotlight: LauncherFileSearching = LauncherSpotlightFileSearch()) {
        self.registry = registry
        self.home = home
        backend = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight),
            .init(name: "scanned", origin: .scanned, backend: scanned),
            .init(name: "known", origin: .known, backend: known),
            .init(name: "clipboard", origin: .clipboard, backend: clipboard),
        ])
    }

    /// 模块 activate：几秒后扫一次。
    func activate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstScanDelay) { [weak self] in
            MainActor.assumeIsolated { self?.rescanIfStale(force: true) }
        }
    }

    /// 面板呼出：取一次已知文件和剪贴板文字（只读内存，建表在后台）；距上次扫描超过 30 秒就重扫。
    func panelShown(clipboardTexts: [LauncherTextSnapshot]) {
        updateKnownFiles()
        updateClipboardPaths(clipboardTexts)
        rescanIfStale(force: false)
    }

    // MARK: - B 自己扫的目录

    /// 要扫的目录：各模块声明的 + 设置里的（`~` 展开），去重、去掉在别的根里面的。
    func scanRoots() -> [String] {
        let declared = registry?.tools.flatMap { $0.launcherFileRoots() } ?? []
        let extra = (UserDefaults.standard.stringArray(forKey: Self.extraRootsKey) ?? []).compactMap { raw -> String? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "~" { return home }
            if text.hasPrefix("~/") { return LauncherPathDisplay.join(home, String(text.dropFirst(2))) }
            return text.hasPrefix("/") ? text : nil
        }
        return LauncherFileScanRules.normalizedRoots(declared + extra)
    }

    private func rescanIfStale(force: Bool) {
        guard !scanning else { return }
        if !force, let lastScanStarted, Date().timeIntervalSince(lastScanStarted) < Self.rescanInterval { return }
        let roots = scanRoots()
        lastScanStarted = Date()
        guard !roots.isEmpty else {
            scanned.replace(LauncherFileCatalog())
            return
        }
        scanning = true
        let home = home
        scanQueue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let (catalog, reports) = LauncherFileScanner.scan(roots: roots, home: home)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.scanned.replace(catalog)
                    for report in reports {
                        Self.log.notice("file roots: \(report.root, privacy: .private) \(report.missing ? "missing" : "scanned", privacy: .public) in \(report.elapsed * 1000, format: .fixed(precision: 0), privacy: .public) ms, \(report.files, privacy: .public) files + \(report.directories, privacy: .public) folders, \(report.prunedDirectories, privacy: .public) folders pruned, \(report.unreadable, privacy: .public) unreadable, \(report.invalidNames, privacy: .public) invalid names\(report.stoppedEarly ? " (stopped at the limit)" : "", privacy: .public)")
                    }
                    Self.log.notice("file roots: \(catalog.count, privacy: .public) entries in \(catalog.directories.count, privacy: .public) folders, scan total \(milliseconds, format: .fixed(precision: 0), privacy: .public) ms")
                }
            }
        }
    }

    // MARK: - C 已知文件

    private func updateKnownFiles() {
        let files = registry?.tools.flatMap { $0.launcherKnownFiles() } ?? []
        guard files != lastKnownFiles else { return }
        lastKnownFiles = files
        buildQueue.async {
            let catalog = LauncherFileCatalog(files: files.map {
                LauncherFileCatalog.File(path: $0.path, lastUsed: $0.date, note: $0.note)
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.known.replace(catalog) }
            }
        }
    }

    // MARK: - D 剪贴板里的路径

    private func updateClipboardPaths(_ texts: [LauncherTextSnapshot]) {
        let home = home
        let box = clipboardIndex
        buildQueue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let (files, extracted) = box.index.update(texts, home: home)
            let catalog = LauncherFileCatalog(files: files)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.clipboard.replace(catalog)
                    if extracted > 0 {
                        Self.log.notice("clipboard paths: \(extracted, privacy: .public) of \(texts.count, privacy: .public) entries read, \(catalog.count, privacy: .public) paths, \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
                    }
                }
            }
        }
    }
}

/// 剪贴板路径缓存的盒子：只在 `LauncherFileSources.buildQueue` 这一个串行队列上读写。
final class LauncherClipboardPathIndexBox: @unchecked Sendable {
    var index = LauncherClipboardPathIndex()
}
