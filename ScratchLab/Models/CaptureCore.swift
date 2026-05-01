import Foundation
import Combine
import OSLog
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum CaptureSessionScratchType: String, CaseIterable, Codable, Sendable {
    case babyScratch = "baby_scratch"
    case forwardScratch = "forward_scratch"
    case backwardScratch = "backward_scratch"
    case releaseScratch = "release_scratch"
    case tear
    case chirp
    case scribble
    case stab
    case transform
    case crab
    case flare1Click = "flare_1click"
    case orbit
    case flare2Click = "flare_2click"
    case twiddle
    case boomerang
    case hydroplane
    case flare3Click = "flare_3click"
    case autobahn
    case military
    case prizm
    case comboL1 = "combo_l1"
    case comboL2 = "combo_l2"
    case comboL3 = "combo_l3"
    case comboL4 = "combo_l4"
    case comboL5 = "combo_l5"

    var title: String {
        switch self {
        case .babyScratch: return "Baby Scratch"
        case .forwardScratch: return "Forward Scratch"
        case .backwardScratch: return "Backward Scratch"
        case .releaseScratch: return "Release Scratch"
        case .tear: return "Tear"
        case .chirp: return "Chirp"
        case .scribble: return "Scribble"
        case .stab: return "Stab"
        case .transform: return "Transform"
        case .crab: return "Crab"
        case .flare1Click: return "1-Click Flare"
        case .orbit: return "Orbit"
        case .flare2Click: return "2-Click Flare"
        case .twiddle: return "Twiddle"
        case .boomerang: return "Boomerang"
        case .hydroplane: return "Hydroplane"
        case .flare3Click: return "3-Click Flare"
        case .autobahn: return "Autobahn"
        case .military: return "Military"
        case .prizm: return "Prizm"
        case .comboL1: return "Combo L1"
        case .comboL2: return "Combo L2"
        case .comboL3: return "Combo L3"
        case .comboL4: return "Combo L4"
        case .comboL5: return "Combo L5"
        }
    }

    var trainingBPMList: [Int] {
        switch self {
        case .tear, .stab, .transform:
            return [110, 120, 130]
        case .crab, .flare1Click, .orbit, .flare2Click, .twiddle:
            return [70, 80, 90]
        case .boomerang, .hydroplane, .flare3Click, .autobahn, .military, .prizm:
            return [80, 90, 100]
        case .comboL1, .comboL2, .comboL3, .comboL4, .comboL5:
            return [70, 80, 95, 105, 125]
        case .babyScratch, .forwardScratch, .backwardScratch, .releaseScratch, .chirp, .scribble:
            return [70, 90, 110]
        }
    }

    static var allTrainingBPMList: [Int] {
        Array(Set(allCases.flatMap(\.trainingBPMList))).sorted()
    }
}

enum CaptureSessionDrillMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case fullCapture
    case cameraAudioOnly
    case referenceOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullCapture: return "Full Capture"
        case .cameraAudioOnly: return "Camera + Audio"
        case .referenceOnly: return "Reference"
        }
    }

    var motionOptional: Bool {
        switch self {
        case .fullCapture:
            return false
        case .cameraAudioOnly, .referenceOnly:
            return true
        }
    }
}

enum CaptureSessionHandedness: String, CaseIterable, Codable, Sendable, Identifiable {
    case left
    case right
    case switchHand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .switchHand: return "Switch"
        }
    }
}

enum CaptureClickTrackDefaults {
    static let supportedBPMRange = 60...140
    static let presetBPMs = [80, 95, 110]
    static let defaultTimedBPM = 95
    static let countInBeats = 4
    static let beatsPerBar = 4
    static let clickAccentPattern = "accent-first-beat"
    static let clickVersion = "scratchlab-click-v1"

    static func clampedBPM(_ bpm: Int) -> Int {
        min(max(bpm, supportedBPMRange.lowerBound), supportedBPMRange.upperBound)
    }
}

enum BeatEngineMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case silent
    case clickTrack = "click_track"
    case boomBapTrainer = "boom_bap_trainer"
    case minimalFunk = "minimal_funk"
    case battleLoop = "battle_loop"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent:
            return "No timing"
        case .clickTrack:
            return "Click track"
        case .boomBapTrainer:
            return "Boom Bap Trainer"
        case .minimalFunk:
            return "Minimal Funk"
        case .battleLoop:
            return "Battle Loop"
        }
    }

    var beatEnabled: Bool {
        switch self {
        case .boomBapTrainer, .minimalFunk, .battleLoop:
            return true
        case .silent, .clickTrack:
            return false
        }
    }

    var clickEnabled: Bool {
        self == .clickTrack
    }

    var beatPatternName: String? {
        switch self {
        case .boomBapTrainer:
            return "boom-bap-trainer"
        case .minimalFunk:
            return "minimal-funk"
        case .battleLoop:
            return "battle-loop"
        case .silent, .clickTrack:
            return nil
        }
    }

    var defaultSwingAmount: Double {
        switch self {
        case .minimalFunk:
            return CaptureBeatEngineDefaults.minimalFunkSwingAmount
        case .silent, .clickTrack, .boomBapTrainer, .battleLoop:
            return 0
        }
    }

    static var practiceModes: [BeatEngineMode] {
        [.clickTrack, .boomBapTrainer, .minimalFunk, .battleLoop]
    }
}

enum CaptureBeatEngineDefaults {
    static let beatPatternVersion = "scratchlab-beats-v1"
    static let engineVersion = "scratchlab-beat-engine-v1"
    static let minimalFunkSwingAmount = 0.08
}

enum TimingPrintedToRecordingState: String, Codable, Sendable, Identifiable {
    case printed = "true"
    case notPrinted = "false"
    case unknown

    var id: String { rawValue }

    var needsWarning: Bool {
        self != .notPrinted
    }
}

enum ExportMixMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case scratchOnly = "scratch_only"
    case scratchWithTiming = "scratch_with_timing"
    case timingOnly = "timing_only"
    case stemsFolder = "stems_folder"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scratchOnly:
            return "Scratch only"
        case .scratchWithTiming:
            return "Scratch + timing"
        case .timingOnly:
            return "Timing only"
        case .stemsFolder:
            return "Export stems"
        }
    }
}

enum CaptureQuality: String, Codable, Sendable {
    case clean
    case mixed
    case processed
}

struct SessionExportOptions: Equatable, Sendable {
    var mixMode: ExportMixMode = .scratchOnly
}

enum CaptureSessionCaptureMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case calibrationNoClick = "calibration_no_click"
    case timedClick = "timed_click"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calibrationNoClick:
            return "Calibration"
        case .timedClick:
            return "Timed capture"
        }
    }

    var clickEnabled: Bool {
        self == .timedClick
    }
}

struct CaptureTimingMetadata: Codable, Equatable, Sendable {
    var clickStartHostTime: UInt64?
    var recordingStartHostTime: UInt64?
}

struct GuidedCaptureMotionAssessment: Equatable, Sendable {
    let syncStatus: String
    let motionStatusTitle: String
    let motionPresent: Bool
}

enum GuidedCaptureReviewStateResolver {
    static func motionAssessment(
        calibrationValid: Bool,
        audioPresent: Bool,
        motionPresent: Bool,
        motionSkipped: Bool,
        motionOptional: Bool
    ) -> GuidedCaptureMotionAssessment {
        let motionStatusTitle: String
        if motionSkipped || motionOptional {
            motionStatusTitle = "Motion Optional"
        } else if motionPresent {
            motionStatusTitle = "Motion Present"
        } else {
            motionStatusTitle = "Motion Missing"
        }

        let syncStatus: String
        if !calibrationValid {
            syncStatus = "Needs calibration"
        } else if !audioPresent {
            syncStatus = "Missing audio"
        } else if motionSkipped || motionOptional {
            syncStatus = "Motion optional"
        } else if motionPresent {
            syncStatus = "Ready"
        } else {
            syncStatus = "Motion pending"
        }

        return GuidedCaptureMotionAssessment(
            syncStatus: syncStatus,
            motionStatusTitle: motionStatusTitle,
            motionPresent: motionPresent
        )
    }
}

