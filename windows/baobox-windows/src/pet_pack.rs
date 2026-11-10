#![cfg(windows)]

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use windows::Win32::Graphics::Gdi::{
    SetStretchBltMode, StretchDIBits, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, COLORONCOLOR,
    DIB_RGB_COLORS, HDC, SRCCOPY,
};

const STATES: [&str; 5] = ["idle", "walk", "sleep", "happy", "drag"];
const MAX_FRAMES: usize = 180;
const MAX_PIXELS: usize = 8_000_000;
const KEY: u32 = 0xff00ff;

#[derive(Default, Deserialize)]
struct Manifest {
    name: Option<String>,
    facing: Option<String>,
    model: Option<String>,
    #[serde(flatten)]
    model_spec: super::pet_model::ModelSpec,
    #[serde(default)]
    states: HashMap<String, Spec>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Spec {
    sheet: Option<String>,
    frames: Option<Vec<String>>,
    frame_width: Option<usize>,
    frame_height: Option<usize>,
    row: Option<usize>,
    column: Option<usize>,
    count: Option<usize>,
    fps: Option<f64>,
}

pub struct Entry {
    pub id: String,
    pub name: String,
    path: PathBuf,
    manifest: Manifest,
    bundled: Option<&'static [u8]>,
}

pub fn directory() -> Option<PathBuf> {
    Some(crate::store::config_path()?.parent()?.join("Pets"))
}

pub fn list() -> Vec<Entry> {
    let mut builtins = vec![
        bundled(
            "plush-cat",
            "毛绒猫",
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-cat/pet.json"),
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-cat/model.glb"),
        ),
        bundled(
            "plush-dog",
            "毛绒狗",
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-dog/pet.json"),
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-dog/model.glb"),
        ),
        bundled(
            "plush-bunny",
            "毛绒兔",
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-bunny/pet.json"),
            include_bytes!("../../../mac/Sources/Resources/Pets/plush-bunny/model.glb"),
        ),
    ];
    let Some(entries) = directory().and_then(|dir| fs::read_dir(dir).ok()) else {
        return builtins;
    };
    let mut entries: Vec<_> = entries
        .flatten()
        .filter_map(|entry| {
            let id = entry.file_name().into_string().ok()?;
            if id.starts_with('.')
                || !entry.file_type().ok()?.is_dir()
                || builtins.iter().any(|entry| entry.id == id)
            {
                return None;
            }
            let path = entry.path();
            let manifest_path = path.join("pet.json");
            let manifest: Manifest = fs::metadata(&manifest_path)
                .ok()
                .filter(|info| info.len() <= 64 * 1024)
                .and_then(|_| fs::read(&manifest_path).ok())
                .and_then(|data| serde_json::from_slice(&data).ok())
                .or_else(|| {
                    Some(Manifest {
                        model: Some(first_model(&path)?),
                        ..Default::default()
                    })
                })?;
            if !manifest.states.contains_key("idle") && manifest.model.is_none() {
                return None;
            }
            Some(Entry {
                name: crate::pet_download::catalog()
                    .iter()
                    .find(|entry| entry.id == id)
                    .map(|entry| entry.name.clone())
                    .or_else(|| manifest.name.clone())
                    .unwrap_or_else(|| id.clone()),
                id,
                path,
                manifest,
                bundled: None,
            })
        })
        .collect();
    entries.sort_by(|a, b| a.id.cmp(&b.id));
    builtins.extend(entries);
    builtins
}

fn first_model(dir: &Path) -> Option<String> {
    fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| {
            [".glb", ".gltf", ".vrm"]
                .iter()
                .any(|ext| name.to_ascii_lowercase().ends_with(ext))
        })
        .min()
}

fn bundled(id: &str, name: &str, manifest: &[u8], model: &'static [u8]) -> Entry {
    Entry {
        id: id.into(),
        name: name.into(),
        path: PathBuf::new(),
        manifest: serde_json::from_slice(manifest).expect("bundled pet manifest"),
        bundled: Some(model),
    }
}
struct Frame {
    width: usize,
    height: usize,
    bgra: Vec<u32>,
}

struct Animation {
    frames: Vec<Frame>,
    fps: f64,
}

// 一只宠物只有一个 Pack，两种变体大小不同也没关系，装箱换不来什么。
#[allow(clippy::large_enum_variant)]
pub enum Pack {
    Sprites(Sprites),
    Model(super::pet_model::Model),
}

