import XCTest

/// 往别的 App 插文字时选哪一档（`TextInsertionPolicy.route`，docs/dictation/TECH_DESIGN.md §5）。
final class TextInsertionPolicyTests: XCTestCase {
    private typealias Focus = TextInsertionPolicy.Focus

    func testBrowserReportingNoFocusedElementStillPastes() {
        // Chrome 的网页辅助功能树没打开时，焦点查询回答「没有焦点元素」（role 为 nil）。
        let route = TextInsertionPolicy.route(pasteOnly: false, browser: true, alwaysPaste: false, focus: Focus())
        XCTAssertEqual(route, .paste)
    }

    func testNonBrowserReportingNoFocusedElementCopies() {
        let route = TextInsertionPolicy.route(pasteOnly: false, browser: false, alwaysPaste: false, focus: Focus())
        XCTAssertEqual(route, .copy(.noTextFocus))
    }

    func testSecureFieldNeverPastesEvenInABrowser() {
        let focus = Focus(role: "AXTextField", subrole: TextInsertionPolicy.secureSubrole)
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, browser: true, alwaysPaste: false, focus: focus),
                       .copy(.secureInput))
    }

    func testUnansweredProbePastes() {
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, browser: false, alwaysPaste: false, focus: nil), .paste)
    }

    func testPasteOnlyAppsPaste() {
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: true, alwaysPaste: false, focus: Focus()), .paste)
    }

    func testNativeFieldIsWrittenThroughAccessibility() {
        let focus = Focus(role: "AXTextField", selectedTextSettable: true, valueReadable: true)
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, alwaysPaste: false, focus: focus), .accessibility)
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, alwaysPaste: true, focus: focus), .paste)
    }

    func testBrowserNativeFieldStillUsesAccessibility() {
        // 地址栏这类原生输入框照常直接写。
        let focus = Focus(role: "AXTextField", selectedTextSettable: true, valueReadable: true)
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, browser: true, alwaysPaste: false, focus: focus),
                       .accessibility)
    }

    func testBrowserWebContentPastes() {
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, browser: true, alwaysPaste: false,
                                                 focus: Focus(role: "AXGroup")), .paste)
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, browser: false, alwaysPaste: false,
                                                 focus: Focus(role: "AXTextArea", inWebArea: true)), .paste)
    }

    func testButtonFocusInANativeAppCopies() {
        XCTAssertEqual(TextInsertionPolicy.route(pasteOnly: false, alwaysPaste: false, focus: Focus(role: "AXButton")),
                       .copy(.noTextFocus))
    }

    func testBrowserRecognitionByBundleID() {
        XCTAssertTrue(TextInsertionPolicy.isBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(TextInsertionPolicy.isBrowser(bundleID: "com.google.Chrome.canary"))
        XCTAssertTrue(TextInsertionPolicy.isBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(TextInsertionPolicy.isBrowser(bundleID: "com.apple.Notes"))
        XCTAssertFalse(TextInsertionPolicy.isBrowser(bundleID: nil))
    }
}
