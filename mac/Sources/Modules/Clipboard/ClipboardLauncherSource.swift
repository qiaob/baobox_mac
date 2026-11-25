import AppKit

/// 剪贴板历史与文本片段交给快速入口搜索（docs/launcher/TECH_DESIGN.md §3.2）。快速入口只认 `LauncherSearchable`，
/// 认识 `ClipboardItem` 的是这里。两个来源各一个实例：
/// - `clipboard`（剪贴板历史）：没收藏的文字条目；
/// - `snippets`（文本片段）：收藏的文字条目（= 片段管理列表 `ClipboardStore.snippets` 的范围，片段就是收藏的条目，
///   docs/snippets/DESIGN.md）。同一条只在一个来源里出现。
/// 交文字（`.text` / `.link`）和图片（`.image`，只在剪贴板历史里，收藏了的也在这里 —— 片段只有文字）；
/// `isConcealed`（密码管理器标成敏感的）一律不交；文件这一期不交。
/// 图片条目（docs/launcher/TECH_DESIGN.md §3.2、§5.5）：标题「图片 · 来源 App」，副标题是相对时间（尺寸要读文件才知道，不放），
/// 「图片 / image / 截图」和来源 App 名都能搜到；只在 `c ` 前缀下出现（标题都差不多，不带前缀时只是噪音）。
/// 缩略图和 Tab 挂成附件要的图片字节交一个「怎么取」（解密读盘），快速入口在后台调 —— 这里仍然零磁盘 IO。
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

    /// 图片条目额外能搜到的词（中英文都放：界面是英文时也能打「截图」搜到）。
    static let imageSearchWords = "图片 截图 照片 image screenshot picture photo"
    /// 图片条目的搜索全文用空格补到这么长。匹配分里「文字比查询长多少就扣多少」（封顶 100，`LauncherMatch`）：不补的话
    /// 来源 App 名短的图片总排在前面（「图片」比「图片 · Safari」高几分）；补齐后同样命中的扣分一样，按复制时间新的在前。
    static let imageSearchTextLength = 160

    /// 只读 `store.items`（已在内存里，新 → 旧）。相对时间按桶格式化，同一个桶只算一次。
    func launcherEntries() -> [LauncherEntry] {
        let now = Date()
        var relativeTexts: [TimeInterval: String] = [:]
        func relativeText(_ date: Date) -> String {
            let bucket = LauncherEntryText.relativeBucket(age: now.timeIntervalSince(date))
            if let cached = relativeTexts[bucket] { return cached }
            let relative = Self.relativeFormatter.localizedString(fromTimeInterval: -bucket)
            relativeTexts[bucket] = relative
            return relative
        }
        var entries: [LauncherEntry] = []
        let wantsPinned = kind == .snippets
        let store = store
        let monitor = monitor
        let imagesDir = ClipboardStore.imagesDir
        for item in store.items {
            if item.type == .image {
                guard kind == .history, !item.isConcealed, let filename = item.imageFilename, !filename.isEmpty else { continue }
                entries.append(imageEntry(item, filename: filename, imagesDir: imagesDir, relative: relativeText(item.createdAt)))
                continue
            }
            guard item.isPinned == wantsPinned, !item.isConcealed, item.type == .text || item.type == .link,
                  let text = item.text else { continue }
            let parts = LauncherEntryText.parts(text)
            guard !parts.searchText.isEmpty else { continue }

            let title: String
            let searchText: String
            let subtitle: String
            switch kind {
            case .history:
                title = parts.title
                searchText = parts.searchText
                let relative = relativeText(item.createdAt)
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

    /// 一条图片条目。图片在磁盘上是加密的（`ClipboardCrypto`），取字节 = 解密读盘：交给快速入口在后台调。
    private func imageEntry(_ item: ClipboardItem, filename: String, imagesDir: URL, relative: String) -> LauncherEntry {
        let app = item.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = app.isEmpty ? L("clipboard.launcher.image") : L("clipboard.launcher.imageFrom \(app)")
        let url = imagesDir.appendingPathComponent(filename)
        let store = store
        let monitor = monitor
        return LauncherEntry(
            id: item.id.uuidString,
            title: title,
            subtitle: relative,
            // 标题在最前（快速入口据此只建一个键），后面是「图片 / image / 截图」这些词，再补齐长度。
            searchText: Self.paddedImageSearchText(title + "\n" + Self.imageSearchWords),
            symbolName: "photo",
            date: item.createdAt,
            image: LauncherEntryImage(cacheKey: filename, loadData: { ClipboardCrypto.read(from: url) }),
            onlyWithPrefix: true,
            primary: { PasteService.paste(item, plainText: false, target: LauncherFocus.previousApp,
                                          store: store, monitor: monitor) }
        )
    }

    static func paddedImageSearchText(_ text: String) -> String {
        text.padding(toLength: max(imageSearchTextLength, text.count), withPad: " ", startingAt: 0)
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
