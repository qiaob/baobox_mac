import Foundation

// 快速入口「输入即出」的结果行（docs/launcher/TECH_DESIGN.md §6.3、§7）：计算结果、文本识别。
// 它们不经过排序，由引擎固定放在最前（计算结果第一，文本识别其次），不记使用记录。
// 这里是什么时候算、识别结果怎么换成行的规则，纯值、只依赖 Foundation，进 BaoboxTests；
// 调计算引擎、调识别器（`Core/TextTools/`，带本地化）在 App 侧（`Providers/CalculatorProvider.swift`、`TextFormatProvider.swift`）。

enum LauncherInstantPolicy {
    /// 文本识别至少要这么多个字符（太短的输入几乎都是在搜东西）。
    static let textRecognitionMinimumLength = 4

    /// 算不算：没打来源前缀（`a `、`c `、`> ` 都不算）、查询词不为空。
    static func runsCalculator(_ query: LauncherQuery) -> Bool {
        query.isUnscoped && !query.text.isEmpty
    }

    /// 识不识别：没打来源前缀、查询词不少于 4 个字符、而且没有计算结果（两者都能认的输入计算优先；
    /// 计算引擎已经不处理裸时间戳，所以 `1700000000` 走这里）。
    static func runsTextRecognition(_ query: LauncherQuery, hasCalculation: Bool) -> Bool {
        query.isUnscoped && !hasCalculation && query.text.count >= textRecognitionMinimumLength
    }
}

/// 识别器表格里的一行（时间换算表、URL 的参数、JWT 的时间声明），App 侧从 `FormatRow` 换过来。
struct LauncherConversionTableRow: Equatable, Sendable {
    let label: String
    let value: String
    /// nil = 这一行没法复制（「3 小时前」），不出。
    let copyValue: String?
}

/// 识别器的一个转换动作（Base64 解码、JSON 格式化…），App 侧从 `FormatAction` 的 transform 换过来。
struct LauncherConversionTransform {
    let title: String
    /// 返回 nil = 这次转换不适用。
    let run: (String) -> String?
}

/// 文本识别出的一行结果。
struct LauncherConversion: Equatable, Sendable {
    /// 显示的值：压成一行、截断（复制的是完整的 `copyText`）。
    let title: String
    /// 右侧小字：「徽章 · 行标签」，如「Unix 时间戳（秒）· 本地时间」「Base64 · 解码」。
    let detail: String
    /// ⏎ 复制、⌘⏎ 插入的完整值。
    let copyText: String
}

enum LauncherConversions {
    /// 一个识别结果最多出几行。
    static let maxRows = 3
    /// 显示的值最多这么多个字符（一行放不下的部分界面自己截断，这里只防整段大 JSON 交给排版）。
    static let maxTitleLength = 300

    /// 识别结果 → 结果行：
    /// 1. 表格里有复制值的行，最多 3 行：标题 = 值，右侧 =「徽章 · 行标签」，复制 = 复制值。
    /// 2. 表格里一行能复制的都没有（Base64、JSON、URL 编码…）：按顺序找第一个结果不为空、也和输入不一样的转换，
    ///    出一行：标题 = 转换结果，右侧 =「徽章 · 动作名」，复制 = 完整结果。
    /// 3. 都没有：不出。
    /// - Parameter input: 识别器看到的输入（去过首尾空白），转换就在它上面做。
    static func rows(input: String, badge: String, table: [LauncherConversionTableRow],
                     transforms: [LauncherConversionTransform]) -> [LauncherConversion] {
        let copyable = table.compactMap { row -> LauncherConversion? in
            guard let copy = row.copyValue, !copy.isEmpty else { return nil }
            return LauncherConversion(title: singleLine(row.value.isEmpty ? copy : row.value),
                                      detail: detail(badge: badge, label: row.label), copyText: copy)
        }
        if !copyable.isEmpty {
            return Array(copyable.prefix(maxRows))
        }
        for transform in transforms {
            guard let result = transform.run(input), !result.isEmpty, result != input else { continue }
            return [LauncherConversion(title: singleLine(result), detail: detail(badge: badge, label: transform.title),
                                       copyText: result)]
        }
        return []
    }

    /// 右侧小字里的标签最多这么多个字符（URL 参数名、请求头名可能很长；右侧小字不截断，太长会把值挤没）。
    static let maxLabelLength = 24

    /// 「徽章 · 标签」；标签为空时只有徽章，过长时截断加省略号。
    static func detail(badge: String, label: String) -> String {
        var label = singleLine(label)
        guard !label.isEmpty else { return badge }
        if label.count > maxLabelLength {
            label = String(label.prefix(maxLabelLength - 1)) + "…"
        }
        return "\(badge) · \(label)"
    }

    /// 压成一行：连续的空白（含换行、制表符）换成一个空格，去首尾空白，最多 `maxLength` 个字符。
    static func singleLine(_ text: String, maxLength: Int = maxTitleLength) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, maxLength))
        var count = 0
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                guard count < maxLength else { break }
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            guard count < maxLength else { break }
            result.append(character)
            count += 1
        }
        return result
    }
}
