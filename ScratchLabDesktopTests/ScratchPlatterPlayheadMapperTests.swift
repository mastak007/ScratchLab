import XCTest
@testable import ScratchLab

/// Scratch Playback Lab (first slice) — pure platter → sample-position mapping.
/// No AVFoundation, no Core MIDI, no UI, and nothing from the capture/scoring/
/// export pipeline is exercised here. Mirrors the documented model:
///   rate = (raw - baseline) * rateScale ; position += rate * dt ; clamp 0…duration.
final class ScratchPlatterPlayheadMapperTests: XCTestCase {

    // MARK: - Pitch-bend 14-bit decode (via the shared parser the lab consumes)

    func testPitchBendDecodesAs14Bit() {
        // data1 = LSB, data2 = MSB → value = lsb | (msb << 7).
        let parsed = MIDIMessageParsing.parse([0xE0, 0x32, 0x58])
        XCTAssertEqual(parsed.messageType, .pitchBend)
        XCTAssertEqual(parsed.value, 0x32 | (0x58 << 7)) // 11314
    }

    func testProvisionalMotorBaselineMatchesMeasuredValue() {
        // 11314 ≈ 0x32 | (0x58 << 7); the provisional RANE motor baseline.
        XCTAssertEqual(ScratchPlatterPlayheadMapper.defaultMotorBaseline, 0x32 | (0x58 << 7))
    }

    // MARK: - Baseline subtraction → playback rate

