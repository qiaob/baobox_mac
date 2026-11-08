#![cfg(windows)]

use std::path::{Component, Path};
use std::rc::Rc;
use std::sync::OnceLock;
use std::{cell::Cell, collections::HashMap};

use glam::{Mat4, Quat, Vec2, Vec3, Vec4};
use gltf::animation::util::ReadOutputs;
use gltf::animation::{Interpolation, Property};
use serde::Deserialize;
use windows::Win32::Graphics::Gdi::HDC;

const MAX_VERTICES: usize = 200_000;
const MAX_TRIANGLES: usize = 200_000;
const KEY: u32 = 0xff00ff;
const HALF_STEP_SECONDS: f32 = std::f32::consts::PI / 5.5;
const WALK_YAW: f32 = 1.25;

#[derive(Deserialize)]
struct MocapWalk {
    frames: usize,
    fps: f32,
    speed: f32,
    hips: Vec<[f32; 3]>,
    rot: HashMap<String, Vec<[f32; 4]>>,
    ankle: HashMap<String, Vec<[f32; 3]>>,
    toe: HashMap<String, Vec<f32>>,
}

fn mocap_walk(style: usize) -> Option<&'static MocapWalk> {
    static TRACKS: OnceLock<[Option<MocapWalk>; 3]> = OnceLock::new();
    TRACKS
        .get_or_init(|| {
            [
                include_str!("../../../mac/Sources/Resources/Motions/mocap-walk-feminine.json"),
                include_str!("../../../mac/Sources/Resources/Motions/mocap-walk-happy.json"),
                include_str!("../../../mac/Sources/Resources/Motions/mocap-walk-childish.json"),
            ]
            .map(|data| {
                let track: MocapWalk = serde_json::from_str(data).ok()?;
                (track.frames > 1
                    && track.fps > 0.0
                    && track.hips.len() == track.frames
                    && track
                        .rot
                        .values()
                        .all(|frames| frames.len() == track.frames)
                    && ["left", "right"].into_iter().all(|side| {
                        track
                            .ankle
                            .get(side)
                            .is_some_and(|frames| frames.len() == track.frames)
                            && track
                                .toe
                                .get(side)
                                .is_some_and(|frames| frames.len() == track.frames)
                    }))
                .then_some(track)
            })
        })
        .get(style)
        .and_then(Option::as_ref)
}

const MOCAP_CHAIN: [&str; 13] = [
    "hips",
    "spine",
    "chest",
    "neck",
    "head",
    "leftShoulder",
    "leftUpperArm",
    "leftLowerArm",
    "leftHand",
    "rightShoulder",
    "rightUpperArm",
    "rightLowerArm",
    "rightHand",
];

struct MocapRig {
    hips: usize,
    legs: [[usize; 3]; 2],
    rest: Vec<Mat4>,
    leg_length: f32,
}

impl MocapRig {
    fn new(human: &Humanoid, rest: &[Mat4]) -> Option<Self> {
        mocap_walk(0)?;
        let leg = |side: &str| {
            Some([
                *human.bones.get(&format!("{side}UpperLeg"))?,
                *human.bones.get(&format!("{side}LowerLeg"))?,
                *human.bones.get(&format!("{side}Foot"))?,
            ])
        };
        let legs = [leg("left")?, leg("right")?];
        let point = |joint: usize| rest[joint].w_axis.truncate();
        let leg_length = legs
            .iter()
            .map(|&[hip, knee, ankle]| {
                point(hip).distance(point(knee)) + point(knee).distance(point(ankle))
            })
            .sum::<f32>()
            * 0.5;
        (leg_length > 0.001 && leg_length.is_finite()).then_some(Self {
            hips: *human.bones.get("hips")?,
            legs,
            rest: rest.to_vec(),
            leg_length,
        })
    }
}
pub const PEEK_LINE: f32 = 0.44;
pub const SEAT_LINE: f32 = 0.64;

#[derive(Deserialize)]
#[serde(untagged)]
enum ClipSpec {
    Name(String),
    Details {
        clip: String,
        #[serde(default)]
        hold: bool,
        #[serde(rename = "loop")]
        looping: Option<bool>,
    },
}

