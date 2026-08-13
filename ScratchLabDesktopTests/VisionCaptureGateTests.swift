import XCTest
import CoreGraphics
@testable import ScratchLab

final class VisionCaptureGateTests: XCTestCase {

    // MARK: - isImpossibleHandJump

    func testNormalScratchVelocityIsNotRejected() {
        // 5% of frame width in 40 ms → 1.25 normalized/sec, well within 4.5
        let from = CGPoint(x: 0.40, y: 0.5)
        let to   = CGPoint(x: 0.45, y: 0.5)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    func testFastScratchVelocityIsNotRejected() {
        // 15% of frame width in 40 ms → 3.75 normalized/sec (fast baby scratch)
        let from = CGPoint(x: 0.20, y: 0.5)
        let to   = CGPoint(x: 0.35, y: 0.5)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    func testVisionNoiseJumpIsRejected() {
        // 80% of frame width in 40 ms → 20 normalized/sec: clearly Vision noise
        let from = CGPoint(x: 0.10, y: 0.5)
        let to   = CGPoint(x: 0.90, y: 0.5)
        XCTAssertTrue(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    func testJumpAtExactThresholdBoundaryIsNotRejected() {
        // Exactly at maxVelocity (4.5): dx = 4.5 * 0.04 = 0.18, not strictly greater
        let from = CGPoint(x: 0.10, y: 0.5)
        let to   = CGPoint(x: 0.28, y: 0.5)  // dx = 0.18
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    func testJumpJustOverThresholdIsRejected() {
        // dx = 0.19 in 40ms → 4.75/sec > 4.5
        let from = CGPoint(x: 0.10, y: 0.5)
        let to   = CGPoint(x: 0.29, y: 0.5)
        XCTAssertTrue(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    func testZeroElapsedNeverRejects() {
        // elapsed == 0 → guard returns false (no division)
        let from = CGPoint(x: 0.0, y: 0.5)
        let to   = CGPoint(x: 1.0, y: 0.5)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0))
    }

    func testLongerGapWithSameJumpIsNotRejected() {
        // Same 0.8 unit jump but over 200 ms → 4.0/sec < 4.5, accepted
        let from = CGPoint(x: 0.10, y: 0.5)
        let to   = CGPoint(x: 0.90, y: 0.5)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.20))
    }

    func testCustomMaxVelocityIsRespected() {
        // dx = 0.10 in 40ms → 2.5/sec; accepted at default 4.5, rejected at 2.0
        let from = CGPoint(x: 0.10, y: 0.5)
        let to   = CGPoint(x: 0.20, y: 0.5)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04, maxVelocity: 4.5))
        XCTAssertTrue(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04, maxVelocity: 2.0))
    }

    func testVerticalOnlyJumpIsNotRejected() {
        // Only y changes; jump check is x-axis only (platter motion is horizontal)
        let from = CGPoint(x: 0.50, y: 0.10)
        let to   = CGPoint(x: 0.50, y: 0.90)
        XCTAssertFalse(MacCaptureEngine.isImpossibleHandJump(from: from, to: to, elapsed: 0.04))
    }

    // MARK: - PlatterPositionRecorder with continuity-filled samples

