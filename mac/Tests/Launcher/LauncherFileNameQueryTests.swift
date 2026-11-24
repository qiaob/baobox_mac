import Foundation
import XCTest

/// 输入像文件名时名字正好是它的文件固定排第一（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：
/// 怎么算像文件名、请求里带上固定的名字、固定行的次序（已知文件 / 剪贴板里的路径在前、同等的新的在前、最多 3 行）。
final class LauncherFileNameQueryTests: XCTestCase {

    private let home = "/Users/me"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ input: String, hasCalculation: Bool = false) -> LauncherFileSearchRequest? {
        LauncherFilePolicy.request(for: LauncherQuery.parse(input), hasCalculation: hasCalculation)
    }

    private func hit(_ path: String, daysAgo: Double = 0, origins: LauncherFileOrigins = [.spotlight]) -> LauncherFileHit {
        LauncherFileHit(path: path, modified: now.addingTimeInterval(-daysAgo * 86_400), origins: origins)
    }

    // MARK: - 像不像文件名

    func testLooksLikeAFileName() {
        for text in ["add-approval-hook.py", "TECH_DESIGN.md", "报告 final.pdf", "a.b", "archive.tar.gz", "Safari.app",
                     "claude.ai", "main.cc", "github.com", "3.mp4", "IMG_1234.HEIC", "发票.jpg", "icon@2x.png", "x.markdown"] {
            XCTAssertEqual(LauncherFileNameQuery.fileName(in: text), text, text)
        }
    }

    func testDoesNotLookLikeAFileName() {
        for text in ["v2.0", "3.14", "1.5", "1.2.3", "README", ".zshrc", "abc.", ".", "a.p-g", "a.toolongext",
                     "https://example.com/a.md", "mailto:a@b.com", "docs/launcher/TECH_DESIGN.md", "a\tb.txt", "a\nb.txt",
                     " a.txt", "a.txt ", "", "   .md", "foo:bar.txt", String(repeating: "x", count: 252) + ".txt"] {
            XCTAssertNil(LauncherFileNameQuery.fileName(in: text), text)
        }
    }

    // MARK: - 请求

    func testFileNameQueriesCarryThePinnedName() {
        XCTAssertEqual(request("add-approval-hook.py"), .nameContains(["add-approval-hook.py"], pinnedName: "add-approval-hook.py"))
        XCTAssertEqual(request("f add-approval-hook.py"), .nameContains(["add-approval-hook.py"], pinnedName: "add-approval-hook.py"))
        XCTAssertEqual(request("报告 final.pdf"), .nameContains(["报告", "final.pdf"], pinnedName: "报告 final.pdf"))
        XCTAssertEqual(request("a.b"), .nameContains(["a.b"], pinnedName: "a.b"), "三个字符：不带前缀的长度门槛照样满足")
        XCTAssertEqual(request("claude.ai"), .nameContains(["claude.ai"], pinnedName: "claude.ai"), "既像域名又像文件名：照样找")
    }

    func testOtherQueriesKeepTheOldRequest() {
        XCTAssertEqual(request("TECH_DESIGN"), .nameContains(["TECH_DESIGN"]))
        XCTAssertEqual(request("f v2.0"), .nameContains(["v2.0"]))
        XCTAssertEqual(request("tech design"), .nameContains(["tech", "design"]))
        XCTAssertNil(request("ab"))
        XCTAssertNil(request("3.14", hasCalculation: true), "算式照旧不搜")
        XCTAssertNil(request("c add-approval-hook.py"), "别的前缀不搜")
        XCTAssertEqual(request("docs/launcher/TECH_DESIGN.md"),
                       .exactName("TECH_DESIGN.md", pathSuffix: "docs/launcher/TECH_DESIGN.md"), "片段照旧")
    }

    // MARK: - 固定行

    func testExactNamesArePinnedAndContainsMatchesAreRanked() {
        let request = LauncherFileSearchRequest.nameContains(["add-approval-hook.py"], pinnedName: "add-approval-hook.py")
        let results = LauncherFileFilter.process([
            hit("/Users/me/a/old-add-approval-hook.py.bak"),
            hit("/private/tmp/claude-501/p/s/scratchpad/add-approval-hook.py", origins: [.scanned]),
            hit("/Users/me/b/ADD-APPROVAL-HOOK.PY", daysAgo: 2),
        ], request: request, home: home)
        XCTAssertEqual(results.map(\.hit.path), ["/private/tmp/claude-501/p/s/scratchpad/add-approval-hook.py",
                                                  "/Users/me/b/ADD-APPROVAL-HOOK.PY", "/Users/me/a/old-add-approval-hook.py.bak"])
        XCTAssertEqual(results.map(\.pinned), [true, true, false], "名字不分大小写地等于它的才固定")
        XCTAssertEqual(results.first?.tierScore, LauncherMatch.exactScore)
    }

    func testPinnedPrefersKnownAndClipboardOriginsThenRecency() {
        let request = LauncherFileSearchRequest.nameContains(["notes.md"], pinnedName: "notes.md")
        let results = LauncherFileFilter.process([
            hit("/Users/me/newest/notes.md", daysAgo: 0, origins: [.spotlight]),
            hit("/Users/me/scanned/notes.md", daysAgo: 1, origins: [.scanned]),
            hit("/Users/me/claude/notes.md", daysAgo: 9, origins: [.known, .spotlight]),
            hit("/Users/me/copied/notes.md", daysAgo: 5, origins: [.clipboard]),
            hit("/Users/me/older/notes.md", daysAgo: 20, origins: [.spotlight]),
        ], request: request, home: home)
        XCTAssertEqual(results.filter(\.pinned).map(\.hit.path),
                       ["/Users/me/copied/notes.md", "/Users/me/claude/notes.md", "/Users/me/newest/notes.md"],
                       "已知文件、剪贴板里的路径先（同等的新的在前），再是别的里最新的；最多 3 行")
        XCTAssertFalse(results.contains { $0.hit.path == "/Users/me/older/notes.md" }, "同名第 4 份起不出（也不进排序）")
    }

    func testPinnedStillDropsNoise() {
        let request = LauncherFileSearchRequest.nameContains(["index.js"], pinnedName: "index.js")
        let results = LauncherFileFilter.process([
            hit("/Users/me/proj/node_modules/x/index.js", origins: [.clipboard]),
            hit("/Users/me/proj/src/index.js", daysAgo: 3),
        ], request: request, home: home)
        XCTAssertEqual(results.map(\.hit.path), ["/Users/me/proj/src/index.js"], "过滤规则对所有来源一视同仁")
    }

    func testNoPinnedNameMeansNothingIsPinned() {
        let results = LauncherFileFilter.process([hit("/Users/me/a/notes.md")], request: .nameContains(["notes.md"]), home: home)
        XCTAssertEqual(results.map(\.pinned), [false])
    }

    func testFragmentPinsUseTheSameOrder() {
        let request = LauncherFileSearchRequest.exactName("TECH_DESIGN.md", pathSuffix: "launcher/TECH_DESIGN.md")
        let results = LauncherFileFilter.process([
            hit("/Users/me/w1/docs/launcher/TECH_DESIGN.md", daysAgo: 0),
            hit("/Users/me/w2/docs/launcher/TECH_DESIGN.md", daysAgo: 3, origins: [.known]),
            hit("/Users/me/w3/docs/meeting/TECH_DESIGN.md", daysAgo: 0),
        ], request: request, home: home)
        XCTAssertEqual(results.map(\.hit.path), ["/Users/me/w2/docs/launcher/TECH_DESIGN.md", "/Users/me/w1/docs/launcher/TECH_DESIGN.md"])
        XCTAssertTrue(results.allSatisfy(\.pinned))
    }

    // MARK: - 副标题

    func testDirectoryLabelShortensIdentifiers() {
        let directory = "/private/tmp/claude-501/-Users-qiao-cmb/e0c00de7-8950-4479-8685-030e3982c98e/scratchpad"
        let label = LauncherPathDisplay.directoryLabel(directory, home: home)
        XCTAssertEqual(label, "/private/tmp/claude-501/-Users-qiao-cmb/e0c00de7…/scratchpad")
        XCTAssertLessThanOrEqual(label.count, LauncherPathDisplay.maxDirectoryLabelLength)
        XCTAssertEqual(LauncherPathDisplay.shorteningIdentifiers("/a/0123456789abcdef0123456789abcdef01234567/b"), "/a/01234567…/b",
                       "git 哈希")
        XCTAssertEqual(LauncherPathDisplay.shorteningIdentifiers("/a/baobox-launcher-file-sources/b"), "/a/baobox-launcher-file-sources/b",
                       "普通的长名字（worktree 名）不缩")
        XCTAssertEqual(LauncherPathDisplay.directoryLabel("/x/e0c00de7-8950-4479-8685-030e3982c98e", home: home),
                       "/x/e0c00de7-8950-4479-8685-030e3982c98e", "不超长就不缩")
    }
}
