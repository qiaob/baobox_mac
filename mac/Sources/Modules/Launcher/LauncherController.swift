import AppKit
import os

// 快速入口的控制器（docs/launcher/TECH_DESIGN.md §1、§4、§5）：呼出 / 收起、一次面板会话的状态（输入、结果、选中行）、
// 按键、执行。呼出时现建命令表、取 App 索引的快照、取各模块交来的条目（剪贴板、片段）装进引擎；每次输入变化同步查一次（只读内存）；
// 执行时先记使用、收起面板，等焦点真的回到原来的 App 再执行（`LauncherFocus.restore(then:)`）—— 很多命令作用于前台 App / 当前窗口。
// 计算结果、识别结果的行不记使用：⏎ 复制，⌘⏎ 插入前台 App。
// 输入是路径时（§6.5）引擎只出路径的行，路径在后台查（`LauncherPathProvider`），查完再刷新一次；
// 路径行 ⌘⏎ 在访达里显示、Tab 把输入框换成选中行的完整路径。
// 文件按名字搜（§6.4）：引擎说要搜什么，控制器交给 `LauncherFileProvider`（防抖、四个来源合并、过滤排序），每回来一批刷新一次；
// 四个来源的数据（自己扫的目录、已知文件、剪贴板里的路径）由 `LauncherFileSources` 在呼出时 / 后台准备（PR 11）。
// 建议行（§5.4）：呼出时收一次各模块的文字动作交给引擎；颜色、字数这类复制行同计算结果，其余建议行 ⏎ / ⌘⏎ 都是执行。
// 图片（§5.5）：⌘V 时先看剪贴板里是什么（`LauncherPasteClassifier`）—— 图片挂成输入里的附件（输入框左边一个小标签），
// 挂上那一下在后台取一次字；挂着时列表里只有这张图的建议，输入框里的字是筛选词；⌫（输入框为空时）/ Esc 去掉，收起即丢。
// 访达里复制的文件 → 输入框换成它的路径（走路径行；图片文件的路径行后面接图片动作）。拖到面板上放下的同样处理。
// 剪贴板历史里的图片条目（`c ` 前缀下）：行首缩略图在后台取（`LauncherThumbnailProvider`），⏎ 粘贴，Tab 挂成附件。
// 输入框为空时（§3.7，`LauncherContextProvider`）：最前面是「选中的」（呼出前那个 App 里选中的文字，后台读、80 ms 封顶，
// 读到了再补上那一行）和「刚复制的」（剪贴板最新一条，5 分钟内），⏎ / Tab 放进输入框；接着是各模块的情景建议。

@MainActor
final class LauncherController {
    private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    /// 收起后多久内再呼出保留上次的输入。
    static let keepInputInterval: TimeInterval = 60
    /// 单次查询超过它记一条日志（设计文档 §10 验证 1 要的数据）。
    static let slowQueryThreshold: TimeInterval = 0.005
    /// 挂着的图片的缩略图最长边（像素）：标签里约 28pt 高，Retina 上两倍。
    nonisolated static let attachmentThumbnailPixels = 112
    /// ⌘1…⌘9 的 keyCode（5 和 6 是反直觉的 0x17 / 0x16，同剪贴板面板）。
    private static let digitKeyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    /// `activate()` 后多久第一次预热（剪贴板的搜索键、计算引擎和识别器的静态表）：别和启动时各模块抢主线程。
    static let firstPrewarmDelay: TimeInterval = 5

    private let apps = LauncherAppProvider()
    private let paths = LauncherPathProvider()
    private let fileSources: LauncherFileSources
    private let files: LauncherFileProvider
    private let thumbnails = LauncherThumbnailProvider()
    private let commands: LauncherCommandProvider
    private let entries: LauncherEntryProvider
    private let context: LauncherContextProvider
    private let usage = LauncherUsageStore()
    private let engine = LauncherEngine()
    private let model = LauncherPanelModel()
    private let panel = LauncherPanel()

