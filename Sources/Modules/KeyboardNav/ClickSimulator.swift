import ApplicationServices
import CoreGraphics

/// 点击一个 AX 元素：优先可访问性 AXPress（不移动真实鼠标、最稳），失败则在元素中心合成鼠标点击。
enum ClickSimulator {
    /// - Parameter centerCG: 元素中心（CG 全局坐标，左上原点）——AXPress 失败时的合成点击位置。
    static func click(_ element: AXUIElement, centerCG: CGPoint) {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        synthesizeClick(at: centerCG)
    }

    private static func synthesizeClick(at p: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
