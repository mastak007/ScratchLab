// MIDIFaderCurveTests.swift
// ScratchLabDesktopTests
//
// Pure-model tests for the configurable fader-curve model
// (ScratchLab/Models/ControllerInput/Registry/MIDIFaderCurve.swift).
// No CoreMIDI, no MacCaptureEngine, no audio — these exercise the pure
// response-shape math, preset definitions, and custom-capture resolution
// in isolation.

import XCTest
@testable import ScratchLab

final class MIDIFaderCurveTests: XCTestCase {

    // MARK: - Response function: position defense (Correction 1)

    func testGainNonFinitePositionFailsToSilence() {
        let response = FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: .nan, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: .infinity, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: -.infinity, response: response), 0)
    }

    func testGainOutOfRangeFinitePositionClamps() {
        let response = FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: -5.0, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 5.0, response: response), 1.0)
    }

    // MARK: - Response function: malformed curve defense (Correction 1)

    func testGainIdenticalCurveEndpointsFailsToUnity() {
        let response = FaderCurveResponse(zeroAt: 0.3, oneAt: 0.3, shape: .linear)
        for p in [0.0, 0.1, 0.3, 0.5, 1.0] {
            XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: p, response: response), 1.0,
                "degenerate curve at p=\(p) must fail to unity, not silence")
        }
    }

    func testGainNonFiniteCurveEndpointsFailsToUnity() {
        let nanResponse = FaderCurveResponse(zeroAt: .nan, oneAt: 1, shape: .linear)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.5, response: nanResponse), 1.0)
        let infResponse = FaderCurveResponse(zeroAt: 0, oneAt: .infinity, shape: .linear)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.5, response: infResponse), 1.0)
    }

    // MARK: - Sharp Scratch == today's exact 5% cut-in

    func testSharpScratchMatchesLegacyFivePercentCutIn() {
        let response = FaderCurvePreset.sharpScratch.fixedResponse!
        XCTAssertEqual(response.zeroAt, 0)
        XCTAssertEqual(response.oneAt, 0.05, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.05, response: response), 1.0, accuracy: 0.0001)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.025, response: response), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.5, response: response), 1.0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 1.0, response: response), 1.0)
    }

    // MARK: - Smooth: genuinely nonlinear, monotonic, exact boundaries

    func testSmoothIsNonlinearMonotonicWithExactBoundaries() {
        let response = FaderCurvePreset.smooth.fixedResponse!
        XCTAssertEqual(response.shape, .smoothstep)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: response.zeroAt, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: response.oneAt, response: response), 1.0, accuracy: 1e-9)

        let samplePositions = stride(from: response.zeroAt, through: response.oneAt, by: (response.oneAt - response.zeroAt) / 20).map { $0 }
        let gains = samplePositions.map { FaderCurveResponse.gain(forNormalizedPosition: $0, response: response) }
        for i in 1..<gains.count {
            XCTAssertGreaterThanOrEqual(gains[i], gains[i - 1], "smoothstep must be monotonic non-decreasing")
        }
        // Genuinely nonlinear: the midpoint's gain must differ from what a
        // linear ramp over the same interval would produce (0.5).
        let midPosition = (response.zeroAt + response.oneAt) / 2
        let midGain = FaderCurveResponse.gain(forNormalizedPosition: midPosition, response: response)
        XCTAssertEqual(midGain, 0.5, accuracy: 1e-9, "smoothstep midpoint happens to equal 0.5 by symmetry")
        // But a quarter-way point must diverge from the linear 0.25.
        let quarterPosition = response.zeroAt + (response.oneAt - response.zeroAt) * 0.25
        let quarterGain = FaderCurveResponse.gain(forNormalizedPosition: quarterPosition, response: response)
        XCTAssertLessThan(quarterGain, 0.25, "smoothstep eases in — below the linear diagonal in the first quarter")
    }

    // MARK: - Blend / Linear: full-travel linear

    func testBlendCoversFullTravelLinearly() {
        let response = FaderCurvePreset.blend.fixedResponse!
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.5, response: response), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 1, response: response), 1.0)
    }

    func testLinearCoversFullTravelLinearly() {
        let response = FaderCurvePreset.linear.fixedResponse!
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.5, response: response), 0.5, accuracy: 0.0001)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 1, response: response), 1.0)
    }

    // MARK: - Sharp Cut: narrow upfader cut-in, exact unity beyond

    func testSharpCutReachesExactUnityBeyondNarrowRegion() {
        let response = FaderCurvePreset.sharpCut.fixedResponse!
        XCTAssertEqual(response.oneAt, 0.05, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0, response: response), 0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.05, response: response), 1.0, accuracy: 0.0001)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 0.06, response: response), 1.0)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: 1.0, response: response), 1.0)
    }

    // MARK: - availablePresets(for:)

    func testAvailablePresetsPerAction() {
        XCTAssertEqual(FaderCurvePreset.availablePresets(for: .crossfader), [.sharpScratch, .smooth, .blend, .custom])
        XCTAssertEqual(FaderCurvePreset.availablePresets(for: .leftUpfader), [.sharpCut, .linear, .custom])
        XCTAssertEqual(FaderCurvePreset.availablePresets(for: .rightUpfader), [.sharpCut, .linear, .custom])
        XCTAssertEqual(FaderCurvePreset.availablePresets(for: .hotCue1), [])
    }

    // MARK: - Preset/action compatibility is re-validated at resolve time,
    // not trusted from UI filtering alone (Correction 2).

    func testMismatchedPresetForActionFallsBackToDefault() {
        // .blend is crossfader-only; assign it to a right-upfader control.
        let control = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 20)
        let mismatched = MIDIFaderCurveConfig(preset: .blend, customCapture: nil)
        let resolved = mismatched.resolvedResponse(for: control)
        let expectedDefault = MIDIFaderCurveConfig.defaultConfig(for: .rightUpfader).resolvedResponse(for: control)
        XCTAssertEqual(resolved, expectedDefault)
    }

    /// Regression: `availablePresets(for:)` is EMPTY for hot-cue actions
    /// (they don't support curves at all). Resolving a config whose preset
    /// isn't allowed for the action used to fall through to
    /// `defaultConfig(for:).resolvedResponse(for:)`, which — for an action
    /// with an empty allowed-preset list — produces an equally
    /// not-allowed config and recurses forever (a real stack-overflow
    /// crash caught while exercising `applyLearnedMapping` for a learned
    /// hot cue, which pushes every learned control's resolved curve
    /// through this exact path). Must terminate and return a harmless
    /// value instead.
    func testResolvedResponseForHotCueActionDoesNotRecurse() {
        let hotCueControl = MIDILearnedControl(action: .hotCue1, messageType: .note, channel: 9, controlNumber: 60)
        XCTAssertTrue(FaderCurvePreset.availablePresets(for: .hotCue1).isEmpty, "sanity: hot cues have no curve presets")
        let response = MIDIFaderCurveConfig.defaultConfig(for: .hotCue1).resolvedResponse(for: hotCueControl)
        XCTAssertEqual(response, FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear))
        // Also exercise it through `resolvedCurveConfig`, the exact path
        // `MacCaptureEngine.pushResolvedCurve(for:)` used to call
        // unconditionally for every freshly-learned control.
        XCTAssertEqual(hotCueControl.resolvedCurveConfig.resolvedResponse(for: hotCueControl), FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear))
    }

    // MARK: - Custom capture: raw values, both directions

    func testCustomCaptureRawEndpointsForwardDirection() {
        let control = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 8, minValue: 0, maxValue: 127, inverted: false)
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: FaderCurveCapture(closedRawValue: 10, fullOnRawValue: 30))
        let response = config.resolvedResponse(for: control)
        XCTAssertEqual(response.zeroAt, control.normalizedValue(from: 10), accuracy: 1e-9)
        XCTAssertEqual(response.oneAt, control.normalizedValue(from: 30), accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 10), response: response), 0, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 30), response: response), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 60), response: response), 1.0,
            "beyond the captured full-on point, gain stays exactly 1")
    }

    func testCustomCaptureRawEndpointsReversedDirection() {
        // "full-on" captured at a LOWER raw value than "closed" — either
        // physical direction must work with no special-casing.
        let control = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 21, minValue: 0, maxValue: 127, inverted: false)
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: FaderCurveCapture(closedRawValue: 100, fullOnRawValue: 40))
        let response = config.resolvedResponse(for: control)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 100), response: response), 0, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 40), response: response), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: 10), response: response), 1.0,
            "beyond the captured full-on point in the reversed direction, gain still stays exactly 1")
    }

    func testCustomCaptureIdenticalRawEndpointsFailToUnity() {
        let control = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 8)
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: FaderCurveCapture(closedRawValue: 50, fullOnRawValue: 50))
        let response = config.resolvedResponse(for: control)
        for raw in [0, 25, 50, 75, 127] {
            XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: control.normalizedValue(from: raw), response: response), 1.0)
        }
    }

    func testCustomCaptureOutOfRangeRawValuesAreClamped() {
        let control = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 8)
        // Simulates a hand-edited/corrupt persisted file with out-of-MIDI-range raw values.
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: FaderCurveCapture(closedRawValue: -40, fullOnRawValue: 999))
        let response = config.resolvedResponse(for: control)
        XCTAssertEqual(response.zeroAt, control.normalizedValue(from: 0), accuracy: 1e-9)
        XCTAssertEqual(response.oneAt, control.normalizedValue(from: 127), accuracy: 1e-9)
    }

    // MARK: - Custom capture survives recalibration (Correction 1's core proof)

    func testCustomCapturePhysicalPointSurvivesRecalibration() {
        // Original calibration: full 0...127 range.
        let originalControl = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 8, minValue: 0, maxValue: 127, inverted: false)
        let capture = FaderCurveCapture(closedRawValue: 20, fullOnRawValue: 40)
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: capture)
        let originalResponse = config.resolvedResponse(for: originalControl)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: originalResponse.oneAt, response: originalResponse), 1.0, accuracy: 1e-9)

        // Recalibrated: min/max narrowed to 10...100 (same raw capture values, unchanged).
        let recalibratedControl = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 8, minValue: 10, maxValue: 100, inverted: false)
        let recalibratedResponse = config.resolvedResponse(for: recalibratedControl)

        // The raw value 40 (the physically captured full-on point) must
        // still resolve to gain 1 under the NEW calibration — proving the
        // curve tracked the physical position, not a stale normalized
        // endpoint from the old calibration.
        let physicalFullOnUnderNewCalibration = recalibratedControl.normalizedValue(from: 40)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: physicalFullOnUnderNewCalibration, response: recalibratedResponse), 1.0, accuracy: 1e-9)
        // And the resolved endpoints actually changed (recalibration was
        // not silently ignored).
        XCTAssertNotEqual(originalResponse.oneAt, recalibratedResponse.oneAt, accuracy: 1e-9)
    }

    // MARK: - Custom capture survives inversion

    func testCustomCapturePhysicalPointSurvivesInversion() {
        let uninvertedControl = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 21, minValue: 0, maxValue: 127, inverted: false)
        let capture = FaderCurveCapture(closedRawValue: 20, fullOnRawValue: 100)
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: capture)

        let invertedControl = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 21, minValue: 0, maxValue: 127, inverted: true)
        let invertedResponse = config.resolvedResponse(for: invertedControl)

        // Under inversion, the SAME physical raw=100 point (the captured
        // full-on) must still resolve to gain 1 — the endpoints flip
        // consistently with the control's own inversion.
        let physicalFullOnUnderInversion = invertedControl.normalizedValue(from: 100)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: physicalFullOnUnderInversion, response: invertedResponse), 1.0, accuracy: 1e-9)
        let physicalClosedUnderInversion = invertedControl.normalizedValue(from: 20)
        XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: physicalClosedUnderInversion, response: invertedResponse), 0, accuracy: 1e-9)
    }

    // MARK: - Codable round trip (raw Int persistence, Correction 1)

    func testFaderCurveCaptureEncodesRawInts() throws {
        let capture = FaderCurveCapture(closedRawValue: 12, fullOnRawValue: 88)
        let data = try JSONEncoder().encode(capture)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("12"))
        XCTAssertTrue(json.contains("88"))
        // Must NOT contain a fractional/normalized representation of these ints.
        XCTAssertFalse(json.contains("0.09"))

        let decoded = try JSONDecoder().decode(FaderCurveCapture.self, from: data)
        XCTAssertEqual(decoded, capture)
    }

    func testMIDIFaderCurveConfigCodableRoundTrip() throws {
        let config = MIDIFaderCurveConfig(preset: .custom, customCapture: FaderCurveCapture(closedRawValue: 5, fullOnRawValue: 90))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MIDIFaderCurveConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Migration: nil curveConfig == today's exact behavior

    func testDefaultConfigMatchesLegacyCrossfaderBehavior() {
        let control = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8)
        let response = MIDIFaderCurveConfig.defaultConfig(for: .crossfader).resolvedResponse(for: control)
        XCTAssertEqual(response.zeroAt, 0)
        XCTAssertEqual(response.oneAt, 0.05, accuracy: 1e-9)
        XCTAssertEqual(response.shape, .linear)
    }

    func testDefaultConfigMatchesLegacyUpfaderBehavior() {
        let control = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 21)
        let response = MIDIFaderCurveConfig.defaultConfig(for: .rightUpfader).resolvedResponse(for: control)
        XCTAssertEqual(response.zeroAt, 0)
        XCTAssertEqual(response.oneAt, 1.0)
        XCTAssertEqual(response.shape, .linear)
        // Byte-identical to a pure pass-through across the whole range.
        for raw in stride(from: 0, through: 127, by: 13) {
            let p = control.normalizedValue(from: raw)
            XCTAssertEqual(FaderCurveResponse.gain(forNormalizedPosition: p, response: response), p, accuracy: 1e-9)
        }
    }
}
