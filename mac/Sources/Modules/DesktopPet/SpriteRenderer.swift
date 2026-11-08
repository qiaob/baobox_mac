import AppKit
import Foundation

// MARK: - 素材包（pet.json）

/// 一个状态的取帧方式：整行帧图（sheet）或散图序列（frames）二选一。格式见 docs/desktop-pet/PACKS.md §2。
struct PetStateSpec: Decodable {
    var sheet: String?      // 帧图文件名；"*" = 文件夹里第一张 PNG
    var frames: [String]?   // 散图文件名序列
    var frameWidth: Int?    // sheet 模式必填
    var frameHeight: Int?
    var row: Int?           // sheet 里第几行（0 起，从上往下）
    var column: Int?        // 从第几列开始取（0 起）；一行里拼了几段动画时用
    var count: Int?         // 帧数；nil = 取到行尾
    var fps: Double?
}

struct PetManifest: Decodable {
    /// 自制形象的显示名；内置 / 可下载形象的名字由 PetCatalog 按界面语言给出。
    var name: String?
    var pixelArt: Bool?
    /// 素材画的是朝哪边（"left" / "right"，默认 right）；走的方向和它相反时渲染层镜像。
    var facing: String?
    /// 2D 帧图（与 model 二选一）。
    var states: [String: PetStateSpec]?
    /// 3D：模型文件名（.glb / .gltf / .vrm）。
    var model: String?
    /// 3D：状态 → 动画片段；不写的按片段名猜。
    var clips: [String: PetClipSpec]?
    /// 3D：模型正面不朝 +Z 时的修正（度）。
    var yaw: Double?
    /// 3D：在自动取景的基础上再放大 / 缩小。
    var scale: Double?
    /// 3D：待机时偶尔做的小动作（东张西望、挠耳朵、打哈欠…），随机挑一个播一次。
    var fidgets: [String]?
    /// 3D：互动（poke / highFive / pet / feed / play / wake）→ 候选列表，候选可以是一串片段。
    var interactions: [String: [PetClipSequence]]?
    /// 3D：出场落地后、退场前播的片段（一个名字或一串，#54）；不写的用默认（VRM 招手 / 道别，其他形象跳一下）。
    var enter: PetClipSequence?
    var leave: PetClipSequence?
}

/// 所有帧里不透明像素的并集（像素），以帧的「底边中点」为原点。
/// 渲染按它统一缩放、让脚踩在窗口底边 —— 不同来源的素材留白差别很大，按帧尺寸缩放会忽大忽小、悬在半空。
struct PetContentBox {
    var left: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var top: CGFloat

    var height: CGFloat { max(top - bottom, 1) }
    /// 绕中线镜像后也要放得下的宽度。
    var symmetricWidth: CGFloat { max(2 * max(-left, right), 1) }

    mutating func formUnion(_ other: PetContentBox) {
        left = min(left, other.left)
        right = max(right, other.right)
        bottom = min(bottom, other.bottom)
        top = max(top, other.top)
    }
}

/// 一个可用的宠物形象：文件夹 + 清单 + 已解码的各状态帧（2D），或模型与动作映射（3D，模型用到时才读）。
struct PetPackage {
    let id: String
    let name: String
    let pixelArt: Bool
    let facesLeft: Bool
    let framesByState: [String: [NSImage]]
    let fpsByState: [String: Double]
    let content: PetContentBox
    /// 非 nil = 3D 形象，由 PetModelView 渲染。
    var model: PetModelSpec?
}

