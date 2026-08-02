import AppKit

/// 长截屏（滚动拼接）：选区固定不动，用户自己滚动页面，这里按固定节奏抓帧，
/// 交给 `ScrollingCaptureStitcher` 按纵向重叠拼成一张长图。
///
/// 全程不激活本 App（HUD 与边框都是 `nonactivatingPanel`），否则用户一点「完成」
/// 焦点就跑了、滚不动目标窗口。抓帧用同步的 `CGWindowListCreateImage`：
/// 走 `optionOnScreenBelowWindow` 以边框窗为界，天然把自己的边框与 HUD 排除在画面外。
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private(set) var isRunning = false

    private var rectAK: NSRect = .zero
    private var scale: CGFloat = 2
    private var startedAt = Date()

    private var timer: Timer?
    private var hud: ScrollingCaptureHUD?
    private var border: ScrollingCaptureBorderWindow?
    private var stitcher: ScrollingCaptureStitcher?
    /// 上一帧还在后台拼接时跳过这一拍，避免积压。
    private var inFlight = false

    /// 拼接队列：串行，`append` 与最终 `compose` 都走它，compose 天然排在在途帧之后。
    private let queue = DispatchQueue(label: "com.baobox.screenshot.scrollingCapture", qos: .userInitiated)

    private let interval: TimeInterval = 0.12
    /// 保险丝：忘了点「完成」也不会无限抓下去。
    private let maxDuration: TimeInterval = 300

    private init() {}

    // MARK: - 生命周期

    func start(rectAK rect: NSRect, on screen: NSScreen) {
        guard !isRunning else { return }
        // 太窄太矮的选区没有滚动拼接的意义，且行特征不足以稳定匹配。
        guard rect.width >= 40, rect.height >= 60 else { return }

        isRunning = true
        rectAK = rect
        scale = max(screen.backingScaleFactor, 1)
        startedAt = Date()
        stitcher = ScrollingCaptureStitcher()

        // 边框在下、HUD 在上（层级固定：floating < statusBar），抓帧时以边框窗为界一并排除。
        let border = ScrollingCaptureBorderWindow(rectAK: rect)
        border.orderFrontRegardless()
        self.border = border

        let hud = ScrollingCaptureHUD(rectAK: rect, on: screen,
                                      onFinish: { [weak self] in self?.finish() },
                                      onCancel: { [weak self] in self?.cancel() })
        hud.orderFrontRegardless()
        self.hud = hud

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 首帧交给定时器的第一拍：边框窗刚 orderFront，还没真正上屏时
        // `optionOnScreenBelowWindow` 抓不到东西，等一拍最稳。
    }

    /// 结束拼接并进入预览窗（先记历史、按设置落盘，再由用户决定复制/贴图/取字）。
    func finish() {
        guard isRunning, let stitcher else { return }
        teardown()
        queue.async {
            let image = stitcher.compose()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let image else {
                        Self.reportEmpty()
                        return
                    }
                    Self.presentResult(image)
                }
            }
        }
    }

    /// 拼接结果先入历史、按设置落盘 —— 预览窗误关也不丢图；不再自动复制，
    /// 长图往往要先检查有无错位，预览窗里的「复制」才是明确意图。
    private static func presentResult(_ image: CGImage) {
        ScreenshotHistoryStore.shared.record(image: image)
        if ScreenshotSettings.autoSave {
            ScreenshotResultHandler.save(image: image)
        }
        ImagePreviewWindow.present(
            image: image,
            title: L("screenshot.longshot.preview.title"),
            actions: [
                ImagePreviewWindow.Action(title: L("screenshot.longshot.preview.save")) {
                    ScreenshotResultHandler.save(image: image)
                },
                ImagePreviewWindow.Action(title: L("screenshot.longshot.preview.ocr")) {
                    OCRResultWindow.present(image: image)
                },
                ImagePreviewWindow.Action(title: L("screenshot.longshot.preview.pin"), closesWindow: true) {
                    ScreenshotTool.pinCentered(image)
                },
                ImagePreviewWindow.Action(title: L("screenshot.longshot.preview.copy"),
                                          isDefault: true, closesWindow: true) {
                    ScreenshotResultHandler.copy(image: image)
                }
            ])
    }

    /// 放弃本次长截屏，不产出任何结果。
    func cancel() {
        guard isRunning else { return }
        teardown()
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
        hud = nil
        border?.orderOut(nil)
        border = nil
        stitcher = nil
        inFlight = false
        isRunning = false
    }

    // MARK: - 抓帧

    private func tick() {
        guard isRunning, let stitcher else { return }
        if Date().timeIntervalSince(startedAt) > maxDuration {
            finish()
            return
        }
        guard !inFlight, let frame = captureFrame() else { return }

        inFlight = true
        queue.async { [weak self] in
            let result = stitcher.append(frame)
            let rows = stitcher.totalRows
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.inFlight = false
                    self.hud?.update(points: Int(CGFloat(rows) / self.scale))
                    if case .full = result { self.finish() }
                }
            }
        }
    }

    private func captureFrame() -> CGImage? {
        guard let border else { return nil }
        let boundsCG = Geometry.cgRect(fromAppKit: rectAK)
        // 抓「边框窗以下」的全部窗口 —— 边框与其上的 HUD 都不会进画面。
        return CGWindowListCreateImage(boundsCG, .optionOnScreenBelowWindow,
                                       CGWindowID(border.windowNumber), .bestResolution)
    }

    private static func reportEmpty() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("screenshot.longshot.error.title")
        alert.informativeText = L("screenshot.longshot.error.message")
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - 拼接范围边框

