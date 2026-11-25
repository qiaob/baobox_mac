import Foundation
import XCTest

/// 计算引擎的反例：用户搜 App、搜文件、粘一段文字时会打出来的、像算式又不是算式的输入，一律不出结果
///（docs/launcher/TECH_DESIGN.md §7「宁可不出，不要误出」）。再加上空输入、超长输入、乱码不崩、很快返回。
final class LauncherCalcRejectionTests: XCTestCase {

    private func assertAllNil(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs { assertLauncherCalcNil(input, file: file, line: line) }
    }

    func testBareNumbers() {
        assertAllNil(["2026", "3.14", "-5", "+5", "(5)", "1,234", "1,000,000", "007", "0.5", ".5", "1e3", "50%", "-0", "3万"])
    }

    func testSingleWords() {
        assertAllNil(["pi", "e", "today", "now playing", "time", "sin", "log", "sqrt", "mod", "hex", "km", "东京", "现在"])
    }

    func testProductAndVersionNames() {
        assertAllNil([
            "iphone 15", "macOS 14", "Windows 11", "Python 3.12", "iOS 17.2", "v2.0", "v1.2.3", "m1 max",
            "ipad pro 11", "go 1.21", "html5", "ES2015", "k8s", "x86", "mp3", "1080p", "4k", "5G", "3d", "2fa",
            "1password", "7-zip", "Top 10", "50 cent", "99 problems", "30 seconds to mars", "B2B", "H2O",
        ])
    }

    func testCodeAndCommands() {
        assertAllNil([
            "a1+2", "f(x)", "c++", "c#", "a/b", "ffmpeg -i in.mp4", "git commit -m", "node -v", "rm -rf",
            "python3 -m http.server", "log12", "sin1", "sqrt9", "0bin", "1hex",
        ])
    }

    func testNumbersWithSeparatorsThatAreNotArithmetic() {
        assertAllNil([
            "192.168.1.1", "10.0.0.1:8080", "localhost:3000", "1.2.3", "2026-11-23", "2026/11/23", "11/23/2026",
            "2026-11", "2026/11", "138-1234-5678", "010-12345678", "1/2/3", "100-20-30", "covid-19", "chapter 3-5",
            "10:30", "1920x1080", "3x4",
        ])
    }

    func testTextAroundNumbers() {
        assertAllNil([
            "1/2 page", "page 1 of 10", "3 of 5", "3 apples + 2", "12 days of christmas", "2(3+4)", "2pi",
            "100元", "第2章", "2026年", "12月25日", "3m胶带", "24小时", "1 minute", "5 days", "1 week", "in 5", "5 to 7",
            "微信", "hello world", "today is good", "friday night", "星期五", "下周", "周末", "next",
        ])
    }

    func testCurrencyAndUnknownUnitsArePhaseTwo() {
        assertAllNil(["100 usd to cny", "$100", "100 usd", "350 新币 人民币", "#1", "5 km to kg"])
    }

    func testIncompleteInput() {
        assertAllNil(["1 + ", "1 2", "1 mod", "10 %", "% 3", "*3", "3*", "0x", "1e", "1 +* 2", "sqrt()", "to hex"])
    }

    // MARK: - 不崩、很快

    func testEmptyAndBlankInput() {
        assertAllNil(["", " ", "   ", "\n", "\t", "=", "?", "=?"])
    }

    func testVeryLongInputReturnsNilQuickly() {
        let longArithmetic = String(repeating: "1+", count: 5_000) + "1"
        let longChinese = String(repeating: "今天", count: 5_000)
        let longDigits = String(repeating: "9", count: 10_000)
        let start = Date()
        XCTAssertNil(launcherCalc(longArithmetic))
        XCTAssertNil(launcherCalc(longChinese))
        XCTAssertNil(launcherCalc(longDigits))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "超长输入要直接放过")
    }

    func testLongestAcceptedInputIsStillFast() {
        let chain = Array(repeating: "1", count: 75).joined(separator: "+")   // 149 个字符，在上限之内
        XCTAssertEqual(launcherCalc(chain)?.display, "75")
        let words = String(repeating: "的是", count: 79)
        let start = Date()
        XCTAssertNil(launcherCalc(words))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }

    func testOddCharactersDoNotCrash() {
        assertAllNil(["😀", "1+1😀", "\u{0}1+1", "1+\u{200B}1", "√", "°", "^", "((((", "))))", "--", "++1", "1..2", "1,,2"])
    }

    func testRandomInputsNeverCrash() {
        // 固定种子的伪随机拼接：不追求结果，只要求每一条都正常返回。
        let pieces = [
            "1", "2", "0", "9", "12", "255", "0x", "ff", "0b", "1e", "e", "-", "+", "*", "/", "^", "%", "(", ")", ".", ",",
            ":", " ", "pi", "sqrt", "log", "mod", "to", "in", "of", "is", "km", "m", "h", "°", "√", "GB", "今天", "下周五",
            "月底", "天", "的", "是", "百分之几", "东京", "现在", "几点", "下午", "点", "utc", "+8", "Asia", "/Tokyo",
            "2026-12-25", "15:00", "3pm", "万", "进制", "转", "（", "）", "×", "²", "℃", "→", "=", "?", "hex", "now",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextIndex() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(pieces.count))
        }
        let context = LauncherCalcTestSupport.context()
        for _ in 0..<3_000 {
            let length = nextIndex() % 8 + 1
            let input = (0..<length).map { _ in pieces[nextIndex()] }.joined()
            _ = LauncherCalculator.evaluate(input, context: context)
        }
    }
}
