//! 开一个终端，把命令交给它（Linux）。
//!
//! 「续接会话」要跑 `claude --resume <id>`，而那是个**交互式**程序 ——
//! 我们自己 `spawn` 的话，用户既看不到界面也没法打字。所以必须开一个
//! 真正的终端窗口。
//!
//! # Linux 上没有「那个终端」
//!
//! macOS 有 Terminal.app，Windows 有 `cmd`；Linux 上装了什么完全看人。
//! 所以按一个候选表逐个试，**用第一个真的存在的**。用户也可以在设置里
//! 指名，那时就只试他指的那一个 —— 指了却用了别的，比失败更让人困惑。
//!
//! # 各家的「执行这条命令」参数还不一样
//!
//! 大多数认 `-e`，但 `gnome-terminal` 要 `--`，`konsole` 也认 `-e`
//! 但对带空格的命令处理不同。所以候选表里连参数一起写死。

use std::path::Path;
use std::process::{Command, Stdio};

/// 候选终端与它的「执行这条命令」参数。
///
/// 顺序是有讲究的：把行为最可预期的排在前面。`x-terminal-emulator`
/// 是 Debian 系的统一入口，放最后当兜底。
pub const CANDIDATES: [(&str, &[&str]); 8] = [
    ("kitty", &[]),
    ("alacritty", &["-e"]),
    ("wezterm", &["start", "--"]),
    ("konsole", &["-e"]),
    ("xfce4-terminal", &["-e"]),
    ("gnome-terminal", &["--"]),
    ("xterm", &["-e"]),
    ("x-terminal-emulator", &["-e"]),
];

/// 开一个终端，在 `cwd` 里跑 `command`。
///
/// `preferred` 非空时**只**试它 —— 用户指名了却用了别的，比失败更让人困惑。
pub fn open(preferred: &str, cwd: &str, command: &str) -> Result<(), String> {
    let preferred = preferred.trim();
    if !preferred.is_empty() {
        let args = CANDIDATES
            .iter()
            .find(|(name, _)| *name == preferred)
            .map(|(_, args)| *args)
            // 不认识的终端按最通用的 `-e` 试
            .unwrap_or(&["-e"]);
        return spawn(preferred, args, cwd, command)
            .map_err(|why| format!("启动 {preferred} 失败：{why}"));
    }
    for (name, args) in CANDIDATES {
        if spawn(name, args, cwd, command).is_ok() {
            return Ok(());
        }
    }
    Err(format!(
        "没找到可用的终端（试过 {}）。在设置里指定一个即可。",
        CANDIDATES
            .iter()
            .map(|(n, _)| *n)
            .collect::<Vec<_>>()
            .join(" / ")
    ))
}

fn spawn(program: &str, args: &[&str], cwd: &str, command: &str) -> Result<(), String> {
    let mut process = Command::new(program);
    process.args(args);
    // 交给 sh 而不是直接执行：命令里带参数，而各家终端对
    // 「后面这一串是一条命令还是一串参数」理解不一
    process.arg("sh").arg("-c").arg(shell_line(command));
    if !cwd.is_empty() && Path::new(cwd).is_dir() {
        process.current_dir(cwd);
    }
    // 终端的输出归它自己，别灌进我们的日志
    process.stdout(Stdio::null()).stderr(Stdio::null());
    process.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// 跑完命令之后**别立刻关窗口**。
///
/// 关掉的话，命令要是一启动就报错，用户连错误信息都来不及看见 ——
/// 只会看到一个窗口闪一下就没了，然后完全不知道发生了什么。
fn shell_line(command: &str) -> String {
    format!("{command}; echo; echo '（按回车关闭）'; read _")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_stays_open_after_the_command_finishes() {
        // 关掉的话，命令一启动就报错时用户连错误信息都看不见
        let line = shell_line("claude --resume abc");
        assert!(line.starts_with("claude --resume abc"));
        assert!(line.contains("read"), "要停下来等用户：{line}");
    }

    #[test]
    fn every_candidate_declares_how_to_pass_it_a_command() {
        // gnome-terminal 要 `--` 而不是 `-e`，写错的表现是它把命令当成自己的参数
        for (name, args) in CANDIDATES {
            assert!(!name.is_empty());
            if name == "gnome-terminal" {
                assert_eq!(args, &["--"]);
            }
        }
    }

    #[test]
    fn asking_for_a_terminal_that_is_not_installed_fails_instead_of_using_another() {
        // 用户指名了却用了别的，比失败更让人困惑
        let why = open("这个终端一定没装", "", "true").unwrap_err();
        assert!(why.contains("这个终端一定没装"), "{why}");
    }

    #[test]
    fn the_failure_message_lists_what_was_tried_and_what_to_do() {
        // 这个容器里一个终端都没装，正好走到兜底那条路
        if let Err(why) = open("", "", "true") {
            assert!(why.contains("设置"), "要告诉用户怎么办：{why}");
            assert!(why.contains("xterm"), "要说清楚试过哪些：{why}");
        }
    }
}
