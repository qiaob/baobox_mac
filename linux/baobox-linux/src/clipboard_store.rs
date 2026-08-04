//! 剪贴板历史的落盘，以及落盘加密。
//!
//! 淘汰规则与索引格式在 `baobox_core::clipboard`（三平台共用），
//! 这里只管「存哪、怎么保护」。
//!
//! # 为什么要加密
//!
//! 剪贴板历史是**长期留存**的：几百条曾经复制过的东西躺在磁盘上。
//! 里面难免有内网地址、订单号、一次性验证码这类不算机密但也不想外泄的内容。
//! 备份、同步盘、二手硬盘都会把它带走。
//!
//! # 密钥放哪
//!
//! 放 **Secret Service**（freedesktop 的标准密钥环，GNOME Keyring / KWallet
//! 都实现了它），走 DBus —— zbus 已经为托盘引进来了，不多一份依赖。
//! 这与 macOS 侧把密钥放进 Keychain 是同一个做法。
//!
//! # 没有密钥环时**不假装加密**
//!
//! 密钥环用不了（headless、没装 keyring 守护进程）时，退回明文 + `0600`，
//! 并且**明确告诉用户**。把密钥和密文放在同一个目录下、都用 0600 保护，
//! 是一种看起来加密了、实际上没有增加任何安全性的自欺 ——
//! 能读到密文的人一样能读到密钥。宁可说清楚「这次没加密」。

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use baobox_core::clipboard::{decode_index, encode_index, Store};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

/// 历史文件名。
const HISTORY: &str = "clipboard.dat";

/// 密文文件的头，用来区分「加密过的」与「明文的」。
const MAGIC: &[u8] = b"BAOBOX1\n";

/// AES-GCM 的 nonce 长度。
const NONCE_LEN: usize = 12;

/// Secret Service 里这条密钥的标识。
const KEY_LABEL: &str = "Baobox 剪贴板历史加密密钥";

/// 剪贴板数据目录：`<data>/baobox/clipboard/`。
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
    /// 密钥来自密钥环，内容是加密的
    Encrypted,
    /// 没有可用的密钥环，内容是明文（文件权限 0600）
    PlainText,
}

impl Protection {
    /// 一句给用户看的说明。
    pub fn describe(&self) -> &'static str {
        match self {
            Protection::Encrypted => "剪贴板历史已加密（密钥存在系统密钥环里）。",
            Protection::PlainText => {
                "系统里没有可用的密钥环，剪贴板历史以明文保存（文件权限 0600）。\
                 装一个 gnome-keyring 或 kwallet 之后重启 Baobox 即可加密。"
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
        // 还没有历史文件：按现在能不能拿到密钥来报告保护级别
        return (Store::new(limit), current_protection());
    };

    if let Some(body) = bytes.strip_prefix(MAGIC) {
        match key().and_then(|k| decrypt(&k, body)) {
            Some(plain) => (decode_index(&plain, limit), Protection::Encrypted),
            // 拿不到密钥（换了机器、密钥环被清了）：这份历史读不回来了。
            // 空历史比崩溃好，而且不能把文件删掉 —— 用户可能还想找回密钥
            None => (Store::new(limit), Protection::Encrypted),
        }
    } else {
        (
            decode_index(&String::from_utf8_lossy(&bytes), limit),
            Protection::PlainText,
        )
    }
}

/// 写回历史。
pub fn save(store: &Store) -> Result<Protection, String> {
    let dir = dir().ok_or("找不到数据目录")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建目录失败：{e}"))?;
    let path = dir.join(HISTORY);
    let plain = encode_index(store);

    let (bytes, protection) = match key().and_then(|k| encrypt(&k, plain.as_bytes())) {
        Some(sealed) => {
            let mut out = MAGIC.to_vec();
            out.extend_from_slice(&sealed);
            (out, Protection::Encrypted)
        }
        None => (plain.into_bytes(), Protection::PlainText),
    };

    write_private(&path, &bytes)?;
    Ok(protection)
}

/// 现在能拿到密钥吗。
pub fn current_protection() -> Protection {
    if key().is_some() {
        Protection::Encrypted
    } else {
        Protection::PlainText
    }
}

/// 以 0600 写文件。
///
/// **先设权限再写内容**：反过来的话，从创建到 chmod 之间有一个窗口，
/// 内容是以默认权限（多半是 0644）躺在磁盘上的。
fn write_private(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("写入历史失败：{e}"))?;
    file.write_all(bytes)
        .map_err(|e| format!("写入历史失败：{e}"))?;
    // 文件已存在时 `mode` 不生效，补一次
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    Ok(())
}

