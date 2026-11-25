import AppKit

// 快速入口空着的时候（docs/launcher/REQUIREMENTS.md §3.7、TECH_DESIGN.md §8.4、§5.6）：
// - 「选中的」：呼出前那个 App 里选中的文字。和记前台 App 同一刻、面板拿焦点之前开始读；只走辅助功能（Core 的
//   `SelectedTextReader`，不借剪贴板、不合成 ⌘C），在后台读、80 ms 封顶（`LauncherSelectionFetcher`），读到了再补上那一行，
//   不拖慢面板出现。没权限、读不到、全是空白、超时：就没有这一行，不提示。
// - 「刚复制的」：剪贴板历史里最新的一条（文字或图片；敏感条目本来就不交给快速入口），5 分钟内复制的才算。
//   从这次呼出已经取到的剪贴板条目里拿（带时间），不读系统剪贴板；文字用条目交来的完整原文（`LauncherEntry.fullText`）。
//   和选中的是同一段（空白归一后）时只出「选中的」。
// - 情景建议：各模块 `launcherContextSuggestions()` 此刻值得提一句的动作（只读内存），每次呼出收一次，按紧急程度
//   （`suggestion.priority`，小的在前）排好再取前 4 条；行 id / 使用记录的键
//   是 `commands/<id>`，和对应的命令同一个键。
// 两样上下文只在内存里显示成一行：不发给模型、不联网、不写盘，收起面板就丢。两个开关：`launcher.context.selection`、
// `launcher.context.clipboard`（默认开）。

/// 「选中的」「刚复制的」一行。⏎ / Tab 把它放进输入框：文字填进去（多行的记下原文，同 ⌘V），图片挂成附件。
struct LauncherContextItem {
    enum Fill {
        /// 完整原文。
        case text(String)
        /// 剪贴板历史里的图片：字节在后台取（来源要解密读盘）。
        case image(LauncherEntryImage)
    }

    let row: LauncherRow
    let fill: Fill

    /// 图片那一行的图（行首缩略图从这里取）。
    var image: LauncherEntryImage? {
        if case .image(let image) = fill { return image }
        return nil
    }
}

/// 空着时最前面的行（引擎拼进列表，`LauncherContextRules.layout`）：「选中的 / 刚复制的」+ 情景建议。
struct LauncherEmptyState {
    var context: [LauncherContextItem] = []
    /// 情景建议：键是 `commands/<id>`，⏎ 同命令（记使用、收起、等焦点回去再执行）。
    var situational: [LauncherItem] = []
}

/// 两个开关（设置页「快速入口」里各一行，默认开）。
enum LauncherContextSettings {
    static let selectionKey = "launcher.context.selection"
    static let clipboardKey = "launcher.context.clipboard"

    static var includesSelection: Bool {
        UserDefaults.standard.object(forKey: selectionKey) as? Bool ?? true
    }

    static var includesClipboard: Bool {
        UserDefaults.standard.object(forKey: clipboardKey) as? Bool ?? true
    }
}

@MainActor
final class LauncherContextProvider {
    static let selectionRowID = "context/selection"
    static let clipboardRowID = "context/clipboard"
    /// 「刚复制的」从哪个来源里取。
    static let clipboardSourceID = "clipboard"
    /// `beginSelectionRead` 的返回值：在后台读（结果之后回调）。
    static let readingStatus = "reading"

    /// 呼出时收情景建议、取剪贴板最新一条的统计（记进 `panel shown in … ms` 那条日志）。
    struct Report {
        /// 「刚复制的」：text / image / none / old（超过 5 分钟）/ off。
        let clipboard: String
        /// 情景建议几条、收集用了多少毫秒。
        let situational: Int
        let situationalMilliseconds: Double
    }

    /// 取词函数（后台线程调，参数是 pid 和时限）。
    typealias SelectionReader = @Sendable (pid_t, TimeInterval) -> LauncherSelectionOutcome

    private weak var registry: ToolRegistry?
    private let readSelection: SelectionReader
    private let fetcher = LauncherSelectionFetcher()
    /// 这次呼出读到的选中文字（收起即丢）。
    private var selection: String?
    /// 剪贴板最新一条（在窗口里的，收起即丢）。
    private var recentCopy: (copy: LauncherRecentCopy, image: LauncherEntryImage?, label: String)?
    private var situational: [LauncherItem] = []

    /// `readSelection`：默认只走辅助功能（Core 的 `SelectedTextReader`）；探针里换成假的。
    init(registry: ToolRegistry?,
         readSelection: @escaping SelectionReader = { pid, budget in
             LauncherContextProvider.readViaAccessibility(pid: pid, budget: budget)
         }) {
        self.registry = registry
        self.readSelection = readSelection
    }

    /// 只走辅助功能读 `pid` 焦点元素里选中的文字（不借剪贴板、不合成 ⌘C），总时限 `budget`。
    nonisolated static func readViaAccessibility(pid: pid_t, budget: TimeInterval) -> LauncherSelectionOutcome {
        switch SelectedTextReader.read(pid: pid, budget: budget) {
        case .text(let text): return .text(text)
        case .none: return .none
        case .timedOut: return .timedOut
        case .noPermission: return .noPermission
        }
    }

