import Foundation
import XCTest

/// 快速入口「输入是路径」：认路径、展开、显示、补全文字、列目录（docs/launcher/TECH_DESIGN.md §6.5）。
final class LauncherPathInputTests: XCTestCase {

    private let home = "/Users/me"

    private func parse(_ input: String) -> LauncherPathInput? {
        LauncherPathInput.parse(input, home: home)
    }

    // MARK: - 认不认

    func testAbsolutePathsAndHome() {
        XCTAssertEqual(parse("/Applications")?.path, "/Applications")
        XCTAssertEqual(parse("/private/tmp/claude-501/-Users-qiao-qiao-repo-baobox-mac/")?.path,
                       "/private/tmp/claude-501/-Users-qiao-qiao-repo-baobox-mac/", "末尾的 / 保留")
        XCTAssertEqual(parse("~")?.path, "/Users/me")
        XCTAssertEqual(parse("~/")?.path, "/Users/me/")
        XCTAssertEqual(parse("~/Downloads/a.pdf")?.path, "/Users/me/Downloads/a.pdf")
        XCTAssertEqual(parse("~")?.usesTilde, true)
        XCTAssertEqual(parse("/Users/me/Downloads")?.usesTilde, false)
    }

    func testHomeWithTrailingSlashIsNormalized() {
        XCTAssertEqual(LauncherPathInput.parse("~/x", home: "/Users/me/")?.path, "/Users/me/x")
        XCTAssertEqual(LauncherPathInput.parse("~", home: "/Users/me/")?.path, "/Users/me")
    }

    func testNotPaths() {
        for input in ["", "   ", "/", "//", "safari", "1/2", "24/7", "png-final/8-prefix-c-light.png", "~foo", "~foo/bar",
                      "a /b", "https://example.com/a", "/a\n/b", "x~/a"] {
            XCTAssertNil(parse(input), input)
        }
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(parse("  /Applications  ")?.path, "/Applications")
        XCTAssertEqual(parse("\t~/Downloads\n")?.path, "/Users/me/Downloads")
    }

    // MARK: - 写法

    func testQuotes() {
        XCTAssertEqual(parse("\"/Users/me/My File.txt\"")?.path, "/Users/me/My File.txt")
        XCTAssertEqual(parse("'~/My Docs/'")?.path, "/Users/me/My Docs/")
        XCTAssertEqual(parse("\"/a\\ b\"")?.path, "/a\\ b", "引号里的反斜杠原样（引号里不用转义）")
        XCTAssertNil(parse("\"/a'"), "两边不成对不去掉，开头的引号让它不像路径")
        XCTAssertEqual(parse("\"  /a  \"")?.path, "/a", "引号里的首尾空白也去掉")
    }

    func testFileURL() {
        XCTAssertEqual(parse("file:///Users/me/My%20File.txt")?.path, "/Users/me/My File.txt")
        XCTAssertEqual(parse("file://localhost/Users/me/a.txt")?.path, "/Users/me/a.txt")
        XCTAssertEqual(parse("FILE:///tmp/%E5%8F%91%E7%A5%A8.pdf")?.path, "/tmp/发票.pdf")
        XCTAssertEqual(parse("file:///Users/me/Downloads/")?.path, "/Users/me/Downloads/")
        XCTAssertNil(parse("file://server/share/a"), "别的主机不认")
        XCTAssertEqual(parse("\"file:///a%20b\"")?.path, "/a b", "引号 + URL")
    }

    func testBackslashEscapes() {
        XCTAssertEqual(parse("/Users/me/My\\ File.txt")?.path, "/Users/me/My File.txt")
        XCTAssertEqual(parse("~/Screen\\ Shot\\ \\(1\\).png")?.path, "/Users/me/Screen Shot (1).png")
        XCTAssertEqual(parse("/a/b\\nc")?.path, "/a/b\\nc", "字母前的反斜杠留着")
        XCTAssertEqual(parse("/a/b\\")?.path, "/a/b\\", "末尾单独一个反斜杠留着")
        XCTAssertEqual(LauncherPathInput.unescapingBackslashes("a\\\\b"), "a\\b")
    }

