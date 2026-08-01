import CoreGraphics
import Foundation

// MARK: - 数据结构

/// 表格里的一行（时间转换表、URL query、JWT 声明）。
struct FormatRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    /// nil = 该行不给复制按钮（如「3 小时前」这种没法粘的值）。
    let copyValue: String?
    /// 需要标橙提醒的行（如已过期的 exp）。
    var isWarning = false
}

enum FormatActionKind {
    /// 文本 → 文本。结果进预览缓冲，⏎ 粘贴的就是它。
    /// 返回 nil = 这次转换不适用（按钮理论上不该被点到，兜底静默）。
    case transform((String) -> String?)
    /// 文本 → 图片，内嵌进预览区展示（二维码）。同一动作再按一次收起，由面板负责。
    /// 返回 nil = 生成失败，静默不动。
    case imagePreview((String) -> CGImage?)
    /// 输出不是文本，动作自己收尾（浏览器打开、Finder 中显示…）。
    case terminal(@MainActor (String) -> Void)
    /// 一组转换收进一个下拉按钮（JSON / URL / cURL / 通用「编码/解码」）。
    /// 子项须是 transform；容器本身不可执行也不占 ⌘ 序号（keyboardActions
    /// 只展开子项），面板把它渲染成 Menu。
    case menu([FormatAction])
}

struct FormatAction: Identifiable {
    let id: String
    /// 已本地化的按钮标题。
    let title: String
    let kind: FormatActionKind
    /// false = 按钮置灰（超长度上限、超二维码容量…）。
    var isEnabled = true
    /// 置灰原因，作为 tooltip 展示。
    var disabledHint: String? = nil
}

struct FormatMatch: Identifiable {
    /// 与识别器 id 一致。
    let id: String
    /// 徽章文案。格式名（JSON / XML…）直接用英文原名，只有语义化的才本地化。
    let badge: String
    /// 覆盖预览正文的渲染结果；nil = 照常显示条目原文。
    ///
    /// **只有原文不可读、且没有等价显式动作时才给**（当前仅 JWT 的分段视图）。
    /// 其余一律留 nil —— 转换是用户显式动作，不能因为「选中了」就把预览换掉，
    /// 否则预览显示的和 ⏎ 粘出去的不一致（Base64 曾自动渲染，2026-08-02 撤销）。
    var rendered: String? = nil
    /// 表格区内容；空数组 = 不显示表格。
    var rows: [FormatRow] = []
    var actions: [FormatAction] = []
}

/// 识别器：一个格式的检测 + 渲染 + 动作。**必须是纯函数**，不得有副作用。
protocol TextFormatRecognizer {
    /// 与 `FormatMatch.id` 一致，也是本地化命名空间后缀。
    var id: String { get }
    /// 数值越小越靠前。依据是**误报率**而非重要性：
    /// JWT 的门槛几乎不可能误报所以排第一，Base64 字符集太宽松所以排最后。
    var priority: Int { get }
    func detect(_ text: String) -> FormatMatch?
}

// MARK: - 上限

/// 识别的长度上限。识别走主线程同步执行，没有上限的话长按 ↑↓ 会掉帧。
///
/// 只留这一道：动作只可能挂在识别成功的条目上，而识别本身已经被这个上限卡住，
/// 所以再给转换单设一道更宽的门槛（原设计里的 2MB）永远不会触发，纯属死代码。
enum TextToolLimits {
    /// 超过此长度不做识别（只显示原文，通用动作仍在）。
    static let maxDetect = 256 * 1024
}

// MARK: - 开关

/// 文本工具的开关。识别是主线程同步跑的，**关掉的识别器压根不参与检测**（在
/// `detectAll` 里先 filter 再 detect），所以用户不需要的格式是真的零开销，
/// 不是「跑完再藏起来」。
enum TextToolSettings {
    struct Descriptor {
        let id: String
        /// 已本地化的显示名。格式名（JSON/XML…）中英一致，直接用原名。
        let title: String
    }

    static let masterKey = "clipboard.textTools.enabled"
    /// 通用动作不是识别器，但同样出现在设置列表里，共用一套键
    /// （2026-08-02 起二维码之外的通用动作也各有开关）。
    static let qrCodeID = "qrcode"
    static let encodeMenuID = "encodemenu"
    static let pinCardID = "pincard"
    static let editorID = "editor"

    static func key(for id: String) -> String { "clipboard.textTools.\(id)" }

    /// 设置页的行顺序 = 面板徽章的优先级顺序；通用动作按动作栏顺序排在后面。
    static var descriptors: [Descriptor] {
        [
            Descriptor(id: "jwt", title: "JWT"),
            Descriptor(id: "json", title: "JSON"),
            Descriptor(id: "xml", title: "XML"),
            Descriptor(id: "timestamp", title: L("clipboard.tools.name.timestamp")),
            // URL 开关同管 cURL（同一识别器、同一 id）
            Descriptor(id: "url", title: "URL / cURL"),
            Descriptor(id: "base64", title: "Base64"),
            Descriptor(id: encodeMenuID, title: L("clipboard.tools.action.encodeDecode")),
            Descriptor(id: qrCodeID, title: L("clipboard.tools.action.qrcode")),
            Descriptor(id: pinCardID, title: L("clipboard.tools.name.pinCard")),
            Descriptor(id: editorID, title: L("clipboard.tools.name.editor"))
        ]
    }

    /// 全部出厂开启：未设置过时 `object(forKey:)` 为 nil，取默认 true。
    static var isMasterEnabled: Bool {
        UserDefaults.standard.object(forKey: masterKey) as? Bool ?? true
    }

    static func isEnabled(_ id: String) -> Bool {
        guard isMasterEnabled else { return false }
        return UserDefaults.standard.object(forKey: key(for: id)) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for id: String) {
        UserDefaults.standard.set(enabled, forKey: key(for: id))
    }

    /// 设置页初始化用。
    static func currentStates() -> [String: Bool] {
        var states: [String: Bool] = [:]
        for descriptor in descriptors {
            states[descriptor.id] = UserDefaults.standard.object(forKey: key(for: descriptor.id)) as? Bool ?? true
        }
        return states
    }
}

// MARK: - 注册表

@MainActor
enum TextFormatRegistry {
    /// 新增一个格式 = 新增一个识别器文件 + 在这里加一行。面板不认识任何具体格式。
    static let recognizers: [TextFormatRecognizer] = [
        JWTRecognizer(),        // 10
        JSONRecognizer(),       // 20
        XMLRecognizer(),        // 30
        TimestampRecognizer(),  // 40
        URLRecognizer(),        // 50
        Base64Recognizer()      // 90
    ]

    /// 对一条文本跑**已启用的**识别器，按 priority 升序返回。
    ///
    /// 注意 filter 在 detect 之前：关掉的格式一次 `detect` 都不会跑 —— 这是设置页
    /// 那组开关的意义所在（识别走主线程同步，不能白花 CPU）。
    static func detectAll(_ text: String) -> [FormatMatch] {
        guard TextToolSettings.isMasterEnabled,
              text.utf8.count <= TextToolLimits.maxDetect else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return recognizers
            .filter { TextToolSettings.isEnabled($0.id) }
            .sorted { $0.priority < $1.priority }
            .compactMap { $0.detect(trimmed) }
    }

    /// 对任何文本条目都出现的动作，排在格式专属动作之后。
    /// 各通用动作的独立开关在 CommonTextActions 里逐个判断；这里只把总开关的关。
    static func commonActions(for text: String) -> [FormatAction] {
        guard TextToolSettings.isMasterEnabled else { return [] }
        return CommonTextActions.all(for: text)
    }
}
