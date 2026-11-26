import AppKit
import SwiftUI

/// 诊断页：上半部分为单目标全链路拆解（DNS → TCP → TLS → HTTP），下半部分为常用服务一键连通性（只读探测）。
struct NetCheckDiagView: View {
    @ObservedObject private var session = NetDiagSession.shared
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                targetSection
                Divider()
                servicesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 单目标全链路诊断

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("netcheck.diag.singleTitle")
                    .font(.headline)
                Spacer()
                if let report = session.report {
                    Button(copied ? "netcheck.window.copied" : "netcheck.window.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(NetCheckText.diagReport(report), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            MainActor.assumeIsolated { copied = false }
                        }
                    }
                    .controlSize(.small)
                    .disabled(session.diagnosing)
                }
            }

            HStack(spacing: 8) {
                TextField("netcheck.diag.placeholder", text: $session.targetInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { session.runDiagnostic() }
                Button("netcheck.diag.run") { session.runDiagnostic() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.diagnosing || session.targetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = session.inputError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if session.diagnosing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("netcheck.diag.running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let report = session.report {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: report.target.urlString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    stepRow(name: "DNS", state: report.dns.state, duration: report.dns.duration,
                            detail: NetCheckText.diagDNSSummary(report.dns))
                    stepRow(name: "TCP", state: report.tcp.state, duration: report.tcp.duration,
                            detail: NetCheckText.diagTCPSummary(report.tcp, target: report.target))
                    stepRow(name: "TLS", state: report.tls.state, duration: report.tls.duration,
                            detail: NetCheckText.diagTLSSummary(report.tls, at: report.at))
                    stepRow(name: "HTTP", state: report.http.state, duration: report.http.ttfb,
                            detail: NetCheckText.diagHTTPSummary(report.http))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            } else {
                Text("netcheck.diag.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stepRow(name: String, state: NetDiagStepState, duration: TimeInterval?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(stepColor(state))
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(verbatim: name)
                .font(.callout.weight(.medium).monospaced())
                .frame(width: 44, alignment: .leading)
            Text(verbatim: duration.map { NetCheckText.milliseconds($0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(state == .failed ? Color.red : (state == .skipped ? Color.secondary : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepColor(_ state: NetDiagStepState) -> Color {
        switch state {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        case .skipped: return .secondary.opacity(0.45)
        }
    }

    // MARK: - 常用服务一键连通性

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("netcheck.diag.servicesTitle")
                        .font(.headline)
                    if let at = session.servicesCheckedAt, !session.probingServices {
                        Text(L("netcheck.window.checkedAt \(at.formatted(date: .omitted, time: .standard))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.probingServices {
                    ProgressView().controlSize(.small)
                }
                Button("netcheck.diag.checkServices") { session.runServiceChecks() }
                    .disabled(session.probingServices)
            }

            ForEach(NetServiceGroup.allCases, id: \.self) { group in
                let items = NetDiagLogic.builtInServices.filter { $0.group == group }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: NetCheckText.serviceGroupTitle(group))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(items) { service in
                        serviceRow(service)
                    }
                }
            }
        }
    }

    private func serviceRow(_ service: NetServiceTarget) -> some View {
        let result = session.serviceResults[service.id]
        return HStack(spacing: 8) {
            Circle()
                .fill(serviceDotColor(result?.outcome))
                .frame(width: 7, height: 7)
            Text(verbatim: service.name)
                .font(.callout)
                .frame(width: 120, alignment: .leading)
            if let result {
                if let tag = NetCheckText.pathTag(result.viaProxy) {
                    Text(verbatim: tag)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                Text(verbatim: NetCheckText.serviceOutcomeText(result.outcome))
                    .font(.caption)
                    .foregroundStyle(serviceTextColor(result.outcome))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let duration = result.duration {
                    Text(verbatim: NetCheckText.milliseconds(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if session.probingServices {
                Text("netcheck.window.running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(verbatim: service.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            Button("netcheck.diag.inspect") {
                session.runDiagnostic(raw: service.url)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(session.diagnosing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    private func serviceDotColor(_ outcome: NetServiceOutcome?) -> Color {
        guard let outcome else { return .secondary.opacity(0.35) }
        switch outcome {
        case .reachable: return .green
        case .restricted: return .orange
        case .unreachable: return .red
        }
    }

    private func serviceTextColor(_ outcome: NetServiceOutcome) -> Color {
        switch outcome {
        case .reachable: return .primary
        case .restricted: return .orange
        case .unreachable: return .red
        }
    }
}
