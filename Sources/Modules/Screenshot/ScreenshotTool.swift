import AppKit
import SwiftUI

/// 截图工具模块壳。
@MainActor
final class ScreenshotTool: ToolModule {
    let id = "screenshot"
    let name = L("screenshot.name")
    let symbolName = "viewfinder"

    private let captureController = CaptureController()

    func willTerminate() {
        ScreenshotHistoryStore.shared.flushPendingSave()
    }

    func submenuItems() -> [NSMenuItem] {
        let start = ClosureMenuItem(title: L("screenshot.menu.start"), hotkeyID: "screenshot.capture") { [weak self] in
            self?.captureController.begin()
        }
        let recordTitle = RecordingController.shared.isRecording
            ? L("screenshot.menu.stopRecord") : L("screenshot.menu.record")
        let record = ClosureMenuItem(title: recordTitle, hotkeyID: "screenshot.record") { [weak self] in
            self?.toggleRecording()
        }
        var items: [NSMenuItem] = [start, record]
        if RecordingController.shared.isRecording {
            let pauseTitle = RecordingController.shared.isPaused
                ? L("screenshot.record.hud.resume") : L("screenshot.record.hud.pause")
            items.append(ClosureMenuItem(title: pauseTitle) {
                RecordingController.shared.togglePause()
            })
        }
        items.append(historyMenuItem())
        items.append(pinsMenuItem())
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "screenshot.capture",
                title: L("screenshot.hotkey.title"),
                subtitle: L("screenshot.hotkey.subtitle"),
                defaultCombo: KeyCombo(keyCode: 0x13, carbonModifiers: KeyCombo.cmd | KeyCombo.shift) // ⌘⇧2
            ) { [weak self] in
                self?.captureController.begin()
            },
            HotkeyDefinition(
                id: "screenshot.record",
                title: L("screenshot.menu.record"),
                subtitle: L("screenshot.record.hotkey.subtitle"),
                defaultCombo: KeyCombo(keyCode: 0x0F, carbonModifiers: KeyCombo.control | KeyCombo.shift) // ⌃⇧R
            ) { [weak self] in
                self?.toggleRecording()
            }
        ]
    }

    /// 同一快捷键：未录制 → 唤起选区；录制中 → 停止。
    private func toggleRecording() {
        if RecordingController.shared.isRecording {
            RecordingController.shared.stopFromUser()
        } else {
            captureController.beginRecording()
        }
    }

    func settingsTab() -> AnyView {
        AnyView(ScreenshotSettingsView())
    }

    func activate() {
        // 截图无需常驻后台服务；快捷键由框架统一注册。
    }

    // MARK: - 截图历史菜单

    private func historyMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("screenshot.menu.history"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = true

        let store = ScreenshotHistoryStore.shared
        if store.entries.isEmpty {
            menu.addItem(NSMenuItem(title: L("screenshot.history.empty"), action: nil, keyEquivalent: ""))
        } else {
            for entry in store.entries.prefix(10) {
                let item = NSMenuItem(title: Self.timeTitle(entry.createdAt), action: nil, keyEquivalent: "")
                item.image = store.thumbnail(for: entry)

                let actions = NSMenu()
                actions.autoenablesItems = true
                actions.addItem(ClosureMenuItem(title: L("pin.menu.copy")) {
                    guard let cg = ScreenshotHistoryStore.shared.cgImage(for: entry) else { return }
                    ScreenshotResultHandler.copy(image: cg)
                })
                actions.addItem(ClosureMenuItem(title: L("screenshot.history.pin")) { [weak self] in
                    guard let cg = ScreenshotHistoryStore.shared.cgImage(for: entry) else { return }
                    self?.pinCentered(cg)
                })
                actions.addItem(ClosureMenuItem(title: L("pin.menu.save")) {
                    Self.saveEntry(entry)
                })
                actions.addItem(.separator())
                actions.addItem(ClosureMenuItem(title: L("common.delete")) {
                    ScreenshotHistoryStore.shared.delete(entry)
                })
                item.submenu = actions
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: L("common.clearHistory")) {
                ScreenshotHistoryStore.shared.clearAll()
            })
        }
        parent.submenu = menu
        return parent
    }

    private static func timeTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MdHHmm")
        return formatter.string(from: date)
    }

    private static func saveEntry(_ entry: ScreenshotHistoryStore.Entry) {
        guard let image = ScreenshotHistoryStore.shared.image(for: entry),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        // 文件名沿用截图模板，但用条目自身的时间戳（不是保存时刻）。
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = ScreenshotSettings.filenameTemplate
        var base = formatter.string(from: entry.createdAt)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "screenshot" }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotSettings.saveDirectoryURL
        panel.nameFieldStringValue = base + ".png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    // MARK: - 贴图菜单

    private func pinsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("screenshot.menu.pins"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(ClosureMenuItem(title: L("screenshot.menu.pinFromClipboard")) { [weak self] in
            self?.pinFromClipboard()
        })
        menu.addItem(ClosureMenuItem(title: L("screenshot.menu.closeAllPins")) {
            PinnedImageWindow.closeAll()
        })
        parent.submenu = menu
        return parent
    }

    private func pinFromClipboard() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first,
              image.size.width > 0, image.size.height > 0 else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("screenshot.pins.noImage.title")
            alert.informativeText = L("screenshot.pins.noImage.message")
            alert.runModal()
            return
        }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        pinCentered(cg)
    }

    /// 把图像按点尺寸钉在鼠标所在屏中央（超屏时等比缩到可见区域 80%）。
    private func pinCentered(_ cg: CGImage) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let scale = screen.backingScaleFactor

        var size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        let fit = min(visible.width * 0.8 / size.width, visible.height * 0.8 / size.height, 1)
        size = NSSize(width: max(40, size.width * fit), height: max(40, size.height * fit))

        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        PinnedImageWindow.pin(image: cg, at: NSRect(origin: origin, size: size))
    }
}
