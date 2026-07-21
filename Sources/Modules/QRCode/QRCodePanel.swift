import AppKit
import CoreImage
import SwiftUI

// MARK: - 生成

enum QRCodeGenerator {
    /// 最大可编码字节数（版本 40、纠错 M 上限约 2953，留少量余量）。
    static let maxBytes = 2900

    /// 生成含 2 模块白色静区的二维码，边长 ≥ minPixels（整数倍放大保持模块边缘锐利）。
    /// 内容为空或超容量返回 nil。
    static func image(for text: String, minPixels: Int) -> CGImage? {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maxBytes,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let moduleCount = Int(output.extent.width)
        guard moduleCount > 0,
              let small = CIContext().createCGImage(output, from: output.extent) else { return nil }

        let quiet = 2 // 两侧各留 2 模块静区，扫码可靠性要求
        let scale = max(1, Int((Double(minPixels) / Double(moduleCount + 2 * quiet)).rounded(.up)))
        let side = (moduleCount + 2 * quiet) * scale
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.draw(small, in: CGRect(x: quiet * scale, y: quiet * scale,
                                   width: moduleCount * scale, height: moduleCount * scale))
        return ctx.makeImage()
    }
}

// MARK: - 面板

/// borderless 非激活面板，必须子类覆写 canBecomeKey（输入框要接键盘）。
private final class QRCodePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 二维码生成浮层：唤起时自动带入剪贴板文字，可编辑实时重绘。
@MainActor
final class QRCodePanelController {
    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    func show() {
        hide() // 再次唤起时重建，重新读取剪贴板

        let prefill = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let content = QRCodePanelView(
            initialText: String(prefill.prefix(2000)),
            onCopy: { [weak self] cg in
                ScreenshotResultHandler.copy(image: cg)
                self?.hide()
            },
            onSave: { [weak self] cg in self?.save(cg) },
            onPin: { [weak self] cg in
                self?.pinCentered(cg)
                self?.hide()
            }
        )
        let hosting = NSHostingView(rootView: content)

        let panel = QRCodePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 448),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting

        // 居中于鼠标所在屏
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - 180, y: visible.midY - 224))
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - 动作

    private func save(_ cg: CGImage) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "qrcode.png"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? png.write(to: url)
        }
        hide()
    }

    /// 钉在鼠标所在屏中央，260pt 见方（二维码是正方形）。
    private func pinCentered(_ cg: CGImage) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let side: CGFloat = min(260, visible.width * 0.5, visible.height * 0.5)
        let rect = NSRect(x: visible.midX - side / 2, y: visible.midY - side / 2, width: side, height: side)
        PinnedImageWindow.pin(image: cg, at: rect)
    }

    // MARK: - 事件监听（Esc 关闭 + 点击面板外关闭，与剪贴板面板一致）

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 0x35 { // Esc
                self.hide()
                return nil
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }
}

// MARK: - 视图

private struct QRCodePanelView: View {
    @State var text: String
    let onCopy: (CGImage) -> Void
    let onSave: (CGImage) -> Void
    let onPin: (CGImage) -> Void

    @FocusState private var inputFocused: Bool

    init(initialText: String,
         onCopy: @escaping (CGImage) -> Void,
         onSave: @escaping (CGImage) -> Void,
         onPin: @escaping (CGImage) -> Void) {
        _text = State(initialValue: initialText)
        self.onCopy = onCopy
        self.onSave = onSave
        self.onPin = onPin
    }

    /// 预览用小图；导出/复制时再按 1024px 重新生成高清版。
    private var previewImage: CGImage? {
        QRCodeGenerator.image(for: text, minPixels: 240)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                Text("qrcode.menu.generate")
                    .font(.headline)
                Spacer()
            }

            TextField("qrcode.panel.placeholder", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($inputFocused)

            ZStack {
                // 深色模式下也保持白底黑码，保证可扫描性。
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                if let cg = previewImage {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 216, height: 216)
                } else {
                    Text(text.isEmpty ? "qrcode.panel.empty" : "qrcode.panel.tooLong")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: 240, height: 240)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1))

            HStack(spacing: 10) {
                Button("qrcode.panel.copy") { export(onCopy) }
                    .buttonStyle(.borderedProminent)
                Button("qrcode.panel.pin") { export(onPin) }
                Button("qrcode.panel.save") { export(onSave) }
            }
            .disabled(previewImage == nil)

            Text("qrcode.panel.escHint")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        // 置焦点必须晚于 makeKeyAndOrderFront（同剪贴板面板的时序问题）。
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            inputFocused = true
        }
    }

    private func export(_ action: (CGImage) -> Void) {
        guard let cg = QRCodeGenerator.image(for: text, minPixels: 1024) else { return }
        action(cg)
    }
}
