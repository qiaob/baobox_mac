import Foundation

// 快速入口 App 来源的名字规则（docs/launcher/TECH_DESIGN.md §6.1）：一个 App 有几个名字（系统显示名、Info.plist 里的
// CFBundleDisplayName / CFBundleName、文件名），都进搜索键，所以「微信」「WeChat」「wx」都能中。
// 只依赖 Foundation，进 BaoboxTests；扫目录、读 Info.plist 在 `Providers/AppProvider.swift`。

enum LauncherAppNames {

    /// 搜索用的名字：按传入顺序（第一个是列表里显示的标题），去掉 `.app` 后缀和首尾空白，
    /// 空的、只剩 `.app` 的不要，不分大小写重复的只留第一个。传进来全是空的时返回空数组。
    static func searchNames(_ names: [String?]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in names {
            guard let raw else { continue }
            let name = strippingAppExtension(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != ".app", seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
        }
        return result
    }

    /// 去掉结尾的 `.app`（不分大小写）；只有 `.app` 本身时原样返回。
    static func strippingAppExtension(_ name: String) -> String {
        let suffix = ".app"
        guard name.count > suffix.count, name.lowercased().hasSuffix(suffix) else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// 是不是 `.app` 包的文件名（不分大小写；只有 `.app` 三个字的隐藏名不算）。
    static func isAppBundleName(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }
}