/// 素材包加载器。三处来源，同 id 先到先得：
/// 1. App 包内 `Pets/`（内置形象，按 PetCatalog.builtIn 的顺序）；
/// 2. `~/Library/Application Support/Baobox/Pets/` 里设置页下载的形象（按 PetCatalog.downloadable 的顺序）；
/// 3. 同一目录里用户自己放的形象（按文件夹名）。
enum PetPackageLoader {
    static var userPetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Baobox/Pets", isDirectory: true)
    }

    static var bundledPetsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Pets", isDirectory: true)
    }

    static func loadAll() -> [PetPackage] {
        var packages: [PetPackage] = []
        var seen: Set<String> = []
        func add(_ id: String, in dir: URL) {
            guard !seen.contains(id), let pkg = loadPackage(id: id, in: dir) else { return }
            seen.insert(id)
            packages.append(pkg)
        }
        let user = userPetsDirectory
        if let bundled = bundledPetsDirectory {
            for info in PetCatalog.builtIn {
                add(info.id, in: bundled.appendingPathComponent(info.id, isDirectory: true))
            }
            for dir in subdirectories(of: bundled) { add(dir.lastPathComponent, in: dir) }
        }
        for info in PetCatalog.downloadable {
            add(info.id, in: user.appendingPathComponent(info.id, isDirectory: true))
        }
        for dir in subdirectories(of: user) { add(dir.lastPathComponent, in: dir) }
        return packages
    }

    /// 文件夹里第一个 .glb / .gltf / .vrm（按文件名排序）。
    private static func firstModelFile(in dir: URL) -> String? {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.sorted().first { ["glb", "gltf", "vrm"].contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// 不含隐藏目录（下载暂存目录以 `.` 开头，不会被当成形象）。
    private static func subdirectories(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func loadPackage(id: String, in dir: URL) -> PetPackage? {
        let manifestURL = dir.appendingPathComponent("pet.json")
        let manifest: PetManifest
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(PetManifest.self, from: data) {
            manifest = decoded
        } else if let glb = firstModelFile(in: dir) {
            // 只放了一个 .glb、没写 pet.json：文件夹名当名字，动作按片段名猜。
            manifest = PetManifest(name: id, model: glb)
        } else {
            return nil
        }
        let name = PetCatalog.info(for: id)?.name ?? manifest.name ?? id
        if let modelFile = manifest.model {
            let url = dir.appendingPathComponent(modelFile)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var spec = PetModelSpec(url: url, clips: manifest.clips ?? [:], fidgets: manifest.fidgets ?? [],
                                    interactions: (manifest.interactions ?? [:]).mapValues { $0.map(\.clips) },
                                    yawDegrees: manifest.yaw ?? 0, scale: manifest.scale ?? 1)
            spec.enterClips = manifest.enter?.clips ?? []
            spec.leaveClips = manifest.leave?.clips ?? []
            return PetPackage(id: id, name: name, pixelArt: false, facesLeft: false, framesByState: [:],
                              fpsByState: [:], content: PetContentBox(left: 0, right: 0, bottom: 0, top: 0),
                              model: spec)
        }
        var framesByState: [String: [NSImage]] = [:]
        var fpsByState: [String: Double] = [:]
        var content: PetContentBox?
        for (state, spec) in manifest.states ?? [:] {
            let frames = loadFrames(spec: spec, in: dir)
            guard !frames.isEmpty else { continue }
            framesByState[state] = frames.map(\.image)
            fpsByState[state] = spec.fps ?? 8
            for frame in frames {
                guard let box = frame.box else { continue }
                if content == nil { content = box } else { content?.formUnion(box) }
            }
        }
        // 至少要有 idle、且不是全透明才算可用包。
        guard framesByState["idle"] != nil, let content else { return nil }
        return PetPackage(id: id, name: name, pixelArt: manifest.pixelArt ?? true,
                          facesLeft: manifest.facing?.lowercased() == "left",
                          framesByState: framesByState, fpsByState: fpsByState, content: content)
    }

    private static func loadFrames(spec: PetStateSpec, in dir: URL) -> [(image: NSImage, box: PetContentBox?)] {
        if let names = spec.frames {
            return names.compactMap { name in
                guard let image = NSImage(contentsOf: dir.appendingPathComponent(name)),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return frame(cg)
            }
        }
        guard let sheetName = spec.sheet else { return [] }
        let sheetURL: URL?
        if sheetName == "*" {
            let pngs = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
            sheetURL = pngs.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        } else {
            sheetURL = dir.appendingPathComponent(sheetName)
        }
        guard let sheetURL, let sheet = NSImage(contentsOf: sheetURL),
              let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let fw = spec.frameWidth ?? cg.height
        let fh = spec.frameHeight ?? fw
        guard fw > 0, fh > 0 else { return [] }
        let rowY = (spec.row ?? 0) * fh
        let startColumn = max(spec.column ?? 0, 0)
        guard rowY + fh <= cg.height else { return [] }
        let available = max(cg.width / fw - startColumn, 0)
        let total = min(spec.count ?? available, available)
        var frames: [(image: NSImage, box: PetContentBox?)] = []
        for i in 0..<total {
            let rect = CGRect(x: (startColumn + i) * fw, y: rowY, width: fw, height: fh)
            guard let cropped = cg.cropping(to: rect) else { continue }
            frames.append(frame(cropped))
        }
        return frames
    }

    /// NSImage 的 size 按像素给（1 像素 = 1 点），渲染层再统一换算成屏幕尺寸。
    private static func frame(_ cg: CGImage) -> (image: NSImage, box: PetContentBox?) {
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, contentBox(cg))
    }

    /// 这一帧不透明像素的包围盒（以帧底边中点为原点）；全透明返回 nil。帧都很小（几十像素见方），逐像素扫一遍即可。
    private static func contentBox(_ image: CGImage) -> PetContentBox? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            for x in 0..<w where pixels[(row * w + x) * 4 + 3] > 8 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // 位图内存的第 0 行是图像最上面一行。
        let half = CGFloat(w) / 2
        return PetContentBox(left: CGFloat(minX) - half, right: CGFloat(maxX + 1) - half,
                             bottom: CGFloat(h - 1 - maxRow), top: CGFloat(h - minRow))
    }
}

// MARK: - 帧渲染视图

