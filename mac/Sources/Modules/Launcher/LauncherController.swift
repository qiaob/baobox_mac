import AppKit
import os

// 快速入口的控制器（docs/launcher/TECH_DESIGN.md §1、§4、§5）：呼出 / 收起、一次面板会话的状态（输入、结果、选中行）、
// 按键、执行。呼出时现建命令表、取 App 索引的快照、取各模块交来的条目（剪贴板、片段）装进引擎；每次输入变化同步查一次（只读内存）；
// 执行时先记使用、收起面板，下一个 runloop 再执行 —— 很多命令作用于前台 App / 当前窗口，要等面板让开。
// 计算结果、识别结果的行不记使用：⏎ 复制，⌘⏎ 插入前台 App。

@MainActor
final class LauncherController {
    private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    /// 收起后多久内再呼出保留上次的输入。
    static let keepInputInterval: TimeInterval = 60
    /// 单次查询超过它记一条日志（设计文档 §10 验证 1 要的数据）。
    static let slowQueryThreshold: TimeInterval = 0.005
    /// ⌘1…⌘9 的 keyCode（5 和 6 是反直觉的 0x17 / 0x16，同剪贴板面板）。
    private static let digitKeyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    /// `activate()` 后多久第一次预热（剪贴板的搜索键、计算引擎和识别器的静态表）：别和启动时各模块抢主线程。
    static let firstPrewarmDelay: TimeInterval = 5

    private let apps = LauncherAppProvider()
    private let commands: LauncherCommandProvider
    private let entries: LauncherEntryProvider
    private let usage = LauncherUsageStore()
    private let engine = LauncherEngine()
    private let model = LauncherPanelModel()
    private let panel = LauncherPanel()

    /// 输入框里上屏的文字（组字中的不算）。收起后保留 60 秒。
    private var text = ""
    /// 拆掉前缀后的查询词：执行时记「这个输入选了谁」用（和排序时查的是同一个）。
    private var queryText = ""
    private var hiddenAt: Date?
    /// 这次呼出的命令和 App 条目（后台建好剪贴板的搜索键后，和条目一起重新装进引擎）。
    private var baseItems: [LauncherItem] = []

    init(registry: ToolRegistry?) {
        commands = LauncherCommandProvider(registry: registry)
        entries = LauncherEntryProvider(registry: registry)
        model.onTextChange = { [weak self] text in self?.textChanged(text) }
        model.onRun = { [weak self] index in self?.run(at: index) }
        model.iconForFile = { [weak self] path in self?.apps.icon(forPath: path) }
        entries.onKeysAdded = { [weak self] in self?.entryKeysAdded() }
    }

