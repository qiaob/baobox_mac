import SwiftUI

/// 关于页：版本号 + 检查更新占位（M2 接入 Sparkle）。
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)

            Text(verbatim: "Baobox")
                .font(.title2.bold())

            Text("settings.about.version \(version)")
                .foregroundStyle(.secondary)

            Text("settings.about.tagline")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("app.menu.checkUpdates") {}
                .disabled(true)
                .help("settings.about.sparkleHelp")

            Text(verbatim: "© 2026 Baobox")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
