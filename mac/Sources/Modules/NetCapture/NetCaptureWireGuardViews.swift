import AppKit
import SwiftUI

// 「配置」页 WireGuard 的设备列表、添加 / 二维码 / 改名小窗、删除确认（docs/packet-capture/WIREGUARD-DEVICES.md §6，
// 示意图 mockups/wireguard-devices-starttls.html 图 1–3）。卡片上只列设备，二维码在小窗里出现。

/// WireGuard 设备小窗的三种用法。
enum WireGuardDialog: Identifiable, Equatable {
    /// 「添加设备」：先起名（输入框里先填好 `name`），点「下一步」才建钥匙、出二维码。
    case add(name: String)
    /// 已有设备点二维码图标：直接是第二步。
    case qr(deviceID: String)
    /// 改名：第一步的小窗，标题「重命名设备」，按钮「保存」。
    case rename(deviceID: String)

    var id: String {
        switch self {
        case .add: return "add"
        case .qr(let id): return "qr-" + id
        case .rename(let id): return "rename-" + id
        }
    }
}

@MainActor
enum WireGuardUI {
    /// WireGuard 总开关（左边那一行和右边标题上的是同一个）。打开时一台设备都没有 → 直接弹出添加小窗，名字填好「设备 1」。
    static func setOn(_ on: Bool) {
        NetCaptureSession.shared.setWireGuard(on)
        guard on else { return }
        let store = WireGuardDeviceStore.shared
        // 排在会话自己的那个回调后面：到这里开关已经落定。
        store.ensureLoaded {
            guard NetCaptureSession.shared.wireguardOn, store.devices.isEmpty else { return }
            showAdd()
        }
    }

    static func showAdd() {
        NetCaptureWindowState.shared.wireguardDialog = .add(name: WireGuardDeviceStore.shared.defaultName())
    }

    /// 「最近活动」那一列的文字。
    static func seenText(_ date: Date?, now: Date) -> String {
        switch WireGuardActivity.seen(date, now: now) {
        case .never: return L("netcapture.wg.seen.never")
        case .justNow: return L("netcapture.wg.seen.justNow")
        case .minutes(let minutes): return L("netcapture.wg.seen.minutes \(minutes)")
        case .hours(let hours): return L("netcapture.wg.seen.hours \(hours)")
        case .yesterday: return L("netcapture.wg.seen.yesterday")
        case .days(let days): return L("netcapture.wg.seen.days \(days)")
        }
    }

    static let green = Color(hex: 0x30D158)
}

// MARK: - 设备列表

/// 设备列表：每台一行（名字、端口、最近活动、二维码 / 改名 / 删除），上面「设备 ＋ 添加设备」，下面一句提示。
struct WireGuardDeviceList: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var store = WireGuardDeviceStore.shared
    @ObservedObject private var state = NetCaptureWindowState.shared

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("netcapture.wg.devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { WireGuardUI.showAdd() } label: {
                    Label("netcapture.wg.add", systemImage: "plus")
                }
                .controlSize(.small)
                // 关着时不能加（加了也看不到二维码：关着时不显示任何和密钥有关的东西）。
                .disabled(!session.wireguardOn || !store.loaded)
            }
            // 「刚刚」「3 分钟前」要跟着时间走。
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(spacing: 0) {
                    if store.devices.isEmpty {
                        Text("netcapture.wg.empty").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().padding(.leading, 40) }
                        WireGuardDeviceRow(device: device, now: context.date)
                    }
                }
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
            }
            Text(session.wireguardOn ? "netcapture.wg.hint" : "netcapture.wg.offHint")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Self.width, alignment: .leading)
    }
}

/// 设备列表里的一行。点一下高亮；右键菜单和右边三个小按钮一样（二维码 / 改名 / 删除）。
struct WireGuardDeviceRow: View {
    let device: WireGuardDevice
    let now: Date
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var store = WireGuardDeviceStore.shared
    @ObservedObject private var state = NetCaptureWindowState.shared

    private var keyMissing: Bool { store.missingKeys.contains(device.id) }
    /// 二维码只在开关开着、钥匙还在时能看。
    private var canShowQR: Bool { session.wireguardOn && !keyMissing }

