import Foundation

/// Structured, measured-only output of `SessionQualityAnalyzer`.
///
/// Every numeric field that depends on a sample population is `Double?`
/// and stays `nil` when the underlying data is insufficient to compute
/// it honestly. Threshold-derived booleans default to `false` only
/// when the inputs they would key off are absent — never `true` from
/// missing data.
///
/// Honesty notes:
///
/// - `audioEventRMSMedian` is the median of per-onset RMS values from
///   `DetectedNotationAudioEvent.rmsLevel`. It is **not** a true silent-
///   window noise floor; the existing capture pipeline does not record
///   inter-onset background RMS, so a literal "noise floor" cannot be
///   measured from data Slice 1 added. This field is exposed as a
///   coarse signal-level proxy only. No `noisyCapture` warning is
///   raised from it for the same reason.
/// - All thresholds are reused from `SessionReviewValidator` to keep
///   the analyzer and the warning generator aligned by construction.
struct SessionQualityReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_session_quality_v1"

    let schemaVersion: String
    let analyzedAt: Date
    let takeDurationSeconds: Double
    let audioEventCount: Int
    let recordMovementEventCount: Int

    // Measured numeric fields — `nil` whenever the population is empty
    // or the gating count threshold isn't met.
    let peakLevelMax: Double?
    let peakLevelMedian: Double?
    let audioEventRMSMedian: Double?
    let interOnsetGapMean: Double?
    let interOnsetGapStdev: Double?
    let directionFlipCount: Int
    let directionFlipsPerSecond: Double?

    // Threshold-derived booleans. Each is documented at its computation
    // site in `SessionQualityAnalyzer.analyze(...)`.
    let clippingDetected: Bool
    let lowSignalDetected: Bool
    let timingVarianceFlagged: Bool
    let incompletePhraseDetected: Bool
    let directionConflictDetected: Bool

    init(
        schemaVersion: String = SessionQualityReport.currentSchemaVersion,
        analyzedAt: Date,
        takeDurationSeconds: Double,
        audioEventCount: Int,
        recordMovementEventCount: Int,
        peakLevelMax: Double?,
        peakLevelMedian: Double?,
        audioEventRMSMedian: Double?,
        interOnsetGapMean: Double?,
        interOnsetGapStdev: Double?,
        directionFlipCount: Int,
        directionFlipsPerSecond: Double?,
        clippingDetected: Bool,
        lowSignalDetected: Bool,
        timingVarianceFlagged: Bool,
        incompletePhraseDetected: Bool,
        directionConflictDetected: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.analyzedAt = analyzedAt
        self.takeDurationSeconds = takeDurationSeconds
        self.audioEventCount = audioEventCount
        self.recordMovementEventCount = recordMovementEventCount
        self.peakLevelMax = peakLevelMax
        self.peakLevelMedian = peakLevelMedian
        self.audioEventRMSMedian = audioEventRMSMedian
        self.interOnsetGapMean = interOnsetGapMean
        self.interOnsetGapStdev = interOnsetGapStdev
        self.directionFlipCount = directionFlipCount
        self.directionFlipsPerSecond = directionFlipsPerSecond
        self.clippingDetected = clippingDetected
        self.lowSignalDetected = lowSignalDetected
        self.timingVarianceFlagged = timingVarianceFlagged
        self.incompletePhraseDetected = incompletePhraseDetected
        self.directionConflictDetected = directionConflictDetected
    }
}

/// Pure deterministic measurement of a captured take from existing
/// `DetectedNotationSnapshot` data. No side effects, no I/O, no UI
/// dependencies, no AVFoundation runtime calls.
enum SessionQualityAnalyzer {

