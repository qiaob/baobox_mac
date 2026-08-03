//! 录屏：把一块区域录成视频。
//!
//! # 为什么调 ffmpeg 而不是自己编码
//!
//! macOS 侧用的是 AVFoundation —— 系统自带的编码器。Linux 上没有对等物：
//! 要自己编码就得引入 x264 / libvpx（GPL 与专利问题各一堆），
//! 或者塞一个纯 Rust 编码器进来（体积与质量都不合算）。
//!
//! 而 ffmpeg 在 Linux 上几乎是「事实上的系统组件」，抓屏（`x11grab`）、
//! 编码、封装一条命令搞定，还顺带解决了音频。所以这里**只做参数拼装与进程管理**，
//! 编码交给它。没装时给一句能直接照做的安装提示，与屏幕取字同一条约定。
//!
//! # 怎么停
//!
//! 往 ffmpeg 的标准输入写一个 `q` —— 它会**写完文件尾再退出**。
//! 直接杀进程会留下一个没有 moov box 的 mp4，多数播放器打不开。

use baobox_core::geometry::Rect;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, Stdio};

/// 默认帧率。截屏演示 15 帧足够清楚，文件也小。
pub const DEFAULT_FPS: u32 = 15;

/// 一次正在进行的录制。
pub struct Recording {
    child: Child,
}

impl Recording {
    /// 优雅停止：写 `q` 让 ffmpeg 自己收尾，再等它退出。
    pub fn stop(mut self) -> Result<(), String> {
        if let Some(stdin) = self.child.stdin.as_mut() {
            let _ = stdin.write_all(b"q");
            let _ = stdin.flush();
        }
        // 关掉 stdin，ffmpeg 读到 EOF 也会退出 —— 双保险
        drop(self.child.stdin.take());
        let status = self
            .child
            .wait()
            .map_err(|e| format!("等待 ffmpeg 退出失败：{e}"))?;
        if status.success() {
            Ok(())
        } else {
            Err("ffmpeg 以非零状态退出，录制的文件可能不完整".to_string())
        }
    }
}

#[cfg(test)]
impl Recording {
    /// 造一个不真的录屏的 `Recording`，只为让「正在录制」这个状态可测。
    ///
    /// 菜单在录制中要把「录屏…」换成「停止录制」，那是常驻 App 里唯一的停止入口，
    /// 值得有测试盯着；而为了测这一条真去起 ffmpeg 既慢又要求环境里有它。
    pub fn detached() -> Recording {
        let child = Command::new("sleep")
            .arg("0")
            .stdin(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("sleep 是 POSIX 必备命令");
        Recording { child }
    }
}

/// 开始录制一块区域。
pub fn start(region: Rect, fps: u32, output: &Path) -> Result<Recording, String> {
    let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into());
    let args = build_args(region, fps, &display, output);
    let child = Command::new("ffmpeg")
        .args(&args)
        .stdin(Stdio::piped())
        // ffmpeg 一直往 stderr 刷进度，直接继承会把终端刷满
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| unavailable(&e))?;
    Ok(Recording { child })
}

/// 拼 ffmpeg 的参数。
///
/// 几个不能省的点：
///
/// - `-video_size` 必须给**偶数**宽高：H.264 的 4:2:0 色度采样要求宽高是 2 的倍数，
///   奇数会被 ffmpeg 直接拒掉（`width not divisible by 2`）。用户框选出奇数尺寸很常见。
/// - `-i :0.0+X,Y` 是 x11grab 的坐标语法，`+` 后面跟偏移。
/// - `-pix_fmt yuv420p`：不给的话 ffmpeg 会选 yuv444p，很多播放器与浏览器不认。
/// - `-y` 覆盖同名文件：文件名由我们生成，不会撞到用户的东西。
pub fn build_args(region: Rect, fps: u32, display: &str, output: &Path) -> Vec<String> {
    let width = even(region.w);
    let height = even(region.h);
    vec![
        "-y".to_string(),
        "-f".to_string(),
        "x11grab".to_string(),
        "-framerate".to_string(),
        fps.max(1).to_string(),
        "-video_size".to_string(),
        format!("{width}x{height}"),
        "-i".to_string(),
        format!("{display}+{},{}", region.x.round() as i64, region.y.round() as i64),
        "-c:v".to_string(),
        "libx264".to_string(),
        "-preset".to_string(),
        "veryfast".to_string(),
        "-pix_fmt".to_string(),
        "yuv420p".to_string(),
        output.to_string_lossy().to_string(),
    ]
}

/// 向下取到偶数，且至少为 2。
fn even(value: f64) -> i64 {
    let rounded = value.round() as i64;
    (rounded - rounded % 2).max(2)
}

fn unavailable(error: &std::io::Error) -> String {
    if error.kind() == std::io::ErrorKind::NotFound {
        return "没找到 ffmpeg。录屏需要它：\
                Debian/Ubuntu `sudo apt install ffmpeg`，\
                Arch `sudo pacman -S ffmpeg`，\
                Fedora `sudo dnf install ffmpeg`。"
            .to_string();
    }
    format!("无法运行 ffmpeg：{error}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn args(region: Rect) -> Vec<String> {
        build_args(region, 15, ":0.0", &PathBuf::from("/tmp/out.mp4"))
    }

    #[test]
    fn odd_sizes_are_rounded_down_to_even() {
        // H.264 的 4:2:0 不接受奇数宽高，而用户框出 801×601 是常事
        let a = args(Rect::new(0.0, 0.0, 801.0, 601.0));
        let size = &a[a.iter().position(|x| x == "-video_size").unwrap() + 1];
        assert_eq!(size, "800x600");
    }

    #[test]
    fn a_degenerate_region_still_produces_a_legal_size() {
        let a = args(Rect::new(0.0, 0.0, 1.0, 0.0));
        let size = &a[a.iter().position(|x| x == "-video_size").unwrap() + 1];
        assert_eq!(size, "2x2", "不能给出 0×0，ffmpeg 会直接失败");
    }

    #[test]
    fn the_offset_uses_the_x11grab_syntax() {
        let a = args(Rect::new(120.0, 80.0, 400.0, 300.0));
        let input = &a[a.iter().position(|x| x == "-i").unwrap() + 1];
        assert_eq!(input, ":0.0+120,80");
    }

    #[test]
    fn the_pixel_format_is_the_widely_playable_one() {
        // 不指定的话会选 yuv444p，浏览器与很多播放器放不了
        let a = args(Rect::new(0.0, 0.0, 100.0, 100.0));
        assert!(a.windows(2).any(|w| w[0] == "-pix_fmt" && w[1] == "yuv420p"));
    }

    #[test]
    fn zero_fps_is_bumped_to_something_legal() {
        let a = build_args(
            Rect::new(0.0, 0.0, 100.0, 100.0),
            0,
            ":0",
            &PathBuf::from("/tmp/x.mp4"),
        );
        let fps = &a[a.iter().position(|x| x == "-framerate").unwrap() + 1];
        assert_eq!(fps, "1");
    }

    #[test]
    fn a_missing_binary_explains_what_to_install() {
        let error = unavailable(&std::io::Error::from(std::io::ErrorKind::NotFound));
        assert!(error.contains("ffmpeg"));
        assert!(error.contains("apt install"));
    }
}
