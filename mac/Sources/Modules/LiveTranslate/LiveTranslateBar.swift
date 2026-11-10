import AppKit
import SwiftUI

/// 字幕条窗口：不抢焦点、置顶、跨 Space、全屏 App 上可见；拖背景移动，拖边 / 角改大小（`BarResizeArea`）。
private final class LiveTranslateBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 改大小的拖拽区：贴着四条边的细条 + 四个角，右下角画出可见的拖拽角。
///
/// 无边框窗口系统不给拖边改大小（`.resizable` 加了也拉不动，实测 2026-11-05），只能自己做：按下时记住鼠标和窗口位置，
/// 拖动时按拖的是哪几条边改窗口 frame。字幕条不能成为 key window，光标用 `.activeAlways` 的追踪区设置。
private final class BarResizeArea: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    private let edges: Edges
    private let showsGrip: Bool
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(edges: Edges, showsGrip: Bool = false) {
        self.edges = edges
        self.showsGrip = showsGrip
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 拖这里是改大小，不是挪窗口（窗口开着「拖背景移动」）。
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minSize = window.minSize
        var frame = startFrame
        if edges.contains(.right) {
            frame.size.width = max(minSize.width, startFrame.width + dx)
        }
        if edges.contains(.left) {
            frame.size.width = max(minSize.width, startFrame.width - dx)
            frame.origin.x = startFrame.maxX - frame.width
        }
        // 屏幕坐标 y 朝上：拖上边 = 底边不动、往上长；拖下边 = 上边不动、往下长。
        if edges.contains(.top) {
            frame.size.height = max(minSize.height, startFrame.height + dy)
        }
        if edges.contains(.bottom) {
            frame.size.height = max(minSize.height, startFrame.height - dy)
            frame.origin.y = startFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
        cursor.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsGrip else { return }
        // 右下角三道斜线：看得出这里能拉。
        let path = NSBezierPath()
        for inset in [CGFloat(4), 8, 12] {
            path.move(to: NSPoint(x: bounds.maxX - 3 - inset, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + inset))
        }
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }

    private var cursor: NSCursor {
        switch edges {
        case [.left], [.right]: return .resizeLeftRight
        case [.top], [.bottom]: return .resizeUpDown
        case [.top, .left], [.bottom, .right]: return Self.diagonalBackslash
        default: return Self.diagonalSlash
        }
    }

    /// 斜向的双箭头光标（系统 14 上没有公开的）：白色符号描一圈黑边，深浅背景上都看得清。
    private static let diagonalBackslash = makeCursor("arrow.up.left.and.arrow.down.right")
    private static let diagonalSlash = makeCursor("arrow.up.right.and.arrow.down.left")

    private static func makeCursor(_ symbol: String) -> NSCursor {
        let base = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        guard let white = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(base.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))),
              let black = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(base.applying(NSImage.SymbolConfiguration(paletteColors: [.black]))) else {
            return .crosshair
        }
        let symbolSize = white.size
        let size = NSSize(width: symbolSize.width + 4, height: symbolSize.height + 4)
        let image = NSImage(size: size, flipped: false) { _ in
            for dx in [CGFloat(-1), 0, 1] {
                for dy in [CGFloat(-1), 0, 1] where dx != 0 || dy != 0 {
                    black.draw(in: NSRect(x: 2 + dx, y: 2 + dy, width: symbolSize.width, height: symbolSize.height))
                }
            }
            white.draw(in: NSRect(x: 2, y: 2, width: symbolSize.width, height: symbolSize.height))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }

    /// 铺满 `container` 四边：细条 6pt、角 10pt（右上角的关闭按钮离边 8pt，角再大就压到它）；右下角 18pt、画出拖拽角。
    static func install(in container: NSView) {
        let bounds = container.bounds
        let thin: CGFloat = 6
        let corner: CGFloat = 10
        let grip: CGFloat = 18
        let width = bounds.width
        let height = bounds.height
        let parts: [(Edges, NSRect, NSView.AutoresizingMask, Bool)] = [
            ([.top], NSRect(x: corner, y: height - thin, width: width - 2 * corner, height: thin), [.width, .minYMargin], false),
            ([.bottom], NSRect(x: corner, y: 0, width: width - corner - grip, height: thin), [.width, .maxYMargin], false),
            ([.left], NSRect(x: 0, y: corner, width: thin, height: height - 2 * corner), [.height, .maxXMargin], false),
            ([.right], NSRect(x: width - thin, y: grip, width: thin, height: height - corner - grip), [.height, .minXMargin], false),
            ([.top, .left], NSRect(x: 0, y: height - corner, width: corner, height: corner), [.maxXMargin, .minYMargin], false),
            ([.top, .right], NSRect(x: width - corner, y: height - corner, width: corner, height: corner), [.minXMargin, .minYMargin], false),
            ([.bottom, .left], NSRect(x: 0, y: 0, width: corner, height: corner), [.maxXMargin, .maxYMargin], false),
            ([.bottom, .right], NSRect(x: width - grip, y: 0, width: grip, height: grip), [.minXMargin, .maxYMargin], true),
        ]
        for (edges, frame, mask, showsGrip) in parts {
            let view = BarResizeArea(edges: edges, showsGrip: showsGrip)
            view.frame = frame
            view.autoresizingMask = mask
            container.addSubview(view)
        }
    }
}

