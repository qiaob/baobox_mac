//! 录屏（Windows）：调 ffmpeg 的 `gdigrab`。
//!
//! # 为什么和 Linux 一样外挂 ffmpeg
//!
//! Windows 自带的编码路径是 Media Foundation：能用，但要走 COM、
//! 自己管 `IMFSinkWriter` 的时间戳与缓冲，光把「录一段能播的 mp4」做对
//! 就是一块独立工程 —— 而它解决的问题 ffmpeg 一条命令就解决了。
//!
//! 录屏是低频操作，多一个外部依赖换来的是**少一大块自己维护的编码代码**。
//! 没装时给一句能照做的话，与屏幕取字、与 Linux 侧同一条约定。
//!
//! # `gdigrab` 的坐标语法与 Linux 不同
//!
//! x11grab 把偏移写在输入名里（`:0.0+X,Y`），gdigrab 用**单独的选项**
//! （`-offset_x` / `-offset_y`），输入名固定是 `desktop`。写混了会得到
//! 「找不到输入设备」这种毫不相干的报错。
//!
//! # 这个模块不加 `cfg(windows)`
//!
//! 里面只有 `std::process` 与字符串拼装，没有一行 Win32。不加门就意味着
//! **参数拼装的那几条测试在开发机上也能跑** —— 而那正是最容易写错、
//! 又最难在真机上发现的部分（少一个 `-pix_fmt` 要等到播放器打不开才知道）。

use baobox_core::geometry::Rect;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, Stdio};

/// 默认帧率。与 Linux 版一致。
pub const DEFAULT_FPS: u32 = 15;

/// 一次正在进行的录制。
pub struct Recording {
    child: Child,
}

impl Recording {
    /// 优雅停止：写 `q` 让 ffmpeg 自己写完文件尾。
    ///
    /// 直接杀进程会留下没有 moov box 的 mp4，多数播放器打不开。
    pub fn stop(mut self) -> Result<(), String> {
        if let Some(stdin) = self.child.stdin.as_mut() {
            let _ = stdin.write_all(b"q");
            let _ = stdin.flush();
        }
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

/// 开始录制一块区域。
pub fn start(region: Rect, fps: u32, output: &Path) -> Result<Recording, String> {
    let child = Command::new("ffmpeg")
        .args(build_args(region, fps, output))
        .stdin(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| unavailable(&e))?;
    Ok(Recording { child })
}

/// 拼 ffmpeg 的参数。
///
/// 与 Linux 版共享同样的两条硬约束：宽高必须是偶数（H.264 的 4:2:0），
/// 像素格式必须显式给 `yuv420p`（否则默认的 yuv444p 很多播放器不认）。
pub fn build_args(region: Rect, fps: u32, output: &Path) -> Vec<String> {
    vec![
        "-y".to_string(),
        "-f".to_string(),
        "gdigrab".to_string(),
        "-framerate".to_string(),
        fps.max(1).to_string(),
        "-offset_x".to_string(),
        (region.x.round() as i64).to_string(),
        "-offset_y".to_string(),
        (region.y.round() as i64).to_string(),
        "-video_size".to_string(),
        format!("{}x{}", even(region.w), even(region.h)),
        "-i".to_string(),
        "desktop".to_string(),
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
        return "没找到 ffmpeg。录屏需要它：`winget install Gyan.FFmpeg`，\
                或从 https://ffmpeg.org/download.html 下载后把 ffmpeg.exe 所在目录加进 PATH。"
            .to_string();
    }
    format!("无法运行 ffmpeg：{error}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn args(region: Rect) -> Vec<String> {
        build_args(region, 15, &PathBuf::from("out.mp4"))
    }

    #[test]
    fn the_offset_uses_separate_options_not_the_x11grab_syntax() {
        let a = args(Rect::new(120.0, 80.0, 400.0, 300.0));
        assert!(a.windows(2).any(|w| w[0] == "-offset_x" && w[1] == "120"));
        assert!(a.windows(2).any(|w| w[0] == "-offset_y" && w[1] == "80"));
        // 输入名固定是 desktop
        assert_eq!(&a[a.iter().position(|x| x == "-i").unwrap() + 1], "desktop");
    }

    #[test]
    fn odd_sizes_are_rounded_down_to_even() {
        let a = args(Rect::new(0.0, 0.0, 801.0, 601.0));
        let size = &a[a.iter().position(|x| x == "-video_size").unwrap() + 1];
        assert_eq!(size, "800x600");
    }

    #[test]
    fn a_degenerate_region_still_produces_a_legal_size() {
        let a = args(Rect::new(0.0, 0.0, 0.0, 1.0));
        let size = &a[a.iter().position(|x| x == "-video_size").unwrap() + 1];
        assert_eq!(size, "2x2");
    }

    #[test]
    fn negative_offsets_survive_because_monitors_can_sit_left_of_the_primary() {
        // 副屏在主屏左边时虚拟屏幕坐标是负的
        let a = args(Rect::new(-1920.0, 0.0, 800.0, 600.0));
        assert!(a.windows(2).any(|w| w[0] == "-offset_x" && w[1] == "-1920"));
    }

    #[test]
    fn the_pixel_format_is_the_widely_playable_one() {
        let a = args(Rect::new(0.0, 0.0, 100.0, 100.0));
        assert!(a.windows(2).any(|w| w[0] == "-pix_fmt" && w[1] == "yuv420p"));
    }

    #[test]
    fn a_missing_binary_explains_what_to_install() {
        let error = unavailable(&std::io::Error::from(std::io::ErrorKind::NotFound));
        assert!(error.contains("ffmpeg"));
        assert!(error.contains("winget"), "要给出能直接照做的命令");
    }
}
