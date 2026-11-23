import Foundation
import XCTest

/// 计算引擎：算术（docs/launcher/TECH_DESIGN.md §7 第 5 种句型、「精度」；REQUIREMENTS.md §3.3）。
final class LauncherCalcArithmeticTests: XCTestCase {

    // MARK: - 需求里的例子

    func testRequirementExamples() {
        assertLauncherCalc("12*(3+4)", "84", "12 × (3 + 4)", kind: .arithmetic, copy: "84")
        assertLauncherCalc("2^10", "1,024", "2^10", copy: "1024")
        assertLauncherCalc("sqrt(2)", "1.41421356237", "sqrt(2)")
        assertLauncherCalc("1.5e3 / 4", "375", "1500 ÷ 4")
        assertLauncherCalc("0.1 + 0.2", "0.3", "0.1 + 0.2", copy: "0.3")
        assertLauncherCalc("-3 + 5", "2", "-3 + 5")
        assertLauncherCalc("10 % 3", "1", "10 mod 3")
        assertLauncherCalc("pi * 2", "6.28318530718", "π × 2")
        assertLauncherCalc("3 × 4 ÷ 2", "6", "3 × 4 ÷ 2")
        assertLauncherCalc("（１＋２）＊３", "9", "(1 + 2) × 3")
    }

    // MARK: - 精度与显示

    func testDecimalArithmeticIsExact() {
        assertLauncherCalc("1/3*3", "1", "1 ÷ 3 × 3")
        assertLauncherCalc("0.1*3", "0.3", "0.1 × 3")
        assertLauncherCalc("1.1^2", "1.21", "1.1^2")
        assertLauncherCalc("0.3 - 0.1", "0.2", "0.3 - 0.1")
    }

    func testNonTerminatingDecimalsAreRounded() {
        // 精确值显示 15 位有效数字。
        assertLauncherCalc("2/3", "0.666666666666667", "2 ÷ 3")
        assertLauncherCalc("24/7", "3.42857142857143", "24 ÷ 7")
    }

    func testThousandsSeparatorsInDisplayButNotInCopy() {
        assertLauncherCalc("1,000 * 1.2345", "1,234.5", "1000 × 1.2345", copy: "1234.5")
        assertLauncherCalc("1,234,567 + 1", "1,234,568", "1234567 + 1", copy: "1234568")
    }

    func testLargeAndSmallNumbers() {
        assertLauncherCalc("2^64", "18,446,744,073,709,551,616", "2^64", copy: "18446744073709551616")
        assertLauncherCalc("2^100", "1.26765060022823e30", "2^100")
        assertLauncherCalc("1/10^6", "0.000001", "1 ÷ 10^6")
        assertLauncherCalc("1/10^7", "1e-7", "1 ÷ 10^7")
    }

    func testChineseMultiplierSuffixes() {
        assertLauncherCalc("3万 + 2千", "32,000", "30000 + 2000")
        assertLauncherCalc("1.5亿 / 3", "50,000,000", "150000000 ÷ 3")
    }

    func testTrailingAndLeadingEqualsSign() {
        assertLauncherCalc("1+2=", "3", "1 + 2")
        assertLauncherCalc("=1+2", "3", "1 + 2")
    }

    // MARK: - 运算符与函数

    func testOperatorPrecedenceAndAssociativity() {
        assertLauncherCalc("-2^2", "-4", "-2^2")
        assertLauncherCalc("2^3^2", "512", "2^3^2")
        assertLauncherCalc("2^-1", "0.5", "2^-1")
        assertLauncherCalc("2**10", "1,024", "2^10")
        assertLauncherCalc("1 + 2 * 3", "7", "1 + 2 × 3")
        assertLauncherCalc("5-3", "2", "5 - 3")
        assertLauncherCalc("100/4", "25", "100 ÷ 4")
    }

    func testRemainder() {
        assertLauncherCalc("10 mod 3", "1", "10 mod 3")
        assertLauncherCalc("-7 % 3", "-1", "-7 mod 3")
        assertLauncherCalc("7.5 % 2", "1.5", "7.5 mod 2")
    }

