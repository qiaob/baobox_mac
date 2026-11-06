import AppKit
import SwiftUI

/// 环形菜单的一项。
struct RadialMenuItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    /// true = 点了不收起菜单（「更多 / 收起」）。
    var keepsMenuOpen = false
    let action: () -> Void
}

/// 右键宠物弹出的环形菜单（docs/desktop-pet/INTERACTION.md §4）：
/// - 内圈一整圈围着宠物，最后一格是「更多」；点「更多」在外面展开更大的一圈（其他功能的快捷操作），再点「收起」；
/// - 靠屏幕边、整圈放不下时，按钮只排在屏内放得下的那段弧上；
/// - 点按钮执行（先收起菜单）；点空白处、点别处、按 Esc 收起（外圈开着时 Esc 先收外圈）。
@MainActor
final class RadialMenuController: ObservableObject {
    @Published private(set) var inner: [RadialMenuItem] = []
    @Published private(set) var outer: [RadialMenuItem] = []
    @Published private(set) var expanded = false
    @Published private(set) var outerShown = false
    /// 每个按钮相对窗口中心的位置（SwiftUI 坐标，y 朝下）。
    @Published private(set) var positions: [String: CGPoint] = [:]

    /// 菜单开 / 关（宠物据此站住面向用户）。
    var onVisibilityChange: ((Bool) -> Void)?

    static let innerRadius: CGFloat = 104
    static let outerRadius: CGFloat = 178
    static let size: CGFloat = 2 * (outerRadius + 42)
    /// 按钮中心离屏幕边至少这么远（按钮半径 + 标签）。
    private static let edgeMargin: CGFloat = 34

    private var panel: RadialMenuPanel?
    private var monitors: [Any] = []

    var isOpen: Bool { panel?.isVisible == true }

    func open(around pet: NSRect, inner innerItems: [RadialMenuItem], outer outerItems: [RadialMenuItem]) {
        close(animated: false)
        guard !innerItems.isEmpty else { return }
        var inner = innerItems
        if !outerItems.isEmpty {
            inner.append(RadialMenuItem(id: "radial.more", symbol: "ellipsis", title: L("pet.ring.more"),
                                        keepsMenuOpen: true) { [weak self] in self?.toggleOuter() })
        }
        self.inner = inner
        self.outer = outerItems
        outerShown = false

        let petCenter = NSPoint(x: pet.midX, y: pet.minY + pet.height * 0.45)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(petCenter) }) ?? NSScreen.main
        let bounds = (screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: Self.edgeMargin, dy: Self.edgeMargin)
        // 内圈尽量整圈：中心只在内圈会出屏时才往里挪（可以压在 Dock 上，Dock 在它下面一层）。
        let r = Self.innerRadius
        let center = NSPoint(x: min(max(petCenter.x, bounds.minX + r), bounds.maxX - r),
                             y: min(max(petCenter.y, bounds.minY + r), bounds.maxY - r))
        // 中心被挪开（宠物贴着屏幕最底、Dock 隐藏）时，挡在宠物身上的角度不放按钮（内圈成马蹄形围着头顶）。
        // 圆形避让区（方形会把正常整圈的 45° 斜角也挖掉）：宠物中心为圆心，半身高再加按钮半径左右。
        let avoid = (center: NSPoint(x: pet.midX, y: pet.midY), radius: pet.height / 2 + 18)
        var positions: [String: CGPoint] = [:]
        for (item, point) in zip(inner, Self.layout(count: inner.count, radius: r, center: center,
                                                    bounds: bounds, avoid: avoid)) {
            positions[item.id] = point
        }
        for (item, point) in zip(outerItems, Self.layout(count: outerItems.count, radius: Self.outerRadius,
                                                          center: center, bounds: bounds, avoid: avoid)) {
            positions[item.id] = point
        }
        self.positions = positions

        let size = Self.size
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
        outerShown = false
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak panel] in panel?.orderOut(nil) }
        } else {
            panel.orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    func toggleOuter() {
        outerShown.toggle()
    }

    /// 先收起再执行（截图这类动作不能把菜单拍进去）。「更多 / 收起」不收菜单。
    func choose(_ item: RadialMenuItem) {
        if item.keepsMenuOpen {
            item.action()
            return
        }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { item.action() }
    }

    fileprivate func escape() {
        if outerShown {
            outerShown = false
        } else {
            close()
        }
    }

    /// 一圈上的按钮位置：整圈放得下就从正上方顺时针均分；放不下（出屏 / 压在宠物身上）就只用最长的那段可用弧，从左到右排。
    private static func layout(count: Int, radius: CGFloat, center: NSPoint, bounds: NSRect,
                               avoid: (center: NSPoint, radius: CGFloat)) -> [CGPoint] {
        guard count > 0 else { return [] }
        let step = 5.0
        let steps = Int(360 / step)
        let allowed = (0..<steps).map { i -> Bool in
            let a = Double(i) * step * .pi / 180
            let p = NSPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius)
            return bounds.contains(p) && hypot(p.x - avoid.center.x, p.y - avoid.center.y) >= avoid.radius
        }
        var degrees: [Double]
        if allowed.allSatisfy({ $0 }) {
            degrees = (0..<count).map { 90 - Double($0) * 360 / Double(count) }
        } else {
            // 环形数组里最长的一段连续可用角度。
            var bestStart = 0, bestLength = 0
            for start in 0..<steps where allowed[start] && !allowed[(start - 1 + steps) % steps] {
                var length = 0
                while length < steps && allowed[(start + length) % steps] { length += 1 }
                if length > bestLength { bestStart = start; bestLength = length }
            }
            let first = Double(bestStart) * step
            let span = Double(max(bestLength - 1, 0)) * step
            degrees = count == 1
                ? [first + span / 2]
                : (0..<count).map { first + span - Double($0) * span / Double(count - 1) }
        }
        return degrees.map { d in
            let a = d * .pi / 180
            return CGPoint(x: CGFloat(cos(a)) * radius, y: -CGFloat(sin(a)) * radius)
        }
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
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onResignKey = { [weak self] in self?.close() }
        panel.contentView = RadialHostingView(rootView: RadialMenuView(controller: self))
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
    var onResignKey: (() -> Void)?
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
        onResignKey?()
    }
}

