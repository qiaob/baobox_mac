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
        currentScreen = Self.focusedScreen(pid: pid)
        active = true
        // AX 遍历可阻塞 → 后台扫描，回主线程显示。
        DispatchQueue.global(qos: .userInitiated).async {
            let elements = AXElementScanner.scan(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.present(elements) }
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
            let overlay = KeyboardNavOverlayWindow(screen: screen, targets: targets, controller: self)
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let key = overlays.first {
            key.makeKeyAndOrderFront(nil)
            key.focusView()
        }
    }

    // MARK: - 键盘输入（由 overlay view 回调）

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
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        hints.removeAll()
        input = ""
        active = false
    }

    // MARK: - 当前屏判定

    /// 前台 App 焦点窗口所在屏；取不到则回退鼠标所在屏 / 主屏。
    private static func focusedScreen(pid: pid_t) -> NSScreen? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() else {
            return screenContainingMouse()
        }
        let winEl = win as! AXUIElement  // 类型已用 CFGetTypeID 校验
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posV = posRef, let sizeV = sizeRef,
              CFGetTypeID(posV) == AXValueGetTypeID(), CFGetTypeID(sizeV) == AXValueGetTypeID() else {
            return screenContainingMouse()
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        let winAK = Geometry.appKitRect(fromCG: CGRect(origin: pos, size: size))
        let center = CGPoint(x: winAK.midX, y: winAK.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screenContainingMouse()
    }

    private static func screenContainingMouse() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
    }
}
