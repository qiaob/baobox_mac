import QuartzCore
import SceneKit
import simd

/// 规范化人形空间里的一个姿势（设计见 docs/desktop-pet/VRM.md §4.1）：
/// 人物面朝 +Z、+X 是人物左手边、T 字姿势时各骨骼旋转为单位旋转。换算到实际骨骼见 `VRMRig.localRotation`。
struct VRMPose {
    var rotations: [String: simd_quatf] = [:]
    /// hips 相对静止位置的位移（模型单位）。
    var hips = SIMD3<Float>(repeating: 0)
    /// 表情名 → 权重（0–1）。
    var expressions: [String: Float] = [:]
}

/// 程序化人形动作（设计 §4.2）：VRM 不带动画，按人形骨骼现场生成，任何 VRM 都能用。
/// 每个片段是「时间 → 姿势」的函数，按 30 fps 采样成 CAKeyframeAnimation，装进 GLTFClip 交给现有的播放逻辑。
enum VRMMotion {
    /// 所有片段都驱动这一整组骨骼：片段之间淡入淡出时两头都有值，不会闪回 T 字姿势。模型缺的骨骼跳过。
    /// 手指两版命名都列上（0.x 拇指是 Proximal / Intermediate / Distal，1.0 是 Metacarpal / Proximal / Distal）。
    static let animatedBones: [String] = {
        var names = [
            "hips", "spine", "chest", "neck", "head", "leftShoulder", "rightShoulder",
            "leftUpperArm", "rightUpperArm", "leftLowerArm", "rightLowerArm", "leftHand", "rightHand",
            "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "rightLowerLeg", "leftFoot", "rightFoot",
        ]
        for side in ["left", "right"] {
            for finger in ["Thumb", "Index", "Middle", "Ring", "Little"] {
                for joint in ["Metacarpal", "Proximal", "Intermediate", "Distal"] {
                    names.append(side + finger + joint)
                }
            }
        }
        return names
    }()

    struct Definition {
        let name: String
        let duration: Double
        /// 这些脚钉在地上（plantFeet）：站着的动作都钉，走路、跳、转圈、被拎起、跺脚那只脚不钉。
        var plant: [VRMSide] = []
        let pose: (Double) -> VRMPose

        func sample(_ t: Double, body: VRMBody) -> VRMPose {
            var p = pose(t)
            if !plant.isEmpty { VRMMotion.plantFeet(&p, body: body, sides: plant) }
            return p
        }
    }

    /// 走路：一个完整步态（左右各一步）的时长与大腿前后摆的幅度。
    /// 引擎按它们算宠物窗的移动速度（`groundSpeed`），脚踩在地上不打滑 —— 试用时窗口固定 34 点 / 秒，
    /// 人放大后步子大、身子挪得慢，像在空中踩水（「感觉是飘在空中的」）。
    static let walkCycle = 1.3
    static let walkSwing = 18.0

    /// 走路时身体每秒前进多少（模型单位）：每一步支撑脚从前摆到后，hips 前进 2·腿长·sin(摆幅)，一个周期两步。
    static func groundSpeed(body: VRMBody) -> Float {
        let leg = body.thigh + body.shin
        return 4 * leg * sinf(Float(walkSwing * .pi / 180)) / Float(walkCycle)
    }

    /// 不坐到地上：VRoid 的裙子没有布料模拟，大腿一往前抬（坐、跪、蹲）裙子不会搭在腿上，
    /// 略俯视的相机会看到裙底（实测正座 + 双手放腿上也挡不住）。所以睡觉是站着打盹，喝水 / 吃东西站着捧杯。
    /// 片段名沿用健康提醒与互动认的 sit_down / sit_hold_drink / stand_up（捧起 → 喝两口 → 放下）。
    static func definitions(body: VRMBody) -> [Definition] {
        let both: [VRMSide] = [.left, .right]
        return [
            Definition(name: "idle", duration: 4, plant: both, pose: idle),
            Definition(name: "walk", duration: walkCycle, pose: walk),
            Definition(name: "wave", duration: 2.6, plant: both, pose: wave),
            Definition(name: "bye", duration: 0.55, plant: both, pose: bye),
            Definition(name: "sleep", duration: 1.8, plant: both) { t in
                var p = blend(idle(t), dozing(body), ramp(t, 0, 1.6))
                p.expressions["blink"] = Float(ramp(t, 0.8, 1.7))
                return p
            },
            Definition(name: "get_up", duration: 1.4, plant: both) { t in
                var p = blend(dozing(body), idle(t), ramp(t, 0.1, 1.2))
                p.expressions["blink"] = Float(1 - ramp(t, 0, 0.35))
                return p
            },
            Definition(name: "sit_down", duration: 1.0, plant: both) { t in holdingCup(t, lift: ramp(t, 0, 1.0), sip: 0, chewing: false) },
            Definition(name: "sit_hold_drink", duration: 3.2, plant: both) { t in holdingCup(t, lift: 1, sip: sips(t), chewing: false) },
            Definition(name: "sit_hold_eat", duration: 3.2, plant: both) { t in holdingCup(t, lift: 1, sip: sips(t), chewing: true) },
            Definition(name: "stand_up", duration: 1.0, plant: both) { t in holdingCup(t, lift: 1 - ramp(t, 0, 1.0), sip: 0, chewing: false) },
            Definition(name: "drag", duration: 1.2, pose: drag),
            Definition(name: "look_around", duration: 3.4, plant: both, pose: lookAround),
            Definition(name: "tilt_head", duration: 2.2, plant: both, pose: tiltHead),
            Definition(name: "stretch", duration: 2.8, pose: stretch),
            Definition(name: "yawn", duration: 2.8, plant: both, pose: yawn),
            Definition(name: "giggle", duration: 1.4, plant: both, pose: giggle),
            Definition(name: "jump", duration: 1.0) { t in jump(t, body: body) },
            Definition(name: "nod", duration: 1.8, plant: both, pose: nod),
            Definition(name: "dance", duration: 3.2, plant: both, pose: dance),
            // 第二批（用户反馈「动作太少」「人小，手指动作看不出来，要幅度大的」）：
            // 只做手臂离开身体、整个身子动起来的大动作；来通知、小动作、互动各有好几种随机挑。
            Definition(name: "raise_hand", duration: 2.0, plant: both, pose: raiseHand),
            Definition(name: "big_wave", duration: 2.6, plant: both, pose: bigWave),
            Definition(name: "banzai", duration: 2.0) { t in banzai(t, body: body) },
            Definition(name: "ta_da", duration: 1.8) { t in taDa(t, body: body) },
            Definition(name: "cheer", duration: 2.2, plant: both, pose: cheer),
            Definition(name: "high_five", duration: 2.0, plant: both, pose: highFive),
            Definition(name: "power_pose", duration: 2.2, pose: powerPose),
            Definition(name: "bow", duration: 2.4, plant: both, pose: bow),
            Definition(name: "side_bend", duration: 3.0, pose: sideBend),
            Definition(name: "flamingo", duration: 3.2, plant: [.left], pose: flamingo),
            Definition(name: "hands_behind", duration: 3.4, pose: handsBehind),
            Definition(name: "sway_hum", duration: 4.0, plant: both, pose: swayHum),
            Definition(name: "jumping_jacks", duration: 2.4) { t in jumpingJacks(t, body: body) },
            Definition(name: "boxing", duration: 2.8, plant: both) { t in boxing(t, body: body) },
            Definition(name: "airplane", duration: 3.0, pose: airplane),
            Definition(name: "twist_dance", duration: 3.2, plant: both) { t in twistDance(t, body: body) },
            Definition(name: "run_in_place", duration: 2.4, pose: runInPlace),
            Definition(name: "spin", duration: 1.6, pose: spin),
            Definition(name: "startled", duration: 1.4, pose: startled),
            Definition(name: "lean_laugh", duration: 2.4, plant: both, pose: leanLaugh),
            Definition(name: "shy", duration: 2.4, plant: both, pose: shy),
            // 活动范围（ROAM.md）：跳上 / 掉下窗口、落地、趴在窗口上。
            Definition(name: "jump_up", duration: 0.7) { t in jumpUp(t, body: body) },
            Definition(name: "fall", duration: 0.6, pose: falling),
            Definition(name: "land", duration: 0.5, plant: both, pose: landing),
            Definition(name: "lie_prone", duration: 3.0) { t in lieProne(t, body: body) },
            Definition(name: "pout", duration: 2.4, plant: [.left], pose: pout),
            // 第三批（试用反馈「走来走去碍事，站着不动又单调」：找个空地待着，以原地动作为主）。
            // 待机站姿：长时间站着时轮换，循环播，首尾无缝（周期 = 时长）；不带表情，自动眨眼照常。
            Definition(name: "idle_hands_behind", duration: 4.0, plant: both, pose: idleHandsBehind),
            Definition(name: "idle_arms_crossed", duration: 4.4, plant: both, pose: idleArmsCrossed),
            Definition(name: "idle_hands_front", duration: 4.0, plant: both, pose: idleHandsFront),
            Definition(name: "idle_hip", duration: 4.6, plant: both, pose: idleHip),
            // 原地小动作：从 idle 出发、回到 idle。脚尖离地的那只脚自己钉（plantFoot），所以不在 plant 里。
            Definition(name: "rock_heels", duration: 2.6) { t in rockHeels(t, body: body) },
            Definition(name: "kick_ground", duration: 2.4, plant: [.left]) { t in kickGround(t, body: body) },
            Definition(name: "fix_hair", duration: 2.4, plant: both, pose: fixHair),
            Definition(name: "look_up", duration: 2.8, plant: both, pose: lookUp),
            Definition(name: "hum_bounce", duration: 3.2, plant: both, pose: humBounce),
            Definition(name: "arms_cross_tap", duration: 3.0, plant: [.left]) { t in armsCrossTap(t, body: body) },
            Definition(name: "neck_stretch", duration: 2.8, plant: both, pose: neckStretch),
            Definition(name: "peek", duration: 2.4, plant: both, pose: peek),
        ]
    }

