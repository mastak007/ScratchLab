// ScratchAnalysis — thin Swift facade over the Objective-C++ scratch analysis bridge.
//
// Converts Swift value types to the bridge's NSObject values, calls the C++ core through
// SLSScratchAnalyzer, and converts the result back to Swift value types. No app
// integration, no UI, no MIDI/audio — pure value translation that mirrors the committed
// C++ core semantics exactly.

import Foundation

/// Platter rotation direction for one stroke (mirrors the C++ core).
enum ScratchStrokeDirection: Equatable {
    case forward
    case reverse
}

/// Whether a stroke was heard through the crossfader, cut, or has no telemetry to decide.
enum ScratchAudibleState: Equatable {
    case unknown
    case audible
    case cut
}

/// Non-fatal advisories surfaced by the core.
enum ScratchAnalysisWarning: Equatable {
    case emptyInput
    case invalidCalibration
    case nonUnitStep
}

/// A platter movement event. `cc6Step` is the signed CC6 ring step (normally ±1).
struct ScratchAnalysisPlatterEvent: Equatable {
    var timeSeconds: Double
    var cc6Step: Int

    init(timeSeconds: Double, cc6Step: Int) {
        self.timeSeconds = timeSeconds
        self.cc6Step = cc6Step
    }
}

/// A crossfader position sample, normalized 0...1.
struct ScratchAnalysisCrossfaderEvent: Equatable {
    var timeSeconds: Double
    var value: Double

    init(timeSeconds: Double, value: Double) {
        self.timeSeconds = timeSeconds
        self.value = value
    }
}

/// Calibration: CC6 steps per revolution (Double) and the crossfader open threshold.
struct ScratchAnalysisCalibration: Equatable {
    var stepsPerRevolution: Double
    var crossfaderCutWidth: Double

    init(stepsPerRevolution: Double, crossfaderCutWidth: Double) {
        self.stepsPerRevolution = stepsPerRevolution
        self.crossfaderCutWidth = crossfaderCutWidth
    }
}

/// One segmented stroke (mirrors the C++ core's Stroke).
struct ScratchAnalyzedStroke: Equatable {
    var direction: ScratchStrokeDirection
    var startTime: Double
    var endTime: Double
    var travelPercent: Double
    var audibleState: ScratchAudibleState
}

/// Analysis output: ordered strokes plus de-duplicated warnings.
struct ScratchAnalysisOutput: Equatable {
    var strokes: [ScratchAnalyzedStroke]
    var warnings: [ScratchAnalysisWarning]
}

/// Swift entry point to the C++ scratch notation core via the Objective-C++ bridge.
enum ScratchAnalysis {
    static func analyze(
        platter: [ScratchAnalysisPlatterEvent],
        crossfader: [ScratchAnalysisCrossfaderEvent],
        calibration: ScratchAnalysisCalibration
    ) -> ScratchAnalysisOutput {
        let bridgePlatter = platter.map {
            SLSPlatterEvent(timeSeconds: $0.timeSeconds, cc6Step: $0.cc6Step)
        }
        let bridgeCrossfader = crossfader.map {
            SLSCrossfaderEvent(timeSeconds: $0.timeSeconds, value: $0.value)
        }
        let bridgeCalibration = SLSAnalysisCalibration(
            stepsPerRevolution: calibration.stepsPerRevolution,
            crossfaderCutWidth: calibration.crossfaderCutWidth
        )

        let result = SLSScratchAnalyzer.analyze(
            platter: bridgePlatter,
            crossfader: bridgeCrossfader,
            calibration: bridgeCalibration
        )

        let strokes = result.strokes.map { stroke in
            ScratchAnalyzedStroke(
                direction: mapDirection(stroke.direction),
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                travelPercent: stroke.travelPercent,
                audibleState: mapAudible(stroke.audibleState)
            )
        }
        let warnings = result.warnings.compactMap { mapWarning($0) }
        return ScratchAnalysisOutput(strokes: strokes, warnings: warnings)
    }

    private static func mapDirection(_ direction: SLSScratchStrokeDirection) -> ScratchStrokeDirection {
        switch direction {
        case .forward: return .forward
        case .reverse: return .reverse
        @unknown default: return .forward
        }
    }

    private static func mapAudible(_ state: SLSScratchAudibleState) -> ScratchAudibleState {
        switch state {
        case .unknown: return .unknown
        case .audible: return .audible
        case .cut: return .cut
        @unknown default: return .unknown
        }
    }

    private static func mapWarning(_ boxed: NSNumber) -> ScratchAnalysisWarning? {
        guard let warning = SLSScratchWarning(rawValue: boxed.intValue) else { return nil }
        switch warning {
        case .emptyInput: return .emptyInput
        case .invalidCalibration: return .invalidCalibration
        case .nonUnitStep: return .nonUnitStep
        @unknown default: return nil
        }
    }
}
