import AppKit

/// 一次 overlay 会话的目的：截图或录屏。选区交互完全一致，仅完成后的链路不同。
enum CaptureSessionMode {
    case capture
    case record
}

/// 截图会话协调：管理多屏 overlay、汇总完成/取消回调、驱动捕获与结果处理。
@MainActor
final class CaptureController {
    private var overlays: [CaptureOverlayWindow] = []
    private var isActive = false
    private var sessionMode: CaptureSessionMode = .capture
    /// 菜单场景的「含菜单整屏」冻结图（displayID → 图）。非空即冻结模式：框选/全屏/窗口都从它裁剪，
    /// 而非重新实时抓屏（那样会丢失已收起的菜单）。
    private var frozenScreens: [CGDirectDisplayID: CGImage] = [:]

    func begin() {
        begin(.capture)
    }

    /// 录屏入口：同一套选区交互（框选 / 点选窗口 / ⏎ 全屏）。
    func beginRecording() {
        guard !RecordingController.shared.isRecording else { return }
        begin(.record)
    }

    private func begin(_ mode: CaptureSessionMode) {
        guard !isActive else { return }

        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            OnboardingController.shared.present()
            return
        }

        isActive = true
        sessionMode = mode
        // 菜单场景：取「含菜单整屏」快照（截图快捷键在菜单打开时按下，已在收菜单前抓好）。仅截图、非录屏。
        frozenScreens = (mode == .capture) ? ScreenMenuSnapshot.take() : [:]
        let mouseAK = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let frozen = screen.displayID.flatMap { frozenScreens[$0] }
            let overlay = CaptureOverlayWindow(screen: screen, controller: self,
                                               recordMode: mode == .record, frozenBackground: frozen)
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }

        // 所有显示器休眠、外接屏热插拔的瞬间 NSScreen.screens 可能为空。此时没有任何
        // overlay 能回调 cancel/finish，isActive 会永久卡在 true，之后所有截图快捷键
        // 都被开头的 guard 挡掉 —— 截图功能到重启 App 为止彻底失效。
        guard !overlays.isEmpty else {
            isActive = false
            return
        }

        // 鼠标所在屏的 overlay 成为 key。
        let keyOverlay = overlays.first(where: { NSMouseInRect(mouseAK, $0.targetScreen.frame, false) })
            ?? overlays.first
        NSApp.activate(ignoringOtherApps: true)
        keyOverlay?.makeKeyAndOrderFront(nil)
        keyOverlay?.focusOverlayView()
    }

    func dismissOverlays() {
        for overlay in overlays {
            overlay.teardown()
            overlay.orderOut(nil)
        }
        overlays.removeAll()
        isActive = false
        frozenScreens = [:] // 释放含菜单大图
    }

    // MARK: - overlay 回调

    func cancel() {
        dismissOverlays()
    }

    func finishWindow(_ window: DetectedWindow) {
        if sessionMode == .record {
            // 录制不追踪窗口本身，录它当前所在矩形（与所在屏求交）。
            let rectAK = Geometry.appKitRect(fromCG: window.frameCG)
            let screens = NSScreen.screens
            guard let screen = WindowLayout.targetScreen(forWindowAK: rectAK,
                                                         screens: screens,
                                                         mouseScreen: nil) else {
                dismissOverlays()
                return
            }
            startRecording(rectAK.intersection(screen.frame), on: screen)
            return
        }
        // 冻结模式：从含菜单整屏裁剪窗口所在矩形（与所在屏求交），不重新实时抓。
        if !frozenScreens.isEmpty {
            let rectAK = Geometry.appKitRect(fromCG: window.frameCG)
            if let screen = NSScreen.screens.first(where: { s in
                   guard let id = s.displayID, frozenScreens[id] != nil else { return false }
                   return s.frame.intersects(rectAK)
               }),
               let displayID = screen.displayID, let frozen = frozenScreens[displayID],
               let cropped = Self.crop(frozen, rectAK: rectAK.intersection(screen.frame), screen: screen) {
                finishComposited(cropped, mode: .standard)
                return
            }
        }
        performCapture(target: .window(window.windowID), mode: .standard)
    }

    func finishRect(_ rectAK: NSRect, on screen: NSScreen, mode: ResultMode) {
        if sessionMode == .record {
            startRecording(rectAK, on: screen)
            return
        }
        guard let displayID = screen.displayID else {
            dismissOverlays()
            return
        }
        // 冻结模式：从含菜单整屏裁剪，不重新实时抓（否则丢失已收起的菜单）。
        if let frozen = frozenScreens[displayID] {
            if let cropped = Self.crop(frozen, rectAK: rectAK, screen: screen) {
                finishComposited(cropped, mode: mode)
            } else {
                dismissOverlays()
            }
            return
        }
        performCapture(target: .displayRect(displayID, rectAK: rectAK, screen: screen), mode: mode)
    }

    func finishFullScreen(on screen: NSScreen) {
        if sessionMode == .record {
            startRecording(screen.frame, on: screen)
            return
        }
        guard let displayID = screen.displayID else {
            dismissOverlays()
            return
        }
        // 冻结模式：整张含菜单快照即为全屏截图。
        if let frozen = frozenScreens[displayID] {
            finishComposited(frozen, mode: .standard)
            return
        }
        performCapture(target: .display(displayID), mode: .standard)
    }

    // MARK: - 录制

    private func startRecording(_ rectAK: NSRect, on screen: NSScreen) {
        dismissOverlays()
        Task { @MainActor in
            // 等 overlay 完全消隐，避免把蒙层录进开头几帧。
            try? await Task.sleep(nanoseconds: 120_000_000)
            do {
                try await RecordingController.shared.start(rectAK: rectAK, on: screen)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("screenshot.record.error.startFailed")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - 标注支持

    /// 冻结选区画面：overlay 不消隐，直接捕获并从画面中剔除自己的窗口（蒙层、工具条）。
    /// 标注期间底下的内容再怎么变，看到与导出的都是冻结那一刻。
    func freezeRegion(_ rectAK: NSRect, on screen: NSScreen,
                      alsoExcluding extra: Set<CGWindowID>) async throws -> CGImage {
        guard let displayID = screen.displayID else { throw CaptureError.targetNotFound }
        var excluded = Set(overlays.map { CGWindowID($0.windowNumber) })
        excluded.formUnion(extra)
        return try await CaptureEngine.capture(.displayRect(displayID, rectAK: rectAK, screen: screen),
                                               excludingWindowIDs: excluded)
    }

    /// 标注完成：直接用合成图走结果链路（不再重新捕获屏幕）。
    func finishComposited(_ image: CGImage, mode: ResultMode) {
        dismissOverlays()
        ScreenshotResultHandler.handle(image: image, mode: mode)
    }

    /// 贴图：把图像钉在原选区位置的置顶浮窗里。贴图不走 handle()，需单独记入历史。
    func finishPin(_ image: CGImage, at rectAK: NSRect) {
        dismissOverlays()
        ScreenshotHistoryStore.shared.record(image: image)
        PinnedImageWindow.pin(image: image, at: rectAK)
    }

    // MARK: - 捕获

    private func performCapture(target: CaptureTarget, mode: ResultMode) {
        dismissOverlays()
        Task { @MainActor in
            // 等 overlay 完全消隐，避免把蒙层截进去。
            try? await Task.sleep(nanoseconds: 80_000_000)
            do {
                let image = try await CaptureEngine.capture(target)
                ScreenshotResultHandler.handle(image: image, mode: mode)
            } catch {
                // overlay 已消隐，此刻 App 可能已不是前台；不先激活的话弹窗会藏在
                // 其他 App 窗口后面，而主线程已进入模态循环 —— 看起来就是「卡死」。
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("screenshot.error.captureFailed")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// 从整屏图裁剪 AK 全局 rect 对应的像素区域（原点左上，同 CaptureEngine.displayRect 口径）。
    static func crop(_ full: CGImage, rectAK: NSRect, screen: NSScreen) -> CGImage? {
        let scale = screen.backingScaleFactor
        let x = (rectAK.minX - screen.frame.minX) * scale
        let y = (screen.frame.maxY - rectAK.maxY) * scale
        let w = rectAK.width * scale
        let h = rectAK.height * scale
        let pixelRect = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        return full.cropping(to: pixelRect)
    }
}
