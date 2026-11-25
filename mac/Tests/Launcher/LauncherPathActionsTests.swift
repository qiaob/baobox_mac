import Foundation
import XCTest

/// 路径行的动作与文件动作（docs/launcher/TECH_DESIGN.md §6.5「路径行的动作」，第 10 步）。
@MainActor
final class LauncherPathActionsTests: XCTestCase {

    // MARK: - 文件动作

    func testFileActionFactoryHandsTheFileOver() {
        var received: URL?
        let command = LauncherCommand.fileAction(id: "phonetransfer.file.send", title: "发到手机",
                                                 symbolName: "iphone") { received = $0 }
        XCTAssertTrue(command.isFileAction)
        XCTAssertFalse(command.isTextAction)
        XCTAssertFalse(command.isImageAction)
        XCTAssertEqual(command.fileParameterName, LauncherCommand.fileParameterKey)
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        command.run([LauncherCommand.fileParameterKey: .file(url)])
        XCTAssertEqual(received, url)
        received = nil
        command.run([LauncherCommand.fileParameterKey: .text("/tmp/a.txt")])
        XCTAssertNil(received, "参数类型不对就不执行")
    }

    func testOnlyOneRequiredFileParameterMakesAFileAction() {
        func command(_ parameters: [LauncherParameter]) -> LauncherCommand {
            LauncherCommand(id: "x", title: "x", symbolName: "x", parameters: parameters) { _ in }
        }
        XCTAssertFalse(command([]).isFileAction)
        XCTAssertFalse(command([LauncherParameter(name: "f", kind: .file, required: false, hint: "")]).isFileAction)
        XCTAssertFalse(command([LauncherParameter(name: "f", kind: .file, required: true, hint: ""),
                                LauncherParameter(name: "g", kind: .text, required: true, hint: "")]).isFileAction)
        XCTAssertFalse(command([LauncherParameter(name: "i", kind: .image, required: true, hint: "")]).isFileAction)
        XCTAssertNil(command([]).fileParameterName)
        XCTAssertEqual(LauncherArgument.file(URL(fileURLWithPath: "/a")), .file(URL(fileURLWithPath: "/a")))
        XCTAssertNotEqual(LauncherParameter.Kind.file, .image)
    }

    func testFileActionsStayOutOfTheCommandListAndGetTheirOwnTable() {
        let entries = [
            LauncherCatalogCommand(command: LauncherCommand.fileAction(id: "phonetransfer.file.send", title: "发到手机",
                                                                      symbolName: "iphone") { _ in },
                                   toolID: "phonetransfer", toolName: "手机互传"),
            LauncherCatalogCommand(command: LauncherCommand.textAction(id: "phonetransfer.text.send", title: "发到手机",
                                                                      symbolName: "iphone") { _ in },
                                   toolID: "phonetransfer", toolName: "手机互传"),
            LauncherCatalogCommand(command: LauncherCommand.fileAction(id: "phonetransfer.file.send", title: "重复",
                                                                      symbolName: "iphone") { _ in },
                                   toolID: "phonetransfer", toolName: "手机互传"),
        ]
        XCTAssertTrue(LauncherCommandCatalog.merge(automatic: [], declared: entries, includesParameterized: true).isEmpty,
                      "文件动作、文字动作都不进普通的命令表")
        let files = LauncherCommandCatalog.fileActions(declared: entries)
        XCTAssertEqual(files.map(\.command.id), ["phonetransfer.file.send"], "只收文件动作，id 重复只留第一条")
        XCTAssertEqual(files.first?.command.title, "发到手机")
        XCTAssertEqual(LauncherCommandCatalog.textActions(declared: entries).map(\.command.id), ["phonetransfer.text.send"])
        XCTAssertTrue(LauncherCommandCatalog.imageActions(declared: entries).isEmpty)
        XCTAssertTrue(LauncherCommandCatalog.fileActions(declared: entries, excludedIDs: ["phonetransfer.file.send"]).isEmpty)
    }

    func testImageActionsCanSkipImageFiles() {
        XCTAssertFalse(LauncherSuggestionTraits().skipsImageFiles)
        XCTAssertTrue(LauncherSuggestionTraits(priority: 50, skipsImageFiles: true).skipsImageFiles)
    }

    // MARK: - 出哪几行

    func testFolderGetsTerminalAndCopy() {
        let folder = LauncherPathTarget(path: "/Users/me/Downloads", isDirectory: true)
        XCTAssertEqual(LauncherPathActionPlan.actions(for: folder, declaredPriorities: [50]), [.openInTerminal, .copyPath],
                       "模块的文件动作只给文件")
    }

    func testFileGetsCopyThenDeclaredByTier() {
        let file = LauncherPathTarget(path: "/Users/me/a.txt", isDirectory: false)
        XCTAssertEqual(LauncherPathActionPlan.actions(for: file, declaredPriorities: []), [.copyPath])
        XCTAssertEqual(LauncherPathActionPlan.actions(for: file, declaredPriorities: [50]), [.copyPath, .declared(0)])
        XCTAssertEqual(LauncherPathActionPlan.actions(for: file, declaredPriorities: [60, 20, 20]),
                       [.copyPath, .declared(1), .declared(2)], "按档位、同档按声明顺序，最多 3 行")
        XCTAssertEqual(LauncherPathActionPlan.actions(for: file, declaredPriorities: [1, 2, 3, 4]).count,
                       LauncherPathActionPlan.maxRows)
    }

    func testPackagesOnlyCopyThePath() {
        let app = LauncherPathTarget(path: "/Applications/Safari.app", isDirectory: true, isPackage: true)
        XCTAssertEqual(LauncherPathActionPlan.actions(for: app, declaredPriorities: [50]), [.copyPath],
                       ".app 当成一个文件，但模块的文件动作（发到手机）发不了包")
    }
}
