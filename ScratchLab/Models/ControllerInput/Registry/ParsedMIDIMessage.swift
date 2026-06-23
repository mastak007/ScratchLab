import Foundation

/// Pure, device-agnostic parsed MIDI 1.0 message. Side-effect free value type used by the
/// registry layer to match bindings and count verification events. No Core MIDI, audio, or
/// playback dependency.
struct ParsedMIDIMessage: Equatable {
    /// MIDI channel 0…15.
    let channel: UInt8
    /// Decoded message kind.
    let messageType: MIDIMessageType
    /// CC number (only meaningful for Control Change).
    let controlNumber: UInt8
    /// Note number (only meaningful for Note On / Note Off).
    let noteNumber: UInt8
    /// Raw data byte 2 (value / velocity / pitch-bend LSB), for diagnostics.
    let value: UInt8
}

/// Message-type discriminator for the pure parsed-MIDI layer. Only the cases needed by the
/// registry matcher are included; SysEx, program change, aftertouch etc. are omitted
/// deliberately — the registry never matches against them.
enum MIDIMessageType: Equatable {
    case controlChange
    case pitchBend
    case noteOn
    case noteOff
}

/// Stateless MIDI 1.0 byte parser that produces a `ParsedMIDIMessage` from a 3-byte
/// short message. Not a general-purpose MIDI parser — handles only the standard
/// 3-byte channel-voice messages that the registry matcher inspects.
enum MIDIMessageParsing {
    /// Parse a 3-byte MIDI 1.0 channel-voice message into a `ParsedMIDIMessage`.
    /// Returns a best-effort result for any 3-byte sequence; does not reject
    /// malformed status bytes (the registry is diagnostic, not a validator).
    static func parse(_ bytes: [UInt8]) -> ParsedMIDIMessage {
        // Best-effort: default to CC on channel 0 if bytes are too short.
        guard bytes.count >= 3 else {
            return ParsedMIDIMessage(
                channel: 0,
                messageType: .controlChange,
                controlNumber: 0,
                noteNumber: 0,
                value: 0
            )
        }
        let status = bytes[0]
        let channel = status & 0x0F
        let messageType: MIDIMessageType
        switch status & 0xF0 {
        case 0x80: messageType = .noteOff
        case 0x90: messageType = .noteOn
        case 0xB0: messageType = .controlChange
        case 0xE0: messageType = .pitchBend
        default:   messageType = .controlChange  // best-effort fallback
        }
        return ParsedMIDIMessage(
            channel: channel,
            messageType: messageType,
            controlNumber: bytes[1],
            noteNumber: bytes[1],
            value: bytes[2]
        )
    }
}
