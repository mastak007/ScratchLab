import Foundation

enum SessionReviewValidator {

    static let clippedPeakThreshold: Double = 0.98
    static let lowAmplitudeMedianThreshold: Double = 0.10
    static let unstableOnsetSpacingRatio: Double = 0.6
    static let missingPhraseRegionMinDuration: Double = 1.0
    static let inconsistentDirectionFlipsPerSecond: Double = 6.0
    static let minimumOnsetEventsForSpacingCheck: Int = 4
    static let minimumMovementEventsForDirectionCheck: Int = 12

    static func warnings(
        for snapshot: CaptureCore.DetectedNotationSnapshot,
        takeDuration: Double,
        now: Date = Date()
    ) -> [CaptureCore.SessionReviewWarning] {
        var output: [CaptureCore.SessionReviewWarning] = []

        if let clipping = clippedAudioWarning(snapshot: snapshot, now: now) {
            output.append(clipping)
        }
        if let lowAmp = lowAmplitudeWarning(snapshot: snapshot, now: now) {
            output.append(lowAmp)
        }
        if let onset = unstableOnsetWarning(snapshot: snapshot, now: now) {
            output.append(onset)
        }
        if let phrase = missingPhraseWarning(
            snapshot: snapshot,
            takeDuration: takeDuration,
            now: now
        ) {
            output.append(phrase)
        }
        if let direction = inconsistentDirectionWarning(
            snapshot: snapshot,
            takeDuration: takeDuration,
            now: now
        ) {
            output.append(direction)
        }

        return output
    }

    private static func clippedAudioWarning(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        now: Date
    ) -> CaptureCore.SessionReviewWarning? {
        let clipped = snapshot.audioEvents.filter { $0.peakLevel >= clippedPeakThreshold }
        guard !clipped.isEmpty else { return nil }
        let peak = clipped.map(\.peakLevel).max() ?? 0
        return CaptureCore.SessionReviewWarning(
            kind: .clippedAudio,
            detail: "\(clipped.count) audio event(s) at or above clip threshold (peak \(String(format: "%.2f", peak))).",
            raisedAt: now
        )
    }

    private static func lowAmplitudeWarning(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        now: Date
    ) -> CaptureCore.SessionReviewWarning? {
        let peaks = snapshot.audioEvents.map(\.peakLevel)
        guard !peaks.isEmpty else { return nil }
        let median = SessionReviewValidator.median(peaks)
        guard median < lowAmplitudeMedianThreshold else { return nil }
        return CaptureCore.SessionReviewWarning(
            kind: .lowAmplitude,
            detail: "Median peak level \(String(format: "%.2f", median)) below \(String(format: "%.2f", lowAmplitudeMedianThreshold)).",
            raisedAt: now
        )
    }

    private static func unstableOnsetWarning(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        now: Date
    ) -> CaptureCore.SessionReviewWarning? {
        let times = snapshot.audioEvents.map(\.startTime).sorted()
        guard times.count >= minimumOnsetEventsForSpacingCheck else { return nil }
        var gaps: [Double] = []
        for index in 1..<times.count {
            gaps.append(times[index] - times[index - 1])
        }
        guard !gaps.isEmpty else { return nil }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean > 0 else { return nil }
        let variance = gaps.reduce(0.0) { partial, gap in
            partial + (gap - mean) * (gap - mean)
        } / Double(gaps.count)
        let stdev = variance.squareRoot()
        guard stdev > unstableOnsetSpacingRatio * mean else { return nil }
        return CaptureCore.SessionReviewWarning(
            kind: .unstableOnsetSpacing,
            detail: "Inter-onset stdev \(String(format: "%.3f", stdev))s exceeds \(String(format: "%.1f", unstableOnsetSpacingRatio))× mean gap \(String(format: "%.3f", mean))s.",
            raisedAt: now
        )
    }

    private static func missingPhraseWarning(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        takeDuration: Double,
        now: Date
    ) -> CaptureCore.SessionReviewWarning? {
        guard snapshot.audioEvents.isEmpty,
              takeDuration > missingPhraseRegionMinDuration else { return nil }
        return CaptureCore.SessionReviewWarning(
            kind: .missingPhraseRegion,
            detail: "No audio onsets detected across \(String(format: "%.2f", takeDuration))s take.",
            raisedAt: now
        )
    }

    private static func inconsistentDirectionWarning(
        snapshot: CaptureCore.DetectedNotationSnapshot,
        takeDuration: Double,
        now: Date
    ) -> CaptureCore.SessionReviewWarning? {
        let movements = snapshot.recordMovementEvents.sorted { $0.startTime < $1.startTime }
        guard movements.count >= minimumMovementEventsForDirectionCheck,
              takeDuration > 0 else { return nil }
        var flips = 0
        for index in 1..<movements.count where movements[index].direction != movements[index - 1].direction {
            flips += 1
        }
        let flipsPerSecond = Double(flips) / takeDuration
        guard flipsPerSecond > inconsistentDirectionFlipsPerSecond else { return nil }
        return CaptureCore.SessionReviewWarning(
            kind: .inconsistentDirection,
            detail: "\(flips) direction flip(s) over \(String(format: "%.2f", takeDuration))s (\(String(format: "%.1f", flipsPerSecond)) Hz).",
            raisedAt: now
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }
}