struct CaptureSessionConfig: Codable, Equatable, Sendable {
    var performerName: String
    var bpm: Int?
    var scratchType: CaptureSessionScratchType?
    var drillMode: CaptureSessionDrillMode?
    var captureMode: CaptureSessionCaptureMode
    var beatEngineMode: BeatEngineMode
    var countInBeats: Int
    var beatsPerBar: Int
    var clickAccentPattern: String
    var clickVersion: String
    var beatPatternVersion: String
    var swingAmount: Double
    var engineVersion: String
    var timingPrintedToRecording: TimingPrintedToRecordingState
    var takeDurationSeconds: Double?
    var takeCount: Int
    var handedness: CaptureSessionHandedness?
    var notes: String
    var sessionID: String
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case performerName
        case bpm
        case scratchTypeID
        case scratchTypeName
        case drillMode
        case captureMode
        case clickEnabled
        case beatEngineMode
        case beatEnabled
        case beatPatternName
        case beatPatternVersion
        case swingAmount
        case engineVersion
        case countInBeats
        case beatsPerBar
        case clickAccentPattern
        case clickVersion
        case timingPrintedToRecording
        case takeDurationSeconds
        case takeCount
        case handedness
        case notes
        case sessionID
        case createdAt
        case updatedAt
    }

    init(
        performerName: String = "",
        bpm: Int? = CaptureClickTrackDefaults.defaultTimedBPM,
        scratchType: CaptureSessionScratchType? = .babyScratch,
        drillMode: CaptureSessionDrillMode? = .fullCapture,
        captureMode: CaptureSessionCaptureMode = .timedClick,
        beatEngineMode: BeatEngineMode = .clickTrack,
        countInBeats: Int = CaptureClickTrackDefaults.countInBeats,
        beatsPerBar: Int = CaptureClickTrackDefaults.beatsPerBar,
        clickAccentPattern: String = CaptureClickTrackDefaults.clickAccentPattern,
        clickVersion: String = CaptureClickTrackDefaults.clickVersion,
        beatPatternVersion: String = CaptureBeatEngineDefaults.beatPatternVersion,
        swingAmount: Double = 0,
        engineVersion: String = CaptureBeatEngineDefaults.engineVersion,
        timingPrintedToRecording: TimingPrintedToRecordingState = .unknown,
        takeDurationSeconds: Double? = nil,
        takeCount: Int = 0,
        handedness: CaptureSessionHandedness? = .right,
        notes: String = "",
        sessionID: String = CaptureCore.LocalRecordingNaming.sessionID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.performerName = performerName
        self.bpm = bpm
        self.scratchType = scratchType
        self.drillMode = drillMode
        self.captureMode = captureMode
        self.beatEngineMode = beatEngineMode
        self.countInBeats = countInBeats
        self.beatsPerBar = beatsPerBar
        self.clickAccentPattern = clickAccentPattern
        self.clickVersion = clickVersion
        self.beatPatternVersion = beatPatternVersion
        self.swingAmount = swingAmount
        self.engineVersion = engineVersion
        self.timingPrintedToRecording = timingPrintedToRecording
        self.takeDurationSeconds = takeDurationSeconds
        self.takeCount = takeCount
        self.handedness = handedness
        self.notes = notes
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        Self.normalizeCaptureSettings(in: &self)
    }

    static func guidedCaptureDefaults(now: Date = Date()) -> CaptureSessionConfig {
        CaptureSessionConfig(
            sessionID: CaptureCore.LocalRecordingNaming.sessionID(),
            createdAt: now,
            updatedAt: now
        )
    }

    static func routineCapture(
        sessionID: String,
        createdAt: Date,
        updatedAt: Date,
        takeCount: Int,
        takeDurationSeconds: Double?
    ) -> CaptureSessionConfig {
        CaptureSessionConfig(
            performerName: "",
            bpm: nil,
            scratchType: nil,
            drillMode: .fullCapture,
            captureMode: .timedClick,
            takeDurationSeconds: takeDurationSeconds,
            takeCount: takeCount,
            handedness: .right,
            notes: "",
            sessionID: sessionID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    mutating func refreshSessionIdentity(
        surface: CaptureCore.LocalRecordingSurface,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        sessionID = CaptureCore.LocalRecordingNaming.sessionID()
        createdAt = now
        updatedAt = now
        takeCount = 0
        takeDurationSeconds = nil
    }

    mutating func applyCapturedTakeMetrics(
        takeCount: Int,
        totalDurationSeconds: Double,
        updatedAt: Date = Date()
    ) {
        self.takeCount = takeCount
        takeDurationSeconds = totalDurationSeconds
        self.updatedAt = updatedAt
    }

    var normalizedPerformerName: String? {
        normalizedText(performerName)
    }

    var normalizedScratchTypeID: String? {
        scratchType?.rawValue
    }

    var normalizedScratchTypeName: String? {
        scratchType?.title
    }

    var normalizedDrillMode: String? {
        drillMode?.rawValue
    }

    var normalizedCaptureMode: String {
        captureMode.rawValue
    }

    var clickEnabled: Bool {
        captureMode != .calibrationNoClick && beatEngineMode.clickEnabled
    }

    var beatEnabled: Bool {
        captureMode != .calibrationNoClick && beatEngineMode.beatEnabled
    }

    var normalizedBeatEngineMode: String {
        beatEngineMode.rawValue
    }

    var normalizedBeatPatternName: String? {
        beatEngineMode.beatPatternName
    }

    var normalizedHandedness: String? {
        handedness?.rawValue
    }

    var normalizedNotes: String? {
        normalizedText(notes)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        performerName = try container.decodeIfPresent(String.self, forKey: .performerName) ?? ""
        bpm = try container.decodeIfPresent(Int.self, forKey: .bpm)
        if let scratchTypeID = try container.decodeIfPresent(String.self, forKey: .scratchTypeID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !scratchTypeID.isEmpty {
            scratchType = CaptureSessionScratchType(rawValue: scratchTypeID)
        } else {
            scratchType = nil
        }
        if let drillModeValue = try container.decodeIfPresent(String.self, forKey: .drillMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !drillModeValue.isEmpty {
            drillMode = CaptureSessionDrillMode(rawValue: drillModeValue)
        } else {
            drillMode = nil
        }
        if let captureModeValue = try container.decodeIfPresent(String.self, forKey: .captureMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decodedCaptureMode = CaptureSessionCaptureMode(rawValue: captureModeValue) {
            captureMode = decodedCaptureMode
        } else if let clickEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickEnabled) {
            captureMode = clickEnabled ? .timedClick : .calibrationNoClick
        } else {
            captureMode = .timedClick
        }
        if let beatEngineValue = try container.decodeIfPresent(String.self, forKey: .beatEngineMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decodedBeatEngineMode = BeatEngineMode(rawValue: beatEngineValue) {
            beatEngineMode = decodedBeatEngineMode
        } else if let clickEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickEnabled),
                  clickEnabled {
            beatEngineMode = .clickTrack
        } else {
            beatEngineMode = captureMode == .calibrationNoClick ? .silent : .clickTrack
        }
        countInBeats = try container.decodeIfPresent(Int.self, forKey: .countInBeats)
            ?? CaptureClickTrackDefaults.countInBeats
        beatsPerBar = try container.decodeIfPresent(Int.self, forKey: .beatsPerBar)
            ?? CaptureClickTrackDefaults.beatsPerBar
        clickAccentPattern = try container.decodeIfPresent(String.self, forKey: .clickAccentPattern)
            ?? CaptureClickTrackDefaults.clickAccentPattern
        clickVersion = try container.decodeIfPresent(String.self, forKey: .clickVersion)
            ?? CaptureClickTrackDefaults.clickVersion
        beatPatternVersion = try container.decodeIfPresent(String.self, forKey: .beatPatternVersion)
            ?? CaptureBeatEngineDefaults.beatPatternVersion
        swingAmount = try container.decodeIfPresent(Double.self, forKey: .swingAmount) ?? 0
        engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
            ?? CaptureBeatEngineDefaults.engineVersion
        if let timingPrintedValue = try container.decodeIfPresent(String.self, forKey: .timingPrintedToRecording)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decodedTimingPrinted = TimingPrintedToRecordingState(rawValue: timingPrintedValue) {
            timingPrintedToRecording = decodedTimingPrinted
        } else {
            timingPrintedToRecording = captureMode == .calibrationNoClick ? .notPrinted : .unknown
        }
        takeDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .takeDurationSeconds)
        takeCount = try container.decodeIfPresent(Int.self, forKey: .takeCount) ?? 0
        if let handednessValue = try container.decodeIfPresent(String.self, forKey: .handedness)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !handednessValue.isEmpty {
            handedness = CaptureSessionHandedness(rawValue: handednessValue)
        } else {
            handedness = nil
        }
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? CaptureCore.LocalRecordingNaming.sessionID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        Self.normalizeCaptureSettings(in: &self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(performerName, forKey: .performerName)
        try container.encodeIfPresent(bpm, forKey: .bpm)
        try container.encodeIfPresent(scratchType?.rawValue, forKey: .scratchTypeID)
        try container.encodeIfPresent(scratchType?.title, forKey: .scratchTypeName)
        try container.encodeIfPresent(drillMode?.rawValue, forKey: .drillMode)
        try container.encode(captureMode.rawValue, forKey: .captureMode)
        try container.encode(clickEnabled, forKey: .clickEnabled)
        try container.encode(beatEngineMode.rawValue, forKey: .beatEngineMode)
        try container.encode(beatEnabled, forKey: .beatEnabled)
        try container.encodeIfPresent(beatEngineMode.beatPatternName, forKey: .beatPatternName)
        try container.encode(beatPatternVersion, forKey: .beatPatternVersion)
        try container.encode(swingAmount, forKey: .swingAmount)
        try container.encode(engineVersion, forKey: .engineVersion)
        try container.encode(countInBeats, forKey: .countInBeats)
        try container.encode(beatsPerBar, forKey: .beatsPerBar)
        try container.encode(clickAccentPattern, forKey: .clickAccentPattern)
        try container.encode(clickVersion, forKey: .clickVersion)
        try container.encode(timingPrintedToRecording.rawValue, forKey: .timingPrintedToRecording)
        try container.encodeIfPresent(takeDurationSeconds, forKey: .takeDurationSeconds)
        try container.encode(takeCount, forKey: .takeCount)
        try container.encodeIfPresent(handedness?.rawValue, forKey: .handedness)
        try container.encode(notes, forKey: .notes)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private func normalizedText(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func normalizeCaptureSettings(in config: inout CaptureSessionConfig) {
        config.countInBeats = CaptureClickTrackDefaults.countInBeats
        config.beatsPerBar = CaptureClickTrackDefaults.beatsPerBar
        if config.clickAccentPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.clickAccentPattern = CaptureClickTrackDefaults.clickAccentPattern
        }
        if config.clickVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.clickVersion = CaptureClickTrackDefaults.clickVersion
        }
        if config.beatPatternVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.beatPatternVersion = CaptureBeatEngineDefaults.beatPatternVersion
        }
        if config.engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.engineVersion = CaptureBeatEngineDefaults.engineVersion
        }
        if config.captureMode == .calibrationNoClick {
            config.beatEngineMode = .silent
            config.swingAmount = 0
            config.timingPrintedToRecording = .notPrinted
            return
        }
        if config.beatEngineMode == .silent {
            config.beatEngineMode = .clickTrack
        }
        config.swingAmount = config.beatEngineMode.defaultSwingAmount
        if config.timingPrintedToRecording == .unknown {
            config.timingPrintedToRecording = config.beatEngineMode == .silent ? .notPrinted : .unknown
        }
        if let bpm = config.bpm {
            config.bpm = CaptureClickTrackDefaults.clampedBPM(bpm)
        } else if config.scratchType != nil {
            config.bpm = CaptureClickTrackDefaults.defaultTimedBPM
        }
    }
}

@MainActor
final class SessionSetupViewModel: ObservableObject {
    @Published private(set) var config: CaptureSessionConfig

    let surface: CaptureCore.LocalRecordingSurface

    init(surface: CaptureCore.LocalRecordingSurface, config: CaptureSessionConfig? = nil) {
        self.surface = surface
        if let config {
            self.config = config
        } else {
            switch surface {
            case .iosCompanion:
                self.config = .guidedCaptureDefaults()
            case .macRoutine:
                let now = Date()
                self.config = .routineCapture(
                    sessionID: CaptureCore.LocalRecordingNaming.sessionID(),
                    createdAt: now,
                    updatedAt: now,
                    takeCount: 0,
                    takeDurationSeconds: nil
                )
            }
        }
    }

    var performerName: String {
        get { config.performerName }
        set {
            updateConfig { config in
                config.performerName = newValue
            }
        }
    }

    var scratchType: CaptureSessionScratchType? {
        get { config.scratchType }
        set {
            updateConfig { config in
                config.scratchType = newValue
                Self.normalizeCaptureSettings(in: &config)
            }
        }
    }

    var scratchTypeID: String {
        get { config.scratchType?.rawValue ?? "" }
        set {
            updateConfig { config in
                let scratchType = CaptureSessionScratchType(rawValue: newValue)
                config.scratchType = scratchType
                Self.normalizeCaptureSettings(in: &config)
            }
        }
    }

    var scratchTypeName: String {
        config.scratchType?.title ?? "Scratch"
    }

    var captureMode: CaptureSessionCaptureMode {
        get { config.captureMode }
        set {
            updateConfig { config in
                config.captureMode = newValue
                Self.normalizeCaptureSettings(in: &config)
            }
        }
    }

    var bpmText: String {
        get { config.bpm.map(String.init) ?? "" }
        set {
            updateConfig { config in
                config.bpm = Self.normalizedBPM(from: newValue)
            }
        }
    }

    var bpmValue: Int? {
        config.bpm
    }

    var beatEngineMode: BeatEngineMode {
        get { config.beatEngineMode }
        set {
            updateConfig { config in
                config.beatEngineMode = newValue
                Self.normalizeCaptureSettings(in: &config)
            }
        }
    }

    var allowedBPMList: [Int] {
        config.scratchType?.trainingBPMList ?? CaptureClickTrackDefaults.presetBPMs
    }

    var showsTimedCaptureTempo: Bool {
        captureMode == .timedClick
    }

    var showsPracticeBeatSelector: Bool {
        captureMode == .timedClick
    }

    var practiceBeatSelectionTitle: String {
        captureMode == .calibrationNoClick ? BeatEngineMode.silent.title : beatEngineMode.title
    }

    var availableBeatEngineModes: [BeatEngineMode] {
        captureMode == .calibrationNoClick ? [.silent] : BeatEngineMode.practiceModes
    }

    var clickEnabled: Bool {
        config.clickEnabled
    }

    var beatEnabled: Bool {
        config.beatEnabled
    }

    var timingPrintedToRecording: TimingPrintedToRecordingState {
        config.timingPrintedToRecording
    }

    var drillMode: CaptureSessionDrillMode {
        get { config.drillMode ?? .fullCapture }
        set {
            updateConfig { config in
                config.drillMode = newValue
            }
        }
    }

    var handedness: CaptureSessionHandedness {
        get { config.handedness ?? .right }
        set {
            updateConfig { config in
                config.handedness = newValue
            }
        }
    }

    var notes: String {
        get { config.notes }
        set {
            updateConfig { config in
                config.notes = newValue
            }
        }
    }

    var validationMessages: [String] {
        var messages: [String] = []

        if performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Add performer name before starting capture.")
        }
        if scratchType == nil {
            messages.append("Choose the scratch type before starting capture.")
        }
        if captureMode == .timedClick {
            guard let bpmValue else {
                messages.append("Enter BPM before starting capture.")
                return messages
            }
            if !CaptureClickTrackDefaults.supportedBPMRange.contains(bpmValue) {
                messages.append("Choose a BPM between 60 and 140.")
            }
        }

        return messages
    }

    var firstValidationMessage: String? {
        validationMessages.first
    }

    var isComplete: Bool {
        validationMessages.isEmpty
    }

    var takeHeader: String {
        if captureMode == .calibrationNoClick {
            return "\(scratchTypeName) · Calibration"
        }
        let bpmLabel = bpmValue.map { "\($0) BPM" } ?? "BPM"
        return "\(scratchTypeName) · \(bpmLabel)"
    }

    func sessionName(defaultAppName: String) -> String {
        let cleanPerformerName = performerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleanPerformerName.isEmpty ? defaultAppName : cleanPerformerName
        if captureMode == .calibrationNoClick, scratchType != nil {
            return "\(baseName) \(scratchTypeName) Calibration"
        }
        if let bpmValue {
            return "\(baseName) \(scratchTypeName) \(bpmValue) BPM"
        }
        if scratchType != nil {
            return "\(baseName) \(scratchTypeName)"
        }
        return baseName
    }

    func applyPersistedConfig(_ persistedConfig: CaptureSessionConfig) {
        config = persistedConfig
        normalizeBPMForCurrentScratch()
    }

    func bootstrapDefaults(performerName: String, defaultScratchType: CaptureSessionScratchType) {
        if config.performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.performerName = performerName
        }
        if config.scratchType == nil {
            config.scratchType = defaultScratchType
        }
        normalizeBPMForCurrentScratch()
        if config.drillMode == nil {
            config.drillMode = .fullCapture
        }
        if config.handedness == nil {
            config.handedness = .right
        }
        if config.captureMode == .timedClick, config.bpm == nil, config.scratchType != nil {
            config.bpm = CaptureClickTrackDefaults.defaultTimedBPM
        }
        config.updatedAt = Date()
    }

    func refreshSessionIdentity(now: Date = Date()) {
        var nextConfig = config
        nextConfig.refreshSessionIdentity(surface: surface, now: now)
        if surface == .iosCompanion {
            if nextConfig.scratchType == nil {
                nextConfig.scratchType = .babyScratch
            }
            Self.normalizeCaptureSettings(in: &nextConfig)
            if nextConfig.drillMode == nil {
                nextConfig.drillMode = .fullCapture
            }
            if nextConfig.handedness == nil {
                nextConfig.handedness = .right
            }
        }
        config = nextConfig
    }

    private func normalizeBPMForCurrentScratch() {
        updateConfig { config in
            Self.normalizeCaptureSettings(in: &config)
        }
    }

    private static func normalizedBPM(from value: String) -> Int? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        guard let bpmValue = Int(trimmedValue) else { return nil }
        return CaptureClickTrackDefaults.clampedBPM(bpmValue)
    }

    private static func normalizeCaptureSettings(in config: inout CaptureSessionConfig) {
        CaptureSessionConfig.normalizeCaptureSettings(in: &config)
    }

    func applyCapturedTakeMetrics(
        takeCount: Int,
        totalDurationSeconds: Double,
        updatedAt: Date = Date()
    ) {
        var nextConfig = config
        nextConfig.applyCapturedTakeMetrics(
            takeCount: takeCount,
            totalDurationSeconds: totalDurationSeconds,
            updatedAt: updatedAt
        )
        config = nextConfig
    }

    private func updateConfig(_ update: (inout CaptureSessionConfig) -> Void) {
        var nextConfig = config
        update(&nextConfig)
        nextConfig.updatedAt = Date()
        config = nextConfig
    }
}

