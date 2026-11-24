import Foundation

// 快速入口空着的时候（docs/launcher/REQUIREMENTS.md §3.7、TECH_DESIGN.md §8.4、§5.6）：呼出后还没打字，列表最前面是
// 「选中的」（呼出前那个 App 里选中的文字）和「刚复制的」（剪贴板历史里最新的一条，5 分钟内），⏎ / Tab 放进输入框；
// 接着是各模块声明的情景建议（正在专注 →「暂停专注」……），最多 4 条；最后是最常用的行。总共不超过 9 行。
// 这里是规则：什么时候出、两行去重、时间窗口、标题、各类行怎么拼、上限；还有读选区的流程（后台读、80 ms 封顶、过期的丢掉），
// 取词函数由调用方注入（App 侧是 Core 的 `SelectedTextReader`），所以流程和超时能在单元测试里测。
// 纯 Foundation，进 BaoboxTests。换成面板的行（文案、图标、执行）在 App 侧 `Providers/ContextProvider.swift`。

/// 一次读选区的结果（同 Core 的 `SelectedTextReader.Outcome`；这里是纯 Foundation 的一份）。
enum LauncherSelectionOutcome: Equatable, Sendable {
    case text(String)
    /// 没选中、App 不暴露选区、选中的全是空白、呼出前的前台就是 Baobox 自己。
    case none
    /// 超过时限。
    case timedOut
    /// 没有辅助功能权限。
    case noPermission

    /// 日志里写的（只写是哪一种和字数，不写内容）。
    var logLabel: String {
        switch self {
        case .text(let text): return "got \(text.count) characters"
        case .none: return "none"
        case .timedOut: return "timed out"
        case .noPermission: return "no accessibility permission"
        }
    }
}

/// 读完的一次：结果 + 从开始读到读完的毫秒数（兜底超时那一种是到点的时刻）。
struct LauncherSelectionRead: Equatable, Sendable {
    let outcome: LauncherSelectionOutcome
    let milliseconds: Double
}

/// 剪贴板历史里最新的一条（「刚复制的」候选）：快速入口每次呼出时已经取到的条目里拿，不读系统剪贴板。
struct LauncherRecentCopy: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// 完整原文（不是截断过的搜索全文）。
        case text(String)
        case image
    }

    let content: Content
    /// 复制的时间。
    let date: Date?
}

/// 空着时的行怎么排（行 id）：「选中的 / 刚复制的」→ 情景建议 → 最常用的。
struct LauncherEmptyStateLayout: Equatable, Sendable {
    var context: [String] = []
    var situational: [String] = []
    var mostUsed: [String] = []

    var all: [String] { context + situational + mostUsed }
}

enum LauncherContextRules {
    /// 读选区的总时限（AX 是同步调用，个别 App 回得慢）：超了就没有这一行，不拖慢面板出现。
    static let selectionBudget: TimeInterval = 0.08
    /// 时限过了这么久后台还没回来（AX 卡住了）：主线程上当超时处理，不再等它。
    static let selectionGrace: TimeInterval = 0.04
    /// 剪贴板最新一条在这么久以内复制的才算「刚复制的」。
    static let recentCopyWindow: TimeInterval = 5 * 60
    /// 复制时间比现在晚这么多以内也算（系统时间被往回调过一点）；再晚的不算。
    static let clockSkewTolerance: TimeInterval = 60
    /// 「选中的 / 刚复制的」那一行的标题最多几个字符（内容的开头，压成一行）。
    static let titleLength = 60
    /// 「选中的」「刚复制的」各最多一行。
    static let maxContextRows = 2
    /// 情景建议最多几条。
    static let maxSituational = 4
    /// 最常用的行最多几条（同原来空输入时的上限）。
    static let maxMostUsed = 8
    /// 空着时一共最多几行。
    static let maxEmptyStateRows = 9

    /// 复制时间在「刚复制」的窗口里（`recentCopyWindow` 以内；晚于现在的只容 `clockSkewTolerance`）。没有时间的不算。
    static func isRecentCopy(at date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -clockSkewTolerance && age <= recentCopyWindow
    }

    /// 两段内容是不是同一段：空白归一后相等（连续的空白、换行算一个空格，去首尾空白 —— 选区和剪贴板里的换行写法可能不同）。
    /// 归一后是空的不算相同。
    static func isSameContent(_ lhs: String, _ rhs: String) -> Bool {
        let left = LauncherPastedText.normalized(lhs)
        return !left.isEmpty && left == LauncherPastedText.normalized(rhs)
    }

