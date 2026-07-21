import AppKit
import SwiftUI

/// 取色器工具模块壳。使用系统原生 NSColorSampler（无需任何权限）。
@MainActor
final class ColorPickerTool: ToolModule {
    let id = "colorpicker"
    let name = L("colorpicker.name")
    let symbolName = "eyedropper"

    private let store = ColorHistoryStore()

    func willTerminate() {
        store.flushPendingSave()
    }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let pick = ClosureMenuItem(title: L("colorpicker.menu.pick"), hotkeyID: "colorpicker.pick") { [weak self] in
            self?.beginPick()
        }
        items.append(pick)

        items.append(.separator())

        let recent = Array(store.entries.prefix(5))
        if recent.isEmpty {
            let empty = NSMenuItem(title: L("colorpicker.menu.empty"), action: nil, keyEquivalent: "")
            items.append(empty)
        } else {
            for entry in recent {
                let title = ColorFormatter.display(hex: entry.hex,
                                                   format: ColorPickerSettings.format,
                                                   hexUppercase: ColorPickerSettings.hexUppercase)
                let item = ClosureMenuItem(title: title) { [weak self] in
                    self?.copyFormatted(hex: entry.hex)
                }
                item.image = swatchImage(hex: entry.hex)
                items.append(item)
            }
        }

        items.append(.separator())

        let clear = ClosureMenuItem(title: L("common.clearHistory")) { [weak self] in
            self?.store.clearAll()
        }
        items.append(clear)

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "colorpicker.pick",
                title: L("colorpicker.menu.pick"),
                subtitle: L("colorpicker.hotkey.subtitle"),
                // 出厂不绑定：⌘⇧C 会抢浏览器 DevTools 的"检查元素"，需要的用户自行设置。
                defaultCombo: nil
            ) { [weak self] in
                self?.beginPick()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ColorPickerSettingsView())
    }

    func activate() {
        // 无后台服务；历史在 store 初始化时已从磁盘加载。
    }

    // MARK: - 取色

    private func beginPick() {
        let sampler = NSColorSampler()
        sampler.show { [weak self] color in
            // NSColorSampler 的回调在主线程执行。
            MainActor.assumeIsolated {
                guard let self, let color else { return } // nil = 用户取消
                self.handlePicked(color)
            }
        }
    }

    private func handlePicked(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        let hex = ColorFormatter.canonicalHex(from: srgb)
        if ColorPickerSettings.autoCopy {
            copyFormatted(hex: hex)
        }
        store.add(hex: hex)
    }

    private func copyFormatted(hex: String) {
        let string = ColorFormatter.display(hex: hex,
                                            format: ColorPickerSettings.format,
                                            hexUppercase: ColorPickerSettings.hexUppercase)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - 色块图片（菜单项 image，16×16 圆角）

    private func swatchImage(hex: String) -> NSImage {
        let color = ColorFormatter.color(fromHex: hex)
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
