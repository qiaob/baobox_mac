import ApplicationServices
import CoreGraphics

/// 点击一个 AX 元素：以**真实合成点击**为主 —— 对网页内容、菜单项等一切控件最忠实
/// （Chrome 的网页元素 AXPress 常年不可靠：返回 success 也可能没有任何效果，元素引用
/// 还容易过期）。取不到有效落点时才退回 AXPress。会移动真实光标到点击处 —— 这符合
/// 「我点了它」的直觉，光标本来也该在用户注意力所在的位置。
enum ClickSimulator {
    /// - Parameter centerCG: 元素中心（CG 全局坐标，左上原点）。
    static func click(_ element: AXUIElement, centerCG: CGPoint) {
        guard centerCG.x.isFinite, centerCG.y.isFinite else {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            return
        }
        synthesizeClick(at: centerCG)
    }

    private static func synthesizeClick(at p: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: p, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                         mouseCursorPosition: p, mouseButton: .left)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.post(tap: .cghidEventTap)
    }
}