    static func clips(for rig: VRMRig) -> [String: GLTFClip] {
        var out: [String: GLTFClip] = [:]
        for definition in definitions(body: rig.body) {
            out[definition.name] = makeClip(definition, rig: rig)
        }
        return out
    }

    // MARK: - 采样成 CAAnimation

    static func makeClip(_ definition: Definition, rig: VRMRig) -> GLTFClip {
        let frames = max(Int((definition.duration * 30).rounded()), 2)
        let keyTimes = (0...frames).map { NSNumber(value: Double($0) / Double(frames)) }
        let poses = (0...frames).map { definition.sample(definition.duration * Double($0) / Double(frames), body: rig.body) }

        var byNode: [ObjectIdentifier: (node: SCNNode, animations: [CAAnimation])] = [:]
        func add(_ node: SCNNode, _ keyPath: String, _ values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = definition.duration
            animation.calculationMode = .linear
            byNode[ObjectIdentifier(node), default: (node, [])].animations.append(animation)
        }

        for name in animatedBones {
            guard let bone = rig.bones[name] else { continue }
            var previous: simd_quatf?
            let values: [NSValue] = poses.map { pose in
                var q = rig.localRotation(bone, pose.rotations[name] ?? identity)
                // 相邻四元数取同一半球，插值才走短弧。
                if let previous, simd_dot(previous.vector, q.vector) < 0 { q = simd_quatf(vector: -q.vector) }
                previous = q
                return NSValue(scnVector4: SCNVector4(CGFloat(q.imag.x), CGFloat(q.imag.y), CGFloat(q.imag.z), CGFloat(q.real)))
            }
            add(bone.node, "orientation", values)
        }
        if let hips = rig.bones["hips"] {
            let values: [NSValue] = poses.map { pose in
                let p = rig.hipsPosition(pose.hips) ?? hips.restPosition
                return NSValue(scnVector3: SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z)))
            }
            add(hips.node, "position", values)
        }

        // 表情：用到任何表情的片段同时接管眨眼 —— 带表情时不眨（不然眯眼笑再叠一次闭眼），睡觉时闭眼（设计 §4.3）。
        var names = Set(poses.flatMap { $0.expressions.keys })
        if !names.isEmpty { names.insert("blink") }
        var targets: [ObjectIdentifier: (node: SCNNode, indices: Set<Int>)] = [:]
        for name in names {
            for target in rig.expressions[name] ?? [] {
                targets[ObjectIdentifier(target.node), default: (target.node, [])].indices.insert(target.index)
            }
        }
        if !targets.isEmpty {
            let weights = poses.map { pose -> [ObjectIdentifier: [Int: Float]] in
                var frame: [ObjectIdentifier: [Int: Float]] = [:]
                for (node, values) in rig.morphWeights(pose.expressions.filter { names.contains($0.key) }) {
                    frame[ObjectIdentifier(node)] = values
                }
                return frame
            }
            for (key, entry) in targets {
                for index in entry.indices.sorted() {
                    add(entry.node, "morpher.weights[\(index)]", weights.map { NSNumber(value: $0[key]?[index] ?? 0) })
                }
            }
        }

        let tracks = byNode.values.map { GLTFClip.Track(node: $0.node, animations: $0.animations) }
        return GLTFClip(name: definition.name, duration: definition.duration, tracks: tracks)
    }

    // MARK: - 站姿与过渡

    /// 自然站立：手臂下垂、肘微弯，其余骨骼回正（每个片段都从这里出发）。
    static func stand() -> VRMPose {
        var p = VRMPose()
        for bone in animatedBones { p.rotations[bone] = identity }
        p.arm(.left, elevation: -72, forward: 6, elbow: 12)
        p.arm(.right, elevation: -72, forward: 6, elbow: 12)
        p.leg(.left, swing: 0, knee: 2, foot: -2)
        p.leg(.right, swing: 0, knee: 2, foot: -2)
        // T 字姿势的手指是平伸的，看着僵；自然站立时手指微屈。
        p.hand(.left, .relaxed)
        p.hand(.right, .relaxed)
        return p
    }

    /// 钉脚（两节骨骼的腿部 IK）：不管 hips 怎么挪、怎么转，重算大腿 / 小腿 / 脚的旋转，让踝关节留在静止时的位置、脚掌放平。
    /// 试用反馈「站着的时候脚左右摇晃，像飘着」：重心左右移、扭胯时腿是跟着 hips 走的，没有它脚就在地上滑。
    /// 膝盖朝前弯；hips 比站直还高（够不着）时腿伸直、脚离地。
    static func plantFeet(_ p: inout VRMPose, body: VRMBody, sides: [VRMSide] = [.left, .right]) {
        let hipsRotation = p.rotation("hips")
        let thigh = body.thigh
        let shin = body.shin
        for side in sides {
            let mirror = SIMD3<Float>(side == .left ? 1 : -1, 1, 1)
            // 都以 hips 的静止位置为原点：腿根随 hips 位移 + 旋转，踝的目标是它静止时的位置。
            let hipJoint = p.hips + hipsRotation.act(body.legOffset * mirror)
            let toAnkle = body.ankleRest * mirror - hipJoint
            let distance = min(max(simd_length(toAnkle), abs(thigh - shin) + 0.001), thigh + shin - 0.0001)
            let kneeBend = Float.pi - acosf(max(-1, min(1, (thigh * thigh + shin * shin - distance * distance) / (2 * thigh * shin))))
            let thighTilt = acosf(max(-1, min(1, (thigh * thigh + distance * distance - shin * shin) / (2 * thigh * distance))))
            let direction = simd_normalize(toAnkle)
            // 大腿从「腿根 → 踝」这条线往前转 thighTilt，膝盖才朝前；转轴 = 方向 × 正前方。
            var axis = simd_cross(direction, SIMD3<Float>(0, 0, 1))
            axis = simd_length(axis) < 1e-5 ? SIMD3(1, 0, 0) : simd_normalize(axis)
            let thighDirection = simd_quatf(angle: thighTilt, axis: axis).act(direction)
            let thighWorld = simd_quatf(from: SIMD3(0, -1, 0), to: thighDirection)
            let knee = simd_quatf(angle: kneeBend, axis: SIMD3(1, 0, 0))
            p.rotations[side.name + "UpperLeg"] = hipsRotation.inverse * thighWorld
            p.rotations[side.name + "LowerLeg"] = knee
            p.rotations[side.name + "Foot"] = (thighWorld * knee).inverse
        }
    }

    static func blend(_ a: VRMPose, _ b: VRMPose, _ t: Double) -> VRMPose {
        let k = Float(min(max(t, 0), 1))
        var out = VRMPose()
        for key in Set(a.rotations.keys).union(b.rotations.keys) {
            out.rotations[key] = simd_slerp(a.rotation(key), b.rotation(key), k)
        }
        out.hips = a.hips + (b.hips - a.hips) * k
        for key in Set(a.expressions.keys).union(b.expressions.keys) {
            out.expressions[key] = (a.expressions[key] ?? 0) * (1 - k) + (b.expressions[key] ?? 0) * k
        }
        return out
    }

    /// 站着打盹（睡觉的最后一帧，场景随后暂停）：低头、头歪向一边、肩膀和手臂松下来、膝盖微屈，闭眼。
    static func dozing(_ body: VRMBody) -> VRMPose {
        var p = stand()
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: -80, forward: 4, elbow: 8)
            p.leg(side, swing: 0, knee: 7, foot: -7)
        }
        p.hips.y = body.groundedHips(swing: 0, knee: 7) - body.hipsHeight
        p.bend("spine", pitch: 5)
        p.bend("chest", pitch: 4)
        p.bend("neck", pitch: 8)
        p.bend("head", pitch: 22, roll: 9)
        p.shrug(-2)
        p.expressions["blink"] = 1
        return p
    }

    /// 站着双手捧杯：lift 0 → 1 从垂手捧到胸前，sip 0 → 1 从胸前举到嘴边、头微仰；chewing = 吃东西，嘴一张一合。
    static func holdingCup(_ t: Double, lift: Double, sip: Double, chewing: Bool) -> VRMPose {
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, lerp(-48, -22, sip), lift), forward: lerp(6, lerp(55, 64, sip), lift),
                  elbow: lerp(12, lerp(88, 126, sip), lift))
        }
        p.bend("head", pitch: 1.5 + 3 * lift - 12 * sip, roll: 2)
        p.rotations["chest"] = qx(-4 * sip) * p.rotation("chest")
        if chewing {
            p.expressions["aa"] = Float(0.35 * max(0, sin(2 * Double.pi * 3 * t)) * lift)
        } else {
            p.expressions["relaxed"] = Float(0.6 * sip)
        }
        return p
    }

    /// 喝两口：1.1 s 与 2.2 s 各举到嘴边一次。
    static func sips(_ t: Double) -> Double {
        max(bump(t, at: 1.1, width: 0.8), bump(t, at: 2.2, width: 0.8))
    }

    // MARK: - 各片段

    /// 待机（4 s 循环）：胸口起伏、重心左右轻移、头微摆。
    static func idle(_ t: Double) -> VRMPose {
        let phase = 2 * Double.pi * t / 4
        let breath = sin(phase)
        let sway = sin(phase + 0.8)
        var p = stand()
        p.bend("hips", roll: 1.2 * sway)
        p.hips.x = Float(0.006 * sway)
        p.bend("spine", pitch: -0.6 * breath, roll: -1.0 * sway)
        p.bend("chest", pitch: -1.2 * breath)
        p.bend("head", pitch: 1.5, yaw: 2.5 * sin(phase + 1.6), roll: 2 + sin(phase + 0.4))
        p.shrug(0.6 * breath)
        p.arm(.left, elevation: -72 + breath, forward: 6, elbow: 12)
        p.arm(.right, elevation: -72 + breath, forward: 6, elbow: 12)
        return p
    }

    /// 走路（1 s 一个完整步态循环）。
    static func walk(_ t: Double) -> VRMPose {
        let phase = 2 * Double.pi * t / walkCycle
        let s = sin(phase)
        let c = cos(phase)
        var p = stand()
        let thighLeft = walkSwing * s
        let thighRight = -walkSwing * s
        // 摆动相（腿往前送）屈膝，摆到最前时伸直落地；脚掌大致保持水平。
        let kneeLeft = 4 + 34 * pow(max(0, c), 1.5)
        let kneeRight = 4 + 34 * pow(max(0, -c), 1.5)
        p.leg(.left, swing: thighLeft, knee: kneeLeft, foot: (thighLeft - kneeLeft) * 0.7)
        p.leg(.right, swing: thighRight, knee: kneeRight, foot: (thighRight - kneeRight) * 0.7)
        p.hips.y = Float(0.008 * cos(2 * phase) - 0.008)
        p.bend("hips", yaw: -5 * s)
        p.bend("spine", pitch: 3, yaw: 3 * s)
        p.bend("chest", yaw: 3 * s)
        p.bend("head", pitch: -1, yaw: -s)
        // 手臂与同侧腿反向摆。
        p.arm(.left, elevation: -74, forward: 4 - 12 * s, elbow: 15 + 12 * max(0, -s))
        p.arm(.right, elevation: -74, forward: 4 + 12 * s, elbow: 15 + 12 * max(0, s))
        return p
    }

    /// 挥手（来通知、双击）：右手举到头侧，小臂左右摆三下，开心。
    static func wave(_ t: Double) -> VRMPose {
        let duration = 2.6
        let e = envelope(t, duration, rise: 0.35, fall: 0.45)
        var p = idle(t)
        let shake = sin(2 * Double.pi * 2.4 * (t - 0.35)) * 20 * ramp(t, 0.35, 0.5) * (1 - ramp(t, duration - 0.6, duration - 0.35))
        p.arm(.right, elevation: lerp(-72, 28, e), forward: lerp(6, 18, e), elbow: 0)
        p.forearmUp(.right, (80 + shake) * e, forward: 12 * (1 - e))
        p.rotations["head"] = qz(6 * e) * qy(-4 * e) * p.rotation("head")
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 道别（退场前，#54）：右手很快举到头侧摆一下半就放下。退场一共不到 0.9 秒，挥手要在 0.55 秒里做完。
    static func bye(_ t: Double) -> VRMPose {
        let duration = 0.55
        let e = envelope(t, duration, rise: 0.15, fall: 0.15)
        var p = idle(t)
        let shake = sin(2 * Double.pi * 3 * (t - 0.15)) * 22 * ramp(t, 0.12, 0.2)
        p.arm(.right, elevation: lerp(-72, 26, e), forward: lerp(6, 18, e), elbow: 0)
        p.forearmUp(.right, (78 + shake) * e, forward: 12 * (1 - e))
        p.rotations["head"] = qz(6 * e) * qy(-4 * e) * p.rotation("head")
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 被拎起来（循环）：腿悬空交替轻踢，手臂微张，惊讶。
    static func drag(_ t: Double) -> VRMPose {
        let phase = 2 * Double.pi * t / 1.2
        var p = stand()
        p.leg(.left, swing: 10 + 12 * sin(phase), knee: 22 + 14 * sin(phase + 1), foot: 18)
        p.leg(.right, swing: 10 - 12 * sin(phase), knee: 22 - 14 * sin(phase + 1), foot: 18)
        p.arm(.left, elevation: -54 + 4 * sin(phase), forward: 18, elbow: 30)
        p.arm(.right, elevation: -54 - 4 * sin(phase), forward: 18, elbow: 30)
        p.bend("spine", pitch: 4)
        p.bend("head", pitch: 10, roll: 3 * sin(phase))
        p.expressions["surprised"] = 0.8
        return p
    }

    /// 东张西望：先看人物左边，再看右边，回正。
    static func lookAround(_ t: Double) -> VRMPose {
        var p = idle(t)
        let yaw = 42 * (ramp(t, 0.1, 0.6) - 2 * ramp(t, 1.3, 2.1) + ramp(t, 2.7, 3.3))
        p.bend("head", pitch: 1.5, yaw: yaw * 0.7, roll: 2)
        p.bend("neck", yaw: yaw * 0.25)
        p.rotations["chest"] = qy(yaw * 0.35) * p.rotation("chest")
        p.rotations["spine"] = qy(yaw * 0.15) * p.rotation("spine")
        return p
    }

    /// 歪头，微微笑。
    static func tiltHead(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.2, rise: 0.4, fall: 0.5)
        var p = idle(t)
        p.rotations["head"] = qz(16 * e) * qy(-6 * e) * p.rotation("head")
        p.rotations["spine"] = qz(8 * e) * p.rotation("spine")
        p.hips.x += Float(-0.01 * e)
        p.expressions["happy"] = Float(0.35 * e)
        return p
    }

    /// 伸懒腰（站立提醒、睡醒）：双手从两侧举过头顶，后仰、踮脚、眯眼。
    static func stretch(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.8, rise: 0.7, fall: 0.8)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, 82, e), forward: lerp(6, 12, e), elbow: lerp(12, 8, e))
            p.leg(side, swing: 0, knee: 2, foot: -2 + 14 * e)
        }
        p.bend("spine", pitch: -5 * e)
        p.bend("chest", pitch: -7 * e)
        p.bend("head", pitch: -10 * e, roll: 2 * (1 - e))
        p.hips.y = Float(0.012 * e)
        p.expressions["relaxed"] = Float(0.8 * e)
        return p
    }

    /// 打哈欠（休息提醒、睡醒）：右手捂嘴，头微仰，张嘴眯眼。
    static func yawn(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.8, rise: 0.6, fall: 0.7)
        var p = idle(t)
        p.arm(.right, elevation: lerp(-72, -30, e), forward: lerp(6, 70, e), elbow: lerp(12, 128, e))
        p.bend("head", pitch: 1.5 - 8 * e, roll: 2)
        p.bend("chest", pitch: -3 * e)
        p.expressions["aa"] = Float(0.9 * bump(t, at: 1.4, width: 1.6))
        p.expressions["blink"] = Float(0.6 * e)
        return p
    }

    /// 被戳：缩肩捂嘴笑，脑袋一点一点。
    static func giggle(_ t: Double) -> VRMPose {
        let e = envelope(t, 1.4, rise: 0.25, fall: 0.35)
        var p = idle(t)
        p.shrug(10 * e)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -50, e), forward: lerp(6, 45, e), elbow: lerp(12, 80, e))
        }
        let bob = sin(2 * Double.pi * 3 * t) * e
        p.bend("head", pitch: 3 + 6 * bob, roll: 2 + 12 * e)
        p.rotations["spine"] = qz(7 * sin(2 * Double.pi * 4 * t) * e) * qx(6 * e) * p.rotation("spine")
        p.hips.y = Float(0.01 * abs(bob))
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 原地小跳：下蹲 → 起跳 → 落地缓冲（下蹲时 hips 按腿的角度现算，脚踩实地面）。
    static func jump(_ t: Double, body: VRMBody) -> VRMPose {
        var p = idle(t)
        let crouch = bump(t, at: 0.18, width: 0.36) + 0.8 * bump(t, at: 0.78, width: 0.36)
        let air = bump(t, at: 0.48, width: 0.4)
        let grounded = body.groundedHips(swing: 22 * crouch, knee: 2 + 46 * crouch) - body.hipsHeight
        p.hips.y = grounded + Float(0.1 * air)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 22 * crouch + 6 * air, knee: 2 + 46 * crouch + 12 * air, foot: -2 - 22 * crouch + 20 * air)
            p.arm(side, elevation: -72 + 18 * air, forward: 6 + 14 * air, elbow: 12 + 20 * air)
        }
        p.expressions["happy"] = Float(min(1, air + 0.6 * crouch))
        return p
    }

    /// 被摸头：眯眼笑着点两下头。
    static func nod(_ t: Double) -> VRMPose {
        let e = envelope(t, 1.8, rise: 0.3, fall: 0.4)
        var p = idle(t)
        let nods = (bump(t, at: 0.55, width: 0.5) + bump(t, at: 1.1, width: 0.5)) * 18
        p.rotations["head"] = qx(nods) * qz(8 * e) * p.rotation("head")
        p.rotations["spine"] = qx(0.3 * nods) * qz(4 * e) * p.rotation("spine")
        p.expressions["relaxed"] = Float(0.9 * e)
        return p
    }

    /// 陪玩：左右摇摆，在胸前拍手，跟着节拍点头。
    static func dance(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.2, rise: 0.3, fall: 0.4)
        let phase = 2 * Double.pi * t / 1.6
        let beat = abs(sin(2 * phase))
        let clap = pow(abs(cos(2 * phase)), 3)   // 1 = 两手合拢
        var p = idle(t)
        p.hips = SIMD3(Float(0.035 * sin(phase) * e), Float(-0.012 * beat * e), 0)
        p.bend("hips", roll: -6 * sin(phase) * e)
        p.bend("spine", roll: 6 * sin(phase) * e)
        p.bend("chest", roll: 4 * sin(phase) * e)
        p.bend("head", pitch: 4 * beat * e, roll: -10 * sin(phase) * e)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -48, e), forward: lerp(6, 48 + 14 * clap, e), elbow: lerp(12, 70 + 10 * clap, e))
            p.leg(side, swing: 3 * beat * e, knee: 2 + 8 * beat * e, foot: -2 - 5 * beat * e)
        }
        p.expressions["happy"] = Float(e)
        return p
    }

    // MARK: - 第二批：来通知（幅度大，小尺寸也看得清）

    /// 举手「はーい！」：右手笔直举高，身子往左歪，轻轻一蹦。
    static func raiseHand(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.0, rise: 0.3, fall: 0.4)
        var p = idle(t)
        p.arm(.right, elevation: lerp(-72, 86, e), forward: lerp(6, 8, e), elbow: lerp(12, 2, e))
        p.hand(.right, .open, weight: e)
        p.rotations["spine"] = qz(6 * e) * p.rotation("spine")
        p.rotations["head"] = qz(-6 * e) * p.rotation("head")
        p.hips.y += Float(0.02 * bump(t, at: 0.45, width: 0.5))
        p.expressions["happy"] = Float(0.8 * e)
        return p
    }

    /// 双手举过头顶左右大幅挥（像在远处打招呼），身子跟着摆。
    static func bigWave(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.6, rise: 0.35, fall: 0.45)
        let tilt = 28 * sin(2 * Double.pi * 1.4 * (t - 0.35)) * ramp(t, 0.3, 0.5) * e   // 正 = 往人物左边摆
        var p = idle(t)
        p.arm(.left, elevation: lerp(-72, 78 - tilt, e), forward: 8 * e, elbow: lerp(12, 8, e))
        p.arm(.right, elevation: lerp(-72, 78 + tilt, e), forward: 8 * e, elbow: lerp(12, 8, e))
        p.hand(.left, .open, weight: e)
        p.hand(.right, .open, weight: e)
        p.rotations["spine"] = qz(-0.25 * tilt) * p.rotation("spine")
        p.hips.x += Float(0.012 * tilt / 28)
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 万岁：下蹲 → 双手往天上一伸跳起来，连跳两下。
    static func banzai(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 2.0, rise: 0.2, fall: 0.35)
        let air = max(bump(t, at: 0.55, width: 0.5), bump(t, at: 1.25, width: 0.5))
        let crouch = bump(t, at: 0.25, width: 0.3) + bump(t, at: 0.92, width: 0.25) + 0.7 * bump(t, at: 1.62, width: 0.3)
        var p = idle(t)
        p.hips.y = body.groundedHips(swing: 20 * crouch, knee: 2 + 42 * crouch) - body.hipsHeight + Float(0.13 * air)
        let up = max(air, 0.35 * e)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 20 * crouch + 8 * air, knee: 2 + 42 * crouch + 22 * air, foot: -2 - 20 * crouch + 24 * air)
            p.arm(side, elevation: -72 + 158 * up, forward: 10 * up, elbow: lerp(12, 4, up))
            p.hand(side, .open, weight: up)
        }
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 「锵锵～」：小蹲一下跳起来，落地时双手往斜上方张开成 V 字，停一会儿。
    static func taDa(_ t: Double, body: VRMBody) -> VRMPose {
        let crouch = bump(t, at: 0.2, width: 0.3) + 0.6 * bump(t, at: 0.85, width: 0.25)
        let air = bump(t, at: 0.52, width: 0.4)
        let open = ramp(t, 0.35, 0.6) * (1 - ramp(t, 1.45, 1.8))
        var p = idle(t)
        p.hips.y = body.groundedHips(swing: 18 * crouch, knee: 2 + 40 * crouch) - body.hipsHeight + Float(0.1 * air)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 18 * crouch + 6 * air, knee: 2 + 40 * crouch + 16 * air, foot: -2 - 18 * crouch + 20 * air,
                  spread: 6 * open)
            p.arm(side, elevation: lerp(-72, 42, open), forward: lerp(6, 18, open), elbow: lerp(12, 4, open))
            p.hand(side, .open, weight: open)
        }
        p.rotations["head"] = qx(-6 * open) * p.rotation("head")
        p.expressions["happy"] = Float(max(open, air))
        return p
    }

    /// 加油：左拳收在胸前，右拳举高往上顶两下，跟着小跳。
    static func cheer(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.2, rise: 0.25, fall: 0.4)
        let pump = bump(t, at: 0.7, width: 0.45) + bump(t, at: 1.3, width: 0.45)
        var p = idle(t)
        p.arm(.right, elevation: lerp(-72, 50 + 28 * pump, e), forward: lerp(6, 16, e), elbow: lerp(12, 80 - 60 * pump, e), twist: 20 * e)
        p.arm(.left, elevation: lerp(-72, -40, e), forward: lerp(6, 40, e), elbow: lerp(12, 105, e), twist: 30 * e)
        p.hand(.right, .fist, weight: e)
        p.hand(.left, .fist, weight: e)
        p.hips.y += Float(0.03 * pump * e)
        p.expressions["happy"] = Float(e)
        return p
    }

    // MARK: - 第二批：双击 / 被戳

    /// 击掌：右手举到头侧、掌心张开，身子往前凑。
    static func highFive(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.0, rise: 0.3, fall: 0.4)
        var p = idle(t)
        p.arm(.right, elevation: lerp(-72, 30, e), forward: lerp(6, 34, e), elbow: 0)
        p.forearmUp(.right, 75 * e, forward: 12 * e)
        p.hand(.right, .open, weight: e)
        p.rotations["spine"] = qx(8 * e) * p.rotation("spine")
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 秀肌肉：两臂侧平举、小臂竖起握拳，用力鼓两下，叉开腿站稳。
    static func powerPose(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.2, rise: 0.3, fall: 0.45)
        let flex = bump(t, at: 0.85, width: 0.4) + bump(t, at: 1.4, width: 0.4)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, 8 + 6 * flex, e), forward: lerp(6, 8, e), elbow: 0)
            p.forearmUp(side, (96 + 14 * flex) * e)
            p.hand(side, .fist, weight: e)
            p.leg(side, swing: 0, knee: 2 + 6 * e, foot: -2 - 6 * e, spread: 8 * e)
        }
        p.rotations["spine"] = qx(-5 * e) * p.rotation("spine")
        p.rotations["head"] = qz(5 * e) * p.rotation("head")
        p.expressions["happy"] = Float(0.7 * e)
        return p
    }

    /// 鞠躬：从腰往下弯二十多度（再深的话没有物理的长头发会像旗子一样平着飘出去），手垂在身前，停一下再起来。
    static func bow(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.6, fall: 0.7)
        var p = stand()
        p.bend("hips", pitch: 6 * e)
        for side in [VRMSide.left, .right] {
            // hips 前倾会把腿一起带往后，大腿补回来保持竖直。
            p.leg(side, swing: 6 * e, knee: 2, foot: -2)
            p.arm(side, elevation: -82, forward: 14 * e, elbow: 8, twist: 25 * e)
        }
        p.bend("spine", pitch: 9 * e)
        p.bend("chest", pitch: 6 * e)
        p.bend("neck", pitch: 6 * e)
        p.bend("head", pitch: 6 * e)
        p.expressions["relaxed"] = Float(0.6 * e)
        return p
    }

    /// 吓一跳：猛地往后一缩、双手往上一甩、整个人跳起来一点，惊讶。
    static func startled(_ t: Double) -> VRMPose {
        let e = envelope(t, 1.4, rise: 0.1, fall: 0.6)
        let jolt = bump(t, at: 0.2, width: 0.35)
        var p = idle(t)
        p.hips += SIMD3(0, Float(0.06 * jolt), Float(-0.05 * e))
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, 35, e), forward: lerp(6, 25, e), elbow: lerp(12, 70, e))
            p.hand(side, .open, weight: e)
            p.leg(side, swing: 6 * jolt, knee: 2 + 18 * jolt, foot: -2 + 10 * jolt)
        }
        p.rotations["spine"] = qx(-12 * e) * p.rotation("spine")
        p.rotations["head"] = qx(-8 * e) * p.rotation("head")
        p.expressions["surprised"] = Float(e)
        return p
    }

    /// 笑弯了腰：先往后仰哈哈笑，再弯腰捂着肚子笑，身子一抖一抖。
    static func leanLaugh(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.25, fall: 0.5)
        let back = bump(t, at: 0.5, width: 0.7)
        let forward = bump(t, at: 1.4, width: 1.0)
        let shake = sin(2 * Double.pi * 7 * t) * e
        var p = idle(t)
        let lean = -16 * back + 28 * forward
        p.rotations["spine"] = qx(0.5 * lean + 2 * shake) * p.rotation("spine")
        p.rotations["chest"] = qx(0.5 * lean + 2 * shake) * p.rotation("chest")
        p.rotations["head"] = qx(-10 * back + 6 * forward) * p.rotation("head")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -66, e), forward: lerp(6, 34, e), elbow: lerp(12, 78, e), twist: 45 * e)
        }
        p.shrug(4 * abs(shake))
        p.expressions["happy"] = Float(e)
        p.expressions["aa"] = Float(0.5 * e)
        return p
    }

    /// 害羞：双手捧脸，整个上身扭到一边再扭回来。
    static func shy(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.35, fall: 0.5)
        let twist = 22 * sin(2 * Double.pi * t / 1.6) * e
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -24, e), forward: lerp(6, 54, e), elbow: lerp(12, 126, e), twist: 30 * e)
        }
        p.rotations["hips"] = qy(0.4 * twist) * p.rotation("hips")
        p.rotations["spine"] = qy(0.6 * twist) * qz(-0.3 * twist) * p.rotation("spine")
        p.rotations["head"] = qx(12 * e) * p.rotation("head")
        p.expressions["happy"] = Float(0.6 * e)
        return p
    }

    /// 生气：双手叉腰，整个人扭过去不理你，跺两下脚。
    static func pout(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.3, fall: 0.5)
        let stomp = bump(t, at: 0.75, width: 0.3) + bump(t, at: 1.25, width: 0.3)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -50, e), forward: lerp(6, -16, e), elbow: lerp(12, 96, e), twist: 70 * e)
        }
        p.leg(.right, swing: 16 * stomp, knee: 2 + 34 * stomp, foot: -2 - 12 * stomp)
        p.rotations["hips"] = qy(30 * e) * p.rotation("hips")
        p.rotations["spine"] = qy(10 * e) * p.rotation("spine")
        p.rotations["head"] = qz(-6 * e) * qy(18 * e) * qx(-6 * e) * p.rotation("head")
        p.expressions["angry"] = Float(0.9 * e)
        return p
    }

    // MARK: - 第二批：待机小动作

    /// 侧弯腰：双手在头顶合拢，身子往左弯、再往右弯。
    static func sideBend(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.0, rise: 0.5, fall: 0.6)
        let bend = 20 * (ramp(t, 0.6, 1.1) - 2 * ramp(t, 1.4, 2.0) + ramp(t, 2.2, 2.6))   // 正 = 往人物左边弯
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, 78, e), forward: lerp(6, 4, e), elbow: lerp(12, 30, e), twist: 35 * e)
        }
        p.rotations["spine"] = qz(-0.55 * bend * e) * p.rotation("spine")
        p.rotations["chest"] = qz(-0.55 * bend * e) * p.rotation("chest")
        p.hips.x += Float(-0.012 * bend / 20 * e)
        p.expressions["relaxed"] = Float(0.6 * e)
        return p
    }

    /// 单脚站（金鸡独立）：右小腿往后勾起，两臂侧平举保持平衡，身子晃晃悠悠。
    static func flamingo(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.2, rise: 0.5, fall: 0.6)
        let wobble = sin(2 * Double.pi * t / 1.3) * e
        var p = idle(t)
        p.hips.x += Float(0.03 * e)
        p.rotations["hips"] = qz(-3 * e + 3 * wobble) * p.rotation("hips")
        p.leg(.right, swing: -6 * e, knee: 2 + 98 * e, foot: -2 + 30 * e)
        p.leg(.left, swing: 0, knee: 3, foot: -3)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -4 + side.sign * 10 * wobble, e), forward: 4, elbow: lerp(12, 8, e))
            p.hand(side, .open, weight: e)
        }
        p.rotations["spine"] = qz(-6 * wobble) * p.rotation("spine")
        p.expressions["happy"] = Float(0.4 * e)
        p.expressions["surprised"] = Float(0.4 * max(0, abs(wobble) - 0.6))
        return p
    }

    /// 双手背在身后，踮着脚尖前后晃，头一歪一歪。
    static func handsBehind(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.4, rise: 0.5, fall: 0.6)
        let rock = max(0, sin(2 * Double.pi * t / 1.1)) * e
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -74, e), forward: lerp(6, -32, e), elbow: lerp(12, 55, e), twist: 85 * e)
            p.leg(side, swing: 0, knee: 2, foot: -2 + 16 * rock)
        }
        p.hips.y += Float(0.014 * rock)
        p.rotations["head"] = qz(9 * sin(2 * Double.pi * t / 2.2) * e) * p.rotation("head")
        p.expressions["happy"] = Float(0.4 * e)
        return p
    }

    /// 闭眼哼歌，身子左右大幅摇，两手微微张开跟着摆。
    static func swayHum(_ t: Double) -> VRMPose {
        let e = envelope(t, 4.0, rise: 0.5, fall: 0.6)
        let phase = 2 * Double.pi * t / 2.0
        var p = idle(t)
        p.hips.x += Float(0.025 * sin(phase) * e)
        p.rotations["hips"] = qz(-4 * sin(phase) * e) * p.rotation("hips")
        p.rotations["spine"] = qz(6 * sin(phase) * e) * p.rotation("spine")
        p.rotations["head"] = qz(10 * sin(phase + 0.4) * e) * p.rotation("head")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -50 + 8 * sin(phase) * side.sign, e), forward: 12 * e, elbow: lerp(12, 20, e))
        }
        p.expressions["happy"] = Float(0.6 * e)
        return p
    }

    // MARK: - 第二批：陪玩

    /// 开合跳三下：手从两侧划到头顶、腿往外开，一蹦一蹦。
    static func jumpingJacks(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.2, fall: 0.3)
        let phase = 2 * Double.pi * t / 0.8
        let open = (0.5 - 0.5 * cos(phase)) * e
        let hop = abs(sin(phase)) * e
        var p = idle(t)
        p.hips.y = body.groundedHips(swing: 4 * hop, knee: 2 + 14 * hop) - body.hipsHeight + Float(0.035 * hop)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, 78, open), forward: 4, elbow: lerp(12, 6, open))
            p.hand(side, .open, weight: open)
            p.leg(side, swing: 4 * hop, knee: 2 + 14 * hop, foot: -2 + 10 * hop, spread: 13 * open)
        }
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 打拳：侧过身摆架势，左右拳轮流往前打出去，身子跟着拧。
    static func boxing(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 2.8, rise: 0.35, fall: 0.5)
        let punchLeft = bump(t, at: 0.7, width: 0.28) + bump(t, at: 1.5, width: 0.28)
        let punchRight = bump(t, at: 1.1, width: 0.28) + bump(t, at: 1.9, width: 0.28)
        var p = idle(t)
        p.rotations["hips"] = qy(-45 * e) * p.rotation("hips")
        p.rotations["spine"] = qy(-20 * punchLeft + 20 * punchRight) * p.rotation("spine")
        p.hips.y = body.groundedHips(swing: 8 * e, knee: 2 + 16 * e) - body.hipsHeight
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 8 * e, knee: 2 + 16 * e, foot: -2 - 8 * e, spread: 4 * e)
            let punch = side == .left ? punchLeft : punchRight
            p.arm(side, elevation: lerp(-72, lerp(-28, -2, punch), e), forward: lerp(6, lerp(55, 88, punch), e),
                  elbow: lerp(12, lerp(125, 8, punch), e), twist: 30 * e)
            p.hand(side, .fist, weight: e)
        }
        p.expressions["angry"] = Float(0.35 * e)
        return p
    }

    /// 开飞机：两臂伸直张开当翅膀，左右倾斜「转弯」，脚下原地小碎步。
    static func airplane(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.0, rise: 0.4, fall: 0.5)
        let bank = 16 * sin(2 * Double.pi * t / 1.5) * e
        let step = sin(2 * Double.pi * t / 0.5)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -side.sign * bank * 0.4, e), forward: -4 * e, elbow: lerp(12, 4, e))
            p.hand(side, .open, weight: e)
        }
        p.rotations["spine"] = qz(bank) * p.rotation("spine")
        p.rotations["hips"] = qz(-0.3 * bank) * p.rotation("hips")
        p.leg(.left, swing: 14 * max(0, step) * e, knee: 2 + 24 * max(0, step) * e, foot: -2)
        p.leg(.right, swing: 14 * max(0, -step) * e, knee: 2 + 24 * max(0, -step) * e, foot: -2)
        p.hips.y += Float(0.01 * abs(step) * e)
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 扭扭舞：胯和肩反向扭，两只胳膊弯着前后甩，膝盖一颠一颠。
    static func twistDance(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 3.2, rise: 0.3, fall: 0.45)
        let phase = 2 * Double.pi * t / 0.8
        let twist = sin(phase) * e
        let bounce = abs(sin(phase)) * e
        var p = idle(t)
        p.rotations["hips"] = qy(26 * twist) * p.rotation("hips")
        p.rotations["spine"] = qy(-22 * twist) * p.rotation("spine")
        p.rotations["chest"] = qy(-14 * twist) * p.rotation("chest")
        p.hips.y = body.groundedHips(swing: 6 * bounce + 6 * e, knee: 2 + 12 * bounce + 12 * e) - body.hipsHeight
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 6 * bounce + 6 * e, knee: 2 + 12 * bounce + 12 * e, foot: -2 - 12 * e)
            p.arm(side, elevation: lerp(-72, -38, e), forward: lerp(6, side.sign * 34 * twist, e), elbow: lerp(12, 92, e))
            p.hand(side, .fist, weight: 0.6 * e)
        }
        p.rotations["head"] = qz(8 * twist) * p.rotation("head")
        p.expressions["happy"] = Float(e)
        return p
    }

    /// 原地小跑：抬腿、两臂弯着前后摆，身子一颠一颠。
    static func runInPlace(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.25, fall: 0.35)
        let phase = 2 * Double.pi * t / 0.5
        let s = sin(phase)
        var p = idle(t)
        p.leg(.left, swing: 26 * max(0, s) * e, knee: 2 + 50 * max(0, s) * e, foot: -2 + 10 * max(0, s) * e)
        p.leg(.right, swing: 26 * max(0, -s) * e, knee: 2 + 50 * max(0, -s) * e, foot: -2 + 10 * max(0, -s) * e)
        p.hips.y += Float(0.018 * abs(s) * e)
        p.rotations["spine"] = qx(6 * e) * p.rotation("spine")
        p.arm(.left, elevation: lerp(-72, -55, e), forward: lerp(6, -30 * s, e), elbow: lerp(12, 90, e))
        p.arm(.right, elevation: lerp(-72, -55, e), forward: lerp(6, 30 * s, e), elbow: lerp(12, 90, e))
        p.hand(.left, .fist, weight: 0.6 * e)
        p.hand(.right, .fist, weight: 0.6 * e)
        p.expressions["happy"] = Float(e)
        return p
    }

    // MARK: - 活动范围：跳、掉、落地、趴

    /// 起跳（播完停在最后一帧，窗口沿抛物线飞）：下蹲 → 蹬起来、手往上甩 → 在空中收腿。
    static func jumpUp(_ t: Double, body: VRMBody) -> VRMPose {
        let crouch = bump(t, at: 0.12, width: 0.24)
        let launch = ramp(t, 0.15, 0.32)
        let tuck = ramp(t, 0.3, 0.55)
        var p = idle(t)
        p.hips.y = body.groundedHips(swing: 22 * crouch, knee: 2 + 50 * crouch) - body.hipsHeight
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 22 * crouch + 20 * tuck, knee: 2 + 50 * crouch + 50 * tuck, foot: -2 - 20 * crouch + 25 * tuck)
            p.arm(side, elevation: lerp(-72, 60, launch) - 30 * tuck, forward: 15 * launch, elbow: lerp(12, 20, launch))
            p.hand(side, .open, weight: launch)
        }
        p.expressions["happy"] = Float(launch)
        return p
    }

    /// 往下掉（循环）：两手在头顶乱挥、腿乱蹬，往后仰，惊讶。
    static func falling(_ t: Double) -> VRMPose {
        let phase = 2 * Double.pi * t / 0.6
        var p = stand()
        p.arm(.left, elevation: 50 + 25 * sin(phase), forward: 15, elbow: 30)
        p.arm(.right, elevation: 50 - 25 * sin(phase), forward: 15, elbow: 30)
        p.hand(.left, .open)
        p.hand(.right, .open)
        p.leg(.left, swing: 10 + 12 * sin(phase + 1), knee: 25 + 20 * sin(phase), foot: 20)
        p.leg(.right, swing: 10 - 12 * sin(phase + 1), knee: 25 - 20 * sin(phase), foot: 20)
        p.bend("spine", pitch: -6)
        p.bend("head", pitch: -8)
        p.expressions["surprised"] = 1
        return p
    }

    /// 落地缓冲：屈膝一蹲（脚钉在地上，膝盖由钉脚算出来），手往两边张开保持平衡。
    static func landing(_ t: Double) -> VRMPose {
        let squash = bump(t, at: 0.12, width: 0.36)
        var p = idle(t)
        p.hips.y = Float(-0.07 * squash)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -35, squash), forward: 10, elbow: 12)
        }
        p.rotations["spine"] = qx(8 * squash) * p.rotation("spine")
        return p
    }

    /// 趴在窗口上（循环）：整个人往前趴平（头朝镜头），胳膊肘撑着、双手托腮抬头看你，小腿在身后交替翘起来。
    /// 裙子在身体后面，正面看不到裙底。
    static func lieProne(_ t: Double, body: VRMBody) -> VRMPose {
        let phase = 2 * Double.pi * t / 1.5
        var p = stand()
        p.rotations["hips"] = qx(90)
        // hips 落到离地一个身体厚度；整个人往后挪一点，头别凑到镜头前出画。
        p.hips = SIMD3(0, 0.11 - body.hipsHeight, -0.28)
        p.bend("spine", pitch: -22)
        p.bend("chest", pitch: -22)
        p.bend("neck", pitch: -14)
        p.bend("head", pitch: -22 + 4 * sin(phase * 0.5), roll: 6 * sin(phase * 0.5))
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: -40, forward: 62, elbow: 118, twist: 30)
        }
        p.leg(.left, swing: 0, knee: 55 + 40 * sin(phase), foot: 30)
        p.leg(.right, swing: 0, knee: 55 - 40 * sin(phase), foot: 30)
        p.expressions["happy"] = 0.4
        return p
    }

    /// 原地转一圈：两手张开、跳起来转。
    static func spin(_ t: Double) -> VRMPose {
        let e = envelope(t, 1.6, rise: 0.2, fall: 0.3)
        let k = ramp(t, 0.1, 1.4)
        var p = idle(t)
        p.rotations["hips"] = qy(360 * k) * p.rotation("hips")
        p.hips.y += Float(0.05 * sin(Double.pi * k))
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -18, e), forward: 8 * e, elbow: lerp(12, 14, e))
            p.hand(side, .open, weight: e)
        }
        p.expressions["happy"] = Float(e)
        return p
    }

    // MARK: - 第三批：待机站姿（循环，周期 = 时长）

    /// 双手背在身后，胸口微微挺起、头稍歪；呼吸、重心轻移与 idle 相同。
    static func idleHandsBehind(_ t: Double) -> VRMPose {
        let breath = sin(2 * Double.pi * t / 4)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: -74 + 0.8 * breath, forward: -32, elbow: 55, twist: 85)
        }
        p.rotations["chest"] = qx(-2.5) * p.rotation("chest")
        p.rotations["head"] = qz(4) * p.rotation("head")
        return p
    }

    /// 双臂抱在胸前（左小臂压在右小臂上），重心左右慢慢移（比 idle 明显一点）。
    static func idleArmsCrossed(_ t: Double) -> VRMPose {
        let period = 4.4
        let phase = 2 * Double.pi * t / period
        let shift = sin(phase + 0.8)
        var p = idle(t * 4 / period)
        crossArms(&p, weight: 1, breath: sin(phase))
        p.hips.x += Float(0.012 * shift)
        p.rotations["hips"] = qz(2 * shift) * p.rotation("hips")
        p.rotations["spine"] = qz(-2 * shift) * p.rotation("spine")
        p.rotations["head"] = qz(-1.5 * shift) * p.rotation("head")
        return p
    }

    /// 双手在腹前交握，头微微低、稍歪（乖巧地站着）。
    static func idleHandsFront(_ t: Double) -> VRMPose {
        let breath = sin(2 * Double.pi * t / 4)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: -68 + 0.8 * breath, forward: 25, elbow: 74, twist: 50)
        }
        p.rotations["head"] = qz(2.5) * qx(2) * p.rotation("head")
        return p
    }

    /// 重心落在右腿：胯往右顶、右胯高，肩膀反过来右低左高，右手叉腰；左膝由钉脚自然松弯。
    static func idleHip(_ t: Double) -> VRMPose {
        let period = 4.6
        let breath = sin(2 * Double.pi * t / period)
        var p = idle(t * 4 / period)
        p.hips += SIMD3(-0.045, -0.018, 0)
        p.rotations["hips"] = qz(-7) * p.rotation("hips")
        p.rotations["spine"] = qz(4) * p.rotation("spine")
        p.rotations["chest"] = qz(4) * p.rotation("chest")
        p.rotations["head"] = qz(-2) * qy(-4) * p.rotation("head")
        p.arm(.right, elevation: -50 + 0.6 * breath, forward: -16, elbow: 96, twist: 70)
        p.arm(.left, elevation: -74 + breath, forward: 8, elbow: 14)
        return p
    }

    /// 抱臂：weight 0 = 垂手，1 = 抱好（左小臂在上、靠前，右小臂在下、贴身）。
    static func crossArms(_ p: inout VRMPose, weight w: Double, breath: Double = 0) {
        p.arm(.left, elevation: lerp(-72, -59 + 0.6 * breath, w), forward: lerp(6, 62, w), elbow: lerp(12, 100, w), twist: 45 * w)
        p.arm(.right, elevation: lerp(-72, -62 + 0.6 * breath, w), forward: lerp(6, 52, w), elbow: lerp(12, 105, w), twist: 50 * w)
    }

    // MARK: - 第三批：原地小动作（从 idle 出发、回到 idle）

    /// 背着手踮脚尖、落脚跟，前后摇两个来回：踮起时人往前送、升高，落到脚跟时脚尖翘起、身子往后靠。
    static func rockHeels(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 2.6, rise: 0.4, fall: 0.5)
        // +1 = 踮在前脚掌上，−1 = 落在脚跟上。
        let rock = sin(2 * Double.pi * (t - 0.45) / 0.85) * ramp(t, 0.35, 0.6) * (1 - ramp(t, 1.95, 2.25))
        let toe = rock > 0 ? 28 * rock : 16 * rock
        let lean = rock > 0 ? 5 * rock : 3 * rock
        let ankle = ankleLift(toe: toe, body: body)
        var p = idle(t)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -74, e), forward: lerp(6, -32, e), elbow: lerp(12, 55, e), twist: 85 * e)
        }
        p.rotations["hips"] = qx(lean) * p.rotation("hips")
        p.rotations["chest"] = qx(-3 * e) * p.rotation("chest")
        // 整个人绕踝前后倾：hips 跟着踝挪，再加上倾斜带出的位移；比够得着的高度低一点，膝盖不会绷死。
        let lever = body.hipsHeight - body.ankle
        p.hips += SIMD3(0, ankle.y - Float(0.004 * abs(rock)), ankle.z + lever * sinf(Float(lean * .pi / 180)))
        for side in [VRMSide.left, .right] {
            plantFoot(&p, body: body, side: side, ankle: ankle, toe: toe)
        }
        p.shrug(4 * max(0, rock))
        p.rotations["head"] = qz(9 * sin(2 * Double.pi * (t - 0.45) / 1.7) * e) * qx(-6 * max(0, rock)) * p.rotation("head")
        p.expressions["happy"] = Float(0.5 * e)
        return p
    }

    /// 低着头、两手在身前握着，右脚前掌贴地来回蹭两下（脚跟抬起，踝基本不挪；腿的动作小，大腿不往前抬）。
    static func kickGround(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.4, fall: 0.5)
        var p = idle(t)
        // 重心移到左腿：胯往左挪。右胯不往下沉 —— 沉了右腿更短、膝盖更弯，大腿就往前抬了。
        p.hips += SIMD3(Float(0.025 * e), Float(-0.002 * e), 0)
        p.rotations["spine"] = qz(-4 * e) * qx(4 * e) * p.rotation("spine")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -78, e), forward: lerp(6, 18, e), elbow: lerp(12, 45, e), twist: 55 * e)
        }
        p.shrug(4 * e)
        p.bend("neck", pitch: 6 * e)
        p.rotations["head"] = qx(14 * e) * qy(-6 * e) * p.rotation("head")
        // 每下 0.7 s：脚跟抬起，前掌贴着地往后蹭、再蹭回来（前掌高度由 ankleLift 保证贴地；踝始终不超过静止位置往前）。
        var toe = 0.0
        var back = 0.0
        var rub = 0.0
        for start in [0.5, 1.2] {
            let s = min(max((t - start) / 0.7, 0), 1)
            toe += 18 * sin(Double.pi * s)
            back += 0.06 * sin(Double.pi * s) + 0.035 * sin(2 * Double.pi * s)
            rub += sin(2 * Double.pi * s)
        }
        var ankle = ankleLift(toe: toe, body: body)
        ankle.z = Float(-back) * (body.thigh + body.shin)
        plantFoot(&p, body: body, side: .right, ankle: ankle, toe: toe)
        p.rotations["spine"] = qz(-2.5 * rub * e) * p.rotation("spine")
        return p
    }

    /// 右手抬到鬓角，把头发往后别到耳后，再顺着头发往外一撩放开；头跟着往右歪，微笑。
    static func fixHair(_ t: Double) -> VRMPose {
        let w = ramp(t, 0, 0.5) * (1 - ramp(t, 1.85, 2.4))
        let tuck = ramp(t, 0.65, 1.2)
        let flick = ramp(t, 1.3, 1.65)
        var p = idle(t)
        let elevation = lerp(lerp(-18, -10, tuck), -30, flick)
        let forward = lerp(lerp(39, 25, tuck), 28, flick)
        let elbow = lerp(lerp(143, 150, tuck), 130, flick)
        let twist = lerp(-80, -70, flick)
        p.arm(.right, elevation: lerp(-72, elevation, w), forward: lerp(6, forward, w), elbow: lerp(12, elbow, w), twist: twist * w)
        let tilt = w * (0.6 + 0.4 * tuck - 0.5 * flick)
        p.rotations["head"] = qz(12 * tilt) * qy(-6 * w) * p.rotation("head")
        p.rotations["spine"] = qz(-3 * w) * p.rotation("spine")
        p.expressions["relaxed"] = Float(0.6 * w)
        return p
    }

    /// 抬头远眺：右手手掌平搭在眉上遮光，头和上身慢慢从左转到右，胸口往上挺。
    static func lookUp(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.8, rise: 0.5, fall: 0.6)
        let scan = 20 * (1 - 2 * ramp(t, 0.8, 2.1)) * e
        var p = idle(t)
        p.arm(.right, elevation: lerp(-72, 42, e), forward: lerp(6, 45, e), elbow: lerp(12, 94, e), twist: -63 * e)
        p.hand(.right, .open, weight: e)
        p.rotations["rightHand"] = qz(50 * e) * p.rotation("rightHand")
        p.rotations["chest"] = qy(0.55 * scan) * qx(-5 * e) * p.rotation("chest")
        p.rotations["neck"] = qy(0.15 * scan) * qx(-6 * e) * p.rotation("neck")
        p.rotations["head"] = qy(0.3 * scan) * qx(-13 * e) * p.rotation("head")
        return p
    }

    /// 哼着歌一颠一颠：膝盖跟着拍子小幅颠、点头，两臂弯着前后摆，身子左右晃，眯眼笑。
    static func humBounce(_ t: Double) -> VRMPose {
        let e = envelope(t, 3.2, rise: 0.4, fall: 0.5)
        let phase = 2 * Double.pi * t / 0.64
        let bounce = (0.5 - 0.5 * cos(phase)) * e
        let swing = sin(phase / 2) * e
        var p = idle(t)
        p.hips.y += Float(-0.02 * bounce)
        p.hips.x += Float(0.026 * swing)
        p.rotations["hips"] = qz(-4 * swing) * p.rotation("hips")
        p.rotations["spine"] = qz(6 * swing) * p.rotation("spine")
        p.rotations["head"] = qx(9 * bounce) * qz(8 * swing) * p.rotation("head")
        p.arm(.left, elevation: lerp(-72, -58, e), forward: 6 + 28 * swing, elbow: lerp(12, 50, e))
        p.arm(.right, elevation: lerp(-72, -58, e), forward: 6 - 28 * swing, elbow: lerp(12, 50, e))
        p.expressions["relaxed"] = Float(0.8 * e)
        return p
    }

    /// 抱着胳膊不耐烦：右脚尖一下一下点地（脚跟着地、前掌抬起落下），头歪着往旁边看、跟着点，最后放下手。
    static func armsCrossTap(_ t: Double, body: VRMBody) -> VRMPose {
        let e = envelope(t, 3.0, rise: 0.5, fall: 0.6)
        let tap = [0.95, 1.3, 1.65, 2.0].map { bump(t, at: $0, width: 0.3) }.reduce(0, +)
        var p = idle(t)
        crossArms(&p, weight: e)
        p.hips += SIMD3(Float(0.015 * e), Float(-0.006 * e - 0.004 * tap), 0)
        p.rotations["hips"] = qz(3 * e) * p.rotation("hips")
        p.rotations["head"] = qx(4 * tap) * qz(-10 * e) * qy(14 * e) * p.rotation("head")
        let toe = -26 * tap
        plantFoot(&p, body: body, side: .right, ankle: ankleLift(toe: toe, body: body), toe: toe)
        p.expressions["angry"] = Float(0.35 * e)
        return p
    }

    /// 活动脖子和肩膀：右手举过头顶搭到头的左侧，把头往右拉（侧颈拉伸）；
    /// 放开后双手握拳搭在肩上，手肘往前、上、后画两圈（广播体操的转肩）。
    static func neckStretch(_ t: Double) -> VRMPose {
        let up = ramp(t, 0.15, 0.5) * (1 - ramp(t, 1.15, 1.45))
        // 先举高再弯肘搭过去、先松开再放下：手从头顶上方绕，不穿过头。
        let fold = ramp(t, 0.3, 0.65) * (1 - ramp(t, 1.0, 1.25))
        let tilt = ramp(t, 0.45, 0.85) * (1 - ramp(t, 1.05, 1.4))
        let fists = ramp(t, 1.3, 1.55) * (1 - ramp(t, 2.4, 2.8))
        let circle = ramp(t, 1.45, 1.6) * (1 - ramp(t, 2.3, 2.45))
        let theta = 2 * Double.pi * (t - 1.5) / 0.45
        var p = idle(t)
        let e0 = lerp(-72, -22 - 20 * cos(theta) * circle, fists)
        let f0 = lerp(6, 20 + 30 * sin(theta) * circle, fists)
        let el0 = lerp(12, 150, fists)
        let tw0 = -90 * fists
        p.arm(.left, elevation: e0, forward: f0, elbow: el0, twist: tw0)
        // 小臂从头顶偏后绕过去（头上有帽子、发饰时不穿过去），手搭在头的左后侧。
        p.arm(.right, elevation: lerp(e0, 58, up), forward: lerp(f0, -20, up), elbow: lerp(lerp(el0, 15, up), 105, fold),
              twist: lerp(tw0, -95, up))
        for side in [VRMSide.left, .right] {
            p.hand(side, .fist, weight: fists)
            p.rotations[side.name + "Hand"] = qz(-side.sign * 70 * fists) * p.rotation(side.name + "Hand")
        }
        p.shrug(8 * fists + 6 * (0.5 - 0.5 * cos(theta)) * circle)
        // 头歪 20° 左右封顶：长头发没有物理，再歪就整片硬邦邦地甩出去（与 tilt_head 同一量级）。
        p.rotations["neck"] = qz(4 * tilt) * p.rotation("neck")
        p.rotations["head"] = qz(16 * tilt) * p.rotation("head")
        p.expressions["relaxed"] = Float(0.6 * max(tilt, fists))
        return p
    }

    /// 探头偷看：上身往右侧大幅探出去（胯往左让保持平衡），头往那边转、带点好奇，右手抬到脸旁像扶着墙角，探两下再回来。
    static func peek(_ t: Double) -> VRMPose {
        let e = envelope(t, 2.4, rise: 0.5, fall: 0.6)
        let bob = bump(t, at: 1.05, width: 0.35) + bump(t, at: 1.45, width: 0.35)
        let lean = (30 + 6 * bob) * e
        var p = idle(t)
        // 从胯开始整个上身往右歪（胯也跟着歪一点），胯往左让、压低一点，两只脚才都钉得住。
        p.hips += SIMD3(Float(0.042 * e), Float(-0.014 * e), 0)
        p.rotations["hips"] = qz(0.15 * lean) * p.rotation("hips")
        p.rotations["spine"] = qz(0.4 * lean) * qy(-8 * e) * p.rotation("spine")
        p.rotations["chest"] = qz(0.35 * lean) * p.rotation("chest")
        p.rotations["neck"] = qz(0.1 * lean) * p.rotation("neck")
        // 头往回摆正一半：探出去的是身子，头只歪 15° 上下（长头发不甩成一整片）。
        p.rotations["head"] = qz(-0.45 * lean) * qy(-18 * e) * qx(-4 * e) * p.rotation("head")
        p.arm(.right, elevation: lerp(-72, -12, e), forward: lerp(6, 62, e), elbow: lerp(12, 108, e), twist: 10 * e)
        p.arm(.left, elevation: lerp(-72, -60, e), forward: lerp(6, -12, e), elbow: lerp(12, 24, e))
        p.hand(.left, .open, weight: 0.5 * e)
        p.expressions["surprised"] = Float(0.3 * e)
        return p
    }

    // MARK: - 第三批：脚尖 / 脚跟离地时的钉脚

    /// 钉脚的变体：踝的目标从静止位置挪开 ankle（规范化空间，模型单位），脚掌再转 toe 度（正 = 脚尖朝下、脚跟抬起）。
    /// 踮脚、前掌蹭地、脚尖点地用；ankle 由 `ankleLift` 算，前脚掌（或脚跟）就留在地上。
    static func plantFoot(_ p: inout VRMPose, body: VRMBody, side: VRMSide, ankle: SIMD3<Float>, toe: Double) {
        var shifted = p
        shifted.hips -= ankle
        plantFeet(&shifted, body: body, sides: [side])
        p.rotations[side.name + "UpperLeg"] = shifted.rotation(side.name + "UpperLeg")
        p.rotations[side.name + "LowerLeg"] = shifted.rotation(side.name + "LowerLeg")
        p.rotations[side.name + "Foot"] = shifted.rotation(side.name + "Foot") * qx(toe)
    }

    /// 脚掌绕前脚掌（toe > 0，脚跟抬起）或脚跟（toe < 0，脚尖翘起）转 toe 度时，踝从静止位置挪了多少。
    /// 踝高从模型量；前脚掌、脚跟到踝的水平距离按腿长估（VRoid 实测前脚掌约 0.16 腿长、脚跟约 0.06）。
    static func ankleLift(toe: Double, body: VRMBody) -> SIMD3<Float> {
        let leg = body.thigh + body.shin
        let a = Float(toe * .pi / 180)
        let pivot = toe >= 0 ? 0.16 * leg : -0.06 * leg
        return SIMD3(0, body.ankle * (cosf(a) - 1) + pivot * sinf(a), body.ankle * sinf(a) + pivot * (1 - cosf(a)))
    }
}

