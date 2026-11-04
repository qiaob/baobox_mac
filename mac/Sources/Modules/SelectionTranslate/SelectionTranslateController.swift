import AppKit
import AVFoundation

/// 划词翻译的 UserDefaults 键（前缀 `selectiontranslate.`），见设计文档 §6。
enum SelectionTranslateSettings {
    static let autoPopupKey = "selectiontranslate.autoPopup"
    static let copyFallbackKey = "selectiontranslate.copyFallback"
    static let autoSpeakKey = "selectiontranslate.autoSpeak"

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
    /// 去重：同一段选区短时间内不重复弹。
    private var lastShownText = ""
    private var lastShownAt = Date.distantPast

    /// 原文长度上限：超长段落截断，避免把整篇文章塞进翻译会话。
    private static let maxCharacters = 8000

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
    }

    // MARK: - 手动触发：翻译选中文字

    /// manual = 用户明确按键 / 点菜单：取不到词要给反馈（必要时走 ⌘C 兜底）；
    /// 自动弹出路径传 false：只走 AX，取不到就安静地什么都不做。
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
        if SelectionTranslateSettings.copyFallback {
            Task { [weak self] in
                if let result = await SelectionText.fetchViaCopyFallback() {
                    self?.show(result)
                } else {
                    self?.showNotice(L("selectiontranslate.panel.noSelection"))
                }
            }
        } else {
            showNotice(L("selectiontranslate.panel.noSelection"))
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
        let language = SelectionText.detectLanguage(of: text)
        panel.show(content: .translation(text: text, source: language), anchor: result.anchorRect)
    }

    private func showNotice(_ message: String, anchor: CGRect? = nil) {
        panel.show(content: .notice(message: message), anchor: anchor)
    }

    // MARK: - 朗读

    func speak(_ text: String, language: SelectionLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceLanguage)
        synthesizer.speak(utterance)
    }

    // MARK: - 自动弹出（CGEventTap，只听左键抬起）

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
        let mask = CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        // tap 的 runloop source 挂在主线程上，回调必然在主线程执行（同 PR #31
        // 识别引擎的 assumeIsolated 用法）。
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    SelectionTranslateController.shared.reEnableEventTap()
                } else if type == .leftMouseUp {
                    SelectionTranslateController.shared.handleMouseUp(at: event.location)
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

    /// 鼠标抬起后延迟一拍查选区：等 App 先把选区落定。
    /// `quartzPoint` 是 CGEvent 的坐标（主屏左上原点）。
    fileprivate func handleMouseUp(at quartzPoint: CGPoint) {
        //点在浮层自身上：别自己触发自己。
        if let frame = panel.frame, panel.isVisible,
           let primaryHeight = NSScreen.screens.first?.frame.height {
            let appKitPoint = CGPoint(x: quartzPoint.x, y: primaryHeight - quartzPoint.y)
            if frame.contains(appKitPoint) { return }
        }
        // 前台是 Baobox 自己（设置页等）时不弹。
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        pendingSelectionCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // asyncAfter 跑在主队列上，与类同为 MainActor 隔离域。
            MainActor.assumeIsolated {
                guard let self, SelectionTranslateSettings.autoPopup else { return }
                guard let result = SelectionText.fetchViaAccessibility() else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                // 同一段文字 2 秒内不重复弹（比如用户在同一选区上又点了一下）。
                if text == self.lastShownText, Date().timeIntervalSince(self.lastShownAt) < 2 {
                    return
                }
                self.show(result)
            }
        }
        pendingSelectionCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
