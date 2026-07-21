import AppKit

/// 截图会话协调：管理多屏 overlay、汇总完成/取消回调、驱动捕获与结果处理。
@MainActor
final class CaptureController {
    private var overlays: [CaptureOverlayWindow] = []
    private var isActive = false

    func begin() {
        guard !isActive else { return }

        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            OnboardingController.shared.present()
            return
        }

        isActive = true
        let mouseAK = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let overlay = CaptureOverlayWindow(screen: screen, controller: self)
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
    }

    // MARK: - overlay 回调

    func cancel() {
        dismissOverlays()
    }

    func finishWindow(_ window: DetectedWindow) {
        performCapture(target: .window(window.windowID), mode: .standard)
    }

    func finishRect(_ rectAK: NSRect, on screen: NSScreen, mode: ResultMode) {
        guard let displayID = screen.displayID else {
            dismissOverlays()
            return
        }
        performCapture(target: .displayRect(displayID, rectAK: rectAK, screen: screen), mode: mode)
    }

    func finishFullScreen(on screen: NSScreen) {
        guard let displayID = screen.displayID else {
            dismissOverlays()
            return
        }
        performCapture(target: .display(displayID), mode: .standard)
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

    /// 贴图：把图像钉在原选区位置的置顶浮窗里。
    func finishPin(_ image: CGImage, at rectAK: NSRect) {
        dismissOverlays()
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
}
