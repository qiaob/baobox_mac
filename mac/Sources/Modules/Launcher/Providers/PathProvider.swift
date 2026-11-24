import AppKit
import os

// 快速入口「输入是路径」的行（docs/launcher/TECH_DESIGN.md §6.5）：不靠任何索引，直接读文件系统。
// 读磁盘不在主线程、不在打字路径上：每次输入变成一个新路径时，在后台查一次（存不存在、文件还是文件夹、列目录），
// 带序号，过期的结果丢掉；查完回主线程换成行，控制器照「后台建完搜索键再刷新」那条路刷新列表。
// 查的是全局并发队列：某个路径卡住（断开的网络盘）也不挡后面的输入。
// 怎么排、补全挑哪些、显示和补全文字是纯逻辑（`Logic/LauncherPathListing.swift`、`LauncherPathInput.swift`）。

@MainActor
final class LauncherPathProvider {
    static let sourceID = "path"
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    private let home: String
    private var sequence = 0
    /// 正在查的路径（同一个路径别重复查）。
    private(set) var inFlight: LauncherPathInput?

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// 在后台查这个路径，查完在主线程回调（中途 `cancel()` 或又查了别的路径就不回调）。
    func resolve(_ input: LauncherPathInput,
                 completion: @escaping @MainActor (LauncherPathInput, [LauncherItem]) -> Void) {
        sequence += 1
        let ticket = sequence
        inFlight = input
        let home = home
        DispatchQueue.global(qos: .userInitiated).async {
            let start = DispatchTime.now().uptimeNanoseconds
            let resolution = Self.resolve(input)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.sequence else { return }
                    self.inFlight = nil
                    let items = Self.items(for: resolution, input: input, home: home)
                    Self.log.notice("path resolved in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(items.count, privacy: .public) rows")
                    completion(input, items)
                }
            }
        }
    }

    /// 不要还没回来的结果了（输入不再是路径、面板收起）。
    func cancel() {
        guard inFlight != nil else { return }
        sequence += 1
        inFlight = nil
    }

    // MARK: - 后台：读文件系统

    /// 查一个路径输入（后台跑；探针也直接调它测耗时）：
    /// 1. 路径存在（带行号的不存在时试去掉行号的）：文件或包 → 一行；文件夹 → 它本身 + 里面的内容。
    /// 2. 不存在：上一级存在就在里面找和最后一段匹配的（路径补全）；上一级也不存在 → 没有。
    nonisolated static func resolve(_ input: LauncherPathInput) -> LauncherPathResolution {
        let fileManager = FileManager()
        for candidate in [input.path, input.pathWithoutLineSuffix].compactMap({ $0 }) {
            let path = LauncherPathDisplay.trimmingTrailingSlashes(candidate)
            guard let entry = entry(atPath: path, fileManager: fileManager) else { continue }
            if entry.isDirectory {
                return .directory(path: path, entry: entry,
                                  children: LauncherPathListing.contents(readDirectory(path, fileManager: fileManager)))
            }
            return .item(path: path, entry: entry)
        }
        let (parent, partial) = LauncherPathDisplay.split(input.pathWithoutLineSuffix ?? input.path)
        guard !partial.isEmpty, entry(atPath: parent, fileManager: fileManager)?.isDirectory == true else { return .none }
        return .completions(parent: parent,
                            matches: LauncherPathListing.completions(readDirectory(parent, fileManager: fileManager),
                                                                     partial: partial))
    }

    /// 一个存在的路径是什么（跟着软链走）；不存在为 nil。
    nonisolated private static func entry(atPath path: String, fileManager: FileManager) -> LauncherPathEntry? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        let isPackage = isDirectory.boolValue
            && ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
        return LauncherPathEntry(name: name, isDirectory: isDirectory.boolValue, isPackage: isPackage)
    }

    /// 目录里的项，最多读 `LauncherPathListing.maxEntriesRead` 个（几万项的目录只读前面这些）。读不了（没权限）就是空的。
    /// 不用 `.skipsHiddenFiles`：带「隐藏」标记的软链（`/Applications/Safari.app`）也要列出来；点开头的由纯逻辑过滤。
    nonisolated static func readDirectory(_ path: String, fileManager: FileManager = FileManager()) -> [LauncherPathEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                                                      errorHandler: { _, _ in true })
        else { return [] }
        var entries: [LauncherPathEntry] = []
        while entries.count < LauncherPathListing.maxEntriesRead, let child = enumerator.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                // 软链：看它指向的是不是文件夹（`/tmp` → `/private/tmp`）。
                var target: ObjCBool = false
                isDirectory = fileManager.fileExists(atPath: child.path, isDirectory: &target) && target.boolValue
            }
            // 包（.app）只在文件夹里才可能是；文件不用查。
            let isPackage = isDirectory && ((try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
            entries.append(LauncherPathEntry(name: child.lastPathComponent, isDirectory: isDirectory, isPackage: isPackage))
        }
        return entries
    }

    // MARK: - 主线程：换成行

    /// 结论 → 面板条目。行不记使用记录；⏎ 打开，⌘⏎ 在访达里显示，Tab 把输入框换成这一行的完整路径。
    static func items(for resolution: LauncherPathResolution, input: LauncherPathInput, home: String) -> [LauncherItem] {
        func item(path: String, entry: LauncherPathEntry, subtitle: String?) -> LauncherItem {
            let candidate = LauncherCandidate(sourceID: sourceID, entryID: path, searchKeys: [])
            let completion = LauncherPathDisplay.completionText(path: path, isDirectory: entry.isDirectory,
                                                                usesTilde: input.usesTilde, home: home)
            return LauncherFileActions.item(candidate: candidate, path: path, title: entry.name, subtitle: subtitle,
                                            isDirectory: entry.isDirectory, isPackage: entry.isPackage,
                                            completion: completion, recordsUsage: false)
        }
        switch resolution {
        case .item(let path, let entry):
            return [item(path: path, entry: entry,
                         subtitle: LauncherPathDisplay.directoryLabel(LauncherPathDisplay.split(path).parent, home: home))]
        case .directory(let path, let entry, let children):
            let parent = path == "/" ? nil : LauncherPathDisplay.directoryLabel(LauncherPathDisplay.split(path).parent, home: home)
            // 里面的项不写副标题：都在同一个文件夹里，第一行已经写着是哪个。
            return [item(path: path, entry: entry, subtitle: parent)]
                + children.map { item(path: LauncherPathDisplay.join(path, $0.name), entry: $0, subtitle: nil) }
        case .completions(let parent, let matches):
            return matches.map { item(path: LauncherPathDisplay.join(parent, $0.name), entry: $0, subtitle: nil) }
        case .none:
            return []
        }
    }
}

