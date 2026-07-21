import AppKit

/// 录制模式的选区确认工具条：系统声音开关 + 取消 + 开始录制。
/// 与标注工具条同款方案 —— 独立子窗口（overlay 视图会吞掉子视图的 mouseDown），
/// 摆位在选区下方右对齐，放不下换上方，再不行放选区内部右下角。
@MainActor
final class RecordStartBar: NSObject {

    let panel: NSPanel
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private let onStart: () -> Void
    private let onCancel: () -> Void
    private let audioCheckbox: BarCheckbox
    private let micCheckbox: BarCheckbox

    private static func makeCheckbox(title: String, on: Bool) -> BarCheckbox {
        let box = BarCheckbox()
        box.setButtonType(.switch)
        box.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.9),
                         .font: NSFont.systemFont(ofSize: 12)])
        box.state = on ? .on : .off
        box.sizeToFit()
        return box
    }

    init(onStart: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel

        // 声音开关是持久化设置：全屏/菜单等不经过本工具条的路径也读同一份。
        audioCheckbox = Self.makeCheckbox(title: L("screenshot.record.bar.audio"),
                                          on: ScreenshotSettings.recordSystemAudio)
        micCheckbox = Self.makeCheckbox(title: L("screenshot.record.bar.mic"),
                                        on: ScreenshotSettings.recordMicrophone)
        // GIF 输出没有声音，两个开关置灰示意。
        if ScreenshotSettings.recordFormat == .gif {
            audioCheckbox.isEnabled = false
            micCheckbox.isEnabled = false
        }

        // 取消
        let cancel = BarButton()
        cancel.isBordered = false
        cancel.attributedTitle = NSAttributedString(
            string: L("common.cancel"),
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.65),
                         .font: NSFont.systemFont(ofSize: 12)])
        cancel.sizeToFit()

        // 开始录制（红色胶囊主按钮）
        let start = BarButton()
        start.isBordered = false
        start.wantsLayer = true
        start.layer?.backgroundColor = NSColor.systemRed.cgColor
        start.layer?.cornerRadius = 13
        let startTitle = NSAttributedString(
            string: L("screenshot.record.bar.start"),
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)])
        start.attributedTitle = startTitle
        let startWidth = startTitle.size().width + 30

        // 手排布局：系统声音 麦克风 | 分隔 | 取消 | 开始
        let padH: CGFloat = 14, gap: CGFloat = 12, height: CGFloat = 42
        let audioW = audioCheckbox.frame.width + 4
        let micW = micCheckbox.frame.width + 4
        let cancelW = max(cancel.frame.width + 8, 40)
        let totalW = padH + audioW + gap + micW + gap + 1 + gap + cancelW + gap + startWidth + padH

        let content = NSView(frame: NSRect(x: 0, y: 0, width: totalW, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 10

        var x = padH
        audioCheckbox.frame = NSRect(x: x, y: (height - 18) / 2, width: audioW, height: 18)
        content.addSubview(audioCheckbox)
        x += audioW + gap

        micCheckbox.frame = NSRect(x: x, y: (height - 18) / 2, width: micW, height: 18)
        content.addSubview(micCheckbox)
        x += micW + gap

        let divider = NSView(frame: NSRect(x: x, y: 10, width: 1, height: height - 20))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        content.addSubview(divider)
        x += 1 + gap

        cancel.frame = NSRect(x: x, y: (height - 24) / 2, width: cancelW, height: 24)
        content.addSubview(cancel)
        x += cancelW + gap

        start.frame = NSRect(x: x, y: (height - 26) / 2, width: startWidth, height: 26)
        content.addSubview(start)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: totalW, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = content
        self.panel = panel

        super.init()

        audioCheckbox.target = self
        audioCheckbox.action = #selector(audioToggled)
        micCheckbox.target = self
        micCheckbox.action = #selector(micToggled)
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        start.target = self
        start.action = #selector(startPressed)
    }

    /// 作为 overlay 的子窗口展示，随 overlay 一起管理层级。
    func show(attachedTo window: NSWindow) {
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    func setHidden(_ hidden: Bool) {
        panel.alphaValue = hidden ? 0 : 1
    }

    /// 选区下方右对齐 → 上方 → 选区内部右下角（与录制控制条一致）。
    func position(near rectAK: NSRect, on screen: NSScreen) {
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let margin: CGFloat = 8

        var x = rectAK.maxX - size.width
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)

        var y = rectAK.minY - size.height - margin
        if y < visible.minY + margin {
            y = rectAK.maxY + margin
            if y + size.height > visible.maxY - margin {
                x = min(rectAK.maxX, visible.maxX) - size.width - 16
                y = max(rectAK.minY, visible.minY) + 16
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - 动作

    @objc private func audioToggled() {
        ScreenshotSettings.recordSystemAudio = (audioCheckbox.state == .on)
    }

    @objc private func micToggled() {
        ScreenshotSettings.recordMicrophone = (micCheckbox.state == .on)
    }

    @objc private func cancelPressed() {
        onCancel()
    }

    @objc private func startPressed() {
        onStart()
    }
}

/// 非激活面板里的控件需要第一击就响应。
private final class BarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BarCheckbox: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