#[derive(Default, Deserialize)]
pub struct ModelSpec {
    #[serde(default)]
    clips: HashMap<String, ClipSpec>,
    yaw: Option<f32>,
    scale: Option<f32>,
    #[serde(default)]
    interactions: HashMap<String, Vec<ClipSequence>>,
    #[serde(default)]
    fidgets: Vec<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ClipSequence {
    Single(String),
    Many(Vec<String>),
}

impl ClipSequence {
    fn names(&self) -> &[String] {
        match self {
            Self::Single(name) => std::slice::from_ref(name),
            Self::Many(names) => names,
        }
    }
}

#[derive(Clone, Copy)]
struct Pose {
    translation: Vec3,
    rotation: Quat,
    scale: Vec3,
}

impl Pose {
    fn matrix(self) -> Mat4 {
        Mat4::from_scale_rotation_translation(self.scale, self.rotation, self.translation)
    }
}

struct Node {
    pose: Pose,
    parent: Option<usize>,
}

struct Skin {
    joints: Vec<(usize, Mat4)>,
}

struct Vertex {
    position: Vec3,
    uv: Vec2,
    joints: [u16; 4],
    weights: [f32; 4],
}

struct Mesh {
    vertices: Rc<Vec<Vertex>>,
    indices: Vec<u32>,
    node: usize,
    skin: Option<usize>,
    texture: Option<usize>,
    color: Vec4,
    unlit: bool,
    expressions: [Vec<Vec3>; 2],
}

enum Values {
    Vector(Vec<Vec3>),
    Rotation(Vec<Quat>),
}

struct Channel {
    node: usize,
    property: Property,
    times: Vec<f32>,
    values: Values,
    interpolation: Interpolation,
}

impl Channel {
    fn sample(&self, time: f32, pose: &mut Pose) {
        let next = self.times.partition_point(|&key| key <= time);
        let start = next.saturating_sub(1);
        let end = next.min(self.times.len() - 1);
        let ratio = if start == end || self.interpolation == Interpolation::Step {
            0.0
        } else {
            ((time - self.times[start]) / (self.times[end] - self.times[start])).clamp(0.0, 1.0)
        };
        match (&self.values, self.property) {
            (Values::Rotation(values), Property::Rotation) => {
                pose.rotation = values[start].slerp(values[end], ratio)
            }
            (Values::Vector(values), Property::Translation) => {
                pose.translation = values[start].lerp(values[end], ratio)
            }
            (Values::Vector(values), Property::Scale) => {
                pose.scale = values[start].lerp(values[end], ratio)
            }
            _ => {}
        }
    }
}

struct Clip {
    name: String,
    duration: f32,
    channels: Vec<Channel>,
}

struct Humanoid {
    bones: HashMap<String, usize>,
    axes: Vec<Quat>,
    arms: [Option<Arm>; 2],
    faces_back: bool,
    expressions: [Vec<(usize, usize, f32)>; 2],
}

#[derive(Clone, Copy)]
struct Arm {
    upper: usize,
    lower: usize,
    rest_direction: Vec3,
    side: f32,
}

impl Humanoid {
    fn read(bytes: &[u8]) -> Option<Self> {
        let length = u32::from_le_bytes(bytes.get(12..16)?.try_into().ok()?) as usize;
        let json: serde_json::Value = serde_json::from_slice(bytes.get(20..20 + length)?).ok()?;
        let extensions = json.get("extensions")?;
        let mut bones = HashMap::new();
        let faces_back = if let Some(entries) = extensions
            .pointer("/VRM/humanoid/humanBones")
            .and_then(|v| v.as_array())
        {
            for entry in entries {
                bones.insert(
                    entry.get("bone")?.as_str()?.to_owned(),
                    entry.get("node")?.as_u64()? as usize,
                );
            }
            true
        } else {
            for (name, entry) in extensions
                .pointer("/VRMC_vrm/humanoid/humanBones")?
                .as_object()?
            {
                bones.insert(name.clone(), entry.get("node")?.as_u64()? as usize);
            }
            false
        };
        let expressions = [("joy", "happy"), ("sorrow", "sad")].map(|(legacy, modern)| {
            let mut binds = Vec::new();
            if let Some(groups) = extensions
                .pointer("/VRM/blendShapeMaster/blendShapeGroups")
                .and_then(|v| v.as_array())
            {
                for group in groups
                    .iter()
                    .filter(|group| group["presetName"].as_str() == Some(legacy))
                {
                    if let Some(items) = group["binds"].as_array() {
                        binds.extend(items.iter().filter_map(|item| {
                            Some((
                                item["mesh"].as_u64()? as usize,
                                item["index"].as_u64()? as usize,
                                (item["weight"].as_f64()? as f32 / 100.0).clamp(0.0, 1.0),
                            ))
                        }));
                    }
                }
            }
            if let Some(items) = extensions["VRMC_vrm"]["expressions"]["preset"][modern]
                ["morphTargetBinds"]
                .as_array()
            {
                binds.extend(items.iter().filter_map(|item| {
                    let node = item["node"].as_u64()? as usize;
                    Some((
                        json["nodes"][node]["mesh"].as_u64()? as usize,
                        item["index"].as_u64()? as usize,
                        (item["weight"].as_f64()? as f32).clamp(0.0, 1.0),
                    ))
                }));
            }
            binds
        });
        Some(Self {
            bones,
            axes: Vec::new(),
            arms: [None; 2],
            faces_back,
            expressions,
        })
    }

    fn bind_arms(&mut self, rest: &[Mat4]) {
        self.arms = [
            ("leftUpperArm", "leftLowerArm"),
            ("rightUpperArm", "rightLowerArm"),
        ]
        .map(|(upper, lower)| {
            let upper = *self.bones.get(upper)?;
            let lower = *self.bones.get(lower)?;
            let rest_direction = (rest[lower].w_axis - rest[upper].w_axis)
                .truncate()
                .try_normalize()?;
            Some(Arm {
                upper,
                lower,
                rest_direction,
                side: rest_direction.x.signum(),
            })
        });
    }

