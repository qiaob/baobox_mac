import AppKit

/// 宠物控制器：拥有窗口、引擎、气泡、环形菜单，并实现通知呈现端（设计 §2；交互见 docs/desktop-pet/INTERACTION.md）。
@MainActor
final class PetController: ObservableObject, NotifyPresenting {
    static let shared = PetController()
    private init() {}

    let engine = PetEngine()
    let bubble = BubbleController()
    let radial = RadialMenuController()

    private var panel: PetPanel?
    private let stage = PetStageView()
    private let petView = SpritePetView()
    /// 3D 后端：用到 3D 形象时才建（SceneKit / Metal 初始化不便宜，只用 2D 形象的人不必付这个钱）。
    private lazy var modelView = PetModelView()
    /// 3D 视图里当前装着的形象；nil = 显示的是 2D 视图。
    private var shownModelID: String?
    private var started = false
    /// 气泡、环形菜单各自开着没有（任一开着宠物就站住面向用户）。
    private var bubbleShowing = false
    private var menuShowing = false
    /// 渲染视图借给了休息画面（#43，见 lendRenderView）。
    private(set) var isLent = false
    private var characterChangePending = false

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
        panel.contentView = stage
        self.panel = panel

        bubble.anchorFrame = { [weak panel] in panel?.frame ?? .zero }
        bubble.parentWindow = panel
        bubble.onVisibilityChange = { [weak self] showing in
            self?.bubbleShowing = showing
            self?.updateHeld()
        }
        bubble.onStickyReminder = { [weak self] in self?.engine.notify(level: .bubble) }
        radial.onVisibilityChange = { [weak self] showing in
            self?.menuShowing = showing
            self?.updateHeld()
        }

        panel.onClick = { [weak self] in self?.interact("poke") }
        panel.onDoubleClick = { [weak self] in self?.interact("highFive", fallback: "poke") }
        panel.onRightClick = { [weak self] in self?.openRadialMenu() }
        stage.onPetting = { [weak self] in self?.interact("pet", fallback: "poke") }
        panel.onMove = { [weak self] origin in
            self?.engine.setOrigin(origin)
            self?.saveOrigin(origin)
            self?.bubble.relayout()
        }
        panel.onDragState = { [weak self] dragging in self?.engine.setDragged(dragging) }
        engine.petSize = side
        engine.onPose = { [weak self] pose, origin in
            guard let self, let panel = self.panel else { return }
            // 拖拽时窗口由 PetPanel 跟手移动；引擎里的位置松手才更新，这时不能按它把窗口拽回去。
            if pose.state != .dragged, panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            // 渲染视图借给休息画面期间（#43），姿态由休息画面驱动。
            guard !self.isLent else { return }
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
        radial.close(animated: false)
        bubble.dismissAll()
        panel?.orderOut(nil)
    }

    private func updateHeld() {
        engine.setHeld(bubbleShowing || menuShowing || isLent)
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
            radial.close(animated: false)
            bubble.dismissAll()
            panel?.orderOut(nil)
            // 宠物关了，之后的通知走系统通知：现在就把权限问好（已问过则不再弹）。
            NotifyCenter.shared.prepareSystemFallback(requestPermission: true)
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
        bubble.relayout()
    }

    // MARK: - 通知呈现（NotifyPresenting）

    func present(_ n: PetNotification, onAction: @escaping (String) -> Void) {
        radial.close()
        engine.notify(level: n.level)
        bubble.show(n, onAction: onAction)
    }

    // MARK: - 互动（单击 / 双击 / 抚摸 / 喂食 / 陪玩）

    /// 做个互动动作并冒一句话。3D 形象按 pet.json 的 interactions（或按片段名猜）播；2D 形象跳一下。
    func interact(_ kind: String, fallback: String? = nil) {
        guard PetSettings.enabled else { return }
        radial.close()
        var used = kind
        var duration: TimeInterval?
        if shownModelID != nil {
            duration = modelView.perform(kind)
            if duration == nil, let fallback {
                used = fallback
                duration = modelView.perform(fallback)
            }
        }
        if let duration {
            engine.occupy(for: duration)
        } else {
            engine.occupy(for: 1)
            engine.notify(level: .bubble)
        }
        say(Self.line(for: used))
    }

    /// 当前形象支不支持某种互动（环形菜单据此显示「喂食」「陪玩」）。
    func supports(_ kind: String) -> Bool {
        shownModelID != nil && modelView.supports(kind)
    }

    /// 宠物说一句话：一条 2 秒的轻提示，不进通知历史。
    private func say(_ text: String) {
        guard !text.isEmpty else { return }
        bubble.show(PetNotification(source: "pet", level: .ambient, title: text, ttl: 2, icon: "pawprint.fill")) { _ in }
    }

    private static func line(for kind: String) -> String {
        let lines: [String]
        switch kind {
        case "poke": lines = [L("pet.line.poke1"), L("pet.line.poke2"), L("pet.line.poke3"), L("pet.line.poke4")]
        case "highFive": lines = [L("pet.line.highFive1"), L("pet.line.highFive2")]
        case "pet": lines = [L("pet.line.pet1"), L("pet.line.pet2")]
        case "feed": lines = [L("pet.line.feed1"), L("pet.line.feed2")]
        case "play": lines = [L("pet.line.play1"), L("pet.line.play2")]
        default: lines = []
        }
        return lines.randomElement() ?? ""
    }

