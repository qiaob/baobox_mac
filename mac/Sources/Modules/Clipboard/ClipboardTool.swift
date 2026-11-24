import AppKit
import SwiftUI

/// 剪贴板工具模块壳。
@MainActor
final class ClipboardTool: ToolModule {
    let id = "clipboard"
    let name = L("clipboard.name")
    let symbolName = "doc.on.clipboard"

    /// 设置 → 通用 → 数据的导出 / 导入要读写片段（docs/data-export/DESIGN.md），所以不是 private。
    let store = ClipboardStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private lazy var panelController = ClipboardPanelController(store: store, monitor: monitor)
    /// 交给快速入口搜索的两个来源：剪贴板历史、文本片段（docs/launcher/TECH_DESIGN.md §3.2）。
    private lazy var launcherSourceList: [any LauncherSearchable] = [
        ClipboardLauncherSource(kind: .history, store: store, monitor: monitor),
        ClipboardLauncherSource(kind: .snippets, store: store, monitor: monitor),
    ]

    func launcherSources() -> [any LauncherSearchable] {
        launcherSourceList
    }

    /// 快速入口的文字动作（docs/launcher/TECH_DESIGN.md §5.4）：对输入框里的任意文字「存为片段 / 钉成贴卡 / 生成二维码」。
    /// 都在档位 50（兜底建议的后半截）；输入是网址时二维码提到最前（「刚拿到个链接，要给手机」）。
    func launcherCommands() -> [LauncherCommand] {
        let store = store
        return [
            .textAction(id: "clipboard.text.saveSnippet", title: L("clipboard.launcher.saveSnippet"),
                        symbolName: "text.badge.star", suggestion: LauncherSuggestionTraits(priority: 50)) { text in
                Self.saveSnippet(text, store: store)
            },
            .textAction(id: "clipboard.text.pinCard", title: L("clipboard.launcher.pinCard"),
                        symbolName: "pin", suggestion: LauncherSuggestionTraits(priority: 50)) { text in
                PinnedTextCard.pin(text)
            },
            .textAction(id: "clipboard.text.qrCode", title: L("clipboard.launcher.qrCode"), symbolName: "qrcode",
                        suggestion: LauncherSuggestionTraits(priority: 50, boostedKinds: [.url])) { text in
                Self.showQRCode(text)
            },
        ]
    }

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

    /// 快速入口「存为片段」：标题用首行（最多 40 个字符），存成一条收藏的文字条目（= 片段），回执一句。
    private static func saveSnippet(_ text: String, store: ClipboardStore) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        let title = firstLine.count > 40 ? String(firstLine.prefix(39)) + "…" : firstLine
        store.addSnippet(title: title, content: content)
        toast(L("clipboard.launcher.savedSnippet \(title)"), icon: "text.badge.star")
    }

    /// 快速入口「生成二维码」：同 `clipboard.qrcodeLast`，钉在鼠标所在屏幕中间；超过二维码容量时说一句。
    private static func showQRCode(_ text: String) {
        guard Data(text.utf8).count <= QRCodeGenerator.maxBytes else {
            toast(L("clipboard.tools.qrcode.tooLong"), icon: "qrcode")
            return
        }
        ClipboardQRCode.pin(text)
    }

    /// 回执（宠物开着是宠物气泡，否则系统通知；勿扰时照常显示）。
    private static func toast(_ text: String, icon: String) {
        NotifyCenter.shared.post(Notice(source: "clipboard", level: .ambient, title: text, icon: icon, isUserFeedback: true))
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