    fn pose(&self, poses: &mut [Pose], state: &str, time: f32) {
        if self.axes.is_empty() {
            return;
        }
        let phase = time * std::f32::consts::PI / HALF_STEP_SECONDS;
        let motion = phase.sin();
        let walking = state == "walk";
        let weight_shift = if walking { phase.sin() } else { 0.0 };
        let torso_twist = if walking { phase.cos() } else { 0.0 };
        let forward = if self.faces_back { -1.0 } else { 1.0 };
        let stride = [0.0, 1.0].map(|offset| {
            let step = (time / HALF_STEP_SECONDS + offset).rem_euclid(2.0);
            let (reach, lift) = if step < 1.0 {
                // 接地与离地时速度归零，中段保持匀速。
                let edge = 0.10;
                let progress = if step < edge {
                    step * step / (2.0 * edge)
                } else if step > 1.0 - edge {
                    let remaining = 1.0 - step;
                    1.0 - edge - remaining * remaining / (2.0 * edge)
                } else {
                    step - edge / 2.0
                } / (1.0 - edge);
                (1.0 - 2.0 * progress, 0.0)
            } else {
                let swing = (step - 1.0) * std::f32::consts::PI;
                (-swing.cos(), swing.sin().powi(2))
            };
            ((reach * 0.27).asin(), lift)
        });
        let sleeping = state == "sleep";
        let gesture = (std::f32::consts::PI * (time / 1.25).clamp(0.0, 1.0))
            .sin()
            .max(0.0);
        let wave = if matches!(state, "happy" | "highFive") {
            (std::f32::consts::PI * (time / 0.75).clamp(0.0, 1.0))
                .sin()
                .max(0.0)
        } else {
            0.0
        };
        for (index, arm) in self.arms.iter().enumerate() {
            let Some(arm) = arm else { continue };
            let wave = if index == 1 { wave } else { 0.0 };
            let swing = if walking {
                torso_twist * if index == 0 { -0.25 } else { 0.25 }
            } else {
                0.0
            };
            let (reach, lift, bend) = match (state, index) {
                ("poke", 1) => (0.32, 0.18, 0.50),
                ("pet", _) => (0.10, 0.06, 0.16),
                ("feed", 1) => (0.63, 0.42, 1.12),
                ("play", _) => (0.55, 0.65, 0.79),
                ("wake", _) => (0.22, 0.80, 0.33),
                ("drag", _) => (0.32, 0.26, 0.48),
                _ => (0.0, 0.0, 0.0),
            };
            let amount = if state == "drag" {
                0.85 + motion * 0.15
            } else {
                gesture
            };
            let target = Vec3::new(
                arm.side * (0.43 + 0.32 * wave),
                -1.0 + lift * amount,
                forward * (0.10 + swing + 0.24 * wave + reach * amount),
            )
            .normalize();
            let correction = Quat::from_rotation_arc(arm.rest_direction, target);
            let local = self.axes[arm.upper];
            poses[arm.upper].rotation *= local * correction * local.inverse();
            let follow = if index == 0 { -1.0 } else { 1.0 };
            let elbow = 0.16
                + bend * amount
                + if walking {
                    0.17 + (phase - 0.55).cos() * follow * 0.20
                } else {
                    0.0
                };
            poses[arm.lower].rotation *=
                Quat::from_axis_angle(self.axes[arm.lower] * Vec3::X, -forward * elbow);
            if wave > 0.0 {
                poses[arm.lower].rotation *= Quat::from_axis_angle(
                    self.axes[arm.lower] * Vec3::Z,
                    arm.side * wave * (1.03 + motion * 0.12),
                );
            }
        }
        let mut rotate = |name: &str, axis, angle| {
            if let Some(index) = self.bones.get(name).copied() {
                poses[index].rotation *= Quat::from_axis_angle(self.axes[index] * axis, angle);
            }
        };
        match state {
            "nod" => rotate(
                "head",
                Vec3::X,
                forward * 0.33 * gesture * (time * 10.0).sin(),
            ),
            "shake" => rotate("head", Vec3::Y, 0.48 * gesture * (time * 13.0).sin()),
            "laugh" | "cry" => {
                rotate(
                    "chest",
                    Vec3::X,
                    -forward * gesture * (0.07 + 0.07 * (time * 18.0).sin()),
                );
                rotate(
                    "head",
                    Vec3::X,
                    forward * gesture * if state == "cry" { 0.24 } else { -0.16 },
                );
            }
            "sit" => {
                for (upper, lower) in [
                    ("leftUpperLeg", "leftLowerLeg"),
                    ("rightUpperLeg", "rightLowerLeg"),
                ] {
                    rotate(upper, Vec3::X, -forward * 1.43);
                    rotate(lower, Vec3::X, forward * 1.43);
                }
            }
            "peek" => rotate("head", Vec3::Z, 0.13 * (time * 2.1).sin()),
            _ => {}
        }
        for (side, sign) in [("left", -1.0), ("right", 1.0)] {
            let wrist = if side == "left" {
                "leftHand"
            } else {
                "rightHand"
            };
            if walking {
                rotate(wrist, Vec3::X, forward * (phase - 0.9).cos() * sign * 0.10);
            }
            let curl = if state == "play" {
                0.12 + 0.76 * gesture
            } else if walking {
                0.16 + 0.09 * (phase - 1.1).cos() * sign
            } else {
                0.12
            };
            let side_index = usize::from(side == "right");
            if let Some(arm) = self.arms[side_index] {
                for finger in ["Index", "Middle", "Ring", "Little"] {
                    rotate(
                        &format!("{side}{finger}Proximal"),
                        Vec3::Z,
                        -arm.side * curl,
                    );
                    rotate(
                        &format!("{side}{finger}Intermediate"),
                        Vec3::Z,
                        -arm.side * curl * 0.65,
                    );
                    if state == "play" {
                        rotate(
                            &format!("{side}{finger}Distal"),
                            Vec3::Z,
                            -arm.side * curl * 0.55,
                        );
                    }
                }
            }
        }
        if state == "drag" {
            rotate("leftUpperLeg", Vec3::X, forward * (-0.18 + motion * 0.20));
            rotate("rightUpperLeg", Vec3::X, forward * (-0.18 - motion * 0.20));
            rotate("leftLowerLeg", Vec3::X, forward * (0.35 + motion * 0.16));
            rotate("rightLowerLeg", Vec3::X, forward * (0.35 - motion * 0.16));
        }
        if walking {
            // 骨盆带动重心，胸口反向转动，头部保持朝前。
            rotate("hips", Vec3::Y, -0.065 * torso_twist);
            rotate("hips", Vec3::Z, forward * 0.028 * weight_shift);
            rotate("spine", Vec3::Y, 0.045 * torso_twist);
            rotate("spine", Vec3::Z, -forward * 0.020 * weight_shift);
            rotate("spine", Vec3::X, -forward * 0.055);
            rotate("chest", Vec3::Y, 0.045 * torso_twist);
            rotate("head", Vec3::Y, -0.025 * torso_twist);
            for ((upper, lower, foot), (reach, lift)) in [
                ("leftUpperLeg", "leftLowerLeg", "leftFoot"),
                ("rightUpperLeg", "rightLowerLeg", "rightFoot"),
            ]
            .into_iter()
            .zip(stride)
            {
                let hip = -forward * (reach + 0.22 * lift);
                let knee = forward * 0.48 * lift;
                rotate(upper, Vec3::X, hip);
                rotate(lower, Vec3::X, knee);
                rotate(foot, Vec3::X, -hip - knee + forward * 0.13 * lift);
            }
        }
        rotate(
            "head",
            Vec3::X,
            if sleeping {
                0.32
            } else {
                let nod = match state {
                    "pet" => 0.28,
                    "feed" => 0.21,
                    "poke" => -0.19,
                    "wake" => -0.30,
                    _ => 0.0,
                };
                (time * 1.6).sin() * 0.055 + forward * nod * gesture
            },
        );
    }
}

pub struct Model {
    nodes: Vec<Node>,
    skins: Vec<Skin>,
    meshes: Vec<Mesh>,
    images: Vec<gltf::image::Data>,
    clips: Vec<Clip>,
    spec: ModelSpec,
    center: Vec3,
    extent: f32,
    half_height: f32,
    humanoid: Option<Humanoid>,
    walk_rate: Option<f32>,
    support_feet: Option<[(usize, f32); 2]>,
    mocap: Option<MocapRig>,
    gait: Cell<usize>,
}

impl Model {
    pub fn is_humanoid(&self) -> bool {
        self.humanoid.is_some()
    }

    #[cfg(test)]
    pub fn has_face_expressions(&self) -> bool {
        (0..2).all(|index| {
            self.meshes.iter().any(|mesh| {
                mesh.expressions[index]
                    .iter()
                    .any(|delta| delta.length_squared() > 0.0)
            })
        })
    }

    pub fn walk_rate(&self) -> Option<f32> {
        self.mocap
            .as_ref()
            .zip(mocap_walk(self.gait.get()))
            .map(|(rig, track)| track.speed * rig.leg_length * self.scale(1.0) * WALK_YAW.sin())
            .or(self.walk_rate)
    }

