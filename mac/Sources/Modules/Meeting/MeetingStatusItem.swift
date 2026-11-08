import AppKit

/// 会议的菜单栏项（docs/meeting/REQUIREMENTS.md §2、§3），点开都是会议菜单：
/// - 记录中常驻录音指示「● 32:15」（暂停时「‖ 32:15」）；
/// - 空闲时、打开了「菜单栏显示下一场倒计时」（默认关）就显示「📅 设计评审 · 25 分钟后」。
/// 两样都没有时不占菜单栏。录音指示优先。
@MainActor
final class MeetingStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var recordingText: String?
    private var recordingPaused = false
    private var countdownText: String?
    /// 现在显示的是什么（没变就不重画）。
    private var shown: String?
    /// 打开菜单时现建（只读内存，零磁盘 IO）。
    var menuItems: () -> [NSMenuItem] = { [] }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
    }

    /// 录音指示；text 为 nil = 不在记录（有倒计时就换成倒计时）。
    func update(text: String?, paused: Bool) {
        recordingText = text
        recordingPaused = paused
        render()
    }

    /// 下一场倒计时；nil = 不显示。
    func setCountdown(_ text: String?) {
        countdownText = text
        render()
    }

    private func render() {
        let signature: String?
        if let recordingText {
            signature = (recordingPaused ? "paused|" : "rec|") + recordingText
        } else if let countdownText {
            signature = "next|" + countdownText
        } else {
            signature = nil
        }
        guard let signature else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shown = nil
            return
        }
        if item == nil {
            // 排在 Baobox 主图标右边：系统默认的最左边可能是菜单栏管理的隐藏区，录音指示被藏起来就看不到了。
            let created = StatusItemController.makeCompanionItem(autosaveName: "baobox.meeting.indicator", offset: 2,
                                                                 length: NSStatusItem.variableLength)
            created.menu = menu
            item = created
        }
        guard let button = item?.button, shown != signature else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if let recordingText {
            button.image = nil
            let title = NSMutableAttributedString(
                string: recordingPaused ? "‖ " : "● ",
                attributes: [.font: font,
                             .foregroundColor: recordingPaused ? NSColor.secondaryLabelColor : NSColor.systemRed])
            title.append(NSAttributedString(string: recordingText, attributes: [.font: font]))
            button.attributedTitle = title
            button.toolTip = L("meeting.statusItem.help")
        } else if let countdownText {
            let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + countdownText, attributes: [.font: font])
            button.toolTip = L("meeting.statusItem.countdownHelp")
        }
        shown = signature
    }

    // 照 StatusItemController：AX 巡检会在后台线程「模拟打开」菜单，非主线程一律跳过。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for entry in menuItems() {
                StatusItemController.showHotkeyIfTagged(entry)
                menu.addItem(entry)
            }
        }
    }
}
