import XCTest
import CoreGraphics
import QuartzCore
@testable import ScratchLab

/// Phase 3 — locks the behaviour contract of `PlatterPositionRecorder`:
/// integration of upstream tracker samples into a `PlatterPositionTimeline`
/// at end-of-take, state reset across recordings, defensive handling of
/// stray pre-start observations, and non-interference with a sibling
/// `HandDirectionTracker` instance.
///
/// The recorder is NOT wired into `MacCaptureEngine` yet — a future slice
/// will mount it alongside `HandDirectionTracker` and forward the same
/// `(rawPoint, time)` samples to both. These tests exercise the recorder
/// in isolation.
final class PlatterPositionRecorderTests: XCTestCase {

    // MARK: - Fresh state

    /// Test #1 — a freshly-constructed recorder is not recording, has
    /// zero samples, and `finishRecording` returns `nil`.
    func testFreshRecorderHasNoActiveRecording() {
        let recorder = PlatterPositionRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.sampleCount, 0)
        XCTAssertNil(recorder.finishRecording(at: 1.0))
    }

    // MARK: - Lifecycle: start / observe / finish

    /// Test #2 — `startRecording` flips `isRecording` to true; the first
    /// `observe(...)` appends a sample with `position = 0` (no prior
    /// point to delta against); subsequent samples carry the signed
    /// running integration of `Δx`.
    func testIntegrationProducesSignedRunningSum() {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        XCTAssertTrue(recorder.isRecording)

        recorder.observe(point: CGPoint(x: 0.5, y: 0.5), at: 0.0)
        recorder.observe(point: CGPoint(x: 0.6, y: 0.5), at: 0.1)   // Δ +0.1
        recorder.observe(point: CGPoint(x: 0.55, y: 0.5), at: 0.2)  // Δ −0.05
        recorder.observe(point: CGPoint(x: 0.75, y: 0.5), at: 0.3)  // Δ +0.20

        XCTAssertEqual(recorder.sampleCount, 4)

        let timeline = try? XCTUnwrap(recorder.finishRecording(at: 0.3))
        let samples = timeline!.samples
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].position, 0.0,   accuracy: 1e-9)
        XCTAssertEqual(samples[1].position, 0.10,  accuracy: 1e-9)
        XCTAssertEqual(samples[2].position, 0.05,  accuracy: 1e-9)
        XCTAssertEqual(samples[3].position, 0.25,  accuracy: 1e-9)
        for sample in samples {
            XCTAssertEqual(sample.confidence, 1.0)
        }
    }

    /// Test #3 — the drained timeline carries the recorder's `source`
    /// label and Phase 1's invariants hold (start ≤ first sample time,
    /// last sample time ≤ end, sorted by time).
    func testDrainedTimelineSatisfiesPhase1Invariants() throws {
        let recorder = PlatterPositionRecorder(source: .liveCapture)
        recorder.startRecording(at: 1.0)
        recorder.observe(point: CGPoint(x: 0.0, y: 0.5), at: 1.0)
        recorder.observe(point: CGPoint(x: 0.1, y: 0.5), at: 1.5)
        recorder.observe(point: CGPoint(x: 0.2, y: 0.5), at: 2.0)
        let timeline = try XCTUnwrap(recorder.finishRecording(at: 2.0))
        XCTAssertEqual(timeline.source, .liveCapture)
        XCTAssertEqual(timeline.startTime, 1.0)
        XCTAssertEqual(timeline.endTime, 2.0)
        XCTAssertGreaterThanOrEqual(timeline.samples.first!.time, timeline.startTime)
        XCTAssertLessThanOrEqual(timeline.samples.last!.time, timeline.endTime)
    }

    /// Test #4 — when the final sample's time exceeds the `endTime`
    /// passed to `finishRecording`, the timeline's `endTime` widens to
    /// the sample time so Phase 1's `samples.last.time ≤ endTime`
    /// invariant holds.
    func testFinishWidensEndTimeWhenSampleOvershoots() throws {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0.0)
        recorder.observe(point: CGPoint(x: 0.0, y: 0.5), at: 0.0)
        recorder.observe(point: CGPoint(x: 0.5, y: 0.5), at: 5.0)  // overshoots
        let timeline = try XCTUnwrap(recorder.finishRecording(at: 4.0))
        XCTAssertEqual(timeline.endTime, 5.0)
        XCTAssertLessThanOrEqual(timeline.samples.last!.time, timeline.endTime)
    }

    // MARK: - State reset

    /// Test #5 — finishing a recording resets internal state; a follow-up
    /// `startRecording` produces an independent timeline with no carry-
    /// over from the previous take.
    func testFinishResetsStateBetweenRecordings() throws {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        recorder.observe(point: CGPoint(x: 0.0, y: 0.5), at: 0.0)
        recorder.observe(point: CGPoint(x: 1.0, y: 0.5), at: 1.0)
        _ = recorder.finishRecording(at: 1.0)

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.sampleCount, 0)

        recorder.startRecording(at: 10)
        recorder.observe(point: CGPoint(x: 0.2, y: 0.5), at: 10.0)
        recorder.observe(point: CGPoint(x: 0.3, y: 0.5), at: 10.5)
        let timeline = try XCTUnwrap(recorder.finishRecording(at: 10.5))
        XCTAssertEqual(timeline.startTime, 10.0)
        XCTAssertEqual(timeline.endTime, 10.5)
        XCTAssertEqual(timeline.samples.count, 2)
        // Running integration MUST have reset — first sample's position
        // is 0, not carried over from the previous take's last value.
        XCTAssertEqual(timeline.samples[0].position, 0.0, accuracy: 1e-9)
        XCTAssertEqual(timeline.samples[1].position, 0.10, accuracy: 1e-9)
    }

    // MARK: - Defensive handling

    /// Test #6 — `observe(...)` calls outside an active recording are
    /// silently ignored; no sample is appended, no state changes.
    func testObserveOutsideRecordingIsIgnored() {
        let recorder = PlatterPositionRecorder()
        recorder.observe(point: CGPoint(x: 0.5, y: 0.5), at: 0.0)
        XCTAssertEqual(recorder.sampleCount, 0)
        XCTAssertNil(recorder.finishRecording(at: 1.0))
    }

    /// Test #7 — `finishRecording` returns `nil` for a recording that
    /// observed no samples (start without observe).
    func testEmptyRecordingDrainsToNil() {
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        XCTAssertNil(recorder.finishRecording(at: 1.0))
    }

    // MARK: - Tracker non-interference

    /// Test #8 — a `HandDirectionTracker` that runs alongside a recorder
    /// produces the EXACT same `Direction` sequence as a tracker that
    /// runs alone with the same input. The recorder is a sibling
    /// consumer; it must not influence tracker behaviour.
    ///
    /// Phase 3 ships the recorder in isolation (not yet wired into
    /// `MacCaptureEngine`), so this test simulates the eventual wiring
    /// by forwarding the same `(rawPoint, time)` samples to both.
    func testRecorderDoesNotPerturbHandDirectionTracker() {
        // Build a deterministic forward-motion sequence.
        let samples: [(CGPoint, CFTimeInterval)] = (0..<8).map { i in
            (CGPoint(x: 0.30 + CGFloat(i) * 0.025, y: 0.50),
             CFTimeInterval(i) * 0.12)
        }

        // Run a tracker alone.
        let trackerAlone = HandDirectionTracker()
        var alone: [HandDirectionTracker.Direction] = []
        for (point, time) in samples {
            alone.append(trackerAlone.recordObservation(rawPoint: point, at: time))
        }

        // Run a tracker alongside a recorder — same sample sequence.
        let trackerSibling = HandDirectionTracker()
        let recorder = PlatterPositionRecorder()
        recorder.startRecording(at: 0)
        var sibling: [HandDirectionTracker.Direction] = []
        for (point, time) in samples {
            sibling.append(trackerSibling.recordObservation(rawPoint: point, at: time))
            recorder.observe(point: point, at: time)
        }
        _ = recorder.finishRecording(at: samples.last!.1)

        XCTAssertEqual(alone, sibling,
                       "Recorder must not perturb HandDirectionTracker's Direction outputs.")
    }
}