@MainActor
protocol PracticeBeatPlaybackEngine: AnyObject {
    func start(mode: BeatEngineMode, bpm: Int) throws
    func stop()
}

extension ScratchLabBeatEngine: PracticeBeatPlaybackEngine {
    func start(mode: BeatEngineMode, bpm: Int) throws {
        _ = try start(
            mode: mode,
            bpm: bpm,
            onCountInBeat: nil,
            onRecordingStart: nil
        )
    }
}

struct PracticeBeatPreferences: Codable, Equatable, Sendable {
    var scratchType: CaptureSessionScratchType
    var bpm: Int
    var captureMode: CaptureSessionCaptureMode
    var beatEngineMode: BeatEngineMode
    var lastAudibleBeatMode: BeatEngineMode

    static let defaultValue = PracticeBeatPreferences(
        scratchType: .babyScratch,
        bpm: CaptureClickTrackDefaults.defaultTimedBPM,
        captureMode: .calibrationNoClick,
        beatEngineMode: .silent,
        lastAudibleBeatMode: .clickTrack
    )
}

@MainActor
final class PracticeBeatStore: ObservableObject {
    @Published private(set) var preferences: PracticeBeatPreferences
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackErrorMessage: String?

    private let defaults: UserDefaults
    private let beatEngine: PracticeBeatPlaybackEngine
    private let defaultsKey = "practiceBeat.preferences"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        beatEngine: PracticeBeatPlaybackEngine = ScratchLabBeatEngine()
    ) {
        self.defaults = defaults
        self.beatEngine = beatEngine
        if let data = defaults.data(forKey: defaultsKey),
           let decodedPreferences = try? decoder.decode(PracticeBeatPreferences.self, from: data) {
            self.preferences = Self.normalizedPreferences(decodedPreferences)
        } else {
            self.preferences = PracticeBeatPreferences.defaultValue
        }
    }

    var scratchType: CaptureSessionScratchType {
        preferences.scratchType
    }

    var scratchTypeID: String {
        preferences.scratchType.rawValue
    }

    var bpmValue: Int {
        preferences.bpm
    }

    var allowedBPMList: [Int] {
        preferences.scratchType.trainingBPMList
    }

    var captureMode: CaptureSessionCaptureMode {
        preferences.captureMode
    }

    var isBeatEnabled: Bool {
        preferences.captureMode == .timedClick
    }

    var beatEngineMode: BeatEngineMode {
        isBeatEnabled ? preferences.beatEngineMode : .silent
    }

    var selectedBeatMode: BeatEngineMode {
        preferences.lastAudibleBeatMode
    }

    var availableBeatModes: [BeatEngineMode] {
        BeatEngineMode.practiceModes
    }

    func configurePracticeContext(
        scratchID: String,
        preferredBPM: Int? = nil
    ) {
        updatePreferences { preferences in
            if let scratchType = CaptureSessionScratchType(rawValue: scratchID) {
                preferences.scratchType = scratchType
            }
            if let preferredBPM {
                preferences.bpm = CaptureClickTrackDefaults.clampedBPM(preferredBPM)
            }
        }
    }

    func setBeatEnabled(_ enabled: Bool) {
        updatePreferences { preferences in
            preferences.captureMode = enabled ? .timedClick : .calibrationNoClick
            preferences.beatEngineMode = enabled ? preferences.lastAudibleBeatMode : .silent
        }

        if enabled {
            restartPlaybackIfNeeded()
        } else {
            stopPlayback()
        }
    }

    func selectBeatMode(_ mode: BeatEngineMode) {
        guard mode != .silent else {
            setBeatEnabled(false)
            return
        }

        updatePreferences { preferences in
            preferences.lastAudibleBeatMode = mode
            if preferences.captureMode == .timedClick {
                preferences.beatEngineMode = mode
            }
        }
        restartPlaybackIfNeeded()
    }

    func setBPM(_ bpm: Int) {
        updatePreferences { preferences in
            preferences.bpm = CaptureClickTrackDefaults.clampedBPM(bpm)
        }
        restartPlaybackIfNeeded()
    }

    func stepBPM(by step: Int) {
        setBPM(preferences.bpm + step)
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        guard isBeatEnabled else { return }

        playbackErrorMessage = nil
        do {
            try beatEngine.start(mode: preferences.beatEngineMode, bpm: preferences.bpm)
            isPlaying = true
        } catch {
            isPlaying = false
            playbackErrorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        beatEngine.stop()
        isPlaying = false
    }

    func handleLeavingPractice() {
        stopPlayback()
    }

    func handleAppDidBecomeInactive() {
        stopPlayback()
    }

    func handleRecordingFlowStarted() {
        stopPlayback()
    }

    func applyToRecordSetup(_ sessionSetup: SessionSetupViewModel) {
        sessionSetup.scratchType = preferences.scratchType
        sessionSetup.bpmText = String(preferences.bpm)
        guard isBeatEnabled else { return }
        sessionSetup.captureMode = .timedClick
        sessionSetup.beatEngineMode = preferences.beatEngineMode
    }

    private func restartPlaybackIfNeeded() {
        guard isPlaying else { return }
        stopPlayback()
        startPlayback()
    }

    private func updatePreferences(_ update: (inout PracticeBeatPreferences) -> Void) {
        var nextPreferences = preferences
        update(&nextPreferences)
        nextPreferences = Self.normalizedPreferences(nextPreferences)
        preferences = nextPreferences
        playbackErrorMessage = nil
        persistPreferences()
    }

    private func persistPreferences() {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func normalizedPreferences(_ preferences: PracticeBeatPreferences) -> PracticeBeatPreferences {
        var normalizedPreferences = preferences
        normalizedPreferences.bpm = CaptureClickTrackDefaults.clampedBPM(preferences.bpm)
        if normalizedPreferences.lastAudibleBeatMode == .silent {
            normalizedPreferences.lastAudibleBeatMode = .clickTrack
        }
        if normalizedPreferences.captureMode == .calibrationNoClick {
            normalizedPreferences.beatEngineMode = .silent
        } else if normalizedPreferences.beatEngineMode == .silent {
            normalizedPreferences.beatEngineMode = normalizedPreferences.lastAudibleBeatMode
        }
        return normalizedPreferences
    }
}

struct ScratchCoachInstruction: Codable, Equatable, Sendable {
    let scratchType: String
    let scratchDisplayName: String
    let instructionSummary: String
    let coachScript: String
    let steps: [String]
    let commonMistake: String
    let practiceChallenge: String
    let difficulty: String
    let sourceReference: String
    let rightsStatus: String
    let reviewStatus: String
    let demoAudioFile: String?
    let demoAudioRole: String
    let poseKeyframesFile: String?
    let controllerKeyframesFile: String?
    let sourceAngle: String?
    let motionReferenceType: String?

    private enum CodingKeys: String, CodingKey {
        case scratchType
        case scratchDisplayName
        case instructionSummary
        case coachScript
        case steps
        case commonMistake
        case practiceChallenge
        case difficulty
        case sourceReference
        case rightsStatus
        case reviewStatus
        case demoAudioFile
        case demoAudioRole
        case poseKeyframesFile
        case controllerKeyframesFile
        case sourceAngle
        case motionReferenceType
    }

    init(
        scratchType: String,
        scratchDisplayName: String,
        instructionSummary: String,
        coachScript: String,
        steps: [String],
        commonMistake: String,
        practiceChallenge: String,
        difficulty: String,
        sourceReference: String,
        rightsStatus: String,
        reviewStatus: String,
        demoAudioFile: String? = nil,
        demoAudioRole: String = "noBeat",
        poseKeyframesFile: String? = nil,
        controllerKeyframesFile: String? = nil,
        sourceAngle: String? = nil,
        motionReferenceType: String? = nil
    ) {
        self.scratchType = scratchType
        self.scratchDisplayName = scratchDisplayName
        self.instructionSummary = instructionSummary
        self.coachScript = coachScript
        self.steps = steps
        self.commonMistake = commonMistake
        self.practiceChallenge = practiceChallenge
        self.difficulty = difficulty
        self.sourceReference = sourceReference
        self.rightsStatus = rightsStatus
        self.reviewStatus = reviewStatus
        self.demoAudioFile = demoAudioFile
        self.demoAudioRole = demoAudioRole
        self.poseKeyframesFile = poseKeyframesFile
        self.controllerKeyframesFile = controllerKeyframesFile
        self.sourceAngle = sourceAngle
        self.motionReferenceType = motionReferenceType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scratchType = try container.decode(String.self, forKey: .scratchType)
        scratchDisplayName = try container.decode(String.self, forKey: .scratchDisplayName)
        instructionSummary = try container.decode(String.self, forKey: .instructionSummary)
        coachScript = try container.decode(String.self, forKey: .coachScript)
        steps = try container.decode([String].self, forKey: .steps)
        commonMistake = try container.decode(String.self, forKey: .commonMistake)
        practiceChallenge = try container.decode(String.self, forKey: .practiceChallenge)
        difficulty = try container.decode(String.self, forKey: .difficulty)
        sourceReference = try container.decode(String.self, forKey: .sourceReference)
        rightsStatus = try container.decode(String.self, forKey: .rightsStatus)
        reviewStatus = try container.decode(String.self, forKey: .reviewStatus)
        demoAudioFile = try container.decodeIfPresent(String.self, forKey: .demoAudioFile)
        demoAudioRole = try container.decodeIfPresent(String.self, forKey: .demoAudioRole) ?? "noBeat"
        poseKeyframesFile = try container.decodeIfPresent(String.self, forKey: .poseKeyframesFile)
        controllerKeyframesFile = try container.decodeIfPresent(String.self, forKey: .controllerKeyframesFile)
        sourceAngle = try container.decodeIfPresent(String.self, forKey: .sourceAngle)
        motionReferenceType = try container.decodeIfPresent(String.self, forKey: .motionReferenceType)
    }

    var showsStructuredCoaching: Bool {
        !steps.isEmpty || !commonMistake.isEmpty || !practiceChallenge.isEmpty
    }

    var hasDemoAudioReference: Bool {
        guard let demoAudioFile else { return false }
        return !demoAudioFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func neutralState() -> ScratchCoachInstruction {
        ScratchCoachInstruction(
            scratchType: "",
            scratchDisplayName: "Scratch Coach",
            instructionSummary: "Choose a scratch to see coaching tips.",
            coachScript: "Select a scratch to load local coaching notes.",
            steps: [],
            commonMistake: "",
            practiceChallenge: "",
            difficulty: "coach",
            sourceReference: "local_fallback",
            rightsStatus: "original_text",
            reviewStatus: "fallback",
            demoAudioFile: nil,
            demoAudioRole: "noBeat"
        )
    }

    static func unavailableState(
        scratchType: String,
        scratchDisplayName: String
    ) -> ScratchCoachInstruction {
        ScratchCoachInstruction(
            scratchType: scratchType,
            scratchDisplayName: scratchDisplayName,
            instructionSummary: "Coach tip unavailable",
            coachScript: "This scratch does not have a local coach note yet.",
            steps: [],
            commonMistake: "",
            practiceChallenge: "",
            difficulty: "coach",
            sourceReference: "local_fallback",
            rightsStatus: "original_text",
            reviewStatus: "fallback",
            demoAudioFile: nil,
            demoAudioRole: "noBeat"
        )
    }
}

func normalizeScratchType(input: String) -> String {
    input
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
}

@MainActor
final class ScratchCoachInstructionStore {
    static let shared = ScratchCoachInstructionStore()

    private static let coachInstructionsDirectory = "CoachInstructions"
    private static let scratchTypeAliases = [
        "baby": "baby",
        "babyscratch": "baby",
        "chirpflare": "chirpflare"
    ]

    private let bundle: Bundle
    private let dataProvider: ((String) -> Data?)?
    private let decoder = JSONDecoder()
    private var cache: [String: ScratchCoachInstruction] = [:]
    private let logger = Logger(subsystem: "ScratchLab", category: "ScratchCoachInstructionStore")

    init(
        bundle: Bundle = .main,
        dataProvider: ((String) -> Data?)? = nil
    ) {
        self.bundle = bundle
        self.dataProvider = dataProvider
    }

    func instruction(
        for scratchType: String?,
        scratchDisplayName: String? = nil
    ) -> ScratchCoachInstruction {
        let resourceNames = Self.resourceNames(
            for: scratchType,
            scratchDisplayName: scratchDisplayName
        )
        guard let fallbackScratchType = Self.lookupScratchType(
            for: scratchType,
            scratchDisplayName: scratchDisplayName
        ), !resourceNames.isEmpty else {
            return .neutralState()
        }

        let fallbackInstruction = ScratchCoachInstruction.unavailableState(
            scratchType: fallbackScratchType,
            scratchDisplayName: Self.fallbackDisplayName(
                for: fallbackScratchType,
                scratchDisplayName: scratchDisplayName
            )
        )

        for resourceName in resourceNames {
            if let cachedInstruction = cache[resourceName] {
                return cachedInstruction
            }

            guard let instructionData = loadData(for: resourceName) else {
                continue
            }

            do {
                let instruction = try decoder.decode(ScratchCoachInstruction.self, from: instructionData)
                cache[resourceName] = instruction
                return instruction
            } catch {
                logger.error("Failed to decode coach instruction \(resourceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return fallbackInstruction
    }

    private func loadData(for resourceName: String) -> Data? {
        if let dataProvider {
            return dataProvider(resourceName)
        }
        guard let fileURL = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: Self.coachInstructionsDirectory
        ) else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    private static func resourceName(for scratchType: String) -> String? {
        let normalizedType = normalizeScratchType(input: scratchType)
        guard !normalizedType.isEmpty else { return nil }
        return scratchTypeAliases[normalizedType] ?? normalizedType
    }

    private static func resourceNames(
        for scratchType: String?,
        scratchDisplayName: String?
    ) -> [String] {
        var seen = Set<String>()
        return [scratchType, scratchDisplayName]
            .compactMap { $0 }
            .compactMap { resourceName(for: $0) }
            .filter { seen.insert($0).inserted }
    }

    private static func lookupScratchType(
        for scratchType: String?,
        scratchDisplayName: String?
    ) -> String? {
        [scratchType, scratchDisplayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func fallbackDisplayName(
        for scratchType: String,
        scratchDisplayName: String?
    ) -> String {
        let trimmedDisplayName = scratchDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDisplayName.isEmpty else {
            let pieces = scratchType
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
            if pieces.isEmpty {
                return "Scratch Coach"
            }
            return pieces
                .map { $0.capitalized }
                .joined(separator: " ")
        }
        return trimmedDisplayName
    }
}

enum ScratchCoachDemoPlaybackState: String, Equatable, Sendable {
    case stopped
    case playing
    case paused
}

protocol ScratchCoachDemoPlayable: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    func prepareToPlay()
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

private final class ScratchCoachAVAudioPlayerAdapter: ScratchCoachDemoPlayable {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    func prepareToPlay() {
        player.prepareToPlay()
    }

    @discardableResult
    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }
}

@MainActor
final class ScratchCoachDemoAudioPlayer: ObservableObject {
    typealias ResourceURLProvider = (String) -> URL?
    typealias PlayerFactory = (URL) throws -> ScratchCoachDemoPlayable

    @Published private(set) var playbackState: ScratchCoachDemoPlaybackState = .stopped
    @Published private(set) var isAudioAvailable = false

    private let resourceURLProvider: ResourceURLProvider
    private let playerFactory: PlayerFactory
    private let logger = Logger(subsystem: "ScratchLab", category: "ScratchCoachDemoAudioPlayer")
    private var player: ScratchCoachDemoPlayable?
    private var currentAudioFile: String?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        resourceURLProvider: @escaping ResourceURLProvider = ScratchCoachDemoAudioPlayer.defaultResourceURLProvider(in: .main),
        playerFactory: @escaping PlayerFactory = { try ScratchCoachAVAudioPlayerAdapter(url: $0) }
    ) {
        self.resourceURLProvider = resourceURLProvider
        self.playerFactory = playerFactory
        registerLifecycleObservers()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isPlaying: Bool {
        playbackState == .playing
    }

    var currentPlaybackTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var isActivelyPlayingAudio: Bool {
        player?.isPlaying ?? false
    }

    func configure(with instruction: ScratchCoachInstruction) {
        let nextAudioFile = Self.normalizedAudioFileName(instruction.demoAudioFile)
        guard nextAudioFile != currentAudioFile || (nextAudioFile != nil && player == nil) else { return }

        clearLoadedAudio()
        currentAudioFile = nextAudioFile

        guard let nextAudioFile,
              let audioURL = resourceURLProvider(nextAudioFile) else {
            return
        }

        do {
            let nextPlayer = try playerFactory(audioURL)
            nextPlayer.prepareToPlay()
            player = nextPlayer
            isAudioAvailable = true
            playbackState = .stopped
        } catch {
            logger.error("Failed to load coach demo audio \(nextAudioFile, privacy: .public): \(error.localizedDescription, privacy: .public)")
            clearLoadedAudio()
        }
    }

    func play() {
        guard let player, isAudioAvailable else { return }
        if player.play() {
            playbackState = .playing
        }
    }

    func pause() {
        guard let player, isAudioAvailable else { return }
        player.pause()
        playbackState = .paused
    }

    func replay() {
        guard let player, isAudioAvailable else { return }
        player.currentTime = 0
        if player.play() {
            playbackState = .playing
        }
    }

    func stop() {
        guard let player else {
            playbackState = .stopped
            return
        }
        player.stop()
        player.currentTime = 0
        playbackState = .stopped
    }

    nonisolated static func bundledDemoAudioURL(
        named audioName: String,
        in bundle: Bundle = .main
    ) -> URL? {
        let searchDirectories: [String?] = ["CoachDemoAudio", nil]
        let trimmedName = audioName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let nsName = trimmedName as NSString
        let baseName = nsName.deletingPathExtension
        let explicitExtension = nsName.pathExtension

        if !explicitExtension.isEmpty {
            for directory in searchDirectories {
                if let explicitURL = bundle.url(
                    forResource: baseName,
                    withExtension: explicitExtension,
                    subdirectory: directory
                ) {
                    return explicitURL
                }
            }
        }

        for directory in searchDirectories {
            if let exactURL = bundle.url(
                forResource: trimmedName,
                withExtension: nil,
                subdirectory: directory
            ) {
                return exactURL
            }
        }

        for candidateExtension in ["m4a", "wav", "aiff", "caf", "mp3"] {
            for directory in searchDirectories {
                if let bundledURL = bundle.url(
                    forResource: trimmedName,
                    withExtension: candidateExtension,
                    subdirectory: directory
                ) {
                    return bundledURL
                }
                if let baseURL = bundle.url(
                    forResource: baseName,
                    withExtension: candidateExtension,
                    subdirectory: directory
                ) {
                    return baseURL
                }
            }
        }

        return nil
    }

    nonisolated private static func defaultResourceURLProvider(in bundle: Bundle) -> ResourceURLProvider {
        { audioName in
            bundledDemoAudioURL(named: audioName, in: bundle)
        }
    }

    nonisolated private static func normalizedAudioFileName(_ audioFile: String?) -> String? {
        guard let audioFile else { return nil }
        let trimmed = audioFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearLoadedAudio() {
        stop()
        player = nil
        isAudioAvailable = false
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        #if canImport(UIKit)
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
                }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
                }
            }
        )
        #elseif canImport(AppKit)
        lifecycleObservers.append(
            center.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
                }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
                }
            }
        )
        #endif
    }
}

