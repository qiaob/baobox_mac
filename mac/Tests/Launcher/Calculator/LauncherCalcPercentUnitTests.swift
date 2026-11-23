import Foundation
import XCTest

/// 计算引擎：百分比与单位换算（docs/launcher/TECH_DESIGN.md §7 第 3、4 种句型）。
final class LauncherCalcPercentTests: XCTestCase {

    func testRequirementExamples() {
        assertLauncherCalc("200 的 15%", "30", "200 × 15%", kind: .percentage, copy: "30")
        assertLauncherCalc("15% of 200", "30", "200 × 15%")
        assertLauncherCalc("200 + 15%", "230", "200 × (1 + 15%)")
        assertLauncherCalc("200 - 15%", "170", "200 × (1 - 15%)")
        assertLauncherCalc("180 是 240 的百分之几", "75%", "180 ÷ 240", copy: "75%")
        assertLauncherCalc("180 is what percent of 240", "75%", "180 ÷ 240")
    }

    func testOtherWordings() {
        assertLauncherCalc("200的15%", "30", "200 × 15%")
        assertLauncherCalc("200的百分之15", "30", "200 × 15%")
        assertLauncherCalc("15 percent of 200", "30", "200 × 15%")
        assertLauncherCalc("200 * 15%", "30", "200 × 15%")
        assertLauncherCalc("what percent of 240 is 180", "75%", "180 ÷ 240")
        assertLauncherCalc("180 is what % of 240", "75%", "180 ÷ 240")
        assertLauncherCalc("180占240的百分比", "75%", "180 ÷ 240")
        assertLauncherCalc("180 是 240 的百分之多少", "75%", "180 ÷ 240")
    }

    func testOperandsCanBeExpressions() {
        assertLauncherCalc("(100+100) 的 15%", "30", "(100 + 100) × 15%")
        assertLauncherCalc("1,000 + 15%", "1,150", "1000 × (1 + 15%)")
        assertLauncherCalc("2 * 100 + 15%", "230", "(2 × 100) × (1 + 15%)")
    }

    func testAmbiguousOfWithoutParenthesesGivesNothing() {
        // 是 (100 + 100) × 50% 还是 100 + 100 × 50%，说不准：不出，加括号就出。
        assertLauncherCalcNil("100 + 100 的 50%")
        assertLauncherCalcNil("15% of 100 + 100")
    }

    func testExactDecimals() {
        assertLauncherCalc("0.1 的 10%", "0.01", "0.1 × 10%")
        assertLauncherCalc("1 是 3 的百分之几", "33.3333333333333%", "1 ÷ 3")
    }

    func testRatioOfZeroIsDivisionByZero() {
        assertLauncherCalcFailure("1 是 0 的百分之几", .divisionByZero, interpretation: "1 ÷ 0")
    }

    func testPercentSignBetweenTwoNumbersIsRemainder() {
        XCTAssertEqual(launcherCalc("10 % 3")?.kind, .arithmetic)
    }

    func testBarePercentIsNotACalculation() {
        assertLauncherCalcNil("50%")
        assertLauncherCalcNil("15% of")
        assertLauncherCalcNil("的 15%")
        assertLauncherCalcNil("200 的")
    }
}

final class LauncherCalcUnitTests: XCTestCase {

    func testRequirementExamples() {
        assertLauncherCalc("5 英里 公里", "8.04672 公里", "5 英里 → 公里", kind: .unit, copy: "8.04672")
        assertLauncherCalc("5 miles to km", "8.04672 公里", "5 英里 → 公里")
        assertLauncherCalc("72 f to c", "22.2222 摄氏度", "72 华氏度 → 摄氏度", copy: "22.22222222")
        assertLauncherCalc("1.5 GB in MB", "1,500 MB", "1.5 GB → MB", copy: "1500")
        assertLauncherCalc("3 小时 20 分 秒", "12,000 秒", "3 小时 20 分钟 → 秒")
        assertLauncherCalc("100 平方米 平方英尺", "1,076.39 平方英尺", "100 平方米 → 平方英尺", copy: "1076.391042")
        assertLauncherCalc("60 mph kmh", "96.5606 公里/小时", "60 英里/小时 → 公里/小时", copy: "96.56064")
    }

