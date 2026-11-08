import AppKit

/// 看不见的占位状态项（docs/menubar-manager/TECH_DESIGN.md §3）：撑到 10_000 宽，排在它左边的图标全被推出屏幕。
///
/// 用户不碰它（2026-11-08 用户：「不需要分割线」），没有图像、不能点，读屏也跳过它。
/// 挪图标、点隐藏的图标时临时缩短到「只让要碰的那个图标露出来」的长度（MenuBarActions），做完再撑回去。
@MainActor
final class MenuBarSpacer {
    static let autosaveName = "baobox.menubar.spacer"
    private static let collapsedLength: CGFloat = 10_000

    private var item: NSStatusItem?

    var isInstalled: Bool { item != nil }

    func install() {
        guard item == nil else { return }
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        // 第一次：排到所有图标的最左边（值越大越靠左，探针实测 100000 落在最左），这时谁都不隐藏。
        // 之后系统按它记住的位置摆；⌘ 拖别的图标时系统会把它的值也改成实际位置。
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(20_000.0, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.isEnabled = false
            button.setAccessibilityElement(false)
        }
        self.item = item
    }

    /// 关掉菜单栏管理：移除后，隐藏的图标全部回到菜单栏。
    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func collapse() {
        item?.length = Self.collapsedLength
    }

    /// 设成指定长度：右边钉在原位不动，左边跟着走，隐藏区里的图标整体跟着平移（MenuBarActions 用它只放出一个图标）。
    func setLength(_ length: CGFloat) {
        item?.length = max(0, min(length, Self.collapsedLength))
    }

    /// 占位项的窗口号（挪图标时当「挪到它左边 / 右边」的目标）。
    var windowID: CGWindowID? {
        item?.button?.window.map { CGWindowID($0.windowNumber) }
    }

    /// 占位项窗口的左右边。水平方向 AppKit 与 CG 同一套 x，直接拿来和扫描结果（CG 坐标）比。
    var frameX: (minX: CGFloat, maxX: CGFloat)? {
        guard let frame = item?.button?.window?.frame else { return nil }
        return (frame.minX, frame.maxX)
    }
}