struct ScratchCoachDemoAnimationState: Equatable, Sendable {
    let recordPosition: Double
    let recordRotationDegrees: Double
    let crossfaderPosition: Double
    let crossfaderOpenState: Bool

    static let neutral = ScratchCoachDemoAnimationState(
        recordPosition: 0,
        recordRotationDegrees: 0,
        crossfaderPosition: 0,
        crossfaderOpenState: false
    )
}

struct ScratchCoachDemoAnimator: Sendable {
    static func state(
        scratchType: String,
        playbackTime: TimeInterval,
        isPlaying: Bool
    ) -> ScratchCoachDemoAnimationState {
        guard isPlaying else { return .neutral }

        switch normalizedScratchType(scratchType) {
        case "baby":
            return babyState(playbackTime: playbackTime)
        case "chirpflare":
            return chirpFlareState(playbackTime: playbackTime)
        default:
            return .neutral
        }
    }

    private static func babyState(playbackTime: TimeInterval) -> ScratchCoachDemoAnimationState {
        let recordMotion = recordMotionState(
            playbackTime: playbackTime,
            cycleDuration: 1.0,
            rotationAmplitude: 26
        )
        return ScratchCoachDemoAnimationState(
            recordPosition: recordMotion.position,
            recordRotationDegrees: recordMotion.rotationDegrees,
            crossfaderPosition: 1,
            crossfaderOpenState: true
        )
    }

