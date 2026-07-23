import AppKit
import SwiftUI

/// Claude Code 助手 —— 设置 Tab。顶部状态卡 + segmented Picker 分 5 节：
/// 通知 / 配置 / Statusline / MCP / 维护（TECH_DESIGN 3.9）。
///
/// 「配置」节一律用可视化控件（Picker 单选 / Toggle 勾选 / DisclosureGroup 分组），
/// 裸文本编辑收进「高级」折叠。所有写配置操作在后台线程执行、完成回主线程刷新，
/// 失败以红字提示或 NSAlert。只调核心层已暴露的 API，不直接碰 `~/.claude` 文件。

// MARK: - 顶层容器

struct ClaudeCodeSettingsView: View {

    /// 6 个分节。
    enum Section: String, CaseIterable, Identifiable {
        case notifications, config, statusline, menu, mcp, maintenance
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .notifications: return "claudecode.settings.section.notifications"
            case .config: return "claudecode.settings.section.config"
            case .statusline: return "claudecode.settings.section.statusline"
            case .menu: return "claudecode.settings.section.menu"
            case .mcp: return "claudecode.settings.section.mcp"
            case .maintenance: return "claudecode.settings.section.maintenance"
            }
        }
    }

    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var hooks = ClaudeHooksManager.shared
    @State private var section: Section = .notifications
    @State private var cliVersion: String?

    var body: some View {
        VStack(spacing: 0) {
            statusCard
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            if ClaudeEnv.isInstalled {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { s in
                        Text(s.titleKey).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider()
                sectionBody
            } else {
                Spacer()
                Text("claudecode.settings.notInstalled")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(32)
                Spacer()
            }
        }
        .onAppear {
            hooks.refreshState()
            loadVersion()
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .notifications: ClaudeNotificationsSection()
        case .config: ClaudeConfigSection()
        case .statusline: ClaudeStatuslineSection()
        case .menu: ClaudeMenuRowSection()
        case .mcp: ClaudeMCPSection()
        case .maintenance: ClaudeMaintenanceSection(localVersion: cliVersion)
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        HStack(spacing: 16) {
            Label {
                if let cliVersion {
                    Text("claudecode.settings.status.version \(cliVersion)")
                } else {
                    Text("claudecode.settings.status.versionUnknown")
                }
            } icon: {
                Image(systemName: "terminal")
            }
            Label {
                Text(hooks.isReporterInstalled ? "claudecode.settings.status.hooksOn" : "claudecode.settings.status.hooksOff")
            } icon: {
                Image(systemName: hooks.isReporterInstalled ? "bell.fill" : "bell.slash")
            }
            Label {
                Text("claudecode.settings.status.sessions \(index.sessions.count)")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func loadVersion() {
        DispatchQueue.global(qos: .utility).async {
            let version = ClaudeEnv.cliVersion()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { cliVersion = version }
            }
        }
    }
}

// MARK: - 1. 通知

struct ClaudeNotificationsSection: View {
    @ObservedObject private var hooks = ClaudeHooksManager.shared
    @AppStorage(ClaudeNotifierSettings.enabledKey) private var enabled = false
    // 初值取迁移后的当前方式(读旧布尔键),写入走新键。
    @AppStorage(ClaudeNotifierSettings.alertStyleKey) private var alertStyle = ClaudeNotifierSettings.alertStyle.rawValue
    @AppStorage(ClaudeNotifierSettings.soundNameKey) private var soundName = ""
    @AppStorage(ClaudeNotifierSettings.speechTextKey) private var speechText = ""
    @AppStorage(ClaudeNotifierSettings.budgetAlertKey) private var budgetAlert = true
    @AppStorage(ClaudeNotifierSettings.budgetRestoreKey) private var budgetRestore = false
    @AppStorage(ClaudeUsageStore.budgetKey) private var tokenBudget = 0
    @AppStorage(ClaudeUsageStore.weeklyBudgetKey) private var weeklyBudget = 0
    @AppStorage(ClaudeUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(ClaudeUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(ClaudeUsageStore.weeklyHourKey) private var weeklyHour = 0

    /// 预算以千 token 为单位输入。
    private var budgetK: Binding<Int> {
        Binding(get: { tokenBudget / 1000 }, set: { tokenBudget = max(0, $0) * 1000 })
    }

    /// 周预算以千 token 为单位输入。
    private var weeklyBudgetK: Binding<Int> {
        Binding(get: { weeklyBudget / 1000 }, set: { weeklyBudget = max(0, $0) * 1000 })
    }

    /// 本地化 standalone 星期名（Calendar 口径：1=周日…7=周六）。
    private static func weekdayName(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }

    var body: some View {
        Form {
            SwiftUI.Section("claudecode.settings.notify.section") {
                Toggle("claudecode.settings.notify.enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        if newValue { ClaudeNotifier.shared.requestAuthorizationIfNeeded() }
                    }
                Text("claudecode.settings.notify.enabledHelp")
                    .font(.caption).foregroundStyle(.secondary)
                // 提醒方式三选一:提示音与朗读同时响会互相干扰,故互斥。
                Picker("claudecode.settings.notify.alertStyle", selection: $alertStyle) {
                    Text("claudecode.settings.notify.style.none")
                        .tag(ClaudeNotifierSettings.AlertStyle.none.rawValue)
                    Text("claudecode.settings.notify.style.sound")
                        .tag(ClaudeNotifierSettings.AlertStyle.sound.rawValue)
                    Text("claudecode.settings.notify.style.speech")
                        .tag(ClaudeNotifierSettings.AlertStyle.speech.rawValue)
                }
                .pickerStyle(.segmented)

                if alertStyle == ClaudeNotifierSettings.AlertStyle.sound.rawValue {
                    Picker("claudecode.settings.notify.soundPicker", selection: $soundName) {
                        Text("claudecode.settings.notify.soundDefault").tag("")
                        ForEach(ClaudeNotifierSettings.systemSounds, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    .onChange(of: soundName) { _, newValue in
                        // 选择即试听,便于挑选。
                        if !newValue.isEmpty { NSSound(named: newValue)?.play() }
                    }
                }

                if alertStyle == ClaudeNotifierSettings.AlertStyle.speech.rawValue {
                    TextField("claudecode.settings.notify.speechText", text: $speechText,
                              prompt: Text("claudecode.settings.notify.speechPlaceholder"))
                    Text("claudecode.settings.notify.speechHelp")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("claudecode.settings.notify.preview") {
                            ClaudeNotifier.shared.preview()
                        }
                    }
                }
            }

            SwiftUI.Section("claudecode.settings.notify.budgetSection") {
                HStack {
                    Text("claudecode.settings.notify.budget")
                    Spacer()
                    TextField("", value: budgetK, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Text("claudecode.settings.notify.budgetHelp")
                    .font(.caption).foregroundStyle(.secondary)
                // 80% 提醒依赖预算基准,预算为 0 时置灰以显式表达这一依赖。
                Toggle("claudecode.settings.notify.budgetAlert", isOn: $budgetAlert)
                    .disabled(tokenBudget == 0)
                Toggle("claudecode.settings.notify.budgetRestore", isOn: $budgetRestore)

                // —— 周额度 ——
                HStack {
                    Text("claudecode.settings.notify.weeklyBudget")
                    Spacer()
                    TextField("", value: weeklyBudgetK, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("claudecode.settings.notify.weeklyFixed", isOn: $weeklyFixed)
                    .onChange(of: weeklyFixed) { _, _ in ClaudeUsageStore.shared.refresh() }
                if weeklyFixed {
                    Picker("claudecode.settings.notify.weeklyWeekday", selection: $weeklyWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(verbatim: Self.weekdayName(weekday)).tag(weekday)
                        }
                    }
                    .onChange(of: weeklyWeekday) { _, _ in ClaudeUsageStore.shared.refresh() }
                    Picker("claudecode.settings.notify.weeklyHour", selection: $weeklyHour) {
                        ForEach(0...23, id: \.self) { hour in
                            Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .onChange(of: weeklyHour) { _, _ in ClaudeUsageStore.shared.refresh() }
                }
                Text("claudecode.settings.notify.weeklyHint")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("claudecode.settings.notify.hooksSection") {
                HStack {
                    Text(hooks.isReporterInstalled ? "claudecode.common.installed" : "claudecode.settings.status.hooksOff")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hooks.isReporterInstalled {
                        Button("claudecode.settings.notify.removeHooks", role: .destructive) {
                            hooks.removeReporter { _ in }
                        }
                    } else {
                        Button("claudecode.settings.notify.installHooks") {
                            hooks.installReporter { _ in }
                        }
                    }
                }
                Text("claudecode.settings.notify.hooksHelp")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hooks.refreshState() }
    }
}

// MARK: - 2. 配置

struct ClaudeConfigSection: View {
    @StateObject private var model = ClaudeConfigModel()
    @ObservedObject private var hooks = ClaudeHooksManager.shared
    @State private var newAllow = ""
    @State private var newDeny = ""
    @State private var newGuard = ""

    var body: some View {
        Form {
            if let error = model.errorMessage {
                Text(verbatim: error).foregroundStyle(.red).font(.caption)
            }
            behaviorGroup
            permissionsGroup
            guardGroup
            privacyGroup
            commitGroup
            claudeMdGroup
        }
        .formStyle(.grouped)
        .onAppear {
            model.load()
            hooks.refreshState()
            hooks.loadGuardPatterns()
        }
    }

    // MARK: 行为

    private var behaviorGroup: some View {
        SwiftUI.Section {
            TappableDisclosure(initiallyExpanded: true) {
                Picker("claudecode.settings.config.defaultMode",
                       selection: Binding(get: { model.defaultMode }, set: { model.setDefaultMode($0) })) {
                    Text("claudecode.settings.config.mode.default").tag("default")
                    Text("claudecode.settings.config.mode.acceptEdits").tag("acceptEdits")
                    Text("claudecode.settings.config.mode.plan").tag("plan")
                    Text("claudecode.settings.config.mode.bypass").tag("bypassPermissions")
                }
                if model.defaultMode == "bypassPermissions" {
                    Text("claudecode.settings.config.mode.bypassWarning")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("claudecode.settings.config.defaultModeHelp")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("claudecode.settings.config.model",
                       selection: Binding(get: { model.model }, set: { model.setModel($0) })) {
                    Text("claudecode.settings.config.model.default").tag("")
                    Text(verbatim: "Opus").tag("opus")
                    Text(verbatim: "Sonnet").tag("sonnet")
                    Text(verbatim: "Haiku").tag("haiku")
                }
                Text("claudecode.settings.config.modelHelp")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("claudecode.settings.config.cleanup",
                       selection: Binding(get: { model.cleanupDays }, set: { model.setCleanup($0) })) {
                    Text("claudecode.settings.config.cleanup.default").tag(0)
                    Text("claudecode.settings.config.cleanup.days \(7)").tag(7)
                    Text("claudecode.settings.config.cleanup.days \(30)").tag(30)
                    Text("claudecode.settings.config.cleanup.days \(90)").tag(90)
                    Text("claudecode.settings.config.cleanup.days \(365)").tag(365)
                }
                Text("claudecode.settings.config.cleanupHelp")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("claudecode.settings.config.behavior").font(.headline)
            }
        }
    }

    // MARK: 权限规则

    private var permissionsGroup: some View {
        SwiftUI.Section {
            TappableDisclosure {
                ForEach(ClaudeConfigModel.permPresets.indices, id: \.self) { i in
                    let preset = ClaudeConfigModel.permPresets[i]
                    Toggle(preset.titleKey, isOn: Binding(
                        get: { model.isPresetOn(preset.rules) },
                        set: { model.setPreset(preset.rules, on: $0) }
                    ))
                }
                Text("claudecode.settings.config.presetsHelp")
                    .font(.caption).foregroundStyle(.secondary)

                TappableDisclosure {
                    ruleEditor(title: "claudecode.settings.config.allowList",
                               rules: model.allow,
                               newRule: $newAllow,
                               add: { model.addRule($0, kind: .allow) },
                               remove: { model.removeRule($0, kind: .allow) })
                    ruleEditor(title: "claudecode.settings.config.denyList",
                               rules: model.deny,
                               newRule: $newDeny,
                               add: { model.addRule($0, kind: .deny) },
                               remove: { model.removeRule($0, kind: .deny) })
                } label: {
                    Text("claudecode.settings.config.advanced")
                }
            } label: {
                Text("claudecode.settings.config.permissions").font(.headline)
            }
        }
    }

    private func ruleEditor(title: LocalizedStringKey, rules: [String], newRule: Binding<String>,
                            add: @escaping (String) -> Void, remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            if rules.isEmpty {
                Text("claudecode.settings.config.noRules").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rules, id: \.self) { rule in
                    HStack {
                        Text(verbatim: rule).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Button {
                            remove(rule)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("claudecode.settings.config.rulePlaceholder", text: newRule)
                    .textFieldStyle(.roundedBorder)
                Button("claudecode.settings.config.addRule") {
                    add(newRule.wrappedValue)
                    newRule.wrappedValue = ""
                }
                .disabled(newRule.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: 危险命令卫士

    private var guardGroup: some View {
        SwiftUI.Section {
            TappableDisclosure {
                Toggle("claudecode.settings.config.guardEnabled", isOn: Binding(
                    get: { hooks.isGuardInstalled },
                    set: { newValue in
                        if newValue { hooks.installGuard { _ in } } else { hooks.removeGuard { _ in } }
                    }
                ))
                Text("claudecode.settings.config.guardHelp")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(hooks.guardPresets) { preset in
                    Toggle(isOn: Binding(
                        get: { hooks.isPresetEnabled(preset) },
                        set: { hooks.setPreset(preset, enabled: $0) }
                    )) {
                        // 预置规则描述键为运行时字符串，用动态 LocalizedStringKey 查表本地化。
                        Text(LocalizedStringKey(preset.descriptionKey))
                    }
                }

                TappableDisclosure {
                    let custom = hooks.customPatterns()
                    if custom.isEmpty {
                        Text("claudecode.settings.config.noRules").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(custom, id: \.self) { pattern in
                            HStack {
                                Text(verbatim: pattern).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Button {
                                    hooks.saveGuardPatterns(hooks.guardPatterns.filter { $0 != pattern })
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("claudecode.settings.config.guardRulePlaceholder", text: $newGuard)
                            .textFieldStyle(.roundedBorder)
                        Button("claudecode.settings.config.addRule") {
                            let t = newGuard.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { hooks.saveGuardPatterns(hooks.guardPatterns + [t]) }
                            newGuard = ""
                        }
                        .disabled(newGuard.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("claudecode.settings.config.guardReset") {
                        hooks.resetGuardPatterns()
                    }
                } label: {
                    Text("claudecode.settings.config.guardCustom")
                }
            } label: {
                Text("claudecode.settings.config.guard").font(.headline)
            }
        }
    }

    // MARK: 隐私

    private var privacyGroup: some View {
        SwiftUI.Section {
            TappableDisclosure {
                Toggle("claudecode.settings.config.privacy.telemetry", isOn: Binding(
                    get: { model.telemetry },
                    set: { model.setPrivacy(ClaudeConfigModel.envTelemetry, on: $0) }
                ))
                Toggle("claudecode.settings.config.privacy.errorReporting", isOn: Binding(
                    get: { model.errorReporting },
                    set: { model.setPrivacy(ClaudeConfigModel.envErrorReporting, on: $0) }
                ))
                Toggle("claudecode.settings.config.privacy.traffic", isOn: Binding(
                    get: { model.traffic },
                    set: { model.setPrivacy(ClaudeConfigModel.envTraffic, on: $0) }
                ))
                Text("claudecode.settings.config.privacyHelp")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("claudecode.settings.config.privacy").font(.headline)
            }
        }
    }

    // MARK: 提交署名

    private var commitGroup: some View {
        SwiftUI.Section {
            TappableDisclosure {
                Toggle("claudecode.settings.config.coauthored", isOn: Binding(
                    get: { model.coAuthored },
                    set: { model.setCoAuthored($0) }
                ))
                Text("claudecode.settings.config.coauthoredHelp")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("claudecode.settings.config.commit").font(.headline)
            }
        }
    }

    // MARK: CLAUDE.md

    private var claudeMdGroup: some View {
        SwiftUI.Section {
            TappableDisclosure {
                ForEach(model.claudeMdEntries) { entry in
                    HStack {
                        Image(systemName: entry.exists ? "doc.text" : "doc.badge.plus")
                            .foregroundStyle(.secondary)
                        Text(verbatim: entry.title).lineLimit(1)
                        Spacer()
                        if entry.exists {
                            Button("claudecode.settings.config.claudeMd.open") {
                                model.openClaudeMd(entry)
                            }
                        } else {
                            Button("claudecode.settings.config.claudeMd.create") {
                                model.createClaudeMd(entry)
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Text("claudecode.settings.config.claudeMdHelp")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("claudecode.settings.config.claudeMd").font(.headline)
            }
        }
    }
}

// MARK: - 配置节视图模型

/// 「配置」节的状态与后台读写。`@Published` 只在主线程写；核心层 throws 接口 do/catch。
@MainActor
final class ClaudeConfigModel: ObservableObject {
    @Published var defaultMode = "default"   // "default" 同时代表未设置
    @Published var model = ""                // "" = 跟随默认
    @Published var cleanupDays = 0           // 0 = 跟随默认
    @Published var allow: [String] = []
    @Published var deny: [String] = []
    @Published var coAuthored = true
    @Published var telemetry = false
    @Published var errorReporting = false
    @Published var traffic = false
    @Published var claudeMdEntries: [ClaudeMdEntry] = []
    @Published var errorMessage: String?

    // 隐私 env 键。
    static let envTelemetry = "DISABLE_TELEMETRY"
    static let envErrorReporting = "DISABLE_ERROR_REPORTING"
    static let envTraffic = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    /// 权限预设矩阵（映射表内置常量；勾选态由「该组规则是否全部在 allow 中」反推）。
    static let permPresets: [(titleKey: LocalizedStringKey, rules: [String])] = [
        ("claudecode.settings.config.preset.packageManagers",
         ["Bash(npm run *)", "Bash(npm install *)", "Bash(pnpm *)", "Bash(yarn *)"]),
        ("claudecode.settings.config.preset.buildTest",
         ["Bash(make *)", "Bash(eslint *)", "Bash(pytest *)", "Bash(go test *)", "Bash(cargo build *)"]),
        ("claudecode.settings.config.preset.gitRead",
         ["Bash(git status *)", "Bash(git log *)", "Bash(git diff *)"]),
        ("claudecode.settings.config.preset.gitWrite",
         ["Bash(git add *)", "Bash(git commit *)", "Bash(git push *)"]),
        ("claudecode.settings.config.preset.fileRead",
         ["Read(*)"])
    ]

    /// CLAUDE.md 内置模板（缺失时创建用）。
    static let claudeMdTemplate = """
    # Project guidance for Claude Code

    ## Overview
    <!-- Briefly describe what this project is and does. -->

    ## Conventions
    <!-- Coding style, naming, and structure notes. -->

    ## Commands
    <!-- Common build / test / run commands. -->
    """

    // MARK: 读取

    func load() {
        let projectPaths = orderedProjectPaths()
        DispatchQueue.global(qos: .utility).async {
            let mode = ClaudeEnv.defaultMode() ?? "default"
            let model = ClaudeEnv.model() ?? ""
            let cleanup = ClaudeEnv.cleanupPeriodDays() ?? 0
            let allow = ClaudeEnv.permissionRules(.allow)
            let deny = ClaudeEnv.permissionRules(.deny)
            let coauth = ClaudeEnv.includeCoAuthoredBy()
            let telemetry = ClaudeEnv.envValue(Self.envTelemetry) != nil
            let errorReporting = ClaudeEnv.envValue(Self.envErrorReporting) != nil
            let traffic = ClaudeEnv.envValue(Self.envTraffic) != nil
            let entries = Self.buildClaudeMd(projectPaths: projectPaths)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.defaultMode = mode
                    self.model = model
                    self.cleanupDays = cleanup
                    self.allow = allow
                    self.deny = deny
                    self.coAuthored = coauth
                    self.telemetry = telemetry
                    self.errorReporting = errorReporting
                    self.traffic = traffic
                    self.claudeMdEntries = entries
                }
            }
        }
    }

    /// 会话索引中出现过的项目路径（去重、保序）。
    private func orderedProjectPaths() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in ClaudeSessionIndex.shared.sessions {
            let path = session.projectPath
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    // MARK: 写入（乐观更新 + 后台落盘）

    func setDefaultMode(_ mode: String) {
        defaultMode = mode
        perform { if mode == "default" { try ClaudeEnv.removeDefaultMode() } else { try ClaudeEnv.setDefaultMode(mode) } }
    }

    func setModel(_ value: String) {
        model = value
        perform { if value.isEmpty { try ClaudeEnv.removeModel() } else { try ClaudeEnv.setModel(value) } }
    }

    func setCleanup(_ days: Int) {
        cleanupDays = days
        perform { if days == 0 { try ClaudeEnv.removeCleanupPeriodDays() } else { try ClaudeEnv.setCleanupPeriodDays(days) } }
    }

    func setCoAuthored(_ value: Bool) {
        coAuthored = value
        perform { try ClaudeEnv.setIncludeCoAuthoredBy(value) }
    }

    func setPrivacy(_ key: String, on: Bool) {
        switch key {
        case Self.envTelemetry: telemetry = on
        case Self.envErrorReporting: errorReporting = on
        case Self.envTraffic: traffic = on
        default: break
        }
        perform { if on { try ClaudeEnv.setEnvFlag(key) } else { try ClaudeEnv.removeEnvKey(key) } }
    }

    func isPresetOn(_ rules: [String]) -> Bool {
        !rules.isEmpty && rules.allSatisfy { allow.contains($0) }
    }

    func setPreset(_ rules: [String], on: Bool) {
        if on {
            for rule in rules where !allow.contains(rule) { allow.append(rule) }
        } else {
            allow.removeAll { rules.contains($0) }
        }
        let snapshot = allow
        perform { try ClaudeEnv.setPermissionRules(snapshot, kind: .allow) }
    }

    func addRule(_ raw: String, kind: ClaudeEnv.PermissionKind) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if kind == .allow {
            guard !allow.contains(trimmed) else { return }
            allow.append(trimmed)
        } else {
            guard !deny.contains(trimmed) else { return }
            deny.append(trimmed)
        }
        let snapshot = kind == .allow ? allow : deny
        perform { try ClaudeEnv.setPermissionRules(snapshot, kind: kind) }
    }

    func removeRule(_ rule: String, kind: ClaudeEnv.PermissionKind) {
        if kind == .allow { allow.removeAll { $0 == rule } } else { deny.removeAll { $0 == rule } }
        let snapshot = kind == .allow ? allow : deny
        perform { try ClaudeEnv.setPermissionRules(snapshot, kind: kind) }
    }

    // MARK: CLAUDE.md

    func openClaudeMd(_ entry: ClaudeMdEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    func createClaudeMd(_ entry: ClaudeMdEntry) {
        let url = entry.url
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.claudeMdTemplate.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSWorkspace.shared.open(url)
                    self.load()
                }
            }
        }
    }

    /// 后台执行一次写配置，失败回主线程红字提示并重载还原。
    private func perform(_ work: @escaping () throws -> Void) {
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.errorMessage = L("claudecode.common.writeFailed")
                        self.load()
                    }
                }
            }
        }
    }

    /// 组装 CLAUDE.md 列表（全局 + 各已知项目）；含存在性检查，故 nonisolated 后台调用。
    nonisolated static func buildClaudeMd(projectPaths: [String]) -> [ClaudeMdEntry] {
        let fm = FileManager.default
        var entries: [ClaudeMdEntry] = []
        let globalURL = ClaudeEnv.claudeDir.appendingPathComponent("CLAUDE.md")
        entries.append(ClaudeMdEntry(
            id: "__global__",
            title: L("claudecode.settings.config.claudeMd.global"),
            url: globalURL,
            exists: fm.fileExists(atPath: globalURL.path)
        ))
        for path in projectPaths {
            let url = URL(fileURLWithPath: path).appendingPathComponent("CLAUDE.md")
            entries.append(ClaudeMdEntry(
                id: path,
                title: ClaudeSessionIndex.projectName(fromPath: path),
                url: url,
                exists: fm.fileExists(atPath: url.path)
            ))
        }
        return entries
    }
}

/// CLAUDE.md 列表一行。
struct ClaudeMdEntry: Identifiable {
    let id: String
    let title: String
    let url: URL
    let exists: Bool
}

// MARK: - 3. Statusline

struct ClaudeStatuslineSection: View {
    @ObservedObject private var manager = ClaudeStatuslineManager.shared

    var body: some View {
        Form {
            if manager.hasForeignStatusline {
                Text("claudecode.settings.statusline.foreignWarning")
                    .font(.caption).foregroundStyle(.orange)
            }

            SwiftUI.Section("claudecode.settings.statusline.segmentsSection") {
                Picker("claudecode.settings.statusline.scheme", selection: $manager.selectedID) {
                    ForEach(manager.allSchemes) { scheme in
                        Text(verbatim: manager.displayName(of: scheme)).tag(scheme.id)
                    }
                }
                Text(verbatim: manager.previewLine())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            if manager.isBuiltin(manager.selectedID) {
                SwiftUI.Section {
                    HStack {
                        Text("claudecode.settings.rowformat.builtinHint")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("claudecode.settings.rowformat.newScheme") { manager.addScheme() }
                    }
                }
            } else if let scheme = manager.scheme(with: manager.selectedID) {
                editor(for: scheme)
            }

            SwiftUI.Section {
                HStack {
                    Button("claudecode.settings.statusline.apply") { apply() }
                    Button("claudecode.settings.statusline.remove", role: .destructive) {
                        manager.remove { _ in }
                    }
                    .disabled(!manager.isInstalled)
                    Spacer()
                    if manager.isInstalled {
                        Label("claudecode.settings.statusline.installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                }
                Text("claudecode.settings.statusline.help")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refreshState() }
    }

    @ViewBuilder
    private func editor(for scheme: StatuslineScheme) -> some View {
        SwiftUI.Section("claudecode.settings.rowformat.editSection") {
            TextField("claudecode.settings.rowformat.name", text: nameBinding(scheme.id))
            HStack {
                Text("claudecode.settings.statusline.separator")
                Spacer()
                TextField("", text: separatorBinding(scheme.id))
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
            ForEach(Array(scheme.segments.enumerated()), id: \.element.segment) { index, config in
                segmentRow(schemeID: scheme.id, index: index, config: config, count: scheme.segments.count)
            }
        }
        SwiftUI.Section {
            HStack {
                Button("claudecode.settings.rowformat.newScheme") { manager.addScheme() }
                Spacer()
                Button(role: .destructive) {
                    manager.deleteScheme(scheme.id)
                } label: {
                    Text("claudecode.settings.rowformat.deleteScheme")
                }
            }
        }
    }

    private func segmentRow(schemeID: UUID, index: Int, config: StatuslineScheme.SegmentConfig, count: Int) -> some View {
        HStack {
            Toggle(isOn: enabledBinding(schemeID, index: index)) {
                Text(verbatim: config.segment.displayName)
            }
            Spacer()
            Button {
                move(schemeID, from: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            Button {
                move(schemeID, from: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == count - 1)
        }
    }

    // MARK: 绑定与操作(统一回读 manager,避免闭包捕获过期方案快照)

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { manager.scheme(with: id)?.name ?? "" },
            set: { newValue in
                guard var scheme = manager.scheme(with: id) else { return }
                scheme.name = newValue
                manager.updateScheme(scheme)
            }
        )
    }

    private func separatorBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { manager.scheme(with: id)?.separator ?? " | " },
            set: { newValue in
                guard var scheme = manager.scheme(with: id) else { return }
                scheme.separator = newValue
                manager.updateScheme(scheme)
            }
        )
    }

    private func enabledBinding(_ id: UUID, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let scheme = manager.scheme(with: id), scheme.segments.indices.contains(index) else { return false }
                return scheme.segments[index].enabled
            },
            set: { newValue in
                guard var scheme = manager.scheme(with: id), scheme.segments.indices.contains(index) else { return }
                scheme.segments[index].enabled = newValue
                manager.updateScheme(scheme)
            }
        )
    }

    private func move(_ id: UUID, from index: Int, offset: Int) {
        guard var scheme = manager.scheme(with: id) else { return }
        let target = index + offset
        guard scheme.segments.indices.contains(index), scheme.segments.indices.contains(target) else { return }
        scheme.segments.swapAt(index, target)
        manager.updateScheme(scheme)
    }

    private func apply() {
        if manager.hasForeignStatusline {
            let alert = NSAlert()
            alert.messageText = L("claudecode.settings.statusline.overwriteConfirm.title")
            alert.informativeText = L("claudecode.settings.statusline.overwriteConfirm.message")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("claudecode.settings.statusline.overwriteConfirm.confirm"))
            alert.addButton(withTitle: L("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        manager.apply { _ in }
    }
}

// MARK: - 4. MCP

struct ClaudeMCPSection: View {
    @State private var rows: [MCPRow] = []
    @State private var loading = false
    @State private var showAdd = false

    var body: some View {
        Form {
            SwiftUI.Section {
                if loading {
                    ProgressView().controlSize(.small)
                } else if rows.isEmpty {
                    Text("claudecode.settings.mcp.empty").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: row.name)
                                Text(verbatim: "\(row.type) · \(row.detail)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                confirmDelete(row)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("claudecode.settings.mcp.add") { showAdd = true }
                Text("claudecode.settings.mcp.help")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .sheet(isPresented: $showAdd) {
            ClaudeMCPAddSheet { reload() }
        }
    }

    private func reload() {
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let servers = ClaudeEnv.mcpServers()
            let mapped: [MCPRow] = servers.map { entry in
                let config = entry.config
                let type = (config["type"] as? String) ?? (config["command"] != nil ? "stdio" : "http")
                let detail: String
                if let command = config["command"] as? String {
                    detail = command
                } else if let url = config["url"] as? String {
                    detail = url
                } else {
                    detail = ""
                }
                return MCPRow(id: entry.name, name: entry.name, type: type, detail: detail)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    rows = mapped
                    loading = false
                }
            }
        }
    }

    private func confirmDelete(_ row: MCPRow) {
        let alert = NSAlert()
        alert.messageText = L("claudecode.settings.mcp.deleteConfirm.title \(row.name)")
        alert.informativeText = L("claudecode.settings.mcp.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("claudecode.common.remove"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? ClaudeEnv.removeMCPServer(name: row.name)
            DispatchQueue.main.async { MainActor.assumeIsolated { reload() } }
        }
    }

    struct MCPRow: Identifiable {
        let id: String
        let name: String
        let type: String
        let detail: String
    }
}

/// 添加 MCP 服务器 sheet。
private struct ClaudeMCPAddSheet: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var env = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("claudecode.settings.mcp.addTitle").font(.headline)
            Form {
                TextField("claudecode.settings.mcp.name", text: $name)
                Picker("claudecode.settings.mcp.type", selection: $type) {
                    Text("claudecode.settings.mcp.type.stdio").tag("stdio")
                    Text("claudecode.settings.mcp.type.http").tag("http")
                }
                if type == "stdio" {
                    TextField("claudecode.settings.mcp.command", text: $command)
                    TextField("claudecode.settings.mcp.args", text: $args)
                } else {
                    TextField("claudecode.settings.mcp.url", text: $url)
                }
                TextField("claudecode.settings.mcp.env", text: $env, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("claudecode.common.save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasTarget = type == "stdio"
            ? !command.trimmingCharacters(in: .whitespaces).isEmpty
            : !url.trimmingCharacters(in: .whitespaces).isEmpty
        return hasName && hasTarget
    }

    private func save() {
        let serverName = name.trimmingCharacters(in: .whitespaces)
        var config: [String: Any] = [:]
        if type == "stdio" {
            config["command"] = command.trimmingCharacters(in: .whitespaces)
            let argList = args.split(separator: " ").map(String.init)
            if !argList.isEmpty { config["args"] = argList }
        } else {
            config["type"] = "http"
            config["url"] = url.trimmingCharacters(in: .whitespaces)
        }
        let envDict = Self.parseEnv(env)
        if !envDict.isEmpty { config["env"] = envDict }

        DispatchQueue.global(qos: .userInitiated).async {
            try? ClaudeEnv.setMCPServer(name: serverName, config: config)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onSaved()
                    dismiss()
                }
            }
        }
    }

    /// 解析 "KEY=value" 每行一条。
    private static func parseEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

// MARK: - 5. 维护

struct ClaudeMaintenanceSection: View {
    let localVersion: String?

    @ObservedObject private var index = ClaudeSessionIndex.shared
    @State private var stats: ClaudeDiskStats?
    @State private var cleanupDays = 30
    @State private var latestVersion: String?
    @State private var checking = false
    @State private var checkFailed = false
    @State private var copied = false

    private static let upgradeCommand = "npm install -g @anthropic-ai/claude-code"

    var body: some View {
        Form {
            SwiftUI.Section("claudecode.settings.maint.diskSection") {
                if let stats {
                    Text("claudecode.settings.maint.projects \(ClaudeFormat.bytes(stats.projectsBytes))")
                    Text("claudecode.settings.maint.todos \(ClaudeFormat.bytes(stats.todosBytes))")
                    Text("claudecode.settings.maint.shellSnapshots \(ClaudeFormat.bytes(stats.shellSnapshotsBytes))")
                    Text("claudecode.settings.maint.other \(ClaudeFormat.bytes(stats.otherBytes))")
                    Text("claudecode.settings.maint.total \(ClaudeFormat.bytes(stats.totalBytes))").bold()
                    Text("claudecode.settings.maint.fileCount \(stats.sessionFileCount)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Picker("claudecode.settings.maint.cleanupOlderThan", selection: $cleanupDays) {
                        Text("claudecode.settings.config.cleanup.days \(30)").tag(30)
                        Text("claudecode.settings.config.cleanup.days \(60)").tag(60)
                        Text("claudecode.settings.config.cleanup.days \(90)").tag(90)
                    }
                    Button("claudecode.settings.maint.cleanup", role: .destructive) { confirmCleanup() }
                }
            }

            SwiftUI.Section("claudecode.settings.maint.versionSection") {
                if let localVersion {
                    Text("claudecode.settings.maint.localVersion \(localVersion)")
                } else {
                    Text("claudecode.settings.status.versionUnknown").foregroundStyle(.secondary)
                }
                if checking {
                    Text("claudecode.settings.maint.checking").font(.caption).foregroundStyle(.secondary)
                } else if checkFailed {
                    Text("claudecode.settings.maint.checkFailed").font(.caption).foregroundStyle(.red)
                } else if let latestVersion {
                    Text("claudecode.settings.maint.latestVersion \(latestVersion)").font(.caption)
                }
                HStack {
                    Button("claudecode.settings.maint.checkUpdate") { checkUpdate() }
                        .disabled(checking)
                    Button("claudecode.settings.maint.copyUpgrade") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.upgradeCommand, forType: .string)
                        copied = true
                    }
                    if copied {
                        Text("claudecode.common.copied").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadDisk() }
    }

    private func reloadDisk() {
        index.diskStats { result in
            MainActor.assumeIsolated { stats = result }
        }
    }

    private func confirmCleanup() {
        let alert = NSAlert()
        alert.messageText = L("claudecode.settings.maint.cleanupConfirm.title")
        alert.informativeText = L("claudecode.settings.maint.cleanupConfirm.message \(cleanupDays)")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("claudecode.settings.maint.cleanup"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        index.cleanup(olderThanDays: cleanupDays) { count, bytes in
            MainActor.assumeIsolated {
                reloadDisk()
                let done = NSAlert()
                done.messageText = L("claudecode.settings.maint.cleanupResult \(count) \(ClaudeFormat.bytes(bytes))")
                done.addButton(withTitle: L("common.ok"))
                done.runModal()
            }
        }
    }

    private func checkUpdate() {
        checking = true
        checkFailed = false
        latestVersion = nil
        guard let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest") else {
            checking = false
            checkFailed = true
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let version: String?
            if let data,
               let raw = try? JSONSerialization.jsonObject(with: data),
               let object = raw as? [String: Any],
               let v = object["version"] as? String {
                version = v
            } else {
                version = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    checking = false
                    if let version {
                        latestVersion = version
                    } else {
                        checkFailed = true
                    }
                }
            }
        }.resume()
    }
}

// MARK: - 会话(续接终端 + 会话行格式)

/// 「会话」分节:续接所用终端 + 快速续接面板的会话行格式(方案选择、实时预览;
/// 自定义方案支持字段开关、上下排序、命名与增删,内置方案只读)。
struct ClaudeMenuRowSection: View {
    @ObservedObject private var store = SessionRowFormatStore.shared
    @State private var terminalApp = TerminalAppChoice.current

    var body: some View {
        Form {
            SwiftUI.Section("settings.general.terminal.section") {
                Picker("settings.general.terminal.picker", selection: $terminalApp) {
                    ForEach(TerminalAppChoice.allCases) { choice in
                        Text(verbatim: choice.pickerLabel).tag(choice)
                    }
                }
                .onChange(of: terminalApp) { _, newValue in
                    TerminalAppChoice.current = newValue
                }
                Text("settings.general.terminal.desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("claudecode.settings.rowformat.section") {
                Picker("claudecode.settings.rowformat.picker", selection: $store.selectedID) {
                    ForEach(store.allSchemes) { scheme in
                        Text(verbatim: store.displayName(of: scheme)).tag(scheme.id)
                    }
                }
                LabeledContent("claudecode.settings.rowformat.preview") {
                    previewRow
                }
            }

            if store.isBuiltin(store.selectedID) {
                SwiftUI.Section {
                    HStack {
                        Text("claudecode.settings.rowformat.builtinHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("claudecode.settings.rowformat.newScheme") { store.addScheme() }
                    }
                }
            } else if let scheme = store.scheme(with: store.selectedID) {
                editor(for: scheme)
            }
        }
        .formStyle(.grouped)
    }

    /// 预览:按当前方案模拟菜单两行样式。
    private var previewRow: some View {
        let sample = SessionRowFormatStore.previewSummary
        let meta = store.activeScheme.metadataLine(for: sample)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: sample.title)
            if !meta.isEmpty {
                Text(verbatim: meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func editor(for scheme: SessionRowScheme) -> some View {
        SwiftUI.Section("claudecode.settings.rowformat.editSection") {
            TextField("claudecode.settings.rowformat.name", text: nameBinding(scheme.id))
            ForEach(Array(scheme.fields.enumerated()), id: \.element.field) { index, config in
                fieldRow(schemeID: scheme.id, index: index, config: config, count: scheme.fields.count)
            }
        }
        SwiftUI.Section {
            HStack {
                Button("claudecode.settings.rowformat.newScheme") { store.addScheme() }
                Spacer()
                Button(role: .destructive) {
                    store.deleteScheme(scheme.id)
                } label: {
                    Text("claudecode.settings.rowformat.deleteScheme")
                }
            }
        }
    }

    /// 一行字段:启用开关 + 上移 / 下移。顺序即菜单里的展示顺序。
    private func fieldRow(schemeID: UUID, index: Int, config: SessionRowScheme.FieldConfig, count: Int) -> some View {
        HStack {
            Toggle(isOn: enabledBinding(schemeID, index: index)) {
                Text(verbatim: config.field.displayName)
            }
            Spacer()
            Button {
                move(schemeID, from: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            Button {
                move(schemeID, from: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == count - 1)
        }
    }

    // MARK: 绑定与操作(统一回读 store,避免闭包捕获过期方案快照)

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.scheme(with: id)?.name ?? "" },
            set: { newValue in
                guard var scheme = store.scheme(with: id) else { return }
                scheme.name = newValue
                store.updateScheme(scheme)
            }
        )
    }

    private func enabledBinding(_ id: UUID, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let scheme = store.scheme(with: id), scheme.fields.indices.contains(index) else { return false }
                return scheme.fields[index].enabled
            },
            set: { newValue in
                guard var scheme = store.scheme(with: id), scheme.fields.indices.contains(index) else { return }
                scheme.fields[index].enabled = newValue
                store.updateScheme(scheme)
            }
        )
    }

    private func move(_ id: UUID, from index: Int, offset: Int) {
        guard var scheme = store.scheme(with: id) else { return }
        let target = index + offset
        guard scheme.fields.indices.contains(index), scheme.fields.indices.contains(target) else { return }
        scheme.fields.swapAt(index, target)
        store.updateScheme(scheme)
    }
}