/// 圈出正在拼接的区域：accent 色描边，完全穿透鼠标事件（用户要在下面滚页面）。
/// 描边画在选区外沿，且本窗口已被抓帧排除，不会进入长图。
@MainActor
private final class ScrollingCaptureBorderWindow: NSPanel {
    init(rectAK: NSRect) {
        super.init(contentRect: rectAK.insetBy(dx: -3, dy: -3),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView = BorderView()
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0, blue: 0xB8 / 255.0, alpha: 0.95).setStroke()
            path.stroke()
        }
    }
}

// MARK: - 长截屏控制条

/// 拼接中的悬浮控制条：已拼接高度 + 完成 / 取消。摆位与录制控制条一致，可拖动。
@MainActor
private final class ScrollingCaptureHUD: NSPanel {
    private static let size = NSSize(width: 250, height: 34)

    private let heightLabel = NSTextField(labelWithString: "")
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(rectAK: NSRect, on screen: NSScreen,
         onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        let origin = Self.placement(for: rectAK, on: screen)
        super.init(contentRect: NSRect(origin: origin, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        content.layer?.cornerRadius = Self.size.height / 2

        let icon = NSImageView(frame: NSRect(x: 13, y: 9, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down",
                             accessibilityDescription: L("screenshot.longshot.hud.hint"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0,
                                        blue: 0xB8 / 255.0, alpha: 1)
        content.addSubview(icon)

        heightLabel.frame = NSRect(x: 36, y: 8, width: 116, height: 18)
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        heightLabel.textColor = .white
        heightLabel.toolTip = L("screenshot.longshot.hud.hint")
        content.addSubview(heightLabel)

        let finish = HUDTextButton(frame: NSRect(x: 156, y: 5, width: 56, height: 24))
        finish.isBordered = false
        finish.wantsLayer = true
        finish.layer?.backgroundColor = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0,
                                                blue: 0xB8 / 255.0, alpha: 1).cgColor
        finish.layer?.cornerRadius = 12
        finish.attributedTitle = NSAttributedString(
            string: L("screenshot.longshot.hud.finish"),
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        finish.target = self
        finish.action = #selector(finishPressed)
        content.addSubview(finish)

        let cancel = HUDTextButton(frame: NSRect(x: 216, y: 5, width: 26, height: 24))
        cancel.bezelStyle = .regularSquare
        cancel.isBordered = false
        cancel.title = ""
        cancel.imagePosition = .imageOnly
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("common.cancel"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        cancel.contentTintColor = NSColor(white: 1, alpha: 0.65)
        cancel.toolTip = L("common.cancel")
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)

        contentView = content
        update(points: 0)
    }

    /// 刷新已拼接高度（点，不是像素 —— 与用户看到的选区同一把尺子）。
    func update(points: Int) {
        heightLabel.stringValue = L("screenshot.longshot.hud.height \(points)")
    }

    /// 与录制控制条同一套摆位：选区下方右对齐 → 上方 → 选区内部右下角。
    private static func placement(for rect: NSRect, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var x = rect.maxX - size.width
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)

        var y = rect.minY - size.height - margin
        if y < visible.minY + margin {
            y = rect.maxY + margin
            if y + size.height > visible.maxY - margin {
                // 内部右下角：HUD 已从抓帧画面剔除，落在选区里也不会拼进长图。
                x = min(rect.maxX, visible.maxX) - size.width - 16
                y = max(rect.minY, visible.minY) + 16
            }
        }
        return NSPoint(x: x, y: y)
    }

    @objc private func finishPressed() { onFinish() }
    @objc private func cancelPressed() { onCancel() }
}

/// 非激活面板里的按钮需要第一击就响应（本 App 全程不抢焦点）。
private final class HUDTextButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
