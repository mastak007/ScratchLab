// ScratchNotationIntentDebugFormatter — UI-free text readout for ScratchNotationIntent.
//
// Pure value formatting only. No app surface or runtime side effects. This intentionally does
// not use the Codable export DTOs; it is a small human-readable debug readout over the
// in-memory notation intent.

import Foundation

enum ScratchNotationIntentDebugFormatter {
    static func lines(for intent: ScratchNotationIntent) -> [String] {
        var output = [
            "Scratch notation intent",
            "strokes: \(intent.strokes.count)",
        ]

        output.append(contentsOf: intent.strokes.enumerated().map { index, stroke in
            "\(index + 1). \(directionString(stroke.direction)) · \(audibleString(stroke.audibleState)) · " +
                "travel \(format(stroke.travelPercent, places: 3))% · " +
                "\(format(stroke.startTime, places: 4))s → \(format(stroke.endTime, places: 4))s"
        })

        output.append("warnings: \(warningText(intent.warnings))")
        return output
    }

    static func text(for intent: ScratchNotationIntent) -> String {
        lines(for: intent).joined(separator: "\n")
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

    private static func warningText(_ warnings: [ScratchAnalysisWarning]) -> String {
        guard !warnings.isEmpty else { return "none" }
        return warnings.map(warningString).joined(separator: ", ")
    }

    private static func warningString(_ warning: ScratchAnalysisWarning) -> String {
        switch warning {
        case .emptyInput: return "emptyInput"
        case .invalidCalibration: return "invalidCalibration"
        case .nonUnitStep: return "nonUnitStep"
        }
    }

    private static func format(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
