import Foundation

/// 一套 hosts 方案：一段 hosts 片段 + 是否启用。多套可同时启用（叠加）。
struct HostsScheme: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var content: String
    var isEnabled: Bool
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, content: String,
         isEnabled: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    // 手写解码：外部文件字段缺失/类型不符只降级，决不让整份 schemes.json 解码失败
    //（那等于用户所有方案一次性丢光）。
    private enum CodingKeys: String, CodingKey {
        case id, name, content, isEnabled, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        content = (try? container.decode(String.self, forKey: .content)) ?? ""
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

/// 应用到系统 hosts 的结果。用户主动取消要与真失败区分开：前者安静收场，后者才提示。
enum HostsApplyOutcome {
    case ok
    case cancelled
    case failed(String)
}

/// 方案存储 + 应用到 `/etc/hosts` 的协调者。
@MainActor
final class HostsStore: ObservableObject {
    static let shared = HostsStore()

    @Published private(set) var schemes: [HostsScheme] = []
    /// 提权写入进行中（授权框已弹出）。菜单/设置页据此避免重复触发。
    @Published private(set) var isApplying = false
    /// 系统 hosts 当前是否带 Baobox 块。仅用于展示，刷新时机为 `refreshManagedState()`。
    @Published private(set) var isManaged = false

    private init() {
        load()
        isManaged = HostsFile.isManaged(HostsFile.readSystem())
    }

    var enabledSchemes: [HostsScheme] { schemes.filter { $0.isEnabled } }

    // MARK: - 增删改

    @discardableResult
    func add(name: String, content: String = "") -> UUID {
        let scheme = HostsScheme(name: name, content: content)
        schemes.append(scheme)
        save()
        return scheme.id
    }

    func delete(_ id: UUID) {
        schemes.removeAll { $0.id == id }
        save()
    }

    func setName(_ id: UUID, _ name: String) {
        guard let index = schemes.firstIndex(where: { $0.id == id }) else { return }
        schemes[index].name = name
        schemes[index].updatedAt = Date()
        save()
    }

    func setContent(_ id: UUID, _ content: String) {
        guard let index = schemes.firstIndex(where: { $0.id == id }) else { return }
        schemes[index].content = content
        schemes[index].updatedAt = Date()
        save()
    }

    /// 只改内存与落盘状态，**不写系统文件**——写系统一律走 `apply`。
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = schemes.firstIndex(where: { $0.id == id }) else { return }
        schemes[index].isEnabled = enabled
        save()
    }

    /// 把当前 `/etc/hosts` 里「非 Baobox 段」的内容导入成一套新方案（默认不启用）。
    @discardableResult
    func importFromSystem(name: String) -> UUID {
        let user = HostsFile.stripBlock(HostsFile.readSystem())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return add(name: name, content: user)
    }

    // MARK: - 应用到系统

    /// 组装并提权写入 `/etc/hosts`，随后刷新 DNS 缓存。内容无变化时直接成功返回，不弹授权框。
    func apply(completion: (@MainActor (HostsApplyOutcome) -> Void)? = nil) {
        guard !isApplying else {
            completion?(.cancelled)
            return
        }
        let block = HostsFile.blockText(from: enabledSchemes)
        isApplying = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = HostsWriter.write(block: block)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isApplying = false
                    self.isManaged = HostsFile.isManaged(HostsFile.readSystem())
                    completion?(outcome)
                }
            }
        }
    }

    /// 停用全部方案并把 Baobox 块从系统 hosts 里整段摘掉。
    func disableAllAndApply(completion: (@MainActor (HostsApplyOutcome) -> Void)? = nil) {
        for scheme in schemes where scheme.isEnabled {
            setEnabled(scheme.id, false)
        }
        apply(completion: completion)
    }

    func refreshManagedState() {
        isManaged = HostsFile.isManaged(HostsFile.readSystem())
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: HostsEnv.schemesFile) else { return }
        schemes = (try? JSONDecoder().decode([HostsScheme].self, from: data)) ?? []
    }

    private func save() {
        HostsEnv.ensureSupportDir()
        let snapshot = schemes
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: HostsEnv.schemesFile, options: .atomic)
        }
    }
}
