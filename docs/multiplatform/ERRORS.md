# Rust 错误类型化（#110）

> 状态：**设计稿，待拍板**。本文只写设计，不含代码改动。
> 数据取自 `main@65b1186`（2026-11-10），行号都指那个提交。
> 相关：模块胶水合并见 [`MODULE_GLUE.md`](MODULE_GLUE.md)（#111），两件事的先后见 §8 Q2。

## 1. 一句话

现在一个动作失败了，平台层手里只有一句中文：分不清是**用户取消**、**这次做不了**还是
**真坏了**，于是 Windows 靠比较字符串 `"已取消"` 决定弹不弹窗，Linux 干脆把所有失败都
丢进 stderr（桌面上的用户一条都看不到）；底层错误被 `format!` 压成文字，`io::ErrorKind`
这类信息丢了，有的路径更是被 `.ok()?` / `let _ =` 整个吞掉。方案：在 `baobox-app`
定义一个按「平台层该怎么对待」分类的 `ToolError` 作为 `ToolModule::perform` 的错误类型，
两个叶子 crate 各有一个小枚举（`hotkey::ParseError`、`baobox_image::ImageError`），
**手写、零依赖**；平台边缘（X11 / Win32 / DBus 的封装、命令行参数）继续用 `String`，
进入核心路径时补一句上下文。给用户看的文字逐字不变。

## 2. 现状

### 2.1 重新数

按 issue 的写法 `grep -rn "Result<.*, String>"`，当前 `main` 有 **222** 处（issue 写 221），
全部在 `.rs` 里。去掉 `#[cfg(test)]` 之后的测试代码，**生产代码 211 处**。

| crate | 生产代码 | 测试 | 说明 |
|---|---|---|---|
| `shared/baobox-core` | 2 | 0 | 只有 `KeyCombo::parse` 与它的 `parse_key`（`hotkey.rs:86、129`） |
| `shared/baobox-app` | 5 | 5 | `ToolModule::perform`（`lib.rs:133`）、`ToolRegistry::perform`（`:230`）、`OpenTerminal`（`assistant_tool.rs:99`）、助手的 `resume` / `perform` |
| `shared/baobox-image` | 3 | 0 | `encode_rgba` / `write_rgba` / `decode_rgba`（`lib.rs:13、37、76`） |
| `shared/baobox-render` | 0 | 0 | |
| `windows/baobox-windows` | 114 | 5 | |
| `linux/baobox-linux` | 87 | 1 | |

**baobox-core 几乎没有会失败的 API**：它的解析器一律宽容（`Config::parse` 不会失败，
`decode_index` 坏行跳过，`json::parse` 返回 `Option`）。真正的错误集中在
`baobox-app` 的动作契约和两个平台 crate 里。

按角色分（生产代码）：

| 类别 | shared | Windows | Linux | 合计 | 归属 |
|---|---|---|---|---|---|
| A 框架契约（`ToolModule::perform`、注册表派发、助手的 `perform` / `resume`） | 4 | — | — | 4 | 核心路径 |
| B 共享叶子（快捷键解析、PNG 编解码） | 5 | — | — | 5 | 核心路径 |
| C 工具适配层（各 `*_module.rs` 的 `perform` 及其辅助函数、宠物） | — | 34 | 18 | 52 | 核心路径 |
| D 常驻 App 装配（`app.rs`） | — | 2 | 1 | 3 | 核心路径 |
| F 落盘 / 读盘（配置、历史、剪贴板库、宠物包） | — | 10 | 5 | 15 | 核心路径 |
| G 外部进程（OCR、ffmpeg） | — | 5 | 2 | 7 | 核心路径 |
| 开终端（`OpenTerminal` 类型与两边 `terminal.rs`） | 1 | 2 | 2 | 5 | 平台边缘 |
| E 命令行入口（`main.rs`：参数解析、子命令） | — | 24 | 13 | 37 | 平台边缘 |
| H 系统 API 封装（X11 / Win32 / DBus / GTK） | — | 37 | 46 | 83 | 平台边缘 |

核心路径 86 处（41%），平台边缘 125 处（59%）。

### 2.2 现在的错误长什么样

文案本身大多**已经写了在做什么**：主流写法是 `map_err(|e| format!("{操作}失败：{e}"))`
（「摆放窗口失败：{e}」「写入配置失败：{e}」「无法写入 {路径}：{e}」）。所以「上下文全丢」
并不准确，真正丢的是三样：

