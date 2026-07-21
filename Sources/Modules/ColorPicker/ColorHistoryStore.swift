import AppKit

/// 取色格式：写入剪贴板与菜单/历史展示时的字符串风格。
enum ColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex
    case rgb
    case swiftui

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hex: return "Hex"
        case .rgb: return "RGB"
        case .swiftui: return "SwiftUI Color"
        }
    }
}

/// 取色相关的 UserDefaults 键与默认值（非 View 环境读取用）。
enum ColorPickerSettings {
    static let formatKey = "colorpicker.format"
    static let hexUppercaseKey = "colorpicker.hexUppercase"
    static let autoCopyKey = "colorpicker.autoCopy"

    static var format: ColorFormat {
        UserDefaults.standard.string(forKey: formatKey).flatMap(ColorFormat.init(rawValue:)) ?? .hex
    }

    static var hexUppercase: Bool {
        UserDefaults.standard.object(forKey: hexUppercaseKey) as? Bool ?? true
    }

    static var autoCopy: Bool {
        UserDefaults.standard.object(forKey: autoCopyKey) as? Bool ?? true
    }
}

/// 颜色格式化工具：规范 hex 存储 ↔ 各格式展示字符串。
enum ColorFormatter {
    /// 由 NSColor 生成规范存储用 hex（大写，形如 `#1AB3A6`）；颜色需已转 sRGB。
    static func canonicalHex(from color: NSColor) -> String {
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// 解析 `#RRGGBB` 为 0–255 分量。
    static func components(fromHex hex: String) -> (r: Int, g: Int, b: Int)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// 按格式生成展示/复制字符串。
    static func display(hex: String, format: ColorFormat, hexUppercase: Bool) -> String {
        guard let c = components(fromHex: hex) else { return hex }
        switch format {
        case .hex:
            let body = String(format: "%02X%02X%02X", c.r, c.g, c.b)
            return "#" + (hexUppercase ? body : body.lowercased())
        case .rgb:
            return "rgb(\(c.r), \(c.g), \(c.b))"
        case .swiftui:
            let rd = decimal(c.r), gd = decimal(c.g), bd = decimal(c.b)
            return "Color(red: \(rd), green: \(gd), blue: \(bd))"
        }
    }

    /// 一个 NSColor 色块，用于菜单项与历史展示；颜色取自 hex。
    static func color(fromHex hex: String) -> NSColor {
        guard let c = components(fromHex: hex) else { return .clear }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private static func decimal(_ v: Int) -> String {
        String(format: "%.3f", Double(v) / 255)
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }
}

/// 取色历史存储：内存 + 磁盘持久化（JSON），复用 ClipboardStore 的目录约定与 debounce 写盘。
@MainActor
final class ColorHistoryStore: ObservableObject {
    /// 新→旧排序。
    @Published private(set) var entries: [ColorEntry] = []

    static let maxEntries = 50
    static var storeFile: URL { ClipboardStore.baseDir.appendingPathComponent("colors.json") }

    private var saveWorkItem: DispatchWorkItem?

    init() {
        load()
    }

    // MARK: - 变更

    func add(hex: String) {
        // 与最近一条相同（忽略大小写）→ 仅刷新时间戳并移至最前。
        if let first = entries.first, first.hex.caseInsensitiveCompare(hex) == .orderedSame {
            entries[0] = ColorEntry(id: first.id, hex: hex, createdAt: Date())
            scheduleSave()
            return
        }
        entries.insert(ColorEntry(hex: hex), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    func clearAll() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - 持久化

    /// 立即落盘并取消待执行的防抖任务。
    /// 取色后 0.5s 内退出（取完色→复制→退出是很常见的流程）时，
    /// 不 flush 这条历史就永久丢了。
    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        try? FileManager.default.createDirectory(at: ClipboardStore.baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.storeFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ColorEntry].self, from: data) {
            entries = decoded
        }
    }
}

/// 单条取色记录（统一存 sRGB hex）。
struct ColorEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let hex: String
    let createdAt: Date

    init(id: UUID = UUID(), hex: String, createdAt: Date = Date()) {
        self.id = id
        self.hex = hex
        self.createdAt = createdAt
    }
}
