import Foundation

// 快速入口自己扫的目录（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：Spotlight 不建索引的地方（默认是 Claude Code 的临时目录
// `/private/tmp/claude-<uid>`），在后台遍历一遍记下「所在目录、名字、是不是文件夹、修改时间」，查询时只读内存里的表。
// 用 fts（BSD 的目录遍历）：2026-11-24 在 `/private/tmp/claude-501`（7 万个文件）上比了三种写法，剪枝后 1.7 万个文件，
// fts 热缓存 40 ms、`FileManager` 按 URL 枚举 112 ms、按路径枚举 580 ms。
// 遍历时就剪枝（同 `LauncherFileFilter` 的目录规则）：依赖、版本库、编译产物、`*.noindex`、隐藏的、包里面的都不进去；
// 软链不跟（避免环）；没权限的跳过；名字不是合法 UTF-8 的跳过；单个根有条数上限和时间上限，超了就停，留下已扫到的。
// 只依赖 Foundation，进 BaoboxTests。

/// 扫描的上限。
struct LauncherFileScanLimits: Equatable, Sendable {
    /// 单个根最多记这么多条。
    var maxEntriesPerRoot = 200_000
    /// 单个根最多扫这么久（秒）。
    var maxSecondsPerRoot: TimeInterval = 5
}

/// 一个根这次扫得怎么样（记日志）。
struct LauncherFileScanReport: Equatable, Sendable {
    let root: String
    var files = 0
    var directories = 0
    /// 剪掉没进去的目录（依赖、编译产物、隐藏的……；包本身记下了、只是没进去，也算在这里）。
    var prunedDirectories = 0
    /// 读不了的（没权限、读的时候出错）。
    var unreadable = 0
    /// 名字不是合法 UTF-8、跳过的。
    var invalidNames = 0
    var elapsed: TimeInterval = 0
    /// 碰到条数或时间上限、没扫完。
    var stoppedEarly = false
    /// 根不存在（或不是目录）。
    var missing = false

    var entries: Int { files + directories }
}

enum LauncherFileScanRules {
    enum Directory: Equatable {
        /// 记下并进去。
        case descend
        /// 记下但不进去（包：`.xcodeproj`、`.pages` 是文档，里面不是）。
        case recordOnly
        /// 不记也不进去（噪音）。
        case skip
    }

    /// 遍历到一个目录（不是根）怎么办：同 `LauncherFileFilter.isExcluded` 的目录规则 ——
    /// 隐藏的、`node_modules` / `.git` / `DerivedData` / `build` 这些、`*.noindex`、`~/Library` 不记也不进去；
    /// `.app` 不记（App 来源有，过滤也会去掉）不进去；别的包记下、不进去。
    static func directory(named name: String, path: String, home: String) -> Directory {
        let lower = name.lowercased()
        if name.hasPrefix(".") || LauncherFileFilter.excludedSegments.contains(lower) || lower.hasSuffix(".noindex") {
            return .skip
        }
        if path == LauncherPathDisplay.trimmingTrailingSlashes(home) + "/Library" { return .skip }
        if let dot = lower.lastIndex(of: "."), LauncherFileFilter.packageExtensions.contains(String(lower[lower.index(after: dot)...])) {
            return lower.hasSuffix(".app") ? .skip : .recordOnly
        }
        return .descend
    }

    /// 文件记不记：隐藏的（点开头）不记。
    static func recordsFile(named name: String) -> Bool {
        !name.hasPrefix(".")
    }

    /// 要扫的根：都是绝对路径；去重；在另一个根里面的不重复扫。顺序照给的。
    static func normalizedRoots(_ roots: [String]) -> [String] {
        var result: [String] = []
        for raw in roots {
            let root = LauncherPathDisplay.trimmingTrailingSlashes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard root.hasPrefix("/"), root != "/" else { continue }
            if result.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) { continue }
            result.removeAll { $0.hasPrefix(root + "/") }
            result.append(root)
        }
        return result
    }
}

enum LauncherFileScanner {
    /// 扫这几个根（后台调），建成一张表。根先解析成真实路径（`/tmp/x` → `/private/tmp/x`），不存在的跳过。
    static func scan(roots: [String], home: String, limits: LauncherFileScanLimits = LauncherFileScanLimits())
        -> (catalog: LauncherFileCatalog, reports: [LauncherFileScanReport]) {
        var catalog = LauncherFileCatalog()
        var reports: [LauncherFileScanReport] = []
        let resolved = LauncherFileScanRules.normalizedRoots(roots.map { realPath($0) ?? $0 })
        for root in resolved {
            reports.append(scanRoot(root, home: home, limits: limits, into: &catalog))
        }
        catalog.finishBuilding()
        return (catalog, reports)
    }

