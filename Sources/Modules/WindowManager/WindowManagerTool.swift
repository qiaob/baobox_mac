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

    /// 未授权提示节流，见 `apply(_:)`。
    private var didPromptAccessibility = false

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
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        Self.hotkeySpecs.map { spec in
            HotkeyDefinition(
                id: spec.id,
                title: spec.title,
                subtitle: spec.subtitle,
                defaultCombo: spec.combo
            ) { [weak self] in
                self?.apply(spec.layout)
            }
        }
    }

    func settingsTab() -> AnyView {
        AnyView(WindowManagerSettingsView())
    }

    func activate() {
        // 无后台服务；快捷键由框架统一注册。
    }

    // MARK: - 动作执行

    private func apply(_ layout: WindowLayout) {
        // 前置权限检查：未授权则引导并直接返回。
        guard AXIsProcessTrusted() else {
            // apply() 每次按键都会走到这里。原先无节流地「弹窗 + 拉起系统设置」，
            // 未授权时连按方向键会变成弹窗轰炸并反复把系统设置拉到前台。
            // 本次启动只提示一次；菜单里另有常驻的「需要辅助功能权限」入口可随时点。
            if !didPromptAccessibility {
                didPromptAccessibility = true
                Permissions.promptAccessibility()
            }
            return
        }

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
            let safeAK = Self.clamped(frameAK, into: target.visibleFrame)
            AXWindow.setFrameCG(Geometry.cgRect(fromAppKit: safeAK), on: window)
        } else {
            AXWindow.setFrameCG(slot.frameCG, on: window)
        }

        // 窗口已关闭时 set 失败也一并清槽。
        restoreSlot = nil
    }

    /// 把 frame 夹进可见区域：尺寸超出时先缩小，再平移回区域内。
    private static func clamped(_ frameAK: NSRect, into visible: NSRect) -> NSRect {
        var r = frameAK
        r.size.width = min(r.width, visible.width)
        r.size.height = min(r.height, visible.height)
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        return r
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
        let combo: KeyCombo
    }

    /// ⌃⌥ 组合。
    private static let ctrlOpt = KeyCombo.control | KeyCombo.option
    /// ⌃⌥⌘ 组合（跨屏移动）。
    private static let ctrlOptCmd = KeyCombo.control | KeyCombo.option | KeyCombo.cmd

    // 方向键 kVK：←0x7B →0x7C ↓0x7D ↑0x7E；⏎ 0x24；⌫ 0x33。
    private static let hotkeySpecs: [HotkeySpec] = [
        HotkeySpec(id: "windowmanager.left", title: L("windowmanager.layout.left"), subtitle: nil,
                   layout: .left, combo: KeyCombo(keyCode: 0x7B, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.right", title: L("windowmanager.layout.right"), subtitle: nil,
                   layout: .right, combo: KeyCombo(keyCode: 0x7C, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.top", title: L("windowmanager.layout.top"), subtitle: nil,
                   layout: .top, combo: KeyCombo(keyCode: 0x7E, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.bottom", title: L("windowmanager.layout.bottom"), subtitle: nil,
                   layout: .bottom, combo: KeyCombo(keyCode: 0x7D, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.topLeft", title: L("windowmanager.layout.topLeft"), subtitle: nil,
                   layout: .topLeft, combo: KeyCombo(keyCode: 0x20, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.topRight", title: L("windowmanager.layout.topRight"), subtitle: nil,
                   layout: .topRight, combo: KeyCombo(keyCode: 0x22, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.bottomLeft", title: L("windowmanager.layout.bottomLeft"), subtitle: nil,
                   layout: .bottomLeft, combo: KeyCombo(keyCode: 0x26, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.bottomRight", title: L("windowmanager.layout.bottomRight"), subtitle: nil,
                   layout: .bottomRight, combo: KeyCombo(keyCode: 0x28, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.maximize", title: L("windowmanager.layout.maximize"),
                   subtitle: L("windowmanager.layout.maximize.subtitle"),
                   layout: .maximize, combo: KeyCombo(keyCode: 0x24, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.center", title: L("windowmanager.layout.center"),
                   subtitle: L("windowmanager.layout.center.subtitle"),
                   layout: .center, combo: KeyCombo(keyCode: 0x08, carbonModifiers: WindowManagerTool.ctrlOpt)),
        HotkeySpec(id: "windowmanager.nextDisplay", title: L("windowmanager.layout.nextDisplay"), subtitle: nil,
                   layout: .nextDisplay, combo: KeyCombo(keyCode: 0x7C, carbonModifiers: WindowManagerTool.ctrlOptCmd)),
        HotkeySpec(id: "windowmanager.prevDisplay", title: L("windowmanager.layout.prevDisplay"), subtitle: nil,
                   layout: .prevDisplay, combo: KeyCombo(keyCode: 0x7B, carbonModifiers: WindowManagerTool.ctrlOptCmd)),
        HotkeySpec(id: "windowmanager.restore", title: L("windowmanager.layout.restore"), subtitle: nil,
                   layout: .restore, combo: KeyCombo(keyCode: 0x33, carbonModifiers: WindowManagerTool.ctrlOpt))
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