1. **类型**。`{e}` 一压成文字，`io::ErrorKind::NotFound` 和 `InvalidData` 就分不出来了 ——
   §2.4 第 3 条的配置覆盖就是这么来的。
2. **分类**。「用户按了 Esc」「只有一块屏所以跨不了屏」「X 服务器连不上」都是同一个
   `Err(String)`，平台层只能靠比字符串区分。
3. **整条路径**。`.ok()?` 把错误变成 `None`（生产代码里 Linux 45 处、Windows 24 处、shared 4 处），
   `let _ =` 直接扔掉（其中不少是不关心结果的 Win32 调用，但也有落盘失败）。

### 2.3 错误最后去了哪

全仓库没有日志框架，stderr 就是日志。

| 场景 | 成功的那句话 | 失败 |
|---|---|---|
| Linux 常驻 App | `notify-send` 桌面通知（`app.rs:138`），没装就打到 stdout | **一律 `eprintln!`**（`app.rs:141`）—— 从桌面启动的用户看不到任何失败 |
| Windows 常驻 App | 宠物气泡 / 托盘气泡（`app.rs:232–266`） | 截图、取字、录屏失败且不是「已取消」→ `MessageBoxW`（`app.rs:269–282`）；**其余一律 `eprintln!`**（`app.rs:283`），进程序自带的控制台窗口（没有 `windows_subsystem` 属性） |
| 两边命令行 | 打到 stdout | `错误：{msg}` 打到 stderr，退出码 1（L `main.rs:60–75` / W `main.rs:94–108`）；取消也是「错误：已取消」 |
| 后台失败（落盘、监听、快捷键注册冲突） | — | 也是 `eprintln!`（两边各 15 处 `eprintln!`，含上面几行）；Linux 上「快捷键被别的程序占了」也只进 stderr |

### 2.4 具体的坑

| # | 问题 | 位置 | 后果 |
|---|---|---|---|
| 1 | **取消靠比字符串** | `"已取消"` 在 12 处构造（W `screenshot_module.rs:274、307、384、715、736、852`，W `main.rs:278、608`，L `screenshot_module.rs:238、371`，L `main.rs:260、591`），1 处比较（W `app.rs:271` `why != "已取消"`） | 哪天有人把文案改成「已取消截图」，Windows 用户每按一次 Esc 就弹一个「截图操作未完成」 |
| 2 | 其他按文案分支的地方 | W `app.rs:236` `message.contains("已复制到剪贴板")`、`:245` `message.starts_with("已保存 ")`、`:105` `label.contains("停止")` | 同上：改文案会悄悄改行为 |
| 3 | **配置读不出来会被默认值覆盖** | `load_config` 用 `.ok()` 吞掉一切读错误（L `store.rs:58–63` / W `store.rs:36–41`），启动时随即 `save_config`（L `app.rs:77–83` / W `app.rs:440–446`） | 文件在但读不了 —— 典型是用记事本另存为 ANSI（GBK）后成了非 UTF-8，`read_to_string` 报 `InvalidData` —— 下次启动就被一份全是默认值的配置**覆盖**，用户的设置全没了。L `store.rs:56–57` 的注释说「用户的文件原样留在那里」，实际并不成立 |
| 4 | **Linux 用户看不到任何失败** | L `app.rs:141` | 例：防休眠一家都没联系上时，代码特意不假装成功，返回「联系不上 systemd-logind，防休眠没能开启。」（L `caffeinate.rs:73–75`）—— 这句话只进了 stderr，用户以为开好了 |
| 5 | 剪贴板里的图片静默丢失 | `save_image` 里 `.ok()?`（L `clipboard_module.rs:152–157` / W `:188–195`） | 磁盘满或目录没权限时，复制的图不进历史，也没有任何记录 |
| 6 | 截图历史索引写失败被忽略 | `let _ = save(&history);`（L `store.rs:129` / W `store.rs:116`） | 同上 |
| 7 | 防休眠重开失败被吞 | `if self.start(remaining).is_ok()`（L `caffeinate_module.rs:180` / W `:187`） | 改「同时不让显示器关掉」时若重开失败，会话被静默关掉 |
| 8 | 测试只能按子串断言 | 测试里 25 处 `unwrap_err()`，**25 处全都**接着 `.contains("…")` | 测的是文案碎片，不是语义；改文案就要改测试，漏改又可能让断言意外变宽 |

### 2.5 依赖与安全现状