    // MARK: - 选中的

    /// 呼出、面板拿焦点之前调：在后台读 `pid`（呼出前的前台 App，`LauncherFocus.capture()` 返回的）里选中的文字，
    /// 读完在主线程调 `onRead`（读到了就有了「选中的」那一行，调用方刷新）。
    /// 返回这次读不读（日志用）：`reading` / `off` / `no app`（前台就是 Baobox 自己）。
    func beginSelectionRead(pid: pid_t?,
                            onRead: @escaping @MainActor (LauncherSelectionRead) -> Void) -> String {
        fetcher.cancel()
        selection = nil
        guard LauncherContextSettings.includesSelection else { return "off" }
        guard let pid else { return "no app" }
        let readSelection = readSelection
        fetcher.start({ budget in readSelection(pid, budget) }) { [weak self] read in
            guard let self else { return }
            if case .text(let text) = read.outcome { self.selection = text }
            onRead(read)
        }
        return Self.readingStatus
    }

    // MARK: - 刚复制的、情景建议

    /// 呼出时调（只读内存）：剪贴板最新一条（`latestClipboard`，这次呼出已经取到的条目里最新的）、各模块的情景建议。
    func prepare(latestClipboard: LauncherEntry?, now: Date) -> Report {
        let clipboard = prepareRecentCopy(latestClipboard, now: now)
        let start = DispatchTime.now().uptimeNanoseconds
        situational = collectSituational()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return Report(clipboard: clipboard, situational: situational.count, situationalMilliseconds: milliseconds)
    }

    /// 面板收起：不要还没回来的选区，两样上下文都丢掉。
    func endSession() {
        fetcher.cancel()
        selection = nil
        recentCopy = nil
        situational = []
    }

    /// 此刻空着时的行（选区读到之后再取一次就有「选中的」）。
    var emptyState: LauncherEmptyState {
        var context: [LauncherContextItem] = []
        if let selection {
            let words = LauncherCalcFormat.grouped(Int64(LauncherTextStats.count(selection).words))
            context.append(LauncherContextItem(
                row: LauncherRow(id: Self.selectionRowID, title: LauncherContextRules.title(selection),
                                 source: L("launcher.context.selection \(words)"), icon: .symbol("character.cursor.ibeam")),
                fill: .text(selection)))
        }
        if let recentCopy, LauncherContextRules.showsRecentCopy(recentCopy.copy, selection: selection, now: Date()) {
            switch recentCopy.copy.content {
            case .text(let text):
                context.append(LauncherContextItem(
                    row: LauncherRow(id: Self.clipboardRowID, title: LauncherContextRules.title(text),
                                     source: recentCopy.label, icon: .symbol("doc.on.clipboard")),
                    fill: .text(text)))
            case .image:
                if let image = recentCopy.image {
                    context.append(LauncherContextItem(
                        row: LauncherRow(id: Self.clipboardRowID, title: L("launcher.context.image"), source: recentCopy.label,
                                         icon: .thumbnail(placeholderSymbol: "photo")),
                        fill: .image(image)))
                }
            }
        }
        return LauncherEmptyState(context: context, situational: situational)
    }

    // MARK: - 内部

    private func prepareRecentCopy(_ entry: LauncherEntry?, now: Date) -> String {
        recentCopy = nil
        guard LauncherContextSettings.includesClipboard else { return "off" }
        guard let entry else { return "none" }
        guard LauncherContextRules.isRecentCopy(at: entry.date, now: now) else { return "old" }
        let content: LauncherRecentCopy.Content
        if entry.image != nil {
            content = .image
        } else if let text = entry.fullText?() {
            content = .text(text)
        } else {
            return "none"
        }
        let age = entry.date.map { now.timeIntervalSince($0) } ?? 0
        let label = LauncherContextRules.copiedMinutes(age: age).map { L("launcher.context.copiedMinutes \($0)") }
            ?? L("launcher.context.copiedJustNow")
        recentCopy = (LauncherRecentCopy(content: content, date: entry.date), entry.image, label)
        return entry.image == nil ? "text" : "image"
    }

    /// 各模块此刻的情景建议，按紧急程度排好（`suggestion.priority` 小的在前；同一优先级保持注册顺序、模块里写的顺序，
    /// `LauncherContextRules.situationalOrder`）。没有 id 的、带参数的不要（这里只能无参数执行）。上限 4 条在拼行时截。
    private func collectSituational() -> [LauncherItem] {
        guard let registry else { return [] }
        var collected: [(command: LauncherCommand, toolName: String)] = []
        for tool in registry.tools {
            for command in tool.launcherContextSuggestions() where !command.id.isEmpty && command.parameters.isEmpty {
                collected.append((command, tool.name))
            }
        }
        let order = LauncherContextRules.situationalOrder(priorities: collected.map(\.command.suggestion.priority))
        return order.map { index in
            let (command, toolName) = collected[index]
            let candidate = LauncherCandidate(sourceID: LauncherCommandProvider.sourceID, entryID: command.id, searchKeys: [])
            let row = LauncherRow(id: candidate.key, title: command.title, source: toolName, icon: .symbol(command.symbolName))
            return LauncherItem(candidate: candidate, row: row, run: { command.run([:]) })
        }
    }
}
