import AppKit
import SwiftUI

// WireGuard 二维码小窗里的「能用的 App」：能扫这张码的客户端，一行一种设备；点名字弹出它下载页的二维码
// （人对着 Mac、App 装在手机上，手机相机一扫就去 App Store / APK 页），也能在浏览器里打开。
// 名单、链接与取舍见 docs/packet-capture/WIREGUARD-DEVICES.md §6.1（国区上架情况 2026-11-23 查的）。

enum WireGuardClientApps {
    struct App: Identifiable {
        let id: String
        let name: String
        /// 名字后面的小字（「国区可下」「外区 ID」「Windows」），没有就是 nil。
        let tag: Text?
        let url: String
    }

    struct Platform: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let apps: [App]
    }

    /// 计算属性：`Text` / `LocalizedStringKey` 不是 Sendable，不放进静态存储。
    static var platforms: [Platform] {
        [
            Platform(id: "ios", title: "netcapture.wg.apps.ios", apps: [
                App(id: "ios-amneziawg", name: "AmneziaWG", tag: Text("netcapture.wg.apps.cnStore"),
                    url: "https://apps.apple.com/app/id6478942365"),
                App(id: "ios-wireguard", name: "WireGuard", tag: Text("netcapture.wg.apps.intlStore"),
                    url: "https://apps.apple.com/app/id1441195209"),
            ]),
            Platform(id: "android", title: "netcapture.wg.apps.android", apps: [
                App(id: "android-wireguard", name: "WireGuard", tag: nil,
                    url: "https://download.wireguard.com/android-client/"),
                App(id: "android-amneziawg", name: "AmneziaWG", tag: nil,
                    url: "https://github.com/amnezia-vpn/amneziawg-android/releases/latest"),
                App(id: "android-wgtunnel", name: "WG Tunnel", tag: nil,
                    url: "https://github.com/wgtunnel/android/releases/latest"),
            ]),
            Platform(id: "computer", title: "netcapture.wg.apps.computer", apps: [
                App(id: "computer-wireguard", name: "WireGuard", tag: nil,
                    url: "https://www.wireguard.com/install/"),
                App(id: "computer-amneziawg", name: "AmneziaWG", tag: Text(verbatim: "Windows"),
                    url: "https://github.com/amnezia-vpn/amneziawg-windows-client/releases/latest"),
            ]),
        ]
    }
}

/// 「能用的 App」整块：标题、每种设备一行（App 名是按钮）、一句 AmneziaWG 的提醒。
struct WireGuardClientAppList: View {
    /// 正弹着下载二维码的那个 App。
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("netcapture.wg.apps.title").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(WireGuardClientApps.platforms) { platform in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(platform.title).font(.callout).foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(platform.apps) { app in chip(app) }
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("netcapture.wg.apps.amneziaNote").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ app: WireGuardClientApps.App) -> some View {
        Button {
            shown = app.id
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: app.name)
                if let tag = app.tag {
                    tag.font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "qrcode").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(Text("netcapture.wg.apps.help"))
        .popover(isPresented: Binding(get: { shown == app.id }, set: { if !$0 { shown = nil } }),
                 arrowEdge: .bottom) {
            WireGuardClientAppDownload(app: app)
        }
    }
}

/// 点 App 名弹出的小气泡：名字、下载页的二维码、「手机相机扫…」、在浏览器打开。
private struct WireGuardClientAppDownload: View {
    let app: WireGuardClientApps.App

    private static let side: CGFloat = 168

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(verbatim: app.name).font(.headline)
                if let tag = app.tag {
                    tag.font(.caption).foregroundStyle(.secondary)
                }
            }
            if let image = QRCodeGenerator.image(for: app.url, minPixels: Int(Self.side * 2)) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: Self.side, height: Self.side)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            }
            Text("netcapture.wg.apps.scan").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: app.url) { NSWorkspace.shared.open(url) }
            } label: {
                Label("netcapture.wg.apps.open", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: Self.side + 56)
    }
}
