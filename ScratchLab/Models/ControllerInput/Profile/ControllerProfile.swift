import Foundation

// MARK: - Status / Confidence

enum ControllerMappingStatus: String, Codable, CaseIterable, Equatable {
    case complete
    case partial
    case detectionOnly
    case unsupported
    case liveVerifiedLocalOnly
}

enum ControllerSourceConfidence: String, Codable, CaseIterable, Equatable {
    case highOfficial
    case mediumOpenSource
    case lowCommunity
    case liveCaptureOnly
    case unknown
}

enum ControllerDeviceClass: String, Codable, Equatable {
    // Has platter/jog MIDI data suitable for scratch-motion scoring.
    case scratchPrimary
    // Has crossfader/channel fader data; no reliable platter source.
    case faderPrimary
    // Buttons/pads only; no scratch-motion source.
    case transportPadsOnly
    // Can be detected; mappings not known enough to use.
    case detectionOnly
    // No MIDI/HID control path suitable for ScratchLab.
    case unsupported
}

enum ControllerProfileKind: String, Codable, Equatable {
    case twoChannelBattleController
    case fourChannelPerformanceController
    case motorizedPlatterController
    case mediaPlayer
    case standaloneDJSystem
    case battleMixer
    case djMixer
    case turntable
    case compactDJController
    case twoChannelDVSMixer
}

// MARK: - Mapping Primitives

enum MappingPrimitive: Codable, Equatable, Hashable {
    // Momentary button: note on / off.
    case noteMomentary(channel: UInt8, note: UInt8, onValue: UInt8, offValue: UInt8)
    // 7-bit absolute CC (0…127), normalized to 0.0…1.0.
    case ccAbsolute7(channel: UInt8, cc: UInt8)
    // 14-bit CC pair; raw range 0…16383, normalized to 0.0…1.0.
    case cc14(channel: UInt8, msbCC: UInt8, lsbCC: UInt8)
    // Relative delta: center = 0x40; 0x41→+1, 0x3F→-1, 0x42→+2, etc.
    case relativeSignedOffset64(channel: UInt8, cc: UInt8)
    // Relative two's complement: 1…63 positive, 65…127 negative.
    case relativeTwosComplement7(channel: UInt8, cc: UInt8)
    // High-resolution jog: paired MSB + LSB CC stream.
    case highResolutionJog(channel: UInt8, msbCC: UInt8, lsbCC: UInt8)
    // Motorized platter: movement CC + optional touch note.
    case motorizedPlatterRelative(channel: UInt8, movementCC: UInt8, touchNote: UInt8?)
    // Touch strip CC.
    case touchStrip(channel: UInt8, cc: UInt8)
    // Needle-search strip: metadata only.
    case needleSearchStrip(channel: UInt8, cc: UInt8)
    // Deck layer selection note.
    case deckLayerSelect(channel: UInt8, note: UInt8)
    // Pad grid: base channel, note offset, dimensions.
    case padGrid(baseChannel: UInt8, noteOffset: UInt8, rows: Int, columns: Int)
    // LED / pad feedback note (output only; does not block input capture).
    case ledOutNote(channel: UInt8, note: UInt8)
    // HID candidate: detection only until a HID parser is implemented.
    case hidCandidate(usagePage: UInt16, usage: UInt16)

    // MARK: Decoder helpers (pure, side-effect free)

    /// Relative signed offset 64: center = 0x40.
    /// 0x41→+1, 0x42→+2, 0x3F→-1, 0x3E→-2, 0x40→0.
    static func decodeRelativeSignedOffset64(_ value: UInt8) -> Int {
        Int(value) - 0x40
    }

    /// Relative two's complement 7-bit.
    /// 1…63 → +1…+63; 65…127 → -63…-1; 0 or 64 → 0.
    static func decodeTwosComplement7(_ value: UInt8) -> Int {
        let v = Int(value)
        if v == 0 || v == 64 { return 0 }
        if v > 0 && v < 64 { return v }
        return v - 128
    }

    /// Combine MSB and LSB into a 14-bit value (0…16383).
    static func decode14bit(msb: UInt8, lsb: UInt8) -> Int {
        (Int(msb) << 7) | Int(lsb)
    }

    static func normalize14bit(_ raw: Int) -> Double {
        Double(raw) / 16383.0
    }