    pub fn set_gait(&self, gait: usize) {
        self.gait.set(gait);
    }

    #[cfg(test)]
    pub fn arms_lowered_at_rest(&self) -> bool {
        let Some(human) = &self.humanoid else {
            return false;
        };
        let world = self.world("idle", 0.0);
        human.arms.iter().all(|arm| {
            arm.is_some_and(|arm| {
                let upper = world[arm.upper].w_axis;
                let lower = world[arm.lower].w_axis;
                lower.y < upper.y && (lower.x - upper.x).abs() < upper.y - lower.y
            })
        })
    }

    #[cfg(test)]
    pub fn walk_uses_opposite_limbs(&self) -> bool {
        let Some(human) = &self.humanoid else {
            return false;
        };
        let first = self.world("walk-procedural", 0.0);
        let second = self.world("walk-procedural", HALF_STEP_SECONDS);
        let Some(feet) = self.support_feet else {
            return false;
        };
        let quarter = self.world("walk-procedural", HALF_STEP_SECONDS * 0.25);
        let support = feet[0].0;
        let travel = second[support].w_axis.z - first[support].w_axis.z;
        let quarter_travel = quarter[support].w_axis.z - first[support].w_axis.z;
        if self.walk_rate.is_none() || (quarter_travel / travel - 0.25).abs() > 0.08 {
            return false;
        }
        ["left", "right"].into_iter().all(|side| {
            let change = |part: &str| -> Option<f32> {
                let index = *human.bones.get(&format!("{side}{part}"))?;
                Some(first[index].w_axis.z - second[index].w_axis.z)
            };
            change("LowerArm")
                .zip(change("LowerLeg"))
                .is_some_and(|(arm, leg)| arm * leg < 0.0)
        })
    }

    pub fn from_bytes(bytes: &[u8], spec: ModelSpec) -> Result<Self, String> {
        let humanoid = Humanoid::read(bytes);
        let (document, buffers, images) = gltf::import_slice(bytes).map_err(|e| e.to_string())?;
        Self::from_document(document, buffers, images, spec, humanoid)
    }

    pub fn from_gltf(path: &Path, bytes: &[u8], spec: ModelSpec) -> Result<Self, String> {
        let base = path.parent().ok_or("缺少素材目录")?;
        let root = std::fs::canonicalize(base).map_err(|error| error.to_string())?;
        let gltf::Gltf { document, blob } =
            gltf::Gltf::from_slice(bytes).map_err(|error| error.to_string())?;
        let buffers = document
            .buffers()
            .filter_map(|buffer| match buffer.source() {
                gltf::buffer::Source::Uri(uri) => Some(uri),
                _ => None,
            });
        let images = document.images().filter_map(|image| match image.source() {
            gltf::image::Source::Uri { uri, .. } => Some(uri),
            _ => None,
        });
        for uri in buffers.chain(images) {
            if uri.starts_with("data:") {
                continue;
            }
            let relative = Path::new(uri);
            if uri.contains(['%', ':', '\\', '?', '#'])
                || relative
                    .components()
                    .any(|part| !matches!(part, Component::Normal(_)))
            {
                return Err("glTF 引用必须指向素材包内的相对路径".into());
            }
            let resolved =
                std::fs::canonicalize(base.join(relative)).map_err(|error| error.to_string())?;
            let metadata = std::fs::metadata(&resolved).map_err(|error| error.to_string())?;
            if !resolved.starts_with(&root)
                || !metadata.is_file()
                || metadata.len() > 32 * 1024 * 1024
            {
                return Err("glTF 引用不在素材包内，或文件太大".into());
            }
        }
        let buffers =
            gltf::import_buffers(&document, Some(base), blob).map_err(|error| error.to_string())?;
        let images = gltf::import_images(&document, Some(base), &buffers)
            .map_err(|error| error.to_string())?;
        Self::from_document(document, buffers, images, spec, None)
    }

