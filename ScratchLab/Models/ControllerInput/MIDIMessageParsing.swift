import Foundation

// Phase 1 controller-input: pure MIDI 1.0 byte parsing.
//
// Scope guardrails (deliberate):
// - Pure value types + pure functions only. No Core MIDI, no device assumptions,
//   no hard-coded CC/note numbers, no RANE ONE mapping, no Serato.
// - Interpretation NEVER mutates or discards the raw bytes; a parsed message is a
//   *derived view*. The verbatim bytes live on the originating `MIDIRawEvent`.
// - This is the unit the Controller Inspector tests exercise.

/// The category of a MIDI 1.0 message, derived from its status byte. System
/// messages (0xF0…0xFF: SysEx, common, realtime) are not channel-scoped and are
/// collapsed to `.system`; `.unknown` covers a leading data byte (e.g. running
/// status with no prior status, or a malformed fragment) that cannot be
/// interpreted standalone.
enum MIDIMessageType: String, Sendable, Equatable, Hashable, CaseIterable {
    case noteOff
    case noteOn
    case polyphonicAftertouch
    case controlChange
    case programChange
    case channelAftertouch
    case pitchBend
    case system
    case unknown

    /// Short human label for the Inspector table.
    var displayName: String {
        switch self {
        case .noteOff: return "Note Off"
        case .noteOn: return "Note On"
        case .polyphonicAftertouch: return "Poly Aftertouch"
        case .controlChange: return "Control Change"
        case .programChange: return "Program Change"
        case .channelAftertouch: return "Channel Aftertouch"
        case .pitchBend: return "Pitch Bend"
        case .system: return "System"
        case .unknown: return "Unknown"
        }
    }
}

/// A decoded, read-only view of one MIDI 1.0 message. The raw bytes that produced
/// it are kept verbatim on the owning `MIDIRawEvent`; nothing here is lossy.
struct ParsedMIDIMessage: Sendable, Equatable, Hashable {
    /// First byte of the message (the status byte, or a leading data byte for `.unknown`).
    let statusByte: UInt8
    /// Message category derived from the status byte.
    let messageType: MIDIMessageType
    /// Channel 0…15 for channel-voice messages; nil for system/unknown.
    let channel: Int?
    /// First data byte, if present.
    let data1: UInt8?
    /// Second data byte, if present.
    let data2: UInt8?

    /// CC number for a Control Change, else nil. No CC number is assumed for any device.
    var controlNumber: Int? {
        messageType == .controlChange ? data1.map(Int.init) : nil
    }

    /// Note number for Note On/Off (and Poly Aftertouch), else nil.
    var noteNumber: Int? {
        switch messageType {
        case .noteOn, .noteOff, .polyphonicAftertouch:
            return data1.map(Int.init)
        default:
            return nil
        }
    }

    /// The CC number or note number this message addresses, if any. Used by the
    /// detected-control summary to group "most active CC/note numbers".
    var controlOrNoteNumber: Int? {
        controlNumber ?? noteNumber
    }

    /// The salient value carried by the message, normalized to an Int:
    /// CC value / note velocity / poly pressure → data2; program & channel
    /// pressure → data1; pitch bend → combined 14-bit (0…16383). Nil if absent.
    var value: Int? {
        switch messageType {
        case .controlChange, .noteOn, .noteOff, .polyphonicAftertouch:
            return data2.map(Int.init)
        case .programChange, .channelAftertouch:
            return data1.map(Int.init)
        case .pitchBend:
            guard let lsb = data1, let msb = data2 else { return nil }
            return Int(lsb) | (Int(msb) << 7)
        case .system, .unknown:
            return nil
        }
    }
}

/// Pure MIDI 1.0 parsing/formatting helpers. Stateless; safe to call from any
/// thread. Makes no assumptions about which controls a device maps to.
enum MIDIMessageParsing {

    /// Parses a single MIDI 1.0 message's bytes into a `ParsedMIDIMessage`.
    /// Always retains the leading byte; never throws and never drops data.
    static func parse(_ bytes: [UInt8]) -> ParsedMIDIMessage {
        guard let status = bytes.first else {
            return ParsedMIDIMessage(statusByte: 0, messageType: .unknown, channel: nil, data1: nil, data2: nil)
        }
        let data1: UInt8? = bytes.count > 1 ? bytes[1] : nil
        let data2: UInt8? = bytes.count > 2 ? bytes[2] : nil

        // Below 0x80 there is no status byte (running status / stray data byte).
        if status < 0x80 {
            return ParsedMIDIMessage(statusByte: status, messageType: .unknown, channel: nil, data1: data1, data2: data2)
        }
        // 0xF0…0xFF are system messages: no channel nibble.
        if status >= 0xF0 {
            return ParsedMIDIMessage(statusByte: status, messageType: .system, channel: nil, data1: data1, data2: data2)
        }

        let channel = Int(status & 0x0F)
        let messageType: MIDIMessageType
        switch status & 0xF0 {
        case 0x80: messageType = .noteOff
        case 0x90: messageType = .noteOn
        case 0xA0: messageType = .polyphonicAftertouch
        case 0xB0: messageType = .controlChange
        case 0xC0: messageType = .programChange
        case 0xD0: messageType = .channelAftertouch
        case 0xE0: messageType = .pitchBend
        default: messageType = .unknown
        }
        return ParsedMIDIMessage(statusByte: status, messageType: messageType, channel: channel, data1: data1, data2: data2)
    }

