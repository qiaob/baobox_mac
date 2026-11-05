import AppKit

/// 宠物控制器：拥有窗口、引擎、气泡，并实现通知呈现端（设计 §2)。
@MainActor
final class PetController: ObservableObject, NotifyPresenting {
    static let shared = PetController()
    private init() {}

    let engine = PetEngine()
    let bubble = BubbleController()

    private var panel: PetPanel?
    private let petView = SpritePetView()
    /// 3D 后端：用到 3D 形象时才建（SceneKit / Metal 初始化不便宜，只用 2D 形象的人不必付这个钱）。
    private lazy var modelView = PetModelView()
    /// 3D 视图里当前装着的形象；nil = 显示的是 2D 视图。
    private var shownModelID: String?
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
            // 拖拽时窗口由 PetPanel 跟手移动；引擎里的位置松手才更新，这时不能按它把窗口拽回去。
            if pose.state != .dragged, panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            if self.shownModelID != nil {
                self.modelView.pose = pose
            } else {
                self.petView.pose = pose
            }
        }

        reloadCharacter()
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
        if shownModelID != nil { modelView.setActive(PetSettings.enabled) }
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

    // MARK: - 形象

    /// 内置 + 已下载 + 自制的全部形象（设置页的选择列表）。
    @Published private(set) var packages: [PetPackage] = []

    /// 当前用的形象：设置里选的那个；没选过 / 已被删掉时用第一个（内置形象排在最前）。
    var currentCharacterID: String {
        let wanted = PetSettings.character
        return (packages.first { $0.id == wanted } ?? packages.first)?.id ?? ""
    }

    /// 从磁盘重新扫一遍素材包（启动、下载 / 删除之后）。
    func reloadCharacter() {
        packages = PetPackageLoader.loadAll()
        applyCharacter()
    }

    func selectCharacter(_ id: String, reload: Bool = false) {
        UserDefaults.standard.set(id, forKey: PetSettings.characterKey)
        if reload { reloadCharacter() } else { applyCharacter() }
    }

    private func applyCharacter() {
        let id = currentCharacterID
        let package = packages.first { $0.id == id }
        if let package, package.model != nil {
            // 设置页每次打开都会重扫素材包；同一个 3D 形象不重新读模型（否则动画从头来、还白读一遍文件）。
            if shownModelID != package.id {
                shownModelID = modelView.setPackage(package) ? package.id : nil
            }
            if shownModelID != nil {
                petView.setPackage(nil)
                show(modelView)
                modelView.setActive(PetSettings.enabled)
                return
            }
            // 模型读不出来：回退 2D 占位。
            petView.setPackage(nil)
            show(petView)
            return
        }
        if shownModelID != nil {
            modelView.setPackage(nil)
            modelView.setActive(false)
            shownModelID = nil
        }
        petView.setPackage(package)
        show(petView)
    }

    private func show(_ view: NSView) {
        guard let panel, panel.contentView !== view else { return }
        panel.contentView = view
    }

    func openPetsFolder() {
        try? FileManager.default.createDirectory(at: PetPackageLoader.userPetsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PetPackageLoader.userPetsDirectory)
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
