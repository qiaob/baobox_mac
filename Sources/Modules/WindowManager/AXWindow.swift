import AppKit
import ApplicationServices

/// 前台窗口的 Accessibility 读写封装。
///
/// **坐标系**：AX 的 `kAXPositionAttribute` / `kAXSizeAttribute` 使用 **CG 全局坐标
/// （主屏左上原点、y 向下）**，与 NSScreen 的换算必须走 `Geometry`，切勿就地翻转。
/// 本封装的入参 / 返回值均为该 CG 坐标（后缀 CG）。
@MainActor
enum AXWindow {
    /// 当前前台 App 的聚焦窗口。
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement,
                                                kAXFocusedWindowAttribute as CFString,
                                                &windowRef)
        guard err == .success, let windowRef else { return nil }
        // AXUIElement 是 CF 类型，可安全强转。
        return (windowRef as! AXUIElement)
    }

    /// 读取窗口 frame（CG 全局坐标）。
    static func frameCG(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        let okPoint = withUnsafeMutablePointer(to: &point) {
            AXValueGetValue(posRef as! AXValue, .cgPoint, $0)
        }
        let okSize = withUnsafeMutablePointer(to: &size) {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, $0)
        }
        guard okPoint, okSize else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// 写入窗口 frame（CG 全局坐标）。
    /// 顺序为 **size → position → size**：部分 App 会按旧位置约束尺寸，两遍 size 是平台通行做法。
    /// 任一步失败（AXError ≠ .success）静默忽略——固定尺寸窗口尽力而为。
    static func setFrameCG(_ rect: CGRect, on element: AXUIElement) {
        var size = rect.size
        var position = rect.origin

        guard let sizeValue = withUnsafePointer(to: &size, { AXValueCreate(.cgSize, $0) }),
              let posValue = withUnsafePointer(to: &position, { AXValueCreate(.cgPoint, $0) }) else {
            return
        }

        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }
}