    static func normalize7bit(_ raw: UInt8) -> Double {
        Double(raw) / 127.0
    }
}

// MARK: - Normalized Events

struct ControllerMotionEvent {
    let profileID: String
    let deviceID: String
    let deck: Int
    let physicalDeckSide: PhysicalDeckSide
    let source: MotionSource
    let deltaSteps: Int
    let rawValue: UInt8
    let timestamp: Double
    let touchActive: Bool
    let trusted: Bool

    enum PhysicalDeckSide: String { case left, right }
    enum MotionSource: String {
        case platterTop
        case jogSide
        case motorizedPlatter
        case touchStrip
    }
}

struct ControllerFaderEvent {
    let profileID: String
    let deviceID: String
    let control: FaderControl
    let deck: Int?
    let normalizedPosition: Double
    let raw7: UInt8?
    let raw14: Int?
    let timestamp: Double
    let trusted: Bool

    enum FaderControl: String { case crossfader, channelFader, tempo }
}

struct ControllerButtonEvent {
    let profileID: String
    let deviceID: String
    let control: ButtonControl
    let deck: Int?
    let isPressed: Bool
    let value: UInt8
    let timestamp: Double
    let trusted: Bool

    enum ButtonControl: String {
        case playPause, cue, shift, jogTouch, deckSelect, pad, vinyl, unknown
    }
}

// MARK: - ControllerBinding

/// A single binding tying a named role to a mapping primitive on a specific deck/side.
struct ControllerBinding: Equatable, Hashable {
    let roleKey: String
    let deck: Int?
    let physicalSide: String?
    let primitive: MappingPrimitive
}

// MARK: - Verification

struct ControllerVerificationStep: Equatable {
    let stepID: String
    let instruction: String
    let expectedControl: String
    let required: Bool
}

struct ControllerVerificationResult: Equatable {
    let profileID: String
    let deviceName: String
    let verifiedAt: Date
    let platterLeftForwardOK: Bool
    let platterLeftBackwardOK: Bool
    let platterRightForwardOK: Bool
    let platterRightBackwardOK: Bool
    let jogTouchLeftOK: Bool
    let jogTouchRightOK: Bool
    let crossfaderOK: Bool
    let channelFader1OK: Bool
    let channelFader2OK: Bool
    let playPauseOK: Bool
    let cueOK: Bool
    let padOK: Bool
    let deck1OpenSide: String?
    let deck2OpenSide: String?
    let warnings: [String]
    let trusted: Bool
}

// MARK: - ControllerProfile

struct ControllerProfile: Identifiable, Equatable {
    // Identity (internal only)
    let id: String
    let internalManufacturer: String
    let internalModel: String
    // Legal-safe public label shown in app UI.
    let publicDisplayFamily: String

    // Detection
    let matchNames: [String]
    let deviceNameRegexes: [String]

    // Classification
    let profileKind: ControllerProfileKind
    let deviceClass: ControllerDeviceClass

    // Status / confidence
    let mappingStatus: ControllerMappingStatus
    let sourceConfidence: ControllerSourceConfidence
    let verificationRequired: Bool

    // Capabilities
    let deckCount: Int
    let physicalDeckCount: Int

    // Bindings
    let bindings: [ControllerBinding]

    // Guided verification
    let verificationSteps: [ControllerVerificationStep]

    // Provenance metadata
    let assumptions: [String]
    let sourceNotes: String
    let sourceURLs: [String]
    let lastCheckedDate: String

    // MARK: Computed helpers

    var isFullySourced: Bool {
        sourceConfidence == .highOfficial || sourceConfidence == .mediumOpenSource
    }

    /// True only when the profile has non-diagnostic bindings and is verified by a user session.
    var canFeedScoringAfterVerification: Bool {
        mappingStatus == .complete || mappingStatus == .partial || mappingStatus == .liveVerifiedLocalOnly
    }

    func binding(roleKey: String, deck: Int? = nil) -> ControllerBinding? {
        bindings.first { $0.roleKey == roleKey && $0.deck == deck }
    }

    /// Returns true when the endpoint name (lowercased) contains any match name fragment.
    func matches(endpointName: String) -> Bool {
        let lower = endpointName.lowercased()
        return matchNames.contains { lower.contains($0.lowercased()) }
    }

    static func == (lhs: ControllerProfile, rhs: ControllerProfile) -> Bool {
        lhs.id == rhs.id
    }
}
