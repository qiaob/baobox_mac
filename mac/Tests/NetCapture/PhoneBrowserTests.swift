import XCTest

final class PhoneBrowserTests: XCTestCase {
    private let safari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
    private let chrome = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1"
    private let firefox = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/133.0 Mobile/15E148 Safari/605.1.15"
    private let edge = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 EdgiOS/131.0.2903.68 Mobile/15E148 Safari/605.1.15"
    private let wechat = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.54(0x18003622) NetType/WIFI Language/zh_CN"
    private let ipadSafari = "Mozilla/5.0 (iPad; CPU OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
    private let android = "Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    func testIOSIsRecognised() {
        for agent in [safari, chrome, firefox, edge, wechat, ipadSafari] {
            XCTAssertTrue(PhoneBrowser.isIOS(userAgent: agent), agent)
        }
        XCTAssertFalse(PhoneBrowser.isIOS(userAgent: android))
        XCTAssertFalse(PhoneBrowser.isIOS(userAgent: ""))
    }

    func testOnlySafariCanInstallProfiles() {
        XCTAssertTrue(PhoneBrowser.isIOSSafari(userAgent: safari))
        XCTAssertTrue(PhoneBrowser.isIOSSafari(userAgent: ipadSafari))
        for agent in [chrome, firefox, edge, wechat] {
            XCTAssertFalse(PhoneBrowser.isIOSSafari(userAgent: agent), agent)
        }
    }

    func testOtherPlatformsAreNotIOSSafari() {
        XCTAssertFalse(PhoneBrowser.isIOSSafari(userAgent: android))
        XCTAssertFalse(PhoneBrowser.isIOSSafari(userAgent: ""))
    }
}