- 任何 `Cargo.toml` 里都没有 `thiserror` / `anyhow`（属实）。但 **Linux 的 `Cargo.lock`
  里已经间接有 `thiserror 1.0.69`**（gtk-rs 的 `glib` / `gio` / `cairo-rs` 带进来的）；
  Windows 的锁文件里有 `syn` / `quote` / `proc-macro2`（windows-rs、serde、gltf 的宏带进来的），
  没有 `thiserror`；四个共享 crate 的锁文件里这些都没有。
- 没有 workspace，**六个 crate 各有各的 `Cargo.lock` 和 target 目录**，CI 也逐个跑。
- `baobox-core` 写明了**零依赖**（`ARCHITECTURE.md:39`；`history.rs:96` 甚至为此不引 serde）。
- 非测试代码的 `.unwrap()`：shared 0 处，Windows 6 处 + `expect` 2 处，Linux `expect` 2 处（issue 说「很少」，属实）。
- 四个共享 crate 都开了 `#![forbid(unsafe_code)]`（`ARCHITECTURE.md:515` 还写着「两个 crate」，已过期）。
  `baobox-core` 另开着 `missing_docs = "warn"`，在 CI 的 `clippy -- -D warnings` 下等于报错。

## 3. 目标与非目标

**目标**

1. 核心路径的错误说得出**在做什么**（上下文）和**为什么**（保留类型的 `source()` 链），
   并带一个**分类**，平台层按分类决定怎么呈现，不再比字符串（issue 验收 1）。
2. 新代码不再新增 `Result<_, String>`：用一条棘轮测试守住（issue 验收 2）。
3. 给用户看的文字逐字不变；能改的只是「以前看不到的失败，现在看得到」，而且那一步
   单独拍板（§8 Q3）。
4. 顺手修掉被吞错误造成的两个实际问题：配置被覆盖（§2.4 #3）、Linux 看不到失败（#4）——
   都作为单独的、标明「行为变化」的 PR。

**非目标**

- 不消灭平台边缘的 `String`：X11 / Win32 / DBus / GTK 的封装与命令行参数解析，错误最终
  就是给人看的一句话，硬套类型只增加样板。它们在进入核心路径时补一句上下文即可。
- 不引日志框架（`log` / `tracing`）。stderr 照旧，只是内容更完整。另开 issue 再议（§8 Q6）。
- 不改 `perform` 成功时返回 `String` 的约定。
- 不做多语言（Rust 侧文案本来就是中文字面量）。

## 4. 引不引 thiserror

两种写法都在临时 crate 里用 1.90.0 验证过：`#![forbid(unsafe_code)]` + `clippy --all-targets
-- -D warnings`（开着 `missing_docs`）都能过 —— thiserror 生成的代码不含 `unsafe`，
所以**安全门禁不是取舍的理由**。

| | thiserror 2 | 手写 |
|---|---|---|
| 新依赖 | `thiserror` + `thiserror-impl`，编译期还要 `syn`（解析出来是 3.0.10）、`quote`、`proc-macro2`、`unicode-ident`；运行期为零 | 无 |
| `baobox-core` 的「零依赖」 | **破**（文档里写明的原则） | 保持 |
| 锁文件 | 用到它的每个 crate 各改一份 `Cargo.lock`（没有 workspace） | 不动 |
| 编译时间 | 本机（M3）每个 crate 冷编译多约 2 秒，CI 的 2 核机器更久；六个 crate 各有 target 目录，各编一遍 | 不变 |
| 代码量 | 每个变体一行 `#[error("…")]` | 每个枚举多一段 `Display` 的 `match` 和 `source()`，约每变体 2 行 + 十来行骨架 |
| 文案可读性 | 文案在属性里 | 文案在 `match` 里，同样可 grep |
| 规模是否值得 | 本设计总共 3 个枚举、约 16 个变体 | 手写完全可控 |

另外两个选项也看了：`anyhow` 把错误类型抹成一个，正好丢掉我们要的「分类」，不合适；
`Box<dyn Error>` 到处传同样分不出取消与故障。

**建议：手写。** 理由：错误面很小（核心 crate 只有一个会失败的 API）；`baobox-core` 的
零依赖是写进文档的原则，整个项目也一贯少引第三方；没有 workspace，一个 proc-macro 依赖要
改多份锁文件、每个 crate 各编一遍 `syn`。留一个出口：将来某个**平台 crate** 自己要定义一大批
错误枚举时，可以在那个 crate 里局部用 thiserror（Linux 的依赖树里本来就有它），不影响共享层。

