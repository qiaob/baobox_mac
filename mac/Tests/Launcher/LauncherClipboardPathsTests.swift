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

    func testVariantsForPathsGluedToText() {
        // 独立验证者找到的三种漏网。
        XCTAssertTrue(paths("文件在/Users/qiao/文档/报告.pdf里").contains("/Users/qiao/文档/报告.pdf"), "末尾多带了「里」")
        XCTAssertTrue(paths("文件在/Users/qiao/文档/报告.pdf里面").contains("/Users/qiao/文档/报告.pdf"), "多带了两个字")
        let cmd = paths("cmd=/usr/local/bin/foo,arg=/etc/hosts")
        XCTAssertTrue(cmd.contains("/usr/local/bin/foo"), "\(cmd)")
        XCTAssertTrue(cmd.contains("/etc/hosts"), "一段里的第二个路径也找出来：\(cmd)")
        XCTAssertTrue(paths("path:/var/log/system.log;next").contains("/var/log/system.log"), "带上了 ;next")
        XCTAssertTrue(paths("见 /Users/me/报告里").contains("/Users/me/报告"), "只去掉末尾一个字的变体（名字本身是汉字）")
    }

    func testPathsInsideChineseText() {
        // 独立验证者复查：两个路径中间夹着汉字时前一个会丢，还会从每个「汉字 + /」处抽出垃圾候选占名额。
        let two = paths("见/Users/qiao/文档/项目/报告/最终版.pdf和/Users/qiao/b.md。")
        XCTAssertTrue(two.contains("/Users/qiao/文档/项目/报告/最终版.pdf"), "\(two)")
        XCTAssertTrue(two.contains("/Users/qiao/b.md"), "\(two)")
        XCTAssertFalse(two.contains { $0.hasPrefix("/项目") || $0.hasPrefix("/报告") || $0.hasPrefix("/最终版") },
                       "「汉字 + /」后面不是已知的顶层目录名不算路径开头：\(two)")
        let logs = paths("日志在/var/log/system.log和/tmp/a.txt里")
        XCTAssertTrue(logs.contains("/var/log/system.log") && logs.contains("/tmp/a.txt"), "\(logs)")
        XCTAssertEqual(paths("看/项目/报告.pdf"), [], "汉字后面的 / 跟的不是已知顶层目录：不算")
        XCTAssertEqual(paths("（/Users/qiao/a.md）和【~/b.md】"), ["/Users/qiao/a.md", "/Users/me/b.md"], "全角括号里的照样认")
        XCTAssertTrue(paths("配置在~/文档/bin/x.conf里").contains("/Users/me/文档/bin/x.conf"),
                      "中文目录下正好有个 bin：不断开的那一段也留作候选")
        XCTAssertEqual(paths(String(repeating: "=/", count: 100)), [], "第一级目录名里没有字母数字的不收")
    }

    func testPathsAtLineStarts() {
        // 复查发现的回归（4257e95 起）：换行后面开头的路径认不出 —— 终端 / Claude Code 回复里复制的多行文字。
        XCTAssertEqual(paths("Created:\n/private/tmp/claude-501/p/s/out.json"), ["/private/tmp/claude-501/p/s/out.json"])
        XCTAssertEqual(paths("第一行\n/Users/qiao/second-line.txt\n第三行"), ["/Users/qiao/second-line.txt"])
        XCTAssertEqual(paths("files:\r\n/Users/qiao/a.txt\r\n/Users/qiao/b.txt"), ["/Users/qiao/a.txt", "/Users/qiao/b.txt"],
                       "\\r\\n 分隔的文件列表（\"\\r\\n\" 是一个 Character）")
        XCTAssertEqual(paths("/Users/qiao/a.txt\nnext line"), ["/Users/qiao/a.txt"], "路径后面紧跟换行：到换行为止")
        XCTAssertEqual(paths("see\u{0B}/Users/qiao/v.txt\u{0C}/Users/qiao/f.txt"), ["/Users/qiao/v.txt", "/Users/qiao/f.txt"],
                       "垂直制表符、换页也算空白")
        XCTAssertEqual(paths("a\u{2028}/Users/qiao/ls.txt"), ["/Users/qiao/ls.txt"], "Unicode 的行分隔符也算")
    }

    func testKnownTopLevelNamesIgnoreCase() {
        XCTAssertEqual(paths("见/users/qiao/a.md"), ["/users/qiao/a.md"], "APFS 默认不区分大小写：汉字后面的 /users 也认")
        XCTAssertTrue(paths("见/Users/qiao/x.pdf和/USERS/qiao/y.md").contains("/USERS/qiao/y.md"))
    }

    func testVariantsOfAToken() {
        XCTAssertEqual(LauncherClipboardPaths.variants(of: "/a/b.txt"), ["/a/b.txt"], "没有可变的")
        XCTAssertEqual(LauncherClipboardPaths.variants(of: "/a/foo,arg=/x;y"), ["/a/foo,arg=/x;y", "/a/foo", "/a/foo,arg"],
                       "只在前两处截断")
        XCTAssertEqual(LauncherClipboardPaths.variants(of: "/a/报告.pdf里面"), ["/a/报告.pdf里面", "/a/报告.pdf里", "/a/报告.pdf"])
        XCTAssertLessThanOrEqual(LauncherClipboardPaths.variants(of: "/a,b;c=d,e里面").count, LauncherClipboardPaths.maxVariantsPerToken)
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
