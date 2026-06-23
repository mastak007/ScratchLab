import Foundation

// DDJ-FLX10 complete profile.
// Source: AlphaTheta / Pioneer DJ official MIDI message list.
// sourceConfidence: highOfficial
// All jog/platter/crossfader/fader addresses are from the official document.

extension ControllerProfile {

    // MARK: - DDJ-FLX10 channel constants

    // Physical deck MIDI channels (0-based, matching status bytes 0xB0–0xB3 / 0x90–0x93)
    private static let flx10Ch1 = UInt8(0)   // Deck 1
    private static let flx10Ch2 = UInt8(1)   // Deck 2
    private static let flx10Ch3 = UInt8(2)   // Deck 3
    private static let flx10Ch4 = UInt8(3)   // Deck 4
    private static let flx10ChMixer = UInt8(6) // Mixer / browser (MIDI ch 7)

    // MARK: - Complete DDJ-FLX10 profile

    static let ddj_flx10 = ControllerProfile(
        id: "alphatheta.ddj-flx10",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-FLX10",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: [
            "DDJ-FLX10",
            "Pioneer DDJ-FLX10",
            "AlphaTheta DDJ-FLX10",
            "DDJFLX10"
        ],
        deviceNameRegexes: [],
        profileKind: .fourChannelPerformanceController,
        deviceClass: .scratchPrimary,
        mappingStatus: .complete,
        sourceConfidence: .highOfficial,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 2,
        bindings: ddj_flx10Bindings,
        verificationSteps: ddj_flx10VerificationSteps,
        assumptions: [
            "Deck 1 left / Deck 2 right physical layout assumed as default.",
            "Deck 3 and Deck 4 are virtual layers on the same physical jog wheels.",
            "Vinyl mode state tracked per deck; warn if off during scratch practice.",
            "Open side of crossfader (Deck 1 / Deck 2) confirmed during guided verification.",
            "Jog scratch CC 0x22 (JogScratch, vinyl mode ON) is the primary platter-motion source.",
            "Jog pitch-bend CC 0x23 (JogPitchBend, vinyl mode OFF) is logged but not used for scoring.",
            "Jog side CC 0x21 (WheelPitchBend) is a secondary outer-ring source; never primary.",
            "Channel faders are secondary gate metadata; not used for platter-motion scoring."
        ],
        sourceNotes: "Jog/platter/fader CC values verified against DDJ-FLX10.midi.csv (MidiControllerMaster_csv.zip, 2026-06-24). sourceType: uploadedCsv. Official URL also recorded.",
        sourceURLs: [
            "https://www.pioneerdj.com/en/support/software/ddj-flx10/"
        ],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - Bindings

