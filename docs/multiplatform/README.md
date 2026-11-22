# 多平台

2026-11-22 起 Baobox 拆成四个仓库，这里的多平台文档随之搬走：

| 仓库 | 内容 |
|---|---|
| [baobox_mac](https://github.com/qiaob/baobox_mac)（本仓库） | macOS 版（Swift），不链接任何 Rust 代码 |
| [baobox_windows](https://github.com/qiaob/baobox_windows) | Windows 版（Rust + Win32） |
| [baobox_linux](https://github.com/qiaob/baobox_linux) | Linux 版（Rust + X11） |
| [baobox_shared](https://github.com/qiaob/baobox_shared) | Windows 和 Linux 共用的 Rust 库，按标签作 Cargo git 依赖 |

原来在这里的三份文档现在都在 baobox_shared 的 `docs/` 下：

- [ARCHITECTURE.md](https://github.com/qiaob/baobox_shared/blob/main/docs/ARCHITECTURE.md)：四个仓库各放什么、什么共用、移植踩到的真实差异、各平台进度、改了共享库之后怎么在两个平台仓库里升级。
- [ERRORS.md](https://github.com/qiaob/baobox_shared/blob/main/docs/ERRORS.md)：Rust 错误类型化（#110）。
- [MODULE_GLUE.md](https://github.com/qiaob/baobox_shared/blob/main/docs/MODULE_GLUE.md)：两个平台的模块胶水（#111）。