    // MARK: - 健康提醒的动作（#43）

    /// 按片段名播一串动作，不冒话（喝水：坐下 → 捧着喝 → 站起；站立：伸懒腰）。
    /// 宠物没开、正借给休息画面、2D 形象或形象里没有这些片段时返回 false（调用方就只让它跳一下）。
    @discardableResult
    func act(clips: [String]) -> Bool {
        guard PetSettings.enabled, !isLent, shownModelID != nil,
              let duration = modelView.performClips(clips) else { return false }
        engine.occupy(for: duration)
        return true
    }

    // MARK: - 借给休息画面（#43，docs/focus-health/TECH_DESIGN.md §5.3）

    /// 借出的渲染视图与它此刻在屏幕上的位置。
    struct Loan {
        let view: NSView
        /// 宠物窗在屏幕上的位置与大小（休息画面从这里飞出去、最后飞回这里）。
        let frame: NSRect
        let is3D: Bool
    }

    /// 把当前渲染视图借给休息画面放大。宠物窗留在原地但变空、不接鼠标，引擎站住不溜达；
    /// 挂在宠物窗上的气泡不受影响。宠物没开 / 没就绪时返回 nil（休息画面走无宠物的回退画面）。
    func lendRenderView() -> Loan? {
        guard !isLent, PetSettings.enabled, let panel, panel.isVisible else { return nil }
        let view: NSView = shownModelID != nil ? modelView : petView
        guard view.superview === stage else { return nil }
        radial.close(animated: false)
        isLent = true
        updateHeld()
        panel.ignoresMouseEvents = true
        view.removeFromSuperview()
        return Loan(view: view, frame: panel.frame, is3D: shownModelID != nil)
    }

    /// 借出期间由休息画面驱动姿态（走过去、躺下、起身）。
    func setLentPose(_ pose: PetPose) {
        guard isLent else { return }
        if shownModelID != nil {
            modelView.pose = pose
        } else {
            petView.pose = pose
        }
    }

    /// 借出期间做个互动动作（被戳一下）。2D 形象或不支持时返回 nil。
    @discardableResult
    func performLent(_ kind: String) -> TimeInterval? {
        guard isLent, shownModelID != nil else { return nil }
        return modelView.perform(kind)
    }

    /// 休息画面结束：视图放回宠物窗，恢复鼠标与溜达；借出期间积下的换形象请求这时执行。
    func returnRenderView() {
        guard isLent else { return }
        isLent = false
        panel?.ignoresMouseEvents = false
        let view: NSView = shownModelID != nil ? modelView : petView
        stage.show(view)
        // 叫醒引擎（休息期间它按勿扰睡着了）；姿态由下一拍（≤ 1/30 秒）接上，不推旧姿态。
        engine.occupy(for: 0.5)
        updateHeld()
        if characterChangePending {
            characterChangePending = false
            applyCharacter()
        }
        applyVisibility()
    }

    // MARK: - 环形菜单（右键）

    private func openRadialMenu() {
        guard let panel else { return }
        if radial.isOpen {
            radial.close()
            return
        }
        let (inner, outer) = radialItems()
        radial.open(around: panel.frame, inner: inner, outer: outer)
    }