/// 字幕条的显示 / 隐藏与位置、大小记忆。每次开始翻译新建一个（翻译会话配置跟着字幕条走）。
@MainActor
final class LiveTranslateBarController {
    private let panel: LiveTranslateBarPanel
    private var observers: [NSObjectProtocol] = []
    /// 本次是否翻译（系统翻译或离线模型）。
    let translates: Bool

    /// 最小尺寸：放得下顶上一行菜单 + 一句字幕。
    private static let minSize = NSSize(width: 480, height: 96)

    /// `systemPairs`：用系统翻译时每个方向一个会话（自动模式两个）；离线模型 / 不翻译时为空。
    init(controller: LiveTranslateController, translates: Bool,
         systemPairs: [(source: TranslationLanguage, target: TranslationLanguage)]) {
        self.translates = translates
        let view = LiveTranslateBarView(controller: controller, translates: translates)
            .liveTranslateTask(systemPairs.first, translator: controller.translator)
            .liveTranslateTask(systemPairs.count > 1 ? systemPairs[1] : nil, translator: controller.translator)

        let size = Self.defaultSize()
        let panel = LiveTranslateBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = Self.minSize
        // 大小由用户拉（并记住），内容铺满窗口：不让 SwiftUI 按内容尺寸撑窗口（那样就拉不动了）。
        // 拖边改大小的细条叠在 SwiftUI 内容上面（见 `BarResizeArea`）。
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        BarResizeArea.install(in: container)
        panel.contentView = container
        self.panel = panel
    }

    func show() {
        panel.setFrame(initialFrame(), display: false)
        panel.orderFrontRegardless()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveFrame()
                }
            }
            observers.append(observer)
        }
    }

    func hide() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        panel.orderOut(nil)
    }

    // MARK: - 位置与大小

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    }

    /// 上次的位置和大小仍在某块屏内就沿用；只存过位置（旧版本）就用它 + 默认大小；否则放鼠标所在屏底部居中。
    private func initialFrame() -> NSRect {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: LiveTranslateSettings.barFrameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= Self.minSize.width, frame.height >= Self.minSize.height, Self.isOnScreen(frame) {
                return frame
            }
        }
        let size = Self.defaultSize()
        if let saved = defaults.string(forKey: LiveTranslateSettings.barOriginKey) {
            let frame = NSRect(origin: NSPointFromString(saved), size: size)
            if Self.isOnScreen(frame) { return frame }
        }
        guard let visible = Self.targetScreen()?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        return NSRect(x: visible.midX - size.width / 2, y: visible.minY + 60, width: size.width, height: size.height)
    }

    /// 左下角附近落在某块屏的可见区域里（拖到屏外、拔了显示器就不沿用）。
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        let probe = NSPoint(x: frame.minX + 20, y: frame.minY + 20)
        return NSScreen.screens.contains { NSMouseInRect(probe, $0.visibleFrame, false) }
    }

    /// 默认大小：屏宽的七成（最多 1200）× 放得下两句字幕的高度。
    private static func defaultSize() -> NSSize {
        let width = min((targetScreen()?.visibleFrame.width ?? 1200) * 0.7, 1200)
        return NSSize(width: max(width, minSize.width), height: max(LiveTranslateBarView.defaultHeight(), minSize.height))
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: LiveTranslateSettings.barFrameKey)
    }
}

