import AppKit
import SwiftUI

/// 气泡队列与窗口（设计 §2 的 PetPresenter 一半）：一次只显示一条，按级别自动消。
@MainActor
final class BubbleController: ObservableObject {
    struct Item {
        let notification: PetNotification
        let onAction: (String) -> Void
    }

    @Published private(set) var current: Item?

    private var queue: [Item] = []
    private var panel: NSPanel?
    private var hostingView: NSHostingView<BubbleView>?
    private var dismissTimer: Timer?

    /// 宠物窗的当前 frame，气泡贴在其上方。
    var anchorFrame: () -> NSRect = { .zero }

    func show(_ n: PetNotification, onAction: @escaping (String) -> Void) {
        queue.append(Item(notification: n, onAction: onAction))
        if current == nil { advance() }
    }

    func dismissAll() {
        queue.removeAll()
        current = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
    }

    /// 用户点了某个动作按钮（或无动作时点气泡本体消掉，actionID 为 nil 不回调）。
    func choose(_ actionID: String?) {
        guard let item = current else { return }
        if let actionID { item.onAction(actionID) }
        current = nil
        advance()
    }

    private func advance() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard !queue.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        current = queue.removeFirst()
        ensurePanel()
        // 等 SwiftUI 按新内容布局后再量尺寸、贴位。
        DispatchQueue.main.async { [weak self] in self?.layoutPanel() }
        panel?.orderFrontRegardless()

        let timeout: TimeInterval
        switch current?.notification.level {
        case .ambient: timeout = 4
        case .bubble: timeout = 12
        case .alert: timeout = 20
        case nil: timeout = 4
        }
        let effective = current?.notification.ttl.map { min(timeout, $0) } ?? timeout
        dismissTimer = Timer.scheduledTimer(withTimeInterval: effective, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.choose(nil) }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 272, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: BubbleView(controller: self))
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting
    }

    private func layoutPanel() {
        guard let panel, let hostingView else { return }
        let fitting = hostingView.fittingSize
        let width: CGFloat = 272
        let height = max(fitting.height, 44)
        panel.setContentSize(NSSize(width: width, height: height))
        let anchor = anchorFrame()
        var x = anchor.maxX - width
        var y = anchor.maxY + 6
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 4), visible.maxX - width - 4)
            y = min(y, visible.maxY - height - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// 气泡内容：标题、正文、动作按钮。点本体（无动作时）即消。
struct BubbleView: View {
    @ObservedObject var controller: BubbleController

    var body: some View {
        if let item = controller.current {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.notification.title)
                    .font(.headline)
                    .lineLimit(3)
                if !item.notification.body.isEmpty {
                    Text(item.notification.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
                if !item.notification.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(item.notification.actions, id: \.id) { action in
                            Button(action.label) { controller.choose(action.id) }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 272, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .onTapGesture {
                if item.notification.actions.isEmpty { controller.choose(nil) }
            }
        }
    }
}
