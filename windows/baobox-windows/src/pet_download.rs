#![cfg(windows)]

use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

const REVISION: &str = "1c39c54a57497f487e296d33de96927db9f734be";
const MARKER: &str = ".baobox-download";

#[derive(Deserialize)]
pub struct CatalogEntry {
    pub id: String,
    pub name: String,
    pub credit: String,
    files: Vec<File>,
}

#[derive(Deserialize)]
struct File {
    name: String,
    size: u64,
    sha256: String,
}

pub fn catalog() -> &'static [CatalogEntry] {
    static CATALOG: OnceLock<Vec<CatalogEntry>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("pet_catalog.json")).expect("bundled catalog")
    })
}

fn destination(id: &str) -> Option<PathBuf> {
    super::pet_pack::directory().map(|root| root.join(id))
}

pub fn installed(id: &str) -> bool {
    destination(id).is_some_and(|path| path.is_dir())
}

pub fn managed(id: &str) -> bool {
    destination(id).is_some_and(|path| path.join(MARKER).is_file())
}

pub fn download(entry: &CatalogEntry) -> Result<(), String> {
    let dest = destination(&entry.id).ok_or("找不到宠物素材目录")?;
    if dest.exists() {
        return Err("同名素材目录已存在".into());
    }
    let root = dest.parent().ok_or("找不到宠物素材目录")?;
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let stage = root.join(format!(".download-{}-{}", entry.id, std::process::id()));
    fs::create_dir(&stage).map_err(|e| e.to_string())?;
    let result = (|| {
        for file in &entry.files {
            fetch(entry, file, &stage.join(&file.name))?;
        }
        fs::write(stage.join(MARKER), REVISION).map_err(|e| e.to_string())?;
        fs::rename(&stage, &dest).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(stage);
    }
    result
}

pub fn remove(entry: &CatalogEntry) -> Result<(), String> {
    if !managed(&entry.id) {
        return Err("只能移除由 BaoBox 下载的素材".into());
    }
    let path = destination(&entry.id).ok_or("找不到宠物素材目录")?;
    fs::remove_dir_all(path).map_err(|e| e.to_string())
}

fn fetch(entry: &CatalogEntry, file: &File, destination: &Path) -> Result<(), String> {
    let system = std::env::var_os("SystemRoot").ok_or("找不到 Windows 系统目录")?;
    let curl = PathBuf::from(system).join("System32").join("curl.exe");
    for base in [
        format!("https://raw.githubusercontent.com/qiaob/baobox_mac/{REVISION}/assets/pets"),
        format!("https://cdn.jsdelivr.net/gh/qiaob/baobox_mac@{REVISION}/assets/pets"),
    ] {
        let url = format!("{}/{}/{}", base, entry.id, file.name);
        let status = Command::new(&curl)
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .args([
                "--disable",
                "--fail",
                "--silent",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--max-time",
                "45",
                "--max-filesize",
            ])
            .arg(file.size.to_string())
            .arg("--output")
            .arg(destination)
            .arg(url)
            .status();
        if status.is_ok_and(|status| status.success()) && verify(file, destination) {
            return Ok(());
        }
    }
    Err(format!("下载失败或校验不匹配：{}", file.name))
}

fn verify(file: &File, path: &Path) -> bool {
    if !fs::metadata(path).is_ok_and(|metadata| metadata.len() == file.size) {
        return false;
    }
    fs::read(path).is_ok_and(|bytes| format!("{:x}", Sha256::digest(&bytes)) == file.sha256)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_checksums_match_the_repository_assets() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/pets");
        assert_eq!(catalog().len(), 18);
        for entry in catalog() {
            for file in &entry.files {
                assert!(
                    verify(file, &root.join(&entry.id).join(&file.name)),
                    "{} / {}",
                    entry.id,
                    file.name
                );
            }
        }
    }

    #[test]
    fn catalog_models_decode_and_render() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/pets");
        for entry in catalog() {
            let folder = root.join(&entry.id);
            let model = entry
                .files
                .iter()
                .find(|file| file.name != "pet.json")
                .unwrap();
            let spec = serde_json::from_slice(&fs::read(folder.join("pet.json")).unwrap()).unwrap();
            let bytes = fs::read(folder.join(&model.name)).unwrap();
            let model = crate::pet_model::Model::from_bytes(&bytes, spec)
                .unwrap_or_else(|error| panic!("{}: {error}", entry.id));
            let rendered = model.render(64, "idle", 0.0, true);
            assert!(
                rendered.iter().filter(|&&pixel| pixel != 0xff00ff).count() > 40,
                "{}",
                entry.id
            );
            if entry.id.starts_with("vroid-") {
                let calm = model.render(96, "walk", 0.32, false);
                for gait in [1, 2] {
                    model.set_gait(gait);
                    assert_ne!(
                        calm,
                        model.render(96, "walk", 0.32, false),
                        "{} gait {gait}",
                        entry.id
                    );
                }
                model.set_gait(0);
                assert_eq!(
                    rendered,
                    model.render(64, "idle", 0.0, false),
                    "{} idle view should face forward",
                    entry.id
                );
                assert!(
                    model.has_face_expressions(),
                    "{} face expressions missing",
                    entry.id
                );
                let rest = model.render(96, "idle", 0.625, false);
                for action in [
                    "poke", "pet", "feed", "play", "wake", "drag", "sit", "peek", "nod", "shake",
                    "laugh", "cry",
                ] {
                    let frame = model.render(96, action, 0.625, false);
                    let changed = rest.iter().zip(&frame).filter(|(a, b)| a != b).count();
                    assert!(
                        changed > 45,
                        "{} {action} barely changes the pose",
                        entry.id
                    );
                }
                for frame in 0..12 {
                    let pixels = model.render(192, "walk", frame as f32 * 0.095, false);
                    assert!(
                        pixels[pixels.len() - 192..]
                            .iter()
                            .all(|&pixel| pixel == 0xff00ff),
                        "{} shoe clipped at frame {frame}",
                        entry.id
                    );
                }
                assert!(
                    model.walk_uses_opposite_limbs(),
                    "{} walk coordination",
                    entry.id
                );
                assert!(model.arms_lowered_at_rest(), "{} arms are raised", entry.id);
                assert_ne!(
                    rendered,
                    model.render(64, "walk", 0.3, true),
                    "{}",
                    entry.id
                );
            }
        }
    }
}
