import Foundation
import XCTest

/// 文字动作的适用性判断（`LauncherCommand.appliesTo`）与「排在对应建议后面」的文字动作（`traits.leading`）
/// （docs/launcher/TECH_DESIGN.md §5.4「适用性判断」，第 10 步）。
@MainActor
final class LauncherActionApplicabilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - appliesTo

    func testCommandsApplyByDefault() {
        let command = LauncherCommand.textAction(id: "a", title: "A", symbolName: "a") { _ in }
        XCTAssertNil(command.appliesTo)
        XCTAssertTrue(command.applies(to: ""))
        XCTAssertTrue(command.applies(to: "随便什么"))
        let plain = LauncherCommand(id: "b", title: "B", symbolName: "b") { _ in }
        XCTAssertTrue(plain.applies(to: "x"), "不是文字动作的命令也不受影响")
    }

    func testTextActionFactoryKeepsTheJudgement() {
        let command = LauncherCommand.textAction(id: "meeting.text.joinAndRecord", title: "入会", symbolName: "video",
                                                 appliesTo: { $0.contains("zoom.us/j/") }) { _ in }
        XCTAssertTrue(command.isTextAction, "加了判断仍是文字动作")
        XCTAssertTrue(command.applies(to: "https://zoom.us/j/123"))
        XCTAssertFalse(command.applies(to: "https://example.com"))
    }

    func testTraitsDefaultToNotLeading() {
        XCTAssertFalse(LauncherSuggestionTraits().leading)
        XCTAssertTrue(LauncherSuggestionTraits(kinds: [.url], leading: true).leading)
        XCTAssertNotEqual(LauncherSuggestionTraits(), LauncherSuggestionTraits(leading: true))
    }

    // MARK: - leading

    private let candidates: [LauncherSuggestionCandidate] = [
        LauncherSuggestionCandidate(id: "clipboard.text.qrCode",
                                    traits: LauncherSuggestionTraits(priority: 50, boostedKinds: [.url])),
        LauncherSuggestionCandidate(id: "meeting.text.joinAndRecord",
                                    traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.translate", traits: LauncherSuggestionTraits(priority: 10)),
        LauncherSuggestionCandidate(id: "other.leading.late",
                                    traits: LauncherSuggestionTraits(kinds: [.url], priority: 30, leading: true)),
        LauncherSuggestionCandidate(id: "other.leading.early",
                                    traits: LauncherSuggestionTraits(kinds: [.url], priority: 5, leading: true)),
        LauncherSuggestionCandidate(id: "other.leading.plain",
                                    traits: LauncherSuggestionTraits(kinds: [.plainText], priority: 1, leading: true)),
    ]

    private func ids(_ indices: [Int]) -> [String] { indices.map { candidates[$0].id } }

    func testLeadingActionsNeverEnterTheFallbackGroup() {
        let order = ids(LauncherSuggestionRanking.order(candidates, kinds: [.url], records: LauncherUsageRecords(), now: now))
        XCTAssertEqual(order, ["clipboard.text.qrCode", "selectiontranslate.text.translate"])
    }

    func testLeadingOrderIsByTierThenDeclarationAndIgnoresUsage() {
        XCTAssertEqual(ids(LauncherSuggestionRanking.leadingOrder(candidates, kinds: [.url])),
                       ["other.leading.early", "meeting.text.joinAndRecord", "other.leading.late"])
        XCTAssertEqual(ids(LauncherSuggestionRanking.leadingOrder(candidates, kinds: [.plainText])), ["other.leading.plain"])
        XCTAssertEqual(LauncherSuggestionRanking.leadingOrder(candidates, kinds: [.email]), [])
        XCTAssertEqual(LauncherSuggestionRanking.leadingOrder([], kinds: [.url]), [])
    }

    /// 会议链接：输入分类认成网址（「入会并开始会议记录」只对网址声明），会议模块的 `MeetingLinkParser` 也认得 ——
    /// 两样都成立这一行才出。普通网址、写在一段话里的链接不出。
    func testMeetingLinksAreURLsTheMeetingParserKnows() {
        let links = ["https://zoom.us/j/123456789?pwd=abc", "meet.google.com/abc-defg-hij",
                     "https://meeting.tencent.com/dm/AbCdEf", "zoommtg://zoom.us/join?confno=123456789",
                     "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x", "https://vc.feishu.cn/j/123456789"]
        for link in links {
            XCTAssertEqual(LauncherInputClassifier.classify(link).kinds, [.url], link)
            XCTAssertFalse(MeetingLinkParser.links(in: link).isEmpty, link)
        }
        for url in ["https://example.com/meeting", "https://zoom.us/pricing", "https://meet.google.com/"] {
            XCTAssertTrue(MeetingLinkParser.links(in: url).isEmpty, url)
        }
        XCTAssertNotEqual(LauncherInputClassifier.classify("明天的会 https://zoom.us/j/123").kinds, [.url], "一段话不是网址")
    }

    // MARK: - 第 10 步之后的默认次序（文档 §5.4 的表）

    /// 和各模块的声明、注册顺序一样（剪贴板 → Claude Code → Codex → 会议 → 划词助手 → 手机互传，最后是快速入口自己的两条），
    /// Claude Code、Codex 都装了。
    private let allActions: [LauncherSuggestionCandidate] = [
        LauncherSuggestionCandidate(id: "clipboard.text.saveSnippet", traits: LauncherSuggestionTraits(priority: 50)),
        LauncherSuggestionCandidate(id: "clipboard.text.pinCard", traits: LauncherSuggestionTraits(priority: 50)),
        LauncherSuggestionCandidate(id: "clipboard.text.qrCode",
                                    traits: LauncherSuggestionTraits(priority: 50, boostedKinds: [.url])),
        LauncherSuggestionCandidate(id: "claudecode.text.handOff",
                                    traits: LauncherSuggestionTraits(priority: 55, boostedKinds: [.longText])),
        LauncherSuggestionCandidate(id: "aitools.text.handOff", traits: LauncherSuggestionTraits(priority: 56)),
        LauncherSuggestionCandidate(id: "meeting.text.joinAndRecord",
                                    traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.translate", traits: LauncherSuggestionTraits(priority: 10)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.learn",
                                    traits: LauncherSuggestionTraits(kinds: [.word], priority: 10, boostedKinds: [.word])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.explain", traits: LauncherSuggestionTraits(priority: 20)),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.summarize",
                                    traits: LauncherSuggestionTraits(kinds: [.plainText, .longText], priority: 20,
                                                                     boostedKinds: [.longText])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.polish",
                                    traits: LauncherSuggestionTraits(kinds: [.plainText, .longText], priority: 60,
                                                                     boostedKinds: [.longText])),
        LauncherSuggestionCandidate(id: "selectiontranslate.text.speak", traits: LauncherSuggestionTraits(priority: 65)),
        LauncherSuggestionCandidate(id: "phonetransfer.text.send", traits: LauncherSuggestionTraits(priority: 50)),
        LauncherSuggestionRanking.webSearch,
        LauncherSuggestionRanking.findFiles,
    ]

    private func defaultOrder(_ kinds: Set<LauncherTextKind>, limit: Int = LauncherSuggestionRanking.maxRows) -> [String] {
        LauncherSuggestionRanking.order(allActions, kinds: kinds, records: LauncherUsageRecords(), now: now, limit: limit)
            .map { allActions[$0].id }
    }

    func testTheCapIsTwelve() {
        XCTAssertEqual(LauncherSuggestionRanking.maxRows, 12, "第 10 步从 8 放宽到 12：第 9 行以后的往下滚 / ↓ 看得到")
    }

    /// 普通文字：用户认可的那张清单仍是前 8 行，第 10 步加的接在后面，12 行之内都出；朗读第 13，不出（用过会往前挪）。
    func testPlainTextKeepsTheApprovedEightAndTheNewOnesFollow() {
        let approved = ["selectiontranslate.text.translate", "selectiontranslate.text.explain", "selectiontranslate.text.summarize",
                        "launcher.webSearch", "launcher.findFiles", "clipboard.text.saveSnippet", "clipboard.text.pinCard",
                        "clipboard.text.qrCode"]
        XCTAssertEqual(defaultOrder([.plainText]), approved + [
            "phonetransfer.text.send", "claudecode.text.handOff", "aitools.text.handOff", "selectiontranslate.text.polish",
        ])
        XCTAssertEqual(defaultOrder([.plainText], limit: 20).last, "selectiontranslate.text.speak", "朗读排第 13")
        XCTAssertEqual(Array(defaultOrder([.plainText]).prefix(8)), approved)
    }

    /// 没装 Codex（它不声明）：朗读进到第 12 行。
    func testWithoutCodexReadAloudMakesTheCut() {
        let withoutCodex = allActions.filter { $0.id != "aitools.text.handOff" }
        let order = LauncherSuggestionRanking.order(withoutCodex, kinds: [.plainText], records: LauncherUsageRecords(), now: now)
            .map { withoutCodex[$0].id }
        XCTAssertEqual(order.count, 12)
        XCTAssertEqual(order.last, "selectiontranslate.text.speak")
    }

    func testWordGetsLearnFirstAndEveryOtherAction() {
        XCTAssertEqual(defaultOrder([.word]), [
            "selectiontranslate.text.learn", "selectiontranslate.text.translate", "selectiontranslate.text.explain",
            "launcher.webSearch", "launcher.findFiles", "clipboard.text.saveSnippet", "clipboard.text.pinCard",
            "clipboard.text.qrCode", "phonetransfer.text.send", "claudecode.text.handOff", "aitools.text.handOff",
            "selectiontranslate.text.speak",
        ])
    }

    func testLongTextPutsClaudeCodeSecond() {
        XCTAssertEqual(defaultOrder([.longText]), [
            "selectiontranslate.text.summarize", "claudecode.text.handOff", "selectiontranslate.text.polish",
            "selectiontranslate.text.translate", "selectiontranslate.text.explain", "launcher.webSearch", "launcher.findFiles",
            "clipboard.text.saveSnippet", "clipboard.text.pinCard", "clipboard.text.qrCode", "phonetransfer.text.send",
            "aitools.text.handOff",
        ], "朗读第 13，不出")
    }

    func testURLGetsSendToPhoneEighthAndTheMeetingActionStaysOut() {
        XCTAssertEqual(defaultOrder([.url]), [
            "clipboard.text.qrCode", "selectiontranslate.text.translate", "selectiontranslate.text.explain",
            "launcher.webSearch", "launcher.findFiles", "clipboard.text.saveSnippet", "clipboard.text.pinCard",
            "phonetransfer.text.send", "claudecode.text.handOff", "aitools.text.handOff", "selectiontranslate.text.speak",
        ], "总结、润色不对网址，一共 11 行")
        XCTAssertEqual(LauncherSuggestionRanking.leadingOrder(allActions, kinds: [.url]).map { allActions[$0].id },
                       ["meeting.text.joinAndRecord"])
    }

    func testEmailAndColorGetElevenRows() {
        let expected = ["selectiontranslate.text.translate", "selectiontranslate.text.explain", "launcher.webSearch",
                        "launcher.findFiles", "clipboard.text.saveSnippet", "clipboard.text.pinCard", "clipboard.text.qrCode",
                        "phonetransfer.text.send", "claudecode.text.handOff", "aitools.text.handOff", "selectiontranslate.text.speak"]
        XCTAssertEqual(defaultOrder([.email]), expected)
        XCTAssertEqual(defaultOrder([.color]), expected)
    }

    /// 排在兜底组第一条的（在终端里运行、有歧义的网址的「打开」）算在 12 行里：交给排序的只剩 11 行。
    func testCommandLeavesElevenRankedRowsAfterRunInTerminal() {
        let plan = LauncherSuggestionPolicy.plan(for: LauncherQuery.parse("git status"), hasCalculation: false,
                                                 hasRecognition: false)
        XCTAssertEqual(plan.fallbackLeading, [.runInTerminal("git status")])
        XCTAssertEqual(plan.rankedFallbackLimit, 11)
        XCTAssertEqual(defaultOrder(plan.fallbackKinds ?? [], limit: plan.rankedFallbackLimit), [
            "selectiontranslate.text.translate", "selectiontranslate.text.explain", "selectiontranslate.text.summarize",
            "launcher.webSearch", "launcher.findFiles", "clipboard.text.saveSnippet", "clipboard.text.pinCard",
            "clipboard.text.qrCode", "phonetransfer.text.send", "claudecode.text.handOff", "aitools.text.handOff",
        ])
        let ambiguous = LauncherSuggestionPolicy.plan(for: LauncherQuery.parse("claude.ai"), hasCalculation: false,
                                                      hasRecognition: false)
        XCTAssertEqual(ambiguous.rankedFallbackLimit, 11)
    }

    func testSameTierKeepsTheDeclarationOrder() {
        let same = [
            LauncherSuggestionCandidate(id: "first", traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
            LauncherSuggestionCandidate(id: "second", traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
        ]
        XCTAssertEqual(LauncherSuggestionRanking.leadingOrder(same, kinds: [.url]), [0, 1])
    }
}
