import AppKit

/// 屏幕标注画笔：在屏幕最上层铺一层透明画布，直接在实时画面上圈画。
///
/// 讲解、演示、录屏时用——先截图再标注的节奏是断的，这个功能要的是「边说边画」。
/// 与截图标注共用绘制引擎（`AnnotationRenderer` 那套），换的只是画布。
///
/// 两个状态：
/// - **绘制态**：画布吃掉鼠标事件，本 App 被激活（这样 ⌘Z / Esc / ⌫ 才收得到）；
/// - **穿透态**：画布 `ignoresMouseEvents`，笔迹留在屏幕上但下面的 App 照常操作。
@MainActor
final class ScreenDrawController {
    static let shared = ScreenDrawController()

    private(set) var isRunning = false
    private(set) var isPassThrough = false

    private var windows: [ScreenDrawOverlayWindow] = []
    private var toolbar: ScreenDrawToolbar?
    /// 本 App 失焦的观察者：失焦即自动转穿透，见 `appDidResignActive()`。
    private var resignObserver: NSObjectProtocol?
    /// 最近一次落笔的画布。撤销/重做只作用于它——多屏下"撤销全部屏幕"是反直觉的。
    private weak var activeView: ScreenDrawView?

    private init() {}

    // MARK: - 生命周期

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard !isRunning else { return }

        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        // 作用范围由设置决定：默认只铺鼠标所在屏，另一块屏完全不受影响（可以边画边在那边操作）；
        // 选「所有屏幕」才每屏一层。多屏各画各的，与截图 overlay 的处理一致。
        let targets: [NSScreen] = ScreenshotSettings.drawScreenScope == .all
            ? NSScreen.screens
            : [mouseScreen].compactMap { $0 }
        for screen in targets {
            let window = ScreenDrawOverlayWindow(screen: screen, controller: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        // 所有显示器休眠 / 外接屏热插拔的瞬间 NSScreen.screens 可能为空。没有画布就没有
        // 任何退出入口，isRunning 会永久卡在 true —— 与截图 overlay 同一个坑，同样兜住。
        guard !windows.isEmpty else {
            windows.removeAll()
            return
        }
        isRunning = true
        isPassThrough = false

        let host = windows.first(where: { $0.targetScreen == mouseScreen }) ?? windows[0]
        let screen = host.targetScreen

        let toolbar = ScreenDrawToolbar()
        toolbar.delegate = self
        toolbar.show(on: screen, attachedTo: host)
        self.toolbar = toolbar

        applyStyleToViews { view in
            view.currentTool = toolbar.selectedTool
            view.style = toolbar.style
        }

        // 必须激活：Esc / ⌘Z / ⌫ 都要靠键盘，不激活就收不到。
        NSApp.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)
        host.focusDrawView()

        // 失焦保险：⌘Tab 切走、点通知、切 Space 之后，画布还盖在最上层吃掉全部点击 ——
        // 用户既点不到切过去的 App，也点不到菜单栏，键盘也不再进画布（Esc / ⌘Z 全失灵），
        // 观感就是「卡死」。失焦即自动转穿透，笔迹留着、机器照常用。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ScreenDrawController.shared.appDidResignActive()
            }
        }
    }

    func stop() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        // 先摘工具条（它是画布的子窗口），再关画布 —— 顺序反了会留下孤儿子窗口。
        toolbar?.close()
        toolbar = nil
        for window in windows {
            window.drawView.endTextEditing(cancel: true)
            window.orderOut(nil)
        }
        windows.removeAll()
        activeView = nil
        isRunning = false
        isPassThrough = false
    }

    // MARK: - 状态

    func viewBecameActive(_ view: ScreenDrawView) {
        activeView = view
    }

    /// 本 App 失焦 → 自动转穿透（见 `start()` 里装观察者时的说明）。
    private func appDidResignActive() {
        guard isRunning, !isPassThrough else { return }
        setPassThrough(true)
    }

    /// 穿透态：画布放行全部鼠标事件，笔迹还在，下面的 App 照常点。
    func togglePassThrough() {
        setPassThrough(!isPassThrough)
    }

    func setPassThrough(_ on: Bool) {
        guard isRunning, on != isPassThrough else { return }
        if on {
            // 进入穿透前提交进行中的文字 —— 半截输入框在穿透态既改不了也点不到。
            for window in windows { window.drawView.endTextEditing(cancel: false) }
        }
        isPassThrough = on
        for window in windows {
            window.setPassThrough(isPassThrough)
        }
        toolbar?.setPassThrough(isPassThrough)
        if !isPassThrough {
            // 回到绘制态要把键盘焦点抢回来，否则 ⌘Z / Esc 失灵。
            NSApp.activate(ignoringOtherApps: true)
            let host = (toolbar?.panel.parent as? ScreenDrawOverlayWindow) ?? windows.first
            host?.makeKeyAndOrderFront(nil)
            host?.focusDrawView()
        }
    }

    func clearAll() {
        for window in windows {
            window.drawView.clear()
        }
    }

    /// 保存画板：抓「最近落笔那块屏」的整屏画面 —— 笔迹本来就显示在屏上，自然在画面里；
    /// 工具条窗口用捕获排除机制剔掉，全程不隐藏任何东西、无闪烁。
    /// 默认静默走标准结果链（复制 + 按设置落盘 + 入历史），标注不中断；
    /// 设置里开了「保存后弹预览窗」则结束标注并进入预览（复制/保存/贴图/取字）。
    func saveCanvas() {
        guard isRunning else { return }
        // 半截输入框不该出现在成品里，先落成笔迹。
        for window in windows { window.drawView.endTextEditing(cancel: false) }

        // 抓屏需要屏幕录制权限（画笔本身不需要）。先转穿透，否则引导窗被画布挡住点不到。
        guard Permissions.hasScreenRecording else {
            setPassThrough(true)
            Permissions.requestScreenRecording()
            OnboardingController.shared.present()
            return
        }

        let host = (activeView?.window as? ScreenDrawOverlayWindow)
            ?? (toolbar?.panel.parent as? ScreenDrawOverlayWindow)
            ?? windows.first
        guard let host, let displayID = host.targetScreen.displayID else { return }
        let screen = host.targetScreen
        var excluded: Set<CGWindowID> = []
        if let toolbar { excluded.insert(CGWindowID(toolbar.panel.windowNumber)) }

        Task { @MainActor in
            do {
                let image = try await CaptureEngine.capture(
                    .displayRect(displayID, rectAK: screen.frame, screen: screen),
                    excludingWindowIDs: excluded)
                if ScreenshotSettings.drawSavePreview {
                    self.stop()
                    ScreenshotResultHandler.presentPreview(image: image,
                                                           title: L("screendraw.preview.title"))
                } else {
                    ScreenshotResultHandler.handle(image: image, mode: .standard)
                    // 静默不等于无感知：工具条下方浮一条提示，不然不知道存没存上。
                    self.toolbar?.showStatus(ScreenshotSettings.autoSave
                        ? L("screendraw.status.savedCopied")
                        : L("screendraw.status.copied"))
                }
            } catch {
                // 不用 NSAlert：画布吃掉全屏点击，模态弹窗点不到 —— 浮条提示错误即可。
                self.toolbar?.showStatus(L("screendraw.status.saveFailed \(error.localizedDescription)"),
                                         isError: true)
            }
        }
    }

    private func applyStyleToViews(_ body: (ScreenDrawView) -> Void) {
        for window in windows {
            body(window.drawView)
        }
    }
}

// MARK: - 工具条回调

extension ScreenDrawController: ScreenDrawToolbarDelegate {
    func drawToolbarDidSelect(_ tool: AnnotationTool) {
        applyStyleToViews { $0.currentTool = tool }
    }

    func drawToolbarDidChangeStyle(_ style: AnnotationStyle) {
        applyStyleToViews { $0.style = style }
    }

    func drawToolbarUndo() {
        (activeView ?? windows.first?.drawView)?.undo()
    }

    func drawToolbarRedo() {
        (activeView ?? windows.first?.drawView)?.redo()
    }

    func drawToolbarClear() {
        clearAll()
    }

    func drawToolbarSave() {
        saveCanvas()
    }

    func drawToolbarTogglePassThrough() {
        togglePassThrough()
    }

    func drawToolbarExit() {
        stop()
    }
}
