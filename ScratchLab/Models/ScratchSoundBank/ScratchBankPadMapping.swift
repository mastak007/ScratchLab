import Foundation

// MARK: - Scratch Loop Mode

enum ScratchLoopMode: String, Codable, CaseIterable, Equatable {
    case none
    case loop
    case pingPong
}

// MARK: - Pad Mapping Enums

enum RanePadMode: String, Codable, CaseIterable, Equatable {
    case hotCue
    case sampler
    case savedLoop
    case roll
    case smallPad
}

enum PadTriggerMode: String, Codable, CaseIterable, Equatable {
    case oneShot
    case cueStart
    case holdToPlay
    case toggleLoop
    case resetToCue
}

enum PadConflictPolicy: String, Codable, CaseIterable, Equatable {
    // For use only when Serato is not running.
    case scratchLabOnly
    // ScratchLab triggers; Serato may also fire — documented dual-trigger risk.
    case listenOnly
    // ScratchLab mirrors the Serato hot cue at the same slot.
    case mirrorSerato
    case disabled
}

// MARK: - ScratchBankPadMapping

struct ScratchBankPadMapping: Equatable {
    let controllerProfileID: String
    let deck: Int?
    let padIndex: Int
    let padMode: RanePadMode
    let midiChannel: UInt8
    let midiCC: UInt8
    let assignedSampleID: String
    let triggerMode: PadTriggerMode
    let conflictPolicy: PadConflictPolicy
    let verificationRequired: Bool
    let sourceNotes: String

    // Always false at the model layer.
    // Scoring integration is gated on live hardware verification and Slice 5 approval.
    var canFeedScoring: Bool { false }
}

// MARK: - Rane ONE MK2 Default Pad Mapping Catalog

// Source: RANE One MK2.djayMidiMapping (djay Pro MIDI mapping archive, 2026-06-24).
// sourceConfidence: highThirdPartyMapping.
// All entries carry verificationRequired = true and conflictPolicy = .listenOnly until
// live hardware pad capture confirms channel/CC values on real hardware.
enum ScratchBankPadMappingCatalog {

    static let raneOneMKII: [ScratchBankPadMapping] =
        deck1LargePads + deck2LargePads + deck1ShiftPads + deck2ShiftPads
        + deck1SmallPads + deck2SmallPads

    // Deck 1 large pads (hot cue / sampler modes): ch=4 CC 20–27
    static let deck1LargePads: [ScratchBankPadMapping] = (0..<8).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 1,
            padIndex: i,
            padMode: .hotCue,
            midiChannel: 4,
            midiCC: UInt8(20 + i),
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; highThirdPartyMapping; unverified"
        )
    }

    // Deck 2 large pads: ch=5 CC 20–27
    static let deck2LargePads: [ScratchBankPadMapping] = (0..<8).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: i,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: UInt8(20 + i),
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; highThirdPartyMapping; unverified"
        )
    }

    // Deck 1 shifted/clear pads: ch=4 CC 28–35
    static let deck1ShiftPads: [ScratchBankPadMapping] = (0..<8).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 1,
            padIndex: i,
            padMode: .hotCue,
            midiChannel: 4,
            midiCC: UInt8(28 + i),
            assignedSampleID: "",
            triggerMode: .resetToCue,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; Shift/Clear pads; highThirdPartyMapping; unverified"
        )
    }

    // Deck 2 shifted/clear pads: ch=5 CC 28–35
    static let deck2ShiftPads: [ScratchBankPadMapping] = (0..<8).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: i,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: UInt8(28 + i),
            assignedSampleID: "",
            triggerMode: .resetToCue,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; Shift/Clear pads; highThirdPartyMapping; unverified"
        )
    }

    // Deck 1 small 4-pad strip: ch=4 CC 100–103
    static let deck1SmallPads: [ScratchBankPadMapping] = (0..<4).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 1,
            padIndex: i,
            padMode: .smallPad,
            midiChannel: 4,
            midiCC: UInt8(100 + i),
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; small pad strip; highThirdPartyMapping; unverified"
        )
    }

    // Deck 2 small 4-pad strip: ch=5 CC 100–103
    static let deck2SmallPads: [ScratchBankPadMapping] = (0..<4).map { i in
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: i,
            padMode: .smallPad,
            midiChannel: 5,
            midiCC: UInt8(100 + i),
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: true,
            sourceNotes: "djay Pro RANE One MK2 mapping; small pad strip; highThirdPartyMapping; unverified"
        )
    }
}
