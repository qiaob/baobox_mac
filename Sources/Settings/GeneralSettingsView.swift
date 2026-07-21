import SwiftUI
import ServiceManagement
import AppKit

/// 通用设置：开机自启 + 语言 + 权限状态。
struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// 辅助功能状态是实时的；屏幕录制用三态（启动缓存 + TCC 实时探测），见 `Permissions.screenRecordingState`。
    @State private var hasAccess = Permissions.hasAccessibility
    @State private var screenState = Permissions.screenRecordingState
    @State private var language = L10n.current
    @State private var showRestartForLanguage = false
    @State private var errorMessage: String?

    private var alertPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }

    var body: some View {
        Form {
            Section("settings.general.launchSection") {
                Toggle("settings.general.launchAtLogin", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("settings.general.language.section") {
                Picker("settings.general.language.picker", selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(verbatim: lang.displayName).tag(lang)
                    }
                }
                .onChange(of: language) { _, newValue in
                    guard newValue != L10n.current else { return }
                    L10n.apply(newValue)
                    showRestartForLanguage = true
                }
                Text("settings.general.language.restartNotice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.general.permissionSection") {
                screenRecordingRow
                accessibilityRow
            }
        }
        .formStyle(.grouped)
        // 从系统设置切回来时刷新。这里刻意不用定时器轮询：设置窗口是复用的
        // （关闭只 orderOut 不销毁），视图不会 disappear，定时器会一直跑到 App 退出。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccess = Permissions.hasAccessibility
            screenState = Permissions.screenRecordingState
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert("settings.general.operationFailed", isPresented: alertPresented) {
            Button("common.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("settings.general.language.restartTitle", isPresented: $showRestartForLanguage) {
            Button("settings.general.language.restartNow") { Permissions.restartApp() }
            Button("settings.general.language.restartLater", role: .cancel) {}
        } message: {
            Text("settings.general.language.restartNotice")
        }
    }

    @ViewBuilder
    private var screenRecordingRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("permission.screenRecording")
                Text("settings.general.screenRecording.desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch screenState {
                case .effective:
                    EmptyView()
                case .grantedNeedsRestart:
                    Text("settings.general.screenRecording.grantedNeedsRestart")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .notGranted:
                    Text("settings.general.screenRecording.notGranted")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            switch screenState {
            case .effective:
                Label("common.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .grantedNeedsRestart:
                Button("settings.general.screenRecording.restartNow") { Permissions.restartApp() }
                    .buttonStyle(.borderedProminent)
            case .notGranted:
                VStack(alignment: .trailing, spacing: 6) {
                    Button("common.goEnable") {
                        Permissions.requestScreenRecording()
                        Permissions.openSystemSettings(pane: .screenRecording)
                    }
                    // TCC 探测有小概率漏报，保留手动重启入口；措辞用疑问句避免读成状态陈述。
                    Button("settings.general.screenRecording.maybeEnabled") { Permissions.restartApp() }
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("permission.accessibility")
                Text("permission.accessibility.desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasAccess {
                Label("common.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                // 该弹窗自带「打开系统设置」按钮，不再额外拉起系统设置（两个窗口会抢焦点）。
                Button("common.goEnable") { Permissions.promptAccessibility() }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 原先这里静默吞掉错误，用户只看到开关自己弹回去、没有任何原因说明。
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
            return
        }

        // 用户曾在「登录项」里手动关掉过时，register() 不报错但也不生效，
        // 开关会永远打不开 —— 必须引导去系统设置批准。
        if on, SMAppService.mainApp.status == .requiresApproval {
            errorMessage = L("settings.general.loginItem.requiresApproval")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
