import AppKit
import SceneKit
import simd

/// 最小 glTF 2.0 / GLB 读取器 → SceneKit 节点树（设计见 docs/desktop-pet/PACKS.md §4）。
///
/// SceneKit / Model I/O 都不认 glTF，而开源模型几乎都是 glTF —— 出厂转 USDZ 需要 Reality Converter / Blender，
/// 用户自己放模型时也做不到，所以在 App 里直接读。只覆盖宠物模型用得到的部分：
/// 三角形网格、PBR 基色（颜色 / 贴图）、骨骼蒙皮、位置 / 旋转 / 缩放动画（LINEAR / STEP，CUBICSPLINE 取关键值）。
/// 不支持 Draco / meshopt 压缩、KTX2 贴图、稀疏访问器、形变（morph）动画：必需扩展直接报错，其余跳过对应部分。
/// VRM（带 VRM / VRMC_vrm 扩展的 GLB）额外读表情用到的形变目标、透明模式、自发光，材质换成卡通光影，
/// 并按人形骨骼生成程序化动作（docs/desktop-pet/VRM.md）。
/// 解析全程容错：字段缺失 / 越界只丢掉那一块，不 crash。可以在后台线程调用（只建节点树，不碰正在渲染的场景）。
enum GLTFLoader {
    static func load(contentsOf url: URL) throws -> GLTFModel {
        let file = try Data(contentsOf: url)
        let (json, bin) = try split(file)
        let doc = try JSONDecoder().decode(GLTFDocument.self, from: json)
        if let required = doc.extensionsRequired, !required.isEmpty {
            throw GLTFError.unsupported(required.joined(separator: ", "))
        }
        let used = doc.extensionsUsed ?? []
        let vrm = used.contains("VRM") || used.contains("VRMC_vrm")
            ? VRMSpec.parse(json: json, nodeMeshes: (doc.nodes ?? []).map(\.mesh))
            : nil
        var buffers: [Data] = []
        for (i, buffer) in (doc.buffers ?? []).enumerated() {
            if let uri = buffer.uri {
                buffers.append((try? loadURI(uri, relativeTo: url)) ?? Data())
            } else {
                // GLB 的第一个无 uri 的 buffer 就是 BIN 块。
                buffers.append(i == 0 ? (bin ?? Data()) : Data())
            }
        }
        let builder = GLTFSceneBuilder(doc: doc, reader: GLTFAccessorReader(doc: doc, buffers: buffers), fileURL: url, vrm: vrm)
        return builder.build()
    }

    /// GLB：12 字节头 + JSON 块 + BIN 块；不是 GLB 就当 .gltf（整份是 JSON）。
    private static func split(_ data: Data) throws -> (json: Data, bin: Data?) {
        guard data.count >= 12 else { throw GLTFError.unreadable }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard u32(0) == 0x4654_6C67 else { return (data, nil) }
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= bytes.count {
            let length = Int(u32(offset))
            let type = u32(offset + 4)
            let start = offset + 8
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            let chunk = Data(bytes[start..<end])
            if type == 0x4E4F_534A, json == nil {
                json = chunk
            } else if type == 0x004E_4942, bin == nil {
                bin = chunk
            }
            offset = end
        }
        guard let json else { throw GLTFError.unreadable }
        return (json, bin)
    }

    /// buffer / image 的 uri：data URI（base64）或相对模型文件的路径。
    static func loadURI(_ uri: String, relativeTo fileURL: URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                throw GLTFError.unreadable
            }
            return data
        }
        let path = uri.removingPercentEncoding ?? uri
        return try Data(contentsOf: fileURL.deletingLastPathComponent().appendingPathComponent(path))
    }
}

enum GLTFError: LocalizedError {
    case unreadable
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "glTF: unreadable file"
        case .unsupported(let what): return "glTF: unsupported \(what)"
        }
    }
}

/// 读出来的模型：节点树 + 按名字索引的动画片段（VRM 还带程序化动作与表情，见 `vrm`）。
final class GLTFModel {
    let root: SCNNode
    let clips: [String: GLTFClip]
    /// 非 nil = VRM 人形模型。
    let vrm: VRMRig?