## 5. 新结构

### 5.1 三层

```
叶子错误（各 crate 自己的小枚举，跟着 API 走）
  baobox_core::hotkey::ParseError       快捷键文本解析
  baobox_image::ImageError              PNG 读写
        │  .context("在做什么") / ?
        ▼
动作错误（baobox_app::error::ToolError，ToolModule::perform 的错误类型）
  Cancelled / Unavailable / Failed{context, source} / UnknownAction
        ▲
        │  ?（桥：From<String>）或 .context("…")
平台边缘（照旧 Result<_, String>）
  X11 / Win32 / DBus / GTK 封装、命令行参数解析、OpenTerminal
```

主错误放在 `baobox-app` 而不是 `baobox-core`：「取消」「未知动作」「该怎么呈现」都是应用层
概念，放进纯逻辑 crate 是层次倒置；而 core 自己只需要一个解析错误。

### 5.2 签名

下面的类型已在临时 crate 里编过、测过（10 条测试，含「文案与现在的 `format!` 逐字相同」
「嵌套上下文每层只出现一次」「`source` 保留类型能 `downcast` 出 `io::ErrorKind`」
「能跨线程」「体积不超 clippy 门槛」）。实测大小：`ToolError` 40 字节、`ImageError` 40 字节、
`ParseError` 32 字节，远低于 `clippy::result_large_err` 的 128 字节。

```rust
// shared/baobox-app/src/error.rs
use std::borrow::Cow;
use std::error::Error;

/// 底层错误的统一装法：保留类型与 source() 链，能跨线程传。
pub type Source = Box<dyn Error + Send + Sync + 'static>;

/// 一个动作没做成。按「平台层该怎么对待」分，不按「哪里出的错」分。
#[derive(Debug)]
pub enum ToolError {
    /// 用户主动取消（Esc、关掉了覆盖层）。不是故障：不弹窗、不记。
    Cancelled,
    /// 这次做不了，但没有东西坏掉（没有活动窗口、只有一块屏、没装 tesseract……）。
    Unavailable(Cow<'static, str>),
    /// 真的失败了。
    Failed {
        /// 一句完整的话：在做什么、哪一步没成（「摆放窗口失败」）
        context: Cow<'static, str>,
        /// 底层原因；平台边缘只给得出一句话时为 None
        source: Option<Source>,
    },
    /// 没有工具认领这个动作 id —— 程序内部的错，只记日志。
    UnknownAction(String),
}

/// 平台层据此决定怎么呈现。
pub enum Severity { Silent, Notice, Fault, Bug }

impl ToolError {
    pub fn failed(context: impl Into<Cow<'static, str>>, source: impl Into<Source>) -> Self;
    pub fn unavailable(reason: impl Into<Cow<'static, str>>) -> Self;
    /// Cancelled → Silent，Unavailable → Notice，Failed → Fault，UnknownAction → Bug
    pub fn severity(&self) -> Severity;
}

/// 把一条错误链用「：」连成一句话 —— 与现在 format!("{上下文}：{e}") 逐字相同。
pub fn chain_message(error: &(dyn Error + 'static)) -> String;

impl std::fmt::Display for ToolError { /* 链的终点：输出整条链，见 §5.3 */ }
impl Error for ToolError { /* source() 返回 Failed 里的 source */ }

/// 迁移用的桥：平台边缘还返回 String 的函数照样能 `?`，文案不变。
impl From<String> for ToolError { /* → Failed { context: 原文, source: None } */ }
impl From<&str> for ToolError { /* 同上 */ }

/// 给任何 Result 补一句「在做什么」，原错误作为 source 保留。
pub trait ErrorContext<T> {
    fn context(self, context: impl Into<Cow<'static, str>>) -> Result<T, ToolError>;
}
impl<T, E: Into<Source>> ErrorContext<T> for Result<T, E> { /* … */ }
```

```rust
// shared/baobox-app/src/lib.rs —— 契约改成这样
pub trait ToolModule {
    // … 其余不变
    fn perform(&mut self, action: &str) -> Result<String, ToolError>;
}
impl ToolRegistry {
    /// 认领不到 → ToolError::UnknownAction(action)
    pub fn perform(&mut self, action: &str) -> Result<String, ToolError>;
}
```