pub struct Sprites {
    faces_left: bool,
    animations: HashMap<&'static str, Animation>,
    width: usize,
    height: usize,
}

fn read_png(dir: &Path, name: &str) -> Result<(usize, usize, Vec<u8>), String> {
    let path = dir.join(name);
    if name.contains(['/', '\\', ':']) || !name.to_ascii_lowercase().ends_with(".png") {
        return Err("帧图文件必须是素材目录里的 PNG".into());
    }
    let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if !metadata.file_type().is_file() || metadata.len() > 16 * 1024 * 1024 {
        return Err("帧图文件无效或太大".into());
    }
    let (width, height, data) =
        baobox_image::decode_rgba(&fs::read(path).map_err(|e| e.to_string())?)?;
    if u64::from(width) * u64::from(height) > MAX_PIXELS as u64 {
        return Err("帧图尺寸太大".into());
    }
    Ok((width as usize, height as usize, data))
}

impl Entry {
    pub fn load(self) -> Result<Pack, String> {
        if let Some(model) = &self.manifest.model {
            let spec = self.manifest.model_spec;
            if let Some(bytes) = self.bundled {
                return super::pet_model::Model::from_bytes(bytes, spec).map(Pack::Model);
            }
            if model.contains(['/', '\\', ':']) {
                return Err("模型必须在素材目录里".into());
            }
            let path = self.path.join(model);
            let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
            if !metadata.file_type().is_file() || metadata.len() > 32 * 1024 * 1024 {
                return Err("模型无效或太大".into());
            }
            let bytes = fs::read(&path).map_err(|e| e.to_string())?;
            return if model.to_ascii_lowercase().ends_with(".gltf") {
                super::pet_model::Model::from_gltf(&path, &bytes, spec)
            } else {
                super::pet_model::Model::from_bytes(&bytes, spec)
            }
            .map(Pack::Model);
        }
        let mut budget = MAX_PIXELS;
        let mut pack = Sprites {
            faces_left: self.manifest.facing.as_deref() == Some("left"),
            animations: HashMap::new(),
            width: 1,
            height: 1,
        };
        for state in STATES {
            let Some(spec) = self.manifest.states.get(state) else {
                continue;
            };
            let frames = spec.load(&self.path, &mut budget)?;
            for frame in &frames {
                pack.width = pack.width.max(frame.width);
                pack.height = pack.height.max(frame.height);
            }
            pack.animations.insert(
                state,
                Animation {
                    frames,
                    fps: spec
                        .fps
                        .filter(|fps| fps.is_finite())
                        .unwrap_or(6.0)
                        .clamp(1.0, 30.0),
                },
            );
        }
        Ok(Pack::Sprites(pack))
    }
}

impl Spec {
    fn load(&self, dir: &Path, budget: &mut usize) -> Result<Vec<Frame>, String> {
        let mut frames = Vec::new();
        if let Some(names) = &self.frames {
            for name in names.iter().take(MAX_FRAMES) {
                let (w, h, rgba) = read_png(dir, name)?;
                frames.push(Frame::crop(&rgba, w, (0, 0, w, h), budget)?);
            }
        } else if let Some(sheet) = &self.sheet {
            let name = if sheet == "*" {
                fs::read_dir(dir)
                    .map_err(|e| e.to_string())?
                    .flatten()
                    .filter_map(|entry| entry.file_name().into_string().ok())
                    .filter(|name| name.to_ascii_lowercase().ends_with(".png"))
                    .min()
                    .ok_or("素材目录没有 PNG")?
            } else {
                sheet.clone()
            };
            let (w, h, rgba) = read_png(dir, &name)?;
            let fw = self
                .frame_width
                .filter(|&v| v > 0 && v <= w)
                .ok_or("frameWidth 无效")?;
            let fh = self
                .frame_height
                .filter(|&v| v > 0 && v <= h)
                .ok_or("frameHeight 无效")?;
            let row = self.row.unwrap_or(0);
            let col = self.column.unwrap_or(0);
            let columns = w / fw;
            if row >= h / fh || col >= columns {
                return Err("帧图行列超出边界".into());
            }
            let count = self
                .count
                .unwrap_or(columns - col)
                .min(columns - col)
                .min(MAX_FRAMES);
            for x in col..col + count {
                frames.push(Frame::crop(&rgba, w, (x * fw, row * fh, fw, fh), budget)?);
            }
        }
        if frames.is_empty() {
            return Err("动画没有帧".into());
        }
        Ok(frames)
    }
}