    /// 内圈 7 格（最后一格由菜单补「更多」）：最常用的工具 + 宠物动作；外圈：其他功能的快捷操作 + 宠物设置。
    /// 工具按各模块的快捷键定义调用（宠物模块不认识具体工具）；没装 / 没注册的工具自动不显示。
    /// 当前形象没有喂食 / 陪玩动作时，从外圈挪工具进内圈，保证内圈是满的。
    private func radialItems() -> (inner: [RadialMenuItem], outer: [RadialMenuItem]) {
        let hotkeys = AppDelegate.shared?.registry.allHotkeys().flatMap(\.defs) ?? []
        func tool(_ id: String, _ symbol: String, _ title: String) -> RadialMenuItem? {
            guard let def = hotkeys.first(where: { $0.id == id }) else { return nil }
            let action = def.action
            return RadialMenuItem(id: id, symbol: symbol, title: title) { action() }
        }
        let quiet = PetSettings.quietUntil.map { $0 > Date() } ?? false

        var inner: [RadialMenuItem] = [
            tool("screenshot.capture", "camera.viewfinder", L("pet.ring.screenshot")),
            tool("screenshot.ocr", "text.viewfinder", L("pet.ring.ocr")),
            tool("clipboard.togglePanel", "doc.on.clipboard", L("pet.ring.clipboard")),
            tool("livetranslate.toggle", "captions.bubble", L("pet.ring.translate")),
        ].compactMap { $0 }
        if supports("feed") {
            inner.append(RadialMenuItem(id: "pet.feed", symbol: "fork.knife", title: L("pet.ring.feed")) { [weak self] in
                self?.interact("feed")
            })
        }
        if supports("play") {
            inner.append(RadialMenuItem(id: "pet.play", symbol: "gamecontroller.fill", title: L("pet.ring.play")) { [weak self] in
                self?.interact("play")
            })
        }
        inner.append(RadialMenuItem(id: "pet.quiet", symbol: quiet ? "bell.fill" : "moon.zzz.fill",
                                    title: quiet ? L("pet.ring.unquiet") : L("pet.ring.quiet")) { [weak self] in
            if quiet { self?.clearQuiet() } else { self?.quietForOneHour() }
        })

        var outer: [RadialMenuItem] = [
            tool("screenshot.record", "record.circle", L("pet.ring.record")),
            tool("screenshot.draw", "scribble", L("pet.ring.draw")),
            tool("selectiontranslate.regionOCR", "rectangle.and.text.magnifyingglass", L("pet.ring.regionTranslate")),
            tool("claudecode.center", "sparkle", "Claude"),
            tool("aitools.center", "chevron.left.forwardslash.chevron.right", "Codex"),
            tool("keyboardnav.click", "keyboard", L("pet.ring.keyboard")),
            tool("windowmanager.maximize", "macwindow", L("pet.ring.maximize")),
            tool("caffeinate.toggle", "cup.and.saucer.fill", L("pet.ring.caffeinate")),
            tool("focushealth.focus", "timer", L("pet.ring.focus")),
        ].compactMap { $0 }
        outer.append(RadialMenuItem(id: "pet.character", symbol: "arrow.triangle.2.circlepath", title: L("pet.ring.character")) { [weak self] in
            self?.nextCharacter()
        })
        outer.append(RadialMenuItem(id: "pet.test", symbol: "bell.badge", title: L("pet.ring.test")) { [weak self] in
            self?.sendTestNotification(.toast)
            self?.sendTestNotification(.card)
            self?.sendTestNotification(.sticky)
        })
        outer.append(RadialMenuItem(id: "pet.settings", symbol: "gearshape", title: L("pet.ring.settings")) {
            guard let registry = AppDelegate.shared?.registry else { return }
            SettingsWindowController.shared.show(registry: registry, tab: "desktop-pet")
        })
        outer.append(RadialMenuItem(id: "pet.hide", symbol: "eye.slash", title: L("pet.ring.hide")) { [weak self] in
            self?.setEnabled(false)
        })

        // 内圈凑满 7 格（第 8 格是「更多」）。
        while inner.count < 7, !outer.isEmpty {
            inner.insert(outer.removeFirst(), at: max(inner.count - 1, 0))
        }
        return (inner, outer)
    }

    /// 换到下一个形象，并让新形象报个名。
    private func nextCharacter() {
        guard !packages.isEmpty else { return }
        let index = packages.firstIndex { $0.id == currentCharacterID } ?? -1
        let next = packages[(index + 1) % packages.count]
        selectCharacter(next.id)
        say(next.name)
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
        // 渲染视图借出去了：等休息画面还回来再换，免得把视图从休息画面里抢回来。
        if isLent {
            characterChangePending = true
            return
        }
        let id = currentCharacterID
        let package = packages.first { $0.id == id }
        if let package, package.model != nil {
            // 设置页每次打开都会重扫素材包；同一个 3D 形象不重新读模型（否则动画从头来、还白读一遍文件）。
            if shownModelID != package.id {
                shownModelID = modelView.setPackage(package) ? package.id : nil
            }
            if shownModelID != nil {
                petView.setPackage(nil)
                stage.show(modelView)
                modelView.setActive(PetSettings.enabled)
                return
            }
            // 模型读不出来：回退 2D 占位。
            petView.setPackage(nil)
            stage.show(petView)
            return
        }
        if shownModelID != nil {
            modelView.setPackage(nil)
            modelView.setActive(false)
            shownModelID = nil
        }
        petView.setPackage(package)
        stage.show(petView)
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

    // MARK: - 测试通知（三种样式各一条，走完整的通知内核）

    func sendTestNotification(_ style: PetNotification.Style = .card) {
        switch style {
        case .toast:
            NotifyCenter.shared.post(PetNotification(source: "pet", level: .ambient, title: L("pet.test.toastTitle")))
        case .card:
            NotifyCenter.shared.post(PetNotification(
                source: "pet", level: .bubble, title: L("pet.test.title"), body: L("pet.test.body"),
                actions: [.init(id: "ok", label: L("pet.test.ok"), role: .primary)]
            ))
        case .sticky:
            NotifyCenter.shared.post(PetNotification(
                source: "meeting", level: .alert, title: L("pet.test.stickyTitle"), body: L("pet.test.stickyBody"),
                actions: [
                    .init(id: "join", label: L("pet.test.join"), role: .primary),
                    .init(id: "later", label: L("pet.test.later")),
                    .init(id: "cancel", label: L("pet.test.cancel"), role: .destructive),
                ]
            )) { [weak self] action in
                // 演示按钮回调：选了什么就让宠物说出来。
                switch action {
                case "join": self?.say(L("pet.test.joined"))
                case "later": self?.say(L("pet.test.snoozed"))
                default: break
                }
            }
        }
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
