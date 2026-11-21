import AppKit
import SwiftUI

// 详情里的表格与正文（docs/packet-capture/TOOLS.md §2、§5）：
// - `KeyValueTable`：两列，名定宽，值换行、可选中；
// - `SetCookieList`：每条一行，名、值、其余属性原样；
// - `BodySection`：正文。图片预览 / Protobuf·gRPC·msgpack 解码文本 / 表单表格 / JSON 树或文本 / 文本 / 二进制只报大小。

// MARK: - 表

struct KeyValueTable: View {
    let rows: [NameValue]

    /// 名那一列的宽度。名长了在列内换行，不挤值那一列。
    static let nameWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: row.name)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: Self.nameWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: row.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(index % 2 == 1 ? Color.primary.opacity(0.04) : Color.clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SetCookieList: View {
    let cookies: [SetCookie]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cookies.enumerated()), id: \.offset) { index, cookie in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: cookie.name)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: KeyValueTable.nameWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: cookie.value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !cookie.attributes.isEmpty {
                            Text(verbatim: cookie.attributes)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(index % 2 == 1 ? Color.primary.opacity(0.04) : Color.clear)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - JSON 树

/// 对象和数组可折叠，默认展开两层；每层超过 `JSONNode.childLimit` 个子项只显示前面的，末尾一行「还有 N 项」；键保持原文顺序。
struct JSONTreeView: View {
    let root: JSONNode

    var body: some View {
        JSONNodeView(label: nil, node: root, depth: 0)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }
}

private struct JSONNodeView: View {
    let label: String?
    let node: JSONNode
    let depth: Int
    @State private var expanded: Bool

    /// 每一层往里缩多少。
    static let indent: CGFloat = 14
    /// 标量行的键和 DisclosureGroup 标题文字对齐要让出的宽度（三角那一格）。
    static let labelInset: CGFloat = 12

    init(label: String?, node: JSONNode, depth: Int) {
        self.label = label
        self.node = node
        self.depth = depth
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        if node.isContainer {
            DisclosureGroup(isExpanded: $expanded) {
                let children = node.children()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(children.items.enumerated()), id: \.offset) { _, child in
                        JSONNodeView(label: child.label, node: child.node, depth: depth + 1)
                    }
                    if children.remaining > 0 {
                        Text("netcapture.body.moreItems \(children.remaining)")
                            .foregroundStyle(.secondary)
                            .padding(.leading, Self.labelInset)
                    }
                }
                // macOS 的 DisclosureGroup 不给内容缩进，自己缩；撑满宽度靠左，否则一列短行会被居中。
                .padding(.leading, Self.indent)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 4) {
                    labelText
                    Text(verbatim: node.summary).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                labelText
                Text(verbatim: node.scalarText)
                    .foregroundStyle(scalarColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 和同一层 DisclosureGroup 的标题对齐（标题前面有一个三角）。
            .padding(.leading, Self.labelInset)
        }
    }

    @ViewBuilder
    private var labelText: some View {
        if let label {
            Text(verbatim: label + ":").foregroundStyle(.primary).fontWeight(.medium)
        }
    }

    private var scalarColor: Color {
        switch node {
        case .string: return Color(hex: 0x28A745)
        case .number: return Color(hex: 0x0A84FF)
        case .bool, .null: return Color(hex: 0x8B5CF6)
        case .object, .array: return .primary
        }
    }
}

// MARK: - 正文

enum BodySide { case request, response }

/// 正文那一节：标题右边有「树 / 文本」切换（JSON）、「原始」切换（Protobuf 等解码过的）、「复制」。
struct BodySection: View {
    let flowID: UUID
    let side: BodySide
    let data: Data?
    let headers: [HTTPHeader]
    let truncated: Bool
    let sniffed: String?
    let decoded: DecodedBody?

    @State private var jsonAsText = false
    @State private var showRaw = false

    init(flowID: UUID, side: BodySide, body: Data?, headers: [HTTPHeader],
         truncated: Bool, sniffed: String?, decoded: DecodedBody?) {
        self.flowID = flowID
        self.side = side
        self.data = body
        self.headers = headers
        self.truncated = truncated
        self.sniffed = sniffed
        self.decoded = decoded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data, !data.isEmpty {
                let presentation = BodyPresentationCache.shared.presentation(
                    flowID: flowID, side: side, data: data, contentType: headers.value(for: "Content-Type"))
                let showingDecoded = decoded != nil && !showRaw
                DetailSection(title: "netcapture.detail.body",
                              copy: copyText(presentation, showingDecoded: showingDecoded)) {
                    accessory(presentation, showingDecoded: showingDecoded)
                } content: {
                    if showingDecoded, let decoded {
                        decodedView(decoded)
                    } else {
                        content(presentation)
                    }
                }
                if let sniffed {
                    Text("netcapture.detail.sniffed \(sniffed)").font(.caption2).foregroundStyle(.secondary)
                }
            } else if !truncated {
                Text("netcapture.detail.noBody").font(.caption).foregroundStyle(.secondary)
            }
            if truncated {
                Text("netcapture.detail.truncated").font(.caption2).foregroundStyle(.orange)
            }
        }
        // 换一条请求时切换状态回到默认（树、解码视图）。
        .id(flowID)
    }

    /// 「复制」复制看到的：解码文本 / 正文原文；二进制且没解码时不给复制。
    private func copyText(_ presentation: BodyPresentation, showingDecoded: Bool) -> (() -> String)? {
        if showingDecoded, let text = decoded?.text { return { text } }
        guard let text = presentation.rawText else { return nil }
        return { text }
    }

    @ViewBuilder
    private func accessory(_ presentation: BodyPresentation, showingDecoded: Bool) -> some View {
        if decoded != nil {
            Toggle("netcapture.body.raw", isOn: $showRaw)
                .toggleStyle(.button)
                .controlSize(.small)
                .help(Text("netcapture.body.rawHelp"))
        }
        if !showingDecoded, case .json = presentation.kind {
            Picker("", selection: $jsonAsText) {
                Text("netcapture.body.tree").tag(false)
                Text("netcapture.body.text").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func content(_ presentation: BodyPresentation) -> some View {
        switch presentation.kind {
        case .image(let image):
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
        case .form(let items):
            KeyValueTable(rows: items)
        case .json(let node):
            if jsonAsText {
                textBox(presentation.jsonText)
            } else {
                JSONTreeView(root: node)
            }
        case .text(let text):
            textBox(text)
        case .binary(let count):
            Text("netcapture.detail.binary \(count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 解码后的文本，上面一行小字说明是按什么解的。
    private func decodedView(_ decoded: DecodedBody) -> some View {
        let view = decoded.view.isEmpty ? "Protobuf" : decoded.view
        let lower = view.lowercased()
        let fieldNumbersOnly = lower.contains("protobuf") || lower.contains("grpc") || lower.contains("proto")
        return VStack(alignment: .leading, spacing: 4) {
            Text(fieldNumbersOnly ? "netcapture.body.decodedProtobuf \(view)" : "netcapture.body.decodedOther \(view)")
                .font(.caption2).foregroundStyle(.secondary)
            textBox(BodyPresentation.capped(decoded.text.trimmingCharacters(in: .newlines)))
        }
    }

    private func textBox(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }
}

/// 一段正文怎么显示。解析（JSON 建树、表单拆分）只做一次：详情视图每次重绘都会重建，不能每次都重新解。
@MainActor
final class BodyPresentation {
    enum Kind {
        case image(NSImage)
        case form([NameValue])
        case json(JSONNode)
        case text(String)
        case binary(Int)
    }

    let kind: Kind
    /// 正文原文；不是文本（见 `BodyText`）为 nil。「复制」用它。
    let rawText: String?

    /// JSON 的文本那一面：缩进两格、键序与原文一致。第一次切到「文本」时才生成。
    private(set) lazy var jsonText: String = {
        guard case .json(let node) = kind else { return rawText ?? "" }
        return Self.capped(node.prettyText())
    }()

    /// SwiftUI 的 Text 排几 MB 文字会卡住窗口：只显示前面这么多字符。
    static let displayLimit = 200_000

    static func capped(_ text: String) -> String {
        text.count > displayLimit ? String(text.prefix(displayLimit)) + "\n…" : text
    }

    init(data: Data, contentType: String?) {
        let type = contentType?.lowercased() ?? ""
        let text = BodyText.text(data)
        rawText = text
        if type.hasPrefix("image/"), let image = NSImage(data: data) {
            kind = .image(image)
        } else if let items = RequestParams.formItems(body: data, contentType: type), !items.isEmpty {
            kind = .form(items)
        } else if JSONNode.looksLikeJSON(data, contentType: type), let node = JSONNode.parse(data) {
            kind = .json(node)
        } else if let text {
            kind = .text(Self.capped(text))
        } else {
            kind = .binary(data.count)
        }
    }
}

/// 最近看过的几段正文的解析结果。键里带上长度：同一条请求的正文到了 / 变了就重新解。
@MainActor
final class BodyPresentationCache {
    static let shared = BodyPresentationCache()
    private var entries: [String: BodyPresentation] = [:]
    private var order: [String] = []
    private static let capacity = 16

    func presentation(flowID: UUID, side: BodySide, data: Data, contentType: String?) -> BodyPresentation {
        let key = "\(flowID.uuidString)-\(side)-\(data.count)-\(contentType ?? "")"
        if let hit = entries[key] { return hit }
        let made = BodyPresentation(data: data, contentType: contentType)
        entries[key] = made
        order.append(key)
        if order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return made
    }
}
