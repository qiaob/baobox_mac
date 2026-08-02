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
    /// 最近一次落笔的画布。撤销/重做只作用于它——多屏下"撤销全部屏幕"是反直觉的。
    private weak var activeView: ScreenDrawView?

    private init() {}

    // MARK: - 生命周期

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard !isRunning else { return }

        // 每屏一层画布。多屏各画各的，与截图 overlay 的处理一致。
        for screen in NSScreen.screens {
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

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let host = windows.first(where: { $0.targetScreen == screen }) ?? windows[0]

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
    }

    func stop() {
        // 先摘工具条（它是画布的子窗口），再关画布 —— 顺序反了会留下孤儿子窗口。
        toolbar?.close()
        toolbar = nil
        for window in windows {
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

    /// 穿透态：画布放行全部鼠标事件，笔迹还在，下面的 App 照常点。
    func togglePassThrough() {
        guard isRunning else { return }
        isPassThrough.toggle()
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

    func drawToolbarTogglePassThrough() {
        togglePassThrough()
    }

    func drawToolbarExit() {
        stop()
    }
}
