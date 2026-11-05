import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 浮层要展示的内容。
enum SelectionPanelContent {
    /// 一条翻译请求：原文 + 检测出的原文语种 + 默认译成的语言（浮层里可以再改）。
    case translation(text: String, source: TranslationLanguage, target: TranslationLanguage)
    /// 纯提示（没取到词 / OCR 没识别到 / 需要权限等）。
    case notice(message: String)
}

/// 划词翻译浮层：不抢焦点的 NSPanel，贴着选区出现。
///
/// 关闭方式：Esc、点击浮层以外的任何地方。判定「以外」靠全局事件监听
/// （需要辅助功能权限，本模块本来就要它取词）。
@MainActor
final class SelectionTranslatePanelController {
    var onSpeakOriginal: ((String, TranslationLanguage) -> Void)?
    var onSpeakTranslation: ((String, TranslationLanguage) -> Void)?
    var onCopyTranslation: ((String) -> Void)?
    var onTranslationReady: ((String, TranslationLanguage) -> Void)?
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    /// 这次浮层贴着的位置；内容变高后重新摆放要用。
    private var anchor: CGRect?
    /// 上一次由我们摆放的位置。浮层位置和它不一样 = 用户拖过，之后只在原地长高、不再跳回选区旁。
    private var placedOrigin: NSPoint?
    private var userMoved = false
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
            onClose: { [weak self] in self?.hide() },
            // 回调发生在 SwiftUI 更新过程中：下一拍再改窗口，避免宿主视图在渲染途中被重入布局。
            onSizeChange: { [weak self] size in Task { @MainActor in self?.fit(to: size) } }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 200)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: PanelMetrics.width, height: PanelMetrics.clampedHeight(hosting.fittingSize.height))

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
        let origin = Self.placement(for: size, anchor: anchor)
        panel.setFrameOrigin(origin)
        self.panel = panel
        self.anchor = anchor
        placedOrigin = origin
        userMoved = false
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

    /// 内容高度变了（译文到了、换了目标语言…）就跟着改浮层高度。没被拖过就按选区重新摆放
    /// （下方放不下会翻到上方）；拖过的话上沿不动、往下长，再夹回屏幕可见区。
    private func fit(to contentSize: CGSize) {
        guard let panel else { return }
        let height = PanelMetrics.clampedHeight(contentSize.height)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let size = NSSize(width: PanelMetrics.width, height: height)
        if let placedOrigin, panel.frame.origin != placedOrigin { userMoved = true }
        var origin: NSPoint
        if userMoved {
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
            if let visible = panel.screen?.visibleFrame {
                origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
            }
        } else {
            origin = Self.placement(for: size, anchor: anchor)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        placedOrigin = origin
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

/// 浮层尺寸。宽度固定；高度跟内容走，夹在上下限之间。
private enum PanelMetrics {
    static let width: CGFloat = 360
    /// 文字区可用宽度（左右各 12 的内边距）。
    static let textWidth: CGFloat = width - 24
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 600
    /// 原文 / 译文各自最多展开多高，超过就收进同样高的滚动框。
    static let originalMaxHeight: CGFloat = 150
    static let translationMaxHeight: CGFloat = 230

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(ceil(height), minHeight), maxHeight)
    }
}

/// 浮层内容的实际尺寸，回报给面板控制器改窗口高度。
private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 文字区：内容多高就多高；超过 `maxHeight` 才收进滚动框（滚动框就是 maxHeight 那么高）。
/// 不能直接给 ScrollView 一个 maxHeight —— ScrollView 不会按内容撑高，会被压成一两行、半行被切
/// （2026-11-05 实测）。是否超高用同样的字体按 NSString 排版量出来，免得靠回传高度来回重排。
private struct AdaptiveText: View {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    let maxHeight: CGFloat

    private static let lineSpacing: CGFloat = 2

    var body: some View {
        let label = Text(text)
            .font(.system(size: size, weight: weight == .medium ? .medium : .regular))
            .lineSpacing(Self.lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if Self.measuredHeight(of: text, size: size, weight: weight) <= maxHeight {
            label
        } else {
            ScrollView {
                label
            }
            .frame(height: maxHeight)
        }
    }

    private static func measuredHeight(of text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: PanelMetrics.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: paragraph])
        return ceil(rect.height)
    }
}

// MARK: - 内容视图

private struct SelectionTranslateView: View {
    let content: SelectionPanelContent
    var onSpeakOriginal: (String, TranslationLanguage) -> Void
    var onSpeakTranslation: (String, TranslationLanguage) -> Void
    var onCopyTranslation: (String) -> Void
    var onTranslationReady: (String, TranslationLanguage) -> Void
    var onClose: () -> Void
    var onSizeChange: (CGSize) -> Void

