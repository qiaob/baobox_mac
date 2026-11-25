import AppKit

/// 剪贴板历史与文本片段交给快速入口搜索（docs/launcher/TECH_DESIGN.md §3.2）。快速入口只认 `LauncherSearchable`，
/// 认识 `ClipboardItem` 的是这里。两个来源各一个实例：
/// - `clipboard`（剪贴板历史）：没收藏的文字条目；
/// - `snippets`（文本片段）：收藏的文字条目（= 片段管理列表 `ClipboardStore.snippets` 的范围，片段就是收藏的条目，
///   docs/snippets/DESIGN.md）。同一条只在一个来源里出现。
/// 只交文字（`.text` / `.link`）；`isConcealed`（密码管理器标成敏感的）一律不交；图片、文件这一期不交。
/// ⏎ 走 `PasteService.paste`，和剪贴板面板回车一样（回填不进历史、切回前台 App 再合成 ⌘V、没有辅助功能权限时说明降级）。
@MainActor
final class ClipboardLauncherSource: LauncherSearchable {
    enum Kind {
        case history
        case snippets
    }

    private let kind: Kind
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor

    init(kind: Kind, store: ClipboardStore, monitor: ClipboardMonitor) {
        self.kind = kind
        self.store = store
        self.monitor = monitor
    }

    var launcherSourceID: String {
        switch kind {
        case .history: return "clipboard"
        case .snippets: return "snippets"
        }
    }

    var launcherSourceName: String {
        switch kind {
        case .history: return L("launcher.source.clipboard")
        case .snippets: return L("launcher.source.snippets")
        }
    }

    /// 只读 `store.items`（已在内存里，新 → 旧）。相对时间按桶格式化，同一个桶只算一次。
    func launcherEntries() -> [LauncherEntry] {
        let now = Date()
        var relativeTexts: [TimeInterval: String] = [:]
        var entries: [LauncherEntry] = []
        let wantsPinned = kind == .snippets
        let store = store
        let monitor = monitor
        for item in store.items where item.isPinned == wantsPinned {
            guard !item.isConcealed, item.type == .text || item.type == .link, let text = item.text else { continue }
            let parts = LauncherEntryText.parts(text)
            guard !parts.searchText.isEmpty else { continue }

            let title: String
            let searchText: String
            let subtitle: String
            switch kind {
            case .history:
                title = parts.title
                searchText = parts.searchText
                let bucket = LauncherEntryText.relativeBucket(age: now.timeIntervalSince(item.createdAt))
                let relative: String
                if let cached = relativeTexts[bucket] {
                    relative = cached
                } else {
                    relative = Self.relativeFormatter.localizedString(fromTimeInterval: -bucket)
                    relativeTexts[bucket] = relative
                }
                subtitle = [item.sourceAppName, relative].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            case .snippets:
                // 片段有名字就用名字当标题（同片段管理列表：没有名字时回落到内容首行），内容首行放副标题。
                let name = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let keyword = item.keyword ?? ""
                title = name.isEmpty ? parts.title : String(name.prefix(LauncherEntryText.maxTitleLength))
                // 关键字也能搜：放在全文最前面（关键字是英文缩写居多，不需要拼音）。
                searchText = keyword.isEmpty ? parts.searchText : keyword + "\n" + parts.searchText
                subtitle = [keyword, name.isEmpty ? "" : parts.title].filter { !$0.isEmpty }.joined(separator: " · ")
            }

            entries.append(LauncherEntry(
                id: item.id.uuidString,
                title: title,
                subtitle: subtitle,
                searchText: searchText,
                symbolName: kind == .history ? "doc.text" : "text.badge.star",
                date: item.createdAt,
                // 目标是呼出快速入口前的前台 App（`LauncherFocus`）：面板拿过焦点，此刻的前台 App 不可靠。
                primary: { PasteService.paste(item, plainText: false, target: LauncherFocus.previousApp,
                                              store: store, monitor: monitor) }
            ))
        }
        return entries
    }

    /// 「3 分钟前」「昨天」：跟着 App 的界面语言。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()
}