    fn from_document(
        document: gltf::Document,
        buffers: Vec<gltf::buffer::Data>,
        images: Vec<gltf::image::Data>,
        spec: ModelSpec,
        humanoid: Option<Humanoid>,
    ) -> Result<Self, String> {
        let read = |buffer: gltf::Buffer<'_>| buffers.get(buffer.index()).map(|b| b.0.as_slice());
        let mut nodes: Vec<_> = document
            .nodes()
            .map(|node| {
                let (translation, rotation, scale) = node.transform().decomposed();
                Node {
                    pose: Pose {
                        translation: Vec3::from_array(translation),
                        rotation: Quat::from_array(rotation).normalize(),
                        scale: Vec3::from_array(scale),
                    },
                    parent: None,
                }
            })
            .collect();
        if nodes.len() > 4096 {
            return Err("模型节点过多".into());
        }
        for node in document.nodes() {
            for child in node.children() {
                nodes[child.index()].parent = Some(node.index());
            }
        }
        let skins = document
            .skins()
            .map(|skin| {
                let reader = skin.reader(read);
                let matrices: Vec<_> = reader
                    .read_inverse_bind_matrices()
                    .map(|items| items.map(|m| Mat4::from_cols_array_2d(&m)).collect())
                    .unwrap_or_default();
                Skin {
                    joints: skin
                        .joints()
                        .enumerate()
                        .map(|(i, node)| {
                            (
                                node.index(),
                                matrices.get(i).copied().unwrap_or(Mat4::IDENTITY),
                            )
                        })
                        .collect(),
                }
            })
            .collect();

        let mut meshes = Vec::new();
        let mut vertex_buffers: HashMap<_, Rc<Vec<Vertex>>> = HashMap::new();
        let mut vertex_count = 0;
        let mut triangle_count = 0;
        for node in document.nodes() {
            let Some(mesh) = node.mesh() else { continue };
            for primitive in mesh.primitives() {
                if primitive.mode() != gltf::mesh::Mode::Triangles {
                    continue;
                }
                let reader = primitive.reader(read);
                let Some(positions) = reader.read_positions() else {
                    continue;
                };
                let pbr = primitive.material().pbr_metallic_roughness();
                let base_texture = pbr.base_color_texture();
                let uv_set = base_texture.as_ref().map_or(0, |t| t.tex_coord());
                use gltf::Semantic::{Joints, Positions, TexCoords, Weights};
                let key = [Positions, TexCoords(uv_set), Joints(0), Weights(0)]
                    .map(|semantic| primitive.get(&semantic).map(|accessor| accessor.index()));
                let vertices = if let Some(vertices) = vertex_buffers.get(&key) {
                    Rc::clone(vertices)
                } else {
                    vertex_count += positions.len();
                    if vertex_count > MAX_VERTICES {
                        return Err("模型顶点过多".into());
                    }
                    let mut uv = reader.read_tex_coords(uv_set).map(|uv| uv.into_f32());
                    let mut joints = reader.read_joints(0).map(|j| j.into_u16());
                    let mut weights = reader.read_weights(0).map(|w| w.into_f32());
                    let vertices: Rc<Vec<_>> = Rc::new(
                        positions
                            .map(|p| Vertex {
                                position: Vec3::from_array(p),
                                uv: uv
                                    .as_mut()
                                    .and_then(Iterator::next)
                                    .map(Vec2::from_array)
                                    .unwrap_or_default(),
                                joints: joints
                                    .as_mut()
                                    .and_then(Iterator::next)
                                    .unwrap_or_default(),
                                weights: weights
                                    .as_mut()
                                    .and_then(Iterator::next)
                                    .unwrap_or_default(),
                            })
                            .collect(),
                    );
                    vertex_buffers.insert(key, Rc::clone(&vertices));
                    vertices
                };
                let indices: Vec<_> = reader
                    .read_indices()
                    .map(|i| i.into_u32().collect())
                    .unwrap_or_else(|| (0..vertices.len() as u32).collect());
                triangle_count += indices.len() / 3;
                if triangle_count > MAX_TRIANGLES
                    || indices.iter().any(|&i| i as usize >= vertices.len())
                {
                    return Err("模型三角面无效或过多".into());
                }
                let expressions = std::array::from_fn(|expression| {
                    let mut result = Vec::new();
                    if let Some(human) = &humanoid {
                        for &(mesh_id, target, weight) in &human.expressions[expression] {
                            if mesh_id != mesh.index() {
                                continue;
                            }
                            if let Some((Some(positions), _, _)) =
                                reader.read_morph_targets().nth(target)
                            {
                                if positions.len() != vertices.len() {
                                    continue;
                                }
                                if result.is_empty() {
                                    result.resize(vertices.len(), Vec3::ZERO);
                                }
                                for (delta, position) in result.iter_mut().zip(positions) {
                                    *delta += Vec3::from_array(position) * weight;
                                }
                            }
                        }
                    }
                    result
                });
                meshes.push(Mesh {
                    vertices,
                    indices,
                    node: node.index(),
                    skin: node.skin().map(|s| s.index()),
                    texture: base_texture.map(|t| t.texture().source().index()),
                    color: Vec4::from_array(pbr.base_color_factor()),
                    unlit: primitive.material().unlit(),
                    expressions,
                });
            }
        }
        if meshes.is_empty() {
            return Err("模型没有三角网格".into());
        }

        let clips = document
            .animations()
            .map(|animation| {
                let channels: Vec<_> = animation
                    .channels()
                    .filter_map(|channel| {
                        let reader = channel.reader(read);
                        let times: Vec<_> = reader.read_inputs()?.collect();
                        if times.is_empty() {
                            return None;
                        }
                        let interpolation = channel.sampler().interpolation();
                        let stride = if interpolation == Interpolation::CubicSpline {
                            3
                        } else {
                            1
                        };
                        let offset = usize::from(stride == 3);
                        let vectors = |values: Vec<[f32; 3]>| {
                            Values::Vector(
                                values
                                    .into_iter()
                                    .skip(offset)
                                    .step_by(stride)
                                    .map(Vec3::from_array)
                                    .collect(),
                            )
                        };
                        let values = match reader.read_outputs()? {
                            ReadOutputs::Translations(v) => vectors(v.collect()),
                            ReadOutputs::Scales(v) => vectors(v.collect()),
                            ReadOutputs::Rotations(v) => Values::Rotation(
                                v.into_f32()
                                    .skip(offset)
                                    .step_by(stride)
                                    .map(|q| Quat::from_array(q).normalize())
                                    .collect(),
                            ),
                            _ => return None,
                        };
                        let len = match &values {
                            Values::Vector(v) => v.len(),
                            Values::Rotation(v) => v.len(),
                        };
                        (len == times.len()).then(|| Channel {
                            node: channel.target().node().index(),
                            property: channel.target().property(),
                            times,
                            values,
                            interpolation,
                        })
                    })
                    .collect();
                let duration = channels
                    .iter()
                    .filter_map(|c| c.times.last().copied())
                    .fold(0.0, f32::max);
                Clip {
                    name: animation.name().unwrap_or_default().to_owned(),
                    duration,
                    channels,
                }
            })
            .collect();

        let mut model = Self {
            nodes,
            skins,
            meshes,
            images,
            clips,
            spec,
            center: Vec3::ZERO,
            extent: 1.0,
            half_height: 0.5,
            humanoid,
            walk_rate: None,
            support_feet: None,
            mocap: None,
            gait: Cell::new(0),
        };
        let rest = model.world("idle", 0.0);
        if let Some(humanoid) = &mut model.humanoid {
            humanoid.bones.retain(|_, index| *index < rest.len());
            humanoid.axes = rest
                .iter()
                .map(|matrix| {
                    matrix
                        .to_scale_rotation_translation()
                        .1
                        .inverse()
                        .normalize()
                })
                .collect();
            humanoid.bind_arms(&rest);
            model.mocap = MocapRig::new(humanoid, &rest);
        }
        let world = model.world("idle", 0.0);
        let mut min = Vec3::splat(f32::INFINITY);
        let mut max = Vec3::splat(f32::NEG_INFINITY);
        for mesh in &model.meshes {
            let joints = model.joints(mesh, &world);
            for vertex in mesh.vertices.iter() {
                let p = position(vertex, world[mesh.node], &joints);
                if p.is_finite() {
                    min = min.min(p);
                    max = max.max(p);
                }
            }
        }
        if !min.is_finite() || !max.is_finite() {
            return Err("模型取景范围无效".into());
        }
        model.center = (min + max) / 2.0;
        model.extent = (max - min).max_element().max(0.0001);
        model.half_height = (max.y - min.y) / 2.0;
        model.support_feet = model.humanoid.as_ref().and_then(|human| {
            let left = *human.bones.get("leftFoot")?;
            let right = *human.bones.get("rightFoot")?;
            Some([(left, world[left].w_axis.y), (right, world[right].w_axis.y)])
        });
        if let Some(foot) = model
            .humanoid
            .as_ref()
            .and_then(|human| human.bones.get("leftFoot"))
        {
            let start = model.world("walk", 0.0)[*foot].w_axis;
            let end = model.world("walk", HALF_STEP_SECONDS)[*foot].w_axis;
            let travel = (start.z - end.z).abs() * WALK_YAW.sin();
            let rate = travel * model.scale(1.0) / HALF_STEP_SECONDS;
            model.walk_rate = (rate.is_finite() && rate > 0.0).then_some(rate);
        }
        Ok(model)
    }

