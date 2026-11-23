import AppKit
import SwiftUI

// 抓包窗口的右栏：一条请求的详情（概览 / 请求 / 响应 / 消息 / 原始）。
// 请求页按 Query 参数 / 请求头 / Cookie / 正文分节，响应页按响应头 / Set-Cookie / 正文分节
// （docs/packet-capture/TOOLS.md §2）；正文怎么显示在 NetCaptureBodyViews.swift。

// MARK: - 共用的小东西

@MainActor
enum FlowActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 「没解密 · 握手失败」那种行能「重新尝试解密」：引擎在跑才有失败表可清。
    @MainActor
    static func canRetryDecrypt(_ flow: Flow) -> Bool {
        !flow.decrypted && flow.undecryptedReason == .handshakeFailed && NetCaptureEngine.shared.isRunning
    }

    /// 忘掉这台设备上这个域名的握手失败，下一条连接重新接管（docs/packet-capture/TLS-FINGERPRINT.md §7.2）。
    @MainActor
    static func retryDecrypt(_ flow: Flow) {
        NetCaptureEngine.shared.send(.retryDecrypt(device: flow.deviceKey, host: flow.host))
    }
}

/// 详情区和列表右键里对一条请求能做的事。动作要弹的面板在窗口根视图上，所以由它传进来。
struct FlowCommands {
    /// 原样再发一次。
    var replay: (Flow) -> Void
    /// 弹「编辑后重发」面板。
    var editAndReplay: (Flow) -> Void
    /// 弹 Mock 面板，用这条请求预填。
    var mock: (Flow) -> Void
}

/// 「重新尝试解密」：点了之后这一行下面写一句「下一条连接会重新解密」，让人知道做了什么、要等什么。
struct RetryDecryptButton: View {
    let flow: Flow
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                FlowActions.retryDecrypt(flow)
                done = true
            } label: {
                Label("netcapture.flow.retryDecrypt", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            if done {
                Text("netcapture.flow.retryDecryptDone").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(flow.id)
    }
}

/// 复制按钮：复制图标 + 文字，点了之后短暂变成「已复制」，让人知道确实复制上了。
struct CopyButton: View {
    let title: LocalizedStringKey
    /// 点的时候才取内容（cURL 要现拼，不在每次重绘时算）。
    let content: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            FlowActions.copy(content())
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "netcapture.common.copied" : title,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

enum FlowFormat {
    static func bytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
        return "\(bytes)B"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }
}

/// 详情里的一节：标题（左）+ 附加控件 + 小的「复制」（右），下面是内容。
struct DetailSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    /// 点「复制」时取的文本；nil = 不放复制按钮。
    let copy: (() -> String)?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                accessory()
                if let copy {
                    CopyButton(title: "netcapture.common.copy", content: copy)
                        .controlSize(.small)
                }
            }
            content()
        }
    }
}

extension DetailSection where Accessory == EmptyView {
    init(title: LocalizedStringKey, copy: (() -> String)?, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, copy: copy, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - 详情视图

struct FlowDetailView: View {
    let flow: Flow
    let commands: FlowCommands
    @State private var tab = DetailTab.overview

    enum DetailTab: String, Identifiable {
        case overview, request, response, messages, raw
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .overview: return "netcapture.detail.overview"
            case .request: return "netcapture.detail.request"
            case .response: return "netcapture.detail.response"
            case .messages: return "netcapture.detail.messages"
            case .raw: return "netcapture.detail.raw"
            }
        }
    }

    private var tabs: [DetailTab] {
        guard flow.decrypted else { return [.overview] }
        return flow.isWebSocket ? [.overview, .request, .response, .messages, .raw]
                                : [.overview, .request, .response, .raw]
    }

