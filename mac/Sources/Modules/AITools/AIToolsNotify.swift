import Foundation
import UserNotifications

/// Codex 助手 —— Codex 完成通知：notify 程序生成 + 事件文件监听 + 系统通知。
///
/// 机制（DESIGN 第 2 节）：把 `codex-notify.sh` 写进支持目录并 chmod 0755，再把其路径装进
/// `~/.codex/config.toml` 的 `notify` 键。Codex 每个回合结束会调用该程序，并把事件 JSON
/// 作为**最后一个参数**传入；脚本取末位参数追加到独立 events 文件。Baobox 用
/// `DispatchSourceFileSystemObject` 监听该文件增量，回合完成（agent-turn-complete）时发系统通知。
///
/// 模式照 `ClaudeLiveStatus`，但**独立实现、独立 events 文件**，避免两模块耦合。
/// 通知走 UNUserNotificationCenter，未签名 dev 包可能失败，全部判空不 crash。
///
/// 用户可见文案（L key）：
///   - aitools.notify.turnComplete.title      zh:「Codex 回合完成」   en:「Codex turn complete」
///   - aitools.notify.turnComplete.titleProject %@  zh:「Codex 完成 · %@」 en:「Codex done · %@」

// MARK: - 通知设置（UserDefaults 键）

enum AIToolsNotifierSettings {
    static let soundKey = "aitools.notificationSound"
    static let budgetAlertKey = "aitools.budgetAlertEnabled"

    /// 提示音（默认开）。
    static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }

    /// 额度 80% 提醒（默认开；仅在设置了预算时生效）。
    static var budgetAlertEnabled: Bool {
        UserDefaults.standard.object(forKey: budgetAlertKey) as? Bool ?? true
    }
}

// MARK: - events 文件增量监听器（非 @MainActor，独占后台串行队列）

/// 监听单个文件的增量写入，把新行回调出去。offset 只在自有串行队列上访问，无需锁。
/// 与 `ClaudeEventWatcher` 平行独立，避免跨模块耦合。
final class CodexEventWatcher {
    private let url: URL
    private var offset: UInt64
    private let onLines: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.baobox.aitools.eventwatcher")
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, startOffset: UInt64, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = open(self.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: self.queue
            )
            src.setEventHandler { [weak self] in
                self?.drain()
            }
            src.setCancelHandler {
                close(fd)
            }
            self.source = src
            src.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            if end < offset { offset = 0 }   // 文件被截断 → 偏移复位
            guard end > offset else { return }
            try handle.seek(toOffset: offset)
            let data = (try handle.read(upToCount: Int(end - offset))) ?? Data()
            offset = end
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if !lines.isEmpty { onLines(lines) }
        } catch {
            return
        }
    }
}

// MARK: - Codex 完成通知管理器（@MainActor 单例）

@MainActor
final class CodexNotify: ObservableObject {
    static let shared = CodexNotify()

    /// notify 是否已装入 config.toml（内存缓存，供菜单零 IO 读取与设置页联动）。
    @Published private(set) var isInstalled = false
    /// config.toml 的 notify 键当前不可安全编辑（多行 / 非字符串数组）时置真，UI 据此置灰。
    @Published private(set) var isUneditable = false

    private var watcher: CodexEventWatcher?

    /// 通知摘要截断长度。
    private static let summaryClip = 60
    /// events 文件超过此大小则截断保尾。后台读取，显式 nonisolated。
    nonisolated private static let maxEventBytes = 2 * 1_024 * 1_024
    nonisolated private static let keepTailLines = 500

    private init() {}

    // MARK: 路径

    var scriptURL: URL {
        CodexEnv.supportDir.appendingPathComponent("codex-notify.sh")
    }

    var eventsURL: URL {
        CodexEnv.supportDir.appendingPathComponent("codex-events.jsonl")
    }

    // MARK: 状态

