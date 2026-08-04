//! 剪贴板历史的落盘，以及落盘加密（Windows）。
//!
//! 淘汰规则与索引格式在 `baobox_core::clipboard`（三平台共用），
//! 这里只管「存哪、怎么保护」。
//!
//! # 为什么要加密
//!
//! 剪贴板历史是**长期留存**的：几百条曾经复制过的东西躺在磁盘上。
//! 里面难免有内网地址、订单号、一次性验证码这类不算机密但也不想外泄的内容。
//! 备份、漫游配置、二手硬盘都会把它带走。
//!
//! # 密钥放哪：不放，交给 DPAPI
//!
//! Linux 那边要自己拿密钥（Secret Service）再自己做 AES-GCM；Windows 上
//! **不需要密钥这个概念** —— `CryptProtectData` 直接把一段数据封给
//! 「当前用户」，密钥由系统派生并保管，换个账号（哪怕是同一台机器上的管理员）
//! 也解不开。这就是 macOS 的 Keychain、Linux 的 Secret Service 在这个平台上的对应物，
//! 而且它是系统内建的，没有「装没装密钥环」这个变数。
//!
//! # DPAPI 失败时**不假装加密**
//!
//! 与 Linux 侧同一条约定：封不上就退回明文，并且明确告诉用户。
//! 自己造一个密钥、和密文放在同一个目录里，是一种看起来加密了、
//! 实际上没有增加任何安全性的自欺 —— 能读到密文的人一样能读到密钥。
//!
//! # 这个模块不加 `cfg(windows)`
//!
//! 目录规则与「加密 / 明文」的判定是纯逻辑，不加门它们的测试在开发机上也能跑。
//! 只有真正调 DPAPI 的那两个函数带门，非 Windows 上直接返回「封不上」，
//! 于是退回明文 —— 与真机上密码学不可用时是同一条路径。

use baobox_core::clipboard::{decode_index, encode_index, Store};
use std::path::PathBuf;

/// 历史文件名。
const HISTORY: &str = "clipboard.dat";

/// 密文文件的头，用来区分「封过的」与「明文的」。
///
/// 与 Linux 版同一个魔数：两边的文件格式一致，将来做同步时不用再分情况。
const MAGIC: &[u8] = b"BAOBOX1\n";

/// 剪贴板数据目录：`%APPDATA%\Baobox\clipboard\`。
pub fn dir() -> Option<PathBuf> {
    crate::store::dir().and_then(|d| d.parent().map(|base| base.join("clipboard")))
}

/// 图片落在哪。
pub fn image_dir() -> Option<PathBuf> {
    dir().map(|d| d.join("images"))
}

/// 这次读写有没有真的加密。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protection {
    /// 内容由 DPAPI 封给当前用户
    Encrypted,
    /// DPAPI 用不了，内容是明文
    PlainText,
}

impl Protection {
    /// 一句给用户看的说明。
    pub fn describe(&self) -> &'static str {
        match self {
            Protection::Encrypted => "剪贴板历史已加密（只有当前 Windows 账号解得开）。",
            Protection::PlainText => {
                "系统的数据保护接口不可用，剪贴板历史以明文保存在你的用户目录里。"
            }
        }
    }
}

/// 读回历史。
///
/// 读不出来就当是空的 —— 历史坏了不该让程序起不来。
pub fn load(limit: usize) -> (Store, Protection) {
    let Some(path) = dir().map(|d| d.join(HISTORY)) else {
        return (Store::new(limit), Protection::PlainText);
    };
    let Ok(bytes) = std::fs::read(&path) else {
        // 还没有历史文件：按现在封不封得上来报告保护级别
        return (Store::new(limit), current_protection());
    };
    let (text, protection) = unseal(&bytes);
    match text {
        Some(plain) => (decode_index(&plain, limit), protection),
        // 封过但解不开（换了账号、配置文件被搬过来）：这份历史读不回来了。
        // 空历史比崩溃好，而且**不能把文件删掉** —— 用户可能还想在原来那台机器上找回它
        None => (Store::new(limit), protection),
    }
}

/// 写回历史。
pub fn save(store: &Store) -> Result<Protection, String> {
    let dir = dir().ok_or("找不到数据目录（%APPDATA% 未设置）")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建目录失败：{e}"))?;
    let (bytes, protection) = seal(&encode_index(store));
    std::fs::write(dir.join(HISTORY), bytes).map_err(|e| format!("写入历史失败：{e}"))?;
    Ok(protection)
}

/// 现在封得上吗。
pub fn current_protection() -> Protection {
    match protect(b"probe") {
        Some(_) => Protection::Encrypted,
        None => Protection::PlainText,
    }
}

/// 明文 → 落盘用的字节。封不上就原样写明文。
fn seal(plain: &str) -> (Vec<u8>, Protection) {
    match protect(plain.as_bytes()) {
        Some(sealed) => {
            let mut out = MAGIC.to_vec();
            out.extend_from_slice(&sealed);
            (out, Protection::Encrypted)
        }
        None => (plain.as_bytes().to_vec(), Protection::PlainText),
    }
}

/// 落盘的字节 → 明文。
///
/// 返回的保护级别说的是**这份文件**是怎么存的，不是现在能不能封 ——
/// 菜单里要显示的是「你磁盘上那份东西的状态」。
fn unseal(bytes: &[u8]) -> (Option<String>, Protection) {
    match bytes.strip_prefix(MAGIC) {
        Some(body) => (
            unprotect(body).and_then(|plain| String::from_utf8(plain).ok()),
            Protection::Encrypted,
        ),
        None => (
            Some(String::from_utf8_lossy(bytes).into_owned()),
            Protection::PlainText,
        ),
    }
}

