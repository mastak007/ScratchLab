import XCTest
@testable import ScratchLab

/// Phase 1 / controller-input — pure MIDI parsing/formatting and detected-control
/// aggregation for the Controller Inspector. No Core MIDI, no UI, no device
/// assumptions, no notation/coaching/replay/export are exercised here.
final class ControllerInspectorParsingTests: XCTestCase {

    // MARK: - Status byte → channel / message type

    func testControlChangeStatusParsesChannelAndType() {
        // 0xB0 = Control Change, channel 0.
        let parsed = MIDIMessageParsing.parse([0xB0, 0x10, 0x40])
        XCTAssertEqual(parsed.messageType, .controlChange)
        XCTAssertEqual(parsed.channel, 0)
        XCTAssertEqual(parsed.statusByte, 0xB0)
    }

    func testChannelNibbleIsDecoded() {
        // 0xB6 = Control Change, channel 6 (0-based) → channel 7 (1-based).
        let parsed = MIDIMessageParsing.parse([0xB6, 0x3F, 0x00])
        XCTAssertEqual(parsed.messageType, .controlChange)
        XCTAssertEqual(parsed.channel, 6)
    }

    func testAllChannelVoiceStatusNibblesMapToTypes() {
        let expectations: [(UInt8, MIDIMessageType)] = [
            (0x80, .noteOff),
            (0x90, .noteOn),
            (0xA0, .polyphonicAftertouch),
            (0xB0, .controlChange),
            (0xC0, .programChange),
            (0xD0, .channelAftertouch),
            (0xE0, .pitchBend)
        ]
        for (status, type) in expectations {
            XCTAssertEqual(MIDIMessageParsing.parse([status, 0x01, 0x02]).messageType, type)
        }
    }

    func testSystemMessageHasNoChannel() {
        // 0xF8 = MIDI clock (system realtime).
        let parsed = MIDIMessageParsing.parse([0xF8])
        XCTAssertEqual(parsed.messageType, .system)
        XCTAssertNil(parsed.channel)
    }

    func testLeadingDataByteIsUnknown() {
        // A byte below 0x80 cannot be interpreted as a standalone message.
        let parsed = MIDIMessageParsing.parse([0x40, 0x20])
        XCTAssertEqual(parsed.messageType, .unknown)
        XCTAssertNil(parsed.channel)
    }

    // MARK: - CC event parsing

    func testCCEventParsesNumberAndValue() {
        let parsed = MIDIMessageParsing.parse([0xB0, 0x3F, 0x7F])
        XCTAssertEqual(parsed.controlNumber, 0x3F)
        XCTAssertEqual(parsed.value, 0x7F)
        XCTAssertNil(parsed.noteNumber)
        XCTAssertEqual(parsed.controlOrNoteNumber, 0x3F)
    }

    // MARK: - Note event parsing

    func testNoteOnParsesNumberAndVelocity() {
        let parsed = MIDIMessageParsing.parse([0x90, 0x3C, 0x64])
        XCTAssertEqual(parsed.messageType, .noteOn)
        XCTAssertEqual(parsed.noteNumber, 0x3C)
        XCTAssertEqual(parsed.value, 0x64)
        XCTAssertNil(parsed.controlNumber)
        XCTAssertEqual(parsed.controlOrNoteNumber, 0x3C)
    }

    func testNoteOffParses() {
        let parsed = MIDIMessageParsing.parse([0x81, 0x40, 0x00])
        XCTAssertEqual(parsed.messageType, .noteOff)
        XCTAssertEqual(parsed.channel, 1)
        XCTAssertEqual(parsed.noteNumber, 0x40)
    }

    func testPitchBendCombines14Bit() {
        // LSB=0x00, MSB=0x40 → centre 8192.
        let parsed = MIDIMessageParsing.parse([0xE0, 0x00, 0x40])
        XCTAssertEqual(parsed.messageType, .pitchBend)
        XCTAssertEqual(parsed.value, 8192)
    }

    // MARK: - Raw bytes + timestamp retained verbatim

