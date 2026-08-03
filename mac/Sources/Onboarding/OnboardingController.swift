import AppKit
import SwiftUI

/// 首次启动权限引导。任一权限缺失时弹出（每次启动最多一次）。
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private var window: NSWindow?
    private var shownThisLaunch = false

    private init() {}

    /// 启动时调用：两项权限都有则不弹。
    func showIfNeeded() {
        guard !shownThisLaunch else { return }
        if Permissions.hasScreenRecording && Permissions.hasAccessibility { return }
        shownThisLaunch = true
        present()
    }

    /// 主动弹出（也用于截图工具在无权限时的就地引导）。
    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView { [weak self] in
            self?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = L("onboarding.windowTitle")
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

// MARK: - 引导视图

struct OnboardingView: View {
    var onClose: () -> Void

    /// 三态：已生效 / 系统已勾选待重启 / 未开启。从系统设置切回来时刷新（见 onReceive）。
    @State private var screenState = Permissions.screenRecordingState
    @State private var hasAccess = Permissions.hasAccessibility

    var body: some View {
        VStack(spacing: 0) {
            // 头部（真实应用图标，与 Finder / 启动台一致）
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("onboarding.title")
                    .font(.headline)
                Text("onboarding.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 26)
            .padding(.horizontal, 28)

            // 权限列表
            VStack(spacing: 10) {
                permissionRow(
                    icon: "display",
                    title: L("permission.screenRecording"),
                    detail: L("onboarding.screen.desc")
                ) {
                    switch screenState {
                    case .effective:
                        grantedBadge
                    case .grantedNeedsRestart:
                        Button("onboarding.enabledRestart") { Permissions.restartApp() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    case .notGranted:
                        Button("common.goEnable") {
                            // 先登记进系统列表（未询问过时会弹系统授权窗），再打开对应面板；
                            // 系统弹窗只在首次询问出现，之后全靠面板里的开关，两者不冲突。
                            Permissions.requestScreenRecording()
                            Permissions.openSystemSettings(pane: .screenRecording)
                        }
                        .controlSize(.small)
                    }
                }
                permissionRow(
                    icon: "keyboard",
                    title: L("permission.accessibility"),
                    detail: L("permission.accessibility.desc")
                ) {
                    if hasAccess {
                        grantedBadge
                    } else {
                        // 该弹窗自带「打开系统设置」按钮，不再额外拉起系统设置（两窗口会抢焦点）。
                        Button("common.goEnable") { Permissions.promptAccessibility() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(18)

            // 底部
            VStack(spacing: 10) {
                Button("onboarding.openSettings") {
                    Permissions.openSystemSettings(
                        pane: screenState == .effective ? .accessibility : .screenRecording)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // 实时探测有小概率漏报（屏幕上恰好没有带标题的他人窗口），
                // 因此"未开启"分支保留手动重启入口；措辞用疑问句，避免被读成状态陈述。
                if screenState == .notGranted {
                    Button("onboarding.maybeEnabledRestart") { Permissions.restartApp() }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                Button("onboarding.later") {
                    onClose()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)
        }
        .frame(width: 470)
        // 从系统设置切回来时刷新：辅助功能实时可读；屏幕录制走 TCC 探测识别"已勾选待重启"。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccess = Permissions.hasAccessibility
            screenState = Permissions.screenRecordingState
        }
    }

    private var grantedBadge: some View {
        Text("common.granted")
            .font(.caption.bold())
            .foregroundStyle(.green)
            .padding(.horizontal, 11).padding(.vertical, 3)
            .background(Color.green.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func permissionRow<Trailing: View>(icon: String, title: String, detail: String,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()

            trailing()
        }
        .padding(13)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }
}
