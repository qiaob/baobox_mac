import Foundation

// 快速入口「输入是路径」时列哪些项（docs/launcher/TECH_DESIGN.md §6.5）：文件夹里的内容怎么排、路径补全挑哪些。
// 目录由 App 侧在后台读（`Providers/PathProvider.swift`），这里只对读出来的列表做纯计算。只依赖 Foundation，进 BaoboxTests。

/// 目录里的一项。
struct LauncherPathEntry: Equatable, Sendable {
    let name: String
    /// 能进去的文件夹（包不算）。
    let isDirectory: Bool
    /// `.app` 这类包：当成一个文件，不进去。
    let isPackage: Bool

    init(name: String, isDirectory: Bool, isPackage: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory && !isPackage
        self.isPackage = isPackage
    }

    /// 点开头的隐藏项。
    var isHidden: Bool { name.hasPrefix(".") }
}

/// 后台查完一个路径输入的结论。
enum LauncherPathResolution: Equatable, Sendable {
    /// 路径存在，是文件（或包）：一行。
    case item(path: String, entry: LauncherPathEntry)
    /// 路径存在，是文件夹：它本身一行，下面是里面的内容（已排好、截断）。
    case directory(path: String, entry: LauncherPathEntry, children: [LauncherPathEntry])
    /// 路径不存在、上一级存在：上一级里和最后一段匹配的项（路径补全）。
    case completions(parent: String, matches: [LauncherPathEntry])
    /// 什么都没有（上一级也不存在、读不了）。
    case none
}

enum LauncherPathListing {
    /// 文件夹里的内容、补全结果最多列几行。
    static let maxRows = 50
    /// 一个目录最多读这么多项（几万项的目录只读前面这些，不卡、不占内存）。
    static let maxEntriesRead = 5000

    /// 文件夹里的内容：不列点开头的；文件夹在前，再按名字（同访达的排法：数字按大小、不分大小写）；最多 `limit` 行。
    static func contents(_ entries: [LauncherPathEntry], limit: Int = maxRows) -> [LauncherPathEntry] {
        Array(entries.filter { !$0.isHidden }.sorted(by: foldersFirstByName).prefix(max(0, limit)))
    }

    /// 路径补全：上一级里名字和 `partial` 匹配的项。只认开头、词首、包含（`LauncherMatch` 打分不低于连续子串那一档），
    /// 不认跳字；`partial` 以 `.` 开头时才列隐藏项。分高的在前，同分文件夹在前、再按名字；最多 `limit` 行。
    /// 只打了一个点（`~/.`）= 想看隐藏项：列出全部隐藏项，不去匹配扩展名里的点（否则每个带扩展名的文件都中）。
    static func completions(_ entries: [LauncherPathEntry], partial: String,
                            limit: Int = maxRows) -> [LauncherPathEntry] {
        let query = LauncherMatchQuery(partial)
        guard !query.isEmpty else { return contents(entries, limit: limit) }
        if partial == "." {
            return Array(entries.filter(\.isHidden).sorted(by: foldersFirstByName).prefix(max(0, limit)))
        }
        let includesHidden = partial.hasPrefix(".")
        var scored: [(entry: LauncherPathEntry, score: Int)] = []
        for entry in entries where includesHidden || !entry.isHidden {
            guard let score = LauncherMatch.score(query, in: LauncherSearchKey(entry.name, pinyin: false)),
                  score >= LauncherMatch.substringMinimumScore else { continue }
            scored.append((entry, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return foldersFirstByName(a.entry, b.entry)
        }
        return scored.prefix(max(0, limit)).map(\.entry)
    }

    /// 文件夹在前，再按名字（`localizedStandardCompare`：访达的排法），名字一样时按原文排，结果确定。
    static func foldersFirstByName(_ a: LauncherPathEntry, _ b: LauncherPathEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name
        }
    }
}
