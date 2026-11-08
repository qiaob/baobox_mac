import AppKit
import SwiftUI

/// 手机互传设置：接收文件夹、收到文字自动复制、公网模式的手机页面地址。
struct PhoneTransferSettingsView: View {
    @AppStorage(PhoneTransferSettings.receiveDirKey) private var receiveDir = ""
    @AppStorage(PhoneTransferSettings.autoCopyTextKey) private var autoCopyText = false
    @AppStorage(PhoneTransferSettings.pageURLKey) private var pageURL = ""

    var body: some View {
        Form {
            Section {
                Text("phonetransfer.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("phonetransfer.menu.open") {
                    PhoneTransferWindowController.shared.show()
                }
            }

            Section("phonetransfer.settings.receiveSection") {
                HStack {
                    Text(receiveDir.isEmpty ? PhoneTransferSettings.defaultReceiveDir.path : receiveDir)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("phonetransfer.settings.choose") { chooseFolder() }
                    if !receiveDir.isEmpty {
                        Button("phonetransfer.settings.reset") { receiveDir = "" }
                    }
                }
                Toggle("phonetransfer.settings.autoCopy", isOn: $autoCopyText)
            }

            Section("phonetransfer.settings.internetSection") {
                TextField("phonetransfer.settings.pageURL", text: $pageURL,
                          prompt: Text(verbatim: PhoneTransferSettings.defaultPageURL))
                Text("phonetransfer.settings.pageURLHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            receiveDir = url.path
        }
    }
}
