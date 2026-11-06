import AppKit
import SceneKit
import simd

/// VRM 扩展里桌宠用得到的部分（设计见 docs/desktop-pet/VRM.md §3）：人形骨骼、表情绑定、MToon 阴影参数。
/// 建 SceneKit 节点之前从 GLB 的 JSON 里读；不是 VRM 返回 nil。解析全程容错：缺什么跳过什么，不 crash。
struct VRMSpec {
    struct Bind {
        let mesh: Int
        let index: Int
        let weight: Float
    }

    /// 0.x 面朝 −Z，1.0 面朝 +Z。
    let isVRM0: Bool
    /// 人形骨骼名（hips / leftUpperArm …）→ 节点下标。
    let humanBones: [String: Int]
    /// 统一后的表情名（blink / happy / relaxed / surprised / aa …）→ 形变绑定。
    let expressions: [String: [Bind]]
    /// 材质下标 → 卡通光影参数（只有 MToon 材质有）。
    let toon: [Int: VRMToonParams]

    /// 每个网格要建哪些形变目标：只建表情用到的（VRoid 的脸有五十多个目标，全建内存翻倍）。
    var morphTargets: [Int: Set<Int>] {
        var out: [Int: Set<Int>] = [:]
        for binds in expressions.values {
            for bind in binds { out[bind.mesh, default: []].insert(bind.index) }
        }
        return out
    }

