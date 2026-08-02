import AppKit
import SwiftUI

/// 局域网传输设置：保存目录、端口、自动关闭、大小上限、通知。
struct LanDropSettingsView: View {
    @AppStorage(LanDropEnv.Keys.saveDirectory) private var saveDirectory = LanDropEnv.defaultDirectory
    @AppStorage(LanDropEnv.Keys.port) private var port = Int(LanDropEnv.defaultPort)
    @AppStorage(LanDropEnv.Keys.idleTimeout) private var idleTimeout = LanDropEnv.defaultIdleTimeout
    @AppStorage(LanDropEnv.Keys.stopWhenDone) private var stopWhenDone = false
    @AppStorage(LanDropEnv.Keys.maxFileSize) private var maxFileSize = LanDropEnv.defaultMaxFileSize
    @AppStorage(LanDropEnv.Keys.notifyStart) private var notifyStart = true
    @AppStorage(LanDropEnv.Keys.notifyDone) private var notifyDone = true
    @AppStorage(LanDropEnv.Keys.notifySound) private var notifySound = true

    @ObservedObject private var server = LanDropServer.shared

    /// 1 GB，用作大小上限选项的基数。
    private static let gb = 1024 * 1024 * 1024

    var body: some View {
        Form {
            Section {
                Text("landrop.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if server.isRunning, let address = server.displayAddress {
                    HStack {
                        Text("landrop.settings.status")
                        Spacer()
                        Text(verbatim: address)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("landrop.settings.saveSection") {
                HStack {
                    Text("landrop.settings.saveDir")
                    Spacer()
                    Text(verbatim: saveDirectory)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("landrop.settings.choose") { chooseDirectory() }
                }
                Text("landrop.settings.saveDirHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("landrop.settings.safetySection") {
                Picker("landrop.settings.idleTimeout", selection: $idleTimeout) {
                    Text("landrop.settings.idle.5m").tag(Double(5 * 60))
                    Text("landrop.settings.idle.10m").tag(Double(10 * 60))
                    Text("landrop.settings.idle.30m").tag(Double(30 * 60))
                    Text("landrop.settings.idle.never").tag(Double(0))
                }
                Text("landrop.settings.idleHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("landrop.settings.stopWhenDone", isOn: $stopWhenDone)

                Picker("landrop.settings.maxSize", selection: $maxFileSize) {
                    Text("landrop.settings.size.1g").tag(Self.gb)
                    Text("landrop.settings.size.4g").tag(4 * Self.gb)
                    Text("landrop.settings.size.16g").tag(16 * Self.gb)
                    Text("landrop.settings.size.unlimited").tag(0)
                }

                Text("landrop.settings.tokenHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("landrop.settings.networkSection") {
                HStack {
                    Text("landrop.settings.port")
                    Spacer()
                    TextField("", value: $port, format: .number.grouping(.never))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .disabled(server.isRunning)
                }
                Text("landrop.settings.portHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("landrop.settings.notifySection") {
                Toggle("landrop.settings.notifyStart", isOn: $notifyStart)
                Toggle("landrop.settings.notifyDone", isOn: $notifyDone)
                Toggle("landrop.settings.notifySound", isOn: $notifySound)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("landrop.settings.choosePrompt")
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}
