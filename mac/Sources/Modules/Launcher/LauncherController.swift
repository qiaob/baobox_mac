import AppKit
import os

// 快速入口的控制器（docs/launcher/TECH_DESIGN.md §1、§4、§5）：呼出 / 收起、一次面板会话的状态（输入、结果、选中行）、
// 按键、执行。呼出时现建命令表、取 App 索引的快照装进引擎；每次输入变化同步查一次（只读内存）；
// 执行时先记使用、收起面板，下一个 runloop 再执行 —— 很多命令作用于前台 App / 当前窗口，要等面板让开。

@MainActor
final class LauncherController {
    private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    /// 收起后多久内再呼出保留上次的输入。
    static let keepInputInterval: TimeInterval = 60
    /// 单次查询超过它记一条日志（设计文档 §10 验证 1 要的数据）。
    static let slowQueryThreshold: TimeInterval = 0.005
    /// ⌘1…⌘9 的 keyCode（5 和 6 是反直觉的 0x17 / 0x16，同剪贴板面板）。
    private static let digitKeyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    private let apps = LauncherAppProvider()
    private let commands: LauncherCommandProvider
    private let usage = LauncherUsageStore()
    private let engine = LauncherEngine()
    private let model = LauncherPanelModel()
    private let panel = LauncherPanel()

    /// 输入框里上屏的文字（组字中的不算）。收起后保留 60 秒。
    private var text = ""
    /// 拆掉前缀后的查询词：执行时记「这个输入选了谁」用（和排序时查的是同一个）。
    private var queryText = ""
    private var hiddenAt: Date?

    init(registry: ToolRegistry?) {
        commands = LauncherCommandProvider(registry: registry)
        model.onTextChange = { [weak self] text in self?.textChanged(text) }
        model.onRun = { [weak self] index in self?.run(at: index) }
        model.iconForFile = { [weak self] path in self?.apps.icon(forPath: path) }
    }

    /// 模块 activate：后台建 App 索引、读使用记录。
    func activate() {
        apps.start()
        usage.load()
    }

    /// 模块 willTerminate：同步写掉没落盘的使用记录。
    func willTerminate() {
        usage.flush()
        apps.stop()
    }

    var isVisible: Bool { panel.isVisible }

    /// 快捷键：按一次呼出、再按一次收起。
    func toggle() {
        let start = DispatchTime.now()
        if panel.isVisible {
            hide()
        } else {
            show(startedAt: start)
        }
    }

    /// 呼出（菜单「打开快速入口」也走这里）。已经开着就什么都不做。
    func show(startedAt start: DispatchTime = .now()) {
        guard !panel.isVisible else { return }
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) >= Self.keepInputInterval {
            text = ""
        }
        engine.load(commands.items() + apps.items,
                    sourceIDs: [LauncherAppProvider.sourceID, LauncherCommandProvider.sourceID])
        refresh()
        panel.show(LauncherPanelView(model: model), height: model.panelHeight,
                   onKey: { [weak self] event in self?.handleKey(event) ?? false },
                   onClickOutside: { [weak self] in self?.hide() })
        // 保留的上次输入：放回输入框，给焦点时全选，直接打字即覆盖。
        model.field.setText(text)
        model.field.focus()
        model.resetHoverBaseline()

        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Self.log.notice("panel shown in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(self.model.rows.count, privacy: .public) rows")
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.hide()
        hiddenAt = Date()
        engine.clear()
    }

    // MARK: - 查询

    private func textChanged(_ newText: String) {
        guard panel.isVisible, newText != text else { return }
        text = newText
        refresh()
        panel.setHeight(model.panelHeight)
    }

    private func refresh() {
        let outcome = engine.search(text, records: usage.records, now: Date())
        queryText = outcome.queryText
        if outcome.duration > Self.slowQueryThreshold {
            Self.log.notice("slow query: \(outcome.duration * 1000, format: .fixed(precision: 2), privacy: .public) ms, \(outcome.candidateCount, privacy: .public) candidates")
        }
        model.setRows(outcome.rows, emptyInput: outcome.queryText.isEmpty)
    }

    // MARK: - 按键

    /// 面板的 keyDown；返回 true = 已处理。输入法正在组字时全部交给它（⏎ 是上屏、↑ ↓ 是选候选词、Esc 是取消组字）。
    private func handleKey(_ event: NSEvent) -> Bool {
        if model.field.isComposing { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 0x7E: // ↑
            model.moveSelection(by: -1)
            return true
        case 0x7D: // ↓
            model.moveSelection(by: 1)
            return true
        case 0x24, 0x4C: // Return / 小键盘 Enter
            run(at: model.selectedIndex)
            return true
        case 0x35: // Esc
            hide()
            return true
        case 0x30: // Tab：先吃掉，以后是「问 AI」
            return true
        default:
            // ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z：面板是 key 但 Baobox 不是前台 App（nonactivating），主菜单「编辑」里的
            // 快捷键这时不生效，粘贴没反应。这里直接把编辑动作交给输入框的编辑器。
            if let handled = performEditShortcut(event, flags: flags) { return handled }
            // ⌘1…⌘9：直接执行第 N 行。
            if flags.contains(.command), flags.isDisjoint(with: [.control, .option]),
               let slot = Self.digitKeyCodes.firstIndex(of: event.keyCode) {
                run(at: slot)
                return true
            }
            return false
        }
    }

    /// 标准编辑快捷键。返回 nil = 不是编辑快捷键（交给后面的规则）；否则是「处理了没有」。
    private func performEditShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shift = flags.contains(.shift)
        let edit: LauncherFieldHandle.Edit
        switch (key, shift) {
        case ("v", false): edit = .paste
        case ("c", false): edit = .copy
        case ("x", false): edit = .cut
        case ("a", false): edit = .selectAll
        case ("z", false): edit = .undo
        case ("z", true): edit = .redo
        default: return nil
        }
        let handled = model.field.perform(edit)
        Self.log.notice("edit shortcut \(key, privacy: .public) handled: \(handled, privacy: .public)")
        return handled
    }

    // MARK: - 执行

    private func run(at index: Int) {
        guard model.rows.indices.contains(index), let item = engine.item(forKey: model.rows[index].id) else { return }
        usage.recordUse(key: item.candidate.key, input: queryText, now: Date())
        hide()
        let action = item.run
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action() }
        }
    }
}
