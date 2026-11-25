import Foundation
import XCTest

/// 快速入口的功能开关（docs/launcher/TECH_DESIGN.md §11「功能开关」，第 13 步）：id 的拼法、开关集合、设置键的读写与容错、
/// 设置页的分组与排序；关掉之后各处不出 —— 来源（前缀跟着失效）、动作（文字 / 图片 / 文件三处，派生的「图里的文字」也不出）、
/// 对应建议、计算 / 识别、路径行的动作；「带上你选中的文字」关着时不调取词函数；建议全关时的那行小字。
@MainActor
final class LauncherFeaturesTests: XCTestCase {

    private var clock: LauncherCalcContext { LauncherCalcTestSupport.context() }

    private func off(_ ids: String...) -> LauncherFeatureSet {
        LauncherFeatureSet(disabled: Set(ids))
    }

    private func plan(_ input: String, features: LauncherFeatureSet, calculation: Bool = false,
                      recognition: Bool = false) -> LauncherSuggestionPlan {
        LauncherSuggestionPolicy.plan(for: LauncherQuery.parse(input), hasCalculation: calculation, hasRecognition: recognition,
                                      clock: clock, features: features)
    }

    private func text(_ id: String, title: String = "T", priority: Int = 50, imageTextPriority: Int? = nil,
                      tool: String = "工具") -> LauncherCatalogCommand {
        LauncherCatalogCommand(command: .textAction(id: id, title: title, symbolName: "t",
                                                    suggestion: LauncherSuggestionTraits(priority: priority,
                                                                                         imageTextPriority: imageTextPriority)) { _ in },
                               toolID: "tool", toolName: tool)
    }

    private func image(_ id: String, title: String = "I", priority: Int = 50, tool: String = "截图") -> LauncherCatalogCommand {
        LauncherCatalogCommand(command: .imageAction(id: id, title: title, symbolName: "i",
                                                     suggestion: LauncherSuggestionTraits(priority: priority)) { _ in },
                               toolID: "tool", toolName: tool)
    }

    private func file(_ id: String, title: String = "F", priority: Int = 50, tool: String = "手机互传") -> LauncherCatalogCommand {
        LauncherCatalogCommand(command: .fileAction(id: id, title: title, symbolName: "f",
                                                    suggestion: LauncherSuggestionTraits(priority: priority)) { _ in },
                               toolID: "tool", toolName: tool)
    }

    // MARK: - id

    func testIDSpelling() {
        XCTAssertEqual(LauncherFeatureID.source("clipboard"), "source/clipboard")
        XCTAssertEqual(LauncherFeatureID.source("snippets"), "source/snippets")
        XCTAssertEqual(LauncherFeatureID.action("clipboard.text.qrCode"), "action/clipboard.text.qrCode")
        // 快速入口自己的来源和 `source(<来源 id>)` 是同一种拼法（引擎按来源 id 查）。
        XCTAssertEqual(LauncherBuiltInFeature.apps.id, LauncherFeatureID.source("apps"))
        XCTAssertEqual(LauncherBuiltInFeature.commands.id, LauncherFeatureID.source("commands"))
        XCTAssertEqual(LauncherBuiltInFeature.files.id, LauncherFeatureID.source("files"))
        XCTAssertEqual(LauncherBuiltInFeature.path.id, "source/path")
        XCTAssertEqual(LauncherBuiltInFeature.selection.id, "context/selection")
        XCTAssertEqual(LauncherBuiltInFeature.clipboard.id, "context/clipboard")
        XCTAssertEqual(LauncherBuiltInFeature.webSearch.id, "suggest/webSearch")
        XCTAssertEqual(LauncherBuiltInFeature.calculator.id, "instant/calculator")
        XCTAssertEqual(LauncherBuiltInFeature.copyPath.id, "path/copyPath")
    }

