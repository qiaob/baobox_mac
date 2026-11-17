import Foundation

/// 中心窗口会话页的搜索（两个中心窗口原来各写一份、逐行相同，#164 PR3 收成这一份）。
/// 和面板的 `sessions(matching:)` 有两处不同，都照原来、有意不统一：查询先去掉首尾空格（`.whitespaces`，换行不去）；只看标题与项目名、不看项目路径。
enum CLISessionsPageSearch {
    /// 去掉首尾空格后为空就原样返回；否则留下标题或项目名 `lowercased()` 后包含查询 `lowercased()` 的会话，顺序不变。
    static func filter<Session: CLISessionSummary>(_ sessions: [Session], query: String) -> [Session] {
        QuickSwitchSelection.filter(sessions, query: query.trimmingCharacters(in: .whitespaces),
                                    fields: [\.title, \.projectName])
    }
}