/// 量出来的身体尺寸（模型单位，VRM 原点在脚底）：跪坐 / 下蹲时算 hips 该降多少，膝盖和脚才刚好着地。
struct VRMBody {
    var hipsHeight: Float = 0.65
    /// hips 关节比大腿根（upperLeg）高多少。
    var hipToLeg: Float = 0.03
    var thigh: Float = 0.25
    var shin: Float = 0.28
    /// 站立时踝关节离地高度。
    var ankle: Float = 0.08
    /// 左腿根、左踝相对 hips 的静止位置（规范化空间；右边按 x 取反）。
    var legOffset = SIMD3<Float>(0.06, -0.03, 0)
    var ankleRest = SIMD3<Float>(0.06, -0.57, 0)

    /// 大腿前抬 swing 度、屈膝 knee 度时，hips 离地多高：脚（小腿竖着时踩地、躺平时脚背贴地）与膝盖都不低于地面。
    func groundedHips(swing: Double, knee: Double) -> Float {
        let thighAngle = Float(swing * .pi / 180)
        let shinAngle = Float((swing - knee) * .pi / 180)
        let kneeY = -thigh * cos(thighAngle)
        let ankleY = kneeY - shin * cos(shinAngle)
        let ankleClearance = max(0.045, ankle * cos(shinAngle))
        return hipToLeg + max(ankleClearance - ankleY, 0.05 - kneeY)
    }
}