    func testBuiltInIDsAreUniqueAndGrouped() {
        let ids = LauncherBuiltInFeature.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let groups = Dictionary(grouping: LauncherBuiltInFeature.allCases, by: \.group).mapValues { $0.map(\.id) }
        XCTAssertEqual(groups[.search], ["source/apps", "source/commands", "source/files", "source/path"])
        XCTAssertEqual(groups[.instant], ["instant/calculator", "instant/textFormat", "instant/url", "instant/email",
                                          "instant/color", "instant/wordCount", "instant/reminder"])
        XCTAssertEqual(groups[.text], ["suggest/runInTerminal", "suggest/webSearch", "suggest/fileName"])
        XCTAssertEqual(groups[.image], ["image/recognition"])
        XCTAssertEqual(groups[.file], ["path/openInTerminal", "path/copyPath"])
        XCTAssertEqual(groups[.emptyState], ["context/selection", "context/clipboard", "context/situational", "context/frequent"])
        XCTAssertEqual(LauncherBuiltInFeature.webSearch.order, 30, "同面板里兜底建议的档位")
        XCTAssertEqual(LauncherBuiltInFeature.fileName.order, 40)
    }

    // MARK: - 开关集合

    func testEverythingIsOnUnlessListed() {
        let features = LauncherFeatureSet.allEnabled
        XCTAssertTrue(features.isEnabled("action/whatever.new"), "以后新加的功能默认开")
        XCTAssertTrue(features.isEnabled(.calculator))
        let some = off("source/files", "action/clipboard.text.qrCode")
        XCTAssertFalse(some.isSourceEnabled("files"))
        XCTAssertFalse(some.isEnabled(.files))
        XCTAssertFalse(some.isActionEnabled("clipboard.text.qrCode"))
        XCTAssertTrue(some.isActionEnabled("clipboard.text.pinCard"))
        XCTAssertTrue(some.isSourceEnabled("apps"))
    }

    func testSettingOneAndManyLeavesTheRestAlone() {
        let start = off("unknown/thing", "source/files")
        let turnedOn = start.setting("source/files", enabled: true)
        XCTAssertEqual(turnedOn.disabled, ["unknown/thing"], "不认识的 id 不动")
        let bulkOff = turnedOn.setting(["instant/url", "instant/email"], enabled: false)
        XCTAssertEqual(bulkOff.disabled, ["unknown/thing", "instant/url", "instant/email"])
        let bulkOn = bulkOff.setting(["instant/url", "instant/email", "instant/color"], enabled: true)
        XCTAssertEqual(bulkOn.disabled, ["unknown/thing"])
        XCTAssertEqual(bulkOn.setting("instant/url", enabled: true), bulkOn, "开着的再打开不变")
    }

