import AppKit
import SwiftUI

/// 环形菜单的一项。
struct RadialMenuItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let action: () -> Void
}

/// 右键宠物弹出的环形菜单（docs/desktop-pet/INTERACTION.md §3）：一圈圆形按钮围着宠物，弹出 / 收起带动画。
/// 宠物坐在屏幕底边时按钮排成头顶的一道弧（下半圈会落到 Dock 后面）。
/// 点按钮执行；点空白处、点别处、按 Esc 收起。
@MainActor
final class RadialMenuController: ObservableObject {
    @Published private(set) var items: [RadialMenuItem] = []
    @Published private(set) var expanded = false
    /// true = 上半圈弧形；false = 整圈。
    @Published private(set) var arc = false

    /// 菜单开 / 关（宠物据此站住面向用户）。
    var onVisibilityChange: ((Bool) -> Void)?

    static let size: CGFloat = 300
    private var panel: RadialMenuPanel?
    private var monitors: [Any] = []

    var isOpen: Bool { panel?.isVisible == true }

    func open(around pet: NSRect, items: [RadialMenuItem]) {
        close(animated: false)
        guard !items.isEmpty else { return }
        self.items = items
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: pet.midX, y: pet.midY)) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        arc = pet.minY - visible.minY < 90
        let size = Self.size
        let center = NSPoint(x: pet.midX, y: pet.minY + pet.height * 0.45)
        let panel = ensurePanel()
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        expanded = false
        DispatchQueue.main.async { [weak self] in self?.expanded = true }
        installMonitors()
        onVisibilityChange?(true)
    }

    func close(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        expanded = false
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak panel] in panel?.orderOut(nil) }
        } else {
            panel.orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    /// 先收起再执行（截图这类动作不能把菜单拍进去）。
    func choose(_ item: RadialMenuItem) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { item.action() }
    }

    private func ensurePanel() -> RadialMenuPanel {
        if let panel { return panel }
        let panel = RadialMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.onEscape = { [weak self] in self?.close() }
        let hosting = RadialHostingView(rootView: RadialMenuView(controller: self))
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// 点到别的 App / 桌面就收起（全局鼠标监听不需要额外权限）。
    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

/// 环形菜单窗：要收 Esc，所以可成为 key（nonactivatingPanel，不会把 Baobox 切到前台）。
final class RadialMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        onEscape?()
    }
}

final class RadialHostingView: NSHostingView<RadialMenuView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    private static let buttonSize: CGFloat = 44
    private static let radius: CGFloat = 104

    var body: some View {
        ZStack {
            // 空白处（含宠物身上）点一下收起。
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { controller.close() }
            ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                let point = position(index: index, count: controller.items.count)
                RadialMenuButton(item: item, size: Self.buttonSize) { controller.choose(item) }
                    .scaleEffect(controller.expanded ? 1 : 0.2)
                    .opacity(controller.expanded ? 1 : 0)
                    .offset(x: controller.expanded ? point.x : 0, y: controller.expanded ? point.y : 0)
                    .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(controller.expanded ? Double(index) * 0.022 : 0),
                               value: controller.expanded)
            }
        }
        .frame(width: RadialMenuController.size, height: RadialMenuController.size)
    }

    /// 整圈：从正上方顺时针均分；弧形：从左到右跨过头顶（180° → 0°）。SwiftUI 的 y 轴朝下。
    private func position(index: Int, count: Int) -> CGPoint {
        let degrees: Double
        if controller.arc {
            degrees = count > 1 ? 180 - Double(index) * 180 / Double(count - 1) : 90
        } else {
            degrees = 90 - Double(index) * 360 / Double(max(count, 1))
        }
        let radians = degrees * .pi / 180
        let r = controller.arc ? Self.radius + 10 : Self.radius
        return CGPoint(x: CGFloat(cos(radians)) * r, y: -CGFloat(sin(radians)) * r)
    }
}

struct RadialMenuButton: View {
    let item: RadialMenuItem
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BubblePalette.accent)
                    .frame(width: size, height: size)
                    .background(Circle().fill(BubblePalette.surface))
                    .overlay(Circle().strokeBorder(BubblePalette.line, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BubblePalette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(BubblePalette.surface))
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RadialPressStyle())
    }
}

/// 按下时缩一点。
struct RadialPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