    func testLineSuffix() {
        let one = parse("/Users/me/x.swift:12")
        XCTAssertEqual(one?.path, "/Users/me/x.swift:12")
        XCTAssertEqual(one?.pathWithoutLineSuffix, "/Users/me/x.swift")
        XCTAssertEqual(parse("~/x.swift:12:5")?.pathWithoutLineSuffix, "/Users/me/x.swift")
        XCTAssertNil(parse("/Users/me/x.swift")?.pathWithoutLineSuffix)
        XCTAssertNil(parse("/Users/me/a:b")?.pathWithoutLineSuffix, "冒号后面不是数字")
        XCTAssertNil(parse("/a:")?.pathWithoutLineSuffix)
        XCTAssertNil(parse("/:12")?.pathWithoutLineSuffix, "去掉后只剩 / 不算")
        XCTAssertEqual(LauncherPathInput.strippingLineSuffix("/a/b.txt:1:2:3"), "/a/b.txt:1", "最多去两段")
    }

    func testContinuesWhileTypingInTheSamePlace() {
        func continues(_ new: String, _ old: String) -> Bool {
            guard let a = parse(new), let b = parse(old) else { return false }
            return a.continues(b)
        }
        XCTAssertTrue(continues("~/Down", "~/Dow"), "改最后一段")
        XCTAssertTrue(continues("~/Dow", "~/Down"), "往回删")
        XCTAssertTrue(continues("~/Downloads/", "~/Downloads"), "往深里打")
        XCTAssertTrue(continues("~/Downloads/a", "~/Downloads/"))
        XCTAssertTrue(continues("~/Downloads", "~/Downloads/a"))
        XCTAssertTrue(continues("~/Documents", "~/Downloads"), "同一个上一级里换了一项")
        XCTAssertFalse(continues("/Applications/", "~/Dow"), "贴了别处的路径")
        XCTAssertFalse(continues("/private/tmp/x/", "~/Downloads/a/b"))
    }

    // MARK: - 显示

    func testAbbreviated() {
        XCTAssertEqual(LauncherPathDisplay.abbreviated("/Users/me", home: home), "~")
        XCTAssertEqual(LauncherPathDisplay.abbreviated("/Users/me/Downloads", home: home), "~/Downloads")
        XCTAssertEqual(LauncherPathDisplay.abbreviated("/Users/meow", home: home), "/Users/meow", "前缀相同但不是主目录")
        XCTAssertEqual(LauncherPathDisplay.abbreviated("/Applications", home: home), "/Applications")
    }

    func testSplitAndJoin() {
        XCTAssertEqual(LauncherPathDisplay.split("/a/b/c").parent, "/a/b")
        XCTAssertEqual(LauncherPathDisplay.split("/a/b/c").name, "c")
        XCTAssertEqual(LauncherPathDisplay.split("/a/b/").name, "b")
        XCTAssertEqual(LauncherPathDisplay.split("/c").parent, "/")
        XCTAssertEqual(LauncherPathDisplay.split("/").name, "")
        XCTAssertEqual(LauncherPathDisplay.join("/", "a"), "/a")
        XCTAssertEqual(LauncherPathDisplay.join("/a", "b"), "/a/b")
        XCTAssertEqual(LauncherPathDisplay.trimmingTrailingSlashes("/a//"), "/a")
        XCTAssertEqual(LauncherPathDisplay.trimmingTrailingSlashes("/"), "/")
    }

    func testDirectoryLabelKeepsHeadAndLastTwoLevels() {
        XCTAssertEqual(LauncherPathDisplay.directoryLabel("/Users/me/Downloads", home: home), "~/Downloads")
        let long = "/Users/me/cmb/worktrees/baobox-launcher-pr6/mac/Sources/Modules/Launcher/Logic"
        let label = LauncherPathDisplay.directoryLabel(long, home: home, maxLength: 50)
        XCTAssertTrue(label.hasPrefix("~/cmb/worktrees/"), label)
        XCTAssertTrue(label.hasSuffix("/…/Launcher/Logic"), label)
        XCTAssertLessThanOrEqual(label.count, 50)
        XCTAssertEqual(LauncherPathDisplay.directoryLabel(long, home: home, maxLength: 20), "~/…/Launcher/Logic")
        XCTAssertEqual(LauncherPathDisplay.directoryLabel(long, home: home, maxLength: 15), "…/Launcher/Logic",
                       "开头一级都放不下时只留末尾两级")
        XCTAssertEqual(LauncherPathDisplay.directoryLabel(long, home: home).hasPrefix("~/cmb/worktrees/baobox-launcher-pr6/"),
                       true, "出厂长度下看得出是哪个副本")
        XCTAssertEqual(LauncherPathDisplay.directoryLabel("/private/a-very-long-folder-name/b", home: home, maxLength: 12),
                       "/private/a-very-long-folder-name/b", "不到四级不截")
    }