    private static let ddj_flx10Bindings: [ControllerBinding] = [

        // MARK: Platter top / JogScratch (primary scratch-motion source, CC 0x22 per deck, vinyl mode ON)
        // Source: DDJ-FLX10.midi.csv row "JogScratch,JogScratch,JogRotate,B022,0,1,2,3,,,,,,RO;Dual,Scratch"
        ControllerBinding(roleKey: "platterTop",    deck: 1, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch1, cc: 0x22)),
        ControllerBinding(roleKey: "platterTop",    deck: 2, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch2, cc: 0x22)),
        ControllerBinding(roleKey: "platterTop",    deck: 3, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch3, cc: 0x22)),
        ControllerBinding(roleKey: "platterTop",    deck: 4, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch4, cc: 0x22)),

        // MARK: Jog pitch-bend / JogPitchBend (platter top in pitch-bend mode, CC 0x23 per deck, vinyl mode OFF)
        // Source: DDJ-FLX10.midi.csv row "JogPitchBend,JogPitchBend,JogRotate,B023,0,1,2,3,,,,,,RO;Dual,Pitch Bend"
        // Not used for scoring; logged only so callers can distinguish vinyl-on vs. vinyl-off.
        ControllerBinding(roleKey: "jogPitchBend",  deck: 1, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch1, cc: 0x23)),
        ControllerBinding(roleKey: "jogPitchBend",  deck: 2, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch2, cc: 0x23)),
        ControllerBinding(roleKey: "jogPitchBend",  deck: 3, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch3, cc: 0x23)),
        ControllerBinding(roleKey: "jogPitchBend",  deck: 4, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch4, cc: 0x23)),

        // MARK: Jog side / WheelPitchBend (outer ring, secondary, CC 0x21 per deck — never primary)
        // Source: DDJ-FLX10.midi.csv row "WheelPitchBend,WheelPitchBend,JogRotate,B021,0,1,2,3,,,,,,RO;Dual,Pitch Bend"
        ControllerBinding(roleKey: "jogSide",       deck: 1, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch1, cc: 0x21)),
        ControllerBinding(roleKey: "jogSide",       deck: 2, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch2, cc: 0x21)),
        ControllerBinding(roleKey: "jogSide",       deck: 3, physicalSide: "left",
                          primitive: .relativeSignedOffset64(channel: flx10Ch3, cc: 0x21)),
        ControllerBinding(roleKey: "jogSide",       deck: 4, physicalSide: "right",
                          primitive: .relativeSignedOffset64(channel: flx10Ch4, cc: 0x21)),

        // MARK: Jog touch (NOTE 0x36, ON = 0x7F, OFF = 0x00)
        ControllerBinding(roleKey: "jogTouch",      deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch1, note: 0x36, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "jogTouch",      deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch2, note: 0x36, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "jogTouch",      deck: 3, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch3, note: 0x36, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "jogTouch",      deck: 4, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch4, note: 0x36, onValue: 0x7F, offValue: 0x00)),

        // MARK: Vinyl mode (CC 0x22 = on, CC 0x23 = off per deck)
        // Modelled as two separate noteMomentary-style CC markers.
        ControllerBinding(roleKey: "vinylModeOn",   deck: 1, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: flx10Ch1, cc: 0x22)),
        ControllerBinding(roleKey: "vinylModeOff",  deck: 1, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: flx10Ch1, cc: 0x23)),
        ControllerBinding(roleKey: "vinylModeOn",   deck: 2, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: flx10Ch2, cc: 0x22)),
        ControllerBinding(roleKey: "vinylModeOff",  deck: 2, physicalSide: nil,
                          primitive: .ccAbsolute7(channel: flx10Ch2, cc: 0x23)),

        // MARK: Crossfader — 14-bit CC pair on mixer channel (ch 7 = index 6)
        // MSB CC 0x1F, LSB CC 0x3F; range 0x0000–0x3FFF; normalize as raw / 16383.0.
        ControllerBinding(roleKey: "crossfader",    deck: nil, physicalSide: nil,
                          primitive: .cc14(channel: flx10ChMixer, msbCC: 0x1F, lsbCC: 0x3F)),

        // MARK: Channel faders — 14-bit CC pair per deck
        ControllerBinding(roleKey: "channelFader",  deck: 1, physicalSide: "left",
                          primitive: .cc14(channel: flx10Ch1, msbCC: 0x13, lsbCC: 0x33)),
        ControllerBinding(roleKey: "channelFader",  deck: 2, physicalSide: "right",
                          primitive: .cc14(channel: flx10Ch2, msbCC: 0x13, lsbCC: 0x33)),
        ControllerBinding(roleKey: "channelFader",  deck: 3, physicalSide: "left",
                          primitive: .cc14(channel: flx10Ch3, msbCC: 0x13, lsbCC: 0x33)),
        ControllerBinding(roleKey: "channelFader",  deck: 4, physicalSide: "right",
                          primitive: .cc14(channel: flx10Ch4, msbCC: 0x13, lsbCC: 0x33)),

        // MARK: Tempo — 14-bit CC pair per deck (metadata only; do not use as scratch-speed truth)
        ControllerBinding(roleKey: "tempo",         deck: 1, physicalSide: nil,
                          primitive: .cc14(channel: flx10Ch1, msbCC: 0x00, lsbCC: 0x20)),
        ControllerBinding(roleKey: "tempo",         deck: 2, physicalSide: nil,
                          primitive: .cc14(channel: flx10Ch2, msbCC: 0x00, lsbCC: 0x20)),

        // MARK: Play / Pause (NOTE 0x0B per deck)
        ControllerBinding(roleKey: "playPause",     deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch1, note: 0x0B, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "playPause",     deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch2, note: 0x0B, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "playPause",     deck: 3, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch3, note: 0x0B, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "playPause",     deck: 4, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch4, note: 0x0B, onValue: 0x7F, offValue: 0x00)),

        // MARK: Cue (NOTE 0x0C per deck)
        ControllerBinding(roleKey: "cue",           deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch1, note: 0x0C, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "cue",           deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch2, note: 0x0C, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "cue",           deck: 3, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch3, note: 0x0C, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "cue",           deck: 4, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch4, note: 0x0C, onValue: 0x7F, offValue: 0x00)),

        // MARK: Shift (NOTE 0x3F per deck)
        ControllerBinding(roleKey: "shift",         deck: 1, physicalSide: "left",
                          primitive: .noteMomentary(channel: flx10Ch1, note: 0x3F, onValue: 0x7F, offValue: 0x00)),
        ControllerBinding(roleKey: "shift",         deck: 2, physicalSide: "right",
                          primitive: .noteMomentary(channel: flx10Ch2, note: 0x3F, onValue: 0x7F, offValue: 0x00)),

        // MARK: Deck select (NOTE 0x3C; channel determines which deck is reported active)
        ControllerBinding(roleKey: "deckSelect",    deck: 1, physicalSide: "left",
                          primitive: .deckLayerSelect(channel: flx10Ch1, note: 0x3C)),
        ControllerBinding(roleKey: "deckSelect",    deck: 2, physicalSide: "right",
                          primitive: .deckLayerSelect(channel: flx10Ch2, note: 0x3C)),
        ControllerBinding(roleKey: "deckSelect",    deck: 3, physicalSide: "left",
                          primitive: .deckLayerSelect(channel: flx10Ch3, note: 0x3C)),
        ControllerBinding(roleKey: "deckSelect",    deck: 4, physicalSide: "right",
                          primitive: .deckLayerSelect(channel: flx10Ch4, note: 0x3C)),

        // MARK: Pad grids (channels 8–15 / indices 7–14 for no-shift and shift layers)
        // Deck 1 no-shift pads: MIDI ch 8 (index 7)
        ControllerBinding(roleKey: "padGrid",       deck: 1, physicalSide: "left",
                          primitive: .padGrid(baseChannel: 7, noteOffset: 0, rows: 2, columns: 4)),
        // Deck 2 no-shift pads: MIDI ch 10 (index 9)
        ControllerBinding(roleKey: "padGrid",       deck: 2, physicalSide: "right",
                          primitive: .padGrid(baseChannel: 9, noteOffset: 0, rows: 2, columns: 4)),
    ]

    // MARK: - DDJ-FLX10 verification steps

    private static let ddj_flx10VerificationSteps: [ControllerVerificationStep] = [
        .init(stepID: "touch_left",       instruction: "Touch the left jog wheel surface.",
              expectedControl: "jogTouch.deck1", required: false),
        .init(stepID: "platter_fwd_left", instruction: "Rotate the left jog wheel forward slowly.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_bwd_left", instruction: "Rotate the left jog wheel backward slowly.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_fwd_fast_left", instruction: "Rotate the left jog wheel forward quickly.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "platter_bwd_fast_left", instruction: "Rotate the left jog wheel backward quickly.",
              expectedControl: "platterTop.deck1", required: true),
        .init(stepID: "touch_right",      instruction: "Touch the right jog wheel surface.",
              expectedControl: "jogTouch.deck2", required: false),
        .init(stepID: "platter_fwd_right", instruction: "Rotate the right jog wheel forward slowly.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "platter_bwd_right", instruction: "Rotate the right jog wheel backward slowly.",
              expectedControl: "platterTop.deck2", required: true),
        .init(stepID: "xfader_left",      instruction: "Move the crossfader fully to the left.",
              expectedControl: "crossfader", required: true),
        .init(stepID: "xfader_right",     instruction: "Move the crossfader fully to the right.",
              expectedControl: "crossfader", required: true),
        .init(stepID: "ch_fader_1",       instruction: "Move Channel 1 fader from bottom to top.",
              expectedControl: "channelFader.deck1", required: false),
        .init(stepID: "ch_fader_2",       instruction: "Move Channel 2 fader from bottom to top.",
              expectedControl: "channelFader.deck2", required: false),
        .init(stepID: "play_pause",       instruction: "Press Play/Pause on Deck 1.",
              expectedControl: "playPause.deck1", required: false),
        .init(stepID: "cue",              instruction: "Press Cue on Deck 1.",
              expectedControl: "cue.deck1", required: false),
        .init(stepID: "pad",              instruction: "Press any hot-cue pad.",
              expectedControl: "padGrid.deck1", required: false),
        .init(stepID: "deck1_open_side",  instruction: "Which side (left/right) is Deck 1 audible on?",
              expectedControl: "crossfaderSide.deck1", required: true),
        .init(stepID: "deck2_open_side",  instruction: "Which side (left/right) is Deck 2 audible on?",
              expectedControl: "crossfaderSide.deck2", required: true),
    ]
}

// MARK: - DDJ-FLX10 Channel-to-Deck Decoder

/// Converts an incoming MIDI channel (0-based) to a logical DDJ-FLX10 deck number (1-based).
/// Returns nil for mixer/FX/pad channels that are not deck-level performance channels.
enum DDJFLX10Decoder {

    static func deck(forChannel channel: UInt8) -> Int? {
        switch channel {
        case 0: return 1
        case 1: return 2
        case 2: return 3
        case 3: return 4
        default: return nil
        }
    }

    /// Decode a relative signed offset 64 value into a signed delta.
    /// 0x41→+1, 0x42→+2, 0x3F→-1, 0x3E→-2, 0x40→0.
    static func platterDelta(_ value: UInt8) -> Int {
        MappingPrimitive.decodeRelativeSignedOffset64(value)
    }

    /// Decode a 14-bit crossfader value from MSB and LSB, normalized 0.0–1.0.
    static func crossfaderPosition(msb: UInt8, lsb: UInt8) -> Double {
        MappingPrimitive.normalize14bit(MappingPrimitive.decode14bit(msb: msb, lsb: lsb))
    }
}
