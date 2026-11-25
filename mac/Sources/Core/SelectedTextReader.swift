import ApplicationServices
import Foundation

/// 只走辅助功能读一个 App 焦点元素里选中的文字：不借剪贴板、不合成按键，读不到就是没有。
/// 划词助手（`SelectionText.fetchViaAccessibility`，不设超时，同原来）和快速入口（呼出时带上选中的文字，
/// docs/launcher/TECH_DESIGN.md §8.4：后台读、总时限 80 ms）共用。从划词助手下沉到 Core：快速入口不能引用模块的类型。
///
/// 时限：AX 每次调用前把这个元素的消息超时（`AXUIElementSetMessagingTimeout`）设成剩下的时间，于是几次调用加起来也不超过预算；
/// 超时的那次 AX 返回 `cannotComplete`，算「超时」。不设时限时一次都不调 `SetMessagingTimeout`（系统默认），行为同下沉前。
/// AX 的客户端调用可以在任何线程上做（Mach 消息）：快速入口在后台线程调 `read`。
enum SelectedTextReader {
    /// 带时限的一次读取的结果（快速入口记日志只记是哪一种和字数，不记内容）。
    enum Outcome: Equatable, Sendable {
        case text(String)
        /// 没选中、App 不暴露选区、选中的全是空白。
        case none
        /// 超过时限（或 AX 报 `cannotComplete`：App 没在时限内回话）。
        case timedOut
        /// 没有辅助功能权限。
        case noPermission
    }

    /// 读 `pid` 这个 App 焦点元素里选中的文字，总时限 `budget` 秒。不在主线程也能调。
    static func read(pid: pid_t, budget: TimeInterval) -> Outcome {
        guard AXIsProcessTrusted() else { return .noPermission }
        var clock = Clock(deadline: ProcessInfo.processInfo.systemUptime + max(0, budget))
        let app = AXUIElementCreateApplication(pid)
        guard let element = focusedElement(of: app, clock: &clock) else { return clock.timedOut ? .timedOut : .none }
        guard let text = selectedText(of: element, clock: &clock) else { return clock.timedOut ? .timedOut : .none }
        if clock.expired { return .timedOut }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text)
    }

    /// `pid` 这个 App 当前的焦点元素；取不到为 nil。不设时限（划词助手用）。
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        var clock = Clock(deadline: nil)
        return focusedElement(of: AXUIElementCreateApplication(pid), clock: &clock)
    }

    /// 元素里选中的文字；取不到 / 没选中为 nil（空白照样返回，由调用方判断）。不设时限（划词助手用）。
    static func selectedText(of element: AXUIElement) -> String? {
        var clock = Clock(deadline: nil)
        return selectedText(of: element, clock: &clock)
    }

    // MARK: - 内部

    /// 一次读取的时限。`deadline` 为 nil = 不设时限。
    private struct Clock {
        let deadline: TimeInterval?
        /// 有一次调用超时了（或到点了还没读完）。
        private(set) var timedOut = false

        init(deadline: TimeInterval?) {
            self.deadline = deadline
        }

        var expired: Bool {
            guard let deadline else { return false }
            return ProcessInfo.processInfo.systemUptime >= deadline
        }

        /// 读一个属性：有时限时先把这个元素的消息超时设成剩下的时间（已经到点就不读，记超时）。
        mutating func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return finish(error) ? value : nil
        }

        private mutating func prepare(_ element: AXUIElement) -> Bool {
            guard let deadline else { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                timedOut = true
                return false
            }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            return true
        }

        private mutating func finish(_ error: AXError) -> Bool {
            if error == .cannotComplete, deadline != nil { timedOut = true }
            return error == .success
        }
    }

    private static func focusedElement(of app: AXUIElement, clock: inout Clock) -> AXUIElement? {
        guard let focused = clock.copy(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    /// 先读 kAXSelectedText；没有就用「全文 + 选区范围」切（不少文本视图只给后者）。读哪几个属性、按什么顺序在
    /// `LauncherSelectedTextSteps`（纯逻辑，有单元测试）：带时限时先读范围、有选区才读全文；不带时限同下沉前，先全文后范围。
    private static func selectedText(of element: AXUIElement, clock: inout Clock) -> String? {
        LauncherSelectedTextSteps.read(
            timed: clock.deadline != nil,
            selectedText: { clock.copy(element, kAXSelectedTextAttribute) as? String },
            selectedRange: { selectedRange(of: element, clock: &clock) },
            value: { clock.copy(element, kAXValueAttribute) as? String },
            stopped: { clock.timedOut })
    }

    /// 选区范围（kAXSelectedTextRange）；读不到、不是范围为 nil。
    private static func selectedRange(of element: AXUIElement, clock: inout Clock) -> NSRange? {
        guard let rangeRef = clock.copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
