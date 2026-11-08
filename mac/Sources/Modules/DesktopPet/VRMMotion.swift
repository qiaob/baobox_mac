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

    /// 跳（近的地方）：引擎按阶段切片段、按抛物线挪窗口。长度以身高为单位（身高 = VRMBody.height，取景时缩放到 1.26 的那个高度）。
    /// 重力 jumpGravity（身高 / 秒²，比真的略小一点，空中多停一会儿）；横向全程匀速，竖向抛物线。
    /// 单跳：最高点比起点、终点里高的那个再高 jumpApex。落差超过约一个身高用二段跳：第一段最高点比起点高 doubleJumpFirstApex，
    /// 到第一段最高点（竖直速度为 0）时播 jump_spin、从那儿再起一段，第二段最高点比终点高 doubleJumpSecondApex。
    /// 往下跳（hop）：最高点比起点高 hopApex，再落到终点。二段跳最多到约 1.5 个身高，再高就用助推器飞。
    static let jumpGravity = 5.8
    static let jumpApex = 0.22
    static let doubleJumpFirstApex = 0.62
    static let doubleJumpSecondApex = 0.24
    static let hopApex = 0.13
    /// 蓄力片段播到最后一帧正好离地（jump_crouch / hop_crouch 的时长）；boost_crouch 在 boostLiftoff 秒离地。
    static let jumpCrouchDuration = 0.39
    static let hopCrouchDuration = 0.27
    static let boostCrouchDuration = 0.55
    static let boostLiftoff = 0.42
    /// jump_spin：开头 0.07 s 在空中往下蹬一下，0.06–0.56 s 转一圈，到 0.7 s 打开成下落的姿势。
    static let jumpSpinDuration = 0.7
    /// 离落地还有多少秒开始播 jump_reach / boost_brake（腿先往下伸，播完停在最后一帧，落地接 jump_land）。
    static let jumpReachLead = 0.26
    static let boostBrakeLead = 0.37
    /// fly / fly_down 一个浮动周期。
    static let flyCycle = 2.4

    /// 跑步（`run`）：一个周期左右各一步；runSwing = 着地、离地时腿与竖直线的夹角（度），
    /// runStance = 一只脚着地占周期的比例（小于 0.5，两步之间有腾空）。
    static let runCycle = 0.7
    static let runSwing = 20.0
    static let runStance = 0.36

    /// 跑步时身体每秒前进多少（模型单位）：着地那段时间里，脚从 hips 前方 腿长·sin(runSwing) 匀速滑到后方同样远。
    static func runGroundSpeed(body: VRMBody) -> Float {
        let leg = body.thigh + body.shin
        return 2 * leg * sinf(Float(runSwing * .pi / 180)) / Float(runStance * runCycle)
    }

    /// 喝水 / 吃东西站着捧杯（片段名沿用健康提醒与互动认的 sit_down / sit_hold_drink / stand_up：捧起 → 喝两口 → 放下）。
    /// 睡觉（2026-11-08 起）：侧身坐到地上、双手抱膝、头歪着闭眼（`hugKnees`）；正对镜头会看到裙底，
    /// 所以睡着时宠物视图把人固定侧过去（PetModelView.sleepYaw）。最早是站着打盹（`dozing`，现在不用了）。
    static func definitions(body: VRMBody) -> [Definition] {
        let both: [VRMSide] = [.left, .right]
        return [
            Definition(name: "idle", duration: 4, plant: both, pose: idle),
            Definition(name: "walk", duration: walkCycle, pose: walk),
            Definition(name: "wave", duration: 2.6, plant: both, pose: wave),
            Definition(name: "bye", duration: 0.55, plant: both, pose: bye),
            // 腿由片段自己摆（先蹲、再坐到地上抱膝），不钉脚。起身是坐下倒着播（眼睛先睁开）。
            Definition(name: "sleep", duration: sleepDownDuration) { t in sleepDown(t, body: body) },
            Definition(name: "get_up", duration: 2.0) { t in sleepDown(sleepDownDuration * (1 - t / 2.0), body: body) },
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
            // 移动：跑步；上下挪位置 —— 近的跳，远的、高的背助推器飞（时长、离地时刻、轨迹参数见 jump* / boost* 常量）。
            // 引擎按阶段一段段切换、按轨迹挪窗口，每段单独播：脚由片段自己钉（plantFeet / plantFoot），不在 plant 里。
            Definition(name: "run", duration: runCycle) { t in run(t, body: body) },
            Definition(name: "jump_crouch", duration: jumpCrouchDuration) { t in jumpCrouchClip(t, body: body, hop: false) },
            Definition(name: "jump_rise", duration: 0.9, pose: jumpAir),
            Definition(name: "jump_fall", duration: 0.8, pose: jumpFallPose),
            Definition(name: "jump_spin", duration: jumpSpinDuration, pose: jumpSpinClip),
            Definition(name: "jump_reach", duration: jumpReachLead, pose: jumpReachClip),
            Definition(name: "jump_land", duration: 0.7) { t in jumpLand(t, t: t, body: body, strength: 1.1) },
            Definition(name: "hop_crouch", duration: hopCrouchDuration) { t in jumpCrouchClip(t, body: body, hop: true) },
            Definition(name: "hop_fall", duration: 0.8, pose: hopFall),
            Definition(name: "boost_crouch", duration: boostCrouchDuration) { t in boostCrouchClip(t, body: body) },
            Definition(name: "fly", duration: flyCycle) { t in flying(t, lean: 14, tuck: 1) },
            Definition(name: "fly_down", duration: flyCycle) { t in flying(t, lean: 3, tuck: 0.45) },
            Definition(name: "boost_brake", duration: boostBrakeLead, pose: boostBrakeClip),
            // 蹲、坐地（引擎的「歇脚」：坐下 → 坐着循环 → 起身）。坐下停在最后一帧，接循环的第一帧；起身从循环的姿势出发。
            // 蹲着这三段 2026-11-08 起歇脚不用了（用户嫌丑），片段留着；squatting 仍是睡下、坐地蹲下去的前半段。
            Definition(name: "squat_down", duration: 0.9) { t in squatting(0, body: body, depth: smooth(t / 0.9)) },
            Definition(name: "squat", duration: 3.2) { t in squatting(t, body: body, depth: 1) },
            Definition(name: "squat_up", duration: 0.8) { t in squatting(0, body: body, depth: 1 - smooth(t / 0.8)) },
            Definition(name: "sit_ground_down", duration: 1.6) { t in sitGroundDown(t, body: body) },
            Definition(name: "sit_ground", duration: 4.0) { t in sittingGround(t, body: body) },
            Definition(name: "sit_ground_up", duration: 1.4) { t in sitGroundDown(1.6 * (1 - t / 1.4), body: body) },
        ]
    }

    static func clips(for rig: VRMRig) -> [String: GLTFClip] {
        var out: [String: GLTFClip] = [:]
        // 动捕走路（VRMMocap）和程序化动作一样采样成动画。
        for definition in definitions(body: rig.body) + VRMMocap.definitions(body: rig.body) {
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
        // 裙片（假布料）：每个片段都带，不抬腿时就是静止朝向，片段之间淡入淡出裙子不会跳。
        if !rig.skirt.isEmpty {
            let skirtPoses = poses.map { skirtRotations($0, rig: rig) }
            for (index, panel) in rig.skirt.enumerated() {
                var previous: simd_quatf?
                let values: [NSValue] = skirtPoses.map { rotations in
                    var q = rig.localRotation(panel.bone, rotations[index])
                    if let previous, simd_dot(previous.vector, q.vector) < 0 { q = simd_quatf(vector: -q.vector) }
                    previous = q
                    return NSValue(scnVector4: SCNVector4(CGFloat(q.imag.x), CGFloat(q.imag.y), CGFloat(q.imag.z), CGFloat(q.real)))
                }
                add(panel.bone.node, "orientation", values)
            }
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

    // MARK: - 假布料：裙片跟着大腿翻

    /// 每条裙片根骨骼此刻的旋转（规范化空间，相对它的人形父骨骼；顺序同 `rig.skirt`）。
    /// 裙片默认竖直往下垂（人直立时按重力，不跟着胯前倾后仰；趴着、躺着时跟着胯）；
    /// 哪条大腿往裙片那个方向抬（往前抬 → 前片，往外张 → 侧片，往后踢 → 后片），裙片就被推着往那边翻，
    /// 比大腿多翻一点（腿有厚度），所以抬腿、蹲、坐时前片盖在大腿上，后片、侧片垂下来挡住屁股和胯两侧。
    /// 坐到地上时，裙片末端碰到地面就顺着地面往外摊开，不扎进地里。不抬腿时就是静止朝向。
    static func skirtRotations(_ p: VRMPose, rig: VRMRig) -> [simd_quatf] {
        let body = rig.body
        let hipsRotation = p.rotation("hips")
        let hipsJoint = SIMD3<Float>(0, body.hipsHeight, 0) + p.hips
        let down = SIMD3<Float>(0, -1, 0)
        // 垂的参照系：直立时只保留胯的朝向（绕竖直轴转了多少），躺倒时整个跟着胯。
        let facing = hipsRotation.act(SIMD3<Float>(0, 0, 1))
        let level = simd_quatf(angle: atan2f(facing.x, facing.z), axis: SIMD3<Float>(0, 1, 0))
        let upright = hipsRotation.act(SIMD3<Float>(0, 1, 0)).y
        let frame = simd_slerp(hipsRotation, level, Float(smooth((Double(upright) - 0.5) / 0.35)))
        let toFrame = frame.inverse * hipsRotation
        var thighs: [(sign: Double, rest: SIMD3<Float>, now: SIMD3<Float>)] = []
        for side in [VRMSide.left, .right] {
            let mirror = SIMD3<Float>(side == .left ? 1 : -1, 1, 1)
            let rest = simd_normalize((body.kneeRest - body.legOffset) * mirror)
            thighs.append((side.sign, rest, toFrame.act(p.rotation(side.name + "UpperLeg").act(rest))))
        }
        let floor = 0.012 * body.height
        return rig.skirt.map { panel in
            var parentRotation = hipsRotation
            var anchor = SIMD3<Float>(0, 0, 0)
            if panel.parent != "hips" {
                anchor = body.legOffset * SIMD3<Float>(panel.parent == "leftUpperLeg" ? 1 : -1, 1, 1)
                parentRotation = hipsRotation * p.rotation(panel.parent)
            }
            let placed = toFrame.act(anchor + panel.offset)
            let flat = SIMD3<Float>(placed.x, 0, placed.z)
            guard simd_length(flat) > 1e-4 else { return parentRotation.inverse * frame }
            let outward = simd_normalize(flat)
            var push = 0.0
            for thigh in thighs {
                // 裙片在这条腿这一侧（含正前、正后）全额，偏到另一侧就不管。
                let weight = smooth((Double(outward.x) * thigh.sign + 0.7) / 0.7)
                push = max(push, weight * max(0, lean(thigh.now, toward: outward) - lean(thigh.rest, toward: outward)))
            }
            // 连着前片的布料被抬起的大腿往前带：侧片跟着大腿抬的方向翻一半，越靠正侧面带得越多，后片不带。
            var drag = 0.0
            var dragAxis = SIMD3<Float>(1, 0, 0)
            for thigh in thighs {
                let level = SIMD3<Float>(thigh.now.x, 0, thigh.now.z)
                guard simd_length(level) > 0.05 else { continue }
                let heading = simd_normalize(level)
                let facing = Double(simd_dot(heading, outward))
                guard facing > -0.3 else { continue }
                let weight = smooth((Double(outward.x) * thigh.sign + 0.7) / 0.7) * 0.5 * (1 - facing * facing)
                let lift = (Double(acosf(min(max(-thigh.now.y, -1), 1))) - Double(acosf(min(max(-thigh.rest.y, -1), 1)))) * 180 / .pi
                if weight * lift > drag {
                    drag = weight * lift
                    dragAxis = simd_normalize(simd_cross(down, heading))
                }
            }
            let dragged = simd_quatf(angle: radians(drag), axis: dragAxis)
            var tilt = push + 6 * smooth(push / 30)
            let axis = simd_normalize(simd_cross(down, outward))
            let root = hipsJoint + hipsRotation.act(anchor) + parentRotation.act(panel.offset)
            func tipHeight(_ angle: Double) -> Float {
                (root + (frame * dragged * simd_quatf(angle: radians(angle), axis: axis)).act(panel.direction * panel.length)).y
            }
            if upright > 0.7 {
                while tilt < 110, tipHeight(tilt) < floor, tipHeight(tilt + 4) > tipHeight(tilt) { tilt += 4 }
            }
            return parentRotation.inverse * frame * dragged * simd_quatf(angle: radians(tilt), axis: axis)
        }
    }

    /// 方向 d 往水平方向 a 偏了多少度：在 a 与竖直线所在的平面里量，再按 d 的水平分量里朝 a 的比例打折 ——
    /// 往前平伸的大腿对前片算 90°（抬过水平再往上就超过 90°），对侧片只算它往外张的那一点。
    private static func lean(_ d: SIMD3<Float>, toward a: SIMD3<Float>) -> Double {
        let along = Double(simd_dot(d, a))
        let horizontal = Double(simd_length(SIMD3<Float>(d.x, 0, d.z)))
        let share = horizontal < 1e-3 ? 1 : min(max(along / horizontal, 0), 1)
        return atan2(along, Double(-d.y)) * 180 / .pi * share
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

    /// 站着打盹（2026-11-08 前睡觉的最后一帧，现在睡觉改成坐地抱膝 `hugKnees`，保留备用）：低头、头歪向一边、肩膀和手臂松下来、膝盖微屈，闭眼。
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

    /// 睡觉的最后一帧（场景随后暂停）：侧身坐在地上抱膝打盹 —— 屁股着地、胯往后靠，两条大腿抬得很陡、膝盖并拢，
    /// 小腿收回来脚掌踩地，两臂环住膝盖、手搭在膝头；上身只微微前倾，头歪向一边（往右肩靠、脸往右转 32°：侧过去时脸朝着镜头，不被头发挡住），闭眼。
    /// 头发没有物理：上身 + 头加起来前倾太多（超过约 30°），双马尾会整片横着翘出去，所以不把头埋到膝盖上。
    /// 角度是用 three.js + three-vrm 照这份代码移植后，对着两个模型逐个方向渲染调出来的（正面能看到裙底，靠侧身挡）。
    static func hugKnees(body: VRMBody) -> VRMPose {
        var p = stand()
        p.hips.y = 0.095 * body.height - body.hipsHeight
        let pelvis = qx(-14)
        p.rotations["hips"] = pelvis
        for side in [VRMSide.left, .right] {
            // 大腿往前上抬到与竖直向下成 154°（胯往后靠了 14°，所以局部只转 140°），膝盖往里并拢 ——
            // 并得不够时大腿下面露出一小条裙底（凍香，侧转 1 弧度时）。
            let thigh = qy(-side.sign * 9) * qx(-140)
            let knee = qx(128)
            p.rotations[side.name + "UpperLeg"] = thigh
            p.rotations[side.name + "LowerLeg"] = knee
            p.rotations[side.name + "Foot"] = (pelvis * thigh * knee).inverse
            p.arm(side, elevation: -38, forward: 72, elbow: 72, twist: 40)
        }
        p.bend("spine", pitch: 16)
        p.bend("chest", pitch: 10)
        p.bend("neck", pitch: 4)
        p.bend("head", pitch: 6, yaw: -32, roll: 18)
        p.shrug(-2)
        p.expressions["blink"] = 1
        return p
    }

    /// 睡下（sleepDownDuration 秒，播完停住）：先蹲下去，再坐到地上抱住膝盖，最后闭眼。
    static let sleepDownDuration = 2.4
    static func sleepDown(_ t: Double, body: VRMBody) -> VRMPose {
        let crouch = squatting(0, body: body, depth: 0.8 * smooth(t / 0.9))
        var p = blend(crouch, hugKnees(body: body), smooth((t - 0.7) / 1.4))
        p.expressions["blink"] = Float(ramp(t, 1.4, 2.3))
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

    // MARK: - 第三批：移动（跑步）

    /// 跑步（循环）：身子前倾，手臂弯 90° 前后大幅摆，步子大，两步之间腾空，身子一颠一颠。
    /// 着地的那只脚在窗口里从 hips 前方匀速滑到后方（runGroundSpeed），宠物窗按这个速度挪，脚踩在地上不打滑。
    static func run(_ t: Double, body: VRMBody) -> VRMPose {
        let leg = body.thigh + body.shin
        let reach = leg * sinf(Float(runSwing * .pi / 180))
        let cycle = t / runCycle
        var p = stand()
        // 着地中段最低，腾空最高。
        let bounce = -cos(4 * Double.pi * (cycle - runStance / 2))
        let swing = cos(2 * Double.pi * cycle)   // 正 = 左脚在前（右臂往前）
        p.hips.y = -0.1 * leg + Float(0.045 * bounce) * leg
        p.bend("hips", pitch: 5, yaw: -5 * swing)
        p.bend("spine", pitch: 9, yaw: 4 * swing)
        p.bend("chest", pitch: 4, yaw: 4 * swing)
        p.bend("head", pitch: -6, yaw: -4 * swing)
        for side in [VRMSide.left, .right] {
            let forward = -side.sign * swing   // 与同侧腿反向
            p.arm(side, elevation: -66, forward: 12 + 40 * forward, elbow: 88 + 10 * forward, twist: 15)
            p.hand(side, .fist, weight: 0.6)
        }
        for (side, offset) in [(VRMSide.left, 0.0), (.right, 0.5)] {
            let u = (cycle + offset) - floor(cycle + offset)
            var ankle = SIMD3<Float>(0, 0, 0)
            let toe: Double
            if u < runStance {
                // 着地：脚从前往后匀速滑（= 地面相对身体往后走），后半段脚跟抬起、前脚掌蹬地。
                let k = u / runStance
                ankle.z = reach * Float(1 - 2 * k)
                toe = lerp(-6, 26, smooth((k - 0.35) / 0.65))
            } else {
                // 腾空 + 摆腿：脚跟往上收、膝盖往前带，再伸出去着地。
                let s = (u - runStance) / (1 - runStance)
                ankle.z = -reach * Float(cos(Double.pi * s))
                ankle.y = 0.24 * leg * Float(pow(sin(Double.pi * s), 1.2))
                toe = lerp(26, -6, smooth(s))
            }
            plantFoot(&p, body: body, side: side, ankle: ankle + ankleLift(toe: toe, body: body), toe: toe)
        }
        return p
    }

    // MARK: - 第三批：上下挪位置 —— 跳（近的）、背助推器飞（远的、高的）

    /// 起跳前蹲下蓄力：膝盖弯、屁股往后坐、上身往前压，两臂往后甩，抬头看要去的地方。k = 0 站着，1 蹲到底；deep 往下跳时只蹲一半。
    static func jumpCrouch(_ t: Double, body: VRMBody, k: Double, deep: Double = 1) -> VRMPose {
        let leg = body.thigh + body.shin
        var p = idle(t)
        p.hips += SIMD3(0, Float(-0.15 * deep * k) * leg, Float(-0.05 * deep * k) * leg)
        p.rotations["hips"] = qx(15 * deep * k) * p.rotation("hips")
        p.rotations["spine"] = qx(7 * k) * p.rotation("spine")
        p.rotations["head"] = qx(-18 * k) * p.rotation("head")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -48, k), forward: lerp(6, -48, k), elbow: lerp(12, 18, k))
            p.hand(side, .open, weight: 0.4 * k)
        }
        plantFeet(&p, body: body)
        p.expressions["happy"] = Float(0.5 * k)
        return p
    }

    /// 蹬地那一下：腿蹬直、脚尖绷着，两臂往前上方甩过头。
    static func jumpLaunch() -> VRMPose {
        var p = stand()
        p.bend("hips", pitch: 6)
        p.bend("spine", pitch: 2)
        p.bend("head", pitch: -12)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 2, knee: 4, foot: 34, spread: -1)
            p.arm(side, elevation: 52, forward: 32, elbow: 14)
            p.hand(side, .open, weight: 0.8)
        }
        p.expressions["happy"] = 0.9
        return p
    }

    /// jump_crouch / hop_crouch（一次性，播到最后一帧正好离地）：慢慢蹲下（最后停一下），再很快蹬直 ——
    /// 脚跟先抬、前脚掌最后离地，窗口这时还没动。往下跳（hop）蹲得浅、蹬得快。
    static func jumpCrouchClip(_ t: Double, body: VRMBody, hop: Bool) -> VRMPose {
        let crouch = hop ? 0.2 : 0.3
        let launch = hop ? hopCrouchDuration - 0.2 : jumpCrouchDuration - 0.3
        let deep = hop ? 0.5 : 1.0
        if t < crouch {
            return jumpCrouch(t, body: body, k: smooth(t / (crouch * 0.85)), deep: deep)
        }
        let k = smooth((t - crouch) / launch)
        var p = blend(jumpCrouch(t, body: body, k: 1, deep: deep), jumpLaunch(), k)
        let toe = 30 * k
        let lift = ankleLift(toe: toe, body: body)
        p.hips.y = Float(1 - k) * p.hips.y + lift.y * Float(k)
        for side in [VRMSide.left, .right] {
            plantFoot(&p, body: body, side: side, ankle: lift, toe: toe)
        }
        return p
    }

    /// jump_rise（循环 0.9 s）：往上飞，腿收起来（膝盖往前上提、小腿往后折，一条腿收得多一点），两臂往上张开。
    static func jumpAir(_ t: Double) -> VRMPose {
        let s = sin(2 * Double.pi * t / 0.9)
        var p = stand()
        p.bend("hips", pitch: 4)
        p.bend("spine", pitch: -2)
        p.bend("head", pitch: -8)
        p.leg(.left, swing: 38 + 3 * s, knee: 82, foot: 18)
        p.leg(.right, swing: 26 - 3 * s, knee: 92, foot: 22)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: 34 + 4 * s * side.sign, forward: 18, elbow: 22)
            p.hand(side, .open, weight: 0.8)
        }
        p.expressions["happy"] = 1
        return p
    }

    /// jump_fall（循环 0.8 s）：往下落，腿还收着一点、两臂往两边张开稳住，低头看落脚的地方。
    static func jumpFallPose(_ t: Double) -> VRMPose {
        let s = sin(2 * Double.pi * t / 0.8)
        var p = stand()
        p.bend("hips", pitch: 3)
        p.bend("head", pitch: 8)
        p.leg(.left, swing: 22 + 3 * s, knee: 50, foot: 18)
        p.leg(.right, swing: 16 - 3 * s, knee: 58, foot: 20)
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: 8 + 4 * s * side.sign, forward: 12, elbow: 20)
            p.hand(side, .open, weight: 0.7)
        }
        p.expressions["happy"] = 0.8
        return p
    }

    /// 二段跳在空中再蹬一下：腿往下猛地一伸，两臂往下甩。
    static func jumpKick() -> VRMPose {
        var p = stand()
        p.bend("hips", pitch: 2)
        p.bend("head", pitch: -10)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: -6 + 8 * side.sign, knee: 10, foot: 36)
            p.arm(side, elevation: -40, forward: -24, elbow: 16)
            p.hand(side, .open, weight: 0.6)
        }
        p.expressions["happy"] = 1
        return p
    }

    /// 二段跳在空中转一圈（绕竖直轴，spin 0 → 1 = 0° → 360°）：两臂收在胸前、两腿并拢微屈，像花样滑冰的旋转。
    /// 不抱膝团身：大腿抬到胸前时两个模型都会从胯两侧露出裙底；也不往前翻（倒过来时略俯视的镜头会看进裙子里）。
    static func jumpSpin(_ spin: Double) -> VRMPose {
        var p = stand()
        p.bend("hips", yaw: 360 * spin)
        p.bend("spine", pitch: 2)
        p.bend("head", pitch: -6)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 18 - 6 * side.sign, knee: 36 + 10 * side.sign, foot: 30, spread: -3)
            p.arm(side, elevation: -48, forward: 72, elbow: 112, twist: 58)
            p.hand(side, .fist, weight: 0.5)
        }
        p.expressions["happy"] = 1
        return p
    }

    /// jump_spin（一次性 jumpSpinDuration）：第一段最高点开始播。0–0.07 s 腿往下一蹬（脚下该冒一圈气浪），
    /// 0.06–0.56 s 收手并腿转一圈（先慢后快再慢），之后打开成下落的姿势。
    static func jumpSpinClip(_ t: Double) -> VRMPose {
        let spin = smooth((t - 0.06) / 0.5)
        let kick = blend(jumpAir(t), jumpKick(), smooth(t / 0.07))
        let turning = blend(kick, jumpSpin(spin), smooth((t - 0.06) / 0.1))
        return blend(turning, jumpFallPose(t), smooth((t - 0.52) / 0.18))
    }

    /// 快落地：腿先往下伸（膝盖还留一点弯）、脚尖略朝下，两臂往两边张开稳住，低头看落脚点。
    static func jumpReach() -> VRMPose {
        var p = stand()
        p.bend("hips", pitch: -2)
        p.bend("spine", pitch: 2)
        p.bend("head", pitch: 10)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 8, knee: 14, foot: 14, spread: 2)
            p.arm(side, elevation: -6, forward: 10, elbow: 14)
            p.hand(side, .open, weight: 0.7)
        }
        p.expressions["happy"] = 0.6
        return p
    }

    /// jump_reach（jumpReachLead 秒，停在最后一帧）：离落地还有 jumpReachLead 秒开始播，腿从收着伸到快站直。
    static func jumpReachClip(_ t: Double) -> VRMPose {
        blend(jumpFallPose(t), jumpReach(), smooth(t / 0.16))
    }

    /// hop_fall（循环 0.8 s）：往下跳的空中，身子直、腿并拢微屈，手臂往两边轻轻张开，像轻轻落下去。
    static func hopFall(_ t: Double) -> VRMPose {
        let s = sin(2 * Double.pi * t / 0.8)
        var p = stand()
        p.bend("hips", pitch: 2)
        p.bend("head", pitch: 6)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: 10 + 2 * s * side.sign, knee: 20, foot: 20, spread: -1)
            p.arm(side, elevation: 4 + 4 * s, forward: 6, elbow: 18)
            p.hand(side, .open, weight: 0.6)
        }
        p.expressions["happy"] = 0.7
        return p
    }

    /// jump_land（0.7 s，一次性，最后一帧就是 idle）：u = 落地以后过了多少秒。脚钉在地上，屈膝一沉很快、站起来慢；
    /// 手臂跟着往下甩再回来，头点一下。strength = 摔得多重。跳和飞落地都用它。
    static func jumpLand(_ u: Double, t: Double, body: VRMBody, strength: Double) -> VRMPose {
        let leg = body.thigh + body.shin
        let down = smooth(u / 0.08) * (1 - smooth((u - 0.1) / 0.4))
        let arms = smooth(u / 0.12) * (1 - smooth((u - 0.2) / 0.45))
        let breath = sin(2 * Double.pi * t / 4)   // 和 idle 一样带呼吸，最后一帧才正好接上 idle
        var p = idle(t)
        p.hips += SIMD3(0, Float(-0.13 * strength * down) * leg, Float(-0.03 * strength * down) * leg)
        p.rotations["hips"] = qx(16 * strength * down) * p.rotation("hips")
        p.rotations["spine"] = qx(8 * strength * down) * p.rotation("spine")
        p.rotations["head"] = qx(8 * down - 3 * arms) * p.rotation("head")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72 + breath, -40, arms), forward: lerp(6, 22, arms), elbow: lerp(12, 24, arms))
            p.hand(side, .open, weight: 0.5 * arms)
        }
        plantFeet(&p, body: body)
        p.expressions["happy"] = Float(0.6 * (1 - smooth((u - 0.3) / 0.4)))
        return p
    }

    /// fly / fly_down（循环 flyCycle）：身子朝飞行方向前倾（lean 度），两腿并拢微屈悬着（tuck 1 = 膝盖弯 22° 左右，
    /// 0.45 = 慢慢降时腿伸得直一些），手臂略张开保持平衡，整个人上下轻轻浮。浮动是一个主频叠一个两倍频，升得慢、落得快一点；
    /// 腿和手比身子慢半拍（跟随），头最后。左右轻轻摇和上下浮同一个周期、错开相位，循环才接得上。
    static func flying(_ t: Double, lean: Double, tuck: Double) -> VRMPose {
        let phase = 2 * Double.pi * t / flyCycle
        func wave(_ delay: Double) -> Double { 0.65 * sin(phase - delay) + 0.3 * sin(2 * (phase - delay) + 0.8) }
        let body = wave(0)
        let legs = wave(0.9)
        let arms = wave(0.5)
        let head = wave(1.3)
        var p = stand()
        p.hips.y = Float(0.012 * body)
        p.bend("hips", pitch: lean * 0.45 + 1.5 * body, roll: 1.2 * sin(phase + 1.9))
        p.bend("spine", pitch: lean * 0.35 - 0.8 * body, roll: -1.5 * sin(phase + 2.3))
        p.bend("chest", pitch: lean * 0.2)
        p.bend("neck", pitch: -lean * 0.25)
        p.bend("head", pitch: -lean * 0.35 + 2.5 * head, roll: 2 * sin(phase + 3.1))
        for side in [VRMSide.left, .right] {
            let s = side.sign
            // 并拢（稍微往里收），一条腿略靠前一点，晃的时候脚尖朝下。
            p.leg(side, swing: (6 + 5 * legs) * tuck + s * 2.5, knee: (22 + 9 * legs) * tuck - s * 4 * tuck + 3,
                  foot: 24 + 8 * legs, spread: -2)
            p.arm(side, elevation: -46 + 5 * arms, forward: 10 - 3 * arms, elbow: 20 + 6 * arms, twist: -10)
            p.hand(side, .open, weight: 0.35)
        }
        p.expressions["happy"] = 0.35
        return p
    }

    /// 点火蓄力：脚踩着地，膝盖弯、身子往下沉、两臂往后甩，抬头看要去的方向。k = 0 站着，1 蹲到底。
    static func boostCrouch(_ t: Double, body: VRMBody, k: Double) -> VRMPose {
        let leg = body.thigh + body.shin
        var p = idle(t)
        p.hips += SIMD3(0, Float(-0.11 * k) * leg, Float(-0.03 * k) * leg)
        p.rotations["hips"] = qx(12 * k) * p.rotation("hips")
        p.rotations["spine"] = qx(6 * k) * p.rotation("spine")
        p.rotations["head"] = qx(-12 * k) * p.rotation("head")
        for side in [VRMSide.left, .right] {
            p.arm(side, elevation: lerp(-72, -58, k), forward: lerp(6, -28, k), elbow: lerp(12, 18, k))
        }
        plantFeet(&p, body: body)
        p.expressions["happy"] = Float(0.3 * k)
        return p
    }

    /// 助推器起飞那一下：腿蹬直、脚尖绷着，两臂往两边稍微抬起来。
    static func boostLaunch() -> VRMPose {
        var p = stand()
        p.bend("hips", pitch: 6)
        p.bend("spine", pitch: 4)
        p.bend("head", pitch: -10)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: -4, knee: 4, foot: 30, spread: -1)
            p.arm(side, elevation: -32, forward: 12, elbow: 16)
            p.hand(side, .open, weight: 0.5)
        }
        p.expressions["happy"] = 0.6
        return p
    }

    /// boost_crouch（一次性 boostCrouchDuration）：0.3 s 蹲到底、停一下，boostLiftoff 秒脚离地（窗口开始挪），蹬直后接 fly。
    static func boostCrouchClip(_ t: Double, body: VRMBody) -> VRMPose {
        if t < 0.4 { return boostCrouch(t, body: body, k: smooth(t / 0.3)) }
        return blend(boostCrouch(t, body: body, k: 1), boostLaunch(), smooth((t - 0.4) / 0.15))
    }

    /// 落地前：身子直起来（略往后靠），腿往下伸去够地面（extend 0 = 还收着，1 = 伸直），手臂往两边张开稳住。
    static func boostBrake(_ t: Double, extend k: Double) -> VRMPose {
        var p = idle(t)
        p.bend("hips", pitch: -3)
        p.bend("spine", pitch: -2)
        p.bend("head", pitch: 4)
        for side in [VRMSide.left, .right] {
            p.leg(side, swing: lerp(8, 3, k), knee: lerp(24, 6, k), foot: lerp(24, 12, k), spread: 1)
            p.arm(side, elevation: -32, forward: 14, elbow: 16)
            p.hand(side, .open, weight: 0.5)
        }
        p.expressions["happy"] = 0.3
        return p
    }

    /// boost_brake（boostBrakeLead 秒，停在最后一帧）：离落地还有 boostBrakeLead 秒开始播，腿先伸、身子直起来。
    static func boostBrakeClip(_ t: Double) -> VRMPose {
        boostBrake(t, extend: smooth(t / 0.3))
    }

    // MARK: - 第三批：蹲、坐地

    /// 蹲（depth 0 = 站着，1 = 蹲到底；循环时 t 带出轻晃）：脚掌踩平钉住，屁股往下往后坐到脚跟上方，
    /// 膝盖并拢、抬得比胯还高，上身往前趴在膝盖上，两臂环抱小腿。
    /// 膝盖高过胯，略俯视的相机看过去胯下被膝盖挡住；蹲到一半时（膝盖还没胯高）两手先按住裙子前面，
    /// 蹲稳了再换成抱膝 —— 起身倒过来，也是先按住裙子再站起来。
    static func squatting(_ t: Double, body: VRMBody, depth k: Double) -> VRMPose {
        let leg = body.thigh + body.shin
        let phase = 2 * Double.pi * t / 3.2
        let sway = sin(phase) * k
        // 先往后坐胯（胯前倾、屁股往后），再往下蹲：蹲下去一半时胯已经倾到位。
        let hinge = smooth(k / 0.55)
        var p = idle(t * 4 / 3.2)
        // 胯往前倾得多（38°）、腰往回收一点：上身前倾的总角度不变，但大腿和胯之间的夹角小一些 ——
        // 裙子上半截是蒙在胯和大腿上的，夹角一大，侧面腰下就被大腿扯开一道缝（3/4 侧面看得到）。
        p.hips += SIMD3(Float(0.012 * sway) * leg, Float(-0.74 * k) * leg, Float(-0.26 * hinge) * leg)
        p.rotations["hips"] = qz(-3 * sway) * qx(38 * hinge) * p.rotation("hips")
        p.rotations["spine"] = qz(3 * sway) * qx(-4 * hinge) * p.rotation("spine")
        p.rotations["chest"] = qx(10 * k) * p.rotation("chest")
        p.rotations["neck"] = qx(-8 * k) * p.rotation("neck")
        p.rotations["head"] = qz(7 * sin(phase + 0.6) * k) * qx(-24 * k) * p.rotation("head")
        let reach = smooth(k / 0.3)
        let hold = 1 - smooth((k - 0.9) / 0.1)
        for side in [VRMSide.left, .right] {
            // 按裙子：两手往前往中间伸，并在一起按住两腿中间的裙摆；抱膝：手肘垂在大腿外侧，小臂圈住小腿 ——
            // 手肘挡住胯两侧（3/4 侧面看得到的地方），小臂挡住两膝之间。这几个角度是对着两个模型逐帧扫出来的，改了要重扫。
            let elevation = lerp(-53, -72, hold), forward = lerp(58, 115, hold)
            let elbow = lerp(74, 30, hold), twist = lerp(68, 30, hold)
            p.arm(side, elevation: lerp(-72, elevation, reach), forward: lerp(6, forward, reach), elbow: lerp(12, elbow, reach),
                  twist: twist * reach)
        }
        plantFeet(&p, body: body)
        for side in [VRMSide.left, .right] { turnKnee(&p, body: body, side: side, angle: 9 * k + 6 * hold * reach) }
        return p
    }

    /// 坐地（ぺたん座り，循环 4 s）：屁股坐在地上，两条大腿往前平放、膝盖并拢，小腿往后往外折；
    /// 两臂伸直、双手搭在两腿中间的裙子上（相机略俯视，裙摆前面就是手，看不进裙底）；身子和头慢慢晃。
    static func sittingGround(_ t: Double, body: VRMBody) -> VRMPose {
        let phase = 2 * Double.pi * t / 4
        var p = seated(body: body)
        // 每一项在 t = 0 都是 0：循环的第一帧 = 坐下（sit_ground_down）的最后一帧。
        p.rotations["spine"] = qz(4 * sin(phase)) * p.rotation("spine")
        p.rotations["chest"] = qz(3 * sin(phase)) * qx(-1.2 * sin(2 * phase)) * p.rotation("chest")
        p.rotations["head"] = qz(-10 * sin(phase)) * qy(8 * sin(phase / 2) * sin(phase / 2)) * p.rotation("head")
        p.shrug(0.8 * sin(2 * phase))
        return p
    }

    /// 坐地的静止姿势（坐下、起身、循环共用）。splay = 大腿往里转、小腿往两边分开的程度（1 = 鸭子坐）。
    static func seated(body: VRMBody, splay: Double = 1) -> VRMPose {
        var p = stand()
        p.hips.y = 0.09 * body.height - body.hipsHeight
        p.rotations["hips"] = qx(-6)
        for side in [VRMSide.left, .right] {
            p.rotations[side.name + "UpperLeg"] = qy(-side.sign * 4 * splay) * qx(-86) * qy(-side.sign * 35 * splay)
            p.rotations[side.name + "LowerLeg"] = qx(158)
            p.rotations[side.name + "Foot"] = qx(45)
            p.arm(side, elevation: -72, forward: 122, elbow: 10, twist: 20)
        }
        p.bend("spine", pitch: 9)
        p.bend("chest", pitch: 3)
        p.bend("head", pitch: -2, roll: 3)
        return p
    }

    /// 坐到地上（1.6 s，播完停住）：先蹲下去，再双膝往前落地、屁股坐到两脚中间。起身（sit_ground_up）是它倒着播。
    static func sitGroundDown(_ t: Double, body: VRMBody) -> VRMPose {
        let crouch = squatting(0, body: body, depth: 0.8 * smooth(t / 0.75))
        let w = smooth((t - 0.6) / 1.0)
        // 大腿往里转（小腿分开）留到屁股快着地才做：转早了，挂在大腿上的裙片被带着往前转，胯侧面就露出来。
        return blend(crouch, seated(body: body, splay: smooth((w - 0.5) / 0.5)), w)
    }

    /// 钉好脚以后把膝盖往里（angle > 0）转：整条腿绕「腿根 → 踝」这条线转，踝不动，脚掌朝向不变。
    static func turnKnee(_ p: inout VRMPose, body: VRMBody, side: VRMSide, angle: Double) {
        let mirror = SIMD3<Float>(side == .left ? 1 : -1, 1, 1)
        let hipsRotation = p.rotation("hips")
        let hip = p.hips + hipsRotation.act(body.legOffset * mirror)
        let axis = simd_normalize(body.ankleRest * mirror - hip)
        let turn = simd_quatf(angle: radians(side.sign * angle), axis: axis)
        let thighWorld = hipsRotation * p.rotation(side.name + "UpperLeg")
        let footWorld = thighWorld * p.rotation(side.name + "LowerLeg") * p.rotation(side.name + "Foot")
        let turned = turn * thighWorld
        p.rotations[side.name + "UpperLeg"] = hipsRotation.inverse * turned
        p.rotations[side.name + "Foot"] = (turned * p.rotation(side.name + "LowerLeg")).inverse * footWorld
    }

    // MARK: - 第三批：脚尖 / 脚跟离地时的钉脚

    /// 钉脚的变体：踝的目标从静止位置挪开 ankle（规范化空间，模型单位），脚掌再转 toe 度（正 = 脚尖朝下、脚跟抬起）。
    /// 踮脚、前掌蹭地、脚尖点地、迈步、跑步用；ankle 由 `ankleLift` 补上时，前脚掌（或脚跟）就留在地上。
    /// plantFeet 把腿当成笔直的两节，而 VRoid 的小腿静止时往后斜（踝在膝盖后两三厘米）：膝盖弯得越多这点误差转得越多，
    /// 踝就偏离目标、脚在地上滑。这里按真实骨骼方向正着算一遍踝落在哪，把差值补回目标再解，两轮就到毫米级；
    /// 站直时 plantFeet 留下的那点固定偏差照样保留，和钉脚的 idle 一致，片段之间淡入淡出脚不挪。
    static func plantFoot(_ p: inout VRMPose, body: VRMBody, side: VRMSide, ankle: SIMD3<Float>, toe: Double) {
        let mirror = SIMD3<Float>(side == .left ? 1 : -1, 1, 1)
        func solve(_ target: SIMD3<Float>) -> VRMPose {
            var shifted = p
            shifted.hips -= target
            plantFeet(&shifted, body: body, sides: [side])
            return shifted
        }
        func reach(_ q: VRMPose, hips: SIMD3<Float>, hipsRotation: simd_quatf) -> SIMD3<Float> {
            let thigh = hipsRotation * q.rotation(side.name + "UpperLeg")
            let shin = thigh * q.rotation(side.name + "LowerLeg")
            return hips + hipsRotation.act(body.legOffset * mirror) + thigh.act((body.kneeRest - body.legOffset) * mirror)
                + shin.act((body.ankleRest - body.kneeRest) * mirror)
        }
        var rest = VRMPose()
        plantFeet(&rest, body: body, sides: [side])
        let goal = reach(rest, hips: .zero, hipsRotation: identity) + ankle
        let hipsRotation = p.rotation("hips")
        var target = ankle
        var solved = solve(target)
        for _ in 0..<2 {
            target += goal - reach(solved, hips: p.hips, hipsRotation: hipsRotation)
            solved = solve(target)
        }
        p.rotations[side.name + "UpperLeg"] = solved.rotation(side.name + "UpperLeg")
        p.rotations[side.name + "LowerLeg"] = solved.rotation(side.name + "LowerLeg")
        p.rotations[side.name + "Foot"] = solved.rotation(side.name + "Foot") * qx(toe)
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
    /// 身高（静止时整个模型外包框的高度，与取景用的高度一致）。
    var height: Float = 1.3
    var hipsHeight: Float = 0.65
    /// hips 关节比大腿根（upperLeg）高多少。
    var hipToLeg: Float = 0.03
    var thigh: Float = 0.25
    var shin: Float = 0.28
    /// 站立时踝关节离地高度。
    var ankle: Float = 0.08
    /// 左腿根、左踝相对 hips 的静止位置（规范化空间；右边按 x 取反）。
    var legOffset = SIMD3<Float>(0.06, -0.03, 0)
    /// 左膝相对 hips 的静止位置（VRoid 的小腿静止时往后斜一点，`plantFoot` 按真实骨骼方向校正钉脚用）。
    var kneeRest = SIMD3<Float>(0.06, -0.28, 0)
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
