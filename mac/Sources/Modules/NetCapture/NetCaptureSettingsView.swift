import SwiftUI

/// 设置窗口里「网络抓包」那一页：只有一句话和一个按钮（docs/packet-capture/CONFIG-LAYOUT.md §1、§3 图 6）。
/// 抓包的设置都在抓包窗口的「配置」页（证书、解密范围、设备接入、本地 MCP、端口与上限）—— 一个设置只放一个地方。
struct NetCaptureSettingsView: View {
    var body: some View {
        Form {
            SwiftUI.Section {
                if let reason = NetCaptureEnv.engineUnavailable {
                    Text(reason == .needsAppleSilicon ? "netcapture.unavailable.intel" : "netcapture.unavailable.notBundled")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("netcapture.name").font(.title3.weight(.semibold))
                        Text("netcapture.settings.moved")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("netcapture.settings.openConfig") { NetCaptureWindowController.shared.showConfig() }
                            .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}
