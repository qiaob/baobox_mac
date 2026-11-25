import Foundation
import XCTest

/// 计算引擎测试共用的环境：「现在」写死成 2026-11-23 10:00 Asia/Shanghai（周一），日期和时区的断言才稳定。
enum LauncherCalcTestSupport {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3_600) ?? .current
    /// 2026-11-23 10:00:00 +08:00 = 2026-11-23 02:00:00 UTC
    static let now = Date(timeIntervalSince1970: 1_795_399_200)

    static func context(english: Bool = false, now: Date = now, timeZone: TimeZone = shanghai,
                        calendar: Calendar? = nil) -> LauncherCalcContext {
        var cal = calendar ?? Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return LauncherCalcContext(now: now, calendar: cal, timeZone: timeZone,
                                   locale: Locale(identifier: english ? "en_US" : "zh-Hans"))
    }
}

extension XCTestCase {
    func launcherCalc(_ input: String, english: Bool = false) -> LauncherCalcResult? {
        LauncherCalculator.evaluate(input, context: LauncherCalcTestSupport.context(english: english))
    }

    /// 断言出结果，且结果文字、「理解成了什么」都对；可选再核对种类和复制的文字。
    func assertLauncherCalc(_ input: String, _ display: String, _ interpretation: String,
                            kind: LauncherCalcKind? = nil, copy: String? = nil, english: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let result = launcherCalc(input, english: english) else {
            XCTFail("「\(input)」没有出结果", file: file, line: line)
            return
        }
        XCTAssertEqual(result.display, display, "「\(input)」的结果", file: file, line: line)
        XCTAssertEqual(result.interpretation, interpretation, "「\(input)」理解成了什么", file: file, line: line)
        XCTAssertNil(result.failure, "「\(input)」不该出错", file: file, line: line)
        if let kind { XCTAssertEqual(result.kind, kind, "「\(input)」的种类", file: file, line: line) }
        if let copy { XCTAssertEqual(result.copyText, copy, "「\(input)」复制的文字", file: file, line: line) }
    }

    /// 断言认成了算式、但给出的是一句说明（除以零、溢出…），没有可复制的结果。
    func assertLauncherCalcFailure(_ input: String, _ failure: LauncherCalcFailure, interpretation: String? = nil,
                                   english: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = launcherCalc(input, english: english) else {
            XCTFail("「\(input)」应该给出说明，却没有出结果", file: file, line: line)
            return
        }
        XCTAssertEqual(result.failure, failure, "「\(input)」", file: file, line: line)
        XCTAssertNil(result.copyText, "「\(input)」出错时没有可复制的文字", file: file, line: line)
        XCTAssertEqual(result.display, failure.message(LauncherCalcTestSupport.context(english: english)),
                       file: file, line: line)
        if let interpretation {
            XCTAssertEqual(result.interpretation, interpretation, "「\(input)」理解成了什么", file: file, line: line)
        }
    }

    func assertLauncherCalcNil(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = launcherCalc(input)
        XCTAssertNil(result, "「\(input)」不该出结果，却出了「\(result?.display ?? "")」（\(result?.interpretation ?? "")）",
                     file: file, line: line)
    }
}
