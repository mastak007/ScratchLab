import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — pure platter → sample-position mapping.
/// No AVFoundation, no Core MIDI, no UI. The playhead is driven by the RANE platter's
/// CC6 companion stream — a clean ±1 direction/step counter — NOT the aliasing 14-bit
/// pitch bend, which is retained only as a diagnostic readout.
final class ScratchPlatterPlayheadMapperTests: XCTestCase {

    // MARK: - Pitch-bend 14-bit decode (via the shared parser the lab consumes)

    func testPitchBendDecodesAs14Bit() {
        let parsed = MIDIMessageParsing.parse([0xE0, 0x32, 0x58])
        XCTAssertEqual(parsed.messageType, .pitchBend)
        XCTAssertEqual(parsed.value, 0x32 | (0x58 << 7)) // 11314
    }

    // MARK: - CC6 step (the primary signal): ±1 ring delta on a 128-step ring

    func testCC6StepForwardAndReverse() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.cc6Step(from: 50, to: 51), 1)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.cc6Step(from: 51, to: 50), -1)
    }

    func testCC6StepWrapsForwardAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.cc6Step(from: 127, to: 0), 1)
    }

    func testCC6StepWrapsReverseAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.cc6Step(from: 0, to: 127), -1)
    }

    // MARK: - CC6 drives the playhead (forward / reverse / wrap / seed / invert)

    func testCC6ForwardAdvancesPosition() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 1.0)
        XCTAssertEqual(m.ingestCC6(50), 0)                 // seed — no move
        XCTAssertEqual(m.samplePosition, 1.0, accuracy: 1e-12)
        XCTAssertEqual(m.ingestCC6(51), 1)                 // +1 step
        XCTAssertEqual(m.samplePosition, 1.1, accuracy: 1e-9)
    }

    func testCC6ReverseMovesBackward() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 5.0)
        m.ingestCC6(50)
        XCTAssertEqual(m.ingestCC6(49), -1)
        XCTAssertEqual(m.samplePosition, 4.9, accuracy: 1e-9)
    }

    func testCC6WrapForwardAdvances() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 2.0)
        m.ingestCC6(127)
        m.ingestCC6(0)                                     // 127 → 0 is +1
        XCTAssertEqual(m.samplePosition, 2.1, accuracy: 1e-9)
    }

    func testCC6WrapReverseRetreats() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 2.0)
        m.ingestCC6(0)
        m.ingestCC6(127)                                   // 0 → 127 is -1
        XCTAssertEqual(m.samplePosition, 1.9, accuracy: 1e-9)
    }

    func testCC6FirstEventSeedsOnly() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 3.0)
        XCTAssertEqual(m.ingestCC6(40), 0)
        XCTAssertEqual(m.samplePosition, 3.0, accuracy: 1e-12)
    }

    func testInvertFlipsCC6Direction() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100,
                                             inverted: true, samplePosition: 5.0)
        m.ingestCC6(50)
        m.ingestCC6(51)                                    // +1 geometric, inverted → -0.1
        XCTAssertEqual(m.samplePosition, 4.9, accuracy: 1e-9)
    }

    // MARK: - One revolution = 3932 CC6 steps → configured sample movement

    func testOneRevolutionOf3932StepsMovesConfiguredSpan() {
        let steps = ScratchPlatterPlayheadMapper.defaultStepsPerRevolution     // 3932
        let stepSize = 1.0 / Double(steps)                                     // 1 rev → 1.0 s
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: stepSize, sampleDuration: 10, samplePosition: 0)
        var v = 0
        m.ingestCC6(v)                                                          // seed
        for _ in 0..<steps { v = (v + 1) % 128; m.ingestCC6(v) }               // 3932 forward steps
        XCTAssertEqual(m.samplePosition, 1.0, accuracy: 1e-6)
    }

    // MARK: - Reset clears the CC6 seed

    func testResetTrackingClearsCC6Seed() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 2.0)
        m.ingestCC6(50)
        m.ingestCC6(51)                                    // → 2.1
        m.resetTracking()
        XCTAssertNil(m.lastCC6Value)
        XCTAssertEqual(m.ingestCC6(80), 0, "first event after reset re-seeds, no move")
        XCTAssertEqual(m.samplePosition, 2.1, accuracy: 1e-9)
    }

    // MARK: - Pitch bend is DIAGNOSTIC ONLY — it does not move the playhead

    func testPitchBendTrackingDoesNotMovePlayhead() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100, samplePosition: 4.0)
        m.trackPitchBend(2000)                             // seed
        XCTAssertEqual(m.trackPitchBend(5000), 3000)       // wrapped delta reported…
        XCTAssertEqual(m.lastWrappedDelta, 3000)
        XCTAssertEqual(m.samplePosition, 4.0, accuracy: 1e-12, "…but the playhead must NOT move")
    }

    func testMaxObservedDeltaTracksLargestPitchBendDelta() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100)
        m.trackPitchBend(5000)                             // seed
        m.trackPitchBend(5500)                             // +500
        m.trackPitchBend(2500)                             // -3000
        XCTAssertEqual(m.maxObservedDelta, 3000)
        m.resetMaxObservedDelta()
        XCTAssertEqual(m.maxObservedDelta, 0)
    }

    func testDeltaSafetyLimitIsDiagnosticFlagOnly() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 100,
                                             deltaSafetyLimit: 1000, samplePosition: 4.0)
        m.trackPitchBend(0)
        m.trackPitchBend(8000)                             // +8000 > 1000 → flagged, no move
        XCTAssertTrue(m.lastDeltaClamped)
        XCTAssertEqual(m.samplePosition, 4.0, accuracy: 1e-12)
    }

    // MARK: - Wrapped delta (diagnostic readout)

    func testWrappedDeltaForwardWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1000, to: 1500), 500)
    }

    func testWrappedDeltaReverseWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1500, to: 1000), -500)
    }

    func testWrappedDeltaForwardAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 16300, to: 100), 184)
    }

    func testWrappedDeltaReverseAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 100, to: 16300), -184)
    }

    // MARK: - Alias risk (diagnostic)

    func testAliasWarningThresholdAbove4096() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 4096), .none)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 4097), .warn)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 8192), .warn)
    }

    func testAliasFailureThresholdAbove8192() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 8193), .fail)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: -9000), .fail)
    }

    // MARK: - Loop / clamp boundary mode (via CC6)

    func testLoopModeWrapsForwardWithCC6() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 1.0,
                                             boundaryMode: .loop, samplePosition: 0.95)
        m.ingestCC6(50)
        m.ingestCC6(51)                                    // +0.1 → 1.05 → wraps to 0.05
        XCTAssertEqual(m.samplePosition, 0.05, accuracy: 1e-9)
        XCTAssertFalse(m.isAtEnd)
    }

    func testLoopModeWrapsReverseWithCC6() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 1.0,
                                             boundaryMode: .loop, samplePosition: 0.05)
        m.ingestCC6(50)
        m.ingestCC6(49)                                    // -0.1 → -0.05 → wraps to 0.95
        XCTAssertEqual(m.samplePosition, 0.95, accuracy: 1e-9)
    }

    func testClampModeClampsWithCC6() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.5, sampleDuration: 1.0,
                                             boundaryMode: .clamp, samplePosition: 0.9)
        m.ingestCC6(50)
        m.ingestCC6(51)                                    // +0.5 → 1.4 → clamps to 1.0
        XCTAssertEqual(m.samplePosition, 1.0, accuracy: 1e-12)
        XCTAssertTrue(m.isAtEnd)
    }

    func testWrapPositionHandlesMultipleAndNegativeWraps() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrapPosition(2.3, duration: 1.0), 0.3, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrapPosition(-0.25, duration: 1.0), 0.75, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrapPosition(5.0, duration: 0), 0, accuracy: 1e-12)
    }

    func testResetPositionReturnsToStart() {
        var m = ScratchPlatterPlayheadMapper(sampleDuration: 10.0, samplePosition: 4.0)
        m.resetPosition()
        XCTAssertEqual(m.samplePosition, 0.0, accuracy: 1e-12)
    }

    func testZeroDurationKeepsPositionAndFractionAtZero() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 0)
        m.ingestCC6(50)
        m.ingestCC6(51)
        XCTAssertEqual(m.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertEqual(m.positionFraction, 0.0, accuracy: 1e-12)
    }

    // MARK: - "Rotate one revolution" measurement (now CC6 steps)

    func testTickMeasurementAccumulatesSignedAndAbsoluteTicks() {
        var measurement = PlatterTickMeasurement()
        measurement.record(delta: 1)
        measurement.record(delta: -1)
        measurement.record(delta: 1)
        XCTAssertEqual(measurement.totalSignedTicks, 1)
        XCTAssertEqual(measurement.absoluteTickSum, 3)
        XCTAssertEqual(measurement.eventCount, 3)
    }

    func testTickMeasurementSuggestionAndEmptyState() {
        var measurement = PlatterTickMeasurement()
        XCTAssertNil(measurement.suggestedSampleSecondsPerTick(targetSeconds: 1.0))
        for _ in 0..<3932 { measurement.record(delta: 1) } // one revolution
        XCTAssertEqual(measurement.suggestedSampleSecondsPerTick(targetSeconds: 1.0)!, 1.0 / 3932.0, accuracy: 1e-12)
        XCTAssertNil(measurement.suggestedSampleSecondsPerTick(targetSeconds: 0))
    }

    // MARK: - Crossfader normalisation + no-value gating

    func testCrossfaderNormalisesFullRange() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 127), 1.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 64), 64.0 / 127.0, accuracy: 1e-12)
    }

    func testGatingDoesNotMuteBeforeFirstValue() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: false, crossfader: 0.0), 1.0)
    }

    func testGatingOffIsAlwaysFullGain() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: false, crossfaderValid: true, crossfader: 0.0), 1.0)
    }

    func testGatingIsHardCutNotLinearSlope() {
        // Off only at the very off end; full gain across the rest of the throw (no slope).
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.0), 0.0)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.5), 1.0, accuracy: 1e-6)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.70), 1.0, accuracy: 1e-6)
        // Inside the narrow cut zone it ramps (click-safe), reaching full by cutWidth.
        let half = ScratchPlatterPlayheadMapper.crossfaderCutWidth / 2
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: half), 0.5, accuracy: 1e-6)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: ScratchPlatterPlayheadMapper.crossfaderCutWidth), 1.0, accuracy: 1e-6)
    }

    // MARK: - Per-deck pitch-bend filtering

    func testIsPitchBendChannelMatchesOnlySelectedDeck() {
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 0))
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 1))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 1))
    }

    func testIsPitchBendChannelRejectsNonPlatterChannelsAndNil() {
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(15, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(nil, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(2, forDeck: 2))
    }

    func testDeckForRawChannelMapping() {
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(0), .left)
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(1), .right)
        XCTAssertNil(ScratchPlatterDeck.forRawChannel(2))
        XCTAssertEqual(ScratchPlatterDeck.left.rawChannel, 0)
        XCTAssertEqual(ScratchPlatterDeck.right.rawChannel, 1)
    }

    // MARK: - RANE pitch bend stays diagnostic-only; SV uses the absolute seek

    func testTrackPitchBendNeverMovesThePlayhead() {
        // RANE invariant: tracking pitch bend updates diagnostics but never the position,
        // even on a huge (aliasing) jump — only CC6 moves the RANE playhead.
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 10, samplePosition: 3.0)
        m.trackPitchBend(2000)
        m.trackPitchBend(9000)   // ~7000-tick alias jump
        m.trackPitchBend(150)
        XCTAssertEqual(m.samplePosition, 3.0, accuracy: 1e-12)
    }

    func testSeekToPositionFractionSetsAbsolutePositionAndClamps() {
        var m = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.1, sampleDuration: 10)
        m.seek(toPositionFraction: 0.5)
        XCTAssertEqual(m.samplePosition, 5.0, accuracy: 1e-12)
        m.seek(toPositionFraction: 2.0)  // clamp high
        XCTAssertEqual(m.samplePosition, 10.0, accuracy: 1e-12)
        m.seek(toPositionFraction: -1.0) // clamp low
        XCTAssertEqual(m.samplePosition, 0.0, accuracy: 1e-12)
    }
}