    /// `nodeMeshes`：节点下标 → 网格下标（1.0 的表情绑定写的是节点）。
    static func parse(json: Data, nodeMeshes: [Int?]) -> VRMSpec? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let extensions = root["extensions"] as? [String: Any] else { return nil }
        let materials = root["materials"] as? [[String: Any]] ?? []
        if let vrm1 = extensions["VRMC_vrm"] as? [String: Any] {
            return parseVRM1(vrm1, materials: materials, nodeMeshes: nodeMeshes)
        }
        if let vrm0 = extensions["VRM"] as? [String: Any] {
            return parseVRM0(vrm0, materials: materials)
        }
        return nil
    }

    // MARK: 0.x

    private static let vrm0Names: [String: String] = [
        "blink": "blink", "blink_l": "blinkLeft", "blink_r": "blinkRight",
        "joy": "happy", "fun": "relaxed", "sorrow": "sad", "angry": "angry", "surprised": "surprised",
        "a": "aa", "i": "ih", "u": "ou", "e": "ee", "o": "oh", "neutral": "neutral",
    ]

    private static func parseVRM0(_ ext: [String: Any], materials: [[String: Any]]) -> VRMSpec? {
        var bones: [String: Int] = [:]
        let humanoid = ext["humanoid"] as? [String: Any]
        for entry in humanoid?["humanBones"] as? [[String: Any]] ?? [] {
            if let name = entry["bone"] as? String, let node = int(entry["node"]) { bones[name] = node }
        }
        guard bones["hips"] != nil else { return nil }

        var expressions: [String: [Bind]] = [:]
        let master = ext["blendShapeMaster"] as? [String: Any]
        for group in master?["blendShapeGroups"] as? [[String: Any]] ?? [] {
            // 0.x 没有「惊讶」预设，VRoid 导出成 presetName = unknown、name = Surprised，所以也按名字认。
            let preset = (group["presetName"] as? String ?? "").lowercased()
            let name = (group["name"] as? String ?? "").lowercased()
            guard let key = vrm0Names[preset] ?? vrm0Names[name], expressions[key] == nil else { continue }
            let binds = (group["binds"] as? [[String: Any]] ?? []).compactMap { bind -> Bind? in
                guard let mesh = int(bind["mesh"]), let index = int(bind["index"]) else { return nil }
                return Bind(mesh: mesh, index: index, weight: max(0, min((float(bind["weight"]) ?? 100) / 100, 1)))
            }
            if !binds.isEmpty { expressions[key] = binds }
        }

        // materialProperties 与 glTF 材质同序；保险起见先按名字对，对不上再按下标。
        var toon: [Int: VRMToonParams] = [:]
        let properties = ext["materialProperties"] as? [[String: Any]] ?? []
        let indexByName = Dictionary(materials.enumerated().compactMap { i, m in (m["name"] as? String).map { ($0, i) } },
                                     uniquingKeysWith: { first, _ in first })
        for (i, property) in properties.enumerated() {
            guard (property["shader"] as? String) == "VRM/MToon" else { continue }
            let index = (property["name"] as? String).flatMap { indexByName[$0] } ?? i
            guard materials.indices.contains(index) else { continue }
            let floats = property["floatProperties"] as? [String: Any] ?? [:]
            let vectors = property["vectorProperties"] as? [String: Any] ?? [:]
            let shift0 = float(floats["_ShadeShift"]) ?? 0
            let toony0 = float(floats["_ShadeToony"]) ?? 0.9
            // 0.x 的明暗分界公式与 1.0 不同，换成等价的 1.0 参数（设计 §5）。
            let toony1 = max(0, min(1 - (1 - toony0) * (1 - shift0) / 2, 0.999))
            let shade = (vectors["_ShadeColor"] as? [Any] ?? []).compactMap(float)
            // 0.x 的颜色是 sRGB（pixiv 把同一个模型转成 1.0 后，shadeColorFactor 正好是这里的线性值）。
            let shadeColor = shade.count >= 3
                ? SIMD3(srgbToLinear(shade[0]), srgbToLinear(shade[1]), srgbToLinear(shade[2]))
                : SIMD3<Float>(repeating: 0.75)
            toon[index] = VRMToonParams(shade: shadeColor, shift: -shift0 - 1 + toony1, toony: toony1)
        }
        return VRMSpec(isVRM0: true, humanBones: bones, expressions: expressions, toon: toon)
    }

    // MARK: 1.0

    private static let vrm1Names: Set<String> = [
        "blink", "blinkLeft", "blinkRight", "happy", "relaxed", "sad", "angry", "surprised",
        "aa", "ih", "ou", "ee", "oh", "neutral",
    ]

    private static func parseVRM1(_ ext: [String: Any], materials: [[String: Any]], nodeMeshes: [Int?]) -> VRMSpec? {
        var bones: [String: Int] = [:]
        let humanoid = ext["humanoid"] as? [String: Any]
        for (name, value) in humanoid?["humanBones"] as? [String: Any] ?? [:] {
            if let node = int((value as? [String: Any])?["node"]) { bones[name] = node }
        }
        guard bones["hips"] != nil else { return nil }

        var expressions: [String: [Bind]] = [:]
        let root = ext["expressions"] as? [String: Any] ?? [:]
        for group in ["preset", "custom"] {
            for (name, value) in root[group] as? [String: Any] ?? [:] {
                let key = vrm1Names.contains(name) ? name : vrm1Names.first { $0.lowercased() == name.lowercased() }
                guard let key, expressions[key] == nil, let expression = value as? [String: Any] else { continue }
                let binds = (expression["morphTargetBinds"] as? [[String: Any]] ?? []).compactMap { bind -> Bind? in
                    guard let node = int(bind["node"]), nodeMeshes.indices.contains(node),
                          let mesh = nodeMeshes[node], let index = int(bind["index"]) else { return nil }
                    return Bind(mesh: mesh, index: index, weight: max(0, min(float(bind["weight"]) ?? 1, 1)))
                }
                if !binds.isEmpty { expressions[key] = binds }
            }
        }

        var toon: [Int: VRMToonParams] = [:]
        for (i, material) in materials.enumerated() {
            guard let mtoon = (material["extensions"] as? [String: Any])?["VRMC_materials_mtoon"] as? [String: Any] else { continue }
            let shade = (mtoon["shadeColorFactor"] as? [Any] ?? []).compactMap(float)
            toon[i] = VRMToonParams(
                shade: shade.count >= 3 ? SIMD3(shade[0], shade[1], shade[2]) : SIMD3<Float>(repeating: 0.75),
                shift: float(mtoon["shadingShiftFactor"]) ?? 0,
                toony: max(0, min(float(mtoon["shadingToonyFactor"]) ?? 0.9, 0.999))
            )
        }
        return VRMSpec(isVRM0: false, humanBones: bones, expressions: expressions, toon: toon)
    }

    // MARK: 小工具

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func float(_ value: Any?) -> Float? {
        (value as? NSNumber)?.floatValue
    }

    private static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }
}

/// MToon 的近似（设计 §5）：亮部 = 底色，暗部 = 底色 × 阴影色，分界按 1.0 的 shift / toony 算。
struct VRMToonParams {
    /// 线性空间。
    let shade: SIMD3<Float>
    let shift: Float
    let toony: Float
}

