import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 划词助手浮层：不抢焦点的 NSPanel，两种形态（docs/selection-translate/ASSISTANT.md §2.2）：
/// - 动作条：一排小按钮，贴在选区上方，宽度跟内容走；
/// - 结果面板：宽 400，高度跟内容走，贴在选区下方（放不下翻到上方）；
///   交来的文字（快速入口）没有选区：水平居中、顶边固定（`SelectionCenteredSlot`）。
/// 另有纯提示（没取到词等）。
///
/// 关闭：点别处、Esc、开始打字、动作条形态下滚轮或 4 秒没碰。判定靠全局事件监听
/// （需要辅助功能权限，本模块本来就要它取词）。
@MainActor
final class SelectionTranslatePanelController {
    var onHide: (() -> Void)?

    private var panel: NSPanel?
    private(set) var session: SelectionSession?
    /// 这次浮层贴着的位置；内容变了重新摆放要用。
    private var anchor: CGRect?
    /// 交来的文字：不贴选区，居中摆在这一格里（非 nil 时 `anchor` 不参与定位）。
    private var centeredSlot: SelectionCenteredSlot?
    /// 上一次由我们摆放的位置。浮层位置和它不一样 = 用户拖过，之后只在原地长高、不再跳回选区旁。
    private var placedOrigin: NSPoint?
    private var userMoved = false
    private var monitors: [Any] = []
    private var idleTimer: Timer?
    private var idleSince = Date()

    /// 动作条无操作多久消失（鼠标不在条上时计时）。
    private static let barIdleTimeout: TimeInterval = 4

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    /// - Parameter slot: 交来的文字（快速入口）时给：结果面板居中摆在这一格里，不贴选区。
    func show(session: SelectionSession, centeredIn slot: SelectionCenteredSlot? = nil) {
        present(AnyView(SelectionRootView(session: session, onSizeChange: { [weak self] size in
            // 回调发生在 SwiftUI 更新过程中：下一拍再改窗口，避免宿主视图在渲染途中被重入布局。
            Task { @MainActor in self?.fit(to: size) }
        })), session: session, anchor: session.anchor, centeredIn: slot)
    }

    func showNotice(_ message: String, anchor: CGRect?) {
        present(AnyView(SelectionNoticeView(message: message, onClose: { [weak self] in self?.hide() },
                                            onSizeChange: { [weak self] size in
            Task { @MainActor in self?.fit(to: size) }
        })), session: nil, anchor: anchor, centeredIn: nil)
    }

    private func present(_ root: AnyView, session: SelectionSession?, anchor: CGRect?, centeredIn slot: SelectionCenteredSlot?) {
        hide()
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: SelectionPanelMetrics.width, height: 200)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(1, ceil(fitting.width)), height: SelectionPanelMetrics.clampedHeight(fitting.height))

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
        self.session = session
        self.anchor = anchor
        centeredSlot = slot
        let origin = slot?.origin(for: size) ?? Self.placement(for: size, anchor: anchor, above: session?.isBar ?? false)
        panel.setFrameOrigin(origin)
        self.panel = panel
        placedOrigin = origin
        userMoved = false
        panel.orderFrontRegardless()
        installDismissMonitors()
        idleSince = Date()
        startIdleTimer()
    }

    func hide() {
        removeDismissMonitors()
        idleTimer?.invalidate()
        idleTimer = nil
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)
        panel = nil
        session = nil
        if wasVisible { onHide?() }
    }

    /// 形态变了（动作条 → 结果面板）：之前没被拖过就按新形态重新摆放。
    func phaseDidChange() {
        idleSince = Date()
        if !userMoved { placedOrigin = nil }
    }

    /// 内容尺寸变了就跟着改浮层。没被拖过就按选区重新摆放（结果面板在下方、放不下翻到上方；动作条在上方）；
    /// 交来的文字没被拖过就重新居中、顶边不动；拖过的话上沿不动、往下长，再夹回屏幕可见区。
    private func fit(to contentSize: CGSize) {
        guard let panel else { return }
        // 居中那一格：不理还没排版时报上来的 0 × 0。理了的话面板先被缩成 1 点宽摆在中线上，宿主视图再按内容把它撑回 400 宽、
        // 左上角不动 —— 面板就从中线往右长（2026-11-24 用户看到的「中间偏右上」，离屏探针复现）。
        if centeredSlot != nil, !SelectionCenteredSlot.isMeasured(contentSize) { return }
        let height = SelectionPanelMetrics.clampedHeight(contentSize.height)
        let width = max(1, ceil(contentSize.width))
        let sizeChanged = abs(panel.frame.height - height) > 0.5 || abs(panel.frame.width - width) > 0.5
        guard sizeChanged || placedOrigin == nil else { return }
        let size = NSSize(width: width, height: height)
        if let placedOrigin {
            // 居中那一格：系统给窗口原点取整，差一点点不算拖过（否则可见区高度的 1/5 不是整数时，第一次改尺寸就被当成拖过、不再居中）。
            let moved = centeredSlot == nil
                ? panel.frame.origin != placedOrigin
                : SelectionCenteredSlot.wasMoved(placed: placedOrigin, actual: panel.frame.origin)
            if moved { userMoved = true }
        }
        var origin: NSPoint
        if userMoved {
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
            if let visible = panel.screen?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
                origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
            }
        } else {
            origin = centeredSlot?.origin(for: size) ?? Self.placement(for: size, anchor: anchor, above: session?.isBar ?? false)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        placedOrigin = origin
    }

    // MARK: - 定位

    /// 结果面板优先贴在选区下方、放不下翻到上方；动作条反过来（不挡住选中的文字）。始终夹进当前屏可见区。
    private static func placement(for size: NSSize, anchor: CGRect?, above: Bool) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let anchorRect = anchor ?? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchorRect.center, $0.frame, false) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return anchorRect.origin }

        var x = above ? anchorRect.minX : anchorRect.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        let below = anchorRect.minY - 6 - size.height
        let upper = anchorRect.maxY + 6
        var y: CGFloat
        if above {
            y = upper + size.height <= visible.maxY - 8 ? upper : below
        } else {
            y = below >= visible.minY + 8 ? below : upper
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
        // 按键：浮层不抢焦点，按键在别的 App 里发生，只能观察（不能吞）。Esc 或开始打字都关；
        // 被临时快捷键吃掉的键（⌥ + 数字、键盘模式的字母…）不会到这里。
        let key = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // 滚动页面：动作条跟不上选区了，收起。
        let scroll = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session?.isBar == true, self.session?.keyboardMode == false else { return }
                self.hide()
            }
        }
        // 按住 ⌥ 显示编号。
        let flags = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let optionOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            Task { @MainActor in self?.session?.optionHeld = optionOnly }
        }
        monitors = [mouse, key, scroll, flags].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    /// 动作条形态：鼠标不在条上、也没在键盘模式，4 秒后自动消失。
    private func startIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        guard let panel, let session, session.isBar, !session.keyboardMode else {
            idleSince = Date()
            return
        }
        if panel.frame.contains(NSEvent.mouseLocation) || session.optionHeld {
            idleSince = Date()
            return
        }
        if Date().timeIntervalSince(idleSince) >= Self.barIdleTimeout {
            hide()
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// 浮层尺寸。结果面板宽度固定；高度跟内容走，夹在上下限之间。
enum SelectionPanelMetrics {
    static let width: CGFloat = 400
    /// 文字区可用宽度（左右各 12 的内边距）。
    static let textWidth: CGFloat = width - 24
    static let minHeight: CGFloat = 20
    static let maxHeight: CGFloat = 640
    /// 原文 / 译文各自最多展开多高，超过就收进同样高的滚动框。
    static let originalMaxHeight: CGFloat = 150
    static let translationMaxHeight: CGFloat = 230

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(ceil(height), minHeight), maxHeight)
    }
}

