import AppKit
import AVFoundation

/// 划词翻译的 UserDefaults 键（前缀 `selectiontranslate.`），见设计文档 §6。
enum SelectionTranslateSettings {
    static let autoPopupKey = "selectiontranslate.autoPopup"
    static let copyFallbackKey = "selectiontranslate.copyFallback"
    static let autoSpeakKey = "selectiontranslate.autoSpeak"
    static let targetKey = "selectiontranslate.target"
    static let secondaryTargetKey = "selectiontranslate.secondaryTarget"

    /// 译成什么语言（默认系统首选语言）。
    static var target: TranslationLanguage {
        get { TranslationLanguage.from(code: UserDefaults.standard.string(forKey: targetKey)) ?? .systemPreferred }
        set { UserDefaults.standard.set(newValue.code, forKey: targetKey) }
    }

    /// 原文已是目标语言时改译成什么（默认 English；目标本身是英文时默认中文）。
    static var secondaryTarget: TranslationLanguage {
        get {
            if let stored = TranslationLanguage.from(code: UserDefaults.standard.string(forKey: secondaryTargetKey)) {
                return stored
            }
            return target.isSameLanguage(as: .english) ? .simplifiedChinese : .english
        }
        set { UserDefaults.standard.set(newValue.code, forKey: secondaryTargetKey) }
    }

    /// 给定原文语种，这次译成什么：原文已是目标语言 → 备选语言。
    static func target(for source: TranslationLanguage) -> TranslationLanguage {
        let primary = target
        guard source.isSameLanguage(as: primary) else { return primary }
        let secondary = secondaryTarget
        if !secondary.isSameLanguage(as: source) { return secondary }
        // 两项设成了同一种语言：中英互为兜底。
        return source.isSameLanguage(as: .english) ? .simplifiedChinese : .english
    }

    static var autoPopup: Bool {
        get { UserDefaults.standard.object(forKey: autoPopupKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoPopupKey) }
    }

    static var copyFallback: Bool {
        get { UserDefaults.standard.object(forKey: copyFallbackKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: copyFallbackKey) }
    }

    static var autoSpeak: Bool {
        get { UserDefaults.standard.object(forKey: autoSpeakKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoSpeakKey) }
    }
}

/// 划词翻译状态机：触发（菜单 / 快捷键 / 自动弹出 / 框选）→ 取词 → 浮层。
@MainActor
final class SelectionTranslateController {
    static let shared = SelectionTranslateController()

    private let panel = SelectionTranslatePanelController()
    private let picker = RegionTextPicker()
    /// 朗读合成器必须常驻持有，中途释放会静音（ClaudeCode 模块同款教训）。
    private let synthesizer = AVSpeechSynthesizer()

    // 自动弹出的事件 tap
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pendingSelectionCheck: DispatchWorkItem?
    /// 最近一次左键按下的位置（Quartz 坐标），抬起时据此判断是不是拖选。
    private var mouseDownPoint: CGPoint?
    /// 左键按下时剪贴板的 changeCount。抬起后它变了 = 前台 App 自己把选区拷进了剪贴板
    /// （终端的「选中即复制」、TUI 用 OSC 52 自己复制），直接用，不必再借剪贴板。
    private var mouseDownChangeCount: Int?
    /// 每次左键抬起 +1。借剪贴板取词是异步的，回来时已经有了新手势就作废。
    private var gestureGeneration = 0
    /// 去重：同一段选区短时间内不重复弹。
    private var lastShownText = ""
    private var lastShownAt = Date.distantPast
    /// 借剪贴板路径上次弹出的文字。终端里的选区会一直留着，之后拖窗口之类的拖动会把它再拷出来一次 ——
    /// 同一段就不再弹，直到一次普通单击（通常会清掉选区）。
    private var lastBorrowedText = ""
    /// 本次运行里拷出过文件 / 图片的 App（Finder 选文件、设计软件拖图层）：自动弹出不再对它借剪贴板。
    private var borrowSkippedApps: Set<pid_t> = []

    /// 原文长度上限：超长段落截断，避免把整篇文章塞进翻译会话。
    private static let maxCharacters = 8000
    /// 按下到抬起移动超过这个距离（点）才算拖选；双击选词 / 三击选行按点击次数认。
    private static let dragThreshold: CGFloat = 5