    /// 解析软链后的真实路径；不存在为 nil。
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingUTF8: resolved)
    }

    /// 扫一个根，记下用了多久。（原来用 `defer` 填耗时：`return report` 拷走之后才执行，日志里永远是 0 ms，PR 11 独立验证发现。）
    private static func scanRoot(_ root: String, home: String, limits: LauncherFileScanLimits,
                                 into catalog: inout LauncherFileCatalog) -> LauncherFileScanReport {
        let start = DispatchTime.now().uptimeNanoseconds
        var report = walk(root, home: home, limits: limits, start: start, into: &catalog)
        report.elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return report
    }

    private static func walk(_ root: String, home: String, limits: LauncherFileScanLimits, start: UInt64,
                             into catalog: inout LauncherFileCatalog) -> LauncherFileScanReport {
        var report = LauncherFileScanReport(root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              let rootCString = strdup(root)
        else {
            report.missing = true
            return report
        }
        defer { free(rootCString) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [rootCString, nil]
        // 不跟软链（FTS_PHYSICAL，根本身例外）、不切换工作目录（多线程安全）、不跨卷。
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR | FTS_XDEV, nil) else {
            report.unreadable += 1
            return report
        }
        defer { fts_close(fts) }
        let deadline = start + UInt64(max(0, limits.maxSecondsPerRoot) * 1_000_000_000)
        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited % 1024 == 0, DispatchTime.now().uptimeNanoseconds > deadline {
                report.stoppedEarly = true
                break
            }
            if report.entries >= limits.maxEntriesPerRoot {
                report.stoppedEarly = true
                break
            }
            let level = entry.pointee.fts_level
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                guard let path = String(validatingUTF8: entry.pointee.fts_path) else {
                    report.invalidNames += 1
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                if level == 0 {
                    entry.pointee.fts_number = Int(catalog.addDirectory(path))
                    continue
                }
                let name = (path as NSString).lastPathComponent
                switch LauncherFileScanRules.directory(named: name, path: path, home: home) {
                case .skip:
                    report.prunedDirectories += 1
                    fts_set(fts, entry, FTS_SKIP)
                case .recordOnly:
                    report.prunedDirectories += 1
                    record(entry, name: name, isDirectory: true, into: &catalog)
                    report.directories += 1
                    fts_set(fts, entry, FTS_SKIP)
                case .descend:
                    record(entry, name: name, isDirectory: true, into: &catalog)
                    report.directories += 1
                    entry.pointee.fts_number = Int(catalog.addDirectory(path))
                }
            case FTS_F:
                guard let path = entry.pointee.fts_path else { continue }
                let nameStart = path + (Int(entry.pointee.fts_pathlen) - Int(entry.pointee.fts_namelen))
                guard let name = String(validatingUTF8: nameStart) else {
                    report.invalidNames += 1
                    continue
                }
                guard LauncherFileScanRules.recordsFile(named: name) else { continue }
                record(entry, name: name, isDirectory: false, into: &catalog)
                report.files += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                report.unreadable += 1
            default:
                // FTS_DP（目录的后序）、FTS_SL / FTS_SLNONE（软链，不跟）、FTS_DC（环）、FTS_DEFAULT（套接字这类）：不记。
                break
            }
        }
        return report
    }

    /// 记一条：所在目录是父项上记下的下标（`fts_number`），修改时间来自遍历时就有的 stat。
    private static func record(_ entry: UnsafeMutablePointer<FTSENT>, name: String, isDirectory: Bool,
                               into catalog: inout LauncherFileCatalog) {
        guard let parent = entry.pointee.fts_parent else { return }
        let directory = Int32(truncatingIfNeeded: parent.pointee.fts_number)
        guard directory >= 0, Int(directory) < catalog.directories.count else { return }
        var modified: Double = 0
        if let stat = entry.pointee.fts_statp {
            modified = Double(stat.pointee.st_mtimespec.tv_sec) + Double(stat.pointee.st_mtimespec.tv_nsec) / 1_000_000_000
        }
        catalog.append(directory: directory, name: name, isDirectory: isDirectory, modified: modified)
    }
}
