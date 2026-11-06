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

    /// 内外圈之间的距离。两圈的大小跟着宠物身体走（见 open）：宠物窗更大时圈不放大的话，
    /// 内圈整圈都落在宠物的避让区里，所有按钮挤到同一个点上（试用时的「按钮都重叠了」）。
    static let ringGap: CGFloat = 74
    /// 按钮半径 + 标签。
    static let buttonRoom: CGFloat = 42
    /// 菜单窗口大小（包住外圈）。
    @Published private(set) var size = NSSize(width: 2 * (104 + 74 + 42), height: 2 * (104 + 74 + 42))

    /// 排按钮用的椭圆（屏幕坐标）。
    struct Ellipse {
        let center: NSPoint
        let radiusX: CGFloat
        let radiusY: CGFloat

        func point(at degrees: Double) -> NSPoint {
            let a = degrees * .pi / 180
            return NSPoint(x: center.x + CGFloat(cos(a)) * radiusX, y: center.y + CGFloat(sin(a)) * radiusY)
        }

        func contains(_ p: NSPoint) -> Bool {
            let dx = (p.x - center.x) / max(radiusX, 1)
            let dy = (p.y - center.y) / max(radiusY, 1)
            return dx * dx + dy * dy < 1
        }
    }
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

        let petCenter = NSPoint(x: pet.midX, y: pet.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(petCenter) }) ?? NSScreen.main
        let bounds = (screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: Self.edgeMargin, dy: Self.edgeMargin)
        // `pet` 是宠物身体所占的矩形（VRM 人形按骨骼投影，又高又瘦；其他形象是整个宠物窗）。
        // 两圈都是围着它的椭圆：横竖半径分开算，人形不会两边空出一大片（试用反馈「左右空的特别多」）。
        // 内圈每个方向都比避让区（身体外扩 18 点）大一个按钮：宠物多大、多瘦，圈就多大、多瘦。
        let radiusX = max(pet.width / 2 + 46, 80)
        let radiusY = max(pet.height / 2 + 40, 80)
        let outerX = radiusX + Self.ringGap
        let outerY = radiusY + Self.ringGap
        let panelSize = NSSize(width: 2 * (outerX + Self.buttonRoom), height: 2 * (outerY + Self.buttonRoom))
        size = panelSize
        // 内圈尽量整圈：中心只在内圈会出屏时才往里挪（可以压在 Dock 上，Dock 在它下面一层）。
        let center = NSPoint(x: min(max(petCenter.x, bounds.minX + radiusX), bounds.maxX - radiusX),
                             y: min(max(petCenter.y, bounds.minY + radiusY), bounds.maxY - radiusY))
        // 中心被挪开（宠物贴着屏幕边）时，挡在宠物身上的那段不放按钮（内圈成马蹄形围着头顶）。
        // 避让区也是椭圆（矩形会把正常整圈的斜角也挖掉），比内圈小一圈，中心不挪时整圈都放得下。
        let avoid = Ellipse(center: petCenter, radiusX: pet.width / 2 + 18, radiusY: pet.height / 2 + 18)
        var positions: [String: CGPoint] = [:]
        let innerRing = Ellipse(center: center, radiusX: radiusX, radiusY: radiusY)
        for (item, point) in zip(inner, Self.layout(count: inner.count, on: innerRing, bounds: bounds, avoid: avoid)) {
            positions[item.id] = point
        }
        let outerRing = Ellipse(center: center, radiusX: outerX, radiusY: outerY)
        for (item, point) in zip(outerItems, Self.layout(count: outerItems.count, on: outerRing, bounds: bounds, avoid: avoid)) {
            positions[item.id] = point
        }
        self.positions = positions

        let panel = ensurePanel()
        panel.setFrame(NSRect(x: center.x - panelSize.width / 2, y: center.y - panelSize.height / 2,
                              width: panelSize.width, height: panelSize.height), display: false)
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

    /// 一圈上的按钮位置（相对椭圆中心，SwiftUI 坐标 y 朝下）：整圈放得下就从正上方顺时针、按弧长均分
    /// （椭圆上按角度均分，长轴两头会挤在一起）；放不下（出屏 / 压在宠物身上）就只用最长的那段可用弧，从左到右排。
    private static func layout(count: Int, on ring: Ellipse, bounds: NSRect, avoid: Ellipse) -> [CGPoint] {
        guard count > 0 else { return [] }
        let samples = 360
        // 从正上方开始顺时针采样一圈，并累计弧长。
        let points = (0..<samples).map { ring.point(at: 90 - Double($0)) }
        var arc = [CGFloat](repeating: 0, count: samples + 1)
        for i in 0..<samples {
            let next = points[(i + 1) % samples]
            arc[i + 1] = arc[i] + hypot(next.x - points[i].x, next.y - points[i].y)
        }
        let total = max(arc[samples], 1)
        func point(atArc length: CGFloat) -> NSPoint {
            var s = length.truncatingRemainder(dividingBy: total)
            if s < 0 { s += total }
            var i = 0
            while i < samples - 1, arc[i + 1] <= s { i += 1 }
            let f = (s - arc[i]) / max(arc[i + 1] - arc[i], 0.0001)
            let a = points[i]
            let b = points[(i + 1) % samples]
            return NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        let allowed = points.map { bounds.contains($0) && !avoid.contains($0) }
        var placed: [NSPoint]
        if allowed.allSatisfy({ $0 }) {
            placed = (0..<count).map { point(atArc: total * CGFloat($0) / CGFloat(count)) }
        } else {
            // 环形数组里最长的一段连续可用弧。
            var bestStart = 0, bestLength = 0
            for start in 0..<samples where allowed[start] && !allowed[(start - 1 + samples) % samples] {
                var length = 0
                while length < samples && allowed[(start + length) % samples] { length += 1 }
                if length > bestLength { bestStart = start; bestLength = length }
            }
            if bestLength == 0 {
                placed = (0..<count).map { point(atArc: total * CGFloat($0) / CGFloat(count)) }
            } else {
                var span: CGFloat = 0
                for k in 0..<max(bestLength - 1, 0) {
                    let i = (bestStart + k) % samples
                    span += arc[i + 1] - arc[i]
                }
                let start = arc[bestStart]
                placed = count == 1
                    ? [point(atArc: start + span / 2)]
                    : (0..<count).map { point(atArc: start + span * CGFloat($0) / CGFloat(count - 1)) }
            }
        }
        return placed.map { CGPoint(x: $0.x - ring.center.x, y: -($0.y - ring.center.y)) }
    }

    private func ensurePanel() -> RadialMenuPanel {
        if let panel { return panel }
        let panel = RadialMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        .frame(width: controller.size.width, height: controller.size.height)
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
