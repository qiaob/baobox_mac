import Foundation
import XCTest

/// 面板认的键：Carbon 虚拟键码 → `QuickSwitchKey`（docs/codex-assistant/DEDUPE.md §4.3、§7.1）。
final class QuickSwitchKeyTests: XCTestCase {

    func testMapsEveryKeyThePanelsHandle() {
        let table: [(UInt16, QuickSwitchKey)] = [
            (0x7E, .up),
            (0x7D, .down),
            (0x7B, .left),
            (0x7C, .right),
            (0x30, .tab),
            (0x35, .escape),
            (0x24, .enter(command: false)),   // Return
            (0x4C, .enter(command: false)),   // 小键盘 Enter
        ]
        for (code, key) in table {
            XCTAssertEqual(QuickSwitchKey(keyCode: code, command: false), key, "键码 0x\(String(code, radix: 16))")
        }
    }

    func testCopyNeedsCommand() {
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x08, command: true), .copy)
        XCTAssertNil(QuickSwitchKey(keyCode: 0x08, command: false), "裸 C 留给搜索框打字")
    }

    func testEnterRemembersCommand() {
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x24, command: true), .enter(command: true))
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x4C, command: true), .enter(command: true))
        XCTAssertNotEqual(QuickSwitchKey(keyCode: 0x24, command: true), .enter(command: false))
    }

    func testOtherKeysIgnoreCommand() {
        // 原来的 switch 只在 C 与 ⏎ 上看 ⌘：⌘↑、⌘Tab、⌘Esc 照样是那个键。
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x7E, command: true), .up)
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x7D, command: true), .down)
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x7B, command: true), .left)
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x7C, command: true), .right)
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x30, command: true), .tab)
        XCTAssertEqual(QuickSwitchKey(keyCode: 0x35, command: true), .escape)
    }

    func testUnknownKeysGoToTheSearchField() {
        // A、V、空格、删除、Home、F1：面板不认，交给搜索框。
        for code: UInt16 in [0x00, 0x09, 0x31, 0x33, 0x73, 0x7A] {
            XCTAssertNil(QuickSwitchKey(keyCode: code, command: false), "键码 0x\(String(code, radix: 16))")
            XCTAssertNil(QuickSwitchKey(keyCode: code, command: true), "⌘ + 键码 0x\(String(code, radix: 16))")
        }
    }
}
