import Foundation
import XCTest

/// 计算引擎：进制与时间戳（docs/launcher/TECH_DESIGN.md §7 第 1 种句型）。
final class LauncherCalcBaseTests: XCTestCase {

    func testRequirementExamples() {
        assertLauncherCalc("0xff", "255", "0xFF → 十进制", kind: .base, copy: "255")
        assertLauncherCalc("255 to hex", "0xFF", "255 → 十六进制", copy: "0xFF")
        assertLauncherCalc("0b1010 to dec", "10", "0b1010 → 十进制")
        assertLauncherCalc("255 转 二进制", "0b11111111", "255 → 二进制")
        assertLauncherCalc("0o17", "15", "0o17 → 十进制")
    }

    func testOtherWordings() {
        assertLauncherCalc("255 转16进制", "0xFF", "255 → 十六进制")
        assertLauncherCalc("255转八进制", "0o377", "255 → 八进制")
        assertLauncherCalc("255 hex", "0xFF", "255 → 十六进制")
        assertLauncherCalc("0xff to bin", "0b11111111", "0xFF → 二进制")
        assertLauncherCalc("255 in binary", "0b11111111", "255 → 二进制")
        assertLauncherCalc("255 to hex", "0xFF", "255 → hex", english: true)
    }

    func testNegativeAndLargeValues() {
        assertLauncherCalc("-255 to hex", "-0xFF", "-255 → 十六进制")
        assertLauncherCalc("0xffff to dec", "65,535", "0xFFFF → 十进制", copy: "65535")
        assertLauncherCalc("0xFFFFFFFFFFFFFFFF", "18,446,744,073,709,551,615", "0xFFFFFFFFFFFFFFFF → 十进制")
        assertLauncherCalcFailure("99999999999999999999999 to hex", .overflow)
    }

    func testNotAConversion() {
        assertLauncherCalcNil("3.5 to hex")
        assertLauncherCalcNil("255 dec")
        assertLauncherCalcNil("0xff to hex")
        assertLauncherCalcNil("hex")
        assertLauncherCalcNil("0bin")
        assertLauncherCalcNil("1hex")
        assertLauncherCalcNil("0x")
        assertLauncherCalcNil("0xg")
        assertLauncherCalcNil("0b102")
    }
}

final class LauncherCalcTimestampTests: XCTestCase {

    func testNowGivesCurrentUnixTimestamp() {
        assertLauncherCalc("now", "1795399200", "2026-11-23 10:00:00 的 Unix 时间戳（秒）", kind: .timestamp,
                           copy: "1795399200")
        assertLauncherCalc("现在的时间戳", "1795399200", "2026-11-23 10:00:00 的 Unix 时间戳（秒）")
        assertLauncherCalc("当前时间戳", "1795399200", "2026-11-23 10:00:00 的 Unix 时间戳（秒）")
        assertLauncherCalc("unix timestamp", "1795399200", "2026-11-23 10:00:00 的 Unix 时间戳（秒）")
        assertLauncherCalc("now", "1795399200", "Unix timestamp (seconds) at 2026-11-23 10:00:00", english: true)
    }

    func testMilliseconds() {
        assertLauncherCalc("毫秒时间戳", "1795399200000", "2026-11-23 10:00:00 的 Unix 时间戳（毫秒）")
        assertLauncherCalc("now in ms", "1795399200000", "2026-11-23 10:00:00 的 Unix 时间戳（毫秒）")
    }

    func testNowFollowsTheContext() {
        let later = LauncherCalcTestSupport.context(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(LauncherCalculator.evaluate("now", context: later)?.display, "1800000000")
    }

    func testBareTimestampNumbersAreLeftToTheTextRecognizer() {
        // 裸的时间戳数字由快速入口的文本识别来源（剪贴板的时间戳识别器）处理，计算引擎不出，免得出两行。
        assertLauncherCalcNil("1700000000")
        assertLauncherCalcNil("1700000000000")
        assertLauncherCalcNil("timestamp")
        assertLauncherCalcNil("时间戳")
        assertLauncherCalcNil("现在")
    }
}