    /// 换了一条请求后，上一条选的页签这条可能没有。
    private var currentTab: DetailTab { tabs.contains(tab) ? tab : .overview }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(8)
            Divider()
            ScrollView {
                Group {
                    switch currentTab {
                    case .overview: overview
                    case .request: requestPage
                    case .response: responsePage
                    case .messages: messages
                    case .raw: rawView
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 顶部：页签 + 按钮

    /// 页签和按钮放一行；详情区太窄放不下时按钮挪到第二行（不换行、不截断按钮文字）。
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tabPicker
                Spacer(minLength: 8)
                actionButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                tabPicker
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actionButtons
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: Binding(get: { currentTab }, set: { tab = $0 })) {
            ForEach(tabs) { t in Text(t.label).tag(t) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// 「复制 cURL」「重发」直接放；「编辑后重发…」「Mock…」收进「⋯」菜单。只对解密了的请求有。
    @ViewBuilder
    private var actionButtons: some View {
        if flow.decrypted {
            HStack(spacing: 6) {
                // 带文字的复制按钮：只放一个图标时看不出是「复制」（用户 2026-11-21）。
                CopyButton(title: "netcapture.flow.copyCurl") { FlowStore.shared.curl(for: flow) }
                Button { commands.replay(flow) } label: {
                    Label("netcapture.replay.action", systemImage: "arrow.clockwise")
                }
                Menu {
                    Button("netcapture.replay.editAction") { commands.editAndReplay(flow) }
                    Button("netcapture.mock.action") { commands.mock(flow) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("netcapture.detail.more"))
            }
            .fixedSize()
        }
    }

    // MARK: 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if flow.decrypted {
                field("netcapture.detail.method", flow.method)
                field("netcapture.detail.url", flow.url)
                field("netcapture.detail.status", flow.statusCode.map(String.init) ?? "—")
                if flow.mockRuleID != nil {
                    field("netcapture.detail.mock", L("netcapture.detail.mockAnswered"))
                }
                field("netcapture.detail.protocol", flow.isWebSocket ? "WebSocket (\(flow.httpVersion))" : flow.httpVersion)
                field("netcapture.detail.remoteIP", flow.remoteIP ?? "—")
                field("netcapture.detail.started", FlowFormat.time(flow.startedAt))
                field("netcapture.detail.duration", flow.durationMs.map { "\($0)ms" } ?? "—")
                field("netcapture.detail.reqSize", FlowFormat.bytes(flow.requestBytes))
                field("netcapture.detail.respSize", FlowFormat.bytes(flow.responseBytes))
                field("netcapture.detail.contentType", flow.responseContentType ?? "—")
                if let encoding = flow.responseEncoding, !encoding.isEmpty {
                    field("netcapture.detail.encoding", encoding)
                }
                if let note = flow.note {
                    field("netcapture.detail.error", note)
                }
            } else {
                field("netcapture.detail.host", flow.host)
                field("netcapture.detail.started", FlowFormat.time(flow.startedAt))
                Text(Self.reasonText(flow.undecryptedReason))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if FlowActions.canRetryDecrypt(flow) {
                    RetryDecryptButton(flow: flow)
                }
            }
        }
    }

    /// 没解密的原因：握手失败、不在解密范围、关了解密，三种说法分开。
    private static func reasonText(_ reason: CaptureEvent.UndecryptedReason?) -> LocalizedStringKey {
        switch reason {
        case .outOfScope: return "netcapture.flow.reason.outOfScope"
        case .decryptOff: return "netcapture.flow.reason.decryptOff"
        case .handshakeFailed, nil: return "netcapture.flow.reason.handshake"
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value).font(.callout).textSelection(.enabled)
        }
    }

    // MARK: 请求 / 响应

    /// Query 参数、请求头、Cookie、正文；没有内容的节整节不显示。
    private var requestPage: some View {
        let query = RequestParams.queryItems(path: flow.path)
        let headers = flow.requestHeaders.map { NameValue(name: $0.name, value: $0.value) }
        let cookies = RequestParams.cookies(headers: flow.requestHeaders)
        return VStack(alignment: .leading, spacing: 16) {
            if !query.isEmpty {
                DetailSection(title: "netcapture.detail.query", copy: { RequestParams.copyText(query) }) {
                    KeyValueTable(rows: query)
                }
            }
            if !headers.isEmpty {
                DetailSection(title: "netcapture.detail.requestHeaders", copy: { RequestParams.copyText(headers) }) {
                    KeyValueTable(rows: headers)
                }
            }
            if !cookies.isEmpty {
                DetailSection(title: "netcapture.detail.cookies", copy: { RequestParams.copyText(cookies) }) {
                    KeyValueTable(rows: cookies)
                }
            }
            BodySection(flowID: flow.id, side: .request, body: flow.requestBody, headers: flow.requestHeaders,
                        truncated: flow.requestTruncated, sniffed: flow.requestSniffed, decoded: flow.requestDecoded)
        }
    }

    /// 响应头、Set-Cookie、正文。
    private var responsePage: some View {
        let headers = flow.responseHeaders.map { NameValue(name: $0.name, value: $0.value) }
        let setCookies = RequestParams.setCookies(headers: flow.responseHeaders)
        return VStack(alignment: .leading, spacing: 16) {
            if !headers.isEmpty {
                DetailSection(title: "netcapture.detail.responseHeaders", copy: { RequestParams.copyText(headers) }) {
                    KeyValueTable(rows: headers)
                }
            }
            if !setCookies.isEmpty {
                DetailSection(title: "netcapture.detail.setCookies", copy: { RequestParams.copyText(setCookies) }) {
                    SetCookieList(cookies: setCookies)
                }
            }
            BodySection(flowID: flow.id, side: .response, body: flow.responseBody, headers: flow.responseHeaders,
                        truncated: flow.responseTruncated, sniffed: flow.responseSniffed, decoded: flow.responseDecoded)
        }
    }

    // MARK: 消息 / 原始

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if flow.messages.isEmpty {
                Text("netcapture.detail.noMessages").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(flow.messages) { message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: message.fromClient ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(message.fromClient ? Color(hex: 0x0A84FF) : Color(hex: 0x28A745))
                        .frame(width: 14)
                    Text(verbatim: FlowFormat.time(message.at))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let text = message.text {
                        Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("netcapture.detail.binary \(message.size)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var rawView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcapture.detail.rawRequest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "\(flow.method) \(flow.path) \(flow.httpVersion)",
                                   headers: flow.requestHeaders, body: flow.requestBody))
                .font(.caption.monospaced()).textSelection(.enabled)
            Divider()
            Text("netcapture.detail.rawResponse").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "\(flow.httpVersion) \(flow.statusCode.map(String.init) ?? "")",
                                   headers: flow.responseHeaders, body: flow.responseBody))
                .font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func rawText(startLine: String, headers: [HTTPHeader], body: Data?) -> String {
        var lines = [startLine]
        for h in headers { lines.append("\(h.name): \(h.value)") }
        lines.append("")
        if let body, let text = String(data: body, encoding: .utf8) {
            lines.append(String(text.prefix(20000)))
        }
        return lines.joined(separator: "\n")
    }
}
