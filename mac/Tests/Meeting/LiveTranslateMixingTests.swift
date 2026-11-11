import Foundation
import XCTest

/// 会议的混合音源与「我 / 对方」判定的纯逻辑（docs/meeting/TECH_DESIGN.md §2.2）：环形缓冲、抖动缓冲与混音、节拍时钟、
/// 有人声的累计时长、说话人判定。
final class LiveTranslateMixingTests: XCTestCase {

    func testRingDropsTheOldestWhenFullAndReadsInOrder() {
        var ring = LiveTranslateSampleRing(capacity: 4)
        XCTAssertEqual(ring.append([1, 2, 3]), 0)
        XCTAssertEqual(ring.append([4, 5]), 1, "满了丢最早的")
        XCTAssertEqual(ring.read(2), [2, 3])
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.append([6, 7, 8, 9, 10, 11]), 4, "一次给的比整个缓冲还多：只留最后 4 个（丢掉旧的 2 个和新的前 2 个）")
        XCTAssertEqual(ring.read(10), [8, 9, 10, 11])
        XCTAssertEqual(ring.count, 0)
        ring.append([1, 2])
        ring.drop(5)
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(LiveTranslateSampleRing(capacity: 0).capacity, 1)
    }

    func testALaneStaysSilentUntilItsJitterBufferIsFull() {
        var mixer = LiveTranslateMixer(laneCount: 2)
        mixer.push([Float](repeating: 0.5, count: LiveTranslateMixer.prefillFrames - 1), lane: 0)
        let silent = mixer.nextBlock()
        XCTAssertEqual(silent.samples, [Float](repeating: 0, count: LiveTranslateMixer.blockFrames))
        XCTAssertEqual(silent.levels, [0, 0])

        mixer.push([0.5], lane: 0)
        let block = mixer.nextBlock()
        XCTAssertEqual(block.samples, [Float](repeating: 0.5, count: LiveTranslateMixer.blockFrames))
        XCTAssertEqual(block.levels[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(block.levels[1], 0)
        XCTAssertEqual(mixer.backlog(lane: 0), LiveTranslateMixer.prefillFrames - LiveTranslateMixer.blockFrames)
        XCTAssertEqual(mixer.backlog(lane: 5), 0)
    }

    func testFreshLanesTrimTheirStartupBacklogAndMixIsClamped() {
        var mixer = LiveTranslateMixer(laneCount: 2)
        mixer.push([Float](repeating: 0.8, count: LiveTranslateMixer.prefillFrames + 1_000), lane: 0)
        mixer.push([Float](repeating: 0.8, count: LiveTranslateMixer.prefillFrames), lane: 1)
        let block = mixer.nextBlock()
        XCTAssertEqual(mixer.lanes[0].dropped, 1_000, "第一次攒够时把多攒的修掉")
        XCTAssertEqual(block.samples, [Float](repeating: 1, count: LiveTranslateMixer.blockFrames), "两路相加限幅在 1")
        XCTAssertEqual(mixer.backlog(lane: 0), LiveTranslateMixer.prefillFrames - LiveTranslateMixer.blockFrames)
    }

    func testBacklogBeyondToleranceIsDroppedAndAnUnderrunRefills() {
        var mixer = LiveTranslateMixer(laneCount: 1)
        mixer.push([Float](repeating: 0.1, count: LiveTranslateMixer.maxBacklogFrames + 500), lane: 0)
        XCTAssertEqual(mixer.backlog(lane: 0), LiveTranslateMixer.maxBacklogFrames)
        XCTAssertEqual(mixer.lanes[0].dropped, 500)

        var short = LiveTranslateMixer(laneCount: 1)
        short.push([Float](repeating: 0.1, count: LiveTranslateMixer.prefillFrames + 100), lane: 0)
        for _ in 0..<(LiveTranslateMixer.prefillFrames / LiveTranslateMixer.blockFrames) {
            _ = short.nextBlock()
        }
        let starved = short.nextBlock()
        XCTAssertEqual(short.lanes[0].underruns, 1, "取空了：补零、重新攒")
        XCTAssertFalse(short.lanes[0].primed)
        XCTAssertEqual(starved.samples.filter { $0 != 0 }.count, 0)
    }

    func testDrainMixesWhatIsLeftAndResetForgets() {
        var mixer = LiveTranslateMixer(laneCount: 2)
        mixer.push([Float](repeating: 0.2, count: 500), lane: 0)
        mixer.push([Float](repeating: 0.2, count: 100), lane: 1)
        let blocks = mixer.drain()
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].samples[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(blocks[1].samples[200], 0, "第二块只有 180 个样本，后面补零")
        XCTAssertEqual(mixer.backlog(lane: 0), 0)

        mixer.push([0.3, 0.3], lane: 0)
        mixer.reset()
        XCTAssertEqual(mixer.backlog(lane: 0), 0)
        XCTAssertTrue(mixer.lanes[0].fresh)
    }

    func testClockEmitsBlocksForElapsedTimeAndCatchesUpAtMostTenAtOnce() {
        var clock = LiveTranslateMixClock(start: 100)
        XCTAssertEqual(clock.blocksDue(at: 99), 0)
        XCTAssertEqual(clock.blocksDue(at: 100.1), 5)
        XCTAssertEqual(clock.blocksDue(at: 100.1), 0)
        XCTAssertEqual(clock.blocksDue(at: 100.12), 1)
        XCTAssertEqual(clock.blocksDue(at: 105), 10, "落后太多只补最近的 200 ms")
        XCTAssertEqual(clock.emittedBlocks, 250)
    }

    func testLaneStatsCountVoicedTimePerLane() {
        var stats = LiveTranslateLaneStats()
        stats.add(levels: [0.02, 0.005])
        stats.add(levels: [0.02, 0.03])
        stats.add(levels: [0.005])
        XCTAssertEqual(stats.microphoneVoiced, 2 * LiveTranslateMixer.blockDuration, accuracy: 1e-9)
        XCTAssertEqual(stats.systemVoiced, LiveTranslateMixer.blockDuration, accuracy: 1e-9)
        let difference = stats - LiveTranslateLaneStats(microphoneVoiced: 1, systemVoiced: 0)
        XCTAssertEqual(difference, LiveTranslateLaneStats(microphoneVoiced: 0, systemVoiced: stats.systemVoiced))
    }

    func testSpeakerJudgePrefersTheOtherSideWhenItsVoiceIsSignificant() {
        XCTAssertEqual(LiveTranslateSpeakerJudge.decide(.init(microphoneVoiced: 1.0, systemVoiced: 0.4)), .them,
                       "回声：系统声音显著且够麦克风的 35%")
        XCTAssertEqual(LiveTranslateSpeakerJudge.decide(.init(microphoneVoiced: 3.0, systemVoiced: 0.4)), .me,
                       "我说了好几秒、对方插一声")
        XCTAssertEqual(LiveTranslateSpeakerJudge.decide(.init(microphoneVoiced: 0.3, systemVoiced: 0.0)), .me)
        XCTAssertEqual(LiveTranslateSpeakerJudge.decide(.init(microphoneVoiced: 0.0, systemVoiced: 0.3)), .them)
        XCTAssertNil(LiveTranslateSpeakerJudge.decide(.init(microphoneVoiced: 0.29, systemVoiced: 0.29)))
    }
}
