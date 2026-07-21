import AppKit
import ApplicationServices
import SwiftUI

/// 窗口管理相关的 UserDefaults 键与默认值。
enum WindowManagerSettings {
    static let gapKey = "windowmanager.gap"

    /// 窗口间距（pt），默认 0。
    static var gap: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: gapKey))
    }
}

/// 窗口管理工具模块壳。依赖辅助功能权限（与剪贴板回填共用，无新授权）。
/// 通过 Accessibility 移动 / 缩放前台窗口，默认键位对齐 Rectangle 惯例。
@MainActor
final class WindowManagerTool: ToolModule {
    let id = "windowmanager"
    let name = L("windowmanager.name")
    let symbolName = "macwindow.on.rectangle"

    /// 恢复槽：单槽记录 (窗口 AXUIElement 强引用, 布局前原 frameCG)。
    private var restoreSlot: (window: AXUIElement, frameCG: CGRect)?

    /// 未授权提示节流，见 `ensureAccessibility()`。
    private var didPromptAccessibility = false

    /// 布局快照存储。
    private let snapshotStore = WindowSnapshotStore()

    // MARK: - ToolModule

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if !AXIsProcessTrusted() {
            // 该弹窗自带「打开系统设置」按钮，不再额外拉起系统设置（两窗口会抢焦点）。
            let notice = ClosureMenuItem(title: L("windowmanager.menu.needAX")) {
                Permissions.promptAccessibility()
            }
            items.append(notice)
            items.append(.separator())
        }

        for entry in Self.menuLayout {
            switch entry {
            case .separator:
                items.append(.separator())
            case let .action(title, layout):
                let hotkeyID = WindowManagerTool.hotkeySpecs.first { $0.layout == layout }?.id
                items.append(ClosureMenuItem(title: title, hotkeyID: hotkeyID) { [weak self] in
                    self?.apply(layout)
                })
            }
        }