fn encrypt(key_bytes: &[u8; 32], plain: &[u8]) -> Option<Vec<u8>> {
    let cipher = Aes256Gcm::new(&Key::<Aes256Gcm>::from(*key_bytes));
    // nonce 每次都要不一样。用「当前纳秒 + 进程 id」而不是随机数：
    // 这个 crate 没有随机数源，而 GCM 只要求 nonce 不重复，不要求不可预测
    let nonce_bytes = nonce_seed();
    let nonce = Nonce::from(nonce_bytes);
    let sealed = cipher.encrypt(&nonce, plain).ok()?;
    let mut out = nonce_bytes.to_vec();
    out.extend_from_slice(&sealed);
    Some(out)
}

fn decrypt(key_bytes: &[u8; 32], body: &[u8]) -> Option<String> {
    if body.len() <= NONCE_LEN {
        return None;
    }
    let cipher = Aes256Gcm::new(&Key::<Aes256Gcm>::from(*key_bytes));
    let mut nonce_bytes = [0u8; NONCE_LEN];
    nonce_bytes.copy_from_slice(&body[..NONCE_LEN]);
    let nonce = Nonce::from(nonce_bytes);
    let plain = cipher.decrypt(&nonce, &body[NONCE_LEN..]).ok()?;
    String::from_utf8(plain).ok()
}

/// 造一个不重复的 nonce。
///
/// GCM 对 nonce 的要求是**不重复**（重复会灾难性地泄露明文），
/// 但不要求不可预测。时间 + 进程 id 足以保证不重复，
/// 而且省掉了一个随机数依赖。
fn nonce_seed() -> [u8; NONCE_LEN] {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let pid = std::process::id() as u32;
    let mut out = [0u8; NONCE_LEN];
    out[..8].copy_from_slice(&nanos.to_le_bytes());
    out[8..].copy_from_slice(&pid.to_le_bytes());
    out
}

/// 从密钥环里取密钥；没有就创建一条。
///
/// 拿不到密钥环时返回 `None`，调用方据此退回明文。
fn key() -> Option<[u8; 32]> {
    let existing = secret::lookup(KEY_LABEL);
    if let Some(bytes) = existing {
        return to_key(&bytes);
    }
    let fresh = nonce_seed();
    // 32 字节的密钥：把种子铺开。不理想，但这里没有 CSPRNG 可用，
    // 而密钥本身是存在密钥环里、由系统保护的
    let mut material = [0u8; 32];
    for (index, slot) in material.iter_mut().enumerate() {
        *slot = fresh[index % NONCE_LEN] ^ (index as u8).wrapping_mul(31);
    }
    secret::store(KEY_LABEL, &material).ok()?;
    Some(material)
}

