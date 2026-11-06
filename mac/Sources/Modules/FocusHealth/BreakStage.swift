import AppKit
import SwiftUI
import os

/// 休息画面的样子（由用户选的强度换算，见 FocusHealthController.stageStyle）。
enum BreakStageStyle {
    /// 不变暗、不拦截，卡片上点一下就能跳过（轻松档下手动「现在休息」用）。
    case gentle
    /// 所有屏变暗 + 拦截键鼠，长按 3 秒才能跳过（标准档）。
    case locked
    /// 同 locked，背景再模糊掉（严格档）。
    case lockedBlur
}

/// 一次休息画面的参数。
struct BreakRequest {
    var title: String
    var message: String
    var seconds: TimeInterval
    var style: BreakStageStyle
    /// 护眼：宠物侧身看远处；否则躺下休息。
    var lookAway: Bool
}

enum BreakOutcome {
    case completed, skipped, snoozed
}

/// 倒计时卡片的数据（SwiftUI 观察）。
@MainActor
final class BreakStageModel: ObservableObject {
    @Published var title = ""
    @Published var message = ""
    @Published var remaining: TimeInterval = 0
    /// 标准 / 严格：长按 3 秒才能跳过；gentle：点一下。
    @Published var holdToSkip = true
    /// 倒计时走完：「休息好啦」。
    @Published var finished = false
    /// 被戳 / 点了暗处时临时顶替标题的一句话。
    @Published var nudge: String?
    @Published var infoVisible = false
    var onSkip: () -> Void = {}
}

/// 休息画面（docs/focus-health/TECH_DESIGN.md §5）：宠物从原位走到屏幕中央、边走边变大，
/// 背景变暗、拦截键鼠（标准 / 严格档），倒计时走完起身伸懒腰再走回去。宠物没开时走回退画面。
@MainActor
final class BreakStageController {
    private static let log = Logger(subsystem: "com.baobox.app", category: "focushealth")
    private static let flightDuration: TimeInterval = 0.9
    private static let infoSize = NSSize(width: 440, height: 210)
    /// 等输入停下来最多等多久。
    private static let inputWait: TimeInterval = 15

    private enum Phase {
        case idle, waiting, flyingIn, resting, celebrating, flyingOut
    }

    /// 等待出场或在场（控制器据此顺延别的提醒）。
    private(set) var isBusy = false
    let model = BreakStageModel()

    private var phase: Phase = .idle
    /// 每次出场 +1：延时回调只认自己那一场，防止上一场的回调落到下一场头上。
    private var generation = 0
    private var request: BreakRequest?
    private var completion: ((BreakOutcome) -> Void)?
    private var pendingOutcome: BreakOutcome?
    private var backdrops: [BreakBackdropWindow] = []
    private var stageWindow: BreakStageWindow?
    private var infoView: NSView?
    private var loan: PetController.Loan?
    /// 到达中央后宠物视图在舞台窗里的位置。
    private var petRectInWindow = NSRect.zero
    private var targetScreen: NSScreen?
    private var endsAt = Date()
    private var restingSince = Date()
    private var waitStarted = Date()
    private var lastNudge = Date.distantPast
    private var pose = PetPose()
    private var tickTimer: Timer?
    private var poseTimer: Timer?
    private var animTimer: Timer?
    private var deadlineTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    /// 出场前的前台 App：撤下时若 Baobox 意外成了前台，把焦点还给它（探针实测 nonactivating 面板
    /// 成为 key 时前台不变、撤下后焦点自动回去；这里是兜底）。
    private var previousApp: NSRunningApplication?
    private let watchdog = MainThreadWatchdog()

    // MARK: - 出场

    func present(_ request: BreakRequest, completion: @escaping (BreakOutcome) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        generation += 1
        self.request = request
        self.completion = completion
        pendingOutcome = nil
        phase = .waiting
        waitStarted = Date()
        waitForQuietInput()
    }