    func testContinuityFilledSamplesAreIncludedInTimeline() {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        // Two real observations
        recorder.observe(point: CGPoint(x: 0.30, y: 0.5), at: 0.04)
        recorder.observe(point: CGPoint(x: 0.35, y: 0.5), at: 0.08)
        // Three continuity-bridge fills using last known good position
        let lastGood = CGPoint(x: 0.35, y: 0.5)
        recorder.observe(point: lastGood, at: 0.12)
        recorder.observe(point: lastGood, at: 0.16)
        recorder.observe(point: lastGood, at: 0.20)
        // Real observation resumes
        recorder.observe(point: CGPoint(x: 0.40, y: 0.5), at: 0.24)
        let timeline = recorder.finishRecording(at: 0.28)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.samples.count, 6)
    }

    func testGapWithNoContinuityFillProducesFewerSamples() {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        recorder.observe(point: CGPoint(x: 0.30, y: 0.5), at: 0.04)
        recorder.observe(point: CGPoint(x: 0.35, y: 0.5), at: 0.08)
        // Gap: no observe calls
        recorder.observe(point: CGPoint(x: 0.40, y: 0.5), at: 0.24)
        let timeline = recorder.finishRecording(at: 0.28)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.samples.count, 3)
    }

    // MARK: - HandDirectionTracker: short gaps do not create fake reversals

    func testShortGapPreservesDirectionWithoutReversal() {
        let tracker = HandDirectionTracker()
        var time: CFTimeInterval = 0
        let interval: CFTimeInterval = 0.04
        let speed: CGFloat = 0.30  // normalized units per second

        // Establish forward direction
        for i in 0..<4 {
            let x = 0.10 + speed * CGFloat(time)
            tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
            time += interval
            _ = i
        }
        XCTAssertEqual(tracker.direction, .movingForward)

        // Simulate continuity bridge: skip tracker for 3 frames (no recordMiss, no recordObservation)
        time += interval * 3

        // Resume forward motion after the bridge
        for i in 1...3 {
            let x = 0.10 + speed * CGFloat(time) + CGFloat(i) * 0.01
            tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
            time += interval
        }

        // Direction should remain forward — no spurious reversal from the gap
        XCTAssertEqual(tracker.direction, .movingForward)
        XCTAssertNotEqual(tracker.direction, .movingBackward)
    }

    func testShortGapDoesNotAdvanceMissCount() {
        // Validates that skipping recordMiss (continuity bridge pattern) leaves
        // the tracker in a better state than calling recordMiss would.
        let tracker = HandDirectionTracker()
        var time: CFTimeInterval = 0
        let interval: CFTimeInterval = 0.04

        for _ in 0..<4 {
            tracker.recordObservation(rawPoint: CGPoint(x: 0.10 + 0.02 * CGFloat(time / interval), y: 0.5), at: time)
            time += interval
        }
        XCTAssertEqual(tracker.direction, .movingForward)

        // Call recordMiss once (simulating what happens after bridge expires)
        _ = tracker.recordMiss()
        XCTAssertEqual(tracker.missedCount, 1)
        // Should still hold direction — only 1 miss, within holdFrames
        XCTAssertEqual(tracker.direction, .movingForward)
    }

    func testImpossibleJumpAfterGapDoesNotPollutePlatterTimeline() {
        // After a legitimate gap, a Vision noise spike (impossible jump) should
        // NOT appear in the platter recorder. Simulate: record 2 samples, then
        // the caller detects an impossible jump and skips feeding the recorder.
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        recorder.observe(point: CGPoint(x: 0.30, y: 0.5), at: 0.04)
        recorder.observe(point: CGPoint(x: 0.35, y: 0.5), at: 0.08)
        // Simulate impossible-jump detection: caller does NOT call observe for the jumped point.
        // (The real MacCaptureEngine calls handleHandTrackingMiss instead.)
        recorder.observe(point: CGPoint(x: 0.40, y: 0.5), at: 0.20)  // next valid point
        let timeline = recorder.finishRecording(at: 0.24)
        XCTAssertNotNil(timeline)
        // The jumped-to position (0.90) is absent; only the legitimate 3 points appear
        XCTAssertEqual(timeline?.samples.count, 3)
        let xs = timeline?.samples.map { $0.position } ?? []
        // All accumulated deltas should be small (not a huge positive spike from 0.35→0.90)
        let maxDelta = xs.max().map { abs($0) } ?? 0
        XCTAssertLessThan(maxDelta, 0.5, "Platter timeline should not contain noise from an impossible jump")
    }

    // MARK: - RoutineDetectedNotationBuilder: extreme tracking and stroke promotion

    func testBuilderProducesMultipleEventsFromBabyScratchAt12Hz() {
        // Simulate a Baby Scratch at ~12 Hz (83 ms per frame, 250 ms per stroke).
        // .movingLeft = camera-rightward (semantic backward) = x INCREASING
        // .movingRight = camera-leftward (semantic forward) = x DECREASING
        // The corrected shouldAdvanceExtreme (>= for .back, <= for .forward) lets
        // furthestPosition advance each frame, so endTime > startTime → events are created.
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 0)
        var t: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.083
        var x: CGFloat = 0.30

        for _ in 0..<6 {
            // Three frames of backward scratch (camera-rightward: x increases)
            for _ in 0..<3 {
                builder.recordObservation(
                    state: .movingLeft,
                    position: Double(x),
                    confidence: 1.0,
                    now: t
                )
                x += 0.05
                t += dt
            }
            // Three frames of forward scratch (camera-leftward: x decreases)
            for _ in 0..<3 {
                builder.recordObservation(
                    state: .movingRight,
                    position: Double(x),
                    confidence: 1.0,
                    now: t
                )
                x -= 0.05
                t += dt
            }
        }

        let events = builder.movementEvents(now: t)
        XCTAssertGreaterThan(events.count, 1,
            "Baby Scratch at 12 Hz should produce multiple movement events; got \(events.count)")
    }

    func testBuilderEventSpansFullStrokeAmplitude() {
        // Feed one backward stroke (x increasing 0.30 → 0.50 over 4 frames) then switch.
        // After the fix, endPosition should equal the peak x (0.50), not the start x.
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 0)
        var t: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.083

        let positions: [CGFloat] = [0.30, 0.35, 0.40, 0.45, 0.50]
        for x in positions {
            builder.recordObservation(
                state: .movingLeft,       // backward: x should increase
                position: Double(x),
                confidence: 1.0,
                now: t
            )
            t += dt
        }
        // Switch direction to flush the active movement.
        builder.recordObservation(
            state: .movingRight,
            position: 0.47,
            confidence: 1.0,
            now: t
        )

        let events = builder.movementEvents(now: t)
        XCTAssertFalse(events.isEmpty, "Should produce at least one movement event")

        let backwardEvent = events.first(where: { $0.direction == "backward" })
        XCTAssertNotNil(backwardEvent, "Expected a backward event")
        if let ev = backwardEvent {
            XCTAssertEqual(ev.startPosition, 0.30, accuracy: 0.01)
            XCTAssertEqual(ev.endPosition, 0.50, accuracy: 0.01,
                "endPosition should be the peak x reached (0.50), not a near-start value")
            XCTAssertGreaterThan(ev.endTime, ev.startTime)
        }
    }

    func testBuilderProducesNoEventsFromFlatSteadyMotion() {
        // Feeding only .steady states should never produce movement events.
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 0)
        var t: CFTimeInterval = 0
        for _ in 0..<20 {
            builder.recordObservation(
                state: .steady,
                position: Double.random(in: 0.45...0.55),
                confidence: 0.0,
                now: t
            )
            t += 0.083
        }
        let events = builder.movementEvents(now: t)
        XCTAssertEqual(events.count, 0, "Steady-only states should produce no movement events")
    }

    func testBuilderProducesNoEventsFromSearchingContext() {
        // .searching is what publishHandTrackingIfNeeded sends when Vision has no hand.
        // Audio-only context: builder only receives searching/steady — no direction changes.
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 0)
        var t: CFTimeInterval = 0
        for _ in 0..<10 {
            builder.recordObservation(
                state: .searching,
                position: nil,
                confidence: 0.0,
                now: t
            )
            t += 0.083
        }
        let events = builder.movementEvents(now: t)
        XCTAssertEqual(events.count, 0, "Searching-only states must not fabricate movement events")
    }
}
