import Foundation
import simd

/// 动捕走路（docs/desktop-pet/MOCAP.md）：真人走路截成一个完整步态，换算到规范化人形空间、长度按腿长归一化，
/// 打包在 App 里（Resources/Motions/mocap-walk-*.json，由 mac/scripts/mocap/convert_bvh.py 生成）。
/// 躯干和手臂直接用动捕的朝向；腿按动捕的踝轨迹交给 `VRMMotion.plantFoot` 解，换成任何身材脚都踩在地上、不打滑。
/// 程序做的走路试用反馈「像机器人」（2026-11），换成了这个；读不到资源时还用程序做的 `walk`。
enum VRMMocap {
    /// 片段名 → 资源名。三种走法按场景换（PetGait）：平时女性化，心情好时开心，活泼时孩子气。
    static let walks: [String: String] = [
        "walk_feminine": "mocap-walk-feminine",
        "walk_happy": "mocap-walk-happy",
        "walk_childish": "mocap-walk-childish",
    ]

    /// 一段动捕步态（convert_bvh.py 的输出）。
    struct Track {
        let frames: Int
        let fps: Double
        /// 地面速度（腿长 / 秒）。
        let speed: Float
        /// hips 相对「腿伸直站着」的位移（腿长为单位）。
        let hips: [SIMD3<Float>]
        /// 躯干、手臂各骨骼的世界旋转（规范化空间，T 字 = 单位旋转）。
        let rotations: [String: [simd_quatf]]
        /// 左右踝的位置（左右、前后相对 hips 的平均位置，上下相对脚掌放平时的踝高；腿长为单位）。
        let ankles: [String: [SIMD3<Float>]]
        /// 左右脚掌角度（度，正 = 脚跟抬起）。
        let toes: [String: [Float]]

        var duration: Double { Double(frames) / fps }

        init?(data: Data) {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let frames = json["frames"] as? Int, frames > 1, let fps = json["fps"] as? Double, fps > 0,
                  let speed = json["speed"] as? Double,
                  let hips = json["hips"] as? [[Double]], hips.count == frames,
                  let rot = json["rot"] as? [String: [[Double]]],
                  let ankle = json["ankle"] as? [String: [[Double]]], let toe = json["toe"] as? [String: [Double]] else {
                return nil
            }
            func vector(_ a: [Double]) -> SIMD3<Float>? {
                a.count == 3 ? SIMD3(Float(a[0]), Float(a[1]), Float(a[2])) : nil
            }
            func quaternion(_ a: [Double]) -> simd_quatf? {
                a.count == 4 ? simd_normalize(simd_quatf(ix: Float(a[0]), iy: Float(a[1]), iz: Float(a[2]), r: Float(a[3]))) : nil
            }
            let hipsTrack = hips.compactMap(vector)
            let rotations = rot.mapValues { $0.compactMap(quaternion) }.filter { $0.value.count == frames }
            let ankles = ankle.mapValues { $0.compactMap(vector) }.filter { $0.value.count == frames }
            let toes = toe.mapValues { $0.map { Float($0) } }.filter { $0.value.count == frames }
            guard hipsTrack.count == frames, ankles.count == 2, toes.count == 2 else { return nil }
            self.frames = frames
            self.fps = fps
            self.speed = Float(speed)
            self.hips = hipsTrack
            self.rotations = rotations
            self.ankles = ankles
            self.toes = toes
        }

        /// 骨骼 → 父骨骼（规范化空间里算局部旋转用；模型多出来的 upperChest 不动，不影响）。
        private static let chain: [(bone: String, parent: String?)] = [
            ("hips", nil), ("spine", "hips"), ("chest", "spine"), ("neck", "chest"), ("head", "neck"),
            ("leftShoulder", "chest"), ("leftUpperArm", "leftShoulder"), ("leftLowerArm", "leftUpperArm"),
            ("leftHand", "leftLowerArm"),
            ("rightShoulder", "chest"), ("rightUpperArm", "rightShoulder"), ("rightLowerArm", "rightUpperArm"),
            ("rightHand", "rightLowerArm"),
        ]

