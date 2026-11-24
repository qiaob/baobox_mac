import Foundation

// 粘贴进来的原文（docs/launcher/TECH_DESIGN.md §5.4）：快速入口的输入框只有一行，粘进来的换行会被换成空格，
// 交给翻译、总结、存为片段时段落就没了。所以按 ⌘V 那一下记下剪贴板里的原文（带换行的才记），
// 之后每次用之前核对：输入框里的文字和原文「把空白归一后」还一样，才拿原文代替输入框里的文字；用户一改动就作废。
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