    func testRawEventRetainsBytesAndTimestamp() {
        let event = MIDIRawEvent(timestamp: 12.345, bytes: [0xB0, 0x10, 0x40])
        XCTAssertEqual(event.timestamp, 12.345, accuracy: 1e-9)
        XCTAssertEqual(event.bytes, [0xB0, 0x10, 0x40])
        // Parsing must not mutate or shrink the raw bytes.
        _ = MIDIMessageParsing.parse(event.bytes)
        XCTAssertEqual(event.bytes, [0xB0, 0x10, 0x40])
    }

    func testHexFormattingIsUppercasePadded() {
        XCTAssertEqual(MIDIMessageParsing.hexString([0xB0, 0x05, 0x7F]), "B0 05 7F")
        XCTAssertEqual(MIDIMessageParsing.hexString([0x00]), "00")
    }

    // MARK: - Packet splitting (lossless)

    func testSplitSeparatesConcatenatedMessages() {
        let bytes: [UInt8] = [0xB0, 0x10, 0x40, 0x90, 0x3C, 0x7F]
        let messages = MIDIMessageParsing.splitIntoMessages(bytes)
        XCTAssertEqual(messages, [[0xB0, 0x10, 0x40], [0x90, 0x3C, 0x7F]])
        // Lossless: concatenation reproduces the input.
        XCTAssertEqual(messages.flatMap { $0 }, bytes)
    }

    func testSplitExpandsRunningStatus() {
        // CC status once, then two more value-pairs reusing it (running status).
        let bytes: [UInt8] = [0xB0, 0x10, 0x40, 0x10, 0x41, 0x10, 0x42]
        let messages = MIDIMessageParsing.splitIntoMessages(bytes)
        XCTAssertEqual(messages, [[0xB0, 0x10, 0x40], [0xB0, 0x10, 0x41], [0xB0, 0x10, 0x42]])
    }

    func testSplitHandlesInterleavedRealtime() {
        // A clock byte (0xF8) interleaved between a CC message's data bytes is
        // extracted as its own message; the CC is reassembled intact.
        let bytes: [UInt8] = [0xB0, 0x10, 0xF8, 0x40]
        let messages = MIDIMessageParsing.splitIntoMessages(bytes)
        XCTAssertTrue(messages.contains([0xF8]))
        XCTAssertTrue(messages.contains([0xB0, 0x10, 0x40]))
        // No data byte is dropped (order may change because realtime is extracted).
        XCTAssertEqual(messages.flatMap { $0 }.sorted(), bytes.sorted())
    }

    // MARK: - Detected-control summary counts events correctly

    func testSummaryCountsAndLastValuePerControl() {
        var summary = DetectedControlSummary()
        // Three updates to CC 16 / ch 0, then one note.
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x01]), at: 0.0)
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x05]), at: 0.5)
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x09]), at: 1.0)
        summary.record(MIDIMessageParsing.parse([0x90, 0x3C, 0x7F]), at: 1.2)

        XCTAssertEqual(summary.totalCount, 4)
        XCTAssertEqual(summary.distinctControlCount, 2)

        let cc = summary.stats[DetectedControlID(messageType: .controlChange, channel: 0, number: 16)]
        XCTAssertEqual(cc?.count, 3)
        XCTAssertEqual(cc?.lastValue, 0x09)
        // 2 intervals across 1.0s → 2 Hz.
        XCTAssertEqual(cc?.eventRate ?? 0, 2.0, accuracy: 1e-6)

        let note = summary.stats[DetectedControlID(messageType: .noteOn, channel: 0, number: 60)]
        XCTAssertEqual(note?.count, 1)
        XCTAssertEqual(note?.lastValue, 0x7F)
    }

    func testSummaryMostActiveIsOrderedByCount() {
        var summary = DetectedControlSummary()
        summary.record(MIDIMessageParsing.parse([0xB0, 0x20, 0x01]), at: 0)
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x01]), at: 0)
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x02]), at: 0)
        let active = summary.mostActive
        XCTAssertEqual(active.first?.id.number, 16)
        XCTAssertEqual(active.first?.count, 2)
    }

    func testSummaryClearResets() {
        var summary = DetectedControlSummary()
        summary.record(MIDIMessageParsing.parse([0xB0, 0x10, 0x01]), at: 0)
        summary.clear()
        XCTAssertEqual(summary.totalCount, 0)
        XCTAssertEqual(summary.distinctControlCount, 0)
        XCTAssertTrue(summary.mostActive.isEmpty)
    }
}
