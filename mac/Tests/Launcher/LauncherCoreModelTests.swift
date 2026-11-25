import Foundation
import XCTest

/// `Core/Launcher` 的命令与条目模型（docs/launcher/TECH_DESIGN.md §3.1、§3.2）。
/// 能在测试 target 里构造，也就钉住了这两个文件只依赖 Foundation。
@MainActor
final class LauncherCoreModelTests: XCTestCase {

    // MARK: - LauncherCommand

    func testCommandDefaults() {
        let command = LauncherCommand(id: "caffeinate.stop", title: "关闭防休眠", symbolName: "cup.and.saucer") { _ in }
        XCTAssertEqual(command.id, "caffeinate.stop")
        XCTAssertEqual(command.keywords, [])
        XCTAssertTrue(command.parameters.isEmpty)
        XCTAssertFalse(command.destructive)
    }

    func testCommandRunReceivesArguments() {
        var received: [String: LauncherArgument] = [:]
        let command = LauncherCommand(
            id: "caffeinate.start",
            title: "防休眠",
            keywords: ["别睡", "保持唤醒"],
            symbolName: "cup.and.saucer",
            parameters: [LauncherParameter(name: "duration", kind: .duration, required: false, hint: "多久")]
        ) { received = $0 }

        XCTAssertEqual(command.parameters.first?.kind, .duration)
        command.run(["duration": .duration(7200)])
        XCTAssertEqual(received, ["duration": .duration(7200)])
    }

    // MARK: - 文字动作

    func testCommandsAreNotTextActionsByDefault() {
        let command = LauncherCommand(id: "caffeinate.stop", title: "关闭防休眠", symbolName: "cup.and.saucer") { _ in }
        XCTAssertFalse(command.isTextAction)
        XCTAssertNil(command.textParameterName)
        XCTAssertEqual(command.suggestion, LauncherSuggestionTraits(), "不声明就是默认值：任何文字、优先级 50、不提前")
        XCTAssertEqual(command.suggestion.kinds, Set(LauncherTextKind.allCases))
        XCTAssertEqual(command.suggestion.priority, 50)
        XCTAssertTrue(command.suggestion.boostedKinds.isEmpty)
    }

    func testTextActionFactoryHandsTheTextOver() {
        var received: [String] = []
        let traits = LauncherSuggestionTraits(kinds: [.word], priority: 10, boostedKinds: [.word])
        let command = LauncherCommand.textAction(id: "selectiontranslate.text.learn", title: "学习", symbolName: "book",
                                                 suggestion: traits) { received.append($0) }
        XCTAssertTrue(command.isTextAction)
        XCTAssertEqual(command.textParameterName, "text")
        XCTAssertEqual(command.parameters.first?.kind, .text)
        XCTAssertEqual(command.parameters.first?.required, true)
        XCTAssertEqual(command.suggestion, traits)
        command.run(["text": .text("serendipity")])
        command.run([:])
        command.run(["text": .number(3)])
        XCTAssertEqual(received, ["serendipity"], "没给文字、给错类型都不执行")
    }

    func testOnlyOneRequiredTextParameterMakesATextAction() {
        func command(_ parameters: [LauncherParameter]) -> LauncherCommand {
            LauncherCommand(id: "x", title: "x", symbolName: "x", parameters: parameters) { _ in }
        }
        let text = LauncherParameter(name: "body", kind: .text, required: true, hint: "")
        XCTAssertTrue(command([text]).isTextAction)
        XCTAssertEqual(command([text]).textParameterName, "body")
        XCTAssertFalse(command([LauncherParameter(name: "body", kind: .text, required: false, hint: "")]).isTextAction)
        XCTAssertFalse(command([text, text]).isTextAction)
        XCTAssertFalse(command([LauncherParameter(name: "d", kind: .duration, required: true, hint: "")]).isTextAction)
        XCTAssertFalse(command([LauncherParameter(name: "c", kind: .clipboardRef, required: true, hint: "")]).isTextAction)
    }

