import AppKit
import SwiftUI

/// 长听写的收集面板状态（需求 §1、技术设计 §7）。只在主线程改。
@MainActor
final class DictationCollectModel: ObservableObject {
    /// 收集到的文字（可编辑）。
    @Published var text = ""
    @Published var listening = false
    /// 收尾中：等最后一段定稿 / 正在插入。
    @Published var busy = false
    /// 有段落在等 AI 润色。
    @Published var polishing = false
    /// 正在说的这一段（还没定稿）。
    @Published var preview = ""
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0

    var onInsert: () -> Void = {}
    var onCopy: () -> Void = {}
    var onClear: () -> Void = {}
    /// 听着 → 结束；停着 → 继续听写。
    var onToggleListening: () -> Void = {}
    /// 用户点了窗口的关闭按钮。
    var onClose: () -> Void = {}

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 收集面板窗口：要编辑文字，所以能成为 key；`.nonactivatingPanel` 保证不把 Baobox 切到前台、
/// 用户可以接着在原来的 App 里干活（插入前再把焦点还给它）。
private final class DictationCollectWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DictationCollectPanelController: NSObject, NSWindowDelegate {
    let model = DictationCollectModel()
    private let panel: DictationCollectWindow
    private var shown = false

    static let defaultSize = NSSize(width: 460, height: 320)

    override init() {
        let size = Self.defaultSize
        let panel = DictationCollectWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = L("dictation.collect.title")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 220)
        panel.contentView = NSHostingView(rootView: DictationCollectView(model: model))
        self.panel = panel
        super.init()
        panel.delegate = self
    }

    /// 显示在鼠标所在屏的右下角（第一次）；之后保持用户拖到的位置。不抢焦点。
    func show() {
        if !shown {
            shown = true
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24))
            }
        }
        panel.orderFrontRegardless()
    }

    /// 程序收起（插入 / 复制之后）：不走 windowWillClose。
    func close() {
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.onClose()
    }
}

// MARK: - 视图

struct DictationCollectView: View {
    @ObservedObject var model: DictationCollectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("dictation.collect.placeholder")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button("dictation.collect.clear", action: model.onClear)
                    .disabled(model.isEmpty || model.busy)
                Spacer()
                Button("dictation.collect.copy", action: model.onCopy)
                    .disabled(model.isEmpty || model.busy)
                Button("dictation.collect.insert", action: model.onInsert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isEmpty || model.busy)
                Group {
                    if model.listening {
                        Button("dictation.collect.stop", action: model.onToggleListening)
                    } else {
                        Button("dictation.collect.resume", action: model.onToggleListening)
                    }
                }
                .disabled(model.busy)
            }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 220)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text("dictation.collect.finishing")
                    .font(.callout)
            } else if model.listening {
                Image(systemName: "mic.fill")
                    .foregroundStyle(DictationCollectView.accent)
                DictationCollectMeter(level: model.level)
                Text(verbatim: DictationBarView.clock(model.elapsed))
                    .font(.callout.monospacedDigit())
            } else {
                Image(systemName: "mic.slash")
                    .foregroundStyle(.secondary)
                Text("dictation.collect.paused")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.polishing {
                Text("dictation.collect.polishing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: model.listening ? model.preview : "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 20)
    }

    /// 浅色窗口里用浅色主题的 accent，深色模式下用深色主题的。
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2B / 255, green: 0xC4 / 255, blue: 0xB8 / 255, alpha: 1)
            : NSColor(srgbRed: 0x17 / 255, green: 0xA3 / 255, blue: 0x98 / 255, alpha: 1)
    })
}

/// 收集面板里的电平表（跟随窗口外观的配色）。
private struct DictationCollectMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Float(index) < level * 5 - 0.25 ? DictationCollectView.accent : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(6 + index % 3 * 4))
            }
        }
        .frame(height: 16)
    }
}
