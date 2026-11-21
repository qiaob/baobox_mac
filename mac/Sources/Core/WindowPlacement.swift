import AppKit

extension NSWindow {
    /// 居中，但先把窗口定成内容的实际大小。
    ///
    /// `NSWindow(contentViewController:)` 包着 SwiftUI 视图建出来的窗口，建完那一刻还没有大小
    /// （2026-11-21 在 macOS 27.2.1 上实测是 1×28），真正的大小要到显示时才撑开，而且是左上角不动往右下撑。
    /// 这时直接 `center()` 居中的是那个 1 个点宽的窗口，显示出来就整体偏右，860 宽的设置窗口有一截在屏幕外面
    /// （用户遇到）。自己 `setContentSize` 过的窗口不受影响，这里也不会改它的大小。
    func centerFittingContent() {
        if frame.width < 10, let size = contentViewController?.view.fittingSize, size.width > 1, size.height > 1 {
            setContentSize(size)
        }
        center()
    }
}
