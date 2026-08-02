import AppKit
import ApplicationServices

/// 键盘点击协调：触发 → 后台扫描 → 生成标签 → overlay 显示 → 键盘输入前缀匹配 → 点击 → 收尾。
@MainActor
final class KeyboardNavController {
    static let shared = KeyboardNavController()

    private struct Hint {
        let label: String
        let element: AXUIElement
        let rectCG: CGRect
    }

    private var overlays: [KeyboardNavOverlayWindow] = []
    private var hints: [Hint] = []
    private var input = ""
    private var active = false
    /// 触发时前台 App 焦点窗口所在屏（"当前屏"模式用）。
    private var currentScreen: NSScreen?
    /// 会话期间的键盘/鼠标捕获 tap（见 installEventTap 的说明）。
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private init() {}

    /// 触发键盘点击（快捷键 / 菜单）。
    func activate() {
        guard !active else { return }
        guard Permissions.hasAccessibility else {
            Permissions.promptAccessibility()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        // 不扫描本 App 自己：in-process 的 AX 深遍历会让 AppKit 在后台线程「模拟打开」
        // 菜单栏菜单，菜单重建里的 NSHostingView 非主线程创建直接崩溃。要点的本来就是
        // 别的 App —— overlay 已不抢激活，正常流程里前台也不会是自己。
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        active = true
        // AX 调用可阻塞（对着菜单跟踪中的 App 尤甚）：焦点窗口判定与扫描都放后台，回主线程显示。
        DispatchQueue.global(qos: .userInitiated).async {
            let focusRect = Self.focusedWindowRectAK(pid: pid)
            let elements = AXElementScanner.scan(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.currentScreen = Self.screen(forFocusRectAK: focusRect)
                    self.present(elements)
                }
            }
        }
    }

    private func present(_ elements: [ClickableElement]) {
        guard active else { return }
        guard !elements.isEmpty else { active = false; return }

        // 排序：上→下、左→右（CG 坐标 y 向下，minY 小者在上）。
        let sorted = elements.sorted { a, b in
            if abs(a.frameCG.minY - b.frameCG.minY) > 6 { return a.frameCG.minY < b.frameCG.minY }
            return a.frameCG.minX < b.frameCG.minX
        }
        let labels = HintLabelGenerator.labels(count: sorted.count, chars: KeyboardNavEnv.hintCharacters)
        guard labels.count == sorted.count else { active = false; return }
        hints = zip(labels, sorted).map { Hint(label: $0.0, element: $0.1.element, rectCG: $0.1.frameCG) }
        input = ""

        // 按「标签显示范围」设置决定用哪些屏：当前屏 / 所有屏。
        let screens: [NSScreen]
        if KeyboardNavEnv.labelScope == "current", let cur = currentScreen {
            screens = [cur]
        } else {
            screens = NSScreen.screens
        }
        // 每屏一个 overlay：把落在该屏的标签转成 view 本地 AppKit 坐标。
        for screen in screens {
            let targets: [HintTarget] = hints.compactMap { h in
                let globalAK = Geometry.appKitRect(fromCG: h.rectCG)
                guard screen.frame.intersects(globalAK) else { return nil }
                let local = NSRect(x: globalAK.minX - screen.frame.minX,
                                   y: globalAK.minY - screen.frame.minY,
                                   width: globalAK.width, height: globalAK.height)
                return HintTarget(label: h.label, rectAK: local)
            }
            let overlay = KeyboardNavOverlayWindow(screen: screen, targets: targets)
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }
        // 所有屏都没建出 overlay（显示器休眠/热插拔瞬间 NSScreen.screens 为空）必须复位，
        // 否则 active 永久卡 true、此后快捷键全被开头的 guard 吞掉 —— 截图 overlay 同款坑。
        guard !overlays.isEmpty else {
            active = false
            return
        }
        // 不激活自己、不做 key window：焦点留在目标 App（别的 App 拉开的菜单也不会塌），
        // hint 输入由 CGEventTap 捕获。
        installEventTap()
    }

    // MARK: - 键盘输入（由事件 tap 回调）

    func appendInput(_ c: String) {
        guard active else { return }
        let next = input + c
        let matches = hints.filter { $0.label.hasPrefix(next) }
        if matches.isEmpty { return } // 无效字符，忽略（不改变当前输入）
        input = next
        if matches.count == 1, matches[0].label == input {
            trigger(matches[0])
        } else {
            overlays.forEach { $0.updateInput(input) }
        }
    }

