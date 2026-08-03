import Foundation

/// Claude Code 助手 —— 菜单会话行的展示格式(字段、排序、方案管理)。
///
/// 会话行为两行式:标题一行 + 元信息一行。元信息由有序字段列表渲染,
/// 内置「简洁 / 标准 / 详细」三个只读方案,用户可另存多个命名自定义方案。
/// 方案与选中态存 UserDefaults(JSON),菜单构建(`ClaudeCodeTool`)与设置页共用本 Store。

// MARK: - 字段

/// 会话行元信息可选字段。rawValue 入 UserDefaults,勿改。
enum SessionRowField: String, Codable, CaseIterable, Identifiable {
    case project
    case path
    case model
    case context
    case fileSize
    case time

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .project: return L("claudecode.rowformat.field.project")
        case .path: return L("claudecode.rowformat.field.path")
        case .model: return L("claudecode.rowformat.field.model")
        case .context: return L("claudecode.rowformat.field.context")
        case .fileSize: return L("claudecode.rowformat.field.fileSize")
        case .time: return L("claudecode.rowformat.field.time")
        }
    }

    /// 渲染字段值;数据缺失(旧缓存 / 尾块没扫到)返回 nil,该字段整体不展示。
    func render(_ summary: ClaudeSessionSummary) -> String? {
        switch self {
        case .project:
            return summary.projectName.isEmpty ? nil : summary.projectName
        case .path:
            let abbreviated = (summary.projectPath as NSString).abbreviatingWithTildeInPath
            return abbreviated.isEmpty ? nil : abbreviated
        case .model:
            return summary.model.map(Self.shortModelName)
        case .context:
            return summary.contextTokens.map { ClaudeFormat.tokens($0) }
        case .fileSize:
            return ClaudeFormat.bytes(summary.fileSize)
        case .time:
            return ClaudeFormat.relative(summary.lastActivity)
        }
    }

    /// 模型 id 缩短展示:去 `claude-` 前缀与日期后缀,末尾 `-4-8` → `-4.8`。
    static func shortModelName(_ id: String) -> String {
        var name = id
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        name = name.replacingOccurrences(of: #"-20\d{6}$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: "-$1.$2", options: .regularExpression)
        return name
    }
}

// MARK: - 方案

/// 一个展示方案:全字段有序列表 + 各自开关。内置方案 id 固定,自定义方案随机 UUID。
struct SessionRowScheme: Codable, Identifiable, Equatable {
    struct FieldConfig: Codable, Equatable {
        var field: SessionRowField
        var enabled: Bool
    }

    var id: UUID
    /// 内置方案存空串(展示名走 L() 随语言切换),自定义方案存用户输入。
    var name: String
    var fields: [FieldConfig]

    /// 按启用字段渲染元信息行;全部缺失返回空串。
    func metadataLine(for summary: ClaudeSessionSummary) -> String {
        fields.filter(\.enabled)
            .compactMap { $0.field.render(summary) }
            .joined(separator: " · ")
    }

    /// 解码后补齐后续版本新增的字段(保持既有顺序,新字段默认关闭追加在尾部)。
    mutating func fillMissingFields() {
        let present = Set(fields.map(\.field))
        for field in SessionRowField.allCases where !present.contains(field) {
            fields.append(FieldConfig(field: field, enabled: false))
        }
    }
}

// MARK: - Store

/// 方案存取与当前选中管理。主线程单例,菜单与设置页共用。
@MainActor
final class SessionRowFormatStore: ObservableObject {
    static let shared = SessionRowFormatStore()

    static let schemesKey = "claudecode.rowformat.schemes"
    static let selectedKey = "claudecode.rowformat.selected"

    private static let compactID = UUID(uuidString: "B0B0B0B0-0000-0000-0000-000000000001")!
    private static let standardID = UUID(uuidString: "B0B0B0B0-0000-0000-0000-000000000002")!
    private static let detailedID = UUID(uuidString: "B0B0B0B0-0000-0000-0000-000000000003")!

