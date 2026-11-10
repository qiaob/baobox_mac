//! 配置文件的读与**读不了时怎么办**（#152）—— 两个 Rust 平台共用这一份规则。
//!
//! 平台层只决定文件放哪（Linux `~/.config/baobox/config.ini`，Windows
//! `%APPDATA%\Baobox\config.ini`）、怎么把文字写进去，以及提示用什么呈现
//! （Linux 桌面通知，Windows 宠物 / 托盘气泡）。
//!
//! # 「没有文件」和「读不了」是两回事
//!
//! 以前读失败一律 `.ok()` 成「没有文件」，启动时又立刻把默认值存回去 ——
//! 文件在却读不了的用户（典型：用记事本另存成 ANSI，中文系统上就是 GBK，不再是 UTF-8），
//! 下次启动设置就被一份默认值整个盖掉，而且没有任何提示。现在两者分开：
//!
//! | 启动时 | 这次用什么 | 写不写盘 | 告诉用户 |
//! |---|---|---|---|
//! | 没有文件 | 默认值 | 照常：首次启动写一份完整的默认配置 | — |
//! | 读得出来 | 文件里的 | 照常 | — |
//! | 读不了 | 默认值 | 先把原文件改名备份，再照常写一份新的 | 一次：读不了、备份在哪、现在是默认设置 |
//! | 读不了，改名也没成 | 默认值 | **这次运行一概不写**，改动只留在内存里 | 一次：同上，并说原文件没动、这次的改动不会保存 |
//!
//! 最后一行是 [`Session`] 存在的理由：存盘的不止启动那一下（设置窗口、换宠物都会存），
//! 原文件改不了名的那次运行里，哪一处存盘都不能碰它。
//!
//! # 备份叫什么
//!
//! `config.ini.unreadable`。这个名字上已经有东西了（更早某一次读不了时留下的），
//! 就依次试 `config.ini.unreadable.1`、`.2`……用第一个空着的，**从不覆盖**：
//! 每一份都是用户某个时候的设置 —— 又出现一份读不了的，说明用户后来又改过、又存坏了一次，
//! 两份内容不一样，哪份都不能丢。也不选「已有备份就不再备份」：那样新的这份只能留在原处，
//! 此后每次启动都退回不写盘的默认设置，直到用户自己去收拾。编号只在又一次读不了时才涨，
//! 正常使用不会越攒越多；攒满 100 份（`MAX_BACKUPS`）就不再改名，按「改名没成」处理。

use baobox_core::config::Config;
use std::error::Error;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

/// 读不了的配置改名时接在后面的后缀：`config.ini` → `config.ini.unreadable`。
const BACKUP_SUFFIX: &str = ".unreadable";

/// 最多留多少份备份：不带编号的一份，加上 `.1` 到 `.99`。
const MAX_BACKUPS: usize = 100;

/// 这次运行里配置怎么读写。
///
/// 平台层在全局放一个（App 装配、设置窗口的回调、个别工具都会读写配置），
/// 路径每次由平台给 —— 这里只记一件事：这次运行还能不能碰原文件。
#[derive(Debug, Default)]
pub struct Session {
    /// `Some`：启动时原文件读不了、又没能改名备份。这次运行的配置只放在这里，
    /// 读给这份、存只换掉这份，原文件一个字节都不碰
    held: Option<Config>,
}

impl Session {
    /// 照常读写文件。`const`，平台层才能直接放进 `static`。
    pub const fn new() -> Self {
        Self { held: None }
    }

    /// 启动时调一次，拿到这次运行的起点；读不了时按模块文档那张表处置。
    pub fn open(&mut self, path: &Path) -> Startup {
        self.open_with(path, |from, to| std::fs::rename(from, to))
    }

    /// [`Self::open`] 的本体。改名由调用方给，测试才造得出「改名没成」——
    /// 靠把目录设成只读来造的话，以 root 跑（Docker 里的常态）时根本拦不住。
    fn open_with(
        &mut self,
        path: &Path,
        rename: impl FnOnce(&Path, &Path) -> io::Result<()>,
    ) -> Startup {
        let error = match self.load(path) {
            Ok(config) => {
                return Startup {
                    config,
                    problem: None,
                }
            }
            Err(error) => error,
        };
        let problem = match set_aside(path, rename) {
            Ok(backup) => Unreadable::SetAside { error, backup },
            Err(rename) => {
                self.held = Some(Config::new());
                Unreadable::LeftInPlace { error, rename }
            }
        };
        Startup {
            config: Config::new(),
            problem: Some(problem),
        }
    }

