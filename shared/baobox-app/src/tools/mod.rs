//! 两个 Rust 平台共用的工具定义。
//!
//! 目前只有截图、剪贴板的 **id 常量**：工具 id 是配置文件里的节名，快捷键动作 id 是
//! `[hotkey]` 节里的键名 —— 它们是跨平台的契约，同一份配置拿到另一个系统上也得认。
//! 以前两个平台各写一份字面量，对不齐也没人知道；现在两边都 `pub use` 这里的同一个常量，
//! 不会再各说各的。
//!
//! 只放**写进配置的** id。只在菜单里出现的动作（打开历史目录、清空历史……）不进配置，
//! 改名不伤用户，留在各自平台的模块里。

pub mod clipboard;
pub mod screenshot;

#[cfg(test)]
mod tests {
    use super::{clipboard, screenshot};

    #[test]
    fn ids_written_into_the_users_config_never_change() {
        // 两个平台用的是同一个常量，所以「两边一致」由编译保证；这条测试盯的是「别改」——
        // 改了任何一个，用户配置里已有的那一节设置和快捷键绑定就对不上了，
        // 而且不报错，只是悄悄失效
        assert_eq!(screenshot::ID, "screenshot");
        assert_eq!(screenshot::CAPTURE, "screenshot.capture");
        assert_eq!(screenshot::CAPTURE_FULL, "screenshot.full");
        assert_eq!(screenshot::OCR, "screenshot.ocr");
        assert_eq!(screenshot::RECORD, "screenshot.record");
        assert_eq!(clipboard::ID, "clipboard");
        assert_eq!(clipboard::PANEL, "clipboard.panel");
    }
}
