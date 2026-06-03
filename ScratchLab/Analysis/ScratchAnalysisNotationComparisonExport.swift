// ScratchAnalysisNotationComparisonExport — a deterministic, Codable debug/export artifact for
// `ScratchNotationComparisonReport`.
//
// This is a DTO + adapter, not a renderer and not a file writer. It exists so the comparison
// result (Slice 9) can be serialized to stable, human-readable JSON for inspection/diagnostics
// without making the comparison value types themselves Codable (which would force the shared
// analysis enums to adopt Codable). Mirrors the established `*_v1` string-schemaVersion DTO
// pattern used elsewhere in the analysis layer.
//
// Pure value transformation, deterministic, Foundation-only. No SwiftUI, no rendering, no
// `Date()` (the caller supplies `generatedAtEpochSeconds`, nil or fixed), no file I/O. No
// reference to ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import Foundation

/// A serializable snapshot of a `ScratchNotationComparisonReport`. All enum-valued fields are
/// flattened to stable strings so the schema is decoupled from the in-memory enums.
struct ScratchNotationComparisonExport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let sourceKind: SourceKind
    let sourceName: String?
    let generatedAtEpochSeconds: Double?
    let intentStrokeCount: Int
    let referenceStrokeCount: Int
    let directionMismatches: [Mismatch]
    let timingMismatches: [Mismatch]
    let audibleMismatches: [Mismatch]
    let countMismatches: [Mismatch]
    let unsupportedFields: [String]
    let warnings: [String]

    /// Where the compared intent came from. Caller-declared (the report itself does not know).
    enum SourceKind: String, Codable, Sendable {
        case syntheticFixture
        case realFixture
        case manual
    }

    struct Mismatch: Codable, Equatable, Sendable {
        let index: Int
        let kind: String
    }
}

/// Converts a `ScratchNotationComparisonReport` into its export DTO. Order-preserving and
/// deterministic; performs no I/O.
enum ScratchAnalysisNotationComparisonExportAdapter {
    static let schemaVersion = "scratch_notation_comparison_export_v1"

    static func export(
        report: ScratchNotationComparisonReport,
        sourceKind: ScratchNotationComparisonExport.SourceKind,
        sourceName: String?,
        generatedAtEpochSeconds: Double?
    ) -> ScratchNotationComparisonExport {
        ScratchNotationComparisonExport(
            schemaVersion: schemaVersion,
            sourceKind: sourceKind,
            sourceName: sourceName,
            generatedAtEpochSeconds: generatedAtEpochSeconds,
            intentStrokeCount: report.intentStrokeCount,
            referenceStrokeCount: report.referenceStrokeCount,
            directionMismatches: report.directionMismatches.map(mismatch),
            timingMismatches: report.timingMismatches.map(mismatch),
            audibleMismatches: report.audibleMismatches.map(mismatch),
            countMismatches: report.countMismatches.map(mismatch),
            unsupportedFields: report.unsupportedFields.map(unsupportedString),
            warnings: report.warnings.map(warningString)
        )
    }

    // MARK: - Stable string mappings (exhaustive: future enum cases force a compile error here)

    private static func mismatch(_ m: ScratchNotationStrokeMismatch) -> ScratchNotationComparisonExport.Mismatch {
        .init(index: m.index, kind: kindString(m.kind))
    }

    private static func kindString(_ kind: ScratchNotationStrokeMismatch.Kind) -> String {
        switch kind {
        case .direction: return "direction"
        case .timing: return "timing"
        case .audible: return "audible"
        case .count: return "count"
        }
    }

    private static func unsupportedString(_ field: ScratchNotationUnsupportedField) -> String {
        switch field {
        case .travelPercent: return "travelPercent"
        case .audibleStateUnknown: return "audibleStateUnknown"
        }
    }

    private static func warningString(_ warning: ScratchAnalysisWarning) -> String {
        switch warning {
        case .emptyInput: return "emptyInput"
        case .invalidCalibration: return "invalidCalibration"
        case .nonUnitStep: return "nonUnitStep"
        }
    }
}
