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
            },
            HotkeyDefinition(
                id: "clipboard.qrcodeLast",
                title: L("clipboard.hotkey.qrcodeLast"),
                subtitle: L("clipboard.hotkey.qrcodeLast.subtitle"),
                // 出厂不绑定：按项目约定，易冲突的组合留给用户自设。
                defaultCombo: nil
            ) { [weak self] in
                self?.qrCodeLast()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ClipboardSettingsView(store: store))
    }

    func activate() {
        monitor.start()
        // 把图片文件对齐到当前的「加密存储」开关（老版本留下的明文补加密 / 关了开关的
        // 解回明文）。读取侧明文密文都兼容，没转完也不影响使用。
        ClipboardCrypto.syncStoredImages(in: ClipboardStore.imagesDir)
        // 关键字展开：默认关，只有用户在设置里打开过才会真正装 event tap。
        SnippetExpander.shared.configure(store: store, monitor: monitor)
    }

    // MARK: - 动作

    private func pastePlainLast() {
        guard let latest = store.items.max(by: { $0.createdAt < $1.createdAt }) else { return }
        PasteService.paste(latest, plainText: true, store: store, monitor: monitor)
    }

    /// 不开面板，直接给最近一条文本生成二维码钉到屏幕 ——
    /// 「刚复制了个链接，立刻要给手机」这个场景中间不该插一步选面板。
    private func qrCodeLast() {
        guard let latest = store.items
            .filter({ $0.type != .image })
            .max(by: { $0.createdAt < $1.createdAt }),
              let text = latest.text, !text.isEmpty else { return }
        ClipboardQRCode.pin(text)
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