    /// 内置三方案。fields 覆盖全字段,顺序即展示顺序。
    static let builtins: [SessionRowScheme] = [
        SessionRowScheme(id: compactID, name: "", fields: configs([.project: true, .time: true])),
        SessionRowScheme(id: standardID, name: "", fields: configs([.project: true, .model: true, .time: true])),
        SessionRowScheme(id: detailedID, name: "", fields: configs([.project: true, .model: true, .context: true, .time: true])),
    ]

    /// 按 allCases 顺序生成全字段配置,仅字典中为 true 的启用。
    private static func configs(_ enabled: [SessionRowField: Bool]) -> [SessionRowScheme.FieldConfig] {
        SessionRowField.allCases.map { SessionRowScheme.FieldConfig(field: $0, enabled: enabled[$0] ?? false) }
    }

    @Published var customSchemes: [SessionRowScheme] {
        didSet { persist() }
    }
    @Published var selectedID: UUID {
        didSet { UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectedKey) }
    }

    private init() {
        var loaded: [SessionRowScheme] = []
        if let data = UserDefaults.standard.data(forKey: Self.schemesKey),
           let decoded = try? JSONDecoder().decode([SessionRowScheme].self, from: data) {
            loaded = decoded
            for index in loaded.indices { loaded[index].fillMissingFields() }
        }
        customSchemes = loaded

        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: raw) {
            selectedID = id
        } else {
            selectedID = Self.standardID
        }
        // 选中的自定义方案已被删(或数据损坏)时回退标准方案。
        if scheme(with: selectedID) == nil {
            selectedID = Self.standardID
        }
    }

    var allSchemes: [SessionRowScheme] { Self.builtins + customSchemes }

    var activeScheme: SessionRowScheme {
        scheme(with: selectedID) ?? Self.builtins[1]
    }

    func scheme(with id: UUID) -> SessionRowScheme? {
        allSchemes.first { $0.id == id }
    }

    func isBuiltin(_ id: UUID) -> Bool {
        Self.builtins.contains { $0.id == id }
    }

    /// 方案展示名:内置走本地化,自定义用存储名。
    func displayName(of scheme: SessionRowScheme) -> String {
        switch scheme.id {
        case Self.compactID: return L("claudecode.rowformat.preset.compact")
        case Self.standardID: return L("claudecode.rowformat.preset.standard")
        case Self.detailedID: return L("claudecode.rowformat.preset.detailed")
        default: return scheme.name
        }
    }

    /// 用当前方案渲染会话行元信息。
    func metadataLine(for summary: ClaudeSessionSummary) -> String {
        activeScheme.metadataLine(for: summary)
    }

    // MARK: 自定义方案 CRUD

    /// 以当前方案为底新建自定义方案并选中,返回新方案 id。
    @discardableResult
    func addScheme() -> UUID {
        var scheme = activeScheme
        scheme.id = UUID()
        scheme.name = "\(L("claudecode.rowformat.customDefault")) \(customSchemes.count + 1)"
        customSchemes.append(scheme)
        selectedID = scheme.id
        return scheme.id
    }

    func deleteScheme(_ id: UUID) {
        guard !isBuiltin(id) else { return }
        customSchemes.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = Self.standardID
        }
    }

    func updateScheme(_ scheme: SessionRowScheme) {
        guard let index = customSchemes.firstIndex(where: { $0.id == scheme.id }) else { return }
        customSchemes[index] = scheme
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customSchemes) {
            UserDefaults.standard.set(data, forKey: Self.schemesKey)
        }
    }

    /// 设置页预览用样例会话(不落盘、不参与索引)。计算属性,保证相对时间恒为「3 分钟前」。
    static var previewSummary: ClaudeSessionSummary { ClaudeSessionSummary(
        id: "preview",
        fileURL: URL(fileURLWithPath: "/dev/null"),
        projectPath: (NSHomeDirectory() as NSString).appendingPathComponent("qiao-repo/tools_mac"),
        projectName: "tools_mac",
        title: L("claudecode.rowformat.previewTitle"),
        lastActivity: Date().addingTimeInterval(-180),
        fileSize: 1_700_000,
        model: "claude-fable-5",
        contextTokens: 92_000
    ) }
}