    private static func chirpFlareState(playbackTime: TimeInterval) -> ScratchCoachDemoAnimationState {
        let cycleDuration: TimeInterval = 0.84
        let recordMotion = recordMotionState(
            playbackTime: playbackTime,
            cycleDuration: cycleDuration,
            rotationAmplitude: 34
        )
        let cycleProgress = normalizedProgress(
            playbackTime: playbackTime,
            cycleDuration: cycleDuration
        )
        let crossfaderPulse = max(
            triangularPulse(progress: cycleProgress, center: 0.18, width: 0.18),
            triangularPulse(progress: cycleProgress, center: 0.68, width: 0.18)
        )

        return ScratchCoachDemoAnimationState(
            recordPosition: recordMotion.position,
            recordRotationDegrees: recordMotion.rotationDegrees,
            crossfaderPosition: crossfaderPulse,
            crossfaderOpenState: crossfaderPulse > 0.18
        )
    }

    private static func recordMotionState(
        playbackTime: TimeInterval,
        cycleDuration: TimeInterval,
        rotationAmplitude: Double
    ) -> (position: Double, rotationDegrees: Double) {
        let progress = normalizedProgress(
            playbackTime: playbackTime,
            cycleDuration: cycleDuration
        )
        let position = sin(progress * 2 * .pi)
        return (
            position: position,
            rotationDegrees: position * rotationAmplitude
        )
    }

