import AppKit
import SwiftUI

/// 录音条上显示什么（需求 §2）。只在主线程改。
@MainActor
final class DictationBarModel: ObservableObject {
    enum Phase: Equatable {
        /// 正在听：电平、计时、实时预览、提示。
        case listening
        /// 收尾中（识别 / 润色）：转圈 + 这句话。
        case working(String)
        /// 结束后的结果：已插入 / 已复制（`detail` = 为什么没能直接插入）。
        case result(inserted: Bool, detail: String?)
        /// 一句话就完（没听到内容、出错）。
        case message(String)
    }

    @Published var phase: Phase = .listening
    /// 「松开结束」「再按一次结束 · Esc 取消」。
    @Published var hint = ""
    /// 正在识别的文字（显示尾部一行）。
    @Published var preview = ""
    /// 正在听、还没有文字时第二行的提示；空 = 「请开始说话…」（连续听写换成「说完一句停一下就上屏」）。
    @Published var placeholder = ""
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0

    var onCancel: () -> Void = {}
    var onCopy: () -> Void = {}
}

/// 录音条窗口：**绝不抢焦点** —— 文字要进的那个 App 一直保持焦点（技术设计 §0，照 RecordingHUD）。
private final class DictationBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 非激活面板里的按钮第一击就要响应（不用先点一下激活窗口）。
final class DictationBarHostingView: NSHostingView<DictationBarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 录音条的显示 / 位置 / 收起。每次听写新建一个。
@MainActor
final class DictationBarController {
    let model = DictationBarModel()
    private let panel: DictationBarPanel
    private var hideWork: DispatchWorkItem?

    init() {
        let size = DictationBarView.size
        let panel = DictationBarPanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        // 不要在设 level 之后再设 isFloatingPanel：它的 setter 会把 level 改回 .floating。
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = DictationBarHostingView(rootView: DictationBarView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    /// 显示：`caret`（AppKit 坐标）有就贴在光标下方（放不下放上方），没有就放鼠标所在屏的底部居中。
    func show(near caret: CGRect?) {
        hideWork?.cancel()
        hideWork = nil
        panel.setFrame(Self.frame(size: DictationBarView.size, caret: caret), display: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel.orderOut(nil)
    }

    /// 到点自动收起后调用（控制器据此放掉这个录音条）。
    var onAutoHide: (() -> Void)?

    /// `seconds` 后收起；鼠标停在条上（要点「复制」）时往后推。
    func hide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                    self.hide(after: 1)
                    return
                }
                self.hide()
                self.onAutoHide?()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func frame(size: NSSize, caret: CGRect?) -> NSRect {
        let margin: CGFloat = 8
        if let caret, let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret.insetBy(dx: -1, dy: -1)) }) {
            let visible = screen.visibleFrame
            var x = caret.minX - 20
            x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
            var y = caret.minY - size.height - 10
            if y < visible.minY + margin { y = caret.maxY + 10 }
            y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.midX - size.width / 2, y: visible.minY + 56, width: size.width, height: size.height)
    }
}

// MARK: - 视图

/// 录音条内容：上一行状态（电平 / 计时 / 提示，或结果）+ ✕；下一行文字（尾部一行）。
struct DictationBarView: View {
    @ObservedObject var model: DictationBarModel

    static let size = NSSize(width: 380, height: 58)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                status
                Spacer(minLength: 4)
                if case .result = model.phase {
                    Button(action: model.onCopy) {
                        Text("dictation.bar.copy")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                Button(action: model.onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(L("dictation.bar.cancel"))
            }
            if !isMessage {
                Text(verbatim: secondLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(secondLineIsPlaceholder ? 0.45 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1, opacity: 0.93)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DictationPalette.accent)
            DictationLevelMeter(level: model.level)
            Text(verbatim: DictationBarView.clock(model.elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            if !model.hint.isEmpty {
                Text(verbatim: model.hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        case .working(let title):
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .frame(width: 16, height: 16)
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        case .result(let inserted, _):
            Image(systemName: inserted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(inserted ? DictationPalette.accent : Color.orange)
            Group {
                if inserted {
                    Text("dictation.bar.inserted")
                } else {
                    Text("dictation.bar.copied")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
        case .message(let text):
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(verbatim: text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var secondLine: String {
        switch model.phase {
        case .listening:
            guard model.preview.isEmpty else { return model.preview }
            return model.placeholder.isEmpty ? L("dictation.bar.placeholder") : model.placeholder
        case .working:
            return model.preview
        case .result(_, let detail):
            return detail ?? model.preview
        case .message:
            return model.preview
        }
    }

    /// 只有一句话（没听到内容、出错）：不留第二行，整条居中。
    private var isMessage: Bool {
        if case .message = model.phase { return true }
        return false
    }

    private var secondLineIsPlaceholder: Bool {
        if case .listening = model.phase { return model.preview.isEmpty }
        if case .result(_, let detail) = model.phase { return detail != nil }
        return false
    }

    /// 计时：0:07、1:23。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 五格电平表。
struct DictationLevelMeter: View {
    let level: Float

    private static let heights: [CGFloat] = [6, 10, 14, 10, 6]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(lit(index) ? DictationPalette.accent : Color.white.opacity(0.22))
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// 中间那格先亮，向两边扩。
    private func lit(_ index: Int) -> Bool {
        let order = [3, 1, 0, 2, 4]
        return Float(order[index]) < level * 5 - 0.25
    }

    private func height(_ index: Int) -> CGFloat {
        let base = Self.heights[index]
        return max(4, base * (0.55 + 0.45 * CGFloat(min(max(level, 0), 1))))
    }
}

/// 设计令牌（docs/design/ui-design-v1.html）：录音条是深色底，用深色主题的 accent。
enum DictationPalette {
    static let accent = Color(red: 0x2B / 255, green: 0xC4 / 255, blue: 0xB8 / 255)
}
