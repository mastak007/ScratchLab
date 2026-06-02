import Foundation

// Pro-DJ MIDI registry layer (future-facing): how one control reports over MIDI, and
// the binding that ties a `MIDIControlRole` to that signal.
//
// Scope guardrails (deliberate):
// - Pure value types only. No Core MIDI, no audio, no playback, no UI.
// - `MIDIControlSignalType` enumerates the encodings real DJ gear uses. NRPN/RPN are
//   modelled as cases for completeness; precise multi-message NRPN decoding is future
//   work. `universalPacket` is a FUTURE-SAFE MODEL CASE for MIDI 2.0 / UMP only — this
//   slice ships no MIDI 2.0 transport and never decodes it.
// - `matches(_:)` reuses the existing pure `ParsedMIDIMessage` (device-agnostic byte
//   parsing). It does not import or touch any playback / mapper / engine code.

/// How a relative encoder encodes direction + magnitude. Real controllers vary;
/// the registry records which scheme a control uses so a decoder can be exact later.
enum MIDIRelativeEncoding: Codable, Equatable, Hashable {
    /// Two's-complement around 0 (e.g. 0x01…0x3F = +, 0x7F…0x41 = −).
    case twosComplement
    /// Sign-and-magnitude: high bit is the sign, low bits the magnitude.
    case signedBit
    /// Binary offset: a centre value (typically 0x40) means "no movement".
    case binaryOffset
    /// A wrapping ring counter of `modulus` steps; the signed step is the shortest
    /// distance on the ring (RANE ONE platter CC6 = modulus 128, ±1 per event).
    case ringCounter(modulus: Int)
}

/// How a single physical control reports over MIDI. Decoupled from the control's
/// semantic `MIDIControlRole`, so the same role can be driven by different encodings
/// across devices.
enum MIDIControlSignalType: Codable, Equatable, Hashable {
    /// A 7-bit absolute Control Change (0…127) on `number`.
    case absoluteCC(number: Int)
    /// A relative Control Change on `number` using `encoding`.
    case relativeCC(number: Int, encoding: MIDIRelativeEncoding)
    /// A 14-bit pitch-bend message.
    case pitchBend
    /// A Note On / Off on `number` (pads, buttons).
    case note(number: Int)
    /// A high-resolution 14-bit CC pair (MSB + LSB CC numbers), e.g. some 14-bit
    /// crossfaders. Both numbers are recorded; either arriving counts as activity.
    case highResCCPair(msb: Int, lsb: Int)
    /// A Non-Registered Parameter Number control (model case; precise decode is future).
    case nrpn(parameter: Int)
    /// A Registered Parameter Number control (model case; precise decode is future).
    case rpn(parameter: Int)
    /// FUTURE-SAFE MODEL CASE ONLY for MIDI 2.0 / Universal MIDI Packet. This slice
    /// ships no MIDI 2.0 transport; `statusHint` is a free-form descriptor for the
    /// eventual decoder. Never matched over the current MIDI 1.0 path.
    case universalPacket(statusHint: String)

    /// The single CC number this signal addresses, for matching/inference. Nil for
    /// signals that are not a single CC (pitch bend, note, high-res pair, NRPN/RPN, UMP).
    var primaryCCNumber: Int? {
        switch self {
        case .absoluteCC(let number), .relativeCC(let number, _):
            return number
        case .pitchBend, .note, .highResCCPair, .nrpn, .rpn, .universalPacket:
            return nil
        }
    }
}

/// Ties a semantic role to the MIDI signal that drives it on a specific controller,
/// plus the constants needed to interpret it. A `MIDIControllerProfile` is a list of
/// these — unlike the fixed platter/crossfader/pitchBend slots of the v1 profile.
struct MIDIControlBinding: Codable, Equatable, Hashable {
    /// What this control means.
    let role: MIDIControlRole
    /// How it reports over MIDI.
    let signal: MIDIControlSignalType
    /// MIDI channel 0…15 this control uses, or nil for "any / unspecified".
    let channel: Int?
    /// Ring-counter modulus for a relative platter (RANE CC6 = 128); nil otherwise.
    let ringModulus: Int?
    /// True when the control is read for diagnostics but must never drive playback
    /// (e.g. the RANE platter pitch bend, which aliases — CC6 is the driver).
    let isDiagnosticOnly: Bool
    /// Optional free-form note (provenance, quirks).
    let notes: String?

    init(
        role: MIDIControlRole,
        signal: MIDIControlSignalType,
        channel: Int? = nil,
        ringModulus: Int? = nil,
        isDiagnosticOnly: Bool = false,
        notes: String? = nil
    ) {
        self.role = role
        self.signal = signal
        self.channel = channel
        self.ringModulus = ringModulus
        self.isDiagnosticOnly = isDiagnosticOnly
        self.notes = notes
    }

    /// Whether a parsed MIDI message could be this control firing. Pure and side-effect
    /// free; used by verification/inference to count activity on an expected control.
    /// Channel is honoured only when the binding pins one. `universalPacket` never
    /// matches over the MIDI 1.0 path (it is a future model case).
    func matches(_ message: ParsedMIDIMessage) -> Bool {
        if let channel, message.channel != channel { return false }
        switch signal {
        case .absoluteCC(let number), .relativeCC(let number, _):
            return message.messageType == .controlChange && message.controlNumber == number
        case .highResCCPair(let msb, let lsb):
            return message.messageType == .controlChange
                && (message.controlNumber == msb || message.controlNumber == lsb)
        case .pitchBend:
            return message.messageType == .pitchBend
        case .note(let number):
            return (message.messageType == .noteOn || message.messageType == .noteOff)
                && message.noteNumber == number
        case .nrpn, .rpn:
            // Modelled at parameter level only. NRPN/RPN are multi-message CC sequences;
            // until a real decoder exists they MUST NOT verify against ordinary CC traffic
            // (an unrelated CC must never be mistaken for an NRPN/RPN parameter change).
            return false
        case .universalPacket:
            return false
        }
    }
}
