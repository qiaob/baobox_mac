import Foundation

// 二次确认（docs/launcher/TECH_DESIGN.md §4「按两次回车」，第 10 步）：要按两次 ⏎ 的行 —— 模块声明的 `LauncherCommand.destructive`
// 命令、「在终端里运行」、取消一条提醒 —— 第一次 ⏎ 不执行，那一行的标题换成「再按一次回车<做什么>：<对象>」，再按才执行。
// 选中移开、输入改了、面板收起就复位；⌘1–⌘9、单击这样的行同样只算第一次。
// 这里是纯值（哪一行在等、对象怎么截断），进 BaoboxTests；换标题在面板模型（`LauncherPanelModel`），按键在控制器。

/// 一行要按两次 ⏎：第一次之后标题写什么。
struct LauncherConfirmation: Equatable, Sendable {
    /// 做什么（「运行」「取消提醒」，已本地化）；nil = 只写对象（模块声明的 destructive 命令：对象就是命令名）。
    let verb: String?
    /// 对什么：完整的命令、提醒的时刻和事由。标题里放不下时中间截断（`LauncherConfirmText.object`）。
    let object: String
    /// 完整显示（第 10 步验证后定，只给「在终端里运行」）：确认时显示的必须是将要执行的全部内容 —— 上膛后那一行变高，
    /// 对象用等宽字按 `LauncherConfirmText.commandColumns` 硬换行、完整显示（`commandLines`，最多 6 行）；false = 一行、中间截断。
    var showsWholeObject = false
}

/// 这一下是从哪来的：键盘（⏎、⌘N）还是鼠标单击。
enum LauncherConfirmSource: Equatable, Sendable {
    case key
    case click
}

/// 对一行按了一下之后怎么办。
enum LauncherConfirmOutcome: Equatable, Sendable {
    /// 执行（它已经在等第二次了，复位）。
    case run
    /// 这一下只是让它等着（之前在等的别的行不等了）。
    case armed
    /// 什么都不做：上膛后双击间隔之内的又一次点击（双击不会一口气确认，验证后定）。
    case ignored
}

/// 哪一行在等第二次 ⏎。
struct LauncherConfirmState: Equatable, Sendable {
    /// 在等第二次 ⏎ 的那一行（行 id）；nil = 没有。
    private(set) var armedID: String?
    /// 上膛的时刻（开机以来的秒数，`ProcessInfo.systemUptime`）。
    private(set) var armedAt: TimeInterval = 0

    /// 对 `id` 这一行按了一下（⏎、⌘N、单击）。键盘的两次分开的按键不设间隔（两次独立按键就是有意的）；
    /// 鼠标点击在上膛后 `doubleClickInterval` 之内的不算确认（`.ignored`）—— 双击一下不能一口气确认。
    /// 按键的自动重复不在这里：控制器直接丢掉（对所有行）。
    mutating func press(_ id: String, source: LauncherConfirmSource = .key, now: TimeInterval = 0,
                        doubleClickInterval: TimeInterval = 0) -> LauncherConfirmOutcome {
        if armedID == id {
            if source == .click, now - armedAt < doubleClickInterval { return .ignored }
            armedID = nil
            return .run
        }
        armedID = id
        armedAt = now
        return .armed
    }

    /// 选中的行换成了 `id`（↑ ↓、悬停、列表刷新后）：不是在等的那一行就复位。返回复位了的行 id（没复位为 nil）。
    mutating func selectionChanged(to id: String?) -> String? {
        guard let armedID, armedID != id else { return nil }
        self.armedID = nil
        return armedID
    }

    /// 输入改了、面板收起：复位。返回复位了的行 id（本来就没有在等的为 nil）。
    mutating func reset() -> String? {
        defer { armedID = nil }
        return armedID
    }
}

enum LauncherConfirmText {
    /// 完整显示时每行最多这么宽（ASCII 字符算 1，其余算 2）。视图（`LauncherResultRow`）用 12 号等宽字画这些行，
    /// 12 号的等宽字一个 ASCII 字符约 7.2 点宽，64 个约 461 点，放得进标题那一栏（约 520 点，右边还有来源小字和 ⌘1）。
    static let commandColumns = 64
    /// 完整显示最多几行；放不下的命令不出「在终端里运行」（太长的命令没法靠眼睛确认，用户自己贴进终端）。
    static let maxCommandLines = 6

    /// 完整显示时的行：按 `columns` 宽硬换行（不按词断开、一个字符都不省，空格也照原样留着 —— 看到的就是要跑的），
    /// 超过 `maxLines` 行为 nil。空文字为 nil。宽度算法同 `width`。调用方保证文字里没有换行和控制字符（「像命令」不认这些）。
    static func commandLines(_ text: String, columns: Int = commandColumns, maxLines: Int = maxCommandLines) -> [String]? {
        guard !text.isEmpty, columns >= 2, maxLines >= 1 else { return nil }
        var lines: [String] = []
        var line = ""
        var lineWidth = 0
        for character in text {
            let w = width(character)
            if lineWidth + w > columns {
                lines.append(line)
                guard lines.count < maxLines else { return nil }
                line = ""
                lineWidth = 0
            }
            line.append(character)
            lineWidth += w
        }
        lines.append(line)
        return lines
    }

    /// 标题里的对象最多占这么宽（ASCII 字符算 1，其余算 2）：面板 680 宽、标题 14 号字，前面还有「再按一次回车运行：」，
    /// 右边有来源小字和 ⌘N —— 这么宽的对象正好放得下（英文约 48 个字母，中文约 24 个字）。
    static let maxObjectWidth = 48

    /// 标题里的对象：压成一行；超出 `maxWidth`（ASCII 字符算 1、其余算 2 —— 汉字大约是英文字母的两倍宽）时中间截断成
    /// 「开头…结尾」，开头和结尾都看得到（省略号算 1）。
    static func object(_ text: String, maxWidth: Int = maxObjectWidth) -> String {
        let line = LauncherConversions.singleLine(text, maxLength: Int.max)
        let limit = max(3, maxWidth)
        let characters = Array(line)
        let widths = characters.map(width)
        guard widths.reduce(0, +) > limit else { return line }
        // 省略号占 1；剩下的开头多半、结尾少半。
        let budget = limit - 1
        let headBudget = (budget + 1) / 2
        let tailBudget = budget - headBudget
        var head = 0, headWidth = 0
        while head < characters.count, headWidth + widths[head] <= headBudget {
            headWidth += widths[head]
            head += 1
        }
        var tail = characters.count, tailWidth = 0
        while tail > head, tailWidth + widths[tail - 1] <= tailBudget {
            tailWidth += widths[tail - 1]
            tail -= 1
        }
        let start = String(characters[..<head]).trimmingCharacters(in: .whitespaces)
        let end = String(characters[tail...]).trimmingCharacters(in: .whitespaces)
        return start + "…" + end
    }

    /// 一个字符占多宽：ASCII 算 1，其余（汉字、全角标点、emoji）算 2。
    static func width(_ character: Character) -> Int {
        character.isASCII ? 1 : 2
    }
}
