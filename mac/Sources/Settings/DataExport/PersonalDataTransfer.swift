import AppKit
import UniformTypeIdentifiers

/// 设置 → 通用 → 数据：导出 / 导入个人数据（docs/data-export/DESIGN.md）。
/// 从各模块抄数据、写回各模块都在主线程（全是内存里的东西）；编码、解码、读写文件在后台。
/// 文件格式与合并规则在 BaoboxBackup.swift（纯函数）。
@MainActor
enum PersonalDataTransfer {
    /// 导出：保存面板（面板上写着「文件不加密」）→ 后台编码写盘。写好了 `done` 收到一句结果，给设置页显示。
    static func export(done: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("data.export.fileName \(dayStamp(Date()))")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = L("data.export.plainWarning")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup = BackupMerge.export(local: localState(store: clipboardStore), exportedAt: Date(), app: appVersion)
        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            do {
                try BaoboxBackupCodec.encode(backup).write(to: url, options: .atomic)
            } catch {
                failure = error.localizedDescription
            }
            let reason = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let reason {
                        showAlert(title: L("data.export.failed"), message: reason)
                    } else {
                        done(L("data.export.done \(url.lastPathComponent)"))
                    }
                }
            }
        }
    }

    /// 导入：打开面板 → 后台读、解析 → 摘要（各类条数、新增条数、关键字冲突）→ 确认后合并。看不懂的文件什么都不改。
    static func importBackup(done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .utility).async {
            let outcome: ReadOutcome
            do {
                switch BaoboxBackupCodec.decode(try Data(contentsOf: url)) {
                case .success(let backup): outcome = .backup(backup)
                case .failure(let error): outcome = .rejected(error)
                }
            } catch {
                outcome = .cannotOpen(error.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { review(outcome, done: done) }
            }
        }
    }

    private enum ReadOutcome {
        case backup(BaoboxBackup)
        case rejected(BackupReadError)
        case cannotOpen(String)
    }

    private static func review(_ outcome: ReadOutcome, done: @escaping (String) -> Void) {
        let backup: BaoboxBackup
        switch outcome {
        case .backup(let value):
            backup = value
        case .rejected(.newerVersion):
            showAlert(title: L("data.import.unreadable"), message: L("data.import.newerVersion"))
            return
        case .rejected(.unreadable):
            showAlert(title: L("data.import.unreadable"), message: L("data.import.notBackup"))
            return
        case .cannotOpen(let reason):
            showAlert(title: L("data.import.cannotOpen"), message: reason)
            return
        }

        let store = clipboardStore
        let preview = BackupMerge.plan(backup, local: localState(store: store), now: Date())
        let alert = NSAlert()
        alert.informativeText = summary(preview)
        if preview.hasChanges {
            alert.messageText = L("data.import.confirmTitle")
            alert.addButton(withTitle: L("data.import.merge"))
            alert.addButton(withTitle: L("common.cancel"))
        } else {
            alert.messageText = L("data.import.nothingNew")
            alert.addButton(withTitle: L("common.ok"))
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, preview.hasChanges else { return }

        // 弹窗开着时专注的计时器照走（可能刚记下一轮）：按现在的样子重算一遍再写回，同一拍里做完。
        let plan = BackupMerge.plan(backup, local: localState(store: store), now: Date())
        store?.importSnippets(plan.newSnippets)
        if plan.dictationAdded > 0 { DictationController.shared.history.replace(with: plan.dictationMerged) }
        if !plan.newReminders.isEmpty { FocusHealthController.shared.importItems(plan.newReminders) }
        if plan.historyAdded > 0 { FocusHealthController.shared.importHistory(backup.focusHistory) }
        for (key, value) in plan.settingsToApply {
            UserDefaults.standard.set(value.storedObject, forKey: key)
        }
        done(L("data.import.done"))
    }

    /// 摘要：一类一行「片段 12 条（新 9 条）」，再加关键字冲突、听写上限的说明。
    private static func summary(_ plan: BackupImportPlan) -> String {
        var lines: [String] = []
        if plan.snippetsInFile > 0 {
            lines.append(L("data.import.snippets \(plan.snippetsInFile) \(plan.newSnippets.count)"))
        }
        if plan.dictationInFile > 0 {
            lines.append(L("data.import.dictation \(plan.dictationInFile) \(plan.dictationAdded)"))
        }
        if plan.remindersInFile > 0 {
            lines.append(L("data.import.reminders \(plan.remindersInFile) \(plan.newReminders.count)"))
        }
        if plan.historyInFile > 0 {
            lines.append(L("data.import.focusHistory \(plan.historyInFile) \(plan.historyAdded)"))
        }
        if !plan.settingsToApply.isEmpty {
            lines.append(L("data.import.settings \(plan.settingsToApply.count)"))
        }
        if lines.isEmpty { lines.append(L("data.import.emptyFile")) }

        var notes: [String] = []
        if !plan.keywordConflicts.isEmpty {
            let prefix = SnippetExpander.prefix
            var shown = plan.keywordConflicts.prefix(10).map { prefix + $0 }
            if plan.keywordConflicts.count > shown.count { shown.append("…") }
            notes.append(L("data.import.keywordConflicts \(shown.joined(separator: L("data.import.listSeparator")))"))
        }
        if plan.dictationCapped {
            notes.append(L("data.import.dictationCapped \(DictationSettings.historyLimit)"))
        }
        return ([lines.joined(separator: "\n")] + notes).joined(separator: "\n\n")
    }

    // MARK: - 各模块的数据

    /// 剪贴板模块持有的存储（片段就是里面的收藏条目）。模块没注册时是 nil：片段不导出也不导入。
    private static var clipboardStore: ClipboardStore? {
        AppDelegate.shared?.registry.tools.lazy.compactMap { ($0 as? ClipboardTool)?.store }.first
    }

    private static func localState(store: ClipboardStore?) -> BackupLocalState {
        BackupLocalState(
            clipboardItems: store?.items ?? [],
            dictation: DictationController.shared.history.records,
            dictationLimit: DictationSettings.historyLimit,
            reminders: FocusHealthController.shared.items,
            focusHistory: FocusHealthController.shared.history,
            focusSettings: BackupMerge.storedFocusSettings { UserDefaults.standard.object(forKey: $0) },
            snippetsAvailable: store != nil)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 文件名里的日期「2026-11-10」（本地日期）。
    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