    fn select(&self, state: &str) -> Option<(&Clip, bool)> {
        if let Some(spec) = self.spec.clips.get(state) {
            let (name, looping) = match spec {
                ClipSpec::Name(name) => (name, matches!(state, "idle" | "walk" | "drag")),
                ClipSpec::Details {
                    clip,
                    hold,
                    looping,
                } => (
                    clip,
                    !hold && looping.unwrap_or(matches!(state, "idle" | "walk" | "drag")),
                ),
            };
            if let Some(clip) = self.clips.iter().find(|clip| clip.name == *name) {
                return Some((clip, looping));
            }
        }
        let names: &[&str] = match state {
            "walk" => &["walk", "run"],
            "sleep" => &["sleep", "lie", "sit"],
            "happy" | "drag" => &["jump", "wave"],
            _ => &["idle", "survey"],
        };
        if let Some(clip) = self.clips.iter().find(|clip| {
            let name = clip.name.to_ascii_lowercase();
            names.iter().any(|keyword| name.contains(keyword))
        }) {
            Some((clip, matches!(state, "idle" | "walk" | "drag")))
        } else if state != "idle" {
            self.select("idle")
        } else {
            self.clips.first().map(|clip| (clip, true))
        }
    }

    fn world(&self, state: &str, seconds: f32) -> Vec<Mat4> {
        let mut poses: Vec<_> = self.nodes.iter().map(|node| node.pose).collect();
        let (clip, time) = if let Some(names) = self.sequence(state) {
            let mut remaining = seconds;
            let mut selected = None;
            for name in names {
                if let Some(clip) = self.clip(name) {
                    selected = Some((clip, remaining.min(clip.duration)));
                    if remaining < clip.duration {
                        break;
                    }
                    remaining -= clip.duration;
                }
            }
            selected.unzip()
        } else if let Some((clip, looping)) = self.select(state) {
            let time = if looping && clip.duration > 0.0 {
                seconds % clip.duration
            } else {
                seconds.min(clip.duration)
            };
            (Some(clip), Some(time))
        } else {
            (None, None)
        };
        if let (Some(clip), Some(time)) = (clip, time) {
            for channel in &clip.channels {
                channel.sample(time, &mut poses[channel.node]);
            }
        }
        if let Some(humanoid) = &self.humanoid {
            if state == "walk" && self.mocap.is_some() && mocap_walk(self.gait.get()).is_some() {
                self.apply_mocap(&mut poses, humanoid, seconds);
            } else {
                humanoid.pose(
                    &mut poses,
                    if state == "walk-procedural" {
                        "walk"
                    } else {
                        state
                    },
                    seconds,
                );
            }
        }
        let locals: Vec<_> = poses.into_iter().map(Pose::matrix).collect();
        let mut world = vec![None; locals.len()];
        for start in 0..locals.len() {
            let mut chain = Vec::new();
            let mut next = Some(start);
            let mut parent = Mat4::IDENTITY;
            while let Some(i) = next {
                if let Some(matrix) = world[i] {
                    parent = matrix;
                    break;
                }
                if chain.len() == locals.len() {
                    break;
                }
                chain.push(i);
                next = self.nodes[i].parent;
            }
            for i in chain.into_iter().rev() {
                parent *= locals[i];
                world[i] = Some(parent);
            }
        }
        world
            .into_iter()
            .map(|m| m.unwrap_or(Mat4::IDENTITY))
            .collect()
    }

    fn bone_matrix(&self, poses: &[Pose], mut bone: Option<usize>) -> Mat4 {
        let mut matrix = Mat4::IDENTITY;
        for _ in 0..self.nodes.len() {
            let Some(index) = bone else { break };
            matrix = poses[index].matrix() * matrix;
            bone = self.nodes[index].parent;
        }
        matrix
    }

    fn set_world_rotation(&self, poses: &mut [Pose], bone: usize, rotation: Quat) {
        let parent = self.bone_matrix(poses, self.nodes[bone].parent);
        let parent_rotation = parent.to_scale_rotation_translation().1.normalize();
        poses[bone].rotation = (parent_rotation.inverse() * rotation).normalize();
    }

