import XCTest
@testable import ScratchLab

final class SessionReplayClockTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_800_000)

    // MARK: - Open-left / closed-right window

    func testTickFiresEventsInOpenLeftClosedRightWindow() {
        var clock = makeClock(eventStartTimes: [0.5, 1.0, 1.5, 2.0], takeDuration: 3.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        // At hostTime = 1.0, currentTime = 1.0. Closed-right boundary
        // means the event at 1.0 fires, and so does the earlier one
        // at 0.5.
        let firstFire = clock.tick(hostTime: 1.0)
        XCTAssertEqual(firstFire.map(\.startTime), [0.5, 1.0])

        // Advance to 1.5. Event at 1.5 fires (closed-right). Open-left
        // means the already-fired event at 1.0 does not fire again.
        let secondFire = clock.tick(hostTime: 1.5)
        XCTAssertEqual(secondFire.map(\.startTime), [1.5])

        // Advance to 3.0 (timeline duration). Event at 2.0 fires.
        let thirdFire = clock.tick(hostTime: 3.0)
        XCTAssertEqual(thirdFire.map(\.startTime), [2.0])

        // Past the end: nothing left.
        let fourthFire = clock.tick(hostTime: 4.0)
        XCTAssertTrue(fourthFire.isEmpty)
    }

    // MARK: - Idempotence on repeat tick without time advance

    func testRepeatedTickWithoutAdvanceFiresNothing() {
        var clock = makeClock(eventStartTimes: [0.5, 1.0, 1.5], takeDuration: 2.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        let firstFire = clock.tick(hostTime: 1.5)
        XCTAssertEqual(firstFire.map(\.startTime), [0.5, 1.0, 1.5])

        // Same hostTime — no advance, no new events.
        let secondFire = clock.tick(hostTime: 1.5)
        XCTAssertTrue(secondFire.isEmpty)

        // And a third repeat to be extra sure cursor truly didn't move.
        let thirdFire = clock.tick(hostTime: 1.5)
        XCTAssertTrue(thirdFire.isEmpty)
    }

    // MARK: - Seek

    func testSeekResetsCursorCorrectly() {
        var clock = makeClock(eventStartTimes: [0.5, 1.0, 1.5, 2.0], takeDuration: 3.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        // Fire everything first.
        let beforeSeek = clock.tick(hostTime: 3.0)
        XCTAssertEqual(beforeSeek.count, 4)

        // Seek to 1.0 — cursor moves to the first event with
        // startTime >= 1.0 (i.e. the event AT 1.0). Next tick at
        // hostTime = 3.0 should fire that event and every later
        // one (currentTime is still 3.0).
        clock.seek(to: 1.0)
        let afterSeek = clock.tick(hostTime: 3.0)
        XCTAssertEqual(afterSeek.map(\.startTime), [1.0, 1.5, 2.0])
    }

    func testSeekToTimeBetweenEventsLandsOnNextEvent() {
        var clock = makeClock(eventStartTimes: [0.5, 1.0, 1.5, 2.0], takeDuration: 3.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)
        _ = clock.tick(hostTime: 3.0)

        // Seek to 1.2 (between events 1.0 and 1.5). Cursor should
        // land on the first event with startTime >= 1.2 — the event
        // at 1.5.
        clock.seek(to: 1.2)
        let fired = clock.tick(hostTime: 3.0)
        XCTAssertEqual(fired.map(\.startTime), [1.5, 2.0])
    }

    // MARK: - Reset

    func testResetReturnsToInitialState() {
        var clock = makeClock(eventStartTimes: [0.5, 1.0, 1.5], takeDuration: 2.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)
        _ = clock.tick(hostTime: 1.5)
        XCTAssertEqual(clock.cursor, 3)
        XCTAssertTrue(clock.audioClock.hasSample)

        clock.reset()
        XCTAssertEqual(clock.cursor, 0)
        XCTAssertFalse(clock.audioClock.hasSample)

        // After reset the clock is once again unanchored; the next
        // ingest hard-anchors and the original event stream replays
        // identically.
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)
        let replayed = clock.tick(hostTime: 1.5)
        XCTAssertEqual(replayed.map(\.startTime), [0.5, 1.0, 1.5])
    }

    // MARK: - Clamp at takeDurationSeconds

    func testClampPreventsEventsPastTimelineDuration() {
        // Two events: one inside the take, one past the take's
        // recorded duration. Even if the audio clock reports a host
        // time well past the take end, the late event must never fire.
        var clock = makeClock(eventStartTimes: [0.5, 1.5], takeDuration: 1.0)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        let fired = clock.tick(hostTime: 5.0)
        XCTAssertEqual(fired.map(\.startTime), [0.5])
        XCTAssertEqual(clock.currentTime(hostTime: 5.0), 1.0,
                       "currentTime must clamp to takeDurationSeconds")

        // Repeated ticks well past the end keep returning empty.
        let again = clock.tick(hostTime: 100.0)
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: - Determinism across clocks

    func testIdenticalStreamProducesIdenticalFiredSequence() {
        let timeline = makeTimeline(
            eventStartTimes: [0.25, 0.75, 1.25, 1.75, 2.25, 2.75],
            takeDuration: 3.0
        )
        var clockA = SessionReplayClock(timeline: timeline)
        var clockB = SessionReplayClock(timeline: timeline)

        let stream: [(playerTime: TimeInterval, isPlaying: Bool, hostTime: TimeInterval)] = [
            (0.0, true, 0.0),
            (0.5, true, 0.5),
            (1.0, true, 1.0),
            (1.5, true, 1.5),
            (2.0, true, 2.0),
            (2.5, true, 2.5),
            (3.0, true, 3.0)
        ]

        var firedA: [Double] = []
        var firedB: [Double] = []
        for sample in stream {
            clockA.ingest(
                playerTime: sample.playerTime,
                isPlaying: sample.isPlaying,
                hostTime: sample.hostTime
            )
            clockB.ingest(
                playerTime: sample.playerTime,
                isPlaying: sample.isPlaying,
                hostTime: sample.hostTime
            )
            firedA.append(contentsOf: clockA.tick(hostTime: sample.hostTime).map(\.startTime))
            firedB.append(contentsOf: clockB.tick(hostTime: sample.hostTime).map(\.startTime))
        }

        XCTAssertEqual(firedA, firedB)
        XCTAssertEqual(firedA, [0.25, 0.75, 1.25, 1.75, 2.25, 2.75])
        // Cursor parity is the strict equality proof.
        XCTAssertEqual(clockA, clockB)
    }

    // MARK: - Resync does not double-fire

    func testResyncDoesNotDoubleFireAlreadyFiredEvents() {
        // Place events on both sides of the resync jump so we can
        // assert both invariants:
        //   - already-fired events do not refire after the re-anchor
        //   - newly-reached events do fire from the new cursor
        var clock = makeClock(
            eventStartTimes: [0.5, 1.0, 2.5, 4.0],
            takeDuration: 6.0
        )
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)
        let firstFire = clock.tick(hostTime: 1.0)
        XCTAssertEqual(firstFire.map(\.startTime), [0.5, 1.0])

        // Trigger a re-anchor in the underlying DemoAudioClock by
        // feeding a fresh raw player time that diverges from the
        // interpolated estimate by more than resyncThreshold (0.12s):
        //   estimate at hostTime = 1.0 is 1.0; ingesting playerTime
        //   = 3.0 forces re-anchor to (hostTime: 1.0, playerTime: 3.0).
        clock.ingest(playerTime: 3.0, isPlaying: true, hostTime: 1.0)
        XCTAssertEqual(clock.currentTime(hostTime: 1.0), 3.0, accuracy: 1e-9)

        // Now tick. Already-fired events at 0.5 and 1.0 must NOT
        // reappear. Newly-reached events at 2.5 (≤ 3.0) DO fire.
        let afterResync = clock.tick(hostTime: 1.0)
        XCTAssertEqual(afterResync.map(\.startTime), [2.5])

        // Advancing further surfaces the event at 4.0.
        clock.ingest(playerTime: 4.0, isPlaying: true, hostTime: 2.0)
        let later = clock.tick(hostTime: 2.0)
        XCTAssertEqual(later.map(\.startTime), [4.0])
    }

    // MARK: - Helpers

    private func makeTimeline(
        eventStartTimes: [Double],
        takeDuration: Double
    ) -> SessionReplayTimeline {
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: [],
            audioEvents: eventStartTimes.map {
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: $0,
                    endTime: $0 + 0.05,
                    duration: 0.05,
                    peakLevel: 0.5,
                    rmsLevel: 0.2,
                    confidence: 0.7,
                    eventKind: "scratchBurst",
                    source: "audio"
                )
            },
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
        return SessionReplayTimeline.build(from: snapshot, takeDuration: takeDuration)
    }

    private func makeClock(
        eventStartTimes: [Double],
        takeDuration: Double
    ) -> SessionReplayClock {
        SessionReplayClock(
            timeline: makeTimeline(
                eventStartTimes: eventStartTimes,
                takeDuration: takeDuration
            )
        )
    }
}