    func testParameterKindsAndArgumentsCompare() {
        XCTAssertEqual(LauncherParameter.Kind.choice(["en", "zh"]), .choice(["en", "zh"]))
        XCTAssertNotEqual(LauncherParameter.Kind.choice(["en", "zh"]), .choice(["en"]))
        XCTAssertNotEqual(LauncherParameter.Kind.text, .clipboardRef)
        XCTAssertNotEqual(LauncherArgument.number(2), .duration(2))
        XCTAssertEqual(LauncherArgument.clipboardRef, .clipboardRef)
        XCTAssertNotEqual(LauncherParameter.Kind.image, .text)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(LauncherArgument.image(.data(bytes)), .image(.data(bytes)))
        XCTAssertNotEqual(LauncherArgument.image(.data(bytes)), .image(.data(Data([0x89]))))
        XCTAssertNotEqual(LauncherArgument.image(.file(URL(fileURLWithPath: "/a.png"))),
                          .image(.file(URL(fileURLWithPath: "/b.png"))))
        XCTAssertNotEqual(LauncherImage.data(bytes), .file(URL(fileURLWithPath: "/a.png")))
    }

    // MARK: - 图片动作

    func testCommandsAreNotImageActionsByDefault() {
        let command = LauncherCommand(id: "screenshot.capture", title: "截图", symbolName: "viewfinder") { _ in }
        XCTAssertFalse(command.isImageAction)
        XCTAssertNil(command.imageParameterName)
        XCTAssertNil(command.suggestion.imageTextPriority, "文字动作默认不用在图里的文字上")
        XCTAssertFalse(LauncherCommand.textAction(id: "t", title: "翻译", symbolName: "x") { _ in }.isImageAction)
    }

    func testImageActionFactoryHandsTheImageOver() {
        var received: [LauncherImage] = []
        let command = LauncherCommand.imageAction(id: "screenshot.image.pin", title: "钉在屏幕上", symbolName: "pin",
                                                  keywords: ["贴图"], suggestion: LauncherSuggestionTraits(priority: 20)) {
            received.append($0)
        }
        XCTAssertTrue(command.isImageAction)
        XCTAssertFalse(command.isTextAction)
        XCTAssertEqual(command.imageParameterName, "image")
        XCTAssertEqual(command.parameters.first?.kind, .image)
        XCTAssertEqual(command.parameters.first?.required, true)
        XCTAssertEqual(command.keywords, ["贴图"])
        XCTAssertEqual(command.suggestion.priority, 20)
        let file = LauncherImage.file(URL(fileURLWithPath: "/tmp/a.png"))
        command.run(["image": .image(file)])
        command.run([:])
        command.run(["image": .text("a.png")])
        XCTAssertEqual(received, [file], "没给图片、给错类型都不执行")
    }

    func testOnlyOneRequiredImageParameterMakesAnImageAction() {
        func command(_ parameters: [LauncherParameter]) -> LauncherCommand {
            LauncherCommand(id: "x", title: "x", symbolName: "x", parameters: parameters) { _ in }
        }
        let image = LauncherParameter(name: "picture", kind: .image, required: true, hint: "")
        XCTAssertTrue(command([image]).isImageAction)
        XCTAssertEqual(command([image]).imageParameterName, "picture")
        XCTAssertFalse(command([LauncherParameter(name: "picture", kind: .image, required: false, hint: "")]).isImageAction)
        XCTAssertFalse(command([image, image]).isImageAction)
        XCTAssertFalse(command([LauncherParameter(name: "t", kind: .text, required: true, hint: "")]).isImageAction)
    }

    func testImageTextPriorityIsPartOfTheTraits() {
        let traits = LauncherSuggestionTraits(priority: 10, imageTextPriority: 15)
        XCTAssertEqual(traits.imageTextPriority, 15)
        XCTAssertNotEqual(traits, LauncherSuggestionTraits(priority: 10))
    }

    // MARK: - LauncherEntry / LauncherSearchable

    func testEntryImageDefaults() {
        let plain = LauncherEntry(id: "1", title: "curl", subtitle: "", searchText: "curl", symbolName: "doc.text") {}
        XCTAssertNil(plain.image)
        XCTAssertFalse(plain.onlyWithPrefix)

        let bytes = Data([1, 2, 3])
        let picture = LauncherEntry(id: "2", title: "图片 · 微信", subtitle: "3 分钟前", searchText: "图片 · 微信\nimage",
                                    symbolName: "photo",
                                    image: LauncherEntryImage(cacheKey: "abc.png", loadData: { bytes }),
                                    onlyWithPrefix: true) {}
        XCTAssertEqual(picture.image?.cacheKey, "abc.png")
        XCTAssertEqual(picture.image?.loadData(), bytes)
        XCTAssertTrue(picture.onlyWithPrefix)
    }

    private struct FakeSource: LauncherSearchable {
        let entries: [LauncherEntry]
        var launcherSourceID: String { "clipboard" }
        var launcherSourceName: String { "剪贴板" }
        func launcherEntries() -> [LauncherEntry] { entries }
    }

