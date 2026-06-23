import Foundation

// Rane controller detection and partial stubs.
// Source policy: detection-only unless a verified MIDI source exists.
// Do NOT claim official support, endorsement, or affiliation with Rane LLC / inMusic.

enum RaneControllerProfiles {

    static var stubs: [ControllerProfile] {
        [
            twelve_mkii,
            twelve,
            one_mkii,
            one,
            four,
            performer,
            seventy_two_mkii,
            seventy_two,
            seventy,
            seventy_atrak,
            mp2015,
            ttm57mkii,
            sl2,
            sl3,
            sl4,
            sixty_eight,
            sixty_four,
            sixty_two,
        ]
    }

    // MARK: - TWELVE MKII (motorized platter; scratchPrimary if MIDI-platter path exists)

    // NOTE: TWELVE MKII is a motorized turntable controller. Its USB MIDI endpoint may be
    // visible alongside DVS/timecode audio modes. ScratchLab keeps MIDI/HID separate from
    // DVS/timecode decoding. If no platter motion data is available over MIDI in the current
    // USB mode, capture falls back to timecode/DVS.
    //
    // Rane ONE MKII has a full certified profile in MIDIHardwareRegistry (CC6 platter/CC8
    // crossfader). The TWELVE / TWELVE MKII are motorized decks — separate class.
    private static let twelve_mkii = ControllerProfile(
        id: "rane.twelve-mkii",
        internalManufacturer: "Rane",
        internalModel: "TWELVE MKII",
        publicDisplayFamily: "Motorized Platter Controller",
        matchNames: ["TWELVE MKII", "TWELVE MK2", "TWELVEMKII", "Rane TWELVE MKII"],
        deviceNameRegexes: [],
        profileKind: .motorizedPlatterController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Motorized platter; MIDI platter-position data availability depends on USB/DVS mode.",
            "Do not mix DVS/timecode audio decoding with MIDI controller profile.",
            "Requires live verification to confirm MIDI platter stream is active.",
            "Duplicate endpoint streams may appear if both MIDI and DVS modes are active.",
        ],
        sourceNotes: "Detection stub only. Exact MIDI platter messages not yet sourced from official Rane documentation.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - TWELVE (mk1)

    private static let twelve = ControllerProfile(
        id: "rane.twelve",
        internalManufacturer: "Rane",
        internalModel: "TWELVE",
        publicDisplayFamily: "Motorized Platter Controller",
        matchNames: ["Rane TWELVE", "RANETWELVE"],
        deviceNameRegexes: [],
        profileKind: .motorizedPlatterController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Motorized platter controller. Match-name scoped to avoid colliding with TWELVE MKII."
        ],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - ONE MKII (has CC6 platter + CC8 crossfader in MIDIHardwareRegistry)

    // The MIDIHardwareRegistry has the full certified binding-list for Rane ONE / ONE MKII.
    // This catalog stub provides device-class and public-display metadata for the broader
    // controller detection system. It is intentionally detectionOnly here — scoring comes
    // from the MIDIHardwareRegistry certified profile, not from this catalog stub.
    private static let one_mkii = ControllerProfile(
        id: "rane.one-mkii",
        internalManufacturer: "Rane",
        internalModel: "ONE MKII",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["ONE MKII", "ONE MK2", "RANE ONE MKII", "Rane ONE MKII"],
        deviceNameRegexes: [],
        profileKind: .twoChannelBattleController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .highOfficial,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Full binding-list is maintained in MIDIHardwareRegistry (.raneOneSeed).",
            "Catalog stub is detection/display only; do not duplicate the binding-list here."
        ],
        sourceNotes: "CC6 platter (±1 ring counter) and CC8 crossfader verified via MIDIHardwareRegistry.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - ONE (mk1)

