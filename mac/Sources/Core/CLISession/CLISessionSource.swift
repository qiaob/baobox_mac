import Foundation

/// 快速切换面板「会话」那一栏、中心窗口「会话」页要的东西（#109，docs/codex-assistant/DEDUPE.md §4.3）。
/// Claude Code 助手、Codex 助手各实现一个（放各自模块）：两边的不同全在这里，窗口外壳、键码、过滤与选中、会话栏视图都是共用的。
/// #164 PR3 起中心窗口也用（`Core/CLICenter/CLISessionsPage.swift`），由 `QuickSwitchSessionSource` 改名挪来，签名不变。
@MainActor
protocol CLISessionSource {
    associatedtype Session: CLISessionSummary

    /// 新→旧；读会话索引的内存列表，零磁盘 IO。
    var sessions: [Session] { get }
    /// 面板打开时调：后台刷新会话索引。
    func refresh()
    /// 行的第二行；空串 = 不显示（面板；中心窗口的会话页同原来 Claude 的行，空串也放一个 Text）。
    func metadataLine(for session: Session) -> String
    /// ⏎ / 双击续接；调用前面板已收起。
    func resume(_ session: Session)
    /// ⌘C：可直接粘贴执行的续接命令。
    func resumeCommand(for session: Session) -> String
}

extension CLISessionSource {
    /// 搜索框过滤：标题 / 项目名 / 项目路径任一包含查询（不区分大小写）。
    func sessions(matching query: String) -> [Session] {
        QuickSwitchSelection.filter(sessions, query: query, fields: [\.title, \.projectName, \.projectPath])
    }
}
