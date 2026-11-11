//! 剪贴板工具的 id。
//!
//! 监听与粘贴两个平台是完全不同的模型，留在平台层；
//! 这里只放写进用户配置的那几个字符串，两个平台 `pub use` 同一份。

/// 工具 id，同时是配置里的节名。
pub const ID: &str = "clipboard";

/// 动作：打开剪贴板历史面板。
pub const PANEL: &str = "clipboard.panel";