```rust
// shared/baobox-core/src/hotkey.rs
/// 快捷键文本解析失败的原因。Display 就是给用户看的那句话（与现在逐字相同）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    Empty,                      // 「快捷键为空」
    MultipleKeys(String),       // 「快捷键里出现了多个主键：{原文}」
    MissingKey(String),         // 「快捷键缺少主键：{原文}」
    FunctionKeyOutOfRange(u8),  // 「功能键只支持 F1–F24，收到 F{n}」
    UnknownKey(String),         // 「无法识别的按键：{键名}」
}
impl KeyCombo {
    pub fn parse(text: &str) -> Result<Self, ParseError>;
}
```

现有调用方只用 `.ok()` / `is_ok()` / `let Ok(..) =`（`HotkeySpec::resolve`、两边
`settings_window.rs`），一处都不用改。说实话这个枚举眼下的收益有限 —— 它的文案今天
哪儿都没显示 —— 价值在于让 core 不剩 `String` 错误，以及以后设置窗口能说清手写的配置哪里不对。

```rust
// shared/baobox-image/src/lib.rs
/// PNG 读写失败。Display 只写这一层，底层原因从 source() 拿。
#[derive(Debug)]
pub enum ImageError {
    SizeMismatch { got: usize, expected: usize },          // 「像素数据长度不符：{got} 字节，应为 {expected}」
    CreateDir { path: PathBuf, source: std::io::Error },   // 「无法创建目录 {path}」
    CreateFile { path: PathBuf, source: std::io::Error },  // 「无法写入 {path}」
    EncodeHeader(png::EncodingError),                      // 「PNG 头写入失败」
    EncodeData(png::EncodingError),                        // 「PNG 数据写入失败」
    ReadInfo(png::DecodingError),                          // 「PNG 读取失败」
    DecodeFrame(png::DecodingError),                       // 「PNG 解码失败」
}
pub fn encode_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, ImageError>;
pub fn write_rgba(path: &Path, width: u32, height: u32, rgba: &[u8]) -> Result<(), ImageError>;
pub fn decode_rgba(png_bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), ImageError>;

/// 临时桥：平台层 12 处还在 String 函数里 `?` 的调用点一行不用改，
/// 输出「{这一层}：{source}」，与现在逐字相同。调用方迁完就删。
impl From<ImageError> for String { … }
```

`impl From<ImageError> for String` 符合孤儿规则（`From` 的类型参数是本地类型），clippy 不报。
调用点一共 15 个：12 个 `?`（L 7、W 5）经桥不用改；2 个 `.ok()` 不受影响；**唯一一个直接
`format!("这张图打不开：{e}")` 的（W `clipboard_module.rs:256`）必须改成用桥**（`String::from(e)`
再拼），否则按规则 1 只打得出「这张图打不开：PNG 读取失败」，少了后半句。

### 5.3 文案规则：不能变差

1. **叶子错误**的 `Display` 只写**这一层**（「无法写入 /a/b.png」），底层原因只从
   `source()` 给，不在 `Display` 里重复 —— 这是标准库约定，否则沿链打印时同一句会出现两次。
2. **给人看的文字 = 整条链用「：」连起来**（`chain_message`），与现在
   `format!("{上下文}：{e}")` 的输出逐字相同。临时测试里逐字比对过。
3. **`ToolError` 是链的终点**（`perform` 的边界，不再被别的错误包住），它的 `Display`
   直接输出整条链 —— 所以平台层不管是 `to_string()`、`format!("{err}")` 还是塞进 `MessageBoxW`，
   拿到的都是今天那句话，不会少一截。`chain_message` 遇到 `ToolError` 就停，嵌套
   `.context()` 时每层只出现一次（测过）。
4. 文案都有测试钉住：迁移某处时，先写一条「新类型的 `to_string()` == 旧 `format!` 输出」的测试。
5. 唯一改动的文字：「XX 工具不认识动作 …」与「没有哪个工具认领动作 …」统一成
   `UnknownAction` 的「不认识的动作 {id}」—— **只出现在 stderr**，用户本来就看不到；
   现有测试 `contains("不认识")` 仍然成立（§8 Q5）。

### 5.4 UI 与日志怎么展示

**E2 之后（行为不变）**：只换判断方式，呈现与今天一模一样。

| | Linux 常驻 App | Windows 常驻 App | 命令行 |
|---|---|---|---|
| 所有失败 | 全部 `eprintln!` | 截图 / 取字 / 录屏且不是 `Cancelled` → `MessageBoxW`，其余 `eprintln!`；判断从比字符串改成 `matches!(e, ToolError::Cancelled)` | `错误：{e}`，退出码 1 |