// MARK: - 摆姿势的小工具（规范化空间：+X 人物左手边、+Y 上、+Z 人物正前方）

enum VRMSide {
    case left, right

    var sign: Double { self == .left ? 1 : -1 }
    var name: String { self == .left ? "left" : "right" }
}

/// 手势（各指三节的弯曲角度，度）。
enum VRMHand {
    case relaxed, open, fist, peace, point

    struct Curls {
        var fingers: [String: [Double]]
        var spread: [String: Double] = [:]
        var thumb: Double
    }

    var curls: Curls {
        let curled = [75.0, 95, 60]
        switch self {
        case .relaxed:
            return Curls(fingers: ["Index": [8, 12, 8], "Middle": [12, 16, 10], "Ring": [16, 20, 12], "Little": [20, 22, 14]],
                         thumb: 12)
        case .open:
            return Curls(fingers: ["Index": [0, 0, 0], "Middle": [0, 0, 0], "Ring": [0, 0, 0], "Little": [0, 0, 0]],
                         spread: ["Index": 6, "Ring": -4, "Little": -8], thumb: 0)
        case .fist:
            return Curls(fingers: ["Index": curled, "Middle": curled, "Ring": curled, "Little": curled], thumb: 45)
        case .peace:
            return Curls(fingers: ["Index": [0, 0, 0], "Middle": [0, 0, 0], "Ring": curled, "Little": curled],
                         spread: ["Index": 9, "Middle": -7], thumb: 45)
        case .point:
            return Curls(fingers: ["Index": [0, 0, 0], "Middle": curled, "Ring": curled, "Little": curled], thumb: 40)
        }
    }
}

