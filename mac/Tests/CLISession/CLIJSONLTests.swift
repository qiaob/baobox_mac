import Foundation
import XCTest

/// 逐行解析的两个小工具与项目名。
final class CLIJSONLTests: XCTestCase {

    func testParsesTimestampsWithAndWithoutMilliseconds() {
        XCTAssertEqual(CLIJSONL.parseDate("2026-11-10T08:00:00.250Z")?.timeIntervalSince1970 ?? 0,
                       1_794_297_600.25, accuracy: 0.001)
        XCTAssertEqual(CLIJSONL.parseDate("2026-11-10T08:00:00Z"), Date(timeIntervalSince1970: 1_794_297_600))
        XCTAssertEqual(CLIJSONL.parseDate("2026-11-10T16:00:00+08:00"), Date(timeIntervalSince1970: 1_794_297_600))
    }

    func testRejectsTimestampsThatAreNotISO8601() {
        XCTAssertNil(CLIJSONL.parseDate(""))
        XCTAssertNil(CLIJSONL.parseDate("2026-11-10"))
        XCTAssertNil(CLIJSONL.parseDate("2026-11-10 08:00:00"))
        XCTAssertNil(CLIJSONL.parseDate("yesterday"))
    }

    func testParseObjectOnlyAcceptsJSONObjects() {
        let object = CLIJSONL.parseObject(Data(#"{"type":"user","n":3}"#.utf8))
        XCTAssertEqual(object?["type"] as? String, "user")
        XCTAssertEqual(object?["n"] as? Int, 3)

        XCTAssertNil(CLIJSONL.parseObject(Data("[1,2]".utf8)), "数组不是对象")
        XCTAssertNil(CLIJSONL.parseObject(Data(#""text""#.utf8)), "字符串不是对象")
        XCTAssertNil(CLIJSONL.parseObject(Data("42".utf8)), "数字不是对象")
        XCTAssertNil(CLIJSONL.parseObject(Data(#"{"type":"user""#.utf8)), "写了一半的行")
        XCTAssertNil(CLIJSONL.parseObject(Data()), "空行")
        XCTAssertNil(CLIJSONL.parseObject(Data([0x7B, 0xE6, 0x88, 0x7D])), "坏 UTF-8")
    }

    func testProjectNameIsTheLastPathComponent() {
        XCTAssertEqual(CLISessionPaths.projectName(fromPath: "/Users/me/work/app"), "app")
        XCTAssertEqual(CLISessionPaths.projectName(fromPath: "/Users/me/work/app/"), "app")
        XCTAssertEqual(CLISessionPaths.projectName(fromPath: "/Users/me/工作/小工具"), "小工具")
        XCTAssertEqual(CLISessionPaths.projectName(fromPath: "/"), "/")
    }
}
