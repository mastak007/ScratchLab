import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — live sample-position timeline (capture model).
///
/// Pure value-type coverage: no Core MIDI, no AVFoundation, no file I/O, and nothing
/// from notation / replay / beat engine / capture / scoring / export. Every sample is
/// hand-built so the derived travel geometry is deterministic.
///
/// The conceptual contract under test: notation height/length is DERIVED from real
/// sample travel, so a partial scratch must not read as a full-height stroke, a
/// reversal must turn around at the actual mid-sample position, a closed crossfader
/// must mark (not delete) a segment, and the captured stream stays monotonic in time
/// and clamped to 0...1.
final class ScratchSampleTimelineTests: XCTestCase {

    /// Appends a forward ramp of `position` samples (one per 10 ms), velocity = +1.
    private func appendRamp(_ timeline: inout ScratchSampleTimeline,
                            positions: [Double],
                            startTime: TimeInterval = 0,
                            step: TimeInterval = 0.01,
                            crossfader: Double? = nil) {
        for (index, position) in positions.enumerated() {
            let previous = index > 0 ? positions[index - 1] : position
            let velocity = position - previous
            timeline.append(timeSeconds: startTime + Double(index) * step,
                            position: position,
                            velocity: velocity,
                            crossfader: crossfader)
        }
    }

    // MARK: - Partial travel is not a full-height stroke