    /// 后台读 config.toml 判定 notify 是否指向本模块脚本，回主线程刷新缓存。
    func refreshState() {
        let scriptPath = scriptURL.path
        DispatchQueue.global(qos: .utility).async {
            let value = CodexEnv.notify()
            var installed = false
            var uneditable = false
            switch value {
            case .array(let programs): installed = programs.contains(scriptPath)
            case .uneditable: uneditable = true
            case .absent: break
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isInstalled = installed
                    self.isUneditable = uneditable
                }
            }
        }
    }

    // MARK: 生命周期

    /// 已安装则启动事件监听（初始回放不发通知）。未安装则空转。
    func start() {
        guard watcher == nil else { return }
        let url = eventsURL
        DispatchQueue.global(qos: .utility).async {
            Self.ensureEventFile(url: url)
            let (lines, size) = Self.readAll(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in lines { self.apply(line: line, notify: false) }
                    let watcher = CodexEventWatcher(url: url, startOffset: size) { [weak self] newLines in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                for line in newLines { self.apply(line: line, notify: true) }
                            }
                        }
                    }
                    watcher.start()
                    self.watcher = watcher
                }
            }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: 安装 / 卸载

    /// 生成脚本 + chmod 0755 + 写入 config.toml notify → 刷新状态并启动监听。
    func install(completion: @escaping (Bool) -> Void) {
        let scriptURL = self.scriptURL
        let scriptPath = scriptURL.path
        let eventsPath = eventsURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            let wrote = Self.writeScript(to: scriptURL, eventsPath: eventsPath)
            var ok = wrote
            if wrote {
                do {
                    var programs: [String]
                    switch CodexEnv.notify() {
                    case .array(let existing): programs = existing
                    case .absent: programs = []
                    case .uneditable: throw CodexTOML.EditError.uneditable
                    }
                    if !programs.contains(scriptPath) { programs.append(scriptPath) }
                    try CodexEnv.setNotify(programs)
                } catch {
                    ok = false
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                    if ok { self.start() }
                    completion(ok)
                }
            }
        }
    }

    /// 从 config.toml notify 中移除本脚本路径（数组空则删键）→ 刷新状态并停监听。
    func remove(completion: @escaping (Bool) -> Void) {
        let scriptPath = scriptURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            do {
                switch CodexEnv.notify() {
                case .array(var programs):
                    programs.removeAll { $0 == scriptPath }
                    if programs.isEmpty {
                        try CodexEnv.removeNotify()
                    } else {
                        try CodexEnv.setNotify(programs)
                    }
                case .absent:
                    break
                case .uneditable:
                    throw CodexTOML.EditError.uneditable
                }
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stop()
                    self.refreshState()
                    completion(ok)
                }
            }
        }
    }

    // MARK: 通知

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 额度 80% 提醒（5h 或周）。与 Claude 同机制，防重由 `CodexUsageStore` 负责。
    func notifyBudget(percent: Int, weekly: Bool) {
        let content = UNMutableNotificationContent()
        content.title = weekly ? L("aitools.notify.weeklyBudget.title") : L("aitools.notify.budget.title")
        content.body = L("aitools.notify.budget.body \(percent)")
        if AIToolsNotifierSettings.soundEnabled { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 处理一行事件 JSON。notify=false 用于初始回放。
    private func apply(line: String, notify: Bool) {
        guard notify,
              let data = line.data(using: .utf8),
              let object = CodexJSONLParsing.parseObject(data) else { return }

        // 兼容顶层与 payload 嵌套两种写法。
        let type = (object["type"] as? String)
            ?? ((object["payload"] as? [String: Any])?["type"] as? String)
        guard type == "agent-turn-complete" || type == "agent_turn_complete" else { return }

        let message = lastAssistantMessage(from: object)
        let cwd = CodexJSONLParsing.extractMeta(from: object).cwd
        let project = cwd.flatMap { $0.isEmpty ? nil : CodexSessionIndex.projectName(fromPath: $0) }
        postTurnComplete(project: project, summary: message)
        // 回合完成 → 节流刷新用量（≥60s 才真正刷），使菜单/用量页近实时。
        CodexUsageStore.shared.refreshThrottledFromEvent()
    }

    /// 从事件对象里取 last-assistant-message（兼容连字符 / 下划线 / payload 嵌套）。
    private func lastAssistantMessage(from object: [String: Any]) -> String {
        let keys = ["last-assistant-message", "last_assistant_message"]
        for key in keys {
            if let s = object[key] as? String { return s }
        }
        if let payload = object["payload"] as? [String: Any] {
            for key in keys {
                if let s = payload[key] as? String { return s }
            }
        }
        return ""
    }

    private func postTurnComplete(project: String?, summary: String) {
        let title: String
        if let project, !project.isEmpty {
            title = L("aitools.notify.turnComplete.titleProject \(project)")
        } else {
            title = L("aitools.notify.turnComplete.title")
        }
        let body = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.summaryClip))

        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        if AIToolsNotifierSettings.soundEnabled { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: 脚本生成 / 事件文件维护（nonisolated static）

    /// 写 notify 脚本。事件 JSON 是最后一个参数，用 `for` 循环取末位后追加到 events 文件。
    nonisolated static func writeScript(to url: URL, eventsPath: String) -> Bool {
        CodexEnv.ensureSupportDir()
        let script = """
        #!/bin/sh
        # Baobox Codex notify hook —— Codex 把事件 JSON 作为最后一个参数传入。
        last=""
        for a in "$@"; do last=$a; done
        printf '%s\\n' "$last" >> \(shellSingleQuote(eventsPath))
        exit 0
        """
        guard let data = script.data(using: .utf8) else { return false }
        do {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// 确保 events 文件存在；超限则截断保留尾部若干行。
    nonisolated static func ensureEventFile(url: URL) {
        CodexEnv.ensureSupportDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > maxEventBytes, let data = try? Data(contentsOf: url) else { return }
        let tail = data.split(separator: 0x0A).suffix(keepTailLines)
        var rebuilt = Data()
        for line in tail {
            rebuilt.append(Data(line))
            rebuilt.append(0x0A)
        }
        try? rebuilt.write(to: url)
    }

    /// 读入全部行与当前大小（供初始回放 + 设定监听偏移）。
    nonisolated static func readAll(url: URL) -> (lines: [String], size: UInt64) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, UInt64(data.count))
    }

    /// 单引号安全包裹（供脚本内路径拼接）。与 `ClaudeEnv.shellSingleQuote` 同实现，独立以避免耦合。
    nonisolated static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
