import SwiftUI

// 「编辑后重发…」面板（docs/packet-capture/TOOLS.md §3）：方法、URL、请求头（每行一个）、正文都能改，发出去是列表里新的一行。

/// 面板里正在编辑的那份请求。
struct ReplayDraft: Identifiable {
    let id = UUID()
    var method: String
    var url: String
    var headersText: String
    var bodyText: String
    /// 原正文不是文本（图片、protobuf…，见 `BodyText`）：不给改，原样发送。
    let binaryBody: Data?

    /// 用抓到的请求预填。长度、压缩、分块这三个头不显示（桥脚本会丢掉重算），正文是解压后的。
    init(flow: Flow) {
        method = flow.method
        url = flow.url
        headersText = HeaderText.text(flow.requestHeaders)
        if let body = flow.requestBody, !body.isEmpty {
            if let text = BodyText.text(body) {
                bodyText = text
                binaryBody = nil
            } else {
                bodyText = ""
                binaryBody = body
            }
        } else {
            bodyText = ""
            binaryBody = nil
        }
    }

    /// 发给引擎的请求；新那一行的 id 在这里定。
    func request() -> ReplayRequest {
        let body: Data? = binaryBody ?? (bodyText.isEmpty ? nil : Data(bodyText.utf8))
        return ReplayRequest(id: UUID(),
                             method: method.trimmingCharacters(in: .whitespaces).uppercased(),
                             url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                             headers: HeaderText.headers(headersText),
                             body: body)
    }
}

struct NetCaptureReplaySheet: View {
    @State var draft: ReplayDraft
    let onCancel: () -> Void
    let onSend: (ReplayRequest) -> Void

    /// 菜单里给的方法；原请求是别的方法就把它也放进去。
    private var methods: [String] {
        let common = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        return common.contains(draft.method) ? common : [draft.method] + common
    }

    private var canSend: Bool {
        !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcapture.replay.title").font(.headline)
            HStack(spacing: 8) {
                Picker("", selection: $draft.method) {
                    ForEach(methods, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                TextField("", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            Text("netcapture.replay.headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            editor($draft.headersText, height: 120)
            Text("netcapture.replay.body").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let binary = draft.binaryBody {
                Text("netcapture.replay.binaryBody \(binary.count)")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            } else {
                editor($draft.bodyText, height: 160)
            }
            HStack {
                Spacer()
                Button("common.cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("netcapture.replay.send") { onSend(draft.request()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.caption.monospaced())
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }
}
