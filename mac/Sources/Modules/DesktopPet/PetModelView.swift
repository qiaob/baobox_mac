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
    /// 出场落地后 / 退场前播的一串片段（pet.json 的 enter / leave，#54）；空 = 用默认。
    var enterClips: [String] = []
    var leaveClips: [String] = []
    /// 待机站姿（循环片段）：长时间站着时和平常的 idle 轮换（docs/desktop-pet/SETTLE.md §5.1）。
    var idleStances: [String] = []
    /// 偶尔来一段的大动作（自娱自乐），比普通小动作少见。
    var bigFidgets: [String] = []

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
        guard clips.isEmpty, fidgets.isEmpty, interactions.isEmpty else {
            var spec = self
            if spec.enterClips.isEmpty { spec.enterClips = ["wave"] }
            if spec.leaveClips.isEmpty { spec.leaveClips = ["bye"] }
            return spec
        }
        var spec = PetModelSpec(
            url: url,
            clips: [
                // 走路用动捕的（docs/desktop-pet/MOCAP.md）：平时这段，心情好 / 活泼时换另外两段（见 gaitClips）。
                // 资源读不到时 resolvedClips 按名字回退到程序做的 walk。
                "idle": PetClipSpec(clip: "idle"), "walk": PetClipSpec(clip: "walk_feminine"), "happy": PetClipSpec(clip: "wave"),
                "sleep": PetClipSpec(clip: "sleep", hold: true), "drag": PetClipSpec(clip: "drag"),
                "jump": PetClipSpec(clip: "jump_up", hold: true), "fall": PetClipSpec(clip: "fall", loop: true),
                "rest": PetClipSpec(clip: "lie_prone", loop: true),
            ],
            // 原地小动作（docs/desktop-pet/SETTLE.md §5.2）：后八个是 2026-11 用户反馈「站着太单调」加的。
            fidgets: ["look_around", "tilt_head", "stretch", "side_bend", "flamingo", "hands_behind", "sway_hum", "yawn",
                      "rock_heels", "kick_ground", "fix_hair", "look_up", "hum_bounce", "arms_cross_tap",
                      "neck_stretch", "peek"],
            interactions: [
                "poke": [["giggle"], ["jump"], ["startled"], ["lean_laugh"], ["shy"], ["pout"]],
                "highFive": [["high_five"], ["power_pose"], ["bow"], ["wave"]],
                "pet": [["nod"], ["shy"]],
                "feed": [["sit_down", "sit_hold_eat", "stand_up"]],
                "play": [["dance"], ["spin"], ["jumping_jacks"], ["boxing"], ["airplane"], ["twist_dance"], ["run_in_place"], ["cheer"]],
                // 你回来了：起身后伸懒腰 / 打哈欠 / 朝你招手。
                "wake": [["get_up", "stretch"], ["get_up", "yawn"], ["get_up", "wave"], ["get_up", "big_wave"]],
            ],
            yawDegrees: yawDegrees,
            scale: scale
        )
        spec.stateVariants = ["happy": ["wave", "big_wave", "raise_hand", "banzai", "ta_da"]]
        spec.fidgetInterval = 5...10
        spec.idleStances = ["idle_hands_behind", "idle_arms_crossed", "idle_hands_front", "idle_hip"]
        spec.bigFidgets = ["dance", "twist_dance", "cheer", "power_pose", "airplane", "jumping_jacks", "spin",
                           "run_in_place"]
        spec.enterClips = enterClips.isEmpty ? ["wave"] : enterClips
        spec.leaveClips = leaveClips.isEmpty ? ["bye"] : leaveClips
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
    /// 出场 / 退场片段（模型里实际有的；缺任何一段就整串不用，回退到跳一下）。
    private var enterSequence: [GLTFClip] = []
    private var leaveSequence: [GLTFClip] = []
    private var pendingSequence: [GLTFClip] = []
    private var lastState = "idle"
    /// 睡觉的片段播完后停渲染，省电（设计 §7.2）。实测 `scene.isPaused` 只停动画、不停渲染（仍 20 fps 画同一个姿势），
    /// 所以睡着时连 `isPlaying` 一起关（docs/desktop-pet/WAKE.md §3）。
    private var sleepPauseAt = Date.distantFuture
    private var dozing = false
    private var active = true
    /// 系统睡眠 / 熄屏期间（控制器设）：停掉渲染循环与动画时钟，醒来由 `restartAnimations` 从头接上。
    var suspended = false {
        didSet { if suspended != oldValue { updateRenderLoop() } }
    }
    private var yaw: Float = .nan
    private var bounceY: Float = 0

    // MARK: 看门狗（docs/desktop-pet/WAKE.md §4）

    private let heartbeat = PetRenderHeartbeat()
    private var watchdog: Timer?
    /// 连续几秒没出帧 / 骨骼没动。
    private var stallSeconds = 0
    private var stillSeconds = 0
    private var lastPoseSignature = ""
    private var lastRestart = Date.distantPast
    /// 当前片段是循环的（待机 / 走路 / 趴着…）：只有这种片段骨骼该一直在动，才拿来判断卡没卡。
    private var currentLoops = false
    private var currentSpeed: CGFloat = 1

    // MARK: 原地动作（docs/desktop-pet/SETTLE.md §5）

    /// 待机站姿：长时间站着时隔半分钟到一分半换一种（交叉淡入淡出 0.6 秒）。只有一种时不换。
    private var stances: [GLTFClip] = []
    private var stance: GLTFClip?
    private var nextStanceAt = Date.distantFuture
    /// 偶尔来一段的大动作（跳舞、开合跳…），两分钟内最多一次。
    private var bigFidgets: [GLTFClip] = []
    private var lastBigFidgetAt = Date.distantPast
    private var lastFidgetName = ""
    /// 赶路时的跑步片段（没有就把走路加快）。
    private var runClip: GLTFClip?
    /// 各种走法的走路片段（VRM 的动捕走路，docs/desktop-pet/MOCAP.md §3）；没有的走法用 clips["walk"]。
    private var gaitClips: [PetGait: GLTFClip] = [:]
    private static let gaitClipNames: [PetGait: String] = [.calm: "walk_feminine", .happy: "walk_happy", .playful: "walk_childish"]
    /// 跳 / 飞的片段（docs/desktop-pet/SETTLE.md §4.4，VRM 的程序化动作里有）：引擎报到哪一段就播哪一段。
    /// 没有这些片段的形象按老办法播 jump / fall / land。
    private var flightClips: [String: GLTFClip] = [:]
    private static let flightClipNames = ["jump_crouch", "jump_rise", "jump_fall", "jump_spin", "jump_reach", "jump_land",
                                          "hop_crouch", "hop_fall", "boost_crouch", "fly", "fly_down", "boost_brake"]
    /// 背包式火箭助推器（VRM 才有）：飞的时候弹出来、喷火，落地收起。
    private var booster: VRMBooster?
    private var boosterShown = false
    private var boosterHideWork: DispatchWorkItem?
    /// 当前跳 / 飞片段是什么时候开始播的（点火蹲下要播完才接飞行）。
    private var flightClipStartedAt = Date.distantPast
    /// 歇脚的几种（坐地、蹲着）：坐下 → 坐着循环 → 起身；这一回用的是哪种。
    private typealias Lounge = (down: GLTFClip, loop: GLTFClip, up: GLTFClip)
    private var lounges: [Lounge] = []
    private var lounge: Lounge?

    // MARK: 头跟着鼠标转（docs/desktop-pet/SETTLE.md §5.3）

    private let look = PetLookState()
    private var lookInfluence: Float = 0
    private var lookYaw: Float = 0
    private var lookPitch: Float = 0
    private var lastMouse = NSPoint.zero
    private var mouseMovedAt = Date.distantPast

    private static let fieldOfView: CGFloat = 28
    /// 人形睡觉时转多少（弧度，约 57°）：侧身坐着，正面的裙底被大腿挡住；再转多了脸被头发挡住。
    private static let sleepYaw: Float = 1.0
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
    /// 平常的走法（动捕的那段，没有就是程序做的 walk）。
    func walkSpeed(viewHeight: CGFloat) -> CGFloat? {
        guard let rig = model?.vrm else { return nil }
        let speed = VRMMocap.groundSpeed(clips["walk"]?.name ?? "", body: rig.body) ?? VRMMotion.groundSpeed(body: rig.body)
        return points(speed, viewHeight: viewHeight)
    }

    /// 各种走法的速度（点 / 秒）：每段动捕走路步幅不同，宠物窗按各自的速度挪。
    func gaitSpeeds(viewHeight: CGFloat) -> [PetGait: CGFloat] {
        guard let rig = model?.vrm else { return [:] }
        return gaitClips.compactMapValues { clip in
            VRMMocap.groundSpeed(clip.name, body: rig.body).flatMap { points($0, viewHeight: viewHeight) }
        }
    }

    /// 跑步的速度（点 / 秒，按跑步片段的步幅算）；没有跑步片段返回 nil（引擎把走路加快）。
    func runSpeed(viewHeight: CGFloat) -> CGFloat? {
        guard let rig = model?.vrm, runClip != nil else { return nil }
        return points(VRMMotion.runGroundSpeed(body: rig.body), viewHeight: viewHeight)
    }

    /// 模型单位 / 秒 → 宠物窗点 / 秒（相机在模型处看到的高度 ↔ 视图高度）。
    private func points(_ modelSpeed: Float, viewHeight: CGFloat) -> CGFloat? {
        guard viewHeight > 1 else { return nil }
        let visibleHeight = 2 * Self.cameraDistance * Float(tan(Self.fieldOfView / 2 * .pi / 180))
        return CGFloat(modelSpeed * fitScale * Float(viewHeight) / visibleHeight)
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
        delegate = heartbeat
        startWatchdog()
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
        enterSequence = []
        leaveSequence = []
        pendingSequence = []
        currentClip = nil
        currentLoops = false
        currentSpeed = 1
        stances = []
        stance = nil
        bigFidgets = []
        runClip = nil
        gaitClips = [:]
        flightClips = [:]
        booster?.hide(animated: false)
        booster = nil
        boosterShown = false
        boosterHideWork?.cancel()
        boosterHideWork = nil
        lounges = []
        lounge = nil
        lookInfluence = 0
        look.set(yaw: 0, pitch: 0, influence: 0)
        yaw = .nan
        presentationScale = CGSize(width: 1, height: 1)
        // 旧形象的锁（一次性动作没播完）、睡着停渲染、上一个状态都清掉：不然新形象第一拍被锁住，停在 T 字好几秒。
        clipLockedUntil = .distantPast
        lastState = "idle"
        sleepPauseAt = .distantFuture
        if dozing {
            dozing = false
            updateRenderLoop()
        }
        guard var spec = package?.model, let loaded else { return }
        if loaded.vrm != nil { spec = spec.withVRMDefaults() }
        model = loaded
        clips = spec.resolvedClips(available: Array(loaded.clips.keys))
        fidgets = spec.fidgets.compactMap { loaded.clips[$0] }
        // 站姿：第一种是平常的待机（pet.json 写的 / 按名字猜的 idle），其余是模型里有的那几种。
        let idleClip = clips["idle"].flatMap { loaded.clips[$0.name] }
        stances = ([idleClip] + spec.idleStances.map { loaded.clips[$0] }).compactMap { $0 }
        stance = stances.first
        nextStanceAt = Date().addingTimeInterval(Double.random(in: 35...90))
        bigFidgets = spec.bigFidgets.compactMap { loaded.clips[$0] }
        // 跑步、蹲、坐地只有 VRM 的程序化动作里有（毛绒 / 动物模型按名字也找不到就不用）。
        if loaded.vrm != nil {
            runClip = loaded.clips["run"]
            // pet.json 自己写了走路片段的照它的来，只有用默认映射（动捕的那段）时才按场景换三种走法。
            if clips["walk"]?.name == Self.gaitClipNames[.calm] {
                gaitClips = Self.gaitClipNames.compactMapValues { loaded.clips[$0] }
            }
            flightClips = Dictionary(uniqueKeysWithValues: Self.flightClipNames.compactMap { name in
                loaded.clips[name].map { (name, $0) }
            })
            if let rig = loaded.vrm, flightClips["fly"] != nil { booster = VRMBooster(rig: rig) }
            lounges = [("sit_ground_down", "sit_ground", "sit_ground_up"), ("squat_down", "squat", "squat_up")]
                .compactMap { names -> Lounge? in
                    guard let down = loaded.clips[names.0], let loop = loaded.clips[names.1],
                          let up = loaded.clips[names.2] else { return nil }
                    return (down, loop, up)
                }
        }
        interactions = spec.resolvedInteractions(available: Array(loaded.clips.keys))
        variants = spec.stateVariants.mapValues { $0.compactMap { loaded.clips[$0] } }.filter { !$0.value.isEmpty }
        fidgetInterval = spec.fidgetInterval
        func sequence(_ names: [String]) -> [GLTFClip] {
            let found = names.compactMap { loaded.clips[$0] }
            return found.count == names.count ? found : []
        }
        enterSequence = sequence(spec.enterClips)
        leaveSequence = sequence(spec.leaveClips)
        // VRM 0.x 面朝 −Z，自动转过来（pet.json 不用写 yaw）。
        let facing: Double = loaded.vrm?.isVRM0 == true ? 180 : 0
        orientNode.simdEulerAngles = SIMD3(0, Float((spec.yawDegrees + facing) * .pi / 180), 0)
        orientNode.addChildNode(loaded.root)
        fit(scale: Float(spec.scale), humanoid: loaded.vrm != nil)
        loaded.vrm?.startBlinking()
        setUpLook(loaded.vrm)
        apply(pose)
    }

    /// 头跟着鼠标转：给头骨挂一个朝向约束，在动画算出来的朝向上再转一点（左右最多约 34°、上下 17°）。
    /// 角度由主线程每帧算好写进 `look`，约束在渲染线程里读。转动在模型空间里做：换到头骨父节点的静止朝向下再乘上去
    /// （脖子 / 身子在动时有一点误差，角度小看不出来）。
    private func setUpLook(_ rig: VRMRig?) {
        guard let rig, let head = rig.bones["head"] else { return }
        let parent = head.parentWorldRest
        let parentInverse = parent.inverse
        // VRM 0.x 在模型空间里面朝 −Z（orientNode 转了 180°）：「抬头」绕 X 轴的方向相反。
        let facing: Float = rig.isVRM0 ? -1 : 1
        let state = look
        let constraint = SCNTransformConstraint.orientationConstraint(inWorldSpace: false) { _, quaternion in
            let (yaw, pitch, influence) = state.read()
            guard influence > 0.001 else { return quaternion }
            let turn = simd_quatf(angle: yaw * influence, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -pitch * facing * influence, axis: SIMD3<Float>(1, 0, 0))
            let local = simd_quatf(ix: Float(quaternion.x), iy: Float(quaternion.y), iz: Float(quaternion.z),
                                   r: Float(quaternion.w))
            let result = parentInverse * turn * parent * local
            return SCNQuaternion(CGFloat(result.imag.x), CGFloat(result.imag.y), CGFloat(result.imag.z),
                                 CGFloat(result.real))
        }
        head.node.constraints = [constraint]
    }

    /// 做一个互动动作，返回总时长（引擎据此站住不动）；不支持返回 nil。
    /// 不挑正在播的那一个（连戳两下抽到同一个，同名片段一替换会从绑定姿势淡入，闪一下 T 字）。
    @discardableResult
    func perform(_ kind: String) -> TimeInterval? {
        guard let model, let options = interactions[kind] else { return nil }
        let fresh = options.filter { $0.first != currentClip?.clip.name }
        guard let option = fresh.randomElement() ?? options.randomElement() else { return nil }
        return play(sequence: option.compactMap { model.clips[$0] })
    }

    /// 从打盹醒来那一下（起身 + 伸懒腰 / 打哈欠 / 招手）最长要多久：引擎这段时间里不溜达、不歇脚。没有就 0.5 秒。
    var wakeDuration: TimeInterval {
        guard let model, let options = interactions["wake"] else { return 0.5 }
        return options.map { $0.compactMap { model.clips[$0]?.duration }.reduce(0, +) }.max() ?? 0.5
    }

    /// 按片段名播一串动作（健康提醒：喝水、伸懒腰）。模型里缺任何一段就不播、返回 nil。
    @discardableResult
    func performClips(_ names: [String]) -> TimeInterval? {
        guard let model, !names.isEmpty else { return nil }
        let sequence = names.compactMap { model.clips[$0] }
        guard sequence.count == names.count else { return nil }
        return play(sequence: sequence)
    }

    /// 有没有出场 / 退场片段（编排据此决定要不要留时间给它）。
    func hasEntranceClip(leaving: Bool) -> Bool {
        !(leaving ? leaveSequence : enterSequence).isEmpty
    }

    /// 出场落地后打招呼 / 退场前道别（#54）：播 pet.json 的 enter / leave（VRM 默认招手 / 道别）。没有返回 nil。
    @discardableResult
    func performEntrance(leaving: Bool) -> TimeInterval? {
        let sequence = leaving ? leaveSequence : enterSequence
        guard !sequence.isEmpty else { return nil }
        return play(sequence: sequence)
    }

    /// 出场 / 退场时的形变（以脚底为原点横竖缩放，落地压扁一下）。VRM 有自己的落地片段，不用它。
    var presentationScale = CGSize(width: 1, height: 1) {
        didSet {
            guard presentationScale != oldValue else { return }
            bounceNode.simdScale = SIMD3(Float(presentationScale.width), Float(presentationScale.height),
                                         Float(presentationScale.width))
        }
    }

    /// 会不会蹲 / 坐地（引擎据此决定要不要歇脚）。
    var supportsLounge: Bool { !lounges.isEmpty }

    /// 人有多高（占视图高度的比例）：人形取景时身高缩放到 1.26、相机在模型处看到约 1.496 高（84%）；
    /// 毛绒形象撑满 73%。引擎按它算跳多高、飞多快。
    var bodyHeightFraction: CGFloat {
        guard model != nil else { return 0.7 }
        return isHumanoid ? 0.842 : 0.73
    }

    /// 某个片段多长（引擎按跳 / 飞各段的片段排时间）；没有返回 nil。
    func clipDuration(_ name: String) -> TimeInterval? {
        flightClips[name]?.duration
    }

    /// 站起来要多久（引擎等它站起来再走）。
    var loungeExitDuration: TimeInterval { lounges.map(\.up.duration).max() ?? 1.2 }

    /// 蹲 / 坐地（docs/desktop-pet/SETTLE.md §5.5）：进入时随机挑一种，先坐下（锁住、停在最后一帧）再接坐着的循环；
    /// 离开时先起身（锁住）再交给正常的状态切换。被拎起来、跳、掉时不起身直接切走（`urgent`）。返回 true = 这一帧归它管。
    private func updateLounge(state: String, urgent: Bool, now: Date, model: GLTFModel) -> Bool {
        let phase = currentClip?.state
        if state == "lounge" {
            if phase == "lounge" { return true }
            if phase == "lounge_down" {
                if now >= clipLockedUntil, let kind = lounge, let current = currentClip?.clip {
                    model.stop(current, fadeOut: 0.25)
                    model.play(kind.loop, loop: true, hold: false, fadeIn: 0.25)
                    currentClip = ("lounge", kind.loop)
                    currentLoops = true
                    currentSpeed = 1
                    clipLockedUntil = .distantPast
                }
                return true
            }
            // 动画刚整个重建过（currentClip 清空了）还在歇脚：接着原来那种坐着的循环，不从 T 字淡入、不重新坐一遍。
            if phase == nil, let kind = lounge {
                model.play(kind.loop, loop: true, hold: false, fadeIn: 0)
                currentClip = ("lounge", kind.loop)
                currentLoops = true
                currentSpeed = 1
                clipLockedUntil = .distantPast
                return true
            }
            // 手上还有没播完的一次性片段（挥手、互动）：等它播完再坐。
            let interruptible = phase == "fidget" || phase == "interact"
            if now < clipLockedUntil, !interruptible { return true }
            guard let kind = lounges.randomElement() else { return false }
            lounge = kind
            if let current = currentClip?.clip { model.stop(current, fadeOut: 0.3) }
            model.play(kind.down, loop: false, hold: true, fadeIn: currentClip == nil ? 0 : 0.3)
            currentClip = ("lounge_down", kind.down)
            currentLoops = false
            currentSpeed = 1
            clipLockedUntil = now.addingTimeInterval(kind.down.duration)
            pendingSequence = []
            return true
        }
        if urgent { return false }
        if phase == "lounge" || phase == "lounge_down", let kind = lounge, let current = currentClip?.clip {
            model.stop(current, fadeOut: 0.2)
            model.play(kind.up, loop: false, hold: false, fadeIn: 0.2)
            currentClip = ("lounge_up", kind.up)
            currentLoops = false
            currentSpeed = 1
            clipLockedUntil = now.addingTimeInterval(kind.up.duration)
            return true
        }
        return phase == "lounge_up" && now < clipLockedUntil
    }

    private func play(sequence: [GLTFClip], fade: CGFloat = 0.15) -> TimeInterval? {
        // 坐着 / 蹲着时被戳、来提醒：先站起来再做。
        var sequence = sequence
        if currentClip?.state == "lounge" || currentClip?.state == "lounge_down", let up = lounge?.up {
            sequence.insert(up, at: 0)
        }
        guard let model, let first = sequence.first else { return nil }
        if let current = currentClip?.clip { model.stop(current, fadeOut: fade) }
        model.play(first, loop: false, hold: false, fadeIn: fade)
        currentClip = ("interact", first)
        currentLoops = false
        currentSpeed = 1
        clipLockedUntil = Date().addingTimeInterval(first.duration)
        pendingSequence = Array(sequence.dropFirst())
        dozing = false
        updateRenderLoop()
        return sequence.reduce(0) { $0 + $1.duration }
    }

    /// 宠物隐藏时停掉渲染循环。
    func setActive(_ active: Bool) {
        self.active = active
        updateRenderLoop()
    }

    /// 渲染循环与动画时钟：宠物开着、系统没睡、没睡着才跑。
    private func updateRenderLoop() {
        let run = active && !suspended && !dozing
        if isPlaying != run { isPlaying = run }
        if let scene, scene.isPaused == run { scene.isPaused = !run }
    }

    /// 从头接上动画（docs/desktop-pet/WAKE.md §3）：清掉骨骼和表情上所有动画、重置片段状态、重新眨眼、重开渲染循环，
    /// 再按当前姿态放片段 —— 当成刚换上这个形象一样。系统唤醒 / 解锁后与看门狗发现卡住时调用。
    func restartAnimations(reason: String) {
        guard let model else { return }
        PetLog.log.info("restart animations: \(reason, privacy: .public)")
        model.root.enumerateHierarchy { node, _ in node.removeAllAnimations() }
        currentClip = nil
        currentLoops = false
        currentSpeed = 1
        clipLockedUntil = .distantPast
        pendingSequence = []
        nextFidgetAt = Date().addingTimeInterval(Double.random(in: fidgetInterval))
        model.vrm?.startBlinking()
        // 助推器挂在骨骼下面，火焰的闪烁 / 光晕也被一起清掉了：装回去。
        booster?.restartEffects()
        dozing = false
        // 渲染循环也关了再开：唤醒后不出画面的可能是它。
        isPlaying = false
        updateRenderLoop()
        stallSeconds = 0
        stillSeconds = 0
        lastPoseSignature = ""
        apply(pose)
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// 每秒一次：该动的时候（开着、没睡、窗口看得见）连续 2 秒没出帧 → 先重开渲染循环，再不行就整个重来；
    /// 出帧了但循环片段上骨骼 2 秒纹丝不动 → 整个重来。每次都写日志，下次卡住能看出是哪种。
    private func checkHealth() {
        let frames = heartbeat.take()
        guard let model, active, !suspended, !dozing, isPlaying, let window, window.isVisible,
              window.occlusionState.contains(.visible) else {
            stallSeconds = 0
            stillSeconds = 0
            lastPoseSignature = ""
            return
        }
        let now = Date()
        if frames == 0 {
            stallSeconds += 1
            if stallSeconds == 2 {
                PetLog.log.error("watchdog: no frames for 2 s (state \(self.currentClip?.state ?? "-", privacy: .public)); restarting the render loop")
                isPlaying = false
                updateRenderLoop()
                needsDisplay = true
            } else if stallSeconds >= 5, now.timeIntervalSince(lastRestart) > 30 {
                lastRestart = now
                PetLog.log.error("watchdog: still no frames after kicking the render loop")
                restartAnimations(reason: "watchdog: no frames")
            }
            return
        }
        stallSeconds = 0
        guard model.vrm != nil, currentLoops, let state = currentClip?.state,
              ["idle", "walk", "rest", "fall", "drag", "lounge", "flight"].contains(state) else {
            stillSeconds = 0
            lastPoseSignature = ""
            return
        }
        let signature = poseSignature()
        if !signature.isEmpty, signature == lastPoseSignature {
            stillSeconds += 1
            if stillSeconds >= 2, now.timeIntervalSince(lastRestart) > 20 {
                lastRestart = now
                PetLog.log.error("watchdog: \(frames) frames/s but the skeleton is frozen on looping clip \(state, privacy: .public)")
                restartAnimations(reason: "watchdog: frozen skeleton")
            }
        } else {
            stillSeconds = 0
        }
        lastPoseSignature = signature
    }

    /// 几根主要骨骼此刻的朝向（渲染出来的那一份），比较两次一样不一样。
    private func poseSignature() -> String {
        guard let rig = model?.vrm else { return "" }
        var parts: [String] = []
        for name in ["hips", "spine", "head", "leftUpperArm", "rightUpperArm", "leftUpperLeg"] {
            guard let node = rig.bones[name]?.node.presentation else { continue }
            let q = node.simdOrientation.vector
            parts.append(String(format: "%.4f,%.4f,%.4f,%.4f", q.x, q.y, q.z, q.w))
        }
        return parts.joined(separator: "|")
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
        // 跳 / 飞（SETTLE.md §4.4）：引擎报到哪一段就播哪一段，火箭跟着弹出、喷火。
        updateBooster(pose.flight)
        if let flight = pose.flight, !flightClips.isEmpty {
            if let choice = Self.flightClip(flight), let clip = flightClips[choice.name],
               currentClip?.state != "flight" || currentClip?.clip.name != clip.name {
                let previous = currentClip?.state == "flight" ? currentClip?.clip.name : nil
                // 点火蹲下那一下播完再飞起来（引擎在 0.42 秒离地，片段 0.55 秒才接得上飞行姿势）。
                let crouching = previous == "boost_crouch" && now.timeIntervalSince(flightClipStartedAt) < (currentClip?.clip.duration ?? 0)
                if !crouching {
                    // 动画刚整个重建过（currentClip 为空）：直接切过去，别从绑定姿势（T 字）淡入。
                    let fade = currentClip == nil ? 0 : Self.flightFade(from: previous, to: clip.name)
                    if let old = currentClip?.clip { model.stop(old, fadeOut: fade) }
                    model.play(clip, loop: choice.loop, hold: !choice.loop, fadeIn: fade)
                    currentClip = ("flight", clip)
                    currentLoops = choice.loop
                    currentSpeed = 1
                    clipLockedUntil = .distantPast
                    pendingSequence = []
                    flightClipStartedAt = now
                }
            }
            // 没有对应片段的那一下（火箭先弹出来，人站着等）：刚才在走就站定，别原地踏步。
            if Self.flightClip(flight) == nil, currentClip?.state == "walk", let idle = stance ?? clips["idle"].flatMap({ model.clips[$0.name] }) {
                if let old = currentClip?.clip { model.stop(old, fadeOut: 0.15) }
                model.play(idle, loop: true, hold: false, fadeIn: 0.15)
                currentClip = ("idle", idle)
                currentLoops = true
                currentSpeed = 1
            }
            finishFrame(pose, state: state, now: now, model: model)
            return
        }
        // 落地（从跳 / 掉 / 飞的状态出来）：先播一下落地缓冲，再回到正常状态。跳 / 飞的落地从伸腿很快接上（0.05 秒）。
        let landedFromFlight = currentClip?.state == "flight"
        let wasAirborne = currentClip?.state == "jump" || currentClip?.state == "fall" || landedFromFlight
        let landingClip = landedFromFlight ? (flightClips["jump_land"] ?? model.clips["land"]) : model.clips["land"]
        if wasAirborne, state != "jump", state != "fall", state != "drag", let landing = landingClip {
            lastState = state
            _ = play(sequence: [landing], fade: landedFromFlight ? 0.05 : 0.15)
            return
        }
        // 一串互动片段：上一段播完接下一段。只在待机时接（来通知、被拖、要走时主切换马上会把它换掉，接了也白接）。
        if state == "idle", currentClip?.state == "interact", now >= clipLockedUntil, !pendingSequence.isEmpty {
            let next = pendingSequence.removeFirst()
            if let current = currentClip?.clip { model.stop(current, fadeOut: 0.12) }
            model.play(next, loop: false, hold: false, fadeIn: 0.12)
            currentClip = ("interact", next)
            currentLoops = false
            currentSpeed = 1
            clipLockedUntil = now.addingTimeInterval(next.duration)
        }
        // 一次性片段（挥手）播完前不切走；待机小动作 / 互动则可以被待机以外的状态（提醒 / 拖拽 / 走路 / 睡觉）立刻打断。
        // 坐下 / 起身也锁着，只有被拎起来、跳、掉这种马上要变的才直接切走。
        let interruptible = currentClip?.state == "fidget" || currentClip?.state == "interact"
        let urgent = (state == "drag" || state == "jump" || state == "fall")
            && (currentClip?.state.hasPrefix("lounge") ?? false)
        let locked = now < clipLockedUntil && !(interruptible && state != "idle") && !urgent
        if updateLounge(state: state, urgent: urgent, now: now, model: model) {
            // 蹲 / 坐地的坐下、坐着、起身由 updateLounge 管。
        } else if currentClip?.state != state, !locked,
           let choice = clips[state] ?? clips["idle"],
           let next = (state == "idle" ? stance : nil)
               // 一起步就在赶路：直接跑（不先播走路、同一帧再换成跑）。
               ?? (state == "walk" ? ((pose.hurry ? runClip : nil) ?? gaitClips[pose.gait]) : nil)
               ?? variants[state]?.randomElement() ?? model.clips[choice.name] {
            if next.name != currentClip?.clip.name || !choice.loop {
                // 趴下 / 起来是整个身子翻过去，交叉淡入淡出拉长一些，看着像「趴下去」而不是一下子变过去。
                // 小动作做完回到抱臂 / 叉腰这类站姿：手臂要绕一大圈，也拉长（小动作都是从普通待机起落的）。
                let fade: CGFloat
                if currentClip == nil {
                    fade = 0
                } else if state == "rest" || currentClip?.state == "rest" {
                    fade = 0.6
                } else if state == "idle", currentClip?.state == "fidget", next.name != stances.first?.name {
                    fade = 0.45
                } else {
                    fade = 0.15
                }
                if let old = currentClip?.clip { model.stop(old, fadeOut: fade) }
                model.play(next, loop: choice.loop, hold: choice.hold, fadeIn: fade)
                clipLockedUntil = (!choice.loop && !choice.hold) ? now.addingTimeInterval(next.duration) : .distantPast
                currentSpeed = 1
            }
            currentClip = (state, next)
            currentLoops = choice.loop
            pendingSequence = []
            if state == "idle" {
                nextFidgetAt = now.addingTimeInterval(Double.random(in: fidgetInterval))
                // 刚回到待机：站一会儿再换站姿（换站姿的时间在走路 / 睡觉 / 做小动作时早就到了，不推的话下一帧马上又换一种）。
                nextStanceAt = max(nextStanceAt, now.addingTimeInterval(Double.random(in: 35...90)))
            }
            sleepPauseAt = state == "sleep" ? now.addingTimeInterval(next.duration + 0.3) : .distantFuture
        } else if state == "idle", currentClip?.state == "idle", !locked, now >= nextStanceAt, stances.count > 1,
                  let current = currentClip?.clip,
                  let next = stances.filter({ $0.name != current.name }).randomElement() {
            // 站久了换个站姿（背手 → 抱臂 → 叉腰…），慢慢过渡过去。
            model.stop(current, fadeOut: 0.6)
            model.play(next, loop: true, hold: false, fadeIn: 0.6)
            currentClip = ("idle", next)
            currentLoops = true
            currentSpeed = 1
            stance = next
            nextStanceAt = now.addingTimeInterval(Double.random(in: 35...90))
            nextFidgetAt = max(nextFidgetAt, now.addingTimeInterval(3))
        } else if state == "idle", currentClip?.state == "idle", !locked, now >= nextFidgetAt,
                  let fidget = pickFidget(now: now), let current = currentClip?.clip {
            // 待机久了做个小动作，做完（锁到片段结束）再回待机循环。从抱臂 / 叉腰这类站姿进去时过渡拉长。
            let fade: CGFloat = current.name == stances.first?.name ? 0.2 : 0.45
            model.stop(current, fadeOut: fade)
            model.play(fidget, loop: false, hold: false, fadeIn: fade)
            currentClip = ("fidget", fidget)
            currentLoops = false
            currentSpeed = 1
            clipLockedUntil = now.addingTimeInterval(fidget.duration)
            nextFidgetAt = now.addingTimeInterval(fidget.duration + Double.random(in: fidgetInterval))
        }

        // 赶路：有跑步片段就换成跑（引擎按跑步的步幅移动）；没有就把走路片段跟着引擎一起加快（脚不打滑）。
        // 不赶路时走这趟挑的走法（动捕的三段，MOCAP.md §3）：跑完接着走、新的一趟换了走法，都淡过去。
        if state == "walk", currentClip?.state == state, let current = currentClip?.clip {
            let run = runClip
            let wantRun = pose.hurry && run != nil
            let walking = gaitClips[pose.gait] ?? clips[state].flatMap { model.clips[$0.name] }
            let isWalkClip = current.name == runClip?.name || gaitClips.values.contains { $0.name == current.name }
            if let run, wantRun, current.name != run.name {
                model.stop(current, fadeOut: 0.2)
                model.play(run, loop: true, hold: false, fadeIn: 0.2)
                currentClip = (state, run)
                currentSpeed = 1
            } else if !wantRun, let walking, current.name != walking.name, isWalkClip {
                model.stop(current, fadeOut: 0.25)
                model.play(walking, loop: true, hold: false, fadeIn: 0.25)
                currentClip = (state, walking)
                currentSpeed = 1
            } else if current.name != runClip?.name {
                let speed: CGFloat = pose.hurry ? PetEngine.walkHurryFactor : 1
                if speed != currentSpeed {
                    model.setSpeed(current, speed)
                    currentSpeed = speed
                }
            }
        }
        finishFrame(pose, state: state, now: now, model: model)
    }

    /// 助推器弹出要多久（VRMBooster.show 的回弹动画）：先弹出来，再点火蹲下 / 小火悬停。
    private static let boosterPop: TimeInterval = 0.35

    /// 跳 / 飞的这一段播哪个片段（SETTLE.md §4.4）：蓄力 / 刹车 / 伸腿 / 空中转圈播完停在最后一帧，空中、飞行中循环。
    /// 火箭刚弹出来那一下返回 nil（人先站着不动）。
    private static func flightClip(_ flight: PetFlightPose) -> (name: String, loop: Bool)? {
        switch (flight.style, flight.phase) {
        case (.plain, _): return nil
        case (.rocket, .prepare):
            guard flight.elapsed >= boosterPop else { return nil }
            return flight.ascending ? ("boost_crouch", false) : ("fly_down", true)
        case (.rocket, .brake): return ("boost_brake", false)
        case (.rocket, _): return (flight.ascending ? "fly" : "fly_down", true)
        case (.hop, .prepare): return ("hop_crouch", false)
        case (.hop, .reach), (_, .reach): return ("jump_reach", false)
        case (.hop, _): return ("hop_fall", true)
        case (_, .prepare): return ("jump_crouch", false)
        case (_, .kick): return ("jump_spin", false)
        case (_, .rise): return ("jump_rise", true)
        case (_, .fall), (_, .cruise), (_, .brake): return ("jump_fall", true)
        }
    }

    /// 片段之间淡入淡出多久（按片段设计时的建议）：蹲 → 起跳、上升 → 下落、伸腿要快；点火 → 飞、飞 → 刹车、悬停降下慢一点。
    private static func flightFade(from previous: String?, to next: String) -> CGFloat {
        switch (previous, next) {
        case ("jump_crouch"?, "jump_rise"), ("hop_crouch"?, "hop_fall"): return 0.1
        case ("jump_rise"?, "jump_fall"): return 0.15
        case (_, "jump_reach"): return 0.1
        case ("boost_crouch"?, "fly"), (_, "boost_brake"): return 0.25
        case (_, "fly_down"): return 0.3
        case (nil, _): return 0.15
        default: return 0.12
        }
    }

    /// 火箭助推器（推力时间线照预览）：弹出来 → 往上飞时点火蹲下 0.52、离地 1、半秒后巡航 0.85、刹车 0.25；
    /// 往下飞一直小火 0.45、刹车 0.3。落地熄火，约 0.45 秒后收起。
    private func updateBooster(_ flight: PetFlightPose?) {
        guard let booster else { return }
        guard let flight, flight.style == .rocket else {
            if boosterShown {
                boosterShown = false
                setThrust(0)
                boosterHideWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.boosterShown else { return }
                        self.booster?.hide(animated: true)
                    }
                }
                boosterHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
            return
        }
        if !boosterShown {
            boosterHideWork?.cancel()
            boosterShown = true
            booster.show(animated: true)
        }
        switch flight.phase {
        case .prepare: setThrust(flight.ascending ? (flight.elapsed < Self.boosterPop ? 0 : 0.52) : 0.45)
        case .brake: setThrust(flight.ascending ? 0.25 : 0.3)
        default: setThrust(flight.ascending ? (flight.air < 0.5 ? 1 : 0.85) : 0.45)
        }
    }

    /// 推力变了才设（设一次助推器自己平滑过渡 0.2 秒）。
    private func setThrust(_ value: Float) {
        guard let booster, booster.thrust != value else { return }
        booster.thrust = value
    }

    /// 每一帧的收尾：帧率、睡着停渲染、转身、影子、看鼠标、提醒时跳一下 / 跳的时候抬高。
    private func finishFrame(_ pose: PetPose, state: String, now: Date, model: GLTFModel) {
        // 帧率：走路 / 跳 / 飞 / 提醒 / 拖拽 30fps，待机呼吸 20fps 就够顺；睡下以后停掉渲染，醒来再恢复。
        let lively = state == "walk" || state == "jump" || state == "fall" || state == "happy" || state == "drag"
            || currentClip?.state == "interact"
        let fps = lively ? 30 : 20
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
        let shouldDoze = state == "sleep" && now >= sleepPauseAt
        if dozing != shouldDoze {
            dozing = shouldDoze
            updateRenderLoop()
        }

        var target: Float
        switch pose.state {
        case .wander: target = pose.facingLeft ? -.pi / 2 : .pi / 2
        case .jump where pose.flight != nil: target = pose.facingLeft ? -.pi / 2 : .pi / 2
        case .notify, .rest: target = 0
        case .idle, .sleep, .dragged, .jump, .fall, .entering, .leaving, .lounge:
            target = pose.attentive ? 0 : (pose.facingLeft ? -0.45 : 0.45)
        }
        // 人形睡觉是侧身坐地抱膝（VRMMotion.hugKnees）：正对镜头会看到裙底，睡下、睡着、起身的整段都固定侧过去，
        // 方向固定（头往右肩靠、脸转向右边，侧向画面右边时脸才朝着镜头）；起身播完再转回来。
        let sleepingVRM = model.vrm != nil && (pose.state == .sleep || currentClip?.clip.name == "get_up")
        if sleepingVRM { target = Self.sleepYaw }
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
        updateLook(now: now)

        // 引擎的跳跃位移是屏幕点：按相机在模型处的可见高度换成场景单位。
        let visibleHeight = 2 * Self.cameraDistance * Float(tan(Self.fieldOfView / 2 * .pi / 180))
        let y = Float(pose.bounce) * visibleHeight / Float(max(bounds.height, 1))
        if abs(y - bounceY) > 0.0005 {
            bounceY = y
            bounceNode.simdPosition = SIMD3(0, y, 0)
        }
    }

    /// 挑一个小动作：大动作（跳舞、开合跳…）两分钟内最多一次、约七分之一的机会；不和上一个重样。
    private func pickFidget(now: Date) -> GLTFClip? {
        let big = !bigFidgets.isEmpty && now.timeIntervalSince(lastBigFidgetAt) > 120 && Double.random(in: 0..<1) < 0.15
        let pool = (big ? bigFidgets : fidgets).filter { $0.name != lastFidgetName }
        guard let pick = pool.randomElement() ?? fidgets.randomElement() else { return nil }
        if big { lastBigFidgetAt = now }
        lastFidgetName = pick.name
        return pick
    }

    /// 头跟着鼠标转（只在站着时；做小动作时转得少一些；走路、跳、睡、互动时回正）。
    /// 鼠标最近 3 秒动过、离头 700 点以内才看；角度按鼠标相对头的位置算（以 500 点为「视距」），身子的 3/4 侧转扣掉。
    private func updateLook(now: Date) {
        guard let rig = model?.vrm, let head = rig.bones["head"]?.node, let window else { return }
        // 走路、跳飞、互动、睡着时不看鼠标、头已经回正：不用每帧投影头的位置、换算坐标。
        let looking = ["idle", "lounge", "fidget"].contains(currentClip?.state ?? "")
        guard looking || lookInfluence > 0 else { return }
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 {
            lastMouse = mouse
            mouseMovedAt = now
        }
        let projected = projectPoint(head.presentation.worldPosition)
        let headScreen = window.convertPoint(toScreen: convert(NSPoint(x: projected.x, y: projected.y), to: nil))
        let dx = mouse.x - headScreen.x, dy = mouse.y - headScreen.y
        let near = hypot(dx, dy) < 700 && now.timeIntervalSince(mouseMovedAt) < 3
        let clipState = currentClip?.state
        let wanted: Float
        switch clipState {
        case _ where !near: wanted = 0
        case "idle"?: wanted = 0.85
        case "lounge"?: wanted = 0.6
        case "fidget"?: wanted = 0.35
        default: wanted = 0
        }
        lookInfluence += (wanted - lookInfluence) * 0.08
        if lookInfluence < 0.002 {
            lookInfluence = 0
            look.set(yaw: 0, pitch: 0, influence: 0)
            return
        }
        let bodyYaw = yaw.isNaN ? 0 : yaw
        let turn = min(max(Float(atan2(dx, 500)) - bodyYaw, -0.6), 0.6)
        let pitch = min(max(Float(atan2(dy, 500)), -0.3), 0.3)
        // 角度也慢慢跟过去：鼠标一甩头不会跟着一甩。
        lookYaw += (turn - lookYaw) * 0.2
        lookPitch += (pitch - lookPitch) * 0.2
        look.set(yaw: lookYaw, pitch: lookPitch, influence: lookInfluence)
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
        case .entering, .leaving: return "idle"
        case .lounge: return "lounge"
        }
    }

    // MARK: - 鼠标交给宠物窗（拖拽 / 点击菜单都在 PetPanel 里处理）

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { window?.rightMouseDown(with: event) }
}
