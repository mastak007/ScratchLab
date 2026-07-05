import Foundation

/// DVS control-vinyl analysis facade.
///
/// Wraps `TimecodeControlPipeline` in diagnostics-only mode and exposes a
/// single `analyze(left:right:sampleRate:hostTime:)` entry point that returns
/// a `DVSTimecodeStatus` snapshot per buffer.
///
/// - Important: This is **not** a Serato product, licensed API, or timecode-
///   format replacement. It is an independent signal-analysis layer that reads
///   phono-level audio from control vinyl as an opaque motion-encoding signal.
///
/// - Thread safety: `analyze` must be called from a single serial queue (the
///   audio callback queue). The pipeline it wraps is not thread-safe.
public final class SeratoControlVinylAnalyzer {

    private let pipeline: TimecodeControlPipeline

    public init(sampleRate: Double = 44100, channelCount: Int = 2) {
        pipeline = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: channelCount)
        pipeline.mode = .diagnosticsOnly
    }

    /// Analyse one PCM buffer and return a `DVSTimecodeStatus` snapshot.
    ///
    /// - Parameters:
    ///   - left: Left-channel samples (Float32, normalised ±1).
    ///   - right: Right-channel samples (Float32, normalised ±1). Pass an
    ///     empty array for mono sources — the analyzer will pad with zeros.
    ///   - sampleRate: Sample rate of the buffers in Hz.
    ///   - hostTime: Optional host-clock timestamp for timing correlation.
    public func analyze(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        hostTime: UInt64? = nil
    ) -> DVSTimecodeStatus {
        guard !left.isEmpty else {
            return noSignalStatus(droppedReason: "emptyBuffer")
        }
        let rightPadded = right.isEmpty
            ? [Float](repeating: 0, count: left.count)
            : right
        pipeline.pushStereoBuffer(
            left: left,
            right: rightPadded,
            sampleRate: sampleRate,
            hostTime: hostTime,
            frameCount: left.count
        )
        _ = pipeline.flushDecode()
        return snapshot()
    }

    /// Reset accumulated pipeline state (e.g. between independent test cases).
    public func reset() {
        pipeline.reset()
    }

    // MARK: - Private

    private func snapshot() -> DVSTimecodeStatus {
        let diagnosis = pipeline.latestDiagnosis
        let health = pipeline.signalHealth

        let hasSignal: Bool
        switch health {
        case .noSignal, .weak:
            hasSignal = false
        default:
            hasSignal = true
        }

        let direction = mappedDirection(
            timecodeDirection: pipeline.currentDirection,
            rate: pipeline.currentRate
        )

        return DVSTimecodeStatus(
            hasSignal: hasSignal,
            rms: diagnosis?.leftRMS ?? 0,
            peak: diagnosis?.leftPeak ?? 0,
            estimatedFrequencyHz: diagnosis?.zcrFrequencyEstimateLeft,
            phaseDelta: pipeline.latestDecodeResult?.frames.last.map { Float($0.deltaPosition) },
            direction: direction,
            relativeRate: Float(abs(pipeline.currentRate)),
            confidence: Float(pipeline.latestDecodeResult?.averageConfidence ?? 0),
            droppedReason: pipeline.lastDropReason?.rawValue.nilIfEmpty
        )
    }

    private func mappedDirection(
        timecodeDirection: TimecodeDirection,
        rate: Double
    ) -> DVSTimecodeStatus.Direction {
        switch timecodeDirection {
        case .forward:  return .forward
        case .backward: return .backward
        case .unknown:  return abs(rate) < 0.05 ? .stopped : .unknown
        }
    }

    private func noSignalStatus(droppedReason: String) -> DVSTimecodeStatus {
        DVSTimecodeStatus(
            hasSignal: false, rms: 0, peak: 0,
            estimatedFrequencyHz: nil, phaseDelta: nil,
            direction: .unknown, relativeRate: 0,
            confidence: 0, droppedReason: droppedReason
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
