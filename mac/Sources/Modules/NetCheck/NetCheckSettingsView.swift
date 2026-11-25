import SwiftUI

/// 网络泄露检测的设置：真实网络、ipapi.is 的 key（钥匙串）、DNS 探测个数、STUN 服务器。
struct NetCheckSettingsView: View {
    @AppStorage(NetCheckSettings.realNetworksKey) private var realNetworks = ""
    @AppStorage(NetCheckSettings.dnsProbesKey) private var dnsProbes = NetCheckSettings.defaultDNSProbes
    @AppStorage(NetCheckSettings.stunServerKey) private var stunServer = ""
    @State private var apiKey = NetCheckKeychain.load() ?? ""
    @State private var keySaveFailed = false

    var body: some View {
        Form {
            Section {
                Text("netcheck.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("netcheck.settings.open") { NetCheckWindowController.shared.show() }
            }

            Section("netcheck.settings.realSection") {
                TextField("netcheck.settings.real", text: $realNetworks,
                          prompt: Text(verbatim: "AS4657, AS9506"))
                Text("netcheck.settings.realHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("netcheck.settings.serviceSection") {
                SecureField("netcheck.settings.apiKey", text: $apiKey)
                    .onSubmit { saveKey() }
                if keySaveFailed {
                    Text("netcheck.settings.apiKeyFailed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("netcheck.settings.apiKeyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper(value: $dnsProbes, in: NetCheckSettings.dnsProbesRange) {
                    Text(verbatim: L("netcheck.settings.dnsProbes \(dnsProbes)"))
                }
                TextField("netcheck.settings.stun", text: $stunServer,
                          prompt: Text(verbatim: NetCheckSettings.defaultSTUNServer))
                Text("netcheck.settings.stunHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("netcheck.settings.privacy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // 回车或离开设置页时才写钥匙串，不是每敲一个字写一次
        .onDisappear { saveKey() }
    }

    private func saveKey() {
        guard apiKey != (NetCheckKeychain.load() ?? "") else { return }
        keySaveFailed = !NetCheckKeychain.save(apiKey)
    }
}
