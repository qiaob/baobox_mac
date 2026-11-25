import Foundation

// 各模块已知的文件（docs/launcher/TECH_DESIGN.md §6.4「来源 C」，PR 11）：模块手里本来就有、在内存里的一份文件清单
// （Claude Code 助手的「最近文件」= 会话写过的文件），经 `ToolModule.launcherKnownFiles()` 交给快速入口按名字搜。
// 快速入口不 import 那些模块的类型（框架不认识具体工具）。只依赖 Foundation，进 BaoboxTests。

/// 模块交给快速入口的一个已知文件。
struct LauncherKnownFile: Equatable, Sendable {
    /// 绝对路径。存不存在由快速入口在后台查（只查名字匹配上的那几条），模块不用先查。
    let path: String
    /// 最近一次和它有关的时间（Claude Code：会话最后一次写它的时间），排序时当「最近使用」；没有为 nil。
    var date: Date?
    /// 显示在副标题里的一句说明（已本地化，如「Claude Code · 项目名」）；nil = 不写。
    var note: String?

    init(path: String, date: Date? = nil, note: String? = nil) {
        self.path = path
        self.date = date
        self.note = note
    }
}

/// 「最多每隔多久做一次」（PR 11）：模块交已知文件时顺带刷新自己的清单用 —— 呼出一次面板就触发一次后台刷新太勤，
/// 隔一段时间才刷（这次呼出拿到的是旧清单，下次呼出就是新的）。值类型，调用方自己存着（主线程）。
struct LauncherRefreshThrottle: Equatable, Sendable {
    let interval: TimeInterval
    private(set) var lastRun: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 现在该不该做：从来没做过、或者距上次不少于 `interval`。该做时记下这次的时间。
    mutating func shouldRun(now: Date) -> Bool {
        if let lastRun, now.timeIntervalSince(lastRun) < interval { return false }
        lastRun = now
        return true
    }
}
