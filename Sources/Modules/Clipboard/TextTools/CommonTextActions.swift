import AppKit

/// 对任何文本条目都出现的动作（格式无关），排在格式专属动作之后。
@MainActor
enum CommonTextActions {
    static func all(for text: String) -> [FormatAction] {
        [qrCode(for: text)]
    }

    static func qrCode(for text: String) -> FormatAction {
        let overLimit = Data(text.utf8).count > QRCodeGenerator.maxBytes
        return FormatAction(
            id: "common.qrcode",
            title: L("clipboard.tools.action.qrcode"),
            kind: .terminal { value in
                ClipboardQRCode.pin(value)
                // 钉完就关面板：二维码已经常驻在屏幕上了，面板留着没意义。
                ClipboardPanelController.current?.hide()
            },
            isEnabled: !overLimit && !text.isEmpty,
            disabledHint: overLimit ? L("clipboard.tools.qrcode.tooLong") : nil
        )
    }
}

/// 生成二维码并**钉到屏幕**。
///
/// 为什么不是画在预览区：剪贴板面板装了 `globalClickMonitor`，点面板外即 `hide()`。
/// 二维码画在预览区的话，用户一拿手机、一切到别的 App 去扫，面板当场就没了 ——
/// 每次都会发生，不是边缘情况。钉出来的浮窗不受面板生命周期影响，
/// 且 `PinnedImageWindow` 自带右键菜单（复制图片 / 另存为 / 关闭）。
@MainActor
enum ClipboardQRCode {
    /// 钉在鼠标所在屏中央，260pt 见方（二维码是正方形）。
    static func pin(_ text: String) {
        guard let image = QRCodeGenerator.image(for: text, minPixels: 1024) else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let side = min(260, visible.width * 0.5, visible.height * 0.5)
        let rect = NSRect(x: visible.midX - side / 2, y: visible.midY - side / 2, width: side, height: side)
        PinnedImageWindow.pin(image: image, at: rect)
    }
}