    private static func normalizedProgress(
        playbackTime: TimeInterval,
        cycleDuration: TimeInterval
    ) -> Double {
        guard cycleDuration > 0 else { return 0 }
        let normalizedTime = playbackTime.truncatingRemainder(dividingBy: cycleDuration)
        return normalizedTime / cycleDuration
    }

    private static func triangularPulse(
        progress: Double,
        center: Double,
        width: Double
    ) -> Double {
        guard width > 0 else { return 0 }
        let halfWidth = width / 2
        let distance = abs(progress - center)
        guard distance <= halfWidth else { return 0 }
        return 1 - (distance / halfWidth)
    }

    private static func normalizedScratchType(_ scratchType: String) -> String {
        let normalizedScratchType = normalizeScratchType(input: scratchType)
        switch normalizedScratchType {
        case "baby", "babyscratch":
            return "baby"
        case "chirpflare":
            return "chirpflare"
        default:
            return normalizedScratchType
        }
    }
}

struct RoutineSessionDraft: Codable, Equatable, Identifiable, Sendable {
    var id: String { config.sessionID }
    var config: CaptureSessionConfig
}

protocol SessionListPresentable {
    var sessionListID: String { get }
    var sessionListCreatedAt: Date { get }
    var sessionListFallbackOpenedAt: Date { get }
}

extension CaptureSessionConfig: SessionListPresentable {
    var sessionListID: String { sessionID }

    var sessionListCreatedAt: Date { createdAt }

    var sessionListFallbackOpenedAt: Date {
        max(updatedAt, createdAt)
    }
}

extension RoutineSessionDraft: SessionListPresentable {
    var sessionListID: String { id }

    var sessionListCreatedAt: Date { config.createdAt }

    var sessionListFallbackOpenedAt: Date {
        config.sessionListFallbackOpenedAt
    }
}

enum SessionListPolicy {
    static let maximumRecentSessionCount = 3
    static let staleDraftRetentionInterval: TimeInterval = 24 * 60 * 60
}

struct SessionListPresentationModel<Session: SessionListPresentable & Sendable>: Sendable {
    struct Entry: Identifiable, Sendable {
        let session: Session
        let lastOpenedAt: Date

        var id: String { session.sessionListID }
    }

    let activeSession: Entry?
    let recentSessions: [Entry]
    let allSessions: [Entry]
    let pinnedSessions: [Entry]?

    init(
        sessions: [Session],
        activeSessionID: String?,
        lastOpenedAtBySessionID: [String: Date],
        maxRecentSessions: Int = SessionListPolicy.maximumRecentSessionCount
    ) {
        let allEntries = sessions
            .map { session in
                Entry(
                    session: session,
                    lastOpenedAt: lastOpenedAtBySessionID[session.sessionListID]
                        ?? session.sessionListFallbackOpenedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.lastOpenedAt != rhs.lastOpenedAt {
                    return lhs.lastOpenedAt > rhs.lastOpenedAt
                }
                if lhs.session.sessionListCreatedAt != rhs.session.sessionListCreatedAt {
                    return lhs.session.sessionListCreatedAt > rhs.session.sessionListCreatedAt
                }
                return lhs.id > rhs.id
            }

        let resolvedActiveSession = activeSessionID.flatMap { activeSessionID in
            allEntries.first(where: { $0.id == activeSessionID })
        } ?? allEntries.first

        activeSession = resolvedActiveSession
        recentSessions = Array(
            allEntries
                .filter { $0.id != resolvedActiveSession?.id }
                .prefix(maxRecentSessions)
        )
        allSessions = allEntries
        pinnedSessions = nil
    }

}

@MainActor
final class SessionOpenHistoryStore: ObservableObject {
    @Published private(set) var lastOpenedAtBySessionID: [String: Date]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let nowProvider: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.nowProvider = nowProvider
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        if let data = defaults.data(forKey: defaultsKey),
           let loadedHistory = try? decoder.decode([String: Date].self, from: data) {
            lastOpenedAtBySessionID = loadedHistory
        } else {
            lastOpenedAtBySessionID = [:]
        }
    }

    func updateLastOpenedAt(sessionID: String) {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return }

