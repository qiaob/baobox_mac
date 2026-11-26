import AppKit
import SwiftUI

/// 本机端口占用页：查看监听中的 TCP/UDP 端口、绑定范围、进程名/PID 与完整命令行，支持搜索和一键停止/强制结束。
struct NetCheckPortView: View {
    @ObservedObject private var session = NetPortSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar

            if let error = session.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        session.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            let items = session.filteredEntries
            if session.loading && session.entries.isEmpty {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("netcheck.ports.scanning")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if items.isEmpty {
                Spacer()
                Text(session.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "netcheck.ports.empty" : "netcheck.ports.noMatch")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { entry in
                            portRow(entry)
                            Divider()
                        }
                    }
                }
            }

            footer
        }
        .onAppear {
            if session.entries.isEmpty && !session.loading {
                session.refresh()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("netcheck.ports.search", text: $session.searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("netcheck.ports.includeUDP", isOn: $session.includeUDP)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: session.includeUDP) { _, _ in session.refresh() }
            Button("netcheck.ports.refresh") { session.refresh() }
                .disabled(session.loading)
        }
    }

    private func portRow(_ entry: NetPortEntry) -> some View {
        let isSelf = entry.pid == ProcessInfo.processInfo.processIdentifier
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: ":\(entry.port)")
                        .font(.callout.weight(.semibold).monospaced())
                    Text(verbatim: entry.proto.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                Text(verbatim: entry.isLocalOnly ? L("netcheck.ports.localOnly") : entry.address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(entry.isLocalOnly ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.processName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: "PID \(entry.pid)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !entry.user.isEmpty {
                        Text(verbatim: entry.user)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.commandLine.isEmpty {
                    Text(verbatim: entry.commandLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button("netcheck.ports.stop") {
                    session.terminate(entry, force: false)
                }
                .controlSize(.small)
                .disabled(isSelf)

                Menu {
                    Button("netcheck.ports.copyAddress") {
                        copy(entry.bindLabel)
                    }
                    if !entry.commandLine.isEmpty {
                        Button("netcheck.ports.copyCommand") {
                            copy(entry.commandLine)
                        }
                    }
                    Divider()
                    Button("netcheck.ports.forceKill", role: .destructive) {
                        session.terminate(entry, force: true)
                    }
                    .disabled(isSelf)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack {
            Text(L("netcheck.ports.count \(session.filteredEntries.count)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let updated = session.lastUpdated {
                Text(L("netcheck.window.checkedAt \(updated.formatted(date: .omitted, time: .standard))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
