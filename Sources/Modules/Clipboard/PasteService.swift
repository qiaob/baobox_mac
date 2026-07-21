import AppKit
import Carbon.HIToolbox

/// 回填粘贴服务。
enum PasteService {
    @MainActor
    static func paste(_ item: ClipboardItem, plainText: Bool, store: ClipboardStore, monitor: ClipboardMonitor) {
        // 1) 忽略本次回填产生的 pasteboard 变更
        monitor.ignoreNextChange = true
        guard writeToPasteboard(item, plainText: plainText) else {
            // 图片缓存文件已丢失：此时剪贴板已被 clearContents 清空，
            // 继续合成 ⌘V 会"粘贴出空气"，必须就地报错停下。
            ClipboardPanelController.current?.hide()
            showBlockedAlert(title: L("clipboard.paste.blockedTitle"),
                             message: L("clipboard.paste.blockedMessage"))
            return
        }

        // 2) 关闭面板前先取出唤起时记录的前台 App —— 那才是真正的粘贴目标。
        //    面板拿过焦点，此刻的 frontmostApplication 已经不可靠。
        let target = ClipboardPanelController.current?.previousApp
        ClipboardPanelController.current?.hide()

        // 3) 已授权辅助功能 → 切回目标 App 并合成 ⌘V；否则明确告知降级为仅复制。
        guard Permissions.hasAccessibility else {
            // 不能只调 promptAccessibility()：AX 系统授权弹窗每次启动只出现一次，
            // 之后再调用毫无反应 —— 用户按 ⏎ 后面板关闭、没有粘贴、没有任何提示，
            // 观感就是"卡死了"。改为自己弹说明框，把降级行为讲清楚并给授权入口。
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("clipboard.paste.noAXTitle")
            alert.informativeText = L("clipboard.paste.noAXMessage")
            alert.addButton(withTitle: L("clipboard.paste.goEnableAX"))
            alert.addButton(withTitle: L("clipboard.paste.gotIt"))
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.promptAccessibility() // 首次会弹系统窗并把 App 登记进列表
                Permissions.openSystemSettings(pane: .accessibility)
            }
            return
        }

        // 粘贴目标缺失（面板不在 / 记录失败）时不能盲发 ⌘V：
        // 那会打给"此刻碰巧在前台"的任意 App，把内容粘进无关窗口。
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let target, target.processIdentifier != myPID {
            target.activate()
        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == myPID {
            return // 目标是自己或未知，仅保留复制结果
        }
        // 留 0.12s 给目标 App 完成激活，之后再等物理修饰键松开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pasteAfterModifiersReleased(deadline: Date().addingTimeInterval(0.5))
        }
    }

    @MainActor
    private static func showBlockedAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// 等物理修饰键全部松开后再合成 ⌘V（带超时兜底）。
    ///
    /// 快捷键触发后立刻发事件时，用户几乎必然还按着 ⌘⇧ / ⌘⌥，硬件修饰键状态会叠加到
    /// 接收端 —— 目标 App 实际收到的是 ⌘⇧V / ⌘⌥V（在多数 App 里是「粘贴并匹配样式」
    /// 或干脆无动作），表现为「粘贴出来的不对」或「按了没反应」。
    private static func pasteAfterModifiersReleased(deadline: Date) {
        let held: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        if NSEvent.modifierFlags.intersection(held).isEmpty || Date() >= deadline {
            simulateCommandV()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            pasteAfterModifiersReleased(deadline: deadline)
        }
    }

    /// 写入成功返回 true；仅当图片条目的缓存文件丢失时返回 false（此时剪贴板已被清空）。
    @MainActor
    private static func writeToPasteboard(_ item: ClipboardItem, plainText: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .link:
            pasteboard.setString(item.text ?? "", forType: .string)

        case .file:
            if plainText {
                pasteboard.setString(item.text ?? "", forType: .string)
            } else {
                let urls = (item.text ?? "")
                    .split(separator: "\n")
                    .map { NSURL(fileURLWithPath: String($0)) }
                if urls.isEmpty {
                    pasteboard.setString(item.text ?? "", forType: .string)
                } else {
                    pasteboard.writeObjects(urls)
                }
            }

        case .image:
            if plainText {
                pasteboard.setString(item.imageFilename ?? "", forType: .string)
            } else {
                guard let filename = item.imageFilename,
                      let data = try? Data(contentsOf: ClipboardStore.imagesDir.appendingPathComponent(filename)),
                      let image = NSImage(data: data) else {
                    return false
                }
                pasteboard.writeObjects([image])
                pasteboard.setData(data, forType: .png)
            }
        }
        return true
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V) // 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
