//! 截图工具的 id。
//!
//! 截图的执行流程（抓屏、覆盖层、编辑器）两个平台形状差太远，留在平台层；
//! 这里只放写进用户配置的那几个字符串，两个平台 `pub use` 同一份。

/// 工具 id，同时是配置里的节名。
pub const ID: &str = "screenshot";

/// 动作：截图（先进覆盖层选区域 / 窗口）。
pub const CAPTURE: &str = "screenshot.capture";
/// 动作：截整个屏幕。
pub const CAPTURE_FULL: &str = "screenshot.full";
/// 动作：屏幕取字。
pub const OCR: &str = "screenshot.ocr";
/// 动作：录屏（没在录就开始，正在录就停下）。
pub const RECORD: &str = "screenshot.record";
