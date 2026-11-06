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
    /// 互动（poke / highFive / pet / feed / play / wake）→ 若干候选，每个候选是一串依次播放的片段。
    let interactions: [String: [[String]]]
    /// 模型正面不朝 +Z 时的修正（度）。
    let yawDegrees: Double
    /// 在自动取景的基础上再放大 / 缩小。
    let scale: Double
    /// 状态 → 每次进入时随机挑一个的片段（VRM 来通知时挥手 / 举手 / 万岁…轮着来）；没写的用 clips 里那一个。
    var stateVariants: [String: [String]] = [:]
    /// 待机多久做一次小动作（秒）。
    var fidgetInterval: ClosedRange<Double> = 8...16

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
            // 活动范围（ROAM.md）：跳上 / 掉下窗口、趴在窗口上。
            "jump": ["jump_up", "jump"],
            "fall": ["fall", "jump"],
            "rest": ["lie_prone", "lie", "rest", "sleep", "sit"],
        ]
        var result: [String: Clip] = [:]
        for state in ["idle", "walk", "happy", "sleep", "drag", "jump", "fall", "rest"] {
            let defaultLoop = state == "idle" || state == "walk" || state == "drag" || state == "fall"
            let defaultHold = state == "sleep" || state == "rest" || state == "jump"
            if let explicit = clips[state], available.contains(explicit.clip) {
                result[state] = Clip(name: explicit.clip, loop: explicit.loop ?? defaultLoop,
                                     hold: explicit.hold ?? defaultHold)
            } else if let keywords = guesses[state], let name = find(keywords) {
                result[state] = Clip(name: name, loop: defaultLoop, hold: defaultHold)
            }
        }
        if result["idle"] == nil, let first = available.sorted().first {
            result["idle"] = Clip(name: first, loop: true, hold: false)
        }
        return result
    }
}

extension PetModelSpec {
    static let interactionKinds = ["poke", "highFive", "pet", "feed", "play", "wake"]

    /// 每种互动的候选（只留模型里真有的片段）；没写的按片段名猜，猜不到就不支持（菜单里不显示）。
    func resolvedInteractions(available: [String]) -> [String: [[String]]] {
        let names = Set(available)
        let sorted = available.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        let guesses: [String: [String]] = [
            "poke": ["giggle", "laugh", "happy", "ear_perk", "wiggle", "yes", "jump", "hitreact"],
            "highFive": ["highfive", "high_five", "wave", "thumbsup"],
            "pet": ["listen_nod", "nod", "lap", "headlow", "purr"],
            "feed": ["sit_hold_eat", "eat", "chew", "drink"],
            "play": ["pounce", "bat_paw", "lie_play", "play", "dance", "attack", "punch"],
            "wake": ["get_up", "stand_up", "yawn", "stretch"],
        ]
        var result: [String: [[String]]] = [:]
        for kind in Self.interactionKinds {
            if let explicit = interactions[kind] {
                let valid = explicit.filter { !$0.isEmpty && $0.allSatisfy(names.contains) }
                if !valid.isEmpty { result[kind] = valid }
                continue
            }
            var options: [[String]] = []
            for keyword in guesses[kind] ?? [] {
                for name in sorted where name.lowercased().contains(keyword) && !options.contains([name]) {
                    options.append([name])
                }
                if options.count >= 3 { break }
            }
            if !options.isEmpty { result[kind] = Array(options.prefix(4)) }
        }
        return result
    }

