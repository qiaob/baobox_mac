import Foundation
import XCTest

/// 别的启动器也用 ⌘Space 时的提示和回执（docs/launcher/TECH_DESIGN.md §9）。
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

    func testConflictOnlyWhenOurShortcutIsCommandSpaceAndALauncherRuns() {
        let running: [String?] = ["com.apple.finder", nil, "com.raycast.macos", "io.appmakes.otty"]
        XCTAssertEqual(LauncherHotkeyConflict.conflictingLauncher(keyCode: space, carbonModifiers: cmd, runningBundleIDs: running),
                       "Raycast")
        XCTAssertNil(LauncherHotkeyConflict.conflictingLauncher(keyCode: space, carbonModifiers: option, runningBundleIDs: running),
                     "快速入口换了快捷键：不提示")
        XCTAssertNil(LauncherHotkeyConflict.conflictingLauncher(keyCode: nil, carbonModifiers: nil, runningBundleIDs: running),
                     "没绑快捷键")
        XCTAssertNil(LauncherHotkeyConflict.conflictingLauncher(keyCode: space, carbonModifiers: cmd,
                                                                runningBundleIDs: ["com.apple.finder", "io.appmakes.otty"]),
                     "那个 App 退出了：不提示")
    }

    func testBlockedReceipt() {
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.raycast.macos", launcherHotkeyIsCommandSpace: true),
                       .hotkeyConflict(name: "Raycast"))
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.raycast.macos", launcherHotkeyIsCommandSpace: false),
                       .keyboardHeld, "快速入口不是 ⌘Space：不能说是撞了快捷键")
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: "com.example.other", launcherHotkeyIsCommandSpace: true),
                       .keyboardHeld)
        XCTAssertEqual(LauncherHotkeyConflict.blockedReceipt(holderBundleID: nil, launcherHotkeyIsCommandSpace: true), .keyboardHeld)
    }
}