private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

private func radians(_ degrees: Double) -> Float {
    Float(degrees * .pi / 180)
}

/// 绕 X：正 = 朝上的骨骼往前倾（低头 / 弯腰），朝下的骨骼往后摆。
private func qx(_ degrees: Double) -> simd_quatf {
    simd_quatf(angle: radians(degrees), axis: SIMD3(1, 0, 0))
}

/// 绕 Y：正 = 转向人物左边。
private func qy(_ degrees: Double) -> simd_quatf {
    simd_quatf(angle: radians(degrees), axis: SIMD3(0, 1, 0))
}

/// 绕 Z：正 = 朝上的骨骼往人物右边歪，左臂往上抬。
private func qz(_ degrees: Double) -> simd_quatf {
    simd_quatf(angle: radians(degrees), axis: SIMD3(0, 0, 1))
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

private func smooth(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// from 到 to 之间平滑地从 0 升到 1。
private func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
    to > from ? smooth((t - from) / (to - from)) : (t >= to ? 1 : 0)
}

/// 0 → 1 → 0：开头 rise 秒升满，最后 fall 秒落回。
private func envelope(_ t: Double, _ duration: Double, rise: Double, fall: Double) -> Double {
    min(ramp(t, 0, rise), 1 - ramp(t, duration - fall, duration))
}

/// 以 center 为中心、宽 width 的一个 0 → 1 → 0 鼓包。
private func bump(_ t: Double, at center: Double, width: Double) -> Double {
    let x = abs(t - center) / (width / 2)
    return x >= 1 ? 0 : smooth(1 - x)
}

extension VRMPose {
    func rotation(_ bone: String) -> simd_quatf {
        rotations[bone] ?? identity
    }

    /// pitch 正 = 往前弯 / 低头，yaw 正 = 转向人物左边，roll 正 = 往人物右边歪。
    mutating func bend(_ bone: String, pitch: Double = 0, yaw: Double = 0, roll: Double = 0) {
        rotations[bone] = qy(yaw) * qx(pitch) * qz(roll)
    }

    /// 上臂指向：elevation 仰角（−90 垂直向下、0 平伸、正往上），forward 往前摆（负 = 往后）；elbow 肘弯；
    /// twist 上臂绕自身转（正 = 内旋：弯肘时小臂往身体中线收，双手才能在身前 / 身后合拢、叉到腰上）。
    mutating func arm(_ side: VRMSide, elevation: Double, forward: Double = 0, elbow: Double = 0, twist: Double = 0) {
        let e = radians(elevation)
        let a = radians(forward)
        let s = Float(side.sign)
        let direction = simd_normalize(SIMD3(s * cos(e) * cos(a), sin(e), cos(e) * sin(a)))
        rotations[side.name + "UpperArm"] = simd_quatf(from: SIMD3(s, 0, 0), to: direction) * qx(twist)
        rotations[side.name + "LowerArm"] = qy(-side.sign * elbow)
    }

    /// 手势：weight 0 = 自然微屈，1 = 完全是这个手势（中间线性过渡）。
    /// 手指在 T 字姿势里沿 ±X 伸、掌心朝下：往掌心弯 = 绕 Z（左右符号相反）；拇指朝前，往掌心收 = 绕 X。
    mutating func hand(_ side: VRMSide, _ shape: VRMHand, weight: Double = 1) {
        let relaxed = VRMHand.relaxed.curls
        let target = shape.curls
        let w = min(max(weight, 0), 1)
        for (finger, angles) in target.fingers {
            let base = relaxed.fingers[finger] ?? angles
            let curl = (0..<3).map { base[$0] + (angles[$0] - base[$0]) * w }
            let spread = (relaxed.spread[finger] ?? 0) + ((target.spread[finger] ?? 0) - (relaxed.spread[finger] ?? 0)) * w
            let prefix = side.name + finger
            rotations[prefix + "Proximal"] = qz(-side.sign * curl[0]) * qy(-side.sign * spread)
            rotations[prefix + "Intermediate"] = qz(-side.sign * curl[1])
            rotations[prefix + "Distal"] = qz(-side.sign * curl[2])
        }
        let thumb = relaxed.thumb + (target.thumb - relaxed.thumb) * w
        let prefix = side.name + "Thumb"
        rotations[prefix + "Metacarpal"] = qx(thumb * 0.5)
        rotations[prefix + "Proximal"] = qx(thumb * 0.5)
        rotations[prefix + "Intermediate"] = qx(thumb * 0.6)
        rotations[prefix + "Distal"] = qx(thumb * 0.6)
    }

    /// 小臂往上竖（挥手）；forward = 同时往前弯一点。
    mutating func forearmUp(_ side: VRMSide, _ degrees: Double, forward: Double = 0) {
        rotations[side.name + "LowerArm"] = qz(side.sign * degrees) * qy(-side.sign * forward)
    }

    /// swing 大腿往前抬（度），knee 屈膝（小腿往后），foot 正 = 脚尖朝下，spread 往外张。
    mutating func leg(_ side: VRMSide, swing: Double, knee: Double = 0, foot: Double = 0, spread: Double = 0) {
        rotations[side.name + "UpperLeg"] = qz(side.sign * spread) * qx(-swing)
        rotations[side.name + "LowerLeg"] = qx(knee)
        rotations[side.name + "Foot"] = qx(foot)
    }

    /// 耸肩（度）。
    mutating func shrug(_ degrees: Double) {
        rotations["leftShoulder"] = qz(degrees)
        rotations["rightShoulder"] = qz(-degrees)
    }
}