**E6 之后（待拍板 Q3）**：按 `severity()` 分发。

| 分类 | Linux 常驻 App | Windows 常驻 App | 命令行 |
|---|---|---|---|
| `Silent`（取消） | 什么都不显示 | 什么都不显示 | 不变 |
| `Notice`（这次做不了） | `notify-send`（与成功消息同一通道） | 宠物气泡（`Notice::feedback`） | 不变 |
| `Fault`（真坏了） | `notify-send` + `eprintln!` | 截图类照旧弹窗，其余宠物气泡；都 `eprintln!` | 不变 |
| `Bug`（未知动作） | `eprintln!` | `eprintln!` | 不变 |

日志（stderr）打的就是 `Display` 的整条链 —— 至少和今天一样多，在补了 `.context()`
的地方更多（以前被 `.ok()?` 吞掉的现在有一句）。

### 5.5 `#![forbid(unsafe_code)]` 与 clippy 门禁下的写法

1. 全部是安全代码：`Box<dyn Error + Send + Sync>`、`downcast_ref` 都是安全 API。
   `windows::core::Error` 是 `Send + Sync`（windows-result 0.2 对 `ErrorInfo` 显式实现了），
   zbus、x11rb、`io::Error`、png 的错误也都是，所以 `Source` 要求 `Send + Sync` 不会卡住任何一边。
2. **公开枚举的每个变体、每个字段都写 `///`**：`baobox-core` 开着 `missing_docs = "warn"`，
   CI 的 `-D warnings` 会把它变成错误（临时 crate 里专门开着它验过）。
3. 体积：保持在 64 字节以内（`clippy::result_large_err` 门槛 128）；
   以后要装大东西就 `Box` 起来。
4. **不加 `#[non_exhaustive]`**：都是同一仓库内部的类型，穷尽匹配让新增变体时
   编译器逼两个平台都处理 —— 这正是想要的。
5. **不给 `ToolError` 实现 `From<io::Error>`**：逼调用方写 `.context("在做什么")`，
   不写就编不过 —— 这是「说得出失败的操作」的机制保证。只给 `String` / `&str`
   开桥，因为边缘函数的那句话本身已经是完整的上下文。
6. 变体命名避开 `clippy::enum_variant_names`（不要让每个变体都以 `Error` 结尾）。
7. 测试用 `matches!(err, ToolError::Cancelled)` 断言语义；文案另由专门的测试钉住。

### 5.6 守住「不再新增」：棘轮测试

在 `baobox-app` 加一条测试：从 `CARGO_MANIFEST_DIR` 往上找到仓库根，逐个扫六个 crate
的 `src/`，数**非测试代码**里的 `Result<…, String>`（遇到 `#[cfg(test)]` 就停，与本文
计数的口径相同），做两个断言：

1. **六个 crate 的总数** `assert_eq!` 一个写死的基线。多了 → 红，提示「新代码请用
   `ToolError` 或本 crate 的错误类型；确属平台边缘的请在 PR 里说明并改基线」；少了 → 也红，
   提示「把基线改小」—— 逼着基线跟着进度走，以后的回退藏不进余量里。
2. **`baobox-core`、`baobox-image`、`baobox-render` 各自封顶**（E3 / E4 之后都是 0），永远不许涨。

不按 crate 逐个卡死，是因为 #111 会把三份适配层从平台 crate 搬进 `baobox-app`：
`baobox-app` 的数会**上升**，平台的数下降更多，总数下降 —— 按 crate 卡就会把这种好的搬家挡住。
测试失败时把六个 crate 各自的数一起打出来，方便看是谁涨了。

放在 `baobox-app` 里是因为共享层测试在 Linux 和 Windows 两条 CI 上都跑，开发机上
`cargo test` 也跑；它只读文本，不需要 Windows 目标。

## 6. 迁移步骤

每个 PR 单独可合，每步都要过 `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`
与测试（命令见 §7.1）。E1–E4、E7、E8 **行为不变**；E5、E6 改变行为，要先拍板。