    func testPartialTravelDoesNotBecomeFullHeightStroke() {
        var timeline = ScratchSampleTimeline()
        // A scratch that only pushes the "ahhh" sample 40% of the way in and back.
        appendRamp(&timeline, positions: [0.0, 0.1, 0.2, 0.3, 0.4, 0.3, 0.2, 0.1, 0.0])

        XCTAssertEqual(timeline.maxPosition ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(timeline.minPosition ?? -1, 0.0, accuracy: 1e-12)
        // The truthful "height": the span travelled is 0.4, NOT a full 1.0 stroke.
        XCTAssertEqual(timeline.positionSpan, 0.4, accuracy: 1e-12)
        XCTAssertLessThan(timeline.positionSpan, 1.0)
    }

    func testFullTravelDoesSpanWholeSample() {
        var timeline = ScratchSampleTimeline()
        appendRamp(&timeline, positions: [0.0, 0.25, 0.5, 0.75, 1.0])
        XCTAssertEqual(timeline.positionSpan, 1.0, accuracy: 1e-12)
    }

    // MARK: - Reversal at mid-sample is a mid-height direction change

    func testReversalAtMidSampleProducesMidHeightDirectionChange() {
        var timeline = ScratchSampleTimeline()
        // Push in to 0.5, then pull back out — the turn point is mid-sample.
        appendRamp(&timeline, positions: [0.0, 0.2, 0.4, 0.5, 0.4, 0.2, 0.0])

        let reversals = timeline.reversalEvents
        XCTAssertEqual(reversals.count, 1, "exactly one forward→reverse turn")
        // The direction change happens at the mid-sample peak, not at full height.
        XCTAssertEqual(reversals.first?.position ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertLessThan(reversals.first?.position ?? 1, 1.0)
        // The reversing sample reports reverse travel from its signed velocity.
        XCTAssertEqual(reversals.first?.direction, .reverse)
    }

    func testPauseMidStrokeIsNotAReversal() {
        var timeline = ScratchSampleTimeline()
        // Forward, hold (no travel) for a few samples, then keep going forward.
        appendRamp(&timeline, positions: [0.0, 0.2, 0.4, 0.4, 0.4, 0.6, 0.8])
        XCTAssertTrue(timeline.reversalEvents.isEmpty, "a hold is not a turn-around")
    }

    func testDirectionDerivedFromVelocitySign() {
        var timeline = ScratchSampleTimeline()
        timeline.append(timeSeconds: 0, position: 0.5, velocity: 0.0)   // idle
        timeline.append(timeSeconds: 1, position: 0.6, velocity: 0.2)   // forward
        timeline.append(timeSeconds: 2, position: 0.5, velocity: -0.2)  // reverse
        XCTAssertEqual(timeline.events.map(\.direction), [.idle, .forward, .reverse])
    }

    // MARK: - Crossfader closed marks/mutes without deleting timing

    func testCrossfaderClosedMutesSegmentButKeepsTiming() {
        var timeline = ScratchSampleTimeline()
        // Same travel, but the crossfader is shut during the middle of the stroke.
        timeline.append(timeSeconds: 0.00, position: 0.10, velocity: 0.1, crossfader: 0.70)
        timeline.append(timeSeconds: 0.01, position: 0.20, velocity: 0.1, crossfader: 0.00) // closed
        timeline.append(timeSeconds: 0.02, position: 0.30, velocity: 0.1, crossfader: 0.00) // closed
        timeline.append(timeSeconds: 0.03, position: 0.40, velocity: 0.1, crossfader: 0.70)

        // Timing and position are fully preserved across the muted segment.
        XCTAssertEqual(timeline.count, 4)
        XCTAssertEqual(timeline.positionSpan, 0.30, accuracy: 1e-12)
        XCTAssertEqual(timeline.events.map(\.muted), [false, true, true, false])
        // The muted samples still carry real timing and position.
        XCTAssertEqual(timeline.events[1].timeSeconds, 0.01, accuracy: 1e-12)
        XCTAssertEqual(timeline.events[2].position, 0.30, accuracy: 1e-12)
    }

    func testCrossfaderOpenAtRestIsNotMuted() {
        var timeline = ScratchSampleTimeline()
        // Resting crossfader (~0.70) is fully open, well above the cut zone.
        timeline.append(timeSeconds: 0, position: 0.2, velocity: 0.1, crossfader: 0.70)
        XCTAssertEqual(timeline.events.first?.muted, false)
    }

    func testMissingCrossfaderIsNotMuted() {
        var timeline = ScratchSampleTimeline()
        timeline.append(timeSeconds: 0, position: 0.2, velocity: 0.1, crossfader: nil)
        XCTAssertEqual(timeline.events.first?.muted, false)
    }

    // MARK: - Monotonic time + clamped position invariants

    func testPositionIsClampedToUnitRange() {
        var timeline = ScratchSampleTimeline()
        timeline.append(timeSeconds: 0, position: -0.5, velocity: -1)  // below 0
        timeline.append(timeSeconds: 1, position: 1.8, velocity: 1)    // above 1
        timeline.append(timeSeconds: 2, position: 0.5, velocity: -1)   // in range

        XCTAssertEqual(timeline.events.map(\.position), [0.0, 1.0, 0.5])
        XCTAssertTrue(timeline.isPositionClamped)
        XCTAssertEqual(timeline.minPosition, 0.0)
        XCTAssertEqual(timeline.maxPosition, 1.0)
    }

    func testOutOfOrderTimeIsPinnedMonotonic() {
        var timeline = ScratchSampleTimeline()
        timeline.append(timeSeconds: 0.00, position: 0.1, velocity: 0.1)
        timeline.append(timeSeconds: 0.05, position: 0.2, velocity: 0.1)
        timeline.append(timeSeconds: 0.03, position: 0.3, velocity: 0.1) // late/out-of-order

        XCTAssertTrue(timeline.isTimeMonotonic)
        // The late sample inherits the previous time rather than going backwards.
        XCTAssertEqual(timeline.events.map(\.timeSeconds), [0.00, 0.05, 0.05])
    }

    func testEmptyTimelineInvariantsHold() {
        let timeline = ScratchSampleTimeline()
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.positionSpan, 0)
        XCTAssertNil(timeline.minPosition)
        XCTAssertTrue(timeline.isTimeMonotonic)
        XCTAssertTrue(timeline.isPositionClamped)
        XCTAssertTrue(timeline.reversalEvents.isEmpty)
    }

    func testClearResetsCaptureAndCapacityFlag() {
        var timeline = ScratchSampleTimeline()
        appendRamp(&timeline, positions: [0.0, 0.2, 0.4])
        XCTAssertEqual(timeline.count, 3)
        timeline.clear()
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertFalse(timeline.didReachCapacity)
    }
}

/// Captured-timeline replay clock (Slice 9): deterministic play/pause/reset/scrub over a
/// captured span. Pure; it never mutates the timeline it was built from.
final class CapturedTimelineReplayTests: XCTestCase {