    // MARK: - 设置键

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "LauncherFeaturesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return XCTFail("建不了测试用的 UserDefaults") }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testLoadToleratesUnknownIDsAndGarbage() {
        withDefaults { defaults in
            XCTAssertEqual(LauncherFeatureSettings.load(from: defaults), .allEnabled, "没有这个键 = 全开")
            defaults.set(["source/files", "以后的功能/xyz", 42, "", ["nested"]] as [Any], forKey: LauncherFeatureSettings.key)
            let loaded = LauncherFeatureSettings.load(from: defaults)
            XCTAssertEqual(loaded.disabled, ["source/files", "以后的功能/xyz"], "不是字符串的、空的跳过；不认识的留着")
            defaults.set("source/files", forKey: LauncherFeatureSettings.key)
            XCTAssertEqual(LauncherFeatureSettings.load(from: defaults), .allEnabled, "类型不对 = 全开，不出错")
            defaults.set(["a": 1], forKey: LauncherFeatureSettings.key)
            XCTAssertEqual(LauncherFeatureSettings.load(from: defaults), .allEnabled)
        }
    }

    func testSaveKeepsUnknownIDsWhenAnotherSwitchFlips() {
        withDefaults { defaults in
            defaults.set(["以后的功能/xyz", "action/claudecode.text.handOff"], forKey: LauncherFeatureSettings.key)
            // 设置页：读出来，拨了别的一项，写回去 —— 不认识的、这次没人声明的（没装 Claude Code）都还在。
            let next = LauncherFeatureSettings.load(from: defaults).setting("instant/color", enabled: false)
            LauncherFeatureSettings.save(next, to: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: LauncherFeatureSettings.key),
                           ["action/claudecode.text.handOff", "instant/color", "以后的功能/xyz"], "排好序写回")
            XCTAssertEqual(LauncherFeatureSettings.load(from: defaults), next)
            LauncherFeatureSettings.save(.allEnabled, to: defaults)
            XCTAssertNil(defaults.object(forKey: LauncherFeatureSettings.key), "全开时删掉这个键")
        }
    }

    // MARK: - 设置页的分组与排序

    func testSectionsFollowTheGroupOrderAndSortStably() {
        let rows = [
            LauncherFeatureRow(id: "b", group: .text, title: "B", symbolName: "x", order: 50),
            LauncherFeatureRow(id: "ctx", group: .emptyState, title: "C", symbolName: "x", order: 0),
            LauncherFeatureRow(id: "a", group: .text, title: "A", symbolName: "x", order: 10),
            LauncherFeatureRow(id: "c", group: .text, title: "C", symbolName: "x", order: 50),
            LauncherFeatureRow(id: "s", group: .search, title: "S", symbolName: "x", order: 0),
            LauncherFeatureRow(id: "a", group: .text, title: "重复的", symbolName: "x", order: 0),
        ]
        let sections = LauncherFeatureLayout.sections(rows)
        XCTAssertEqual(sections.map(\.group), [.search, .text, .emptyState], "按组的固定次序；没有行的组不出")
        XCTAssertEqual(sections[1].ids, ["a", "b", "c"], "组内按次序，同次序保持传入的先后；同一个 id 只留第一行")
        XCTAssertEqual(sections[1].rows[0].title, "A")
    }

    func testActionRowsGoToTheirGroupsInPanelOrder() {
        // 照注册顺序：会议（入会 10）在划词助手（翻译 10、解释 20）前面，剪贴板（二维码 50）在手机互传（50）前面。
        let rows = LauncherFeatureLayout.actionRows(
            text: [text("meeting.text.joinAndRecord", priority: 10, tool: "会议"),
                   text("clipboard.text.qrCode", priority: 50, tool: "剪贴板"),
                   text("selectiontranslate.text.translate", priority: 10, tool: "划词助手"),
                   text("selectiontranslate.text.explain", priority: 20, tool: "划词助手"),
                   text("phonetransfer.text.send", priority: 50, tool: "手机互传")],
            image: [image("screenshot.image.pin", priority: 20), image("screenshot.image.ocr", priority: 10)],
            file: [file("phonetransfer.file.send")])
        let builtIns = LauncherBuiltInFeature.allCases.map {
            LauncherFeatureRow(id: $0.id, group: $0.group, title: $0.rawValue, symbolName: $0.symbolName, order: $0.order)
        }
        let sections = Dictionary(uniqueKeysWithValues: LauncherFeatureLayout.sections(rows + builtIns).map { ($0.group, $0) })
        XCTAssertEqual(sections[.text]?.ids, [
            "suggest/runInTerminal", "action/meeting.text.joinAndRecord", "action/selectiontranslate.text.translate",
            "action/selectiontranslate.text.explain", "suggest/webSearch", "suggest/fileName",
            "action/clipboard.text.qrCode", "action/phonetransfer.text.send",
        ])
        XCTAssertEqual(sections[.image]?.ids, ["image/recognition", "action/screenshot.image.ocr", "action/screenshot.image.pin"])
        XCTAssertEqual(sections[.file]?.ids, ["path/openInTerminal", "path/copyPath", "action/phonetransfer.file.send"])
        XCTAssertEqual(sections[.text]?.rows.first { $0.id == "action/clipboard.text.qrCode" }?.toolName, "剪贴板")
        XCTAssertNil(sections[.text]?.rows.first { $0.id == "suggest/webSearch" }?.toolName, "快速入口自己的不写工具名")
    }

    func testSourceRowsNameTheirToolUnlessItIsTheSameName() {
        let history = LauncherFeatureLayout.sourceRow(sourceID: "clipboard", name: "剪贴板", toolName: "剪贴板", symbolName: "c")
        XCTAssertEqual(history.id, "source/clipboard")
        XCTAssertEqual(history.group, .search)
        XCTAssertNil(history.toolName, "来源名就是工具名时不重复写")
        let snippets = LauncherFeatureLayout.sourceRow(sourceID: "snippets", name: "片段", toolName: "剪贴板", symbolName: "c")
        XCTAssertEqual(snippets.toolName, "剪贴板")
        let sections = LauncherFeatureLayout.sections([snippets, history] + LauncherBuiltInFeature.allCases.map {
            LauncherFeatureRow(id: $0.id, group: $0.group, title: $0.rawValue, symbolName: $0.symbolName, order: $0.order)
        })
        XCTAssertEqual(sections.first?.ids, ["source/apps", "source/commands", "source/snippets", "source/clipboard",
                                             "source/files", "source/path"], "模块的来源在命令和文件之间，按传入的先后")
    }

    func testSectionButtonOffersTurningAllOnWhenAnyIsOff() {
        let section = LauncherFeatureSection(group: .instant, rows: [
            LauncherFeatureRow(id: "instant/url", group: .instant, title: "U", symbolName: "x", order: 0),
            LauncherFeatureRow(id: "instant/email", group: .instant, title: "E", symbolName: "x", order: 1),
        ])
        XCTAssertFalse(section.offersEnableAll(in: .allEnabled), "全开着：「全部关闭」")
        XCTAssertTrue(section.offersEnableAll(in: off("instant/email")), "有关着的：「全部打开」")
        XCTAssertFalse(section.offersEnableAll(in: off("instant/color")), "别的组关着的不算")
        let allOff = LauncherFeatureSet.allEnabled.setting(section.ids, enabled: false)
        XCTAssertTrue(section.offersEnableAll(in: allOff))
        XCTAssertFalse(section.offersEnableAll(in: allOff.setting(section.ids, enabled: true)))
    }

    // MARK: - 来源：前缀跟着失效

    func testTurnedOffSourceLosesItsPrefix() {
        let loaded: Set<String> = ["apps", "commands", "files", "clipboard", "snippets"]
        let prefixes = off("source/files").prefixes(LauncherQuery.defaultPrefixBySource, loadedSources: loaded)
        XCTAssertNil(prefixes["files"])
        XCTAssertEqual(prefixes["apps"], "a")
        XCTAssertNil(prefixes["sessions"], "没装进来的来源本来就不生效")
        let query = LauncherQuery.parse("f readme", prefixBySource: prefixes)
        XCTAssertTrue(query.isUnscoped, "关掉文件后 `f readme` 按普通文字处理")
        XCTAssertEqual(query.text, "f readme")
        XCTAssertNil(LauncherFilePolicy.request(for: query, hasCalculation: false, features: off("source/files")), "也不搜文件")
        XCTAssertNotNil(LauncherFilePolicy.request(for: LauncherQuery.parse("f readme"), hasCalculation: false),
                        "开着时照旧只搜文件")
        // 普通文字的建议照出，但「搜文件名」不出（文件关着）。
        let result = LauncherSuggestionPolicy.plan(for: query, hasCalculation: false, hasRecognition: false, clock: clock,
                                                   features: off("source/files"))
        XCTAssertEqual(result.fallbackKinds, [.word], "「f readme」两个英文词：学习也提前")
        XCTAssertEqual(result.fallbackBuiltIns.map(\.id), ["launcher.webSearch"])
        let commandsOff = LauncherQuery.parse("> 截图", prefixBySource: off("source/commands")
            .prefixes(LauncherQuery.defaultPrefixBySource, loadedSources: loaded))
        XCTAssertTrue(commandsOff.isUnscoped)
    }

    func testBuiltInFallbacksFollowTheirSwitches() {
        XCTAssertEqual(LauncherFeatureRules.fallbackBuiltIns(.allEnabled).map(\.id), ["launcher.webSearch", "launcher.findFiles"])
        XCTAssertEqual(LauncherFeatureRules.fallbackBuiltIns(off("suggest/webSearch")).map(\.id), ["launcher.findFiles"])
        XCTAssertEqual(LauncherFeatureRules.fallbackBuiltIns(off("suggest/fileName")).map(\.id), ["launcher.webSearch"])
        XCTAssertEqual(plan("周末的计划", features: off("suggest/webSearch", "suggest/fileName")).fallbackBuiltIns, [])
        XCTAssertEqual(plan("周末的计划", features: .allEnabled).fallbackBuiltIns.count, 2)
        XCTAssertEqual(plan("1+1", features: off("suggest/webSearch"), calculation: true).fallbackBuiltIns.map(\.id),
                       ["launcher.findFiles"], "有计算结果时也按开关")
    }

    // MARK: - 动作：三处都不出，派生的也不出

    func testTurnedOffActionsLeaveTextImageAndFileLists() {
        let features = off("action/selectiontranslate.text.translate", "action/screenshot.image.pin",
                           "action/phonetransfer.file.send")
        let texts = LauncherCommandCatalog.textActions(declared: [
            text("selectiontranslate.text.translate", priority: 10, imageTextPriority: 15),
            text("clipboard.text.qrCode"),
        ])
        let images = LauncherCommandCatalog.imageActions(declared: [image("screenshot.image.ocr"), image("screenshot.image.pin")])
        let files = LauncherCommandCatalog.fileActions(declared: [file("phonetransfer.file.send")])
        XCTAssertEqual(features.enabledActions(texts).map(\.command.id), ["clipboard.text.qrCode"])
        XCTAssertEqual(features.enabledActions(images).map(\.command.id), ["screenshot.image.ocr"])
        XCTAssertEqual(features.enabledActions(files).map(\.command.id), [])
        // 「翻译图里的文字」由「翻译」派生（`imageTextPriority`）：它从过滤后的文字动作里来，关掉翻译就没有了。
        XCTAssertEqual(features.enabledActions(texts).filter { $0.command.suggestion.imageTextPriority != nil }.count, 0)
        XCTAssertEqual(LauncherFeatureSet.allEnabled.enabledActions(texts)
            .filter { $0.command.suggestion.imageTextPriority != nil }.count, 1)
        // 同一个模块的另外两处（文字、图片的「发到手机」）各是各的 id，不受文件那一项影响。
        let phone = [text("phonetransfer.text.send")]
        XCTAssertEqual(features.enabledActions(phone).count, 1)
    }

    // MARK: - 直接给结果

    func testInstantSuggestionsFollowTheirSwitches() throws {
        XCTAssertEqual(plan("example.com/path", features: off("instant/url")).leading, [])
        XCTAssertEqual(plan("example.com/path", features: off("instant/url")).fallbackKinds, [.url], "类别照旧，二维码照样提前")
        XCTAssertEqual(plan("claude.ai", features: off("instant/url")).fallbackLeading, [], "有歧义的网址也不出「打开」")
        XCTAssertEqual(plan("claude.ai", features: off("instant/url")).rankedFallbackLimit, LauncherSuggestionRanking.maxRows)
        XCTAssertEqual(plan("me@baobox.dev", features: off("instant/email")).leading, [])
        XCTAssertEqual(plan("#17A398", features: off("instant/color")).leading, [])
        XCTAssertEqual(plan("#17A398", features: off("instant/email")).leading.count, 1, "别的开关不影响")
        let long = String(repeating: "这是一段很长的文字，", count: 10)
        XCTAssertEqual(plan(long, features: off("instant/wordCount")).leading, [])
        XCTAssertEqual(plan(long, features: off("instant/wordCount")).fallbackKinds, [.longText], "总结、润色照样提前")
        XCTAssertEqual(plan(long, features: .allEnabled).leading.count, 1)
    }

    func testReminderSwitchCoversTheRowAndTheList() {
        let sentence = "20 分钟后提醒我取快递"
        XCTAssertEqual(plan(sentence, features: .allEnabled).top.count, 1)
        let offPlan = plan(sentence, features: off("instant/reminder"))
        XCTAssertEqual(offPlan.top, [], "不出「到时提醒我」")
        XCTAssertEqual(offPlan.fallbackKinds, [.plainText], "输入仍按普通文字给建议")
        XCTAssertTrue(plan("提醒", features: .allEnabled).showsReminders)
        XCTAssertFalse(plan("提醒", features: off("instant/reminder")).showsReminders, "也不列出待响的提醒")
    }

    func testRunInTerminalSwitch() {
        XCTAssertEqual(plan("git status", features: .allEnabled).fallbackLeading, [.runInTerminal("git status")])
        let offPlan = plan("git status", features: off("suggest/runInTerminal"))
        XCTAssertEqual(offPlan.fallbackLeading, [])
        XCTAssertEqual(offPlan.rankedFallbackLimit, LauncherSuggestionRanking.maxRows, "不再占名额")
        XCTAssertEqual(offPlan.fallbackKinds, [.plainText, .command])
        // 开着时和第 10 步一致：放得下完整显示（最多 6 行）的才出；关着时哪种都不出（也就没有上膛、完整显示）。
        let short = "docker run --rm -it node:20 sh -c 'npm ci && npm test'"
        let long = "git commit -m '" + String(repeating: "很长的提交说明", count: 200) + "'"
        for command in [short, long] {
            let expected: [LauncherLeadingSuggestion] = LauncherConfirmText.commandLines(command) != nil
                ? [.runInTerminal(command)] : []
            XCTAssertEqual(plan(command, features: .allEnabled).fallbackLeading, expected, "开着：同第 10 步")
            XCTAssertEqual(plan(command, features: off("suggest/runInTerminal")).fallbackLeading, [], "关着：不出")
        }
        XCTAssertNotNil(LauncherConfirmText.commandLines(short))
    }

    func testCalculatorAndTextFormatSwitches() {
        let sum = LauncherQuery.parse("12*(3+4)")
        XCTAssertTrue(LauncherInstantPolicy.runsCalculator(sum))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(sum, features: off("instant/calculator")))
        let stamp = LauncherQuery.parse("1700000000")
        XCTAssertTrue(LauncherInstantPolicy.runsTextRecognition(stamp, hasCalculation: false))
        XCTAssertFalse(LauncherInstantPolicy.runsTextRecognition(stamp, hasCalculation: false, features: off("instant/textFormat")))
        XCTAssertTrue(LauncherInstantPolicy.runsTextRecognition(stamp, hasCalculation: false, features: off("instant/calculator")))
        // 计算关着：算式按普通文字给建议（引擎这时没有计算结果）。
        XCTAssertEqual(plan("12*(3+4)", features: off("instant/calculator")).fallbackKinds, [.plainText])
    }

    // MARK: - 路径

    func testPathSwitchTreatsPathsAsPlainText() {
        XCTAssertEqual(plan("/Users/qiao/a.txt", features: .allEnabled), .none, "开着：路径的事归路径行")
        let offPlan = plan("/Users/qiao/a.txt", features: off("source/path"))
        XCTAssertEqual(offPlan.fallbackKinds, [.plainText], "关着：按普通文字处理，仍有文字的建议")
        XCTAssertEqual(plan("~/Downloads", features: off("source/path")).fallbackKinds, [.plainText])
        XCTAssertTrue(LauncherInputClassifier.classify("/tmp").isPath)
        XCTAssertFalse(LauncherInputClassifier.classify("/tmp", recognizesPaths: false).isPath)
    }

    func testPathActionSwitches() {
        let folder = LauncherPathTarget(path: "/Users/me/项目", isDirectory: true)
        let fileTarget = LauncherPathTarget(path: "/Users/me/a.md", isDirectory: false)
        XCTAssertEqual(LauncherPathActionPlan.actions(for: folder, declaredPriorities: [], features: off("path/openInTerminal")),
                       [.copyPath])
        XCTAssertEqual(LauncherPathActionPlan.actions(for: folder, declaredPriorities: [],
                                                      features: off("path/openInTerminal", "path/copyPath")), [])
        XCTAssertEqual(LauncherPathActionPlan.actions(for: fileTarget, declaredPriorities: [50], features: off("path/copyPath")),
                       [.declared(0)])
        XCTAssertEqual(LauncherPathActionPlan.actions(for: fileTarget, declaredPriorities: [50, 60, 70],
                                                      features: off("path/copyPath")),
                       [.declared(0), .declared(1), .declared(2)], "复制路径让出的位置给模块的动作")
    }

    // MARK: - 建议全关时的那行小字

    func testSuggestionsOffNoticeOnlyWhenEverythingIsOffAndNothingShows() {
        let allTextOff = off("suggest/webSearch", "suggest/fileName", "suggest/runInTerminal")
        let query = LauncherQuery.parse("周末的计划")
        XCTAssertTrue(LauncherFeatureRules.showsSuggestionsOff(query: query, rowCount: 0, textActionCount: 0, features: allTextOff))
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: query, rowCount: 1, textActionCount: 0, features: allTextOff),
                       "有行时不提示")
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: query, rowCount: 0, textActionCount: 1, features: allTextOff),
                       "还有开着的文字动作：照旧「没有结果」")
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: query, rowCount: 0, textActionCount: 0,
                                                                features: off("suggest/fileName", "suggest/runInTerminal")),
                       "上网搜开着")
        XCTAssertTrue(LauncherFeatureRules.showsSuggestionsOff(query: query, rowCount: 0, textActionCount: 0,
                                                               features: off("suggest/webSearch", "source/files",
                                                                             "suggest/runInTerminal")),
                      "搜文件名开着、但文件关着：它出不来，也算全关")
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: LauncherQuery.parse("周"), rowCount: 0, textActionCount: 0,
                                                                features: allTextOff), "一个字本来就没有建议")
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: LauncherQuery.parse("c 周末"), rowCount: 0,
                                                                textActionCount: 0, features: allTextOff), "打了前缀")
        XCTAssertFalse(LauncherFeatureRules.showsSuggestionsOff(query: LauncherQuery.parse(""), rowCount: 0, textActionCount: 0,
                                                                features: allTextOff), "空输入照旧显示提示")
    }

    func testImageSuggestionsOffOnlyWhenEveryImageItemIsOff() {
        let recognitionOff = off("image/recognition")
        XCTAssertTrue(LauncherFeatureRules.showsImageSuggestionsOff(rowCount: 0, imageActionCount: 0, imageTextActionCount: 0,
                                                                    features: recognitionOff), "全关")
        XCTAssertFalse(LauncherFeatureRules.showsImageSuggestionsOff(rowCount: 0, imageActionCount: 0, imageTextActionCount: 0,
                                                                     features: .allEnabled),
                       "识别开着（图里没认出东西时也是一行都没有）：照旧「没有结果」")
        XCTAssertFalse(LauncherFeatureRules.showsImageSuggestionsOff(rowCount: 0, imageActionCount: 1, imageTextActionCount: 0,
                                                                     features: recognitionOff), "还有开着的图片动作（筛选词没对上）")
        XCTAssertFalse(LauncherFeatureRules.showsImageSuggestionsOff(rowCount: 0, imageActionCount: 0, imageTextActionCount: 1,
                                                                     features: recognitionOff), "「翻译图里的文字」还开着")
        XCTAssertFalse(LauncherFeatureRules.showsImageSuggestionsOff(rowCount: 1, imageActionCount: 0, imageTextActionCount: 0,
                                                                     features: recognitionOff), "有行时不提示")
        // 「图里的文字」来自过滤后的文字动作：关掉翻译后带 `imageTextPriority` 的就没有了。
        let texts = [text("selectiontranslate.text.translate", priority: 10, imageTextPriority: 15), text("clipboard.text.qrCode")]
        let derived = off("action/selectiontranslate.text.translate").enabledActions(texts)
            .filter { $0.command.suggestion.imageTextPriority != nil }
        XCTAssertTrue(derived.isEmpty)
    }

    // MARK: - 「带上你选中的文字」关着时不读

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func hit() { lock.lock(); value += 1; lock.unlock() }
    }

    func testSelectionIsNotReadWhenItsSwitchIsOff() {
        let counter = ReadCounter()
        let reader: @Sendable (pid_t, TimeInterval) -> LauncherSelectionOutcome = { _, _ in
            counter.hit()
            return .text("选中的")
        }
        let fetcher = LauncherSelectionFetcher(budget: 0.05, grace: 0.02, queue: DispatchQueue(label: "test.features.fetch"))
        var delivered = 0
        XCTAssertEqual(fetcher.begin(features: off("context/selection"), pid: 123, read: reader) { _ in delivered += 1 }, .off)
        XCTAssertEqual(fetcher.begin(features: .allEnabled, pid: nil, read: reader) { _ in delivered += 1 }, .noApp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(counter.count, 0, "关着时不调取词函数（不做那次辅助功能调用）")
        XCTAssertEqual(delivered, 0)
        XCTAssertFalse(fetcher.isReading)

        let done = expectation(description: "read")
        var outcome: LauncherSelectionOutcome?
        XCTAssertEqual(fetcher.begin(features: off("context/clipboard"), pid: 123, read: reader) { read in
            outcome = read.outcome
            done.fulfill()
        }, .reading, "别的开关不影响")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(outcome, .text("选中的"))
        XCTAssertEqual(LauncherSelectionStart.reading.logLabel, "reading")
        XCTAssertEqual(LauncherSelectionStart.off.logLabel, "off")
        XCTAssertEqual(LauncherSelectionStart.noApp.logLabel, "no app")
    }
}
