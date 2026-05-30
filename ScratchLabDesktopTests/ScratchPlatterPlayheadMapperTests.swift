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
}
