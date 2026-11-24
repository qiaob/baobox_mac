import Foundation
import XCTest

/// 剪贴板历史里出现过的路径（docs/launcher/TECH_DESIGN.md §6.4「来源 D」，PR 11）：从文字里抽绝对路径、按条目键缓存。
final class LauncherClipboardPathsTests: XCTestCase {

    private let home = "/Users/me"

    private func paths(_ text: String) -> [String] {
        LauncherClipboardPaths.extract(from: text, home: home)
    }

    // MARK: - 整段就是一个路径

    func testWholeTextIsAPath() {
        let path = "/private/tmp/claude-501/-Users-qiao-cmb/e0c00de7-8950-4479-8685-030e3982c98e/scratchpad/add-approval-hook.py"
        XCTAssertEqual(paths(path), [path], "用户截图里的那一条")
        XCTAssertEqual(paths("  ~/Downloads/发票.pdf \n"), ["/Users/me/Downloads/发票.pdf"])
        XCTAssertEqual(paths("\"/Users/me/My Docs/a b.txt\""), ["/Users/me/My Docs/a b.txt", "/Users/me/My"],
                       "引号里带空格的整段先收；按空白断开的也收（存不存在由来源查）")
        XCTAssertEqual(paths("file:///Users/me/a%20b.txt"), ["/Users/me/a b.txt"])
        XCTAssertEqual(paths("/Users/me/My\\ File.txt"), ["/Users/me/My File.txt"])
        XCTAssertEqual(paths("/Users/me/proj/main.swift:12:3"), ["/Users/me/proj/main.swift"], "去掉 :行号:列号")
        XCTAssertEqual(paths("/Users/me/proj/"), ["/Users/me/proj"], "文件夹也收，末尾的 / 去掉")
    }

    func testWholeTextWithSpacesAlsoGivesTokens() {
        XCTAssertEqual(paths("/Users/me/a.py is broken"), ["/Users/me/a.py is broken", "/Users/me/a.py"])
    }

    // MARK: - 文字里的路径

    func testPathsInsideText() {
        XCTAssertEqual(paths("脚本写在 /private/tmp/x/hook.py，你看一下"), ["/private/tmp/x/hook.py"], "全角逗号断开")
        XCTAssertEqual(paths("see (/Users/me/a.txt) and ~/b.md."), ["/Users/me/a.txt", "/Users/me/b.md"], "括号断开、末尾的句号去掉")
        XCTAssertEqual(paths("error at /Users/me/x.swift:42: missing return"), ["/Users/me/x.swift"])
        XCTAssertEqual(paths("--config=/etc/nginx/nginx.conf"), ["/etc/nginx/nginx.conf"])
        XCTAssertEqual(paths("{\"path\": \"/Users/me/data.json\"}"), ["/Users/me/data.json"])
        XCTAssertEqual(paths("open file:///Users/me/a.txt now"), ["/Users/me/a.txt"])
        XCTAssertEqual(paths("first /a/one.txt\nsecond /b/two.txt"), ["/a/one.txt", "/b/two.txt"], "多行")
        XCTAssertEqual(paths("在/private/tmp/a.py"), ["/private/tmp/a.py"], "汉字后面紧跟着也算开头")
    }

    func testNotPaths() {
        for text in ["and/or", "1/2 + 3/4", "https://github.com/a/b.md", "//network/share", "~", "/", "hello world",
                     "a=b", "~other/x.txt", "price 50/50"] {
            XCTAssertEqual(paths(text), [], text)
        }
    }

    func testDedupesAndCaps() {
        XCTAssertEqual(paths("/a/x.txt then /a/x.txt again"), ["/a/x.txt"])
        let many = (1...20).map { "/d/f\($0).txt" }.joined(separator: " ")
        XCTAssertEqual(paths(many).count, LauncherClipboardPaths.maxPerText)
        XCTAssertEqual(paths("/" + String(repeating: "a", count: 2000)), [], "太长的不收")
    }

    // MARK: - 缓存

    func testIndexCachesByKeyAndText() {
        var index = LauncherClipboardPathIndex()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let first = index.update([
            LauncherTextSnapshot(key: "clipboard/1", text: "/a/old.txt", date: old),
            LauncherTextSnapshot(key: "clipboard/2", text: "see /tmp/shared.txt", date: new),
            LauncherTextSnapshot(key: "clipboard/3", text: "no path here", date: new),
        ], home: home)
        XCTAssertEqual(first.extracted, 3)
        XCTAssertEqual(first.files.map(\.path), ["/tmp/shared.txt", "/a/old.txt"], "新的在前")
        XCTAssertEqual(first.files.first?.lastUsed, new, "最近使用 = 复制它的时间")
        XCTAssertEqual(index.cachedEntries, 3)

        let second = index.update([
            LauncherTextSnapshot(key: "clipboard/1", text: "/a/old.txt", date: old),
            LauncherTextSnapshot(key: "clipboard/4", text: "/private/tmp/shared.txt", date: old),
        ], home: home)
        XCTAssertEqual(second.extracted, 1, "文字没变的用缓存")
        XCTAssertEqual(second.files.map(\.path), ["/a/old.txt", "/private/tmp/shared.txt"])
        XCTAssertEqual(index.cachedEntries, 2, "这次没出现的条目从缓存删掉")

        let third = index.update([
            LauncherTextSnapshot(key: "clipboard/5", text: "/tmp/shared.txt", date: new),
            LauncherTextSnapshot(key: "clipboard/4", text: "/private/tmp/shared.txt", date: old),
        ], home: home)
        XCTAssertEqual(third.files.map(\.path), ["/tmp/shared.txt"], "同一个文件（/tmp 和 /private/tmp）只留最新的那次")
    }

    func testIndexCapsTheTotal() {
        var index = LauncherClipboardPathIndex()
        let snapshots = (0..<400).map { i in
            LauncherTextSnapshot(key: "clipboard/\(i)", text: (0..<8).map { "/d\(i)/f\($0).txt" }.joined(separator: " "),
                                 date: Date(timeIntervalSince1970: Double(i)))
        }
        let result = index.update(snapshots, home: home)
        XCTAssertEqual(result.files.count, LauncherClipboardPathIndex.maxPaths)
        XCTAssertTrue(result.files.first?.path.hasPrefix("/d399/") == true, "留新的")
    }
}
