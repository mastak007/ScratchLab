// ScratchAnalysisNotationIntentExport — a deterministic, Codable, LOSSLESS export artifact for
// `ScratchNotationIntent` (the C++ notation truth itself).
//
// Companion to ScratchAnalysisNotationComparisonExport (which serializes a *comparison report*).
// This serializes the intent directly so the raw analysis output can be captured/inspected as
// stable JSON without any comparison or reference. Lossless: travelPercent is preserved
// (unclamped) and the `.unknown` audible state is represented as "unknown" — nothing is dropped
// or guessed.
//
// DTO + adapter, not a renderer and not a file writer. Pure value transformation, deterministic,
// Foundation-only. No SwiftUI, no rendering, no `Date()` (caller supplies
// `generatedAtEpochSeconds`, nil or fixed), no file I/O. No reference to ScratchPlaybackLabEngine
// / ScratchPlaybackLabModel.

import Foundation

/// A serializable, lossless snapshot of a `ScratchNotationIntent`. Enum-valued fields are
/// flattened to stable strings so the schema is decoupled from the in-memory enums.
struct ScratchNotationIntentExport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let sourceKind: SourceKind
    let sourceName: String?
    let generatedAtEpochSeconds: Double?
    let strokes: [Stroke]
    let warnings: [String]

    /// Where the intent came from. Caller-declared (the intent itself does not know).
    enum SourceKind: String, Codable, Sendable {
        case syntheticFixture
        case realFixture
        case manual
    }

    struct Stroke: Codable, Equatable, Sendable {
        let direction: String       // "forward" | "reverse"
        let startTime: Double
        let endTime: Double
        let travelPercent: Double    // preserved, UNCLAMPED
        let audibleState: String     // "audible" | "cut" | "unknown"
    }
}

/// Converts a `ScratchNotationIntent` into its lossless export DTO. Order-preserving and
/// deterministic; performs no I/O.
enum ScratchAnalysisNotationIntentExportAdapter {
    static let schemaVersion = "scratch_notation_intent_export_v1"

    static func export(
        intent: ScratchNotationIntent,
        sourceKind: ScratchNotationIntentExport.SourceKind,
        sourceName: String?,
        generatedAtEpochSeconds: Double?
    ) -> ScratchNotationIntentExport {
        ScratchNotationIntentExport(
            schemaVersion: schemaVersion,
            sourceKind: sourceKind,
            sourceName: sourceName,
            generatedAtEpochSeconds: generatedAtEpochSeconds,
            strokes: intent.strokes.map(stroke),
            warnings: intent.warnings.map(warningString)
        )
    }

    // MARK: - Stable string mappings (exhaustive: future enum cases force a compile error here)

    private static func stroke(_ s: ScratchNotationIntentStroke) -> ScratchNotationIntentExport.Stroke {
        .init(
            direction: directionString(s.direction),
            startTime: s.startTime,
            endTime: s.endTime,
            travelPercent: s.travelPercent,
            audibleState: audibleString(s.audibleState)
        )
    }

    private static func directionString(_ direction: ScratchStrokeDirection) -> String {
        switch direction {
        case .forward: return "forward"
        case .reverse: return "reverse"
        }
    }

    private static func audibleString(_ state: ScratchAudibleState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .audible: return "audible"
        case .cut: return "cut"
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
