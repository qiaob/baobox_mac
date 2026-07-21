import AppKit

/// 携带闭包动作的 NSMenuItem，供框架与工具模块构建菜单时复用。
/// NSMenu 默认开启 autoenablesItems：设置了 target/action 的项保持可用，
/// action 为 nil 的项会被自动置灰（正好用于 M2 占位项）。
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    /// 关联的全局快捷键 id。非 nil 时，框架会在构建菜单时把当前键位渲染到该项右侧
    /// （二级菜单项没有 submenu，可直接用原生 keyEquivalent 显示）。
    let hotkeyID: String?

    init(title: String, keyEquivalent: String = "", hotkeyID: String? = nil,
         handler: @escaping () -> Void) {
        self.handler = handler
        self.hotkeyID = hotkeyID
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