    func testEnglishInterfaceUsesSymbols() {
        assertLauncherCalc("5 miles to km", "8.04672 km", "5 mi → km", english: true)
        assertLauncherCalc("100 平方米 平方英尺", "1,076.39 ft²", "100 m² → ft²", english: true)
        assertLauncherCalc("72 f to c", "22.2222 °C", "72 °F → °C", english: true)
    }

    func testSpellingsAndConnectors() {
        assertLauncherCalc("5英里公里", "8.04672 公里", "5 英里 → 公里")
        assertLauncherCalc("5英里是多少公里", "8.04672 公里", "5 英里 → 公里")
        assertLauncherCalc("5 mi = km", "8.04672 公里", "5 英里 → 公里")
        assertLauncherCalc("72°F to °C", "22.2222 摄氏度", "72 华氏度 → 摄氏度")
        assertLauncherCalc("72℉ in ℃", "22.2222 摄氏度", "72 华氏度 → 摄氏度")
        assertLauncherCalc("100 km/h to m/s", "27.7778 米/秒", "100 公里/小时 → 米/秒")
        assertLauncherCalc("2 sq ft to square inches", "288 平方英寸", "2 平方英尺 → 平方英寸")
    }

    func testCompoundQuantities() {
        assertLauncherCalc("5 ft 11 in to cm", "180.34 厘米", "5 英尺 11 英寸 → 厘米")
        assertLauncherCalc("3h20m to s", "12,000 秒", "3 小时 20 分钟 → 秒")
    }

    func testAmbiguousAbbreviationFollowsTheOtherSide() {
        assertLauncherCalc("5 m to ft", "16.4042 英尺", "5 米 → 英尺")
        assertLauncherCalc("30 m to s", "1,800 秒", "30 分钟 → 秒")
    }

    func testDataUnitsAreCaseSensitive() {
        assertLauncherCalc("100 Mb to MB", "12.5 MB", "100 Mb → MB")
        assertLauncherCalc("1 GiB to MB", "1,073.74 MB", "1 GiB → MB")
        assertLauncherCalc("1 gb to mb", "1,000 MB", "1 GB → MB")
    }

    func testChineseAndImperialUnitsUseExactFactors() {
        assertLauncherCalc("2斤 克", "1,000 克", "2 斤 → 克")
        assertLauncherCalc("1 lb to g", "453.592 克", "1 磅 → 克", copy: "453.59237")
        assertLauncherCalc("1 gal to l", "3.78541 升", "1 加仑 → 升", copy: "3.785411784")
        assertLauncherCalc("10 kn to km/h", "18.52 公里/小时", "10 节 → 公里/小时")
        assertLauncherCalc("1亩 平方米", "666.667 平方米", "1 亩 → 平方米")
    }

    func testDisplayKeepsSixSignificantDigitsAndCopyKeepsTen() {
        assertLauncherCalc("5 in to cm", "12.7 厘米", "5 英寸 → 厘米", copy: "12.7")
        assertLauncherCalc("0.000123456789 km to m", "0.123457 米", "0.000123456789 公里 → 米", copy: "0.123456789")
        // 整数部分超过 6 位时取整到个位，不变成科学计数法。
        assertLauncherCalc("1000 km to m", "1,000,000 米", "1000 公里 → 米", copy: "1000000")
        assertLauncherCalc("1234.5678 km to m", "1,234,568 米", "1234.5678 公里 → 米", copy: "1234567.8")
        assertLauncherCalc("1 light year to km", "9.46073e12 公里", "1 光年 → 公里", copy: "9.460730473e12")
    }

    func testNegativeTemperature() {
        assertLauncherCalc("-40 c to f", "-40 华氏度", "-40 摄氏度 → 华氏度")
    }

    func testDifferentDimensionsGiveNothing() {
        assertLauncherCalcNil("5 km to kg")
        assertLauncherCalcNil("1 GB to km")
        assertLauncherCalcNil("3 小时 公里")
        assertLauncherCalcNil("20 c 5 f to k")
    }

    func testQuantityWithoutTargetGivesNothing() {
        assertLauncherCalcNil("5 km")
        assertLauncherCalcNil("3 小时")
        assertLauncherCalcNil("1.5 GB")
        assertLauncherCalcNil("5 km to")
    }
}