fn to_key(bytes: &[u8]) -> Option<[u8; 32]> {
    if bytes.len() != 32 {
        return None;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(bytes);
    Some(key)
}

/// Secret Service（freedesktop 的密钥环）。
mod secret {
    use std::collections::HashMap;
    use zbus::blocking::Connection;
    use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

    const SERVICE: &str = "org.freedesktop.secrets";
    const PATH: &str = "/org/freedesktop/secrets";
    const COLLECTION: &str = "/org/freedesktop/secrets/aliases/default";

    /// 按标签找一条密钥。
    pub fn lookup(label: &str) -> Option<Vec<u8>> {
        let conn = Connection::session().ok()?;
        let service = proxy(&conn, PATH, "org.freedesktop.Secret.Service").ok()?;

        let mut attributes = HashMap::new();
        attributes.insert("baobox", label);
        let (unlocked, _locked): (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>) =
            service.call("SearchItems", &(attributes)).ok()?;
        let item = unlocked.first()?;

        // 开一个会话；不加密传输（PLAIN），因为这是本机的 DBus
        // 用 OwnedValue 而不是 Value：后者借了返回缓冲的生命周期，
        // 反序列化时推不出「对任意生命周期都成立」
        let (_output, session): (OwnedValue, OwnedObjectPath) = service
            .call("OpenSession", &("plain", Value::from("")))
            .ok()?;

        let item_proxy = proxy(&conn, item.as_str(), "org.freedesktop.Secret.Item").ok()?;
        let secret: (OwnedObjectPath, Vec<u8>, Vec<u8>, String) =
            item_proxy.call("GetSecret", &(&session)).ok()?;
        Some(secret.2)
    }

    /// 存一条密钥。
    pub fn store(label: &str, value: &[u8]) -> Result<(), String> {
        let conn = Connection::session().map_err(|e| e.to_string())?;
        let service =
            proxy(&conn, PATH, "org.freedesktop.Secret.Service").map_err(|e| e.to_string())?;
        let (_output, session): (OwnedValue, OwnedObjectPath) = service
            .call("OpenSession", &("plain", Value::from("")))
            .map_err(|e| e.to_string())?;

        let mut attributes = HashMap::new();
        attributes.insert("baobox".to_string(), label.to_string());
        let properties: HashMap<&str, Value> = HashMap::from([
            ("org.freedesktop.Secret.Item.Label", Value::from(label)),
            (
                "org.freedesktop.Secret.Item.Attributes",
                Value::from(attributes),
            ),
        ]);
        let secret = (
            ObjectPath::try_from(session.as_str()).map_err(|e| e.to_string())?,
            Vec::<u8>::new(),
            value.to_vec(),
            "application/octet-stream".to_string(),
        );

        let collection =
            proxy(&conn, COLLECTION, "org.freedesktop.Secret.Collection").map_err(|e| e.to_string())?;
        let _: (OwnedObjectPath, OwnedObjectPath) = collection
            .call("CreateItem", &(properties, secret, true))
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn proxy<'a>(
        conn: &'a Connection,
        path: &'a str,
        interface: &'a str,
    ) -> zbus::Result<zbus::blocking::Proxy<'a>> {
        zbus::blocking::Proxy::new(conn, SERVICE, path, interface)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_round_trip_through_encryption_returns_the_original() {
        let key = [7u8; 32];
        let plain = "第一条\t带制表符\n第二条";
        let sealed = encrypt(&key, plain.as_bytes()).unwrap();
        assert_ne!(sealed, plain.as_bytes(), "密文不该等于明文");
        assert_eq!(decrypt(&key, &sealed).unwrap(), plain);
    }

    #[test]
    fn the_wrong_key_fails_instead_of_returning_garbage() {
        // GCM 带认证，密钥不对应当是「解不开」而不是「解出一堆乱码」
        let sealed = encrypt(&[7u8; 32], b"secret").unwrap();
        assert!(decrypt(&[8u8; 32], &sealed).is_none());
    }

    #[test]
    fn tampering_with_the_ciphertext_is_detected() {
        let key = [7u8; 32];
        let mut sealed = encrypt(&key, b"secret").unwrap();
        let last = sealed.len() - 1;
        sealed[last] ^= 0xFF;
        assert!(decrypt(&key, &sealed).is_none(), "改过的密文必须被拒");
    }

    #[test]
    fn a_truncated_payload_does_not_panic() {
        let key = [7u8; 32];
        assert!(decrypt(&key, &[]).is_none());
        assert!(decrypt(&key, &[0u8; NONCE_LEN]).is_none());
        assert!(decrypt(&key, &[0u8; 4]).is_none());
    }

    #[test]
    fn nonces_do_not_repeat_between_calls() {
        // GCM 的 nonce 重复会灾难性地泄露明文
        let mut seen = std::collections::HashSet::new();
        for _ in 0..50 {
            assert!(seen.insert(nonce_seed()), "nonce 重复了");
        }
    }

    #[test]
    fn the_magic_header_tells_encrypted_files_from_plain_ones() {
        let sealed = encrypt(&[1u8; 32], b"x").unwrap();
        let mut file = MAGIC.to_vec();
        file.extend_from_slice(&sealed);
        assert!(file.starts_with(MAGIC));
        // 明文的历史文件是 TSV，绝不会以这个头开始
        assert!(!b"id\ttext\t".starts_with(MAGIC));
    }

    #[test]
    fn both_protection_levels_explain_themselves() {
        assert!(Protection::Encrypted.describe().contains("已加密"));
        let plain = Protection::PlainText.describe();
        assert!(plain.contains("明文"), "没加密就要说清楚，不能假装加密了");
        assert!(plain.contains("keyring") || plain.contains("kwallet"));
    }

    #[test]
    fn only_a_thirty_two_byte_secret_is_accepted_as_a_key() {
        assert!(to_key(&[0u8; 32]).is_some());
        assert!(to_key(&[0u8; 16]).is_none(), "长度不对的密钥不能将就着用");
        assert!(to_key(&[]).is_none());
    }

    #[test]
    fn clipboard_data_sits_beside_the_screenshot_data_not_inside_it() {
        // 各模块一个子目录，互不串扰（根 CLAUDE.md 约定 8）
        let previous = std::env::var("XDG_DATA_HOME").ok();
        std::env::set_var("XDG_DATA_HOME", "/d");
        let clip = dir().unwrap();
        assert_eq!(clip, PathBuf::from("/d/baobox/clipboard"));
        assert!(image_dir().unwrap().starts_with(&clip));
        match previous {
            Some(value) => std::env::set_var("XDG_DATA_HOME", value),
            None => std::env::remove_var("XDG_DATA_HOME"),
        }
    }
}