| PR | 内容 | 动哪些文件 | 行为 |
|---|---|---|---|
| **E1 错误模块** | 新增 `ToolError` / `Severity` / `ErrorContext` / `chain_message` 与单测（§5.2 那 10 条）；还没有调用方 | shared：新 `baobox-app/src/error.rs`、`lib.rs` 加 `pub mod error` | 不变 |
| **E8 棘轮** | §5.6 的测试：总数基线 = 当时的实际数（现在是 211）；core / image / render 各自封顶（现在 2 / 3 / 0） | shared：`baobox-app` 的测试 | 不变 |
| **E3 快捷键解析** | `hotkey::ParseError`；`KeyCombo::parse` 改返回它；文案测试 | shared：`baobox-core/src/hotkey.rs`（调用方不用改） | 不变；core 归零 |
| **E4 PNG 读写** | `ImageError` + 临时桥 `From<ImageError> for String`；文案测试 | shared：`baobox-image/src/lib.rs`；Windows `clipboard_module.rs:256` 那一处改用桥（其余 12 个 `?` 调用点不用改） | 不变；image 归零 |
| **E2 动作契约**（等 #111 合完） | `ToolModule::perform` / `ToolRegistry::perform` 改返回 `ToolError`；所有实现机械迁移（辅助函数仍可返回 `String`，`perform` 里经桥 `?`）；**截图模块里 8 处「已取消」（W 6、L 2）全部改成 `ToolError::Cancelled`**，它们所在的辅助函数一并改成返回 `ToolError`；命令行 `main.rs` 的 4 处不经过 `perform`，留在边缘（见 Q7）；Windows `app.rs:271` 改 `matches!`，`perform_tool` 跟着改；测试里 25 处 `.unwrap_err().contains(…)` 先改成 `.to_string().contains(…)` | shared：`lib.rs`、`menu.rs`（测试）、`assistant_tool.rs`、`tools/*`（#111 之后）；两边：`app.rs`、`screenshot_module.rs`、`clipboard_module.rs`；Windows：`pet.rs` | 不变（呈现规则照 §5.4「E2 之后」那张表） |
| **E7 逐个工具归类** | 把「这次做不了」改成 `Unavailable`，IO 失败补 `.context()` 并带上 `source`；被 `.ok()?` / `let _ =` 吞掉的落盘失败至少记一句 stderr（§2.4 #5、#6）；测试改成 `matches!`。#111 的三个后端 trait（`AwakeBackend` 等）在这一步改返回 `ToolError`，垫片才说得清「没有活动窗口」是做不了、「摆放窗口失败」是坏了。可按工具拆成几个 PR：共享三工具 + 助手 / 截图 / 剪贴板 / 宠物 | 对应模块、它们的 `store` 调用；共享三工具的 trait 与两边垫片 | 用户界面不变（E6 之前 `Notice` 与 `Fault` 呈现相同）；stderr 多出以前被吞的那几句 |
| **E6 让用户看得到失败**（待拍板 Q3） | 两边常驻 App 按 `severity()` 分发，照 §5.4 | 两边 `app.rs` | **变化**：Linux 用户第一次看得到失败；Windows 非截图类失败从 stderr 改成宠物气泡 |
| **E5 配置读不了时不覆盖**（待拍板 Q4） | `load_config` 区分「没有文件」（`NotFound` → 空配置）与「读不了」（其他 `io::Error` → 返回错误）；启动时遇到后者：先把原文件改名为 `config.ini.unreadable`（已有同名备份就不覆盖），再按默认值继续，并提示一次 | 两边 `store.rs`、`app.rs` | **变化**（修 §2.4 #3） |

