import Foundation

// 快速入口的计算结果行（docs/launcher/TECH_DESIGN.md §7）：每次输入变化调一次计算引擎（纯逻辑、只读内存），
// 有结果就固定排在第一行，不经过排序、不记使用。什么时候算见 `LauncherInstantPolicy`（打了来源前缀不算）。

@MainActor
enum LauncherCalculatorProvider {
    static let rowID = "calculator/result"

    /// 这次输入的计算结果行；不是算式为 nil。`locale` 跟 App 的界面语言（`L10n.locale`），日历和时区跟系统。
    static func instant(for text: String, now: Date, locale: Locale) -> LauncherInstant? {
        let context = LauncherCalcContext(now: now, calendar: .current, timeZone: .current, locale: locale)
        guard let result = LauncherCalculator.evaluate(text, context: context) else { return nil }
        let row = LauncherRow(id: rowID, title: result.display, source: kindName(result.kind), icon: .symbol("equal"),
                              style: .calculation(interpretation: result.interpretation, failed: result.failure != nil))
        return LauncherInstant(row: row, copyText: result.copyText)
    }

    /// 第一次调计算引擎要建单位、地名这些静态表：预热时先算一次，别让第一下按键来付这笔钱。
    static func warmUp(locale: Locale) {
        for text in ["12*(3+4)", "72 f to c", "today + 45 days", "time in tokyo"] {
            _ = instant(for: text, now: Date(), locale: locale)
        }
    }

    /// 右侧小字：结果的种类。
    static func kindName(_ kind: LauncherCalcKind) -> String {
        switch kind {
        case .arithmetic: return L("launcher.calc.kind.arithmetic")
        case .percentage: return L("launcher.calc.kind.percentage")
        case .unit: return L("launcher.calc.kind.unit")
        case .base: return L("launcher.calc.kind.base")
        case .date: return L("launcher.calc.kind.date")
        case .timeZone: return L("launcher.calc.kind.timeZone")
        case .timestamp: return L("launcher.calc.kind.timestamp")
        }
    }
}
