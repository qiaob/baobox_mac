import AppKit
import SwiftUI

/// 剪贴板工具模块壳。
@MainActor
final class ClipboardTool: ToolModule {
    let id = "clipboard"
    let name = L("clipboard.name")
    let symbolName = "doc.on.clipboard"

    private let store = ClipboardStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private lazy var panelController = ClipboardPanelController(store: store, monitor: monitor)

    func willTerminate() {
        store.flushPendingSave()
    }

    func submenuItems() -> [NSMenuItem] {
        let open = ClosureMenuItem(title: L("clipboard.menu.open"), hotkeyID: "clipboard.togglePanel") { [weak self] in
            self?.panelController.toggle()
        }
        let clear = ClosureMenuItem(title: L("common.clearHistory")) { [weak self] in
            self?.confirmClear()
        }
        return [open, clear]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "clipboard.togglePanel",
                title: L("clipboard.menu.open"),
                subtitle: nil,
                defaultCombo: KeyCombo(keyCode: 0x09, carbonModifiers: KeyCombo.cmd | KeyCombo.shift) // ⌘⇧V
            ) { [weak self] in
                self?.panelController.toggle()
            },
            HotkeyDefinition(
                id: "clipboard.pastePlainLast",
                title: L("clipboard.hotkey.pastePlain"),
                subtitle: nil,
                defaultCombo: KeyCombo(keyCode: 0x09, carbonModifiers: KeyCombo.cmd | KeyCombo.option) // ⌘⌥V
            ) { [weak self] in
                self?.pastePlainLast()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ClipboardSettingsView(store: store))
    }

    func activate() {
        monitor.start()
    }

    // MARK: - 动作

    private func pastePlainLast() {
        guard let latest = store.items.max(by: { $0.createdAt < $1.createdAt }) else { return }
        PasteService.paste(latest, plainText: true, store: store, monitor: monitor)
    }

    private func confirmClear() {
        // 从状态栏二级菜单触发时 Baobox 并非前台 App，不先激活的话弹窗会排在其他
        // App 窗口之后 —— 用户看不到任何东西，但主线程已进入模态循环，像是卡死了。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("clipboard.clearConfirm.title")
        alert.informativeText = L("clipboard.clearConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("clipboard.clearConfirm.confirm"))
        alert.addButton(withTitle: L("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearAll()
        }
    }
}
