import Foundation
import XCTest

/// 快速入口的命令表：快捷键自动生成的 + 模块声明的合并规则，搜索文字与搜索键缓存（docs/launcher/TECH_DESIGN.md §3.1）。
@MainActor
final class LauncherCommandCatalogTests: XCTestCase {

    private func entry(_ id: String, _ title: String, tool: String = "截图", keywords: [String] = [],
                       parameters: [LauncherParameter] = []) -> LauncherCatalogCommand {
        LauncherCatalogCommand(
            command: LauncherCommand(id: id, title: title, keywords: keywords, symbolName: "camera",
                                     parameters: parameters) { _ in },
            toolID: "tool", toolName: tool)
    }

    private let duration = LauncherParameter(name: "duration", kind: .duration, required: false, hint: "多久")

    private func ids(_ entries: [LauncherCatalogCommand]) -> [String] {
        entries.map(\.command.id)
    }

    // MARK: - 合并

    func testAutomaticOnlyKeepsOrder() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("b", "B"), entry("a", "A"), entry("c", "C")], declared: [])
        XCTAssertEqual(ids(merged), ["b", "a", "c"])
    }

    func testDeclaredReplacesAutomaticInPlace() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("a", "A"), entry("b", "自动的 B"), entry("c", "C")],
            declared: [entry("b", "声明的 B", tool: "防休眠", keywords: ["别睡"])])
        XCTAssertEqual(ids(merged), ["a", "b", "c"])
        XCTAssertEqual(merged[1].command.title, "声明的 B")
        XCTAssertEqual(merged[1].command.keywords, ["别睡"])
        XCTAssertEqual(merged[1].toolName, "防休眠")
    }

    func testNewDeclaredCommandsGoAfterAutomaticInOrder() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("a", "A"), entry("b", "B")],
            declared: [entry("z", "Z"), entry("b", "B2"), entry("y", "Y")])
        XCTAssertEqual(ids(merged), ["a", "b", "z", "y"])
        XCTAssertEqual(merged[1].command.title, "B2")
    }

    func testExcludedIDsAreDroppedFromBothGroups() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("launcher.toggle", "打开快速入口"), entry("a", "A")],
            declared: [entry("launcher.toggle", "又一个"), entry("b", "B")],
            excludedIDs: ["launcher.toggle"])
        XCTAssertEqual(ids(merged), ["a", "b"])
    }

    func testParameterizedCommandsAreLeftOutByDefault() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("a", "A")],
            declared: [entry("caffeinate.start", "防休眠", parameters: [duration]), entry("b", "B")])
        XCTAssertEqual(ids(merged), ["a", "b"])
    }

    func testParameterizedDeclaredDoesNotHideTheAutomaticOneWithTheSameID() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("caffeinate.toggle", "开关防休眠")],
            declared: [entry("caffeinate.toggle", "防休眠多久", parameters: [duration])])
        XCTAssertEqual(ids(merged), ["caffeinate.toggle"])
        XCTAssertEqual(merged[0].command.title, "开关防休眠", "带参数的这次不收，快捷键那条照样能执行")
    }

    func testParameterizedCommandsCanBeIncluded() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("caffeinate.toggle", "开关防休眠")],
            declared: [entry("caffeinate.toggle", "防休眠多久", parameters: [duration])],
            includesParameterized: true)
        XCTAssertEqual(merged.map(\.command.title), ["防休眠多久"])
    }

    func testDuplicateIDsWithinAGroupKeepTheFirst() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("a", "第一个"), entry("a", "第二个")],
            declared: [entry("b", "B1"), entry("b", "B2")])
        XCTAssertEqual(merged.map(\.command.title), ["第一个", "B1"])
    }

    func testEmptyIDsAreDropped() {
        let merged = LauncherCommandCatalog.merge(automatic: [entry("", "没 id")], declared: [entry("", "也没有")])
        XCTAssertTrue(merged.isEmpty)
    }

    func testEmptyInputs() {
        XCTAssertTrue(LauncherCommandCatalog.merge(automatic: [], declared: []).isEmpty)
    }

    // MARK: - 文字动作

    private func textAction(_ id: String, _ title: String = "翻译", tool: String = "划词助手") -> LauncherCatalogCommand {
        LauncherCatalogCommand(command: .textAction(id: id, title: title, symbolName: "character.bubble") { _ in },
                               toolID: "tool", toolName: tool)
    }

    private let optionalText = LauncherParameter(name: "text", kind: .text, required: false, hint: "文字")
    private let requiredText = LauncherParameter(name: "text", kind: .text, required: true, hint: "文字")

    func testTextActionsNeverJoinTheSearchableCommands() {
        let declared = [textAction("selectiontranslate.text.translate"), entry("b", "B")]
        XCTAssertEqual(ids(LauncherCommandCatalog.merge(automatic: [entry("a", "A")], declared: declared)), ["a", "b"])
        XCTAssertEqual(ids(LauncherCommandCatalog.merge(automatic: [entry("a", "A")], declared: declared,
                                                        includesParameterized: true)), ["a", "b"],
                       "收带参数的命令时也不收文字动作：没有文字可给时执行不了")
    }

    func testTextActionWithAHotkeyIDDoesNotHideTheHotkeyCommand() {
        let merged = LauncherCommandCatalog.merge(
            automatic: [entry("selectiontranslate.translateSelection", "翻译选中文字")],
            declared: [textAction("selectiontranslate.translateSelection")])
        XCTAssertEqual(merged.map(\.command.title), ["翻译选中文字"])
    }

    func testTextActionsAreTheDeclaredCommandsWithExactlyOneRequiredTextParameter() {
        let declared = [
            textAction("t1"),
            entry("plain", "无参数"),
            entry("optional", "文字可选", parameters: [optionalText]),
            entry("two", "两个参数", parameters: [requiredText, duration]),
            entry("duration", "时长", parameters: [duration]),
            entry("manual", "手写的文字动作", parameters: [requiredText]),
            textAction("t2", "存为片段", tool: "剪贴板"),
        ]
        let actions = LauncherCommandCatalog.textActions(declared: declared)
        XCTAssertEqual(ids(actions), ["t1", "manual", "t2"])
        XCTAssertEqual(actions.last?.toolName, "剪贴板")
    }

    func testTextActionsDropEmptyExcludedAndDuplicateIDs() {
        let actions = LauncherCommandCatalog.textActions(
            declared: [textAction(""), textAction("launcher.toggle"), textAction("a", "第一个"), textAction("a", "第二个")],
            excludedIDs: ["launcher.toggle"])
        XCTAssertEqual(actions.map(\.command.title), ["第一个"])
    }

    // MARK: - 图片动作

    private func imageAction(_ id: String, _ title: String = "取字", tool: String = "截图") -> LauncherCatalogCommand {
        LauncherCatalogCommand(command: .imageAction(id: id, title: title, symbolName: "text.viewfinder") { _ in },
                               toolID: "tool", toolName: tool)
    }

    private let requiredImage = LauncherParameter(name: "image", kind: .image, required: true, hint: "图片")

    func testImageActionsNeverJoinTheSearchableCommands() {
        let declared = [imageAction("screenshot.image.ocr"), entry("b", "B")]
        XCTAssertEqual(ids(LauncherCommandCatalog.merge(automatic: [entry("a", "A")], declared: declared)), ["a", "b"])
        XCTAssertEqual(ids(LauncherCommandCatalog.merge(automatic: [entry("a", "A")], declared: declared,
                                                        includesParameterized: true)), ["a", "b"],
                       "收带参数的命令时也不收图片动作：没有图片可给时执行不了")
    }

    func testImageActionWithAHotkeyIDDoesNotHideTheHotkeyCommand() {
        let merged = LauncherCommandCatalog.merge(automatic: [entry("screenshot.ocr", "屏幕取字")],
                                                  declared: [imageAction("screenshot.ocr")])
        XCTAssertEqual(merged.map(\.command.title), ["屏幕取字"])
    }

    func testImageActionsAreTheDeclaredCommandsWithExactlyOneRequiredImageParameter() {
        let declared = [
            imageAction("i1"),
            textAction("text"),
            entry("plain", "无参数"),
            entry("optional", "图片可选", parameters: [LauncherParameter(name: "image", kind: .image, required: false, hint: "")]),
            entry("two", "图片 + 时长", parameters: [requiredImage, duration]),
            entry("manual", "手写的图片动作", parameters: [requiredImage]),
            imageAction("i2", "钉在屏幕上"),
        ]
        XCTAssertEqual(ids(LauncherCommandCatalog.imageActions(declared: declared)), ["i1", "manual", "i2"])
        XCTAssertEqual(ids(LauncherCommandCatalog.textActions(declared: declared)), ["text"], "两张表互不相干")
    }

    func testImageActionsDropEmptyExcludedAndDuplicateIDs() {
        let actions = LauncherCommandCatalog.imageActions(
            declared: [imageAction(""), imageAction("launcher.toggle"), imageAction("a", "第一个"), imageAction("a", "第二个")],
            excludedIDs: ["launcher.toggle"])
        XCTAssertEqual(actions.map(\.command.title), ["第一个"])
    }

    // MARK: - 搜索文字

    func testSearchTextsStartWithTitleThenKeywordsThenToolAndTitle() {
        let texts = LauncherCommandCatalog.searchTexts(
            for: entry("caffeinate.toggle", "关闭防休眠", tool: "防休眠", keywords: ["别睡", "保持唤醒"]))
        XCTAssertEqual(texts, ["关闭防休眠", "别睡", "保持唤醒", "防休眠 关闭防休眠"])
    }

    func testSearchTextsDropBlankAndDuplicates() {
        let texts = LauncherCommandCatalog.searchTexts(
            for: entry("x", "区域截图", tool: "  ", keywords: ["", " ", "区域截图", "截屏"]))
        XCTAssertEqual(texts, ["区域截图", "截屏"])
    }

    func testToolNameFindsItsCommandsWithoutBeatingAnExactTitle() {
        // 「截图」是工具名，也是另一个工具里一条命令的完整标题：完全相等的那条排第一，截图工具的命令跟在后面。
        let catalog = [
            entry("screenshot.area", "区域截图", tool: "截图"),
            entry("screenshot.window", "窗口截图", tool: "截图"),
            entry("other.capture", "截图", tool: "别的工具"),
        ]
        var cache = LauncherCommandKeyCache()
        let keys = cache.keys(for: catalog)
        let candidates = zip(catalog, keys).map { item, keys in
            LauncherCandidate(sourceID: "commands", entryID: item.command.id, searchKeys: keys)
        }
        let result = LauncherRanking.rank(candidates, query: "截图", records: LauncherUsageRecords(),
                                          now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.keys.first, "commands/other.capture")
        XCTAssertEqual(Set(result.keys), ["commands/other.capture", "commands/screenshot.area", "commands/screenshot.window"])
        XCTAssertLessThan(result.items[1].matchScore, LauncherMatch.exactScore)
    }

    func testToolNameAndTitleTogetherMatch() {
        var cache = LauncherCommandKeyCache()
        let catalog = [entry("screenshot.area", "区域截图", tool: "截图"), entry("ocr", "屏幕取字", tool: "截图")]
        let keys = cache.keys(for: catalog)
        let candidates = zip(catalog, keys).map { item, keys in
            LauncherCandidate(sourceID: "commands", entryID: item.command.id, searchKeys: keys)
        }
        let result = LauncherRanking.rank(candidates, query: "截图 区域", records: LauncherUsageRecords(),
                                          now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.keys, ["commands/screenshot.area"])
    }

    // MARK: - 搜索键缓存

    func testCacheReusesKeysWhenNothingChanged() {
        var cache = LauncherCommandKeyCache()
        let catalog = [entry("a", "区域截图"), entry("b", "屏幕取字")]
        let first = cache.keys(for: catalog)
        XCTAssertEqual(cache.buildCount, 2)
        let second = cache.keys(for: catalog)
        XCTAssertEqual(cache.buildCount, 2, "第二次呼出不再建")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[0].first?.original.text, "区域截图")
    }

    func testCacheRebuildsOnlyWhatChanged() {
        var cache = LauncherCommandKeyCache()
        _ = cache.keys(for: [entry("caffeinate.toggle", "开关防休眠", tool: "防休眠"), entry("b", "屏幕取字")])
        XCTAssertEqual(cache.buildCount, 2)
        let keys = cache.keys(for: [entry("caffeinate.toggle", "关闭防休眠", tool: "防休眠"), entry("b", "屏幕取字")])
        XCTAssertEqual(cache.buildCount, 3, "只有标题变了的那条重建")
        XCTAssertEqual(keys[0].first?.original.text, "关闭防休眠")
        _ = cache.keys(for: [entry("caffeinate.toggle", "关闭防休眠", tool: "防休眠"), entry("c", "新命令")])
        XCTAssertEqual(cache.buildCount, 4, "新出现的补建")
    }

    func testCacheForgetsCommandsThatWentAway() {
        var cache = LauncherCommandKeyCache()
        _ = cache.keys(for: [entry("a", "A")])
        _ = cache.keys(for: [])
        _ = cache.keys(for: [entry("a", "A")])
        XCTAssertEqual(cache.buildCount, 2, "上一次没出现的已经从缓存里删了")
    }

    func testCacheKeysFollowInputOrder() {
        var cache = LauncherCommandKeyCache()
        let keys = cache.keys(for: [entry("b", "B 命令"), entry("a", "A 命令")])
        XCTAssertEqual(keys.map { $0.first?.original.text }, ["b 命令", "a 命令"])
    }
}