    func backspace() {
        guard active, !input.isEmpty else { return }
        input = String(input.dropLast())
        overlays.forEach { $0.updateInput(input) }
    }

    func cancel() { dismiss() }

    // MARK: - 点击 / 收尾

    private func trigger(_ hint: Hint) {
        let center = CGPoint(x: hint.rectCG.midX, y: hint.rectCG.midY)
        let element = hint.element
        dismiss() // 先关 overlay，避免挡住合成点击
        ClickSimulator.click(element, centerCG: center)
    }

    private func dismiss() {
        removeEventTap()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        hints.removeAll()
        input = ""
        active = false
    }

    // MARK: - 键盘/鼠标捕获（CGEventTap）
    //
    // overlay 不再抢激活（.nonactivatingPanel）：焦点始终留在目标 App，别的 App 拉开的
    // 菜单也不会被 NSApp.activate 收起。代价是收不到普通 keyDown —— 会话期间用
    // CGEventTap 在 HID 层捕获（写法同 HotkeyCenter.beginMenuTrackingCapture）：
    // hint 字母 / Esc / ⌫ 消费掉不漏进目标 App，带修饰键的组合与其余按键放行；
    // 物理点击不消费但视为放弃会话（用户改用鼠标了）。

    private func installEventTap() {
        guard eventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if KeyboardNavTapRelay.handle(type: type, event: event) {
                return nil // 消费：hint 字母 / Esc / ⌫ 不能漏进目标 App
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: nil) else {
            // 模块入口已查过辅助功能权限，走到这只可能是权限被中途收走 ——
            // 没有输入通道，会话无法进行，直接收尾（否则 overlay 挂着永远关不掉）。
            dismiss()
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        tapSource = nil
    }

    /// tap 事件入口（source 挂主 run loop，回调在主线程）。返回 true = 消费该事件。
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard active else { return false }
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // 用户改用鼠标 = 放弃本次会话；点击本身放行，照常作用于目标。
            dismiss()
            return false
        case .keyDown:
            return handleKeyDown(event)
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 0x35: // Esc
            dismiss()
            return true
        case 0x33: // ⌫
            backspace()
            return true
        default:
            // 带 ⌘/⌃/⌥ 的组合键放行 —— 全局快捷键（包括本功能自己的）照常工作。
            let flags = event.flags
            if flags.contains(.maskCommand) || flags.contains(.maskControl)
                || flags.contains(.maskAlternate) {
                return false
            }
            guard let ch = Self.character(from: event)?.lowercased(), ch.count == 1,
                  KeyboardNavEnv.hintCharacters.contains(ch) else {
                return false // 非 hint 字母：放行，也不打断会话
            }
            appendInput(ch)
            return true
        }
    }

    /// 从 CGEvent 取按键对应的输入字符。
    private static func character(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length,
                                       unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - 当前屏判定

    /// 前台 App 焦点窗口矩形（AK 全局坐标）。纯 AX 调用，供后台线程使用。
    private nonisolated static func focusedWindowRectAK(pid: pid_t) -> NSRect? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() else {
            return nil
        }
        let winEl = win as! AXUIElement  // 类型已用 CFGetTypeID 校验
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posV = posRef, let sizeV = sizeRef,
              CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID() else {
            return nil
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        return Geometry.appKitRect(fromCG: CGRect(origin: pos, size: size))
    }

    /// 焦点窗口所在屏；取不到则回退鼠标所在屏 / 主屏（主线程：要碰 NSScreen/NSEvent）。
    private static func screen(forFocusRectAK rect: NSRect?) -> NSScreen? {
        if let rect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
                return screen
            }
        }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }
}

/// C 回调不能捕获 MainActor 隔离上下文，经由这个非隔离转发层进入控制器
/// （同 HotkeyCenter / SnippetExpander 的取舍）。tap source 挂主 run loop，回调本就在主线程。
private enum KeyboardNavTapRelay {
    static func handle(type: CGEventType, event: CGEvent) -> Bool {
        MainActor.assumeIsolated {
            KeyboardNavController.shared.handleTapEvent(type: type, event: event)
        }
    }
}
