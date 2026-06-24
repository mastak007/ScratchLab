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
            "Deck channel pattern (MIDI Monitor 1-indexed): left continuous=ch1 (ch=0), right continuous=ch2 (ch=1), left pads=ch5 (ch=4), right pads=ch6 (ch=5).",
            "Left deck channel fader confirmed: CC28 ch1 (ch=0). 0=closed, 127=open.",
            "Left deck pitch/tempo confirmed: CC9 (MSB) + CC41 (LSB) on ch1 (ch=0), 14-bit high-res pair. Calibration (direction, travel range) needed before scoring.",
            "Left deck pads 1–8 confirmed: Note On/Off ch5 (ch=4) notes 20–27. Note On vel127=press; Note Off/vel0=release. NOT CC.",
            "Right deck pads 1–8 confirmed: Note On/Off ch6 (ch=5) notes 20–27. Pads 1–4 from earlier capture; pads 5–8 from latest capture. NOT CC.",
            "EQ/gain raw controls confirmed: CC25/24/23/22 on ch1 (left, ch=0) and ch2 (right, ch=1). " +
                "Capture order: bass=CC25, mid=CC24, highs=CC23, gain=CC22. " +
                "Labels applied as provisional; pending isolated knob confirmation per control.",
            "Crossfader: djay mapping ch=15 CC8; live-verified CC8 ch=0. Profile stores ch=0. Channel needs isolated-crossfader capture to confirm definitively.",
            "Right deck channel fader (CC28 ch=1) retained as unverified candidate — right deck fader not yet captured in isolation.",
            "Right deck pitch/tempo: CC9 ch=1 retained as unverified djay candidate. Right deck pitch not yet captured.",
            "djay CC mapping for pads (CC20–27) is entirely superseded by Note On/Off hardware captures. Do not use CC pads.",
            "Not yet captured: right channel fader, right pitch/tempo fader, play/pause, cue, load, sync, deck select, browser, crossfader full sweep, right platter (isolated), slow/backward platter movement, touch/motor state messages.",
            "Do not feed scoring until live verification confirms channel, direction, and rate per control.",
        ],
        sourceNotes: "Partial profile — combined djay Pro mapping evidence + direct MIDI Monitor hardware captures. " +
            "djay source: Midi_Mapping_Controllers.zip / RANE One MK2.djayMidiMapping (2026-06-24); sourceType: uploadedDjayMapping. " +
            "Hardware captures (MIDI Monitor, decimal format, Rane ONE MKII): " +
            "2026-06-24 initial capture: right deck pads 1–4 Note On ch6 notes 20–23 (not CC). " +
            "2026-06-24 extended capture: confirmed deck channel pattern ch1/ch2 continuous, ch5/ch6 pads; " +
            "left deck pads 1–8 ch5 notes 20–27; right deck pads 5–8 ch6 notes 24–27; " +
            "left CC28 channel fader; left CC9+CC41 14-bit pitch; left/right CC22-25 EQ/gain (capture order bass/mid/highs/gain).",
        sourceURLs: [],
        lastCheckedDate: "2026-06-24"
    )

    private static let one_mkii_bindings: [ControllerBinding] = [

        // ── Crossfader ─────────────────────────────────────────────────────────────
        // djay mapping: ch=15 CC8. ScratchLab live-verified: CC8 ch=0. Channel
        // discrepancy needs isolated crossfader capture to confirm.
        ControllerBinding(roleKey: "crossfader", deck: nil, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: 0, cc: 8)),

        // ── Left deck channel fader ─────────────────────────────────────────────────
        // Confirmed: CC28 ch1 (MIDI Monitor) = ch=0 (0-indexed). 0=closed, 127=open.
        ControllerBinding(roleKey: "channelVolume", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 28)),

        // Right deck channel fader not yet captured. Right deck channel follows ch2
        // (ch=1) by channel pattern, but CC address not isolated-confirmed.
        // Candidate retained from djay mapping pending live verification.
        ControllerBinding(roleKey: "channelVolume", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 28)),

        // ── Left deck pitch/tempo fader (14-bit high-res CC pair) ──────────────────
        // Confirmed: CC9 (MSB) + CC41 (LSB) on ch1 (ch=0). Standard 14-bit pairing.
        // Calibration (direction, travel range) required before scoring or display.
        ControllerBinding(roleKey: "pitchRaw14", deck: 1, physicalSide: "left",
                          primitive: .cc14(channel: 0, msbCC: 9, lsbCC: 41)),

        // Right deck pitch/tempo: not yet captured. Candidate from djay mapping.
        ControllerBinding(roleKey: "speedCandidate", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 9)),

        // ── Pitch bend buttons (djay mapping; hardware nudge keys, NOT platter) ─────
        ControllerBinding(roleKey: "pitchBendPlus",  deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 11)),
        ControllerBinding(roleKey: "pitchBendMinus", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 12)),
        ControllerBinding(roleKey: "pitchBendPlus",  deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 11)),
        ControllerBinding(roleKey: "pitchBendMinus", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 12)),

        // ── Left deck EQ / gain raw controls ───────────────────────────────────────
        // Confirmed: ch1 (MIDI Monitor) = ch=0 (0-indexed). CC25/24/23/22.
        // Capture order reported as: bass=CC25, mid=CC24, highs=CC23, gain=CC22.
        // Applied as provisional labels; pending one isolated knob turn per control
        // to confirm exact bass/mid/highs/gain assignment before UI is labelled.
        ControllerBinding(roleKey: "eqBassRaw", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 25)),
        ControllerBinding(roleKey: "eqMidRaw", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 24)),
        ControllerBinding(roleKey: "eqHighsRaw", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 23)),
        ControllerBinding(roleKey: "gainRaw", deck: 1, physicalSide: "left",
                          primitive: .ccAbsolute7(channel: 0, cc: 22)),

        // ── Right deck EQ / gain raw controls ──────────────────────────────────────
        // Confirmed: ch2 (MIDI Monitor) = ch=1 (0-indexed). Same CC addresses as left.
        ControllerBinding(roleKey: "eqBassRaw", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 25)),
        ControllerBinding(roleKey: "eqMidRaw", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 24)),
        ControllerBinding(roleKey: "eqHighsRaw", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 23)),
        ControllerBinding(roleKey: "gainRaw", deck: 2, physicalSide: "right",
                          primitive: .ccAbsolute7(channel: 1, cc: 22)),

        // ── Left deck performance pads 1–8 ─────────────────────────────────────────
        // Confirmed: Note On/Off ch5 (MIDI Monitor) = ch=4 (0-indexed).
        // Press: velocity 127. Release: Note Off velocity 0.
        ControllerBinding(roleKey: "leftDeckPad1", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 20, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad2", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 21, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad3", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 22, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad4", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 23, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad5", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 24, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad6", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 25, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad7", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 26, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "leftDeckPad8", deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: 4, note: 27, onValue: 127, offValue: 0)),

        // ── Right deck performance pads 1–8 ────────────────────────────────────────
        // Confirmed: Note On/Off ch6 (MIDI Monitor) = ch=5 (0-indexed).
        // Pads 1–4 (notes 20–23) confirmed in earlier capture (2026-06-24).
        // Pads 5–8 (notes 24–27) confirmed in latest capture.
        ControllerBinding(roleKey: "rightDeckPad1", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 20, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad2", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 21, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad3", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 22, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad4", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 23, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad5", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 24, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad6", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 25, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad7", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 26, onValue: 127, offValue: 0)),
        ControllerBinding(roleKey: "rightDeckPad8", deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: 5, note: 27, onValue: 127, offValue: 0)),
    ]

    private static let one_mkii_verificationSteps: [ControllerVerificationStep] = [
        .init(stepID: "xfader_sweep",
              instruction: "Move the crossfader fully left then fully right — confirm CC8 on ch1 (ch=0).",
              expectedControl: "crossfader", required: true),
        .init(stepID: "ch_vol_left",
              instruction: "Move left channel volume fader from bottom to top — expect CC28 ch1.",
              expectedControl: "channelVolume", required: false),
        .init(stepID: "platter_fwd_left",
              instruction: "Rotate the left platter forward — confirm CC6 ring-counter events on ch1.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_bwd_left",
              instruction: "Rotate the left platter backward — confirm CC6 direction is inverted.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_fwd_right",
              instruction: "Rotate the right platter forward — expect CC6 on ch2.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "platter_bwd_right",
              instruction: "Rotate the right platter backward.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "pitch_left",
              instruction: "Move the left pitch/tempo fader — expect CC9 + CC41 on ch1.",
              expectedControl: "pitchRaw14", required: false),
        .init(stepID: "eq_bass_left",
              instruction: "Turn left Bass knob — expect CC25 ch1 (capture order position 1).",
              expectedControl: "eqBassRaw.deck1", required: false),
        .init(stepID: "eq_mid_left",
              instruction: "Turn left Mid knob — expect CC24 ch1.",
              expectedControl: "eqMidRaw.deck1", required: false),
        .init(stepID: "eq_highs_left",
              instruction: "Turn left Highs knob — expect CC23 ch1.",
              expectedControl: "eqHighsRaw.deck1", required: false),
        .init(stepID: "gain_left",
              instruction: "Turn left Gain knob — expect CC22 ch1.",
              expectedControl: "gainRaw.deck1", required: false),
        .init(stepID: "eq_bass_right",
              instruction: "Turn right Bass knob — expect CC25 ch2.",
              expectedControl: "eqBassRaw.deck2", required: false),
        .init(stepID: "eq_mid_right",
              instruction: "Turn right Mid knob — expect CC24 ch2.",
              expectedControl: "eqMidRaw.deck2", required: false),
        .init(stepID: "eq_highs_right",
              instruction: "Turn right Highs knob — expect CC23 ch2.",
              expectedControl: "eqHighsRaw.deck2", required: false),
        .init(stepID: "gain_right",
              instruction: "Turn right Gain knob — expect CC22 ch2.",
              expectedControl: "gainRaw.deck2", required: false),
        .init(stepID: "left_pad1",
              instruction: "Press left deck Pad 1 — expect Note On ch5 note20 vel127.",
              expectedControl: "leftDeckPad1", required: false),
        .init(stepID: "left_pad8",
              instruction: "Press left deck Pad 8 — expect Note On ch5 note27 vel127.",
              expectedControl: "leftDeckPad8", required: false),
        .init(stepID: "right_pad1",
              instruction: "Press right deck Pad 1 — expect Note On ch6 note20 vel127.",
              expectedControl: "rightDeckPad1", required: false),
        .init(stepID: "right_pad8",
              instruction: "Press right deck Pad 8 — expect Note On ch6 note27 vel127.",
              expectedControl: "rightDeckPad8", required: false),
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