    /// 读配置。**没有文件**给空配置；**文件在但读不了**返回错误 —— 调用方不许把它
    /// 当成空配置存回去，那正是 #152 的覆盖。这次运行不许碰原文件时，给内存里那份。
    pub fn load(&self, path: &Path) -> Result<Config, ReadError> {
        match &self.held {
            Some(config) => Ok(config.clone()),
            None => read(path),
        }
    }

    /// 每次存盘之前先过这里。这次运行不许碰原文件时，把这份配置收进内存并返回 `true`
    /// —— 调用方就**别写文件了**；返回 `false` 才照常写。
    pub fn keep_in_memory(&mut self, config: &Config) -> bool {
        match &mut self.held {
            Some(held) => {
                *held = config.clone();
                true
            }
            None => false,
        }
    }
}

/// 启动时读配置的结果。
#[derive(Debug, Default)]
pub struct Startup {
    /// 这次运行从这份配置开始。读不了时是空的：调用方照常补默认值、照常存盘
    /// （不许碰原文件时，那一下存盘只会进内存）
    pub config: Config,
    /// 读不了，以及原文件怎么处置的 —— 要告诉用户一次。一切正常时是 `None`
    pub problem: Option<Unreadable>,
}

/// 启动时配置文件读不了，原文件怎么处置的。
#[derive(Debug)]
pub enum Unreadable {
    /// 原文件已改名备份。这次用默认值，照常存盘（存的是一份新的配置文件）
    SetAside {
        /// 为什么读不了
        error: ReadError,
        /// 原文件现在在哪
        backup: PathBuf,
    },
    /// 改名也没成，原文件留在原处没动。这次用默认值，**整次运行不写盘**
    LeftInPlace {
        /// 为什么读不了
        error: ReadError,
        /// 为什么改不了名
        rename: io::Error,
    },
}

impl Unreadable {
    /// 提示的标题：出了什么事，现在是什么状态。
    pub fn title(&self) -> &'static str {
        "设置文件读不了，现在用的是默认设置"
    }

    /// 提示的正文：为什么读不了，原文件在哪。
    ///
    /// 改名成功时不以句号收尾 —— 结尾是备份的路径，紧跟一个「。」容易被当成文件名的一部分。
    pub fn body(&self) -> String {
        match self {
            Self::SetAside { error, backup } => {
                format!(
                    "原文件{}，已改名备份为 {}",
                    error.reason(),
                    backup.display()
                )
            }
            Self::LeftInPlace { error, rename } => format!(
                "原文件 {} {}；改名备份也没成（{rename}），原文件没动，这次的改动不会保存。",
                error.path().display(),
                error.reason()
            ),
        }
    }
}

impl fmt::Display for Unreadable {
    /// 标题加正文，一整句进日志。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}：{}", self.title(), self.body())
    }
}

/// 配置文件在，但读不出来。
#[derive(Debug)]
pub enum ReadError {
    /// 内容不是 UTF-8 —— 典型是用记事本另存成了 ANSI（中文系统上就是 GBK）
    NotUtf8 {
        /// 读的哪个文件
        path: PathBuf,
        /// 第一处坏掉的字节在哪
        source: std::str::Utf8Error,
    },
    /// 打不开或读不完：没有权限、是个目录、被别的程序占着……
    Io {
        /// 读的哪个文件
        path: PathBuf,
        /// 系统给的原因
        source: io::Error,
    },
}

impl ReadError {
    /// 读的哪个文件。
    pub fn path(&self) -> &Path {
        match self {
            Self::NotUtf8 { path, .. } | Self::Io { path, .. } => path,
        }
    }

    /// 给用户看的原因，接在「原文件」后面。
    fn reason(&self) -> String {
        match self {
            Self::NotUtf8 { .. } => "不是 UTF-8 编码".to_string(),
            Self::Io { source, .. } => format!("打不开（{source}）"),
        }
    }
}

