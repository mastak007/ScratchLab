import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — pure platter → sample-position mapping.
/// No AVFoundation, no Core MIDI, no UI, and nothing from the capture/scoring/
/// export pipeline is exercised here. The RANE platter pitch bend is an ABSOLUTE
/// 14-bit angle, so the playhead tracks the wrapped *delta* between successive
/// values (no velocity integration, no baseline):
///   delta = wrappedDelta(last → raw, 16384) ; position += delta/16384 * secPerRev.
final class ScratchPlatterPlayheadMapperTests: XCTestCase {

    private let mod = ScratchPlatterPlayheadMapper.ticksPerRevolution // 16384

    // MARK: - Pitch-bend 14-bit decode (via the shared parser the lab consumes)

    func testPitchBendDecodesAs14Bit() {
        // data1 = LSB, data2 = MSB → value = lsb | (msb << 7).
        let parsed = MIDIMessageParsing.parse([0xE0, 0x32, 0x58])
        XCTAssertEqual(parsed.messageType, .pitchBend)
        XCTAssertEqual(parsed.value, 0x32 | (0x58 << 7)) // 11314
    }

    func testTicksPerRevolutionIs14Bit() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.ticksPerRevolution, 16384)
    }

    // MARK: - Wrapped delta (the core of absolute-angle tracking)

    func testWrappedDeltaForwardWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1000, to: 1500), 500)
    }

    func testWrappedDeltaReverseWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1500, to: 1000), -500)
    }

    func testWrappedDeltaForwardAcrossBoundary() {
        // 16300 → 100 forward is +184 (16384 - 16300 + 100), not -16200.
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 16300, to: 100), 184)
    }

    func testWrappedDeltaReverseAcrossBoundary() {
        // 100 → 16300 reverse is -184, not +16200.
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 100, to: 16300), -184)
    }

    func testWrappedDeltaHalfRevolutionTakesPositiveBranch() {
        // Exactly half a revolution folds to +8192 (boundary is inclusive on +side).
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 0, to: 8192), 8192)
    }

    // MARK: - First event seeds without jumping

    func testFirstEventSeedsLastRawAndDoesNotMove() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 10.0, samplePosition: 3.0)
        let delta = mapper.ingestPitchBend(12000) // far from anything, but it's the first
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(mapper.samplePosition, 3.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.lastRawPitchBend, 12000)
    }

    // MARK: - Forward / reverse tracking

    func testForwardRotationAdvancesPosition() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.6384, sampleDuration: 100.0)
        mapper.ingestPitchBend(0)       // seed
        mapper.ingestPitchBend(1000)    // +1000 ticks
        // 1000/16384 * 1.6384 = 0.1 s
        XCTAssertEqual(mapper.samplePosition, 0.1, accuracy: 1e-9)
    }

    func testReverseRotationRetreatsPosition() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.6384, sampleDuration: 100.0, samplePosition: 0.5)
        mapper.ingestPitchBend(2000)    // seed
        mapper.ingestPitchBend(1000)    // -1000 ticks → -0.1 s
        XCTAssertEqual(mapper.samplePosition, 0.4, accuracy: 1e-9)
    }

    func testOneFullRevolutionEqualsSecondsPerRevolution() {
        // Walk a full turn in quarter-turn steps (each <= half a revolution so no fold).
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 100.0)
        mapper.ingestPitchBend(0)       // seed
        for tick in [4096, 8192, 12288, 16383] {
            mapper.ingestPitchBend(tick)
        }
        // 0 → 16383 is one tick short of a full turn; add the final tick to complete it.
        mapper.ingestPitchBend(0)       // 16383 → 0 forward is +1 tick (completes the turn)
        XCTAssertEqual(mapper.samplePosition, 1.8, accuracy: 1e-6)
    }

    // MARK: - Wrap boundary does not jump to the end

    func testCrossingBoundaryForwardDoesNotJump() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 10.0)
        mapper.ingestPitchBend(16300)   // seed near the top
        mapper.ingestPitchBend(100)     // forward across 16383→0: +184 ticks only
        let expected = Double(184) / 16384.0 * 1.8
        XCTAssertEqual(mapper.samplePosition, expected, accuracy: 1e-9)
        XCTAssertFalse(mapper.isAtEnd)
    }

    // MARK: - Invert direction

    func testInvertFlipsTrackingDirection() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.6384, sampleDuration: 100.0,
                                                  inverted: true, samplePosition: 0.5)
        mapper.ingestPitchBend(0)       // seed
        mapper.ingestPitchBend(1000)    // +1000 geometrically, inverted → -0.1 s
        XCTAssertEqual(mapper.samplePosition, 0.4, accuracy: 1e-9)
    }

    // MARK: - Clamp at start / end

    func testClampAtEnd() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 1.0, samplePosition: 0.9)
        mapper.ingestPitchBend(0)       // seed
        mapper.ingestPitchBend(8000)    // big forward delta → clamp to 1.0
        XCTAssertEqual(mapper.samplePosition, 1.0, accuracy: 1e-12)
        XCTAssertTrue(mapper.isAtEnd)
        XCTAssertFalse(mapper.isAtStart)
    }

    func testClampAtStart() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 1.0, samplePosition: 0.1)
        mapper.ingestPitchBend(8000)    // seed
        mapper.ingestPitchBend(0)       // big reverse delta → clamp to 0
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertTrue(mapper.isAtStart)
        XCTAssertFalse(mapper.isAtEnd)
    }

    // MARK: - Reset / tracking re-seed

    func testResetTrackingMakesNextEventSeedAgain() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 10.0)
        mapper.ingestPitchBend(1000)
        mapper.ingestPitchBend(2000)    // moved
        let moved = mapper.samplePosition
        mapper.resetTracking()
        let delta = mapper.ingestPitchBend(9000) // first after reset → seed, no move
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(mapper.samplePosition, moved, accuracy: 1e-12)
    }

    func testResetPositionReturnsToStart() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 10.0, samplePosition: 4.0)
        mapper.resetPosition()
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
    }

    // MARK: - Degenerate sample duration

    func testZeroDurationKeepsPositionAndFractionAtZero() {
        var mapper = ScratchPlatterPlayheadMapper(secondsPerRevolution: 1.8, sampleDuration: 0)
        mapper.ingestPitchBend(0)
        mapper.ingestPitchBend(8000)
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.positionFraction, 0.0, accuracy: 1e-12)
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

    // MARK: - Crossfader volume gating (never mutes before a value arrives)

    func testGatingDoesNotMuteBeforeFirstValue() {
        // Gating on, but no valid crossfader yet → full gain, not silence.
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: false, crossfader: 0.0), 1.0)
    }

    func testGatingOffIsAlwaysFullGain() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: false, crossfaderValid: true, crossfader: 0.0), 1.0)
    }

    func testGatingAppliesAfterValueReceived() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.0), 0.0)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 1.0), 1.0)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.5), 0.5, accuracy: 1e-6)
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
        XCTAssertNil(ScratchPlatterDeck.forRawChannel(15))
        XCTAssertEqual(ScratchPlatterDeck.left.rawChannel, 0)
        XCTAssertEqual(ScratchPlatterDeck.right.rawChannel, 1)
    }
}