    /// 输入框里上屏的文字（组字中的不算）。收起后保留 60 秒。
    private var text = ""
    /// 拆掉前缀后的查询词：执行时记「这个输入选了谁」用（和排序时查的是同一个）。
    private var queryText = ""
    /// 放进来的原文：⌘V 粘贴、拖放、「选中的 / 刚复制的」放进输入框的文字（单行的也记）。输入框里的文字在空白归一后
    /// 还是它时：按字面处理、不拆前缀（「c is a language」放进来不是只搜剪贴板）；带换行的建议行用原文（输入框只有一行，
    /// 换行被换成了空格；交给翻译、总结、存为片段，算字数，§5.4）。一改动就作废，之后照常拆前缀。和输入一起保留 60 秒。
    /// 不变式：`placement.current` 有值 = `text` 还是它。`text` 只在 `adoptText` 里换（每次核对一次）或和它一起清空；
    /// 原文只在 `place(_:_:)` 里记，记完紧跟改输入框和一次落定（`settle`），绕不过去。引擎据此不再核对、不归一。
    private var placement = LauncherPlacement()
    private var hiddenAt: Date?
    /// 输入里挂着的图片（§5.5）。只有一张，收起即丢。
    private var attachment: LauncherAttachment?
    /// 这次呼出的命令和 App 条目（后台建好剪贴板的搜索键后，和条目一起重新装进引擎）。
    private var baseItems: [LauncherItem] = []
    /// 呼出那条日志（`panel shown in … ms`）在等选区读完：读了多久、读到什么写进同一条（不读时立刻写）。
    private var pendingShownLog: String?

    init(registry: ToolRegistry?) {
        commands = LauncherCommandProvider(registry: registry)
        entries = LauncherEntryProvider(registry: registry)
        context = LauncherContextProvider(registry: registry)
        fileSources = LauncherFileSources(registry: registry)
        files = LauncherFileProvider(backend: fileSources.backend)
        model.onTextChange = { [weak self] text in self?.textChanged(text) }
        model.onRun = { [weak self] index in self?.run(at: index) }
        model.iconForFile = { [weak self] path in self?.apps.icon(forPath: path) }
        model.thumbnailForRow = { [weak self] id in self?.thumbnail(forRow: id) }
        thumbnails.onLoaded = { [weak self] in self?.model.thumbnailsChanged() }
        entries.onKeysAdded = { [weak self] in self?.entryKeysAdded() }
        fileSources.onTablesChanged = { [weak self] in self?.fileTablesChanged() }
    }

    /// 模块 activate：后台建 App 索引、读使用记录；几秒后预热一次。
    func activate() {
        apps.start()
        usage.load()
        fileSources.activate()
        // 一次性提醒（PR 10）：后台读回、补响过了点的、定下一条的计时器。
        LauncherReminderCenter.shared.activate()
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
        LauncherReminderCenter.shared.flush()
        LauncherFocus.cancel(reason: "quitting")
        apps.stop()
        paths.cancel()
        files.cancel()
    }

    var isVisible: Bool { panel.isVisible }

    /// 快捷键：按一次呼出、再按一次收起。
    func toggle() {
        let start = DispatchTime.now()
        if panel.isVisible {
            hide()
            LauncherFocus.restore()
        } else {
            show(startedAt: start)
        }
    }