    static func analyze(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        takeDuration: Double,
        now: Date = Date()
    ) -> SessionQualityReport {
        let peaks = snapshot.audioEvents.map(\.peakLevel)
        let rms = snapshot.audioEvents.map(\.rmsLevel)
        let onsetTimes = snapshot.audioEvents.map(\.startTime).sorted()
        let movements = snapshot.recordMovementEvents.sorted { $0.startTime < $1.startTime }

        let peakLevelMax: Double? = peaks.max()
        let peakLevelMedian: Double? = peaks.isEmpty ? nil : Self.median(peaks)
        let audioEventRMSMedian: Double? = rms.isEmpty ? nil : Self.median(rms)

        let (interOnsetGapMean, interOnsetGapStdev) = Self.onsetGapStatistics(times: onsetTimes)

        let directionFlipCount = Self.directionFlipCount(movements: movements)
        let directionFlipsPerSecond: Double? = {
            guard takeDuration > 0, !movements.isEmpty else { return nil }
            return Double(directionFlipCount) / takeDuration
        }()

        // `clippingDetected`: any captured onset hit or exceeded the
        // hardware-clipping peak threshold. Empty events → false
        // (no measurement made).
        let clippingDetected = (peakLevelMax ?? 0) >= SessionReviewValidator.clippedPeakThreshold

        // `lowSignalDetected`: median peak level across all captured
        // onsets is below the low-amplitude threshold. Requires at
        // least one onset to be honest.
        let lowSignalDetected: Bool = {
            guard let median = peakLevelMedian else { return false }
            return median < SessionReviewValidator.lowAmplitudeMedianThreshold
        }()

        // `timingVarianceFlagged`: stdev of inter-onset gaps exceeds
        // `unstableOnsetSpacingRatio × mean`. Requires the same
        // 4-onset minimum used by `SessionReviewValidator`.
        let timingVarianceFlagged: Bool = {
            guard let mean = interOnsetGapMean,
                  let stdev = interOnsetGapStdev,
                  mean > 0 else { return false }
            return stdev > SessionReviewValidator.unstableOnsetSpacingRatio * mean
        }()

        // `incompletePhraseDetected`: take ran longer than the minimum
        // and produced zero audio onsets. Matches the
        // `missingPhraseRegion` warning gate.
        let incompletePhraseDetected =
            snapshot.audioEvents.isEmpty
            && takeDuration > SessionReviewValidator.missingPhraseRegionMinDuration

        // `directionConflictDetected`: requires the same
        // 12-movement minimum as `SessionReviewValidator` and
        // flips-per-second above its threshold. Empty movements or
        // missing flips-per-second → false.
        let directionConflictDetected: Bool = {
            guard movements.count >= SessionReviewValidator.minimumMovementEventsForDirectionCheck,
                  let flipsPerSecond = directionFlipsPerSecond else { return false }
            return flipsPerSecond > SessionReviewValidator.inconsistentDirectionFlipsPerSecond
        }()

        return SessionQualityReport(
            analyzedAt: now,
            takeDurationSeconds: takeDuration,
            audioEventCount: snapshot.audioEvents.count,
            recordMovementEventCount: snapshot.recordMovementEvents.count,
            peakLevelMax: peakLevelMax,
            peakLevelMedian: peakLevelMedian,
            audioEventRMSMedian: audioEventRMSMedian,
            interOnsetGapMean: interOnsetGapMean,
            interOnsetGapStdev: interOnsetGapStdev,
            directionFlipCount: directionFlipCount,
            directionFlipsPerSecond: directionFlipsPerSecond,
            clippingDetected: clippingDetected,
            lowSignalDetected: lowSignalDetected,
            timingVarianceFlagged: timingVarianceFlagged,
            incompletePhraseDetected: incompletePhraseDetected,
            directionConflictDetected: directionConflictDetected
        )
    }

    // MARK: - Helpers

    private static func onsetGapStatistics(times: [Double]) -> (mean: Double?, stdev: Double?) {
        guard times.count >= SessionReviewValidator.minimumOnsetEventsForSpacingCheck else {
            return (nil, nil)
        }
        var gaps: [Double] = []
        gaps.reserveCapacity(times.count - 1)
        for index in 1..<times.count {
            gaps.append(times[index] - times[index - 1])
        }
        guard !gaps.isEmpty else { return (nil, nil) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let variance = gaps.reduce(0.0) { partial, gap in
            partial + (gap - mean) * (gap - mean)
        } / Double(gaps.count)
        return (mean, variance.squareRoot())
    }

    private static func directionFlipCount(
        movements: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> Int {
        guard movements.count >= 2 else { return 0 }
        var flips = 0
        for index in 1..<movements.count where movements[index].direction != movements[index - 1].direction {
            flips += 1
        }
        return flips
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }
}