    private static let one = ControllerProfile(
        id: "rane.one",
        internalManufacturer: "Rane",
        internalModel: "ONE",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["RANE ONE", "Rane ONE"],
        deviceNameRegexes: [],
        profileKind: .twoChannelBattleController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .highOfficial,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: [
            "Full binding-list is maintained in MIDIHardwareRegistry (.raneOneSeed).",
            "Match-name deliberately short to avoid collision with ONE MKII."
        ],
        sourceNotes: "Binding-list exists in MIDIHardwareRegistry.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - FOUR

    private static let four = ControllerProfile(
        id: "rane.four",
        internalManufacturer: "Rane",
        internalModel: "FOUR",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["Rane FOUR", "RANE FOUR"],
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

    // MARK: - PERFORMER

    private static let performer = ControllerProfile(
        id: "rane.performer",
        internalManufacturer: "Rane",
        internalModel: "PERFORMER",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["Rane PERFORMER", "RANE PERFORMER"],
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

    // MARK: - SEVENTY-TWO MKII (battle mixer; fader-primary)

    private static let seventy_two_mkii = ControllerProfile(
        id: "rane.seventy-two-mkii",
        internalManufacturer: "Rane",
        internalModel: "SEVENTY-TWO MKII",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["SEVENTY-TWO MKII", "SEVENTY TWO MKII", "72 MKII", "SEVENTYTWOMKII",
                     "Rane SEVENTY-TWO MKII", "Rane Seventy-Two MKII"],
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
        assumptions: ["Battle mixer; no onboard platter. Crossfader MIDI not yet sourced."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - SEVENTY-TWO

    private static let seventy_two = ControllerProfile(
        id: "rane.seventy-two",
        internalManufacturer: "Rane",
        internalModel: "SEVENTY-TWO",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["SEVENTY-TWO", "SEVENTY TWO", "Rane SEVENTY-TWO"],
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
        sourceNotes: "Detection stub only. Note: match-names scoped to avoid collision with MKII.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - SEVENTY

    private static let seventy = ControllerProfile(
        id: "rane.seventy",
        internalManufacturer: "Rane",
        internalModel: "SEVENTY",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["Rane SEVENTY", "RANE SEVENTY"],
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

    // MARK: - SEVENTY A-TRAK

    private static let seventy_atrak = ControllerProfile(
        id: "rane.seventy-atrak",
        internalManufacturer: "Rane",
        internalModel: "SEVENTY A-TRAK",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["SEVENTY A-TRAK", "SEVENTY ATRAK"],
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

    // MARK: - MP2015

    private static let mp2015 = ControllerProfile(
        id: "rane.mp2015",
        internalManufacturer: "Rane",
        internalModel: "MP2015",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["MP2015", "Rane MP2015"],
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

    // MARK: - TTM57mkII

    private static let ttm57mkii = ControllerProfile(
        id: "rane.ttm57mkii",
        internalManufacturer: "Rane",
        internalModel: "TTM57mkII",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["TTM57mkII", "TTM57 mkII", "TTM57MK2", "Rane TTM57"],
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

    // MARK: - SL2 / SL3 / SL4 (DVS interfaces; faderPrimary at best)

    private static let sl2 = ControllerProfile(
        id: "rane.sl2",
        internalManufacturer: "Rane",
        internalModel: "SL2",
        publicDisplayFamily: "Detected MIDI Device",
        matchNames: ["Rane SL2", "SL2"],
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
        assumptions: ["DVS interface; primary use is timecode audio. MIDI control surface usefulness not confirmed."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    private static let sl3 = ControllerProfile(
        id: "rane.sl3",
        internalManufacturer: "Rane",
        internalModel: "SL3",
        publicDisplayFamily: "Detected MIDI Device",
        matchNames: ["Rane SL3", "SL3"],
        deviceNameRegexes: [],
        profileKind: .battleMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 3,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: ["DVS interface."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    private static let sl4 = ControllerProfile(
        id: "rane.sl4",
        internalManufacturer: "Rane",
        internalModel: "SL4",
        publicDisplayFamily: "Detected MIDI Device",
        matchNames: ["Rane SL4", "SL4"],
        deviceNameRegexes: [],
        profileKind: .battleMixer,
        deviceClass: .faderPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 0,
        bindings: [],
        verificationSteps: [],
        assumptions: ["DVS interface."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Sixty-Eight / Sixty-Four / Sixty-Two

    private static let sixty_eight = ControllerProfile(
        id: "rane.sixty-eight",
        internalManufacturer: "Rane",
        internalModel: "Sixty-Eight",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["Sixty-Eight", "Sixty Eight", "SixtyEight", "68"],
        deviceNameRegexes: [],
        profileKind: .battleMixer,
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

    private static let sixty_four = ControllerProfile(
        id: "rane.sixty-four",
        internalManufacturer: "Rane",
        internalModel: "Sixty-Four",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["Sixty-Four", "Sixty Four", "SixtyFour"],
        deviceNameRegexes: [],
        profileKind: .battleMixer,
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

    private static let sixty_two = ControllerProfile(
        id: "rane.sixty-two",
        internalManufacturer: "Rane",
        internalModel: "Sixty-Two",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["Sixty-Two", "Sixty Two", "SixtyTwo"],
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
