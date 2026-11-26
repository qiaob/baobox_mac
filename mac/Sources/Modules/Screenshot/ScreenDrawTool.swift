import Foundation

/// 屏幕标注已并入「截图与标注」（`ScreenshotTool`）；保留此命名空间与 `hotkeyID` 以维持快捷键持久化兼容。
enum ScreenDrawTool {
    /// 快捷键的持久化键，保持不变以免用户已设键位丢失。
    static let hotkeyID = "screenshot.draw"
}
