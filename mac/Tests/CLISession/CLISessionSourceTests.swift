import Foundation
import XCTest

/// 会话列表的两种搜索（docs/codex-assistant/DEDUPE-P2.md §2.4 类 1）：面板的 `CLISessionSource.sessions(matching:)`（原 `QuickSwitchSessionSource`，
/// #164 PR3 改名搬家后照旧）与中心窗口会话页的 `CLISessionsPageSearch.filter`（两个中心窗口原来各写一份）。两者有意不同，这里一并钉住。
@MainActor
final class CLISessionSourceTests: XCTestCase {

    /// 只有会话列表的数据源；另外三件事测试用不到。
    private struct FakeSource: CLISessionSource {
        let sessions: [FakeSessionSummary]
        func refresh() {}
        func metadataLine(for session: FakeSessionSummary) -> String { session.projectName }
        func resume(_ session: FakeSessionSummary) {}
        func resumeCommand(for session: FakeSessionSummary) -> String { session.id }
    }

    private let sessions = [
        fakeSession("Fix the Login bug", project: "app", path: "/Users/me/work/app"),
        fakeSession("整理周报", project: "notes", path: "/Users/me/文档/notes"),
        fakeSession("Release notes", project: "Baobox", path: "/Users/me/src/Baobox"),
        fakeSession("Café menu", project: "", path: ""),
        fakeSession("refactor", project: "tools", path: "/Users/me/secret-dir/tools"),
    ]

    private func panel(_ query: String) -> [String] {
        FakeSource(sessions: sessions).sessions(matching: query).map(\.title)
    }

    private func page(_ query: String) -> [String] {
        CLISessionsPageSearch.filter(sessions, query: query).map(\.title)
    }

    private var allTitles: [String] { sessions.map(\.title) }

    // MARK: - 面板

    func testPanelMatchesTitleProjectAndPathIgnoringCase() {
        XCTAssertEqual(panel(""), allTitles, "空查询原样返回，顺序不变")
        XCTAssertEqual(panel("LOGIN"), ["Fix the Login bug"])
        XCTAssertEqual(panel("notes"), ["整理周报", "Release notes"], "项目名与标题都算，顺序照列表")
        XCTAssertEqual(panel("secret-dir"), ["refactor"], "面板也看项目路径")
        XCTAssertEqual(panel("café"), ["Café menu"])
        XCTAssertEqual(panel("文档"), ["整理周报"])
    }

    func testPanelDoesNotTrimTheQuery() {
        XCTAssertEqual(panel("  login"), [], "首尾空格也算要匹配的字符（同原来）")
        XCTAssertEqual(panel(" "), ["Fix the Login bug", "Release notes", "Café menu"], "只有空格的查询照样过滤：留下标题里有空格的")
    }

    // MARK: - 中心窗口会话页

    func testPageTrimsSpacesAndMatchesTitleOrProjectIgnoringCase() {
        XCTAssertEqual(page("  LOGIN \t"), ["Fix the Login bug"], "去掉首尾空格与制表符再比")
        XCTAssertEqual(page("notes"), ["整理周报", "Release notes"])
        XCTAssertEqual(page("BAOBOX"), ["Release notes"], "项目名不区分大小写")
        XCTAssertEqual(page("CAFÉ"), ["Café menu"], "非 ASCII 字母也按 lowercased() 比")
        XCTAssertEqual(page("the login"), ["Fix the Login bug"], "中间的空格保留")
    }

    func testPageQueryOfOnlySpacesReturnsEverything() {
        XCTAssertEqual(page(""), allTitles)
        XCTAssertEqual(page("   "), allTitles, "去掉首尾空格后为空：原样返回")
        XCTAssertEqual(page("\t "), allTitles)
    }

    func testPageDoesNotLookAtTheProjectPath() {
        XCTAssertEqual(page("secret-dir"), [], "只看标题与项目名（面板多看项目路径）")
        XCTAssertEqual(page("/Users/me"), [])
        XCTAssertEqual(page("文档"), [])
    }

    func testPageKeepsNewlines() {
        XCTAssertEqual(page("login\n"), [], "只去空格（.whitespaces），换行不去，同原来")
        XCTAssertEqual(page("\n"), [], "只有换行的查询不算空")
    }

    func testPageOnEmptyListIsEmpty() {
        XCTAssertEqual(CLISessionsPageSearch.filter([FakeSessionSummary](), query: "x"), [])
        XCTAssertEqual(CLISessionsPageSearch.filter([FakeSessionSummary](), query: " "), [])
    }
}

private func fakeSession(_ title: String, project: String, path: String) -> FakeSessionSummary {
    FakeSessionSummary(id: UUID().uuidString, fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jsonl"),
                       projectPath: path, projectName: project, title: title,
                       lastActivity: Date(timeIntervalSince1970: 0))
}
