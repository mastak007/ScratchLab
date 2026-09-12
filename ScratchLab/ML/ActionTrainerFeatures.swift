// Shared 67-column transform for legacy action-model training and offline
// advisory inference. Sentinel zeros, clamping and population statistics are
// compatibility behavior, not a claim that missing coordinates were observed.
import Foundation

public enum ActionTrainerFeatures {

    /// Per-frame numeric coordinate fields summarised across the window.
    /// 12 coordinates + 1 confidence = 13 fields × 4 stats = 52 columns.
    public static let perFrameNumericFields: [String] = [
        "dominantHandX", "dominantHandY",
        "dominantHandWristX", "dominantHandWristY",
        "dominantHandIndexTipX", "dominantHandIndexTipY",
        "dominantHandThumbTipX", "dominantHandThumbTipY",
        "dominantHandMiddleTipX", "dominantHandMiddleTipY",
        "secondaryHandWristX", "secondaryHandWristY",
        "dominantHandConfidence",
    ]

    public static let summaryStatistics: [String] = ["mean", "std", "min", "max"]

    /// Per-frame Boolean presence flags. We summarise these as a rate in
    /// `[0, 1]` (the fraction of frames where the landmark was detected).
    public static let perFramePresenceFields: [String] = [
        "dominantHandPresent",
        "dominantHandWristPresent",
        "dominantHandIndexTipPresent",
        "dominantHandThumbTipPresent",
        "dominantHandMiddleTipPresent",
        "secondaryHandWristPresent",
    ]

    /// Names of the nine `MotionWindowAggregates` columns, prefixed with
    /// `agg_` to disambiguate from the summary stats.
    public static let aggregateFields: [String] = [
        "agg_dominantWristPathLength",
        "agg_dominantHandPathLength",
        "agg_romX",
        "agg_romY",
        "agg_meanVelocity",
        "agg_maxVelocity",
        "agg_centerLineCrossings",
        "agg_dominantHandMissingRatio",
        "agg_dominantHandWristMissingRatio",
    ]

    /// Full ordered list of feature column names. Order matters for the
    /// training table and for inference at runtime.
    public static let columns: [String] = {
        var out: [String] = []
        out.append(contentsOf: aggregateFields)
        for field in perFrameNumericFields {
            for stat in summaryStatistics {
                out.append("\(field)_\(stat)")
            }
        }
        for flag in perFramePresenceFields {
            out.append("\(flag)_rate")
        }
        return out
    }()

    /// Project one window into its `[columnName: Double]` row.
    public static func projectToRow(_ window: MotionFeatureWindow) -> [String: Double] {
        projectToRow(frames: window.frames, aggregates: window.aggregates)
    }

    public static func projectToRow(
        frames: [MotionFrameFeatures],
        aggregates: MotionWindowAggregates
    ) -> [String: Double] {
        var row: [String: Double] = [:]

        // Aggregates
        let agg = aggregates
        row["agg_dominantWristPathLength"] = agg.dominantWristPathLength
        row["agg_dominantHandPathLength"] = agg.dominantHandPathLength
        row["agg_romX"] = agg.romX
        row["agg_romY"] = agg.romY
        row["agg_meanVelocity"] = agg.meanVelocity
        row["agg_maxVelocity"] = agg.maxVelocity
        row["agg_centerLineCrossings"] = Double(agg.centerLineCrossings)
        row["agg_dominantHandMissingRatio"] = agg.dominantHandMissingRatio
        row["agg_dominantHandWristMissingRatio"] = agg.dominantHandWristMissingRatio

        // Per-frame numeric summaries
        let n = max(1, frames.count)
        for field in perFrameNumericFields {
            let values = frames.map { extractNumeric($0, field: field) }
            let (mean, std, lo, hi) = summaryOf(values: values, fallback: 0)
            row["\(field)_mean"] = mean
            row["\(field)_std"] = std
            row["\(field)_min"] = lo
            row["\(field)_max"] = hi
        }
        // Per-frame presence rates
        for flag in perFramePresenceFields {
            let count = frames.filter { extractPresence($0, flag: flag) }.count
            row["\(flag)_rate"] = Double(count) / Double(n)
        }
        return row
    }

    private static func summaryOf(
        values: [Double],
        fallback: Double
    ) -> (mean: Double, std: Double, min: Double, max: Double) {
        guard !values.isEmpty else { return (fallback, fallback, fallback, fallback) }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let std = variance.squareRoot()
        return (mean, std, values.min() ?? fallback, values.max() ?? fallback)
    }

    private static func extractNumeric(
        _ frame: MotionFrameFeatures,
        field: String
    ) -> Double {
        switch field {
        case "dominantHandX": return frame.dominantHandX
        case "dominantHandY": return frame.dominantHandY
        case "dominantHandWristX": return frame.dominantHandWristX
        case "dominantHandWristY": return frame.dominantHandWristY
        case "dominantHandIndexTipX": return frame.dominantHandIndexTipX
        case "dominantHandIndexTipY": return frame.dominantHandIndexTipY
        case "dominantHandThumbTipX": return frame.dominantHandThumbTipX
        case "dominantHandThumbTipY": return frame.dominantHandThumbTipY
        case "dominantHandMiddleTipX": return frame.dominantHandMiddleTipX
        case "dominantHandMiddleTipY": return frame.dominantHandMiddleTipY
        case "secondaryHandWristX": return frame.secondaryHandWristX
        case "secondaryHandWristY": return frame.secondaryHandWristY
        case "dominantHandConfidence": return frame.dominantHandConfidence
        default: return 0
        }
    }

    private static func extractPresence(
        _ frame: MotionFrameFeatures,
        flag: String
    ) -> Bool {
        switch flag {
        case "dominantHandPresent": return frame.dominantHandPresent
        case "dominantHandWristPresent": return frame.dominantHandWristPresent
        case "dominantHandIndexTipPresent": return frame.dominantHandIndexTipPresent
        case "dominantHandThumbTipPresent": return frame.dominantHandThumbTipPresent
        case "dominantHandMiddleTipPresent": return frame.dominantHandMiddleTipPresent
        case "secondaryHandWristPresent": return frame.secondaryHandWristPresent
        default: return false
        }
    }
}
