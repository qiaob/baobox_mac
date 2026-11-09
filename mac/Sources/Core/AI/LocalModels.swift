import Combine
import Darwin
import Foundation

/// 一个本地模型（docs/local-models/DESIGN.md §2）。都一样：按需下载、启动 / 停止、开机自启、给功能用。
/// 只分「翻译专用」（Hy-MT2）和「通用」（其余，翻译也能做），以及「这一类功能默认用哪个」。
struct LocalModelEntry: Identifiable {
    /// 模型家族：决定用途说明，以及推荐时考不考虑它。
    enum Family {
        case translation    // Hy-MT2：翻译专用
        case qwen           // Qwen3：中英文都好，推荐只在这一家里挑（提示词按它调过）
        case qwenMoE        // Qwen3-30B-A3B：混合专家，大但快
        case gemma
        case llama
        case glm
        case phi
        case reasoning      // DeepSeek-R1 蒸馏：先思考再回答，慢
        case custom         // 用户粘贴的 Hugging Face 链接
    }

    let model: OfflineModel
    let family: Family
    /// 出品方（下拉框里显示）。
    let vendor: String

    var id: String { model.id }
    var name: String { model.displayName }
    /// `.translation` = 翻译专用；`.generation` = 通用。
    var kind: AIFeatureKind { family == .translation ? .translation : .generation }
    var isReasoning: Bool { family == .reasoning }
    var isCustom: Bool { family == .custom }
    /// 推荐说明里能不能当「推荐」：只在 Qwen3 里挑（提示词按它调过，中英文都好）。
    var isRecommendable: Bool { family == .qwen || family == .qwenMoE }

    /// 运行时大约占多少内存：文件大小 + KV 缓存和计算缓冲（4096 上下文约 1 GB，推理模型 8192 上下文约 1.5 GB），偏保守。
    var memoryNeed: Int64 {
        model.byteSize + (model.contextSize > 4096 ? LocalModels.runtimeOverhead * 3 / 2 : LocalModels.runtimeOverhead)
    }

    @MainActor
    var translator: OfflineTranslator { OfflineTranslator.instance(for: model) }

    /// 适合做什么（「AI」页的说明）。
    var usage: String {
        switch family {
        case .translation: return L("localmodel.usage.translation")
        case .qwen:
            if model.id == OfflineModel.corrector.id { return L("localmodel.usage.small") }
            if model.id == OfflineModel.qwen3_0_6b.id { return L("localmodel.usage.tiny") }
            return L("localmodel.usage.general")
        case .qwenMoE: return L("localmodel.usage.moe")
        case .gemma: return L("localmodel.usage.gemma")
        case .llama: return L("localmodel.usage.llama")
        case .glm: return L("localmodel.usage.glm")
        case .phi: return L("localmodel.usage.phi")
        case .reasoning: return L("localmodel.usage.reasoning")
        case .custom: return L("localmodel.usage.custom")
        }
    }
}

/// 用户粘贴 Hugging Face 链接加的模型（`localmodel.custom`，JSON）。
struct CustomLocalModel: Codable, Equatable {
    var id: String
    var name: String
    var repo: String
    var revision: String
    var path: String
    var byteSize: Int64
    var sha256: String

    /// 文件名带上 id，免得两个仓库里同名的文件互相覆盖。
    var offlineModel: OfflineModel {
        let base = OfflineModel.huggingFace(id: id, name: name, repo: repo, file: path, revision: revision,
                                            byteSize: byteSize, sha256: sha256)
        return OfflineModel(id: base.id, displayName: base.displayName, fileName: "\(id)-\(base.fileName)",
                            byteSize: base.byteSize, sha256: base.sha256, mirrors: base.mirrors,
                            contextSize: base.contextSize)
    }
}

/// 本地模型清单、推荐规则、开机自启（docs/local-models/DESIGN.md）。
enum LocalModels {
    static let runtimeOverhead: Int64 = 1 << 30

    /// 内置清单，从小到大大致按家族排。
    static let catalog: [LocalModelEntry] = [
        LocalModelEntry(model: .translation, family: .translation, vendor: "腾讯混元"),
        LocalModelEntry(model: .qwen3_0_6b, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .corrector, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .qwen3_4b, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .qwen3_8b, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .qwen3_14b, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .qwen3_32b, family: .qwen, vendor: "通义千问"),
        LocalModelEntry(model: .qwen3_30b_a3b, family: .qwenMoE, vendor: "通义千问"),
        LocalModelEntry(model: .gemma3_4b, family: .gemma, vendor: "Google"),
        LocalModelEntry(model: .gemma3_12b, family: .gemma, vendor: "Google"),
        LocalModelEntry(model: .gemma3_27b, family: .gemma, vendor: "Google"),
        LocalModelEntry(model: .llama31_8b, family: .llama, vendor: "Meta"),
        LocalModelEntry(model: .glm4_9b, family: .glm, vendor: "智谱"),
        LocalModelEntry(model: .phi4_mini, family: .phi, vendor: "微软"),
        LocalModelEntry(model: .r1_distill_7b, family: .reasoning, vendor: "DeepSeek"),
        LocalModelEntry(model: .r1_distill_14b, family: .reasoning, vendor: "DeepSeek"),
    ]