建议顺序：E1 → E8 → E3、E4（随时）→ [#111 合完] → E2 → E7 → E6 → E5（E5 拍板后随时可做）。
E2 必须一次改完所有实现：trait 签名是原子的，拆不开；好在全是机械改动，#111 之后要改的文件也少了三组。

预计终点：核心路径 86 处全部类型化；平台边缘 125 处保留（其中开终端那 5 处是平台边界的
函数指针与它的两份实现，签名里的 `String` 就是终端启动失败的那句话），由棘轮看住不再增长。

## 7. 风险与验证

### 7.1 本机怎么验

与 [`MODULE_GLUE.md` §6.1](MODULE_GLUE.md) 相同：共享层 `cargo +1.90.0 fmt --check` /
`clippy --all-targets -- -D warnings` / `test`；Windows 在 Mac 上加
`--target x86_64-pc-windows-gnu` 做 clippy（只能类型检查，真跑看 `build-windows.yml`）；
Linux 用 `baobox-linux-dev:local` 镜像只读挂载跑 fmt / clippy / test（容器里用 `bash -c`，
不要 `bash -lc`）。当前 `main` 的基线三边都是绿的。

### 7.2 风险

| 风险 | 怎么防 |
|---|---|
| E2 漏改一处「已取消」，它经桥变成 `Failed`，Windows 用户按 Esc 也弹「截图操作未完成」 | 截图模块里那 8 处逐个列出、逐个改；加一条测试：截图工具的取消路径返回 `ToolError::Cancelled`；PR 描述里附 `grep -rn '"已取消"' */*/src` 的结果，只许剩命令行 `main.rs` 的 4 处 |
| 桥（`From<String>`）被滥用，核心路径继续产出无类型的 `Failed` | 棘轮只数签名里的 `Result<_, String>`，桥本身不计数；E7 逐个工具清理，review 时看新代码有没有 `.context()` |
| 文案在迁移中走样 | 每迁一处先写「新 `to_string()` == 旧 `format!` 输出」的测试；`ToolError` 的 `Display` 输出整条链，平台层少一截的可能被类型挡住 |
| Windows 路径只能在 CI 上真跑 | E2 的 Windows 改动全是签名与 `match` 臂，本机 clippy 能查出所有类型错误；合并前看 Windows 流水线 |
| E6 让 Linux 多出很多通知（比如反复按跨屏快捷键而只有一块屏） | `Notice` 走 `notify-send` 本来就不抢焦点；若嫌吵，可只对用户主动触发的动作提示（现在就是：`perform` 只在用户点了什么、按了什么时才调） |
| E5 改名备份时目录不可写 | 改名失败就退回「这次只用默认值、不写回」，并在提示里说清楚原文件没动 |

## 8. 待用户拍板

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 引 `thiserror` 还是手写？ | **手写**（§4）。保住 core 的零依赖；以后某个平台 crate 真要定义一大批错误时，可在那个 crate 里局部引 thiserror |
| Q2 | 先 #111 还是先 #110？ | **先 #111**，再做本文的 E2。E1、E3、E4、E8 可以先做；E8 先合的话，#111 的每个 PR 顺手把总数基线改小（合并重复代码会让总数下降） |
| Q3 | 常驻 App 要不要把 `Notice` / `Fault` 显示给用户（Linux 现在一条都看不到，Windows 只有截图类会弹窗）？ | **要**（E6）。像「防休眠没能开启」这样的话本来就是写给用户看的 |
| Q4 | 配置文件读不了时怎么办？ | **改名为 `config.ini.unreadable` 备份，再用默认值继续，提示一次**（E5）。现在的行为是直接覆盖，属于数据丢失 |
| Q5 | 「不认识动作」的 stderr 文案统一成一句？ | **统一**成「不认识的动作 {id}」。只在 stderr，用户看不到，现有测试照样过 |
| Q6 | 这次要不要引日志框架（`log` / `tracing`）？ | **不引**，stderr 够用；另开 issue 再议（真要做，Linux 可接 journald，Windows 可写文件） |
| Q7 | 命令行里取消还打「错误：已取消」、退出码 1？ | 可选：去掉「错误：」前缀，退出码保持 1（脚本能据此判断没出图）。优先级低 |

## 9. 与 issue 描述的出入

- 数量：当前是 **222** 处（issue 写 221），其中生产代码 211、测试 11。
- 「Rust 错误全是 String」基本属实，但分布很不均匀：**211 处里 201 处在两个平台 crate**，
  `baobox-core` 只有 2 处（快捷键解析）。所以「在 `baobox-core` 先引错误枚举」够不着核心路径 ——
  真正的中心是 `baobox-app` 的 `ToolModule::perform`，本设计把主错误类型放在那里，core 只放一个解析错误。
- 「错误上下文丢失」部分属实：多数文案已经写了在做什么、哪个路径（`"{操作}失败：{e}"`）；
  丢的是底层错误的**类型**、错误的**分类**，以及被 `.ok()?` / `let _ =` 整个吞掉的路径。
- 「任何 `Cargo.toml` 里都没有 thiserror / anyhow」属实；但 Linux 的 `Cargo.lock` 里已经
  间接有 `thiserror 1.0.69`（gtk-rs 带进来的）。
- 「非测试 `.unwrap()` 很少」属实（shared 0；Windows 6 + `expect` 2；Linux `expect` 2）。
- 「shared crates 有 `#![forbid(unsafe_code)]`」属实，四个都有；`ARCHITECTURE.md` 约定 2 写的
  「两个 crate」已过期，可在 E1 顺手改掉。
