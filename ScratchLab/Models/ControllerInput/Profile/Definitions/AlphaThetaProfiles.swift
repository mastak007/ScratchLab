import Foundation

// AlphaTheta / Pioneer DJ detection-only and partial stubs.
// Source policy: all mappings below are detection-only stubs unless marked otherwise.
// Official MIDI message PDFs exist for many models but have not yet been incorporated.
// Do NOT promote any stub to "complete" or "partial" until sourced mappings are verified.
// Do NOT claim official support, endorsement, or affiliation with AlphaTheta Corporation.

enum AlphaThetaProfiles {

    static var detectionStubs: [ControllerProfile] {
        [
            // MARK: DDJ Series (performance controllers)
            ddj_rev7,
            ddj_rev5,
            ddj_grv6,
            ddj_flx6,
            ddj_flx6_gt,
            ddj_flx4,
            ddj_flx2,
            ddj_1000,
            ddj_1000srt,
            ddj_800,
            ddj_400,
            ddj_sx3,
            ddj_sr2,
            ddj_sb3,

            // MARK: XDJ / CDJ / Standalone
            xdj_rr,
            xdj_rx2,
            xdj_rx3,
            xdj_xz,
            xdj_az,
            opus_quad,
            omnis_duo,
            cdj_3000,
            cdj_2000nxs2,
            cdj_tour1,

            // MARK: DJM Mixers (fader-primary)
            djm_s9,
            djm_s11,
            djm_s7,
            djm_750mk2,
            djm_900nxs2,
            djm_a9,
            djm_v10,
        ]
    }

    // MARK: - DDJ-REV7 (motorized jog wheels; detection-only until sourced)