    /// VRM 没写动作映射时用程序化动作的默认映射（docs/desktop-pet/VRM.md §4.2）。写了的照旧按 pet.json 来。
    /// 都是手臂离开身体、整个人动起来的大动作 —— 桌宠只有一两百像素高，手指、表情这种细节看不出来。
    func withVRMDefaults() -> PetModelSpec {
        guard clips.isEmpty, fidgets.isEmpty, interactions.isEmpty else { return self }
        var spec = PetModelSpec(
            url: url,
            clips: [
                "idle": PetClipSpec(clip: "idle"), "walk": PetClipSpec(clip: "walk"), "happy": PetClipSpec(clip: "wave"),
                "sleep": PetClipSpec(clip: "sleep", hold: true), "drag": PetClipSpec(clip: "drag"),
                "jump": PetClipSpec(clip: "jump_up", hold: true), "fall": PetClipSpec(clip: "fall", loop: true),
                "rest": PetClipSpec(clip: "lie_prone", loop: true),
            ],
            fidgets: ["look_around", "tilt_head", "stretch", "side_bend", "flamingo", "hands_behind", "sway_hum", "yawn"],
            interactions: [
                "poke": [["giggle"], ["jump"], ["startled"], ["lean_laugh"], ["shy"], ["pout"]],
                "highFive": [["high_five"], ["power_pose"], ["bow"], ["wave"]],
                "pet": [["nod"], ["shy"]],
                "feed": [["sit_down", "sit_hold_eat", "stand_up"]],
                "play": [["dance"], ["spin"], ["jumping_jacks"], ["boxing"], ["airplane"], ["twist_dance"], ["run_in_place"], ["cheer"]],
                "wake": [["get_up", "stretch"], ["get_up", "yawn"]],
            ],
            yawDegrees: yawDegrees,
            scale: scale
        )
        spec.stateVariants = ["happy": ["wave", "big_wave", "raise_hand", "banzai", "ta_da"]]
        spec.fidgetInterval = 5...10
        return spec
    }
}

/// pet.json 里互动的一个候选：一个片段名，或一串依次播放的片段名（如 ["sit_down", "sit_hold_eat", "stand_up"]）。
struct PetClipSequence: Decodable {
    var clips: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(String.self) {
            clips = [one]
        } else {
            clips = try container.decode([String].self)
        }
    }
}

/// pet.json 里一个状态的片段：可以直接写片段名，也可以写 `{ "clip": "Sitting", "loop": false, "hold": true }`。
struct PetClipSpec: Decodable {
    var clip: String
    var loop: Bool?
    var hold: Bool?

    private enum CodingKeys: String, CodingKey { case clip, loop, hold }

    init(clip: String, loop: Bool? = nil, hold: Bool? = nil) {
        self.clip = clip
        self.loop = loop
        self.hold = hold
    }

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
    /// 互动：当前形象支持哪些、正在播的一串里还剩哪些。
    private var interactions: [String: [[String]]] = [:]
    /// 状态 → 进入时随机挑的片段（见 PetModelSpec.stateVariants）。
    private var variants: [String: [GLTFClip]] = [:]
    private var fidgetInterval: ClosedRange<Double> = 8...16
    private var pendingSequence: [GLTFClip] = []
    private var lastState = "idle"
    /// 睡觉的片段播完后整个场景暂停（不再渲染），省电（设计 §7.2）。
    private var sleepPauseAt = Date.distantFuture
    private var active = true
    private var yaw: Float = .nan
    private var bounceY: Float = 0

    private static let fieldOfView: CGFloat = 28
    private static let cameraDistance: Float = 3.0
    /// 取景时模型被缩放了多少（模型单位 → 场景单位）。
    private var fitScale: Float = 1

    /// VRM 脚下的软影子：贴在地面上，人「站」在地上而不是飘着（试用反馈）。
    private let shadowNode: SCNNode = {
        let plane = SCNPlane(width: 1, height: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PetModelView.shadowImage()
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        node.renderingOrder = -1
        node.isHidden = true
        return node
    }()

    private static func shadowImage() -> NSImage {
        let side = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor(white: 0, alpha: 0.32).cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray,
                                     locations: [0, 1]) {
            let center = CGPoint(x: side / 2, y: side / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(side) / 2, options: [])
        }
        image.unlockFocus()
        return image
    }

    /// 脚底离视图底边占视图高度的比例（站到台面上时对齐用）：人形取景时脚放在场景 y = −0.1，毛绒形象在 0；
    /// 相机在模型处看到的底边约为 y = −0.136，可见高度约 1.51。2D 帧图脚本来就踩在底边。
    var footInsetFraction: CGFloat {
        guard model != nil else { return 0 }
        return isHumanoid ? 0.024 : 0.09
    }

    /// VRM 走路时宠物窗每秒该挪多少点，与步幅对上（脚踩在地上不打滑）；非 VRM 返回 nil（用默认速度）。
    func walkSpeed(viewHeight: CGFloat) -> CGFloat? {
        guard let rig = model?.vrm, viewHeight > 1 else { return nil }
        let visibleHeight = 2 * Self.cameraDistance * Float(tan(Self.fieldOfView / 2 * .pi / 180))
        return CGFloat(VRMMotion.groundSpeed(body: rig.body) * fitScale * Float(viewHeight) / visibleHeight)
    }