/// 帧序列渲染（设计 §7.1)：按引擎姿态选状态、按时间取帧；朝向镜像、跳跃/呼吸以位移叠加。
/// 没有可用素材包时只画一个 SF Symbol 占位（空态提示，不是形象本体）。
final class SpritePetView: NSView {
    /// 姿态每 tick（30fps）都会变，但画面只在帧号 / 朝向 / 整点位移变了时才不同 —— 只在那时重画
    /// （每 tick 都重画时空闲 CPU 约 10%，大半耗在重绘上）。
    var pose = PetPose() {
        didSet {
            let key = renderKey()
            if key != lastRenderKey {
                lastRenderKey = key
                needsDisplay = true
            }
        }
    }

    private(set) var package: PetPackage?
    private var lastRenderKey: RenderKey?

    /// 出场 / 退场时的形变（#54）：以脚底中点为原点横竖各缩放多少（落地压扁、退场缩小）。1 = 原样。
    var presentationScale = CGSize(width: 1, height: 1) {
        didSet {
            if presentationScale != oldValue { needsDisplay = true }
        }
    }

    /// 决定画面的全部输入：相同就不用重画。
    private struct RenderKey: Equatable {
        var state: String
        var frame: Int
        var facingLeft: Bool
        var offsetY: Int
    }

    /// 形象占窗口高度的比例：头顶留出提醒时跳一下（最高约 13 点）的空间。
    private static let heightFill: CGFloat = 0.8
    private static let widthFill: CGFloat = 0.94

    func setPackage(_ package: PetPackage?) {
        self.package = package
        lastRenderKey = nil
        needsDisplay = true
    }

    /// 拖到缩放比不同的屏幕上时，整数倍放大要按新屏幕重算。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private func renderKey() -> RenderKey {
        guard let package, let resolved = resolvedFrames(package) else {
            return RenderKey(state: "placeholder", frame: 0, facingLeft: false, offsetY: 0)
        }
        return RenderKey(state: resolved.state, frame: frameIndex(package, resolved),
                         facingLeft: pose.facingLeft, offsetY: verticalOffset)
    }

    /// 呼吸 / 跳跃位移取整点：像素图不糊边，也让重画次数跟着降下来。
    private var verticalOffset: Int { Int((pose.bob + pose.bounce).rounded()) }

    private func frameIndex(_ package: PetPackage, _ resolved: (state: String, frames: [NSImage])) -> Int {
        let fps = package.fpsByState[resolved.state] ?? 8
        return Int(pose.time * fps) % resolved.frames.count
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        guard let package, let resolved = resolvedFrames(package) else {
            drawPlaceholder(in: b)
            return
        }
        let image = resolved.frames[frameIndex(package, resolved)]
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.imageInterpolation = package.pixelArt ? .none : .high

        let box = package.content
        let backing = max(window?.backingScaleFactor ?? 2, 1)
        var scale = min(b.height * Self.heightFill / box.height, b.width * Self.widthFill / box.symmetricWidth)
        if package.pixelArt {
            // 像素图按整数个屏幕像素放大：每个源像素占的格子一样大，不糊边、不出现宽窄不一的像素。
            scale = max((scale * backing).rounded(.down), 1) / backing
        }
        func snap(_ value: CGFloat) -> CGFloat { (value * backing).rounded() / backing }
        let width = image.size.width * scale
        let height = image.size.height * scale
        let rect = NSRect(x: snap(b.midX - width / 2),
                          y: snap(b.minY - box.bottom * scale + CGFloat(verticalOffset)),
                          width: width, height: height)
        if presentationScale != CGSize(width: 1, height: 1) {
            let anchor = CGPoint(x: rect.midX, y: rect.minY + box.bottom * scale)
            context.cgContext.translateBy(x: anchor.x, y: anchor.y)
            context.cgContext.scaleBy(x: max(presentationScale.width, 0.01), y: max(presentationScale.height, 0.01))
            context.cgContext.translateBy(x: -anchor.x, y: -anchor.y)
        }
        if pose.facingLeft != package.facesLeft {
            context.cgContext.translateBy(x: rect.midX, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            context.cgContext.translateBy(x: -rect.midX, y: 0)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private var stateKey: String {
        switch pose.state {
        case .sleep, .rest: return "sleep"
        case .wander: return "walk"
        case .notify, .jump: return "happy"
        case .idle, .dragged, .fall, .entering, .leaving, .lounge: return "idle"
        }
    }

    /// 当前姿态实际用哪组帧：缺的状态回退 idle，帧率也跟着用被借用那组的。
    private func resolvedFrames(_ package: PetPackage) -> (state: String, frames: [NSImage])? {
        let candidates = stateKey == "happy" ? ["happy", "notify", "idle"] : [stateKey, "idle"]
        for key in candidates {
            if let frames = package.framesByState[key], !frames.isEmpty { return (key, frames) }
        }
        return nil
    }

    private func drawPlaceholder(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: min(rect.width, rect.height) * 0.5, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 0.35)
    }
}