    func testCompletionTextFollowsUsersStyle() {
        XCTAssertEqual(LauncherPathDisplay.completionText(path: "/Users/me/Downloads", isDirectory: true,
                                                          usesTilde: true, home: home), "~/Downloads/")
        XCTAssertEqual(LauncherPathDisplay.completionText(path: "/Users/me/Downloads", isDirectory: true,
                                                          usesTilde: false, home: home), "/Users/me/Downloads/")
        XCTAssertEqual(LauncherPathDisplay.completionText(path: "/Users/me/a.pdf", isDirectory: false,
                                                          usesTilde: true, home: home), "~/a.pdf")
        XCTAssertEqual(LauncherPathDisplay.completionText(path: "/Users/me", isDirectory: true,
                                                          usesTilde: true, home: home), "~/")
        XCTAssertEqual(LauncherPathDisplay.completionText(path: "/", isDirectory: true,
                                                          usesTilde: false, home: home), "/")
    }

    // MARK: - 列目录

    private func entry(_ name: String, folder: Bool = false, package: Bool = false) -> LauncherPathEntry {
        LauncherPathEntry(name: name, isDirectory: folder || package, isPackage: package)
    }

    func testPackageIsAFile() {
        let app = entry("Safari.app", package: true)
        XCTAssertFalse(app.isDirectory)
        XCTAssertTrue(app.isPackage)
    }

    func testContentsFoldersFirstNaturalOrderNoHidden() {
        let entries = [entry("b.txt"), entry(".DS_Store"), entry("Zeta", folder: true), entry("file10.txt"),
                       entry("file2.txt"), entry("alpha", folder: true), entry(".git", folder: true),
                       entry("Safari.app", package: true)]
        XCTAssertEqual(LauncherPathListing.contents(entries).map(\.name),
                       ["alpha", "Zeta", "b.txt", "file2.txt", "file10.txt", "Safari.app"])
    }

    func testContentsLimit() {
        let entries = (0..<120).map { entry("f\($0)") }
        XCTAssertEqual(LauncherPathListing.contents(entries).count, LauncherPathListing.maxRows)
        XCTAssertEqual(LauncherPathListing.contents(entries, limit: 3).map(\.name), ["f0", "f1", "f2"])
    }

    func testCompletionsPrefixBeforeWordStartBeforeSubstring() {
        let entries = [entry("Documents", folder: true), entry("Downloads", folder: true), entry("my-downloads.txt"),
                       entry("Shadow.txt"), entry("Desktop", folder: true), entry("d-o-w-n.txt")]
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: "Dow").map(\.name),
                       ["Downloads", "my-downloads.txt", "Shadow.txt"], "开头 > 词首 > 包含，不认跳字")
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: "dow").first?.name, "Downloads", "不分大小写")
    }

    func testCompletionsHiddenOnlyWithDot() {
        let entries = [entry(".claude", folder: true), entry("claude-notes.md"), entry(".zshrc")]
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: "cl").map(\.name), ["claude-notes.md"])
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: ".cl").map(\.name), [".claude"])
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: ".").map(\.name), [".claude", ".zshrc"],
                       "只打一个点 = 列隐藏项（文件夹在前），不去匹配扩展名里的点")
    }

    func testCompletionsTieFoldersFirst() {
        let entries = [entry("notes.txt"), entry("notes", folder: true)]
        XCTAssertEqual(LauncherPathListing.completions(entries, partial: "no").map(\.name), ["notes", "notes.txt"],
                       "notes 比 notes.txt 短，分更高")
        let same = [entry("abc.txt"), entry("abc.dir", folder: true)]
        XCTAssertEqual(LauncherPathListing.completions(same, partial: "ab").map(\.name), ["abc.dir", "abc.txt"],
                       "同分文件夹在前")
    }
}