        lastOpenedAtBySessionID[trimmedSessionID] = nowProvider()
        persist()
    }

    func prune(keepingSessionIDs: Set<String>) {
        let prunedHistory = lastOpenedAtBySessionID.filter { keepingSessionIDs.contains($0.key) }
        guard prunedHistory != lastOpenedAtBySessionID else { return }

        lastOpenedAtBySessionID = prunedHistory
        persist()
    }

    func clearAll() {
        guard !lastOpenedAtBySessionID.isEmpty || defaults.object(forKey: defaultsKey) != nil else {
            return
        }

        lastOpenedAtBySessionID = [:]
        defaults.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        guard let data = try? encoder.encode(lastOpenedAtBySessionID) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

struct RoutineSessionDraftStoreSnapshot: Codable, Equatable, Sendable {
    var sessions: [RoutineSessionDraft]
    var selectedSessionID: String?
}

private extension RoutineSessionDraft {
    var lastActivityAt: Date {
        max(config.updatedAt, config.createdAt)
    }

    var hasRecordedTakeMetrics: Bool {
        config.takeCount > 0 || (config.takeDurationSeconds ?? 0) > 0
    }
}

@MainActor
final class RoutineSessionStore: ObservableObject {
    struct AlertState: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var sessions: [RoutineSessionDraft]
    @Published private(set) var selectedSessionID: String?
    @Published var alertState: AlertState?

    private let storageURL: URL
    private let fileManager: FileManager
    private let nowProvider: () -> Date
    private let sessionIDProvider: () -> String
    private let sessionOpenHistoryStore: SessionOpenHistoryStore
    private let logger = Logger(subsystem: "com.machelpnz.scratchlab.mac", category: "RoutineSessionStore")
    private var cancellables: Set<AnyCancellable> = []
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        nowProvider: @escaping () -> Date = Date.init,
        sessionIDProvider: @escaping () -> String = SessionIdentity.makeSessionID,
        sessionOpenHistoryDefaults: UserDefaults = .standard,
        sessionOpenHistoryKey: String = "routineSession.lastOpenedAt"
    ) {
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.sessionIDProvider = sessionIDProvider
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        self.sessionOpenHistoryStore = SessionOpenHistoryStore(
            defaults: sessionOpenHistoryDefaults,
            defaultsKey: sessionOpenHistoryKey,
            nowProvider: nowProvider
        )

        let loadedSnapshot = Self.loadSnapshot(
            from: self.storageURL,
            fileManager: fileManager,
            decoder: decoder
        )
        sessions = loadedSnapshot.sessions
        if let loadedSelection = loadedSnapshot.selectedSessionID,
           loadedSnapshot.sessions.contains(where: { $0.id == loadedSelection }) {
            selectedSessionID = loadedSelection
        } else {
            selectedSessionID = loadedSnapshot.sessions.first?.id
        }
        pruneDiscardableSessions(persistIfNeeded: true)

        sessionOpenHistoryStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var selectedSession: RoutineSessionDraft? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var sessionListPresentation: SessionListPresentationModel<RoutineSessionDraft> {
        SessionListPresentationModel(
            sessions: sessions,
            activeSessionID: selectedSessionID,
            lastOpenedAtBySessionID: sessionOpenHistoryStore.lastOpenedAtBySessionID
        )
    }

    @discardableResult
    func createNewSessionFromUI() -> RoutineSessionDraft? {
        logger.info("Routine session create-new started.")

        let previousSnapshot = snapshot()
        let draft = CaptureCore.createNewRoutineSessionDraft(
            sessionID: sessionIDProvider(),
            now: nowProvider()
        )

        sessions.insert(draft, at: 0)
        selectedSessionID = draft.id
        pruneDiscardableSessions()

        do {
            try persist()
            sessionOpenHistoryStore.prune(keepingSessionIDs: Set(sessions.map(\.id)))
            sessionOpenHistoryStore.updateLastOpenedAt(sessionID: draft.id)
            print("NEW_SESSION_CREATED:", draft.id)
            alertState = nil
            logger.info(
                "Routine session create-new succeeded for sessionID=\(draft.id, privacy: .public)."
            )
            return draft
        } catch {
            restore(previousSnapshot)
            presentPersistenceFailure(
                action: "create a new session",
                error: error
            )
            logger.error(
                "Routine session create-new failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func openSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }

        if selectedSessionID == id {
            sessionOpenHistoryStore.updateLastOpenedAt(sessionID: id)
            alertState = nil
            return
        }

        let previousSnapshot = snapshot()
        selectedSessionID = id

        do {
            try persist()
            sessionOpenHistoryStore.updateLastOpenedAt(sessionID: id)
            alertState = nil
        } catch {
            restore(previousSnapshot)
            presentPersistenceFailure(
                action: "switch sessions",
                error: error
            )
            logger.error(
                "Routine session selection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func selectSession(id: String) {
        openSession(id: id)
    }

    func updateLastOpenedAt(sessionID: String) {
        sessionOpenHistoryStore.updateLastOpenedAt(sessionID: sessionID)
    }

    func updateSelectedSession(config: CaptureSessionConfig) {
        guard let selectedSessionID,
              let selectedIndex = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            return
        }

        let previousSnapshot = snapshot()
        sessions[selectedIndex] = RoutineSessionDraft(config: config)
        pruneDiscardableSessions()

        do {
            try persist()
            sessionOpenHistoryStore.prune(keepingSessionIDs: Set(sessions.map(\.id)))
            alertState = nil
        } catch {
            restore(previousSnapshot)
            presentPersistenceFailure(
                action: "save session details",
                error: error
            )
            logger.error(
                "Routine session detail save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func dismissAlert() {
        alertState = nil
    }

    static func defaultStorageURL(fileManager: FileManager = .default) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? {
#if os(macOS)
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
#else
                fileManager.temporaryDirectory
#endif
            }()

        return baseDirectory
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineSessionDrafts.json")
    }

    private func snapshot() -> RoutineSessionDraftStoreSnapshot {
        RoutineSessionDraftStoreSnapshot(
            sessions: sessions,
            selectedSessionID: selectedSessionID
        )
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot())
        try data.write(to: storageURL, options: .atomic)
    }

    private func restore(_ snapshot: RoutineSessionDraftStoreSnapshot) {
        sessions = snapshot.sessions
        selectedSessionID = snapshot.selectedSessionID
    }

    private func pruneDiscardableSessions(persistIfNeeded: Bool = false) {
        let staleCutoff = nowProvider().addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval)
        let retainedSessions = sessions.filter { session in
            shouldRetainSession(session, staleCutoff: staleCutoff)
        }
        let retainedSessionIDs = Set(retainedSessions.map(\.id))
        let resolvedSelectedSessionID: String?

        if let selectedSessionID,
           retainedSessionIDs.contains(selectedSessionID) {
            resolvedSelectedSessionID = selectedSessionID
        } else {
            resolvedSelectedSessionID = retainedSessions.first?.id
        }

        let didChange = retainedSessions != sessions || resolvedSelectedSessionID != selectedSessionID
        sessions = retainedSessions
        selectedSessionID = resolvedSelectedSessionID
        sessionOpenHistoryStore.prune(keepingSessionIDs: retainedSessionIDs)

        guard didChange, persistIfNeeded else { return }

        do {
            try persist()
        } catch {
            logger.error(
                "Routine session stale-draft pruning failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func shouldRetainSession(_ session: RoutineSessionDraft, staleCutoff: Date) -> Bool {
        if session.id == selectedSessionID {
            return true
        }

        if session.hasRecordedTakeMetrics {
            return true
        }

        if hasRoutineCaptureArtifacts(for: session.id) {
            return true
        }

        if hasPersistedUploadJob(for: session.id) {
            return true
        }

        return session.lastActivityAt >= staleCutoff
    }

    private func hasRoutineCaptureArtifacts(for sessionID: String) -> Bool {
        let routineCapturesDirectory = scratchLabStorageRootURL()
            .appendingPathComponent("RoutineCaptures", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: routineCapturesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { entry in
            CaptureCore.LocalRecordingNaming.appLocalTakeNumber(
                for: entry.deletingPathExtension().lastPathComponent,
                sessionID: sessionID
            ) != nil
        }
    }

    private func hasPersistedUploadJob(for sessionID: String) -> Bool {
        let uploadsRootDirectory = sharedApplicationSupportBaseURL()
            .appendingPathComponent("ScratchLabUploads", isDirectory: true)
        let jobFileURL = uploadsRootDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("job.json")
        return fileManager.fileExists(atPath: jobFileURL.path)
    }

    private func scratchLabStorageRootURL() -> URL {
        storageURL.deletingLastPathComponent()
    }

    private func sharedApplicationSupportBaseURL() -> URL {
        let scratchLabRoot = scratchLabStorageRootURL()
        if scratchLabRoot.lastPathComponent == "ScratchLab" {
            return scratchLabRoot.deletingLastPathComponent()
        }
        return scratchLabRoot
    }

    private func presentPersistenceFailure(action: String, error _: Error) {
        alertState = AlertState(
            title: "Session Update Failed",
            message: "ScratchLab couldn't \(action). Try again. If the problem continues, reopen the app."
        )
    }

    private static func loadSnapshot(
        from storageURL: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> RoutineSessionDraftStoreSnapshot {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return RoutineSessionDraftStoreSnapshot(sessions: [], selectedSessionID: nil)
        }

        do {
            let data = try Data(contentsOf: storageURL)
            return try decoder.decode(RoutineSessionDraftStoreSnapshot.self, from: data)
        } catch {
            return RoutineSessionDraftStoreSnapshot(sessions: [], selectedSessionID: nil)
        }
    }
}

@MainActor
enum RoutineSessionUIActionFactory {
    static func makeCreateNewSessionAction(
        for store: RoutineSessionStore,
        onSuccess: ((RoutineSessionDraft) -> Void)? = nil
    ) -> () -> Void {
        {
            guard let session = store.createNewSessionFromUI() else { return }
            onSuccess?(session)
        }
    }
}

enum CaptureCore {
    static func createNewRoutineSessionDraft(
        sessionID: String = SessionIdentity.makeSessionID(),
        now: Date = Date()
    ) -> RoutineSessionDraft {
        RoutineSessionDraft(
            config: .routineCapture(
                sessionID: sessionID,
                createdAt: now,
                updatedAt: now,
                takeCount: 0,
                takeDurationSeconds: nil
            )
        )
    }

    enum LocalRecordingSurface: String {
        case iosCompanion = "ios-companion"
        case macRoutine = "mac-routine"
    }

    enum LocalRecordingNaming {
        private static let takePrefixSeparator = "_take"

        static func sessionID() -> String {
            SessionIdentity.makeSessionID()
        }

        static func takeID(takeNumber: Int) -> String {
            "take-\(paddedTakeNumber(takeNumber))"
        }

        static func takeIdentity(sessionID: String, takeNumber: Int) -> TakeIdentity {
            TakeIdentity(
                sessionID: sessionID,
                takeID: takeID(takeNumber: takeNumber),
                takeNumber: takeNumber
            )
        }

        static func baseName(sessionID: String, takeNumber: Int, roleLabel: String) -> String {
            "\(sessionID)\(takePrefixSeparator)\(paddedTakeNumber(takeNumber))_\(roleLabel)"
        }

        static func nextTakeNumber(in directory: URL, sessionID: String, fileManager: FileManager = .default) throws -> Int {
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let highestTakeNumber = entries.compactMap { entry in
                appLocalTakeNumber(for: entry.deletingPathExtension().lastPathComponent, sessionID: sessionID)
            }.max() ?? 0
            return highestTakeNumber + 1
        }

        static func appLocalTakeNumber(for baseName: String, sessionID: String) -> Int? {
            let prefix = "\(sessionID)\(takePrefixSeparator)"
            guard baseName.hasPrefix(prefix) else { return nil }
            let digits = baseName.dropFirst(prefix.count).prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(String(digits))
        }

        static func paddedTakeNumber(_ takeNumber: Int) -> String {
            String(format: "%03d", takeNumber)
        }
    }

    struct LocalRecordingFiles: Equatable {
        let baseName: String
        let mediaURL: URL
        let sidecarURL: URL

        static func make(
            in directory: URL,
            sessionID: String,
            takeNumber: Int,
            roleLabel: String,
            mediaExtension: String = "mov",
            sidecarExtension: String = "json",
            fileManager: FileManager = .default
        ) throws -> LocalRecordingFiles {
            let baseName = LocalRecordingNaming.baseName(
                sessionID: sessionID,
                takeNumber: takeNumber,
                roleLabel: roleLabel
            )
            let mediaURL = directory.appendingPathComponent(baseName).appendingPathExtension(mediaExtension)
            let sidecarURL = directory.appendingPathComponent(baseName).appendingPathExtension(sidecarExtension)

            guard !fileManager.fileExists(atPath: mediaURL.path),
                  !fileManager.fileExists(atPath: sidecarURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }

            return LocalRecordingFiles(baseName: baseName, mediaURL: mediaURL, sidecarURL: sidecarURL)
        }

        static func sidecarURL(forMediaURL mediaURL: URL, sidecarExtension: String = "json") -> URL {
            mediaURL.deletingPathExtension().appendingPathExtension(sidecarExtension)
        }
    }

    struct LocalRecordingSidecar: Codable, Equatable {
        static let currentSchemaVersion = "scratchlab_local_recording_sidecar_v1"

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return encoder
        }()

        let schemaVersion: String
        let sessionID: String
        let sessionConfig: CaptureSessionConfig?
        let takeID: String
        let appLocalTakeNumber: Int
        let recordingRole: String
        let platform: String
        let appSurface: String
        let sourceDeviceName: String
        let cameraPosition: String?
        let audioInputName: String?
        let videoDeviceUniqueID: String?
        let videoDeviceName: String?
        let audioDeviceUniqueID: String?
        let audioDeviceName: String?
        let captureTiming: CaptureTimingMetadata?
        let startedAt: Date
        var endedAt: Date?
        var recordingStatus: String
        var mediaFileName: String
        let sidecarFileName: String
        var errorDescription: String?
        var watchSyncState: CaptureWatchSyncState
        var watchCommandID: String?
        var watchRequestedAt: Date?
        var watchAcknowledgedAt: Date?
        var linkedMotionCaptureID: UUID?
        var linkedMotionFileName: String?
        var auditTrail: [CaptureAuditEvent]

        init(
            schemaVersion: String = LocalRecordingSidecar.currentSchemaVersion,
            sessionID: String,
            sessionConfig: CaptureSessionConfig? = nil,
            takeID: String,
            appLocalTakeNumber: Int,
            recordingRole: String,
            platform: String,
            appSurface: String,
            sourceDeviceName: String,
            cameraPosition: String? = nil,
            audioInputName: String? = nil,
            videoDeviceUniqueID: String? = nil,
            videoDeviceName: String? = nil,
            audioDeviceUniqueID: String? = nil,
            audioDeviceName: String? = nil,
            captureTiming: CaptureTimingMetadata? = nil,
            startedAt: Date,
            endedAt: Date? = nil,
            recordingStatus: String,
            mediaFileName: String,
            sidecarFileName: String,
            errorDescription: String? = nil,
            watchSyncState: CaptureWatchSyncState = .notRequested,
            watchCommandID: String? = nil,
            watchRequestedAt: Date? = nil,
            watchAcknowledgedAt: Date? = nil,
            linkedMotionCaptureID: UUID? = nil,
            linkedMotionFileName: String? = nil,
            auditTrail: [CaptureAuditEvent] = []
        ) {
            self.schemaVersion = schemaVersion
            self.sessionID = sessionID
            self.sessionConfig = sessionConfig
            self.takeID = takeID
            self.appLocalTakeNumber = appLocalTakeNumber
            self.recordingRole = recordingRole
            self.platform = platform
            self.appSurface = appSurface
            self.sourceDeviceName = sourceDeviceName
            self.cameraPosition = cameraPosition
            self.audioInputName = audioInputName
            self.videoDeviceUniqueID = videoDeviceUniqueID
            self.videoDeviceName = videoDeviceName
            self.audioDeviceUniqueID = audioDeviceUniqueID
            self.audioDeviceName = audioDeviceName
            self.captureTiming = captureTiming
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.recordingStatus = recordingStatus
            self.mediaFileName = mediaFileName
            self.sidecarFileName = sidecarFileName
            self.errorDescription = errorDescription
            self.watchSyncState = watchSyncState
            self.watchCommandID = watchCommandID
            self.watchRequestedAt = watchRequestedAt
            self.watchAcknowledgedAt = watchAcknowledgedAt
            self.linkedMotionCaptureID = linkedMotionCaptureID
            self.linkedMotionFileName = linkedMotionFileName
            self.auditTrail = auditTrail
        }

        var recordingIdentity: String {
            "\(sessionID):\(takeID)"
        }

        static func recording(
            sessionID: String,
            sessionConfig: CaptureSessionConfig? = nil,
            takeIdentity: TakeIdentity,
            files: LocalRecordingFiles,
            recordingRole: String,
            platform: String,
            appSurface: String,
            sourceDeviceName: String,
            cameraPosition: String? = nil,
            audioInputName: String? = nil,
            videoDeviceUniqueID: String? = nil,
            videoDeviceName: String? = nil,
            audioDeviceUniqueID: String? = nil,
            audioDeviceName: String? = nil,
            captureTiming: CaptureTimingMetadata? = nil,
            startedAt: Date
        ) -> LocalRecordingSidecar {
            let takeEvent = CaptureAuditEvent(
                timestamp: startedAt,
                category: "take_allocated",
                detail: "Allocated \(takeIdentity.takeID) for session \(sessionID)."
            )

            return LocalRecordingSidecar(
                sessionID: sessionID,
                sessionConfig: sessionConfig,
                takeID: takeIdentity.takeID,
                appLocalTakeNumber: takeIdentity.takeNumber,
                recordingRole: recordingRole,
                platform: platform,
                appSurface: appSurface,
                sourceDeviceName: sourceDeviceName,
                cameraPosition: cameraPosition,
                audioInputName: audioInputName,
                videoDeviceUniqueID: videoDeviceUniqueID,
                videoDeviceName: videoDeviceName,
                audioDeviceUniqueID: audioDeviceUniqueID,
                audioDeviceName: audioDeviceName,
                captureTiming: captureTiming,
                startedAt: startedAt,
                recordingStatus: "recording",
                mediaFileName: files.mediaURL.lastPathComponent,
                sidecarFileName: files.sidecarURL.lastPathComponent,
                auditTrail: [takeEvent]
            )
        }

        func encodedData() throws -> Data {
            try Self.encoder.encode(self)
        }

        func finalized(
            endedAt: Date = Date(),
            mediaFileName: String,
            captureErrorDescription: String?
        ) -> LocalRecordingSidecar {
            var finalized = self
            finalized.endedAt = endedAt
            finalized.mediaFileName = mediaFileName
            finalized.recordingStatus = captureErrorDescription == nil ? "completed" : "failed"
            finalized.errorDescription = captureErrorDescription
            finalized.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: endedAt,
                    category: captureErrorDescription == nil ? "recording_completed" : "recording_failed",
                    detail: captureErrorDescription ?? "Recording completed successfully."
                )
            )
            return finalized
        }

        func withWatchSync(_ reply: WatchCaptureControlReply) -> LocalRecordingSidecar {
            var updated = self
            updated.watchSyncState = reply.syncState
            updated.watchCommandID = reply.commandID
            updated.watchRequestedAt = updated.watchRequestedAt ?? reply.acknowledgedAt
            updated.watchAcknowledgedAt = reply.acknowledgedAt
            updated.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: reply.acknowledgedAt ?? Date(),
                    category: "watch_sync",
                    detail: "Watch sync state set to \(reply.syncState.rawValue)."
                )
            )
            return updated
        }

        func withPendingWatchRequest(_ request: WatchCaptureCommandPayload) -> LocalRecordingSidecar {
            var updated = self
            updated.watchSyncState = .requested
            updated.watchCommandID = request.commandID
            updated.watchRequestedAt = request.requestedAt
            updated.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: request.requestedAt,
                    category: "watch_requested",
                    detail: "Requested watch capture for \(request.takeID ?? takeID)."
                )
            )
            return updated
        }

        func linkingWatchCapture(id: UUID, fileName: String) -> LocalRecordingSidecar {
            var updated = self
            updated.linkedMotionCaptureID = id
            updated.linkedMotionFileName = fileName
            updated.auditTrail.append(
                CaptureAuditEvent(
                    category: "watch_linked",
                    detail: "Linked watch capture \(fileName) to \(takeID)."
                )
            )
            return updated
        }
    }
}
