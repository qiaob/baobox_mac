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
    /// ⏎ 的主动作。
    let primary: @MainActor () -> Void
}

/// 「我有可搜索的条目」：剪贴板历史、文本片段、会议、会话各是一个来源。
@MainActor
protocol LauncherSearchable {
    /// 来源 id，如 "clipboard"、"snippets"、"meetings"；也是设置里来源开关与前缀的键名后缀。
    var launcherSourceID: String { get }
    /// 此刻的全部条目。只读内存、零磁盘 IO；面板呼出时调一次并缓存到收起，不是每次按键都调。
    func launcherEntries() -> [LauncherEntry]
}
