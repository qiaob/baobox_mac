import Foundation
import XCTest

/// 快速入口 App 来源的名字规则（docs/launcher/TECH_DESIGN.md §6.1）。
final class LauncherAppNamesTests: XCTestCase {

    func testDisplayNameFirstThenOthersDeduplicated() {
        let names = LauncherAppNames.searchNames(["微信", "WeChat", "WeChat", "WeChat.app"])
        XCTAssertEqual(names, ["微信", "WeChat"])
    }

    func testDuplicatesIgnoreCase() {
        XCTAssertEqual(LauncherAppNames.searchNames(["Visual Studio Code", "visual studio code", "Code"]),
                       ["Visual Studio Code", "Code"])
    }

    func testAppSuffixIsStrippedEverywhere() {
        XCTAssertEqual(LauncherAppNames.searchNames(["Safari.app", nil, "Safari"]), ["Safari"])
        XCTAssertEqual(LauncherAppNames.searchNames(["Foo.APP"]), ["Foo"])
    }

    func testNilBlankAndBareSuffixAreDropped() {
        XCTAssertEqual(LauncherAppNames.searchNames([nil, "", "  ", ".app", "Notes"]), ["Notes"])
        XCTAssertEqual(LauncherAppNames.searchNames([nil, nil]), [])
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(LauncherAppNames.searchNames(["  Xcode  ", "Xcode"]), ["Xcode"])
    }

    func testStrippingAppExtension() {
        XCTAssertEqual(LauncherAppNames.strippingAppExtension("系统设置.app"), "系统设置")
        XCTAssertEqual(LauncherAppNames.strippingAppExtension("Safari"), "Safari")
        XCTAssertEqual(LauncherAppNames.strippingAppExtension(".app"), ".app")
        XCTAssertEqual(LauncherAppNames.strippingAppExtension("My.application"), "My.application")
    }

    func testIsAppBundleName() {
        XCTAssertTrue(LauncherAppNames.isAppBundleName("Safari.app"))
        XCTAssertTrue(LauncherAppNames.isAppBundleName("Foo.APP"))
        XCTAssertFalse(LauncherAppNames.isAppBundleName(".app"))
        XCTAssertFalse(LauncherAppNames.isAppBundleName("Utilities"))
        XCTAssertFalse(LauncherAppNames.isAppBundleName("notes.application"))
    }
}
