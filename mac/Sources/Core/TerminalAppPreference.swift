import AppKit

/// 续接会话等命令所用的终端应用偏好（通用设置）。
///
/// macOS 没有系统级「默认终端」概念：`.command` 脚本的默认关联是系统 Terminal，
/// 与用户日常终端割裂——在系统 Terminal 里 Claude TUI 的真彩色转义与 powerline
/// 字形会渲染成乱码。因此由本枚举显式解析目标终端,`TerminalLauncher` 按启动方式拉起:
/// - document:App 声明了 `.command` 文档类型(Terminal / iTerm2 / Ghostty),
///   直接 `open(_:withApplicationAt:)` 执行;
/// - binary:App 不接管 `.command`(kitty / WezTerm / Alacritty),直接拉起
///   bundle 可执行文件并把脚本路径作为待执行程序参数传入。
enum TerminalAppChoice: String, CaseIterable, Identifiable {
    case auto
    case iterm
    case ghostty
    case kitty
    case wezterm
    case alacritty
    case system

    var id: String { rawValue }

    static let defaultsKey = "general.terminalApp"

    /// auto 模式与偏好失效时的回退顺序:第三方终端优先,系统 Terminal 兜底。
    private static let fallbackOrder: [TerminalAppChoice] = [
        .iterm, .ghostty, .kitty, .wezterm, .alacritty, .system,
    ]

    var bundleID: String? {
        switch self {
        case .auto: return nil
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .kitty: return "net.kovidgoyal.kitty"
        case .wezterm: return "com.github.wez.wezterm"
        case .alacritty: return "org.alacritty"
        case .system: return "com.apple.Terminal"
        }
    }

    /// 启动方式。binary 关联值为脚本路径之前的参数前缀。
    enum LaunchStyle {
        case document
        case binary(argsPrefix: [String])
    }

    var launchStyle: LaunchStyle {
        switch self {
        case .kitty: return .binary(argsPrefix: ["--single-instance"])
        case .wezterm: return .binary(argsPrefix: ["start", "--"])
        case .alacritty: return .binary(argsPrefix: ["-e"])
        default: return .document
        }
    }

    /// 终端名按惯例用产品名书写；仅「自动」「系统终端」需要本地化。
    var displayName: String {
        switch self {
        case .auto: return L("settings.general.terminal.auto")
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .alacritty: return "Alacritty"
        case .system: return L("settings.general.terminal.system")
        }
    }

    /// 设置页展示用：未安装的具体终端追加「（未安装）」，选中它时运行期按 auto 回退。
    var pickerLabel: String {
        guard bundleID != nil, installedAppURL == nil else { return displayName }
        return displayName + L("settings.general.terminal.notInstalled")
    }

    /// 该选项对应的已安装 App；auto 或未安装返回 nil。
    var installedAppURL: URL? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var current: TerminalAppChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let choice = TerminalAppChoice(rawValue: raw) else { return .auto }
            return choice
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 解析最终使用的终端:偏好未安装(或为 auto)时走回退顺序。
    /// 返回具体选项与其 App URL;连系统 Terminal 都找不到返回 nil,调用方交回系统默认关联。
    static func resolveLaunch() -> (choice: TerminalAppChoice, appURL: URL)? {
        if let url = current.installedAppURL { return (current, url) }
        for choice in fallbackOrder {
            if let url = choice.installedAppURL { return (choice, url) }
        }
        return nil
    }
}