/// 文件、文件夹行共用的样子和动作（路径行、文件搜索的行）。
@MainActor
enum LauncherFileActions {
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    /// 一行文件 / 文件夹：真实图标、文件名、副标题（所在目录）、右侧小字「文件 / 文件夹 / App」；
    /// ⏎ 打开（文件夹在访达里打开、App 启动），⌘⏎ 在访达里显示。
    static func item(candidate: LauncherCandidate, path: String, title: String, subtitle: String?, isDirectory: Bool,
                     isPackage: Bool, completion: String? = nil, recordsUsage: Bool) -> LauncherItem {
        let isApp = isPackage && LauncherAppNames.isAppBundleName(title)
        let source = isDirectory ? L("launcher.source.folder") : (isApp ? L("launcher.source.app") : L("launcher.source.file"))
        let row = LauncherRow(id: candidate.key, title: title, source: source, icon: .file(path), subtitle: subtitle)
        return LauncherItem(candidate: candidate, row: row,
                            run: { open(path: path, isApp: isApp) },
                            alternate: { reveal(path: path) },
                            completion: completion, recordsUsage: recordsUsage)
    }

    /// 打开：App 照 App 来源的做法启动；别的交给系统（文件用默认 App 打开，文件夹在访达里打开）。打不开（刚被删了）给一句回执。
    static func open(path: String, isApp: Bool) {
        if isApp {
            LauncherAppProvider.openApp(path: path)
            return
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
            log.error("open failed: \(path, privacy: .private)")
            LauncherController.toast(L("launcher.toast.openFailed \((path as NSString).lastPathComponent)"))
            return
        }
    }

    /// 在访达里显示（选中它）。
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