    init(root: SCNNode, clips: [String: GLTFClip], vrm: VRMRig? = nil) {
        self.root = root
        self.clips = clips
        self.vrm = vrm
    }

    /// 播放一段动画（同名片段重复播放 = 从头开始）。`hold` = 播完停在最后一帧（坐下 / 躺下这类过渡动作）。
    func play(_ clip: GLTFClip, loop: Bool, hold: Bool, fadeIn: CGFloat) {
        for track in clip.tracks {
            let group = CAAnimationGroup()
            group.animations = track.animations
            group.duration = clip.duration
            group.repeatCount = loop ? .infinity : 1
            if hold, !loop {
                group.isRemovedOnCompletion = false
                group.fillMode = .forwards
            }
            group.fadeInDuration = fadeIn
            track.node.addAnimation(group, forKey: clip.key)
        }
    }

    func stop(_ clip: GLTFClip, fadeOut: CGFloat) {
        for track in clip.tracks {
            track.node.removeAnimation(forKey: clip.key, blendOutDuration: fadeOut)
        }
    }
}

/// 一段动画：每个被驱动的节点一组关键帧（位置 / 朝向 / 缩放），整段共用一个时长，循环时各节点同步。
struct GLTFClip {
    struct Track {
        let node: SCNNode
        let animations: [CAAnimation]
    }

    let name: String
    let duration: TimeInterval
    let tracks: [Track]

    var key: String { "pet.clip." + name }
}

// MARK: - glTF 文档（只解码用得到的字段，其余忽略）

private struct GLTFDocument: Decodable {
    var scene: Int?
    var scenes: [GLTFScene]?
    var nodes: [GLTFNode]?
    var meshes: [GLTFMesh]?
    var accessors: [GLTFAccessor]?
    var bufferViews: [GLTFBufferView]?
    var buffers: [GLTFBuffer]?
    var materials: [GLTFMaterial]?
    var textures: [GLTFTexture]?
    var images: [GLTFImage]?
    var skins: [GLTFSkin]?
    var animations: [GLTFAnimation]?
    var extensionsUsed: [String]?
    var extensionsRequired: [String]?
}

private struct GLTFScene: Decodable {
    var nodes: [Int]?
}

private struct GLTFNode: Decodable {
    var name: String?
    var children: [Int]?
    var mesh: Int?
    var skin: Int?
    var matrix: [Float]?
    var translation: [Float]?
    var rotation: [Float]?
    var scale: [Float]?
}

private struct GLTFMesh: Decodable {
    var primitives: [GLTFPrimitive]?
}

private struct GLTFPrimitive: Decodable {
    var attributes: [String: Int]?
    var indices: Int?
    var material: Int?
    var mode: Int?
    /// 形变目标：属性名（POSITION / NORMAL）→ 访问器，存的是相对基础网格的增量。
    var targets: [[String: Int]]?
}

private struct GLTFAccessor: Decodable {
    var bufferView: Int?
    var byteOffset: Int?
    var componentType: Int
    var normalized: Bool?
    var count: Int
    var type: String
}

private struct GLTFBufferView: Decodable {
    var buffer: Int
    var byteOffset: Int?
    var byteLength: Int
    var byteStride: Int?
}

private struct GLTFBuffer: Decodable {
    var uri: String?
}

private struct GLTFMaterial: Decodable {
    struct PBR: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureRef?
    }

    struct TextureRef: Decodable {
        var index: Int
    }

    var pbrMetallicRoughness: PBR?
    var doubleSided: Bool?
    /// OPAQUE / MASK / BLEND（只有 VRM 材质按它处理，毛绒形象照旧）。
    var alphaMode: String?
    var alphaCutoff: Float?
    var emissiveFactor: [Float]?
    var emissiveTexture: TextureRef?
}

private struct GLTFTexture: Decodable {
    var source: Int?
}

private struct GLTFImage: Decodable {
    var uri: String?
    var bufferView: Int?
}

private struct GLTFSkin: Decodable {
    var joints: [Int]
    var inverseBindMatrices: Int?
}

private struct GLTFAnimation: Decodable {
    struct Channel: Decodable {
        struct Target: Decodable {
            var node: Int?
            var path: String
        }

        var sampler: Int
        var target: Target
    }

    struct Sampler: Decodable {
        var input: Int
        var output: Int
        var interpolation: String?
    }