    /// 模块 activate：后台建 App 索引、读使用记录；几秒后预热一次。
    func activate() {
        apps.start()
        usage.load()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstPrewarmDelay) { [weak self] in
            MainActor.assumeIsolated { self?.prewarm() }
        }
    }

    /// 预热：各来源的条目先在后台建好搜索键；计算引擎和识别器先跑一次（建它们的静态表）。
    private func prewarm() {
        let start = DispatchTime.now().uptimeNanoseconds
        LauncherCalculatorProvider.warmUp(locale: L10n.locale)
        LauncherTextFormatProvider.warmUp()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        Self.log.notice("calculator and recognizers warmed up in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        entries.prewarm()
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
        baseItems = commands.items() + apps.items
        // 剪贴板、片段：取一次条目（只读内存），缺的搜索键最新的 200 条现在建，其余后台建、建完刷新一次列表。
        let entriesStart = DispatchTime.now().uptimeNanoseconds
        let report = entries.beginSession()
        let entryItems = entries.sessionItems()
        let entriesMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - entriesStart) / 1_000_000
        loadEngine(entryItems: entryItems)
        refresh()
        panel.show(LauncherPanelView(model: model), height: model.panelHeight,
                   onKey: { [weak self] event in self?.handleKey(event) ?? false },
                   onClickOutside: { [weak self] in self?.hide() })
        // 保留的上次输入：放回输入框，给焦点时全选，直接打字即覆盖。
        model.field.setText(text)
        model.field.focus()
        model.resetHoverBaseline()

        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Self.log.notice("panel shown in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms, \(self.model.rows.count, privacy: .public) rows; entries \(entriesMilliseconds, format: .fixed(precision: 1), privacy: .public) ms (\(report.entries, privacy: .public) entries, \(report.built, privacy: .public) keys built, \(report.pending, privacy: .public) pending)")
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.hide()
        hiddenAt = Date()
        engine.clear()
        baseItems = []
        entries.endSession()
    }

    private func loadEngine(entryItems: [LauncherItem]) {
        engine.load(baseItems + entryItems,
                    sourceIDs: Set([LauncherAppProvider.sourceID, LauncherCommandProvider.sourceID])
                        .union(entries.sessionSourceIDs))
    }

    /// 后台建好了一批条目的搜索键、面板还开着：重新装一次，同一个输入再查一次（选中的行还在就留在它上面）。
    private func entryKeysAdded() {
        guard panel.isVisible else { return }
        loadEngine(entryItems: entries.sessionItems())
        refresh(keepSelection: true)
        panel.setHeight(model.panelHeight)
    }

    // MARK: - 查询

    private func textChanged(_ newText: String) {
        guard panel.isVisible, newText != text else { return }
        text = newText
        refresh()
        panel.setHeight(model.panelHeight)
    }

    private func refresh(keepSelection: Bool = false) {
        let outcome = engine.search(text, records: usage.records, now: Date())
        queryText = outcome.queryText
        if outcome.duration > Self.slowQueryThreshold {
            Self.log.notice("slow query: \(outcome.duration * 1000, format: .fixed(precision: 2), privacy: .public) ms, \(outcome.candidateCount, privacy: .public) candidates")
        }
        model.setRows(outcome.rows, emptyInput: outcome.queryText.isEmpty, keepSelection: keepSelection)
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
        case 0x24, 0x4C: // Return / 小键盘 Enter；⌘⏎ 在计算结果、识别结果上 = 插入前台 App，其余行同 ⏎
            if flags.contains(.command) {
                insertOrRun(at: model.selectedIndex)
            } else {
                run(at: model.selectedIndex)
            }
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
        guard model.rows.indices.contains(index) else { return }
        let id = model.rows[index].id
        if let instant = engine.instant(forKey: id) {
            copy(instant)
            return
        }
        guard let item = engine.item(forKey: id) else { return }
        usage.recordUse(key: item.candidate.key, input: queryText, now: Date())
        hide()
        let action = item.run
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action() }
        }
    }

    /// ⌘⏎：计算结果、识别结果插入前台 App（和听写、划词助手同一条路：能直接写进输入框就写，不行借剪贴板粘贴，
    /// 都不行就复制并提示）；其余行同 ⏎。
    private func insertOrRun(at index: Int) {
        guard model.rows.indices.contains(index) else { return }
        guard let instant = engine.instant(forKey: model.rows[index].id) else {
            run(at: index)
            return
        }
        guard let text = instant.copyText else { return }
        hide()
        // 下一个 runloop 再插：等面板让开、焦点回到原来的输入框。
        DispatchQueue.main.async {
            Task { @MainActor in
                let result = await TextInserter.insert(text)
                if !result.inserted { Self.toast(L("launcher.toast.insertCopied")) }
            }
        }
    }

    /// ⏎：复制结果并收起（普通复制，进剪贴板历史：这是用户要的一份新内容），给一句回执。出错的结果不做事。
    private func copy(_ instant: LauncherInstant) {
        guard let text = instant.copyText else { return }
        TextInserter.copyToClipboard(text)
        hide()
        Self.toast(L("launcher.toast.copied \(LauncherConversions.singleLine(text, maxLength: 40))"))
    }

    /// 回执（同防休眠开关的回执：宠物开着是宠物气泡，否则系统通知；勿扰时照常显示）。
    private static func toast(_ text: String) {
        NotifyCenter.shared.post(Notice(source: "launcher", level: .ambient, title: text,
                                        icon: "doc.on.doc", isUserFeedback: true))
    }
}
