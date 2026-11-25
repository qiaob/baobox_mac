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

    #if DEBUG
    /// 只在测试里看：`normalized` 被调了几次（守住「每次查询不再归一放进来的原文」，不靠计时）。主线程 / 测试线程上用。
    static var normalizedCallCount = 0
    #endif

    /// 空白归一：连续的空白（空格、制表符、换行，含 `\r\n`）换成一个空格，去掉首尾空白。
    static func normalized(_ text: String) -> String {
        #if DEBUG
        normalizedCallCount += 1
        #endif
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
/// 判断规则按 `LauncherPastedText.matches`（空白归一后相等），但**只会更严**：那边说不等的这里一定不等；反过来，同一个字的
/// 合成 / 分解两种编码（`é` 和 `e` + 组合重音）、空白后面紧跟组合字符这类文字，那边按「规范等价」算相等，这里逐字比、先比 UTF-8
/// 长度会判不等。后果只是这类文字放进来后按手打的规则处理（拆前缀、带换行的不用原文），不会把手打的当成放进来的。
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

    /// 一次核对的结果，和读了输入框几个字（单元测试守「短了不看内容」「第一处不同就停」用，不靠计时）。
    struct Check: Equatable, Sendable {
        let matches: Bool
        let charactersRead: Int
    }

    /// 输入框里的文字还是它（空白归一后相等；比 `LauncherPastedText.matches` 只严不松，见类型说明）。
    func matches(fieldText: String) -> Bool {
        check(fieldText: fieldText).matches
    }

    /// 核对：
    /// - 先比长度：归一不会让 UTF-8 变长（一段空白换成一个空格或去掉，别的字照抄），输入框比归一后的原文还短就一定不是它，不看内容
    ///   （删了一个字的情况）。
    /// - 否则边走边归一输入框这一边、和放进来时存好的逐字比，第一处不同就停：不再归一原文，也不为输入框另建一个字符串。
    func check(fieldText: String) -> Check {
        guard fieldText.utf8.count >= normalizedUTF8Count else { return Check(matches: false, charactersRead: 0) }
        var expected = normalized.makeIterator()
        var pendingSpace = false
        var started = false
        var read = 0
        for character in fieldText {
            read += 1
            if character.isWhitespace {
                pendingSpace = started
                continue
            }
            if pendingSpace {
                guard expected.next() == " " else { return Check(matches: false, charactersRead: read) }
                pendingSpace = false
            }
            guard expected.next() == character else { return Check(matches: false, charactersRead: read) }
            started = true
        }
        return Check(matches: expected.next() == nil, charactersRead: read)
    }

    /// 输入框里的文字还是它时是自己，否则 nil（控制器在输入框变化时这样核对）。
    func still(in fieldText: String) -> LauncherPlacedText? {
        matches(fieldText: fieldText) ? self : nil
    }
}

/// 放进来的原文在一次面板会话里的状态（控制器持有一份）：放进来那一下先记下（`begin`，还没核对）→ 改输入框 →
/// 输入框变了就核对（`fieldChanged`）→ 改完以后不管有没有文字变化的回调、改没改成都落定一次（`settle`）。
/// `current` 有值 = 输入框此刻还是它（引擎据此按字面处理、不再核对）。
/// 为什么要「待定 → 落定」两步：⌘V 时先记下剪贴板里的文字、再让输入框粘贴；输入框不在编辑时粘贴什么都不做、也没有回调，
/// 只记不核对的话，记下的原文会留着，而输入框里还是手打的 `f readme` —— 下一次查询就被当成放进来的、不拆前缀了。
struct LauncherPlacement: Equatable, Sendable {
    /// 核对过、此刻还算数的原文。
    private(set) var current: LauncherPlacedText?
    /// 刚记下、还没核对的原文（放进来那一下，输入框还没换）。
    private var pending: LauncherPlacedText?

    init() {}

    /// 放进来：记下原文（全是空白的不记），等输入框换完再核对。
    mutating func begin(_ text: String?) {
        pending = text.flatMap(LauncherPlacedText.init)
    }

    /// 输入框换成了 `fieldText`：正在放进来的那段优先，否则核对原来那段；对不上就作废，之后再打字什么都不核对。
    mutating func fieldChanged(to fieldText: String) {
        let candidate = pending ?? current
        pending = nil
        current = candidate?.still(in: fieldText)
    }

    /// 放进来的那一下改完输入框之后调，一定要调（`LauncherController.place`）：还没核对的（没有文字变化的回调 ——
    /// 输入框不在编辑、粘贴没成，或贴的正好是框里原来的字）在这里对着此刻的输入框核对。对不上就作废；输入框没变时原来那段照旧
    /// （它就是对着这段文字核对过的）。返回 `current` 变没变（变了要再查一次）。
    mutating func settle(fieldText: String) -> Bool {
        guard let pending else { return false }
        self.pending = nil
        let before = current
        current = pending.still(in: fieldText) ?? before
        return current != before
    }

    /// 输入框换成了别的东西（文件路径、挂上图片、过了 60 秒清空）：都丢掉。
    mutating func clear() {
        current = nil
        pending = nil
    }
}
