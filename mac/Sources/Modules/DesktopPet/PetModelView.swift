import AppKit
import SceneKit

/// 3D 形象的动作映射（pet.json 的 `clips`）：引擎状态 → 模型里的动画片段。
struct PetModelSpec {
    struct Clip {
        let name: String
        let loop: Bool
        /// 播完停在最后一帧（坐下 / 躺下这类过渡动作当「睡觉」用）。
        let hold: Bool
    }

    let url: URL
    /// 状态键（idle / walk / happy / sleep / drag）→ 片段；没写的按片段名猜（见 resolvedClips）。
    let clips: [String: PetClipSpec]
    /// 待机时偶尔播一次的小动作。
    let fidgets: [String]
    /// 模型正面不朝 +Z 时的修正（度）。
    let yawDegrees: Double
    /// 在自动取景的基础上再放大 / 缩小。
    let scale: Double

    /// 结合模型里实际有的片段名，给出每个状态用哪段。
    func resolvedClips(available: [String]) -> [String: Clip] {
        let lowered = Dictionary(available.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func find(_ keywords: [String]) -> String? {
            for keyword in keywords {
                if let exact = lowered[keyword] { return exact }
            }
            for keyword in keywords {
                if let hit = available.sorted().first(where: { $0.lowercased().contains(keyword) }) { return hit }
            }
            return nil
        }
        let guesses: [String: [String]] = [
            "idle": ["idle", "survey", "stand", "breath"],
            "walk": ["walk", "trot", "run"],
            "happy": ["jump", "wave", "yes", "happy", "dance", "run"],
            "sleep": ["sleep", "lie", "rest", "sit"],
        ]
        var result: [String: Clip] = [:]
        for state in ["idle", "walk", "happy", "sleep", "drag"] {
            let defaultLoop = state == "idle" || state == "walk" || state == "drag"
            if let explicit = clips[state], available.contains(explicit.clip) {
                result[state] = Clip(name: explicit.clip, loop: explicit.loop ?? defaultLoop,
                                     hold: explicit.hold ?? (state == "sleep"))
            } else if let keywords = guesses[state], let name = find(keywords) {
                result[state] = Clip(name: name, loop: defaultLoop, hold: state == "sleep")
            }
        }
        if result["idle"] == nil, let first = available.sorted().first {
            result["idle"] = Clip(name: first, loop: true, hold: false)
        }
        return result
    }
}

/// pet.json 里一个状态的片段：可以直接写片段名，也可以写 `{ "clip": "Sitting", "loop": false, "hold": true }`。
struct PetClipSpec: Decodable {
    var clip: String
    var loop: Bool?
    var hold: Bool?

    private enum CodingKeys: String, CodingKey { case clip, loop, hold }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            clip = name
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clip = try container.decode(String.self, forKey: .clip)
        loop = try container.decodeIfPresent(Bool.self, forKey: .loop)
        hold = try container.decodeIfPresent(Bool.self, forKey: .hold)
    }
}

/// 3D 渲染后端（设计 §7.2）：透明 SceneKit 视图，固定透视相机（轻微俯角）+ 方向光 + 环境光，无阴影。
/// 引擎只给姿态；这里换动画片段（交叉淡入淡出 150ms）、转身（走路侧身、待机 3/4 侧、提醒正对用户）、提醒时跳一下。
final class PetModelView: SCNView {
    var pose = PetPose() {
        didSet { apply(pose) }
    }

    private let bounceNode = SCNNode()
    private let yawNode = SCNNode()
    private let fitNode = SCNNode()
    private let orientNode = SCNNode()
    private var model: GLTFModel?
    private var clips: [String: PetModelSpec.Clip] = [:]
    private var currentClip: (state: String, clip: GLTFClip)?
    /// 一次性片段（如挥手）播完前不切走，免得提醒刚开始就被打断。
    private var clipLockedUntil = Date.distantPast
    /// 待机小动作（模型里实际有的那些）与下一次的时间。
    private var fidgets: [GLTFClip] = []
    private var nextFidgetAt = Date.distantFuture
    /// 睡觉的片段播完后整个场景暂停（不再渲染），省电（设计 §7.2）。
    private var sleepPauseAt = Date.distantFuture
    private var active = true
    private var yaw: Float = .nan
    private var bounceY: Float = 0

    private static let fieldOfView: CGFloat = 28
    private static let cameraDistance: Float = 3.0