/// 字幕条内容：顶上一行快捷菜单、状态和延迟；下面是字幕，最新的在最下面。拉高了能往上翻历史：
/// 在底部时跟着新字走，往上翻了就停在那儿，回到底部（或点「回到最新」）再接着跟。
private struct LiveTranslateBarView: View {
    @ObservedObject var controller: LiveTranslateController
    let translates: Bool
    /// 离线翻译模型：加载中（第一次要 6 秒左右，实测 2026-11-05）时字幕区底部转圈提示。
    @ObservedObject private var translationModel = OfflineTranslator.shared

    @AppStorage(LiveTranslateSettings.displayKey) private var displayRaw = LiveTranslateDisplay.both.rawValue
    @AppStorage(LiveTranslateSettings.fontSizeKey) private var fontSize = LiveTranslateSettings.defaultFontSize
    @AppStorage(LiveTranslateSettings.opacityKey) private var opacity = LiveTranslateSettings.defaultOpacity

    /// 在底部、跟着新字走。
    @State private var following = true
    /// 上一次的内容高度：高度变了 = 来了新字（或改了窗口大小）；没变而位置变了 = 用户在翻。
    @State private var contentHeight: CGFloat = 0

    private static let topRowHeight: CGFloat = 24
    private static let bottomID = "bottom"
    private static let scrollSpace = "liveTranslateScroll"

    /// 不翻译时一律按「仅原文」显示。
    private var display: LiveTranslateDisplay {
        guard translates else { return .original }
        return LiveTranslateDisplay(rawValue: displayRaw) ?? .both
    }

    private var secondarySize: CGFloat { CGFloat(fontSize) * 0.7 }

