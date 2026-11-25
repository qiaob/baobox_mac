import Foundation

// 快速入口的计算引擎入口（docs/launcher/TECH_DESIGN.md §7；例子见 REQUIREMENTS.md §3.3）。
// 输入 → 归一化与词法（LauncherCalcLexer）→ 按顺序试几种句型，第一个**完整吃掉整段输入**的生效：
//   时间戳 → 进制 → 日期 → 时区 → 单位 → 百分比 → 算术。
// 宁可不出，不要误出：裸数字、一个普通的词、带着认不出的字母或汉字的输入一律不出结果。
// 只依赖 Foundation，进 BaoboxTests；不取当前时间、不读设置 —— 现在几点、时区、语言都由调用方经
// LauncherCalcContext 传入，测试才能写死。全程容错：任何输入都不 crash，长输入直接放过。

/// 结果的种类（界面按它选图标和 ⌘K 动作）。
enum LauncherCalcKind: String, Sendable {
    case arithmetic
    case percentage
    case unit
    case base
    case date
    case timeZone
    case timestamp
}

/// 调用方传入的环境。引擎里不取 `Date()`、`TimeZone.current`。
struct LauncherCalcContext: Sendable {
    var now: Date
    var calendar: Calendar
    var timeZone: TimeZone
    /// 决定输出语言：中文界面出中文单位名和说明，其余出英文。
    var locale: Locale

    init(now: Date, calendar: Calendar, timeZone: TimeZone, locale: Locale) {
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
        self.locale = locale
    }

    /// locale 的语言是中文（zh、zh-Hans、zh_CN…）。
    var prefersChinese: Bool { locale.identifier.lowercased().hasPrefix("zh") }

    /// 按界面语言二选一。
    func text(_ zh: String, _ en: String) -> String { prefersChinese ? zh : en }

    /// 日期计算用的日历：时区换成 `timeZone`。ISO 日期本来就按公历，传入的不是公历时换成公历。
    var gregorian: Calendar {
        var cal = calendar.identifier == .gregorian ? calendar : Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

/// 算不出结果的原因：显示成一句说明，不是结果，也没有可复制的文字。
enum LauncherCalcFailure: Error, Equatable, Sendable {
    case divisionByZero
    case overflow
    case notReal
    case infinite
    case outOfRange

    func message(_ context: LauncherCalcContext) -> String {
        switch self {
        case .divisionByZero: return context.text("不能除以零", "Division by zero")
        case .overflow: return context.text("数字太大，算不出来", "Number too large")
        case .notReal: return context.text("结果不是实数", "Not a real number")
        case .infinite: return context.text("结果是无穷大", "Result is infinite")
        case .outOfRange: return context.text("日期超出范围", "Date out of range")
        }
    }
}

/// 一条计算结果（快速入口列表的第一行）。
struct LauncherCalcResult: Equatable, Sendable {
    let kind: LauncherCalcKind
    /// 主行文字：结果（带千分位、单位，如 `1,234.5`、`8.04672 公里`）；出错时是那句说明。
    let display: String
    /// ⏎ 复制的文字（不带千分位、不带单位）；出错时 nil。
    let copyText: String?
    /// 小字：理解成了什么（标准写法，如 `458 × 1.15 ÷ 3`），理解错了一眼能看出来。
    let interpretation: String
    /// 非 nil = 出错（除以零、溢出…），`display` 是说明。
    let failure: LauncherCalcFailure?

    static func value(_ kind: LauncherCalcKind, display: String, copy: String,
                      interpretation: String) -> LauncherCalcResult {
        LauncherCalcResult(kind: kind, display: display, copyText: copy,
                           interpretation: interpretation, failure: nil)
    }

    static func failed(_ kind: LauncherCalcKind, _ failure: LauncherCalcFailure, interpretation: String,
                       context: LauncherCalcContext) -> LauncherCalcResult {
        LauncherCalcResult(kind: kind, display: failure.message(context), copyText: nil,
                           interpretation: interpretation, failure: failure)
    }
}

enum LauncherCalculator {
    /// 超过这个长度（字符数）不当算式：没有人会在输入框里打这么长的算式，长输入直接放过，不拖慢打字。
    static let maxInputLength = 160

    /// 整个输入是一条算式才返回结果；否则 nil。
    static func evaluate(_ input: String, context: LauncherCalcContext) -> LauncherCalcResult? {
        // 先按字节数挡掉超长输入（O(1) 级别的开销），再按字符数精确判断。
        guard input.utf8.count <= maxInputLength * 4, input.count <= maxInputLength else { return nil }
        guard let tokens = LauncherCalcLexer.tokenize(input), !tokens.isEmpty else { return nil }
        let matchers: [([LauncherCalcToken], LauncherCalcContext) -> LauncherCalcResult?] = [
            LauncherCalcTimestamp.match,
            LauncherCalcBase.match,
            LauncherCalcDates.match,
            LauncherCalcTimeZones.match,
            LauncherCalcUnitConversion.match,
            LauncherCalcPercent.match,
            LauncherCalcArithmetic.match,
        ]
        for match in matchers {
            if let result = match(tokens, context) { return result }
        }
        return nil
    }
}