    /// 全是空白。
    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    /// 出不出「刚复制的」那一行：有最新的一条、在窗口里、文字不是空白、和选中的不是同一段（相同时只留「选中的」）。
    static func showsRecentCopy(_ copy: LauncherRecentCopy?, selection: String?, now: Date) -> Bool {
        guard let copy, isRecentCopy(at: copy.date, now: now) else { return false }
        switch copy.content {
        case .image:
            return true
        case .text(let text):
            guard !isBlank(text) else { return false }
            if let selection, isSameContent(selection, text) { return false }
            return true
        }
    }

    /// 那一行的标题：内容的开头，压成一行，最多 `titleLength` 个字符（超出末尾加省略号）。
    static func title(_ text: String) -> String {
        LauncherSuggestionText.quote(text, maxLength: titleLength)
    }

    /// 「刚复制 · N 分钟前」的 N（按分钟往下取整）；不到 1 分钟（含时间稍晚于现在的）为 nil，显示「1 分钟内」。
    static func copiedMinutes(age: TimeInterval) -> Int? {
        let minutes = Int((age / 60).rounded(.down))
        return minutes >= 1 ? minutes : nil
    }

    /// 后台读完的结果怎么算：超过时限的算超时（硬上限：晚到的不要）；读到的全是空白算没有。
    static func finalize(_ outcome: LauncherSelectionOutcome, elapsed: TimeInterval,
                         budget: TimeInterval) -> LauncherSelectionOutcome {
        if elapsed > budget, outcome != .noPermission { return .timedOut }
        if case .text(let text) = outcome, isBlank(text) { return .none }
        return outcome
    }

    /// 空着时的各类行拼成一列（行 id）：
    /// - 「选中的 / 刚复制的」最多 2 行，在最前（重复的只留第一个）；
    /// - 情景建议最多 4 条，接在后面（和前面重复的、自己重复的只留第一个）；
    /// - 最常用的接在最后，最多 8 条，并且总数不超过 9 行；已经作为情景建议出现的命令不再出（留在情景建议里）。
    static func layout(context: [String], situational: [String], mostUsed: [String]) -> LauncherEmptyStateLayout {
        var seen: Set<String> = []
        func take(_ keys: [String], limit: Int) -> [String] {
            var taken: [String] = []
            for key in keys where taken.count < limit && seen.insert(key).inserted {
                taken.append(key)
            }
            return taken
        }
        var layout = LauncherEmptyStateLayout()
        layout.context = take(context, limit: maxContextRows)
        layout.situational = take(situational, limit: maxSituational)
        let room = min(maxMostUsed, max(0, maxEmptyStateRows - layout.context.count - layout.situational.count))
        layout.mostUsed = take(mostUsed, limit: room)
        return layout
    }
}

/// 读一次选区：在后台调注入的取词函数（带时限），回主线程交结果。规则：
/// - 每次 `start` 作废还没回来的上一次（再次呼出）；`cancel()`（面板收起）之后什么都不交。
/// - 每次 `start` 只交一次结果：后台读完了就交（超过时限的按超时，`LauncherContextRules.finalize`）；
///   时限 + 宽限到了还没回来，就在主线程上交一个超时，之后回来的不要。
@MainActor
final class LauncherSelectionFetcher {
    /// 取词函数：在后台线程调，参数是时限（秒）。
    typealias Reader = @Sendable (TimeInterval) -> LauncherSelectionOutcome

    let budget: TimeInterval
    let grace: TimeInterval
    private let queue: DispatchQueue
    private var generation = 0
    /// 这一次还没交结果。
    private(set) var isReading = false

    init(budget: TimeInterval = LauncherContextRules.selectionBudget, grace: TimeInterval = LauncherContextRules.selectionGrace,
         queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.budget = budget
        self.grace = grace
        self.queue = queue
    }

    /// 开始读。`completion` 在主线程调，这一次最多调一次。
    func start(_ read: @escaping Reader, completion: @escaping @MainActor (LauncherSelectionRead) -> Void) {
        generation += 1
        let current = generation
        isReading = true
        let budget = budget
        let begin = DispatchTime.now().uptimeNanoseconds
        queue.async {
            let outcome = read(budget)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000_000
            let result = LauncherSelectionRead(outcome: LauncherContextRules.finalize(outcome, elapsed: elapsed, budget: budget),
                                               milliseconds: elapsed * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.deliver(result, generation: current, completion: completion)
                }
            }
        }
        let limit = budget + grace
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            MainActor.assumeIsolated {
                self?.deliver(LauncherSelectionRead(outcome: .timedOut, milliseconds: limit * 1000),
                              generation: current, completion: completion)
            }
        }
    }

    /// 不要还没回来的那次（面板收起）。
    func cancel() {
        generation += 1
        isReading = false
    }

    private func deliver(_ result: LauncherSelectionRead, generation: Int,
                         completion: @MainActor (LauncherSelectionRead) -> Void) {
        guard generation == self.generation, isReading else { return }
        isReading = false
        completion(result)
    }
}
