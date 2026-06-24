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
    /// Non-nil when this pad uses Note On/Off rather than CC.
    /// When set, `midiCC` is unused and `isNoteMapping` returns true.
    let midiNoteNumber: UInt8?
    let assignedSampleID: String
    let triggerMode: PadTriggerMode
    let conflictPolicy: PadConflictPolicy
    let verificationRequired: Bool
    let sourceNotes: String

    init(
        controllerProfileID: String,
        deck: Int?,
        padIndex: Int,
        padMode: RanePadMode,
        midiChannel: UInt8,
        midiCC: UInt8,
        midiNoteNumber: UInt8? = nil,
        assignedSampleID: String,
        triggerMode: PadTriggerMode,
        conflictPolicy: PadConflictPolicy,
        verificationRequired: Bool,
        sourceNotes: String
    ) {
        self.controllerProfileID = controllerProfileID
        self.deck = deck
        self.padIndex = padIndex
        self.padMode = padMode
        self.midiChannel = midiChannel
        self.midiCC = midiCC
        self.midiNoteNumber = midiNoteNumber
        self.assignedSampleID = assignedSampleID
        self.triggerMode = triggerMode
        self.conflictPolicy = conflictPolicy
        self.verificationRequired = verificationRequired
        self.sourceNotes = sourceNotes
    }

    /// True when this pad reports via Note On/Off (confirmed hardware).
    /// False for CC-based candidates sourced from djay mapping.
    var isNoteMapping: Bool { midiNoteNumber != nil }

    // Always false at the model layer.
    // Scoring integration is gated on live hardware verification and Slice 5 approval.
    var canFeedScoring: Bool { false }

    /// Display-friendly verification status for UI surfaces.
    /// "Pending hardware verification" when `verificationRequired`, empty otherwise.
    var verificationDisplayStatus: String {
        verificationRequired ? "Pending hardware verification" : ""
    }

    /// Concise provenance note for UI surfaces.
    /// Describes where the CC addresses came from and what remains to confirm.
    var provenanceDisplayNote: String {
        "CC addresses sourced from djay Pro mapping — confirm on real hardware"
    }
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

    // Confirmed Rane ONE MKII hardware capture: right deck pads 1–8 use Note On/Off, not CC.
    // Right deck = ch6 (MIDI Monitor 1-indexed) = channel 5 (0-indexed raw byte) = deck 2 (v1 1-indexed).
    // Deck channel pattern confirmed: right pads = ch6 (ch=5).
    // Pads 1–4 captured 2026-06-24 (initial capture).
    // Pads 5–8 captured 2026-06-24 (extended capture, same session).
    // Sample IDs for pads 5–8 not yet assigned; using "" pending sample bank extension.
    static let confirmedHardwareNotePads: [ScratchBankPadMapping] = [
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 0,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 20,
            assignedSampleID: "ahhh",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 (ch=5) note20 vel127=press, Note Off vel0=release"
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 1,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 21,
            assignedSampleID: "fresh",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note21 vel127=press, Note Off vel0=release"
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 2,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 22,
            assignedSampleID: "ah_yeah",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note22 vel127=press, Note Off vel0=release"
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 3,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 23,
            assignedSampleID: "check_it_out",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note23 vel127=press, Note Off vel0=release"
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 4,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 24,
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note24. Sample not yet assigned."
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 5,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 25,
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note25. Sample not yet assigned."
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 6,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 26,
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note26. Sample not yet assigned."
        ),
        ScratchBankPadMapping(
            controllerProfileID: "rane.one-mkii",
            deck: 2,
            padIndex: 7,
            padMode: .hotCue,
            midiChannel: 5,
            midiCC: 0,
            midiNoteNumber: 27,
            assignedSampleID: "",
            triggerMode: .oneShot,
            conflictPolicy: .listenOnly,
            verificationRequired: false,
            sourceNotes: "Confirmed right deck: Note On ch6 note27. Sample not yet assigned."
        ),
    ]
}
