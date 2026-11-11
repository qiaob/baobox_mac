import Foundation

/// Claude Code / Codex 两个助手共用的展示格式化（#164，docs/codex-assistant/DEDUPE-P2.md §2.4 类 2）：
/// 费用、token、倒计时、字节、相对时间、星期名。
///
/// 两边原来各有一份逐行相同的 `ClaudeFormat` / `AIToolsFormat`，只差「≥ 24 小时的倒计时」用的文案 key
/// （key 按模块分命名空间，有意保留，D5）。现在模块里这两个名字是 `CLIFormat<各自的 Localization>` 的 typealias，
/// 调用点一行不改；文案与语言由 `Localization` 给（模块用自己的文案 key 取译文、传 `L10n.locale`）。
/// 只 import Foundation、不碰文案表：进 BaoboxTests。
protocol CLIFormatLocalization {
    /// 「N 天 M 小时」：周窗口剩 ≥ 1 天时的倒计时（模块用自己的文案 key）。
    static func dayHour(days: Int, hours: Int) -> String
    /// 相对时间、星期名用的语言（跟随应用语言，不是系统地区）。
    static var locale: Locale { get }
}

enum CLIFormat<Localization: CLIFormatLocalization> {

    /// 费用统一 `$%.2f`（处处标「估算」由文案负责）。
    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// token 数：≥100 万记 `%.1fM`，≥1000 记 `%.1fk`，否则原样。
    /// 先判门槛再按一位小数四舍五入，所以 999,950–999,999 显示「1000.0k」（一直如此，单测钉着）。
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    /// 倒计时：`2h15m` / `45m`（语言无关的 h/m）。
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    /// 长倒计时（跨度可到「天」，供周窗口用）：≥24h 显示本地化的「N 天 M 小时」，<24h 沿用 `countdown`。
    static func countdownLong(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        guard days > 0 else { return countdown(seconds) }
        let hours = (total % 86_400) / 3600
        return Localization.dayHour(days: days, hours: hours)
    }

    /// 字节数人性化展示。
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 相对时间（如「3 分钟前」），相对于 `now`（默认此刻；测试传固定值）。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 本地化的 standalone 星期名（Calendar 口径：1 = 周日 … 7 = 周六）；越界给数字本身。
    static func weekdayName(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }

    /// 周窗口固定锚点的描述，如「周三 09:00」（星期名 + 补零的整点）。
    static func weekAnchor(weekday: Int, hour: Int) -> String {
        String(format: "%@ %02d:00", weekdayName(weekday), hour)
    }
}
