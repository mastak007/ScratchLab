// DVSOfflineGrainRendererTests
//
// Karl's post-fix hardware listening check ("10 seconds steady forward and
// 15 seconds reversals") still reported Ahhh sounding "slightly garbled like
// its under water" even though the grain-timing jitter fix (112/112 focused
// tests) is in place. Per the handoff, the next step is offline diagnosis —
// not more decoder/calibration tuning and not more hardware time — using a
// DEBUG-only scheduled-grain observer plus an offline renderer that replays
// the saved full-length hardware captures through the *unmodified* production
// scheduler and reconstructs the actual audio an AVAudioPlayerNode would have
// produced, without a running audio device.
//
// This file adds no new production behavior: `scheduledGrainObserver` on
// `ScratchSamplePlaybackController` is nil unless a test sets it, and setting
// it does not change what gets scheduled — it only observes the exact PCM
// and timing already computed by `positionDidChangeOnQueue`.

import AVFAudio
import XCTest
@testable import ScratchLab

#if DEBUG

final class DVSOfflineGrainRendererTests: XCTestCase {

    private struct GrainEvent {
        /// Scheduling-clock time (matches `positionDidChangeOnQueue`'s `now`)
        /// at which this grain was queued.
        let scheduledAt: TimeInterval
        let interrupts: Bool
        /// Real output-time duration this grain occupies (`scheduledOutputWindow`).
        let duration: TimeInterval
        let sampleRate: Double
        /// Exact PCM as scheduled (post edge-fade, post time-stretch), one array per channel.
        let channelData: [[Float]]
        /// Whether this grain went through the sub-0.25x `copyTimeStretched`
        /// software time-stretch path rather than normal varispeed playback.
        let usesSoftwareSlowGrain: Bool
        /// Raw source-frame count feeding the stretch, before stretching.
        let rawSourceFrameCount: Int
    }

    /// The PCM-level (value) and first-difference (slope) discontinuity
    /// between one scheduled grain's last sample and the next scheduled
    /// grain's first sample, per channel-averaged. A real, continuously
    /// varying waveform has near-zero slope discontinuity between adjacent
    /// grains; a large slope jump is audible as a click/buzz at the
    /// scheduler's ~16.7 ms cadence.
    private struct BoundaryDiscontinuity {
        let boundaryIndex: Int
        let valueJump: Float
        let slopeJump: Float
        let involvesSoftwareSlowGrain: Bool
    }

    private final class SchedulingClock {
        var now: TimeInterval = 1
    }

    private struct RenderReport {
        let channelData: [[Float]]
        let sampleRate: Double
        let gapCount: Int
        let totalGapDuration: TimeInterval
        let maxGapDuration: TimeInterval
        let overlapCount: Int
        let totalOverlapDuration: TimeInterval
        /// Real-time (start, duration) of every detected gap, for correlating
        /// against `TickRecord`s to tell an intended no-motion/decode-pause
        /// interval apart from an unexplained scheduling failure.
        let gapIntervals: [(start: TimeInterval, duration: TimeInterval)]
    }

    /// One control-tick's bridge/scheduler outcome, captured alongside grain
    /// events so a detected gap's real time span can be attributed to a
    /// specific cause instead of left as an unexplained hole.
    private struct TickRecord {
        let time: TimeInterval
        let decision: TimecodePlaybackBridgeDecision
        /// `ScratchSamplePlaybackController.lastScheduleSkippedReason` right
        /// after this tick's `positionDidChange` call, if a drive was present.
        /// `nil` when no drive was present (the decision alone explains it) or
        /// when a grain was actually scheduled successfully.
        let skippedReason: String?
    }