    func testEntryDefaultsAndActions() {
        var log: [String] = []
        let plain = LauncherEntry(id: "1", title: "curl", subtitle: "终端", searchText: "curl localhost",
                                  symbolName: "doc.on.clipboard") { log.append("paste") }
        XCTAssertNil(plain.date)
        XCTAssertTrue(plain.actions.isEmpty)

        let withActions = LauncherEntry(
            id: "2", title: "token", subtitle: "", searchText: "token", symbolName: "doc.on.clipboard",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            actions: [
                LauncherEntryAction(id: "copy", title: "复制", symbolName: "doc.on.doc") { log.append("copy") },
                LauncherEntryAction(id: "delete", title: "删除", symbolName: "trash", destructive: true) { log.append("delete") },
            ]
        ) { log.append("paste2") }
        XCTAssertEqual(withActions.actions.map(\.id), ["copy", "delete"])
        XCTAssertEqual(withActions.actions.map(\.destructive), [false, true])

        let source: any LauncherSearchable = FakeSource(entries: [plain, withActions])
        XCTAssertEqual(source.launcherSourceID, "clipboard")
        let entries = source.launcherEntries()
        entries.first?.primary()
        entries.last?.actions.last?.run()
        XCTAssertEqual(log, ["paste", "delete"])
    }

    // MARK: - LauncherEntryText

    func testEntryTitleIsTheFirstLineAndSearchTextIsTheHead() {
        let parts = LauncherEntryText.parts("\n\n   docker run -it   \n  ubuntu bash\n\n")
        XCTAssertEqual(parts.title, "docker run -it")
        XCTAssertEqual(parts.searchText, "docker run -it   \n  ubuntu bash")
        XCTAssertTrue(parts.searchText.hasPrefix(parts.title))
    }

    func testEntryTextLimits() {
        let long = String(repeating: "长", count: 500)
        let parts = LauncherEntryText.parts(long)
        XCTAssertEqual(parts.title.count, LauncherEntryText.maxTitleLength)
        XCTAssertEqual(parts.searchText.count, LauncherEntryText.maxSearchLength)
        XCTAssertTrue(parts.searchText.hasPrefix(parts.title))

        let small = LauncherEntryText.parts("abcdef\nxyz", maxTitleLength: 3, maxSearchLength: 8)
        XCTAssertEqual(small.title, "abc")
        XCTAssertEqual(small.searchText, "abcdef\nx")
    }

    func testEntryTextBlank() {
        XCTAssertEqual(LauncherEntryText.parts("").title, "")
        XCTAssertEqual(LauncherEntryText.parts(" \n\t ").searchText, "")
    }

    func testEntryTitleAlwaysStartsTheSearchText() {
        for text in ["a", " a b ", "x\ny", "\t\tfoo   \n", "e\u{301}clair\nb", "😀 smile", String(repeating: "ab ", count: 100)] {
            let parts = LauncherEntryText.parts(text)
            XCTAssertTrue(parts.searchText.hasPrefix(parts.title), text)
        }
    }

    func testRelativeBuckets() {
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: -5), 0, "将来的当成现在")
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 59), 0)
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 61), 60)
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 3_599), 59 * 60)
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 3_600 * 5 + 10), 3_600 * 5)
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 86_400 * 3 + 100), 86_400 * 3)
        XCTAssertEqual(LauncherEntryText.relativeBucket(age: 86_400 * 65), 86_400 * 60)
        // 一天里的几千条只落在几十个桶里。
        let buckets = Set((0..<5000).map { LauncherEntryText.relativeBucket(age: Double($0) * 17) })
        XCTAssertLessThan(buckets.count, 90)
    }

    // MARK: - 刷新节流（PR 11：Claude Code 交已知文件时顺带刷新最近文件）

    func testRefreshThrottleRunsAtMostOncePerInterval() {
        var throttle = LauncherRefreshThrottle(interval: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.shouldRun(now: start), "第一次")
        XCTAssertFalse(throttle.shouldRun(now: start.addingTimeInterval(5)))
        XCTAssertFalse(throttle.shouldRun(now: start.addingTimeInterval(29.9)))
        XCTAssertTrue(throttle.shouldRun(now: start.addingTimeInterval(30)), "到了间隔")
        XCTAssertFalse(throttle.shouldRun(now: start.addingTimeInterval(40)), "从上次做的时候重新算")
        XCTAssertEqual(throttle.lastRun, start.addingTimeInterval(30))
    }
}
