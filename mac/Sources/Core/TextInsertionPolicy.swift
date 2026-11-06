import Foundation

/// 往别的 App 里插文字时走哪一档（docs/dictation/TECH_DESIGN.md §5）。纯逻辑，可单测；
/// 辅助功能查询与实际写入 / 粘贴在 `TextInserter`。
enum TextInsertionPolicy {
    /// 没能插进去、只能复制给用户自己 ⌘V 的原因。
    enum CopyReason: Equatable {
        /// 安全输入开着（焦点在密码框）：不往里粘贴。
        case secureInput
        /// 没有辅助功能权限：既读不了焦点，也合成不了 ⌘V。
        case noAccessibility
        /// 焦点不在能输入文字的地方（按钮、列表、桌面…）。
        case noTextFocus
        /// 剪贴板正被借用（划词取词 / 上一次粘贴还没还原）。
        case busy
    }

    enum Route: Equatable {
        /// 用辅助功能直接写进焦点输入框（写完读回校验）。
        case accessibility
        /// 借剪贴板粘贴。
        case paste
        case copy(CopyReason)
    }

    /// 辅助功能看到的焦点元素。
    struct Focus: Equatable {
        /// nil = App 回答了「没有焦点元素」。
        var role: String?
        var subrole: String?
        /// `kAXSelectedTextAttribute` 可写。
        var selectedTextSettable = false
        /// `kAXValueAttribute` 能读成字符串（写完读回校验要用）。
        var valueReadable = false
        /// 在网页内容区里（某一级祖先是 AXWebArea）：浏览器 / WebView 的输入框。
        var inWebArea = false
    }

    /// 文字输入类的角色（搜索框的角色多是 AXTextField + 子角色 AXSearchField，少数直接报 AXSearchField）。
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static let secureSubrole = "AXSecureTextField"

    /// 终端：辅助功能「写进」文字视图不等于输进 shell，一律粘贴。
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.appmakes.otty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
    ]

    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Electron App：包里带 `Contents/Frameworks/Electron Framework.framework`。它们的输入框是网页，
    /// 辅助功能写不进去（或写了不触发页面的输入事件），一律粘贴。
    static func isElectron(appURL: URL?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> Bool {
        guard let appURL else { return false }
        let framework = appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return fileExists(framework.path)
    }

    /// 「只粘贴」名单：终端、Electron。浏览器内容区按焦点判断（见 `route`）。
    static func isPasteOnly(bundleID: String?, appURL: URL?,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        isTerminal(bundleID: bundleID) || isElectron(appURL: appURL, fileExists: fileExists)
    }

    /// 选档。`focus` 为 nil = App 不回答辅助功能查询（不支持 / 超时）：尽力粘贴。
    static func route(pasteOnly: Bool, alwaysPaste: Bool, focus: Focus?) -> Route {
        if focus?.subrole == secureSubrole { return .copy(.secureInput) }
        if pasteOnly { return .paste }
        guard let focus else { return .paste }
        guard let role = focus.role else { return .copy(.noTextFocus) }
        if focus.inWebArea { return .paste }
        let textLike = textRoles.contains(role) || focus.selectedTextSettable
        guard textLike else { return .copy(.noTextFocus) }
        if alwaysPaste { return .paste }
        // 值读不回来就无法确认写没写进去：宁可直接粘贴，也不冒「写进去了又粘一遍」变两份的险。
        if textRoles.contains(role), focus.selectedTextSettable, focus.valueReadable { return .accessibility }
        return .paste
    }
}