    var name: String?
    var channels: [Channel]?
    var samplers: [Sampler]?
}

// MARK: - 访问器

private struct GLTFAccessorReader {
    let accessors: [GLTFAccessor]
    let views: [GLTFBufferView]
    let buffers: [Data]

    init(doc: GLTFDocument, buffers: [Data]) {
        accessors = doc.accessors ?? []
        views = doc.bufferViews ?? []
        self.buffers = buffers
    }

    private static func components(_ type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4", "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 0
        }
    }

    private static func byteSize(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return 0
        }
    }

    /// 分量数（VEC3 = 3 …）；访问器不存在返回 0。
    func componentCount(_ index: Int?) -> Int {
        guard let index, accessors.indices.contains(index) else { return 0 }
        return Self.components(accessors[index].type)
    }

    /// 全部分量按顺序读成 Float（count × 分量数）。整数类型 normalized 时按规范化换算；
    /// `raw` = 不规范化（索引、关节号）。读不到 / 越界返回 nil。
    func floats(_ index: Int?, raw: Bool = false) -> [Float]? {
        guard let index, accessors.indices.contains(index) else { return nil }
        let a = accessors[index]
        let comps = Self.components(a.type)
        let size = Self.byteSize(a.componentType)
        guard comps > 0, size > 0, a.count > 0 else { return nil }
        let total = a.count * comps
        // 没有 bufferView 的访问器按规范是全 0（配合稀疏访问器用；稀疏部分不支持）。
        guard let viewIndex = a.bufferView else { return [Float](repeating: 0, count: total) }
        guard views.indices.contains(viewIndex) else { return nil }
        let view = views[viewIndex]
        guard buffers.indices.contains(view.buffer) else { return nil }
        let data = buffers[view.buffer]
        let elementSize = comps * size
        let stride = (view.byteStride ?? 0) > 0 ? (view.byteStride ?? elementSize) : elementSize
        let viewStart = view.byteOffset ?? 0
        let start = viewStart + (a.byteOffset ?? 0)
        let end = start + (a.count - 1) * stride + elementSize
        guard start >= 0, end <= data.count, end <= viewStart + view.byteLength else { return nil }
        let normalized = (a.normalized ?? false) && !raw
        let type = a.componentType
        var out = [Float](repeating: 0, count: total)
        data.withUnsafeBytes { buffer in
            for i in 0..<a.count {
                let base = start + i * stride
                for c in 0..<comps {
                    out[i * comps + c] = Self.read(buffer, base + c * size, type, normalized)
                }
            }
        }
        return out
    }

    func uints(_ index: Int?) -> [UInt32]? {
        floats(index, raw: true)?.map { UInt32(max($0, 0)) }
    }

    /// bufferView 原始字节（内嵌贴图）。
    func bytes(view index: Int) -> Data? {
        guard views.indices.contains(index) else { return nil }
        let view = views[index]
        guard buffers.indices.contains(view.buffer) else { return nil }
        let data = buffers[view.buffer]
        let start = view.byteOffset ?? 0
        let end = start + view.byteLength
        guard start >= 0, end <= data.count else { return nil }
        return data.subdata(in: data.startIndex + start..<data.startIndex + end)
    }

    private static func read(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ type: Int, _ normalized: Bool) -> Float {
        switch type {
        case 5126:
            return buffer.loadUnaligned(fromByteOffset: offset, as: Float.self)
        case 5121:
            let v = Float(buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            return normalized ? v / 255 : v
        case 5123:
            let v = Float(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            return normalized ? v / 65535 : v
        case 5125:
            return Float(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        case 5120:
            let v = Float(buffer.loadUnaligned(fromByteOffset: offset, as: Int8.self))
            return normalized ? max(v / 127, -1) : v
        case 5122:
            let v = Float(buffer.loadUnaligned(fromByteOffset: offset, as: Int16.self))
            return normalized ? max(v / 32767, -1) : v
        default:
            return 0
        }
    }
}

// MARK: - 建 SceneKit 场景

private struct GLTFSceneBuilder {
    let doc: GLTFDocument
    let reader: GLTFAccessorReader
    let fileURL: URL
    /// 非 nil = VRM：建表情用到的形变目标、材质走卡通光影，最后生成人形动作。
    let vrm: VRMSpec?

    func build() -> GLTFModel {
        let specs = doc.nodes ?? []
        let nodes = specs.map(makeNode)
        var hasParent = [Bool](repeating: false, count: nodes.count)
        for (i, spec) in specs.enumerated() {
            for child in spec.children ?? [] where nodes.indices.contains(child) && child != i && !hasParent[child] {
                hasParent[child] = true
                nodes[i].addChildNode(nodes[child])
            }
        }
        var materialCache: [Int: SCNMaterial] = [:]
        var skinned: [SCNNode] = []
        let morphTargets = vrm?.morphTargets ?? [:]
        var morphs: [Int: [(node: SCNNode, map: [Int: Int])]] = [:]
        for (i, spec) in specs.enumerated() {
            guard let meshIndex = spec.mesh, let mesh = doc.meshes?[safe: meshIndex] else { continue }
            let skin = spec.skin.flatMap { doc.skins?[safe: $0] }
            for primitive in mesh.primitives ?? [] {
                guard let (child, morphMap) = makePrimitive(primitive, skin: skin, meshWorld: nodes[i].simdWorldTransform,
                                                            nodes: nodes, morphTargets: morphTargets[meshIndex] ?? [],
                                                            materials: &materialCache) else { continue }
                if !morphMap.isEmpty { morphs[meshIndex, default: []].append((child, morphMap)) }
                if child.skinner != nil {
                    skinned.append(child)
                } else {
                    nodes[i].addChildNode(child)
                }
            }
        }
        let root = SCNNode()
        let sceneRoots = doc.scenes?[safe: doc.scene ?? 0]?.nodes
            ?? nodes.indices.filter { !hasParent[$0] }
        for index in sceneRoots where nodes.indices.contains(index) && nodes[index].parent == nil {
            root.addChildNode(nodes[index])
        }
        // glTF 规定蒙皮网格所在节点的变换不起作用（顶点只由关节 × 逆绑定矩阵决定），SceneKit 却会再乘一遍 ——
        // 实测 RobotExpressive 的手（节点带 100 倍缩放）被放大一百倍。蒙皮网格统一挂到模型根下（单位变换），
        // 节点变换已在 makePrimitive 里烘进顶点。
        for node in skinned { root.addChildNode(node) }
        var clips = makeClips(nodes: nodes)
        var rig: VRMRig?
        if let vrm, let made = VRMRig(spec: vrm, nodes: nodes, root: root, morphs: morphs) {
            rig = made
            // 模型自带同名动画时以模型的为准。
            for (name, clip) in VRMMotion.clips(for: made) where clips[name] == nil { clips[name] = clip }
        }
        return GLTFModel(root: root, clips: clips, vrm: rig)
    }

    private func makeNode(_ spec: GLTFNode) -> SCNNode {
        let node = SCNNode()
        node.name = spec.name
        if let m = spec.matrix, m.count == 16 {
            node.simdTransform = simd_float4x4(columns: (
                SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
            ))
        } else {
            if let t = spec.translation, t.count == 3 { node.simdPosition = SIMD3(t[0], t[1], t[2]) }
            if let r = spec.rotation, r.count == 4 { node.simdOrientation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]) }
            if let s = spec.scale, s.count == 3 { node.simdScale = SIMD3(s[0], s[1], s[2]) }
        }
        return node
    }

    // MARK: 网格

    /// 一个图元的蒙皮数据（已校验过数量与范围）。
    private struct Skinning {
        let bones: [SCNNode]
        let inverseBinds: [simd_float4x4]
        let weights: [Float]
        let joints: [UInt16]
    }

    /// `meshWorld` = 网格所在节点相对模型根的变换（蒙皮时要烘进顶点，见下）。
    /// `morphTargets` = 要建的形变目标（glTF 下标）；返回的 map 是「glTF 下标 → SCNMorpher 下标」。
    private func makePrimitive(_ primitive: GLTFPrimitive, skin: GLTFSkin?, meshWorld: simd_float4x4, nodes: [SCNNode],
                               morphTargets: Set<Int>,
                               materials: inout [Int: SCNMaterial]) -> (SCNNode, [Int: Int])? {
        let attributes = primitive.attributes ?? [:]
        guard (primitive.mode ?? 4) == 4,
              reader.componentCount(attributes["POSITION"]) == 3,
              var positions = reader.floats(attributes["POSITION"]) else { return nil }
        let vertexCount = positions.count / 3
        var indices = reader.uints(primitive.indices) ?? (0..<UInt32(vertexCount)).map { $0 }
        indices.removeLast(indices.count % 3)
        guard !indices.isEmpty, indices.allSatisfy({ $0 < vertexCount }) else { return nil }

        var normals = reader.componentCount(attributes["NORMAL"]) == 3 ? reader.floats(attributes["NORMAL"]) : nil
        if normals?.count != positions.count { normals = nil }
        var skinning = skin.flatMap { makeSkinning($0, attributes: attributes, vertexCount: vertexCount, nodes: nodes) }
        // 蒙皮网格会被挂到模型根下（见 build）。顶点若在网格节点的局部空间（FBX2glTF 导出的 RobotExpressive：
        // 手的节点带 100 倍缩放 + 绕 X 转 90°，局部坐标只有零点几），挂过去后包围盒就不对了 —— 相机取景靠它。
        // 所以把网格节点的变换烘进顶点 / 法线，再从逆绑定矩阵里除掉：
        // 关节 × 逆绑定′ × 顶点′ = 关节 × 逆绑定 × M⁻¹ × M × 顶点，蒙皮结果与 glTF 定义一致。
        if var data = skinning, meshWorld != matrix_identity_float4x4 {
            positions = Self.transformPoints(positions, by: meshWorld)
            normals = normals.map { Self.transformNormals($0, by: meshWorld) }
            let inverse = simd_inverse(meshWorld)
            data = Skinning(bones: data.bones, inverseBinds: data.inverseBinds.map { simd_mul($0, inverse) },
                            weights: data.weights, joints: data.joints)
            skinning = data
        }
        let finalNormals = normals ?? Self.computeNormals(positions: positions, indices: indices)
        var sources = [
            Self.source(positions, semantic: .vertex, components: 3),
            Self.source(finalNormals, semantic: .normal, components: 3),
        ]
        if reader.componentCount(attributes["TEXCOORD_0"]) == 2,
           let uv = reader.floats(attributes["TEXCOORD_0"]), uv.count == vertexCount * 2 {
            sources.append(Self.source(uv, semantic: .texcoord, components: 2))
        }
        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let materialIndex = primitive.material ?? -1
        if let cached = materials[materialIndex] {
            geometry.materials = [cached]
        } else {
            let material = makeMaterial(primitive.material)
            materials[materialIndex] = material
            geometry.materials = [material]
        }
        let node = SCNNode(geometry: geometry)
        // VRM 的 BLEND 材质（睫毛、眼线、眼睛高光）不写深度，排在不透明部分之后画。
        if vrm != nil, doc.materials?[safe: materialIndex]?.alphaMode == "BLEND" {
            node.renderingOrder = 10
        }
        // 形变目标：glTF 存的就是相对基础网格的增量，SceneKit 用 additive 模式直接叠加。
        var morphMap: [Int: Int] = [:]
        if !morphTargets.isEmpty, let targets = primitive.targets {
            var geometries: [SCNGeometry] = []
            for index in morphTargets.sorted() where targets.indices.contains(index) {
                guard reader.componentCount(targets[index]["POSITION"]) == 3,
                      var delta = reader.floats(targets[index]["POSITION"]), delta.count == vertexCount * 3 else { continue }
                var normalDelta = reader.componentCount(targets[index]["NORMAL"]) == 3 ? reader.floats(targets[index]["NORMAL"]) : nil
                if normalDelta?.count != delta.count { normalDelta = nil }
                if skinning != nil, meshWorld != matrix_identity_float4x4 {
                    // 与基础顶点一样烘进网格节点的变换（增量只随线性部分变，不加平移）。
                    delta = Self.transformVectors(delta, by: meshWorld)
                    normalDelta = normalDelta.map { Self.transformVectors($0, by: meshWorld) }
                }
                let sources = [
                    Self.source(delta, semantic: .vertex, components: 3),
                    Self.source(normalDelta ?? [Float](repeating: 0, count: delta.count), semantic: .normal, components: 3),
                ]
                morphMap[index] = geometries.count
                geometries.append(SCNGeometry(sources: sources, elements: nil))
            }
            if !geometries.isEmpty {
                let morpher = SCNMorpher()
                morpher.calculationMode = .additive
                morpher.targets = geometries
                node.morpher = morpher
            }
        }
        if let skinning {
            let indexData = skinning.joints.withUnsafeBufferPointer { Data(buffer: $0) }
            let indexSource = SCNGeometrySource(data: indexData, semantic: .boneIndices, vectorCount: vertexCount,
                                                usesFloatComponents: false, componentsPerVector: 4,
                                                bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
            node.skinner = SCNSkinner(
                baseGeometry: geometry, bones: skinning.bones,
                boneInverseBindTransforms: skinning.inverseBinds.map { NSValue(scnMatrix4: SCNMatrix4($0)) },
                boneWeights: Self.source(skinning.weights, semantic: .boneWeights, components: 4),
                boneIndices: indexSource
            )
        }
        return (node, morphMap)
    }

    private func makeSkinning(_ skin: GLTFSkin, attributes: [String: Int], vertexCount: Int, nodes: [SCNNode]) -> Skinning? {
        guard reader.componentCount(attributes["JOINTS_0"]) == 4, reader.componentCount(attributes["WEIGHTS_0"]) == 4,
              let joints = reader.uints(attributes["JOINTS_0"]), joints.count == vertexCount * 4,
              let weights = reader.floats(attributes["WEIGHTS_0"]), weights.count == vertexCount * 4,
              !skin.joints.isEmpty, skin.joints.allSatisfy({ nodes.indices.contains($0) }) else { return nil }
        let bones = skin.joints.map { nodes[$0] }
        var inverseBinds = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        if let m = reader.floats(skin.inverseBindMatrices), m.count == bones.count * 16 {
            for b in 0..<bones.count {
                let o = b * 16
                inverseBinds[b] = simd_float4x4(columns: (
                    SIMD4(m[o], m[o + 1], m[o + 2], m[o + 3]), SIMD4(m[o + 4], m[o + 5], m[o + 6], m[o + 7]),
                    SIMD4(m[o + 8], m[o + 9], m[o + 10], m[o + 11]), SIMD4(m[o + 12], m[o + 13], m[o + 14], m[o + 15])
                ))
            }
        }
        // 每个顶点的四个权重归一化：有的导出器存的权重加起来不是 1（RobotExpressive 的手最大到 1.75），
        // 线性混合蒙皮时顶点会被成倍推远（实测手被拉成长条）。three.js 读 glTF 时同样会做这一步。
        var normalized = weights
        var v = 0
        while v + 3 < normalized.count {
            let sum = normalized[v] + normalized[v + 1] + normalized[v + 2] + normalized[v + 3]
            if sum > 0 {
                for k in 0..<4 { normalized[v + k] /= sum }
            } else {
                normalized[v] = 1
            }
            v += 4
        }
        let maxBone = UInt32(bones.count - 1)
        return Skinning(bones: bones, inverseBinds: inverseBinds, weights: normalized,
                        joints: joints.map { UInt16(min($0, maxBone)) })
    }

    private static func transformPoints(_ values: [Float], by m: simd_float4x4) -> [Float] {
        var out = values
        var i = 0
        while i + 2 < values.count {
            let p = simd_mul(m, SIMD4(values[i], values[i + 1], values[i + 2], 1))
            out[i] = p.x
            out[i + 1] = p.y
            out[i + 2] = p.z
            i += 3
        }
        return out
    }

    /// 只乘线性部分（形变目标的位移增量）。
    private static func transformVectors(_ values: [Float], by m: simd_float4x4) -> [Float] {
        var out = values
        var i = 0
        while i + 2 < values.count {
            let v = simd_mul(m, SIMD4(values[i], values[i + 1], values[i + 2], 0))
            out[i] = v.x
            out[i + 1] = v.y
            out[i + 2] = v.z
            i += 3
        }
        return out
    }

    /// 法线按逆转置变换（带缩放时方向才对），再归一化。
    private static func transformNormals(_ values: [Float], by m: simd_float4x4) -> [Float] {
        let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                   SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                   SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let normalMatrix = simd_transpose(simd_inverse(linear))
        var out = values
        var i = 0
        while i + 2 < values.count {
            let n = simd_mul(normalMatrix, SIMD3(values[i], values[i + 1], values[i + 2]))
            let length = simd_length(n)
            let unit = length > 0 ? n / length : SIMD3<Float>(0, 1, 0)
            out[i] = unit.x
            out[i + 1] = unit.y
            out[i + 2] = unit.z
            i += 3
        }
        return out
    }

    private static func source(_ values: [Float], semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count / components,
                                 usesFloatComponents: true, componentsPerVector: components,
                                 bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                 dataStride: MemoryLayout<Float>.size * components)
    }

    /// 没带法线的网格：按面法线累加（不共享顶点的低多边形网格自然得到平直的面片光照）。
    private static func computeNormals(positions: [Float], indices: [UInt32]) -> [Float] {
        var normals = [Float](repeating: 0, count: positions.count)
        func p(_ i: UInt32) -> SIMD3<Float> {
            let o = Int(i) * 3
            return SIMD3(positions[o], positions[o + 1], positions[o + 2])
        }
        var t = 0
        while t + 2 < indices.count {
            let (a, b, c) = (indices[t], indices[t + 1], indices[t + 2])
            let n = simd_cross(p(b) - p(a), p(c) - p(a))
            for i in [a, b, c] {
                let o = Int(i) * 3
                normals[o] += n.x
                normals[o + 1] += n.y
                normals[o + 2] += n.z
            }
            t += 3
        }
        var v = 0
        while v + 2 < normals.count {
            let n = SIMD3(normals[v], normals[v + 1], normals[v + 2])
            let length = simd_length(n)
            let unit = length > 0 ? n / length : SIMD3<Float>(0, 1, 0)
            normals[v] = unit.x
            normals[v + 1] = unit.y
            normals[v + 2] = unit.z
            v += 3
        }
        return normals
    }

    // MARK: 材质

    private func makeMaterial(_ index: Int?) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        guard let index, let spec = doc.materials?[safe: index] else {
            material.diffuse.contents = NSColor(white: 0.8, alpha: 1)
            return material
        }
        material.isDoubleSided = spec.doubleSided ?? false
        let factor = spec.pbrMetallicRoughness?.baseColorFactor
        let color = factor.flatMap(Self.linearColor) ?? .white
        if let textureIndex = spec.pbrMetallicRoughness?.baseColorTexture?.index,
           let image = image(forTexture: textureIndex) {
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            if factor != nil { material.multiply.contents = color }
        } else {
            material.diffuse.contents = color
        }
        if let vrm { applyVRM(material, spec: spec, toon: vrm.toon[index]) }
        return material
    }

    /// VRM 材质：卡通光影 + 透明模式 + 自发光（设计 §2 / §5）。没有 MToon 参数的（Unlit）阴影色取白 = 不变暗。
    private func applyVRM(_ material: SCNMaterial, spec: GLTFMaterial, toon: VRMToonParams?) {
        if let textureIndex = spec.emissiveTexture?.index, let image = image(forTexture: textureIndex) {
            material.emission.contents = image
            material.emission.intensity = CGFloat(spec.emissiveFactor?.max() ?? 1)
        } else if let factor = spec.emissiveFactor, factor.contains(where: { $0 > 0 }) {
            material.emission.contents = Self.linearColor(factor)
        }
        let alpha: VRMToon.AlphaMode
        switch spec.alphaMode {
        case "MASK": alpha = .mask(spec.alphaCutoff ?? 0.5)
        case "BLEND": alpha = .blend
        default: alpha = .opaque
        }
        VRMToon.apply(to: material, params: toon ?? VRMToonParams(shade: SIMD3(repeating: 1), shift: 0, toony: 0.9), alpha: alpha)
    }

    /// glTF 的颜色因子是线性空间。
    private static func linearColor(_ c: [Float]) -> NSColor? {
        guard c.count >= 3, let space = CGColorSpace(name: CGColorSpace.linearSRGB),
              let nsSpace = NSColorSpace(cgColorSpace: space) else { return nil }
        var components: [CGFloat] = [CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]), CGFloat(c.count > 3 ? c[3] : 1)]
        return NSColor(colorSpace: nsSpace, components: &components, count: 4)
    }

    private func image(forTexture index: Int) -> NSImage? {
        guard let source = doc.textures?[safe: index]?.source, let image = doc.images?[safe: source] else { return nil }
        if let view = image.bufferView, let data = reader.bytes(view: view) { return NSImage(data: data) }
        if let uri = image.uri, let data = try? GLTFLoader.loadURI(uri, relativeTo: fileURL) { return NSImage(data: data) }
        return nil
    }

    // MARK: 动画

    private func makeClips(nodes: [SCNNode]) -> [String: GLTFClip] {
        var clips: [String: GLTFClip] = [:]
        for (animationIndex, animation) in (doc.animations ?? []).enumerated() {
            let samplers = animation.samplers ?? []
            struct Channel {
                let node: Int
                let keyPath: String
                let times: [Float]
                let values: [NSValue]
                let discrete: Bool
            }
            var channels: [Channel] = []
            for channel in animation.channels ?? [] {
                guard let nodeIndex = channel.target.node, nodes.indices.contains(nodeIndex),
                      let sampler = samplers[safe: channel.sampler],
                      let times = reader.floats(sampler.input), !times.isEmpty,
                      let output = reader.floats(sampler.output) else { continue }
                let keyPath: String
                let comps: Int
                switch channel.target.path {
                case "translation": (keyPath, comps) = ("position", 3)
                case "rotation": (keyPath, comps) = ("orientation", 4)
                case "scale": (keyPath, comps) = ("scale", 3)
                default: continue   // weights（形变）不支持
                }
                let cubic = sampler.interpolation == "CUBICSPLINE"
                let perKey = cubic ? comps * 3 : comps
                guard output.count >= times.count * perKey else { continue }
                var values: [NSValue] = []
                var previous: SIMD4<Float>?
                for k in 0..<times.count {
                    let o = k * perKey + (cubic ? comps : 0)   // 三次样条：[入切线, 值, 出切线]，取值
                    if comps == 4 {
                        var q = SIMD4(output[o], output[o + 1], output[o + 2], output[o + 3])
                        // 相邻四元数取同一半球，插值才走短弧。
                        if let previous, simd_dot(previous, q) < 0 { q = -q }
                        previous = q
                        values.append(NSValue(scnVector4: SCNVector4(CGFloat(q.x), CGFloat(q.y), CGFloat(q.z), CGFloat(q.w))))
                    } else {
                        values.append(NSValue(scnVector3: SCNVector3(CGFloat(output[o]), CGFloat(output[o + 1]), CGFloat(output[o + 2]))))
                    }
                }
                channels.append(Channel(node: nodeIndex, keyPath: keyPath, times: times, values: values,
                                        discrete: sampler.interpolation == "STEP"))
            }
            let duration = channels.compactMap { $0.times.last }.max() ?? 0
            guard duration > 0 else { continue }
            var byNode: [Int: [CAAnimation]] = [:]
            for channel in channels {
                var times = channel.times.map { Double($0) / Double(duration) }
                var values = channel.values
                // keyTimes 必须从 0 到 1：两头不够的用首 / 末值补齐。
                if let first = times.first, first > 0, let value = values.first {
                    times.insert(0, at: 0)
                    values.insert(value, at: 0)
                }
                if let last = times.last, last < 1, let value = values.last {
                    times.append(1)
                    values.append(value)
                }
                if times.count == 1, let value = values.first {
                    times = [0, 1]
                    values = [value, value]
                }
                let keyframes = CAKeyframeAnimation(keyPath: channel.keyPath)
                keyframes.values = values
                keyframes.keyTimes = times.map { NSNumber(value: $0) }
                keyframes.duration = Double(duration)
                keyframes.calculationMode = channel.discrete ? .discrete : .linear
                byNode[channel.node, default: []].append(keyframes)
            }
            let name = animation.name ?? "animation\(animationIndex)"
            let tracks = byNode.keys.sorted().map { GLTFClip.Track(node: nodes[$0], animations: byNode[$0] ?? []) }
            clips[name] = GLTFClip(name: name, duration: Double(duration), tracks: tracks)
        }
        return clips
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
