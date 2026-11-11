import Foundation
import XCTest

/// 面板列表的过滤与选中（docs/codex-assistant/DEDUPE.md §4.3、§7.1）。
final class QuickSwitchSelectionTests: XCTestCase {

    /// 与会话摘要同样的三个搜索字段。
    private struct Item: Equatable {
        let title: String
        let projectName: String
        let projectPath: String
    }

    private static let fields: [KeyPath<Item, String>] = [\.title, \.projectName, \.projectPath]

    private let items = [
        Item(title: "Fix the Login bug", projectName: "app", projectPath: "/Users/me/work/app"),
        Item(title: "整理周报", projectName: "notes", projectPath: "/Users/me/文档/notes"),
        Item(title: "Release notes", projectName: "Baobox", projectPath: "/Users/me/src/Baobox"),
        Item(title: "Café menu", projectName: "", projectPath: ""),
    ]

    private func titles(_ query: String) -> [String] {
        QuickSwitchSelection.filter(items, query: query, fields: Self.fields).map(\.title)
    }

    // MARK: - filter

    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(QuickSwitchSelection.filter(items, query: "", fields: Self.fields), items)
        XCTAssertEqual(QuickSwitchSelection.filter([Item](), query: "", fields: Self.fields), [])
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(titles("login"), ["Fix the Login bug"])
        XCTAssertEqual(titles("LOGIN"), ["Fix the Login bug"])
        XCTAssertEqual(titles("CAFÉ"), ["Café menu"], "非 ASCII 字母也按 lowercased() 比")
    }

    func testAnyFieldCanMatchAndOrderIsKept() {
        XCTAssertEqual(titles("notes"), ["整理周报", "Release notes"], "项目名命中与标题命中都算，顺序同输入")
        XCTAssertEqual(titles("/src/"), ["Release notes"], "项目路径命中")
        XCTAssertEqual(titles("周报"), ["整理周报"])
        XCTAssertEqual(titles("文档"), ["整理周报"], "路径里的中文")
        XCTAssertEqual(titles("zzz"), [])
    }

    func testQueryIsNotTrimmed() {
        // 记录现状：首尾空格也是要匹配的字符。
        XCTAssertEqual(titles(" notes"), ["Release notes"], "只有标题里有「 notes」")
        XCTAssertEqual(titles("app "), [], "没有哪个字段含「app 」")
        XCTAssertEqual(titles(" "), ["Fix the Login bug", "Release notes", "Café menu"], "单个空格匹配含空格的标题")
    }

    func testOnlyTheGivenFieldsAreSearched() {
        // 只按给的字段找：不给 projectPath 时路径命中不算。
        let byTitle = QuickSwitchSelection.filter(items, query: "/src/", fields: [\Item.title, \Item.projectName])
        XCTAssertEqual(byTitle, [])
        XCTAssertEqual(QuickSwitchSelection.filter(items, query: "app", fields: []), [], "没有字段就什么也不留")
    }

    // MARK: - moved

    func testMovedStaysInsideTheList() {
        XCTAssertEqual(QuickSwitchSelection.moved(0, by: 1, count: 3), 1)
        XCTAssertEqual(QuickSwitchSelection.moved(2, by: 1, count: 3), 2, "末项再往下不动")
        XCTAssertEqual(QuickSwitchSelection.moved(0, by: -1, count: 3), 0, "首项再往上不动")
        XCTAssertEqual(QuickSwitchSelection.moved(1, by: 10, count: 3), 2)
        XCTAssertEqual(QuickSwitchSelection.moved(1, by: -10, count: 3), 0)
        XCTAssertEqual(QuickSwitchSelection.moved(7, by: -1, count: 3), 2, "越界的下标先移再夹紧")
        XCTAssertEqual(QuickSwitchSelection.moved(-4, by: 1, count: 3), 0)
    }

    func testMovedDoesNothingOnAnEmptyList() {
        XCTAssertEqual(QuickSwitchSelection.moved(0, by: 1, count: 0), 0)
        XCTAssertEqual(QuickSwitchSelection.moved(5, by: -1, count: 0), 5, "空列表时原样返回，不归零")
    }

    // MARK: - clamped

    func testClampedPullsBackPastTheEnd() {
        XCTAssertEqual(QuickSwitchSelection.clamped(1, count: 3), 1)
        XCTAssertEqual(QuickSwitchSelection.clamped(2, count: 3), 2)
        XCTAssertEqual(QuickSwitchSelection.clamped(3, count: 3), 2)
        XCTAssertEqual(QuickSwitchSelection.clamped(9, count: 1), 0)
    }

    func testClampedZeroesOnAnEmptyListAndLeavesNegativesAlone() {
        XCTAssertEqual(QuickSwitchSelection.clamped(4, count: 0), 0)
        XCTAssertEqual(QuickSwitchSelection.clamped(0, count: 0), 0)
        // 记录现状：负数不往上夹（面板里的下标不会是负数）。
        XCTAssertEqual(QuickSwitchSelection.clamped(-1, count: 3), -1)
    }

    // MARK: - cycled

    func testCycledWrapsBothWays() {
        // 全部 → 文档 → 网页 → 代码 → 配置 → 其他 → 全部（6 项）。
        XCTAssertEqual(QuickSwitchSelection.cycled(0, by: 1, count: 6), 1)
        XCTAssertEqual(QuickSwitchSelection.cycled(5, by: 1, count: 6), 0)
        XCTAssertEqual(QuickSwitchSelection.cycled(0, by: -1, count: 6), 5)
        XCTAssertEqual(QuickSwitchSelection.cycled(2, by: 13, count: 6), 3)
        XCTAssertEqual(QuickSwitchSelection.cycled(2, by: -13, count: 6), 1)
    }

    func testCycledOnTinyLists() {
        XCTAssertEqual(QuickSwitchSelection.cycled(0, by: 1, count: 1), 0)
        XCTAssertEqual(QuickSwitchSelection.cycled(0, by: -1, count: 1), 0)
        XCTAssertEqual(QuickSwitchSelection.cycled(3, by: 1, count: 0), 0, "空列表不崩，返回 0")
    }

    // MARK: - element

    func testElementReturnsNilOutsideTheList() {
        let list = ["a", "b", "c"]
        XCTAssertEqual(QuickSwitchSelection.element(list, at: 0), "a")
        XCTAssertEqual(QuickSwitchSelection.element(list, at: 2), "c")
        XCTAssertNil(QuickSwitchSelection.element(list, at: 3))
        XCTAssertNil(QuickSwitchSelection.element(list, at: -1))
        XCTAssertNil(QuickSwitchSelection.element([String](), at: 0))
    }
}
