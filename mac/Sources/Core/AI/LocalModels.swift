import Combine
import Darwin
import Foundation

/// 一个本地模型（docs/local-models/DESIGN.md §2）。六个都一样：按需下载、启动 / 停止、开机自启、给功能用。
/// 只分「翻译专用」（Hy-MT2）和「通用」（Qwen3，翻译也能做），以及「这一类功能默认用哪个」。
struct LocalModelEntry: Identifiable {
    let model: OfflineModel
    /// `.translation` = 翻译专用；`.generation` = 通用。
    let kind: AIFeatureKind

    var id: String { model.id }
    var name: String { model.displayName }

    /// 运行时大约占多少内存：文件大小 + 1 GB（4096 上下文的 KV 缓存加计算缓冲，偏保守）。
    var memoryNeed: Int64 { model.byteSize + LocalModels.runtimeOverhead }

    @MainActor
    var translator: OfflineTranslator { OfflineTranslator.instance(for: model) }

    /// 适合做什么（「AI」页的说明）。
    var usage: String {
        switch model.id {
        case OfflineModel.translation.id: return L("localmodel.usage.translation")
        case OfflineModel.corrector.id: return L("localmodel.usage.small")
        case OfflineModel.qwen3_30b_a3b.id: return L("localmodel.usage.moe")
        default: return L("localmodel.usage.general")
        }
    }
}

/// 本地模型清单、推荐规则、开机自启（docs/local-models/DESIGN.md）。
enum LocalModels {
    static let runtimeOverhead: Int64 = 1 << 30

    /// 全部本地模型，从小到大。
    static let all: [LocalModelEntry] = [
        LocalModelEntry(model: .translation, kind: .translation),
        LocalModelEntry(model: .corrector, kind: .generation),
        LocalModelEntry(model: .qwen3_4b, kind: .generation),
        LocalModelEntry(model: .qwen3_8b, kind: .generation),
        LocalModelEntry(model: .qwen3_14b, kind: .generation),
        LocalModelEntry(model: .qwen3_30b_a3b, kind: .generation),
    ]

    static func entry(_ id: String) -> LocalModelEntry? { all.first { $0.id == id } }

    /// 能给这一类功能用的本地模型：翻译类 = 全部（Qwen3 用提示词翻译）；通用类 = 去掉翻译专用的。
    static func models(for kind: AIFeatureKind) -> [LocalModelEntry] {
        kind == .translation ? all : all.filter { $0.kind == .generation }
    }

    /// 这一类功能的默认本地模型：翻译 = Hy-MT2（「自动」翻译的离线后备）；通用 = Qwen3-1.7B。
    /// `AIEngineChoice.local` 指的就是它（docs/local-models/DESIGN.md §5）。
    static func defaultEntry(for kind: AIFeatureKind) -> LocalModelEntry {
        let id = kind == .translation ? OfflineModel.translation.id : OfflineModel.corrector.id
        return all.first { $0.id == id } ?? all[0]
    }

    /// 已下载（功能能用它）。
    @MainActor
    static func isInstalled(_ id: String) -> Bool {
        entry(id)?.translator.isReady ?? false
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

    /// 这台 Mac 推荐装哪个：占用不超过总内存 45% 的通用模型里最大的。
    static func recommended(totalMemory: Int64) -> LocalModelEntry? {
        models(for: .generation).filter { Double($0.memoryNeed) <= Double(totalMemory) * comfortableShare }
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

    private var subscriptions: [AnyCancellable] = []

    private init() {
        for entry in LocalModels.all {
            subscriptions.append(entry.translator.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
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