        /// t 秒时的姿势（循环）。restAnkle：这个身材静止时左右踝相对 hips 的位置（见 `restAnkles`）。
        func pose(_ t: Double, body: VRMBody, restAnkle: [VRMSide: SIMD3<Float>]) -> VRMPose {
            let x = (t * fps).truncatingRemainder(dividingBy: Double(frames))
            let position = x < 0 ? x + Double(frames) : x
            let i0 = min(Int(position), frames - 1)
            let i1 = (i0 + 1) % frames
            let f = Float(position - Double(i0))
            let leg = body.thigh + body.shin
            var p = VRMMotion.stand()
            p.hips = simd_mix(hips[i0], hips[i1], SIMD3(repeating: f)) * leg
            var world: [String: simd_quatf] = [:]
            for (bone, parent) in Self.chain {
                guard let track = rotations[bone] else { continue }
                let w = simd_slerp(track[i0], track[i1], f)
                world[bone] = w
                let parentWorld = parent.flatMap { world[$0] } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                p.rotations[bone] = parentWorld.inverse * w
            }
            for side in [VRMSide.left, .right] {
                guard let track = ankles[side.name], let pitch = toes[side.name], let rest = restAnkle[side] else { continue }
                let target = simd_mix(track[i0], track[i1], SIMD3(repeating: f)) * leg
                let toe = Double(pitch[i0] + (pitch[i1] - pitch[i0]) * f)
                VRMMotion.plantFoot(&p, body: body, side: side, ankle: SIMD3(target.x - rest.x, target.y, target.z - rest.z), toe: toe)
            }
            return p
        }
    }

    /// 打包在 App 里的几段（读一次）。
    private static let tracks: [String: Track] = {
        var out: [String: Track] = [:]
        for (clip, resource) in walks {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
                  let data = try? Data(contentsOf: url), let track = Track(data: data) else {
                PetLog.log.error("mocap walk \(resource, privacy: .public) missing or unreadable")
                continue
            }
            out[clip] = track
        }
        return out
    }()

    /// 给这个身材的动捕片段（和程序化动作一起采样成动画，见 `VRMMotion.clips`）。
    static func definitions(body: VRMBody) -> [VRMMotion.Definition] {
        let rest = restAnkles(body: body)
        return tracks.keys.sorted().compactMap { name in
            guard let track = tracks[name] else { return nil }
            return VRMMotion.Definition(name: name, duration: track.duration) { t in
                track.pose(t, body: body, restAnkle: rest)
            }
        }
    }

    /// 动捕走路片段的地面速度（模型单位 / 秒）：宠物窗按它挪，脚才不打滑。不是动捕片段返回 nil。
    static func groundSpeed(_ clip: String, body: VRMBody) -> Float? {
        tracks[clip].map { $0.speed * (body.thigh + body.shin) }
    }

    /// 静止时（plantFoot 的静止解）左右踝相对 hips 的位置：动捕的踝位置按它换算成 plantFoot 要的偏移。
    static func restAnkles(body: VRMBody) -> [VRMSide: SIMD3<Float>] {
        var out: [VRMSide: SIMD3<Float>] = [:]
        for side in [VRMSide.left, .right] {
            var p = VRMPose()
            VRMMotion.plantFoot(&p, body: body, side: side, ankle: .zero, toe: 0)
            let mirror = SIMD3<Float>(side == .left ? 1 : -1, 1, 1)
            let thigh = p.rotation(side.name + "UpperLeg")
            let shin = thigh * p.rotation(side.name + "LowerLeg")
            out[side] = body.legOffset * mirror + thigh.act((body.kneeRest - body.legOffset) * mirror)
                + shin.act((body.ankleRest - body.kneeRest) * mirror)
        }
        return out
    }
}
