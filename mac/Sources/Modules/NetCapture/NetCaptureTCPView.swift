import AppKit
import SwiftUI

// 抓包窗口的「TCP 包」页（docs/packet-capture/CONTROL.md §4）：左边连接列表，右边详情。
// 记的是引擎当成原始 TCP 处理的连接（不是 HTTP、也不是能解成 HTTP 的 TLS）：手机经 WireGuard 来的，本机经 SOCKS 来的
// （要开「本机 → TCP」）。数据怎么落、协议怎么认、段怎么合成块在 Logic/TCPLog.swift、TCPProtocol.swift。

struct NetCaptureTCPView: View {
    @ObservedObject private var store = TCPStore.shared
    @ObservedObject private var engine = NetCaptureEngine.shared

    /// 协议筛选：某个协议（按列表里显示的名字，猜的带问号），或「未知」。
    enum ProtocolChoice: Hashable {
        case named(String)
        case unknown
    }

    @State private var query = ""
    @State private var device: String?
    @State private var protocolChoice: ProtocolChoice?
    @State private var selection: TCPConnection.ID?

    /// 列表显示的行，新的在上。
    private var visible: [TCPConnection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.connections.reversed().filter { connection in
            if let device, connection.deviceKey != device { return false }
            switch protocolChoice {
            case .named(let label)?: if connection.protocolLabel != label { return false }
            case .unknown?: if connection.protocolLabel != nil { return false }
            case nil: break
            }
            guard !needle.isEmpty else { return true }
            return "\(connection.target):\(connection.port)".lowercased().contains(needle)
                || connection.host.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.connections.isEmpty {
                if engine.isActive {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("netcapture.tcp.waiting").foregroundStyle(.secondary)
                        Text("netcapture.tcp.waitingNote").font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NetCaptureGoToConfig()
                }
            } else {
                let rows = visible
                GeometryReader { geometry in
                    let total = geometry.size.width
                    // 列表 45%，至少 380；详情至少 380（十六进制一行 16 字节要这么宽）。
                    let listWidth = min(max(total * 0.45, 380), max(total - 380, 300))
                    HStack(spacing: 0) {
                        connectionList(rows).frame(width: listWidth)
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                store.clear()
                selection = nil
            } label: {
                Image(systemName: "trash")
            }
            .help(Text("netcapture.tcp.clear"))
            .disabled(store.connections.isEmpty)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("netcapture.tcp.search", text: $query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 90, idealWidth: 180, maxWidth: 260)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

            Menu {
                Button("netcapture.tcp.allDevices") { device = nil }
                Divider()
                ForEach(devices, id: \.self) { key in
                    Button(FlowStore.label(for: key)) { device = key }
                }
            } label: {
                Text(device.map(FlowStore.label(for:)) ?? L("netcapture.tcp.allDevices"))
            }
            .fixedSize()

            Menu {
                Button("netcapture.tcp.allProtocols") { protocolChoice = nil }
                Divider()
                ForEach(protocolLabels, id: \.self) { label in
                    Button(label) { protocolChoice = .named(label) }
                }
                if store.connections.contains(where: { $0.protocolLabel == nil }) {
                    Button("netcapture.tcp.unknown") { protocolChoice = .unknown }
                }
            } label: {
                Text(protocolMenuTitle)
            }
            .fixedSize()

            Spacer(minLength: 0)

            Text("netcapture.tcp.count \(visible.count) \(store.connections.count)")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var devices: [String] {
        var seen = Set<String>()
        return store.connections.compactMap { seen.insert($0.deviceKey).inserted ? $0.deviceKey : nil }
    }

    /// 列表里出现过的协议（显示名，猜的带问号），按名字排。
    private var protocolLabels: [String] {
        Set(store.connections.compactMap(\.protocolLabel)).sorted()
    }

    private var protocolMenuTitle: String {
        switch protocolChoice {
        case .named(let label)?: return label
        case .unknown?: return L("netcapture.tcp.unknown")
        case nil: return L("netcapture.tcp.allProtocols")
        }
    }

    // MARK: 列表

    /// 一行两层：上面「目标:端口 协议」，下面「开始时间 · 设备」；右边「状态」，下面「时长 · ↑ ↓」。
    /// 不用多列的表格：窗口最窄（900）时八列放不下，挤掉的正是时长和字节数。
    private func connectionList(_ rows: [TCPConnection]) -> some View {
        List(rows, selection: $selection) { connection in
            TCPRow(connection: connection).tag(connection.id)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
    }

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let connection = store.connections.first(where: { $0.id == id }) {
            // 换一条连接时详情里的选择（十六进制 / 文本、按分段）回到默认。
            TCPDetailView(connection: connection).id(connection.id)
        } else {
            Text("netcapture.tcp.select").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 列表的一行

private struct TCPRow: View {
    let connection: TCPConnection

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(connection.target):\(connection.port)")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    protocolBadge
                }
                Text(verbatim: "\(TCPFormat.clock(connection.startedAt)) · \(FlowStore.label(for: connection.deviceKey))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(TCPFormat.stateKey(connection.state))
                    .font(.caption.weight(.medium)).foregroundStyle(TCPFormat.stateColor(connection.state))
                Text(verbatim: "\(TCPFormat.duration(connection))  ↑\(FlowFormat.bytes(connection.bytesUp))  ↓\(FlowFormat.bytes(connection.bytesDown))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    /// 协议放在目标后面：认出来的正常色，按端口猜的（带问号）次要色，认不出写「未知」。
    @ViewBuilder
    private var protocolBadge: some View {
        if let match = connection.detected {
            Text(verbatim: match.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background((match.guessed ? Color.secondary : NetCaptureColors.accent).opacity(0.15), in: Capsule())
                .foregroundStyle(match.guessed ? Color.secondary : NetCaptureColors.accent)
                .fixedSize()
        } else {
            Text("netcapture.tcp.unknown")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.08), in: Capsule())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

// MARK: - 格式化

enum TCPFormat {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func duration(_ connection: TCPConnection) -> String {
        let seconds = (connection.endedAt ?? Date()).timeIntervalSince(connection.startedAt)
        if seconds < 1 { return "\(Int(seconds * 1000))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        if whole < 3600 { return "\(whole / 60)m\(whole % 60)s" }
        return "\(whole / 3600)h\(whole % 3600 / 60)m"
    }

    static func stateKey(_ state: TCPConnection.State) -> LocalizedStringKey {
        switch state {
        case .open: return "netcapture.tcp.state.open"
        case .closed: return "netcapture.tcp.state.closed"
        case .failed: return "netcapture.tcp.state.failed"
        }
    }

    static func stateColor(_ state: TCPConnection.State) -> Color {
        switch state {
        case .open: return NetCaptureColors.accent
        case .closed: return .secondary
        case .failed: return Color(hex: 0xFF3B30)
        }
    }
}

// MARK: - 一条连接的详情

struct TCPDetailView: View {
    let connection: TCPConnection

    enum Format: String { case hex, text }

    /// nil = 跟着协议走：文本类协议默认文本，其余默认十六进制。
    @State private var format: Format?
    /// 按读到的分段显示（看读取时序用）；默认把相邻同方向的段合成一块。
    @State private var bySegment = false

    /// 一块最多显示这么多字节，后面的复制可以拿到。
    static let displayLimit = 64 * 1024

    private var shownFormat: Format {
        format ?? (connection.detected?.prefersText == true ? .text : .hex)
    }

    var body: some View {
        let blocks = TCPStream.blocks(connection.segments, merge: !bySegment)
        VStack(spacing: 0) {
            header.padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    overview
                    Divider()
                    dataControls(blocks)
                    if blocks.isEmpty {
                        Text("netcapture.tcp.noData").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(blocks) { block in
                        TCPBlockView(block: block, format: shownFormat, limit: Self.displayLimit)
                    }
                    if connection.droppedSegments > 0 {
                        Text("netcapture.tcp.dropped \(TCPLog.maxSegments) \(connection.droppedSegments)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(connection.target):\(connection.port)").font(.headline).lineLimit(1).truncationMode(.middle)
            Text(TCPFormat.stateKey(connection.state))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(TCPFormat.stateColor(connection.state).opacity(0.15), in: Capsule())
                .foregroundStyle(TCPFormat.stateColor(connection.state))
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("netcapture.tcp.target", connection.sni.map { "\($0) (\(connection.host)):\(connection.port)" }
                ?? "\(connection.host):\(connection.port)")
            field("netcapture.tcp.device", FlowStore.label(for: connection.deviceKey))
            field("netcapture.detail.protocol", protocolText)
            field("netcapture.detail.started", FlowFormat.time(connection.startedAt))
            field("netcapture.tcp.ended", connection.endedAt.map(FlowFormat.time) ?? L("netcapture.tcp.state.open"))
            field("netcapture.detail.duration", TCPFormat.duration(connection))
            field("netcapture.tcp.sent", FlowFormat.bytes(connection.bytesUp))
            field("netcapture.tcp.received", FlowFormat.bytes(connection.bytesDown))
            field("netcapture.tcp.segments", "\(connection.segmentCount)")
            if let error = connection.error {
                field("netcapture.detail.error", error)
            }
        }
    }

    private var protocolText: String {
        guard let match = connection.detected else { return L("netcapture.tcp.unknown") }
        return match.guessed ? L("netcapture.tcp.guessedByPort \(match.name)") : match.name
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(verbatim: value).font(.callout).textSelection(.enabled)
        }
    }

    private func dataControls(_ blocks: [TCPBlock]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("netcapture.tcp.data").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Picker("", selection: Binding(get: { shownFormat }, set: { format = $0 })) {
                    Text("netcapture.tcp.hex").tag(Format.hex)
                    Text("netcapture.tcp.text").tag(Format.text)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                CopyButton(title: "netcapture.tcp.copyAll") { TCPBlockView.copyText(blocks, format: shownFormat) }
                    .controlSize(.small)
            }
            Toggle("netcapture.tcp.bySegment", isOn: $bySegment).toggleStyle(.checkbox).font(.callout)
            Text("netcapture.tcp.boundaryNote").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 一块数据

/// 一块：方向、总字节数、起止时间、几段；下面是内容（十六进制或文本），没保存的部分是一行占位，偏移照样往前走。
struct TCPBlockView: View {
    let block: TCPBlock
    let format: TCPDetailView.Format
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: block.fromClient ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(block.fromClient ? NetCaptureColors.accent : Color(hex: 0x0A84FF))
                Text(block.fromClient ? "netcapture.tcp.fromClient" : "netcapture.tcp.fromServer").font(.caption.weight(.medium))
                Text(verbatim: FlowFormat.bytes(block.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(verbatim: timeRange).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if block.segmentCount > 1 {
                    Text("netcapture.tcp.blockSegments \(block.segmentCount)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                CopyButton(title: "netcapture.common.copy") { Self.copyText([block], format: format) }
                    .controlSize(.mini)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .text(let text) where format == .hex:
                    // 十六进制不折行（折了偏移和 ASCII 就对不齐）：放不下就横着滚。
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                case .text(let text):
                    Text(verbatim: text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .note(let text):
                    Text(verbatim: text)
                        .font(.caption).italic().foregroundStyle(.secondary)
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill((block.fromClient ? NetCaptureColors.accent : Color(hex: 0x0A84FF)).opacity(0.06)))
    }

    /// 开始时间，跨了时间的再跟一个「+耗时」（写两个完整时间在窄的详情里会折行）。
    private var timeRange: String {
        let start = FlowFormat.time(block.startedAt)
        let span = Int(block.endedAt.timeIntervalSince(block.startedAt) * 1000)
        return span > 0 ? start + " +\(span)ms" : start
    }

    enum Row {
        case text(String)
        case note(String)
    }

    /// 显示用的行：数据切成每 4 KB 一段（一个 Text 不会太大），超过 `limit` 的不显示；没保存的部分一行占位。
    private var rows: [Row] {
        var result: [Row] = []
        var shown = 0
        var hidden = 0
        for part in block.parts {
            switch part {
            case .data(let data, let offset):
                let room = max(0, limit - shown)
                let visible = data.prefix(room)
                hidden += data.count - visible.count
                shown += visible.count
                result += Self.chunks(Data(visible), offset: offset, format: format).map(Row.text)
            case .missing(let count, let offset):
                result.append(.note(L("netcapture.tcp.missing \(count) \(TCPPayload.offsetText(offset))")))
            }
        }
        if hidden > 0 { result.append(.note(L("netcapture.tcp.notShown \(hidden)"))) }
        return result
    }

    private static func chunks(_ data: Data, offset: Int, format: TCPDetailView.Format) -> [String] {
        guard !data.isEmpty else { return [] }
        switch format {
        case .hex:
            let size = 4096
            return stride(from: 0, to: data.count, by: size).map { start in
                let slice = data.subdata(in: data.startIndex + start..<data.startIndex + min(start + size, data.count))
                return TCPPayload.hexDump(slice, startOffset: offset + start)
            }
        case .text:
            let lines = TCPPayload.text(data).components(separatedBy: "\n")
            return stride(from: 0, to: lines.count, by: 200).map { lines[$0..<min($0 + 200, lines.count)].joined(separator: "\n") }
        }
    }

    /// 复制：整块（不受显示上限限制），十六进制带累计偏移；没保存的部分写一行说明。
    static func copyText(_ blocks: [TCPBlock], format: TCPDetailView.Format) -> String {
        blocks.map { block in
            let direction = L(block.fromClient ? "netcapture.tcp.fromClient" : "netcapture.tcp.fromServer")
            var lines = ["# \(direction) · \(block.size) B · \(FlowFormat.time(block.startedAt))"]
            for part in block.parts {
                switch part {
                case .data(let data, let offset):
                    lines.append(format == .hex ? TCPPayload.hexDump(data, startOffset: offset) : TCPPayload.text(data))
                case .missing(let count, let offset):
                    lines.append(L("netcapture.tcp.missing \(count) \(TCPPayload.offsetText(offset))"))
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
