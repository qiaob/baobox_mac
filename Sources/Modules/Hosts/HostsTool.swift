import AppKit
import SwiftUI

/// hosts 管理模块壳。纯菜单操作 + 设置页编辑，无全局快捷键。
@MainActor
final class HostsTool: ToolModule {
    let id = "hosts"
    let name = L("hosts.name")
    let symbolName = "globe"

    private var store: HostsStore { HostsStore.shared }

    func activate() {
        // 无常驻后台服务。只在启动时同步一次「系统 hosts 是否已被接管」，
        // 之后菜单只读这份内存缓存（约定 2：菜单构建零磁盘 IO）。
        store.refreshManagedState()
    }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // 状态行（action 为 nil 即自动置灰）。全部读内存缓存，不碰磁盘。
        items.append(NSMenuItem(title: statusText(), action: nil, keyEquivalent: ""))
        items.append(.separator())

        if store.schemes.isEmpty {
            // 一条置灰引导，不报错（约定 7：没内容就降级提示）。
            items.append(NSMenuItem(title: L("hosts.menu.empty"), action: nil, keyEquivalent: ""))
            return items
        }

        for scheme in store.schemes {
            let title = scheme.name.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("hosts.untitled") : scheme.name
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.toggle(scheme)
            }
            item.state = scheme.isEnabled ? .on : .off
            items.append(item)
        }

        if !store.enabledSchemes.isEmpty {
            items.append(.separator())
            items.append(ClosureMenuItem(title: L("hosts.menu.disableAll")) { [weak self] in
                self?.disableAll()
            })
        }
        return items
    }

    func hotkeys() -> [HotkeyDefinition] { [] }

    func settingsTab() -> AnyView {
        AnyView(HostsSettingsView())
    }

    // MARK: - 动作

    private func statusText() -> String {
        if store.isApplying { return L("hosts.menu.status.applying") }
        let count = store.enabledSchemes.count
        return count > 0 ? L("hosts.menu.status.enabled \(count)") : L("hosts.menu.status.off")
    }

    /// 勾选即写系统。写失败/用户取消都要**回滚勾选状态**，否则菜单显示与 /etc/hosts 实际内容不符。
    private func toggle(_ scheme: HostsScheme) {
        guard !store.isApplying else { return }
        let previous = scheme.isEnabled
        store.setEnabled(scheme.id, !previous)
        store.apply { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ok:
                break
            case .cancelled:
                self.store.setEnabled(scheme.id, previous) // 用户取消授权：安静回滚
            case .failed(let message):
                self.store.setEnabled(scheme.id, previous)
                Self.reportFailure(message)
            }
        }
    }

    private func disableAll() {
        guard !store.isApplying else { return }
        store.disableAllAndApply { outcome in
            if case .failed(let message) = outcome {
                Self.reportFailure(message)
            }
        }
    }

    static func reportFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("hosts.error.applyFailed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
