import AppKit

/// 记录中常驻的菜单栏录音指示「● 32:15」（暂停时「‖ 32:15」），点开是会议菜单（docs/meeting/REQUIREMENTS.md §3）。
/// 只在会议记录期间存在，空闲时不占菜单栏。
@MainActor
final class MeetingStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var shownText: String?
    private var shownPaused: Bool?
    /// 打开菜单时现建（只读内存，零磁盘 IO）。
    var menuItems: () -> [NSMenuItem] = { [] }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
    }

    /// text 为 nil = 收起。
    func update(text: String?, paused: Bool) {
        guard let text else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownText = nil
            shownPaused = nil
            return
        }
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.menu = menu
            item = created
        }
        guard let button = item?.button, shownText != text || shownPaused != paused else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(
            string: paused ? "‖ " : "● ",
            attributes: [.font: font, .foregroundColor: paused ? NSColor.secondaryLabelColor : NSColor.systemRed])
        title.append(NSAttributedString(string: text, attributes: [.font: font]))
        button.attributedTitle = title
        button.toolTip = L("meeting.statusItem.help")
        shownText = text
        shownPaused = paused
    }

    // 照 StatusItemController：AX 巡检会在后台线程「模拟打开」菜单，非主线程一律跳过。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for entry in menuItems() { menu.addItem(entry) }
        }
    }
}
