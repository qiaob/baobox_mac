import Foundation
import os

private let storageLog = Logger(subsystem: "com.baobox.app", category: "storage")

/// 本地写盘失败（磁盘满、没权限、文件夹被删）的统一出口（#101）。以前剪贴板历史、专注状态、AI 账号写失败都是
/// `try?` 静默丢掉，用户不知道数据没存上。现在：每次失败记一条 fault 日志；同一份数据在这次运行里只提示用户一次
/// （经桌面宠物，宠物关着就是系统通知），免得每次保存都弹。下次保存照常重试，写成功不另行通知。
enum StorageWriteFailure {
    @MainActor private static var shown: Set<String> = []

    /// `what`：哪份数据（「剪贴板历史」，已本地化）；`reason`：系统给的原因。任何线程都可以调。
    static func report(_ what: String, reason: String) {
        storageLog.fault("write failed: \(what, privacy: .public): \(reason, privacy: .public)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { notifyOnce(what, reason: reason) }
        }
    }

    @MainActor
    private static func notifyOnce(_ what: String, reason: String) {
        guard shown.insert(what).inserted else { return }
        NotifyCenter.shared.post(Notice(
            source: "storage", level: .alert,
            title: L("storage.writeFailed.title \(what)"),
            body: reason + "\n" + L("storage.writeFailed.body"),
            dedupeKey: what,
            icon: "externaldrive.badge.exclamationmark"))
    }
}