    private var localHardwareArchiveDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "debug_captures/timecode/hardware_fixtures/20260731",
                isDirectory: true
            )
    }

    /// The sandboxed test host can't write into the repo tree (only inside
    /// its own container), so this mirrors the debug fixture recorder's
    /// existing writable root (`TimecodeCMSampleBufferAdapter.defaultRootDirectoryURL`)
    /// rather than introducing a second convention.
    private var offlineRenderOutputDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("DebugCaptures", isDirectory: true)
            .appendingPathComponent("Timecode", isDirectory: true)
            .appendingPathComponent("OfflineRenders", isDirectory: true)
    }

    // MARK: - Resampling (mirrors ScratchSamplePlaybackController.copyTimeStretched)

    /// Linearly resamples `source` (one array per channel) to `outputFrameCount`
    /// frames. This is the same technique the production varispeed path uses
    /// to stretch a sub-varispeed-floor grain, applied here uniformly so the
    /// reconstructed timeline reflects what the node's `rate` actually does
    /// to each grain's real-time duration.
    private func resample(_ source: [[Float]], to outputFrameCount: Int) -> [[Float]] {
        let safeCount = max(1, outputFrameCount)
        guard let first = source.first, first.count >= 2 else {
            return source.map { _ in [Float](repeating: 0, count: safeCount) }
        }
        let inputSpan = Double(first.count - 1)
        let outputSpan = Double(max(1, safeCount - 1))
        return source.map { channel in
            (0..<safeCount).map { index -> Float in
                let inputPosition = Double(index) * inputSpan / outputSpan
                let lowerIndex = Int(inputPosition)
                let upperIndex = min(lowerIndex + 1, channel.count - 1)
                let fraction = Float(inputPosition - Double(lowerIndex))
                return channel[lowerIndex] + (channel[upperIndex] - channel[lowerIndex]) * fraction
            }
        }
    }

    // MARK: - Offline timeline reconstruction

    /// Reconstructs the continuous output timeline an `AVAudioPlayerNode`
    /// would have produced from a sequence of real `scheduleBuffer` calls.
    ///
    /// A non-interrupting grain queues after whatever is still playing: if
    /// the queue had already drained before this grain was scheduled, the gap
    /// between the queue's end and `scheduledAt` is a genuine underrun
    /// (rendered as silence). An interrupting grain (direction change) stops
    /// whatever was still queued and starts immediately at `scheduledAt`;
    /// anything trimmed off the previous grain counts as an overlap/discontinuity.
    ///
    /// `grainEdgeFadeFrames` (default 32, matching the committed
    /// `ScratchSamplePlaybackController.grainEdgeFadeFrames`): DVS grains are
    /// queued unfaded by the live scheduler (contiguous grains must not
    /// amplitude-modulate), so every scheduling gap is a hard PCM cut to
    /// silence — a measured click proxy up to 0.74 on scratch takes. This
    /// renderer therefore applies a gap-aware edge fade at each detected gap:
    /// the preceding grain's tail fades out over its last `fadeFrames` samples
    /// and the following grain's head fades in over its first `fadeFrames`
    /// (both clamped to half the grain's own length via
    /// `ScratchSamplePlaybackController.fadeOutTail`/`fadeInHead`). Contiguous
    /// junctions are untouched. Pass 0 to disable (pre-fix A/B behavior).
    private func render(events: [GrainEvent], grainEdgeFadeFrames: Int = 32) -> RenderReport {
        let sampleRate = events.first?.sampleRate ?? 44_100
        var cursor: TimeInterval = events.first?.scheduledAt ?? 0
        var timeline: [(start: TimeInterval, data: [[Float]])] = []
        var gapCount = 0
        var totalGap: TimeInterval = 0
        var maxGap: TimeInterval = 0
        var overlapCount = 0
        var totalOverlap: TimeInterval = 0
        var gapIntervals: [(start: TimeInterval, duration: TimeInterval)] = []

        for event in events {
            let outputFrames = max(1, Int((event.duration * sampleRate).rounded()))
            var rendered = resample(event.channelData, to: outputFrames)

            let start: TimeInterval
            if event.interrupts {
                if cursor > event.scheduledAt {
                    overlapCount += 1
                    totalOverlap += cursor - event.scheduledAt
                }
                start = event.scheduledAt
            } else if event.scheduledAt > cursor {
                gapCount += 1
                let gap = event.scheduledAt - cursor
                totalGap += gap
                maxGap = max(maxGap, gap)
                gapIntervals.append((start: cursor, duration: gap))
                // Gap-aware edge fade (Task 14): smooth the hard cut to
                // silence without touching contiguous junctions.
                if grainEdgeFadeFrames > 0 {
                    if let lastIndex = timeline.indices.last {
                        var tailData = timeline[lastIndex].data
                        for channel in 0..<tailData.count {
                            ScratchSamplePlaybackController.fadeOutTail(&tailData[channel], fadeFrames: grainEdgeFadeFrames)
                        }
                        timeline[lastIndex] = (timeline[lastIndex].start, tailData)
                    }
                    for channel in 0..<rendered.count {
                        ScratchSamplePlaybackController.fadeInHead(&rendered[channel], fadeFrames: grainEdgeFadeFrames)
                    }
                }
                start = event.scheduledAt
            } else {
                start = cursor
            }

            timeline.append((start: start, data: rendered))
            cursor = start + event.duration
        }

        let totalDuration = timeline.last.map {
            $0.start + Double($0.data.first?.count ?? 0) / sampleRate
        } ?? 0
        let totalFrames = max(1, Int((totalDuration * sampleRate).rounded()))
        let channelCount = max(1, timeline.first?.data.count ?? 1)
        var output = Array(repeating: [Float](repeating: 0, count: totalFrames), count: channelCount)

        for entry in timeline {
            let startFrame = max(0, Int((entry.start * sampleRate).rounded()))
            for channel in 0..<min(channelCount, entry.data.count) {
                let samples = entry.data[channel]
                for index in 0..<samples.count {
                    let frame = startFrame + index
                    guard frame < totalFrames else { break }
                    // A later grain overwriting an earlier grain's tail here
                    // is exactly what a real interrupt does: it truncates
                    // whatever hadn't played yet.
                    output[channel][frame] = samples[index]
                }
            }
        }

        return RenderReport(
            channelData: output,
            sampleRate: sampleRate,
            gapCount: gapCount,
            totalGapDuration: totalGap,
            maxGapDuration: maxGap,
            overlapCount: overlapCount,
            totalOverlapDuration: totalOverlap,
            gapIntervals: gapIntervals
        )
    }

    /// Measures the PCM value-jump and slope-jump between every consecutive
    /// pair of scheduled grains (in scheduling order), classified by whether
    /// either side of the boundary used the software time-stretch path. Used
    /// to prove (not assume) whether the sub-0.25x `copyTimeStretched` path
    /// produces materially worse grain-boundary continuity than normal
    /// varispeed grains.
    private func measureBoundaryDiscontinuities(events: [GrainEvent]) -> [BoundaryDiscontinuity] {
        var results: [BoundaryDiscontinuity] = []
        for index in 1..<max(1, events.count) where index < events.count {
            let previous = events[index - 1]
            let next = events[index]
            var valueJumps: [Float] = []
            var slopeJumps: [Float] = []
            for channel in 0..<min(previous.channelData.count, next.channelData.count) {
                let prevChannel = previous.channelData[channel]
                let nextChannel = next.channelData[channel]
                guard prevChannel.count >= 2, nextChannel.count >= 2 else { continue }
                let prevLast = prevChannel[prevChannel.count - 1]
                let prevPrevious = prevChannel[prevChannel.count - 2]
                let nextFirst = nextChannel[0]
                let nextSecond = nextChannel[1]
                valueJumps.append(abs(nextFirst - prevLast))
                let prevSlope = prevLast - prevPrevious
                let nextSlope = nextSecond - nextFirst
                slopeJumps.append(abs(nextSlope - prevSlope))
            }
            guard !valueJumps.isEmpty else { continue }
            results.append(
                BoundaryDiscontinuity(
                    boundaryIndex: index,
                    valueJump: valueJumps.reduce(0, +) / Float(valueJumps.count),
                    slopeJump: slopeJumps.reduce(0, +) / Float(slopeJumps.count),
                    involvesSoftwareSlowGrain: previous.usesSoftwareSlowGrain || next.usesSoftwareSlowGrain
                )
            )
        }
        return results
    }

    /// Counts sign changes in the first difference of a channel's samples —
    /// a cheap proxy for how much real oscillation/high-frequency detail a
    /// grain's PCM actually contains. `copyTimeStretched` linearly
    /// interpolates a handful of raw source samples across a much larger
    /// output span; if that collapses a grain to a near-straight ramp, its
    /// sign-change rate falls far below a normal grain's, even though its
    /// edge-to-edge value/slope jump (measured separately) looks fine.
    private func signChangeRatePerSecond(_ channel: [Float], duration: TimeInterval) -> Double {
        guard channel.count >= 3, duration > 0 else { return 0 }
        var signChanges = 0
        var previousDelta = channel[1] - channel[0]
        for index in 2..<channel.count {
            let delta = channel[index] - channel[index - 1]
            if (delta > 0 && previousDelta < 0) || (delta < 0 && previousDelta > 0) {
                signChanges += 1
            }
            if delta != 0 { previousDelta = delta }
        }
        return Double(signChanges) / duration
    }

    private struct GrainRichnessSummary {
        let count: Int
        let meanSignChangeRate: Double
        let maxSignChangeRate: Double
    }

    private func summarizeRichness(_ events: [GrainEvent]) -> GrainRichnessSummary {
        guard !events.isEmpty else {
            return GrainRichnessSummary(count: 0, meanSignChangeRate: 0, maxSignChangeRate: 0)
        }
        let rates = events.map { event -> Double in
            guard let firstChannel = event.channelData.first else { return 0 }
            return signChangeRatePerSecond(firstChannel, duration: event.duration)
        }
        return GrainRichnessSummary(
            count: events.count,
            meanSignChangeRate: rates.reduce(0, +) / Double(rates.count),
            maxSignChangeRate: rates.max() ?? 0
        )
    }

    private struct BoundaryDiscontinuitySummary {
        let count: Int
        let meanValueJump: Float
        let maxValueJump: Float
        let meanSlopeJump: Float
        let maxSlopeJump: Float
    }

    private func summarize(_ discontinuities: [BoundaryDiscontinuity]) -> BoundaryDiscontinuitySummary {
        guard !discontinuities.isEmpty else {
            return BoundaryDiscontinuitySummary(count: 0, meanValueJump: 0, maxValueJump: 0, meanSlopeJump: 0, maxSlopeJump: 0)
        }
        let valueJumps = discontinuities.map(\.valueJump)
        let slopeJumps = discontinuities.map(\.slopeJump)
        return BoundaryDiscontinuitySummary(
            count: discontinuities.count,
            meanValueJump: valueJumps.reduce(0, +) / Float(valueJumps.count),
            maxValueJump: valueJumps.max() ?? 0,
            meanSlopeJump: slopeJumps.reduce(0, +) / Float(slopeJumps.count),
            maxSlopeJump: slopeJumps.max() ?? 0
        )
    }

    /// A gap is "explained" if every control tick whose scheduling-clock time
    /// falls inside it either had no drive from the bridge (a fail-closed
    /// decision — the correct behavior near a genuine zero-crossing/decode
    /// reacquisition) or had a drive that the playback controller itself
    /// legitimately chose not to turn into a grain (e.g. `nearStop`,
    /// `tinyGrain`, `noMotion`, `priming`, `noDirection`). A tick with a
    /// `.driving` decision and no skip reason means a grain WAS scheduled
    /// successfully at that moment — if that tick's time falls inside a
    /// reported gap, the gap is not decode-driven and needs investigating.
    private func unexplainedGapDuration(
        gapIntervals: [(start: TimeInterval, duration: TimeInterval)],
        ticks: [TickRecord]
    ) -> TimeInterval {
        let legitimateSkipReasons: Set<String> = [
            "nearStop", "tinyGrain", "noMotion", "priming", "noDirection"
        ]
        var unexplained: TimeInterval = 0
        for interval in gapIntervals {
            let end = interval.start + interval.duration
            let ticksInGap = ticks.filter { $0.time >= interval.start && $0.time < end }
            let hasUnexplainedTick = ticksInGap.contains { tick in
                if tick.decision != .driving { return false }
                if let reason = tick.skippedReason, legitimateSkipReasons.contains(reason) {
                    return false
                }
                return true
            }
            if hasUnexplainedTick {
                unexplained += interval.duration
            }
        }
        return unexplained
    }

    private struct GapEdgeClickSummary {
        let count: Int
        let meanEdgeAmplitude: Float
        let maxEdgeAmplitude: Float
    }

    /// A gap is rendered as hard silence with no fade. If the real audio
    /// immediately bordering a gap isn't already near zero, that hard cut
    /// itself is an audible click — independent of anything happening
    /// inside `copyTimeStretched`. Measures `abs()` of the last real sample
    /// before each gap and the first real sample after it, on the final
    /// rendered (post-concatenation) channel data.
    private func gapEdgeClickAmplitudes(report: RenderReport) -> GapEdgeClickSummary {
        guard let firstChannel = report.channelData.first, !report.gapIntervals.isEmpty else {
            return GapEdgeClickSummary(count: 0, meanEdgeAmplitude: 0, maxEdgeAmplitude: 0)
        }
        var amplitudes: [Float] = []
        for interval in report.gapIntervals {
            let startFrame = Int((interval.start * report.sampleRate).rounded())
            let endFrame = Int(((interval.start + interval.duration) * report.sampleRate).rounded())
            if startFrame - 1 >= 0, startFrame - 1 < firstChannel.count {
                amplitudes.append(abs(firstChannel[startFrame - 1]))
            }
            if endFrame >= 0, endFrame < firstChannel.count {
                amplitudes.append(abs(firstChannel[endFrame]))
            }
        }
        guard !amplitudes.isEmpty else {
            return GapEdgeClickSummary(count: 0, meanEdgeAmplitude: 0, maxEdgeAmplitude: 0)
        }
        return GapEdgeClickSummary(
            count: amplitudes.count,
            meanEdgeAmplitude: amplitudes.reduce(0, +) / Float(amplitudes.count),
            maxEdgeAmplitude: amplitudes.max() ?? 0
        )
    }

    private func writeWAV(_ report: RenderReport, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: report.sampleRate,
            channels: AVAudioChannelCount(report.channelData.count),
            interleaved: false
        ) else {
            throw NSError(domain: "DVSOfflineGrainRendererTests", code: 1)
        }
        let frameCount = report.channelData.first?.count ?? 0
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else {
            throw NSError(domain: "DVSOfflineGrainRendererTests", code: 2)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (channel, samples) in report.channelData.enumerated() {
            channels[channel].update(from: samples, count: samples.count)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    // MARK: - Replay harness

    /// Replays a full-length captured pair-3/4 WAV through the unmodified
    /// production decode → bridge → step-converter → playback-controller
    /// path (same call sequence `MacAnalyzerView`'s control loop uses),
    /// capturing every real scheduled grain via `scheduledGrainObserver`,
    /// then reconstructs and writes the resulting offline Ahhh render.
    private func renderCaptureToOfflineWAV(
        captureFolder: String,
        controlInterval: TimeInterval = 1.0 / 60.0
    ) throws -> (report: RenderReport, ticks: [TickRecord], boundaries: [BoundaryDiscontinuity], events: [GrainEvent]) {
        let sourceURL = localHardwareArchiveDirectory
            .appendingPathComponent(captureFolder, isDirectory: true)
            .appendingPathComponent("pair_3_4_float32.wav")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip(
                "Full hardware capture '\(captureFolder)' is local-only and not present on this machine."
            )
        }

        let file = try AVAudioFile(forReading: sourceURL)
        let inputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: inputBuffer)
        let inputChannels = try XCTUnwrap(inputBuffer.floatChannelData)
        XCTAssertEqual(inputBuffer.format.channelCount, 2)

        let pipeline = TimecodeControlPipeline(
            sampleRate: file.processingFormat.sampleRate,
            channelCount: 2
        )
        let profile = TimecodePrototypeProfile.raneOneMkiiDebug()
        profile.apply(to: pipeline)
        pipeline.mode = .controlPrototype
        pipeline.liveTapEnabled = true

        let bridge = TimecodePlaybackBridge(
            playbackDriveEnabled: true,
            validationRequired: profile.validationRequired,
            maxPlaybackRate: profile.maxRate,
            minConfidence: profile.minConfidence
        )
        let clock = SchedulingClock()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        // Offline grain reconstruction is a diagnostic of the legacy
        // scheduled-grain DVS path — pin it (production DVS now uses the
        // continuous renderer; see dvsUsesContinuousRenderer).
        controller.dvsUsesContinuousRenderer = false
        guard controller.ensureLoadedForDVSDrive(sampleID: "dvs_ahhh") else {
            throw XCTSkip("The app test host does not contain VirtualPlatter/ahhh.wav")
        }
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.loadedSampleID, "dvs_ahhh")

        var events: [GrainEvent] = []
        controller.scheduledGrainObserver = { snapshot in
            events.append(
                GrainEvent(
                    scheduledAt: clock.now,
                    interrupts: snapshot.interrupts,
                    duration: snapshot.scheduledOutputWindow,
                    sampleRate: snapshot.sampleRate,
                    channelData: snapshot.channelData,
                    usesSoftwareSlowGrain: snapshot.usesSoftwareSlowGrain,
                    rawSourceFrameCount: snapshot.rawSourceFrameCount
                )
            )
        }

        let callbackFrames = 512
        var nextControlFrame = file.processingFormat.sampleRate * controlInterval
        var converter = TimecodeDriveStepConverter()
        var offset = 0
        var ticks: [TickRecord] = []

        func flushControlTick() {
            pipeline.flushDecode()
            let drive = bridge.evaluate(pipeline: pipeline)
            clock.now += controlInterval
            if let drive {
                let converted = converter.steps(
                    forRate: drive.rate,
                    direction: drive.direction,
                    elapsed: controlInterval
                )
                controller.positionDidChange(
                    steps: converted.steps,
                    direction: converted.direction,
                    segmentWindow: controlInterval
                )
                let skippedReason = controller.diagnosticsSnapshot().lastScheduleSkippedReason
                ticks.append(
                    TickRecord(time: clock.now, decision: bridge.lastDecision, skippedReason: skippedReason)
                )
            } else {
                ticks.append(
                    TickRecord(time: clock.now, decision: bridge.lastDecision, skippedReason: nil)
                )
            }
        }

        while offset < Int(inputBuffer.frameLength) {
            let count = min(callbackFrames, Int(inputBuffer.frameLength) - offset)
            let left = Array(UnsafeBufferPointer(start: inputChannels[0].advanced(by: offset), count: count))
            let right = Array(UnsafeBufferPointer(start: inputChannels[1].advanced(by: offset), count: count))
            pipeline.pushStereoBuffer(
                left: left,
                right: right,
                sampleRate: file.processingFormat.sampleRate,
                frameCount: count
            )
            offset += count
            if Double(offset) >= nextControlFrame {
                flushControlTick()
                nextControlFrame += file.processingFormat.sampleRate * controlInterval
            }
        }
        flushControlTick()
        controller.waitForAudioQueue()
        controller.scheduledGrainObserver = nil

        guard !events.isEmpty else {
            throw XCTSkip("No grains were scheduled for '\(captureFolder)' — motion never passed the confidence gate.")
        }

        let report = render(events: events)
        let outputURL = offlineRenderOutputDirectory
            .appendingPathComponent("\(captureFolder)_offline_render.wav")
        try writeWAV(report, to: outputURL)

        let unexplained = unexplainedGapDuration(gapIntervals: report.gapIntervals, ticks: ticks)
        let boundaries = measureBoundaryDiscontinuities(events: events)
        let slowInvolved = summarize(boundaries.filter(\.involvesSoftwareSlowGrain))
        let normalOnly = summarize(boundaries.filter { !$0.involvesSoftwareSlowGrain })
        let softwareSlowGrainCount = events.filter(\.usesSoftwareSlowGrain).count
        print(
            "[DVSOfflineGrainRenderer] \(captureFolder): grains=\(events.count) " +
            "gaps=\(report.gapCount) totalGap=\(String(format: "%.4f", report.totalGapDuration))s " +
            "maxGap=\(String(format: "%.4f", report.maxGapDuration))s " +
            "unexplainedGap=\(String(format: "%.4f", unexplained))s " +
            "overlaps=\(report.overlapCount) totalOverlap=\(String(format: "%.4f", report.totalOverlapDuration))s " +
            "wrote=\(outputURL.path)"
        )
        print(
            "[DVSOfflineGrainRenderer] \(captureFolder) boundaries: " +
            "softwareSlowGrains=\(softwareSlowGrainCount)/\(events.count) " +
            "slowInvolved(n=\(slowInvolved.count) meanValueJump=\(String(format: "%.5f", slowInvolved.meanValueJump)) " +
            "maxValueJump=\(String(format: "%.5f", slowInvolved.maxValueJump)) " +
            "meanSlopeJump=\(String(format: "%.5f", slowInvolved.meanSlopeJump)) " +
            "maxSlopeJump=\(String(format: "%.5f", slowInvolved.maxSlopeJump))) " +
            "normalOnly(n=\(normalOnly.count) meanValueJump=\(String(format: "%.5f", normalOnly.meanValueJump)) " +
            "maxValueJump=\(String(format: "%.5f", normalOnly.maxValueJump)) " +
            "meanSlopeJump=\(String(format: "%.5f", normalOnly.meanSlopeJump)) " +
            "maxSlopeJump=\(String(format: "%.5f", normalOnly.maxSlopeJump)))"
        )
        let slowRichness = summarizeRichness(events.filter(\.usesSoftwareSlowGrain))
        let normalRichness = summarizeRichness(events.filter { !$0.usesSoftwareSlowGrain })
        print(
            "[DVSOfflineGrainRenderer] \(captureFolder) richness (sign-changes/sec, proxy for real waveform detail): " +
            "softwareSlow(n=\(slowRichness.count) mean=\(String(format: "%.1f", slowRichness.meanSignChangeRate)) " +
            "max=\(String(format: "%.1f", slowRichness.maxSignChangeRate))) " +
            "normal(n=\(normalRichness.count) mean=\(String(format: "%.1f", normalRichness.meanSignChangeRate)) " +
            "max=\(String(format: "%.1f", normalRichness.maxSignChangeRate)))"
        )
        let gapEdges = gapEdgeClickAmplitudes(report: report)
        print(
            "[DVSOfflineGrainRenderer] \(captureFolder) gap-edge click amplitude (post gap-aware edge fade): " +
            "n=\(gapEdges.count) mean=\(String(format: "%.5f", gapEdges.meanEdgeAmplitude)) " +
            "max=\(String(format: "%.5f", gapEdges.maxEdgeAmplitude))"
        )

        return (report, ticks, boundaries, events)
    }

    // MARK: - Tests

    func testOfflineRenderReconstructsSteadyNormalCapture() throws {
        let (report, _, _, _) = try renderCaptureToOfflineWAV(
            captureFolder: "20260731_031405_steady_normal_2467C04C"
        )
        XCTAssertGreaterThan(report.channelData.first?.count ?? 0, 0)
        XCTAssertEqual(report.sampleRate, 44_100)
        XCTAssertEqual(report.overlapCount, 0)
    }

    func testOfflineRenderReconstructsSlowReversalsCapture() throws {
        let (report, ticks, boundaries, events) = try renderCaptureToOfflineWAV(
            captureFolder: "20260731_035857_slow_reversals_9C60FC34"
        )
        XCTAssertGreaterThan(report.channelData.first?.count ?? 0, 0)
        XCTAssertEqual(
            report.overlapCount,
            0,
            "DVS reversals must not discard the bounded queued tail"
        )
        let unexplained = unexplainedGapDuration(gapIntervals: report.gapIntervals, ticks: ticks)
        XCTAssertEqual(
            unexplained,
            0,
            "Every gap must fall inside a non-driving bridge decision or a legitimate " +
            "controller skip reason (near-stop/no-motion/priming), not a silently dropped grain"
        )

        // Karl's listening check found `slow_reversals` static-like/clicking
        // while `steady_normal` and `fast_reversals` were clean. Neither
        // grain-boundary value/slope jumps nor gap-edge silence-cut
        // amplitudes distinguished slow_reversals from fast_reversals when
        // measured (both fixtures showed comparable numbers on both
        // metrics) — the one metric that was *always* systematically worse
        // for software-time-stretched grains than normal ones, in every
        // fixture, was oscillation/high-frequency content ("richness"): a
        // proxy for how much of the real waveform's detail
        // `copyTimeStretched` actually preserves. slow_reversals spends
        // ~38% of all its grains on that path (vs ~6% for fast_reversals),
        // so that quality gap dominates its audible character even though
        // no single grain looks catastrophically bad in isolation. Cubic
        // (Catmull-Rom) interpolation in `copyTimeStretched` measurably
        // raised software-slow-grain richness from a pre-fix baseline of
        // 601.0/sec to 648.5/sec on this exact fixture; this pins that
        // improvement so a regression back to plain linear interpolation
        // is caught by test, not by ear.
        let slowInvolved = summarize(boundaries.filter(\.involvesSoftwareSlowGrain))
        XCTAssertGreaterThan(
            slowInvolved.count,
            0,
            "slow_reversals is expected to exercise the software time-stretch path at all"
        )
        let slowRichness = summarizeRichness(events.filter(\.usesSoftwareSlowGrain))
        XCTAssertGreaterThan(
            slowRichness.meanSignChangeRate,
            620,
            "Software time-stretched grains must retain more real waveform detail than plain " +
            "linear interpolation between two raw samples produces (measured baseline: 601/sec)"
        )
    }

    func testOfflineRenderReconstructsFastReversalsCapture() throws {
        let (report, ticks, _, _) = try renderCaptureToOfflineWAV(
            captureFolder: "20260731_040231_fast_reversals_83DA737D"
        )
        XCTAssertGreaterThan(report.channelData.first?.count ?? 0, 0)
        XCTAssertEqual(
            report.overlapCount,
            0,
            "DVS reversals must not discard the bounded queued tail"
        )
        let unexplained = unexplainedGapDuration(gapIntervals: report.gapIntervals, ticks: ticks)
        XCTAssertEqual(
            unexplained,
            0,
            "Every gap must fall inside a non-driving bridge decision or a legitimate " +
            "controller skip reason (near-stop/no-motion/priming), not a silently dropped grain"
        )
    }

    // MARK: - Task 14: gap-aware edge fade (hard-cut click suppression)

    /// A constant-amplitude synthetic grain (both channels), so a hard cut to
    /// silence without the fade would sit at the full amplitude.
    private func constantGrain(amplitude: Float, frames: Int) -> [[Float]] {
        [[Float](repeating: amplitude, count: frames),
         [Float](repeating: amplitude, count: frames)]
    }

    private func makeGrain(
        scheduledAt: TimeInterval,
        amplitude: Float,
        frames: Int,
        sampleRate: Double
    ) -> GrainEvent {
        GrainEvent(
            scheduledAt: scheduledAt,
            interrupts: false,
            duration: Double(frames) / sampleRate,
            sampleRate: sampleRate,
            channelData: constantGrain(amplitude: amplitude, frames: frames),
            usesSoftwareSlowGrain: false,
            rawSourceFrameCount: frames
        )
    }

    func testGapEdgeFadeSuppressesHardCutClick() {
        // Two full-amplitude grains separated by a 0.1 s gap. Without the fade
        // the reconstructed timeline hard-cuts 1.0 -> 0.0 at both sides of the
        // gap (the measured exit-pack defect: gap-edge amplitude up to 0.74).
        let sampleRate = 16_000.0
        let frames = 400 // 25 ms at 16 kHz
        let grainDuration = Double(frames) / sampleRate
        let events = [
            makeGrain(scheduledAt: 0, amplitude: 1.0, frames: frames, sampleRate: sampleRate),
            makeGrain(scheduledAt: 0.2, amplitude: 1.0, frames: frames, sampleRate: sampleRate),
        ]

        // Pre-fix A/B reference: fade disabled -> the cut samples sit at full amplitude.
        let withoutFade = render(events: events, grainEdgeFadeFrames: 0)
        let before = gapEdgeClickAmplitudes(report: withoutFade)
        XCTAssertEqual(before.maxEdgeAmplitude, 1.0, accuracy: 1e-6,
                       "without the fade, a constant-amplitude cut is a full-amplitude click proxy")

        // Post-fix: fade enabled -> both cut samples are exactly 0 (ramp ends at 0).
        let withFade = render(events: events, grainEdgeFadeFrames: 32)
        let after = gapEdgeClickAmplitudes(report: withFade)
        XCTAssertEqual(after.maxEdgeAmplitude, 0, accuracy: 1e-6,
                       "the gap-aware fade must bring every hard-cut sample to zero")
        // Gap accounting is unchanged by the fade (scheduling, not amplitude, is untouched).
        XCTAssertEqual(withFade.gapCount, withoutFade.gapCount)
        XCTAssertEqual(withFade.overlapCount, 0)
        // The grains themselves are intact: interior samples remain at full amplitude.
        XCTAssertEqual(withFade.channelData[0][frames / 2], 1.0, accuracy: 1e-6)
    }

    func testGapEdgeFadeDoesNotAlterContiguousJunctions() {
        // Two grains with NO gap (second starts exactly when the first ends):
        // the fade must not touch contiguous junctions (the committed live-path
        // guard against scheduler-rate amplitude modulation is preserved offline).
        let sampleRate = 16_000.0
        let frames = 400
        let grainDuration = Double(frames) / sampleRate
        let events = [
            makeGrain(scheduledAt: 0, amplitude: 1.0, frames: frames, sampleRate: sampleRate),
            makeGrain(scheduledAt: grainDuration, amplitude: 1.0, frames: frames, sampleRate: sampleRate),
        ]
        let withoutFade = render(events: events, grainEdgeFadeFrames: 0)
        let withFade = render(events: events, grainEdgeFadeFrames: 32)
        XCTAssertEqual(withFade.gapCount, 0)
        XCTAssertEqual(
            withFade.channelData,
            withoutFade.channelData,
            "no gap means no fade: contiguous output must be byte-identical with and without the fade"
        )
    }

    func testGapEdgeFadeClampsToHalfGrain() {
        // A 40-frame grain with fadeFrames=64 must clamp to 20 (half the grain)
        // and never fully zero the grain; the tail ramp is symmetric with the
        // head ramp and both end exactly at 0.
        let frames = 40
        var channel = [Float](repeating: 1.0, count: frames)
        ScratchSamplePlaybackController.fadeOutTail(&channel, fadeFrames: 64)
        XCTAssertEqual(channel[0], 1.0, accuracy: 1e-6, "head untouched by fadeOutTail")
        XCTAssertEqual(channel[19], 1.0, accuracy: 1e-6, "first 20 samples untouched (clamp = 20)")
        XCTAssertEqual(channel[20], Float(19) / Float(20), accuracy: 1e-6, "tail ramp starts at (f-1)/f")
        XCTAssertEqual(channel[39], 0.0, accuracy: 1e-6, "last sample ramps exactly to 0")
        XCTAssertTrue(channel.contains { $0 > 0.5 }, "grain is never fully zeroed")

        var head = [Float](repeating: 1.0, count: frames)
        ScratchSamplePlaybackController.fadeInHead(&head, fadeFrames: 64)
        XCTAssertEqual(head[0], 0.0, accuracy: 1e-6, "first sample ramps exactly from 0")
        XCTAssertEqual(head[19], Float(19) / Float(20), accuracy: 1e-6)
        XCTAssertEqual(head[39], 1.0, accuracy: 1e-6, "tail untouched by fadeInHead")
    }
}

#endif
