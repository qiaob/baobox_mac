import SwiftUI

@main
struct BaoboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 设置窗口由 SettingsWindowController 自行持有：macOS 14 起无法再从 AppKit
        // 菜单打开 SwiftUI 的 Settings scene。这里仅保留一个占位 Scene 以满足
        // App 协议「body 至少含一个 Scene」的要求；LSUIElement 下它不可达。
        Settings { EmptyView() }
    }
}
