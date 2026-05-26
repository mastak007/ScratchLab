import XCTest
@testable import ScratchLab

final class OverlayReplayControllerTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_950_000)

    // MARK: - Initial state

    func testReplayStartsAtZero() {
        let controller = makeController(eventStartTimes: [0.25, 0.75], duration: 1.5)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0.0)
        XCTAssertEqual(controller.currentTime(at: 0.0), 0.0)
        XCTAssertEqual(controller.currentTime(at: 5.0), 0.0)
        XCTAssertEqual(controller.duration, 1.5)
        XCTAssertTrue(controller.hasTimeline)
    }

    // MARK: - Monotonic advance

    func testReplayAdvancesMonotonically() {
        var controller = makeController(eventStartTimes: [0.5, 1.0, 1.5], duration: 2.0)
        controller.play(hostTime: 0.0)

        var lastCursor: TimeInterval = -1
        for sample in stride(from: 0.0, through: 2.5, by: 0.1) {
            let cursor = controller.currentTime(at: sample)
            XCTAssertGreaterThanOrEqual(cursor, lastCursor)
            XCTAssertLessThanOrEqual(cursor, controller.duration)
            lastCursor = cursor
        }
    }

    // MARK: - Stop at end

    func testReplayStopsAtEnd() {
        var controller = makeController(eventStartTimes: [0.25, 0.5], duration: 1.0)
        controller.play(hostTime: 0.0)
        // Tick past the end — controller should auto-stop and clamp.
        _ = controller.tick(hostTime: 2.0)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 1.0)
        // A further tick past the end is a no-op state-wise.
        _ = controller.tick(hostTime: 5.0)
        XCTAssertEqual(controller.currentTime, 1.0)
        XCTAssertFalse(controller.isPlaying)
    }

    // MARK: - Restart rewinds cursor

    func testRestartRewindsCursor() {
        var controller = makeController(eventStartTimes: [0.25, 0.75], duration: 1.5)
        controller.play(hostTime: 0.0)
        _ = controller.tick(hostTime: 1.0)
        XCTAssertGreaterThan(controller.currentTime, 0)
        XCTAssertGreaterThan(controller.clock.cursor, 0)

        controller.restart(hostTime: 1.0)
        XCTAssertEqual(controller.currentTime, 0.0)
        XCTAssertEqual(controller.clock.cursor, 0)
        // Restart preserves isPlaying so playback continues from zero.
        XCTAssertTrue(controller.isPlaying)
    }

    func testRestartWhenPausedKeepsPausedState() {
        var controller = makeController(eventStartTimes: [0.25, 0.75], duration: 1.5)
        controller.play(hostTime: 0.0)
        controller.pause(hostTime: 0.6)
        XCTAssertFalse(controller.isPlaying)

        controller.restart(hostTime: 0.7)
        XCTAssertEqual(controller.currentTime, 0.0)
        XCTAssertFalse(controller.isPlaying,
                       "Restart while paused must not silently resume playback")
    }

    // MARK: - Pause/play repetition does not double-fire

    func testRepeatedPausePlayDoesNotDoubleFire() {
        var controller = makeController(eventStartTimes: [0.25, 0.75, 1.25], duration: 1.5)
        controller.play(hostTime: 0.0)

        var fired: [TimeInterval] = []
        fired.append(contentsOf: controller.tick(hostTime: 0.5).map(\.startTime))
        controller.pause(hostTime: 0.5)
        // Repeated pause is a no-op.
        controller.pause(hostTime: 0.5)
        controller.play(hostTime: 0.5)
        // Repeated play is a no-op.
        controller.play(hostTime: 0.5)
        fired.append(contentsOf: controller.tick(hostTime: 1.0).map(\.startTime))
        controller.pause(hostTime: 1.0)
        controller.play(hostTime: 1.1)
        fired.append(contentsOf: controller.tick(hostTime: 1.4).map(\.startTime))

        XCTAssertEqual(fired, [0.25, 0.75, 1.25])
    }

    // MARK: - Restart does not duplicate within a tick

    func testRestartDoesNotEmitDuplicateEventsWithinATick() {
        var controller = makeController(eventStartTimes: [0.25, 0.75], duration: 1.0)
        controller.play(hostTime: 0.0)
        let firstPass = controller.tick(hostTime: 0.5).map(\.startTime)
        XCTAssertEqual(firstPass, [0.25])

        // Restart resets the cursor; the next tick replays from zero.
        // After restart at hostTime = 0.5 the play anchor is
        // (host: 0.5, player: 0.0), so hostTime = 0.8 → player = 0.3 →
        // the event at 0.25 fires exactly once.
        controller.restart(hostTime: 0.5)
        let restartedPass = controller.tick(hostTime: 0.8).map(\.startTime)
        XCTAssertEqual(restartedPass, [0.25])
        // No duplicates: each fired startTime is unique.
        XCTAssertEqual(Set(restartedPass).count, restartedPass.count)

        // hostTime = 1.4 → player = 0.9 → event at 0.75 fires exactly once.
        let restartedPass2 = controller.tick(hostTime: 1.4).map(\.startTime)
        XCTAssertEqual(restartedPass2, [0.75])
    }

    // MARK: - Playhead clamps to duration

    func testPlayheadClampsToDuration() {
        var controller = makeController(eventStartTimes: [0.5], duration: 1.0)
        controller.play(hostTime: 0.0)
        // Pure derivation: even a host time far past the end clamps.
        XCTAssertEqual(controller.currentTime(at: 100.0), 1.0)
        // Mutating advance also clamps.
        _ = controller.tick(hostTime: 100.0)
        XCTAssertEqual(controller.currentTime, 1.0)
        XCTAssertLessThanOrEqual(controller.currentTime, controller.duration)
    }

    func testPlayheadIsNeverNegative() {
        var controller = makeController(eventStartTimes: [0.5], duration: 1.0)
        controller.play(hostTime: 1.0)
        // A "before-start" sample is just clamped to zero.
        XCTAssertEqual(controller.currentTime(at: 0.0), 0.0)
        XCTAssertGreaterThanOrEqual(controller.currentTime, 0.0)
    }

    // MARK: - No replay without timeline

    func testNoReplayWithoutTimeline() {
        let emptyTimeline = SessionReplayTimeline(takeDurationSeconds: 0.0, events: [])
        var controller = OverlayReplayController(timeline: emptyTimeline)
        XCTAssertFalse(controller.hasTimeline)
        XCTAssertEqual(controller.duration, 0.0)

        controller.play(hostTime: 0.0)
        XCTAssertFalse(controller.isPlaying,
                       "Play must be a no-op when the timeline has no playable duration")
        XCTAssertTrue(controller.tick(hostTime: 1.0).isEmpty)
        controller.restart(hostTime: 2.0)
        XCTAssertEqual(controller.currentTime, 0.0)
        XCTAssertFalse(controller.isPlaying)
    }

    // MARK: - Determinism across controllers

    func testIdenticalInputsProduceIdenticalState() {
        let timelineA = makeTimeline(eventStartTimes: [0.25, 0.75, 1.25], duration: 1.5)
        let timelineB = makeTimeline(eventStartTimes: [0.25, 0.75, 1.25], duration: 1.5)
        var controllerA = OverlayReplayController(timeline: timelineA)
        var controllerB = OverlayReplayController(timeline: timelineB)

        controllerA.play(hostTime: 0.0)
        controllerB.play(hostTime: 0.0)

        for hostTime in stride(from: 0.0, through: 2.0, by: 0.25) {
            let firedA = controllerA.tick(hostTime: hostTime).map(\.startTime)
            let firedB = controllerB.tick(hostTime: hostTime).map(\.startTime)
            XCTAssertEqual(firedA, firedB)
        }
        XCTAssertEqual(controllerA, controllerB)
    }

    // MARK: - Helpers

    private func makeController(
        eventStartTimes: [Double],
        duration: Double
    ) -> OverlayReplayController {
        OverlayReplayController(
            timeline: makeTimeline(
                eventStartTimes: eventStartTimes,
                duration: duration
            )
        )
    }

    private func makeTimeline(
        eventStartTimes: [Double],
        duration: Double
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
        return SessionReplayTimeline.build(from: snapshot, takeDuration: duration)
    }
}
