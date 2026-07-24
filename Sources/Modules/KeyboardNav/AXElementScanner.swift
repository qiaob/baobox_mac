import AppKit
import ApplicationServices

/// 一个可点击元素：AX 句柄 + 屏幕矩形（CG 全局坐标，主屏左上原点、y 向下）。
struct ClickableElement {
    let element: AXUIElement
    let frameCG: CGRect
}

/// 用 Accessibility 遍历指定进程，收集可点击元素。**后台线程调用**（AX 调用可阻塞主线程）。
///
/// 坐标：`kAXPositionAttribute` / `kAXSizeAttribute` 用 CG 全局坐标（左上原点），与 `AXWindow` 一致。
enum AXElementScanner {
    /// 视为「可点击」的 AX role（用字符串字面量，规避不同 SDK 下 kAX*Role 常量的导入差异）。
    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXTabButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXDisclosureTriangle", "AXStepper", "AXSlider",
        "AXSegmentedControl", "AXColorWell", "AXSwitch", "AXIncrementor",
    ]

    /// 遍历 pid 对应 App 的 AX 树，返回可点击元素（带 CG 矩形）。
    static func scan(pid: pid_t) -> [ClickableElement] {
        let appEl = AXUIElementCreateApplication(pid)
        var out: [ClickableElement] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(KeyboardNavEnv.scanTimeout)
        traverse(appEl, depth: 0, out: &out, visited: &visited, deadline: deadline)
        return out
    }

    private static func traverse(_ el: AXUIElement, depth: Int,
                                 out: inout [ClickableElement], visited: inout Int, deadline: Date) {
        if depth > KeyboardNavEnv.maxDepth { return }
        if out.count >= KeyboardNavEnv.maxElements { return }
        if Date() > deadline { return }
        visited += 1

        if isClickable(el), let rect = frameCG(of: el), rect.width > 1, rect.height > 1 {
            out.append(ClickableElement(element: el, frameCG: rect))
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            if out.count >= KeyboardNavEnv.maxElements || Date() > deadline { return }
            traverse(child, depth: depth + 1, out: &out, visited: &visited, deadline: deadline)
        }
    }

    private static func isClickable(_ el: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, clickableRoles.contains(role) {
            return true
        }
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(el, &actionsRef) == .success,
           let actions = actionsRef as? [String], actions.contains(kAXPressAction as String) {
            return true
        }
        return false
    }

    /// 读元素矩形（CG 全局坐标）。同 `AXWindow.frameCG` 的 AXValue 解析法，附类型校验避免无保护强转崩溃。
    private static func frameCG(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        let okP = withUnsafeMutablePointer(to: &point) { AXValueGetValue(posRef as! AXValue, .cgPoint, $0) }
        let okS = withUnsafeMutablePointer(to: &size) { AXValueGetValue(sizeRef as! AXValue, .cgSize, $0) }
        guard okP, okS else { return nil }
        return CGRect(origin: point, size: size)
    }
}