    func testRateIsZeroAtBaseline() {
        let mapper = ScratchPlatterPlayheadMapper(baseline: 11314, rateScale: 1.0 / 4096.0, sampleDuration: 1.0)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314), 0, accuracy: 1e-12)
    }

    func testRateIsPositiveAboveBaselineAndNegativeBelow() {
        let mapper = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 1.0)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 8192 + 4096), 1.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 8192 - 4096), -1.0, accuracy: 1e-12)
    }

    // MARK: - Integration: forward and reverse velocity

    func testForwardMotionAdvancesPosition() {
        // maxIntegrationStep raised so this exercises integration, not the dt cap.
        var mapper = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 10.0, maxIntegrationStep: 10.0)
        // rate = +1.0 (realtime), dt = 0.5 → +0.5s.
        mapper.ingestPitchBend(8192 + 4096, dt: 0.5)
        XCTAssertEqual(mapper.samplePosition, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(mapper.positionFraction, 0)
    }

    func testReverseMotionRetreatsPosition() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 10.0, maxIntegrationStep: 10.0, samplePosition: 2.0)
        // rate = -1.0, dt = 0.5 → -0.5s → 1.5s.
        mapper.ingestPitchBend(8192 - 4096, dt: 0.5)
        XCTAssertEqual(mapper.samplePosition, 1.5, accuracy: 1e-9)
    }

    func testIntegrationAccumulatesAcrossEvents() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 100.0, maxIntegrationStep: 10.0)
        mapper.ingestPitchBend(2, dt: 1.0) // +2
        mapper.ingestPitchBend(3, dt: 1.0) // +3 → 5
        XCTAssertEqual(mapper.samplePosition, 5.0, accuracy: 1e-9)
    }

    // MARK: - Clamp behaviour (clamp, not wrap)

    func testPositionClampsAtUpperBound() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 1.0, samplePosition: 0.9)
        mapper.ingestPitchBend(10, dt: 1.0) // would reach 10.9 → clamp to 1.0
        XCTAssertEqual(mapper.samplePosition, 1.0, accuracy: 1e-12)
    }

    func testPositionClampsAtLowerBound() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 1.0, samplePosition: 0.2)
        mapper.ingestPitchBend(-10, dt: 1.0) // would reach -9.8 → clamp to 0
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
    }

    // MARK: - dt guarding

    func testNegativeDtIsIgnored() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 10.0, samplePosition: 1.0)
        mapper.ingestPitchBend(5, dt: -2.0)
        XCTAssertEqual(mapper.samplePosition, 1.0, accuracy: 1e-12)
    }

    func testLargeDtIsCappedAtMaxIntegrationStep() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 100.0, maxIntegrationStep: 0.05)
        // rate = 1.0, dt = 10s but capped to 0.05 → +0.05.
        mapper.ingestPitchBend(1, dt: 10.0)
        XCTAssertEqual(mapper.samplePosition, 0.05, accuracy: 1e-9)
    }

    // MARK: - Calibration / reset

    func testCalibrateMovesTheZeroVelocityPoint() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0, sampleDuration: 1.0)
        mapper.calibrate(toBaseline: 12000)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 12000), 0, accuracy: 1e-12)
    }

    func testResetReturnsToStart() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 10.0, samplePosition: 4.0)
        mapper.resetPosition()
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
    }

    // MARK: - Crossfader normalisation (CC / 127)

    func testCrossfaderNormalisesFullRange() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 127), 1.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 64), 64.0 / 127.0, accuracy: 1e-12)
    }

    func testCrossfaderClampsOutOfRange() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: -5), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 200), 1.0, accuracy: 1e-12)
    }

    // MARK: - Degenerate sample duration

    func testZeroDurationKeepsPositionAndFractionAtZero() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 0)
        mapper.ingestPitchBend(100, dt: 1.0)
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.positionFraction, 0.0, accuracy: 1e-12)
    }

    // MARK: - Deadband (idle-jitter guard)

    func testDeadbandForcesZeroRateWithinBand() {
        let mapper = ScratchPlatterPlayheadMapper(baseline: 11314, rateScale: 1.0, sampleDuration: 10.0, velocityDeadband: 16)
        // Inside ±16 of baseline → zero, regardless of sign.
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314 + 16), 0, accuracy: 1e-12)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314 - 16), 0, accuracy: 1e-12)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314), 0, accuracy: 1e-12)
    }

    func testDeadbandPassesValuesOutsideBand() {
        let mapper = ScratchPlatterPlayheadMapper(baseline: 11314, rateScale: 1.0, sampleDuration: 10.0, velocityDeadband: 16)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314 + 17), 17, accuracy: 1e-12)
        XCTAssertEqual(mapper.playbackRate(forPitchBend: 11314 - 17), -17, accuracy: 1e-12)
    }

    func testCalibratedIdleDoesNotCreep() {
        // Calibrated baseline + jitter within the deadband → position never moves.
        var mapper = ScratchPlatterPlayheadMapper(baseline: 11314, rateScale: 1.0 / 4096.0, sampleDuration: 10.0,
                                                  maxIntegrationStep: 10.0, velocityDeadband: 16, samplePosition: 3.0)
        for jitter in [-8, 4, -2, 12, -16, 16, 0, 7] {
            mapper.ingestPitchBend(11314 + jitter, dt: 0.1)
        }
        XCTAssertEqual(mapper.samplePosition, 3.0, accuracy: 1e-12)
    }

    // MARK: - Invert direction (lab-only escape hatch)

    func testInvertFlipsRateSign() {
        let normal = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 10.0)
        let flipped = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 10.0, inverted: true)
        XCTAssertEqual(normal.playbackRate(forPitchBend: 8192 + 4096), 1.0, accuracy: 1e-12)
        XCTAssertEqual(flipped.playbackRate(forPitchBend: 8192 + 4096), -1.0, accuracy: 1e-12)
        XCTAssertEqual(flipped.playbackRate(forPitchBend: 8192 - 4096), 1.0, accuracy: 1e-12)
    }

    func testInvertReversesIntegrationDirection() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 8192, rateScale: 1.0 / 4096.0, sampleDuration: 10.0,
                                                  maxIntegrationStep: 10.0, inverted: true, samplePosition: 5.0)
        // Forward platter (+) now retreats the playhead.
        mapper.ingestPitchBend(8192 + 4096, dt: 0.5)
        XCTAssertEqual(mapper.samplePosition, 4.5, accuracy: 1e-9)
    }

    // MARK: - Clamp-edge flags

    func testIsAtStartAndIsAtEndReflectClamp() {
        var mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 1.0,
                                                  maxIntegrationStep: 10.0, samplePosition: 0.5)
        XCTAssertFalse(mapper.isAtStart)
        XCTAssertFalse(mapper.isAtEnd)

        mapper.ingestPitchBend(-100, dt: 1.0) // drive hard negative → clamp to start
        XCTAssertTrue(mapper.isAtStart)
        XCTAssertFalse(mapper.isAtEnd)

        mapper.ingestPitchBend(100, dt: 1.0) // drive hard positive → clamp to end
        XCTAssertTrue(mapper.isAtEnd)
        XCTAssertFalse(mapper.isAtStart)
    }

    func testZeroDurationIsNeitherStartNorEndForEnd() {
        let mapper = ScratchPlatterPlayheadMapper(baseline: 0, rateScale: 1.0, sampleDuration: 0)
        XCTAssertTrue(mapper.isAtStart)   // position 0 <= 0
        XCTAssertFalse(mapper.isAtEnd)    // no end when there is no duration
    }

    // MARK: - Per-deck pitch-bend filtering

    func testIsPitchBendChannelMatchesOnlySelectedDeck() {
        // Left deck (0) accepts raw channel 0 only; right deck (1) accepts channel 1 only.
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 0))
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 1))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 1))
    }

    func testIsPitchBendChannelRejectsNonPlatterChannelsAndNil() {
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(15, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(nil, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(2, forDeck: 2)) // deck 2 is not a platter
    }

    func testDeckForRawChannelMapping() {
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(0), .left)
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(1), .right)
        XCTAssertNil(ScratchPlatterDeck.forRawChannel(2))
        XCTAssertNil(ScratchPlatterDeck.forRawChannel(15))
        XCTAssertEqual(ScratchPlatterDeck.left.rawChannel, 0)
        XCTAssertEqual(ScratchPlatterDeck.right.rawChannel, 1)
    }
}
