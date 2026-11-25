import Foundation

// 粘贴 / 放进来的原文（docs/launcher/TECH_DESIGN.md §5.4）：快速入口的输入框只有一行，粘进来的换行会被换成空格，
// 交给翻译、总结、存为片段时段落就没了；开头碰巧像来源前缀的（「c is a language」）也不该被拆成前缀。所以放进来那一下
// （⌘V、拖放、「选中的 / 刚复制的」）记下原文（`LauncherPlacedText`），输入框里的文字和原文「把空白归一后」还一样时：
// 按字面处理、不拆前缀，带换行的拿原文代替输入框里的文字；用户一改动就作废。
// 归一只在放进来那一刻对原文做一次；之后核对只看输入框这一边、先比长度（大段文字每次查询都归一一遍太慢）。
// 纯函数、只依赖 Foundation，进 BaoboxTests。

enum LauncherPastedText {
    /// 值得记下的原文：含换行（单行的原文和输入框里的文字本来就一样，不用记）。
    static func isWorthKeeping(_ pasted: String) -> Bool {
        pasted.contains(where: \.isNewline)
    }

    /// 空白归一：连续的空白（空格、制表符、换行，含 `\r\n`）换成一个空格，去掉首尾空白。
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }

    /// 输入框里的文字是不是还是这段粘贴（把原文的换行当空格、两边空白归一后相等）。
    static func matches(original: String, fieldText: String) -> Bool {
        normalized(original) == normalized(fieldText)
    }

    /// 这次该用的原文：记着原文、原文含换行、输入框里的文字还是它 → 原文（去首尾空白）；否则 nil（用输入框里的文字）。
    static func original(_ pasted: String?, matching fieldText: String) -> String? {
        guard let pasted, isWorthKeeping(pasted), matches(original: pasted, fieldText: fieldText) else { return nil }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 放进来的一段原文（⌘V 粘贴、拖放、「选中的 / 刚复制的」放进输入框）。放进来那一刻把要用的都算好（归一后的原文、建议用的原文），
/// 之后控制器在输入框每次变化时核对一次（`matches`）：还是它就交给查询（按字面处理、不拆前缀），不是了就丢掉。
/// 查询本身不再归一任何东西（`LauncherQuery.parse(_:literal:)`、`LauncherSuggestionPolicy.plan(placed:)` 只读这里算好的）。
/// 判断规则同 `LauncherPastedText.matches`（空白归一后相等），那个函数留着当规则的定义，单元测试拿它对照。
struct LauncherPlacedText: Equatable, Sendable {
    /// 原文。
    let original: String
    /// 归一后的原文（放进来时算一次）。
    let normalized: String
    /// 归一后的原文的 UTF-8 长度：核对时先比它。
    private let normalizedUTF8Count: Int
    /// 建议行用的原文：带换行的（`LauncherPastedText.isWorthKeeping`）才有，去首尾空白；单行的为 nil —— 和输入框里的一样，不用换。
    let suggestionText: String?

    /// 全是空白（没东西可用）时为 nil。
    init?(_ original: String) {
        let normalized = LauncherPastedText.normalized(original)
        guard !normalized.isEmpty else { return nil }
        self.original = original
        self.normalized = normalized
        normalizedUTF8Count = normalized.utf8.count
        if LauncherPastedText.isWorthKeeping(original) {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestionText = trimmed.isEmpty ? nil : trimmed
        } else {
            suggestionText = nil
        }
    }

    /// 输入框里的文字还是它（空白归一后相等，同 `LauncherPastedText.matches`）。
    /// - 先比长度：归一不会让 UTF-8 变长（一段空白换成一个空格或去掉，别的字照抄），输入框比归一后的原文还短就一定不是它，不用看内容
    ///   （删了一个字的情况）。
    /// - 否则边走边归一输入框这一边、和放进来时存好的逐字比，第一处不同就停：不再归一原文，也不为输入框另建一个字符串。
    func matches(fieldText: String) -> Bool {
        guard fieldText.utf8.count >= normalizedUTF8Count else { return false }
        var expected = normalized.makeIterator()
        var pendingSpace = false
        var started = false
        for character in fieldText {
            if character.isWhitespace {
                pendingSpace = started
                continue
            }
            if pendingSpace {
                guard expected.next() == " " else { return false }
                pendingSpace = false
            }
            guard expected.next() == character else { return false }
            started = true
        }
        return expected.next() == nil
    }

    /// 输入框里的文字还是它时是自己，否则 nil（控制器在输入框变化时这样核对）。
    func still(in fieldText: String) -> LauncherPlacedText? {
        matches(fieldText: fieldText) ? self : nil
    }
}