    var body: some View {
        let seen = store.lastSeen[device.id]
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: device.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if keyMissing {
                    Text("netcapture.wg.keyMissing").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: String(device.port))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 5) {
                Circle().fill(WireGuardActivity.isRecent(seen, now: now) ? WireGuardUI.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(verbatim: WireGuardUI.seenText(seen, now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            HStack(spacing: 4) {
                action("qrcode", help: "netcapture.wg.action.qr", enabled: canShowQR) { showQR() }
                action("pencil", help: "netcapture.wg.action.rename", enabled: true) { rename() }
                action("trash", help: "netcapture.wg.action.delete", enabled: true) { askDelete() }
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(state.focusedWireGuardDevice == device.id ? NetCaptureColors.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { state.focusedWireGuardDevice = device.id }
        .contextMenu {
            Button { showQR() } label: { Label("netcapture.wg.action.qr", systemImage: "qrcode") }.disabled(!canShowQR)
            Button { rename() } label: { Label("netcapture.wg.action.rename", systemImage: "pencil") }
            Button(role: .destructive) { askDelete() } label: { Label("netcapture.wg.action.delete", systemImage: "trash") }
        }
    }

    private func action(_ symbol: String, help: LocalizedStringKey, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(Text(help))
    }

    private func showQR() {
        state.focusedWireGuardDevice = device.id
        state.wireguardDialog = .qr(deviceID: device.id)
    }

    private func rename() {
        state.focusedWireGuardDevice = device.id
        state.wireguardDialog = .rename(deviceID: device.id)
    }

    private func askDelete() {
        state.focusedWireGuardDevice = device.id
        state.wireguardDeleteID = device.id
    }
}

// MARK: - 小窗

/// 添加设备（起名 → 二维码）、看已有设备的二维码、改名，都是这一个小窗。
struct WireGuardDeviceSheet: View {
    let dialog: WireGuardDialog
    let close: () -> Void

    enum Step: Equatable {
        case name
        /// `isNew`：刚加的（状态行写「第一个包」）；已有设备点二维码图标进来的写最近活动。
        case qr(deviceID: String, isNew: Bool)
    }

    @ObservedObject private var store = WireGuardDeviceStore.shared
    @ObservedObject private var session = NetCaptureSession.shared
    @State private var step: Step
    @State private var name: String
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    init(dialog: WireGuardDialog, close: @escaping () -> Void) {
        self.dialog = dialog
        self.close = close
        switch dialog {
        case .add(let name):
            _step = State(initialValue: .name)
            _name = State(initialValue: name)
        case .qr(let id):
            _step = State(initialValue: .qr(deviceID: id, isNew: false))
            _name = State(initialValue: "")
        case .rename:
            _step = State(initialValue: .name)
            _name = State(initialValue: "")
        }
    }

    private var renamingID: String? {
        if case .rename(let id) = dialog { return id }
        return nil
    }

    var body: some View {
        switch step {
        case .name: nameStep
        case .qr(let id, let isNew): qrStep(id: id, isNew: isNew)
        }
    }

    // MARK: 第一步：起名

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renamingID != nil ? "netcapture.device.renameTitle" : "netcapture.wg.dialog.addTitle").font(.headline)
            HStack(spacing: 8) {
                Text("netcapture.wg.dialog.name").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { primary() }
            }
            Text("netcapture.wg.dialog.nameHint").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(verbatim: failure).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("common.cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(renamingID != nil ? "netcapture.wg.dialog.save" : "netcapture.wg.dialog.next") { primary() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent)
                    .disabled(WireGuardDeviceTable.cleanName(name) == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let id = renamingID, name.isEmpty { name = store.device(id: id)?.name ?? "" }
            // 先填好的名字整段选中：直接打字就是改名（文本框拿到焦点时 AppKit 会全选）。
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    /// 「下一步」才建钥匙、分端口、写设备表（WireGuard 开着就重启引擎）；「保存」只改名。
    private func primary() {
        guard WireGuardDeviceTable.cleanName(name) != nil, !busy else { return }
        busy = true
        failure = nil
        if let id = renamingID {
            store.rename(id: id, to: name) { ok in
                busy = false
                if ok { close() }
            }
            return
        }
        store.add(name: name) { result in
            busy = false
            switch result {
            case .success(let device): step = .qr(deviceID: device.id, isNew: true)
            case .failure(let error): failure = L("netcapture.wg.dialog.failed \(error.localizedDescription)")
            }
        }
    }

    // MARK: 第二步：二维码

    @ViewBuilder
    private func qrStep(id: String, isNew: Bool) -> some View {
        if let device = store.device(id: id) {
            let config = session.wireguardOn ? store.clientConfig(for: device) : nil
            let endpoint = store.endpoint(for: device)
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: isNew ? L("netcapture.wg.dialog.scanTitle \(device.name)") : L("netcapture.wg.dialog.qrTitle \(device.name)"))
                    .font(.headline)
                HStack(alignment: .top, spacing: 18) {
                    // 开关在小窗开着时被关掉：不再显示二维码（关着时不显示任何和密钥有关的东西）。
                    QRBox(text: config, side: ConfigDetailMetrics.qrSide, placeholder: "netcapture.wg.offHint", caption: endpoint)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("netcapture.config.wg.endpoint").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: endpoint).font(.title3.monospaced()).textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        CopyButton(title: "netcapture.config.wg.copy") { config ?? "" }
                            .controlSize(.small)
                            .disabled(config == nil)
                        StepRow(number: 1, text: "netcapture.config.wg.step1")
                        StepRow(number: 2, text: "netcapture.config.wg.step2")
                        StepRow(number: 3, text: "netcapture.config.wg.step3")
                    }
                }
                Divider()
                // 能扫这张码的客户端（§6.1）：点名字弹出下载页的二维码。
                WireGuardClientAppList()
                waitLine(device: device, isNew: isNew)
                HStack {
                    Spacer()
                    Button("netcapture.wg.dialog.done") { close() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent)
                }
            }
            .padding(20)
            .frame(width: 560)
        } else {
            // 小窗开着时这台被删了（比如经 MCP）。
            VStack(alignment: .leading, spacing: 14) {
                Text("netcapture.device.deleted").font(.headline)
                HStack {
                    Spacer()
                    Button("netcapture.wg.dialog.done") { close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    /// 底下一行状态：还没有这台的包时转圈等；来了包就变绿。
    private func waitLine(device: WireGuardDevice, isNew: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let seen = store.lastSeen[device.id]
            HStack(spacing: 8) {
                if let seen {
                    Image(systemName: "checkmark.seal.fill")
                    Text(verbatim: isNew
                         ? L("netcapture.wg.dialog.connected \(device.name)")
                         : L("netcapture.wg.dialog.lastSeen \(WireGuardUI.seenText(seen, now: context.date))"))
                } else {
                    ProgressView().controlSize(.small)
                    Text("netcapture.wg.dialog.waiting")
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(seen != nil ? WireGuardUI.green : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(seen != nil ? WireGuardUI.green.opacity(0.1) : Color.primary.opacity(0.05)))
        }
    }
}

// MARK: - 删除确认

extension View {
    /// 「删除「Pixel 模拟器」？」确认框（配置页的删除按钮、右键菜单都走这里）。
    func wireguardDeleteConfirmation() -> some View {
        modifier(WireGuardDeleteConfirmation())
    }
}

private struct WireGuardDeleteConfirmation: ViewModifier {
    @ObservedObject private var state = NetCaptureWindowState.shared
    @ObservedObject private var store = WireGuardDeviceStore.shared

    func body(content: Content) -> some View {
        let name = state.wireguardDeleteID.flatMap { store.device(id: $0)?.name } ?? ""
        content.alert(Text(verbatim: L("netcapture.wg.delete.title \(name)")),
                      isPresented: Binding(get: { state.wireguardDeleteID != nil },
                                           set: { if !$0 { state.wireguardDeleteID = nil } })) {
            Button("netcapture.wg.action.delete", role: .destructive) {
                if let id = state.wireguardDeleteID { store.remove(id: id) }
                state.wireguardDeleteID = nil
            }
            Button("common.cancel", role: .cancel) { state.wireguardDeleteID = nil }
        } message: {
            Text("netcapture.wg.delete.message")
        }
    }
}