/// 把一段数据封给当前用户。
#[cfg(windows)]
fn protect(plain: &[u8]) -> Option<Vec<u8>> {
    crypt(plain, true)
}

/// 解封。
#[cfg(windows)]
fn unprotect(sealed: &[u8]) -> Option<Vec<u8>> {
    crypt(sealed, false)
}

/// `CryptProtectData` / `CryptUnprotectData`。
///
/// 两个方向的参数与收尾完全一样，只有调哪个函数不同，所以写在一处 ——
/// 分成两份的话，迟早有一边忘了 `LocalFree`。
#[cfg(windows)]
fn crypt(input: &[u8], seal: bool) -> Option<Vec<u8>> {
    use windows::Win32::Foundation::{LocalFree, HLOCAL};
    use windows::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    // 空输入不必进 DPAPI，也省得处理「长度为 0 的 blob」这种边角情况
    if input.is_empty() {
        return Some(Vec::new());
    }

    unsafe {
        let source = CRYPT_INTEGER_BLOB {
            cbData: input.len() as u32,
            pbData: input.as_ptr() as *mut u8,
        };
        let mut out = CRYPT_INTEGER_BLOB::default();
        // CRYPTPROTECT_UI_FORBIDDEN：绝不能弹窗。这个调用可能发生在
        // 退出流程里，弹一个用户看不懂的对话框比存不下来更糟
        let ok = if seal {
            CryptProtectData(
                &source,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        } else {
            CryptUnprotectData(
                &source,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut out,
            )
        };
        if ok.is_err() || out.pbData.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(out.pbData, out.cbData as usize).to_vec();
        // 输出缓冲由 DPAPI 用 LocalAlloc 分配，归我们释放
        let _ = LocalFree(HLOCAL(out.pbData as *mut core::ffi::c_void));
        Some(bytes)
    }
}

/// 非 Windows 上没有 DPAPI —— 走「封不上」那条路，也就是明文。
///
/// 这不是降级实现，只是让交叉编译时的类型检查与测试跑得起来。
#[cfg(not(windows))]
fn protect(_plain: &[u8]) -> Option<Vec<u8>> {
    None
}

#[cfg(not(windows))]
fn unprotect(_sealed: &[u8]) -> Option<Vec<u8>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_data_sits_beside_the_screenshot_data_not_inside_it() {
        // 各模块一个子目录，互不串扰（根 CLAUDE.md 约定 8）
        let screenshot = crate::store::dir();
        // 环境里没有 %APPDATA% / %USERPROFILE% 时这两个都是 None，跳过
        let (Some(screenshot), Some(clip)) = (screenshot, dir()) else {
            return;
        };
        assert_eq!(clip.parent(), screenshot.parent(), "两个模块该是兄弟目录");
        assert!(clip.ends_with("clipboard"));
        assert!(image_dir().unwrap().starts_with(&clip));
    }

    #[test]
    fn a_plain_file_round_trips_when_sealing_is_unavailable() {
        // 非 Windows 上 protect 永远返回 None，正好走明文那条路
        let (bytes, protection) = seal("第一条\t带制表符\n第二条");
        if protection == Protection::PlainText {
            assert!(!bytes.starts_with(MAGIC), "没封上就不该带密文头");
            let (text, level) = unseal(&bytes);
            assert_eq!(text.unwrap(), "第一条\t带制表符\n第二条");
            assert_eq!(level, Protection::PlainText);
        }
    }

    #[test]
    fn the_magic_header_tells_sealed_files_from_plain_ones() {
        let mut sealed = MAGIC.to_vec();
        sealed.extend_from_slice(b"\x01\x02\x03");
        let (_, level) = unseal(&sealed);
        assert_eq!(level, Protection::Encrypted, "带头的必须按密文处理");
        // 明文的历史文件是 TSV，绝不会以这个头开始
        let (text, level) = unseal(b"id\ttext\t");
        assert_eq!(level, Protection::PlainText);
        assert_eq!(text.unwrap(), "id\ttext\t");
    }

    #[test]
    fn a_sealed_file_that_cannot_be_opened_reports_no_text_rather_than_garbage() {
        // 换了账号 / 把文件搬到别的机器上：解不开就是解不开，
        // 绝不能把密文当成明文读出来塞进历史
        let mut sealed = MAGIC.to_vec();
        sealed.extend_from_slice(&[0xFF; 32]);
        let (text, level) = unseal(&sealed);
        assert!(text.is_none());
        assert_eq!(level, Protection::Encrypted);
    }

    #[test]
    fn an_empty_file_does_not_panic() {
        let (text, level) = unseal(&[]);
        assert_eq!(text.unwrap(), "");
        assert_eq!(level, Protection::PlainText);
        // 只有一个头、后面什么都没有
        let (text, _) = unseal(MAGIC);
        assert!(text.is_none() || text.unwrap().is_empty());
    }

    #[test]
    fn both_protection_levels_explain_themselves() {
        assert!(Protection::Encrypted.describe().contains("已加密"));
        let plain = Protection::PlainText.describe();
        assert!(plain.contains("明文"), "没加密就要说清楚，不能假装加密了");
    }
}
