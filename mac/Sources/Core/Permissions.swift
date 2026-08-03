import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit

/// 系统权限查询与引导。
enum Permissions {
    enum Pane {
        case screenRecording
        case accessibility
    }

    // MARK: 屏幕录制

    /// 启动时读到的屏幕录制授权状态。
    ///
    /// **重要**：`CGPreflightScreenCaptureAccess()` 的结果在进程内被缓存 —— 用户在系统
    /// 设置里勾选之后，当前进程**永远**读不到 true，必须重启 App 才生效（macOS 自己也是
    /// 弹 "Quit & Reopen" 处理这件事）。因此这里只在启动时求值一次并固定下来；若按变量
    /// 轮询，界面会一直显示「未授权」，让用户误以为授权没生效或 App 坏了。
    static let hasScreenRecordingAtLaunch: Bool = CGPreflightScreenCaptureAccess()

    static var hasScreenRecording: Bool { hasScreenRecordingAtLaunch }

    /// 屏幕录制的界面展示三态。
    enum ScreenRecordingState {
        case effective           // 启动时已授权，本进程截图可用
        case grantedNeedsRestart // 系统设置里已勾选，但需重启本进程才生效
        case notGranted
    }

    static var screenRecordingState: ScreenRecordingState {
        if hasScreenRecordingAtLaunch { return .effective }
        return screenRecordingGrantedInTCC() ? .grantedNeedsRestart : .notGranted
    }

    /// 实时探测系统设置里"屏幕录制"开关是否已勾选（绕过 preflight 的进程缓存）。
    ///
    /// 原理：未授权时 WindowServer 会隐藏其他进程窗口的 kCGWindowName，能读到任一
    /// 其他进程窗口的标题即说明系统侧已勾选。屏幕上恰好没有任何带标题的他人窗口时
    /// 会误判为未开启，因此调用方在"未开启"分支仍须保留手动重启入口（实践中用户
    /// 刚从系统设置窗口切回来，该窗口本身就带标题，必能探测到）。
    static func screenRecordingGrantedInTCC() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner != "Window Server", owner != "Dock",
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty
            else { continue }
            return true
        }
        return false
    }

    /// 触发系统"屏幕录制"授权：把本 App 登记进系统设置列表，未询问过时弹系统授权窗。
    ///
    /// 不用 `CGRequestScreenCaptureAccess()` —— 它在 Sonoma 上不可靠，常常既不弹窗
    /// 也不登记，系统设置列表里根本不出现本 App，用户只能点「+」手动添加。
    /// 改为真实发起一次 ScreenCaptureKit 内容枚举（与截图引擎同一路径）：
    /// 未授权时 tccd 会立即记账（列表出现条目）并在"未询问过"状态下弹出系统授权窗。
    static func requestScreenRecording() {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// 重启本 App —— 屏幕录制授权后必须重启才能生效。
    static func restartApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: 辅助功能

    /// 与屏幕录制不同，辅助功能状态是**实时**的，授权后无需重启即可读到。
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统"辅助功能"授权弹窗。
    ///
    /// 该弹窗自带「打开系统设置」按钮，**调用方不要再额外调 `openSystemSettings`** ——
    /// 两个窗口会互相抢焦点。
    ///
    /// 直接用字符串键 "AXTrustedCheckOptionPrompt"（即 kAXTrustedCheckOptionPrompt 的取值），
    /// 规避不同 SDK 下该常量 Unmanaged<CFString> / CFString 导入差异带来的编译问题。
    static func promptAccessibility() {
        let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSystemSettings(pane: Pane) {
        let urlString: String
        switch pane {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