    fn apply_mocap(&self, poses: &mut [Pose], human: &Humanoid, seconds: f32) {
        let Some((rig, track)) = self.mocap.as_ref().zip(mocap_walk(self.gait.get())) else {
            return;
        };
        let frame = (seconds * track.fps).rem_euclid(track.frames as f32);
        let first = frame.floor() as usize;
        let second = (first + 1) % track.frames;
        let blend = frame.fract();
        let vector = |samples: &[[f32; 3]]| {
            Vec3::from_array(samples[first]).lerp(Vec3::from_array(samples[second]), blend)
        };
        let facing = Quat::from_rotation_y(if human.faces_back {
            std::f32::consts::PI
        } else {
            0.0
        });
        let root = self.bone_matrix(poses, self.nodes[rig.hips].parent);
        poses[rig.hips].translation += root
            .inverse()
            .transform_vector3(facing * vector(&track.hips) * rig.leg_length);
        for name in MOCAP_CHAIN {
            let Some((&bone, frames)) = human.bones.get(name).zip(track.rot.get(name)) else {
                continue;
            };
            let delta = Quat::from_array(frames[first])
                .normalize()
                .slerp(Quat::from_array(frames[second]).normalize(), blend);
            let rest = rig.rest[bone].to_scale_rotation_translation().1.normalize();
            self.set_world_rotation(poses, bone, facing * delta * facing.inverse() * rest);
        }
        for (side, &[upper, lower, ankle]) in ["left", "right"].into_iter().zip(&rig.legs) {
            let rest_hip = rig.rest[rig.hips].w_axis.truncate();
            let rest_ankle = rig.rest[ankle].w_axis.truncate();
            let target = Vec3::new(rest_hip.x, rest_ankle.y, rest_hip.z)
                + facing * vector(&track.ankle[side]) * rig.leg_length;
            let position =
                |poses: &[Pose], joint| self.bone_matrix(poses, Some(joint)).w_axis.truncate();
            let hip = position(poses, upper);
            let knee = position(poses, lower);
            let foot = position(poses, ankle);
            let thigh = hip.distance(knee);
            let shin = knee.distance(foot);
            let reach = target - hip;
            let Some(axis) = reach.try_normalize() else {
                continue;
            };
            if thigh.min(shin) <= 0.0001 {
                continue;
            }
            let distance = reach
                .length()
                .clamp((thigh - shin).abs() + 0.0001, thigh + shin - 0.0001);
            let along = (thigh * thigh - shin * shin + distance * distance) / (2.0 * distance);
            let forward = facing * Vec3::Z;
            let bend = (forward - axis * forward.dot(axis)).normalize_or_zero();
            let knee_target =
                hip + axis * along + bend * (thigh * thigh - along * along).max(0.0).sqrt();
            let foot_target = hip + axis * distance;
            for (bone, child, desired) in [
                (upper, lower, knee_target - hip),
                (lower, ankle, foot_target - knee_target),
            ] {
                let current = position(poses, child) - position(poses, bone);
                if let (Some(current), Some(desired)) =
                    (current.try_normalize(), desired.try_normalize())
                {
                    let rotation = self
                        .bone_matrix(poses, Some(bone))
                        .to_scale_rotation_translation()
                        .1
                        .normalize();
                    self.set_world_rotation(
                        poses,
                        bone,
                        Quat::from_rotation_arc(current, desired) * rotation,
                    );
                }
            }
            let toes = &track.toe[side];
            let pitch = (toes[first] + (toes[second] - toes[first]) * blend).to_radians();
            let rest = rig.rest[ankle]
                .to_scale_rotation_translation()
                .1
                .normalize();
            self.set_world_rotation(
                poses,
                ankle,
                Quat::from_axis_angle(facing * Vec3::X, pitch) * rest,
            );
        }
    }

    fn clip(&self, name: &str) -> Option<&Clip> {
        self.clips.iter().find(|clip| clip.name == name)
    }

    fn sequence(&self, state: &str) -> Option<&[String]> {
        if state == "fidget" {
            return self
                .spec
                .fidgets
                .iter()
                .find(|name| self.clip(name).is_some())
                .map(std::slice::from_ref);
        }
        self.spec
            .interactions
            .get(state)?
            .iter()
            .map(ClipSequence::names)
            .find(|names| !names.is_empty() && names.iter().all(|name| self.clip(name).is_some()))
    }

    pub fn interaction_seconds(&self, state: &str) -> Option<f32> {
        if self.humanoid.is_some()
            && matches!(
                state,
                "poke"
                    | "highFive"
                    | "pet"
                    | "feed"
                    | "play"
                    | "wake"
                    | "nod"
                    | "shake"
                    | "laugh"
                    | "cry"
            )
        {
            return Some(1.25);
        }
        let duration: f32 = self
            .sequence(state)?
            .iter()
            .filter_map(|name| self.clip(name))
            .map(|clip| clip.duration)
            .sum();
        (duration > 0.0).then_some(duration)
    }

    fn joints(&self, mesh: &Mesh, world: &[Mat4]) -> Vec<Mat4> {
        mesh.skin
            .and_then(|i| self.skins.get(i))
            .map(|skin| {
                skin.joints
                    .iter()
                    .map(|&(i, bind)| world[i] * bind)
                    .collect()
            })
            .unwrap_or_default()
    }

    pub unsafe fn draw(&self, dc: HDC, size: i32, state: &str, seconds: f64, left: bool) {
        let edge = if self.is_humanoid() {
            size
        } else {
            size.min(160)
        } as usize;
        let pixels = self.render(edge, state, seconds as f32, left);
        super::pet_pack::draw_bitmap(dc, (0, 0, size, size), (edge, edge), &pixels);
    }

    pub fn render(&self, edge: usize, state: &str, seconds: f32, left: bool) -> Vec<u32> {
        let mut raster = Raster {
            edge,
            pixels: vec![KEY; edge * edge],
            depth: vec![f32::NEG_INFINITY; edge * edge],
            origin_y: 0.0,
        };
        let yaw = if state == "walk" {
            WALK_YAW
        } else if self.is_humanoid() || state == "happy" {
            0.0
        } else {
            0.45
        };
        let correction = if self.humanoid.as_ref().is_some_and(|human| human.faces_back) {
            std::f32::consts::PI
        } else {
            0.0
        };
        let pitch = if self.is_humanoid() && state != "walk" {
            0.06
        } else {
            0.17
        };
        let camera = Quat::from_rotation_x(pitch)
            * Quat::from_rotation_y(
                (if left { -yaw } else { yaw })
                    + self.spec.yaw.unwrap_or_default().to_radians()
                    + correction,
            );
        let scale = self.scale(edge as f32);
        let shoe_margin = if self.is_humanoid() {
            edge as f32 * 0.055
        } else {
            3.0
        };
        raster.origin_y = edge as f32 - self.half_height * scale * 0.985 - shoe_margin;
        let world = self.world(state, seconds);
        if let Some(human) = &self.humanoid {
            let anchor = match state {
                "sit" => Some(("hips", SEAT_LINE)),
                "peek" => Some(("neck", PEEK_LINE)),
                _ => None,
            };
            if let Some((bone, line)) = anchor {
                if let Some(&joint) = human.bones.get(bone) {
                    let projected = camera * (world[joint].w_axis.truncate() - self.center) * scale;
                    raster.origin_y = edge as f32 * line + projected.y;
                }
            }
        }
        if state == "walk" && (self.mocap.is_none() || mocap_walk(self.gait.get()).is_none()) {
            if let Some(feet) = self.support_feet {
                let phase = seconds / HALF_STEP_SECONDS;
                let side = phase.floor() as usize % 2;
                let blend = (phase.fract() / 0.20).clamp(0.0, 1.0);
                let blend = blend * blend * (3.0 - 2.0 * blend);
                let offset = |side: usize| {
                    let (foot, rest_height) = feet[side];
                    world[foot].w_axis.y - rest_height
                };
                let support = offset(1 - side) * (1.0 - blend) + offset(side) * blend;
                raster.origin_y += support * scale * 0.985;
            }
        }
        let mut projected: HashMap<_, Vec<Vec3>> = HashMap::new();
        let expression = match state {
            "laugh" => Some(0),
            "cry" => Some(1),
            _ => None,
        };
        let strength = (std::f32::consts::PI * (seconds / 1.25).clamp(0.0, 1.0))
            .sin()
            .max(0.0);
        for (mesh_index, mesh) in self.meshes.iter().enumerate() {
            let deltas = expression.map_or(&[][..], |index| mesh.expressions[index].as_slice());
            let points = projected
                .entry((
                    mesh.node,
                    Rc::as_ptr(&mesh.vertices),
                    (!deltas.is_empty()).then_some(mesh_index),
                ))
                .or_insert_with(|| {
                    let joints = self.joints(mesh, &world);
                    mesh.vertices
                        .iter()
                        .enumerate()
                        .map(|(index, vertex)| {
                            camera
                                * (position_with_offset(
                                    vertex,
                                    world[mesh.node],
                                    &joints,
                                    deltas.get(index).copied().unwrap_or_default() * strength,
                                ) - self.center)
                                * scale
                        })
                        .collect()
                });
            let texture = mesh.texture.and_then(|i| self.images.get(i));
            for index in mesh.indices.chunks_exact(3) {
                let indices = [index[0] as usize, index[1] as usize, index[2] as usize];
                raster.triangle(
                    indices.map(|i| points[i]),
                    indices.map(|i| mesh.vertices[i].uv),
                    mesh,
                    texture,
                );
            }
        }
        if state == "peek" {
            let cut = (edge as f32 * PEEK_LINE) as usize;
            raster.pixels[cut * edge..].fill(KEY);
        }
        raster.pixels
    }