/// 浮层内容的实际尺寸，回报给面板控制器改窗口大小。
struct SelectionPanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 文字区：内容多高就多高；超过 `maxHeight` 才收进滚动框（滚动框就是 maxHeight 那么高）。
/// 不能直接给 ScrollView 一个 maxHeight —— ScrollView 不会按内容撑高，会被压成一两行、半行被切
/// （2026-11-05 实测）。是否超高用同样的字体按 NSString 排版量出来，免得靠回传高度来回重排。
struct AdaptiveText: View {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    let maxHeight: CGFloat
    var color: Color = .primary

    private static let lineSpacing: CGFloat = 2

    var body: some View {
        let label = Text(text)
            .font(.system(size: size, weight: weight == .medium ? .medium : .regular))
            .foregroundStyle(color)
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
            with: NSSize(width: SelectionPanelMetrics.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: paragraph])
        return ceil(rect.height)
    }
}

/// 翻译区：按本模块的引擎设置选系统翻译 / 离线模型 / 云端服务；系统翻译失败时（「自动」模式）回落离线模型；
/// 云端出错时 `AIService` 自动改用离线模型（有的话），译文下面标一句。都不可用（macOS 14 且没下载模型）时给下载入口，下完自动开翻。
struct SelectionTranslationArea: View {
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
    /// false = 译文不在这里显示（学习把译文当成要学的句子，自己排版）。
    var showsResult = true
    let onResult: (String) -> Void

    @ObservedObject private var offline = OfflineTranslator.shared
    @State private var engine: TranslationEngineKind?
    @State private var result: String?
    @State private var failure: String?
    /// 要的是云端、实际用了本地。
    @State private var fellBack = false

    init(text: String, source: TranslationLanguage, target: TranslationLanguage, showsResult: Bool = true,
         onResult: @escaping (String) -> Void) {
        self.text = text
        self.source = source
        self.target = target
        self.showsResult = showsResult
        self.onResult = onResult
        _engine = State(initialValue: TranslationSettings.resolve(.selectionTranslate))
    }

    var body: some View {
        Group {
            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    if showsResult {
                        AdaptiveText(text: result, size: 13, weight: .medium, maxHeight: SelectionPanelMetrics.translationMaxHeight)
                    }
                    if fellBack {
                        Text(L("ai.notice.cloudFallback"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
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
                if TranslationSettings.canFallBackToOffline(.selectionTranslate) {
                    engine = .offline
                } else {
                    failure = L("selectiontranslate.panel.translateFailed")
                }
            }
        })
        .task(id: engine) {
            switch engine {
            case .offline: await runModel(.local)
            case .cloud(let modelID): await runModel(.cloud(modelID))
            case .localModel(let id): await runModel(.localModel(id))
            case .system, nil: return
            }
        }
        .onChange(of: offline.isReady) { _, ready in
            // 在浮层里点了下载、下完了：直接开翻。
            if ready, engine == nil, AIFeatureSettings.choice(.selectionTranslate) != .system {
                engine = .offline
            }
        }
    }

    private func runModel(_ route: AIRoute) async {
        do {
            let reply = try await AIService.shared.translate(text, to: target, from: source, route: route)
            guard !Task.isCancelled else { return }
            fellBack = reply.usedFallback
            finish(reply.text)
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