    init() {
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 30
        isPlaying = true
        allowsCameraControl = false

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(bounceNode)
        bounceNode.addChildNode(yawNode)
        yawNode.addChildNode(fitNode)
        fitNode.addChildNode(orientNode)

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.zNear = 0.05
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // 模型被归一到「脚在 y=0、最高 1.1、最长 1.35」；相机略俯视，底下留一点点边，头顶留出提醒跳一下的空间。
        cameraNode.simdPosition = SIMD3(0, 0.95, Self.cameraDistance)
        cameraNode.simdLook(at: SIMD3(0, 0.64, 0))
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdEulerAngles = SIMD3(-0.9, -0.5, 0)
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        self.scene = scene
        pointOfView = cameraNode
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// 换形象。读模型失败返回 false（调用方回退 2D 占位）。
    @discardableResult
    func setPackage(_ package: PetPackage?) -> Bool {
        if let currentClip, let model { model.stop(currentClip.clip, fadeOut: 0) }
        orientNode.childNodes.forEach { $0.removeFromParentNode() }
        model = nil
        clips = [:]
        fidgets = []
        currentClip = nil
        yaw = .nan
        guard let spec = package?.model, let loaded = try? GLTFLoader.load(contentsOf: spec.url) else { return false }
        model = loaded
        clips = spec.resolvedClips(available: Array(loaded.clips.keys))
        fidgets = spec.fidgets.compactMap { loaded.clips[$0] }
        orientNode.simdEulerAngles = SIMD3(0, Float(spec.yawDegrees * .pi / 180), 0)
        orientNode.addChildNode(loaded.root)
        fit(scale: Float(spec.scale))
        apply(pose)
        return true
    }

    /// 宠物隐藏时停掉渲染循环。
    func setActive(_ active: Bool) {
        self.active = active
        isPlaying = active
        scene?.isPaused = !active
    }

    /// 归一化：脚踩 y=0、水平居中，高不超过 1.1、长（任意朝向）不超过 1.35 —— 走路侧身时也放得下。
    private func fit(scale: Float) {
        fitNode.simdScale = SIMD3(repeating: 1)
        fitNode.simdPosition = .zero
        let (lo, hi) = fitNode.boundingBox
        let height = max(Float(hi.y - lo.y), 1e-4)
        let horizontal = max(Float(hi.x - lo.x), Float(hi.z - lo.z), 1e-4)
        let s = min(1.1 / height, 1.35 / horizontal) * max(scale, 0.1)
        fitNode.simdScale = SIMD3(repeating: s)
        fitNode.simdPosition = SIMD3(-Float(lo.x + hi.x) / 2 * s, -Float(lo.y) * s, -Float(lo.z + hi.z) / 2 * s)
    }

    private func apply(_ pose: PetPose) {
        guard let model else { return }
        let state = Self.stateKey(pose.state)
        let now = Date()
        // 一次性片段（挥手）播完前不切走；待机小动作则可以被待机以外的状态（提醒 / 走路 / 拖拽 / 睡觉）立刻打断。
        let playingFidget = currentClip?.state == "fidget"
        let locked = now < clipLockedUntil && !(playingFidget && state != "idle")
        if currentClip?.state != state, !locked,
           let choice = clips[state] ?? clips["idle"], let next = model.clips[choice.name] {
            if next.name != currentClip?.clip.name || !choice.loop {
                if let old = currentClip?.clip { model.stop(old, fadeOut: 0.15) }
                model.play(next, loop: choice.loop, hold: choice.hold, fadeIn: currentClip == nil ? 0 : 0.15)
                clipLockedUntil = (!choice.loop && !choice.hold) ? now.addingTimeInterval(next.duration) : .distantPast
            }
            currentClip = (state, next)
            if state == "idle" { nextFidgetAt = now.addingTimeInterval(Double.random(in: 8...16)) }
            sleepPauseAt = state == "sleep" ? now.addingTimeInterval(next.duration + 0.3) : .distantFuture
        } else if state == "idle", currentClip?.state == "idle", !locked, now >= nextFidgetAt,
                  let fidget = fidgets.randomElement(), let current = currentClip?.clip {
            // 待机久了做个小动作，做完（锁到片段结束）再回待机循环。
            model.stop(current, fadeOut: 0.2)
            model.play(fidget, loop: false, hold: false, fadeIn: 0.2)
            currentClip = ("fidget", fidget)
            clipLockedUntil = now.addingTimeInterval(fidget.duration)
            nextFidgetAt = now.addingTimeInterval(fidget.duration + Double.random(in: 8...16))
        }

        // 帧率：走路 / 提醒 / 拖拽 30fps，待机呼吸 20fps 就够顺；睡下以后整个场景暂停，醒来再恢复。
        let fps = (state == "walk" || state == "happy" || state == "drag") ? 30 : 20
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        if let scene, active {
            let shouldPause = state == "sleep" && now >= sleepPauseAt
            if scene.isPaused != shouldPause { scene.isPaused = shouldPause }
        }

        let target: Float
        switch pose.state {
        case .wander: target = pose.facingLeft ? -.pi / 2 : .pi / 2
        case .notify: target = 0
        case .idle, .sleep, .dragged: target = pose.facingLeft ? -0.45 : 0.45
        }
        if yaw.isNaN {
            yaw = target
            yawNode.simdEulerAngles = SIMD3(0, target, 0)
        } else if abs(target - yaw) > 0.001 {
            yaw = target
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            yawNode.simdEulerAngles = SIMD3(0, target, 0)
            SCNTransaction.commit()
        }

        // 引擎的跳跃位移是屏幕点：按相机在模型处的可见高度换成场景单位。
        let visibleHeight = 2 * Self.cameraDistance * Float(tan(Self.fieldOfView / 2 * .pi / 180))
        let y = Float(pose.bounce) * visibleHeight / Float(max(bounds.height, 1))
        if abs(y - bounceY) > 0.0005 {
            bounceY = y
            bounceNode.simdPosition = SIMD3(0, y, 0)
        }
    }

    private static func stateKey(_ state: PetEngine.State) -> String {
        switch state {
        case .idle: return "idle"
        case .wander: return "walk"
        case .notify: return "happy"
        case .sleep: return "sleep"
        case .dragged: return "drag"
        }
    }

    // MARK: - 鼠标交给宠物窗（拖拽 / 点击菜单都在 PetPanel 里处理）

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { window?.rightMouseDown(with: event) }
}
