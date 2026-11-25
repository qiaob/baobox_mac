import Foundation
import XCTest

/// 文字动作的适用性判断（`LauncherCommand.appliesTo`）与「排在对应建议后面」的文字动作（`traits.leading`）
/// （docs/launcher/TECH_DESIGN.md §5.4「适用性判断」，PR 10）。
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

    func testSameTierKeepsTheDeclarationOrder() {
        let same = [
            LauncherSuggestionCandidate(id: "first", traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
            LauncherSuggestionCandidate(id: "second", traits: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true)),
        ]
        XCTAssertEqual(LauncherSuggestionRanking.leadingOrder(same, kinds: [.url]), [0, 1])
    }
}