    /// 默认高度（没拉过时）：两句字幕（当前句两行、上一句一行）+ 顶上一行菜单。
    static func defaultHeight() -> CGFloat {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.object(forKey: LiveTranslateSettings.fontSizeKey) as? Double
            ?? LiveTranslateSettings.defaultFontSize)
        let display = LiveTranslateDisplay(rawValue: defaults.string(forKey: LiveTranslateSettings.displayKey) ?? "")
            ?? .both
        let perLine: CGFloat
        switch display {
        case .both: perLine = (size * 0.7 + size) * 1.3 + 4
        case .translation, .original: perLine = size * 1.3
        }
        return perLine * 3 + 36 + topRowHeight
    }

    /// 状态行：「识别：简体中文 本机 · English 服务器　翻译：离线模型」。识别器还没报上来时不显示。
    private var statusText: String? {
        guard !controller.channelStates.isEmpty else { return nil }
        let recognition = controller.channelStates.map { state -> String in
            let mode: String
            switch state.mode {
            case .onDevice: mode = L("livetranslate.status.onDevice")
            case .server: mode = L("livetranslate.status.server")
            case .disabled: mode = L("livetranslate.status.disabled")
            case .standby: mode = L("livetranslate.status.standby")
            }
            return "\(state.language.endonym) \(mode)"
        }.joined(separator: " · ")
        let engine: String
        switch controller.sessionEngine {
        case .offline: engine = L("livetranslate.status.engineLocalModel \(OfflineModel.translation.displayName)")
        case .system: engine = L("livetranslate.status.engineSystem")
        case .cloud(let modelID):
            engine = L("livetranslate.status.engineCloud \(AIModelStore.shared.displayName(modelID: modelID) ?? "")")
        case .localModel(let id):
            engine = L("livetranslate.status.engineLocalModel \(LocalModels.entry(id)?.name ?? id)")
        case nil: engine = L("livetranslate.status.engineOff")
        }
        var text = L("livetranslate.status.recognition \(recognition)") + "　" + L("livetranslate.status.translation \(engine)")
        if controller.correcting {
            text += " · " + L("livetranslate.status.aiCorrection")
        }
        return text
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                topRow
                linesArea
            }
            Button {
                // 实时翻译：停止；会议：收起字幕（会议照常记录）。
                controller.closeBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(L("livetranslate.bar.close"))
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(opacity))
        )
    }

    /// 顶上一行：快捷菜单 + 状态（识别方式 / 翻译引擎）+ 右上角的延迟监控。
    private var topRow: some View {
        HStack(spacing: 12) {
            // 会议的音源由会议类型定，不在这里换。
            if controller.showsSourceMenu {
                sourceMenu
            }
            speechMenu
            if translates {
                targetMenu
                voiceToggle
            }
            recordToggle
            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            latencyMonitor
        }
        .padding(.leading, 16)
        .padding(.trailing, 36) // 别压到右上角的关闭按钮
        .padding(.top, 7)
        // 字幕条是深色底：菜单按深色外观画（浅色字），浅色系统外观下也看得清。
        .environment(\.colorScheme, .dark)
    }

    /// 字幕区：可滚动，内容不满一屏时贴底。
    private var linesArea: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if controller.lines.isEmpty {
                            Text(controller.notice ?? L("livetranslate.bar.listening"))
                                .font(.system(size: secondarySize))
                                .foregroundStyle(.white.opacity(0.7))
                        } else {
                            ForEach(controller.lines) { line in
                                lineView(line, isCurrent: line.id == controller.lines.last?.id)
                            }
                            if let notice = controller.notice {
                                Text(notice)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.yellow.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if modelLoading {
                            loadingRow
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .bottomLeading)
                    .background(GeometryReader { content in
                        Color.clear.preference(key: BarContentFrameKey.self,
                                               value: content.frame(in: .named(Self.scrollSpace)))
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(BarContentFrameKey.self) { frame in
                    contentChanged(frame, viewportHeight: viewport.size.height, proxy: proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button {
                            following = true
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                        .help(L("livetranslate.bar.latest"))
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// 翻译模型还在加载（本次用离线模型翻译、模型进程还没就绪）：译文要等它，先告诉用户在加载、不是卡了。
    private var modelLoading: Bool {
        controller.sessionEngine == .offline && translationModel.isStartingServer
    }

    /// 加载中：转圈 + 提示，加载好就消失。
    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("livetranslate.bar.loadingModel")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        // 字幕区是深色底：转圈按深色外观画（浅色），浅色系统外观下也看得见。
        .environment(\.colorScheme, .dark)
    }

    /// 内容高度变了（来了新字、改了窗口大小）：在跟就滚到底。高度没变而位置变了：用户在翻，离底部远了就不跟。
    private func contentChanged(_ frame: CGRect, viewportHeight: CGFloat, proxy: ScrollViewProxy) {
        if abs(frame.height - contentHeight) > 0.5 {
            contentHeight = frame.height
            if following {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            following = frame.maxY <= viewportHeight + 24
        }
    }

    // MARK: - 延迟监控（右上角）

    /// 识别 / 翻译各一个数（最近 5 次的中位数）。有一截等译文比平时久时改显示它已经等了多久（带 …）：
    /// 翻译卡住时数字一直往上走，一眼看得出。每半秒刷新一次。
    private var latencyMonitor: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 8) {
                latencyText(value: controller.recognitionLatency, waiting: nil) {
                    L("livetranslate.latency.recognition \($0)")
                }
                if translates {
                    latencyText(value: controller.translationLatency,
                                waiting: controller.translationPendingSince.map { context.date.timeIntervalSince($0) }) {
                        L("livetranslate.latency.translation \($0)")
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .fixedSize()
        .help(L("livetranslate.latency.help"))
    }

    /// `waiting`：最早那截已经等了多久（只有翻译有）；比平时久就显示它。`label` 把数字套进「识别 %@」之类的文案。
    private func latencyText(value: TimeInterval?, waiting: TimeInterval?,
                             label: (String) -> String) -> some View {
        let stalled = waiting.map { $0 > max(1.5, (value ?? 0) + 1) } ?? false
        let shown = stalled ? waiting : value
        let number = (shown.map { String(format: "%.1fs", $0) } ?? "–") + (stalled ? "…" : "")
        let color: Color
        if let shown, stalled || shown >= 3 {
            color = .orange
        } else if let shown, shown >= 1.5 {
            color = .yellow.opacity(0.9)
        } else {
            color = .white.opacity(shown == nil ? 0.4 : 0.6)
        }
        return Text(verbatim: label(number)).foregroundStyle(color)
    }

    // MARK: - 快捷菜单（选了立即生效：重新开始一次，字幕条位置不变）

    private var sourceMenu: some View {
        let current = LiveTranslateSettings.source
        return Menu {
            Picker("", selection: Binding(
                get: { current },
                set: { value in
                    guard value != current else { return }
                    LiveTranslateSettings.source = value
                    controller.restartIfRunning()
                }
            )) {
                ForEach(LiveTranslateSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(current.title, systemImage: current == .microphone ? "mic" : "speaker.wave.2")
        }
        .modifier(BarMenuStyle())
    }

    /// 说话语言：自动（两种之间逐句判别）+ 常用几种 + 当前选中的（完整列表在设置页）。
    private var speechMenu: some View {
        let current = SpeechSettings.speech
        let auto = SpeechLanguages.auto(SpeechSettings.autoA, SpeechSettings.autoB)
        var languages = TranslationLanguage.common.filter { LiveTranslateSettings.speechLanguages.contains($0) }
        if case .fixed(let language) = current, !languages.contains(language) {
            languages.append(language)
        }
        return Menu {
            Picker("", selection: Binding(
                get: { Self.tag(for: current) },
                set: { tag in
                    if tag == SpeechSettings.autoValue {
                        guard current != auto else { return }
                        SpeechSettings.setAutoSpeech()
                    } else {
                        guard let language = TranslationLanguage.from(code: tag),
                              current != .fixed(language) else { return }
                        SpeechSettings.setSpeech(language)
                    }
                    controller.restartIfRunning()
                }
            )) {
                Text(auto.title).tag(SpeechSettings.autoValue)
                ForEach(languages) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(L("livetranslate.bar.speech \(current.title)"))
        }
        .modifier(BarMenuStyle())
    }

    /// 译成：常用几种 + 当前选中的。
    private var targetMenu: some View {
        let current = LiveTranslateSettings.target
        var targets = TranslationLanguage.common
        if !targets.contains(current) {
            targets.append(current)
        }
        return Menu {
            Picker("", selection: Binding(
                get: { current.code },
                set: { code in
                    guard let language = TranslationLanguage.from(code: code), language != current else { return }
                    LiveTranslateSettings.target = language
                    controller.restartIfRunning()
                }
            )) {
                ForEach(targets) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(L("livetranslate.bar.target \(current.endonym)"))
        }
        .modifier(BarMenuStyle())
    }

    /// 朗读译文：开关、送到哪个会议设备（送会议时再选要不要外放 / 原声）、音色、语速。输出相关的改了重新开始一次；
    /// 音色和语速每句现读，下一句就生效。
    private var voiceToggle: some View {
        let on = LiveTranslateVoiceSettings.enabled
        let meeting = LiveTranslateVoiceSettings.meetingDeviceUID
        // 开始时查好的（字幕条每来一个字都会重画，不能每次都去系统里枚举声卡）。
        let devices = controller.virtualDevices
        let micSource = LiveTranslateSettings.source == .microphone
        return Menu {
            Toggle(L("livetranslate.voice.enabled"), isOn: Binding(
                get: { on },
                set: { value in
                    LiveTranslateVoiceSettings.enabled = value
                    controller.restartIfRunning()
                }
            ))
            if on {
                Divider()
                Picker(L("livetranslate.voice.meeting"), selection: Binding(
                    get: { meeting },
                    set: { value in
                        guard value != meeting else { return }
                        LiveTranslateVoiceSettings.meetingDeviceUID = value
                        controller.restartIfRunning()
                    }
                )) {
                    Text("livetranslate.voice.meetingOff").tag("")
                    ForEach(devices) { device in
                        Text(verbatim: device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.inline)
                if !micSource, !meeting.isEmpty {
                    Text("livetranslate.voice.barMeetingNeedsMic")
                }
                // 不送会议时总是外放（控制器里强制），外放 / 原声两个开关只在真的送会议时才有意义。
                // 麦克风 + 外放：读的时候默认暂停识别（防回授）；戴耳机就不用。
                if micSource, meeting.isEmpty || LiveTranslateVoiceSettings.speakers {
                    Toggle(L("livetranslate.voice.keepListening"), isOn: Binding(
                        get: { LiveTranslateVoiceSettings.keepListening },
                        set: { value in
                            LiveTranslateVoiceSettings.keepListening = value
                            controller.restartIfRunning()
                        }
                    ))
                }
                if micSource, devices.contains(where: { $0.uid == meeting }) {
                    Toggle(L("livetranslate.voice.speakers"), isOn: Binding(
                        get: { LiveTranslateVoiceSettings.speakers },
                        set: { value in
                            LiveTranslateVoiceSettings.speakers = value
                            controller.restartIfRunning()
                        }
                    ))
                    Toggle(L("livetranslate.voice.mixOriginal"), isOn: Binding(
                        get: { LiveTranslateVoiceSettings.mixOriginal },
                        set: { value in
                            LiveTranslateVoiceSettings.mixOriginal = value
                            controller.restartIfRunning()
                        }
                    ))
                }
                Divider()
                // 只读译文，译文都是「译成」的那种语言。
                voiceMenu(for: LiveTranslateSettings.target)
                rateMenu
            }
        } label: {
            // 读的时候暂停着识别：直接写在按钮上（这几秒说的话不会被识别）。
            Label(controller.listeningPaused ? L("livetranslate.voice.barPaused") : L("livetranslate.voice.barToggle"),
                  systemImage: on ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(controller.listeningPaused ? Color.orange : Color.white.opacity(0.85))
        }
        .modifier(BarMenuStyle())
    }

    private func voiceMenu(for language: TranslationLanguage) -> some View {
        let key = LiveTranslateVoiceSettings.voiceKey(language)
        let current = UserDefaults.standard.string(forKey: key) ?? ""
        return Menu(L("livetranslate.voice.voiceFor \(language.endonym)")) {
            Picker("", selection: Binding(
                get: { current },
                set: { value in UserDefaults.standard.set(value, forKey: key) }
            )) {
                Text("livetranslate.voice.voiceDefault").tag("")
                ForEach(LiveTranslateVoiceSettings.voices(for: language), id: \.identifier) { voice in
                    Text(verbatim: voice.name).tag(voice.identifier)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// 语速档位（设置页里是连续的滑杆）。
    private var rateMenu: some View {
        let current = LiveTranslateVoiceSettings.rate
        let presets: [(LocalizedStringKey, Double)] = [
            ("livetranslate.voice.rateSlow", 0.45), ("livetranslate.voice.rateNormal", 0.5),
            ("livetranslate.voice.rateFast", 0.55), ("livetranslate.voice.rateFaster", 0.62),
        ]
        return Menu(L("livetranslate.voice.rate")) {
            ForEach(presets.indices, id: \.self) { index in
                let preset = presets[index]
                Toggle(isOn: Binding(
                    get: { abs(current - preset.1) < 0.02 },
                    set: { _ in LiveTranslateVoiceSettings.rate = preset.1 }
                )) {
                    Text(preset.0)
                }
            }
        }
    }

    /// 记录开关（2026-11-05 用户：菜单里操作不方便，放在字幕条上一点就切）：点一下开始 / 停止保存记录，立刻生效并记住；
    /// 旁边的小按钮打开本次记录（还没有就打开记录文件夹）。
    private var recordToggle: some View {
        let on = controller.recording
        let url = controller.transcriptURL
        return HStack(spacing: 6) {
            Button {
                // 实时翻译：开 / 关保存记录；会议：暂停 / 继续记录（与控制条同步）。
                controller.toggleBarRecording()
            } label: {
                Label(on ? L("livetranslate.record.barOn") : L("livetranslate.record.barOff"),
                      systemImage: on ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(on ? Color.red.opacity(0.9) : Color.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(controller.isHostedSession ? L("livetranslate.record.toggleHelpMeeting") : L("livetranslate.record.toggleHelp"))
            Button {
                if let url {
                    NSWorkspace.shared.open(url)
                } else {
                    LiveTranslateRecordSettings.openFolder()
                }
            } label: {
                Image(systemName: url != nil ? "doc.text" : "folder")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(url != nil ? L("livetranslate.record.openCurrent") : L("livetranslate.record.openFolder"))
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
    }

    private static func tag(for speech: SpeechLanguages) -> String {
        switch speech {
        case .auto: return SpeechSettings.autoValue
        case .fixed(let language): return language.code
        }
    }

    /// 一句字幕：全文换行显示（字幕区可滚动，长句看得到全部）；当前句亮、之前的淡。
    @ViewBuilder
    private func lineView(_ line: LiveTranslateController.Line, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !line.translates {
                // 这句本来就是「译成」的语言、不翻：原文就是要看的字幕，按主字幕的样式显示。
                primaryText(line.original)
            } else {
                switch display {
                case .both:
                    Text(line.original)
                        .font(.system(size: secondarySize))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.translation.isEmpty {
                        primaryText(line.translation)
                    }
                case .translation:
                    // 译文还没回来时先垫原文（淡色），免得字幕条空着。
                    primaryText(line.translation.isEmpty ? line.original : line.translation)
                        .opacity(line.translation.isEmpty ? 0.6 : 1)
                case .original:
                    primaryText(line.original)
                }
            }
        }
        .opacity(isCurrent ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 字幕区内容在滚动坐标系里的位置和大小（判断「在不在底部」「是不是来了新字」）。
private struct BarContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// 字幕条顶上的快捷菜单：小号、无边框、浅色字。
private struct BarMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
    }
}
