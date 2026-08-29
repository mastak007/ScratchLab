// MIDIPacketBoundsCrashFixTests.swift
// ScratchLabDesktopTests
//
// Regression coverage for the confirmed Rane ONE MKII crash in
// `MacCaptureEngine.receiveMIDIPacketList`.
//
// CONFIRMED root cause: the original code obtained the first packet's
// address via `withUnsafePointer(to: packetListPtr.pointee.packet)`, which
// copies the packet into a temporary and hands back a pointer valid only
// for that call — using it afterwards (as the original loop did) reads
// stale/reused stack memory. That explains both the invalid decoded values
// reported immediately before the crash (garbage read as if it were MIDI
// bytes) and the eventual crash itself, which trapped in `rawBytes[i]`
// inside `withUnsafeBytes(of: packetPtr.pointee.data)` — reachable once
// whatever garbage occupied `.length` exceeded the 256 bytes that call can
// ever expose for the fixed-size `data` tuple CoreMIDI's header declares.
//
// NOT CONFIRMED: no diagnostic captured the actual `MIDIPacket.length` at
// crash time, so this suite does not claim Rane hardware itself delivers a
// real packet longer than 256 bytes. CoreMIDI's header does allow it
// ("[length] may be larger than 256 bytes if the packet is dynamically
// allocated"), so the one oversized-packet test below is labeled and kept
// separate as defensive coverage of that documented possibility, not a
// reproduction of the confirmed trigger.
//
// Per MIDIServices.h: "Running status is not allowed" for `MIDIPacket.data`
// and "the MIDI messages in the packet must always be complete, except for
// system-exclusive." The fixed parser is stateless accordingly — no
// running status, no channel-message reconstruction across a packet
// boundary, no SysEx state carried into the next packet.

import CoreMIDI
import XCTest
@testable import ScratchLab

/// Builds a real `MIDIPacketList` using CoreMIDI's own convenience API, so
/// these tests exercise genuine packet-list memory and real `MIDIPacketNext`
/// traversal rather than a synthetic stand-in.
///
/// `packets`: each inner array is the set of complete MIDI events that
/// should land in one `MIDIPacket` (each event a single, non-running-status
/// message, per `MIDIPacketListAdd`'s documented contract). Distinct
/// `MIDITimeStamp` values per group are what makes `MIDIPacketListAdd`
/// start a new packet instead of coalescing into the current one (verified
/// empirically against this SDK: identical timestamps merge into one
/// packet; a changed timestamp starts a new one).
private final class MIDIPacketListFixture {
    let pointer: UnsafeMutablePointer<MIDIPacketList>
    private let buffer: UnsafeMutableRawPointer

    init(packets: [[[UInt8]]], bufferSize: Int = 4096) {
        buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        pointer = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packetPtr = MIDIPacketListInit(pointer)
        for (groupIndex, events) in packets.enumerated() {
            for event in events {
                // Imported as non-optional on this SDK (the header's
                // `CF_ASSUME_NONNULL` region doesn't mark this return
                // `_Nullable`, despite documenting a null return on
                // failure) — check for a null address explicitly since the
                // type system can't do it for us.
                let next = MIDIPacketListAdd(pointer, bufferSize, packetPtr, MIDITimeStamp(groupIndex), event.count, event)
                XCTAssertNotEqual(UInt(bitPattern: next), 0, "MIDIPacketListAdd failed — fixture event too large for bufferSize")
                packetPtr = next
            }
        }
    }

    deinit {
        buffer.deallocate()
    }
}

/// DEFENSIVE COVERAGE ONLY — see the file-level comment above. Manually
/// constructs a single `MIDIPacket` whose `length` exceeds the inline
/// 256-byte `data` capacity by writing directly into a real
/// `MIDIPacketList` allocation, using the live pointer `MIDIPacketListInit`
/// returns (not a `.pointee` value copy). `MIDIPacketListAdd` is not used
/// for the payload write because it refuses/truncates a single event
/// anywhere near this size on this SDK (confirmed empirically) — this is
/// exactly the legacy ~256-byte-per-packet assumption the production fix
/// removes, so the convenience API cannot be used to construct the case it
/// no longer applies to.
private final class DefensiveOversizedPacketListFixture {
    let pointer: UnsafeMutablePointer<MIDIPacketList>
    private let buffer: UnsafeMutableRawPointer