    /// The number of data bytes a channel-voice / system status byte expects, or
    /// nil for variable-length messages (SysEx 0xF0). Used to split a packet that
    /// concatenates several messages into discrete ones.
    static func expectedDataByteCount(forStatus status: UInt8) -> Int? {
        guard status >= 0x80 else { return nil }
        if status >= 0xF0 {
            switch status {
            case 0xF0: return nil          // SysEx: variable, terminated by 0xF7
            case 0xF1, 0xF3: return 1       // MTC quarter frame, song select
            case 0xF2: return 2             // song position pointer
            default: return 0               // 0xF4…0xFF: tune request / realtime / EOX
            }
        }
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1           // program change, channel pressure
        default: return 2                   // note on/off, poly AT, CC, pitch bend
        }
    }

    /// Splits a Core MIDI packet's bytes (which may concatenate several messages,
    /// carry running status, or interleave realtime bytes) into discrete,
    /// individually-parseable MIDI 1.0 messages.
    ///
    /// No data byte is ever dropped. Two transformations mean the output is not a
    /// byte-identical re-slice of the input: running status is **expanded** so each
    /// message carries an explicit status byte, and realtime bytes (0xF8…0xFF),
    /// which may appear anywhere — including mid-message — are **extracted** as
    /// standalone messages. An ambiguous tail (SysEx, or leading data with no
    /// running status) is returned as a single chunk so it stays visible.
    static func splitIntoMessages(_ bytes: [UInt8]) -> [[UInt8]] {
        guard !bytes.isEmpty else { return [] }
        var messages: [[UInt8]] = []
        var index = 0
        var runningStatus: UInt8? = nil

        // Collects up to `need` data bytes (< 0x80) from `index`, emitting any
        // interleaved realtime bytes (>= 0xF8) as standalone messages and stopping
        // early if a non-realtime status byte interrupts. Advances `index`.
        func collectData(_ need: Int) -> [UInt8] {
            var data: [UInt8] = []
            while data.count < need && index < bytes.count {
                let byte = bytes[index]
                if byte >= 0xF8 {            // realtime: extract, don't consume a data slot
                    messages.append([byte])
                    index += 1
                    continue
                }
                if byte >= 0x80 { break }    // a new status byte interrupts this message
                data.append(byte)
                index += 1
            }
            return data
        }

        while index < bytes.count {
            let head = bytes[index]

            // Realtime messages are single bytes that can appear anywhere.
            if head >= 0xF8 {
                messages.append([head])
                index += 1
                continue
            }

            // SysEx: consume through the next 0xF7 (or to the end if unterminated).
            if head == 0xF0 {
                var end = index + 1
                while end < bytes.count && bytes[end] != 0xF7 { end += 1 }
                if end < bytes.count { end += 1 } // include the 0xF7 terminator
                messages.append(Array(bytes[index..<end]))
                index = end
                runningStatus = nil
                continue
            }

            // Channel-voice / system-common status byte.
            if head >= 0x80 {
                // System common (0xF1…0xF7) clears running status; channel voice sets it.
                runningStatus = head < 0xF0 ? head : nil
                guard let need = expectedDataByteCount(forStatus: head) else {
                    // Defensive: treat the remainder as one chunk rather than drop it.
                    messages.append(Array(bytes[index..<bytes.count]))
                    break
                }
                index += 1
                messages.append([head] + collectData(need))
                continue
            }

            // A data byte where a status is expected → running status, if we have one.
            if let status = runningStatus, let need = expectedDataByteCount(forStatus: status) {
                messages.append([status] + collectData(need))
                continue
            }

            // No usable running status: emit the remaining bytes as one chunk so
            // the verbatim data is preserved and visible in the Inspector.
            messages.append(Array(bytes[index..<bytes.count]))
            break
        }
        return messages
    }

    /// Formats raw bytes as space-separated uppercase hex (e.g. "B0 10 40") for
    /// the Inspector's raw-bytes column.
    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
