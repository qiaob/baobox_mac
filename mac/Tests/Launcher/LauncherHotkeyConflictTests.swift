import Foundation
import XCTest

/// 别的启动器也用 ⌘Space 时的提示和回执：只在有证据时说撞了（docs/launcher/TECH_DESIGN.md §9）。
final class LauncherHotkeyConflictTests: XCTestCase {
    private let space: UInt32 = 0x31
    private let cmd: UInt32 = 256
    private let shift: UInt32 = 512
    private let option: UInt32 = 2048

    func testCommandSpace() {
        XCTAssertTrue(LauncherHotkeyConflict.isCommandSpace(keyCode: space, carbonModifiers: cmd))
        XCTAssertFalse(LauncherHotkeyConflict.isCommandSpace(keyCode: space, carbonModifiers: option), "⌥Space 不算")
        XCTAssertFalse(LauncherHotkeyConflict.isCommandSpace(keyCode: space, carbonModifiers: cmd | shift), "⌘⇧Space 不算")
        XCTAssertFalse(LauncherHotkeyConflict.isCommandSpace(keyCode: 0x09, carbonModifiers: cmd))
    }

    func testKnownLaunchers() {
        XCTAssertEqual(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.raycast.macos"), "Raycast")
        XCTAssertEqual(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred"), "Alfred", "Alfred 4 起")
        XCTAssertEqual(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred-3"), "Alfred")
        XCTAssertEqual(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred-2"), "Alfred")
        XCTAssertNil(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred-Preferences"), "偏好设置 App 不算")
        XCTAssertNil(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred-Preferences-3"))
        XCTAssertNil(LauncherHotkeyConflict.knownLauncherName(bundleID: "com.runningwithcrayons.Alfred-"))
        XCTAssertNil(LauncherHotkeyConflict.knownLauncherName(bundleID: "io.appmakes.otty"))
        XCTAssertNil(LauncherHotkeyConflict.knownLauncherName(bundleID: nil))
    }

    // MARK: - Raycast 的 raycastGlobalHotkey

    func testParseRaycastHotkey() {
        let commandSpace = LauncherHotkeyConflict.parseRaycastHotkey("Command-49")
        XCTAssertEqual(commandSpace, LauncherHotkeyConflict.ForeignHotkey(keyCode: 49, command: true))
        XCTAssertTrue(commandSpace?.isCommandSpace == true, "用户机器上读出来的就是这个")

        let optionSpace = LauncherHotkeyConflict.parseRaycastHotkey("Option-49")
        XCTAssertEqual(optionSpace, LauncherHotkeyConflict.ForeignHotkey(keyCode: 49, option: true))
        XCTAssertFalse(optionSpace?.isCommandSpace == true, "Raycast 的出厂键 ⌥Space：不撞")

        let commandShiftSpace = LauncherHotkeyConflict.parseRaycastHotkey("Command-Shift-49")
        XCTAssertEqual(commandShiftSpace, LauncherHotkeyConflict.ForeignHotkey(keyCode: 49, command: true, shift: true))
        XCTAssertFalse(commandShiftSpace?.isCommandSpace == true, "多了 ⇧：不撞")

        XCTAssertFalse(LauncherHotkeyConflict.parseRaycastHotkey("Command-36")?.isCommandSpace == true, "⌘⏎")
        XCTAssertEqual(LauncherHotkeyConflict.parseRaycastHotkey("command-49")?.isCommandSpace, true, "大小写不论")
    }

    func testUnreadableRaycastHotkeyIsNoConflict() {
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey(nil), "没有这个键")
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey(""))
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("Command-"))
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("Command"))
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("Hyper-49"), "认不出的修饰键名")
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("⌘Space"))
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("Command-4x9"))
        XCTAssertNil(LauncherHotkeyConflict.parseRaycastHotkey("Command-٤٩"), "非 ASCII 数字")
    }

    // MARK: - 有证据才说撞了

    private func confirmed(ourModifiers: UInt32? = 256, ourRegistered: Bool = true, raycastRunning: Bool = true,
                           raycastHotkey: String? = "Command-49") -> String? {
        LauncherHotkeyConflict.confirmedConflict(ourKeyCode: ourModifiers == nil ? nil : space, ourModifiers: ourModifiers,
                                                 ourRegistered: ourRegistered, raycastRunning: raycastRunning,
                                                 raycastHotkey: raycastHotkey)
    }

    func testConfirmedConflictNeedsEveryPieceOfEvidence() {
        XCTAssertEqual(confirmed(), "Raycast")
        XCTAssertNil(confirmed(raycastHotkey: "Option-49"), "Raycast 用的是出厂的 ⌥Space：不提示")
        XCTAssertNil(confirmed(raycastHotkey: nil), "读不到 Raycast 的绑定：当作没有冲突")
        XCTAssertNil(confirmed(raycastHotkey: "garbage"), "格式不认识：当作没有冲突")
        XCTAssertNil(confirmed(raycastRunning: false), "Raycast 没在运行")
        XCTAssertNil(confirmed(ourModifiers: option), "快速入口换了快捷键")
        XCTAssertNil(confirmed(ourModifiers: nil), "快速入口没绑快捷键")
        XCTAssertNil(confirmed(ourRegistered: false), "快速入口的 ⌘Space 自己没注册上（被 Spotlight 占着）：不说别人撞了")
    }

    // MARK: - 回执

    func testBlockedReceipt() {
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.raycast.macos", confirmedConflict: "Raycast"),
                       .hotkeyConflict(name: "Raycast"))
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.raycast.macos", confirmedConflict: nil),
                       .keyboardHeld, "没确认 Raycast 绑着 ⌘Space：不能说是撞了快捷键")
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.runningwithcrayons.Alfred", confirmedConflict: "Raycast"),
                       .keyboardHeld, "Alfred 的绑定读不到：占着键盘时用通用的那句")
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.example.other", confirmedConflict: "Raycast"),
                       .keyboardHeld)
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: nil, confirmedConflict: "Raycast"), .keyboardHeld)
    }
}
