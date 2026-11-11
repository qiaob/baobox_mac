import Foundation
import XCTest

/// 会议检测的纯逻辑（docs/meeting/TECH_DESIGN.md §5 规则 2）：谁是会议 App、每次采样的信号、浏览器里的会议网站、检测状态机。
final class MeetingDetectionTests: XCTestCase {
    private let zoom = "us.zoom.xos"
    private let dingTalk = "com.alibaba.DingTalkMac"
    private let chrome = "com.google.Chrome"

    func testHostAppPathFoldsHelpersIntoTheirApp() {
        XCTAssertEqual(MeetingDetectionApps.hostAppPath(
            forExecutable: "/Applications/DingTalk.app/Contents/Frameworks/Tblive.app/Contents/MacOS/Tblive"),
                       "/Applications/DingTalk.app")
        XCTAssertNil(MeetingDetectionApps.hostAppPath(
            forExecutable: "/System/Library/Frameworks/WebKit.framework/XPCServices/GPU.app/Contents/MacOS/GPU"))
        XCTAssertNil(MeetingDetectionApps.hostAppPath(forExecutable: "/usr/libexec/coreaudiod"))
        XCTAssertNil(MeetingDetectionApps.hostAppPath(forExecutable: "/opt/tool/bin/rec"))
    }

    func testMeetingAppsAndTheOrderToAskIn() {
        XCTAssertTrue(MeetingDetectionApps.isMeetingApp(zoom))
        XCTAssertTrue(MeetingDetectionApps.isMeetingApp(MeetingWebSites.meet))
        XCTAssertFalse(MeetingDetectionApps.isMeetingApp(chrome))
        XCTAssertTrue(MeetingDetectionApps.isDedicated(zoom))
        XCTAssertTrue(MeetingDetectionApps.isDedicated(MeetingWebSites.teams))
        XCTAssertFalse(MeetingDetectionApps.isDedicated(dingTalk))
        XCTAssertEqual(MeetingDetectionApps.ordered([dingTalk, zoom, MeetingWebSites.meet, chrome], frontmost: nil),
                       [zoom, MeetingWebSites.meet, dingTalk])
        XCTAssertEqual(MeetingDetectionApps.ordered([dingTalk, zoom], frontmost: dingTalk), [dingTalk, zoom], "前台的先问")
        XCTAssertEqual(MeetingDetectionApps.ordered([zoom], frontmost: chrome), [zoom])
    }

    func testSignalsFromProcessesMicrophoneAndWebsites() {
        let signals = MeetingDetectionApps.signals(
            runningBundleIDs: ["5ZSL2CJU2T.com.dingtalk.mac.tblive", "com.apple.finder"],
            microphoneApps: [zoom, dingTalk, "com.apple.VoiceMemos"], unattributedMicrophone: false,
            webMeetings: [MeetingWebSites.meet, "web.unknown"], frontmost: nil, ignored: [])
        XCTAssertEqual(signals, [dingTalk: .meetingProcess, zoom: .microphone, MeetingWebSites.meet: .microphone],
                       "会议进程优先于麦克风；不认识的 App、网站不算")

        let unattributed = MeetingDetectionApps.signals(runningBundleIDs: [], microphoneApps: [],
                                                        unattributedMicrophone: true, frontmost: zoom, ignored: [])
        XCTAssertEqual(unattributed, [zoom: .microphone], "说不清是谁在录：算到前台的会议 App 头上")
        XCTAssertEqual(MeetingDetectionApps.signals(runningBundleIDs: [], microphoneApps: [], unattributedMicrophone: true,
                                                    frontmost: chrome, ignored: []), [:])

        let ignored = MeetingDetectionApps.signals(runningBundleIDs: [], microphoneApps: [zoom, dingTalk],
                                                   unattributedMicrophone: false, frontmost: nil, ignored: [zoom])
        XCTAssertEqual(ignored, [dingTalk: .microphone])
    }

