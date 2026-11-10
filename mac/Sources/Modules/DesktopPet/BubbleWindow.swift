import AppKit
import SwiftUI

/// 屏幕上的一条气泡。
struct BubbleEntry: Identifiable {
    let id = UUID()
    let notification: PetNotification
    let onAction: (String) -> Void
    /// 总时长；nil = 常驻。
    let duration: TimeInterval?
    /// 计时中的截止时间；悬停暂停时为 nil，剩余时间记在 remaining。
    var deadline: Date?
    var remaining: TimeInterval?

    var style: PetNotification.Style { notification.resolvedStyle }
}

/// 气泡层（设计见 docs/desktop-pet/INTERACTION.md §1–§2）：
/// - 气泡窗是宠物窗的**子窗口**，宠物走动 / 被拖时跟着动，相对位置固定；
/// - 一次最多叠 3 条（最新的贴近宠物），多出来的排队，顶上显示「还有 N 条」；
/// - toast 3 秒、card 8 秒自动消失，鼠标停在气泡上时暂停计时；sticky 常驻，隔 25 秒让宠物招手提醒一次；
/// - 靠屏幕边时气泡整体挪进屏内、尾巴仍指向宠物；宠物在屏幕顶上时气泡翻到下面。
@MainActor
final class BubbleController: ObservableObject {
    @Published private(set) var entries: [BubbleEntry] = []
    @Published private(set) var overflowCount = 0
    /// 尾巴在气泡层里的横坐标（点）。
    @Published private(set) var tailX: CGFloat = 80
    /// 气泡在宠物下方（尾巴朝上）。
    @Published private(set) var below = false

    /// 宠物窗当前 frame。
    var anchorFrame: () -> NSRect = { .zero }
    /// 宠物窗：气泡挂成它的子窗口。
    weak var parentWindow: NSWindow?
    /// 有 / 没有气泡了（宠物据此站住面向用户 / 继续溜达）。
    var onVisibilityChange: ((Bool) -> Void)?
    /// 有常驻气泡没处理时，隔一会儿让宠物招手。
    var onStickyReminder: (() -> Void)?

    /// 宠物头顶 / 脚下挂着东西（会议控制条）时，气泡往外让开的距离（PetController 贴挂件时设）。
    enum AccessoryClearance: Equatable {
        case none
        case above(CGFloat)
        case below(CGFloat)
    }

    var accessoryClearance: AccessoryClearance = .none {
        didSet { if accessoryClearance != oldValue { relayout() } }
    }

    /// 宠物窗里头顶 / 脚底所在的高度比例：气泡尾巴、头顶挂件都贴这里。
    static let headFraction: CGFloat = 0.86
    static let feetFraction: CGFloat = 0.12

    static let panelWidth: CGFloat = 300
    private static let maxVisible = 3
    private static let stickyReminderInterval: TimeInterval = 25

    private var waiting: [BubbleEntry] = []
    /// 出场 / 退场动画期间（#54）气泡先收起来、新来的排队，宠物落地后再出（气泡是宠物窗的子窗口，不收会跟着飞出屏幕）。
    private(set) var suspended = false
    private var held: [(PetNotification, (String) -> Void)] = []
    private var panel: BubblePanel?
    private var hosting: BubbleHostingView?
    private var ticker: Timer?
    private var hovering = false
    private var nextStickyReminder = Date.distantFuture

    // MARK: - 显示 / 关闭

    func show(_ n: PetNotification, onAction: @escaping (String) -> Void) {
        if suspended {
            held.append((n, onAction))
            return
        }
        let base: TimeInterval? = {
            switch n.resolvedStyle {
            case .toast: return 3
            case .card: return 8
            case .sticky: return nil
            }
        }()
        let duration = base.map { limit in n.ttl.map { min(limit, $0) } ?? limit }
        var entry = BubbleEntry(notification: n, onAction: onAction, duration: duration,
                                deadline: nil, remaining: duration)
        if !hovering, let duration { entry.deadline = Date().addingTimeInterval(duration) }
        if entries.count < Self.maxVisible {
            entries.append(entry)
        } else {
            waiting.append(entry)
        }
        if n.resolvedStyle == .sticky, nextStickyReminder == .distantFuture {
            nextStickyReminder = Date().addingTimeInterval(Self.stickyReminderInterval)
        }
        refresh()
    }

