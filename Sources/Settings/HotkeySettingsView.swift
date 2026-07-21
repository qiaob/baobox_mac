import SwiftUI
import AppKit

/// 快捷键设置页：按工具分组展示，每行一个可录制的键位控件。
struct HotkeySettingsView: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject private var hotkeys = HotkeyCenter.shared

    private struct ToolGroup: Identifiable {
        let id: String
        let name: String
        let defs: [HotkeyDefinition]
    }

    private var groups: [ToolGroup] {
        // 跳过无快捷键的工具（如防休眠），避免渲染空 GroupBox。
        registry.tools
            .map { ToolGroup(id: $0.id, name: $0.name, defs: $0.hotkeys()) }
            .filter { !$0.defs.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("hotkeys.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(groups) { group in
                    GroupBox(group.name) {
                        VStack(spacing: 10) {
                            ForEach(group.defs, id: \.id) { def in
                                HotkeyRow(def: def,
                                          conflicted: hotkeys.conflictedIDs.contains(def.id))
                                if def.id != group.defs.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct HotkeyRow: View {
    let def: HotkeyDefinition
    let conflicted: Bool
    @State private var combo: KeyCombo

    init(def: HotkeyDefinition, conflicted: Bool) {
        self.def = def
        self.conflicted = conflicted
        _combo = State(initialValue: HotkeyCenter.shared.combo(for: def.id) ?? def.defaultCombo)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.title)
                if let subtitle = def.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if conflicted {
                    Text("hotkeys.conflict")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            KeyRecorder(combo: $combo) { newCombo in
                // 注册失败（系统保留组合 / App 内重复）时中心会回滚到旧键位，
                // 必须把 UI 同步回真正生效的组合，否则设置里显示 A、实际工作的是 B。
                if !HotkeyCenter.shared.update(id: def.id, to: newCombo) {
                    combo = HotkeyCenter.shared.combo(for: def.id) ?? def.defaultCombo
                    NSSound.beep()
                }
            }
            Button {
                HotkeyCenter.shared.resetToDefault(id: def.id)
                combo = HotkeyCenter.shared.combo(for: def.id) ?? def.defaultCombo
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("hotkeys.resetDefault")
        }
    }
}

// MARK: - KeyRecorder（NSViewRepresentable 包裹 RecorderView）

struct KeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo
    var onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.combo = combo
        view.onChange = { newCombo in
            combo = newCombo
            onChange(newCombo)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
    }
}

@MainActor
final class RecorderView: NSView {
    var combo = KeyCombo(keyCode: 0, carbonModifiers: 0) {
        didSet { needsDisplay = true }
    }
    var onChange: ((KeyCombo) -> Void)?

    private var recording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 26) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        // 录制期间必须挂起全局热键：Carbon 热键由 HIToolbox 在常规按键分发之前派发，
        // 不挂起则本 App 已占用的组合永远录不进来，还会顺带误触发对应工具。
        HotkeyCenter.shared.suspendAll()
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        HotkeyCenter.shared.resumeAll()
        return true
    }

    /// 录制期间拦截 key equivalent 链。否则 ⌘W / ⌘, / ⌘Q 这类组合会被菜单先消费，
    /// 根本走不到 keyDown（按 ⌘W 会直接把设置窗关掉而不是录入）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { // Esc 取消录制
            window?.makeFirstResponder(nil)
            return
        }
        if let newCombo = KeyCombo(event: event) {
            combo = newCombo
            onChange?(newCombo)
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if recording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.controlColor.setFill()
        }
        path.fill()

        path.lineWidth = recording ? 2 : 1
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = recording ? L("hotkeys.recording") : combo.display
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let color: NSColor = recording ? .controlAccentColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        str.draw(at: origin)
    }
}
