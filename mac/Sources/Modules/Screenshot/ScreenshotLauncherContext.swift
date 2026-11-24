import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：正在录屏 →「停止录屏」。
/// 就是「录屏」那个快捷键动作此刻的 `stateTitle`（录制中才有），同 id（`screenshot.record`）、同动作（录制中按下 = 停止）。
/// 只读内存（`RecordingController.isRecording`）；截图、取字没有 `stateTitle`，不会出。
/// 写在扩展里（不动 `ScreenshotTool.swift`）：协议要求由这里的实现满足。
extension ScreenshotTool {
    func launcherContextSuggestions() -> [LauncherCommand] {
        hotkeys().compactMap { $0.launcherStateCommand(symbolName: "stop.circle") }
    }
}