    /// 用户在浮层里改选的目标语言；nil = 用默认的。
    @State private var chosenTarget: TranslationLanguage?
    @State private var translatedText: String?
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
            case .translation(let text, let source, let target):
                translationBody(text: text, source: source, target: chosenTarget ?? target)
            }
        }
        .padding(12)
        .frame(width: PanelMetrics.width)
        // 高度取内容的理想高度，不随窗口高度伸缩：窗口跟着内容改，不会反过来把内容压扁。
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            onSizeChange(size)
        }
    }

    @ViewBuilder
    private func translationBody(text: String, source: TranslationLanguage, target: TranslationLanguage) -> some View {
        // 方向行：English → 中文 ▾（目标语言可点开切换）+ 关闭
        HStack(spacing: 6) {
            Text(source.endonym)
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
            Menu {
                ForEach(TranslationLanguage.all) { language in
                    Button(language.endonym) {
                        guard language != target else { return }
                        translatedText = nil
                        copied = false
                        chosenTarget = language
                    }
                }
            } label: {
                Text(target.endonym)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("selectiontranslate.panel.changeTarget"))
            Spacer()
            closeButton
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)

        AdaptiveText(text: text, size: 13, weight: .regular, maxHeight: PanelMetrics.originalMaxHeight)

        Divider()

        // 换目标语言 = 重建翻译区（新会话 / 新请求）。
        SelectionTranslationArea(text: text, source: source, target: target) { value in
            translatedText = value
            onTranslationReady(value, target)
        }
        .id(target.code)

        // 按钮行
        HStack(spacing: 8) {
            Button {
                onSpeakOriginal(text, source)
            } label: {
                Label(L("selectiontranslate.panel.speakOriginal"), systemImage: "speaker.wave.2")
            }
            if let translatedText {
                Button {
                    onSpeakTranslation(translatedText, target)
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

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("selectiontranslate.panel.close"))
    }
}

/// 翻译区：按引擎解析选系统翻译 / 离线模型；系统翻译失败时（「自动」模式）回落离线模型；
/// 都不可用（macOS 14 且没下载模型）时给下载入口，下完自动开翻。
private struct SelectionTranslationArea: View {
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
    let onResult: (String) -> Void

    @ObservedObject private var offline = OfflineTranslator.shared
    @State private var engine: TranslationEngineKind?
    @State private var result: String?
    @State private var failure: String?

    init(text: String, source: TranslationLanguage, target: TranslationLanguage,
         onResult: @escaping (String) -> Void) {
        self.text = text
        self.source = source
        self.target = target
        self.onResult = onResult
        _engine = State(initialValue: TranslationSettings.resolve())
    }

    var body: some View {
        Group {
            if let result {
                AdaptiveText(text: result, size: 13, weight: .medium, maxHeight: PanelMetrics.translationMaxHeight)
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if engine == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("selectiontranslate.panel.needsOfflineModel"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    OfflineModelRow(compact: true)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(engine == .offline && offline.isStartingServer
                         ? L("selectiontranslate.panel.startingModel")
                         : L("selectiontranslate.panel.translating"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(SystemTranslationHost(active: engine == .system, text: text, source: source, target: target) { outcome in
            switch outcome {
            case .success(let value):
                finish(value)
            case .failure:
                if TranslationSettings.canFallBackToOffline {
                    engine = .offline
                } else {
                    failure = L("selectiontranslate.panel.translateFailed")
                }
            }
        })
        .task(id: engine == .offline) {
            guard engine == .offline else { return }
            await runOffline()
        }
        .onChange(of: offline.isReady) { _, ready in
            // 在浮层里点了下载、下完了：直接开翻。
            if ready, engine == nil, TranslationSettings.engineChoice != .system {
                engine = .offline
            }
        }
    }

    private func runOffline() async {
        do {
            let value = try await offline.translate(text, to: target, from: source)
            guard !Task.isCancelled else { return }
            finish(value)
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    private func finish(_ value: String) {
        result = value
        onResult(value)
    }
}

#if canImport(Translation)
/// 只在 macOS 15+ 且这次用系统翻译时挂上翻译会话。
private struct SystemTranslationHost: ViewModifier {
    let active: Bool
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
    let onResult: (Result<String, Error>) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            if active {
                content.modifier(TranslationSessionHost(text: text, source: source, target: target,
                                                        onResult: onResult))
            } else {
                content
            }
        } else {
            content
        }
    }
}

/// 翻译会话宿主（macOS 15+）：框架只认挂在视图上的 `.translationTask`，会话句柄只在闭包里出现。
/// 浮层每次 show 都重建视图、换目标语言也会重建，因此文本与方向固定，直接翻一次即可。
@available(macOS 15.0, *)
private struct TranslationSessionHost: ViewModifier {
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
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
                    source: Locale.Language(identifier: source.appleCode),
                    target: Locale.Language(identifier: target.appleCode)
                )
            }
    }
}
#else
private struct SystemTranslationHost: ViewModifier {
    let active: Bool
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
    let onResult: (Result<String, Error>) -> Void
    func body(content: Content) -> some View { content }
}
#endif
