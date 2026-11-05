import AppKit

/// 宠物控制器：拥有窗口、引擎、气泡，并实现通知呈现端（设计 §2)。
@MainActor
final class PetController: NotifyPresenting {
    static let shared = PetController()
    private init() {}

    let engine = PetEngine()
    let bubble = BubbleController()

    private var panel: PetPanel?
    private let petView = CodeDrawnPetView()
    private var started = false

    var isReady: Bool { PetSettings.enabled && panel?.isVisible == true }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        let side = panelSide
        let panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = petView
        self.panel = panel

        bubble.anchorFrame = { [weak panel] in panel?.frame ?? .zero }
        panel.onClick = { [weak self] in self?.showPetMenu() }
        panel.onMove = { [weak self] origin in
            self?.engine.setOrigin(origin)
            self?.saveOrigin(origin)
        }
        panel.onDragState = { [weak self] dragging in self?.engine.setDragged(dragging) }
        engine.petSize = side
        engine.onPose = { [weak self] pose, origin in
            guard let self, let panel = self.panel else { return }
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            petView.pose = pose
        }

        let origin = restoredOrigin()
        panel.setFrameOrigin(origin)
        engine.start(at: origin)
        applyVisibility()
    }

    func stop() {
        saveOrigin(engine.origin)
        engine.stop()
        panel?.orderOut(nil)
    }

    // MARK: - 启用 / 尺寸

    private var panelSide: CGFloat { 104 * CGFloat(PetSettings.size) }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: PetSettings.enabledKey)
        applyVisibility()
    }

    func toggleEnabled() {
        setEnabled(!PetSettings.enabled)
    }

    func applyVisibility() {
        if PetSettings.enabled {
            panel?.orderFrontRegardless()
        } else {
            bubble.dismissAll()
            panel?.orderOut(nil)
        }
    }

    func applySize() {
        guard let panel else { return }
        let side = panelSide
        engine.petSize = side
        var frame = panel.frame
        frame.size = NSSize(width: side, height: side)
        panel.setFrame(frame, display: true)
        engine.setOrigin(frame.origin)
    }

    // MARK: - 通知呈现（NotifyPresenting）

    func present(_ n: PetNotification, onAction: @escaping (String) -> Void) {
        engine.notify(level: n.level)
        bubble.show(n, onAction: onAction)
    }

    // MARK: - 安静一下

    func quietForOneHour() {
        PetSettings.setQuietUntil(Date().addingTimeInterval(3600))
    }

    func quietForToday() {
        PetSettings.setQuietUntil(Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)))
    }

    func clearQuiet() {
        PetSettings.setQuietUntil(nil)
    }

    // MARK: - 测试通知

    func sendTestNotification() {
        NotifyCenter.shared.post(
            PetNotification(
                source: "pet",
                level: .bubble,
                title: L("pet.test.title"),
                body: L("pet.test.body"),
                actions: [.init(id: "ok", label: L("pet.test.ok"))]
            )
        )
    }

    // MARK: - 宠物菜单（点击 / 右键）

    private func showPetMenu() {
        guard let panel else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: PetSettings.enabled ? L("pet.menu.statusOn") : L("pet.menu.statusOff"),
                                action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quietItem = NSMenuItem(title: L("pet.menu.quiet"), action: nil, keyEquivalent: "")
        let quietMenu = NSMenu()
        quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quiet1h")) { [weak self] in self?.quietForOneHour() })
        quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quietToday")) { [weak self] in self?.quietForToday() })
        if PetSettings.quietUntil != nil {
            quietMenu.addItem(ClosureMenuItem(title: L("pet.menu.quietOff")) { [weak self] in self?.clearQuiet() })
        }
        quietItem.submenu = quietMenu
        menu.addItem(quietItem)
        menu.addItem(ClosureMenuItem(title: L("pet.menu.test")) { [weak self] in self?.sendTestNotification() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("pet.menu.hide")) { [weak self] in self?.setEnabled(false) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: panel.frame.height), in: panel.contentView)
    }

    // MARK: - 位置持久化

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: PetSettings.originXKey)
        UserDefaults.standard.set(origin.y, forKey: PetSettings.originYKey)
    }

    private func restoredOrigin() -> NSPoint {
        let defaults = UserDefaults.standard
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard defaults.object(forKey: PetSettings.originXKey) != nil else {
            return NSPoint(x: visible.minX + 24, y: visible.minY + 2)
        }
        var point = NSPoint(x: defaults.double(forKey: PetSettings.originXKey),
                            y: defaults.double(forKey: PetSettings.originYKey))
        point.x = min(max(point.x, visible.minX), visible.maxX - panelSide)
        point.y = min(max(point.y, visible.minY), visible.maxY - panelSide)
        return point
    }
}