impl fmt::Display for ReadError {
    /// 只说这一层，底层原因从 `source()` 拿（`docs/multiplatform/ERRORS.md` §5.3 的约定）。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotUtf8 { path, .. } => {
                write!(f, "配置文件 {} 不是 UTF-8 编码", path.display())
            }
            Self::Io { path, .. } => write!(f, "读不了配置文件 {}", path.display()),
        }
    }
}

impl Error for ReadError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::NotUtf8 { source, .. } => Some(source),
            Self::Io { source, .. } => Some(source),
        }
    }
}

/// 临时桥（同 `ERRORS.md` §5.2 给 `ImageError` 的那座）：平台层还返回 `String` 的函数
/// 照样能 `?`，得到「这一层：底层原因」一整句。调用方迁到 `ToolError` 之后删掉。
impl From<ReadError> for String {
    fn from(error: ReadError) -> Self {
        match error.source() {
            Some(source) => format!("{error}：{source}"),
            None => error.to_string(),
        }
    }
}

/// 读配置文件本身。见 [`Session::load`]。
fn read(path: &Path) -> Result<Config, ReadError> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        // 路径上有一段不是目录，那里同样不可能有文件 —— 也是「没有」，不是「读不了」
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
            ) =>
        {
            return Ok(Config::new());
        }
        Err(source) => {
            return Err(ReadError::Io {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    match std::str::from_utf8(&bytes) {
        Ok(text) => Ok(Config::parse(text)),
        Err(source) => Err(ReadError::NotUtf8 {
            path: path.to_path_buf(),
            source,
        }),
    }
}

/// 读不了的原文件改名成什么：`config.ini.unreadable`，那里有东西了就 `.1`、`.2`……
/// 取第一个 `taken` 说空着的；`MAX_BACKUPS` 个全占了给 `None`。
///
/// 「有没有东西」由调用方判断，规则本身才能不碰磁盘地单测。
fn backup_path(original: &Path, taken: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let mut first = original.as_os_str().to_os_string();
    first.push(BACKUP_SUFFIX);
    (0..MAX_BACKUPS)
        .map(|n| {
            let mut name = first.clone();
            if n > 0 {
                name.push(format!(".{n}"));
            }
            PathBuf::from(name)
        })
        .find(|candidate| !taken(candidate))
}

/// 把读不了的原文件改名备份，返回它现在在哪。**不覆盖任何已有的东西**。
///
/// 先看名字再改名，中间有一道缝：两个 Baobox 同一瞬间启动才可能撞上，不值得为此上锁。
fn set_aside(
    original: &Path,
    rename: impl FnOnce(&Path, &Path) -> io::Result<()>,
) -> io::Result<PathBuf> {
    // 看 symlink_metadata 而不是 exists()：悬空的符号链接也算占着，不去顶掉它
    let backup = backup_path(original, |candidate| candidate.symlink_metadata().is_ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("已经攒了 {MAX_BACKUPS} 份备份"),
            )
        })?;
    rename(original, &backup)?;
    Ok(backup)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 「截图」两个字的 GBK 编码 —— 用记事本另存为 ANSI 后，中文 Windows 上就是这样。
    /// 0xBD 不可能出现在 UTF-8 的开头，所以一读就坏。
    const GBK: &[u8] = b"[screenshot]\nsave_dir = D:\\\xbd\xd8\xcd\xbc\n";

    /// 每条测试一个干净的临时目录。带上进程号：同时跑的几个 `cargo test` 互不踩。
    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("baobox-config-file-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn not_utf8(path: &Path) -> ReadError {
        ReadError::NotUtf8 {
            path: path.to_path_buf(),
            source: String::from_utf8(GBK.to_vec()).unwrap_err().utf8_error(),
        }
    }

    #[test]
    fn a_missing_file_is_a_first_launch_not_a_problem() {
        let dir = scratch("missing");
        let path = dir.join("config.ini");
        let startup = Session::new().open(&path);
        assert!(startup.problem.is_none());
        assert_eq!(startup.config.to_text(), "");
        assert!(
            !dir.join("config.ini.unreadable").exists(),
            "没有文件就没什么可备份的"
        );
        // 目录都还没有（%APPDATA%\Baobox 在第一次启动前就不存在），或者路径上
        // 有一段根本不是目录 —— 那里都不可能有文件，也都是「没有」
        let session = Session::new();
        let deeper = dir.join("no-such-dir").join("config.ini");
        assert_eq!(session.load(&deeper).unwrap().to_text(), "");
        std::fs::write(dir.join("plain"), "我是个文件").unwrap();
        let through_a_file = dir.join("plain").join("config.ini");
        assert_eq!(session.load(&through_a_file).unwrap().to_text(), "");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_readable_file_is_used_as_is_and_left_alone() {
        let dir = scratch("readable");
        let path = dir.join("config.ini");
        std::fs::write(&path, "[screenshot]\nsave_dir = /tmp/shots\n").unwrap();
        let mut session = Session::new();
        let startup = session.open(&path);
        assert!(startup.problem.is_none());
        assert_eq!(
            startup.config.get("screenshot", "save_dir"),
            Some("/tmp/shots")
        );
        assert!(path.exists());
        assert!(!dir.join("config.ini.unreadable").exists());
        assert!(!session.keep_in_memory(&startup.config), "照常写盘");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_is_not_utf8_is_an_error_not_an_empty_config() {
        let dir = scratch("gbk");
        let path = dir.join("config.ini");
        std::fs::write(&path, GBK).unwrap();
        match Session::new().load(&path) {
            Err(ReadError::NotUtf8 { path: reported, .. }) => assert_eq!(reported, path),
            other => panic!("读不了必须报错，不能当成空配置：{other:?}"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_cannot_be_opened_is_an_error_too() {
        // 拿一个目录冒充配置文件：Linux / macOS 报「是个目录」，Windows 报「拒绝访问」，
        // 都不是「没有」。不靠改权限来造，以 root 跑也成立
        let dir = scratch("directory");
        let path = dir.join("config.ini");
        std::fs::create_dir_all(&path).unwrap();
        assert!(matches!(
            Session::new().load(&path),
            Err(ReadError::Io { .. })
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unreadable_file_is_renamed_aside_and_the_run_starts_from_defaults() {
        let dir = scratch("set-aside");
        let path = dir.join("config.ini");
        std::fs::write(&path, GBK).unwrap();
        let mut session = Session::new();
        let startup = session.open(&path);
        assert_eq!(
            startup.config.to_text(),
            "",
            "从空配置开始，由调用方补默认值"
        );
        let backup = dir.join("config.ini.unreadable");
        match &startup.problem {
            Some(Unreadable::SetAside {
                backup: moved,
                error: ReadError::NotUtf8 { .. },
            }) => assert_eq!(moved, &backup),
            other => panic!("应当改名备份：{other:?}"),
        }
        assert_eq!(
            std::fs::read(&backup).unwrap(),
            GBK,
            "备份就是原文件，一个字节不差"
        );
        assert!(!path.exists(), "原位置空出来，留给新写的默认配置");
        assert!(
            !session.keep_in_memory(&Config::new()),
            "备份好了就照常写盘"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_older_backup_is_never_overwritten() {
        let dir = scratch("older-backup");
        let path = dir.join("config.ini");
        std::fs::write(dir.join("config.ini.unreadable"), "更早那份").unwrap();
        std::fs::write(&path, GBK).unwrap();
        let startup = Session::new().open(&path);
        let numbered = dir.join("config.ini.unreadable.1");
        assert!(matches!(
            &startup.problem,
            Some(Unreadable::SetAside { backup, .. }) if backup == &numbered
        ));
        assert_eq!(
            std::fs::read_to_string(dir.join("config.ini.unreadable")).unwrap(),
            "更早那份"
        );
        assert_eq!(std::fs::read(&numbered).unwrap(), GBK);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn backup_names_count_up_past_the_taken_ones() {
        let original = Path::new("/c/baobox/config.ini");
        let named = |suffix: &str| PathBuf::from(format!("/c/baobox/config.ini{suffix}"));
        assert_eq!(backup_path(original, |_| false), Some(named(".unreadable")));
        let taken = [named(".unreadable"), named(".unreadable.1")];
        assert_eq!(
            backup_path(original, |p| taken.iter().any(|t| t == p)),
            Some(named(".unreadable.2"))
        );
        // 中间空出来的号先用上：哪份都不覆盖就行，编号连不连续无所谓
        let gap = [named(".unreadable"), named(".unreadable.2")];
        assert_eq!(
            backup_path(original, |p| gap.iter().any(|t| t == p)),
            Some(named(".unreadable.1"))
        );
        assert_eq!(backup_path(original, |_| true), None, "攒满了就不再改名");
    }

    #[test]
    fn when_the_rename_fails_nothing_is_written_back_for_the_whole_run() {
        let dir = scratch("left-in-place");
        let path = dir.join("config.ini");
        std::fs::write(&path, GBK).unwrap();
        let mut session = Session::new();
        let startup = session.open_with(&path, |_, _| {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "目录不可写",
            ))
        });
        assert!(matches!(
            startup.problem,
            Some(Unreadable::LeftInPlace { .. })
        ));

        // 启动时补上默认值再存一次 —— 以前就是这一下把用户的文件盖掉的
        let mut config = startup.config;
        config.set("screenshot", "save_to_disk", "true");
        assert!(session.keep_in_memory(&config), "这次运行不许写盘");
        // 之后用户在设置窗口里又改了一项
        config.set("hotkey", "screenshot.capture", "Ctrl+Alt+P");
        assert!(session.keep_in_memory(&config));

        assert_eq!(std::fs::read(&path).unwrap(), GBK, "原文件一个字节都不能动");
        assert!(!dir.join("config.ini.unreadable").exists());
        // 改完设置会重新读一遍：拿到的是内存里这份，改动在这次运行里照样生效
        let reloaded = session.load(&path).unwrap();
        assert_eq!(
            reloaded.get("hotkey", "screenshot.capture"),
            Some("Ctrl+Alt+P")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn running_out_of_backup_names_leaves_the_file_where_it_is() {
        let dir = scratch("full");
        let path = dir.join("config.ini");
        std::fs::write(&path, GBK).unwrap();
        // 真把 100 个名字都占上（空文件，几毫秒的事），走真的改名流程
        for n in 0..MAX_BACKUPS {
            let name = match n {
                0 => "config.ini.unreadable".to_string(),
                n => format!("config.ini.unreadable.{n}"),
            };
            std::fs::write(dir.join(name), "").unwrap();
        }
        let mut session = Session::new();
        match session.open(&path).problem {
            Some(Unreadable::LeftInPlace { rename, .. }) => {
                assert_eq!(rename.kind(), io::ErrorKind::AlreadyExists)
            }
            other => panic!("没有空名字就不该改名：{other:?}"),
        }
        assert_eq!(std::fs::read(&path).unwrap(), GBK, "哪份都没被覆盖");
        assert_eq!(
            std::fs::read(dir.join("config.ini.unreadable.99")).unwrap(),
            b""
        );
        assert!(session.keep_in_memory(&Config::new()), "这次运行不写盘");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_prompt_says_what_happened_where_the_file_went_and_what_is_used_now() {
        let path = PathBuf::from("/c/baobox/config.ini");
        let set_aside = Unreadable::SetAside {
            error: not_utf8(&path),
            backup: PathBuf::from("/c/baobox/config.ini.unreadable"),
        };
        assert!(set_aside.title().contains("读不了"));
        assert!(set_aside.title().contains("默认设置"));
        assert!(set_aside.body().contains("不是 UTF-8"));
        assert!(
            set_aside.body().contains("config.ini.unreadable"),
            "要说清备份在哪"
        );

        let left = Unreadable::LeftInPlace {
            error: not_utf8(&path),
            rename: io::Error::new(io::ErrorKind::PermissionDenied, "拒绝访问"),
        };
        assert!(left.body().contains("原文件没动"));
        assert!(left.body().contains("不会保存"));
        assert!(left.body().contains("拒绝访问"), "改不了名的原因也要给");
        assert!(left.to_string().starts_with(left.title()), "日志里是一整句");
    }

    #[test]
    fn errors_bridged_into_strings_keep_the_underlying_reason() {
        let path = Path::new("/c/config.ini");
        let error = ReadError::Io {
            path: path.to_path_buf(),
            source: io::Error::new(io::ErrorKind::PermissionDenied, "拒绝访问"),
        };
        assert_eq!(
            String::from(error),
            format!("读不了配置文件 {}：拒绝访问", path.display())
        );
    }
}