    func testWebsitesFromBrowserWindowTitles() {
        XCTAssertEqual(MeetingWebSites.site(forTitle: "Meet - abc-defg-hij - Google Chrome"), MeetingWebSites.meet)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "Google Meet"), MeetingWebSites.meet)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "会议 | Microsoft Teams"), MeetingWebSites.teams)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "Zoom Meeting - Safari"), MeetingWebSites.zoom)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "腾讯会议 - 正在开会"), MeetingWebSites.tencent)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "飞书会议"), MeetingWebSites.feishu)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "Cisco Webex Meetings"), MeetingWebSites.webex)
        XCTAssertEqual(MeetingWebSites.site(forTitle: "Jitsi Meet"), MeetingWebSites.jitsi)
        XCTAssertNil(MeetingWebSites.site(forTitle: "Zoom 的使用说明 - 博客"), "只认会议页的标题")
        XCTAssertNil(MeetingWebSites.site(forTitle: "   "))
        XCTAssertEqual(MeetingWebSites.sites(inTitles: ["Google Meet", "收件箱", "Jitsi Meet"]),
                       [MeetingWebSites.meet, MeetingWebSites.jitsi])
    }

    func testWebLatchRemembersASiteWhileThatBrowserKeepsRecording() {
        var latch = MeetingWebLatch()
        XCTAssertEqual(latch.update(recordingBrowsers: [chrome], unattributed: false, matches: [chrome: [MeetingWebSites.meet]]),
                       [MeetingWebSites.meet])
        XCTAssertEqual(latch.update(recordingBrowsers: [chrome], unattributed: false, matches: [:]), [MeetingWebSites.meet],
                       "标题认不出了也还算")
        XCTAssertEqual(latch.update(recordingBrowsers: [], unattributed: false, matches: [:]), [], "松开麦克风就忘")

        // 说不清是谁在录（Safari）：认在前台浏览器头上，说不清的录音停了才忘。
        let safari = "com.apple.Safari"
        XCTAssertEqual(latch.update(recordingBrowsers: [], unattributed: true, matches: [safari: [MeetingWebSites.teams]]),
                       [MeetingWebSites.teams])
        XCTAssertEqual(latch.update(recordingBrowsers: [], unattributed: true, matches: [:]), [MeetingWebSites.teams])
        XCTAssertEqual(latch.update(recordingBrowsers: [], unattributed: false, matches: [:]), [])
    }

    // MARK: - 状态机

    private func at(_ seconds: TimeInterval) -> Date {
        localDate(10, 0, 0).addingTimeInterval(seconds)
    }

    func testDedicatedAppIsAskedAfterTwoSecondsOnTheMicrophoneAndOnlyOnce() {
        var machine = MeetingDetectionMachine()
        let mic: [String: MeetingSignal] = [zoom: .microphone]
        XCTAssertNil(machine.step(now: at(0), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertNil(machine.step(now: at(1), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertEqual(machine.step(now: at(2), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false), zoom)
        XCTAssertNil(machine.step(now: at(3), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
    }

    func testChatAppNeedsTenSecondsAndAShortUseIsNotAMeeting() {
        var machine = MeetingDetectionMachine()
        let mic: [String: MeetingSignal] = [dingTalk: .microphone]
        XCTAssertNil(machine.step(now: at(0), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertNil(machine.step(now: at(5), signals: [:], frontmost: nil, recordingMeeting: false, holdOff: false),
                     "语音消息：松开了")
        XCTAssertNil(machine.step(now: at(6), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertNil(machine.step(now: at(15), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertEqual(machine.step(now: at(16), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false), dingTalk)
    }

    func testMeetingProcessIsAskedAfterTwoSeconds() {
        var machine = MeetingDetectionMachine()
        let process: [String: MeetingSignal] = [dingTalk: .meetingProcess]
        XCTAssertNil(machine.step(now: at(0), signals: process, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertEqual(machine.step(now: at(2), signals: process, frontmost: nil, recordingMeeting: false, holdOff: false),
                       dingTalk)
    }

    func testRecordingAMeetingMarksTheOngoingOnesAsAskedAndHoldOffDefers() {
        var recording = MeetingDetectionMachine()
        let mic: [String: MeetingSignal] = [zoom: .microphone]
        XCTAssertNil(recording.step(now: at(0), signals: mic, frontmost: nil, recordingMeeting: true, holdOff: false))
        XCTAssertNil(recording.step(now: at(5), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false),
                     "记录过的这一场不再问")

        var held = MeetingDetectionMachine()
        XCTAssertNil(held.step(now: at(0), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: true))
        XCTAssertNil(held.step(now: at(3), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: true))
        XCTAssertEqual(held.step(now: at(4), signals: mic, frontmost: nil, recordingMeeting: false, holdOff: false), zoom,
                       "听写 / 录屏结束后再问")
    }

    func testOneQuestionAtATimeMarksTheOthersAskedToo() {
        var machine = MeetingDetectionMachine()
        let both: [String: MeetingSignal] = [zoom: .microphone, MeetingWebSites.meet: .microphone]
        XCTAssertNil(machine.step(now: at(0), signals: both, frontmost: nil, recordingMeeting: false, holdOff: false))
        XCTAssertEqual(machine.step(now: at(2), signals: both, frontmost: nil, recordingMeeting: false, holdOff: false), zoom)
        XCTAssertNil(machine.step(now: at(4), signals: both, frontmost: nil, recordingMeeting: false, holdOff: false))
    }

    func testGapDecidesWhetherItIsTheSameMeeting() {
        // 专门开会的 App 松开麦克风 10 秒 = 退会了：下一场再问。
        var dedicated = MeetingDetectionMachine()
        let zoomMic: [String: MeetingSignal] = [zoom: .microphone]
        _ = dedicated.step(now: at(0), signals: zoomMic, frontmost: nil, recordingMeeting: false, holdOff: false)
        XCTAssertEqual(dedicated.step(now: at(2), signals: zoomMic, frontmost: nil, recordingMeeting: false, holdOff: false), zoom)
        _ = dedicated.step(now: at(3), signals: [:], frontmost: nil, recordingMeeting: false, holdOff: false)
        _ = dedicated.step(now: at(15), signals: zoomMic, frontmost: nil, recordingMeeting: false, holdOff: false)
        XCTAssertEqual(dedicated.step(now: at(17), signals: zoomMic, frontmost: nil, recordingMeeting: false, holdOff: false), zoom)

        // 聊天 App 静音时会松开麦克风：3 分钟内回来还是同一场，不再问。
        var chat = MeetingDetectionMachine()
        let dingMic: [String: MeetingSignal] = [dingTalk: .microphone]
        _ = chat.step(now: at(0), signals: dingMic, frontmost: nil, recordingMeeting: false, holdOff: false)
        XCTAssertEqual(chat.step(now: at(10), signals: dingMic, frontmost: nil, recordingMeeting: false, holdOff: false), dingTalk)
        _ = chat.step(now: at(11), signals: [:], frontmost: nil, recordingMeeting: false, holdOff: false)
        _ = chat.step(now: at(100), signals: dingMic, frontmost: nil, recordingMeeting: false, holdOff: false)
        XCTAssertNil(chat.step(now: at(120), signals: dingMic, frontmost: nil, recordingMeeting: false, holdOff: false))
    }
}
