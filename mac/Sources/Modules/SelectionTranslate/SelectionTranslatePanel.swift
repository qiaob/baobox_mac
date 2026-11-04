import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 浮层要展示的内容。
enum SelectionPanelContent {
    /// 一条翻译请求：原文 + 判定出的原文语种（译文语种自动取反）。
    case translation(text: String, source: SelectionLanguage)
    /// 纯提示（没取到词 / OCR 没识别到 / 需要权限等）。
    case notice(message: String)
}

/// 划词翻译浮层：不抢焦点的 NSPanel，贴着选区出现。
///
/// 关闭方式：Esc、点击浮层以外的任何地方。判定「以外」靠全局事件监听
/// （需要辅助功能权限，本模块本来就要它取词）。
@MainActor
final class SelectionTranslatePanelController {
    var onSpeakOriginal: ((String, SelectionLanguage) -> Void)?
    var onSpeakTranslation: ((String, SelectionLanguage) -> Void)?
    var onCopyTranslation: ((String) -> Void)?
    var onTranslationReady: ((String, SelectionLanguage) -> Void)?
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private var monitors: [Any] = []

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    func show(content: SelectionPanelContent, anchor: CGRect?) {
        hide()
        let view = SelectionTranslateView(
            content: content,
            onSpeakOriginal: { [weak self] text, lang in self?.onSpeakOriginal?(text, lang) },
            onSpeakTranslation: { [weak self] text, lang in self?.onSpeakTranslation?(text, lang) },
            onCopyTranslation: { [weak self] text in self?.onCopyTranslation?(text) },
            onTranslationReady: { [weak self] text, lang in self?.onTranslationReady?(text, lang) },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(width: 360, height: min(max(fitting.height, 80), 460))

        let panel = SelectionPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(Self.placement(for: size, anchor: anchor))
        self.panel = panel
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    func hide() {
        removeDismissMonitors()
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            onHide?()
        }
        panel = nil
    }

    // MARK: - 定位

    /// 优先贴在选区下方，下方放不下翻到上方，始终夹进当前屏可见区。
    private static func placement(for size: NSSize, anchor: CGRect?) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let anchorRect = anchor ?? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchorRect.center, $0.frame, false) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return anchorRect.origin }

        var x = anchorRect.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        var y = anchorRect.minY - 6 - size.height // 选区下方
        if y < visible.minY + 8 {
            y = anchorRect.maxY + 6 // 翻到上方
        }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    // MARK: - 关闭监听

    private func installDismissMonitors() {
        // 点到别的 App = 点在浮层外（点浮层自身的事件只会走本地分发，不进全局监听）。
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // Esc：浮层不抢焦点，按键在别的 App 里发生，只能用全局监听观察（不能吞）。
        let key = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.hide() }
        }
        monitors = [mouse, key].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - 内容视图

private struct SelectionTranslateView: View {
    let content: SelectionPanelContent
    var onSpeakOriginal: (String, SelectionLanguage) -> Void
    var onSpeakTranslation: (String, SelectionLanguage) -> Void
    var onCopyTranslation: (String) -> Void
    var onTranslationReady: (String, SelectionLanguage) -> Void
    var onClose: () -> Void

    @State private var translatedText: String?
    @State private var translationFailed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .notice(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "character.bubble")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    closeButton
                }
            case .translation(let text, let source):
                translationBody(text: text, source: source)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func translationBody(text: String, source: SelectionLanguage) -> some View {
        // 方向行：English → 中文 + 关闭
        HStack(spacing: 6) {
            Text(source.displayName)
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
            Text(source.other.displayName)
            Spacer()
            closeButton
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)

        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 110)

        Divider()

        if #available(macOS 15.0, *) {
            translationArea(text: text, source: source)
        } else {
            Text(L("selectiontranslate.panel.needsMacOS15"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }

        // 按钮行
        HStack(spacing: 8) {
            Button {
                onSpeakOriginal(text, source)
            } label: {
                Label(L("selectiontranslate.panel.speakOriginal"), systemImage: "speaker.wave.2")
            }
            if let translatedText {
                Button {
                    onSpeakTranslation(translatedText, source.other)
                } label: {
                    Label(L("selectiontranslate.panel.speakTranslation"), systemImage: "speaker.wave.2.fill")
                }
                Button {
                    onCopyTranslation(translatedText)
                    copied = true
                } label: {
                    Label(copied ? L("selectiontranslate.panel.copied") : L("selectiontranslate.panel.copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            Spacer()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    @available(macOS 15.0, *)
    private func translationArea(text: String, source: SelectionLanguage) -> some View {
        Group {
            if let translatedText {
                ScrollView {
                    Text(translatedText)
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } else if translationFailed {
                Text(L("selectiontranslate.panel.translateFailed"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("selectiontranslate.panel.translating"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(TranslationSessionHost(text: text, source: source) { result in
            switch result {
            case .success(let value):
                translatedText = value
                onTranslationReady(value, source.other)
            case .failure:
                translationFailed = true
            }
        })
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("selectiontranslate.panel.close"))
    }
}

#if canImport(Translation)
/// 翻译会话宿主（macOS 15+）：与 LiveTranslate 的模式一致——框架只认
/// 挂在视图上的 `.translationTask`，会话句柄只在闭包里出现。
/// 浮层每次 show 都重建视图，因此文本固定，直接翻一次即可。
@available(macOS 15.0, *)
private struct TranslationSessionHost: ViewModifier {
    let text: String
    let source: SelectionLanguage
    let onResult: (Result<String, Error>) -> Void

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    guard !Task.isCancelled else { return }
                    onResult(.success(response.targetText))
                } catch {
                    guard !Task.isCancelled else { return }
                    onResult(.failure(error))
                }
            }
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: source.translationCode),
                    target: Locale.Language(identifier: source.other.translationCode)
                )
            }
    }
}
#else
private struct TranslationSessionHost: ViewModifier {
    let text: String
    let source: SelectionLanguage
    let onResult: (Result<String, Error>) -> Void
    func body(content: Content) -> some View { content }
}
#endif