    init() {
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 30
        isPlaying = true
        allowsCameraControl = false

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.rootNode.addChildNode(shadowNode)
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

    /// 后台读模型（不碰当前显示的形象），读完在主线程交给 completion；读不出来给 nil。
    /// 20 MB 级的 VRM 读一次要 0.7–3.6 秒，放主线程会卡住整个 App（docs/desktop-pet/VRM.md §6）。
    static func loadModel(for package: PetPackage, completion: @escaping (GLTFModel?) -> Void) {
        guard let url = package.model?.url else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let model = try? GLTFLoader.load(contentsOf: url)
            DispatchQueue.main.async { completion(model) }
        }
    }

    /// 换形象（模型由 `loadModel` 读好）；package 或 model 为 nil = 清空。
    func setPackage(_ package: PetPackage?, model loaded: GLTFModel?) {
        if let currentClip, let model { model.stop(currentClip.clip, fadeOut: 0) }
        orientNode.childNodes.forEach { $0.removeFromParentNode() }
        model = nil
        clips = [:]
        fidgets = []
        interactions = [:]
        variants = [:]
        pendingSequence = []
        currentClip = nil
        yaw = .nan
        guard var spec = package?.model, let loaded else { return }
        if loaded.vrm != nil { spec = spec.withVRMDefaults() }
        model = loaded
        clips = spec.resolvedClips(available: Array(loaded.clips.keys))
        fidgets = spec.fidgets.compactMap { loaded.clips[$0] }
        interactions = spec.resolvedInteractions(available: Array(loaded.clips.keys))
        variants = spec.stateVariants.mapValues { $0.compactMap { loaded.clips[$0] } }.filter { !$0.value.isEmpty }
        fidgetInterval = spec.fidgetInterval
        // VRM 0.x 面朝 −Z，自动转过来（pet.json 不用写 yaw）。
        let facing: Double = loaded.vrm?.isVRM0 == true ? 180 : 0
        orientNode.simdEulerAngles = SIMD3(0, Float((spec.yawDegrees + facing) * .pi / 180), 0)
        orientNode.addChildNode(loaded.root)
        fit(scale: Float(spec.scale), humanoid: loaded.vrm != nil)
        loaded.vrm?.startBlinking()
        apply(pose)
    }

    /// 当前形象支不支持某种互动（环形菜单据此显示 / 隐藏「喂食」「陪玩」）。
    func supports(_ kind: String) -> Bool {
        interactions[kind] != nil
    }

    /// 做一个互动动作，返回总时长（引擎据此站住不动）；不支持返回 nil。
    @discardableResult
    func perform(_ kind: String) -> TimeInterval? {
        guard let model, let option = interactions[kind]?.randomElement() else { return nil }
        return play(sequence: option.compactMap { model.clips[$0] })
    }

    /// 按片段名播一串动作（健康提醒：喝水、伸懒腰）。模型里缺任何一段就不播、返回 nil。
    @discardableResult
    func performClips(_ names: [String]) -> TimeInterval? {
        guard let model, !names.isEmpty else { return nil }
        let sequence = names.compactMap { model.clips[$0] }
        guard sequence.count == names.count else { return nil }
        return play(sequence: sequence)
    }

    private func play(sequence: [GLTFClip]) -> TimeInterval? {
        guard let model, let first = sequence.first else { return nil }
        if let current = currentClip?.clip { model.stop(current, fadeOut: 0.15) }
        model.play(first, loop: false, hold: false, fadeIn: 0.15)
        currentClip = ("interact", first)
        clipLockedUntil = Date().addingTimeInterval(first.duration)
        pendingSequence = Array(sequence.dropFirst())
        scene?.isPaused = false
        return sequence.reduce(0) { $0 + $1.duration }
    }

    /// 宠物隐藏时停掉渲染循环。
    func setActive(_ active: Bool) {
        self.active = active
        isPlaying = active
        scene?.isPaused = !active
    }