    /// 呼出（菜单「打开快速入口」也走这里）。已经开着就什么都不做。
    func show(startedAt start: DispatchTime = .now()) {
        guard !panel.isVisible else { return }
        // 必须在面板拿焦点之前记：收起后要把焦点还给它，粘贴 / 插入也以它为目标。
        let capturedPID = LauncherFocus.capture()
        // 「选中的」（§8.4）：同一刻、面板拿焦点之前开始读它里面选中的文字 —— 后台读、80 ms 封顶，读到了再补上那一行，不拖慢面板出现。
        let selectionStatus = context.beginSelectionRead(pid: capturedPID) { [weak self] read in
            self?.selectionRead(read, startedAt: start)
        }
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) >= Self.keepInputInterval {
            text = ""
            placement.clear()
        }
        // 快捷键确实和正在运行的 Raycast 撞了（§9）：列表最下面一行小字提示；换了快捷键 / 退出那个 App 后下次呼出就没了。
        let conflict = LauncherHotkeyConflictCheck.confirmedConflictName()
        model.notice = conflict.map { L("launcher.panel.hotkeyConflict \($0)") }
        if let conflict { Self.log.notice("hotkey conflict hint shown: \(conflict, privacy: .public)") }
        baseItems = commands.items() + apps.items
        engine.textActions = commands.textActions()
        engine.imageActions = commands.imageActions()
        engine.fileActions = commands.fileActions()
        // 剪贴板、片段：取一次条目（只读内存），缺的搜索键最新的 200 条现在建，其余后台建、建完刷新一次列表。
        let entriesStart = DispatchTime.now().uptimeNanoseconds
        let report = entries.beginSession()
        let entryItems = entries.sessionItems()
        let entriesMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - entriesStart) / 1_000_000
        // 文件来源（§6.4）：已知文件、剪贴板里的路径在后台建表；自己扫的目录距上次超过 30 秒就后台重扫。
        fileSources.panelShown(clipboardTexts: entries.sessionTexts(sourceIDs: LauncherFileSources.clipboardSourceIDs))
        // 空着时的行（§3.7）：「刚复制的」从刚取到的剪贴板条目里拿；情景建议向各模块收一次（只读内存）。
        let contextReport = context.prepare(
            latestClipboard: entries.latestEntry(sourceID: LauncherContextProvider.clipboardSourceID), now: Date())
        engine.emptyState = context.emptyState
        loadEngine(entryItems: entryItems)
        refresh()
        panel.show(LauncherPanelView(model: model), height: model.panelHeight,
                   onKey: { [weak self] event in self?.handleKey(event) ?? false },
                   onClickOutside: { [weak self] in self?.hide() },
                   onDrop: { [weak self] pasteboard in self?.handleDrop(pasteboard) ?? false })
        // 保留的上次输入：放回输入框，给焦点时全选，直接打字即覆盖。
        model.field.setText(text)
        model.field.focus()
        model.resetHoverBaseline()

        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let shown = String(format: "panel shown in %.1f ms, %ld rows; entries %.1f ms (%ld entries, %ld keys built, %ld pending); situational %ld in %.2f ms; recent copy %@",
                           milliseconds, model.rows.count, entriesMilliseconds, report.entries, report.built, report.pending,
                           contextReport.situational, contextReport.situationalMilliseconds, contextReport.clipboard)
        // 选区还在读：读完（或收起）时再写，读了多久、读到什么在同一条里。
        if selectionStatus == LauncherContextProvider.readingStatus {
            pendingShownLog = shown
        } else {
            pendingShownLog = nil
            Self.log.notice("\(shown, privacy: .public); selection \(selectionStatus, privacy: .public)")
        }
    }

    /// 选区读完了（`LauncherSelectionFetcher` 保证每次呼出只来一次，收起后不来）：补写呼出那条日志；读到了文字、
    /// 输入框还空着就刷新一次，最前面出「选中的」（后台刷新，选中规则见 `LauncherSelectionState`：没手动选过就选中它）。
    /// 日志只记字数和耗时，不记内容。
    private func selectionRead(_ read: LauncherSelectionRead, startedAt start: DispatchTime) {
        let sinceHotkey = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let selection = String(format: "selection %@ in %.1f ms (%.1f ms after the hotkey)",
                               read.outcome.logLabel, read.milliseconds, sinceHotkey)
        if let shown = pendingShownLog {
            pendingShownLog = nil
            Self.log.notice("\(shown, privacy: .public); \(selection, privacy: .public)")
        } else {
            Self.log.notice("\(selection, privacy: .public)")
        }
        guard panel.isVisible, case .text = read.outcome else { return }
        engine.emptyState = context.emptyState
        guard attachment == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refresh(background: true)
        panel.setHeight(model.panelHeight)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.hide()
        hiddenAt = Date()
        // 选区还没读完就收起了：不要它，呼出那条日志照写。
        context.endSession()
        if let shown = pendingShownLog {
            pendingShownLog = nil
            Self.log.notice("\(shown, privacy: .public); selection cancelled (panel hidden)")
        }
        // 在等第二次 ⏎ 的行复位（PR 10）。
        model.disarm()
        // 挂着的图片收起即丢（图片占内存）；输入框里的字那时是这张图的筛选词，也不留。
        if attachment != nil {
            attachment = nil
            model.attachment = nil
            text = ""
            placement.clear()
        }
        paths.cancel()
        files.cancel()
        engine.clear()
        baseItems = []
        entries.endSession()
    }

    private func loadEngine(entryItems: [LauncherItem]) {
        engine.load(baseItems + entryItems,
                    sourceIDs: Set([LauncherAppProvider.sourceID, LauncherCommandProvider.sourceID, LauncherFileProvider.sourceID])
                        .union(entries.sessionSourceIDs))
    }

    /// 后台建好了一批条目的搜索键、面板还开着：重新装一次，同一个输入再查一次（后台刷新，选中规则见 `LauncherSelectionState`）。
    private func entryKeysAdded() {
        guard panel.isVisible else { return }
        loadEngine(entryItems: entries.sessionItems())
        refresh(background: true)
        panel.setHeight(model.panelHeight)
    }

    // MARK: - 查询

    private func textChanged(_ newText: String) {
        guard panel.isVisible, adoptText(newText) else { return }
        refresh()
        panel.setHeight(model.panelHeight)
    }

    /// 输入框里的文字换成了 `newText`（打字的回调、程序换文字都走这里）：记下，并核对放进来的原文还算不算数 ——
    /// 正在放进来的那段优先；不再是它就丢掉（之后照常拆前缀）。核对先比长度、只归一输入框这一边（`LauncherPlacedText.matches`），
    /// 放进来的原文丢掉以后再打字就什么都不核对。返回文字变没变。
    @discardableResult
    private func adoptText(_ newText: String) -> Bool {
        guard newText != text else { return false }
        text = newText
        placement.fieldChanged(to: newText)
        return true
    }

    /// 把一段放进来的文字换进输入框（⌘V、拖放、「选中的 / 刚复制的」都走这里）：记下原文（`pasted`，nil / 全是空白不记）→
    /// `change` 改输入框（有文字变化的回调时 `adoptText` 当场核对）→ 落定：不管改没改成、有没有回调，都对着此刻的输入框核对一次，
    /// 对不上就作废（输入框不在编辑时 ⌘V 什么都不做、也没有回调 —— 不落定的话手打的 `f readme` 会被当成放进来的）。
    /// 落定后原文变了（贴的正好是框里原来的字）就再查一次。
    @discardableResult
    private func place<Result>(_ pasted: String?, _ change: () -> Result) -> Result {
        placement.begin(pasted)
        let result = change()
        if placement.settle(fieldText: text), panel.isVisible {
            refresh()
            panel.setHeight(model.panelHeight)
        }
        return result
    }

    /// 查一次、换上新的行。`background`：同一个输入、后台结果回来了（文件、路径、搜索键、识别结果）—— 选中规则见
    /// `LauncherSelectionState`（没手动选过 → 第一行；手动选过 → 留在他选的那一行）；false = 输入变了，选中第一行。
    private func refresh(background: Bool = false) {
        engine.placedText = placement.current
        engine.attachment = attachment
        let outcome = engine.search(text, records: usage.records, now: Date())
        queryText = outcome.queryText
        if outcome.duration > Self.slowQueryThreshold {
            Self.log.notice("slow query: \(outcome.duration * 1000, format: .fixed(precision: 2), privacy: .public) ms, \(outcome.candidateCount, privacy: .public) candidates")
        }
        model.setRows(outcome.rows, emptyInput: outcome.queryText.isEmpty, newInput: !background,
                      searching: outcome.isPending)
        requestBackgroundResults(outcome)
    }

    /// 引擎要的后台结果：输入是一个还没查过的路径 → 后台查；要搜的文件还没搜过 → 去搜（同一个正在查 / 搜就不再发）。
    /// 不需要了（不再是路径、不再搜文件、手上的结果已经是这次的）→ 不要还没回来的。
    private func requestBackgroundResults(_ outcome: LauncherSearchOutcome) {
        if let path = outcome.pendingPath {
            if paths.inFlight != path {
                paths.resolve(path) { [weak self] input, items in self?.pathResolved(items, for: input) }
            }
        } else {
            paths.cancel()
        }
        if let request = outcome.pendingFiles {
            // 正在跑的就是它（只回来了一部分来源）时不重发，等它回齐（`LauncherFileResultState.shouldStart`）。
            if LauncherFileResultState.shouldStart(pending: request, inFlight: files.inFlight) {
                files.search(request) { [weak self] request, pinned, ranked, complete in
                    self?.filesFound(pinned: pinned, ranked: ranked, for: request, complete: complete)
                }
            }
        } else {
            files.cancel()
        }
    }

    /// 文件搜好了（或先回来了一部分来源）：交给引擎，同一个输入再查一次（后台刷新：没手动选过选中第一行 ——
    /// 输入文件名后 ⏎ 打开的就是当下排第一的文件；手动选过留在他选的那一行。`LauncherSelectionState`）。
    private func filesFound(pinned: [LauncherItem], ranked: [LauncherItem], for request: LauncherFileSearchRequest,
                            complete: Bool) {
        guard panel.isVisible else { return }
        engine.setFileResult(pinned: pinned, ranked: ranked, for: request, complete: complete)
        refresh(background: true)
        panel.setHeight(model.panelHeight)
    }

    /// 文件来源的表换上了（扫完了、已知文件 / 剪贴板路径重建了）：面板开着、这次输入正在搜文件，就重查（结果先照旧显示）——
    /// 刚呼出就贴文件名、冷扫描还没完时，不用再按一个键才出来。同一个请求只重查内存来源（PR 11 复查后定）：Spotlight 已经交回的
    /// 那一批留着、还在路上的让它继续，列表里不会出现 Spotlight 的行消失又回来，也不多查一次 Spotlight。
    /// 最近一次查询不是这个请求（或已经停了）时才整个重搜。
    private func fileTablesChanged() {
        guard panel.isVisible, let request = engine.expireFileResults() else { return }
        guard !files.requeryLocalSources(for: request) else { return }
        files.cancel()
        refresh(background: true)
        panel.setHeight(model.panelHeight)
    }

    /// 后台查好了一个路径：交给引擎，同一个输入再查一次（后台刷新，选中规则见 `LauncherSelectionState`）。
    private func pathResolved(_ items: [LauncherItem], for input: LauncherPathInput) {
        guard panel.isVisible else { return }
        engine.setPathResult(items, for: input)
        refresh(background: true)
        panel.setHeight(model.panelHeight)
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
        case 0x24, 0x4C: // Return / 小键盘 Enter；⌘⏎ 在计算结果、识别结果上 = 插入前台 App，文件 / 路径行上 = 在访达里显示，其余行同 ⏎
            if flags.contains(.command) {
                insertOrRun(at: model.selectedIndex)
            } else {
                run(at: model.selectedIndex)
            }
            return true
        case 0x35: // Esc：挂着图片时第一下去掉图片（连同筛选的字），第二下才收起；收起时把焦点还给原来的 App（点别处收起的不还）
            if attachment != nil {
                removeAttachment(clearingText: true)
                return true
            }
            hide()
            LauncherFocus.restore()
            return true
        case 0x33 where attachment != nil && text.isEmpty && flags.isDisjoint(with: [.command, .control, .option]):
            // ⌫：输入框为空时去掉挂着的图片（输入框里有字时照常删字）。
            removeAttachment(clearingText: false)
            return true
        case 0x30: // Tab：路径行上 = 补全成这一行的完整路径；图片条目上 = 挂成附件；其余时候先吃掉，以后是「问 AI」
            if flags.isDisjoint(with: [.command, .control, .option]) { complete(at: model.selectedIndex) }
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
        let handled: Bool
        if edit == .paste {
            switch pasteSpecial(from: .general) {
            case .handled(let done):
                Self.log.notice("edit shortcut v handled as a non-text paste: \(done, privacy: .public)")
                return done
            case .pasteText(let pasted):
                // 文字交还给输入框粘贴：原文记下、粘贴、落定（输入框不在编辑、粘贴没成时也落定，`place`）。
                handled = place(pasted) { model.field.perform(.paste) }
            }
        } else {
            handled = model.field.perform(edit)
        }
        Self.log.notice("edit shortcut \(key, privacy: .public) handled: \(handled, privacy: .public)")
        return handled
    }

    /// ⌘V 这一下怎么处理：自己处理完了（文件、图片），或交还给输入框粘贴文字（带上剪贴板里的文字，记成放进来的原文）。
    private enum PasteHandling {
        case handled(Bool)
        case pasteText(String?)
    }

    /// ⌘V：先看剪贴板里是什么（只在按 ⌘V 这一下读，不在打字路径上），各走各的（§5.5）：
    /// 文件 → 输入框换成它的路径；图片 → 挂成附件（不往输入框里粘）；文字 → 交还给输入框照常粘贴，
    /// 调用方经 `place` 记下原文（按字面处理，带换行的建议用它）并落定。
    private func pasteSpecial(from pasteboard: NSPasteboard) -> PasteHandling {
        let snapshot = LauncherPasteboardReader.snapshot(pasteboard)
        let kind = LauncherPasteClassifier.classify(snapshot)
        Self.log.notice("paste: \(Self.label(kind), privacy: .public) (\(snapshot.types.count, privacy: .public) types)")
        switch kind {
        case .image:
            if let data = LauncherPasteboardReader.imageData(pasteboard) {
                attach(.data(data))
                return .handled(true)
            }
            return .pasteText(snapshot.string)
        case .file(let url):
            if insertFile(url) { return .handled(true) }
            return .pasteText(snapshot.string)
        case .text, .nothing:
            return .pasteText(snapshot.string)
        }
    }

    /// 贴进 / 拖进一个文件：输入框换成它的路径（主目录下写 `~/…`、文件夹末尾带 `/`），于是走路径行（⏎ 打开、⌘⏎ 在访达里显示、
    /// Tab 补全；图片文件后面接图片动作）。挂着的图片去掉。不是本地文件为 false。
    private func insertFile(_ url: URL) -> Bool {
        guard let path = LauncherPastedFile.fieldText(for: url, home: NSHomeDirectory()) else { return false }
        attachment = nil
        model.attachment = nil
        placement.clear()
        replaceInput(with: path)
        return true
    }

    /// 输入框整个换成 `newText` 并查一次（挂着的图片已由调用方处理）。编辑器换文字时会回调一次文字变化；
    /// 输入框不在编辑、或文字和原来一样时不回调，所以这里自己记下文字、再查一次。
    private func replaceInput(with newText: String) {
        model.field.replaceText(newText)
        adoptText(newText)
        refresh()
        panel.setHeight(model.panelHeight)
    }

    /// 有东西拖到面板上放下（§5.5）：和 ⌘V 同一套归类 —— 文件换成路径、图片挂成附件、文字放进输入框（带换行的记下原文）。
    /// 接了就让面板重新拿键盘焦点（按下鼠标的那个 App 的窗口成了 key），输入框拿焦点，接着就能用键盘选。
    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard panel.isVisible else { return false }
        let snapshot = LauncherPasteboardReader.snapshot(pasteboard)
        let kind = LauncherPasteClassifier.classify(snapshot)
        Self.log.notice("drop: \(Self.label(kind), privacy: .public) (\(snapshot.types.count, privacy: .public) types)")
        let handled: Bool
        switch kind {
        case .file(let url):
            handled = insertFile(url)
        case .image:
            if let data = LauncherPasteboardReader.imageData(pasteboard) {
                attach(.data(data))
                handled = true
            } else {
                handled = false
            }
        case .text:
            guard let string = snapshot.string else { return false }
            attachment = nil
            model.attachment = nil
            // 输入框只有一行：换行换成空格放进去，原文记下（同 ⌘V：按字面处理、不拆前缀，带换行的建议用原文）。
            place(string) { replaceInput(with: string.components(separatedBy: .newlines).joined(separator: " ")) }
            handled = true
        case .nothing:
            handled = false
        }
        if handled {
            panel.makeKey()
            model.field.focusIfNeeded()
        }
        return handled
    }

    /// 日志里的类别名（不带路径、内容）。
    private static func label(_ kind: LauncherPasteKind) -> String {
        switch kind {
        case .file: return "file"
        case .image: return "image"
        case .text: return "text"
        case .nothing: return "nothing"
        }
    }

    // MARK: - 挂着的图片（§5.5）

    /// 挂上一张图（再挂一张就换掉）：输入框清空（之后打的字是筛这张图的建议），后台出缩略图、取一次字。
    private func attach(_ image: LauncherImage) {
        let recognition = LauncherRecognition(image: image)
        recognition.onFinish = { [weak self] finished in self?.recognitionFinished(finished) }
        attachment = LauncherAttachment(image: image, recognition: recognition)
        model.attachment = LauncherAttachmentChip()
        placement.clear()
        if !text.isEmpty {
            text = ""
            model.field.replaceText("")
        }
        refresh()
        panel.setHeight(model.panelHeight)
        recognition.start()
        loadThumbnail(for: recognition)
    }

    /// 把来源交来的一张图（剪贴板历史里的图片条目）挂成附件：字节在后台取（来源要解密读盘），取到时面板还开着才挂。
    private func attach(entryImage: LauncherEntryImage) {
        let load = entryImage.loadData
        DispatchQueue.global(qos: .userInitiated).async {
            let data = load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.panel.isVisible else { return }
                    guard let data, !data.isEmpty else {
                        Self.toast(L("launcher.toast.imageUnreadable"))
                        return
                    }
                    self.attach(.data(data))
                }
            }
        }
    }

    /// 图片条目行首的缩略图（缓存里没有就去后台取，先返回 nil）。
    private func thumbnail(forRow id: String) -> NSImage? {
        guard let image = engine.item(forKey: id)?.image ?? engine.contextItem(forKey: id)?.image else { return nil }
        return thumbnails.thumbnail(for: image)
    }

    /// 去掉挂着的图片。`clearingText`：连输入框里的筛选词一起清掉（Esc）。
    private func removeAttachment(clearingText: Bool) {
        guard attachment != nil else { return }
        attachment = nil
        model.attachment = nil
        if clearingText, !text.isEmpty {
            adoptText("")
            model.field.replaceText("")
        }
        refresh()
        panel.setHeight(model.panelHeight)
    }

    /// 缩略图（长边 112 像素，约 28pt 高的两倍）和像素尺寸：后台解，回来时附件已经换了就丢掉。读不出来 = 不是能用的图片：
    /// 去掉附件，回执一句。
    private func loadThumbnail(for recognition: LauncherRecognition) {
        let image = recognition.image
        let begin = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global(qos: .userInitiated).async {
            let size = LauncherImageLoader.pixelSize(image)
            let thumbnail = LauncherImageLoader.thumbnail(image, maxPixelSize: Self.attachmentThumbnailPixels)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.attachment?.recognition === recognition else { return }
                    guard let thumbnail else {
                        Self.log.error("attached image is unreadable")
                        self.removeAttachment(clearingText: false)
                        Self.toast(L("launcher.toast.imageUnreadable"))
                        return
                    }
                    Self.log.notice("image #\(recognition.id, privacy: .public): thumbnail in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
                    self.model.attachment = LauncherAttachmentChip(
                        thumbnail: NSImage(cgImage: thumbnail, size: .zero),
                        sizeText: size.map { "\(Int($0.width))×\(Int($0.height))" })
                }
            }
        }
    }

    /// 挂着的这张图取完字了：同一个输入再查一次（后台刷新，选中规则见 `LauncherSelectionState`）。不是当前附件的（换了、去了）不管。
    private func recognitionFinished(_ recognition: LauncherRecognition) {
        guard panel.isVisible, attachment?.recognition === recognition else { return }
        refresh(background: true)
        panel.setHeight(model.panelHeight)
    }

    // MARK: - 执行

    private func run(at index: Int) {
        guard model.rows.indices.contains(index) else { return }
        let id = model.rows[index].id
        if let contextItem = engine.contextItem(forKey: id) {
            fill(contextItem)
            return
        }
        // 要按两次 ⏎ 的行（PR 10）：第一次（含 ⌘N、单击）只选中它、标题换成「再按一次回车…」，再按才往下走。
        if let confirmation = engine.suggestion(forKey: id)?.confirmation ?? engine.item(forKey: id)?.confirmation,
           !model.confirmPress(at: index, title: Self.confirmTitle(confirmation)) {
            return
        }
        if let instant = engine.instant(forKey: id) {
            copy(instant)
            return
        }
        if let suggestion = engine.suggestion(forKey: id) {
            runSuggestion(suggestion)
            return
        }
        guard let item = engine.item(forKey: id) else { return }
        perform(item.run, for: item)
    }

    /// 执行一行的动作：先记使用（路径行不记），收起面板，等焦点回到原来的 App 再执行（粘贴、窗口管理这类动作都作用于它）。
    private func perform(_ action: @escaping @MainActor () -> Void, for item: LauncherItem) {
        if item.recordsUsage {
            usage.recordUse(key: item.candidate.key, input: queryText, now: Date())
        }
        hide()
        LauncherFocus.restore(then: action)
    }

    /// Tab：选中的是路径行时，把输入框换成它的完整路径（文件夹末尾带 `/`，于是立刻列出它里面的内容）；
    /// 选中的是图片条目（剪贴板历史里的图片）时，把这张图挂成附件 —— 于是出取字、贴图这些建议（§5.5）。
    private func complete(at index: Int) {
        guard model.rows.indices.contains(index) else { return }
        // 「选中的 / 刚复制的」：Tab 同 ⏎，放进输入框。
        if let contextItem = engine.contextItem(forKey: model.rows[index].id) {
            fill(contextItem)
            return
        }
        guard let item = engine.item(forKey: model.rows[index].id) else { return }
        if let image = item.image {
            attach(entryImage: image)
            return
        }
        guard let completion = item.completion else { return }
        model.field.replaceText(completion)
        // 编辑器换文字时已经回调过一次；输入框不在编辑时没有回调，这里补上（同样的文字不会再查）。
        textChanged(completion)
    }

    /// 「选中的 / 刚复制的」放进输入框（§3.7，⏎ / Tab / ⌘⏎ / ⌘N / 单击都是它）：文字去掉首尾空白后填进去 ——
    /// 输入框只有一行，换行换成空格放进去、原文记下（同 ⌘V，经 `place`）：按字面处理、不拆前缀（「A quick fix…」不是只搜 App），
    /// 于是建议照常出、交给动作的是原文；
    /// 图片挂成附件（字节在后台取）。输入框不再为空，这两行就没了。不记使用记录。
    private func fill(_ item: LauncherContextItem) {
        switch item.fill {
        case .text(let original):
            let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Self.log.notice("context row \(item.row.id, privacy: .public) put into the field (\(text.count, privacy: .public) characters)")
            place(text) { replaceInput(with: text.components(separatedBy: .newlines).joined(separator: " ")) }
        case .image(let image):
            Self.log.notice("context row \(item.row.id, privacy: .public) attached as an image")
            attach(entryImage: image)
        }
    }

    /// 建议行（§5.4）：兜底建议记一次使用（`textaction/<id>`；不记「这个输入选了谁」，那是给排序里的普通行用的）。
    /// 改输入的（搜文件名 → `f <文字>`）面板不收；其余同命令：收起面板、等焦点回到原来的 App 再执行。
    private func runSuggestion(_ suggestion: LauncherSuggestion) {
        if let key = suggestion.usageKey {
            usage.recordUse(key: key, input: "", now: Date())
        }
        switch suggestion.action {
        case .replaceInput(let newText):
            model.field.replaceText(newText)
            // 编辑器换文字时已经回调过一次；输入框不在编辑时没有回调，这里补上（同样的文字不会再查）。
            textChanged(newText)
        case .run(let action):
            hide()
            LauncherFocus.restore(then: action)
        case .runOnImageText(let recognition, let action):
            // 「<命令名>图里的文字」：挂上图片时开始的那次取字多半已经跑完；还没跑完（或是图片文件的路径、回车才开始取）就等它。
            hide()
            LauncherFocus.restore {
                // 取字可能要等：动作的上下文先读走，取到了再在它里面执行（上下文只在闭包同步执行时有）。
                let context = LauncherFocus.actionContext
                recognition.whenDone { result in
                    guard let text = LauncherRecognizedContent.text(result.text) else {
                        Self.toast(L("launcher.toast.noTextInImage"))
                        return
                    }
                    LauncherFocus.continueAction(in: context) { action(text) }
                }
            }
        }
    }

    /// ⌘⏎：计算结果、识别结果插入前台 App（和听写、划词助手同一条路：能直接写进输入框就写，不行借剪贴板粘贴，
    /// 都不行就复制并提示）；文件、路径行在访达里显示；其余行同 ⏎。
    private func insertOrRun(at index: Int) {
        guard model.rows.indices.contains(index) else { return }
        guard let instant = engine.instant(forKey: model.rows[index].id) else {
            if let item = engine.item(forKey: model.rows[index].id), let alternate = item.alternate {
                perform(alternate, for: item)
            } else {
                run(at: index)
            }
            return
        }
        guard let text = instant.copyText else { return }
        hide()
        // 等面板让开、焦点回到原来的输入框再插。
        LauncherFocus.restore {
            // 目标在闭包里同步读走；插入是异步的，显式把目标和「粘贴前看键盘」交给 `TextInserter`。
            let target = LauncherFocus.actionContext?.target
            Task { @MainActor in
                let result = await TextInserter.insert(text, into: target, checkKeyboardBeforePaste: true)
                // 键盘被别的 App 占着时，`LauncherFocus` 已经发过说明原因的回执。
                if !result.inserted, result != .copied(.keyboardElsewhere) { Self.toast(L("launcher.toast.insertCopied")) }
            }
        }
    }

    /// ⏎：复制结果并收起（普通复制，进剪贴板历史：这是用户要的一份新内容），给一句回执。出错的结果不做事。
    private func copy(_ instant: LauncherInstant) {
        guard let text = instant.copyText else { return }
        TextInserter.copyToClipboard(text)
        hide()
        let toast = L("launcher.toast.copied \(LauncherConversions.singleLine(text, maxLength: 40))")
        LauncherFocus.restore { Self.toast(toast) }
    }

    /// 二次确认时那一行的标题：「再按一次回车<做什么>：<对象>」（对象太长中间截断，开头结尾都在）；没有「做什么」的写「再按一次回车：<对象>」。
    static func confirmTitle(_ confirmation: LauncherConfirmation) -> String {
        let object = LauncherConfirmText.object(confirmation.object)
        guard let verb = confirmation.verb else { return L("launcher.confirm.plain \(object)") }
        return L("launcher.confirm.action \(verb) \(object)")
    }

    /// 回执（同防休眠开关的回执：宠物开着是宠物气泡，否则系统通知；勿扰时照常显示）。
    static func toast(_ text: String) {
        NotifyCenter.shared.post(Notice(source: "launcher", level: .ambient, title: text,
                                        icon: "doc.on.doc", isUserFeedback: true))
    }
}
