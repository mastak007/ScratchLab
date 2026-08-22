/// Stateless MIDI 1.0 channel-voice byte-stream parser shared by platform
/// transports. It has no CoreMIDI, audio, device, or playback dependency.
///
/// CoreMIDI's `MIDIPacket.data` contract does not permit running status and
/// requires messages other than SysEx to be complete within a packet. Parser
/// state therefore never crosses calls or packet boundaries.
enum MIDIChannelMessageParser {
    struct Message: Equatable, Sendable {
        let status: UInt8
        let data1: UInt8
        let data2: UInt8?

        /// Converts the channel-voice types represented by ScratchLab's
        /// existing registry model. Other valid channel messages remain
        /// framed but deliberately do not acquire a misleading fallback type.
        var parsedMessage: ParsedMIDIMessage? {
            guard let data2 else { return nil }
            switch status & 0xF0 {
            case 0x80, 0x90, 0xB0, 0xE0:
                return MIDIMessageParsing.parse([status, data1, data2])
            default:
                return nil
            }
        }
    }

    private enum DataByteResult {
        case byte(UInt8)
        case malformed
        case truncated
    }

    /// Emits every complete channel-voice message in one packet payload, in
    /// stream order. Malformed input is dropped and parsing resumes at the
    /// next status byte without ever reading beyond `bytes.count`.
    static func parse(
        _ bytes: UnsafeRawBufferPointer,
        onMessage: (Message) -> Void
    ) {
        var index = 0
        let count = bytes.count
        var sysExActive = false

        while index < count {
            let byte = bytes[index]

            // Realtime messages may legally occur anywhere, including in the
            // middle of another message, and never affect framing state.
            if byte >= 0xF8 {
                index += 1
                continue
            }
            if sysExActive {
                if byte == 0xF7 { sysExActive = false }
                index += 1
                continue
            }
            if byte == 0xF0 {
                sysExActive = true
                index += 1
                continue
            }
            if byte >= 0xF1 {
                // ScratchLab does not consume System Common messages. Skip
                // their status bytes without guessing lengths or misaligning
                // a later channel-voice status.
                index += 1
                continue
            }
            if byte >= 0x80 {
                index += 1
                if let message = readData(bytes, &index, count, status: byte) {
                    onMessage(message)
                }
                continue
            }

            // Bare data cannot use running status in a MIDIPacket.
            index += 1
        }
    }

    private static func readData(
        _ bytes: UnsafeRawBufferPointer,
        _ index: inout Int,
        _ count: Int,
        status: UInt8
    ) -> Message? {
        let type = status & 0xF0
        let needsTwoDataBytes = !(type == 0xC0 || type == 0xD0)

        guard case .byte(let data1) = nextDataByte(bytes, &index, count) else {
            return nil
        }
        guard needsTwoDataBytes else {
            return Message(status: status, data1: data1, data2: nil)
        }
        guard case .byte(let data2) = nextDataByte(bytes, &index, count) else {
            return nil
        }
        return Message(status: status, data1: data1, data2: data2)
    }

    private static func nextDataByte(
        _ bytes: UnsafeRawBufferPointer,
        _ index: inout Int,
        _ count: Int
    ) -> DataByteResult {
        while index < count {
            let byte = bytes[index]
            if byte >= 0xF8 {
                index += 1
                continue
            }
            if byte >= 0x80 {
                return .malformed
            }
            index += 1
            return .byte(byte)
        }
        return .truncated
    }
}
