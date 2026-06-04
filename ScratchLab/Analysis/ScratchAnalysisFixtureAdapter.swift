// ScratchAnalysisFixtureAdapter — offline JSON proof for the scratch notation core.
//
// Decodes a versioned, synthetic `scratchlab_analysis_fixture_v1` JSON shape that mirrors
// the C++ core's input contract EXACTLY (signed CC6 step events + optional crossfader +
// calibration), maps it to the Slice-2 Swift wrapper value types, and runs
// `ScratchAnalysis.analyze(...)`. This proves the JSON -> Swift -> Obj-C++ -> C++ path
// deterministically, without any real RANE export, hardware, audio, or UI.
//
// Deliberately narrow (Slice 3):
// - Only `scratchlab_analysis_fixture_v1` is supported.
// - The fixture carries `cc6Step` directly; no raw-CC6 -> ring-delta derivation here.
// - Pitch bend and any other unknown JSON keys are ignored (not declared in the DTOs).
// - PlatterPositionTimeline and RANE diagnostic exports are intentionally NOT supported.

import Foundation

/// The decoded, wrapper-ready inputs from a fixture (before analysis).
struct ScratchAnalysisFixtureInput: Equatable {
    let calibration: ScratchAnalysisCalibration
    let platter: [ScratchAnalysisPlatterEvent]
    let crossfader: [ScratchAnalysisCrossfaderEvent]
}

/// Errors raised while decoding a fixture. Decode/validation only — the C++ core's own
/// advisories (emptyInput, invalidCalibration, nonUnitStep) are surfaced as warnings in
/// the analysis output, not duplicated here.
enum ScratchAnalysisFixtureError: Error, Equatable {
    /// `schemaVersion` was absent or not `scratchlab_analysis_fixture_v1`.
    case unsupportedSchema(String)
    /// The JSON could not be decoded into the expected shape.
    case decodeFailed(String)
}

enum ScratchAnalysisFixtureAdapter {
    /// The only schema version this slice understands.
    static let supportedSchemaVersion = "scratchlab_analysis_fixture_v1"

    /// Decode fixture JSON into wrapper-ready Swift values (no analysis yet).
    static func decodeFixtureInput(data: Data) throws -> ScratchAnalysisFixtureInput {
        let fixture: Fixture
        do {
            fixture = try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ScratchAnalysisFixtureError.decodeFailed(String(describing: error))
        }

        guard fixture.schemaVersion == supportedSchemaVersion else {
            throw ScratchAnalysisFixtureError.unsupportedSchema(fixture.schemaVersion)
        }

        let calibration = ScratchAnalysisCalibration(
            stepsPerRevolution: fixture.calibration.stepsPerRevolution,
            crossfaderCutWidth: fixture.calibration.crossfaderCutWidth
        )
        let platter = fixture.platterEvents.map {
            ScratchAnalysisPlatterEvent(timeSeconds: $0.timeSeconds, cc6Step: $0.cc6Step)
        }
        // Absent crossfaderEvents -> empty array, so the C++ core reports .unknown.
        let crossfader = (fixture.crossfaderEvents ?? []).map {
            ScratchAnalysisCrossfaderEvent(timeSeconds: $0.timeSeconds, value: $0.value)
        }
        return ScratchAnalysisFixtureInput(
            calibration: calibration, platter: platter, crossfader: crossfader)
    }

    /// Decode a fixture and run it through the Swift wrapper -> Obj-C++ bridge -> C++ core.
    static func analyzeFixture(data: Data) throws -> ScratchAnalysisOutput {
        let input = try decodeFixtureInput(data: data)
        return ScratchAnalysis.analyze(
            platter: input.platter,
            crossfader: input.crossfader,
            calibration: input.calibration
        )
    }

    // MARK: - Codable DTOs (decode-only; unknown keys such as pitch bend are ignored)

    private struct Fixture: Decodable {
        let schemaVersion: String
        let calibration: CalibrationDTO
        let platterEvents: [PlatterEventDTO]
        let crossfaderEvents: [CrossfaderEventDTO]?
    }

    private struct CalibrationDTO: Decodable {
        let stepsPerRevolution: Double
        let crossfaderCutWidth: Double
    }

    private struct PlatterEventDTO: Decodable {
        let timeSeconds: Double
        let cc6Step: Int
    }

    private struct CrossfaderEventDTO: Decodable {
        let timeSeconds: Double
        let value: Double
    }
}
