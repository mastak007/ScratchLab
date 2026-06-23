import Foundation

// Reloop controller, turntable, and mixer stubs.
// Source policy: detection-only unless a verified official or open-source mapping is cited.
// Secondary sources (Mixxx, VirtualDJ, GitHub) are acceptable but must be marked
// sourceConfidence: .mediumOpenSource until live verification confirms them.
// Do NOT claim official support, endorsement, or affiliation with Reloop.

enum ReloopProfiles {

    static var stubs: [ControllerProfile] {
        [
            mixon8pro,
            mixon4,
            ready,
            buddy,
            beatpad2,
            terminalMix8,
            terminalMix4,
            jockey3Master,
            jockey3Remix,
            beatmix2,
            beatmix4,
            beatmix4mk2,
            mixtour,
            mixtourPro,
            touch,
            neon,
            rp8000mk2,
            rp8000,
            rp7000mk2,
            rmx95,
            rmx90dvs,
            rmx60,
            elite,
        ]
    }

    // MARK: - Mixon 8 Pro

    private static let mixon8pro = ControllerProfile(
        id: "reloop.mixon-8-pro",
        internalManufacturer: "Reloop",
        internalModel: "Mixon 8 Pro",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Mixon 8 Pro", "Mixon8Pro", "Reloop Mixon 8"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only. Check Reloop support pages and Mixxx/VirtualDJ for MIDI map.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Mixon 4

    private static let mixon4 = ControllerProfile(
        id: "reloop.mixon-4",
        internalManufacturer: "Reloop",
        internalModel: "Mixon 4",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Mixon 4", "Mixon4", "Reloop Mixon 4"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only. Mixxx mapping exists as secondary source.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Ready

    private static let ready = ControllerProfile(
        id: "reloop.ready",
        internalManufacturer: "Reloop",
        internalModel: "Ready",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Reloop Ready"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Buddy

    private static let buddy = ControllerProfile(
        id: "reloop.buddy",
        internalManufacturer: "Reloop",
        internalModel: "Buddy",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Reloop Buddy"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Beatpad 2

    private static let beatpad2 = ControllerProfile(
        id: "reloop.beatpad-2",
        internalManufacturer: "Reloop",
        internalModel: "Beatpad 2",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Beatpad 2", "Beatpad2", "Reloop Beatpad 2"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Terminal Mix 8

    private static let terminalMix8 = ControllerProfile(
        id: "reloop.terminal-mix-8",
        internalManufacturer: "Reloop",
        internalModel: "Terminal Mix 8",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Terminal Mix 8", "TerminalMix8", "Reloop Terminal Mix 8"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Terminal Mix 4

    private static let terminalMix4 = ControllerProfile(
        id: "reloop.terminal-mix-4",
        internalManufacturer: "Reloop",
        internalModel: "Terminal Mix 4",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Terminal Mix 4", "TerminalMix4", "Reloop Terminal Mix 4"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Jockey 3 Master Edition

    private static let jockey3Master = ControllerProfile(
        id: "reloop.jockey-3-master",
        internalManufacturer: "Reloop",
        internalModel: "Jockey 3 Master Edition",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["Jockey 3 Master", "Jockey3 Master"],
        deviceNameRegexes: [],
        profileKind: .twoChannelBattleController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Jockey 3 Remix

    private static let jockey3Remix = ControllerProfile(
        id: "reloop.jockey-3-remix",
        internalManufacturer: "Reloop",
        internalModel: "Jockey 3 Remix",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Jockey 3 Remix", "Jockey3 Remix"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Beatmix 2

    private static let beatmix2 = ControllerProfile(
        id: "reloop.beatmix-2",
        internalManufacturer: "Reloop",
        internalModel: "Beatmix 2",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Beatmix 2", "Beatmix2"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Beatmix 4

    private static let beatmix4 = ControllerProfile(
        id: "reloop.beatmix-4",
        internalManufacturer: "Reloop",
        internalModel: "Beatmix 4",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Beatmix 4"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only. Note: match-name scoped to avoid collision with Beatmix 4 MK2.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Beatmix 4 MK2

    private static let beatmix4mk2 = ControllerProfile(
        id: "reloop.beatmix-4-mk2",
        internalManufacturer: "Reloop",
        internalModel: "Beatmix 4 MK2",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Beatmix 4 MK2", "Beatmix4 MK2", "Beatmix 4 MK2"],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Mixtour

    private static let mixtour = ControllerProfile(
        id: "reloop.mixtour",
        internalManufacturer: "Reloop",
        internalModel: "Mixtour",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Reloop Mixtour"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only. Note: scoped to avoid collision with Mixtour Pro.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Mixtour Pro

    private static let mixtourPro = ControllerProfile(
        id: "reloop.mixtour-pro",
        internalManufacturer: "Reloop",
        internalModel: "Mixtour Pro",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Mixtour Pro", "MixtourPro"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Touch

    private static let touch = ControllerProfile(
        id: "reloop.touch",
        internalManufacturer: "Reloop",
        internalModel: "Touch",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Reloop Touch"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Neon

    private static let neon = ControllerProfile(
        id: "reloop.neon",
        internalManufacturer: "Reloop",
        internalModel: "Neon",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["Reloop Neon"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .transportPadsOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: ["Pad/button-focused device; no platter. Transport/pads only."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RP-8000 MK2 (MIDI-capable turntable)

    // The RP-8000 / RP-8000 MK2 is a DJ turntable with MIDI buttons and pads.
    // The platter itself is a standard turntable motor — platter-position data is NOT
    // transmitted over MIDI. ScratchLab would use DVS/timecode audio for platter capture.
    // MIDI buttons/pads may be useful for transport/pad control only.
    private static let rp8000mk2 = ControllerProfile(
        id: "reloop.rp-8000-mk2",
        internalManufacturer: "Reloop",
        internalModel: "RP-8000 MK2",
        publicDisplayFamily: "Turntable",
        matchNames: ["RP-8000 MK2", "RP8000 MK2", "RP-8000MK2"],
        deviceNameRegexes: [],
        profileKind: .turntable,
        deviceClass: .transportPadsOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Turntable platter does not transmit MIDI. Use DVS/timecode audio for platter capture.",
            "MIDI buttons and performance pads may be usable for transport/pad control only.",
        ],
        sourceNotes: "Detection stub only. RP-8000 MK2 has MIDI-capable performance pads but no MIDI platter stream.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RP-8000 (mk1)

    private static let rp8000 = ControllerProfile(
        id: "reloop.rp-8000",
        internalManufacturer: "Reloop",
        internalModel: "RP-8000",
        publicDisplayFamily: "Turntable",
        matchNames: ["RP-8000"],
        deviceNameRegexes: [],
        profileKind: .turntable,
        deviceClass: .transportPadsOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Turntable platter does not transmit MIDI. Match-name scoped to avoid RP-8000 MK2 collision."
        ],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RP-7000 MK2 (detection only — MIDI-capability unclear)

    private static let rp7000mk2 = ControllerProfile(
        id: "reloop.rp-7000-mk2",
        internalManufacturer: "Reloop",
        internalModel: "RP-7000 MK2",
        publicDisplayFamily: "Turntable",
        matchNames: ["RP-7000 MK2", "RP7000 MK2", "RP-7000MK2"],
        deviceNameRegexes: [],
        profileKind: .turntable,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: ["No confirmed MIDI control path documented. Detection only."],
        sourceNotes: "Detection stub only. MIDI-capability for RP-7000 MK2 not confirmed in public documentation.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RMX-95 (mixer)

    private static let rmx95 = ControllerProfile(
        id: "reloop.rmx-95",
        internalManufacturer: "Reloop",
        internalModel: "RMX-95",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["RMX-95", "RMX95"],
        deviceNameRegexes: [],
        profileKind: .djMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RMX-90 DVS

    private static let rmx90dvs = ControllerProfile(
        id: "reloop.rmx-90-dvs",
        internalManufacturer: "Reloop",
        internalModel: "RMX-90 DVS",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["RMX-90 DVS", "RMX90 DVS", "RMX-90DVS"],
        deviceNameRegexes: [],
        profileKind: .djMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: ["DVS-capable mixer; timecode audio is separate from MIDI profile."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - RMX-60

    private static let rmx60 = ControllerProfile(
        id: "reloop.rmx-60",
        internalManufacturer: "Reloop",
        internalModel: "RMX-60",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["RMX-60", "RMX60"],
        deviceNameRegexes: [],
        profileKind: .djMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 6,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Elite (mixer)

    private static let elite = ControllerProfile(
        id: "reloop.elite",
        internalManufacturer: "Reloop",
        internalModel: "Elite",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["Reloop Elite"],
        deviceNameRegexes: [],
        profileKind: .battleMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )
}
