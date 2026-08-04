//! 开一个终端，把命令交给它（Windows）。
//!
//! 「续接会话」要跑 `claude --resume <id>`，那是个**交互式**程序 ——
//! 我们自己 `spawn` 的话，用户既看不到界面也没法打字。所以必须开一个
//! 真正的终端窗口。
//!
//! # 这个平台上简单得多
//!
//! Linux 上装了什么终端完全看人，要拿一张候选表挨个试；Windows 上
//! `cmd.exe` 一定在，`wt.exe`（Windows Terminal）在新系统上也基本都有。
//! 所以只有两个候选，而且兜底那个不会失败。
//!
//! # `cmd /K` 而不是 `/C`
//!
//! `/C` 是「跑完就关」。命令要是一启动就报错，用户只会看到一个窗口
//! 闪一下就没了，完全不知道发生了什么。`/K` 跑完把窗口留着。

#![cfg(windows)]

use std::path::Path;
use std::process::Command;

/// 候选终端。**顺序有讲究**：先试 Windows Terminal（外观与体验都更好），
/// 兜底 `cmd.exe`（它一定在）。
pub const CANDIDATES: [&str; 2] = ["wt.exe", "cmd.exe"];

/// 开一个终端，在 `cwd` 里跑 `command`。
///
/// `preferred` 非空时**只**试它 —— 用户指名了却用了别的，比失败更让人困惑。
pub fn open(preferred: &str, cwd: &str, command: &str) -> Result<(), String> {
    let preferred = preferred.trim();
    if !preferred.is_empty() {
        return spawn(preferred, cwd, command)
            .map_err(|why| format!("启动 {preferred} 失败：{why}"));
    }
    for name in CANDIDATES {
        if spawn(name, cwd, command).is_ok() {
            return Ok(());
        }
    }
    Err("开不了终端窗口（cmd.exe 都启动不了，系统可能有问题）".to_string())
}

fn spawn(program: &str, cwd: &str, command: &str) -> Result<(), String> {
    let mut process = Command::new(program);
    // Windows Terminal 要先说「在这个新标签里跑」，后面才是真正的命令
    if program.eq_ignore_ascii_case("wt.exe") {
        process.arg("new-tab");
        if !cwd.is_empty() {
            process.arg("-d").arg(cwd);
        }
        process.arg("cmd.exe");
    }
    // /K：跑完把窗口留着。用 /C 的话命令一报错窗口就闪没了
    process.arg("/K").arg(command);
    if !cwd.is_empty() && Path::new(cwd).is_dir() {
        process.current_dir(cwd);
    }
    process.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmd_is_the_last_candidate_because_it_is_always_there() {
        assert_eq!(CANDIDATES.last(), Some(&"cmd.exe"));
        assert!(CANDIDATES.contains(&"wt.exe"), "有 Windows Terminal 时该优先用它");
    }

    #[test]
    fn asking_for_a_terminal_that_is_not_installed_fails_instead_of_using_another() {
        // 用户指名了却用了别的，比失败更让人困惑
        let why = open("这个终端一定没装.exe", "", "echo hi").unwrap_err();
        assert!(why.contains("这个终端一定没装"), "{why}");
    }
}
