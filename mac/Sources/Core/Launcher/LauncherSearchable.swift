import Foundation

// 快速入口的可搜索数据（docs/launcher/TECH_DESIGN.md §3.2）：快速入口不 import 剪贴板、会议、会话这些模块的类型，
// 由它们经 `ToolModule.launcherSources()` 交出实现了 `LauncherSearchable` 的来源，每个来源给一组条目。
// 只依赖 Foundation，进 BaoboxTests；文案由模块用 `L()` 取好再传进来。

/// 一个条目在 ⌘K 里的其余动作（⏎ 的主动作是 `LauncherEntry.primary`）。
struct LauncherEntryAction {
    /// 条目内唯一，如 "copy"、"delete"。
    let id: String
    let title: String
    /// SF Symbol 名。
    let symbolName: String
    /// true = 有破坏性（删除这一条），要按两次 ⏎。
    var destructive: Bool = false
    let run: @MainActor () -> Void
}

/// 条目是一张图片时（剪贴板历史里的图片，docs/launcher/TECH_DESIGN.md §3.2、§5.5）：行首的缩略图、
/// Tab 把它挂成输入里的附件，都从这里取。`launcherEntries()` 仍然零磁盘 IO —— 交出来的只是「怎么取」，
/// 快速入口在行要显示时 / 按 Tab 时才在后台调。
struct LauncherEntryImage: Sendable {
    /// 同一张图不变的键（剪贴板：图片文件名，即内容的哈希）：快速入口按它缓存缩略图。
    let cacheKey: String
    /// 读出这张图的编码字节（PNG / TIFF…）。快速入口只在后台线程调（来源可能要读盘、解密）；读不到返回 nil。
    let loadData: @Sendable () -> Data?

    init(cacheKey: String, loadData: @escaping @Sendable () -> Data?) {
        self.cacheKey = cacheKey
        self.loadData = loadData
    }
}

/// 来源交出来的一个条目。
struct LauncherEntry {
    /// 来源内唯一（不同来源之间可能重复，快速入口按「来源 id + 条目 id」区分）。
    let id: String
    let title: String
    let subtitle: String
    /// 参与匹配的全文（来源负责截断，别把整段长文交出来）。
    let searchText: String
    /// SF Symbol 名。
    let symbolName: String
    /// 条目的时间（剪贴板的复制时间、会议的开始时间），没有就 nil。
    var date: Date? = nil
    /// ⌘K 里的其余动作。
    var actions: [LauncherEntryAction] = []
    /// 条目是一张图片：行首显示缩略图，Tab 把它挂成输入里的附件；nil = 不是图片（行首是 `symbolName`）。
    var image: LauncherEntryImage? = nil
    /// true = 只在打了来源前缀时出现（`c 图片`），不带前缀的搜索里不出 —— 图片条目的标题都差不多（「图片 · 微信」），
    /// 搜 App 名时混进来只是噪音。
    var onlyWithPrefix = false
    /// ⏎ 的主动作。
    let primary: @MainActor () -> Void
}

/// 「我有可搜索的条目」：剪贴板历史、文本片段、会议、会话各是一个来源。
@MainActor
protocol LauncherSearchable {
    /// 来源 id，如 "clipboard"、"snippets"、"meetings"；也是设置里来源开关与前缀的键名后缀。
    var launcherSourceID: String { get }
    /// 来源的名字（已本地化），列表每一行右侧的小字：「剪贴板」「片段」。
    var launcherSourceName: String { get }
    /// 此刻的全部条目。只读内存、零磁盘 IO；面板呼出时调一次并缓存到收起，不是每次按键都调。
    func launcherEntries() -> [LauncherEntry]
}

/// 来源把一段长文字整理成条目的标题和搜索全文（剪贴板、片段都用）。
enum LauncherEntryText {
    /// 标题最多这么多个字符（一行只放得下四五十个字，再长也看不到，只会多占建键时间）。
    static let maxTitleLength = 80
    /// 搜索全文最多这么多个字符（§3.2「已截断」）。
    static let maxSearchLength = 200

    /// 标题和搜索全文：
    /// - 搜索全文 = 去掉开头的空白后的前 `maxSearchLength` 个字符，再去掉末尾的空白；
    /// - 标题 = 搜索全文的第一行（行尾空白去掉），超长截断（不加省略号：列表一行放不下时界面自己加）。
    /// 所以标题总是搜索全文的开头（快速入口据此只建一个键）。全是空白时两个都是空串。
    /// 只看开头那一小段，不整段去空白 —— 剪贴板里可能有几 MB 的一条，整段复制一遍不划算。
    static func parts(_ text: String, maxTitleLength: Int = maxTitleLength,
                      maxSearchLength: Int = maxSearchLength) -> (title: String, searchText: String) {
        let head = text.drop(while: \.isWhitespace).prefix(max(0, maxSearchLength))
        let searchText = String(head).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = searchText.prefix { !$0.isNewline }
        let title = String(firstLine).trimmingCharacters(in: .whitespaces)
        return (String(title.prefix(max(0, maxTitleLength))), searchText)
    }

    /// 相对时间的粒度（秒）：给「3 分钟前」这类文字分桶，同一个桶只格式化一次 ——
    /// 几千条剪贴板每条都调一次 `RelativeDateTimeFormatter` 会拖慢呼出。
    /// 一分钟内 → 0（「现在」）；一小时内按分钟、一天内按小时、30 天内按天、再往前按 30 天往下取整。
    static func relativeBucket(age: TimeInterval) -> TimeInterval {
        let age = max(0, age)
        let unit: TimeInterval
        switch age {
        case ..<60: return 0
        case ..<3_600: unit = 60
        case ..<86_400: unit = 3_600
        case ..<(30 * 86_400): unit = 86_400
        default: unit = 30 * 86_400
        }
        return (age / unit).rounded(.down) * unit
    }
}
