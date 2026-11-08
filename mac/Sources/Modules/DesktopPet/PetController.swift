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

    /// 换形象时退场已播完、新形象还没出场（VRM 要在后台读几秒）：这期间通知照样交给宠物，排队等它出场。
    private var switchingCharacter = false

    var isReady: Bool { PetSettings.enabled && (panel?.isVisible == true || switchingCharacter) }

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
        // 出场 / 退场时按洞线裁掉宠物（PetEntrance）要用图层遮罩。
        stage.wantsLayer = true
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
            self?.layoutAccessory()
        }
        panel.onDragState = { [weak self] dragging in self?.engine.setDragged(dragging) }
        engine.petSize = side
        engine.onPose = { [weak self] pose, origin in
            guard let self, let panel = self.panel else { return }
            // 站在窗口上 / 在空中时窗口列表刷得勤一些，窗口被拖动时跟得上。
            self.windowWatcher.fast = self.engine.isOnLedge || pose.state == .jump || pose.state == .fall
            // 拖拽时窗口由 PetPanel 跟手移动；引擎里的位置松手才更新，这时不能按它把窗口拽回去。
            if pose.state != .dragged, panel.frame.origin != origin {
                panel.setFrameOrigin(origin)
                // 头顶挂件跟着宠物窗平移；落地、跟着窗口挪走以后，头顶还放不放得下可能变了。
                if self.accessory != nil { self.layoutAccessory() }
            }
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
        engine.ledges = { [weak self] in self?.windowWatcher.ledges ?? [] }
        configureRange()
        engine.start(at: origin)
        // 3D 形象在后台读（VRM 要好几秒）：读好再出场，不先拿占位图跳一遍。期间的通知排队。
        if PetSettings.enabled, loadingModelID != nil {
            switchingCharacter = true
            bubble.setSuspended(true)
        }
        applyVisibility()
        startClickThroughTracking()
    }

    // MARK: - 活动范围（docs/desktop-pet/ROAM.md）

    /// 窗口上的顶边从这里来（只在「窗口上」模式时运行）。
    private let windowWatcher = PetWindowWatcher()

    private func configureRange() {
        engine.range = PetSettings.range
        engine.customRect = PetSettings.rangeRect
        if engine.range == .windows {
            if !windowWatcher.isRunning { windowWatcher.start() }
        } else {
            windowWatcher.stop()
        }
    }

    /// 设置页改了活动范围：重新找脚下的台面（离开随意放模式时会掉到地上）。
    func applyRange() {
        configureRange()
        engine.rangeChanged()
    }

    /// 框选自定义区域；选好后自动切到「自定义区域」。
    func pickRegion() {
        PetRegionPicker.shared.pick { [weak self] rect in
            guard let rect else { return }
            PetSettings.setRangeRect(rect)
            UserDefaults.standard.set(PetRange.custom.rawValue, forKey: PetSettings.rangeKey)
            self?.applyRange()
        }
    }

    /// 退出 Baobox：宠物开着就先播一个短退场（只掉下去那段），最多等 0.5 秒，不拖慢退出 / 重启。
    func stop() {
        saveOrigin(choreographyHome ?? engine.origin)
        radial.close(animated: false)
        bubble.dismissAll()
        if let panel, panel.isVisible, PetSettings.enabled, !isLent, !switchingCharacter {
            var done = false
            playExit(quick: true) { done = true }
            let deadline = Date().addingTimeInterval(0.5)
            // 退出流程里等不了事件循环下一轮：就地转几圈，让引擎的帧定时器和 3D 渲染跑起来。
            while !done, Date() < deadline {
                RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(1.0 / 60)))
            }
        }
        engine.stop()
        panel?.orderOut(nil)
    }

    // MARK: - 出场 / 退场（#54，docs/desktop-pet/ENTRANCE.md）

    /// 正在播出场 / 退场：不接鼠标、不溜达、气泡排队、头顶挂件先摘下来。
    private(set) var isChoreographing = false
    /// 播之前宠物站的位置：退场播完放回这里（下次出场、记住的位置都用它）。
    private var choreographyHome: NSPoint?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 该不该播动画：设置里开着、宠物没借给休息画面。
    private var animatesEntrance: Bool { PetSettings.entranceAnimation && !isLent }

    private func beginChoreography() {
        guard let panel else { return }
        if !isChoreographing {
            choreographyHome = engine.origin
        }
        isChoreographing = true
        radial.close(animated: false)
        panel.ignoresMouseEvents = true
        bubble.setSuspended(true)
        updateAccessory()
    }

    /// 播完（或被打断不再播）：外观复原，位置放回 `home`，恢复鼠标、气泡与头顶挂件。
    private func endChoreography(restoreHome: Bool) {
        guard isChoreographing else { return }
        isChoreographing = false
        let home = choreographyHome
        choreographyHome = nil
        engine.endScript(at: restoreHome ? home : nil)
        if restoreHome, let home { panel?.setFrameOrigin(home) }
        applyFrame(PetEntrancePlan.Frame(origin: engine.origin, look: .idle, attentive: false))
        portal.hide()
        panel?.ignoresMouseEvents = false
        updateClickThrough()
    }

    /// 出场 / 退场的黑洞（排在宠物窗下面）。
    private let portal = PetPortal()
    /// 「被吞掉」的遮罩：只留洞线以上的宠物。
    private let swallowMask = CALayer()

    /// 洞多宽：大约是宠物身子的宽度（VRM 人又高又瘦，窗口放大了，洞按身子算）。
    private var holeWidth: CGFloat {
        guard shownModelID != nil else { return panelSide * 0.8 }
        return panelSide * (modelView.isHumanoid ? 0.42 : 0.7)
    }

    private func applyFrame(_ frame: PetEntrancePlan.Frame) {
        panel?.alphaValue = frame.alpha
        portal.setOpen(frame.hole)
        if let line = frame.swallowLine, let layer = stage.layer {
            // 宠物窗左下角 = frame.origin：洞线在窗口里的高度 = line − origin.y。
            let bounds = stage.bounds
            let cut = min(max(line - frame.origin.y, 0), bounds.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            swallowMask.backgroundColor = NSColor.black.cgColor
            swallowMask.frame = CGRect(x: 0, y: cut, width: bounds.width, height: bounds.height - cut)
            if layer.mask !== swallowMask { layer.mask = swallowMask }
            CATransaction.commit()
        } else if stage.layer?.mask != nil {
            stage.layer?.mask = nil
        }
        if shownModelID != nil {
            // VRM 有自己的落地片段；毛绒 / 动物模型没有，靠形变压一下。
            modelView.presentationScale = modelView.isHumanoid ? CGSize(width: 1, height: 1) : frame.scale
        } else {
            petView.presentationScale = frame.scale
        }
    }

    /// 交给引擎逐帧执行；播完在下一轮主循环回调 completion（被新的出场 / 退场打断的不回调）。
    private func run(_ plan: PetEntrancePlan, as state: PetEngine.State, completion: @escaping () -> Void) {
        let start = Date()
        if let hole = plan.hole, let panel {
            portal.show(center: hole.center, width: hole.width, below: panel)
        } else {
            portal.hide()
        }
        applyFrame(plan.sample(0))
        engine.runScript(as: state) { [weak self] now in
            let t = now.timeIntervalSince(start)
            guard let self, t < plan.duration else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
                return nil
            }
            let frame = plan.sample(t)
            self.applyFrame(frame)
            return PetEngine.ScriptFrame(origin: frame.origin, look: frame.look, attentive: frame.attentive,
                                         bounce: frame.bounce, facingLeft: frame.facingLeft)
        }
    }

    /// 出场：先放到起点再显示。设置里关了动画就直接出现；减弱动态效果时原地淡入。
    private func playEntrance() {
        guard let panel else { return }
        guard animatesEntrance else {
            if isChoreographing { endChoreography(restoreHome: true) }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            bubble.setSuspended(false)
            updateAccessory()
            return
        }
        beginChoreography()
        let home = choreographyHome ?? engine.origin
        let plan = reduceMotion
            ? PetEntrancePlan.fade(home: home, appearing: true)
            : PetEntrancePlan.enter(home: home, side: panelSide, footInset: engine.footInset, holeWidth: holeWidth,
                                    greetClip: shownModelID != nil && modelView.hasEntranceClip(leaving: false))
        let first = plan.sample(0)
        engine.setOrigin(first.origin)
        panel.setFrameOrigin(first.origin)
        panel.orderFrontRegardless()
        applyFrame(first)
        if shownModelID != nil { modelView.setActive(true) }
        // 黑洞要排在宠物窗下面：窗口显示出来之后再摆。
        run(plan, as: .entering) { [weak self] in
            guard let self else { return }
            self.endChoreography(restoreHome: true)
            self.bubble.setSuspended(false)
            self.updateAccessory()
            if !self.reduceMotion { self.greet(afterEntrance: true) }
        }
    }

    /// 打招呼：有出场片段的播片段（VRM 招手）；没有的跳一下 —— 出场编排里已经弹过一下的就不再跳。
    private func greet(afterEntrance: Bool) {
        if shownModelID != nil, let duration = modelView.performEntrance(leaving: false) {
            engine.occupy(for: duration)
        } else if !afterEntrance {
            engine.occupy(for: 1)
            engine.notify(level: .bubble)
        }
    }

    /// 退场：播完回调（窗口还没收起，由调用方决定收起还是换形象）。没开动画 / 窗口没显示时立刻回调。
    private func playExit(quick: Bool, completion: @escaping () -> Void) {
        guard let panel, panel.isVisible, animatesEntrance else {
            if isChoreographing { endChoreography(restoreHome: true) }
            completion()
            return
        }
        // 正在出场又要退场（快速开关）：从此刻的位置退，播完放回出场的终点。
        beginChoreography()
        let home = engine.origin
        let is3D = shownModelID != nil
        let farewellClip = is3D && modelView.hasEntranceClip(leaving: true)
        let plan: PetEntrancePlan
        if reduceMotion {
            plan = PetEntrancePlan.fade(home: home, appearing: false)
        } else {
            plan = PetEntrancePlan.leave(home: home, side: panelSide, footInset: engine.footInset,
                                         holeWidth: holeWidth, farewellClip: farewellClip, quick: quick)
            if !quick, farewellClip { modelView.performEntrance(leaving: true) }
        }
        run(plan, as: .leaving) { [weak self] in
            guard let self else { return }
            panel.orderOut(nil)
            self.endChoreography(restoreHome: true)
            completion()
        }
    }

    private func updateHeld() {
        engine.setHeld(bubbleShowing || menuShowing || isLent)
    }

    // MARK: - 启用 / 尺寸

    /// 宠物窗边长。VRM 人形又高又瘦，方窗里只占一小条：窗口放大 1.55 倍（docs/desktop-pet/VRM.md §6），
    /// 人身以外的地方点击穿透（见 updateClickThrough），大窗口不挡下面的东西。
    private var panelSide: CGFloat {
        let humanoid = shownModelID != nil && modelView.isHumanoid
        return (104 * CGFloat(PetSettings.size) * (humanoid ? 1.55 : 1)).rounded()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: PetSettings.enabledKey)
        applyVisibility()
    }

    func toggleEnabled() {
        setEnabled(!PetSettings.enabled)
    }

    /// 宠物开 / 关：开 = 出场，关 = 退场后收起（#54）。已经是那个样子就只理一理窗口。
    func applyVisibility() {
        guard let panel else { return }
        if PetSettings.enabled {
            if shownModelID != nil { modelView.setActive(true) }
            if switchingCharacter { return }   // 新形象读好后自己出场
            let leaving = isChoreographing && engine.state == .leaving
            if !panel.isVisible || leaving {
                playEntrance()
            } else {
                panel.orderFrontRegardless()
                updateAccessory()
            }
        } else {
            switchingCharacter = false
            radial.close(animated: false)
            bubble.dismissAll()
            let finish: () -> Void = { [weak self] in
                guard let self, !PetSettings.enabled else { return }
                // 先把头顶挂件摘下来交还：子窗口会跟着宠物窗一起收起。
                self.updateAccessory()
                self.panel?.orderOut(nil)
                if self.shownModelID != nil { self.modelView.setActive(false) }
            }
            if panel.isVisible, !(isChoreographing && engine.state == .leaving) {
                playExit(quick: false, completion: finish)
            } else if !isChoreographing {
                finish()
            }
            // 宠物关了，之后的通知走系统通知：现在就把权限问好（已问过则不再弹）。
            NotifyCenter.shared.prepareSystemFallback(requestPermission: true)
        }
    }

    /// 按尺寸设置与当前形象调整宠物窗：底边中点不动（换成更大的 VRM 窗时脚还踩在原地），不出屏。
    func applySize() {
        guard let panel else { return }
        let side = panelSide
        engine.petSize = side
        // 脚离窗口底边多远（站到台面上时对齐用）与走路速度（3D 按步幅算，脚不打滑）。
        let model = shownModelID != nil ? modelView : nil
        engine.footInset = (model?.footInsetFraction ?? 0) * side
        engine.walkSpeed = model?.walkSpeed(viewHeight: side) ?? 34 * side / 104
        var frame = panel.frame
        guard frame.width != side || frame.height != side else { return }
        frame.origin.x = (frame.midX - side / 2).rounded()
        frame.size = NSSize(width: side, height: side)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - side)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - side)
        }
        panel.setFrame(frame, display: true)
        engine.setOrigin(frame.origin)
        bubble.relayout()
        layoutAccessory()
    }

    // MARK: - 点击穿透（VRM：只有人身上接鼠标）

    private var clickThroughTimer: Timer?

    /// 每秒 20 次看鼠标在不在人身上：不在就让整个窗口不接鼠标，点击落到下面的窗口。
    /// 拖拽中、借给休息画面时不动（借出时窗口本来就不接鼠标）。2D / 毛绒形象整个窗口都接，与原来一样。
    private func startClickThroughTracking() {
        clickThroughTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickThroughTimer = timer
    }

    private func updateClickThrough() {
        guard let panel, !isLent, !isChoreographing, panel.isVisible, !panel.isTracking else { return }
        var ignore = false
        if shownModelID != nil, modelView.isHumanoid {
            let mouse = NSEvent.mouseLocation
            if panel.frame.contains(mouse) {
                let point = modelView.convert(panel.convertPoint(fromScreen: mouse), from: nil)
                ignore = !modelView.hitsBody(at: point)
            } else {
                ignore = true
            }
        }
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    // MARK: - 头顶挂件（会议控制条，docs/meeting/TECH_DESIGN.md §3）

    /// 挂在宠物头顶的窗口，一次一个。挂上 = 宠物窗的子窗口：宠物被拖、跟着窗口挪、掉下来时一起动；气泡排在它外侧。
    private weak var accessory: NSWindow?
    private var accessoryOnChange: ((Bool) -> Void)?
    /// 上次告诉挂件方的状态；nil = 还没告诉过。
    private var accessoryDocked: Bool?
    private static let accessoryGap: CGFloat = 4

    /// 把窗口挂到宠物头顶。宠物在（开着、窗口显示着、没借给休息画面）就挂上，否则不挂。挂上 / 摘下都回调
    /// `onChange(挂着没有)`：登记时先回调一次，之后宠物开关、借出归还时再回调 —— 没挂上时位置由调用方自己摆。
    func dockAccessory(_ window: NSWindow, onChange: @escaping (Bool) -> Void) {
        if let old = accessory, old !== window { undockAccessory(old) }
        accessory = window
        accessoryOnChange = onChange
        accessoryDocked = nil
        updateAccessory()
    }

    /// 摘下来、不再跟着宠物（不回调，调用方自己收起窗口）。
    func undockAccessory(_ window: NSWindow) {
        guard accessory === window else { return }
        detachAccessory(window)
        accessory = nil
        accessoryOnChange = nil
        accessoryDocked = nil
    }

    /// 挂件要换大小（`size`），或者自己重新排过一次窗口（orderOut 会把子窗口从宠物窗上摘掉）：重新挂好、贴位。
    func refreshAccessory(size: CGSize? = nil) {
        updateAccessory(size: size)
    }

    private func updateAccessory(size: CGSize? = nil) {
        guard let accessory else { return }
        // 出场 / 退场途中不挂：控制条先放到屏幕顶部，落地后再挂回来。
        if PetSettings.enabled, !isLent, !isChoreographing, let panel, panel.isVisible {
            // 先告诉挂件方（它据此停掉自己的拖动和记位置），再挂上、贴位。
            if accessoryDocked != true {
                accessoryDocked = true
                accessoryOnChange?(true)
            }
            if accessory.parent !== panel {
                accessory.parent?.removeChildWindow(accessory)
                panel.addChildWindow(accessory, ordered: .above)
            }
            layoutAccessory(size: size)
        } else {
            detachAccessory(accessory)
            if accessoryDocked != false {
                accessoryDocked = false
                accessoryOnChange?(false)
            }
        }
    }

    private func detachAccessory(_ window: NSWindow) {
        window.parent?.removeChildWindow(window)
        bubble.accessoryClearance = .none
    }

    /// 头顶正上方、跟宠物居中对齐；头顶放不下（宠物在屏幕上沿附近）就放到脚下。左右挪进屏内。
    private func layoutAccessory(size: CGSize? = nil) {
        guard let accessory, let panel, accessory.parent === panel else { return }
        let pet = panel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pet) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = screen.map { Self.usableTop($0) } ?? visible.maxY
        let size = size ?? accessory.frame.size
        let head = pet.minY + pet.height * BubbleController.headFraction
        let fitsAbove = head + Self.accessoryGap + size.height <= top - 4
        let x = min(max((pet.midX - size.width / 2).rounded(), visible.minX + 4), visible.maxX - size.width - 4)
        let y = fitsAbove
            ? head + Self.accessoryGap
            : max(pet.minY + pet.height * BubbleController.feetFraction - Self.accessoryGap - size.height,
                  visible.minY + 4)
        let frame = NSRect(x: x, y: y.rounded(), width: size.width, height: size.height)
        if accessory.frame != frame { accessory.setFrame(frame, display: true) }
        let clearance = size.height + Self.accessoryGap * 2
        bubble.accessoryClearance = fitsAbove ? .above(clearance) : .below(clearance)
    }

    /// 屏幕上沿能放东西到哪：让开菜单栏；全屏 App 里菜单栏收起时还要让开刘海那条黑带（safeAreaInsets）。
    private static func usableTop(_ screen: NSScreen) -> CGFloat {
        screen.frame.maxY - max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top,
                                NSStatusBar.system.thickness)
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
        guard PetSettings.enabled, !isChoreographing else { return }
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
        guard PetSettings.enabled, !isLent, !isChoreographing, shownModelID != nil,
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
        guard !isLent, PetSettings.enabled, !switchingCharacter, let panel, panel.isVisible else { return nil }
        // 正在出场 / 退场：直接收尾（站回原位、外观复原）再借出。
        if isChoreographing {
            endChoreography(restoreHome: true)
            bubble.setSuspended(false)
        }
        let view: NSView = shownModelID != nil ? modelView : petView
        guard view.superview === stage else { return nil }
        radial.close(animated: false)
        isLent = true
        updateHeld()
        updateAccessory()
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
        updateAccessory()
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
        // 归位：休息画面已经把它送回原处，这里转过来打个招呼（#54；不再从屏幕外跳上来）。
        if PetSettings.enabled, PetSettings.entranceAnimation, !reduceMotion { greet(afterEntrance: false) }
    }

    // MARK: - 环形菜单（右键）

    private func openRadialMenu() {
        guard let panel else { return }
        if radial.isOpen {
            radial.close()
            return
        }
        let (inner, outer) = radialItems()
        // VRM 人形：圈围着人身（又高又瘦）排，不围着放大了的方窗口；其他形象围着宠物窗。
        var body = panel.frame
        if shownModelID != nil, modelView.isHumanoid, let rect = modelView.bodyBounds() {
            body = panel.convertToScreen(modelView.convert(rect, to: nil))
        }
        radial.open(around: body, inner: inner, outer: outer)
    }

    /// 内圈 7 格（最后一格由菜单补「更多」）：最常用的工具（含手机互传）+ 宠物动作；外圈：其他功能的快捷操作 + 宠物设置。
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
            tool("phonetransfer.open", "iphone.and.arrow.forward", L("pet.ring.phoneTransfer")),
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

        // 内圈最多 7 格（第 8 格是「更多」）：形象有喂食 + 陪玩时会多出来，把排在最后的工具（实时翻译，已并入会议）挪到外圈最前。
        while inner.count > 7, let last = inner.lastIndex(where: { !$0.id.hasPrefix("pet.") }) {
            outer.insert(inner.remove(at: last), at: 0)
        }
        // 内圈凑满 7 格。
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

    /// 换形象：开着动画时先让旧形象退场，再换上新形象出场（#54）。
    func selectCharacter(_ id: String, reload: Bool = false) {
        let previous = currentCharacterID
        UserDefaults.standard.set(id, forKey: PetSettings.characterKey)
        if reload { packages = PetPackageLoader.loadAll() }
        // 退场还没播完 / 新形象还在读：播完、读完时会按最新的选择来。
        if isChoreographing, engine.state == .leaving, switchingCharacter { return }
        if switchingCharacter {
            applyCharacter()
            return
        }
        guard currentCharacterID != previous, PetSettings.enabled, animatesEntrance,
              let panel, panel.isVisible else {
            applyCharacter()
            return
        }
        switchingCharacter = true
        playExit(quick: false) { [weak self] in
            guard let self else { return }
            guard self.switchingCharacter else {
                // 退场途中宠物被关掉了：窗口已收起，3D 渲染也停掉。
                if !PetSettings.enabled, self.shownModelID != nil { self.modelView.setActive(false) }
                return
            }
            self.applyCharacter()
        }
    }

    /// 换好的形象显示出来了：换形象途中就让它出场。
    private func characterShown() {
        guard switchingCharacter else { return }
        switchingCharacter = false
        guard PetSettings.enabled else { return }
        playEntrance()
    }

    /// 正在后台读的 3D 形象：读完前不重复发起；期间换成了别的形象，读完的结果作废。
    private var loadingModelID: String?

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
            if shownModelID == package.id {
                loadingModelID = nil
                petView.setPackage(nil)
                stage.show(modelView)
                modelView.setActive(PetSettings.enabled)
                characterShown()
                return
            }
            // 模型在后台读（VRM 一读就是好几秒，docs/desktop-pet/VRM.md §6），读好之前旧形象照常显示。
            guard loadingModelID != package.id else { return }
            loadingModelID = package.id
            PetModelView.loadModel(for: package) { [weak self] model in
                MainActor.assumeIsolated {
                    guard let self, self.loadingModelID == package.id else { return }
                    self.loadingModelID = nil
                    if self.isLent {
                        self.characterChangePending = true
                        return
                    }
                    self.showModel(package, model: model)
                }
            }
            return
        }
        loadingModelID = nil
        if shownModelID != nil {
            modelView.setPackage(nil, model: nil)
            modelView.setActive(false)
            shownModelID = nil
        }
        petView.setPackage(package)
        stage.show(petView)
        applySize()
        characterShown()
    }

    /// 后台读好的 3D 形象换上；读不出来回退 2D 占位。
    private func showModel(_ package: PetPackage, model: GLTFModel?) {
        guard let model else {
            if shownModelID != nil {
                modelView.setPackage(nil, model: nil)
                modelView.setActive(false)
                shownModelID = nil
            }
            petView.setPackage(nil)
            stage.show(petView)
            applySize()
            characterShown()
            return
        }
        modelView.setPackage(package, model: model)
        shownModelID = package.id
        petView.setPackage(nil)
        stage.show(modelView)
        modelView.setActive(PetSettings.enabled)
        applySize()
        characterShown()
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