    func activate() {
        panel.onSpeakOriginal = { [weak self] text, language in self?.speak(text, language: language) }
        panel.onSpeakTranslation = { [weak self] text, language in self?.speak(text, language: language) }
        panel.onCopyTranslation = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        panel.onTranslationReady = { [weak self] text, language in
            guard SelectionTranslateSettings.autoSpeak else { return }
            self?.speak(text, language: language)
        }
        panel.onHide = { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
        refreshEventTap()
    }

    func stopAll() {
        removeEventTap()
        picker.cancel()
        panel.hide()
        synthesizer.stopSpeaking(at: .immediate)
        OfflineTranslator.shared.shutdown()
    }

    // MARK: - 手动触发：翻译选中文字

    /// manual = 用户明确按键 / 点菜单：取不到词要给反馈（按设置借剪贴板兜底）；
    /// manual 为 false 时只走 AX，取不到就安静地什么都不做（自动弹出另有一套判断，见 `handleMouseUp`）。
    func translateSelection(manual: Bool) {
        guard Permissions.hasAccessibility else {
            if manual { Permissions.promptAccessibility() }
            return
        }
        if let result = SelectionText.fetchViaAccessibility() {
            show(result)
            return
        }
        guard manual else { return }
        guard SelectionTranslateSettings.copyFallback,
              let front = NSWorkspace.shared.frontmostApplication else {
            showNotice(L("selectiontranslate.panel.noSelection"))
            return
        }
        let mouse = NSEvent.mouseLocation
        let anchor = CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        Task { [weak self] in
            var outcome = await SelectionText.copyViaMenu(pid: front.processIdentifier, allowImages: true)
            // 菜单栏里找不到「拷贝」：用户明确要取词，直接合成 ⌘C。
            if case .noMenuItem = outcome {
                outcome = await SelectionText.copyViaKeystroke()
            }
            let summary = outcome.logDescription
            SelectionTranslateLog.selection.notice(
                "manual borrow in \(front.bundleIdentifier ?? "?", privacy: .public): \(summary, privacy: .public)")
            guard let self else { return }
            if case .copied(let text, let method) = outcome {
                let route: SelectionTextResult.Route = method == .menu ? .menuCopy : .keystrokeCopy
                self.show(SelectionTextResult(text: text, anchorRect: anchor, route: route))
            } else {
                self.showNotice(L("selectiontranslate.panel.noSelection"))
            }
        }
    }

    // MARK: - 手动触发：框选 OCR

    func translateRegion() {
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            showNotice(L("selectiontranslate.panel.needsScreenRecording"))
            return
        }
        panel.hide()
        picker.pick { [weak self] text, anchor in
            guard let self else { return }
            if let text {
                show(SelectionTextResult(text: text, anchorRect: anchor, route: .ocr))
            } else if anchor != nil {
                showNotice(L("selectiontranslate.panel.noTextRecognized"), anchor: anchor)
            }
            // text 与 anchor 都为空 = 用户取消框选，安静结束。
        }
    }

    // MARK: - 展示