enum VRMToon {
    /// 不受场景灯光影响（毛绒形象照旧用场景的方向光 + 环境光）：固定的视空间光方向，左上前方。
    /// MASK 材质按 `toonCutoff` 丢弃片元；OPAQUE 的贴图即使带透明通道也当不透明。
    static let fragment = """
    #pragma arguments
    float3 toonShade;
    float toonShift;
    float toonToony;
    float toonCutoff;
    float toonOpaque;
    #pragma body
    float3 toonNormal = normalize(_surface.normal);
    float toonNdl = dot(toonNormal, normalize(float3(-0.35, 0.6, 0.72)));
    float toonLo = -1.0 + toonToony;
    float toonHi = 1.0 - toonToony;
    float toonLit = clamp((toonNdl + toonShift - toonLo) / max(toonHi - toonLo, 0.0001), 0.0, 1.0);
    _output.color.rgb *= mix(toonShade, float3(1.0), toonLit);
    if (_output.color.a < toonCutoff) { discard_fragment(); }
    if (toonOpaque > 0.5) { _output.color.a = 1.0; }
    """

    enum AlphaMode {
        case opaque, mask(Float), blend
    }

    static func apply(to material: SCNMaterial, params: VRMToonParams, alpha: AlphaMode) {
        material.lightingModel = .constant
        material.shaderModifiers = [.fragment: fragment]
        material.setValue(NSValue(scnVector3: SCNVector3(CGFloat(params.shade.x), CGFloat(params.shade.y), CGFloat(params.shade.z))),
                          forKey: "toonShade")
        material.setValue(NSNumber(value: params.shift), forKey: "toonShift")
        material.setValue(NSNumber(value: params.toony), forKey: "toonToony")
        switch alpha {
        case .opaque:
            material.setValue(NSNumber(value: -1), forKey: "toonCutoff")
            material.setValue(NSNumber(value: 1), forKey: "toonOpaque")
        case .mask(let cutoff):
            material.setValue(NSNumber(value: cutoff), forKey: "toonCutoff")
            material.setValue(NSNumber(value: 1), forKey: "toonOpaque")
        case .blend:
            material.setValue(NSNumber(value: -1), forKey: "toonCutoff")
            material.setValue(NSNumber(value: 0), forKey: "toonOpaque")
            material.writesToDepthBuffer = false
        }
    }
}

/// 读好的 VRM：人形骨骼的静止姿态（把规范化动作换算到实际骨骼，设计 §4.1）与表情 → 形变权重的去向。
final class VRMRig {
    struct Bone {
        let node: SCNNode
        let restLocal: simd_quatf
        let restPosition: SIMD3<Float>
        /// 父节点的静止旋转（相对模型根）。
        let parentWorldRest: simd_quatf
        /// 父节点的整体缩放（hips 位移从模型单位换到父节点的局部单位）。
        let parentWorldScale: Float
    }

    struct MorphTarget {
        let node: SCNNode
        /// SCNMorpher 里的下标（只建了表情用到的目标，与 glTF 的下标不同）。
        let index: Int
        let weight: Float
    }

    let isVRM0: Bool
    let bones: [String: Bone]
    let expressions: [String: [MorphTarget]]
    /// 腿长、hips 高度等（跪坐 / 下蹲时算 hips 降多少）。
    let body: VRMBody

    /// `morphs`：网格下标 → 该网格每个图元的节点与「glTF 形变下标 → SCNMorpher 下标」。
    init?(spec: VRMSpec, nodes: [SCNNode], root: SCNNode, morphs: [Int: [(node: SCNNode, map: [Int: Int])]]) {
        var bones: [String: Bone] = [:]
        for (name, index) in spec.humanBones where nodes.indices.contains(index) {
            let node = nodes[index]
            var parentRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            var parentScale: Float = 1
            var ancestor = node.parent
            while let current = ancestor, current !== root {
                parentRotation = current.simdOrientation * parentRotation
                parentScale *= max(abs(current.simdScale.y), 1e-4)
                ancestor = current.parent
            }
            bones[name] = Bone(node: node, restLocal: node.simdOrientation, restPosition: node.simdPosition,
                               parentWorldRest: parentRotation, parentWorldScale: parentScale)
        }
        guard let hips = bones["hips"] else { return nil }
        self.bones = bones
        isVRM0 = spec.isVRM0
        // 量腿：静止姿势下各关节相对模型根的位置（VRM 原点在脚底）。缺骨骼就用默认值。
        var body = VRMBody()
        let position = { (name: String) in bones[name]?.node.simdConvertPosition(.zero, to: root) }
        let hipsPosition = hips.node.simdConvertPosition(.zero, to: root)
        body.hipsHeight = max(hipsPosition.y, 0.1)
        if let upper = position("leftUpperLeg"), let lower = position("leftLowerLeg"), let foot = position("leftFoot") {
            body.hipToLeg = max(hipsPosition.y - upper.y, 0)
            body.thigh = max(simd_distance(upper, lower), 0.05)
            body.shin = max(simd_distance(lower, foot), 0.05)
            body.ankle = max(foot.y, 0.02)
            // 钉脚用（VRMMotion.plantFeet）：左腿根、左踝相对 hips 的位置，换到规范化空间（0.x 面朝 −Z，x、z 取反）。
            let canonical = { (v: SIMD3<Float>) in spec.isVRM0 ? SIMD3(-v.x, v.y, -v.z) : v }
            body.legOffset = canonical(upper - hipsPosition)
            body.ankleRest = canonical(foot - hipsPosition)
        }
        self.body = body

        var expressions: [String: [MorphTarget]] = [:]
        for (name, binds) in spec.expressions {
            var targets: [MorphTarget] = []
            for bind in binds {
                for primitive in morphs[bind.mesh] ?? [] {
                    if let index = primitive.map[bind.index] {
                        targets.append(MorphTarget(node: primitive.node, index: index, weight: bind.weight))
                    }
                }
            }
            if !targets.isEmpty { expressions[name] = targets }
        }
        // 只有左右分开眨眼的模型：两只一起闭当「眨眼」。
        if expressions["blink"] == nil, let left = expressions["blinkLeft"], let right = expressions["blinkRight"] {
            expressions["blink"] = left + right
        }
        self.expressions = expressions
    }

