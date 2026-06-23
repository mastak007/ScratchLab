import Foundation

// Rane controller detection and partial stubs.
// Source policy: detection-only unless a verified MIDI source exists.
// Do NOT claim official support, endorsement, or affiliation with Rane LLC / inMusic.

enum RaneControllerProfiles {

    /// Detection-only stubs (no sourced bindings yet).
    static var stubs: [ControllerProfile] {
        [
            twelve_mkii,
            twelve,
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

    /// Partial profiles sourced from third-party mapping evidence; require live verification.
    static var partialProfiles: [ControllerProfile] {
        [one_mkii]
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

    // MARK: - ONE MKII (partial — djay mapping evidence + MIDIHardwareRegistry platter)
    //
    // Crossfader (CC8) and line volumes (CC28) are sourced from the djay Pro MIDI mapping
    // archive (RANE One MK2.djayMidiMapping, Midi_Mapping_Controllers.zip).
    // turntable.speed (CC9) is the tempo/playback speed fader — NOT the scratch platter delta.
    // The verified CC6 ring-counter platter delta lives exclusively in MIDIHardwareRegistry.
    //
    // Channel discrepancy: djay maps the crossfader at ch=15; ScratchLab's live-verified
    // data uses ch=0. The djay channel is preserved here as sourced evidence; live
    // verification must confirm the effective MIDI channel before scoring is enabled.
    private static let one_mkii = ControllerProfile(
        id: "rane.one-mkii",
        internalManufacturer: "Rane",
        internalModel: "ONE MKII",
        publicDisplayFamily: "Motorized Platter Controller",
        matchNames: ["ONE MKII", "ONE MK2", "RANE ONE MKII", "Rane ONE MKII",
                     "Rane ONE MK2", "RANE ONE MK2"],
        deviceNameRegexes: [],
        profileKind: .motorizedPlatterController,
        deviceClass: .scratchPrimary,
        mappingStatus: .partial,
        sourceConfidence: .highThirdPartyMapping,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: one_mkii_bindings,
        verificationSteps: one_mkii_verificationSteps,
        assumptions: [
            "Motorized platter scratch delta (CC6 ring counter, ~3932 steps/rev) is live-verified in MIDIHardwareRegistry (.raneOneSeed) — not duplicated here.",
            "Crossfader candidate: djay mapping ch=15 CC8. ScratchLab live-verified binding is CC8 ch=0. Channel discrepancy must be resolved by live verification before scoring is enabled.",
            "Channel volume faders: CC28 on ch=0 (deck 1) and ch=1 (deck 2) per djay mapping.",
            "turntable.speed (CC9 per deck) is the tempo/playback speed fader — NOT the platter scratch delta. Do not use for scratch scoring.",
            "No platter scratch-delta address was found in the djay mapping; djay handles the motorized platter internally without a named keyPath.",
            "Do not feed scoring until live verification confirms channel, direction, and rate.",
        ],
        sourceNotes: "Partial profile sourced from djay Pro MIDI mapping archive. " +
            "sourceType: uploadedDjayMapping. sourceConfidence: highThirdPartyMapping. " +
            "sourceArchive: Midi_Mapping_Controllers.zip. sourceFile: RANE One MK2.djayMidiMapping. " +
            "Extracted 2026-06-24. Crossfader CC8, line volumes CC28 confirmed. " +
            "Platter delta (CC6 ring counter) verified separately in MIDIHardwareRegistry.",
        sourceURLs: [],
        lastCheckedDate: "2026-06-24"
    )

    private static let one_mkii_bindings: [ControllerBinding] = [
        // Crossfader — djay mapping: mixer.crossfade, ch=15, CC8 (Fader/absolute type).
        // Note: djay maps ch=15; ScratchLab live-verified crossfader is CC8 ch=0.
        // Channel discrepancy needs live verification. CC number (8) agrees with verified data.
        ControllerBinding(roleKey: "crossfader", deck: nil, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: 15, cc: 8)),

        // Channel (line) volume faders — djay mapping: mixer.externalLineVolume1/2, CC28.
        ControllerBinding(roleKey: "channelVolume", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 28)),
        ControllerBinding(roleKey: "channelVolume", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 28)),

        // Speed/tempo fader — djay mapping: turntable.speed, CC9 per deck.
        // THIS IS NOT the scratch platter delta. It is the tempo/playback speed control.
        // Kept as a metadata candidate only; roleKey "speedCandidate" prevents accidental
        // use as a scratch-motion source before live verification.
        ControllerBinding(roleKey: "speedCandidate", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 9)),
        ControllerBinding(roleKey: "speedCandidate", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 9)),

        // Pitch bend buttons (hardware nudge buttons, NOT motorized platter).
        ControllerBinding(roleKey: "pitchBendPlus",  deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 11)),
        ControllerBinding(roleKey: "pitchBendMinus", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 12)),
        ControllerBinding(roleKey: "pitchBendPlus",  deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 11)),
        ControllerBinding(roleKey: "pitchBendMinus", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 12)),
    ]

    private static let one_mkii_verificationSteps: [ControllerVerificationStep] = [
        .init(stepID: "xfader_left",
              instruction: "Move the crossfader fully to the left.",
              expectedControl: "crossfader", required: true),
        .init(stepID: "xfader_right",
              instruction: "Move the crossfader fully to the right.",
              expectedControl: "crossfader", required: true),
        .init(stepID: "ch_vol_1",
              instruction: "Move Channel 1 volume fader from bottom to top.",
              expectedControl: "channelVolume.deck1", required: false),
        .init(stepID: "ch_vol_2",
              instruction: "Move Channel 2 volume fader from bottom to top.",
              expectedControl: "channelVolume.deck2", required: false),
        .init(stepID: "platter_fwd_left",
              instruction: "Rotate the left platter forward — confirm CC6 ring-counter events arrive.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_bwd_left",
              instruction: "Rotate the left platter backward — confirm direction is inverted.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_fwd_right",
              instruction: "Rotate the right platter forward.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "platter_bwd_right",
              instruction: "Rotate the right platter backward.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "xfader_channel",
              instruction: "Confirm which MIDI channel the crossfader arrives on (expected CC8; djay mapping shows ch=15, live data shows ch=0).",
              expectedControl: "crossfader.channel", required: true),
    ]

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