    private func show(_ result: SelectionTextResult) {
        let text = String(result.text.prefix(Self.maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastShownText = text
        lastShownAt = Date()
        let preferred = [SelectionTranslateSettings.target, SelectionTranslateSettings.secondaryTarget]
        let source = LanguageDetector.detect(text, preferred: preferred)
        let target = SelectionTranslateSettings.target(for: source)
        panel.show(content: .translation(text: text, source: source, target: target), anchor: result.anchorRect)
    }

    private func showNotice(_ message: String, anchor: CGRect? = nil) {
        panel.show(content: .notice(message: message), anchor: anchor)
    }

    // MARK: - 朗读

    func speak(_ text: String, language: TranslationLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // 没装这种语言的嗓音时为 nil，交给系统默认嗓音。
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceLanguage)
        synthesizer.speak(utterance)
    }

    // MARK: - 自动弹出（CGEventTap，只听左键按下 / 抬起）

    /// 按设置与权限装配 / 拆除事件 tap。tap 建不起来（无辅助功能权限）就静默降级。
    func refreshEventTap() {
        if SelectionTranslateSettings.autoPopup, Permissions.hasAccessibility {
            installEventTapIfNeeded()
        } else {
            removeEventTap()
        }
    }

    private func installEventTapIfNeeded() {
        guard eventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        // tap 的 runloop source 挂在主线程上，回调必然在主线程执行（同 PR #31
        // 识别引擎的 assumeIsolated 用法）。
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    SelectionTranslateController.shared.reEnableEventTap()
                case .leftMouseDown:
                    SelectionTranslateController.shared.handleMouseDown(at: event.location)
                case .leftMouseUp:
                    let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
                    SelectionTranslateController.shared.handleMouseUp(at: event.location, clickCount: clicks)
                default:
                    break
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else { return }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let tapSource {
            CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), tapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        pendingSelectionCheck?.cancel()
        pendingSelectionCheck = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let tapSource {
            CFRunLoopRemoveSource(RunLoop.main.getCFRunLoop(), tapSource, .commonModes)
        }
        eventTap = nil
        tapSource = nil
    }

    fileprivate func reEnableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    fileprivate func handleMouseDown(at quartzPoint: CGPoint) {
        mouseDownPoint = quartzPoint
        mouseDownChangeCount = NSPasteboard.general.changeCount
    }

    /// 鼠标抬起后延迟一拍查选区：等 App 先把选区落定。
    /// `quartzPoint` 是 CGEvent 的坐标（主屏左上原点）。
    fileprivate func handleMouseUp(at quartzPoint: CGPoint, clickCount: Int) {
        let downPoint = mouseDownPoint
        let downChangeCount = mouseDownChangeCount
        mouseDownPoint = nil
        mouseDownChangeCount = nil
        gestureGeneration += 1
        let primaryHeight = NSScreen.screens.first?.frame.height
        // 点在浮层自身上：别自己触发自己。
        if let frame = panel.frame, panel.isVisible, let primaryHeight {
            let appKitPoint = CGPoint(x: quartzPoint.x, y: primaryHeight - quartzPoint.y)
            if frame.contains(appKitPoint) { return }
        }
        // 前台是 Baobox 自己（设置页等）时不弹。
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        // 像不像在选文字：拖过一段距离，或双击选词 / 三击选行。只有这样 AX 读不到时才借剪贴板。
        let dragged = downPoint.map { hypot($0.x - quartzPoint.x, $0.y - quartzPoint.y) >= Self.dragThreshold } ?? false
        let selectionGesture = dragged || clickCount >= 2
        if !selectionGesture { lastBorrowedText = "" }
        let pid = front.processIdentifier
        let generation = gestureGeneration
        let anchor = primaryHeight.map { CGRect(x: quartzPoint.x, y: $0 - quartzPoint.y, width: 1, height: 1) }

        pendingSelectionCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // asyncAfter 跑在主队列上，与类同为 MainActor 隔离域。
            MainActor.assumeIsolated {
                guard let self, SelectionTranslateSettings.autoPopup else { return }
                if let result = SelectionText.fetchViaAccessibility() {
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    // 同一段文字 2 秒内不重复弹（比如用户在同一选区上又点了一下）。
                    if text == self.lastShownText, Date().timeIntervalSince(self.lastShownAt) < 2 {
                        return
                    }
                    self.show(result)
                    return
                }
                // AX 读不到（很多终端、部分自绘界面）：满足设计文档 §2 的条件才借剪贴板。
                guard selectionGesture, SelectionTranslateSettings.copyFallback,
                      !self.borrowSkippedApps.contains(pid),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !PasteboardBorrow.holdsConcealedContent else { return }
                Task { [weak self] in
                    await self?.fetchSelectionWithoutAX(from: front, downChangeCount: downChangeCount,
                                                        anchor: anchor, generation: generation)
                }
            }
        }
        pendingSelectionCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 自动弹出、AX 读不到选区时（设计文档 §2.1）：
    /// 1. App 自己已经把选区拷进了剪贴板（按下鼠标之后剪贴板变了）→ 直接用；
    /// 2. 否则借剪贴板：前台 App 的「拷贝」菜单项可用才动手（先按菜单项、不灵再合成 ⌘C）；
    ///    找不到菜单项就作罢 —— 这条路径一天会走很多次，没有选区时合成按键会响提示音。
    private func fetchSelectionWithoutAX(from app: NSRunningApplication, downChangeCount: Int?,
                                         anchor: CGRect?, generation: Int) async {
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? "?"
        if let downChangeCount, let copied = await Self.textCopiedByApp(since: downChangeCount) {
            SelectionTranslateLog.selection.notice(
                "auto in \(bundle, privacy: .public): app copied the selection itself (\(copied.count) chars)")
            present(copied, anchor: anchor, generation: generation, route: .appCopied)
            return
        }
        let outcome = await SelectionText.copyViaMenu(pid: pid, allowImages: false)
        SelectionTranslateLog.selection.notice(
            "auto borrow in \(bundle, privacy: .public): \(outcome.logDescription, privacy: .public)")
        switch outcome {
        case .copied(let raw, let method):
            present(raw, anchor: anchor, generation: generation, route: method == .menu ? .menuCopy : .keystrokeCopy)
        case .notText:
            borrowSkippedApps.insert(pid)
        case .noMenuItem, .disabled, .nothingCopied:
            break
        }
    }

    /// 借剪贴板 / App 自己复制拿到的文字：等待期间又有了新手势（又选了一段 / 点走了）就作废；
    /// 同一段不重复弹（见 `lastBorrowedText`）。
    private func present(_ raw: String, anchor: CGRect?, generation: Int, route: SelectionTextResult.Route) {
        guard generation == gestureGeneration else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastBorrowedText else { return }
        lastBorrowedText = text
        show(SelectionTextResult(text: raw, anchorRect: anchor, route: route))
    }

    /// 按下鼠标之后剪贴板被前台 App 改过（不算 Baobox 自己借用 / 还原的那次）就读出文字。
    /// TUI 走 OSC 52 复制是异步的：抬起后再等最多 ~0.25 秒。带文件 / 密码标记的不收。
    private static func textCopiedByApp(since changeCount: Int) async -> String? {
        let pasteboard = NSPasteboard.general
        for attempt in 0..<9 {
            let current = pasteboard.changeCount
            if current != changeCount, !PasteboardBorrow.isActive, current != PasteboardBorrow.settledChangeCount {
                let types = Set(pasteboard.types ?? [])
                guard !types.contains(.fileURL), !PasteboardBorrow.holdsConcealedContent,
                      let text = pasteboard.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
            if attempt < 8 { try? await Task.sleep(nanoseconds: 30_000_000) }
        }
        return nil
    }
}