    func testFunctionsAndConstants() {
        assertLauncherCalc("sin(pi)", "0", "sin(π)")
        assertLauncherCalc("sin(30°)", "0.5", "sin(30°)")
        assertLauncherCalc("sin 30°", "0.5", "sin(30°)")
        assertLauncherCalc("cos(0)", "1", "cos(0)")
        assertLauncherCalc("log2(8)", "3", "log2(8)")
        assertLauncherCalc("log10(1000)", "3", "log10(1000)")
        assertLauncherCalc("log(100)", "2", "log10(100)")
        assertLauncherCalc("ln(e)", "1", "ln(e)")
        assertLauncherCalc("sqrt 16", "4", "sqrt(16)")
        assertLauncherCalc("√16", "4", "sqrt(16)")
        assertLauncherCalc("根号2", "1.41421356237", "sqrt(2)")
        assertLauncherCalc("cbrt(27)", "3", "cbrt(27)")
        assertLauncherCalc("abs(-3.5)", "3.5", "abs(-3.5)")
        assertLauncherCalc("floor(-7.5)", "-8", "floor(-7.5)")
        assertLauncherCalc("ceil(-7.5)", "-7", "ceil(-7.5)")
        assertLauncherCalc("round(2.5)", "3", "round(2.5)")
        assertLauncherCalc("e + 1", "3.71828182846", "e + 1")
    }

    func testRadixLiteralsInsideExpressions() {
        assertLauncherCalc("0xff + 1", "256", "255 + 1")
        assertLauncherCalc("0b1010 * 2", "20", "10 × 2")
    }

    // MARK: - 出错给说明

    func testDivisionByZero() {
        assertLauncherCalcFailure("1/0", .divisionByZero, interpretation: "1 ÷ 0")
        assertLauncherCalcFailure("5 % 0", .divisionByZero, interpretation: "5 mod 0")
        assertLauncherCalcFailure("0^-1", .divisionByZero)
        assertLauncherCalcFailure("1/(2-2)", .divisionByZero, interpretation: "1 ÷ (2 - 2)")
        XCTAssertEqual(launcherCalc("1/0", english: true)?.display, "Division by zero")
        XCTAssertEqual(launcherCalc("1/0")?.display, "不能除以零")
    }

    func testNotRealAndInfinite() {
        assertLauncherCalcFailure("sqrt(-1)", .notReal, interpretation: "sqrt(-1)")
        assertLauncherCalcFailure("(-8)^0.5", .notReal)
        assertLauncherCalcFailure("asin(2)", .notReal)
        assertLauncherCalcFailure("ln(0)", .infinite)
        assertLauncherCalcFailure("log(-1)", .notReal)
    }

    func testOverflow() {
        assertLauncherCalcFailure("10^1000", .overflow, interpretation: "10^1000")
        assertLauncherCalcFailure("9^9^9", .overflow)
        assertLauncherCalcFailure("1e300 * 1e300", .overflow)
        assertLauncherCalcFailure("exp(1000)", .overflow)
    }

    // MARK: - 括号与嵌套

    func testUnbalancedParenthesesGiveNothing() {
        assertLauncherCalcNil("(1+2")
        assertLauncherCalcNil("1+2)")
        assertLauncherCalcNil("((1+2)")
        assertLauncherCalcNil("()")
        assertLauncherCalcNil("(")
    }

    func testModeratelyNestedParenthesesStillWork() {
        let input = String(repeating: "(", count: 25) + "1+1" + String(repeating: ")", count: 25)
        XCTAssertEqual(launcherCalc(input)?.display, "2")
    }

    func testDeeplyNestedInputIsRejectedWithoutCrashing() {
        let parens = String(repeating: "(", count: 79) + "1" + String(repeating: ")", count: 79)
        XCTAssertNil(launcherCalc(parens))
        let minuses = String(repeating: "-", count: 150) + "1+1"
        XCTAssertNil(launcherCalc(minuses))
        let roots = String(repeating: "√", count: 150) + "2"
        XCTAssertNil(launcherCalc(roots))
    }

    // MARK: - 数字格式

    func testFormatRoundingCarries() {
        XCTAssertEqual(LauncherCalcFormat.number(.approx(9.99999999999999))?.display, "10")
        XCTAssertEqual(LauncherCalcFormat.number(.approx(-0.0))?.display, "0")
        XCTAssertEqual(LauncherCalcFormat.number(.approx(123_456.7))?.display, "123,456.7")
        XCTAssertEqual(LauncherCalcFormat.number(.approx(1e20))?.display, "1e20")
        XCTAssertEqual(LauncherCalcFormat.number(.exact(Decimal(1_000)))?.display, "1,000")
        XCTAssertNil(LauncherCalcFormat.number(.approx(.infinity)))
        XCTAssertNil(LauncherCalcFormat.number(.approx(.nan)))
    }

    func testNormalization() {
        XCTAssertEqual(LauncherCalcLexer.normalize("（１＋２）×３÷４−５"), "(1+2)*3/4-5")
        XCTAssertEqual(LauncherCalcLexer.normalize("2**10="), "2^10")
        XCTAssertEqual(LauncherCalcLexer.normalize("  下周五是几号？ "), "下周五是几号")
    }
}
