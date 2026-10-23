import AppKit
import SwiftUI

/// 字幕条窗口：不抢焦点、置顶、跨 Space、全屏 App 上可见，可拖动。
private final class LiveTranslateBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 字幕条的显示 / 隐藏与位置记忆。每次开始翻译新建一个（翻译会话配置跟着字幕条走）。
@MainActor
final class LiveTranslateBarController {
    private let panel: LiveTranslateBarPanel
    private var moveObserver: NSObjectProtocol?
    /// 本次是否挂了翻译会话。
    let translates: Bool

    init(controller: LiveTranslateController, translationPair: (source: String, target: String)?) {
        translates = translationPair != nil && LiveTranslateSettings.translationSupported
        let screen = Self.targetScreen()
        let width = min((screen?.visibleFrame.width ?? 1200) * 0.7, 1200)
        let view = LiveTranslateBarView(controller: controller,
                                        translates: translates,
                                        width: width)
            .liveTranslateTask(translates ? translationPair : nil, translator: controller.translator)

        let panel = LiveTranslateBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
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
        // NSHostingView 默认按内容尺寸撑窗口：字号 / 显示样式变化时高度自动跟着变。
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
    }

    func show() {
        panel.setFrameOrigin(initialOrigin())
        panel.orderFrontRegardless()
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveOrigin()
            }
        }
    }

    func hide() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        moveObserver = nil
        panel.orderOut(nil)
    }

    // MARK: - 位置

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    }

    /// 上次拖到的位置仍在某块屏内就沿用，否则放鼠标所在屏底部居中。
    private func initialOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: LiveTranslateSettings.barOriginKey) {
            let origin = NSPointFromString(saved)
            let probe = NSPoint(x: origin.x + 20, y: origin.y + 20)
            if NSScreen.screens.contains(where: { NSMouseInRect(probe, $0.visibleFrame, false) }) {
                return origin
            }
        }
        guard let visible = Self.targetScreen()?.visibleFrame else { return .zero }
        return NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 60)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: LiveTranslateSettings.barOriginKey)
    }
}

/// 字幕条内容：最近两句，上一句淡出；长句只看得到最新的部分（头部截断）。
private struct LiveTranslateBarView: View {
    @ObservedObject var controller: LiveTranslateController
    let translates: Bool
    let width: CGFloat

    @AppStorage(LiveTranslateSettings.displayKey) private var displayRaw = LiveTranslateDisplay.both.rawValue
    @AppStorage(LiveTranslateSettings.fontSizeKey) private var fontSize = LiveTranslateSettings.defaultFontSize
    @AppStorage(LiveTranslateSettings.opacityKey) private var opacity = LiveTranslateSettings.defaultOpacity

    /// 不翻译时一律按「仅原文」显示。
    private var display: LiveTranslateDisplay {
        guard translates else { return .original }
        return LiveTranslateDisplay(rawValue: displayRaw) ?? .both
    }

    private var secondarySize: CGFloat { CGFloat(fontSize) * 0.7 }

    /// 固定高度，避免每来一个字窗口就跳一下：两句 × 每句可见行数。
    private var height: CGFloat {
        let size = CGFloat(fontSize)
        let perLine: CGFloat
        switch display {
        case .both: perLine = (secondarySize + size) * 1.3 + 4
        case .translation, .original: perLine = size * 1.3
        }
        return perLine * 3 + 36
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
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
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Button {
                controller.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(L("livetranslate.bar.close"))
            .padding(8)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(opacity))
        )
    }

    @ViewBuilder
    private func lineView(_ line: LiveTranslateController.Line, isCurrent: Bool) -> some View {
        // 当前句给两行，上一句一行。
        let limit = isCurrent ? 2 : 1
        VStack(alignment: .leading, spacing: 2) {
            switch display {
            case .both:
                Text(line.original)
                    .font(.system(size: secondarySize))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
                if !line.translation.isEmpty {
                    Text(line.translation)
                        .font(.system(size: CGFloat(fontSize), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(limit)
                        .truncationMode(.head)
                }
            case .translation:
                // 译文还没回来时先垫原文（淡色），免得字幕条空着。
                Text(line.translation.isEmpty ? line.original : line.translation)
                    .font(.system(size: CGFloat(fontSize), weight: .semibold))
                    .foregroundStyle(.white.opacity(line.translation.isEmpty ? 0.6 : 1))
                    .lineLimit(limit)
                    .truncationMode(.head)
            case .original:
                Text(line.original)
                    .font(.system(size: CGFloat(fontSize), weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(limit)
                    .truncationMode(.head)
            }
        }
        .opacity(isCurrent ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
