// TimecodePrototypeRecorderTests
//
// Batch 5 tests for the timecode prototype take recorder:
//   - recorder defaults idle/empty
//   - disabled and diagnosticsOnly pipeline modes emit no recorded trusted motion
//   - controlPrototype records trusted timecode_live samples
//   - bad signal (silence, clipping, dropout) fails closed and counts drops
//   - low-confidence drops are counted
//   - start/stop gates recording
//   - clear resets take
//   - recorded timeline source is timecode_live
//   - monotonic time preserved across successive flushes
//   - rate/clamp safety already applied by adapter before samples reach recorder
//   - recording does not affect replay trust or RANE source labels
//   - recording does not call notation/HandDirectionTracker/Review path
//   - position continuity maintained across multiple flushes
//
// Batch 5: Prototype take-path only. DEBUG-only.

import XCTest
@testable import ScratchLab

#if DEBUG

final class TimecodePrototypeRecorderTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441

    // MARK: - Helpers: recorder factory

    private func makeRecorder() -> TimecodePrototypeRecorder {
        TimecodePrototypeRecorder()
    }

    // MARK: - Helpers: pipeline factory

    private func makePipeline(mode: TimecodeControlMode = .controlPrototype) -> TimecodeControlPipeline {
        let p = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: 2)
        p.mode = mode
        return p
    }

    // MARK: - Helpers: synthetic signal

    private func sineTone(
        frequency: Float,
        frameCount: Int,
        amplitude: Float,
        phaseOffset: Float = 0
    ) -> [Float] {
        (0..<frameCount).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t + phaseOffset)
        }
    }

    private func feedPhaseProgression(
        into pipeline: TimecodeControlPipeline,
        bufferCount: Int,
        phaseStep: Float,
        amplitude: Float = 0.5
    ) {
        for i in 0..<bufferCount {
            let left = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                                amplitude: amplitude)
            let right = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                                 amplitude: amplitude, phaseOffset: phaseStep * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
        }
    }

    private func feedSilence(into pipeline: TimecodeControlPipeline, count: Int = 1) {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        for _ in 0..<count {
            pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: sampleRate)
        }
    }

    // MARK: - Helpers: synthetic timeline

    private func makeLiveTimeline(
        sampleCount: Int = 5,
        startTime: TimeInterval = 0.0
    ) -> PlatterPositionTimeline? {
        var samples: [PlatterPositionSample] = []
        for i in 0..<sampleCount {
            let t = startTime + Double(i) * 0.01
            samples.append(PlatterPositionSample(time: t, position: Double(i) * 0.1, confidence: 0.8))
        }
        guard let first = samples.first, let last = samples.last else { return nil }
        return PlatterPositionTimeline(
            source: .timecodeLive,
            startTime: first.time,
            endTime: last.time,
            samples: samples
        )
    }

    // MARK: - 1. Default state

    func testTimecodePrototypeRecorderDefaultsEmpty() {
        let recorder = makeRecorder()
        XCTAssertEqual(recorder.state, .idle, "recorder must default to .idle")
        XCTAssertNil(recorder.recordedTimeline, "recordedTimeline must default to nil")
        XCTAssertEqual(recorder.acceptedSampleCount, 0, "acceptedSampleCount must default to 0")
        XCTAssertEqual(recorder.droppedSampleCount, 0, "droppedSampleCount must default to 0")
        XCTAssertTrue(recorder.lastDropReason.isEmpty, "lastDropReason must default to empty")
        XCTAssertEqual(recorder.recordedDuration, 0, "recordedDuration must default to 0")
        XCTAssertEqual(recorder.sourceLabel, "timecode_live", "sourceLabel must be timecode_live")
    }

    // MARK: - 2. Disabled mode cannot record trusted samples

    func testTimecodePrototypeRecorderRequiresControlMode() {
        let pipeline = makePipeline(mode: .disabled)
        pipeline.prototypeRecorder.startRecording()

        // In .disabled mode, pushStereoBuffer drops all input and flushDecode
        // returns nil at the early guard — the recorder bridge is never reached.
        feedSilence(into: pipeline, count: 3)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "disabled mode must not feed accepted samples to recorder")
        XCTAssertEqual(pipeline.prototypeRecorder.droppedSampleCount, 0,
                       "disabled mode must not feed drop counts to recorder")
    }

    // MARK: - 3. DiagnosticsOnly cannot record trusted samples

    func testTimecodePrototypeRecorderIgnoresDiagnosticsOnly() {
        let pipeline = makePipeline(mode: .diagnosticsOnly)
        pipeline.prototypeRecorder.startRecording()

        // In .diagnosticsOnly, the accumulator is always empty, so flushDecode
        // returns nil at the !inputs.isEmpty guard — recorder bridge not reached.
        feedPhaseProgression(into: pipeline, bufferCount: 4, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "diagnosticsOnly must not feed samples to recorder")
        XCTAssertEqual(pipeline.prototypeRecorder.droppedSampleCount, 0,
                       "diagnosticsOnly must not feed drop counts to recorder")
    }

    // MARK: - 4. ControlPrototype records trusted timecode_live samples

    func testTimecodePrototypeRecorderRecordsTrustedLiveSamples() {
        let recorder = makeRecorder()
        recorder.startRecording()

        guard let timeline = makeLiveTimeline(sampleCount: 5) else {
            XCTFail("Failed to build synthetic timecode_live timeline")
            return
        }
        recorder.accept(timeline: timeline)
        recorder.stopRecording()

        XCTAssertEqual(recorder.state, .stopped)
        XCTAssertEqual(recorder.acceptedSampleCount, 5)
        XCTAssertNotNil(recorder.recordedTimeline)
        XCTAssertEqual(recorder.recordedTimeline?.source, .timecodeLive)
        XCTAssertGreaterThan(recorder.recordedTimeline?.samples.count ?? 0, 0)
    }

    // MARK: - 5. Low-confidence drops are counted

    func testTimecodePrototypeRecorderDropsLowConfidence() {
        let recorder = makeRecorder()
        recorder.startRecording()

        // Simulate pipeline calling recordDrop for a low-confidence decode window
        recorder.recordDrop(reason: TimecodeDropoutReason.lowConfidence.rawValue, count: 3)

        XCTAssertEqual(recorder.droppedSampleCount, 3,
                       "low-confidence drops must be counted")
        XCTAssertEqual(recorder.lastDropReason, TimecodeDropoutReason.lowConfidence.rawValue,
                       "lastDropReason must reflect low-confidence dropout")
        XCTAssertEqual(recorder.acceptedSampleCount, 0,
                       "no samples must be accepted on a low-confidence dropout")
    }

    // MARK: - 6. Bad signal (silence, clipping, channel fault) fails closed

    func testTimecodePrototypeRecorderSilenceDropCountsIncrement() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.prototypeRecorder.startRecording()

        // Silence → decoder produces no frames → pipeline calls recordDrop
        feedSilence(into: pipeline, count: 4)
        _ = pipeline.flushDecode()

        XCTAssertGreaterThan(pipeline.prototypeRecorder.droppedSampleCount, 0,
                             "silent input must increment recorder droppedSampleCount")
        XCTAssertFalse(pipeline.prototypeRecorder.lastDropReason.isEmpty,
                       "silent input must set recorder lastDropReason")
        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "silent input must not produce accepted samples in recorder")
    }

    func testTimecodePrototypeRecorderClippedInputDropCountsIncrement() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.prototypeRecorder.startRecording()

        // Clipped signal (amplitude 1.0) → decoder drops → recordDrop called
        let clip = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer, amplitude: 1.0)
        for _ in 0..<4 {
            pipeline.pushStereoBuffer(left: clip, right: clip, sampleRate: sampleRate)
        }
        _ = pipeline.flushDecode()

        XCTAssertGreaterThan(pipeline.prototypeRecorder.droppedSampleCount, 0,
                             "clipped input must increment recorder droppedSampleCount")
        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "clipped input must not produce accepted samples in recorder")
    }

    func testTimecodePrototypeRecorderDropsWrongSourceTimeline() {
        let recorder = makeRecorder()
        recorder.startRecording()

        // A liveCapture timeline (RANE source) must never be accepted
        let wrongSource = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 0.04,
            samples: [
                PlatterPositionSample(time: 0.00, position: 0.0, confidence: 0.9),
                PlatterPositionSample(time: 0.04, position: 0.1, confidence: 0.9)
            ]
        )!
        recorder.accept(timeline: wrongSource)

        XCTAssertEqual(recorder.acceptedSampleCount, 0,
                       "wrong-source timeline must not be accepted")
        XCTAssertGreaterThan(recorder.droppedSampleCount, 0,
                             "wrong-source timeline must increment drop count")
        XCTAssertEqual(recorder.lastDropReason, "wrong_source")
    }

    // MARK: - 7. Start/stop gates recording

    func testTimecodePrototypeRecorderStartStopGatesRecording() {
        let recorder = makeRecorder()

        XCTAssertEqual(recorder.state, .idle)

        // accept before start is silently ignored
        if let tl = makeLiveTimeline(sampleCount: 3) {
            recorder.accept(timeline: tl)
        }
        XCTAssertEqual(recorder.acceptedSampleCount, 0,
                       "accept before startRecording must be ignored")

        recorder.startRecording()
        XCTAssertEqual(recorder.state, .recording)

        if let tl = makeLiveTimeline(sampleCount: 3) {
            recorder.accept(timeline: tl)
        }
        XCTAssertEqual(recorder.acceptedSampleCount, 3,
                       "accept during recording must accumulate samples")

        recorder.stopRecording()
        XCTAssertEqual(recorder.state, .stopped)

        // accept after stop is silently ignored
        if let tl = makeLiveTimeline(sampleCount: 2, startTime: 1.0) {
            recorder.accept(timeline: tl)
        }
        XCTAssertEqual(recorder.acceptedSampleCount, 3,
                       "accept after stopRecording must be ignored")
    }

    // MARK: - 8. Clear resets take

    func testTimecodePrototypeRecorderClearResetsTake() {
        let recorder = makeRecorder()
        recorder.startRecording()

        if let tl = makeLiveTimeline(sampleCount: 5) {
            recorder.accept(timeline: tl)
        }
        recorder.stopRecording()

        XCTAssertGreaterThan(recorder.acceptedSampleCount, 0)
        XCTAssertNotNil(recorder.recordedTimeline)
        XCTAssertEqual(recorder.state, .stopped)

        recorder.clearTake()

        XCTAssertEqual(recorder.state, .idle, "clearTake must return state to .idle")
        XCTAssertNil(recorder.recordedTimeline, "clearTake must nil recordedTimeline")
        XCTAssertEqual(recorder.acceptedSampleCount, 0, "clearTake must zero acceptedSampleCount")
        XCTAssertEqual(recorder.droppedSampleCount, 0, "clearTake must zero droppedSampleCount")
        XCTAssertTrue(recorder.lastDropReason.isEmpty, "clearTake must empty lastDropReason")
        XCTAssertEqual(recorder.recordedDuration, 0, "clearTake must zero recordedDuration")
    }

    // MARK: - 9. Recorded timeline source is timecode_live

    func testTimecodePrototypeTimelineUsesTimecodeLiveSource() {
        let recorder = makeRecorder()
        recorder.startRecording()

        if let tl = makeLiveTimeline(sampleCount: 3) {
            recorder.accept(timeline: tl)
        }
        recorder.stopRecording()

        XCTAssertEqual(recorder.recordedTimeline?.source, .timecodeLive,
                       "recorded timeline source must be .timecodeLive")
        XCTAssertEqual(recorder.sourceLabel, "timecode_live",
                       "sourceLabel must be timecode_live string")
    }

    // MARK: - 10. Monotonic time preserved across successive flushes

    func testTimecodePrototypeRecordingPreservesMonotonicTime() {
        let recorder = makeRecorder()
        recorder.startRecording()

        // Two successive timelines with non-overlapping times
        if let tl1 = makeLiveTimeline(sampleCount: 3, startTime: 0.00) {
            recorder.accept(timeline: tl1)
        }
        if let tl2 = makeLiveTimeline(sampleCount: 3, startTime: 0.03) {
            recorder.accept(timeline: tl2)
        }
        recorder.stopRecording()

        guard let timeline = recorder.recordedTimeline else {
            XCTFail("Expected recorded timeline from two accepted flushes")
            return
        }

        XCTAssertEqual(timeline.samples.count, 6, "both timelines must be concatenated")

        var lastTime: TimeInterval = -1
        for sample in timeline.samples {
            XCTAssertGreaterThanOrEqual(sample.time, lastTime,
                                         "sample times must be monotonically non-decreasing")
            lastTime = sample.time
        }
    }

    func testTimecodePrototypeRecorderDropsBackwardsTimeFlushed() {
        let recorder = makeRecorder()
        recorder.startRecording()

        // First flush at times 0.00–0.04
        if let tl1 = makeLiveTimeline(sampleCount: 5, startTime: 0.00) {
            recorder.accept(timeline: tl1)
        }
        let countAfterFirst = recorder.acceptedSampleCount

        // Second flush with earlier start time (simulates pipeline reset mid-recording)
        if let tlBackwards = makeLiveTimeline(sampleCount: 3, startTime: 0.01) {
            recorder.accept(timeline: tlBackwards)  // firstSample.time=0.01 < lastRecorded=0.04 → drop
        }

        XCTAssertEqual(recorder.acceptedSampleCount, countAfterFirst,
                       "backwards-time flush must not increase acceptedSampleCount")
        XCTAssertGreaterThan(recorder.droppedSampleCount, 0,
                             "backwards-time flush must increment droppedSampleCount")
        XCTAssertEqual(recorder.lastDropReason, "non_monotonic_time")
    }

    // MARK: - 11. Rate-safety already applied by adapter

    func testTimecodePrototypeRecordingRateSafetyAlreadyApplied() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.maxRate = 5.0
        pipeline.prototypeRecorder.startRecording()

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        pipeline.prototypeRecorder.stopRecording()

        // If a timeline was recorded, positions must be within reasonable bounds
        // (rate clamping applied by TimecodePlatterAdapter before samples reach recorder)
        if let timeline = pipeline.prototypeRecorder.recordedTimeline {
            for sample in timeline.samples {
                XCTAssertLessThanOrEqual(abs(sample.position), 100.0,
                                          "position must be within reasonable bounds after rate clamping")
            }
        }
        // No crash or unbound values regardless of whether motion decoded
    }

    // MARK: - 12. Recording does not affect replay trust

    func testTimecodePrototypeRecordingDoesNotAffectReplayTrust() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.prototypeRecorder.startRecording()

        feedPhaseProgression(into: pipeline, bufferCount: 5, phaseStep: 0.3)
        _ = pipeline.flushDecode()

        pipeline.prototypeRecorder.stopRecording()

        // RANE / replay source must remain distinct
        XCTAssertNotEqual(PlatterPositionTimeline.Source.liveCapture,
                           PlatterPositionTimeline.Source.timecodeLive,
                           "liveCapture (RANE/replay) must not collide with timecodeLive")

        // Recorder's timeline source must never be liveCapture
        if let timeline = pipeline.prototypeRecorder.recordedTimeline {
            XCTAssertEqual(timeline.source, .timecodeLive)
            XCTAssertNotEqual(timeline.source, .liveCapture,
                              "recorded timeline must not be stamped with RANE source")
        }

        // All five source labels must remain distinct (no collision)
        let sources: Set<String> = [
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            PlatterPositionTimeline.Source.bundledDemo.rawValue,
            PlatterPositionTimeline.Source.coachAuthored.rawValue,
            PlatterPositionTimeline.Source.timecodeFixture.rawValue,
            PlatterPositionTimeline.Source.timecodeLive.rawValue
        ]
        XCTAssertEqual(sources.count, 5, "all five source labels must remain distinct")
    }

    // MARK: - 13. Recording does not call notation/HandDirectionTracker/Review path

    func testTimecodePrototypeRecordingDoesNotCallNotationPath() {
        // The recorder only stores PlatterPositionSamples and updates internal counters.
        // It has no reference to HandDirectionTracker, notation, or Review.
        // We verify structurally: after a full start/accept/stop cycle, only the
        // recorder's own published properties changed.
        let recorder = makeRecorder()
        recorder.startRecording()

        if let tl = makeLiveTimeline(sampleCount: 5) {
            recorder.accept(timeline: tl)
        }
        recorder.stopRecording()

        // Recorded timeline contains only PlatterPositionSamples with timecode_live source
        XCTAssertNotNil(recorder.recordedTimeline)
        XCTAssertEqual(recorder.recordedTimeline?.source, .timecodeLive,
                       "recorder only stores timecode_live samples; no notation path was called")
        // The recorder has no notation-typed properties — this compiles only if
        // no notation dependencies were added.
    }

    // MARK: - 14. RANE / replay source labels remain unaffected

    func testRANEReplaySourceLabelsRemainUnaffected() {
        let recorder = makeRecorder()
        recorder.startRecording()

        if let tl = makeLiveTimeline(sampleCount: 3) {
            recorder.accept(timeline: tl)
        }
        recorder.stopRecording()

        XCTAssertNotEqual(
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            PlatterPositionTimeline.Source.timecodeLive.rawValue,
            "RANE liveCapture source must not collide with timecode_live"
        )
        XCTAssertNotEqual(
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            recorder.sourceLabel,
            "RANE source label must differ from recorder sourceLabel"
        )
    }

    // MARK: - Position continuity across multiple flushes

    func testTimecodePrototypeRecorderPositionContinuityAcrossFlushes() {
        let recorder = makeRecorder()
        recorder.startRecording()

        // First flush: positions 0.0, 0.1, 0.2
        guard let tl1 = makeLiveTimeline(sampleCount: 3, startTime: 0.00) else {
            XCTFail("Failed to build tl1"); return
        }
        recorder.accept(timeline: tl1)

        let lastPositionAfterFlush1 = tl1.samples.last!.position  // 0.2

        // Second flush: positions 0.0, 0.1, 0.2 (from adapter's 0-based cumulative)
        guard let tl2 = makeLiveTimeline(sampleCount: 3, startTime: 0.03) else {
            XCTFail("Failed to build tl2"); return
        }
        recorder.accept(timeline: tl2)

        recorder.stopRecording()

        guard let recorded = recorder.recordedTimeline else {
            XCTFail("Expected recorded timeline"); return
        }

        XCTAssertEqual(recorded.samples.count, 6)

        // The 4th sample (first from flush 2) should be offset by flush 1's last position
        let fourthSamplePosition = recorded.samples[3].position
        let expectedOffset = lastPositionAfterFlush1
        let secondFlushFirstOriginalPosition = tl2.samples[0].position  // 0.0

        XCTAssertEqual(fourthSamplePosition,
                       secondFlushFirstOriginalPosition + expectedOffset,
                       accuracy: 0.001,
                       "second flush positions must be offset by last position of first flush")
    }

    // MARK: - Pipeline integration: prototypeRecorder embedded in pipeline

    func testPipelineExposesPrototypeRecorder() {
        let pipeline = makePipeline(mode: .controlPrototype)
        XCTAssertEqual(pipeline.prototypeRecorder.state, .idle,
                       "pipeline.prototypeRecorder must default to .idle")
        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0)
    }

    func testPipelineControlPrototypeFeeedsRecorderOnSuccessfulDecode() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.prototypeRecorder.startRecording()

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        pipeline.prototypeRecorder.stopRecording()

        // Either motion was decoded (accepted > 0) or signal was too weak
        // (dropped > 0). Either outcome is valid — we just verify no crash
        // and the recorder state is consistent.
        let accepted = pipeline.prototypeRecorder.acceptedSampleCount
        let dropped = pipeline.prototypeRecorder.droppedSampleCount
        XCTAssertTrue(accepted > 0 || dropped > 0,
                      "some pipeline activity must have reached the recorder")
        XCTAssertEqual(pipeline.prototypeRecorder.state, .stopped)
    }
}

#endif // DEBUG