    /// 归一化：脚踩 y=0、水平居中，高不超过 1.1、长（任意朝向）不超过 1.35 —— 走路侧身时也放得下。
    /// `humanoid`（VRM）：包围盒是 T 字姿势（臂展和身高差不多宽），只按身高取景；人又高又瘦，
    /// 撑满窗口高度的 83%、脚贴近窗口底边（毛绒形象是 73%，留出提醒时跳一下的空间）。
    private func fit(scale: Float, humanoid: Bool = false) {
        fitNode.simdScale = SIMD3(repeating: 1)
        fitNode.simdPosition = .zero
        let (lo, hi) = fitNode.boundingBox
        let height = max(Float(hi.y - lo.y), 1e-4)
        let horizontal = max(Float(hi.x - lo.x), Float(hi.z - lo.z), 1e-4)
        let s = (humanoid ? 1.26 / height : min(1.1 / height, 1.35 / horizontal)) * max(scale, 0.1)
        fitScale = s
        fitNode.simdScale = SIMD3(repeating: s)
        // 影子贴地：脚底所在高度，宽度按身高比例（人形才显示）。
        shadowNode.simdPosition = SIMD3(0, -0.098, 0)
        shadowNode.simdScale = SIMD3(0.5, 0.2, 1)
        fitNode.simdPosition = SIMD3(-Float(lo.x + hi.x) / 2 * s, -Float(lo.y) * s - (humanoid ? 0.1 : 0),
                                     -Float(lo.z + hi.z) / 2 * s)
    }

    /// 当前是不是 VRM 人形（控制器据此把宠物窗放大、只让人身上接点击）。
    var isHumanoid: Bool { model?.vrm != nil }

