import AppKit
import Foundation

// MARK: - 素材包（pet.json）

/// 一个状态的取帧方式：整行帧图（sheet）或散图序列（frames）二选一。
struct PetStateSpec: Decodable {
    var sheet: String?      // 帧图文件名；"*" = 文件夹里第一张 PNG（优先名字含 side 的）
    var frames: [String]?   // 散图文件名序列
    var frameWidth: Int?    // sheet 模式必填
    var frameHeight: Int?
    var row: Int?           // sheet 里第几行（0 起，从上往下）
    var count: Int?         // 帧数；nil = 按图宽自动算
    var fps: Double?
}

struct PetManifest: Decodable {
    var name: String
    var pixelArt: Bool?
    var states: [String: PetStateSpec]
}

/// 一个可用的宠物形象：文件夹 + 清单 + 已解码的各状态帧。
struct PetPackage {
    let id: String
    let name: String
    let pixelArt: Bool
    let framesByState: [String: [NSImage]]
    let fpsByState: [String: Double]
}

/// 素材包加载器。两处来源：
/// 1. App 包内 `Pets/`（随版本发布的内置形象）；
/// 2. `~/Library/Application Support/Baobox/Pets/`（用户自放，不用重打包即可换形象）。
/// 首次启动会在 2 处生成几个示例形象文件夹（只写 pet.json，图由用户把素材包里的帧图放进来）。
enum PetPackageLoader {
    static var userPetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Baobox/Pets", isDirectory: true)
    }

    static func loadAll() -> [PetPackage] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Pets", isDirectory: true) {
            dirs.append(bundled)
        }
        dirs.append(userPetsDirectory)
        var packages: [PetPackage] = []
        var seen: Set<String> = []
        for dir in dirs {
            guard let subs = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for sub in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = sub.lastPathComponent
                guard !seen.contains(id), let pkg = loadPackage(id: id, in: sub) else { continue }
                seen.insert(id)
                packages.append(pkg)
            }
        }
        return packages
    }

    private static func loadPackage(id: String, in dir: URL) -> PetPackage? {
        let manifestURL = dir.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) else { return nil }
        var framesByState: [String: [NSImage]] = [:]
        var fpsByState: [String: Double] = [:]
        for (state, spec) in manifest.states {
            let frames = loadFrames(spec: spec, in: dir)
            if !frames.isEmpty {
                framesByState[state] = frames
                fpsByState[state] = spec.fps ?? 8
            }
        }
        // 至少要有 idle 才算可用包。
        guard framesByState["idle"] != nil else { return nil }
        return PetPackage(id: id, name: manifest.name, pixelArt: manifest.pixelArt ?? true,
                          framesByState: framesByState, fpsByState: fpsByState)
    }

    private static func loadFrames(spec: PetStateSpec, in dir: URL) -> [NSImage] {
        if let names = spec.frames {
            return names.compactMap { NSImage(contentsOf: dir.appendingPathComponent($0)) }
        }
        guard let sheetName = spec.sheet else { return [] }
        let sheetURL: URL?
        if sheetName == "*" {
            let pngs = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
            sheetURL = pngs.first(where: { $0.lastPathComponent.lowercased().contains("side") }) ?? pngs.first
        } else {
            sheetURL = dir.appendingPathComponent(sheetName)
        }
        guard let sheetURL, let sheet = NSImage(contentsOf: sheetURL),
              let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let fw = spec.frameWidth ?? 64
        let fh = spec.frameHeight ?? fw
        let rowY = (spec.row ?? 0) * fh
        guard rowY + fh <= cg.height else { return [] }
        let total = spec.count ?? max(cg.width / fw, 0)
        var frames: [NSImage] = []
        for i in 0..<total {
            let rect = CGRect(x: i * fw, y: rowY, width: fw, height: fh)
            guard let cropped = cg.cropping(to: rect) else { continue }
            frames.append(NSImage(cgImage: cropped, size: NSSize(width: fw, height: fh)))
        }
        return frames
    }

    // MARK: 示例形象（只写清单，图由用户放）

    /// Frakassets Free Pets Pack（CC-BY 4.0）的三只：帧图为「动画 × 朝向」分行，
    /// 顺序 Happy / Idle / Sleep / Walk × South / East / North / West，侧面用 East 行。
    static func ensureStarterPackages() {
        let starters: [(id: String, name: String)] = [
            ("cat-orange", "橘猫"),
            ("shiba-puppy", "柴犬"),
            ("fox-red", "赤狐"),
        ]
        let fm = FileManager.default
        for starter in starters {
            let dir = userPetsDirectory.appendingPathComponent(starter.id, isDirectory: true)
            let manifestURL = dir.appendingPathComponent("pet.json")
            if fm.fileExists(atPath: manifestURL.path) { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = """
            {
              "name": "\(starter.name)",
              "pixelArt": true,
              "states": {
                "idle":   { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 5,  "fps": 6 },
                "walk":   { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 13, "fps": 12 },
                "happy":  { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 1,  "fps": 10 },
                "sleep":  { "sheet": "*", "frameWidth": 64, "frameHeight": 64, "row": 9,  "fps": 4 }
              }
            }
            """
            try? json.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
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

    /// 决定画面的全部输入：相同就不用重画。
    private struct RenderKey: Equatable {
        var state: String
        var frame: Int
        var facingLeft: Bool
        var offsetY: Int
    }

    func setPackage(_ package: PetPackage?) {
        self.package = package
        lastRenderKey = nil
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

        let targetHeight = b.height * 0.94
        let aspect = image.size.width / max(image.size.height, 1)
        let targetWidth = targetHeight * aspect
        let rect = NSRect(x: b.midX - targetWidth / 2,
                          y: b.minY + CGFloat(verticalOffset),
                          width: targetWidth, height: targetHeight)
        if pose.facingLeft {
            context.cgContext.translateBy(x: b.midX, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            context.cgContext.translateBy(x: -b.midX, y: 0)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private var stateKey: String {
        switch pose.state {
        case .sleep: return "sleep"
        case .wander: return "walk"
        case .notify: return "happy"
        case .idle, .dragged: return "idle"
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
