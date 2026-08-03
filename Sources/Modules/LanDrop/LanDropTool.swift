import AppKit
import SwiftUI

/// 局域网传输 —— ToolModule 壳：菜单开关、地址、内嵌二维码、传输进度、最近接收、
/// 快捷键（出厂不绑定）与生命周期。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，只读内存状态、零磁盘 IO。
/// `activate()` **不**自动开服务（关闭态零开销 + 默认关闭的安全前提）。
@MainActor
final class LanDropTool: ToolModule {
    let id = "landrop"
    let name = L("landrop.name")
    let symbolName = "square.and.arrow.down"

    private var server: LanDropServer { LanDropServer.shared }

    // MARK: - 生命周期

    func activate() {
        // 无需后台服务：接收服务只在用户显式开启时启动。
    }

    func willTerminate() {
        // 退出必停：绝不把一个还在监听的端口留在后台。
        server.stop()
    }

    // MARK: - 菜单

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // ① 开关行
        items.append(hostingRow(LanDropToggleRow()))

        if case .failed(let message) = server.state {
            items.append(disabled(L("landrop.menu.failed \(message)")))
            return items
        }

        if server.isRunning {
            // ② 地址（点击复制含访问码的完整链接）
            if let address = server.displayAddress {
                items.append(ClosureMenuItem(title: L("landrop.menu.address \(address)")) { [weak self] in
                    guard let link = self?.server.shareURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                })
            }

            // ③ 内嵌二维码（带一次性配对码）+ 扫码提示
            if server.shareURL != nil {
                items.append(disabled(L("landrop.menu.scanHint")))
                items.append(hostingRow(LanDropMenuQR(), height: 152))
            } else {
                // 配对码已过期：不显示一个扫了也没用的码。
                items.append(disabled(L("landrop.menu.pairExpired")))
            }
            items.append(ClosureMenuItem(title: L("landrop.menu.rotatePair")) {
                LanDropServer.shared.rotatePairCode()
            })

            // 已配对设备
            let devices = LanDropAccess.shared.devices
            if !devices.isEmpty {
                items.append(disabled(L("landrop.menu.devices \(devices.count)")))
                items.append(ClosureMenuItem(title: L("landrop.menu.disconnectAll")) {
                    LanDropServer.shared.disconnectAllDevices()
                })
            }

            // ④ 自动关闭剩余时间
            if let deadline = server.autoStopAt {
                let minutes = max(0, Int(deadline.timeIntervalSinceNow / 60) + 1)
                items.append(disabled(L("landrop.menu.autoStop \(minutes)")))
            }

            items.append(.separator())
        }

        // ⑤ 发送到手机（拖文件进面板才会被分享）
        items.append(ClosureMenuItem(title: L("landrop.menu.send"), hotkeyID: "landrop.send") {
            LanDropSendPanel.show()
        })
        let shared = LanDropShare.shared.items
        if !shared.isEmpty {
            items.append(disabled(L("landrop.menu.sharing \(shared.count)")))
            for item in shared.prefix(5) {
                let row = NSMenuItem(title: "\(item.name) · \(LanDropEnv.formatBytes(item.size))",
                                     action: nil, keyEquivalent: "")
                let actions = NSMenu()
                actions.autoenablesItems = true
                actions.addItem(ClosureMenuItem(title: L("landrop.menu.stopSharing")) {
                    LanDropShare.shared.remove(id: item.id)
                })
                actions.addItem(ClosureMenuItem(title: L("claudecode.audit.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                })
                row.submenu = actions
                items.append(row)
            }
        }
        items.append(.separator())

        // ⑥ 进行中的传输
        let transfers = LanDropTransfers.shared
        if transfers.hasActive {
            items.append(hostingRow(LanDropProgressRow(), height: 38))
            items.append(.separator())
        }

        // ⑦ 最近接收（最多 5 条，点击在访达中显示）
        let recent = transfers.items.filter { $0.status == .done }.prefix(5)
        if !recent.isEmpty {
            items.append(disabled(L("landrop.menu.recent")))
            for item in recent {
                guard let path = item.path else { continue }
                let title = "\(item.name) · \(LanDropEnv.formatBytes(item.received))"
                items.append(ClosureMenuItem(title: title) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
            items.append(ClosureMenuItem(title: L("landrop.menu.clearRecent")) {
                LanDropTransfers.shared.clear()
            })
            items.append(.separator())
        }

        // ⑧ 打开保存目录
        items.append(ClosureMenuItem(title: L("landrop.menu.openFolder")) {
            let dir = LanDropEnv.ensureSaveDirectory() ?? LanDropEnv.saveDirectoryURL
            NSWorkspace.shared.open(dir)
        })

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "landrop.toggle",
                title: L("landrop.hotkey.toggle"),
                subtitle: L("landrop.hotkey.toggle.subtitle"),
                defaultCombo: nil // 出厂不绑定
            ) {
                LanDropServer.shared.toggle()
            },
            HotkeyDefinition(
                id: "landrop.send",
                title: L("landrop.hotkey.send"),
                subtitle: L("landrop.hotkey.send.subtitle"),
                defaultCombo: nil // 出厂不绑定
            ) {
                LanDropSendPanel.show()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(LanDropSettingsView())
    }

    // MARK: - 工具

    /// 把一个 SwiftUI 视图包成菜单项（自定义 view 行）。
    private func hostingRow<V: View>(_ view: V, height: CGFloat = 30) -> NSMenuItem {
        let item = NSMenuItem()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        hosting.autoresizingMask = [.width]
        item.view = hosting
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}

// MARK: - 开关行

/// 「接收文件」菜单行：左标题右 switch，绑 `LanDropServer` 启停。
struct LanDropToggleRow: View {
    @ObservedObject private var server = LanDropServer.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("landrop.menu.toggle")
                if server.isRunning {
                    Text("landrop.menu.sameWiFi")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { server.isRunning },
                set: { _ in server.toggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            // 菜单里的 NSHostingView 不继承 App 强调色，需显式指定。
            .tint(Color(nsColor: .controlAccentColor))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        .environment(\.controlActiveState, .key)
    }
}

// MARK: - 传输进度行

/// 进行中传输的汇总进度条。菜单打开期间由 `@ObservedObject` 驱动刷新。
struct LanDropProgressRow: View {
    @ObservedObject private var transfers = LanDropTransfers.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("landrop.menu.receiving \(transfers.activeCount)")
                .font(.caption)
            ProgressView(value: transfers.activeFraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Color(nsColor: .controlAccentColor))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 38)
        .environment(\.controlActiveState, .key)
    }
}

// MARK: - 菜单内嵌二维码

/// 手机扫这个码即可配对并打开页面。内容是**一次性配对码**，扫过一次即换新，
/// 故每次构建按当前 URL 现生成（QR 生成是纯 CPU，开销很小）。
struct LanDropMenuQR: View {
    @ObservedObject private var server = LanDropServer.shared
    /// 配对码被消费 / 换新时要重画（内容变了）。
    @ObservedObject private var access = LanDropAccess.shared

    var body: some View {
        VStack(spacing: 0) {
            if let link = server.shareURL,
               let cg = QRCodeGenerator.image(for: link, minPixels: 160) {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 132, height: 132)))
                    .interpolation(.none)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 152)
    }
}