    /// 人物此刻在本视图里大致占的矩形：骨骼投影的外包框，再加头顶、头发和身体厚度的余量。
    /// 环形菜单围着它排（宠物窗是方的，人又高又瘦，围着窗口排两边空一大片）。非 VRM 返回 nil。
    func bodyBounds() -> CGRect? {
        guard let rig = model?.vrm else { return nil }
        func screen(_ bone: String) -> CGPoint? {
            guard let node = rig.bones[bone]?.node else { return nil }
            let p = projectPoint(node.presentation.worldPosition)
            return CGPoint(x: p.x, y: p.y)
        }
        guard let hips = screen("hips"), let head = screen("head") else { return nil }
        let unit = max(hypot(head.x - hips.x, head.y - hips.y), 6)
        let crown = CGPoint(x: head.x + (head.x - hips.x) * 0.45, y: head.y + (head.y - hips.y) * 0.45)
        var points = [hips, head, crown]
        points += ["leftHand", "rightHand", "leftLowerArm", "rightLowerArm", "leftUpperArm", "rightUpperArm",
                   "leftFoot", "rightFoot"].compactMap(screen)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -unit * 0.22, dy: -unit * 0.08)
    }

    /// 鼠标点（本视图坐标）是不是落在人物身上：按此刻动画里各骨骼的屏幕投影粗算 ——
    /// 头一个圆、躯干一段胶囊、四肢各两段胶囊，半径按 hips 到头的距离等比放大。头发、裙摆外沿不算。
    /// 非 VRM 形象整个窗口都算（保持原来的命中区）。
    func hitsBody(at point: CGPoint) -> Bool {
        guard let rig = model?.vrm else { return true }
        func screen(_ bone: String) -> CGPoint? {
            guard let node = rig.bones[bone]?.node else { return nil }
            let p = projectPoint(node.presentation.worldPosition)
            return CGPoint(x: p.x, y: p.y)
        }
        guard let hips = screen("hips"), let head = screen("head") else { return true }
        let unit = max(hypot(head.x - hips.x, head.y - hips.y), 6)
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let k = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
            return hypot(p.x - (a.x + k * dx), p.y - (a.y + k * dy))
        }
        // 头：头骨在下巴附近，往头顶方向挪一点当圆心。
        let crown = CGPoint(x: head.x + (head.x - hips.x) * 0.25, y: head.y + (head.y - hips.y) * 0.25)
        if hypot(point.x - crown.x, point.y - crown.y) <= unit * 0.4 { return true }
        if distance(point, hips, head) <= unit * 0.32 { return true }
        for chain in [["leftUpperArm", "leftLowerArm", "leftHand"], ["rightUpperArm", "rightLowerArm", "rightHand"],
                      ["leftUpperLeg", "leftLowerLeg", "leftFoot"], ["rightUpperLeg", "rightLowerLeg", "rightFoot"]] {
            let points = chain.compactMap(screen)
            for (a, b) in zip(points, points.dropFirst()) where distance(point, a, b) <= unit * 0.16 {
                return true
            }
        }
        return false
    }

    private func apply(_ pose: PetPose) {
        guard let model else { return }
        let state = Self.stateKey(pose.state)
        let now = Date()
        // 从睡梦中被叫醒：先播「起身 / 打哈欠」。
        if lastState == "sleep", state == "idle", interactions["wake"] != nil {
            lastState = state
            perform("wake")
            return
        }
        lastState = state
        // 落地（从跳 / 掉的状态出来）：先播一下落地缓冲，再回到正常状态。
        let wasAirborne = currentClip?.state == "jump" || currentClip?.state == "fall"
        if wasAirborne, state != "jump", state != "fall", state != "drag", let landing = model.clips["land"] {
            lastState = state
            _ = play(sequence: [landing])
            return
        }
        // 一串互动片段：上一段播完接下一段。
        if currentClip?.state == "interact", now >= clipLockedUntil, !pendingSequence.isEmpty {
            let next = pendingSequence.removeFirst()
            if let current = currentClip?.clip { model.stop(current, fadeOut: 0.12) }
            model.play(next, loop: false, hold: false, fadeIn: 0.12)
            currentClip = ("interact", next)
            clipLockedUntil = now.addingTimeInterval(next.duration)
        }
        // 一次性片段（挥手）播完前不切走；待机小动作 / 互动则可以被待机以外的状态（提醒 / 拖拽 / 走路 / 睡觉）立刻打断。
        let interruptible = currentClip?.state == "fidget" || currentClip?.state == "interact"
        let locked = now < clipLockedUntil && !(interruptible && state != "idle")
        if currentClip?.state != state, !locked,
           let choice = clips[state] ?? clips["idle"],
           let next = variants[state]?.randomElement() ?? model.clips[choice.name] {
            if next.name != currentClip?.clip.name || !choice.loop {
                // 趴下 / 起来是整个身子翻过去，交叉淡入淡出拉长一些，看着像「趴下去」而不是一下子变过去。
                let fade: CGFloat = currentClip == nil ? 0 : (state == "rest" || currentClip?.state == "rest" ? 0.6 : 0.15)
                if let old = currentClip?.clip { model.stop(old, fadeOut: fade) }
                model.play(next, loop: choice.loop, hold: choice.hold, fadeIn: fade)
                clipLockedUntil = (!choice.loop && !choice.hold) ? now.addingTimeInterval(next.duration) : .distantPast
            }
            currentClip = (state, next)
            pendingSequence = []
            if state == "idle" { nextFidgetAt = now.addingTimeInterval(Double.random(in: fidgetInterval)) }
            sleepPauseAt = state == "sleep" ? now.addingTimeInterval(next.duration + 0.3) : .distantFuture
        } else if state == "idle", currentClip?.state == "idle", !locked, now >= nextFidgetAt,
                  let fidget = fidgets.randomElement(), let current = currentClip?.clip {
            // 待机久了做个小动作，做完（锁到片段结束）再回待机循环。
            model.stop(current, fadeOut: 0.2)
            model.play(fidget, loop: false, hold: false, fadeIn: 0.2)
            currentClip = ("fidget", fidget)
            clipLockedUntil = now.addingTimeInterval(fidget.duration)
            nextFidgetAt = now.addingTimeInterval(fidget.duration + Double.random(in: fidgetInterval))
        }

        // 帧率：走路 / 提醒 / 拖拽 30fps，待机呼吸 20fps 就够顺；睡下以后整个场景暂停，醒来再恢复。
        let lively = state == "walk" || state == "happy" || state == "drag" || currentClip?.state == "interact"
        let fps = lively ? 30 : 20
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        if let scene, active {
            let shouldPause = state == "sleep" && now >= sleepPauseAt
            if scene.isPaused != shouldPause { scene.isPaused = shouldPause }
        }

        let target: Float
        switch pose.state {
        case .wander: target = pose.facingLeft ? -.pi / 2 : .pi / 2
        case .notify, .rest: target = 0
        case .idle, .sleep, .dragged, .jump, .fall: target = pose.attentive ? 0 : (pose.facingLeft ? -0.45 : 0.45)
        }
        // 在空中时脚下的影子藏起来（影子在宠物窗里，跟着窗口飞，留着反而像踩着它）。
        let airborne = pose.state == .jump || pose.state == .fall
        if shadowNode.isHidden != (airborne || model.vrm == nil) { shadowNode.isHidden = airborne || model.vrm == nil }
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
        case .jump: return "jump"
        case .fall: return "fall"
        case .rest: return "rest"
        }
    }

    // MARK: - 鼠标交给宠物窗（拖拽 / 点击菜单都在 PetPanel 里处理）

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { window?.rightMouseDown(with: event) }
}
