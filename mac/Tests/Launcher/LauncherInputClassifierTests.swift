import Foundation
import XCTest

/// 快速入口的输入分类：网址、邮箱、颜色、英文单词、一大段文字、其余（docs/launcher/TECH_DESIGN.md §5.4）。
final class LauncherInputClassifierTests: XCTestCase {

    private func kinds(_ text: String) -> Set<LauncherTextKind> {
        LauncherInputClassifier.classify(text).kinds
    }

    private func url(_ text: String) -> String? {
        LauncherInputClassifier.classify(text).url?.absoluteString
    }

    // MARK: - 空、路径

    func testEmptyAndWhitespaceHaveNoKinds() {
        for text in ["", "   ", "\n\t "] {
            let result = LauncherInputClassifier.classify(text)
            XCTAssertTrue(result.kinds.isEmpty, text)
            XCTAssertFalse(result.isPath, text)
            XCTAssertEqual(result.text, "")
        }
    }

    func testPathsGetNoKinds() {
        for text in ["/", "/Users/qiao", "~", "~/Downloads/a.pdf", "  ~/Desktop  ", "/usr/bin/swift", "~user/x"] {
            let result = LauncherInputClassifier.classify(text)
            XCTAssertTrue(result.isPath, text)
            XCTAssertTrue(result.kinds.isEmpty, text)
            XCTAssertNil(result.url, text)
        }
    }

    func testTextIsTrimmed() {
        XCTAssertEqual(LauncherInputClassifier.classify("  hello  ").text, "hello")
    }

    // MARK: - 网址：带 scheme

    func testURLsWithSchemeAreKeptAsTyped() {
        let samples = [
            "https://github.com/qiaob/baobox_mac/pull/212",
            "http://example.com",
            "https://example.com/search?q=%E4%B8%AD&page=2#top",
            "HTTPS://EXAMPLE.COM/Path",
            "ftp://files.example.com/pub",
            "vscode://file/Users/qiao/a.swift",
            "obsidian://open?vault=notes",
            "ws://localhost:8080/socket",
            "file:///Users/qiao/a.txt",
        ]
        for text in samples {
            XCTAssertEqual(kinds(text), [.url], text)
            XCTAssertEqual(url(text), text, text)
        }
    }

    func testSchemeURLsWithNonASCIIStillOpen() {
        XCTAssertEqual(kinds("https://例子.cn/路径"), [.url])
        XCTAssertNotNil(LauncherInputClassifier.classify("https://例子.cn/路径").url)
    }

    func testBrokenOrBlockedSchemeURLsAreNotURLs() {
        for text in ["http://", "https://", "https:///path", "http://?q=1", "c://foo", "1http://x.com",
                     "javascript://%0Aalert(1)", "data://text/plain,hi", "https://exa mple.com",
                     "see https://example.com", "://example.com"] {
            XCTAssertNotEqual(kinds(text), [.url], text)
            XCTAssertNil(url(text), text)
        }
    }

    // MARK: - 网址：不带 scheme

    func testBareDomainsGetHTTPS() {
        let samples: [(String, String)] = [
            ("example.com", "https://example.com"),
            ("Example.COM", "https://Example.COM"),
            ("www.google.com", "https://www.google.com"),
            ("example.com/path", "https://example.com/path"),
            ("github.com/qiaob/baobox_mac?tab=readme#top", "https://github.com/qiaob/baobox_mac?tab=readme#top"),
            ("baobox.dev", "https://baobox.dev"),
            ("socket.io", "https://socket.io"),
            ("foo.co.uk", "https://foo.co.uk"),
            ("news.sina.com.cn", "https://news.sina.com.cn"),
            ("notion.so", "https://notion.so"),
            ("x.com", "https://x.com"),
            ("my-site.io:8443/admin", "https://my-site.io:8443/admin"),
            ("openai.ai", "https://openai.ai"),
            ("example.sg", "https://example.sg"),
        ]
        for (text, expected) in samples {
            XCTAssertEqual(kinds(text), [.url], text)
            XCTAssertEqual(url(text), expected, text)
        }
    }

    func testLocalhostAndIPGetHTTP() {
        let samples: [(String, String)] = [
            ("localhost", "http://localhost"),
            ("localhost:8080", "http://localhost:8080"),
            ("LOCALHOST:3000/api", "http://LOCALHOST:3000/api"),
            ("192.168.1.1", "http://192.168.1.1"),
            ("192.168.1.1:3000", "http://192.168.1.1:3000"),
            ("10.0.0.1/admin", "http://10.0.0.1/admin"),
            ("127.0.0.1:8000?debug=1", "http://127.0.0.1:8000?debug=1"),
        ]
        for (text, expected) in samples {
            XCTAssertEqual(kinds(text), [.url], text)
            XCTAssertEqual(url(text), expected, text)
        }
    }

