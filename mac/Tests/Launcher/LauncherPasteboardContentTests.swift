import Foundation
import XCTest

/// 剪贴板内容归哪一类（docs/launcher/TECH_DESIGN.md §5.5）：文件 / 图片 / 文字，和贴进文件时换进输入框的路径。
final class LauncherPasteboardContentTests: XCTestCase {

    private func classify(types: [String] = [], string: String? = nil, files: [URL] = []) -> LauncherPasteKind {
        LauncherPasteClassifier.classify(LauncherPasteboardSnapshot(types: types, string: string, fileURLs: files))
    }

    private let png = "public.png"
    private let tiff = "public.tiff"
    private let text = "public.utf8-plain-text"
    private let fileURL = "public.file-url"

    // MARK: - 文件

    func testFinderCopyIsAFileEvenWithItsNameAndIcon() {
        // 访达复制一个文件：文件网址 + 文件名文字 + 图标（TIFF）。
        let url = URL(fileURLWithPath: "/Users/me/Desktop/报价单.pdf")
        XCTAssertEqual(classify(types: [fileURL, text, tiff], string: "报价单.pdf", files: [url]), .file(url))
    }

    func testSeveralFilesTakeTheFirst() {
        let first = URL(fileURLWithPath: "/Users/me/a.png")
        let second = URL(fileURLWithPath: "/Users/me/b.png")
        XCTAssertEqual(classify(types: [fileURL], files: [first, second]), .file(first))
    }

    func testNonFileURLsAreNotFiles() {
        let web = URL(string: "https://example.com/a.png")!
        XCTAssertEqual(classify(types: [png], files: [web]), .image)
        XCTAssertEqual(classify(types: [text], string: "https://example.com", files: [web]), .text)
    }

    func testAnImageFileIsStillAFile() {
        // 图片文件也按文件算（输入框换成路径，路径行后面再接图片动作）。
        let url = URL(fileURLWithPath: "/Users/me/Pictures/cat.heic")
        XCTAssertEqual(classify(types: [fileURL, png], files: [url]), .file(url))
    }

    // MARK: - 图片

    func testImageWithoutTextIsAnImage() {
        XCTAssertEqual(classify(types: [png]), .image)
        XCTAssertEqual(classify(types: [tiff, png]), .image)
        XCTAssertEqual(classify(types: ["public.jpeg"]), .image)
        XCTAssertEqual(classify(types: ["NeXT TIFF v4.0 pasteboard type"]), .image)
        XCTAssertEqual(classify(types: [png, text], string: "   \n"), .image, "全是空白的文字不算")
    }

    func testImageWithItsAddressIsAnImage() {
        XCTAssertEqual(classify(types: [tiff, text], string: "https://cdn.example.com/photo/123?w=800"), .image)
        XCTAssertEqual(classify(types: [png, text, "public.html"], string: " http://example.com/a.webp "), .image,
                       "地址优先于「带格式」那条")
        XCTAssertEqual(classify(types: [png, text], string: "file:///Users/me/a.png"), .image)
        XCTAssertEqual(classify(types: [png, text], string: "data:image/png;base64,iVBORw0KGgo="), .image)
    }

    func testImageWithAFileNameIsAnImage() {
        XCTAssertEqual(classify(types: [png, text], string: "IMG_1234.PNG"), .image)
        XCTAssertEqual(classify(types: [png, text], string: "Screenshot 2026-11-24 at 10.12.33.png"), .image)
        XCTAssertEqual(classify(types: [png, text, "public.rtf"], string: "截图 2026-11-24.jpeg"), .image)
    }

    func testImageWithShortTextIsAnImage() {
        XCTAssertEqual(classify(types: [png, text], string: "logo"), .image)
        XCTAssertEqual(classify(types: [png, text], string: String(repeating: "字", count: 20)), .image)
    }

    func testImageWithLongTextIsText() {
        XCTAssertEqual(classify(types: [png, text], string: String(repeating: "字", count: 21)), .text)
        XCTAssertEqual(classify(types: [png, text], string: "第一行\n第二行"), .text, "多行的文字不算「很短」")
    }

    func testDocumentSelectionWithAPictureIsText() {
        // 表格、文档里复制一段：文字 + RTF / HTML + 一张这段内容的截图。再短也按文字。
        XCTAssertEqual(classify(types: [text, "public.rtf", "public.html", tiff], string: "42"), .text)
        XCTAssertEqual(classify(types: [text, "com.apple.webarchive", png], string: "Hello"), .text)
    }

    // MARK: - 文字

    func testPlainTextIsText() {
        XCTAssertEqual(classify(types: [text], string: "hello"), .text)
        XCTAssertEqual(classify(types: [text, "public.rtf"], string: "第一段\n第二段"), .text)
        XCTAssertEqual(classify(types: [text], string: " "), .text, "空白也照旧交给输入框")
    }

    func testNothing() {
        XCTAssertEqual(classify(), .nothing)
        XCTAssertEqual(classify(types: ["com.adobe.pdf"]), .nothing, "PDF 这一期不算图片")
    }

    func testImageAddressAndFileNameRules() {
        XCTAssertTrue(LauncherPasteClassifier.isImageAddress("https://a.b/c"))
        XCTAssertFalse(LauncherPasteClassifier.isImageAddress("https://a.b/c d"))
        XCTAssertFalse(LauncherPasteClassifier.isImageAddress("ftp://a.b/c"))
        XCTAssertFalse(LauncherPasteClassifier.isImageAddress(""))
        XCTAssertTrue(LauncherPasteClassifier.isImageFileName("a.gif"))
        XCTAssertFalse(LauncherPasteClassifier.isImageFileName(".png"), "只有扩展名的不算")
        XCTAssertFalse(LauncherPasteClassifier.isImageFileName("report.pdf"))
        XCTAssertFalse(LauncherPasteClassifier.isImageFileName("a\nb.png"))
        XCTAssertFalse(LauncherPasteClassifier.isImageFileName(String(repeating: "a", count: 300) + ".png"))
    }

    // MARK: - 贴进文件时的路径

    func testFileFieldTextUsesTildeUnderHome() {
        // 显式 isDirectory：不写的话 URL(fileURLWithPath:) 会查磁盘，路径在跑测试的机器上是目录就带上结尾的 /
        let home = "/Users/me"
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/Users/me/Desktop/a b.png", isDirectory: false), home: home),
                       "~/Desktop/a b.png")
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/opt/tools/report.pdf", isDirectory: false), home: home),
                       "/opt/tools/report.pdf")
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/Users/me", isDirectory: false), home: home), "~")
    }

    func testFolderFieldTextEndsWithSlash() {
        let home = "/Users/me"
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/Users/me/Documents/", isDirectory: true),
                                                    home: home), "~/Documents/")
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(string: "file:///private/tmp/")!, home: home), "/private/tmp/")
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/", isDirectory: true), home: home), "/")
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(fileURLWithPath: "/Users/me/", isDirectory: true), home: home), "~/")
    }

    func testFileFieldTextDecodesPercentEscapes() {
        XCTAssertEqual(LauncherPastedFile.fieldText(for: URL(string: "file:///Users/me/%E6%96%87%E6%A1%A3/x%20y.txt")!,
                                                    home: "/Users/me"), "~/文档/x y.txt")
        XCTAssertNil(LauncherPastedFile.fieldText(for: URL(string: "https://example.com/a.png")!, home: "/Users/me"))
    }
}