        // 布局快照：保存的快照直接列出（点击即恢复），末尾是保存入口。
        items.append(.separator())
        for snapshot in snapshotStore.snapshots {
            let item = ClosureMenuItem(title: snapshot.name) { [weak self] in
                self?.restoreSnapshot(snapshot)
            }
            item.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
            items.append(item)
        }
        items.append(ClosureMenuItem(title: L("windowmanager.snapshot.save")) { [weak self] in
            self?.saveSnapshotPrompt()
        })
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        Self.hotkeySpecs.map { spec in
            HotkeyDefinition(
                id: spec.id,
                title: spec.title,
                subtitle: spec.subtitle,
                defaultCombo: nil
            ) { [weak self] in
                self?.apply(spec.layout)
            }
        }
    }

    func settingsTab() -> AnyView {
        AnyView(WindowManagerSettingsView(snapshots: snapshotStore))
    }

    func activate() {
        // 无后台服务；快捷键由框架统一注册。
    }

    // MARK: - 动作执行

    /// 前置权限检查：未授权则引导（每次启动仅提示一次）并返回 false。
    /// 未授权时连按快捷键会反复走到这里，无节流会变成弹窗轰炸。
    private func ensureAccessibility() -> Bool {
        guard AXIsProcessTrusted() else {
            if !didPromptAccessibility {
                didPromptAccessibility = true
                Permissions.promptAccessibility()
            }
            return false
        }
        return true
    }

    private func apply(_ layout: WindowLayout) {
        guard ensureAccessibility() else { return }

        guard let window = AXWindow.focusedWindow(),
              let frameCG = AXWindow.frameCG(of: window) else { return }

        if layout == .restore {
            performRestore(window: window)
            return
        }

        // 布局生效前记录恢复槽（仅当记录的不是本窗口时）。
        recordRestoreIfNeeded(window: window, frameCG: frameCG)

        let frameAK = Geometry.appKitRect(fromCG: frameCG)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let mouseScreen = screenContainingMouse(in: screens)

        switch layout {
        case .nextDisplay, .prevDisplay:
            // 单屏时跨屏动作静默无效。
            guard screens.count > 1 else { return }
            let sorted = WindowLayout.sortedScreens(screens)
            guard let source = WindowLayout.targetScreen(forWindowAK: frameAK,
                                                         screens: screens,
                                                         mouseScreen: mouseScreen),
                  let idx = sorted.firstIndex(where: { $0 === source }) else { return }
            let step = (layout == .nextDisplay) ? 1 : -1
            let dest = sorted[(idx + step + sorted.count) % sorted.count]
            guard dest !== source else { return }
            let newAK = WindowLayout.mappedFrameAK(window: frameAK, from: source, to: dest)
            setFrame(newAK, on: window)

        default:
            guard let screen = WindowLayout.targetScreen(forWindowAK: frameAK,
                                                         screens: screens,
                                                         mouseScreen: mouseScreen) else { return }
            let newAK = WindowLayout.targetFrameAK(for: layout,
                                                   window: frameAK,
                                                   on: screen,
                                                   gap: WindowManagerSettings.gap)
            setFrame(newAK, on: window)
        }
    }

    private func setFrame(_ frameAK: NSRect, on window: AXUIElement) {
        let cg = Geometry.cgRect(fromAppKit: frameAK)
        AXWindow.setFrameCG(cg, on: window)
    }

    // MARK: - 恢复槽

    private func recordRestoreIfNeeded(window: AXUIElement, frameCG: CGRect) {
        if let slot = restoreSlot, CFEqual(slot.window, window) {
            return // 同一窗口连续布局，保留最初的原始位置。
        }
        restoreSlot = (window, frameCG)
    }

    private func performRestore(window: AXUIElement) {
        guard let slot = restoreSlot, CFEqual(slot.window, window) else { return }

        // 槽里存的是绝对坐标。若记录之后拔掉了外接屏，原坐标可能已不在任何屏幕上；
        // AX 会老老实实把窗口放到那片不存在的区域，系统不会拉回来，窗口从此不可见
        //（只能靠 Mission Control 救）。其余布局路径都做了 clamp，唯独 restore 没有。
        let screens = NSScreen.screens
        let frameAK = Geometry.appKitRect(fromCG: slot.frameCG)
        if let target = WindowLayout.targetScreen(forWindowAK: frameAK,
                                                  screens: screens,
                                                  mouseScreen: screenContainingMouse(in: screens)) {
            let safeAK = WindowLayout.clamped(frameAK, into: target.visibleFrame)
            AXWindow.setFrameCG(Geometry.cgRect(fromAppKit: safeAK), on: window)
        } else {
            AXWindow.setFrameCG(slot.frameCG, on: window)
        }

        // 窗口已关闭时 set 失败也一并清槽。
        restoreSlot = nil
    }

    // MARK: - 布局快照

    private func restoreSnapshot(_ snapshot: WindowSnapshot) {
        guard ensureAccessibility() else { return }
        WindowSnapshotStore.restore(snapshot)
    }

    private func saveSnapshotPrompt() {
        guard ensureAccessibility() else { return }
        // 先采集再激活自己：激活会改变前台 App，但采集遍历的是所有 App，顺序无影响，
        // 唯独要避免把弹窗时序夹进采集中间。
        let entries = WindowSnapshotStore.captureCurrent()

        NSApp.activate(ignoringOtherApps: true)
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("windowmanager.snapshot.emptyCapture.title")
            alert.informativeText = L("windowmanager.snapshot.emptyCapture.message")
            alert.runModal()
            return
        }

        let defaultName = L("windowmanager.snapshot.defaultName \(snapshotStore.snapshots.count + 1)")
        let alert = NSAlert()
        alert.messageText = L("windowmanager.snapshot.namePrompt.title")
        alert.informativeText = L("windowmanager.snapshot.namePrompt.message \(entries.count)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.save"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshotStore.add(name: trimmed.isEmpty ? defaultName : trimmed, entries: entries)
    }

    // MARK: - 辅助

    private func screenContainingMouse(in screens: [NSScreen]) -> NSScreen? {
        let mouse = NSEvent.mouseLocation // AK 坐标
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screens.first
    }

    // MARK: - 快捷键规格（对齐 Rectangle 默认）

    private struct HotkeySpec {
        let id: String
        let title: String
        let subtitle: String?
        let layout: WindowLayout
    }

    // 出厂不绑定键位：默认的 ⌃⌥ 系列与 Rectangle 完全同键，同时运行必然打架。
    // 用户在「快捷键」页按需设置，菜单入口不受影响。
    private static let hotkeySpecs: [HotkeySpec] = [
        HotkeySpec(id: "windowmanager.left", title: L("windowmanager.layout.left"), subtitle: nil, layout: .left),
        HotkeySpec(id: "windowmanager.right", title: L("windowmanager.layout.right"), subtitle: nil, layout: .right),
        HotkeySpec(id: "windowmanager.top", title: L("windowmanager.layout.top"), subtitle: nil, layout: .top),
        HotkeySpec(id: "windowmanager.bottom", title: L("windowmanager.layout.bottom"), subtitle: nil, layout: .bottom),
        HotkeySpec(id: "windowmanager.topLeft", title: L("windowmanager.layout.topLeft"), subtitle: nil, layout: .topLeft),
        HotkeySpec(id: "windowmanager.topRight", title: L("windowmanager.layout.topRight"), subtitle: nil, layout: .topRight),
        HotkeySpec(id: "windowmanager.bottomLeft", title: L("windowmanager.layout.bottomLeft"), subtitle: nil, layout: .bottomLeft),
        HotkeySpec(id: "windowmanager.bottomRight", title: L("windowmanager.layout.bottomRight"), subtitle: nil, layout: .bottomRight),
        HotkeySpec(id: "windowmanager.maximize", title: L("windowmanager.layout.maximize"),
                   subtitle: L("windowmanager.layout.maximize.subtitle"), layout: .maximize),
        HotkeySpec(id: "windowmanager.center", title: L("windowmanager.layout.center"),
                   subtitle: L("windowmanager.layout.center.subtitle"), layout: .center),
        HotkeySpec(id: "windowmanager.nextDisplay", title: L("windowmanager.layout.nextDisplay"), subtitle: nil, layout: .nextDisplay),
        HotkeySpec(id: "windowmanager.prevDisplay", title: L("windowmanager.layout.prevDisplay"), subtitle: nil, layout: .prevDisplay),
        HotkeySpec(id: "windowmanager.restore", title: L("windowmanager.layout.restore"), subtitle: nil, layout: .restore)
    ]

    // MARK: - 菜单条目

    private enum MenuEntry {
        case action(String, WindowLayout)
        case separator
    }

    private static let menuLayout: [MenuEntry] = [
        .action(L("windowmanager.layout.left"), .left),
        .action(L("windowmanager.layout.right"), .right),
        .action(L("windowmanager.layout.top"), .top),
        .action(L("windowmanager.layout.bottom"), .bottom),
        .separator,
        .action(L("windowmanager.layout.topLeft"), .topLeft),
        .action(L("windowmanager.layout.topRight"), .topRight),
        .action(L("windowmanager.layout.bottomLeft"), .bottomLeft),
        .action(L("windowmanager.layout.bottomRight"), .bottomRight),
        .separator,
        .action(L("windowmanager.layout.maximize"), .maximize),
        .action(L("windowmanager.layout.center"), .center),
        .separator,
        .action(L("windowmanager.layout.nextDisplay"), .nextDisplay),
        .action(L("windowmanager.layout.prevDisplay"), .prevDisplay),
        .separator,
        .action(L("windowmanager.layout.restore"), .restore)
    ]
}
