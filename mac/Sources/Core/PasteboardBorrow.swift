import AppKit

/// 借用系统剪贴板：取一次文字（让前台 App 把选区拷进剪贴板 → 读出 → 立即还原原内容），
/// 或粘一次文字（写入 → ⌘V → 还原，见 `paste`）。
///
/// 划词翻译在辅助功能读不到选区时用（很多终端、部分 Electron / 自绘界面的 App），
/// 见 docs/selection-translate/DESIGN.md §2；语音听写写不进输入框时借它粘贴，见 docs/dictation/TECH_DESIGN.md §5。
/// 借用期间以及还原本身产生的剪贴板变更都不是用户的复制：剪贴板历史据 `isActive` / `settledChangeCount`
/// 跳过，不入库。只在主线程使用。
@MainActor
enum PasteboardBorrow {
    enum Result {
        case text(String)
        /// 剪贴板没变：App 没拷任何东西（没有选区，或「拷贝」没触发成功）。
        case unchanged
        /// 拷到了，但不是一段文字（文件、图片…）。
        case notText
    }

    /// 借用开始前同步发出。剪贴板监听借此先轮询一次，把「借用前用户刚复制、还没轮询到」的
    /// 那条照常入库，免得被借用后的整体跳过一并吞掉。
    static let willBeginNotification = Notification.Name("com.baobox.app.pasteboardBorrow.willBegin")

    /// 正在借用：拷贝 → 读取 → 还原 之间。
    private(set) static var isActive = false
    /// 最近一次借用结束时的 changeCount。监听看到的正好是它 = 借用之后再没有新的复制。
    private(set) static var settledChangeCount: Int?

    /// 剪贴板里是不是密码管理器标了敏感的内容。借用会改 changeCount，密码管理器的
    /// 「N 秒后自动清除」据此认定用户已复制了别的而不再清除 —— 自动路径遇到它就别借。
    static var holdsConcealedContent: Bool {
        NSPasteboard.general.types?.contains(concealedType) ?? false
    }

    /// 让前台 App 执行一次拷贝的办法（按它的「拷贝」菜单项 / 合成 ⌘C），返回 false = 没触发成功。
    typealias Trigger = @MainActor () -> Bool

    /// 依次试 `triggers`（先按菜单项，剪贴板没动静再合成 ⌘C），每个最多等 ~0.3 秒剪贴板变化。
    /// 返回结果，以及起作用的是第几个（都没起作用时为最后一个）。带文件的结果一律不收，
    /// `allowImages` 为 false 时带图片的也不收（设计软件拷图层、Finder 拷文件都会顺带一段文字）。
    /// 剪贴板变过才还原，没变不碰。
    static func copy(allowImages: Bool, triggers: [Trigger]) async -> (result: Result, trigger: Int) {
        guard !isActive, !triggers.isEmpty else { return (.unchanged, 0) }
        NotificationCenter.default.post(name: willBeginNotification, object: nil)
        isActive = true
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotItems(of: pasteboard)
        let changeBefore = pasteboard.changeCount
        // 等待放进独立任务：调用方即使被取消也要等到底、把剪贴板还原，不能半路撒手。
        return await Task { @MainActor () -> (result: Result, trigger: Int) in
            defer { finish() }
            for (index, trigger) in triggers.enumerated() {
                guard trigger() else { continue }
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    guard pasteboard.changeCount != changeBefore else { continue }
                    let result = await read(pasteboard, allowImages: allowImages)
                    restore(snapshot, to: pasteboard)
                    return (result, index)
                }
            }
            return (.unchanged, triggers.count - 1)
        }.value
    }

    /// 借剪贴板把一段文字粘进前台 App（语音听写插入的第二档，docs/dictation/TECH_DESIGN.md §5）：
    /// 快照全部剪贴板条目 → 写入文字 → 等物理修饰键松开（最多 0.5 秒）→ 合成 ⌘V → 0.35 秒后还原快照。
    /// 整个过程 `isActive`：写入与还原两次变更剪贴板历史都跳过，不入库。
    /// 已在借用中（划词取词、上一次粘贴还没还原）返回 false，什么也不做。需要辅助功能权限（合成按键）。
    static func paste(_ text: String) async -> Bool {
        guard !isActive else { return false }
        NotificationCenter.default.post(name: willBeginNotification, object: nil)
        isActive = true
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotItems(of: pasteboard)
        // 同 `copy`：放进独立任务，调用方被取消也要等到还原完。
        return await Task { @MainActor () -> Bool in
            defer { finish() }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // 告诉别家剪贴板管理器「临时内容，别存」（nspasteboard.org 约定）。
            pasteboard.setData(Data(), forType: transientType)
            // 快捷键刚松开时 ⌘⌥⇧ 可能还按着，叠加到合成的 ⌘V 上就成了别的命令（同 PasteService）。
            let deadline = Date().addingTimeInterval(0.5)
            let held: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
            while !NSEvent.modifierFlags.intersection(held).isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            postCommandV()
            // 目标 App 读完剪贴板再还原，太早还原会粘出旧内容。
            try? await Task.sleep(nanoseconds: 350_000_000)
            restore(snapshot, to: pasteboard)
            return true
        }.value
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 0x09 = kVK_ANSI_V（Carbon 虚拟键码，避免为一个常量引整个 Carbon 头）。
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func finish() {
        isActive = false
        settledChangeCount = NSPasteboard.general.changeCount
    }

    /// 剪贴板刚变时 App 可能还没写完（先清空、再写入），没读到文字就再等两拍。
    private static func read(_ pasteboard: NSPasteboard, allowImages: Bool) async -> Result {
        for attempt in 0..<3 {
            let types = Set(pasteboard.types ?? [])
            if types.contains(.fileURL) || types.contains(legacyFilenamesType) { return .notText }
            if !allowImages, !types.isDisjoint(with: imageTypes) { return .notText }
            if let text = pasteboard.string(forType: .string) { return .text(text) }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 30_000_000) }
        }
        return .notText
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .tiff, .png, .pdf, NSPasteboard.PasteboardType("public.jpeg"),
    ]

    private static func snapshotItems(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
