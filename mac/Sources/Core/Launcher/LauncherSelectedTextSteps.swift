import Foundation

/// 读一个焦点元素里选中的文字：要读哪几个属性、按什么顺序（docs/launcher/TECH_DESIGN.md §8.4）。
/// AX 调用由 `Core/SelectedTextReader` 注入（每一步一个闭包），这里只管顺序和「什么时候不读全文」——
/// 纯 Foundation，进 BaoboxTests（真的 AX 要辅助功能权限，测不了）。划词助手和快速入口共用。
enum LauncherSelectedTextSteps {
    /// 先读 `selectedText`（kAXSelectedText）；没有（很多文本视图没选中时回「成功 + 空串」）就用「全文 + 选区范围」切。
    /// - `timed`（快速入口呼出时，带时限）：**先读选区范围，长度 > 0 才读全文** —— 光标停在一个大文件里、没选中时，
    ///   不经 AX 把整篇正文拉过来，也不会因为拉正文超了时把「没有」记成「超时」。
    /// - 不带时限（划词助手）：同下沉前的顺序，先全文、后范围。
    /// - `stopped`：第一步之后到点 / 超时了就不再读（带时限的那一步一步本来也会因到点读不到）。
    static func read(timed: Bool,
                     selectedText: () -> String?,
                     selectedRange: () -> NSRange?,
                     value: () -> String?,
                     stopped: () -> Bool) -> String? {
        if let text = selectedText(), !text.isEmpty { return text }
        if stopped() { return nil }
        if timed {
            guard let range = selectedRange(), range.length > 0, let value = value() else { return nil }
            return substring(of: value, range: range)
        }
        guard let value = value(), let range = selectedRange(), range.length > 0 else { return nil }
        return substring(of: value, range: range)
    }

    /// 按选区范围切全文。AX 的范围按 UTF-16 计，与 NSString 同口径；越界为 nil。
    static func substring(of value: String, range: NSRange) -> String? {
        let ns = value as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: range)
    }
}
