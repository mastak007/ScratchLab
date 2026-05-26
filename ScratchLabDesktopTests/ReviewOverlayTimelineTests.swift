import XCTest
@testable import ScratchLab

final class ReviewOverlayTimelineTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_900_000)

    // MARK: - Deterministic ordering

    func testOverlayPreservesDeterministicEventOrdering() {
        let overlay = makeOverlay(
            targetAudio: [(startTime: 1.5, kind: "scratchBurst"),
                          (startTime: 0.5, kind: "scratchBurst")],
            targetDuration: 2.0,
            capturedAudio: [(startTime: 0.6, kind: "scratchBurst"),
                            (startTime: 1.4, kind: "scratchBurst")],
            capturedDuration: 2.0
        )

        // Each underlying timeline is sorted by SessionReplayTimeline.build
        // and the overlay must preserve that ordering — it is purely a
        // pair container.
        XCTAssertEqual(overlay.target.events.map(\.startTime), [0.5, 1.5])
        XCTAssertEqual(overlay.captured.events.map(\.startTime), [0.6, 1.4])
    }

    func testOverlayBuildIsDeterministicAcrossInvocations() {
        let targetSnapshot = snapshot(
            audio: [(startTime: 0.5, kind: "scratchBurst"),
                    (startTime: 1.2, kind: "possibleDrag")],
            movements: [(startTime: 0.7, direction: "forward")]
        )
        let capturedSnapshot = snapshot(
            audio: [(startTime: 0.6, kind: "scratchBurst")],
            movements: [(startTime: 0.8, direction: "forward")]
        )

        let first = ReviewOverlayTimeline.build(
            targetSnapshot: targetSnapshot,
            targetDuration: 2.0,
            capturedSnapshot: capturedSnapshot,
            capturedDuration: 2.0
        )
        let second = ReviewOverlayTimeline.build(
            targetSnapshot: targetSnapshot,
            targetDuration: 2.0,
            capturedSnapshot: capturedSnapshot,
            capturedDuration: 2.0
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.displayDurationSeconds, 2.0)
    }

    // MARK: - Clamp behaviour

    func testClampIsMonotonicAndBounded() {
        let overlay = makeOverlay(
            targetAudio: [(startTime: 0.5, kind: "scratchBurst")],
            targetDuration: 2.0,
            capturedAudio: [(startTime: 0.5, kind: "scratchBurst")],
            capturedDuration: 3.0
        )
        XCTAssertEqual(overlay.displayDurationSeconds, 3.0)

        XCTAssertEqual(overlay.clamp(time: -1.0), 0.0)
        XCTAssertEqual(overlay.clamp(time: 0.0), 0.0)
        XCTAssertEqual(overlay.clamp(time: 1.5), 1.5)
        XCTAssertEqual(overlay.clamp(time: 3.0), 3.0)
        XCTAssertEqual(overlay.clamp(time: 7.5), 3.0)

        // Monotonicity over a sweep.
        let inputs = stride(from: -1.0, through: 5.0, by: 0.25).map { $0 }
        let outputs = inputs.map { overlay.clamp(time: $0) }
        for index in 1..<outputs.count {
            XCTAssertGreaterThanOrEqual(outputs[index], outputs[index - 1])
        }
    }

    func testEmptyOverlayIsSafe() {
        let overlay = ReviewOverlayTimeline(
            target: SessionReplayTimeline(takeDurationSeconds: 0.0, events: []),
            captured: SessionReplayTimeline(takeDurationSeconds: 0.0, events: [])
        )
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertEqual(overlay.displayDurationSeconds, 0.0)
        XCTAssertEqual(overlay.clamp(time: 5.0), 0.0)
        XCTAssertEqual(overlay.clamp(time: -5.0), 0.0)
    }

    func testNegativeDurationsClampToZero() {
        let overlay = ReviewOverlayTimeline.build(
            targetSnapshot: snapshot(),
            targetDuration: -2.0,
            capturedSnapshot: snapshot(),
            capturedDuration: -5.0
        )
        XCTAssertEqual(overlay.displayDurationSeconds, 0.0)
        XCTAssertTrue(overlay.isEmpty)
    }

    func testMismatchedDurationsUseJointSpan() {
        let overlay = makeOverlay(
            targetAudio: [(startTime: 0.5, kind: "scratchBurst")],
            targetDuration: 2.0,
            capturedAudio: [(startTime: 4.0, kind: "scratchBurst")],
            capturedDuration: 5.0
        )
        // Joint span is the larger of the two — the shorter target
        // timeline cannot truncate the captured axis.
        XCTAssertEqual(overlay.displayDurationSeconds, 5.0)
        XCTAssertEqual(overlay.clamp(time: 4.5), 4.5)
        XCTAssertEqual(overlay.clamp(time: 10.0), 5.0)
    }

    // MARK: - Replay cursor integration

    func testReplayClockCursorIsMonotonicAfterOverlayClamp() {
        // Drive a SessionReplayClock against the captured timeline and
        // funnel the cursor time through the overlay clamp. The clamp
        // never moves backward as host time advances.
        let overlay = makeOverlay(
            targetAudio: [(startTime: 0.5, kind: "scratchBurst")],
            targetDuration: 2.0,
            capturedAudio: [(startTime: 0.5, kind: "scratchBurst"),
                            (startTime: 1.5, kind: "scratchBurst")],
            capturedDuration: 3.0
        )
        var clock = SessionReplayClock(timeline: overlay.captured)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        var lastClamped: TimeInterval = 0
        for sample in stride(from: 0.0, through: 4.0, by: 0.25) {
            clock.ingest(playerTime: sample, isPlaying: true, hostTime: sample)
            let clamped = overlay.clamp(time: clock.currentTime(hostTime: sample))
            XCTAssertGreaterThanOrEqual(clamped, lastClamped)
            XCTAssertLessThanOrEqual(clamped, overlay.displayDurationSeconds)
            lastClamped = clamped
        }
    }

    func testSeekDoesNotDuplicateEvents() {
        // The overlay reuses SessionReplayClock for playback timing.
        // A seek followed by a tick must not re-fire any event the
        // cursor has already consumed, even though the overlay holds
        // a separate (target) timeline.
        let overlay = makeOverlay(
            targetAudio: [(startTime: 0.5, kind: "scratchBurst"),
                          (startTime: 1.0, kind: "scratchBurst")],
            targetDuration: 2.0,
            capturedAudio: [(startTime: 0.5, kind: "scratchBurst"),
                            (startTime: 1.0, kind: "scratchBurst"),
                            (startTime: 1.5, kind: "scratchBurst")],
            capturedDuration: 2.0
        )
        var clock = SessionReplayClock(timeline: overlay.captured)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)

        var fired: [TimeInterval] = []
        fired.append(contentsOf: clock.tick(hostTime: 2.0).map(\.startTime))
        XCTAssertEqual(fired, [0.5, 1.0, 1.5])

        // Seek back to 0.5 and tick again: the events at 0.5 and 1.0
        // and 1.5 surface once more from the new cursor, but the
        // overall fired stream still contains each unique event
        // start time only once per cursor pass — the cursor itself
        // is monotonic between resets.
        clock.seek(to: 0.5)
        let afterSeek = clock.tick(hostTime: 2.0).map(\.startTime)
        XCTAssertEqual(afterSeek, [0.5, 1.0, 1.5])

        // Repeated tick without time advance produces no new events.
        let repeated = clock.tick(hostTime: 2.0)
        XCTAssertTrue(repeated.isEmpty)
    }

    func testCursorClampsToDisplayDurationEvenWhenClockOvershoots() {
        // Captured take is 1.0s but the host overshoots; the overlay's
        // displayDurationSeconds bounds the cursor regardless of what
        // the underlying clock reports.
        let overlay = makeOverlay(
            targetAudio: [(startTime: 0.25, kind: "scratchBurst")],
            targetDuration: 1.0,
            capturedAudio: [(startTime: 0.25, kind: "scratchBurst")],
            capturedDuration: 1.0
        )
        var clock = SessionReplayClock(timeline: overlay.captured)
        clock.ingest(playerTime: 0, isPlaying: true, hostTime: 0)
        let clamped = overlay.clamp(time: clock.currentTime(hostTime: 50.0))
        XCTAssertEqual(clamped, 1.0)
        XCTAssertEqual(clamped, overlay.displayDurationSeconds)
    }

    // MARK: - Helpers

    private func makeOverlay(
        targetAudio: [(startTime: Double, kind: String)] = [],
        targetDuration: Double,
        capturedAudio: [(startTime: Double, kind: String)] = [],
        capturedDuration: Double
    ) -> ReviewOverlayTimeline {
        ReviewOverlayTimeline.build(
            targetSnapshot: snapshot(audio: targetAudio),
            targetDuration: targetDuration,
            capturedSnapshot: snapshot(audio: capturedAudio),
            capturedDuration: capturedDuration
        )
    }

    private func snapshot(
        audio: [(startTime: Double, kind: String)] = [],
        movements: [(startTime: Double, direction: String)] = []
    ) -> CaptureCore.DetectedNotationSnapshot {
        let audioEvents = audio.map {
            CaptureCore.DetectedNotationAudioEvent(
                startTime: $0.startTime,
                endTime: $0.startTime + 0.05,
                duration: 0.05,
                peakLevel: 0.5,
                rmsLevel: 0.2,
                confidence: 0.7,
                eventKind: $0.kind,
                source: "audio"
            )
        }
        let movementEvents = movements.map {
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: $0.startTime,
                endTime: $0.startTime + 0.05,
                startPosition: 0.0,
                endPosition: 1.0,
                direction: $0.direction,
                movementKind: .normalPush,
                speed: 1.0,
                confidence: 0.7,
                source: "detected"
            )
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: movementEvents,
            audioEvents: audioEvents,
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
    }
}