    static let customKey = "localmodel.custom"

    /// 用户加的自定义模型（每次现读；条目很少）。
    static var custom: [LocalModelEntry] {
        guard let data = UserDefaults.standard.data(forKey: customKey),
              let items = try? JSONDecoder().decode([CustomLocalModel].self, from: data) else { return [] }
        return items.map { LocalModelEntry(model: $0.offlineModel, family: .custom, vendor: $0.repo) }
    }

    /// 全部本地模型：内置清单 + 自定义。
    static var all: [LocalModelEntry] { catalog + custom }

    static func entry(_ id: String) -> LocalModelEntry? { all.first { $0.id == id } }

    /// 能给这一类功能用的本地模型：翻译类 = 全部（通用模型用提示词翻译）；通用类 = 去掉翻译专用的。
    static func models(for kind: AIFeatureKind) -> [LocalModelEntry] {
        kind == .translation ? all : all.filter { $0.kind == .generation }
    }

    /// 这一类功能的默认本地模型：翻译 = Hy-MT2（「自动」翻译的离线后备）；通用 = Qwen3-1.7B。
    /// `AIEngineChoice.local` 指的就是它（docs/local-models/DESIGN.md §5）。
    static func defaultEntry(for kind: AIFeatureKind) -> LocalModelEntry {
        let id = kind == .translation ? OfflineModel.translation.id : OfflineModel.corrector.id
        return catalog.first { $0.id == id } ?? catalog[0]
    }

    /// 已下载（功能能用它）。
    @MainActor
    static func isInstalled(_ id: String) -> Bool {
        entry(id)?.translator.isReady ?? false
    }

    // MARK: - 自定义模型

    /// 记下一个自定义模型（已存在同 id 的就不重复加）。
    @MainActor
    static func addCustom(_ model: CustomLocalModel) {
        var items = customModels()
        guard !items.contains(where: { $0.id == model.id }) else { return }
        items.append(model)
        saveCustom(items)
        LocalModelsObserver.shared.track(model.offlineModel)
    }

    /// 删掉自定义模型的记录（文件由 `OfflineTranslator.deleteModel` 删）。
    static func removeCustom(_ id: String) {
        saveCustom(customModels().filter { $0.id != id })
    }

    private static func customModels() -> [CustomLocalModel] {
        guard let data = UserDefaults.standard.data(forKey: customKey) else { return [] }
        return (try? JSONDecoder().decode([CustomLocalModel].self, from: data)) ?? []
    }

    private static func saveCustom(_ items: [CustomLocalModel]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: customKey) }
    }

    // MARK: - 推荐

    enum Fit {
        /// 占用不超过总内存 45% 里最大的那个。
        case recommended
        /// 不超过 45%。
        case ok
        /// 45% 到 55% 之间：能跑，但占内存较多。
        case heavy
        /// 超过 55%：会卡顿，不建议。16 GB 的 Mac 上 14B（约 10 GB，58%）就在这里 —— 2026-11-09 用户在 Ollama 里
        /// 加载 9 GB 的 14B 模型时整机卡死。
        case tooBig
    }

    /// 推荐 / 可以用的上限、「内存不够」的下限（占总内存的比例）。
    private static let comfortableShare = 0.45
    private static let tooBigShare = 0.55

    static func fit(_ entry: LocalModelEntry, totalMemory: Int64) -> Fit {
        let need = Double(entry.memoryNeed)
        let total = Double(totalMemory)
        if need > total * tooBigShare { return .tooBig }
        if need > total * comfortableShare { return .heavy }
        return entry.id == recommended(totalMemory: totalMemory)?.id ? .recommended : .ok
    }

    /// 这台 Mac 推荐装哪个：占用不超过总内存 45% 的 Qwen3 里最大的（提示词按它调过，中英文都好）。
    static func recommended(totalMemory: Int64) -> LocalModelEntry? {
        catalog.filter { $0.isRecommendable && Double($0.memoryNeed) <= Double(totalMemory) * comfortableShare }
            .max { $0.memoryNeed < $1.memoryNeed }
    }

    /// 一个内存需求（字节）在这台 Mac 上算不算「太大」（Ollama 模型也用这条）。
    static func isTooBig(memoryNeed: Int64, totalMemory: Int64) -> Bool {
        Double(memoryNeed) > Double(totalMemory) * tooBigShare
    }

    // MARK: - 开机自启

    static func autostartKey(_ id: String) -> String { "localmodel.\(id).autostart" }

    static func isAutostart(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: autostartKey(id))
    }

    /// 打开：没在跑就立刻启动并常驻；关掉：只解除常驻，不立刻停。
    @MainActor
    static func setAutostart(_ on: Bool, for entry: LocalModelEntry) {
        UserDefaults.standard.set(on, forKey: autostartKey(entry.id))
        if on {
            entry.translator.start()
        } else {
            entry.translator.unpin()
        }
    }

    /// Baobox 启动时：把开了开机自启、已下载的模型拉起来并常驻。
    @MainActor
    static func startAutostartModels() {
        for entry in all where isAutostart(entry.id) && entry.translator.isReady {
            entry.translator.start()
        }
    }
}