    /// 正在拖拽 / 按着鼠标 / 打字：等这一下结束（最多 15 秒）再出来。
    private func waitForQuietInput() {
        guard phase == .waiting else { return }
        if UserActivity.isBusyWithInput(), Date().timeIntervalSince(waitStarted) < Self.inputWait {
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.waitForQuietInput()
                }
            }
            return
        }
        show()
    }

    private func show() {
        guard let request else {
            cleanup()
            return
        }
        let screen = Self.screenUnderMouse()
        targetScreen = screen
        model.title = request.title
        model.message = request.message
        model.remaining = request.seconds
        model.holdToSkip = request.style != .gentle
        model.finished = false
        model.nudge = nil
        model.infoVisible = false
        model.onSkip = { [weak self] in self?.finish(.skipped) }

        previousApp = NSWorkspace.shared.frontmostApplication
        // 休息期间其他模块的非重要通知攒着，结束后合并补呈。
        NotifyDND.shared.setSuppressed(true, token: FocusHealthController.breakToken)
        loan = PetController.shared.lendRenderView()
        let blocking = request.style != .gentle
        if blocking { buildBackdrops(fadeIn: true) }
        buildStageWindow(blocking: blocking)
        startTimers()
        scheduleDeadline(request.seconds + Self.flightDuration * 2 + 50)
        if blocking { watchdog.arm() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        Self.log.info("break shown: \(Int(request.seconds))s, style \(String(describing: request.style), privacy: .public), pet \(self.loan != nil)")
        flyIn()
    }

    // MARK: - 窗口

    private func buildBackdrops(fadeIn: Bool) {
        backdrops.forEach { $0.orderOut(nil) }
        // 严格档有没有宠物都是模糊（宠物关着时也不退成渐变，否则和标准档一模一样）；
        // 标准档有宠物是变暗，宠物关着才用设置里选的渐变 / 图片铺满。
        let style: BreakBackdropView.Style
        if request?.style == .lockedBlur {
            style = .blur
        } else if loan == nil {
            style = .fallback
        } else {
            style = .dim
        }
        backdrops = NSScreen.screens.map { screen in
            let primary = screen.frame == targetScreen?.frame
            let window = BreakBackdropWindow(screen: screen, style: style, showMini: !primary, model: model)
            window.onClick = { [weak self] in self?.nudge() }
            window.alphaValue = fadeIn ? 0 : 1
            window.orderFrontRegardless()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    window.animator().alphaValue = 1
                }
            }
            return window
        }
        stageWindow?.orderFrontRegardless()
    }

    private func buildStageWindow(blocking: Bool) {
        guard let screen = targetScreen else { return }
        let window = BreakStageWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        // level 必须先于 setFrame 设置（照截图 overlay：普通级别会被菜单栏约束挤下去）。
        // 不要设 isFloatingPanel：它的 setter 会把 level 改回 .floating(3)，舞台就掉到暗幕（1000）下面，
        // 宠物被一起调暗 / 模糊、「长按跳过」也按不到（2026-11-06 真机踩到）。
        window.level = blocking ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) : .statusBar
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.swallowsKeys = blocking
        window.onClick = { [weak self] in self?.poke() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = content

        if let loan {
            // 起点：宠物在桌面上的位置与大小，渲染视图铺满窗口。
            window.setFrame(loan.frame, display: false)
            loan.view.frame = content.bounds
            loan.view.autoresizingMask = [.width, .height]
            content.addSubview(loan.view)
        } else {
            let info = fallbackInfoRect(on: screen)
            window.setFrame(info, display: false)
            attachInfo(frame: NSRect(origin: .zero, size: info.size), in: window)
        }
        window.orderFrontRegardless()
        if blocking { window.makeKey() }
        stageWindow = window
    }

    /// 中央大宠物 + 下方卡片的位置（屏幕坐标）。
    private func layout(on screen: NSScreen) -> (pet: NSRect, info: NSRect, union: NSRect) {
        let frame = screen.frame
        // 3D 形象实时渲染，放大照样清晰；2D 帧图只有几十像素，超过原尺寸 3 倍就糊。
        let maxSide: CGFloat = (loan?.is3D ?? true) ? 520 : (loan?.frame.height ?? 104) * 3
        let side = min(frame.height * 0.42, maxSide)
        let info = Self.infoSize
        let overlap: CGFloat = 12
        let blockHeight = side + info.height - overlap
        let bottom = frame.midY - blockHeight / 2
        let infoRect = NSRect(x: frame.midX - info.width / 2, y: bottom, width: info.width, height: info.height)
        let petRect = NSRect(x: frame.midX - side / 2, y: infoRect.maxY - overlap, width: side, height: side)
        return (petRect, infoRect, petRect.union(infoRect))
    }

    private func fallbackInfoRect(on screen: NSScreen) -> NSRect {
        let size = Self.infoSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 窗口显式传进来：宠物关着时卡片在 stageWindow 赋值之前就要挂上（第一版写成
    /// `stageWindow?.contentView?.addSubview` 挂了个空，宠物关着时整屏只剩纯色、没有一个字，2026-11-06 真机踩到）。
    private func attachInfo(frame: NSRect, in window: NSWindow) {
        infoView?.removeFromSuperview()
        let hosting = BreakInfoHostingView(rootView: BreakInfoView(model: model))
        hosting.frame = frame
        window.contentView?.addSubview(hosting)
        infoView = hosting
    }

    // MARK: - 飞过去、休息、飞回来

    private func flyIn() {
        guard let window = stageWindow, let screen = targetScreen else { return }
        guard let loan else {
            beginResting()
            return
        }
        let target = layout(on: screen).pet
        phase = .flyingIn
        pose = PetPose()
        pose.state = .wander
        pose.facingLeft = target.midX < loan.frame.midX
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(target, display: true)
            arrive()
            return
        }
        animate(window, from: loan.frame, to: target, duration: Self.flightDuration) { [weak self] in
            self?.arrive()
        }
    }

    /// 到了中央：窗口扩成「宠物 + 卡片」，卡片淡入，倒计时从这一刻开始。
    private func arrive() {
        guard let screen = targetScreen else { return }
        placeArrived(on: screen)
        beginResting()
    }

    private func placeArrived(on screen: NSScreen) {
        guard let window = stageWindow, let loan else { return }
        let (pet, info, union) = layout(on: screen)
        // 先关掉跟随缩放再扩窗口，宠物视图不会被拉伸一下。
        loan.view.autoresizingMask = []
        window.setFrame(union, display: false)
        loan.view.frame = pet.offsetBy(dx: -union.minX, dy: -union.minY)
        petRectInWindow = loan.view.frame
        attachInfo(frame: info.offsetBy(dx: -union.minX, dy: -union.minY), in: window)
        window.display()
    }

    private func beginResting() {
        guard let request else { return }
        phase = .resting
        restingSince = Date()
        endsAt = Date().addingTimeInterval(request.seconds)
        model.remaining = request.seconds
        model.infoVisible = true
    }

    private func tickCountdown() {
        guard phase == .resting else { return }
        let left = max(0, endsAt.timeIntervalSinceNow)
        if abs(model.remaining - left) >= 0.2 { model.remaining = left }
        if left <= 0 { celebrate() }
    }

    /// 倒计时走完：「休息好啦」。3D 形象从睡姿回待机时会自动播「起身 + 伸懒腰」。
    private func celebrate() {
        phase = .celebrating
        model.remaining = 0
        model.finished = true
        let pause: TimeInterval = loan != nil ? 2.6 : 1.4
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.finish(.completed)
            }
        }
    }

    /// 结束（完成 / 跳过 / 推迟）：卡片收起、暗幕淡出、宠物飞回原位，然后归还视图、回调结果。
    func finish(_ outcome: BreakOutcome) {
        guard isBusy else { return }
        switch phase {
        case .idle, .waiting:
            cleanup()
            deliver(outcome)
            return
        case .flyingOut:
            return
        case .flyingIn, .resting, .celebrating:
            break
        }
        let arrived = infoView != nil && loan != nil
        animTimer?.invalidate()
        animTimer = nil
        phase = .flyingOut
        pendingOutcome = outcome
        model.infoVisible = false
        fadeOutBackdrops()
        guard let window = stageWindow, let loan else {
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.completeTeardown()
                }
            }
            return
        }
        // 窗口收回到宠物那一块，视图重新铺满窗口，再飞回原位。
        let current = arrived ? petRectInWindow.offsetBy(dx: window.frame.minX, dy: window.frame.minY) : window.frame
        infoView?.removeFromSuperview()
        infoView = nil
        window.setFrame(current, display: false)
        loan.view.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: current.size)
        loan.view.autoresizingMask = [.width, .height]
        pose.facingLeft = loan.frame.midX < current.midX
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            completeTeardown()
            return
        }
        animate(window, from: current, to: loan.frame, duration: Self.flightDuration) { [weak self] in
            self?.completeTeardown()
        }
    }

    /// 退出 App、截止看门狗：不走动画，立刻撤下。
    func forceTeardown() {
        guard isBusy else { return }
        let outcome = pendingOutcome ?? .skipped
        cleanup()
        deliver(outcome)
    }

    private func completeTeardown() {
        let outcome = pendingOutcome ?? .completed
        cleanup()
        deliver(outcome)
    }

    private func cleanup() {
        animTimer?.invalidate()
        animTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        poseTimer?.invalidate()
        poseTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        watchdog.disarm()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        // 先撤勿扰再还宠物：否则引擎还按勿扰让它睡着，还回去先躺下再爬起来。
        NotifyDND.shared.setSuppressed(false, token: FocusHealthController.breakToken)
        if let loan {
            loan.view.removeFromSuperview()
            PetController.shared.returnRenderView()
        }
        loan = nil
        infoView?.removeFromSuperview()
        infoView = nil
        stageWindow?.orderOut(nil)
        stageWindow = nil
        backdrops.forEach { $0.orderOut(nil) }
        backdrops = []
        let me = ProcessInfo.processInfo.processIdentifier
        if let previous = previousApp, previous.processIdentifier != me, !previous.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == me {
            previous.activate(options: [])
        }
        previousApp = nil
        phase = .idle
        request = nil
        isBusy = false
    }

    private func deliver(_ outcome: BreakOutcome) {
        let completion = self.completion
        self.completion = nil
        pendingOutcome = nil
        completion?(outcome)
    }

    private func fadeOutBackdrops() {
        for window in backdrops {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window.animator().alphaValue = 0
            }
        }
    }

    // MARK: - 姿态（30fps 推送；2D 帧动画靠它走）

    private func pushPose() {
        guard loan != nil else { return }
        let now = Date()
        pose.time = now.timeIntervalSinceReferenceDate
        switch phase {
        case .flyingIn, .flyingOut:
            pose.state = .wander
            pose.walkPhase += 9.0 / 30.0
            pose.attentive = false
            pose.lying = false
            pose.eyesClosed = false
            pose.bob = 0
        case .resting:
            if now.timeIntervalSince(restingSince) < 1.2 {
                // 先转过来看你一眼。
                pose.state = .idle
                pose.attentive = true
            } else if request?.lookAway == true {
                // 护眼：侧过身去看远处。
                pose.state = .idle
                pose.attentive = false
                pose.facingLeft = false
            } else {
                pose.state = .sleep
            }
            pose.lying = pose.state == .sleep
            pose.eyesClosed = pose.state == .sleep
            pose.bob = pose.state == .idle ? CGFloat(sin(pose.time * 1.7)) * 1.4 : 0
        case .celebrating:
            pose.state = .idle
            pose.attentive = true
            pose.lying = false
            pose.eyesClosed = false
            pose.bob = CGFloat(sin(pose.time * 1.7)) * 1.4
        case .idle, .waiting:
            return
        }
        PetController.shared.setLentPose(pose)
    }

    // MARK: - 互动

    /// 点了大宠物：它动一下，告诉你还剩多久。
    private func poke() {
        guard phase == .resting else { return }
        PetController.shared.performLent("poke")
        let left = model.remaining
        showNudge(left < 60 ? L("focus.break.almost") : L("focus.break.pokeLine \(FocusText.minutesLeft(left))"))
    }

    /// 点了暗处想接着干活：宠物摇摇头。
    private func nudge() {
        guard phase == .resting, Date().timeIntervalSince(lastNudge) > 2.5 else { return }
        lastNudge = Date()
        PetController.shared.performLent("poke")
        showNudge(L("focus.break.nudge"))
    }

    private func showNudge(_ text: String) {
        model.nudge = text
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, self.model.nudge == text else { return }
                self.model.nudge = nil
            }
        }
    }

    // MARK: - 定时器与看门狗

    private func startTimers() {
        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCountdown() }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
        if loan != nil {
            let poseTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushPose() }
            }
            RunLoop.main.add(poseTimer, forMode: .common)
            self.poseTimer = poseTimer
        }
    }

    /// 截止看门狗：到点还没撤（动画卡住等），强制撤下。
    private func scheduleDeadline(_ seconds: TimeInterval) {
        deadlineTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.error("break stage passed its deadline; tearing down")
                self?.forceTeardown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func animate(_ window: NSWindow, from: NSRect, to: NSRect, duration: TimeInterval,
                         completion: @escaping () -> Void) {
        animTimer?.invalidate()
        let start = Date()
        window.setFrame(from, display: true)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] timer in
            MainActor.assumeIsolated {
                guard let self, let window else {
                    timer.invalidate()
                    return
                }
                let t = min(Date().timeIntervalSince(start) / duration, 1)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                window.setFrame(Self.interpolate(from, to, CGFloat(eased)), display: true)
                if t >= 1 {
                    timer.invalidate()
                    self.animTimer = nil
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private static func interpolate(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// 插拔显示器：重建暗幕；舞台所在的屏没了就挪到主屏中央。
    private func screensChanged() {
        guard isBusy, phase != .waiting, phase != .idle else { return }
        let screens = NSScreen.screens
        if let target = targetScreen, !screens.contains(where: { $0.frame == target.frame }) {
            targetScreen = NSScreen.main ?? screens.first
        }
        if let request, request.style != .gentle { buildBackdrops(fadeIn: false) }
        guard let screen = targetScreen else { return }
        if phase == .resting || phase == .celebrating {
            if loan != nil {
                placeArrived(on: screen)
            } else {
                stageWindow?.setFrame(fallbackInfoRect(on: screen), display: true)
            }
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - 窗口类

/// 舞台窗：装宠物渲染视图 + 倒计时卡片。标准 / 严格档成为 key 窗口（nonactivating，不激活 App）吞掉键盘，
/// 快捷键一律在这里截住 —— 否则 ⌘Q 会走 Baobox 的主菜单把整个 App 退出。
final class BreakStageWindow: NSPanel {
    /// 标准 / 严格档：出场即成为 key 并吞掉键盘；轻松档不主动抢 key，只在点按钮时临时成为 key。
    var swallowsKeys = true
    /// 点到宠物（渲染视图把鼠标事件转给窗口）或窗口里的空白处。
    var onClick: (() -> Void)?

    // 始终可成为 key：SwiftUI 按钮在不能成为 key 的面板里点不动（同桌面宠物的气泡窗）。nonactivating，不激活 App。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if !swallowsKeys { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        swallowsKeys ? true : super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {}

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {}
}

/// 暗幕窗：每屏一张、铺满整屏（含菜单栏），吞掉鼠标；点一下 = 戳宠物。副屏中央显示小字倒计时。
final class BreakBackdropWindow: NSPanel {
    var onClick: (() -> Void)?

    init(screen: NSScreen, style: BreakBackdropView.Style, showMini: Bool, model: BreakStageModel) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 同舞台窗：不设 isFloatingPanel（会把 level 改回 .floating，暗幕就盖不住菜单栏和 Dock）。
        level = .screenSaver
        setFrame(screen.frame, display: false)
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        let view = BreakBackdropView(frame: NSRect(origin: .zero, size: screen.frame.size), style: style)
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
        if showMini {
            let mini = NSHostingView(rootView: BreakMiniView(model: model))
            let size = NSSize(width: 320, height: 120)
            mini.frame = NSRect(x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2,
                                width: size.width, height: size.height)
            view.addSubview(mini)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 暗幕本体：有宠物时半透明变暗（严格档再加背景模糊）；宠物关闭时是回退画面（渐变色或自选图片）。
final class BreakBackdropView: NSView {
    enum Style {
        case dim, blur, fallback
    }

    var onClick: (() -> Void)?

    init(frame: NSRect, style: Style) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        guard let layer else { return }
        switch style {
        case .dim:
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        case .blur:
            installBlur()
        case .fallback:
            Self.installFallback(on: layer, bounds: bounds)
        }
    }

    /// 严格档：把窗口背后的内容（别的 App、桌面）实时模糊掉，再压一层暗色。
    /// 系统开了「减少透明度」时，NSVisualEffectView 自己会退成不透明底。
    private func installBlur() {
        let effect = NSVisualEffectView(frame: bounds)
        effect.blendingMode = .behindWindow
        effect.material = .fullScreenUI
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        let shade = NSView(frame: bounds)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
    }

    /// 点在暗幕任何位置（含模糊层、副屏倒计时）都算点在暗幕上：子视图不接鼠标，
    /// 否则点击落到子视图上，「首击即生效」与「戳宠物」都会失灵。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    required init?(coder: NSCoder) {
        nil
    }

    private static func installFallback(on layer: CALayer, bounds: NSRect) {
        if FocusHealthSettings.backdrop == "image", let path = FocusHealthSettings.backdropImagePath,
           let image = NSImage(contentsOfFile: path) {
            layer.backgroundColor = NSColor.black.cgColor
            let picture = CALayer()
            picture.frame = bounds
            picture.contents = image
            picture.contentsGravity = .resizeAspectFill
            picture.masksToBounds = true
            picture.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.addSublayer(picture)
            // 压一层暗色，卡片上的字才看得清。
            let shade = CALayer()
            shade.frame = bounds
            shade.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            shade.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.addSublayer(shade)
            return
        }
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = gradientColors(FocusHealthSettings.backdrop)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(gradient)
    }

    /// 三款渐变：青绿（品牌色 #17A398）、暮色、森林。
    private static func gradientColors(_ name: String) -> [CGColor] {
        switch name {
        case "dusk":
            return [NSColor(srgbRed: 0.23, green: 0.24, blue: 0.56, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.60, green: 0.31, blue: 0.59, alpha: 1).cgColor]
        case "forest":
            return [NSColor(srgbRed: 0.18, green: 0.42, blue: 0.31, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.66, green: 0.78, blue: 0.53, alpha: 1).cgColor]
        default:
            return [NSColor(srgbRed: 0.055, green: 0.37, blue: 0.34, alpha: 1).cgColor,
                    NSColor(srgbRed: 0.09, green: 0.64, blue: 0.60, alpha: 1).cgColor]
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) {}
}

/// 卡片的宿主：首击即生效（Baobox 平时不是前台 App，不用先点一下激活窗口）。
final class BreakInfoHostingView: NSHostingView<BreakInfoView> {
    required init(rootView: BreakInfoView) {
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 主线程看门狗

/// 拦截键鼠期间盯主线程（技术设计 §5.5）：主线程卡死超过 20 秒就结束进程 —— 窗口随进程消失，
/// 绝不留下一块撤不掉、又吞键鼠的遮罩。
final class MainThreadWatchdog: @unchecked Sendable {
    private static let limit: TimeInterval = 20
    private let lock = NSLock()
    private var armed = false
    private var lastBeat = Date()
    private var source: DispatchSourceTimer?
    private var beatTimer: Timer?

    @MainActor
    func arm() {
        disarm()
        lock.lock()
        armed = true
        lastBeat = Date()
        lock.unlock()
        let beat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(beat, forMode: .common)
        beatTimer = beat
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        self.source = source
    }

    @MainActor
    func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
        beatTimer?.invalidate()
        beatTimer = nil
        source?.cancel()
        source = nil
    }

    private func beat() {
        lock.lock()
        lastBeat = Date()
        lock.unlock()
    }

    private func check() {
        lock.lock()
        let stuck = armed && Date().timeIntervalSince(lastBeat) > Self.limit
        lock.unlock()
        guard stuck else { return }
        Logger(subsystem: "com.baobox.app", category: "focushealth")
            .fault("main thread unresponsive for 20s while the break stage blocks input; terminating")
        abort()
    }
}