    /// 规范化旋转（面朝 +Z、T 字姿势为单位旋转）→ 骨骼实际的局部旋转。
    func localRotation(_ bone: Bone, _ normalized: simd_quatf) -> simd_quatf {
        var q = normalized
        // 0.x 面朝 −Z：绕 Y 转 180° 的共轭 = x、z 分量取反。
        if isVRM0 { q = simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real) }
        return bone.parentWorldRest.inverse * q * bone.parentWorldRest * bone.restLocal
    }

    /// hips 在规范化空间里的位移 → hips 节点的局部位置。
    func hipsPosition(_ offset: SIMD3<Float>) -> SIMD3<Float>? {
        guard let hips = bones["hips"] else { return nil }
        var d = offset
        if isVRM0 { d = SIMD3(-d.x, d.y, -d.z) }
        return hips.restPosition + hips.parentWorldRest.inverse.act(d) / hips.parentWorldScale
    }

    /// 直接摆一个姿势（离线渲染与取景用；App 里动作走 CAAnimation）。
    func apply(_ pose: VRMPose) {
        for (name, bone) in bones {
            bone.node.simdOrientation = localRotation(bone, pose.rotations[name] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        }
        if let position = hipsPosition(pose.hips) { bones["hips"]?.node.simdPosition = position }
        for targets in expressions.values {
            for target in targets { target.node.morpher?.setWeight(0, forTargetAt: target.index) }
        }
        for (node, weights) in morphWeights(pose.expressions) {
            for (index, weight) in weights { node.morpher?.setWeight(CGFloat(weight), forTargetAt: index) }
        }
    }

    /// 表情权重 → 每个形变目标的权重（同一目标被几个表情用到时相加，封顶 1）。
    func morphWeights(_ values: [String: Float]) -> [(SCNNode, [Int: Float])] {
        var byNode: [ObjectIdentifier: (SCNNode, [Int: Float])] = [:]
        for (name, value) in values {
            for target in expressions[name] ?? [] {
                let key = ObjectIdentifier(target.node)
                var entry = byNode[key] ?? (target.node, [:])
                entry.1[target.index] = min((entry.1[target.index] ?? 0) + value * target.weight, 1)
                byNode[key] = entry
            }
        }
        return Array(byNode.values)
    }

    /// 自动眨眼：一轮 7 秒，两次单眨 + 一次连眨，循环播（带表情的片段会盖掉它，见 VRMMotion）。
    func startBlinking() {
        let blinks: [Double] = [1.4, 4.1, 4.45]
        var times: [Double] = [0]
        var values: [Float] = [0]
        for start in blinks {
            times += [start, start + 0.06, start + 0.1, start + 0.2]
            values += [0, 1, 1, 0]
        }
        times.append(7)
        values.append(0)
        for target in expressions["blink"] ?? [] {
            let animation = CAKeyframeAnimation(keyPath: "morpher.weights[\(target.index)]")
            animation.values = values.map { NSNumber(value: $0 * target.weight) }
            animation.keyTimes = times.map { NSNumber(value: $0 / 7) }
            animation.duration = 7
            animation.repeatCount = .infinity
            target.node.addAnimation(animation, forKey: "pet.vrm.blink")
        }
    }
}
