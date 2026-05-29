import XCTest
@testable import ScratchLab

/// Phase 1 / hardware-input layer — locks the pure-data contract of the
/// normalized controller-input model and the transport/normalizer seams.
/// No notation, audio, coaching, ML, capture, DVS, HID, or device decoding is
/// exercised here.
final class ScratchControllerInputModelTests: XCTestCase {

    private func makeSource(_ transport: ScratchTransportKind = .synthetic) -> ScratchInputSource {
        ScratchInputSource(transport: transport, deviceID: "test", profileID: nil)
    }

    // MARK: - ScratchInputFrame velocity / direction

    func testFrameStoresForwardVelocityAndDirection() {
        let frame = ScratchInputFrame(
            timestamp: 1.0, deck: .left,
            platterPosition: 2.5, platterVelocity: 1.25,
            source: makeSource()
        )
        XCTAssertEqual(frame.platterVelocity, 1.25, accuracy: 1e-9)
        XCTAssertEqual(frame.platterDirection, .forward)
        XCTAssertEqual(frame.platterPosition, 2.5, accuracy: 1e-9)
    }

    func testFrameStoresReverseVelocityAndDirection() {
        let frame = ScratchInputFrame(
            timestamp: 2.0, deck: .right,
            platterPosition: -0.75, platterVelocity: -3.0,
            source: makeSource()
        )
        XCTAssertEqual(frame.platterVelocity, -3.0, accuracy: 1e-9)
        XCTAssertEqual(frame.platterDirection, .reverse)
    }

    func testZeroVelocityIsStopped() {
        let frame = ScratchInputFrame(
            timestamp: 0, deck: .left,
            platterPosition: 0, platterVelocity: 0,
            source: makeSource()
        )
        XCTAssertEqual(frame.platterDirection, .stopped)
    }

    func testPlatterPositionIsAccumulatedNotWrapped() {
        // A position beyond one revolution must be retained verbatim
        // (unwrapped/accumulated), not folded into a 0..1 angle.
        let frame = ScratchInputFrame(
            timestamp: 0, deck: .left,
            platterPosition: 12.3, platterVelocity: 0.1,
            source: makeSource()
        )
        XCTAssertEqual(frame.platterPosition, 12.3, accuracy: 1e-9)
    }

    // MARK: - Crossfader optionality

    func testCrossfaderCanBeAbsent() {
        let frame = ScratchInputFrame(
            timestamp: 0, deck: .left,
            platterPosition: 0, platterVelocity: 0,
            source: makeSource(.dvs)
        )
        XCTAssertNil(frame.crossfaderPosition)
        XCTAssertNil(frame.crossfaderVelocity)
    }

    func testCrossfaderCanBePresent() {
        let frame = ScratchInputFrame(
            timestamp: 0, deck: .left,
            platterPosition: 0, platterVelocity: 0,
            crossfaderPosition: 0.5, crossfaderVelocity: -0.2,
            source: makeSource(.midi)
        )
        XCTAssertEqual(frame.crossfaderPosition, 0.5)
        XCTAssertEqual(frame.crossfaderVelocity, -0.2)
    }

    // MARK: - Deck / direction identity stability

    func testDeckIDsAreStable() {
        XCTAssertEqual(ScratchDeckID.left.rawValue, 0)
        XCTAssertEqual(ScratchDeckID.right.rawValue, 1)
        XCTAssertEqual(ScratchDeckID(rawValue: 0), .left)
        XCTAssertEqual(ScratchDeckID(rawValue: 1), .right)
        XCTAssertEqual(ScratchDeckID.allCases, [.left, .right])
    }

    func testPlatterDirectionRawValuesAreStable() {
        XCTAssertEqual(ScratchPlatterDirection.reverse.rawValue, -1)
        XCTAssertEqual(ScratchPlatterDirection.stopped.rawValue, 0)
        XCTAssertEqual(ScratchPlatterDirection.forward.rawValue, 1)
    }

    // MARK: - Raw events retain bytes + timestamp

    func testMIDIRawEventRetainsBytesAndTimestamp() {
        let event = MIDIRawEvent(timestamp: 4.2, bytes: [0xB0, 0x10, 0x40])
        XCTAssertEqual(event.timestamp, 4.2, accuracy: 1e-9)
        XCTAssertEqual(event.bytes, [0xB0, 0x10, 0x40])
    }

    func testRawInputEventWrapsMIDIVerbatim() {
        let midi = MIDIRawEvent(timestamp: 7.5, bytes: [0x90, 0x3C, 0x7F])
        let raw = ScratchRawInputEvent(id: 99, midi: midi)
        XCTAssertEqual(raw.id, 99)
        XCTAssertEqual(raw.transport, .midi)
        XCTAssertEqual(raw.timestamp, 7.5, accuracy: 1e-9)
        XCTAssertEqual(raw.bytes, [0x90, 0x3C, 0x7F])
    }

    // MARK: - Transport stub lifecycle + gated delivery

    func testStubTransportStartStopLifecycle() {
        let transport = StubMIDITransport()
        XCTAssertFalse(transport.isRunning)
        transport.start()
        XCTAssertTrue(transport.isRunning)
        transport.stop()
        XCTAssertFalse(transport.isRunning)
    }

    func testStubTransportOnlyDeliversWhileRunning() {
        let transport = StubMIDITransport()
        var received: [MIDIRawEvent] = []
        transport.onEvent = { received.append($0) }

        // Stopped: injection is dropped.
        transport.inject(MIDIRawEvent(timestamp: 0, bytes: [0xB0, 0x00, 0x01]))
        XCTAssertTrue(received.isEmpty)

        // Running: injection is delivered verbatim.
        transport.start()
        transport.inject(MIDIRawEvent(timestamp: 1, bytes: [0xB0, 0x00, 0x02]))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.bytes, [0xB0, 0x00, 0x02])
    }

    // MARK: - Normalizer emits nothing without a profile

    func testNormalizerEmitsNoFrameWithoutProfile() {
        let normalizer = StubControllerInputNormalizer()
        XCTAssertNil(normalizer.profile)
        let raw = ScratchRawInputEvent(id: 1, transport: .midi, timestamp: 0, bytes: [0xB0, 0x10, 0x40])
        XCTAssertNil(normalizer.ingest(raw))
    }
}