    private static let ddj_rev7 = ControllerProfile(
        id: "alphatheta.ddj-rev7",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-REV7",
        publicDisplayFamily: "Motorized Platter Controller",
        matchNames: ["DDJ-REV7", "Pioneer DDJ-REV7", "AlphaTheta DDJ-REV7"],
        deviceNameRegexes: [],
        profileKind: .motorizedPlatterController,
        deviceClass: .scratchPrimary,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: ["Motorized jog wheels; platter MIDI encoding not yet sourced."],
        sourceNotes: "Detection stub only. Official MIDI message list available from AlphaTheta support pages; not yet incorporated.",
        sourceURLs: ["https://www.pioneerdj.com/en/support/software/ddj-rev7/"],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-REV5

    private static let ddj_rev5 = ControllerProfile(
        id: "alphatheta.ddj-rev5",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-REV5",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["DDJ-REV5", "Pioneer DDJ-REV5", "AlphaTheta DDJ-REV5"],
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
        assumptions: ["Non-motorized jog wheels. Jog encoding not yet sourced."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-GRV6

    private static let ddj_grv6 = ControllerProfile(
        id: "alphatheta.ddj-grv6",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-GRV6",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-GRV6", "Pioneer DDJ-GRV6", "AlphaTheta DDJ-GRV6"],
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
        assumptions: ["GRV6 jog encoding is likely similar to FLX10 but not confirmed."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-FLX6

    private static let ddj_flx6 = ControllerProfile(
        id: "alphatheta.ddj-flx6",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-FLX6",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-FLX6", "Pioneer DDJ-FLX6", "AlphaTheta DDJ-FLX6"],
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
        assumptions: ["Jog encoding assumed similar to FLX-series but not confirmed."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-FLX6-GT

    private static let ddj_flx6_gt = ControllerProfile(
        id: "alphatheta.ddj-flx6-gt",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-FLX6-GT",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-FLX6-GT", "DDJ-FLX6GT", "Pioneer DDJ-FLX6-GT"],
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

    // MARK: - DDJ-FLX4

    private static let ddj_flx4 = ControllerProfile(
        id: "alphatheta.ddj-flx4",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-FLX4",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["DDJ-FLX4", "Pioneer DDJ-FLX4", "AlphaTheta DDJ-FLX4"],
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

    // MARK: - DDJ-FLX2

    private static let ddj_flx2 = ControllerProfile(
        id: "alphatheta.ddj-flx2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-FLX2",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["DDJ-FLX2", "Pioneer DDJ-FLX2", "AlphaTheta DDJ-FLX2"],
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

    // MARK: - DDJ-1000

    private static let ddj_1000 = ControllerProfile(
        id: "alphatheta.ddj-1000",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-1000",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-1000"],
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
        sourceNotes: "Detection stub only. Match-name disambiguated from DDJ-1000SRT.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-1000SRT

    private static let ddj_1000srt = ControllerProfile(
        id: "alphatheta.ddj-1000srt",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-1000SRT",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-1000SRT"],
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
        assumptions: ["Serato-optimised variant; MIDI map may differ from DDJ-1000."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-800

    private static let ddj_800 = ControllerProfile(
        id: "alphatheta.ddj-800",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-800",
        publicDisplayFamily: "2-Channel Performance Controller",
        matchNames: ["DDJ-800"],
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

    // MARK: - DDJ-400

    private static let ddj_400 = ControllerProfile(
        id: "alphatheta.ddj-400",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-400",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["DDJ-400"],
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

    // MARK: - DDJ-SX3

    private static let ddj_sx3 = ControllerProfile(
        id: "alphatheta.ddj-sx3",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-SX3",
        publicDisplayFamily: "4-Channel Performance Controller",
        matchNames: ["DDJ-SX3"],
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
        assumptions: ["Serato-optimised variant."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DDJ-SR2

    private static let ddj_sr2 = ControllerProfile(
        id: "alphatheta.ddj-sr2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-SR2",
        publicDisplayFamily: "2-Channel Battle Controller",
        matchNames: ["DDJ-SR2"],
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

    // MARK: - DDJ-SB3

    private static let ddj_sb3 = ControllerProfile(
        id: "alphatheta.ddj-sb3",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DDJ-SB3",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["DDJ-SB3"],
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

    // MARK: - XDJ-RR

    private static let xdj_rr = ControllerProfile(
        id: "alphatheta.xdj-rr",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "XDJ-RR",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["XDJ-RR"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 2,
        physicalDeckCount: 2,
        bindings: [],
        verificationSteps: [],
        assumptions: ["Standalone system; MIDI control surface usefulness for scratch not confirmed."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - XDJ-RX2

    private static let xdj_rx2 = ControllerProfile(
        id: "alphatheta.xdj-rx2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "XDJ-RX2",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["XDJ-RX2"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
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

    // MARK: - XDJ-RX3

    private static let xdj_rx3 = ControllerProfile(
        id: "alphatheta.xdj-rx3",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "XDJ-RX3",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["XDJ-RX3"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
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

    // MARK: - XDJ-XZ

    private static let xdj_xz = ControllerProfile(
        id: "alphatheta.xdj-xz",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "XDJ-XZ",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["XDJ-XZ"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
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

    // MARK: - XDJ-AZ

    private static let xdj_az = ControllerProfile(
        id: "alphatheta.xdj-az",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "XDJ-AZ",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["XDJ-AZ"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
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

    // MARK: - OPUS-QUAD

    private static let opus_quad = ControllerProfile(
        id: "alphatheta.opus-quad",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "OPUS-QUAD",
        publicDisplayFamily: "Standalone DJ System",
        matchNames: ["OPUS-QUAD", "OPUSQUAD"],
        deviceNameRegexes: [],
        profileKind: .standaloneDJSystem,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 4,
        physicalDeckCount: 4,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - OMNIS-DUO

    private static let omnis_duo = ControllerProfile(
        id: "alphatheta.omnis-duo",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "OMNIS-DUO",
        publicDisplayFamily: "Compact DJ Controller",
        matchNames: ["OMNIS-DUO", "OMNISDUO"],
        deviceNameRegexes: [],
        profileKind: .compactDJController,
        deviceClass: .detectionOnly,
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

    // MARK: - CDJ-3000

    private static let cdj_3000 = ControllerProfile(
        id: "alphatheta.cdj-3000",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "CDJ-3000",
        publicDisplayFamily: "Media Player",
        matchNames: ["CDJ-3000"],
        deviceNameRegexes: [],
        profileKind: .mediaPlayer,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: ["CDJ media player; jog wheel MIDI suitability for scratch capture not yet confirmed."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - CDJ-2000NXS2

    private static let cdj_2000nxs2 = ControllerProfile(
        id: "alphatheta.cdj-2000nxs2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "CDJ-2000NXS2",
        publicDisplayFamily: "Media Player",
        matchNames: ["CDJ-2000NXS2", "CDJ-2000 NXS2", "CDJ2000NXS2"],
        deviceNameRegexes: [],
        profileKind: .mediaPlayer,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - CDJ-TOUR1

    private static let cdj_tour1 = ControllerProfile(
        id: "alphatheta.cdj-tour1",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "CDJ-TOUR1",
        publicDisplayFamily: "Media Player",
        matchNames: ["CDJ-TOUR1", "CDJTOUR1"],
        deviceNameRegexes: [],
        profileKind: .mediaPlayer,
        deviceClass: .detectionOnly,
        mappingStatus: .detectionOnly,
        sourceConfidence: .unknown,
        verificationRequired: true,
        deckCount: 1,
        physicalDeckCount: 1,
        bindings: [],
        verificationSteps: [],
        assumptions: [],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DJM-S9 (battle mixer; fader-primary)

    private static let djm_s9 = ControllerProfile(
        id: "alphatheta.djm-s9",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-S9",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["DJM-S9"],
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
        assumptions: ["Standalone mixer; no onboard platter. Crossfader/channel fader MIDI not yet mapped."],
        sourceNotes: "Detection stub only. Fader mapping requires sourced MIDI message list.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DJM-S11

    private static let djm_s11 = ControllerProfile(
        id: "alphatheta.djm-s11",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-S11",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["DJM-S11"],
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
        assumptions: ["Standalone mixer; fader MIDI not yet mapped."],
        sourceNotes: "Detection stub only.",
        sourceURLs: [],
        lastCheckedDate: "2024-01-01"
    )

    // MARK: - DJM-S7

    private static let djm_s7 = ControllerProfile(
        id: "alphatheta.djm-s7",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-S7",
        publicDisplayFamily: "Battle Mixer",
        matchNames: ["DJM-S7"],
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

    // MARK: - DJM-750MK2

    private static let djm_750mk2 = ControllerProfile(
        id: "alphatheta.djm-750mk2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-750MK2",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["DJM-750MK2", "DJM-750 MK2", "DJM750MK2"],
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

    // MARK: - DJM-900NXS2

    private static let djm_900nxs2 = ControllerProfile(
        id: "alphatheta.djm-900nxs2",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-900NXS2",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["DJM-900NXS2", "DJM-900 NXS2", "DJM900NXS2"],
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

    // MARK: - DJM-A9

    private static let djm_a9 = ControllerProfile(
        id: "alphatheta.djm-a9",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-A9",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["DJM-A9"],
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

    // MARK: - DJM-V10

    private static let djm_v10 = ControllerProfile(
        id: "alphatheta.djm-v10",
        internalManufacturer: "AlphaTheta / Pioneer DJ",
        internalModel: "DJM-V10",
        publicDisplayFamily: "DJ Mixer",
        matchNames: ["DJM-V10"],
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
}