    fn scale(&self, edge: f32) -> f32 {
        edge * 0.72 / self.extent * self.spec.scale.unwrap_or(1.0).clamp(0.25, 3.0)
    }
}

fn position(vertex: &Vertex, world: Mat4, joints: &[Mat4]) -> Vec3 {
    position_with_offset(vertex, world, joints, Vec3::ZERO)
}

fn position_with_offset(vertex: &Vertex, world: Mat4, joints: &[Mat4], offset: Vec3) -> Vec3 {
    let local_position = vertex.position + offset;
    let mut result = Vec3::ZERO;
    let mut total = 0.0;
    for (index, weight) in vertex.joints.iter().zip(vertex.weights) {
        if let Some(joint) = joints.get(*index as usize).filter(|_| weight > 0.0) {
            result += joint.transform_point3(local_position) * weight;
            total += weight;
        }
    }
    if total > 0.0 {
        result / total
    } else {
        world.transform_point3(local_position)
    }
}

struct Raster {
    edge: usize,
    pixels: Vec<u32>,
    depth: Vec<f32>,
    origin_y: f32,
}

impl Raster {
    fn triangle(
        &mut self,
        points: [Vec3; 3],
        uv: [Vec2; 3],
        mesh: &Mesh,
        texture: Option<&gltf::image::Data>,
    ) {
        if points.iter().any(|point| !point.is_finite()) {
            return;
        }
        let center = self.edge as f32 * 0.5;
        let [a, b, c] = points.map(|p| Vec2::new(center + p.x, self.origin_y - p.y));
        let ab = b - a;
        let ac = c - a;
        let det = ab.perp_dot(ac);
        if det.abs() < 0.01 {
            return;
        }
        let min = a.min(b).min(c).floor().max(Vec2::ZERO);
        let max = a.max(b).max(c).ceil().min(Vec2::splat(self.edge as f32));
        let normal = (points[1] - points[0])
            .cross(points[2] - points[0])
            .normalize_or_zero();
        let light = if mesh.unlit {
            1.0
        } else {
            0.63 + 0.37 * normal.dot(Vec3::new(-0.35, 0.45, 0.82)).abs()
        };
        for y in min.y as usize..max.y as usize {
            for x in min.x as usize..max.x as usize {
                let p = Vec2::new(x as f32 + 0.5, y as f32 + 0.5) - a;
                let v = p.perp_dot(ac) / det;
                let w = ab.perp_dot(p) / det;
                let u = 1.0 - v - w;
                if u < 0.0 || v < 0.0 || w < 0.0 {
                    continue;
                }
                let depth = points[0].z * u + points[1].z * v + points[2].z * w;
                let i = y * self.edge + x;
                if depth <= self.depth[i] {
                    continue;
                }
                let rgba = texture.map_or(Vec4::ONE, |tex| {
                    sample(tex, uv[0] * u + uv[1] * v + uv[2] * w)
                }) * mesh.color;
                if rgba.w < 0.5 {
                    continue;
                }
                self.depth[i] = depth;
                let rgb = (rgba.truncate() * light * 255.0).clamp(Vec3::ZERO, Vec3::splat(255.0));
                let rgb = ((rgb.x as u32) << 16) | ((rgb.y as u32) << 8) | rgb.z as u32;
                self.pixels[i] = if rgb == KEY { KEY - 1 } else { rgb };
            }
        }
    }
}

fn sample(texture: &gltf::image::Data, uv: Vec2) -> Vec4 {
    use gltf::image::Format::*;
    let channels = match texture.format {
        R8 => 1,
        R8G8 => 2,
        R8G8B8 => 3,
        R8G8B8A8 => 4,
        _ => return Vec4::ONE,
    };
    let width = texture.width as i32;
    let height = texture.height as i32;
    let x = uv.x.rem_euclid(1.0) * width as f32 - 0.5;
    let y = uv.y.rem_euclid(1.0) * height as f32 - 0.5;
    let left = x.floor() as i32;
    let top = y.floor() as i32;
    let horizontal = x - left as f32;
    let vertical = y - top as f32;
    let texel = |x: i32, y: i32| {
        let index = y.rem_euclid(height) as usize * width as usize + x.rem_euclid(width) as usize;
        texel(texture, index * channels, channels)
    };
    texel(left, top)
        .lerp(texel(left + 1, top), horizontal)
        .lerp(
            texel(left, top + 1).lerp(texel(left + 1, top + 1), horizontal),
            vertical,
        )
}

fn texel(texture: &gltf::image::Data, start: usize, channels: usize) -> Vec4 {
    let p = &texture.pixels[start..start + channels];
    let rgba = match p {
        [g] => [*g, *g, *g, 255],
        [g, a] => [*g, *g, *g, *a],
        [r, g, b] => [*r, *g, *b, 255],
        [r, g, b, a] => [*r, *g, *b, *a],
        _ => return Vec4::ONE,
    };
    Vec4::from_array(rgba.map(|v| f32::from(v) / 255.0))
}