    /// 点了按钮（actionID）/ 点了卡片本身（"open"）/ 点了 ×（nil）。
    func choose(_ id: UUID, action: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        if let action { entry.onAction(action) }
        promoteWaiting()
        refresh()
    }

    func dismissAll() {
        entries.removeAll()
        waiting.removeAll()
        held.removeAll()
        refresh()
    }

    /// 收起 / 放出气泡（见 suspended）。放出时排队的按到达顺序补上。
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        if on {
            if let panel {
                parentWindow?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            return
        }
        let pending = held
        held = []
        for (notification, action) in pending { show(notification, onAction: action) }
        if !entries.isEmpty { refresh() }
    }

    var isShowing: Bool { !entries.isEmpty }

    /// 宠物换了位置（拖完 / 改大小）后重新贴位。
    func relayout() {
        guard !entries.isEmpty else { return }
        layoutPanel()
    }

    // MARK: - 计时（悬停暂停）

    fileprivate func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        let now = Date()
        for i in entries.indices {
            if on, let deadline = entries[i].deadline {
                entries[i].remaining = max(0, deadline.timeIntervalSince(now))
                entries[i].deadline = nil
            } else if !on, entries[i].deadline == nil, let remaining = entries[i].remaining {
                // 移开后至少再留 1.5 秒，免得刚移开就消失。
                entries[i].deadline = now.addingTimeInterval(max(remaining, 1.5))
            }
        }
    }

    private func tick() {
        let now = Date()
        let expired = entries.filter { ($0.deadline.map { $0 <= now }) ?? false }.map(\.id)
        if !expired.isEmpty {
            entries.removeAll { expired.contains($0.id) }
            promoteWaiting()
            refresh()
        }
        if entries.contains(where: { $0.style == .sticky }) {
            if now >= nextStickyReminder {
                nextStickyReminder = now.addingTimeInterval(Self.stickyReminderInterval)
                onStickyReminder?()
            }
        } else {
            nextStickyReminder = .distantFuture
        }
    }

    private func promoteWaiting() {
        while entries.count < Self.maxVisible, !waiting.isEmpty {
            var next = waiting.removeFirst()
            if !hovering, let duration = next.duration { next.deadline = Date().addingTimeInterval(duration) }
            entries.append(next)
        }
    }

    // MARK: - 窗口

    private func refresh() {
        overflowCount = waiting.count
        if entries.isEmpty {
            ticker?.invalidate()
            ticker = nil
            if let panel {
                parentWindow?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            hovering = false
            onVisibilityChange?(false)
            return
        }
        // 收着的时候不显示（放出时再 refresh 一次）。
        guard !suspended else { return }
        ensurePanel()
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        onVisibilityChange?(true)
        // 等 SwiftUI 按新内容排好版再量尺寸、贴位；移除时淡出动画期间被删的那条还占着位置，
        // 动画结束后再量一次，窗口才会缩回去（实测只量一次时，toast 消失后窗口要等下一条变化才缩）。
        DispatchQueue.main.async { [weak self] in self?.layoutPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.layoutPanel() }
        if let panel, panel.parent == nil {
            layoutPanel()
            panel.orderFrontRegardless()
            parentWindow?.addChildWindow(panel, ordered: .above)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = BubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // 阴影由 SwiftUI 画（跟着气泡形状走）
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = BubbleHostingView(rootView: BubbleStackView(controller: self))
        hosting.onHover = { [weak self] on in self?.setHovering(on) }
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    /// 尾巴尖贴在宠物头顶；气泡默认往宠物右边展开，靠边时整体挪进屏内、尾巴跟着滑。
    private func layoutPanel() {
        guard let panel, let hosting else { return }
        let pet = anchorFrame()
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pet) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = max(hosting.fittingSize.height, 44)
        let width = Self.panelWidth
        var headTop = pet.minY + pet.height * Self.headFraction
        var feet = pet.minY + pet.height * Self.feetFraction
        switch accessoryClearance {
        case .above(let clearance): headTop += clearance
        case .below(let clearance): feet -= clearance
        case .none: break
        }
        let fitsAbove = headTop + height <= visible.maxY - 4
        var x = pet.midX - width * 0.28
        x = min(max(x, visible.minX + 4), visible.maxX - width - 4)
        let y = fitsAbove ? headTop : max(feet - height, visible.minY + 4)
        let newTail = pet.midX - x
        if abs(newTail - tailX) > 0.5 { tailX = newTail }
        if below == fitsAbove { below = !fitsAbove }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// 气泡窗：要能点按钮，所以允许成为 key（nonactivatingPanel 保证不把 Baobox 切到前台）。
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI 宿主：首击即生效（不用先点一下激活窗口），并用 AppKit 跟踪区判断悬停 ——
/// Baobox 平时不是前台 App，SwiftUI 的 onHover 在非激活 App 里不一定触发。
final class BubbleHostingView: NSHostingView<BubbleStackView> {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    required init(rootView: BubbleStackView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - 视图

/// 气泡层内容：从远到近排列（最新的贴近宠物，只有它带尾巴）。
struct BubbleStackView: View {
    @ObservedObject var controller: BubbleController

    var body: some View {
        let ordered = controller.below ? Array(controller.entries.reversed()) : controller.entries
        let nearest = controller.entries.last?.id
        VStack(alignment: .leading, spacing: 8) {
            if controller.overflowCount > 0, !controller.below { overflowPill }
            ForEach(ordered) { entry in
                BubbleCard(entry: entry, tailX: entry.id == nearest ? controller.tailX - Self.inset : nil,
                           tailOnTop: controller.below) { action in
                    controller.choose(entry.id, action: action)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.86, anchor: controller.below ? .top : .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
            if controller.overflowCount > 0, controller.below { overflowPill }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, controller.below ? 2 : 12)
        .padding(.bottom, controller.below ? 12 : 2)
        .frame(width: BubbleController.panelWidth, alignment: .leading)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: controller.entries.map(\.id))
    }

    /// 两侧留给阴影的边距。
    static let inset: CGFloat = 10

    private var overflowPill: some View {
        Text(L("pet.bubble.more \(controller.overflowCount)"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(BubblePalette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(BubblePalette.surface))
            .overlay(Capsule().strokeBorder(BubblePalette.line, lineWidth: 0.5))
    }
}

/// 一条气泡：toast（一行）/ card（标题 + 正文 + 按钮 + 倒计时线）/ sticky（同 card，常驻、品牌色描边）。
struct BubbleCard: View {
    let entry: BubbleEntry
    /// 有值 = 带尾巴（气泡卡片内的横坐标）。
    let tailX: CGFloat?
    let tailOnTop: Bool
    let onChoose: (String?) -> Void

    private static let tailHeight: CGFloat = 9
    private var notification: PetNotification { entry.notification }

    var body: some View {
        let shape = SpeechBubbleShape(cornerRadius: entry.style == .toast ? 16 : 14, tailX: tailX,
                                      tailOnTop: tailOnTop, tailHeight: Self.tailHeight)
        content
            .padding(.top, tailX != nil && tailOnTop ? Self.tailHeight : 0)
            .padding(.bottom, tailX != nil && !tailOnTop ? Self.tailHeight : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(BubblePalette.surface).shadow(color: .black.opacity(0.16), radius: 9, y: 3))
            .overlay(shape.stroke(entry.style == .sticky ? BubblePalette.accent.opacity(0.75) : BubblePalette.line,
                                  lineWidth: entry.style == .sticky ? 1.2 : 0.5))
            .contentShape(shape)
            .onTapGesture {
                // 点卡片本身：交给来源（如「打开」），没按钮的 toast / card 顺便收起。
                if notification.actions.isEmpty { onChoose("open") }
            }
    }

    @ViewBuilder
    private var content: some View {
        if entry.style == .toast {
            HStack(spacing: 8) {
                BubbleSourceIcon(symbol: symbol, size: 20)
                Text(notification.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 12))
                        .foregroundStyle(BubblePalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    BubbleSourceIcon(symbol: symbol, size: 20)
                    Text(sourceName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BubblePalette.muted)
                    Spacer(minLength: 0)
                    Button {
                        onChoose(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BubblePalette.muted)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(BubblePalette.muted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                Text(notification.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(BubblePalette.muted)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notification.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(notification.actions, id: \.id) { action in
                            BubbleActionButton(action: action) { onChoose(action.id) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                }
                if entry.duration != nil {
                    BubbleCountdown(entry: entry).padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, entry.duration != nil ? 8 : 11)
        }
    }

    private var symbol: String {
        if let icon = notification.icon { return icon }
        switch notification.source {
        case "claudecode": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "livetranslate": return "captions.bubble.fill"
        case "meeting": return "video.fill"
        case "digest": return "tray.full.fill"
        case "pet": return "pawprint.fill"
        default: return "bell.fill"
        }
    }

    private var sourceName: String {
        switch notification.source {
        case "storage": return "Baobox"
        case "claudecode": return "Claude Code"
        case "codex": return "Codex"
        case "livetranslate": return L("pet.source.livetranslate")
        case "meeting": return L("pet.source.meeting")
        case "digest": return L("pet.source.digest")
        case "pet": return L("pet.name")
        default: return notification.source
        }
    }
}

/// 来源图标：品牌色淡底圆 + 图标。
struct BubbleSourceIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(BubblePalette.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(BubblePalette.accent.opacity(0.14)))
    }
}

/// 按钮：主按钮品牌色实心，次按钮淡底，危险按钮红字。
struct BubbleActionButton: View {
    let action: PetNotification.Action
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(action.label)
                .font(.system(size: 12, weight: action.role == .primary ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch action.role {
        case .primary: return .white
        case .secondary: return BubblePalette.accentInk
        case .destructive: return Color(nsColor: .systemRed)
        }
    }

    private var background: Color {
        switch action.role {
        case .primary: return BubblePalette.accent
        case .secondary: return BubblePalette.accent.opacity(0.12)
        case .destructive: return Color(nsColor: .systemRed).opacity(0.09)
        }
    }
}

/// 剩余时间细线（悬停时停住）。
struct BubbleCountdown: View {
    let entry: BubbleEntry

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: entry.deadline == nil)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(BubblePalette.line.opacity(0.6))
                    Capsule().fill(BubblePalette.accent.opacity(0.85))
                        .frame(width: geometry.size.width * progress(at: context.date))
                }
            }
            .frame(height: 2)
        }
    }

    private func progress(at date: Date) -> CGFloat {
        guard let duration = entry.duration, duration > 0 else { return 0 }
        let remaining = entry.deadline.map { max(0, $0.timeIntervalSince(date)) } ?? (entry.remaining ?? duration)
        return CGFloat(min(max(remaining / duration, 0), 1))
    }
}

/// 设计令牌（docs/design/ui-design-v1.html）：深浅两套。
enum BubblePalette {
    static let accent = dynamic(light: 0x17A398, dark: 0x2BC4B8)
    static let accentInk = dynamic(light: 0x0E7C74, dark: 0x7FE0D8)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C2224, alpha: 0.97)
    static let line = dynamic(light: 0xDDE4E2, dark: 0x2F383A)
    static let muted = dynamic(light: 0x5D6B68, dark: 0x9CAAA6)

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
}

/// 对话气泡外形：圆角矩形 + 一条指向宠物的圆润小尾巴（一笔画成，描边才不会在尾巴根部断开）。
struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 14
    /// nil = 不带尾巴。
    var tailX: CGFloat?
    var tailOnTop = false
    var tailHeight: CGFloat = 9
    var tailWidth: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        let th = tailX == nil ? 0 : tailHeight
        let top = rect.minY + (tailOnTop ? th : 0)
        let bottom = rect.maxY - (tailOnTop ? 0 : th)
        let left = rect.minX
        let right = rect.maxX
        let half = tailWidth / 2
        let x = tailX.map { min(max($0, left + r + half), right - r - half) }

        var p = Path()
        p.move(to: CGPoint(x: left + r, y: top))
        if let x, tailOnTop {
            p.addLine(to: CGPoint(x: x - half, y: top))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - half * 0.25, y: top - th * 0.15))
            p.addQuadCurve(to: CGPoint(x: x + half, y: top), control: CGPoint(x: x + half * 0.25, y: top - th * 0.15))
        }
        p.addLine(to: CGPoint(x: right - r, y: top))
        p.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + r), radius: r)
        p.addLine(to: CGPoint(x: right, y: bottom - r))
        p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right - r, y: bottom), radius: r)
        if let x, !tailOnTop {
            p.addLine(to: CGPoint(x: x + half, y: bottom))
            p.addQuadCurve(to: CGPoint(x: x, y: rect.maxY), control: CGPoint(x: x + half * 0.25, y: bottom + th * 0.15))
            p.addQuadCurve(to: CGPoint(x: x - half, y: bottom), control: CGPoint(x: x - half * 0.25, y: bottom + th * 0.15))
        }
        p.addLine(to: CGPoint(x: left + r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - r), radius: r)
        p.addLine(to: CGPoint(x: left, y: top + r))
        p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}
