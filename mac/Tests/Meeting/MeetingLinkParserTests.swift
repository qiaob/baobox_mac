import Foundation
import XCTest

/// 从日历事件里找会议链接（docs/meeting/TECH_DESIGN.md §5）。
final class MeetingLinkParserTests: XCTestCase {

    private func provider(_ text: String) -> MeetingLinkProvider? {
        MeetingLinkParser.links(in: text).first?.provider
    }

    func testRecognisesEachProvider() {
        XCTAssertEqual(provider("https://us02web.zoom.us/j/123456789?pwd=abc"), .zoom)
        XCTAssertEqual(provider("zoommtg://zoom.us/join?confno=123"), .zoom)
        XCTAssertEqual(provider("https://meeting.tencent.com/dm/AbCdEf"), .tencent)
        XCTAssertEqual(provider("wemeet://page/inmeeting?meeting_code=123"), .tencent)
        XCTAssertEqual(provider("https://meeting.dingtalk.com/j/abc123"), .dingtalk)
        XCTAssertEqual(provider("https://meet.google.com/abc-defg-hij"), .googleMeet)
        XCTAssertEqual(provider("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"), .teams)
        XCTAssertEqual(provider("https://teams.live.com/meet/9876543210"), .teams)
        XCTAssertEqual(provider("https://vc.feishu.cn/j/123456789"), .feishu)
        XCTAssertEqual(provider("https://company.webex.com/meet/someone"), .webex)
    }

    func testPagesOfTheSameSitesThatAreNotMeetingsAreIgnored() {
        XCTAssertNil(provider("https://zoom.us/u/abcdef"), "当地拨号号码页")
        XCTAssertNil(provider("https://www.dingtalk.com/download"))
        XCTAssertNil(provider("https://meet.google.com/"))
        XCTAssertNil(provider("https://help.webex.com/article/123"))
        XCTAssertNil(provider("https://teams.microsoft.com/v2/"))
        XCTAssertNil(provider("https://example.com/j/123"))
        XCTAssertNil(provider("msteams://teams.microsoft.com/l/chat/0/0"))
    }

    func testLinksWithoutASchemeInTheLocation() throws {
        let link = try XCTUnwrap(MeetingLinkParser.find(url: nil, location: "会议室 3 / meet.google.com/abc-defg-hij", notes: nil))
        XCTAssertEqual(link, MeetingLink(provider: .googleMeet, url: try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))))
    }

    func testEventURLWinsOverLocationAndNotes() {
        let link = MeetingLinkParser.find(url: "https://zoom.us/j/1", location: "https://meet.google.com/aaa-bbbb-ccc",
                                          notes: "https://vc.feishu.cn/j/2")
        XCTAssertEqual(link?.provider, .zoom)
        XCTAssertEqual(MeetingLinkParser.find(url: "", location: nil, notes: "加入：https://vc.feishu.cn/j/2。")?.provider, .feishu)
        XCTAssertNil(MeetingLinkParser.find(url: nil, location: "3 楼大会议室", notes: "没有链接"))
    }

    func testSafeLinksAndGoogleRedirectsAreUnwrapped() {
        let safe = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F123456789&data=abc"
        XCTAssertEqual(MeetingLinkParser.links(in: safe).first?.url.absoluteString, "https://us02web.zoom.us/j/123456789")
        let google = "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D"
        XCTAssertEqual(MeetingLinkParser.links(in: google).first?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testHTMLNotesBracketsAndTrailingPunctuation() {
        let html = "<a href=\"https://us02web.zoom.us/j/123?pwd=a&amp;from=addon\">加入 Zoom 会议</a>"
        XCTAssertEqual(MeetingLinkParser.links(in: html).first?.url.absoluteString, "https://us02web.zoom.us/j/123?pwd=a&from=addon")
        XCTAssertEqual(MeetingLinkParser.links(in: "（https://vc.feishu.cn/j/123）").first?.url.absoluteString,
                       "https://vc.feishu.cn/j/123")
        XCTAssertEqual(MeetingLinkParser.links(in: "(https://zoom.us/j/123).").first?.url.absoluteString,
                       "https://zoom.us/j/123")
        XCTAssertEqual(MeetingLinkParser.cleaned("https://example.com/a_(b)"), "https://example.com/a_(b)", "配对的括号留着")
        XCTAssertEqual(MeetingLinkParser.cleaned("https://zoom.us/j/1**"), "https://zoom.us/j/1")
    }

    func testTheSameLinkCountsOnceAndOrderIsKept() {
        let text = "主会场 https://zoom.us/j/1 备用 https://meet.google.com/abc-defg-hij 再贴一次 https://zoom.us/j/1"
        XCTAssertEqual(MeetingLinkParser.links(in: text).map(\.provider), [.zoom, .googleMeet])
    }
}