    func testFileNamesVersionsAndNumbersAreNotURLs() {
        let samples = [
            "TECH_DESIGN.md", "README.md", "file.txt", "main.py", "index.js", "next.config.js", "build.sh", "lib.rs",
            "script.pl", "messages.mo", "Makefile.in", "photo.jpeg", "report.pdf", "archive.tar.gz",
            "v2.0", "1.5", "3.14", "3.14.15", "a.b", "e.g.", "i.e.", "U.S", "Node.js", "Vue.js", "Mr.Smith",
            "hello.world", "example.zzz", "www.example", "example.com.", ".com", "example..com", "-bad.com",
            "bad-.com", "under_score.com", "999.1.1.1", "1.2.3", "1.2.3.4.5", "256.0.0.1",
            "localhost:", "localhost:0", "localhost:70000", "localhost:abc", "example.com:99999",
            "user@example.com", "user:pass@example.com", "例子.中国", "12.5%",
        ]
        for text in samples {
            XCTAssertNil(url(text), text)
            XCTAssertFalse(kinds(text).contains(.url), text)
        }
    }

    // MARK: - 邮箱

    func testEmails() {
        let samples: [(String, String)] = [
            ("name@example.com", "name@example.com"),
            ("first.last+tag@sub.example.co.uk", "first.last+tag@sub.example.co.uk"),
            ("A_B-c%d@Example.ORG", "A_B-c%d@Example.ORG"),
            ("mailto:name@example.com", "name@example.com"),
            ("MAILTO:boss@company.internal", "boss@company.internal"),
            ("  me@baobox.dev  ", "me@baobox.dev"),
        ]
        for (text, expected) in samples {
            let result = LauncherInputClassifier.classify(text)
            XCTAssertEqual(result.kinds, [.email], text)
            XCTAssertEqual(result.email, expected, text)
            XCTAssertNil(result.url, text)
        }
    }

    func testNotEmails() {
        let samples = [
            "@example.com", "name@", "name@example", "name@example.c", "a@b@c.com", ".name@example.com",
            "name.@example.com", "na..me@example.com", "name@-example.com", "name@example-.com", "name@exa_mple.com",
            "na me@example.com", "名字@example.com", "name@example.123", "write to name@example.com",
            "mailto:", "name@example.com?subject=hi",
        ]
        for text in samples {
            XCTAssertNil(LauncherInputClassifier.classify(text).email, text)
            XCTAssertFalse(kinds(text).contains(.email), text)
        }
    }

    // MARK: - 颜色

    func testColorsAreRecognized() {
        for text in ["#17A398", "#17a398", "#fff", "#17A39880", "rgb(23, 163, 152)", "rgba(23,163,152,0.5)",
                     "hsl(175, 75%, 36%)", "HSL(175 75% 36% / 50%)"] {
            let result = LauncherInputClassifier.classify(text)
            XCTAssertEqual(result.kinds, [.color], text)
            XCTAssertNotNil(result.color, text)
        }
    }

    func testColorLikeButNotColor() {
        for text in ["#12", "#12345", "#GGG", "rgb(300, 0, 0)", "rgb(1, 2)", "hsl(10, 200%, 50%)", "rgb(a, b, c)", "17A398"] {
            XCTAssertNil(LauncherInputClassifier.classify(text).color, text)
            XCTAssertFalse(kinds(text).contains(.color), text)
        }
    }

    // MARK: - 英文单词 / 短语

    func testWordsAndShortPhrases() {
        for text in ["hello", "Serendipity", "a", "don't", "rock'n'roll", "well-known", "o’clock", "take it easy",
                     "look  up", "students'", "API", "re-"] {
            XCTAssertEqual(kinds(text), [.word], text)
        }
    }

    func testNotWords() {
        let plain = ["four words are here", "hello world again now", "你好", "hello 世界", "hello123", "C++", "e-mail!",
                     "-dash", "'quoted'", "Café", "naïve", "hello, world", "3 cats", "hello\tworld",
                     String(repeating: "a", count: 41)]
        for text in plain {
            XCTAssertEqual(kinds(text), [.plainText], text)
        }
    }

    func testURLWinsOverWord() {
        XCTAssertEqual(kinds("localhost"), [.url])
    }

    // MARK: - 一大段文字

    func testLongTextStartsAtEightyCharacters() {
        let seventyNine = String(repeating: "字", count: 79)
        XCTAssertEqual(kinds(seventyNine), [.plainText])
        XCTAssertEqual(kinds(seventyNine + "字"), [.longText])
        XCTAssertEqual(kinds("  " + seventyNine + "  "), [.plainText], "首尾空白不算")
        let english = "The quick brown fox jumps over the lazy dog, and then it runs away into the woods again."
        XCTAssertGreaterThanOrEqual(english.count, 80)
        XCTAssertEqual(kinds(english), [.longText])
    }

    func testTextWithANewlineIsLong() {
        XCTAssertEqual(kinds("第一行\n第二行"), [.longText])
    }

    func testLongURLIsStillAURL() {
        let long = "https://example.com/" + String(repeating: "a", count: 200)
        XCTAssertEqual(kinds(long), [.url])
    }

    func testHugeInputIsClassifiedQuickly() {
        let huge = String(repeating: "这是一段很长的文字，", count: 200_000)
        let start = Date()
        XCTAssertEqual(kinds(huge), [.longText])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - 其余

    func testPlainText() {
        for text in ["随便什么", "微信", "12*(3+4)", "1700000000", "{\"a\":1}", "hello world!", "v2.0", "TECH_DESIGN.md",
                     "#1234", "@someone", "xyz123"] {
            XCTAssertEqual(kinds(text), [.plainText], text)
        }
    }
}