final class RadialHostingView: NSHostingView<RadialMenuView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController

    var body: some View {
        ZStack {
            // 空白处（含宠物身上）点一下：外圈开着先收外圈，否则收起菜单。
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { controller.outerShown ? controller.toggleOuter() : controller.close() }
            // 外圈：点「更多」后从中心依次弹出。
            ForEach(Array(controller.outer.enumerated()), id: \.element.id) { index, item in
                let visible = controller.expanded && controller.outerShown
                let point = controller.positions[item.id] ?? .zero
                RadialMenuButton(item: item, size: 40) { controller.choose(item) }
                    .scaleEffect(visible ? 1 : 0.3)
                    .opacity(visible ? 1 : 0)
                    .offset(x: visible ? point.x : point.x * 0.55, y: visible ? point.y : point.y * 0.55)
                    .allowsHitTesting(visible)
                    .animation(.spring(response: 0.36, dampingFraction: 0.74).delay(visible ? Double(index) * 0.018 : 0),
                               value: visible)
            }
            // 内圈。
            ForEach(Array(controller.inner.enumerated()), id: \.element.id) { index, item in
                let point = controller.positions[item.id] ?? .zero
                RadialMenuButton(item: displayed(item), size: 44, highlighted: item.id == "radial.more" && controller.outerShown) {
                    controller.choose(item)
                }
                .scaleEffect(controller.expanded ? 1 : 0.2)
                .opacity(controller.expanded ? 1 : 0)
                .offset(x: controller.expanded ? point.x : 0, y: controller.expanded ? point.y : 0)
                .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(controller.expanded ? Double(index) * 0.022 : 0),
                           value: controller.expanded)
            }
        }
        .frame(width: RadialMenuController.size, height: RadialMenuController.size)
    }

    /// 「更多」展开后显示成「收起」。
    private func displayed(_ item: RadialMenuItem) -> RadialMenuItem {
        guard item.id == "radial.more", controller.outerShown else { return item }
        return RadialMenuItem(id: item.id, symbol: "chevron.down", title: L("pet.ring.less"), keepsMenuOpen: true, action: item.action)
    }
}

struct RadialMenuButton: View {
    let item: RadialMenuItem
    let size: CGFloat
    var highlighted = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : BubblePalette.accent)
                    .frame(width: size, height: size)
                    .background(Circle().fill(highlighted ? BubblePalette.accent : BubblePalette.surface))
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
