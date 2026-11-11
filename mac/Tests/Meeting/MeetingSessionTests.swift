import Foundation
import XCTest

/// 会话的决策（docs/meeting/ENGINE.md §5.4）：开始、开起来、会中、结束、退出、心跳。引擎、会议库、文档、App 环境都是假的，
/// 副作用的先后记在同一本账上（§7.1 R16）。
@MainActor
final class MeetingSessionTests: XCTestCase {

    // MARK: - 开始

    func testStartsOnlyWhenIdleAndOnlyToastsWhileAlreadyRecording() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        XCTAssertEqual(fixture.session.phase, .starting)

        fixture.session.start(type: .offline)
        XCTAssertEqual(fixture.environment.toasts, [.alreadyRecording])
        XCTAssertEqual(fixture.library.created.count, 1)
        XCTAssertEqual(fixture.engine.starts.count, 1)
        XCTAssertEqual(fixture.session.type, .online)
    }

    func testBusyMicrophoneToastsWithoutAskingForConsent() {
        let fixture = MeetingSessionFixture()
        fixture.environment.busyMessage = { "正在听写，先停止再开始" }
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.environment.toasts, [.busy("正在听写，先停止再开始")])
        XCTAssertEqual(fixture.environment.consentRequests, 0)
        XCTAssertTrue(fixture.library.created.isEmpty)
        XCTAssertTrue(fixture.engine.starts.isEmpty)
        XCTAssertEqual(fixture.session.phase, .idle)
    }

    func testCancelledConsentDoesNotStart() {
        let fixture = MeetingSessionFixture()
        fixture.environment.consent = { false }
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.environment.consentRequests, 1)
        XCTAssertTrue(fixture.library.created.isEmpty)
        XCTAssertTrue(fixture.engine.starts.isEmpty)
        XCTAssertTrue(fixture.environment.toasts.isEmpty)
        XCTAssertEqual(fixture.session.phase, .idle)
    }

    func testAMeetingStartedDuringTheConsentDialogWins() {
        let fixture = MeetingSessionFixture()
        var first = true
        // 对话框开着时别处（快捷键、提醒气泡）开了一场线下会议。
        fixture.environment.consent = {
            if first {
                first = false
                fixture.session.start(type: .offline)
            }
            return true
        }
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.library.created.map(\.meta.type), [.offline])
        XCTAssertEqual(fixture.engine.starts.count, 1)
        XCTAssertEqual(fixture.session.type, .offline)
        XCTAssertTrue(fixture.environment.toasts.isEmpty)
    }

    func testMicrophoneTakenDuringTheConsentDialogToastsAndDoesNotStart() {
        let fixture = MeetingSessionFixture()
        var asked = 0
        fixture.environment.busyMessage = {
            asked += 1
            return asked == 1 ? nil : "正在自由听译，先停止再开始"
        }
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.environment.consentRequests, 1)
        XCTAssertEqual(fixture.environment.toasts, [.busy("正在自由听译，先停止再开始")])
        XCTAssertTrue(fixture.library.created.isEmpty)
        XCTAssertEqual(fixture.session.phase, .idle)
    }

    func testManualOnlineStartBindsTheCalendarCandidate() {
        let fixture = MeetingSessionFixture()
        let candidate = MeetingEventInfo(title: "设计评审", start: localDate(9, 58, 0), end: localDate(10, 30, 0),
                                         attendees: ["张三", "李四"], calendarTitle: "工作")
        fixture.environment.candidate = candidate
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.environment.candidateRequests, 1)
        XCTAssertEqual(fixture.session.event, candidate)
        XCTAssertEqual(fixture.session.title, "设计评审")
        XCTAssertEqual(fixture.library.created.first?.meta.attendees, ["张三", "李四"])
    }

    func testOfflineStartAndAnExplicitEventDoNotLookForACandidate() {
        let offline = MeetingSessionFixture()
        offline.environment.candidate = MeetingEventInfo(title: "设计评审", start: localDate(9, 58, 0), end: localDate(10, 30, 0))
        offline.session.start(type: .offline)
        XCTAssertEqual(offline.environment.candidateRequests, 0)
        XCTAssertNil(offline.session.event)
        XCTAssertEqual(offline.session.title, "线下会议")

        let explicit = MeetingSessionFixture()
        let event = MeetingEventInfo(title: "周会", start: localDate(10, 0, 0), end: localDate(11, 0, 0))
        explicit.session.start(type: .online, event: event)
        XCTAssertEqual(explicit.environment.candidateRequests, 0)
        XCTAssertEqual(explicit.session.event, event)
    }

    func testTitleIsTheTrimmedEventTitleOrTheTypeName() {
        let named = MeetingSessionFixture()
        named.session.start(type: .online, event: MeetingEventInfo(title: "  周会  ", start: localDate(10, 0, 0),
                                                                   end: localDate(11, 0, 0)))
        XCTAssertEqual(named.session.title, "周会")
        XCTAssertEqual(named.library.created.first?.meta.title, "周会")

        let blank = MeetingSessionFixture()
        blank.session.start(type: .online, event: MeetingEventInfo(title: "   ", start: localDate(10, 0, 0),
                                                                   end: localDate(11, 0, 0)))
        XCTAssertEqual(blank.session.title, "线上会议")
    }

    func testStartAsksForConsentThenCreatesThenStartsTheEngineThenShowsTheUI() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.log.entries, ["env.consent", "library.create", "engine.start", "env.dnd(true)",
                                             "env.heartbeat(true)", "env.controlBar(show)", "env.indicators"])
        XCTAssertEqual(fixture.session.phase, .starting)
        XCTAssertEqual(fixture.session.startedAt, localDate(10, 0, 0))
        XCTAssertEqual(fixture.library.created.first?.meta.template, "standard")
    }

    func testRefusedStartDiscardsTheMeetingAndLeavesNoUI() {
        let fixture = MeetingSessionFixture()
        fixture.engine.acceptsStart = false
        fixture.session.start(type: .online)

        XCTAssertEqual(fixture.log.entries, ["env.consent", "library.create", "engine.start", "library.discard(M1)"])
        XCTAssertEqual(fixture.session.phase, .idle)
        XCTAssertNil(fixture.session.meetingID)
        XCTAssertNil(fixture.session.type)
        XCTAssertTrue(fixture.environment.doNotDisturb.isEmpty)
        XCTAssertTrue(fixture.environment.heartbeat.isEmpty)
        XCTAssertTrue(fixture.environment.controlBarChanges.isEmpty)
    }

    func testEngineConfigForOnlineAndOfflineMeetings() {
        let online = MeetingSessionFixture()
        online.session.start(type: .online)
        XCTAssertEqual(online.engine.starts, [MeetingEngineConfig(
            owner: "meeting", label: "会议记录", capture: .microphoneAndSystem, subtitles: false, speakers: true,
            documentURL: URL(fileURLWithPath: "/Meetings/2026/2026-11-10 10-00 线上会议/meeting.md"))])

        let offline = MeetingSessionFixture()
        offline.session.start(type: .offline)
        XCTAssertEqual(offline.engine.starts, [MeetingEngineConfig(
            owner: "meeting", label: "会议记录", capture: .microphone, subtitles: false, speakers: false,
            documentURL: URL(fileURLWithPath: "/Meetings/2026/2026-11-10 10-00 线下会议/meeting.md"))])
    }

    func testIdleEngineConfigFallsBackToTheLibraryRoot() {
        let fixture = MeetingSessionFixture()
        let config = fixture.session.engineConfig
        XCTAssertEqual(config.capture, .microphone)
        XCTAssertFalse(config.speakers)
        XCTAssertEqual(config.documentURL, fixture.library.rootURL)
    }

    func testFreeTypeAndTheFreeListeningEntryToggleTheEngineWhenIdle() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .free)
        fixture.session.startFreeListening()

        XCTAssertEqual(fixture.engine.calls, [.toggleFreeListening, .toggleFreeListening])
        XCTAssertTrue(fixture.library.created.isEmpty)
        XCTAssertEqual(fixture.environment.consentRequests, 0)
    }

    func testStartDefaultUsesTheTypeFromSettings() {
        let fixture = MeetingSessionFixture()
        fixture.environment.defaultType = .offline
        fixture.session.startDefault()
        XCTAssertEqual(fixture.session.type, .offline)
    }

    // MARK: - 开起来

    func testTranscriptIsCreatedOnTheFirstStartedWithThisMeetingsHeader() throws {
        let fixture = MeetingSessionFixture()
        let event = MeetingEventInfo(title: "设计评审", start: localDate(9, 58, 0), end: localDate(10, 30, 0),
                                     attendees: ["张三", "李四"], calendarTitle: "工作")
        fixture.session.start(type: .online, event: event)
        XCTAssertTrue(fixture.library.transcripts.isEmpty, "开起来之前没有文档")

        fixture.environment.advance(3)
        fixture.engine.report(.started(onlineRun))
        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(fixture.library.transcripts.count, 1)
        XCTAssertEqual(transcript.start, localDate(10, 0, 3))
        XCTAssertEqual(transcript.run, onlineRun)
        XCTAssertEqual(transcript.spec.fileURL, URL(fileURLWithPath: "/Meetings/2026/2026-11-10 10-00 设计评审/meeting.md"))
        XCTAssertEqual(transcript.spec.displayName, "2026-11-10 10-00 设计评审")
        XCTAssertEqual(transcript.spec.header, MeetingTranscriptSpec.Header(
            title: "设计评审", kind: "线上会议", start: localDate(10, 0, 0), attendees: ["张三", "李四"], calendar: "工作"))
        XCTAssertTrue(transcript.spec.speakers)
        XCTAssertEqual(transcript.spec.template, .meeting(.standard))
        XCTAssertTrue(transcript.spec.summarizes)
        XCTAssertFalse(transcript.spec.notifiesMinutes)
        XCTAssertEqual(fixture.session.phase, .recording)
    }

    func testOfflineTranscriptHasNoSpeakersAndUsesTheTemplateFromSettings() throws {
        let fixture = MeetingSessionFixture()
        fixture.environment.minutesStyle = .standup
        fixture.startRecording(.offline)
        let transcript = try XCTUnwrap(fixture.transcript)

        XCTAssertFalse(transcript.spec.speakers)
        XCTAssertEqual(transcript.spec.template, .meeting(.standup))
        XCTAssertEqual(transcript.spec.header?.kind, "线下会议")
        XCTAssertEqual(fixture.library.created.first?.meta.template, "standup")
    }

    func testNotesAndSubtitlesFromTheStartingPhaseAreAppliedWhenStarted() throws {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        fixture.session.setNotes("议程：发布计划")
        fixture.session.setSubtitles(true)
        XCTAssertEqual(fixture.engine.calls, [.setSubtitles(true)], "开始中也先告诉引擎（它没在跑时不做）")

        fixture.engine.report(.started(onlineRun))
        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.setNotes("议程：发布计划")])
        XCTAssertEqual(fixture.engine.calls, [.setSubtitles(true), .setSubtitles(true)], "开起来时按 subtitlesOn 再设一次")
        XCTAssertTrue(transcript.markdown.contains("## 速记\n\n议程：发布计划\n\n"))
    }

    func testFinishWhileStartingFinishesRightAfterStarted() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .offline)
        XCTAssertEqual(fixture.engine.starts.first?.capture, .microphone)

        fixture.session.finish()                              // 还在开始中：记下，开起来再收尾
        XCTAssertFalse(fixture.engine.calls.contains(.finish))
        XCTAssertEqual(fixture.session.phase, .starting)

        fixture.engine.report(.started(onlineRun))
        XCTAssertEqual(fixture.session.phase, .finishing)
        XCTAssertEqual(fixture.engine.calls, [.finish])
    }

    func testRestartContinuesTheSameTranscriptAndKeepsThePhase() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.say("1-1", "大家好", after: 2)
        fixture.session.setSubtitles(true)
        fixture.session.pause()

        fixture.environment.advance(3)
        fixture.engine.restart(englishRun)                    // 改了说话语言
        XCTAssertEqual(fixture.library.transcripts.count, 1, "还是同一份文档")
        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls.last, .continueWith(englishRun, localDate(10, 0, 5)))
        XCTAssertEqual(fixture.session.phase, .paused, "暂停中的照旧暂停")
        XCTAssertEqual(fixture.engine.starts.count, 2)
        XCTAssertEqual(fixture.engine.starts.last?.subtitles, true, "重启时按托管方此刻的配置重组")
        XCTAssertTrue(transcript.markdown.contains("*10:00:05 改为：麦克风 + 系统声音 · 说：English · 译成：不翻译*"))
    }

    func testLinesBeforeTheFirstStartedAreReplayedInTimeOrder() throws {
        // I10：音源全开好才报 .started，先开的麦克风那一路可能已经出了字。
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        let later = engineLine("1-3", "第二句", at: localDate(10, 0, 3), speaker: .me)
        let sameTimeB = engineLine("1-2", "同一刻 B", at: localDate(10, 0, 1), speaker: .me)
        let sameTimeA = engineLine("1-1", "同一刻 A", at: localDate(10, 0, 1), speaker: .me)
        fixture.engine.report(.line(later))
        fixture.engine.report(.line(sameTimeB))
        fixture.engine.report(.line(sameTimeA))
        XCTAssertTrue(fixture.library.transcripts.isEmpty)

        fixture.engine.report(.started(onlineRun))
        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.update(sameTimeA), .update(sameTimeB), .update(later)],
                       "按时间补写，同一刻按键")
        XCTAssertTrue(transcript.markdown.hasSuffix(
            "**10:00:01 我** 同一刻 A\n\n**10:00:01 我** 同一刻 B\n\n**10:00:03 我** 第二句\n\n"))
    }

    // MARK: - 会中

    func testPauseAndResumeTellTheEngineAndWriteANoteEach() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.log.clear()

        fixture.environment.advance(4)
        fixture.session.pause()
        fixture.session.pause()
        XCTAssertEqual(fixture.session.phase, .paused)
        fixture.environment.advance(10)
        fixture.session.togglePause()
        XCTAssertEqual(fixture.session.phase, .recording)

        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.note(.paused, localDate(10, 0, 4)), .note(.resumed, localDate(10, 0, 14))])
        XCTAssertEqual(fixture.engine.calls, [.setPaused(true), .setPaused(false)])
        XCTAssertEqual(fixture.log.entries, [
            "engine.setPaused(true)", "transcript.note(paused)", "env.indicators", "env.controlBar(refreshSize)",
            "engine.setPaused(false)", "transcript.note(resumed)", "env.indicators", "env.controlBar(refreshSize)",
        ])
    }

    func testPauseIsIgnoredWhileStarting() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        fixture.session.pause()
        XCTAssertEqual(fixture.session.phase, .starting)
        XCTAssertTrue(fixture.engine.calls.isEmpty)
    }

    func testLaneMutesTellTheEngineAndWriteNotesOnceThereIsATranscript() throws {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        fixture.session.toggleMicrophoneMuted()               // 开始中：引擎收着，开起来生效；还没有文档，不记
        XCTAssertTrue(fixture.session.microphoneMuted)
        XCTAssertEqual(fixture.engine.calls, [.setMuted(true, .microphone)])

        fixture.engine.report(.started(onlineRun))
        fixture.environment.advance(2)
        fixture.session.toggleMicrophoneMuted()
        fixture.environment.advance(2)
        fixture.session.toggleSystemMuted()
        fixture.session.toggleSystemMuted()

        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.note(.microphoneUnmuted, localDate(10, 0, 2)),
                                          .note(.systemMuted, localDate(10, 0, 4)),
                                          .note(.systemUnmuted, localDate(10, 0, 4))])
        XCTAssertEqual(fixture.engine.calls, [.setMuted(true, .microphone), .setMuted(false, .microphone),
                                              .setMuted(true, .system), .setMuted(false, .system)])
    }

    func testOfflineMeetingHasNoSystemLaneAndFinishingIgnoresMutes() {
        let offline = MeetingSessionFixture()
        offline.startRecording(.offline)
        offline.session.toggleSystemMuted()
        XCTAssertFalse(offline.session.systemMuted)
        XCTAssertTrue(offline.engine.calls.isEmpty)

        let finishing = MeetingSessionFixture()
        finishing.startRecording()
        finishing.session.finish()
        finishing.session.toggleMicrophoneMuted()
        finishing.session.toggleSystemMuted()
        XCTAssertEqual(finishing.engine.calls, [.finish])
    }

    func testMarkRecordsSecondsSinceStartAndTheCurrentLine() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.environment.advance(75)
        let long = String(repeating: "长", count: 300)
        fixture.engine.currentText = long
        fixture.session.mark()
        fixture.engine.currentText = nil
        fixture.environment.advance(5)
        fixture.session.mark()

        XCTAssertEqual(fixture.session.marks, [MeetingHighlight(t: 75, text: String(repeating: "长", count: 200)),
                                               MeetingHighlight(t: 80, text: "")])
        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.mark(localDate(10, 1, 15)), .mark(localDate(10, 1, 20))])
        XCTAssertTrue(transcript.markdown.contains("🔖 **10:01:15** 标记重点\n\n"))
    }

    func testMarkNeedsARecordingMeeting() {
        let fixture = MeetingSessionFixture()
        fixture.session.mark()
        fixture.session.start(type: .online)
        fixture.session.mark()
        XCTAssertTrue(fixture.session.marks.isEmpty)
    }

    func testNotesAreDedupedAndWrittenToTheTranscript() throws {
        let fixture = MeetingSessionFixture()
        fixture.session.setNotes("空闲时不记")
        XCTAssertEqual(fixture.session.notes, "")

        fixture.startRecording()
        fixture.session.setNotes("决定：周五发布")
        fixture.session.setNotes("决定：周五发布")
        fixture.session.setNotes("决定：周五发布\n风险：测试")

        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls, [.setNotes("决定：周五发布"), .setNotes("决定：周五发布\n风险：测试")])
        XCTAssertEqual(fixture.session.notes, "决定：周五发布\n风险：测试")
    }

    func testToggleNotesExpandsTheControlBar() {
        let fixture = MeetingSessionFixture()
        fixture.session.toggleNotes()
        XCTAssertFalse(fixture.session.notesExpanded, "空闲时不动")

        fixture.session.start(type: .online)
        fixture.log.clear()
        fixture.session.toggleNotes()
        fixture.session.toggleNotes()
        XCTAssertEqual(fixture.log.entries, ["env.controlBar(notesExpanded(true))", "env.controlBar(refreshSize)",
                                             "env.controlBar(notesExpanded(false))", "env.controlBar(refreshSize)"])
    }

    func testSubtitleToggleGuards() {
        let fixture = MeetingSessionFixture()
        fixture.session.setSubtitles(true)
        XCTAssertFalse(fixture.session.subtitlesOn, "空闲时不动")

        fixture.startRecording()
        fixture.session.setSubtitles(true)
        fixture.session.setSubtitles(true)
        XCTAssertTrue(fixture.session.subtitlesOn)
        fixture.session.finish()
        fixture.session.setSubtitles(false)
        XCTAssertTrue(fixture.session.subtitlesOn, "收尾中不切")
        XCTAssertEqual(fixture.engine.calls, [.setSubtitles(true), .finish])
    }

    func testUserActionsFromTheEnginesOwnUI() {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()

        fixture.engine.report(.userAction(.freeListeningTogglePressed))
        XCTAssertTrue(fixture.session.subtitlesOn, "「开始自由听译」开关在会议中 = 打开字幕")
        fixture.engine.report(.userAction(.subtitleBarClosed))
        XCTAssertFalse(fixture.session.subtitlesOn, "字幕条 ✕ = 收起字幕，照常记录")
        XCTAssertEqual(fixture.session.phase, .recording)
        fixture.engine.report(.userAction(.recordButtonPressed))
        XCTAssertEqual(fixture.session.phase, .paused, "字幕条「记录」= 暂停 / 继续")
        fixture.engine.report(.userAction(.recordButtonPressed))
        XCTAssertEqual(fixture.session.phase, .recording)
        XCTAssertEqual(fixture.engine.calls, [.setSubtitles(true), .setSubtitles(false), .setPaused(true), .setPaused(false)])
    }

    func testFreeListeningEntryDuringAMeetingTogglesSubtitlesInstead() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        fixture.session.startFreeListening()
        XCTAssertTrue(fixture.engine.calls.isEmpty, "开始中什么也不做")

        fixture.engine.report(.started(onlineRun))
        fixture.session.startFreeListening()
        XCTAssertTrue(fixture.session.subtitlesOn)
        XCTAssertEqual(fixture.engine.calls, [.setSubtitles(true)])
    }

    func testTranscriptWriteFailureGoesToTheSubtitleBar() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        try XCTUnwrap(fixture.transcript).failWrite("记录写不进去：磁盘满了")
        XCTAssertEqual(fixture.engine.calls, [.showNotice("记录写不进去：磁盘满了")])
    }

    // MARK: - 结束

    func testFinishWhileRecordingOrPausedAsksTheEngineToFlushOnce() {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.session.pause()
        fixture.log.clear()
        fixture.session.finish()
        fixture.session.finish()

        XCTAssertEqual(fixture.session.phase, .finishing)
        XCTAssertEqual(fixture.log.entries, ["env.indicators", "env.controlBar(refreshSize)", "engine.finish"])
    }

    func testEndedFinishesTheTranscriptBeforeTearingDownTheUI() {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2, speaker: .me)
        fixture.session.finish()
        fixture.environment.advance(1)
        fixture.log.clear()
        fixture.engine.end()

        XCTAssertEqual(fixture.log.entries, [
            "transcript.finish(terminating: false)", "library.update(\(id), sync: false)",
            "env.dnd(false)", "env.heartbeat(false)", "env.controlBar(hide)", "env.indicators",
        ])
        XCTAssertEqual(fixture.session.phase, .idle)
        XCTAssertNil(fixture.session.meetingID)
        XCTAssertEqual(fixture.session.lastMeetingID, id)
        XCTAssertTrue(fixture.library.finishedWriting.isEmpty, "纪要还在整理：先不 finishWriting")
        XCTAssertTrue(fixture.library.discarded.isEmpty)
    }

    func testLastLinesReportedBeforeEndedMakeItIntoTheTranscript() throws {
        // I4 / R1：最后半句在 .ended 之前报完，文档在 .ended 里收尾。
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2, speaker: .me)
        fixture.session.finish()
        let last = engineLine("1-2", Speech.three, at: localDate(10, 0, 3), speaker: .them)
        fixture.environment.advance(2)
        fixture.engine.end(lines: [last])

        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls.suffix(2), [.update(last), .finish(localDate(10, 0, 4), terminating: false)])
        XCTAssertTrue(transcript.markdown.contains("**10:00:03 对方** \(Speech.three)"))
    }

    func testMetaGetsTheEndStatusAndHighlightsThenTheActionItems() throws {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 5, speaker: .me)            // 10:00:05：标记前 25 秒，不算
        fixture.say("1-2", Speech.two, after: 15, speaker: .them)         // 10:00:20：前 10 秒，算
        fixture.environment.advance(10)
        fixture.engine.currentText = "屏幕上那句"
        fixture.session.mark()                                            // 10:00:30
        fixture.say("1-3", Speech.three, after: 10, speaker: .me)         // 10:00:40：后 10 秒，不算
        fixture.session.finish()
        fixture.environment.advance(20)
        fixture.engine.end()

        var meta = try XCTUnwrap(fixture.library.records[id]?.meta)
        XCTAssertEqual(meta.end, localDate(10, 1, 0))
        XCTAssertEqual(meta.status, .summarizing)
        XCTAssertEqual(meta.highlights, [MeetingHighlight(t: 30, text: Speech.two)])
        XCTAssertTrue(meta.actionItems.isEmpty)
        XCTAssertTrue(fixture.environment.saved.isEmpty)

        try XCTUnwrap(fixture.transcript).completeMinutes(.done(Speech.minutes))
        meta = try XCTUnwrap(fixture.library.records[id]?.meta)
        XCTAssertEqual(meta.status, .summarized)
        XCTAssertEqual(meta.actionItems.map(\.text), ["整理发布说明"])
        XCTAssertEqual(meta.actionItems.first?.owner, "张三")
        XCTAssertEqual(meta.actionItems.first?.due, "周五")
        XCTAssertEqual(meta.actionItems.first?.done, false)
        XCTAssertEqual(fixture.library.finishedWriting, [id])
        XCTAssertEqual(fixture.environment.saved.map(\.record.id), [id])
        XCTAssertEqual(fixture.environment.saved.first?.outcome, .done(Speech.minutes))
    }

    func testHighlightFallsBackToTheLineOnScreenWhenNothingWasFinalNearby() throws {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2, speaker: .me)
        fixture.environment.advance(60)
        fixture.engine.currentText = "这句还没说完"
        fixture.session.mark()
        fixture.session.finish()
        fixture.engine.end()

        XCTAssertEqual(fixture.library.records[id]?.meta.highlights, [MeetingHighlight(t: 62, text: "这句还没说完")])
    }

    func testActionItemsAreOnlyParsedWhenTheMinutesAreDone() throws {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2)
        fixture.session.finish()
        fixture.engine.end()
        try XCTUnwrap(fixture.transcript).completeMinutes(.failed("模型没有给出内容"))

        let meta = try XCTUnwrap(fixture.library.records[id]?.meta)
        XCTAssertEqual(meta.status, .failed)
        XCTAssertTrue(meta.actionItems.isEmpty)
        XCTAssertEqual(fixture.environment.saved.first?.outcome, .failed("模型没有给出内容"))
    }

    func testMinutesThatAreNotGeneratedFinishWritingRightAway() throws {
        let fixture = MeetingSessionFixture()
        fixture.library.minutesOnFinish = .tooShort
        let id = fixture.startRecording()
        fixture.say("1-1", "好", after: 2)
        fixture.session.finish()
        fixture.engine.end()

        XCTAssertEqual(fixture.library.records[id]?.meta.status, .transcribed)
        XCTAssertEqual(fixture.library.finishedWriting, [id])
        XCTAssertEqual(fixture.environment.saved.map(\.outcome), [.tooShort])
    }

    func testNothingRecordedIsDiscardedWithAToast() {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.environment.advance(10)
        fixture.session.finish()
        fixture.engine.end()

        XCTAssertEqual(fixture.library.discarded, [id])
        XCTAssertEqual(fixture.environment.toasts, [.nothingRecorded])
        XCTAssertTrue(fixture.library.updates.isEmpty)
        XCTAssertTrue(fixture.environment.saved.isEmpty)
        XCTAssertNil(fixture.session.lastMeetingID)
    }

    func testEndedWithoutStartedDiscardsTheMeetingSilently() throws {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        let id = try XCTUnwrap(fixture.session.meetingID)
        fixture.engine.report(.ended)                         // 没开起来：权限被拒、识别不可用

        XCTAssertTrue(fixture.library.transcripts.isEmpty, "从没建过文档")
        XCTAssertEqual(fixture.library.discarded, [id])
        XCTAssertTrue(fixture.environment.toasts.isEmpty, "不提示「什么也没记下」")
        XCTAssertEqual(fixture.session.phase, .idle)
        XCTAssertEqual(fixture.environment.doNotDisturb, [true, false])
        XCTAssertEqual(fixture.environment.heartbeat, [true, false])
        XCTAssertEqual(fixture.environment.controlBarChanges, [.show, .hide])
    }

    func testMinutesOfThePreviousMeetingDoNotTouchTheCurrentOne() throws {
        let fixture = MeetingSessionFixture()
        let first = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2)
        fixture.session.finish()
        fixture.engine.end()
        let firstTranscript = try XCTUnwrap(fixture.transcript)

        fixture.environment.advance(60)
        let second = fixture.startRecording(.offline)
        fixture.say("1-1", Speech.two, after: 2)
        firstTranscript.completeMinutes(.done(Speech.minutes))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.session.meetingID, second)
        XCTAssertEqual(fixture.session.phase, .recording)
        XCTAssertEqual(fixture.library.records[first]?.meta.status, .summarized)
        XCTAssertEqual(fixture.library.records[second]?.meta.status, .recording)
        XCTAssertEqual(fixture.library.updates.map(\.id), [first, first])
        XCTAssertEqual(fixture.library.finishedWriting, [first])
        XCTAssertEqual(fixture.environment.saved.map(\.record.id), [first])
        XCTAssertEqual(fixture.session.lastMeetingID, first)
    }

    // MARK: - 退出

    func testTerminateWhileStartingDiscardsWithoutTouchingTheEngine() {
        let fixture = MeetingSessionFixture()
        fixture.session.start(type: .online)
        fixture.log.clear()
        fixture.session.terminate()

        XCTAssertEqual(fixture.log.entries, ["library.discard(M1)", "library.flush"])
        XCTAssertFalse(fixture.engine.calls.contains(.terminate))
    }

    func testTerminateWhileRecordingFinishesEverythingSynchronously() throws {
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2, speaker: .me)
        let last = engineLine("1-2", "那我们周五", at: localDate(10, 0, 3), speaker: .me)
        // 真引擎：terminate() 返回前把剩下的句子和 .ended 同步报完（I5）。
        fixture.engine.onTerminate = { engine in engine.end(lines: [last]) }
        fixture.environment.advance(2)
        fixture.log.clear()
        fixture.session.terminate()

        XCTAssertEqual(fixture.log.entries, [
            "engine.terminate", "transcript.update(1-2)", "transcript.finish(terminating: true)",
            "library.update(\(id), sync: true)", "library.finishWriting(\(id))",
            "env.dnd(false)", "env.heartbeat(false)", "env.controlBar(hide)", "env.indicators", "library.flush",
        ])
        XCTAssertEqual(fixture.library.records[id]?.meta.status, .transcribed)
        XCTAssertTrue(fixture.environment.saved.isEmpty, "退出时不发通知")
        XCTAssertTrue(fixture.environment.toasts.isEmpty)
        XCTAssertEqual(fixture.session.phase, .idle)
    }

    func testTerminateFinishesItselfWhenTheEngineNeverReportsEnded() throws {
        // 比如正因为改设置在重启、还没开起来：引擎报不出 .ended，会议自己收尾（兜底）。
        let fixture = MeetingSessionFixture()
        let id = fixture.startRecording()
        fixture.say("1-1", Speech.one, after: 2)
        fixture.session.terminate()

        let transcript = try XCTUnwrap(fixture.transcript)
        XCTAssertEqual(transcript.calls.last, .finish(localDate(10, 0, 2), terminating: true))
        XCTAssertEqual(fixture.library.updates.map(\.sync), [true])
        XCTAssertEqual(fixture.library.records[id]?.meta.status, .transcribed)
        XCTAssertEqual(fixture.session.phase, .idle)
        XCTAssertEqual(fixture.library.flushes, 1)
    }

    func testTerminateWhenIdleOnlyFlushes() {
        let fixture = MeetingSessionFixture()
        fixture.session.terminate()
        XCTAssertEqual(fixture.log.entries, ["library.flush"])
    }

    // MARK: - 心跳

    func testTickTurnsTheLevelDotsOnAndGreysThemWhilePaused() {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.engine.levels = MeetingInputLevels(microphone: 0.05, system: 0.004)
        fixture.session.tick()
        XCTAssertEqual(fixture.session.levels.microphoneActive, true)
        XCTAssertEqual(fixture.session.levels.systemActive, false, "0.006 以下不亮")

        fixture.session.pause()
        fixture.session.tick()
        XCTAssertEqual(fixture.session.levels.microphoneActive, false)
        XCTAssertEqual(fixture.session.levels.systemActive, false)

        let offline = MeetingSessionFixture()
        offline.startRecording(.offline)
        offline.engine.levels = MeetingInputLevels(microphone: 0.05, system: nil)
        offline.session.tick()
        XCTAssertEqual(offline.session.levels.microphoneActive, true)
        XCTAssertNil(offline.session.levels.systemActive, "线下会议没有系统声音那一路")

        offline.session.finish()
        offline.engine.end()
        XCTAssertNil(offline.session.levels.microphoneActive, "结束后复位")
    }

    func testTickRefreshesTheIndicatorOncePerSecond() {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        let before = fixture.environment.indicatorRefreshes
        for _ in 0..<3 { fixture.session.tick() }
        XCTAssertEqual(fixture.environment.indicatorRefreshes, before)
        fixture.session.tick()
        XCTAssertEqual(fixture.environment.indicatorRefreshes, before + 1)
        XCTAssertEqual(fixture.engine.levelReads, 4)
    }

    func testOvertimeToastOnceFiveMinutesPastTheBoundEventsEnd() {
        let fixture = MeetingSessionFixture()
        let event = MeetingEventInfo(title: "周会", start: localDate(9, 30, 0), end: localDate(10, 30, 0))
        fixture.startRecording(event: event)

        fixture.environment.clock = localDate(10, 35, 0)
        for _ in 0..<4 { fixture.session.tick() }
        XCTAssertTrue(fixture.environment.toasts.isEmpty, "刚好 5 分钟不算")

        fixture.environment.clock = localDate(10, 35, 1)
        for _ in 0..<8 { fixture.session.tick() }
        XCTAssertEqual(fixture.environment.toasts, [.overtime], "只提示一次")
    }

    func testNoOvertimeToastWithoutABoundEvent() {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.environment.advance(4 * 3600)
        for _ in 0..<4 { fixture.session.tick() }
        XCTAssertTrue(fixture.environment.toasts.isEmpty)
    }

    // MARK: - #149（现状钉住，修 #149 时翻转）

    /// #149：会议里改设置重启失败时，已记下的句子在 meeting.md 里重复一遍。
    ///
    /// 根子在引擎：句子键是「第几次运行-句子 id」，重启时运行次数先加一，失败收尾时 `LiveTranslateController.stop()` 又把字幕条上
    /// 留着的句子按新的运行次数强制报了一遍 —— 键变了，文档当成新句子。假引擎在这里照着现在的做法报。
    /// 修 #149（引擎不再重报，或文档认出重报的句子）之后这个测试会「意外通过」，那时删掉 `XCTExpectFailure`、改成正面断言。
    func testFailedRestartDoesNotDuplicateLines_issue149() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        let first = engineLine("1-2", Speech.one, at: localDate(10, 0, 2), speaker: .me)
        let second = engineLine("1-3", Speech.two, at: localDate(10, 0, 6), speaker: .them)
        fixture.engine.report(.line(first))
        fixture.engine.report(.line(second))
        // 改设置 → 重启 → 识别器不可用：引擎按新的运行次数（2）把字幕条上的两句再报一遍，然后报 .ended（同探针 x03）。
        fixture.environment.clock = localDate(10, 0, 8)
        fixture.engine.end(lines: [engineLine("2-2", Speech.one, at: localDate(10, 0, 2), speaker: .me),
                                   engineLine("2-3", Speech.two, at: localDate(10, 0, 6), speaker: .them)])

        let markdown = try XCTUnwrap(fixture.transcript).markdown
        XCTExpectFailure("#149：重启失败后已记下的句子重复（引擎按新的运行次数重报）") {
            XCTAssertEqual(markdown.components(separatedBy: Speech.one).count - 1, 1)
            XCTAssertEqual(markdown.components(separatedBy: Speech.two).count - 1, 1)
        }
    }

    /// 同一个根子（2026-11-10 PR7 的金样探针 s06 / y08 / x05）：重启**成功**之后，结束时 `stop()` 也会把字幕条上
    /// 还留着的旧句子按新的运行次数再报一遍。修 #149 时一起翻转。
    func testFinishAfterARestartDoesNotDuplicateLines_issue149() throws {
        let fixture = MeetingSessionFixture()
        fixture.startRecording()
        fixture.engine.report(.line(engineLine("1-2", Speech.one, at: localDate(10, 0, 2), speaker: .me)))
        fixture.environment.clock = localDate(10, 0, 7)
        fixture.engine.restart(englishRun)
        fixture.engine.report(.line(engineLine("2-4", "Then we ship on Friday.", at: localDate(10, 0, 11), speaker: .them)))
        fixture.session.finish()
        fixture.environment.clock = localDate(10, 0, 13)
        fixture.engine.end(lines: [engineLine("2-2", Speech.one, at: localDate(10, 0, 2), speaker: .me),
                                   engineLine("2-4", "Then we ship on Friday.", at: localDate(10, 0, 11), speaker: .them)])

        let markdown = try XCTUnwrap(fixture.transcript).markdown
        XCTExpectFailure("#149：重启后结束时，字幕条上的旧句子按新的运行次数重报") {
            XCTAssertEqual(markdown.components(separatedBy: Speech.one).count - 1, 1)
        }
    }
}
