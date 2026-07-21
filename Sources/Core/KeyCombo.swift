import AppKit
import Carbon.HIToolbox

/// 一个全局快捷键的键位组合。
/// keyCode 为 Carbon/kVK 虚拟键码；carbonModifiers 为 Carbon 修饰键位掩码
/// （cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096）。
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    // Carbon 修饰键位（避免依赖 Carbon 常量的 Int 类型转换歧义，这里显式声明）
    static let cmd: UInt32 = 256
    static let shift: UInt32 = 512
    static let option: UInt32 = 2048
    static let control: UInt32 = 4096

    /// 展示用字符串：修饰键符号（按 ⌃⌥⇧⌘ 顺序）+ 键名。
    var display: String {
        var s = ""
        if carbonModifiers & KeyCombo.control != 0 { s += "⌃" }
        if carbonModifiers & KeyCombo.option != 0 { s += "⌥" }
        if carbonModifiers & KeyCombo.shift != 0 { s += "⇧" }
        if carbonModifiers & KeyCombo.cmd != 0 { s += "⌘" }
        s += KeyCombo.names[keyCode] ?? "key(\(keyCode))"
        return s
    }

    /// 从 keyDown 事件构造。至少需含一个修饰键才有效（F 键除外）。
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= KeyCombo.cmd }
        if flags.contains(.shift) { carbon |= KeyCombo.shift }
        if flags.contains(.option) { carbon |= KeyCombo.option }
        if flags.contains(.control) { carbon |= KeyCombo.control }
        let code = UInt32(event.keyCode)
        if carbon == 0 && !KeyCombo.functionKeyCodes.contains(code) { return nil }
        self.keyCode = code
        self.carbonModifiers = carbon
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 供 NSMenuItem 显示：返回 (keyEquivalent 字符, 修饰键 flags)。
    /// 仅覆盖字母/数字/回车/空格等能表达为 keyEquivalent 的键，其余返回 nil。
    var keyEquivalent: (String, NSEvent.ModifierFlags)? {
        let equiv: String
        if let name = KeyCombo.names[keyCode], name.count == 1,
           let scalar = name.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            equiv = name.lowercased()
        } else if keyCode == 0x24 || keyCode == 0x4C {
            equiv = "\r"
        } else if keyCode == 0x31 {
            equiv = " "
        } else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & KeyCombo.cmd != 0 { flags.insert(.command) }
        if carbonModifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
        if carbonModifiers & KeyCombo.option != 0 { flags.insert(.option) }
        if carbonModifiers & KeyCombo.control != 0 { flags.insert(.control) }
        return (equiv, flags)
    }

    /// F1–F12 的 kVK 键码，用于允许"无修饰键"的合法快捷键。
    static let functionKeyCodes: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F
    ]

    /// kVK 键码 → 展示键名（硬编码常用键）。
    static let names: [UInt32: String] = [
        // 字母
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        // 数字
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        // 符号
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";",
        0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",
        // 特殊键
        0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x31: L("keycombo.space"), 0x33: "⌫",
        0x35: "⎋", 0x75: "⌦",
        // 方向键
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        // 功能键
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12"
    ]
}