    init(oversizedEventBytes: [UInt8], bufferSize: Int = 65536) {
        precondition(oversizedEventBytes.count > 256, "fixture only exists to exercise the oversized-packet path")
        buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)
        pointer = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)

        // Official API for the first packet's address — a genuine live
        // pointer into `pointer`'s storage.
        let packetPtr = MIDIPacketListInit(pointer)
        pointer.pointee.numPackets = 1

        packetPtr.pointee.timeStamp = 0
        packetPtr.pointee.length = UInt16(oversizedEventBytes.count)
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        let dataPtr = UnsafeMutableRawPointer(packetPtr).advanced(by: dataOffset)
        oversizedEventBytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                dataPtr.copyMemory(from: base, byteCount: oversizedEventBytes.count)
            }
        }
    }

    deinit {
        buffer.deallocate()
    }
}

final class MIDIPacketBoundsCrashFixTests: XCTestCase {

    /// Proves the `MemoryLayout` field offsets the production fix (and the
    /// defensive fixture above) rely on actually match this SDK's imported
    /// struct layout — `#pragma pack(push, 4)` around `MIDIPacket`/
    /// `MIDIPacketList` in MIDIServices.h — rather than assuming it.
    func testMIDIPacketLayoutMatchesSDKPackedContract() {
        XCTAssertEqual(MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data), 10)
        XCTAssertEqual(MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet), 4)
    }

    // MARK: - Engine-level: real MIDIPacketList through the fixed receive path

    /// Regression test for the confirmed dangling-pointer bug: the original
    /// code obtained the first packet's address via
    /// `withUnsafePointer(to: packetListPtr.pointee.packet)`, which copies
    /// the packet into a temporary and returns a pointer valid only for
    /// that call. If that bug regressed, this would silently decode zeros
    /// or garbage instead of the real constructed bytes — exactly what was
    /// observed empirically while developing this fix, before the pointer
    /// was corrected to read live packet-list storage.
    func testFirstPacketIsReadFromLivePacketListMemoryNotATemporaryCopy() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let fixture = MIDIPacketListFixture(packets: [[[0xB1, 0x06, 0x55]]])

        engine.testOnly_receiveMIDIPacketList(fixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiEventsReceivedCount, 1)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value85")
    }

    /// Multiple `MIDIPacket`s in one `MIDIPacketList` must each be
    /// traversed and parsed correctly — proves the per-packet raw byte
    /// offset computation, combined with `MIDIPacketNext`, works for every
    /// packet in the list, not only the first.
    func testMultiplePacketsInOneListAreTraversedCorrectly() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let fixture = MIDIPacketListFixture(packets: [
            [[0xB0, 0x06, 0x10], [0xB0, 0x06, 0x11]],
            [[0xB1, 0x06, 0x20], [0xB1, 0x06, 0x21], [0xB1, 0x06, 0x22]],
        ])

        engine.testOnly_receiveMIDIPacketList(fixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiEventsReceivedCount, 5)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value34")
    }

    /// CoreMIDI's own contract: "the MIDI messages in the packet must
    /// always be complete, except for system-exclusive." An incomplete
    /// channel message (here, a lone status byte with no data bytes) must
    /// be dropped safely — never guessed at, never carried into the next
    /// packet — while an independent, complete message in the next packet
    /// still decodes correctly.
    func testIncompleteChannelMessageAtPacketBoundaryIsDroppedNextPacketDecodesCorrectly() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let fixture = MIDIPacketListFixture(packets: [
            [[0xB1]],
            [[0xB1, 0x06, 0x40]],
        ])

        engine.testOnly_receiveMIDIPacketList(fixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiEventsReceivedCount, 1, "the incomplete message in the first packet must not be decoded")
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value64")
    }

    /// SysEx may be partial per CoreMIDI's contract, but ScratchLab does
    /// not consume it — a SysEx that doesn't close with 0xF7 within its
    /// packet must be skipped safely, and that "still inside SysEx" state
    /// must NOT leak into the next packet, which decodes independently.
    func testPartialSysExPacketIsIgnoredSafelyNextPacketDecodesCorrectly() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let fixture = MIDIPacketListFixture(packets: [
            [[0xF0, 0x7E, 0x00, 0x09, 0x01]],  // SysEx start, no 0xF7 in this packet
            [[0xB1, 0x06, 0x40]],
        ])

        engine.testOnly_receiveMIDIPacketList(fixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiEventsReceivedCount, 1)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value64")
    }

    /// Left (channel 0) and right (channel 1) platter CC6 events must each
    /// decode with the correct channel number — proving the fixed byte
    /// extraction doesn't discriminate or corrupt channel identity. The
    /// actual right-deck-only ownership enforcement lives in unchanged
    /// dispatch code and is separately covered by
    /// `ScratchSamplePlaybackControllerMIDIPlatterTests` /
    /// `ScratchPlatterTrackerTests` / `MIDIPlatterContinuousDriveTests`.
    func testLeftAndRightPlatterCC6ChannelsDecodeWithCorrectChannelNumber() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)

        let leftFixture = MIDIPacketListFixture(packets: [[[0xB0, 0x06, 0x10]]])
        engine.testOnly_receiveMIDIPacketList(leftFixture.pointer)
        // The SwiftUI-facing monitor properties are throttled to ~4Hz
        // (`midiMonitorPublishInterval`); wait past that window so the
        // second feed below gets its own publish rather than being folded
        // into a batch that never flushes within a short RunLoop spin.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(engine.midiEventsReceivedCount, 1)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch1 Value16")

        let rightFixture = MIDIPacketListFixture(packets: [[[0xB1, 0x06, 0x20]]])
        engine.testOnly_receiveMIDIPacketList(rightFixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(engine.midiEventsReceivedCount, 2)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value32")
    }

    /// DEFENSIVE COVERAGE ONLY (see `DefensiveOversizedPacketListFixture`
    /// and the file-level comment): a packet whose `length` exceeds the
    /// inline 256-byte `data` capacity — a possibility CoreMIDI's header
    /// documents but which no captured diagnostic confirms Rane actually
    /// produced — is read safely from live storage rather than crashing,
    /// and every event in it decodes exactly once with in-range values.
    func testOversizedPacketDefensiveCoverageDoesNotCrash() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        var bytes: [UInt8] = []
        for i in 0..<100 {
            bytes += [0xB1, 0x06, UInt8(i % 128)]
        }
        XCTAssertGreaterThan(bytes.count, 256, "must exceed the inline buffer to exercise the defensive path")

        let fixture = DefensiveOversizedPacketListFixture(oversizedEventBytes: bytes)
        engine.testOnly_receiveMIDIPacketList(fixture.pointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiEventsReceivedCount, 100)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC6 Ch2 Value\(99 % 128)")
    }

    // MARK: - Parser-level: stateless per-packet framing

    private func decode(_ bytes: [UInt8]) -> [MIDIChannelMessageParser.Message] {
        var messages: [MIDIChannelMessageParser.Message] = []
        bytes.withUnsafeBytes { raw in
            MIDIChannelMessageParser.parse(raw) { messages.append($0) }
        }
        return messages
    }

    /// Two-byte channel messages (Program Change, Channel Pressure) must
    /// not misalign the CC messages surrounding them.
    func testTwoByteChannelMessagesDoNotCauseMisalignment() {
        let messages = decode([
            0xC0, 0x05,             // Program Change, 2 bytes
            0xB1, 0x06, 0x50,       // CC, 3 bytes
            0xD0, 0x7F,             // Channel Pressure, 2 bytes
            0xB1, 0x06, 0x51        // CC, 3 bytes
        ])

        let ccMessages = messages.filter { $0.status & 0xF0 == 0xB0 }
        XCTAssertEqual(ccMessages.count, 2)
        XCTAssertEqual(ccMessages[0].data1, 0x06); XCTAssertEqual(ccMessages[0].data2, 0x50)
        XCTAssertEqual(ccMessages[1].data1, 0x06); XCTAssertEqual(ccMessages[1].data2, 0x51)
    }

    /// Real-time bytes (MIDI Clock etc.) may appear anywhere per spec,
    /// including inside an otherwise in-progress channel message, and must
    /// never corrupt the surrounding message.
    func testInterspersedRealTimeMessagesDoNotCorruptSurroundingChannelMessages() {
        let messages = decode([
            0xB1, 0x06, 0x10,       // complete CC
            0xF8,                   // MIDI Clock between messages
            0xB1, 0x06, 0x11,       // complete CC
            0xB1, 0xF8, 0x06, 0x20  // CC with a real-time byte injected mid-message
        ])

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.map(\.data2), [0x10, 0x11, 0x20])
        XCTAssertTrue(messages.allSatisfy { $0.data1 == 0x06 && $0.status == 0xB1 })
    }

    /// Running status is not supported — CoreMIDI's own contract for
    /// `MIDIPacket.data` states "Running status is not allowed." A bare
    /// data byte with no immediately-preceding status byte must be
    /// dropped, not decoded against some earlier message's status, and
    /// parsing must resynchronize on the next valid status byte.
    func testBareDataByteWithNoPrecedingStatusIsRejectedAndParsingResyncs() {
        let messages = decode([0x06, 0x40, 0xB1, 0x06, 0x50])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.status, 0xB1)
        XCTAssertEqual(messages.first?.data1, 0x06)
        XCTAssertEqual(messages.first?.data2, 0x50)
    }

    /// Malformed input — a new status byte arriving before a prior
    /// message's data bytes were fully received — must never read out of
    /// bounds and must never emit a controller/value above 127. The parser
    /// must resynchronize and keep decoding subsequent valid messages.
    func testMalformedAndTruncatedInputNeverEmitsImpossibleValuesAndResyncs() {
        let messages = decode([
            0x40, 0x50,             // stray data bytes, no preceding status: dropped
            0xB1, 0x06,             // valid status + data1, then a new status arrives early:
            0x92, 0x04, 0x10,       // (abandons the CC, this Note On decodes normally)
            0xB1, 0x06              // incomplete CC at the very end of the buffer: dropped, no crash
        ])

        XCTAssertEqual(messages.count, 1, "only the fully-formed Note On should decode")
        XCTAssertEqual(messages.first?.status, 0x92)
        XCTAssertEqual(messages.first?.data1, 0x04)
        XCTAssertEqual(messages.first?.data2, 0x10)
        for message in messages {
            XCTAssertLessThan(message.data1, 0x80)
            if let data2 = message.data2 {
                XCTAssertLessThan(data2, 0x80)
            }
        }
    }

    /// System Common and SysEx bytes must be skipped safely without
    /// misaligning the channel-voice messages around them.
    func testSystemCommonAndSysExAreSkippedSafely() {
        let messages = decode([
            0xB1, 0x06, 0x10,                   // valid CC
            0xF2, 0x00, 0x00,                   // Song Position Pointer (System Common)
            0xF0, 0x7E, 0x00, 0x09, 0x01, 0xF7,  // a short, complete SysEx message
            0xB1, 0x06, 0x11                    // valid CC, must still decode correctly
        ])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.data2), [0x10, 0x11])
    }

    func testSupportedChannelMessagesConvertToExistingParsedModel() {
        let messages = decode([
            0x90, 0x24, 0x7F,
            0xB1, 0x06, 0x40,
            0xE2, 0x00, 0x40
        ])
        let parsed = messages.compactMap(\.parsedMessage)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.map(\.messageType), [.noteOn, .controlChange, .pitchBend])
        XCTAssertEqual(parsed.map(\.channel), [0, 1, 2])
    }

    func testTwoByteMessagesDoNotBecomeMisleadingParsedMessages() {
        let messages = decode([0xC0, 0x05, 0xD1, 0x7F])

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.compactMap(\.parsedMessage).isEmpty)
    }

    func testMIDIReadinessRequiresDeviceAndMessageEvidence() {
        XCTAssertEqual(
            MIDIReadinessState.classify(
                hasConnectedDevice: false,
                hasReceivedValidMessage: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            MIDIReadinessState.classify(
                hasConnectedDevice: true,
                hasReceivedValidMessage: false
            ),
            .deviceConnected
        )
        XCTAssertEqual(
            MIDIReadinessState.classify(
                hasConnectedDevice: true,
                hasReceivedValidMessage: true
            ),
            .receivingMessages
        )
        XCTAssertEqual(
            MIDIReadinessState.classify(
                hasConnectedDevice: false,
                hasReceivedValidMessage: true
            ),
            .unavailable,
            "message history cannot imply readiness after every device disconnects"
        )
    }
}
