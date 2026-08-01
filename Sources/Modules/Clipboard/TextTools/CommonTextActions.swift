import AppKit
import CryptoKit

/// 对任何文本条目都出现的动作（格式无关），排在格式专属动作之后。
@MainActor
enum CommonTextActions {
    static func all(for text: String) -> [FormatAction] {
        var actions: [FormatAction] = []
        if TextToolSettings.isEnabled(TextToolSettings.encodeMenuID) { actions.append(encodeMenu()) }
        if TextToolSettings.isEnabled(TextToolSettings.qrCodeID) { actions.append(qrCode(for: text)) }
        if TextToolSettings.isEnabled(TextToolSettings.pinCardID) { actions.append(pinCard()) }
        if TextToolSettings.isEnabled(TextToolSettings.editorID) { actions.append(editWindow()) }
        return actions
    }

    /// 大窗编辑（2026-08-02 增补）：面板放不下的大文本，开成独立可全屏的编辑
    /// 窗口。打开后面板收起 —— 编辑器接管，浮层面板留着只会盖在编辑器上碍事。
    static func editWindow() -> FormatAction {
        FormatAction(id: "common.edit", title: L("clipboard.tools.action.edit"),
                     kind: .terminal { text in
                         ClipboardEditorWindow.open(text: text)
                         ClipboardPanelController.current?.hide()
                     })
    }

    /// 钉住卡片（2026-08-02 增补）：把当前内容（转换过就是转换结果）钉成屏幕上
    /// 可任意拖动的浮动卡片。terminal 动作 —— 输出是窗口不是文本，面板不关。
    static func pinCard() -> FormatAction {
        FormatAction(id: "common.pin", title: L("clipboard.tools.action.pinCard"),
                     kind: .terminal { PinnedTextCard.pin($0) })
    }

    /// 「编码/解码」下拉（2026-08-02 增补）：任何文本都可用的通用转换收进一个
    /// 按钮，不随选项增多占满动作栏。Base64/JWT 解码对不匹配的文本静默不动
    /// （transform 自校验）。设置页「文本工具」有独立开关；总开关由
    /// TextFormatRegistry 把关。
    static func encodeMenu() -> FormatAction {
        FormatAction(id: "common.encode", title: L("clipboard.tools.action.encodeDecode"), kind: .menu([
            FormatAction(id: "common.base64encode", title: L("clipboard.tools.action.base64Encode"),
                         kind: .transform { Data($0.utf8).base64EncodedString() }),
            FormatAction(id: "common.base64decode", title: L("clipboard.tools.action.base64Decode"),
                         kind: .transform { Base64Recognizer.explicitDecode($0) }),
            FormatAction(id: "common.jwtdecode", title: L("clipboard.tools.action.jwtDecode"),
                         kind: .transform { text in
                             guard let parsed = JWTRecognizer.parse(text) else { return nil }
                             return parsed.headerJSON + "\n\n" + parsed.payloadJSON
                         }),
            FormatAction(id: "common.md5", title: L("clipboard.tools.action.md5"),
                         kind: .transform { Self.hexDigest(Insecure.MD5.hash(data: Data($0.utf8))) }),
            FormatAction(id: "common.sha1", title: L("clipboard.tools.action.sha1"),
                         kind: .transform { Self.hexDigest(Insecure.SHA1.hash(data: Data($0.utf8))) }),
            FormatAction(id: "common.sha256", title: L("clipboard.tools.action.sha256"),
                         kind: .transform { Self.hexDigest(SHA256.hash(data: Data($0.utf8))) })
        ]))
    }

    /// 小写十六进制，与 md5 / shasum 命令行输出一致。
    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func qrCode(for text: String) -> FormatAction {
        let overLimit = Data(text.utf8).count > QRCodeGenerator.maxBytes
        return FormatAction(
            id: "common.qrcode",
            title: L("clipboard.tools.action.qrcode"),
            // 内嵌进预览区、不关面板：扫码只是把手机举到屏幕前，不需要在 Mac 上点
            // 任何东西，面板保持前台即可。需要常驻二维码（切走焦点面板会收起）的
            // 场景走 `clipboard.qrcodeLast` 快捷键的钉屏路径。
            kind: .imagePreview { QRCodeGenerator.image(for: $0, minPixels: 1024) },
            isEnabled: !overLimit && !text.isEmpty,
            disabledHint: overLimit ? L("clipboard.tools.qrcode.tooLong") : nil
        )
    }
}

/// 生成二维码并**钉到屏幕**。
///
/// 面板内的二维码动作已改为内嵌预览区显示（见 `qrCode(for:)`），这里只服务
/// **无面板**的场景：`clipboard.qrcodeLast` 快捷键（不开面板给最近一条出码）。
/// 钉出的浮窗不受面板生命周期影响，且 `PinnedImageWindow` 自带右键菜单
/// （复制图片 / 另存为 / 关闭）。
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
