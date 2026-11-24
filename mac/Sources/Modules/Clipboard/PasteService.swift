import AppKit
import Carbon.HIToolbox
import os

/// 回填粘贴服务。
enum PasteService {
    /// 日志只记 bundle id、布尔值、毫秒数和走了哪条路，不记粘贴的内容。
    private static let log = Logger(subsystem: "com.baobox.app", category: "clipboard")

    /// - Parameter overrideText: 非 nil 时粘贴它而不是 `item.text`（预览区里做过转换）。
    ///   转换结果只在内存里，历史条目本身不变。
    /// - Parameter target: 粘贴到哪个 App。取的顺序（`LauncherPasteTarget`）：传入的 → 剪贴板面板唤起时记下的前台 App →
    ///   快速入口正在执行的动作的目标（`LauncherFocus.actionContext`：剪贴板条目、「纯文本粘贴上一条」这类命令从快速入口执行时）。
    ///   都没有 = 粘给此刻的前台 App（全局快捷键触发时就是它）。快速入口的上下文进门就同步读走，后面的异步步骤只用读走的值。
    @MainActor
    static func paste(_ item: ClipboardItem, plainText: Bool,
                      overrideText: String? = nil,
                      target explicitTarget: NSRunningApplication? = nil,
                      store: ClipboardStore, monitor: ClipboardMonitor) {
        let began = ProcessInfo.processInfo.systemUptime
        // 0) 是不是快速入口的动作：只在动作闭包同步执行时看得到，进门就读走（全局快捷键、剪贴板面板来的这里是 nil）。
        let launcherAction = LauncherFocus.actionContext
        // 1) 忽略本次回填产生的 pasteboard 变更
        monitor.ignoreNextChange = true
        guard writeToPasteboard(item, plainText: plainText, overrideText: overrideText) else {
            // 图片缓存文件已丢失：此时剪贴板已被 clearContents 清空，
            // 继续合成 ⌘V 会"粘贴出空气"，必须就地报错停下。
            log.notice("paste: image file is missing, stopped")
            ClipboardPanelController.current?.hide()
            showBlockedAlert(title: L("clipboard.paste.blockedTitle"),
                             message: L("clipboard.paste.blockedMessage"))
            return
        }

        // 2) 关闭面板前先取出唤起时记录的前台 App —— 那才是真正的粘贴目标。
        //    面板拿过焦点，此刻的 frontmostApplication 已经不可靠。
        let choice = LauncherPasteTarget.resolve(explicit: explicitTarget,
                                                 clipboardPanel: ClipboardPanelController.current?.previousApp,
                                                 launcher: launcherAction?.target)
        let target = choice.app
        // 从快速入口执行的（剪贴板条目、「纯文本粘贴上一条」这类命令）：发 ⌘V 前看键盘，粘不出去时要给一句回执。
        let fromLauncher = LauncherPasteTarget.isFromLauncher(inLauncherAction: launcherAction != nil, source: choice.source)
        ClipboardPanelController.current?.hide()

        // 3) 已授权辅助功能 → 切回目标 App 并合成 ⌘V；否则明确告知降级为仅复制。
        let hasAccessibility = Permissions.hasAccessibility
        log.notice("paste: target \(LauncherFocus.bundleID(target), privacy: .public) from \(choice.source.rawValue, privacy: .public), accessibility \(hasAccessibility, privacy: .public), from launcher \(fromLauncher, privacy: .public), front \(LauncherFocus.bundleID(NSWorkspace.shared.frontmostApplication), privacy: .public)")
        guard hasAccessibility else {
            log.notice("paste: no accessibility permission, copied only (explaining in an alert)")
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
            log.notice("paste: activating the target, then ⌘V")
            target.activate()
        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == myPID {
            // 目标是自己或未知，仅保留复制结果。从快速入口来的说一句（别的途径保持原样）。
            log.notice("paste: no target and Baobox is frontmost, copied only")
            if fromLauncher {
                NotifyCenter.shared.post(Notice(source: "clipboard", level: .ambient, title: L("clipboard.paste.copiedNotPasted"),
                                                icon: "doc.on.clipboard", isUserFeedback: true))
            }
            return
        } else {
            log.notice("paste: no target, ⌘V into the frontmost app")
        }
        // 留 0.12s 给目标 App 完成激活，之后再等物理修饰键松开。
        let pending = PendingPaste(target: target, fromLauncher: fromLauncher, began: began)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated {
                pasteAfterModifiersReleased(pending, deadline: Date().addingTimeInterval(0.5),
                                            waitStarted: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// 一次还没发出 ⌘V 的粘贴。
    private struct PendingPaste {
        let target: NSRunningApplication?
        /// 从快速入口执行的：发 ⌘V 前先看系统键盘焦点在哪儿（`LauncherFocus.checkKeyboardBeforePaste`）。
        let fromLauncher: Bool
        /// 进入 `paste` 的时刻（uptime）。
        let began: TimeInterval
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
    /// 从快速入口执行的，修饰键松开后先看系统键盘焦点：在第三个 App 那里就不发 ⌘V（内容已在剪贴板上，回执已发）。
    /// 发出那一刻记一行日志：前台 App、系统键盘焦点所在 App（读得到的话）、从进入 `paste` 起多少毫秒、等修饰键用了多久。
    @MainActor
    private static func pasteAfterModifiersReleased(_ pending: PendingPaste, deadline: Date, waitStarted: TimeInterval) {
        let held: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let released = NSEvent.modifierFlags.intersection(held).isEmpty
        guard released || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                MainActor.assumeIsolated {
                    pasteAfterModifiersReleased(pending, deadline: deadline, waitStarted: waitStarted)
                }
            }
            return
        }
        let modifiersWaited = (ProcessInfo.processInfo.systemUptime - waitStarted) * 1000
        let post = {
            let now = ProcessInfo.processInfo.systemUptime
            log.notice("paste: posting ⌘V; front \(LauncherFocus.bundleID(NSWorkspace.shared.frontmostApplication), privacy: .public), keyboard (AX) \(LauncherFocus.bundleID(pid: LauncherFocus.keyboardFocusPID()), privacy: .public), \((now - pending.began) * 1000, format: .fixed(precision: 0), privacy: .public) ms since paste began, modifiers waited \(modifiersWaited, format: .fixed(precision: 0), privacy: .public) ms\(released ? "" : " (timed out, still held)", privacy: .public)")
            simulateCommandV()
        }
        guard pending.fromLauncher else {
            post()
            return
        }
        LauncherFocus.checkKeyboardBeforePaste(target: pending.target) { check in
            if check == .clear {
                post()
            } else {
                // 内容在进门时已经写进剪贴板：说清原因，让用户自己 ⌘V。
                log.notice("paste: not posting ⌘V (\(String(describing: check), privacy: .public)); left on the clipboard")
                LauncherFocus.postBlockedReceipt(check)
            }
        }
    }

    /// 写入成功返回 true；仅当图片条目的缓存文件丢失时返回 false（此时剪贴板已被清空）。
    @MainActor
    private static func writeToPasteboard(_ item: ClipboardItem, plainText: Bool,
                                          overrideText: String? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 转换结果永远是纯文本，与条目原本的类型无关（图片条目不产生 override）。
        if let overrideText {
            pasteboard.setString(overrideText, forType: .string)
            return true
        }

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
                guard let data = ClipboardStore.imageData(for: item),
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
