import AppKit
import SwiftUI

/// 控制条窗口：不抢焦点（nonactivating）、置顶、跨 Space、全屏 App 上可见。只有速记展开时才能成为 key（要打字），
/// 仍然不激活 Baobox —— 前台 App 还是会议软件。
private final class MeetingControlPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// 会议控制条（docs/meeting/TECH_DESIGN.md §3）：记录期间常驻的小浮条。经 `AccessoryDock` 找挂靠点：宠物开着时挂在宠物头顶、
/// 跟着宠物走（要挪就拖宠物）；挂不上（宠物关着、宠物模块没注册）时在屏幕顶部居中，可拖动（记住位置）。
/// `● REC 时长 · 类型 · 两路电平点 | 暂停 / 继续 · 标记重点 · 速记 · 字幕 | 结束`；速记展开一个内嵌编辑区。
@MainActor
final class MeetingControlBarController {
    private var panel: MeetingControlPanel?
    private var observers: [NSObjectProtocol] = []
    /// 挂在宠物头顶：位置归宠物管，自己不能拖、不记位置。
    private var docked = false
    /// 程序自己在摆位置（不是用户拖的），别记下来。
    private var placing = false

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            if docked { AccessoryDock.refresh(panel) }
            return
        }
        let hosting = NSHostingView(rootView: Self.makeView())
        // 窗口大小由我们按内容量好了设（`refreshSize`），上边不动地往下长 —— 不让 AppKit 按内容自动改窗口（那样是往上长）。
        let size = Self.measure()
        hosting.sizingOptions = []
        let panel = MeetingControlPanel(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        // 先设别的、最后设 level（别再碰 isFloatingPanel：它的 setter 会把 level 改回 .floating）。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(Self.initialFrame(size: size), display: false)
        self.panel = panel
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveOrigin()
            }
        }
        observers.append(observer)
        // 宠物开着就挂到它头顶；宠物关着、或开会中途被关掉时，回到上面摆的位置。先挂好再显示，免得从屏幕顶上跳过去。
        AccessoryDock.dock(panel) { [weak self] docked in
            self?.setDocked(docked)
        }
        panel.orderFrontRegardless()
    }

    private func setDocked(_ docked: Bool) {
        self.docked = docked
        guard let panel else { return }
        panel.isMovableByWindowBackground = !docked
        guard !docked else { return }
        placing = true
        panel.setFrame(Self.initialFrame(size: Self.measure()), display: true)
        placing = false
        panel.orderFrontRegardless()
    }

    func hide() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let panel { AccessoryDock.undock(panel) }
        docked = false
        panel?.acceptsKey = false
        panel?.orderOut(nil)
        panel = nil
    }

    /// 速记展开：允许成为 key 并接收键盘输入；收起：交还焦点给原来的 App（重新排一次窗口就不再是 key）。
    func setNotesExpanded(_ expanded: Bool) {
        guard let panel else { return }
        panel.acceptsKey = expanded
        if expanded {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
            // orderOut 会把子窗口从宠物窗上摘下来：挂着的话重新挂回去。
            if docked { AccessoryDock.refresh(panel) }
        }
    }

    /// 内容变了（开始 / 记录中 / 暂停 / 收尾、速记展开收起、字幕开关、标记数）：下一拍按新内容量一次，上边与左边不动。
    /// 下一拍再量：调用方此刻刚改完状态，SwiftUI 还没重算。
    func refreshSize() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.resizeToContent()
            }
        }
    }

    private func resizeToContent() {
        guard let panel else { return }
        let size = Self.measure()
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        if docked {
            // 在宠物头顶时底边贴着头顶往上长（在脚下时往下长）：交给宠物按新大小重新贴位。
            AccessoryDock.refresh(panel, size: size)
            return
        }
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    private static func makeView() -> MeetingControlBarView {
        let session = MeetingSessionController.shared
        return MeetingControlBarView(session: session, levels: session.levels)
    }

    /// 按此刻的状态量内容大小：新建一个不进窗口的宿主视图，它当场按当前状态排版（窗口里那个要等下一次重绘）。
    private static func measure() -> CGSize {
        let size = NSHostingView(rootView: makeView()).fittingSize
        return size.width > 1 && size.height > 1 ? size : fallbackSize
    }

    /// 记住位置（左上角：展开速记会改高度，记左下角的话下次位置会跳）。
    func saveOrigin() {
        guard let panel, !docked, !placing else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: MeetingSettings.controlBarOriginKey)
    }

    /// 量不出来时的初始大小（内容报上来尺寸后马上改成实际的）。
    private static let fallbackSize = CGSize(width: 520, height: 40)

    /// 上次的位置还在某块屏内就沿用；否则放鼠标所在屏的顶部居中（菜单栏下面）。两种都不进屏幕顶上那条（`topInset`）。
    private static func initialFrame(size: CGSize) -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: MeetingSettings.controlBarOriginKey) {
            let topLeft = NSPointFromString(saved)
            var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            let probe = NSPoint(x: frame.minX + 20, y: frame.maxY - 10)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(probe, $0.visibleFrame, false) }) {
                frame.origin.y = min(frame.origin.y, screen.frame.maxY - topInset(of: screen) - size.height)
                return frame
            }
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(x: screen.visibleFrame.midX - size.width / 2,
                      y: screen.frame.maxY - topInset(of: screen) - 12 - size.height,
                      width: size.width, height: size.height)
    }

    /// 屏幕顶上要让开的高度。平时就是菜单栏；可全屏 App 里菜单栏收起，visibleFrame 一直顶到屏幕边，
    /// 带刘海的屏顶上那条（safeAreaInsets）全屏时是黑的 —— 2026-11-06 真机：Chrome 全屏开 Google Meet，
    /// 黑底的控制条落进刘海那条黑带，整个看不见。没刘海的屏全屏时菜单栏也会滑下来盖住顶上，至少让开一个菜单栏高。
    private static func topInset(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }
}

