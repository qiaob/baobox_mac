//! Baobox 跨平台核心。
//!
//! 这里只放**与操作系统无关**的截图逻辑：坐标运算、选区状态机、标注模型、
//! 长截屏拼接、文件名规则、历史存储。三个平台（macOS / Windows / Linux）
//! 实现各自的抓屏与窗口层，行为规格由本 crate 统一约束。
//!
//! # 坐标系约定
//!
//! 本 crate 一律使用**左上角为原点、y 轴向下**的坐标系（Windows 与 X11 的原生约定）。
//! macOS 是左下角原点，那边负责在边界处转换 —— 与 `mac/Sources/Core/Geometry.swift`
//! 承担的是同一件事，只是方向相反。
//!
//! # 为什么不含平台 trait
//!
//! 抓屏、窗口枚举、剪贴板这些能力在三个平台上的形状差异极大（同步/异步、
//! 权限模型、像素格式都不同），强行抽象成一个 trait 只会得到一个谁都不好用的
//! 最小公倍数。本 crate 只提供**纯函数与纯数据结构**，平台层直接调用。

#![forbid(unsafe_code)]

pub mod annotation;
pub mod filename;
pub mod geometry;
pub mod hotkey;
pub mod history;
pub mod selection;
pub mod stitch;