impl Frame {
    fn crop(
        rgba: &[u8],
        stride: usize,
        region: (usize, usize, usize, usize),
        budget: &mut usize,
    ) -> Result<Self, String> {
        let (x, y, width, height) = region;
        *budget = budget
            .checked_sub(width * height)
            .ok_or("素材包帧图超过解码上限")?;
        let mut bgra = Vec::with_capacity(width * height);
        for row in y..y + height {
            let start = (row * stride + x) * 4;
            for p in rgba[start..start + width * 4].chunks_exact(4) {
                let rgb = u32::from_be_bytes([0, p[0], p[1], p[2]]);
                bgra.push(if p[3] < 128 {
                    KEY
                } else if rgb == KEY {
                    KEY - 1
                } else {
                    rgb
                });
            }
        }
        Ok(Self {
            width,
            height,
            bgra,
        })
    }
}

impl Pack {
    pub fn body_bounds(&self) -> Option<(i32, i32, i32, i32)> {
        match self {
            Self::Model(model) => model.body_bounds(),
            Self::Sprites(_) => None,
        }
    }
    pub fn set_gait(&self, gait: usize) {
        if let Self::Model(model) = self {
            model.set_gait(gait);
        }
    }
    pub fn walk_rate(&self) -> Option<f32> {
        match self {
            Self::Model(model) => model.walk_rate(),
            Self::Sprites(_) => None,
        }
    }

    pub fn is_humanoid(&self) -> bool {
        matches!(self, Self::Model(model) if model.is_humanoid())
    }

    pub fn interaction_seconds(&self, state: &str) -> Option<f32> {
        match self {
            Self::Model(model) => model.interaction_seconds(state),
            Self::Sprites(_) => None,
        }
    }

    pub unsafe fn draw(&self, dc: HDC, size: i32, state: &str, seconds: f64, left: bool) {
        match self {
            Self::Sprites(pack) => pack.draw(dc, size, state, seconds, left),
            Self::Model(model) => model.draw(dc, size, state, seconds, left),
        }
    }
}

impl Sprites {
    unsafe fn draw(&self, dc: HDC, size: i32, state: &str, seconds: f64, left: bool) {
        let animation = self
            .animations
            .get(state)
            .unwrap_or(&self.animations["idle"]);
        let index = (seconds * animation.fps) as usize % animation.frames.len();
        let frame = &animation.frames[index];
        let scale = f64::from(size) / self.width.max(self.height) as f64;
        let width = (frame.width as f64 * scale).round() as i32;
        let height = (frame.height as f64 * scale).round() as i32;
        let left_edge = (size - width) / 2;
        let mirror = self.faces_left != left;
        draw_bitmap(
            dc,
            (
                if mirror { left_edge + width } else { left_edge },
                size - height,
                if mirror { -width } else { width },
                height,
            ),
            (frame.width, frame.height),
            &frame.bgra,
        );
    }
}

pub unsafe fn draw_bitmap(
    dc: HDC,
    dest: (i32, i32, i32, i32),
    dimensions: (usize, usize),
    pixels: &[u32],
) {
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: dimensions.0 as i32,
            biHeight: -(dimensions.1 as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let _ = SetStretchBltMode(dc, COLORONCOLOR);
    StretchDIBits(
        dc,
        dest.0,
        dest.1,
        dest.2,
        dest.3,
        0,
        0,
        dimensions.0 as i32,
        dimensions.1 as i32,
        Some(pixels.as_ptr().cast()),
        &info,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_pets_render_and_animate() {
        for entry in list().into_iter().take(3) {
            let id = entry.id.clone();
            let Pack::Model(model) = entry.load().unwrap_or_else(|error| panic!("{id}: {error}"))
            else {
                panic!("{id} must be a model");
            };
            let initial = model.render(80, "walk", 0.0, false);
            let moved = model.render(80, "walk", 0.22, false);
            assert!(
                initial.iter().filter(|&&pixel| pixel != KEY).count() > 200,
                "{id}"
            );
            assert_ne!(initial, moved, "{id} animation did not advance");
            assert!(
                model.interaction_seconds("feed").is_some(),
                "{id} has no feed animation"
            );
        }
    }
}