/// 控制条内容（深色底，浅色字）。
struct MeetingControlBarView: View {
    @ObservedObject var session: MeetingSessionController
    @ObservedObject var levels: MeetingLevelMeter
    @FocusState private var notesFocused: Bool

    private var busy: Bool { session.phase == .starting || session.phase == .finishing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                recordingIndicator
                if let type = session.type {
                    Text(verbatim: MeetingText.typeBadge(type))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                levelDots
                separator
                iconButton(session.phase == .paused ? "play.fill" : "pause.fill",
                           help: session.phase == .paused ? L("meeting.bar.resume") : L("meeting.bar.pause"),
                           active: session.phase == .paused, disabled: !session.isRecording) {
                    session.togglePause()
                }
                markButton
                iconButton("square.and.pencil", help: L("meeting.bar.notes"), active: session.notesExpanded,
                           disabled: !session.isActive) {
                    session.toggleNotes()
                }
                subtitlesButton
                separator
                Button {
                    session.finish()
                } label: {
                    Label(L("meeting.bar.finish"), systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.phase == .finishing ? Color.white.opacity(0.4) : Color.red.opacity(0.95))
                }
                .buttonStyle(.plain)
                .disabled(session.phase == .finishing)
                .help(L("meeting.bar.finishHelp"))
            }
            if session.notesExpanded {
                notesEditor
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        // 深色底：控件按深色外观画，浅色系统外观下也看得清。
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// `● REC 32:15`（暂停：灰色 ‖；开始中 / 收尾中：说明文字）。
    private var recordingIndicator: some View {
        HStack(spacing: 6) {
            switch session.phase {
            case .starting, .finishing, .idle:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(session.phase == .finishing ? L("meeting.bar.finishing") : L("meeting.bar.starting"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            case .recording, .paused:
                Circle()
                    .fill(session.phase == .paused ? Color.gray : Color.red)
                    .frame(width: 8, height: 8)
                Text(session.phase == .paused ? L("meeting.bar.paused") : L("meeting.bar.rec"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(session.phase == .paused ? Color.white.opacity(0.6) : Color.red.opacity(0.95))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // 按「0:00:00」占位：过了一小时多出几位，宽度也不变（窗口大小只在状态变时才重量）。
                    ZStack(alignment: .leading) {
                        Text(verbatim: "0:00:00").hidden()
                        Text(verbatim: MeetingText.clock(session.elapsed(at: context.date)))
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }

    /// 麦克风 / 系统声音两个图标：有声音亮（绿），没声音或暂停变灰；点一下单独不录这一路（红色带斜杠），再点恢复。
    /// 线下会议没有系统声音那一个。
    private var levelDots: some View {
        HStack(spacing: 2) {
            levelToggle(on: "mic.fill", off: "mic.slash.fill", active: levels.microphoneActive,
                        muted: session.microphoneMuted,
                        help: session.microphoneMuted ? L("meeting.bar.micUnmute") : L("meeting.bar.micMute")) {
                session.toggleMicrophoneMuted()
            }
            if session.type == .online {
                levelToggle(on: "speaker.wave.2.fill", off: "speaker.slash.fill", active: levels.systemActive,
                            muted: session.systemMuted,
                            help: session.systemMuted ? L("meeting.bar.systemUnmute") : L("meeting.bar.systemMute")) {
                    session.toggleSystemMuted()
                }
            }
        }
    }

    private func levelToggle(on: String, off: String, active: Bool?, muted: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: muted ? off : on)
                .font(.system(size: 11))
                .foregroundStyle(muted ? Color.red.opacity(0.9) : active == true ? Color.green : Color.white.opacity(0.35))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isActive || session.phase == .finishing)
        .help(help)
    }

    private var markButton: some View {
        Button {
            session.mark()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bookmark.fill")
                if !session.marks.isEmpty {
                    Text(verbatim: "\(session.marks.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(session.isRecording ? Color.yellow.opacity(0.9) : Color.white.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!session.isRecording)
        .help(L("meeting.bar.mark"))
    }

    private var subtitlesButton: some View {
        Button {
            session.toggleSubtitles()
        } label: {
            Label(L("meeting.bar.subtitles"), systemImage: "captions.bubble")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(session.subtitlesOn ? Color.accentColor.opacity(0.55) : Color.clear))
                .foregroundStyle(busy ? Color.white.opacity(0.3) : Color.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .disabled(session.phase == .finishing)
        .help(L("meeting.bar.subtitlesHelp"))
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(
                get: { session.notes },
                set: { session.setNotes($0) }
            ))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($notesFocused)
            .frame(width: 440, height: 120)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .onAppear { notesFocused = true }
            .onExitCommand { session.toggleNotes() }
            Text("meeting.bar.notesHint")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 0.5, height: 16)
    }

    private func iconButton(_ symbol: String, help: String, active: Bool, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
                .foregroundStyle(disabled ? Color.white.opacity(0.3)
                                 : (active ? Color.accentColor : Color.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
