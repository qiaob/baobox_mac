import Foundation

// 快速切换面板（Claude Code 助手 / Codex 助手各一个）共用的纯逻辑（#109，docs/codex-assistant/DEDUPE.md §4.3）：
// 面板认哪些键、列表怎么过滤、选中项怎么移动。只依赖 Foundation，进 BaoboxTests；
// 按键的含义（⏎ 是续接还是打开文件）留在各模块的控制器里。

/// 面板认的键（Carbon 虚拟键码，与剪贴板面板同一套）。只有 C 与 ⏎ 看 ⌘，其余键不看修饰键（同原来）。
enum QuickSwitchKey: Equatable {
    case up, down, left, right, tab, escape
    /// Return（0x24）/ 小键盘 Enter（0x4C）；`command` = 按着 ⌘。
    case enter(command: Bool)
    /// ⌘C（C = 0x08）。不带 ⌘ 的 C 不算 —— 裸字符留给搜索框。
    case copy

    /// 不认识的键返回 nil（交给搜索框）。
    init?(keyCode: UInt16, command: Bool) {
        switch keyCode {
        case 0x7E: self = .up
        case 0x7D: self = .down
        case 0x7B: self = .left
        case 0x7C: self = .right
        case 0x30: self = .tab
        case 0x35: self = .escape
        case 0x24, 0x4C: self = .enter(command: command)
        case 0x08 where command: self = .copy
        default: return nil
        }
    }
}

/// 列表的过滤与选中。选中项用下标表示（面板里的 `selectedIndex`）。
enum QuickSwitchSelection {

    /// 空查询原样返回；否则留下任一字段 `lowercased()` 后包含 `query.lowercased()` 的项，顺序不变。
    /// 查询不 trim（同原来：首尾的空格也算要匹配的字符）。
    static func filter<T>(_ items: [T], query: String, fields: [KeyPath<T, String>]) -> [T] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { item in
            fields.contains { item[keyPath: $0].lowercased().contains(q) }
        }
    }

    /// ↑↓：移动 `delta` 后夹在 0…count-1；count 为 0 时不动。
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return index }
        return min(max(0, index + delta), count - 1)
    }

    /// 列表变短后夹紧选中项：count 为 0 时归零，越过末项时落到末项，其余不动（负数也不动，同原来）。
    static func clamped(_ index: Int, count: Int) -> Int {
        if count == 0 { return 0 }
        if index >= count { return count - 1 }
        return index
    }

    /// 首尾循环地移动（Claude 文件模式的类别筛选）；count 为 0 时返回 0。
    static func cycled(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// 下标处的元素；越界（含负数）返回 nil。
    static func element<T>(_ list: [T], at index: Int) -> T? {
        list.indices.contains(index) ? list[index] : nil
    }
}