    private func spanTimeline() -> ScratchSampleTimeline {
        var timeline = ScratchSampleTimeline()
        // Five samples spanning t = 0 ... 0.4 s (duration 0.4).
        for index in 0..<5 {
            timeline.append(timeSeconds: Double(index) * 0.1, position: Double(index) * 0.2, velocity: 1.0)
        }
        return timeline
    }

    func testReplayAdvancesDeterministically() {
        var replay = CapturedTimelineReplay(timeline: spanTimeline())
        XCTAssertEqual(replay.duration, 0.4, accuracy: 1e-12)
        XCTAssertEqual(replay.fraction, 0, accuracy: 1e-12)

        replay.play()
        XCTAssertTrue(replay.isPlaying)
        replay.tick(deltaSeconds: 0.1)
        XCTAssertEqual(replay.currentTime, 0.1, accuracy: 1e-12)
        XCTAssertEqual(replay.fraction, 0.25, accuracy: 1e-12)
        replay.tick(deltaSeconds: 0.1)
        XCTAssertEqual(replay.fraction, 0.5, accuracy: 1e-12)
    }

    func testPausedReplayDoesNotAdvance() {
        var replay = CapturedTimelineReplay(timeline: spanTimeline())
        replay.play()
        replay.tick(deltaSeconds: 0.1)
        let held = replay.currentTime
        replay.pause()
        replay.tick(deltaSeconds: 0.2)
        XCTAssertEqual(replay.currentTime, held, accuracy: 1e-12)
    }

    func testReplayStopsAtEndAndRestartsOnPlay() {
        var replay = CapturedTimelineReplay(timeline: spanTimeline())
        replay.play()
        replay.tick(deltaSeconds: 10.0) // overshoot
        XCTAssertEqual(replay.currentTime, replay.endTime, accuracy: 1e-12)
        XCTAssertFalse(replay.isPlaying)
        XCTAssertTrue(replay.isAtEnd)
        replay.play() // at end → restart
        XCTAssertEqual(replay.fraction, 0, accuracy: 1e-12)
        XCTAssertTrue(replay.isPlaying)
    }

    func testResetReturnsToStart() {
        var replay = CapturedTimelineReplay(timeline: spanTimeline())
        replay.play()
        replay.tick(deltaSeconds: 0.2)
        replay.reset()
        XCTAssertEqual(replay.currentTime, replay.startTime, accuracy: 1e-12)
        XCTAssertEqual(replay.fraction, 0, accuracy: 1e-12)
        XCTAssertFalse(replay.isPlaying)
    }

    func testSeekClampsToRange() {
        var replay = CapturedTimelineReplay(timeline: spanTimeline())
        replay.seek(toFraction: 0.5)
        XCTAssertEqual(replay.fraction, 0.5, accuracy: 1e-12)
        replay.seek(toFraction: 2.0)
        XCTAssertEqual(replay.fraction, 1.0, accuracy: 1e-12)
        replay.seek(toFraction: -1.0)
        XCTAssertEqual(replay.fraction, 0.0, accuracy: 1e-12)
    }

    func testReplayDoesNotMutateTimeline() throws {
        let timeline = spanTimeline()
        let before = try ScratchSampleTimelineExport(timeline: timeline).jsonData()
        var replay = CapturedTimelineReplay(timeline: timeline)
        replay.play()
        replay.tick(deltaSeconds: 0.3)
        replay.reset()
        let after = try ScratchSampleTimelineExport(timeline: timeline).jsonData()
        XCTAssertEqual(before, after)
    }

    func testEmptyTimelineHasZeroDurationReplay() {
        var replay = CapturedTimelineReplay(timeline: ScratchSampleTimeline())
        XCTAssertEqual(replay.duration, 0, accuracy: 1e-12)
        replay.play()
        XCTAssertFalse(replay.isPlaying) // nothing to play
        replay.tick(deltaSeconds: 1.0)
        XCTAssertEqual(replay.fraction, 0, accuracy: 1e-12)
    }
}