/// 任一本地模型的状态变了（下载进度、装好、删掉、启动、停止）就通知一次：功能下拉框的「本机」一组、「AI」页据此刷新。
@MainActor
final class LocalModelsObserver: ObservableObject {
    static let shared = LocalModelsObserver()

    private var subscriptions: [String: AnyCancellable] = [:]

    private init() {
        for entry in LocalModels.all {
            track(entry.model)
        }
    }

    /// 开始跟踪一个模型（新加的自定义模型也要调）。
    func track(_ model: OfflineModel) {
        guard subscriptions[model.id] == nil else { return }
        subscriptions[model.id] = OfflineTranslator.instance(for: model).objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }
}

/// 这台 Mac 的芯片、内存、磁盘，以及进程的实际内存占用（docs/local-models/DESIGN.md §1、§4）。
enum MachineInfo {
    private static let host = mach_host_self()

    static var totalMemory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    /// 芯片名（「Apple M3」）；读不到时返回 nil。
    static var chipName: String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 现在可用的内存：空闲 + 不活跃 + 可清除 + 预读的页（这些都能马上腾出来）。
    static func availableMemory() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)
            + Int64(stats.speculative_count)
        return pages * Int64(pageSize)
    }

    /// 放模型的那个磁盘还剩多少空间。
    static func freeDiskSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 进程的实际内存占用（活动监视器里的「内存」那一列）。
    static func footprint(pid: Int32) -> Int64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return Int64(info.ri_phys_footprint)
    }

    /// 「16 GB」「5.0 GB」这类展示。
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// 自定义模型：解析 Hugging Face 上 GGUF 文件的链接，查出大小和 SHA-256（下载完照样双重校验，docs/local-models/DESIGN.md §2）。
enum CustomModelImport {
    enum Failure: LocalizedError {
        case badLink
        case notGGUF
        case notFound
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badLink: return L("localmodel.custom.badLink")
            case .notGGUF: return L("localmodel.custom.notGGUF")
            case .notFound: return L("localmodel.custom.notFound")
            case .network(let detail): return L("localmodel.custom.network \(detail)")
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// 接受 `https://huggingface.co/<作者>/<仓库>/resolve|blob/<分支>/<路径>.gguf`。
    static func resolve(_ link: String) async throws -> CustomLocalModel {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              host == "huggingface.co" || host == "www.huggingface.co" else { throw Failure.badLink }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[2] == "resolve" || parts[2] == "blob" else { throw Failure.badLink }
        let repo = parts[0] + "/" + parts[1]
        let revision = parts[3]
        let path = parts[4...].joined(separator: "/")
        guard path.lowercased().hasSuffix(".gguf") else { throw Failure.notGGUF }

        // 列出文件所在目录，找到这个文件的大小和 LFS 的 SHA-256。
        let directory = (path as NSString).deletingLastPathComponent
        var api = "https://huggingface.co/api/models/\(repo)/tree/\(revision)"
        if !directory.isEmpty { api += "/" + directory }
        guard let apiURL = URL(string: api) else { throw Failure.badLink }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: apiURL)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let file = files.first(where: { ($0["path"] as? String) == path }),
              let lfs = file["lfs"] as? [String: Any],
              let sha256 = lfs["oid"] as? String, sha256.count == 64,
              let size = (lfs["size"] as? NSNumber)?.int64Value ?? (file["size"] as? NSNumber)?.int64Value,
              size > 0 else { throw Failure.notFound }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return CustomLocalModel(id: "custom-" + sha256.prefix(12), name: name, repo: repo, revision: revision,
                                path: path, byteSize: size, sha256: sha256)
    }
}
