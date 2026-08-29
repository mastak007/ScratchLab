import Foundation
import Combine
import OSLog
import AVFoundation
import QuartzCore
import os.signpost
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum ScratchLabPerformanceSignpost {
    private static let log = OSLog(
        subsystem: "com.machelpnz.scratchlab",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        return signpostID
    }

    static func end(_ name: StaticString, _ signpostID: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: signpostID)
    }

    static func withInterval<T>(
        _ name: StaticString,
        _ work: () throws -> T
    ) rethrows -> T {
        let signpostID = begin(name)
        defer { end(name, signpostID) }
        return try work()
    }

    /// Fire-and-forget Points-of-Interest marker. Use for high-frequency
    /// signals like audio buffers / MIDI packets where opening an interval
    /// would add overhead without surfacing useful timing.
    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    /// Event with a single integer payload (counts).
    static func event(_ name: StaticString, count: Int) {
        os_signpost(.event, log: log, name: name, "count=%{public}d", count)
    }

    /// Event with a single double payload (seconds, ms, normalised value).
    static func event(_ name: StaticString, time: Double) {
        os_signpost(.event, log: log, name: name, "time=%{public}.4f", time)
    }

    /// Event with a count plus take number — useful for take-scoped pipeline
    /// stages so the Instruments timeline groups by take.
    static func event(_ name: StaticString, count: Int, take: Int) {
        os_signpost(.event, log: log, name: name, "count=%{public}d take=%{public}d", count, take)
    }

    /// Notation-snapshot event: records the three event-lane counts and the
    /// take number so a snapshot can be inspected without dumping payload.
    static func eventNotationSnapshot(
        movement: Int,
        audio: Int,
        fader: Int,
        take: Int
    ) {
        os_signpost(
            .event,
            log: log,
            name: "NotationSnapshotCreate",
            "movement=%{public}d audio=%{public}d fader=%{public}d take=%{public}d",
            movement,
            audio,
            fader,
            take
        )
    }
}

final class ScratchLabRuntimeDiagnostics: ObservableObject {
    static let shared = ScratchLabRuntimeDiagnostics()

    @Published private(set) var notationLastTickDurationMS: Double = 0
    @Published private(set) var notationTickRateHz: Double = 0
    @Published private(set) var coachLastUpdateDurationMS: Double = 0

    /// Slice O — diagnostics-only summary of audio-onset notation
    /// candidates produced by `AudioOnsetDetector` against the recent
    /// audio stream. Read-only from outside; never gates Practice,
    /// Review, scoring, export, or notation rendering.
    @Published private(set) var audioOnsetSummary: NotationCandidateDiagnosticsSummary = .empty

    /// Slice R0 — Review-curated summary derived from the same envelope
    /// as `audioOnsetSummary` but with the stricter `reviewPreview`
    /// detector config + a strength-ranked candidate cap. Used by the
    /// Review onset preview card so the count stays in a useful range
    /// (a few dozen) rather than the inclusive Advanced view (which can
    /// easily run into the hundreds on a long noisy take). Raw
    /// diagnostics surface in Advanced via `audioOnsetSummary` —
    /// untouched.
    @Published private(set) var audioOnsetReviewSummary: NotationCandidateDiagnosticsSummary = .empty

    /// Slice R1 — timestamps of the filtered Review candidates, in
    /// ascending order, capped to the same `maxCandidates` budget as
    /// `audioOnsetReviewSummary`. Drives the Review preview's visual
    /// timing-mark strip. Diagnostics-only; never reaches captured
    /// notation, scoring, or export. Empty when no audio activity has
    /// been accumulated.
    @Published private(set) var audioOnsetReviewMarks: [TimeInterval] = []

    private var notationTickWindowStartedAt: CFTimeInterval = 0
    private var notationTickCount = 0

    private let audioOnsetAccumulator = NotationCandidateAccumulator()
    private let audioOnsetQueue = DispatchQueue(
        label: "com.machelpnz.scratchlab.diagnostics.audioOnset",
        qos: .utility
    )
    private let audioOnsetSummaryInterval: TimeInterval = 0.20  // 5 Hz max
    private var audioOnsetLastSummaryAt: CFTimeInterval = 0

    private init() {}

    func recordNotationTick(durationSeconds: TimeInterval) {
        notationLastTickDurationMS = durationSeconds * 1_000
        let now = CACurrentMediaTime()
        if notationTickWindowStartedAt == 0 {
            notationTickWindowStartedAt = now
            notationTickCount = 0
        }
        notationTickCount += 1

        let elapsed = now - notationTickWindowStartedAt
        guard elapsed >= 1 else { return }
        notationTickRateHz = Double(notationTickCount) / elapsed
        notationTickWindowStartedAt = now
        notationTickCount = 0
    }

    func recordCoachRigUpdate(durationSeconds: TimeInterval) {
        coachLastUpdateDurationMS = durationSeconds * 1_000
    }

    func markNotationIdle() {
        notationLastTickDurationMS = 0
        notationTickRateHz = 0
        notationTickWindowStartedAt = 0
        notationTickCount = 0
    }

    /// Slice O — feed audio samples into the diagnostic accumulator.
    /// Throttles published summary updates to `audioOnsetSummaryInterval`
    /// so the @Published property doesn't churn at audio-packet rate.
    /// Safe to call from any thread.
    func recordAudioSamplesForOnsetDiagnostics(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        audioOnsetQueue.async { [weak self] in
            guard let self else { return }
            self.audioOnsetAccumulator.pushSamples(samples, sampleRate: sampleRate)
            let now = CACurrentMediaTime()
            if now - self.audioOnsetLastSummaryAt < self.audioOnsetSummaryInterval {
                return
            }
            self.audioOnsetLastSummaryAt = now
            let summary = self.audioOnsetAccumulator.currentSummary()
            let reviewSummary = self.audioOnsetAccumulator.currentReviewSummary()
            let reviewMarks = self.audioOnsetAccumulator.currentReviewMarks()
            DispatchQueue.main.async { [weak self] in
                self?.audioOnsetSummary = summary
                self?.audioOnsetReviewSummary = reviewSummary
                self?.audioOnsetReviewMarks = reviewMarks
            }
        }
    }

    /// Slice O — clear the accumulator and reset the published summary.
    /// Safe to call from any thread.
    func resetAudioOnsetDiagnostics() {
        audioOnsetQueue.async { [weak self] in
            guard let self else { return }
            self.audioOnsetAccumulator.reset()
            self.audioOnsetLastSummaryAt = 0
            DispatchQueue.main.async { [weak self] in
                self?.audioOnsetSummary = .empty
                self?.audioOnsetReviewSummary = .empty
                self?.audioOnsetReviewMarks = []
            }
        }
    }
}

enum CaptureSessionScratchType: String, CaseIterable, Codable, Sendable {
    case unknown
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
        case .unknown: return "Unknown"
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
        case .unknown, .babyScratch, .forwardScratch, .backwardScratch, .releaseScratch, .chirp, .scribble:
            return [70, 79, 90, 110]
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

    static var appReviewVisibleModes: [ExportMixMode] {
        #if DEBUG
        return allCases
        #else
        return [.scratchOnly]
        #endif
    }

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

// MARK: - Capture motion evidence

/// Which platter evidence a take's decoded movement runs actually amount to.
///
/// A powered, released turntable is still *moving* — it produces a long
/// forward-only stream of CC6 steps — but it is not a scratch gesture. Every
/// real gesture contains a reversal (the pull-back), so the presence of a
/// decoded backward run is the structural discriminator. This deliberately
/// reuses `derivePlatterMovementEvents`' existing noise gates (minimum run
/// duration and step count) rather than introducing a second, independently
/// tunable threshold layer.
enum CapturePlatterMotionEvidence: Equatable, Sendable {
    /// No decoded movement runs at all.
    case absent
    /// Forward-only runs: motion, but never a scratch gesture on its own.
    case steadyRotationOnly(forwardRuns: Int)
    /// At least one decoded reversal.
    case gesture(movementRuns: Int, reversalRuns: Int)

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }
}

enum CaptureWatchMotionEvidence: Equatable, Sendable {
    case notUsed
    case linked
}

/// DVS is modelled so the evidence type is complete and callers can switch
/// exhaustively, but iOS capture has no timecode-pipeline feed at take
/// finalization today. It therefore reports `.unsupported` rather than a
/// fabricated value — wiring a genuine DVS source is a separate slice, and
/// until then this must never contribute to motion presence.
enum CaptureDVSMotionEvidence: Equatable, Sendable {
    case unsupported
}

/// The sources that can independently establish that a take contains motion.
enum CaptureMotionSource: String, Codable, Sendable, CaseIterable {
    case platter
    case watch
    case dvs
}

/// Typed, domain-only record of which capture sources produced motion
/// evidence for one take.
///
/// This carries no user-facing strings by design: presentation belongs to the
/// review/HUD layer, so the two platforms cannot drift into different
/// vocabularies for the same underlying state.
///
/// Motion presence is not a Watch-only question. A RANE platter scratch
/// captured over MIDI is real movement even with no Watch paired. Before this
/// model existed, three separate sites derived presence solely from a linked
/// Watch artifact, so valid controller takes reported motion missing in review
/// and exported as motionless.
struct CaptureMotionEvidence: Equatable, Sendable {
    let platter: CapturePlatterMotionEvidence
    let faderEventCount: Int
    let watch: CaptureWatchMotionEvidence
    let dvs: CaptureDVSMotionEvidence
    /// How this take's crossfader was recognised, or nil when no fader
    /// evidence carried provenance — either none was captured, or the sidecar
    /// predates provenance being recorded.
    let faderMappingSource: FaderMappingSource?

    init(
        platter: CapturePlatterMotionEvidence,
        faderEventCount: Int,
        watch: CaptureWatchMotionEvidence,
        dvs: CaptureDVSMotionEvidence = .unsupported,
        faderMappingSource: FaderMappingSource? = nil
    ) {
        self.platter = platter
        self.faderEventCount = faderEventCount
        self.watch = watch
        self.dvs = dvs
        self.faderMappingSource = faderMappingSource
    }

    /// Sources that independently establish motion presence, in a stable
    /// order so callers and tests never depend on incidental ordering.
    ///
    /// Crossfader activity is deliberately excluded. A cut is real captured
    /// evidence and is persisted and exported as such, but it is not platter
    /// movement and must never stand in for it — a take where only the fader
    /// moved has no scratch gesture to review.
    var motionSources: [CaptureMotionSource] {
        var sources: [CaptureMotionSource] = []
        if platter.isGesture { sources.append(.platter) }
        if watch == .linked { sources.append(.watch) }
        switch dvs {
        case .unsupported: break
        }
        return sources
    }

    var motionPresent: Bool { !motionSources.isEmpty }

    /// True when the only motion claim comes from a linked Watch artifact.
    /// Export validation uses this to decide whether a watch file is required.
    var requiresLinkedWatchArtifact: Bool { motionSources == [.watch] }

    static let none = CaptureMotionEvidence(
        platter: .absent,
        faderEventCount: 0,
        watch: .notUsed,
        faderMappingSource: nil
    )
}

extension ScratchMovementKind {
    /// Backward (pull) travel. Used to identify the reversal that separates a
    /// scratch gesture from free-running forward platter rotation.
    var isReversal: Bool {
        switch self {
        case .fastPull, .normalPull, .slowPullDrag:
            return true
        case .fastPush, .normalPush, .slowDrag, .hold, .releaseNormalPlayback:
            return false
        }
    }
}

/// Single place that turns persisted take evidence into a `CaptureMotionEvidence`.
///
/// Both the live capture path and the recovery/export path resolve through
/// this, reading the same persisted sidecar notation, so a take that is
/// reviewed live and the same take rebuilt from disk can never disagree about
/// whether it contains motion.
enum CaptureMotionEvidenceResolver {
    static func platterEvidence(
        from movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> CapturePlatterMotionEvidence {
        guard !movementEvents.isEmpty else { return .absent }
        let reversalRuns = movementEvents.filter { $0.movementKind.isReversal }.count
        guard reversalRuns > 0 else {
            return .steadyRotationOnly(forwardRuns: movementEvents.count)
        }
        return .gesture(movementRuns: movementEvents.count, reversalRuns: reversalRuns)
    }

    static func resolve(
        detectedNotation: CaptureCore.DetectedNotationSnapshot?,
        watchCaptureLinked: Bool
    ) -> CaptureMotionEvidence {
        CaptureMotionEvidence(
            platter: platterEvidence(from: detectedNotation?.recordMovementEvents ?? []),
            faderEventCount: detectedNotation?.faderEvents.count ?? 0,
            watch: watchCaptureLinked ? .linked : .notUsed,
            faderMappingSource: faderMappingSource(from: detectedNotation)
        )
    }

    /// Drops controller events that arrived after the take's Stop instant.
    ///
    /// Finalization is not instantaneous — the movie-file callback can arrive
    /// well after Stop — so without this bound a fader or platter move made
    /// while the take was still finalizing would be decoded into the finished
    /// take's evidence. `stopRelativeTime` is in the same monotonic take-clock
    /// domain as `RawMixerMIDIEvent.takeRelativeTime`; `nil` means the take is
    /// still running and nothing is dropped.
    ///
    /// Shared rather than dispatcher-private so the boundary is one testable
    /// rule (the iOS dispatcher is not reachable from the macOS test target).
    static func eventsWithinTakeWindow(
        _ events: [CaptureCore.RawMixerMIDIEvent],
        stopRelativeTime: Double?
    ) -> [CaptureCore.RawMixerMIDIEvent] {
        guard let stopRelativeTime else { return events }
        return events.filter { $0.takeRelativeTime <= stopRelativeTime }
    }

    /// Reads provenance back off the persisted mixer events, so a take
    /// recovered from disk reports the same source the live take did. Older
    /// sidecars decode `mappingSource` as nil and simply report no provenance.
    static func faderMappingSource(
        from detectedNotation: CaptureCore.DetectedNotationSnapshot?
    ) -> FaderMappingSource? {
        guard let detectedNotation else { return nil }
        let sources = Set(
            detectedNotation.mixerMidiEvents
                .filter { $0.mappedControl == "crossfader" }
                .compactMap(\.mappingSource)
        )
        if sources.contains(.learned) { return .learned }
        return sources.contains(.certifiedRegistry) ? .certifiedRegistry : nil
    }
}

// MARK: - Guided capture review state

/// Whether this take is required to contain motion at all.
enum CaptureMotionRequirement: Equatable, Sendable {
    /// The drill needs motion and the operator did not skip it.
    case required
    /// The drill declares motion optional.
    case optional
    /// The operator explicitly skipped motion for this take.
    case skipped
}

enum CaptureMotionStatus: Equatable, Sendable {
    case present
    case optional
    case missing

    var title: String {
        switch self {
        case .present: return "Motion Present"
        case .optional: return "Motion Optional"
        case .missing: return "Motion Missing"
        }
    }
}

/// The single readiness verdict for a finished take.
///
/// Ordered most- to least-blocking. Exactly one case is reported, so the
/// review surface cannot present a take as simultaneously ready and blocked.
enum CaptureReviewReadiness: Equatable, Sendable {
    case recordingInterrupted
    case takeTooShort
    case missingAudio
    case calibrationInvalid
    /// Required motion is absent. Distinct from a hard failure: the media is
    /// valid and keepable, but the take will not teach anything.
    case retakeRecommended
    case readyToKeep

    var title: String {
        switch self {
        case .recordingInterrupted: return "Recording interrupted"
        case .takeTooShort: return "Take too short"
        case .missingAudio: return "Missing audio"
        case .calibrationInvalid: return "Calibration invalid"
        case .retakeRecommended: return "Retake recommended"
        case .readyToKeep: return "Ready to keep"
        }
    }

    var isKeepable: Bool {
        switch self {
        case .readyToKeep, .retakeRecommended: return true
        case .recordingInterrupted, .takeTooShort, .missingAudio, .calibrationInvalid: return false
        }
    }
}

/// One resolved review state for a finished take.
///
/// Every label the review surface renders is a projection of this single
/// value. Previously the operator message was a hardcoded literal and the
/// sync/motion labels were computed independently from the same inputs, so
/// one take could truthfully render "Ready to keep", "Motion pending" and
/// "Motion Missing" at the same time. Deriving all three here makes that
/// combination unrepresentable rather than merely unlikely.
struct GuidedCaptureReviewState: Equatable, Sendable {
    let readiness: CaptureReviewReadiness
    let motionStatus: CaptureMotionStatus

    var operatorMessage: String { readiness.title }
    var motionStatusTitle: String { motionStatus.title }
    var motionPresent: Bool { motionStatus == .present }

    /// The sync label. Deliberately a projection of the same readiness rather
    /// than an independently computed string: when motion is the blocker it
    /// repeats the motion wording verbatim, so the two labels can restate each
    /// other but can never contradict each other.
    var syncStatus: String {
        switch readiness {
        case .recordingInterrupted: return "Recording interrupted"
        case .takeTooShort: return "Take too short"
        case .missingAudio: return "Missing audio"
        case .calibrationInvalid: return "Needs calibration"
        case .retakeRecommended: return motionStatus.title
        case .readyToKeep:
            return motionStatus == .optional ? "Motion optional" : "Ready"
        }
    }
}

enum GuidedCaptureReviewStateResolver {
    static func motionRequirement(
        motionSkipped: Bool,
        motionOptional: Bool
    ) -> CaptureMotionRequirement {
        if motionSkipped { return .skipped }
        if motionOptional { return .optional }
        return .required
    }

    static func motionStatus(
        motionPresent: Bool,
        requirement: CaptureMotionRequirement
    ) -> CaptureMotionStatus {
        if motionPresent { return .present }
        switch requirement {
        case .optional, .skipped: return .optional
        case .required: return .missing
        }
    }

    /// Resolves the one state every review label projects from.
    ///
    /// `recordingFailed` and `duration` are folded in here so the operator
    /// message can no longer be decided at the call site — that split is what
    /// let a hardcoded "Ready to keep" survive next to a missing-motion pill.
    static func reviewState(
        recordingFailed: Bool,
        duration: TimeInterval,
        calibrationValid: Bool,
        audioPresent: Bool,
        motionPresent: Bool,
        motionSkipped: Bool,
        motionOptional: Bool
    ) -> GuidedCaptureReviewState {
        let requirement = motionRequirement(motionSkipped: motionSkipped, motionOptional: motionOptional)
        let status = motionStatus(motionPresent: motionPresent, requirement: requirement)

        let readiness: CaptureReviewReadiness
        if recordingFailed {
            readiness = .recordingInterrupted
        } else if duration < minimumKeepableTakeDuration {
            readiness = .takeTooShort
        } else if !audioPresent {
            readiness = .missingAudio
        } else if !calibrationValid {
            readiness = .calibrationInvalid
        } else if status == .missing {
            readiness = .retakeRecommended
        } else {
            readiness = .readyToKeep
        }

        return GuidedCaptureReviewState(readiness: readiness, motionStatus: status)
    }

    /// Shortest take the review flow will offer to keep.
    static let minimumKeepableTakeDuration: TimeInterval = 1.0
}

// MARK: - Bounded capture finalization state machine

/// Where an accepted Stop originated.
///
/// Both sources drive the *identical* transition. This value exists only so
/// the Watch reply text and the take audit trail can name the origin; it must
/// never be branched on to decide what finalization does, which is exactly
/// how the phone and Watch paths drifted apart before.
enum CaptureStopSource: String, Equatable, Sendable {
    case phone
    case watch
}

/// What the movie recorder was doing when a Stop was accepted.
enum CaptureRecorderPhase: Equatable, Sendable {
    /// `startRecording(to:)` was issued but `AVCaptureFileOutput` has not yet
    /// reported `didStartRecordingTo`. A Stop here must still be delivered to
    /// the recorder, or capture keeps running with no visible UI state.
    case starting
    case recording
}

/// Identity of the take one finalization cycle belongs to.
///
/// Finalization is scoped to this key, not to a global "is saving" flag, so a
/// summary published for a different take cannot complete the active one.
struct CaptureFinalizationTakeKey: Hashable, Sendable {
    let sessionID: String
    let takeNumber: Int

    init(sessionID: String, takeNumber: Int) {
        self.sessionID = sessionID
        self.takeNumber = takeNumber
    }
}

/// The bound on one finalization cycle.
///
/// `worstCaseSaving` is the total time Saving can last before the operator is
/// returned to System Check with an explicit recoverable failure. There is no
/// path that exceeds it, because exactly one retry is permitted.
struct CaptureFinalizationBudget: Equatable, Sendable {
    let firstWait: TimeInterval
    let retryWait: TimeInterval
    /// Optional post-Review audio inspection bound. Review is already reached
    /// before inspection starts; this only stops a stalled `AVAsset` load from
    /// leaving a task alive forever.
    let audioInspection: TimeInterval

    init(firstWait: TimeInterval, retryWait: TimeInterval, audioInspection: TimeInterval) {
        self.firstWait = max(0, firstWait)
        self.retryWait = max(0, retryWait)
        self.audioInspection = max(0, audioInspection)
    }

    static let `default` = CaptureFinalizationBudget(
        firstWait: 12,
        retryWait: 3,
        audioInspection: 5
    )

    var worstCaseSaving: TimeInterval { firstWait + retryWait }
}

/// The single authoritative finalization state.
///
/// Nothing else may store "are we saving", "did the watchdog already fire",
/// or "was this summary already handled" — those all became contradictory
/// when they lived in separate flags across the view, the store, and the
/// watchdog task.
enum CaptureFinalizationState: Equatable, Sendable {
    case idle
    /// Stop accepted; the first recorder-summary window is open.
    case awaitingRecorder(take: CaptureFinalizationTakeKey, stoppedAt: Date, deadline: Date)
    /// The single permitted stop retry is outstanding.
    case retryingStop(take: CaptureFinalizationTakeKey, stoppedAt: Date, deadline: Date)
    /// Terminal: the take reached Review.
    case completed(take: CaptureFinalizationTakeKey, recordingID: String)
    /// Terminal: the take could not be finalized and the operator was given an
    /// explicit recoverable failure with the staged media preserved.
    case failed(take: CaptureFinalizationTakeKey, reason: String)

    /// True while a Stop has been accepted but no terminal result exists yet.
    var isSaving: Bool {
        switch self {
        case .awaitingRecorder, .retryingStop: return true
        case .idle, .completed, .failed: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        case .idle, .awaitingRecorder, .retryingStop: return false
        }
    }

    var take: CaptureFinalizationTakeKey? {
        switch self {
        case .idle: return nil
        case let .awaitingRecorder(take, _, _): return take
        case let .retryingStop(take, _, _): return take
        case let .completed(take, _): return take
        case let .failed(take, _): return take
        }
    }

    /// The instant the first accepted Stop was recorded. The elapsed-time
    /// readout freezes here and never moves again for this take.
    var stoppedAt: Date? {
        switch self {
        case let .awaitingRecorder(_, stoppedAt, _): return stoppedAt
        case let .retryingStop(_, stoppedAt, _): return stoppedAt
        case .idle, .completed, .failed: return nil
        }
    }

    var deadline: Date? {
        switch self {
        case let .awaitingRecorder(_, _, deadline): return deadline
        case let .retryingStop(_, _, deadline): return deadline
        case .idle, .completed, .failed: return nil
        }
    }
}

/// Everything that can move the finalization cycle forward.
enum CaptureFinalizationEvent: Equatable, Sendable {
    /// A new take started recording, so the previous cycle's terminal result
    /// is retired.
    case takeArmedForRecording(take: CaptureFinalizationTakeKey)
    /// Stop pressed on the phone, or received from the Watch. Identical
    /// handling for both.
    case stopRequested(
        take: CaptureFinalizationTakeKey,
        source: CaptureStopSource,
        recorderPhase: CaptureRecorderPhase
    )
    /// A finalized recorder summary arrived, from any delivery path: the
    /// `endRecording` completion, the published-summary subscription, or the
    /// deadline handler consuming an already-published summary.
    case summaryDelivered(take: CaptureFinalizationTakeKey, recordingID: String)
    /// The recorder stated that no summary will arrive for this take.
    case recorderReportedNoSummary(status: String)
    /// The one scheduled deadline fired.
    case deadlineElapsed(recorderStillRecording: Bool, status: String)
}

/// Side effects the owner must perform, in the order returned.
///
/// `preserveStagedMedia` always precedes `presentRecoverableFailure`, so the
/// operator is never shown a failure for media that has not been secured yet.
enum CaptureFinalizationEffect: Equatable, Sendable {
    case freezeElapsedTimer(at: Date)
    /// Close the controller/MIDI take window so moves made during
    /// finalization cannot land in this take's evidence.
    case closeTakeEvidenceWindow
    /// The recorder had not reached `didStartRecordingTo`; make sure the
    /// pending start cannot leave capture running invisibly.
    case cancelPendingRecorderStart
    case requestRecorderStop
    case scheduleDeadline(at: Date)
    case cancelDeadline
    case completeToReview(recordingID: String)
    case preserveStagedMedia
    case presentRecoverableFailure(message: String)
}

/// One bounded, take-ID-scoped finalization state machine.
///
/// This is the whole of the finalization policy. It is pure and clock-free —
/// every transition is given the current instant — so the races that produced
/// the original hang (duplicate recorder callbacks, a stale published summary,
/// a stop that raced the recorder starting, and a watchdog that could fire
/// after the take had already reached Review) are reproducible in tests
/// without waiting on real time.
///
/// Guarantees, each covered by a test:
/// - every accepted Stop reaches exactly one terminal state, within
///   `budget.worstCaseSaving`;
/// - duplicate summaries, duplicate deadline deliveries, and repeated Stop
///   presses are no-ops that emit no effects;
/// - a summary whose take key differs from the active take is ignored;
/// - phone and Watch Stops produce byte-identical effect lists;
/// - failure preserves staged media before it is presented.
struct CaptureFinalizationMachine: Equatable, Sendable {
    let budget: CaptureFinalizationBudget
    private(set) var state: CaptureFinalizationState

    init(budget: CaptureFinalizationBudget = .default) {
        self.budget = budget
        self.state = .idle
    }

    var isSaving: Bool { state.isSaving }
    var activeTake: CaptureFinalizationTakeKey? { state.take }
    var stoppedAt: Date? { state.stoppedAt }

    /// Whether a summary for `take` would be accepted right now. The delivery
    /// sites use this to skip *all* of their side work — notation persistence,
    /// scratch-stem renaming, artifact banners — on a duplicate or foreign
    /// summary, rather than doing that work and de-duplicating afterwards.
    func acceptsSummary(for take: CaptureFinalizationTakeKey) -> Bool {
        state.isSaving && state.take == take
    }

    /// Optional audio inspection may only refine the take it was started for.
    func acceptsAudioInspection(forRecordingID recordingID: String) -> Bool {
        guard case let .completed(_, completedID) = state else { return false }
        return completedID == recordingID
    }

    @discardableResult
    mutating func apply(
        _ event: CaptureFinalizationEvent,
        at now: Date
    ) -> [CaptureFinalizationEffect] {
        switch event {
        case let .takeArmedForRecording(take):
            let hadTimer = state.isSaving
            _ = take
            state = .idle
            return hadTimer ? [.cancelDeadline] : []

        case let .stopRequested(take, _, recorderPhase):
            // A Stop while already saving joins the in-flight cycle. It must
            // not re-freeze the timer, re-close the evidence window, or start
            // a second deadline.
            guard !state.isSaving else { return [] }

            let deadline = now.addingTimeInterval(budget.firstWait)
            state = .awaitingRecorder(take: take, stoppedAt: now, deadline: deadline)

            var effects: [CaptureFinalizationEffect] = [
                .freezeElapsedTimer(at: now),
                .closeTakeEvidenceWindow
            ]
            if recorderPhase == .starting {
                effects.append(.cancelPendingRecorderStart)
            }
            // The deadline is armed before the stop is issued, so a recorder
            // that finalizes synchronously cancels a timer that already
            // exists rather than racing one into existence behind it.
            effects.append(.scheduleDeadline(at: deadline))
            effects.append(.requestRecorderStop)
            return effects

        case let .summaryDelivered(take, recordingID):
            guard acceptsSummary(for: take) else { return [] }
            state = .completed(take: take, recordingID: recordingID)
            return [.cancelDeadline, .completeToReview(recordingID: recordingID)]

        case let .recorderReportedNoSummary(status):
            guard let take = state.take, state.isSaving else { return [] }
            let message = Self.recoveryMessage(status: status)
            state = .failed(take: take, reason: message)
            return [.cancelDeadline, .preserveStagedMedia, .presentRecoverableFailure(message: message)]

        case let .deadlineElapsed(recorderStillRecording, status):
            switch state {
            case let .awaitingRecorder(take, stoppedAt, _) where recorderStillRecording:
                // The original stop can race the movie output becoming
                // active. Retry exactly once so recording cannot continue
                // invisibly after Save Take, then give up within the bound.
                let deadline = now.addingTimeInterval(budget.retryWait)
                state = .retryingStop(take: take, stoppedAt: stoppedAt, deadline: deadline)
                return [.scheduleDeadline(at: deadline), .requestRecorderStop]

            case let .awaitingRecorder(take, _, _):
                return fail(take: take, status: status)

            case let .retryingStop(take, _, _):
                return fail(take: take, status: status)

            case .idle, .completed, .failed:
                // A deadline that outlived its cycle is inert.
                return []
            }
        }
    }

    private mutating func fail(
        take: CaptureFinalizationTakeKey,
        status: String
    ) -> [CaptureFinalizationEffect] {
        let message = Self.recoveryMessage(status: status)
        state = .failed(take: take, reason: message)
        return [.preserveStagedMedia, .presentRecoverableFailure(message: message)]
    }

    /// The exact operator-facing recovery wording. Kept here so the timeout,
    /// the retry exhaustion, and the explicit no-summary report cannot drift
    /// into three different explanations of the same situation.
    static func recoveryMessage(status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.isEmpty ? "The recorder did not report completion." : trimmed
        return "Take save did not finish. The staged recording was preserved. \(detail)"
    }
}

/// Injectable time source so a finalization cycle is deterministic in tests.
struct CaptureFinalizationClock: Sendable {
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    static let system = CaptureFinalizationClock { Date() }
}

/// The one place a finalization deadline becomes real elapsed time.
///
/// Exactly one timer exists per scheduler, and scheduling replaces the
/// previous one. This is what keeps a second watchdog from reappearing: the
/// machine emits `scheduleDeadline`, and there is nowhere else to start one.
final class CaptureFinalizationDeadlineScheduler {
    private var task: Task<Void, Never>?
    private let clock: CaptureFinalizationClock

    init(clock: CaptureFinalizationClock = .system) {
        self.clock = clock
    }

    var isScheduled: Bool { task != nil }

    func schedule(at deadline: Date, _ body: @escaping () -> Void) {
        cancel()
        let interval = max(0, deadline.timeIntervalSince(clock.now()))
        task = Task { @MainActor in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            body()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Capture evidence presentation

/// One labelled evidence row for the review surface.
struct CaptureEvidenceRow: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    /// True when this row represents evidence that was actually captured, so
    /// the surface can style contributing sources differently from absent ones
    /// without re-deriving the meaning of the string.
    let isPresent: Bool

    var id: String { label }
}

/// Turns the typed `CaptureMotionEvidence` into review rows.
///
/// Lives in the shared model, alongside the readiness vocabulary, so iOS and
/// macOS name the same evidence identically rather than each inventing its own
/// wording for the same state.
enum CaptureMotionEvidencePresenter {
    static func rows(for evidence: CaptureMotionEvidence) -> [CaptureEvidenceRow] {
        [
            CaptureEvidenceRow(
                label: "Platter",
                value: platterValue(evidence.platter),
                isPresent: evidence.platter.isGesture
            ),
            CaptureEvidenceRow(
                label: "Fader",
                value: faderValue(
                    eventCount: evidence.faderEventCount,
                    source: evidence.faderMappingSource
                ),
                isPresent: evidence.faderEventCount > 0
            ),
            CaptureEvidenceRow(
                label: "Watch",
                value: evidence.watch == .linked ? "Linked" : "Not used",
                isPresent: evidence.watch == .linked
            )
        ]
        // DVS is deliberately absent: iOS capture has no timecode feed at take
        // finalization, and a permanent "Unavailable" row would imply a source
        // the product does not have. It returns as a row when a real feed exists.
    }

    /// Names the fader evidence and, when there is any, where its mapping came
    /// from. A certified-registry take says so explicitly rather than implying
    /// the user mapped the control. "No movement" stays unqualified — an open
    /// fader is a real, correct result for a Baby Scratch, not a mapping fault.
    private static func faderValue(
        eventCount: Int,
        source: FaderMappingSource?
    ) -> String {
        guard eventCount > 0 else { return "No movement" }
        let base = "\(eventCount) event\(eventCount == 1 ? "" : "s")"
        switch source {
        case .learned: return "\(base) · learned"
        case .certifiedRegistry: return "\(base) · certified default"
        case .none: return base
        }
    }

    private static func platterValue(_ platter: CapturePlatterMotionEvidence) -> String {
        switch platter {
        case .gesture:
            return "Present · MIDI"
        case .steadyRotationOnly:
            // Movement was decoded, but forward-only: a running motor, not a
            // scratch. Naming it separately stops it reading as a capture bug.
            return "Rotation only"
        case .absent:
            return "Not detected"
        }
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

    var hasValidScratchTypeSelection: Bool {
        guard let scratchType else { return false }
        return scratchType != .unknown
    }

    var validationMessages: [String] {
        var messages: [String] = []

        if !hasValidScratchTypeSelection {
            messages.append("Choose a scratch type before recording.")
        }
        if captureMode == .timedClick {
            if let bpmValue,
               !CaptureClickTrackDefaults.supportedBPMRange.contains(bpmValue) {
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
        let displayScratchType: CaptureSessionScratchType? = {
            guard let scratchType, scratchType != .unknown else { return nil }
            return scratchType
        }()
        if captureMode == .calibrationNoClick, displayScratchType != nil {
            return "\(baseName) \(scratchTypeName) Calibration"
        }
        if let bpmValue, displayScratchType != nil {
            return "\(baseName) \(scratchTypeName) \(bpmValue) BPM"
        }
        if displayScratchType != nil {
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

enum BeatPlaybackState: Equatable, Sendable {
    case ready
    case playing
    case stopped
    case failed(reason: String)
}

@MainActor
protocol PracticeBeatPlaybackEngine: AnyObject {
    func start(mode: BeatEngineMode, bpm: Int) throws
    func stop()
    func hardResetBeatPlayback()
    func setOutputGain(_ normalizedGain: Double)
}

extension PracticeBeatPlaybackEngine {
    func setOutputGain(_ normalizedGain: Double) {}
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
    @Published private(set) var playbackState: BeatPlaybackState = .ready

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

    func setOutputGain(_ normalizedGain: Double) {
        beatEngine.setOutputGain(normalizedGain)
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
            playbackState = .playing
        } catch {
            isPlaying = false
            playbackErrorMessage = error.localizedDescription
            playbackState = .failed(reason: error.localizedDescription)
        }
    }

    func stopPlayback() {
        beatEngine.stop()
        isPlaying = false
        if case .playing = playbackState {
            playbackState = .stopped
        }
    }

    func retryPlayback() {
        beatEngine.hardResetBeatPlayback()
        playbackState = .ready
        playbackErrorMessage = nil
        startPlayback()
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

typealias DemoPlaybackState = ScratchCoachDemoPlaybackState

protocol ScratchCoachDemoPlayable: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    func prepareToPlay()
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    func setOutputGain(_ normalizedGain: Float)
}

extension ScratchCoachDemoPlayable {
    func setOutputGain(_ normalizedGain: Float) {}
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
        // Must run synchronously, on the same execution context as `play()`.
        // `AVAudioPlayer` is not safe against a concurrent `prepareToPlay()`
        // racing an immediately-following `play()` call from another thread —
        // dispatching this to a background queue let that race corrupt
        // playback (play() intermittently returning false, or returning true
        // then silently stopping again within milliseconds). The bundled
        // demo assets are small PCM WAVs with measured negligible prepare
        // cost, so blocking here is not a real responsiveness concern.
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

    func setOutputGain(_ normalizedGain: Float) {
        let finiteGain = normalizedGain.isFinite ? normalizedGain : 0
        player.volume = min(max(finiteGain, 0), 1)
    }
}

/// Deterministic, documented resolution outcome for a requested demo audio
/// file. `.fallback` never claims to be the exact requested source — a
/// caller reporting status to the user must branch on this to say so
/// honestly.
enum DemoAudioResolution: Equatable {
    case exact(URL)
    case fallback(URL, actualFileName: String)
    case unavailable
}

/// Pure resolver — no bundle/file-system access of its own, takes a lookup
/// closure so it's trivially testable with an injected bundle or synthetic
/// data. Fallback is opt-in per call site (`allowsFallback`) so a lesson
/// with no real fallback resource never silently borrows one from an
/// unrelated lesson.
enum DemoAudioResolver {
    static func resolve(
        requestedFileName: String,
        allowsFallback: Bool,
        fallbackFileName: String = "baby_reel_callresponse.wav",
        lookup: (String) -> URL?
    ) -> DemoAudioResolution {
        if let url = lookup(requestedFileName) {
            return .exact(url)
        }
        if allowsFallback, let fallbackURL = lookup(fallbackFileName) {
            return .fallback(fallbackURL, actualFileName: fallbackFileName)
        }
        return .unavailable
    }
}

@MainActor
final class ScratchCoachDemoAudioPlayer: ObservableObject {
    typealias ResourceURLProvider = (String) -> URL?
    typealias PlayerFactory = (URL) throws -> ScratchCoachDemoPlayable

    @Published private(set) var playbackState: ScratchCoachDemoPlaybackState = .stopped
    @Published private(set) var isAudioAvailable = false
    /// True when the currently loaded audio is a fallback resource, not the
    /// exact file that was requested — set only by `configure(url:sourceFileName:isFallback:)`.
    /// `configure(withAudioFileNamed:)` never sets this true (it has no
    /// fallback concept of its own).
    @Published private(set) var isUsingFallbackAudio = false

    private let resourceURLProvider: ResourceURLProvider
    private let playerFactory: PlayerFactory
    private let logger = Logger(subsystem: "ScratchLab", category: "ScratchCoachDemoAudioPlayer")
    private var player: ScratchCoachDemoPlayable?
    private var currentAudioFile: String?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var outputGain: Float = 1.0

    // Host-clock source for the Demo-mode playhead clock (injectable for tests).
    private let hostTimeProvider: () -> TimeInterval
    // Smoothing, latency-compensated clock for the Demo-mode notation playhead
    // — see `sampledPlaybackTime()`.
    private var syncClock = DemoAudioClock()
    private var cachedOutputLatency: TimeInterval = 0

    init(
        resourceURLProvider: @escaping ResourceURLProvider = ScratchCoachDemoAudioPlayer.defaultResourceURLProvider(in: .main),
        playerFactory: @escaping PlayerFactory = { try ScratchCoachAVAudioPlayerAdapter(url: $0) },
        hostTimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.resourceURLProvider = resourceURLProvider
        self.playerFactory = playerFactory
        self.hostTimeProvider = hostTimeProvider
        registerLifecycleObservers()
        refreshOutputLatency()
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

    /// A smoothed, latency-compensated playback position for the Demo-mode
    /// notation playhead. Unlike `currentPlaybackTime` — a raw `AVAudioPlayer`
    /// sample — this interpolates against the host clock and subtracts the
    /// audio output latency, so the notation tracks what the listener hears
    /// instead of stepping coarsely and leading the sound.
    func sampledPlaybackTime() -> TimeInterval {
        let hostTime = hostTimeProvider()
        syncClock.outputLatency = cachedOutputLatency
        syncClock.ingest(
            playerTime: player?.currentTime ?? 0,
            isPlaying: player?.isPlaying ?? false,
            hostTime: hostTime
        )
        return syncClock.currentTime(hostTime: hostTime)
    }

    var isActivelyPlayingAudio: Bool {
        player?.isPlaying ?? false
    }

    func configure(with instruction: ScratchCoachInstruction) {
        configure(withAudioFileNamed: instruction.demoAudioFile)
    }

    /// Loads a specific bundled demo-audio file by name. The manifest-driven
    /// Demo path resolves the audio from a `PracticeReelTimeline`; the legacy
    /// path routes here via `configure(with:)`.
    func configure(withAudioFileNamed audioFileName: String?) {
        let nextAudioFile = Self.normalizedAudioFileName(audioFileName)
        guard nextAudioFile != currentAudioFile || (nextAudioFile != nil && player == nil) else { return }

        clearLoadedAudio()
        currentAudioFile = nextAudioFile

        guard let nextAudioFile,
              let audioURL = resourceURLProvider(nextAudioFile) else {
            return
        }

        do {
            let nextPlayer = try playerFactory(audioURL)
            nextPlayer.setOutputGain(outputGain)
            nextPlayer.prepareToPlay()
            player = nextPlayer
            isAudioAvailable = true
            playbackState = .stopped
        } catch {
            logger.error("Failed to load coach demo audio \(nextAudioFile, privacy: .public): \(error.localizedDescription, privacy: .public)")
            clearLoadedAudio()
        }
    }

    /// Configures playback directly from an already-resolved URL, skipping
    /// this player's own `resourceURLProvider` lookup entirely. For callers
    /// that resolved the exact/fallback URL themselves (e.g. via
    /// `DemoAudioResolver`) — guarantees a single resolution point instead
    /// of two independent lookups that could disagree.
    func configure(url: URL, sourceFileName: String, isFallback: Bool) {
        guard sourceFileName != currentAudioFile || player == nil else { return }

        clearLoadedAudio()
        currentAudioFile = sourceFileName

        do {
            let nextPlayer = try playerFactory(url)
            nextPlayer.setOutputGain(outputGain)
            nextPlayer.prepareToPlay()
            player = nextPlayer
            isAudioAvailable = true
            isUsingFallbackAudio = isFallback
            playbackState = .stopped
        } catch {
            logger.error("Failed to load coach demo audio \(sourceFileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            clearLoadedAudio()
        }
    }

    func play() {
        guard let player, isAudioAvailable else { return }
        refreshOutputLatency()
        if player.play() {
            playbackState = .playing
        } else {
            playbackState = .stopped
        }
    }

    func pause() {
        guard let player, isAudioAvailable else { return }
        player.pause()
        playbackState = .paused
    }

    func replay() {
        guard let player, isAudioAvailable else { return }
        refreshOutputLatency()
        player.currentTime = 0
        if player.play() {
            playbackState = .playing
        } else {
            playbackState = .stopped
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

    func setOutputGain(_ normalizedGain: Double) {
        let finiteGain = normalizedGain.isFinite ? normalizedGain : 0
        outputGain = Float(min(max(finiteGain, 0), 1))
        player?.setOutputGain(outputGain)
    }

    nonisolated static func bundledDemoAudioURL(
        named audioName: String,
        in bundle: Bundle = .main
    ) -> URL? {
        let searchDirectories: [String?] = ["CoachDemoAudio", "PracticeReelAudio", nil]
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

    /// Refreshes the session latency away from the main actor. The sampled
    /// playhead reads the last completed value without synchronously querying
    /// AVAudioSession on every display update.
    private func refreshOutputLatency() {
        Task { [weak self] in
            let latency = await Task.detached(priority: .userInitiated) {
                #if canImport(UIKit)
                return max(0, AVAudioSession.sharedInstance().outputLatency)
                #else
                return 0.0
                #endif
            }.value
            self?.cachedOutputLatency = latency
        }
    }

    private func clearLoadedAudio() {
        stop()
        player = nil
        isAudioAvailable = false
        isUsingFallbackAudio = false
        syncClock.reset()
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

    static let babyScratchCrossfaderPosition: Double = 0.5

    static let neutral = ScratchCoachDemoAnimationState(
        recordPosition: 0,
        recordRotationDegrees: 0,
        crossfaderPosition: 0,
        crossfaderOpenState: false
    )

    static let babyScratchOpen = ScratchCoachDemoAnimationState(
        recordPosition: 0,
        recordRotationDegrees: 0,
        crossfaderPosition: babyScratchCrossfaderPosition,
        crossfaderOpenState: true
    )
}

struct ScratchLabBabyScratchDemoMotionState: Equatable, Sendable {
    let recordPosition: Double
    let recordRotationDegrees: Double
    let inputLevel: Float
    let direction: ScratchMotionDirection
    let feedback: ScratchMotionFeedback

    var animationState: ScratchCoachDemoAnimationState {
        guard abs(recordPosition) > 0.0001 || direction != .neutral else {
            return .neutral
        }
        return ScratchCoachDemoAnimationState(
            recordPosition: recordPosition,
            recordRotationDegrees: recordRotationDegrees,
            crossfaderPosition: ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition,
            crossfaderOpenState: true
        )
    }
}

struct ScratchLabBabyScratchStrokeSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let direction: ScratchMotionDirection
    let holdAfter: TimeInterval
    let startProgress: Double
    let endProgress: Double

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    var holdEndTime: TimeInterval {
        endTime + holdAfter
    }
}

enum ScratchNotationDirection: String, Codable, Equatable, Sendable {
    case forward
    case backward
}

enum ScratchNotationSpeedClassification: String, Codable, Equatable, Sendable {
    case slow
    case medium
    case fast
}

enum ScratchNotationFaderState: String, Codable, Equatable, Sendable {
    case open
    case closed
}

/// Which timing domain a `ScratchNotation` document's stroke times are
/// authored in.
///
/// Timing AUTHORITY and TEMPO are separate concepts:
///
/// - `.seconds`: the historical schema — `startTime`/`endTime` are the
///   authored values and any beat fields are non-authoritative annotations.
///   Every bundled resource to date (including the legacy
///   `beat_quantized_*` basis, whose beat metadata was never part of the
///   decoded schema) resolves to this domain.
/// - `.beats`: a beat-authored document — per-stroke `startBeat`/`endBeat`
///   are authoritative. Beats-authorship is declared by `timingBasis`
///   alone (the `ScratchNotation.beatAuthoredTimingBasisPrefix` marker),
///   with or without a tempo: `bpm` is required only to *project* beats
///   into seconds. Seconds on a beat-authored value are always derived
///   cache/compatibility values for existing consumers — never authored,
///   never authoritative. A tempo-free beat-authored pattern carries no
///   seconds at all and lives in `ScratchNotation.BeatPattern`.
enum ScratchNotationTimingDomain: String, Codable, Equatable, Sendable {
    case seconds
    case beats
}

enum ScratchMovementKind: String, Codable, Equatable, Sendable {
    case fastPush
    case normalPush
    case slowDrag
    case fastPull
    case normalPull
    case slowPullDrag
    case hold
    case releaseNormalPlayback
}

enum ScratchFaderEventKind: String, Codable, Equatable, Sendable {
    case open
    case closed
    case cut
    case pulse
    case transformPulse
    case flareClick
    case unknown
}

/// The canonical, renderer-independent representation of a scratch gesture
/// over time — the single type authored targets, detected previews, and both
/// platforms' renderers converge on.
///
/// **Timing domains.** A document is authored in exactly one domain
/// (`resolvedTimingDomain`): legacy documents in seconds, canonical documents
/// in musical beats with seconds derived — see `ScratchNotationTimingDomain`.
/// The in-memory `Stroke` always carries seconds so every existing renderer
/// adapter (`LaneContent`, overlays, replay) keeps working unchanged.
///
/// **Holds.** A stationary/hold region is the implicit gap between one
/// stroke's end and the next stroke's start (in whichever domain is
/// authoritative). `strokeSegments` materialises the gaps as `holdAfter`
/// values; there is deliberately no "hold stroke" kind.
///
/// **Fader/cuts.** Per-stroke `faderState` (open/closed, a cut readable as a
/// boundary where the state flips) is sufficient for Baby Scratch — fader
/// open throughout — but is intentionally NOT the final canonical channel
/// for cut-heavy techniques (transform / crab / flare families), which need
/// fader events denser than strokes. That richer channel
/// (`ScratchFaderEventKind` vocabulary, `LaneContent.faderEvents` slot) is a
/// deferred, separate slice.
struct ScratchNotation: Codable, Equatable, Sendable {
    struct Stroke: Codable, Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let direction: ScratchNotationDirection
        let speedClassification: ScratchNotationSpeedClassification
        let faderState: ScratchNotationFaderState
        /// Beat-domain span of the stroke, in fractional beats from the
        /// document origin (same convention as `ScratchRenderEvent`). Both
        /// fields are `nil` on legacy seconds-authored strokes; when the
        /// document resolves to `.beats` they are authoritative and the
        /// seconds fields hold the projection (see `validationIssues()`).
        let startBeat: Double?
        let endBeat: Double?

        init(startTime: TimeInterval,
             endTime: TimeInterval,
             direction: ScratchNotationDirection,
             speedClassification: ScratchNotationSpeedClassification,
             faderState: ScratchNotationFaderState,
             startBeat: Double? = nil,
             endBeat: Double? = nil) {
            self.startTime = startTime
            self.endTime = endTime
            self.direction = direction
            self.speedClassification = speedClassification
            self.faderState = faderState
            self.startBeat = startBeat
            self.endBeat = endBeat
        }

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }

        var motionDirection: ScratchMotionDirection {
            direction == .backward ? .backward : .forward
        }

        var startProgress: Double {
            direction == .forward ? 0 : 1
        }

        var endProgress: Double {
            direction == .forward ? 1 : 0
        }

        var movementKind: ScratchMovementKind {
            switch (direction, speedClassification) {
            case (.forward,  .fast):   return .fastPush
            case (.forward,  .medium): return .normalPush
            case (.forward,  .slow):   return .slowDrag
            case (.backward, .fast):   return .fastPull
            case (.backward, .medium): return .normalPull
            case (.backward, .slow):   return .slowPullDrag
            }
        }
    }

    /// A materialized fader-state edge: "at `time` (derived from `beat`
    /// when beat-authored), the fader becomes `state`." This is the
    /// canonical high-resolution fader timeline — see
    /// `BeatPattern.faderEvents` for the authority rule against per-stroke
    /// `Stroke.faderState` (non-empty `faderEvents` is authoritative;
    /// empty means no canonical edge channel was authored, never
    /// implicitly open or closed).
    struct FaderEvent: Codable, Equatable, Sendable {
        let time: TimeInterval
        let state: ScratchNotationFaderState
        /// Beat position, in fractional beats from the document origin.
        /// `nil` on legacy seconds-authored events; authoritative when the
        /// document resolves to `.beats` (see `validationIssues()`).
        let beat: Double?

        init(time: TimeInterval, state: ScratchNotationFaderState, beat: Double? = nil) {
            self.time = time
            self.state = state
            self.beat = beat
        }
    }

    let version: Int
    let scratchID: String
    let demoStart: TimeInterval
    let demoEnd: TimeInterval
    let phraseStart: TimeInterval?
    let phraseEnd: TimeInterval?
    let timingBasis: String
    /// Document tempo, in beats per minute. NOT part of timing authority —
    /// beat-authorship is declared by `timingBasis` alone. `bpm` exists so
    /// beat positions can be projected into seconds: a decoded beat-authored
    /// JSON document must carry it (its materialized seconds cannot exist
    /// otherwise), while a tempo-free beat-authored pattern lives in
    /// `ScratchNotation.BeatPattern` until a caller materializes it.
    /// `nil` on legacy seconds documents.
    let bpm: Double?
    /// Optional meter hint for beat-authored documents. Never affects
    /// timing resolution.
    let beatsPerBar: Int?
    let strokes: [Stroke]
    /// The canonical high-resolution fader-state timeline, as edge
    /// transitions. Non-empty ⇒ authoritative over every stroke's
    /// `faderState`, which becomes a legacy/compatibility snapshot. Empty ⇒
    /// no canonical fader edge channel was authored — NEVER treat this as
    /// implicitly open or closed; per-stroke `faderState` remains the sole
    /// fader description in that case (true of every notation shipped
    /// today, including `ScratchNotation.babyScratchCycle`). See
    /// `BeatPattern.faderEvents` for the authoring-side rules this
    /// timeline must satisfy.
    let faderEvents: [FaderEvent]

    init(version: Int,
         scratchID: String,
         demoStart: TimeInterval,
         demoEnd: TimeInterval,
         phraseStart: TimeInterval?,
         phraseEnd: TimeInterval?,
         timingBasis: String,
         bpm: Double? = nil,
         beatsPerBar: Int? = nil,
         strokes: [Stroke],
         faderEvents: [FaderEvent] = []) {
        self.version = version
        self.scratchID = scratchID
        self.demoStart = demoStart
        self.demoEnd = demoEnd
        self.phraseStart = phraseStart
        self.phraseEnd = phraseEnd
        self.timingBasis = timingBasis
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.strokes = strokes
        self.faderEvents = faderEvents
    }

    // MARK: Timing-domain resolution

    /// `timingBasis` marker declaring a beat-authored document. Note the
    /// legacy `"beat_quantized_BPM79_body6beats_v4"` basis does NOT match —
    /// that resource is seconds-authored (its beat metadata was never part
    /// of the decoded schema) and must keep resolving to `.seconds`.
    static let beatAuthoredTimingBasisPrefix = "beat_canonical"

    /// Timing authority comes from the declared basis ALONE — a
    /// `beat_canonical…` document is beat-authored even when it is
    /// tempo-free (`bpm == nil`). Tempo is a projection concern, not an
    /// authority concern.
    static func resolvedTimingDomain(timingBasis: String) -> ScratchNotationTimingDomain {
        timingBasis.hasPrefix(beatAuthoredTimingBasisPrefix) ? .beats : .seconds
    }

    var resolvedTimingDomain: ScratchNotationTimingDomain {
        Self.resolvedTimingDomain(timingBasis: timingBasis)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, scratchID, demoStart, demoEnd, phraseStart, phraseEnd
        case timingBasis, bpm, beatsPerBar, strokes, faderEvents
    }

    /// All-optional-timing stroke record so one decoder serves both domains.
    private struct StrokeRecord: Decodable {
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let startBeat: Double?
        let endBeat: Double?
        let direction: ScratchNotationDirection
        let speedClassification: ScratchNotationSpeedClassification
        let faderState: ScratchNotationFaderState
    }

    /// All-optional-timing fader-event record so one decoder serves both
    /// domains, mirroring `StrokeRecord`.
    private struct FaderEventRecord: Decodable {
        let time: TimeInterval?
        let beat: Double?
        let state: ScratchNotationFaderState
    }

    /// Seconds-domain documents decode byte-for-byte like the historical
    /// schema (per-stroke seconds and demo bounds required, beat fields
    /// riding along as annotations).
    ///
    /// Beat-authored documents (basis-declared) require per-stroke beats AND
    /// a usable `bpm` — a beat-authored JSON document without a tempo cannot
    /// materialize the seconds this type must carry, so decoding FAILS
    /// rather than silently reclassifying the document as seconds-authored.
    /// All seconds fields (stroke times, demo/phrase bounds) are derived
    /// unconditionally from beats × 60/bpm; any seconds present in the JSON
    /// are ignored, never trusted — beats are the only authority.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let scratchID = try container.decode(String.self, forKey: .scratchID)
        let timingBasis = try container.decode(String.self, forKey: .timingBasis)
        let bpm = try container.decodeIfPresent(Double.self, forKey: .bpm)
        let beatsPerBar = try container.decodeIfPresent(Int.self, forKey: .beatsPerBar)
        let records = try container.decode([StrokeRecord].self, forKey: .strokes)
        let faderEventRecords = try container.decodeIfPresent([FaderEventRecord].self, forKey: .faderEvents) ?? []

        let strokes: [Stroke]
        let faderEvents: [FaderEvent]
        let demoStart: TimeInterval
        let demoEnd: TimeInterval
        let phraseStart: TimeInterval?
        let phraseEnd: TimeInterval?

        switch Self.resolvedTimingDomain(timingBasis: timingBasis) {
        case .seconds:
            strokes = try records.enumerated().map { index, record in
                guard let startTime = record.startTime,
                      let endTime = record.endTime else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .strokes,
                        in: container,
                        debugDescription: "Stroke \(index) is missing startTime/endTime in a seconds-domain document"
                    )
                }
                return Stroke(startTime: startTime,
                              endTime: endTime,
                              direction: record.direction,
                              speedClassification: record.speedClassification,
                              faderState: record.faderState,
                              startBeat: record.startBeat,
                              endBeat: record.endBeat)
            }
            faderEvents = try faderEventRecords.enumerated().map { index, record in
                guard let time = record.time else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .faderEvents,
                        in: container,
                        debugDescription: "Fader event \(index) is missing time in a seconds-domain document"
                    )
                }
                return FaderEvent(time: time, state: record.state, beat: record.beat)
            }
            // Author-declared document bounds are trusted as-is in the
            // seconds domain — never recomputed from strokes or fader
            // events here (that recomputation only applies to the
            // beat-authored branch below, which has no authored bounds).
            demoStart = try container.decode(TimeInterval.self, forKey: .demoStart)
            demoEnd = try container.decode(TimeInterval.self, forKey: .demoEnd)
            phraseStart = try container.decodeIfPresent(TimeInterval.self, forKey: .phraseStart)
            phraseEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .phraseEnd)
        case .beats:
            guard let bpm, bpm.isFinite, bpm > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bpm,
                    in: container,
                    debugDescription: "Beat-authored document (timingBasis \(timingBasis)) requires a finite bpm > 0 to materialize seconds"
                )
            }
            let secondsPerBeat = 60.0 / bpm
            strokes = try records.enumerated().map { index, record in
                guard let startBeat = record.startBeat,
                      let endBeat = record.endBeat else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .strokes,
                        in: container,
                        debugDescription: "Stroke \(index) is missing startBeat/endBeat in a beat-authored document"
                    )
                }
                return Stroke(startTime: startBeat * secondsPerBeat,
                              endTime: endBeat * secondsPerBeat,
                              direction: record.direction,
                              speedClassification: record.speedClassification,
                              faderState: record.faderState,
                              startBeat: startBeat,
                              endBeat: endBeat)
            }
            // `time` is never trusted here even when present in the JSON —
            // beats are the only authority for a beat-authored document, so
            // it is always re-derived from `beat × secondsPerBeat`.
            faderEvents = try faderEventRecords.enumerated().map { index, record in
                guard let beat = record.beat else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .faderEvents,
                        in: container,
                        debugDescription: "Fader event \(index) is missing beat in a beat-authored document"
                    )
                }
                return FaderEvent(time: beat * secondsPerBeat, state: record.state, beat: beat)
            }
            demoStart = 0
            // The canonical time horizon is the union of BOTH authored
            // streams, not strokes alone — a fader event may end after the
            // last stroke.
            demoEnd = max(strokes.map(\.endTime).max() ?? 0,
                          faderEvents.map(\.time).max() ?? 0)
            phraseStart = 0
            phraseEnd = demoEnd
        }

        self.init(version: version,
                  scratchID: scratchID,
                  demoStart: demoStart,
                  demoEnd: demoEnd,
                  phraseStart: phraseStart,
                  phraseEnd: phraseEnd,
                  timingBasis: timingBasis,
                  bpm: bpm,
                  beatsPerBar: beatsPerBar,
                  strokes: strokes,
                  faderEvents: faderEvents)
    }

    // MARK: Beat projection

    /// Re-materializes a beat-authored notation's derived seconds at `bpm`.
    ///
    /// The result is STILL a beat-authored notation — it keeps its beat
    /// `timingBasis`, its authoritative `startBeat`/`endBeat` fields, and
    /// records the projection tempo in `bpm`. Only the derived seconds
    /// cache changes; the timing domain does not. Pure and deterministic;
    /// returns `nil` when `bpm` is unusable, any stroke lacks beat fields,
    /// or any fader event lacks a beat field.
    func projectedToSeconds(bpm targetBPM: Double) -> ScratchNotation? {
        // Only beat-AUTHORED notation may be reprojected: on a legacy
        // seconds-authored document, incidental beat annotations are
        // non-authoritative and must not be promoted into new seconds.
        guard resolvedTimingDomain == .beats else { return nil }
        guard targetBPM.isFinite, targetBPM > 0 else { return nil }
        let secondsPerBeat = 60.0 / targetBPM
        var projected: [Stroke] = []
        projected.reserveCapacity(strokes.count)
        for stroke in strokes {
            guard let startBeat = stroke.startBeat,
                  let endBeat = stroke.endBeat else { return nil }
            projected.append(Stroke(startTime: startBeat * secondsPerBeat,
                                    endTime: endBeat * secondsPerBeat,
                                    direction: stroke.direction,
                                    speedClassification: stroke.speedClassification,
                                    faderState: stroke.faderState,
                                    startBeat: startBeat,
                                    endBeat: endBeat))
        }
        var projectedFaderEvents: [FaderEvent] = []
        projectedFaderEvents.reserveCapacity(faderEvents.count)
        for event in faderEvents {
            guard let beat = event.beat else { return nil }
            projectedFaderEvents.append(FaderEvent(time: beat * secondsPerBeat,
                                                    state: event.state,
                                                    beat: beat))
        }
        // The canonical time horizon is the union of BOTH authored streams,
        // not strokes alone.
        let maxEnd = max(projected.map(\.endTime).max() ?? 0,
                         projectedFaderEvents.map(\.time).max() ?? 0)
        return ScratchNotation(version: version,
                               scratchID: scratchID,
                               demoStart: 0,
                               demoEnd: maxEnd,
                               phraseStart: 0,
                               phraseEnd: maxEnd,
                               timingBasis: timingBasis,
                               bpm: targetBPM,
                               beatsPerBar: beatsPerBar,
                               strokes: projected,
                               faderEvents: projectedFaderEvents)
    }

    // MARK: Validation

    /// Tolerance for the seconds-vs-beat-projection agreement rule, per
    /// stroke endpoint, in seconds.
    static let secondsBeatAgreementTolerance: TimeInterval = 1e-6

    /// Pure invariant check — deliberately NOT part of decoding (bundle
    /// loaders treat any decode error as "no notation" and views silently
    /// blank, so decoding stays tolerant and strictness lives here).
    ///
    /// Beyond structural checks, this enforces the no-silent-disagreement
    /// rule for beat-authored values: a materialized beat-authored
    /// `ScratchNotation` must carry a usable `bpm`, and every stroke's
    /// derived seconds must equal the beat projection at that tempo within
    /// `secondsBeatAgreementTolerance`. Tempo-free patterns are represented
    /// by `ScratchNotation.BeatPattern`, never by this type.
    /// Returns an ordered list of human-readable issues; empty means valid.
    func validationIssues() -> [String] {
        var issues: [String] = []
        let tolerance = Self.secondsBeatAgreementTolerance

        if !demoStart.isFinite || !demoEnd.isFinite {
            issues.append("demoStart/demoEnd must be finite")
        } else if demoEnd < demoStart {
            issues.append("demoEnd (\(demoEnd)) precedes demoStart (\(demoStart))")
        }
        if let phraseStart, !phraseStart.isFinite {
            issues.append("phraseStart must be finite")
        }
        if let phraseEnd, !phraseEnd.isFinite {
            issues.append("phraseEnd must be finite")
        }
        if let phraseStart, let phraseEnd, phraseEnd < phraseStart {
            issues.append("phraseEnd (\(phraseEnd)) precedes phraseStart (\(phraseStart))")
        }
        if let bpm, !bpm.isFinite || bpm <= 0 {
            issues.append("bpm must be finite and > 0, got \(bpm)")
        }
        if let beatsPerBar, beatsPerBar <= 0 {
            issues.append("beatsPerBar must be > 0, got \(beatsPerBar)")
        }

        for (index, stroke) in strokes.enumerated() {
            if !stroke.startTime.isFinite || !stroke.endTime.isFinite {
                issues.append("stroke \(index): startTime/endTime must be finite")
                continue
            }
            if stroke.endTime < stroke.startTime {
                issues.append("stroke \(index): endTime precedes startTime")
            }
            switch (stroke.startBeat, stroke.endBeat) {
            case (nil, nil):
                break
            case (let startBeat?, let endBeat?):
                if !startBeat.isFinite || !endBeat.isFinite {
                    issues.append("stroke \(index): startBeat/endBeat must be finite")
                } else if endBeat < startBeat {
                    issues.append("stroke \(index): endBeat precedes startBeat")
                }
            default:
                issues.append("stroke \(index): startBeat/endBeat must be both present or both absent")
            }
            if index > 0 {
                let previous = strokes[index - 1]
                if stroke.startTime < previous.startTime - tolerance {
                    issues.append("stroke \(index): strokes are not sorted by startTime")
                } else if stroke.startTime < previous.endTime - tolerance {
                    issues.append("stroke \(index): overlaps stroke \(index - 1)")
                }
                if let startBeat = stroke.startBeat,
                   let previousEndBeat = previous.endBeat,
                   startBeat < previousEndBeat - tolerance {
                    issues.append("stroke \(index): beat span overlaps stroke \(index - 1)")
                }
            }
        }

        if resolvedTimingDomain == .beats {
            if let bpm, bpm.isFinite, bpm > 0 {
                let secondsPerBeat = 60.0 / bpm
                for (index, stroke) in strokes.enumerated() {
                    guard let startBeat = stroke.startBeat,
                          let endBeat = stroke.endBeat else {
                        issues.append("stroke \(index): beat-authored notation requires startBeat/endBeat")
                        continue
                    }
                    if abs(stroke.startTime - startBeat * secondsPerBeat) > tolerance {
                        issues.append("stroke \(index): derived startTime disagrees with beat projection")
                    }
                    if abs(stroke.endTime - endBeat * secondsPerBeat) > tolerance {
                        issues.append("stroke \(index): derived endTime disagrees with beat projection")
                    }
                }
            } else {
                issues.append("beat-authored ScratchNotation requires bpm — tempo-free patterns live in ScratchNotation.BeatPattern")
            }
        }

        // Fader-event structural checks — independent of stroke boundaries
        // by design (no cross-check against `strokes`). Which field is
        // authoritative for ordering/initial-state depends entirely on the
        // notation's resolved timing domain: a seconds-authored document's
        // incidental `beat` annotations are never used to validate
        // ordering, exactly mirroring the authority rule that governs
        // strokes.
        switch resolvedTimingDomain {
        case .seconds:
            for (index, event) in faderEvents.enumerated() {
                if !event.time.isFinite {
                    issues.append("faderEvent \(index): time must be finite")
                    continue
                }
                if event.time < 0 {
                    issues.append("faderEvent \(index): time must be >= 0, got \(event.time)")
                }
                if index == 0, event.time != 0 {
                    issues.append("faderEvent 0: first fader event must be at time 0, got \(event.time)")
                }
                if index > 0 {
                    let previous = faderEvents[index - 1]
                    if event.time <= previous.time {
                        issues.append("faderEvent \(index): time must strictly increase over faderEvent \(index - 1)")
                    }
                    if event.state == previous.state {
                        issues.append("faderEvent \(index): adjacent fader events must not repeat the same state")
                    }
                }
            }
        case .beats:
            let secondsPerBeat: Double?
            if let bpm, bpm.isFinite, bpm > 0 {
                secondsPerBeat = 60.0 / bpm
            } else {
                secondsPerBeat = nil
            }
            for (index, event) in faderEvents.enumerated() {
                guard let beat = event.beat, beat.isFinite else {
                    issues.append("faderEvent \(index): beat-authored notation requires a finite beat")
                    continue
                }
                if beat < 0 {
                    issues.append("faderEvent \(index): beat must be >= 0, got \(beat)")
                }
                if index == 0, beat != 0 {
                    issues.append("faderEvent 0: first fader event must be at beat 0, got \(beat)")
                }
                if index > 0, let previousBeat = faderEvents[index - 1].beat, beat <= previousBeat {
                    issues.append("faderEvent \(index): beat must strictly increase over faderEvent \(index - 1)")
                }
                if index > 0, event.state == faderEvents[index - 1].state {
                    issues.append("faderEvent \(index): adjacent fader events must not repeat the same state")
                }
                if !event.time.isFinite {
                    issues.append("faderEvent \(index): time must be finite")
                } else if let secondsPerBeat, abs(event.time - beat * secondsPerBeat) > tolerance {
                    issues.append("faderEvent \(index): derived time disagrees with beat projection")
                }
            }
        }

        return issues
    }

    var timelineDuration: TimeInterval {
        if let phraseEnd {
            return max(0, phraseEnd)
        }
        return max(0, demoEnd - demoStart)
    }

    var strokeSegments: [ScratchLabBabyScratchStrokeSegment] {
        strokes.enumerated().map { index, stroke in
            let nextStartTime = index + 1 < strokes.count
                ? strokes[index + 1].startTime
                : timelineDuration
            return ScratchLabBabyScratchStrokeSegment(
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                direction: stroke.motionDirection,
                holdAfter: max(0, nextStartTime - stroke.endTime),
                startProgress: stroke.startProgress,
                endProgress: stroke.endProgress
            )
        }
    }

    static let babyScratch: ScratchNotation? = loadBabyScratchFromBundle()

    /// Full-demo notation constructed from the extracted stroke resource
    /// (`CoachDemoMotion/baby_scratch_strokes.json`). The resource follows
    /// the bundled 79 BPM performance exactly: a 2-second lead-in, 16
    /// forward/backward cycles, and a 2-second tail hold.
    ///
    /// Falls back to `nil` when the extracted stroke resource is missing
    /// from the bundle — callers should treat `nil` as the empty state
    /// (same pattern as `babyScratch`).
    ///
    /// **Follow-up:** The Review tab (`reviewTargetNotationStageCard`)
    /// still uses `ScratchNotation.babyScratch` (the short ~5 s excerpt)
    /// because Review is a static chart with its own renderer and
    /// windowing. Expanding Review to the full-demo source is a separate
    /// product decision — do not drive-by wire it without a dedicated
    /// slice and sign-off.
    static let babyScratchDemo: ScratchNotation? = babyScratchDemoFromExtractedStrokes()

    /// 76-stroke four-phrase Baby Scratch target notation built from
    /// audio-unit semantic analysis of the bundled demo WAV.
    ///
    /// Each audible baby-scratch unit is an F/B pair (2 strokes);
    /// the final release is a single forward let-go.
    ///
    /// Phrase counts: 19 + 19 + 13 + 25 = 76.
    /// Silence/instruction gaps between phrases are not represented
    /// as strokes — only waveform-active regions carry notation.
    static let babyScratchFull76: ScratchNotation? = loadBabyScratchFull76FromBundle()

    static func loadBabyScratchFull76FromBundle(_ bundle: Bundle = .main) -> ScratchNotation? {
        guard let url = bundle.url(
            forResource: "baby_scratch_full_76",
            withExtension: "json",
            subdirectory: "Notation"
        ) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ScratchNotation.self, from: data)
        } catch {
            Logger(subsystem: "com.scratchlab.capture", category: "ScratchNotation")
                .warning("Failed to load 76-stroke Baby Scratch notation: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Beat-quantized 76-stroke Baby Scratch notation for teaching/practice.
    /// 19 + 19 + 13 + 25 strokes, BPM 79, 4/4, 6-beat body per phrase.
    /// F1 and final let-go are beat-anchored.  F/B pairs share amplitude.
    static let babyScratchFull76BeatQuantized: ScratchNotation? = loadBabyScratchFull76BeatQuantizedFromBundle()

    static func loadBabyScratchFull76BeatQuantizedFromBundle(_ bundle: Bundle = .main) -> ScratchNotation? {
        guard let url = bundle.url(
            forResource: "baby_scratch_full_76_beat_quantized",
            withExtension: "json",
            subdirectory: "Notation"
        ) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ScratchNotation.self, from: data)
        } catch {
            Logger(subsystem: "com.scratchlab.capture", category: "ScratchNotation")
                .warning("Failed to load beat-quantized Baby Scratch notation: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func loadBabyScratchFromBundle(_ bundle: Bundle = .main) -> ScratchNotation? {
        guard let url = bundle.url(
            forResource: "baby_scratch",
            withExtension: "json",
            subdirectory: "Notation"
        ) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ScratchNotation.self, from: data)
        } catch {
            Logger(subsystem: "com.scratchlab.capture", category: "ScratchNotation")
                .warning("Failed to load Baby Scratch notation JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Constructs a full-length `ScratchNotation` from the existing
    /// `BabyScratchExtractedStrokeResource` (the same full extracted
    /// stroke timeline the 3D Coach animation rig already consumes).
    ///
    /// Each extracted stroke is mapped with:
    /// - Direction preserved (`"forward"` → `.forward`, `"backward"` →
    ///   `.backward`). Unknown direction strings fail the factory
    ///   (return `nil`) rather than silently defaulting.
    /// - Speed defaulted to `.medium` (the extracted resource does not
    ///   carry an explicit speed classification)
    /// - Fader defaulted to `.open` (Baby Scratch is always fader-open)
    ///
    /// The factory creates no new bundled data files — it reuses the
    /// existing `CoachDemoMotion/baby_scratch_strokes.json` already
    /// shipped in the app.
    static func babyScratchDemoFromExtractedStrokes(_ bundle: Bundle = .main) -> ScratchNotation? {
        guard let resource = BabyScratchExtractedStrokeResource.loadFromBundle(bundle) else {
            return nil
        }
        var strokes: [Stroke] = []
        strokes.reserveCapacity(resource.strokes.count)
        for extracted in resource.strokes {
            let direction: ScratchNotationDirection
            switch extracted.direction {
            case "forward":  direction = .forward
            case "backward": direction = .backward
            default:
                Logger(subsystem: "com.scratchlab.capture", category: "ScratchNotation")
                    .warning("Baby Scratch extracted stroke has unknown direction '\(extracted.direction, privacy: .public)' — refusing to construct full-demo notation")
                return nil
            }
            strokes.append(Stroke(
                startTime: extracted.startTime,
                endTime: extracted.endTime,
                direction: direction,
                speedClassification: .medium,
                faderState: .open
            ))
        }
        guard !strokes.isEmpty else { return nil }
        return ScratchNotation(
            version: 1,
            scratchID: resource.scratchID,
            demoStart: resource.demoStart,
            demoEnd: resource.demoEnd,
            phraseStart: resource.phraseStart,
            phraseEnd: resource.phraseEnd,
            timingBasis: "extracted_strokes_full_demo",
            strokes: strokes
        )
    }
}

extension ScratchNotation {

    /// A beat-authored notation pattern with NO materialized seconds — the
    /// representation of canonical musical notation before a tempo has been
    /// selected. This is the explicit "unmaterialized" state:
    ///
    ///     BeatPattern (beats only, tempo-free)
    ///         --- materialized(bpm:) --->
    ///     ScratchNotation (beats authoritative + derived seconds + bpm)
    ///
    /// Because the type carries no `startTime`/`endTime` anywhere, a
    /// tempo-free pattern cannot masquerade as seconds-ready notation:
    /// seconds-domain consumers (LaneContent, overlays, playback) simply
    /// cannot accept it. Selecting a tempo via `materialized(bpm:)` is the
    /// only path to seconds.
    struct BeatPattern: Codable, Equatable, Sendable {

        struct BeatStroke: Codable, Equatable, Sendable {
            let startBeat: Double
            let endBeat: Double
            let direction: ScratchNotationDirection
            let speedClassification: ScratchNotationSpeedClassification
            let faderState: ScratchNotationFaderState

            var durationBeats: Double { max(0, endBeat - startBeat) }
        }

        /// A tempo-free fader-state edge: "at `beat`, the fader becomes
        /// `state`." See `faderEvents` for the authority rule against
        /// `BeatStroke.faderState`.
        struct BeatFaderEvent: Codable, Equatable, Sendable {
            let beat: Double
            let state: ScratchNotationFaderState
        }

        let version: Int
        let scratchID: String
        /// Must carry `ScratchNotation.beatAuthoredTimingBasisPrefix` so the
        /// materialized document resolves to the `.beats` domain
        /// (`validationIssues()` enforces this).
        let timingBasis: String
        let beatsPerBar: Int?
        let strokes: [BeatStroke]
        /// The canonical high-resolution fader-state edge stream, in beats.
        /// AUTHORITY RULE: when non-empty, this is the authoritative fader
        /// description and each stroke's `BeatStroke.faderState` becomes a
        /// legacy/compatibility snapshot only — the two channels are never
        /// independently canonical. When empty (every pattern authored in
        /// this slice, including `babyScratchCycle`), NO canonical fader
        /// edge channel exists — never read that as implicitly open or
        /// closed; per-stroke `faderState` remains the sole fader
        /// description and is fully sufficient on its own.
        let faderEvents: [BeatFaderEvent]

        init(version: Int,
             scratchID: String,
             timingBasis: String,
             beatsPerBar: Int?,
             strokes: [BeatStroke],
             faderEvents: [BeatFaderEvent] = []) {
            self.version = version
            self.scratchID = scratchID
            self.timingBasis = timingBasis
            self.beatsPerBar = beatsPerBar
            self.strokes = strokes
            self.faderEvents = faderEvents
        }

        /// Total span of the pattern, in beats — the union of BOTH
        /// authored streams, since fader timing is independent of stroke
        /// boundaries and may extend past the last stroke.
        var durationBeats: Double {
            max(strokes.map(\.endBeat).max() ?? 0,
                faderEvents.map(\.beat).max() ?? 0)
        }

        /// The ONLY path from musical time to seconds: materializes the
        /// pattern at `bpm` as a beat-authored `ScratchNotation` whose
        /// seconds are derived (`seconds = beats × 60 / bpm`) and whose
        /// `bpm` records the projection tempo. Beats remain authoritative
        /// in the result; re-projection at another tempo goes through
        /// `ScratchNotation.projectedToSeconds(bpm:)`. Pure, deterministic;
        /// `nil` when `bpm` is unusable or the pattern itself is
        /// structurally invalid — this boundary never emits a seconds-ready
        /// notation from a malformed pattern.
        func materialized(bpm: Double) -> ScratchNotation? {
            guard validationIssues().isEmpty else { return nil }
            guard bpm.isFinite, bpm > 0 else { return nil }
            let secondsPerBeat = 60.0 / bpm
            let materializedStrokes = strokes.map { stroke in
                Stroke(startTime: stroke.startBeat * secondsPerBeat,
                       endTime: stroke.endBeat * secondsPerBeat,
                       direction: stroke.direction,
                       speedClassification: stroke.speedClassification,
                       faderState: stroke.faderState,
                       startBeat: stroke.startBeat,
                       endBeat: stroke.endBeat)
            }
            let materializedFaderEvents = faderEvents.map { event in
                ScratchNotation.FaderEvent(time: event.beat * secondsPerBeat,
                                           state: event.state,
                                           beat: event.beat)
            }
            // The canonical time horizon is the union of BOTH authored
            // streams, not strokes alone.
            let maxEnd = max(materializedStrokes.map(\.endTime).max() ?? 0,
                             materializedFaderEvents.map(\.time).max() ?? 0)
            return ScratchNotation(version: version,
                                   scratchID: scratchID,
                                   demoStart: 0,
                                   demoEnd: maxEnd,
                                   phraseStart: 0,
                                   phraseEnd: maxEnd,
                                   timingBasis: timingBasis,
                                   bpm: bpm,
                                   beatsPerBar: beatsPerBar,
                                   strokes: materializedStrokes,
                                   faderEvents: materializedFaderEvents)
        }

        /// Structural validation for the tempo-free pattern — no bpm
        /// involved, per the authority/tempo separation. `faderEvents` are
        /// checked independently of `strokes` — no cross-stream ordering
        /// constraint; a fader edge may freely share a beat with a stroke
        /// boundary.
        func validationIssues() -> [String] {
            var issues: [String] = []
            if !timingBasis.hasPrefix(ScratchNotation.beatAuthoredTimingBasisPrefix) {
                issues.append("timingBasis '\(timingBasis)' does not declare beat authorship")
            }
            if let beatsPerBar, beatsPerBar <= 0 {
                issues.append("beatsPerBar must be > 0, got \(beatsPerBar)")
            }
            for (index, stroke) in strokes.enumerated() {
                if !stroke.startBeat.isFinite || !stroke.endBeat.isFinite {
                    issues.append("stroke \(index): startBeat/endBeat must be finite")
                    continue
                }
                if stroke.endBeat < stroke.startBeat {
                    issues.append("stroke \(index): endBeat precedes startBeat")
                }
                if index > 0 {
                    let previous = strokes[index - 1]
                    if stroke.startBeat < previous.startBeat {
                        issues.append("stroke \(index): strokes are not sorted by startBeat")
                    } else if stroke.startBeat < previous.endBeat {
                        issues.append("stroke \(index): overlaps stroke \(index - 1)")
                    }
                }
            }
            for (index, event) in faderEvents.enumerated() {
                if !event.beat.isFinite {
                    issues.append("faderEvent \(index): beat must be finite")
                    continue
                }
                if event.beat < 0 {
                    issues.append("faderEvent \(index): beat must be >= 0, got \(event.beat)")
                }
                if index == 0, event.beat != 0 {
                    issues.append("faderEvent 0: first fader event must be at beat 0, got \(event.beat)")
                }
                if index > 0 {
                    let previous = faderEvents[index - 1]
                    if event.beat <= previous.beat {
                        issues.append("faderEvent \(index): beat must strictly increase over faderEvent \(index - 1)")
                    }
                    if event.state == previous.state {
                        issues.append("faderEvent \(index): adjacent fader events must not repeat the same state")
                    }
                }
            }
            return issues
        }
    }

    /// The canonical Baby Scratch unit: ONE repeatable cycle in musical
    /// time — forward for half a beat, backward for half a beat, contiguous
    /// (no holds), fader open throughout. One cycle = 1.0 beat, agreeing
    /// with the technique definition in `ScratchLibrary` ("baby_scratch":
    /// 2 peaks, equal rhythm, `formulaDefaultBeats == 1.0`) and with
    /// `BabyScratchPolarity` (first stroke forward, alternating).
    ///
    /// Tempo-free by type: a `BeatPattern` carries no seconds, so this value
    /// cannot reach seconds-domain consumers until `materialized(bpm:)`
    /// selects a session tempo. This is a TECHNIQUE definition, not a demo:
    /// the bundled 76-stroke resources remain demo/performance timelines
    /// conceptually built from repetitions of this cycle.
    ///
    /// Identity note: the cycle uses the repository's canonical TECHNIQUE
    /// ID `"baby_scratch"` (`ScratchLibrary.Scratch.id`,
    /// `CaptureSessionScratchType.babyScratch`), which is also what
    /// detected/performed notations carry via `detectedPreview`. The
    /// bundled authored resources still carry the legacy short ID
    /// `"baby"` — a pre-existing inconsistency, deliberately not extended
    /// to the canonical layer.
    static let babyScratchCycle = BeatPattern(
        version: 1,
        scratchID: CaptureSessionScratchType.babyScratch.rawValue,
        timingBasis: "beat_canonical_cycle_v1",
        beatsPerBar: nil,
        strokes: [
            .init(startBeat: 0.0, endBeat: 0.5,
                  direction: .forward, speedClassification: .medium, faderState: .open),
            .init(startBeat: 0.5, endBeat: 1.0,
                  direction: .backward, speedClassification: .medium, faderState: .open)
        ]
    )

    /// Every technique with a proven, SAFE-to-author `BeatPattern` (see the
    /// evidence audit on `babyScratchCycle`). Adding an entry here requires
    /// clearing the same bar: an anchored starting platter direction, exact
    /// beat-positioned strokes, cycle duration, and fader state — never
    /// guessed from `PatternSignature`/coach tips. Every other
    /// `ScratchLibrary` technique intentionally has no entry.
    static let canonicalBeatPatterns: [BeatPattern] = [babyScratchCycle]

    /// The canonical technique unit for `scratchID`, or `nil` when no
    /// evidenced `BeatPattern` exists for it yet — callers must treat `nil`
    /// as "no canonical target notation", never fall back to a guess.
    static func canonicalBeatPattern(forScratchID scratchID: String) -> BeatPattern? {
        canonicalBeatPatterns.first { $0.scratchID == scratchID }
    }
}

/// Frame-anchored direction polarity for Baby Scratch.
///
/// Audio onsets tell us *when* a stroke happened but not *which way* the
/// platter moved — the same attack envelope is produced by a forward push
/// and a backward pull. For Baby Scratch the platter alternates after a
/// known starting direction; a reference frame of the performer's first
/// move locks that polarity. `frame_000024.jpeg` (left deck, clockwise =
/// forward, crossfader open) anchors the canonical sequence to forward →
/// backward → forward → …, fader open throughout. This helper exposes the
/// sequence so onset-driven synthesisers (currently
/// `ScratchNotation.detectedPreview`) can superimpose direction onto
/// timing instead of trusting upstream's polarity guess.
enum BabyScratchPolarity {
    /// Authoritative first-stroke direction, anchored by the reference frame.
    static let initialDirection: ScratchNotationDirection = .forward
    /// Fader stays open across every Baby Scratch stroke — no cut.
    static let faderState: ScratchNotationFaderState = .open

    /// Canonical direction for the `index`-th stroke (0-based), alternating
    /// from `initialDirection`.
    static func direction(forStrokeAtIndex index: Int) -> ScratchNotationDirection {
        let safeIndex = max(index, 0)
        if safeIndex.isMultiple(of: 2) {
            return initialDirection
        }
        return initialDirection == .forward ? .backward : .forward
    }
}

extension ScratchNotation {
    static func detectedPreview(
        scratchID: String,
        events: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> ScratchNotation? {
        let sortedEvents = events.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
        guard !sortedEvents.isEmpty else { return nil }

        // Drop zero/negative-duration events first so the polarity index is
        // stable across survivors — otherwise a dropped event would skip an
        // alternation slot and produce two same-direction strokes in a row.
        let validEvents = sortedEvents.filter { $0.endTime > $0.startTime }
        let isBabyScratch = scratchID == CaptureSessionScratchType.babyScratch.rawValue

        let strokes: [Stroke] = validEvents.enumerated().compactMap { index, event -> Stroke? in
            let direction: ScratchNotationDirection
            let faderState: ScratchNotationFaderState
            if isBabyScratch {
                // Baby Scratch — polarity locked by the reference frame.
                // Onset timing from `event` is preserved as-is.
                direction = BabyScratchPolarity.direction(forStrokeAtIndex: index)
                faderState = BabyScratchPolarity.faderState
            } else {
                switch event.direction {
                case "forward":
                    direction = .forward
                case "backward":
                    direction = .backward
                default:
                    return nil
                }
                faderState = .open
            }

            let speedClassification: ScratchNotationSpeedClassification
            switch event.movementKind {
            case .fastPush, .fastPull:
                speedClassification = .fast
            case .slowDrag, .slowPullDrag:
                speedClassification = .slow
            default:
                speedClassification = .medium
            }

            return Stroke(
                startTime: event.startTime,
                endTime: event.endTime,
                direction: direction,
                speedClassification: speedClassification,
                faderState: faderState
            )
        }
        guard !strokes.isEmpty else { return nil }

        let phraseEnd = max(strokes.last?.endTime ?? 0, sortedEvents.last?.endTime ?? 0)
        return ScratchNotation(
            version: 1,
            scratchID: scratchID,
            demoStart: 0,
            demoEnd: phraseEnd,
            phraseStart: 0,
            phraseEnd: phraseEnd,
            timingBasis: "detected_capture",
            strokes: strokes
        )
    }
}

struct BabyScratchExtractedStrokeResource: Decodable, Equatable, Sendable {
    struct Stroke: Decodable, Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let direction: String
        let holdAfter: TimeInterval
        let startProgress: Double
        let endProgress: Double

        var motionDirection: ScratchMotionDirection {
            direction == "backward" ? .backward : .forward
        }

        var segment: ScratchLabBabyScratchStrokeSegment {
            ScratchLabBabyScratchStrokeSegment(
                startTime: startTime,
                endTime: endTime,
                direction: motionDirection,
                holdAfter: holdAfter,
                startProgress: startProgress,
                endProgress: endProgress
            )
        }
    }

    let version: Int
    let scratchID: String
    let timingSource: String
    let demoStart: TimeInterval
    let demoEnd: TimeInterval
    let phraseStart: TimeInterval?
    let phraseEnd: TimeInterval?
    let timelineDuration: TimeInterval
    let strokes: [Stroke]

    var strokeSegments: [ScratchLabBabyScratchStrokeSegment] {
        strokes.map(\.segment)
    }

    static func loadFromBundle(_ bundle: Bundle = .main) -> BabyScratchExtractedStrokeResource? {
        guard let url = bundle.url(
            forResource: "baby_scratch_strokes",
            withExtension: "json",
            subdirectory: "CoachDemoMotion"
        ) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(BabyScratchExtractedStrokeResource.self, from: data)
        } catch {
            Logger(subsystem: "com.scratchlab.capture", category: "BabyScratchMotion")
                .warning("Failed to load Baby Scratch extracted motion JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct BabyScratchReferenceMotionKeyframe: Equatable, Sendable {
    let time: TimeInterval
    let sourceTime: TimeInterval
    let handViewerHour: Double
    let stickerViewerHour: Double
    let recordRotationDegrees: Double
    let direction: ScratchMotionDirection
    let isHold: Bool
    let scratchProgress: Double
}

struct BabyScratchReferenceMotionPose: Equatable, Sendable {
    let scratchProgress: Double
    let handViewerHour: Double
    let stickerViewerHour: Double
    let recordRotationDegrees: Double
    let direction: ScratchMotionDirection
    let isHold: Bool
    let strokeDuration: TimeInterval?
}

enum BabyScratchNotationLoopMode: Equatable, Sendable {
    case fullDemoAudio
    case notationPhrase
    case disabled
}

enum BabyScratchReferenceTimingSource: String, Equatable, Sendable {
    case wavAudio = "wav_audio"
}

enum BabyScratchReferenceVideoAngleRole: String, Equatable, Sendable {
    case primary
    case validation
}

enum BabyScratchReferenceVideoUsage: String, Equatable, Sendable {
    case visualReferenceOnly = "visual_reference_only"
}

enum BabyScratchReferenceValidationFocus: String, Equatable, Sendable {
    case handPosition = "hand_position"
    case recordStickerMovement = "record_sticker_movement"
    case directionChanges = "direction_changes"
    case holdPhases = "hold_phases"
    case strokeSpeed = "stroke_speed"
}

struct BabyScratchReferenceVideoAngle: Equatable, Sendable {
    let angleID: String
    let path: String
    let role: BabyScratchReferenceVideoAngleRole
    let validationFocus: [BabyScratchReferenceValidationFocus]
}

struct BabyScratchReferenceAsset: Equatable, Sendable {
    let scratchName: String
    let bpm: Int
    let demoStart: TimeInterval
    let demoEnd: TimeInterval
    let audioPath: String
    let timingSource: BabyScratchReferenceTimingSource
    let videoAngles: [BabyScratchReferenceVideoAngle]
    let videoUsage: BabyScratchReferenceVideoUsage
    let motionTimelinePath: String?
    let embeddedMotionTimelineName: String?
    let automaticVideoTrackingEnabled: Bool
}

struct BabyScratchReferenceMotionTimeline: Sendable {
    static let handStartViewerHour: Double = 3
    static let handEndViewerHour: Double = 5
    static let stickerStartViewerHour: Double = 6
    static let stickerEndViewerHour: Double = 8
    static let recordRotationRangeDegrees: Double = 60
    // The bundled WAV is itself the demo, so app playback time 0 == demoStart.
    static let demoStart: TimeInterval = 0
    static let demoEnd: TimeInterval = 16.0483125
    static let phaseOffset: TimeInterval = 0
    // The clean-demo timeline encodes the complete 16-cycle performance, so
    // the audio and coach motion play through once without synthetic looping.
    static let demoAudioPhraseCycleCount = 1
    private static let fallbackPhraseDuration: TimeInterval = 1.0
    private static let notationResource = ScratchNotation.loadBabyScratchFromBundle()
    private static let extractedStrokeResource = BabyScratchExtractedStrokeResource.loadFromBundle()
    // Coach motion takes precedence so the visual rig can render extra
    // release/reset segments between phrases without polluting the notation.
    static let usesExtractedStrokeResource = extractedStrokeResource != nil
    static let usesNotationResource = !usesExtractedStrokeResource && notationResource != nil
    static let phraseStart: TimeInterval =
        extractedStrokeResource?.phraseStart
        ?? notationResource?.phraseStart
        ?? 0
    static let phraseEnd: TimeInterval = max(
        phraseStart,
        extractedStrokeResource?.phraseEnd
            ?? notationResource?.phraseEnd
            ?? fallbackPhraseDuration
    )
    static let phraseDuration: TimeInterval = phraseEnd
    static let phraseLoopDuration: TimeInterval = max(0, phraseEnd - phraseStart)

    static var sourceDuration: TimeInterval {
        max(0, demoEnd - demoStart)
    }

    static var demoAudioPhraseCycleDuration: TimeInterval {
        guard demoAudioPhraseCycleCount > 0 else { return sourceDuration }
        return sourceDuration / Double(demoAudioPhraseCycleCount)
    }

    static let strokeSegments: [ScratchLabBabyScratchStrokeSegment] =
        extractedStrokeResource?.strokeSegments
        ?? notationResource?.strokeSegments
        ?? fallbackStrokeSegments

    private static let fallbackStrokeSegments: [ScratchLabBabyScratchStrokeSegment] = [
        ScratchLabBabyScratchStrokeSegment(
            startTime: 0.04,
            endTime: 0.22,
            direction: .forward,
            holdAfter: 0.12,
            startProgress: 0,
            endProgress: 1
        ),
        ScratchLabBabyScratchStrokeSegment(
            startTime: 0.34,
            endTime: 0.52,
            direction: .backward,
            holdAfter: 0.48,
            startProgress: 1,
            endProgress: 0
        )
    ]

    static var keyframes: [BabyScratchReferenceMotionKeyframe] {
        var frames: [BabyScratchReferenceMotionKeyframe] = []
        frames.reserveCapacity(strokeSegments.count * 3)
        for segment in strokeSegments {
            frames.append(keyframe(
                time: segment.startTime,
                scratchProgress: segment.startProgress,
                direction: segment.direction,
                isHold: false
            ))
            frames.append(keyframe(
                time: segment.endTime,
                scratchProgress: segment.endProgress,
                direction: segment.direction,
                isHold: false
            ))
            frames.append(keyframe(
                time: segment.holdEndTime,
                scratchProgress: segment.endProgress,
                direction: .neutral,
                isHold: true
            ))
        }
        frames.append(keyframe(
            time: phraseDuration,
            scratchProgress: 0,
            direction: .neutral,
            isHold: true
        ))
        return frames.sorted { $0.time < $1.time }
    }

    static func pose(
        at playbackTime: TimeInterval,
        loopMode: BabyScratchNotationLoopMode = .fullDemoAudio
    ) -> BabyScratchReferenceMotionPose {
        let phase = timelineTime(forPlaybackTime: playbackTime, loopMode: loopMode) + phaseOffset
        for segment in strokeSegments {
            if phase >= segment.startTime && phase < segment.endTime {
                let localProgress = segment.duration > 0
                    ? (phase - segment.startTime) / segment.duration
                    : 1
                let scratchProgress = interpolate(
                    from: segment.startProgress,
                    to: segment.endProgress,
                    progress: localProgress
                )
                return pose(
                    scratchProgress: scratchProgress,
                    direction: segment.direction,
                    isHold: false,
                    strokeDuration: segment.duration
                )
            }

            if phase >= segment.endTime && phase < segment.holdEndTime {
                return pose(
                    scratchProgress: segment.endProgress,
                    direction: .neutral,
                    isHold: true,
                    strokeDuration: segment.duration
                )
            }
        }

        return pose(
            scratchProgress: 0,
            direction: .neutral,
            isHold: true,
            strokeDuration: nil
        )
    }

    static func sourceTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval {
        demoStart + boundedPlaybackTime(playbackTime)
    }

    static func timelineTime(
        forPlaybackTime playbackTime: TimeInterval,
        loopMode: BabyScratchNotationLoopMode = .fullDemoAudio
    ) -> TimeInterval {
        let boundedTime = boundedPlaybackTime(playbackTime)
        switch loopMode {
        case .fullDemoAudio:
            return cycleLocalTime(
                boundedTime,
                cycleDuration: demoAudioPhraseCycleDuration
            )
        case .notationPhrase:
            return notationPhraseLocalTime(boundedTime)
        case .disabled:
            return boundedTime
        }
    }

    static func timelineTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval {
        max(0, min(sourceDuration, sourceTime - demoStart))
    }

    static func pose(
        activeSegmentTime: TimeInterval,
        activeSegmentDuration: TimeInterval,
        direction: ScratchMotionDirection
    ) -> BabyScratchReferenceMotionPose {
        guard activeSegmentDuration > 0,
              direction != .neutral else {
            return pose(
                scratchProgress: 0,
                direction: .neutral,
                isHold: true,
                strokeDuration: nil
            )
        }

        let rawProgress = max(0, min(1, activeSegmentTime / activeSegmentDuration))
        let scratchProgress: Double
        switch direction {
        case .backward:
            scratchProgress = 1 - rawProgress
        default:
            scratchProgress = rawProgress
        }
        return pose(
            scratchProgress: scratchProgress,
            direction: direction,
            isHold: false,
            strokeDuration: activeSegmentDuration
        )
    }

    private static func keyframe(
        time: TimeInterval,
        scratchProgress: Double,
        direction: ScratchMotionDirection,
        isHold: Bool
    ) -> BabyScratchReferenceMotionKeyframe {
        BabyScratchReferenceMotionKeyframe(
            time: time,
            sourceTime: demoStart + time,
            handViewerHour: handViewerHour(progress: scratchProgress),
            stickerViewerHour: stickerViewerHour(progress: scratchProgress),
            recordRotationDegrees: recordRotationDegrees(progress: scratchProgress),
            direction: direction,
            isHold: isHold,
            scratchProgress: scratchProgress
        )
    }

    private static func pose(
        scratchProgress: Double,
        direction: ScratchMotionDirection,
        isHold: Bool,
        strokeDuration: TimeInterval?
    ) -> BabyScratchReferenceMotionPose {
        let clampedProgress = max(0, min(1, scratchProgress))
        return BabyScratchReferenceMotionPose(
            scratchProgress: clampedProgress,
            handViewerHour: handViewerHour(progress: clampedProgress),
            stickerViewerHour: stickerViewerHour(progress: clampedProgress),
            recordRotationDegrees: recordRotationDegrees(progress: clampedProgress),
            direction: direction,
            isHold: isHold,
            strokeDuration: strokeDuration
        )
    }

    private static func handViewerHour(progress: Double) -> Double {
        interpolate(from: handStartViewerHour, to: handEndViewerHour, progress: progress)
    }

    private static func stickerViewerHour(progress: Double) -> Double {
        interpolate(from: stickerStartViewerHour, to: stickerEndViewerHour, progress: progress)
    }

    private static func recordRotationDegrees(progress: Double) -> Double {
        interpolate(from: 0, to: recordRotationRangeDegrees, progress: progress)
    }

    private static func boundedPlaybackTime(_ playbackTime: TimeInterval) -> TimeInterval {
        min(sourceDuration, max(0, playbackTime))
    }

    private static func notationPhraseLocalTime(_ playbackTime: TimeInterval) -> TimeInterval {
        guard phraseLoopDuration > 0,
              playbackTime >= phraseEnd else {
            return playbackTime
        }
        return phraseStart + positiveRemainder(
            playbackTime - phraseStart,
            duration: phraseLoopDuration
        )
    }

    private static func cycleLocalTime(
        _ playbackTime: TimeInterval,
        cycleDuration: TimeInterval
    ) -> TimeInterval {
        guard cycleDuration > 0 else { return playbackTime }
        return positiveRemainder(playbackTime, duration: cycleDuration)
    }

    private static func positiveRemainder(
        _ value: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard duration > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: duration)
        let positive = remainder >= 0 ? remainder : remainder + duration
        return duration - positive < 0.000_001 ? 0 : positive
    }

    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + ((end - start) * max(0, min(1, progress)))
    }
}

#if DEBUG
struct BabyScratchCoachTimingProbe: Equatable, Sendable {
    let playbackTime: TimeInterval
    let timelineTime: TimeInterval
    let strokeIndex: Int?
    let direction: ScratchMotionDirection
    let progress: Double
    let isHold: Bool
    let timingSource: String
}

extension BabyScratchReferenceMotionTimeline {
    static let debugProbePlaybackTimes: [TimeInterval] = [2.0, 2.410975, 3.062990, 5.85, 8.5, 12.45, 14.048311, 15.0]

    static func debugTimingProbe(
        at playbackTime: TimeInterval,
        loopMode: BabyScratchNotationLoopMode = .fullDemoAudio
    ) -> BabyScratchCoachTimingProbe {
        let phase = timelineTime(forPlaybackTime: playbackTime, loopMode: loopMode) + phaseOffset
        for (index, segment) in strokeSegments.enumerated() {
            if phase >= segment.startTime && phase < segment.endTime {
                let localProgress = segment.duration > 0
                    ? (phase - segment.startTime) / segment.duration
                    : 1
                let scratchProgress = interpolate(
                    from: segment.startProgress,
                    to: segment.endProgress,
                    progress: localProgress
                )
                return BabyScratchCoachTimingProbe(
                    playbackTime: playbackTime,
                    timelineTime: phase,
                    strokeIndex: index,
                    direction: segment.direction,
                    progress: scratchProgress,
                    isHold: false,
                    timingSource: debugTimingSource
                )
            }

            if phase >= segment.endTime && phase < segment.holdEndTime {
                return BabyScratchCoachTimingProbe(
                    playbackTime: playbackTime,
                    timelineTime: phase,
                    strokeIndex: index,
                    direction: .neutral,
                    progress: segment.endProgress,
                    isHold: true,
                    timingSource: debugTimingSource
                )
            }
        }

        return BabyScratchCoachTimingProbe(
            playbackTime: playbackTime,
            timelineTime: phase,
            strokeIndex: nil,
            direction: .neutral,
            progress: 0,
            isHold: true,
            timingSource: debugTimingSource
        )
    }

    static func debugTimingReport(
        at playbackTime: TimeInterval,
        loopMode: BabyScratchNotationLoopMode = .fullDemoAudio
    ) -> String {
        let probe = debugTimingProbe(at: playbackTime, loopMode: loopMode)
        let strokeLabel = probe.strokeIndex.map(String.init) ?? "none"
        return "time=\(probe.playbackTime) timeline=\(probe.timelineTime) stroke=\(strokeLabel) direction=\(probe.direction) progress=\(probe.progress) source=\(probe.timingSource)"
    }

    private static var debugTimingSource: String {
        if usesNotationResource {
            return "Notation/baby_scratch.json"
        }
        if usesExtractedStrokeResource {
            return "CoachDemoMotion/baby_scratch_strokes.json"
        }
        return "fallback"
    }
}
#endif

#if DEBUG
extension BabyScratchReferenceAsset {
    // Reference angles are development-only inputs for validating the hand-authored timeline.
    // Demo Mode keeps rendering the animated coach rig and never plays these MKVs.
    static let babyScratch79BPM = BabyScratchReferenceAsset(
        scratchName: "Baby Scratch",
        bpm: 79,
        demoStart: BabyScratchReferenceMotionTimeline.demoStart,
        demoEnd: BabyScratchReferenceMotionTimeline.demoEnd,
        audioPath: "CoachDemoAudio/baby_noBeat.wav",
        timingSource: .wavAudio,
        videoAngles: [
            BabyScratchReferenceVideoAngle(
                angleID: "angle_1",
                path: "CoachDemoVideo/baby_angle_1_reference",
                role: .primary,
                validationFocus: [
                    .handPosition,
                    .recordStickerMovement,
                    .directionChanges,
                    .holdPhases,
                    .strokeSpeed
                ]
            ),
            BabyScratchReferenceVideoAngle(
                angleID: "angle_2",
                path: "CoachDemoVideo/baby_angle_2_reference",
                role: .validation,
                validationFocus: [
                    .handPosition,
                    .directionChanges
                ]
            ),
            BabyScratchReferenceVideoAngle(
                angleID: "angle_3",
                path: "CoachDemoVideo/baby_angle_3_reference",
                role: .validation,
                validationFocus: [
                    .recordStickerMovement,
                    .holdPhases
                ]
            ),
            BabyScratchReferenceVideoAngle(
                angleID: "angle_4",
                path: "CoachDemoVideo/baby_angle_4_reference",
                role: .validation,
                validationFocus: [
                    .directionChanges,
                    .holdPhases,
                    .strokeSpeed
                ]
            )
        ],
        videoUsage: .visualReferenceOnly,
        motionTimelinePath: "Notation/baby_scratch.json",
        embeddedMotionTimelineName: "BabyScratchReferenceMotionTimelineFallback",
        automaticVideoTrackingEnabled: false
    )
}
#endif

struct ScratchLabBabyScratchDemoMotionPattern: Sendable {
    static let babyScratchStrokeTimeline = BabyScratchReferenceMotionTimeline.strokeSegments
    static let babyScratchStrokeTimelineDuration = BabyScratchReferenceMotionTimeline.phraseDuration
    static let babyScratchDemoPhaseOffset = BabyScratchReferenceMotionTimeline.phaseOffset
    static let minimumActiveLevel: Float = 0.20
    static let maximumHoldAfter: TimeInterval = 0.30

    static func state(
        activePhaseTime: TimeInterval,
        activityLevel: Float = 1
    ) -> ScratchLabBabyScratchDemoMotionState {
        state(playbackTime: activePhaseTime, activityLevel: activityLevel)
    }

    static func state(
        playbackTime: TimeInterval,
        activityLevel: Float = 1
    ) -> ScratchLabBabyScratchDemoMotionState {
        let normalizedActivity = max(0, min(1, activityLevel))
        let isActive = normalizedActivity >= minimumActiveLevel
        guard isActive else {
            let inactiveState = ScratchLabBabyScratchDemoMotionState(
                recordPosition: 0,
                recordRotationDegrees: 0,
                inputLevel: normalizedActivity,
                direction: .neutral,
                feedback: listeningFeedback(direction: .neutral)
            )
            assert(!(isActive == false && inactiveState.animationState != .neutral))
            return inactiveState
        }

        let timelineState = BabyScratchReferenceMotionTimeline.pose(at: playbackTime)
        let inputLevel = min(1, max(0.12, strokeInputLevel(progress: timelineState.scratchProgress)) * max(0.42, normalizedActivity))
        let balance: ScratchMotionBalance = timelineState.direction == .backward ? .balanced : .listening
        let feedback = ScratchMotionFeedback(
            direction: timelineState.direction,
            balance: balance,
            forwardDuration: balance == .balanced ? timelineState.strokeDuration : nil,
            backwardDuration: balance == .balanced ? timelineState.strokeDuration : nil,
            timingError: balance == .balanced ? 0 : nil,
            forwardPeakAmplitude: balance == .balanced ? inputLevel : nil,
            backwardPeakAmplitude: balance == .balanced ? inputLevel : nil
        )

        return ScratchLabBabyScratchDemoMotionState(
            recordPosition: timelineState.scratchProgress,
            recordRotationDegrees: timelineState.recordRotationDegrees,
            inputLevel: inputLevel,
            direction: timelineState.direction,
            feedback: feedback
        )
    }

    static func timelinePhase(playbackTime: TimeInterval) -> TimeInterval {
        BabyScratchReferenceMotionTimeline.timelineTime(forPlaybackTime: playbackTime)
            + babyScratchDemoPhaseOffset
    }

    static func isHoldWindow(playbackTime: TimeInterval) -> Bool {
        return babyScratchStrokeTimeline.contains { segment in
            let phase = timelinePhase(playbackTime: playbackTime)
            return phase >= segment.endTime && phase < segment.holdEndTime
        }
    }

    static func isMovingStrokeWindow(playbackTime: TimeInterval) -> Bool {
        return babyScratchStrokeTimeline.contains { segment in
            let phase = timelinePhase(playbackTime: playbackTime)
            return phase >= segment.startTime && phase < segment.endTime
        }
    }

    static func state(
        activeSegmentTime: TimeInterval,
        activeSegmentDuration: TimeInterval,
        strokeDirection: ScratchMotionDirection,
        activityLevel: Float
    ) -> ScratchLabBabyScratchDemoMotionState {
        let normalizedActivity = max(0, min(1, activityLevel))
        let isActive = normalizedActivity >= minimumActiveLevel
        guard isActive,
              activeSegmentDuration > 0,
              strokeDirection != .neutral else {
            let inactiveState = ScratchLabBabyScratchDemoMotionState(
                recordPosition: 0,
                recordRotationDegrees: 0,
                inputLevel: normalizedActivity,
                direction: .neutral,
                feedback: listeningFeedback(direction: .neutral)
            )
            assert(!(isActive == false && inactiveState.animationState != .neutral))
            return inactiveState
        }

        let timelineState = BabyScratchReferenceMotionTimeline.pose(
            activeSegmentTime: activeSegmentTime,
            activeSegmentDuration: activeSegmentDuration,
            direction: strokeDirection
        )
        let strokeLevel = strokeInputLevel(progress: timelineState.scratchProgress)
        let inputLevel = min(1, max(0.12, strokeLevel) * max(0.42, normalizedActivity))
        let balance: ScratchMotionBalance = strokeDirection == .backward ? .balanced : .listening
        let feedback = ScratchMotionFeedback(
            direction: timelineState.direction,
            balance: balance,
            forwardDuration: balance == .balanced ? activeSegmentDuration : nil,
            backwardDuration: balance == .balanced ? activeSegmentDuration : nil,
            timingError: balance == .balanced ? 0 : nil,
            forwardPeakAmplitude: balance == .balanced ? inputLevel : nil,
            backwardPeakAmplitude: balance == .balanced ? inputLevel : nil
        )

        return ScratchLabBabyScratchDemoMotionState(
            recordPosition: timelineState.scratchProgress,
            recordRotationDegrees: timelineState.recordRotationDegrees,
            inputLevel: inputLevel,
            direction: timelineState.direction,
            feedback: feedback
        )
    }

    private static func strokeInputLevel(progress: Double) -> Float {
        let centered = sin(max(0, min(1, progress)) * .pi)
        return Float(0.34 + (centered * 0.44))
    }

    private static func listeningFeedback(
        direction: ScratchMotionDirection
    ) -> ScratchMotionFeedback {
        ScratchMotionFeedback(
            direction: direction,
            balance: .listening,
            forwardDuration: nil,
            backwardDuration: nil,
            timingError: nil,
            forwardPeakAmplitude: nil,
            backwardPeakAmplitude: nil
        )
    }
}

struct ScratchCoachDemoAnimator: Sendable {
    static func state(
        scratchType: String,
        playbackTime: TimeInterval,
        isPlaying: Bool,
        activityLevel: Float = 1
    ) -> ScratchCoachDemoAnimationState {
        guard isPlaying else { return .neutral }

        switch normalizedScratchType(scratchType) {
        case "baby":
            return babyState(
                playbackTime: playbackTime,
                activityLevel: activityLevel
            )
        case "chirpflare":
            return chirpFlareState(playbackTime: playbackTime)
        default:
            return .neutral
        }
    }

    private static func babyState(
        playbackTime: TimeInterval,
        activityLevel: Float
    ) -> ScratchCoachDemoAnimationState {
        let motionState = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: playbackTime,
            activityLevel: activityLevel
        )
        let animationState = motionState.animationState
        return animationState == .neutral ? .babyScratchOpen : animationState
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

struct ScratchLabDemoAudioSampleBuffer: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
    private let activityEnvelope: [Float]
    private let activitySegmentTimes: [TimeInterval]
    private let activitySegmentDurations: [TimeInterval]
    private let activitySegmentDirections: [ScratchMotionDirection]
    private let activityFrameDuration: TimeInterval

    private static let activityFrameSize = 1_024
    private static let activeEnergyThresholdOn: Float = 0.20
    private static let activeEnergyThresholdOff: Float = 0.10

    init(audioURL: URL) throws {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        guard format.sampleRate > 0,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audioFile.length)
              ) else {
            throw SessionExportError.unableToPrepareExport
        }

        try audioFile.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            throw SessionExportError.missingRequiredFiles
        }

        let rawSamples = Self.downmixedSamples(from: buffer, frameCount: frameCount)
        let activityProfile = Self.activityProfile(
            from: rawSamples,
            sampleRate: format.sampleRate
        )
        self.samples = rawSamples
        self.sampleRate = format.sampleRate
        self.duration = Double(frameCount) / format.sampleRate
        self.activityEnvelope = activityProfile.envelope
        self.activitySegmentTimes = activityProfile.segmentTimes
        self.activitySegmentDurations = activityProfile.segmentDurations
        self.activitySegmentDirections = activityProfile.segmentDirections
        self.activityFrameDuration = activityProfile.frameDuration
    }

    init(samples: [Float], sampleRate: Double) {
        let activityProfile = Self.activityProfile(
            from: samples,
            sampleRate: sampleRate
        )
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        self.activityEnvelope = activityProfile.envelope
        self.activitySegmentTimes = activityProfile.segmentTimes
        self.activitySegmentDurations = activityProfile.segmentDurations
        self.activitySegmentDirections = activityProfile.segmentDirections
        self.activityFrameDuration = activityProfile.frameDuration
    }

    private static func downmixedSamples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int
    ) -> [Float] {
        let channelCount = max(1, Int(buffer.format.channelCount))

        if let floatChannelData = buffer.floatChannelData {
            var downmixed = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let channelData = floatChannelData[channel]
                for frame in 0..<frameCount {
                    downmixed[frame] += channelData[frame]
                }
            }
            return downmixed.map { $0 / Float(channelCount) }
        }

        if let int16ChannelData = buffer.int16ChannelData {
            var downmixed = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let channelData = int16ChannelData[channel]
                for frame in 0..<frameCount {
                    downmixed[frame] += Float(channelData[frame]) / Float(Int16.max)
                }
            }
            return downmixed.map { $0 / Float(channelCount) }
        }

        return []
    }

    func activityState(
        at playbackTime: TimeInterval,
        windowDuration _: TimeInterval
    ) -> (
        level: Float,
        activeSegmentTime: TimeInterval,
        activeSegmentDuration: TimeInterval,
        strokeDirection: ScratchMotionDirection
    ) {
        guard !activityEnvelope.isEmpty,
              !activitySegmentTimes.isEmpty,
              !activitySegmentDurations.isEmpty,
              !activitySegmentDirections.isEmpty,
              activityFrameDuration > 0 else {
            return (0, 0, 0, .neutral)
        }

        let normalizedTime = normalizedPlaybackTime(playbackTime)
        let envelopePosition = normalizedTime / activityFrameDuration
        let lowerIndex = min(
            activityEnvelope.count - 1,
            max(0, Int(floor(envelopePosition)))
        )
        let upperIndex = min(activityEnvelope.count - 1, lowerIndex + 1)
        let interpolation = Float(envelopePosition - floor(envelopePosition))
        let nearestIndex = min(
            activityEnvelope.count - 1,
            max(0, Int(envelopePosition.rounded()))
        )
        let interpolatedLevel = activityEnvelope[lowerIndex]
            + ((activityEnvelope[upperIndex] - activityEnvelope[lowerIndex]) * interpolation)
        let segmentDirection = activitySegmentDirections[nearestIndex]
        let segmentDuration = activitySegmentDurations[nearestIndex]
        let segmentTime: TimeInterval
        if activitySegmentDirections[lowerIndex] == activitySegmentDirections[upperIndex],
           segmentDirection != .neutral {
            let timeInterpolation = TimeInterval(interpolation)
            segmentTime = activitySegmentTimes[lowerIndex]
                + ((activitySegmentTimes[upperIndex] - activitySegmentTimes[lowerIndex]) * timeInterpolation)
        } else {
            segmentTime = activitySegmentTimes[nearestIndex]
        }

        guard interpolatedLevel >= Self.activeEnergyThresholdOff else {
            return (0, segmentTime, segmentDuration, .neutral)
        }
        return (interpolatedLevel, segmentTime, segmentDuration, segmentDirection)
    }

    func coachRigAnimationState(
        scratchType: String,
        playbackTime: TimeInterval,
        isPlaying: Bool,
        windowDuration: TimeInterval = 1.0 / 30.0
    ) -> ScratchCoachDemoAnimationState {
        let normalizedScratchType = Self.normalizedScratchType(scratchType)
        guard isPlaying else {
            if normalizedScratchType == "baby" {
                return .babyScratchOpen
            }
            return .neutral
        }

        let activityState = activityState(
            at: playbackTime,
            windowDuration: windowDuration
        )

        switch normalizedScratchType {
        case "baby":
            let normalizedTime = normalizedPlaybackTime(playbackTime)
            let motionActivityLevel: Float = ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(
                playbackTime: normalizedTime
            )
                ? max(activityState.level, ScratchLabBabyScratchDemoMotionPattern.minimumActiveLevel)
                : activityState.level
            let activeMotionState = ScratchLabBabyScratchDemoMotionPattern.state(
                playbackTime: normalizedTime,
                activityLevel: motionActivityLevel
            )
            if activeMotionState.direction != .neutral {
                let animationState = activeMotionState.animationState
                return animationState == .neutral ? .babyScratchOpen : animationState
            }

            let holdMotionState = ScratchLabBabyScratchDemoMotionPattern.state(
                playbackTime: normalizedTime,
                activityLevel: 1
            )
            if ScratchLabBabyScratchDemoMotionPattern.isHoldWindow(playbackTime: normalizedTime),
               holdMotionState.animationState != .neutral,
               hasRecentBabyScratchActivity(
                at: normalizedTime,
                lookbackDuration: ScratchLabBabyScratchDemoMotionPattern.maximumHoldAfter + 0.06
               ) {
                return holdMotionState.animationState
            }

            return .babyScratchOpen
        default:
            guard activityState.level >= ScratchLabBabyScratchDemoMotionPattern.minimumActiveLevel,
                  activityState.strokeDirection != .neutral else {
                return .neutral
            }
            return ScratchCoachDemoAnimator.state(
                scratchType: scratchType,
                playbackTime: activityState.activeSegmentTime,
                isPlaying: true,
                activityLevel: activityState.level
            )
        }
    }

    private static func normalizedScratchType(_ scratchType: String) -> String {
        let normalizedScratchType = normalizeScratchType(input: scratchType)
        switch normalizedScratchType {
        case "baby", "babyscratch":
            return "baby"
        default:
            return normalizedScratchType
        }
    }

    private func normalizedPlaybackTime(_ playbackTime: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        let remainder = playbackTime.truncatingRemainder(dividingBy: duration)
        return remainder >= 0 ? remainder : remainder + duration
    }

    private func hasRecentBabyScratchActivity(
        at playbackTime: TimeInterval,
        lookbackDuration: TimeInterval
    ) -> Bool {
        guard !activityEnvelope.isEmpty,
              activityFrameDuration > 0,
              lookbackDuration > 0 else {
            return false
        }

        let normalizedTime = normalizedPlaybackTime(playbackTime)
        let currentFrame = min(
            activityEnvelope.count - 1,
            max(0, Int((normalizedTime / activityFrameDuration).rounded()))
        )
        let lookbackFrames = max(1, Int(ceil(lookbackDuration / activityFrameDuration)))

        for offset in 0...lookbackFrames {
            let rawIndex = currentFrame - offset
            let wrappedIndex = ((rawIndex % activityEnvelope.count) + activityEnvelope.count)
                % activityEnvelope.count
            if activityEnvelope[wrappedIndex] >= ScratchLabBabyScratchDemoMotionPattern.minimumActiveLevel {
                return true
            }
        }

        return false
    }

    private static func activityProfile(
        from samples: [Float],
        sampleRate: Double
    ) -> (
        envelope: [Float],
        segmentTimes: [TimeInterval],
        segmentDurations: [TimeInterval],
        segmentDirections: [ScratchMotionDirection],
        frameDuration: TimeInterval
    ) {
        guard !samples.isEmpty,
              sampleRate > 0 else {
            return ([], [], [], [], 0)
        }

        let frameSize = min(samples.count, max(1, Self.activityFrameSize))
        let frameDuration = Double(frameSize) / sampleRate
        var rawEnergy: [Float] = []
        rawEnergy.reserveCapacity((samples.count / frameSize) + 1)

        var sampleIndex = 0
        while sampleIndex < samples.count {
            let endIndex = min(sampleIndex + frameSize, samples.count)
            var meanSquare: Float = 0
            var peak: Float = 0
            for sample in samples[sampleIndex..<endIndex] {
                let absoluteSample = abs(sample)
                meanSquare += sample * sample
                peak = max(peak, absoluteSample)
            }
            meanSquare /= Float(max(1, endIndex - sampleIndex))
            let rms = sqrtf(meanSquare)
            rawEnergy.append((rms * 0.72) + (peak * 0.28))
            sampleIndex = endIndex
        }

        guard !rawEnergy.isEmpty else {
            return ([], [], [], [], frameDuration)
        }

        let sortedEnergy = rawEnergy.sorted()
        let percentileIndex = min(
            sortedEnergy.count - 1,
            max(0, Int(Double(sortedEnergy.count - 1) * 0.94))
        )
        let referenceEnergy = max(0.004, sortedEnergy[percentileIndex])
        let normalizedEnergy = rawEnergy.map { min(1, $0 / referenceEnergy) }

        var isActive = false
        var activeFrames = [Bool](repeating: false, count: normalizedEnergy.count)
        for (energyIndex, energy) in normalizedEnergy.enumerated() {
            if energy > Self.activeEnergyThresholdOn {
                isActive = true
            } else if energy < Self.activeEnergyThresholdOff {
                isActive = false
            }
            activeFrames[energyIndex] = isActive
        }

        var envelope = [Float](repeating: 0, count: normalizedEnergy.count)
        var segmentTimes = [TimeInterval](repeating: 0, count: normalizedEnergy.count)
        var segmentDurations = [TimeInterval](repeating: 0, count: normalizedEnergy.count)
        var segmentDirections = [ScratchMotionDirection](repeating: .neutral, count: normalizedEnergy.count)
        var segmentIndex = 0
        var activityIndex = 0

        while activityIndex < activeFrames.count {
            guard activeFrames[activityIndex] else {
                activityIndex += 1
                continue
            }

            let segmentStart = activityIndex
            while activityIndex < activeFrames.count,
                  activeFrames[activityIndex] {
                activityIndex += 1
            }
            let segmentEnd = activityIndex
            let segmentDuration = Double(segmentEnd - segmentStart) * frameDuration
            let segmentDirection: ScratchMotionDirection = segmentIndex.isMultiple(of: 2) ? .forward : .backward
            var smoothed: Float = 0

            for frameIndex in segmentStart..<segmentEnd {
                let energy = normalizedEnergy[frameIndex]
                if energy > smoothed {
                    smoothed = (smoothed * 0.42) + (energy * 0.58)
                } else {
                    smoothed = (smoothed * 0.86) + (energy * 0.14)
                }
                envelope[frameIndex] = max(Self.activeEnergyThresholdOn, smoothed)
                segmentTimes[frameIndex] = (Double(frameIndex - segmentStart) + 0.5) * frameDuration
                segmentDurations[frameIndex] = segmentDuration
                segmentDirections[frameIndex] = segmentDirection
            }
            segmentIndex += 1
        }

        return (envelope, segmentTimes, segmentDurations, segmentDirections, frameDuration)
    }
}

struct ScratchLabDemoAnalysisFrame: Equatable, Sendable {
    let inputLevel: Float
    let direction: ScratchMotionDirection
    let feedback: ScratchMotionFeedback?
    let animationState: ScratchCoachDemoAnimationState
    let didLoop: Bool
}

final class ScratchLabDemoModeAnalyzer {
    private let sampleBuffer: ScratchLabDemoAudioSampleBuffer
    private var cursorTime: TimeInterval = 0

    init(sampleBuffer: ScratchLabDemoAudioSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }

    var duration: TimeInterval {
        sampleBuffer.duration
    }

    var sampleRate: Double {
        sampleBuffer.sampleRate
    }

    func reset() {
        cursorTime = 0
    }

    func processNextFrame(frameCount requestedFrameCount: Int) -> ScratchLabDemoAnalysisFrame {
        guard !sampleBuffer.samples.isEmpty,
              sampleBuffer.sampleRate > 0 else {
            return ScratchLabDemoAnalysisFrame(
                inputLevel: 0,
                direction: .neutral,
                feedback: nil,
                animationState: .neutral,
                didLoop: false
            )
        }

        let frameDuration = Double(max(1, requestedFrameCount)) / sampleBuffer.sampleRate
        let frame = processFrame(
            playbackTime: cursorTime,
            windowDuration: frameDuration
        )

        var didLoop = false
        cursorTime += frameDuration
        if sampleBuffer.duration > 0,
           cursorTime >= sampleBuffer.duration {
            cursorTime = cursorTime.truncatingRemainder(dividingBy: sampleBuffer.duration)
            didLoop = true
        }

        return ScratchLabDemoAnalysisFrame(
            inputLevel: frame.inputLevel,
            direction: frame.direction,
            feedback: frame.feedback,
            animationState: frame.animationState,
            didLoop: didLoop
        )
    }

    func processFrame(
        playbackTime: TimeInterval,
        windowDuration: TimeInterval
    ) -> ScratchLabDemoAnalysisFrame {
        guard !sampleBuffer.samples.isEmpty,
              sampleBuffer.sampleRate > 0 else {
            return ScratchLabDemoAnalysisFrame(
                inputLevel: 0,
                direction: .neutral,
                feedback: nil,
                animationState: .neutral,
                didLoop: false
            )
        }

        let activityState = sampleBuffer.activityState(
            at: playbackTime,
            windowDuration: windowDuration
        )
        let motionState = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: playbackTime,
            activityLevel: activityState.level
        )
        return ScratchLabDemoAnalysisFrame(
            inputLevel: motionState.inputLevel,
            direction: motionState.direction,
            feedback: motionState.feedback,
            animationState: motionState.animationState,
            didLoop: false
        )
    }
}

// MARK: - Baby Scratch demo playback coordinator

@MainActor
final class BabyScratchDemoPlaybackCoordinator: ObservableObject {

    let audioPlayer: ScratchCoachDemoAudioPlayer

    @Published private(set) var playbackState: DemoPlaybackState = .stopped
    @Published private(set) var isConfiguredForBabyScratch = false
    @Published private(set) var lastErrorMessage: String?

    init() {
        self.audioPlayer = ScratchCoachDemoAudioPlayer()
    }

    init(audioPlayer: ScratchCoachDemoAudioPlayer) {
        self.audioPlayer = audioPlayer
    }

    var currentAudioTime: TimeInterval { audioPlayer.currentPlaybackTime }
    var isAudioAvailable: Bool { audioPlayer.isAudioAvailable }
    var isPlaying: Bool { playbackState == .playing && audioPlayer.isActivelyPlayingAudio }
    var isPaused: Bool { playbackState == .paused }
    var isStopped: Bool { playbackState == .stopped }

    func configureBabyScratchIfNeeded() {
        guard !isConfiguredForBabyScratch || !audioPlayer.isAudioAvailable else { return }

        audioPlayer.configure(with: Self.babyScratchInstruction())
        isConfiguredForBabyScratch = audioPlayer.isAudioAvailable
        lastErrorMessage = isConfiguredForBabyScratch
            ? nil
            : "Baby Scratch demo audio is unavailable."
    }

    func playBabyScratch() {
        configureBabyScratchIfNeeded()
        guard audioPlayer.isAudioAvailable else {
            audioPlayer.stop()
            playbackState = .stopped
            lastErrorMessage = "Baby Scratch demo audio is unavailable."
            return
        }

        audioPlayer.play()
        if audioPlayer.playbackState == .playing && audioPlayer.isActivelyPlayingAudio {
            playbackState = .playing
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Baby Scratch demo audio could not start."
            audioPlayer.stop()
            playbackState = .stopped
        }
    }

    func pause() {
        guard audioPlayer.isAudioAvailable else {
            playbackState = .stopped
            return
        }
        audioPlayer.pause()
        playbackState = .paused
    }

    func stop() {
        audioPlayer.stop()
        playbackState = .stopped
    }

    func replayBabyScratch() {
        configureBabyScratchIfNeeded()
        guard audioPlayer.isAudioAvailable else {
            audioPlayer.stop()
            playbackState = .stopped
            lastErrorMessage = "Baby Scratch demo audio is unavailable."
            return
        }

        audioPlayer.replay()
        if audioPlayer.playbackState == .playing && audioPlayer.isActivelyPlayingAudio {
            playbackState = .playing
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Baby Scratch demo audio could not start."
            audioPlayer.stop()
            playbackState = .stopped
        }
    }

    nonisolated static var audioDuration: TimeInterval { BabyScratchReferenceMotionTimeline.sourceDuration }
    nonisolated static var phraseDuration: TimeInterval { BabyScratchReferenceMotionTimeline.phraseEnd }
    nonisolated static var phraseCycleDuration: TimeInterval { BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration }

    nonisolated static func notationPhraseTime(for audioTime: TimeInterval) -> TimeInterval {
        let cycleDur = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration
        let phraseEnd = BabyScratchReferenceMotionTimeline.phraseEnd
        guard cycleDur > 0 else { return min(phraseEnd, max(0, audioTime)) }
        let cycleIndex = Int(audioTime / cycleDur)
        let cycleLocalTime = audioTime - Double(cycleIndex) * cycleDur
        return min(phraseEnd, max(0, cycleLocalTime))
    }

    nonisolated static func coachPose(for audioTime: TimeInterval) -> BabyScratchReferenceMotionPose {
        ScratchLabPerformanceSignpost.event("CoachPoseLookup", time: audioTime)
        return BabyScratchReferenceMotionTimeline.pose(at: audioTime)
    }

    nonisolated static func coachAnimationState(
        for audioTime: TimeInterval,
        isPlaying: Bool
    ) -> ScratchCoachDemoAnimationState {
        guard isPlaying else { return .babyScratchOpen }
        return coachAnimationState(for: coachPose(for: audioTime))
    }

    nonisolated static func coachAnimationState(
        for pose: BabyScratchReferenceMotionPose
    ) -> ScratchCoachDemoAnimationState {
        ScratchCoachDemoAnimationState(
            recordPosition: pose.scratchProgress,
            recordRotationDegrees: pose.recordRotationDegrees,
            crossfaderPosition: ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition,
            crossfaderOpenState: true
        )
    }

    func coachAnimationState(isPlaying: Bool) -> ScratchCoachDemoAnimationState {
        Self.coachAnimationState(
            for: currentAudioTime,
            isPlaying: isPlaying && self.isPlaying
        )
    }

    private static func babyScratchInstruction() -> ScratchCoachInstruction {
        let bundledInstruction = ScratchCoachInstructionStore.shared.instruction(
            for: CaptureSessionScratchType.babyScratch.rawValue,
            scratchDisplayName: CaptureSessionScratchType.babyScratch.title
        )
        guard bundledInstruction.hasDemoAudioReference else {
            return fallbackBabyScratchInstruction
        }
        return bundledInstruction
    }

    private static var fallbackBabyScratchInstruction: ScratchCoachInstruction {
        ScratchCoachInstruction(
            scratchType: CaptureSessionScratchType.babyScratch.rawValue,
            scratchDisplayName: CaptureSessionScratchType.babyScratch.title,
            instructionSummary: "Baby Scratch demo",
            coachScript: "Play the bundled Baby Scratch demo audio.",
            steps: [],
            commonMistake: "",
            practiceChallenge: "",
            difficulty: "beginner",
            demoAudioFile: ScratchLabDemoSessionBuilder.demoAudioFileName,
            demoAudioRole: "noBeat"
        )
    }
}

@MainActor
final class ScratchLabDemoModeController: ObservableObject {
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var motionDirection: ScratchMotionDirection = .neutral
    @Published private(set) var motionFeedback: ScratchMotionFeedback?
    @Published private(set) var statusMessage = "Loading bundled baby scratch demo."
    @Published private(set) var isReady = false

    let instruction: ScratchCoachInstruction
    let demoPlayer: ScratchCoachDemoAudioPlayer

    private let audioFileName: String
    private let audioURLProvider: ScratchCoachDemoAudioPlayer.ResourceURLProvider
    private var analyzer: ScratchLabDemoModeAnalyzer?
    private(set) var analysisTimer: Timer?

    init(
        audioFileName: String = ScratchLabDemoSessionBuilder.demoAudioFileName,
        audioURLProvider: @escaping ScratchCoachDemoAudioPlayer.ResourceURLProvider = { audioName in
            ScratchCoachDemoAudioPlayer.bundledDemoAudioURL(named: audioName, in: .main)
        },
        demoPlayer: ScratchCoachDemoAudioPlayer? = nil
    ) {
        self.audioFileName = audioFileName
        self.audioURLProvider = audioURLProvider
        self.demoPlayer = demoPlayer ?? ScratchCoachDemoAudioPlayer()
        self.instruction = ScratchCoachInstructionStore.shared.instruction(
            for: CaptureSessionScratchType.babyScratch.rawValue,
            scratchDisplayName: CaptureSessionScratchType.babyScratch.title
        )
    }

    deinit {
        analysisTimer?.invalidate()
    }

    func startDemo() {
        stopDemo()
        guard let resolved = resolveDemoAudio() else { return }
        do {
            analyzer = ScratchLabDemoModeAnalyzer(
                sampleBuffer: try ScratchLabDemoAudioSampleBuffer(audioURL: resolved.url)
            )
            demoPlayer.configure(url: resolved.url, sourceFileName: resolved.sourceFileName, isFallback: resolved.isFallback)
            demoPlayer.replay()
            let startedPlaying = confirmPlaybackStarted(
                successStatusMessage: resolved.isFallback
                    ? "Playing the bundled call-response practice reel — the exact demo track isn't in this build."
                    : "Bundled baby scratch demo is playing with synced coach feedback.",
                failureStatusMessage: "ScratchLab could not start the bundled demo audio."
            )
            guard startedPlaying else { return }
            startAnalysisTimer()
        } catch {
            statusMessage = "ScratchLab could not load the bundled demo."
            isReady = false
        }
    }

    /// Confirms `demoPlayer.play()`/`.replay()` actually produced live audio
    /// before this controller claims success. `AVAudioPlayer.play()` can
    /// return true synchronously yet not sustain playback, so both
    /// `playbackState` and `isActivelyPlayingAudio` are required — matching
    /// `BabyScratchDemoPlaybackCoordinator`'s existing honest-reporting
    /// pattern. Shared by every play/replay/resume path so failure is
    /// reported identically instead of drifting between call sites.
    @discardableResult
    private func confirmPlaybackStarted(successStatusMessage: String, failureStatusMessage: String) -> Bool {
        guard demoPlayer.playbackState == .playing, demoPlayer.isActivelyPlayingAudio else {
            demoPlayer.stop()
            analysisTimer?.invalidate()
            analysisTimer = nil
            statusMessage = failureStatusMessage
            isReady = false
            return false
        }
        statusMessage = successStatusMessage
        isReady = true
        return true
    }

    /// Resolves `audioFileName` through `DemoAudioResolver` — exact match
    /// preferred; falls back to the bundled Baby Scratch call-response reel
    /// only when `audioFileName` actually is the Baby Scratch dry demo (no
    /// other lesson borrows this fallback). On `.unavailable`, sets
    /// `statusMessage`/`isReady` and returns `nil` so callers can bail out
    /// with one `guard`.
    private func resolveDemoAudio() -> (url: URL, sourceFileName: String, isFallback: Bool)? {
        let resolution = DemoAudioResolver.resolve(
            requestedFileName: audioFileName,
            allowsFallback: audioFileName == ScratchLabDemoSessionBuilder.demoAudioFileName,
            lookup: audioURLProvider
        )
        switch resolution {
        case .exact(let url):
            return (url, audioFileName, false)
        case .fallback(let url, let actualFileName):
            return (url, actualFileName, true)
        case .unavailable:
            statusMessage = "Bundled demo audio is unavailable."
            isReady = false
            return nil
        }
    }

    func stopDemo() {
        analysisTimer?.invalidate()
        analysisTimer = nil
        demoPlayer.stop()
        analyzer?.reset()
        inputLevel = 0
        motionDirection = .neutral
        motionFeedback = nil
        isReady = false
    }

    private func demoDidFinishNaturally() {
        analysisTimer?.invalidate()
        analysisTimer = nil
        demoPlayer.stop()
        analyzer?.reset()
        inputLevel = 0
        motionDirection = .neutral
        motionFeedback = nil
        statusMessage = "Demo finished. Tap Restart to play again."
        // isReady intentionally preserved so Restart remains enabled.
    }

    func replayDemo() {
        analyzer?.reset()
        motionFeedback = nil
        motionDirection = .neutral
        inputLevel = 0
        demoPlayer.replay()
        guard confirmPlaybackStarted(
            successStatusMessage: "Bundled baby scratch demo is playing with synced coach feedback.",
            failureStatusMessage: "ScratchLab could not restart the bundled demo audio."
        ) else { return }
        if analysisTimer == nil {
            startAnalysisTimer()
        }
    }

    func pauseDemo() {
        demoPlayer.pause()
        analysisTimer?.invalidate()
        analysisTimer = nil
        statusMessage = "Demo paused."
    }

    func resumeDemo() {
        guard demoPlayer.playbackState == .paused else { return }
        demoPlayer.play()
        guard confirmPlaybackStarted(
            successStatusMessage: "Demo resumed.",
            failureStatusMessage: "ScratchLab could not resume the bundled demo audio."
        ) else { return }
        if analysisTimer == nil {
            startAnalysisTimer()
        }
    }

    /// Loads audio and analyzer without starting playback.
    /// Used by Demo with Beat so the scratch audio can be scheduled
    /// to start aligned with the beat engine's reported start time.
    func prepareDemoForBeatAlignment() {
        stopDemo()
        guard let resolved = resolveDemoAudio() else { return }
        do {
            analyzer = ScratchLabDemoModeAnalyzer(
                sampleBuffer: try ScratchLabDemoAudioSampleBuffer(audioURL: resolved.url)
            )
            demoPlayer.configure(url: resolved.url, sourceFileName: resolved.sourceFileName, isFallback: resolved.isFallback)
            isReady = true
            statusMessage = resolved.isFallback
                ? "Demo ready (call-response practice reel) — waiting for beat."
                : "Demo ready — waiting for beat."
        } catch {
            statusMessage = "ScratchLab could not load the bundled demo."
            isReady = false
        }
    }

    /// Starts audio playback after the beat-alignment delay fires.
    /// Must be called after `prepareDemoForBeatAlignment()`.
    func startAlignedPlayback() {
        guard isReady else { return }
        demoPlayer.replay()
        guard confirmPlaybackStarted(
            successStatusMessage: "Demo playing with beat.",
            failureStatusMessage: "ScratchLab could not start the bundled demo audio."
        ) else { return }
        startAnalysisTimer()
    }

    func coachAnimationState(
        playbackTime: TimeInterval,
        isPlaying: Bool
    ) -> ScratchCoachDemoAnimationState {
        guard isPlaying,
              let analyzer else {
            return .neutral
        }

        return analyzer.processFrame(
            playbackTime: playbackTime,
            windowDuration: 1.0 / 30.0
        ).animationState
    }

    private func startAnalysisTimer() {
        analysisTimer?.invalidate()
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processNextAnalysisFrame()
            }
        }
    }

    private func processNextAnalysisFrame() {
        guard let analyzer else { return }
        guard demoPlayer.playbackState == .playing else {
            return
        }

        if !demoPlayer.isActivelyPlayingAudio {
            demoDidFinishNaturally()
            return
        }

        let frame = analyzer.processFrame(
            playbackTime: demoPlayer.currentPlaybackTime,
            windowDuration: 1.0 / 30.0
        )
        inputLevel = (inputLevel * 0.64) + (frame.inputLevel * 0.36)
        motionDirection = frame.direction
        if let feedback = frame.feedback {
            motionFeedback = feedback
        }
    }
}

struct ScratchLabDemoSessionBuilder: Sendable {
    static let demoAudioFileName = "baby_noBeat.wav"
    private static let demoSessionName = "ScratchLab Demo"
    private static let demoPerformerName = "App Review Demo"
    static let demoBPM = 79
    private static let videoFrameRate: Int32 = 10
    private static let videoSize = CGSize(width: 160, height: 90)

    typealias AudioURLProvider = @Sendable (String) -> URL?

    private let audioURLProvider: AudioURLProvider

    init(
        audioURLProvider: @escaping AudioURLProvider = { audioName in
            ScratchCoachDemoAudioPlayer.bundledDemoAudioURL(named: audioName, in: .main)
        }
    ) {
        self.audioURLProvider = audioURLProvider
    }

    func makePackage(
        rootDirectory: URL? = nil,
        sessionID: String = CaptureCore.LocalRecordingNaming.sessionID(),
        now: Date = Date()
    ) throws -> SessionExportPackage {
        let fileManager = FileManager.default
        guard let bundledAudioURL = audioURLProvider(Self.demoAudioFileName) else {
            throw SessionExportError.missingRequiredFiles
        }

        let demoRoot = try makeDemoRootDirectory(
            rootDirectory: rootDirectory,
            sessionID: sessionID,
            fileManager: fileManager
        )
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let files = try CaptureCore.LocalRecordingFiles.make(
            in: demoRoot,
            sessionID: sessionID,
            takeNumber: takeIdentity.takeNumber,
            roleLabel: "demo",
            mediaExtension: "mov",
            fileManager: fileManager
        )
        let audioURL = files.mediaURL.deletingPathExtension().appendingPathExtension("wav")
        try fileManager.copyItem(at: bundledAudioURL, to: audioURL)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0
            ? max(1, Double(audioFile.length) / sampleRate)
            : 1
        try Self.writeDemoVideo(at: files.mediaURL, duration: duration)

        let endedAt = now.addingTimeInterval(duration)
        var config = CaptureSessionConfig(
            performerName: Self.demoPerformerName,
            bpm: Self.demoBPM,
            scratchType: .babyScratch,
            drillMode: .referenceOnly,
            captureMode: .calibrationNoClick,
            beatEngineMode: .silent,
            timingPrintedToRecording: .notPrinted,
            takeDurationSeconds: duration,
            takeCount: 1,
            handedness: .right,
            notes: "Bundled demo session.",
            sessionID: sessionID,
            createdAt: now,
            updatedAt: endedAt
        )
        config.applyCapturedTakeMetrics(
            takeCount: 1,
            totalDurationSeconds: duration,
            updatedAt: endedAt
        )

        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: config,
            takeIdentity: takeIdentity,
            files: files,
            recordingRole: "demo_mode",
            platform: Self.platformLabel,
            appSurface: "ScratchLab Demo Mode",
            sourceDeviceName: "Bundled Demo",
            cameraPosition: nil,
            audioInputName: "Bundled baby scratch audio",
            videoDeviceUniqueID: nil,
            videoDeviceName: "Generated demo deck view",
            audioDeviceUniqueID: nil,
            audioDeviceName: "Bundled baby scratch audio",
            captureTiming: nil,
            startedAt: now
        ).finalized(
            endedAt: endedAt,
            mediaFileName: files.mediaURL.lastPathComponent,
            captureErrorDescription: nil
        )
        try sidecar.encodedData().write(to: files.sidecarURL, options: .atomic)

        let metadata = SessionExportMetadata(
            config: config,
            workflow: "demo_mode",
            platform: Self.platformLabel,
            sessionName: Self.demoSessionName,
            totalDurationSeconds: duration,
            deviceInfo: SessionExportDeviceInfo(
                sourceDeviceName: sidecar.sourceDeviceName,
                appSurface: sidecar.appSurface,
                cameraPosition: sidecar.cameraPosition,
                audioInputName: sidecar.audioInputName,
                videoDeviceUniqueID: sidecar.videoDeviceUniqueID,
                videoDeviceName: sidecar.videoDeviceName,
                audioDeviceUniqueID: sidecar.audioDeviceUniqueID,
                audioDeviceName: sidecar.audioDeviceName
            )
        )
        let take = SessionExportTake(
            takeID: takeIdentity.takeID,
            takeNumber: takeIdentity.takeNumber,
            bpm: Self.demoBPM,
            mediaURL: files.mediaURL,
            audioArtifactURL: audioURL,
            sidecarURL: files.sidecarURL,
            watchCaptureSession: nil,
            drillName: "Try Demo",
            duration: duration,
            quality: CaptureQuality.clean.rawValue,
            comboTagged: false,
            audioPresent: true,
            motionPresent: false,
            syncStatus: CaptureWatchSyncState.notRequested.rawValue,
            recordingStatus: "completed",
            verbalSlateUsed: false,
            syncClapUsed: false,
            note: "Bundled baby scratch demo.",
            captureTiming: nil
        )

        return SessionExportPackage(
            metadata: metadata,
            takes: [take],
            calibrationData: nil
        )
    }

    private func makeDemoRootDirectory(
        rootDirectory: URL?,
        sessionID: String,
        fileManager: FileManager
    ) throws -> URL {
        let baseDirectory = rootDirectory
            ?? (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
                .appendingPathComponent("ScratchLabDemoSessions", isDirectory: true)
        let demoRoot = baseDirectory.appendingPathComponent(sessionID, isDirectory: true)
        if fileManager.fileExists(atPath: demoRoot.path) {
            try fileManager.removeItem(at: demoRoot)
        }
        try fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        return demoRoot
    }

    private static var platformLabel: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "Apple"
        #endif
    }

    private static func writeDemoVideo(at url: URL, duration: TimeInterval) throws {
        try? FileManager.default.removeItem(at: url)

        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw SessionExportError.unableToPrepareExport
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(ceil(duration * Double(videoFrameRate))))
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: videoFrameRate)
            let pixelBuffer = try makeDemoPixelBuffer(
                width: width,
                height: height,
                frameIndex: frameIndex,
                frameCount: frameCount
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? SessionExportError.unableToPrepareExport
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
    }

    private static func makeDemoPixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int,
        frameCount: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard let pixelBuffer else {
            throw SessionExportError.unableToPrepareExport
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SessionExportError.unableToPrepareExport
        }
        let pixels = baseAddress.assumingMemoryBound(to: UInt32.self)
        let pixelsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        let progress = Double(frameIndex) / Double(max(1, frameCount - 1))
        let playheadX = Int(progress * Double(max(1, width - 1)))
        let background = bgra(red: 8, green: 12, blue: 18)
        let gridLine = bgra(red: 24, green: 32, blue: 44)
        let accent = bgra(red: 250, green: 204, blue: 21)
        let secondary = bgra(red: 34, green: 197, blue: 94)

        for y in 0..<height {
            let row = pixels.advanced(by: y * pixelsPerRow)
            for x in 0..<width {
                let isGrid = x % 20 == 0 || y % 18 == 0
                let wave = 0.5 + (sin((Double(x) * 0.14) + (Double(frameIndex) * 0.22)) * 0.5)
                let waveHeight = Int(wave * Double(height / 3))
                let centerY = height / 2
                let isWave = abs(y - centerY) <= max(1, waveHeight / 8)
                let isPlayhead = abs(x - playheadX) <= 1
                row[x] = isPlayhead ? accent : (isWave ? secondary : (isGrid ? gridLine : background))
            }
        }

        return pixelBuffer
    }

    private static func bgra(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> UInt32 {
        UInt32(blue) | (UInt32(green) << 8) | (UInt32(red) << 16) | (UInt32(alpha) << 24)
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
            #if DEBUG
            print("NEW_SESSION_CREATED:", draft.id)
            #endif
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

    struct CaptureReviewDecision: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case accepted
            case corrected
            case unknown
        }

        let status: Status
        let label: String
        let detectedLabel: String?
        let confidence: Double?
        let reviewedAt: Date
    }

    enum SessionReviewState: String, Codable, Sendable, CaseIterable {
        case unreviewed
        case approved
        case rejected
        case lowSignal = "low_signal"
        case timingDrift = "timing_drift"
        case mislabeled
        case needsManualReview = "needs_manual_review"
    }

    struct SessionReviewQualityFlags: Codable, Equatable, Sendable {
        let signalQualityFlagged: Bool
        let timingStabilityFlagged: Bool
        let noiseFloorFlagged: Bool
        let directionReliabilityFlagged: Bool

        init(
            signalQualityFlagged: Bool = false,
            timingStabilityFlagged: Bool = false,
            noiseFloorFlagged: Bool = false,
            directionReliabilityFlagged: Bool = false
        ) {
            self.signalQualityFlagged = signalQualityFlagged
            self.timingStabilityFlagged = timingStabilityFlagged
            self.noiseFloorFlagged = noiseFloorFlagged
            self.directionReliabilityFlagged = directionReliabilityFlagged
        }

        static let none = SessionReviewQualityFlags()
    }

    struct SessionReviewWarning: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable {
            case clippedAudio = "clipped_audio"
            case lowAmplitude = "low_amplitude"
            case unstableOnsetSpacing = "unstable_onset_spacing"
            case missingPhraseRegion = "missing_phrase_region"
            case inconsistentDirection = "inconsistent_direction"
        }

        let id: UUID
        let kind: Kind
        let detail: String
        let raisedAt: Date

        init(
            id: UUID = UUID(),
            kind: Kind,
            detail: String,
            raisedAt: Date = Date()
        ) {
            self.id = id
            self.kind = kind
            self.detail = detail
            self.raisedAt = raisedAt
        }
    }

    struct CaptureReviewMetadata: Codable, Equatable, Sendable {
        static let currentSchemaVersion = "scratchlab_review_metadata_v1"

        let schemaVersion: String
        let reviewState: SessionReviewState
        let reviewedAt: Date?
        let reviewedBy: String?
        let reviewNotes: String?
        let qualityFlags: SessionReviewQualityFlags
        let labelOverride: String?
        let isTrainingQuality: Bool
        let warnings: [SessionReviewWarning]

        init(
            schemaVersion: String = CaptureReviewMetadata.currentSchemaVersion,
            reviewState: SessionReviewState = .unreviewed,
            reviewedAt: Date? = nil,
            reviewedBy: String? = nil,
            reviewNotes: String? = nil,
            qualityFlags: SessionReviewQualityFlags = .none,
            labelOverride: String? = nil,
            isTrainingQuality: Bool = false,
            warnings: [SessionReviewWarning] = []
        ) {
            self.schemaVersion = schemaVersion
            self.reviewState = reviewState
            self.reviewedAt = reviewedAt
            self.reviewedBy = reviewedBy
            self.reviewNotes = reviewNotes
            self.qualityFlags = qualityFlags
            self.labelOverride = labelOverride
            self.isTrainingQuality = isTrainingQuality
            self.warnings = warnings
        }

        static let unreviewed = CaptureReviewMetadata()
    }

    struct DetectedNotationRecordMovementEvent: Codable, Equatable, Sendable {
        let startTime: Double
        let endTime: Double
        let startPosition: Double
        let endPosition: Double
        let direction: String
        let movementKind: ScratchMovementKind
        let speed: Double
        let confidence: Double
        let source: String
    }

    /// Controller notation is gesture-relative, while persisted movement
    /// evidence keeps its existing finalized/export coordinate. `live_preview`
    /// is produced only from the controller decoder's open run and follows the
    /// same presentation rule.
    static func usesGestureRelativeControllerNotation(
        _ event: DetectedNotationRecordMovementEvent
    ) -> Bool {
        event.source == "controller" || event.source == "live_preview"
    }

    /// Presentation-only projection for one decoder-committed controller run.
    ///
    /// The existing run/reversal boundaries and noise gates have already made
    /// the gesture decision before this method is called. No event is added,
    /// removed, merged, or re-timed here; only its lane coordinates are locally
    /// rebased from the explicit raw step displacement supplied by the shared
    /// decoder. Finalized sidecars/export continue to own the unprojected event
    /// returned by `derivePlatterMovementEvents`.
    static func gestureRelativeControllerNotationEvent(
        _ event: DetectedNotationRecordMovementEvent,
        signedDisplacementSteps: Double,
        stepsPerRevolution: Double = PlatterCoordinateSemantics
            .raneOneMKIIDirectMIDIStepsPerRevolution
    ) -> DetectedNotationRecordMovementEvent {
        guard usesGestureRelativeControllerNotation(event) else { return event }
        let coordinates = PlatterCoordinateSemantics.gestureRelativeNotation(
            signedDisplacementSteps: signedDisplacementSteps,
            stepsPerRevolution: stepsPerRevolution
        )
        return DetectedNotationRecordMovementEvent(
            startTime: event.startTime,
            endTime: event.endTime,
            startPosition: coordinates.startPosition,
            endPosition: coordinates.endPosition,
            direction: event.direction,
            movementKind: event.movementKind,
            speed: event.speed,
            confidence: event.confidence,
            source: event.source
        )
    }

    /// The decoder boundary is the only place where `speed × duration` is raw
    /// step displacement. Keeping that conversion private prevents a fused or
    /// persisted controller event's normalized `speed` from entering the
    /// physical notation projection.
    private static func gestureRelativeNotationEventFromDecodedRun(
        _ event: DetectedNotationRecordMovementEvent,
        stepsPerRevolution: Double
    ) -> DetectedNotationRecordMovementEvent? {
        let duration = event.endTime - event.startTime
        guard duration.isFinite, duration > 0, event.speed.isFinite else {
            return nil
        }
        let magnitude = abs(event.speed) * duration
        let signedDisplacement: Double
        switch event.direction {
        case "forward": signedDisplacement = magnitude
        case "backward": signedDisplacement = -magnitude
        default: return nil
        }
        return gestureRelativeControllerNotationEvent(
            event,
            signedDisplacementSteps: signedDisplacement,
            stepsPerRevolution: stepsPerRevolution
        )
    }

    /// Event-only presentation fallback for controller evidence whose raw CC6
    /// stream is unavailable (for example, an older sidecar). It preserves the
    /// stored endpoint excursion exactly and only moves that span onto the
    /// local gesture baseline. It intentionally never reads `speed`: macOS
    /// finalization normalizes that field, so treating it as raw steps would
    /// divide saved excursions by the platter scale a second time.
    static func locallyRebasedControllerNotationEvent(
        _ event: DetectedNotationRecordMovementEvent
    ) -> DetectedNotationRecordMovementEvent {
        guard usesGestureRelativeControllerNotation(event) else { return event }
        let excursion = abs(event.endPosition - event.startPosition)
        let signedExcursion: Double
        switch event.direction {
        case "forward": signedExcursion = excursion
        case "backward": signedExcursion = -excursion
        default: return event
        }
        let coordinates = PlatterCoordinateSemantics.gestureRelativeNotation(
            signedDisplacementSteps: signedExcursion,
            stepsPerRevolution: 1
        )
        return DetectedNotationRecordMovementEvent(
            startTime: event.startTime,
            endTime: event.endTime,
            startPosition: coordinates.startPosition,
            endPosition: coordinates.endPosition,
            direction: event.direction,
            movementKind: event.movementKind,
            speed: event.speed,
            confidence: event.confidence,
            source: event.source
        )
    }

    struct DetectedNotationAudioEvent: Codable, Equatable, Sendable {
        let startTime: Double
        let endTime: Double
        let duration: Double
        let peakLevel: Double
        let rmsLevel: Double
        let confidence: Double
        let eventKind: String
        let source: String
    }

    struct RawMixerMIDIEvent: Codable, Equatable, Sendable {
        let timestamp: Double
        let takeRelativeTime: Double
        let deviceName: String
        let channel: Int
        let controller: Int
        let value: Int
        let normalizedValue: Double
        let mappedControl: String?
        /// How this control was recognised — the user's learned mapping, or a
        /// certified registry binding. Optional and additive: sidecars written
        /// before provenance existed decode with `nil`, which means "unknown
        /// provenance", never "learned".
        let mappingSource: FaderMappingSource?

        init(
            timestamp: Double,
            takeRelativeTime: Double,
            deviceName: String,
            channel: Int,
            controller: Int,
            value: Int,
            normalizedValue: Double,
            mappedControl: String?,
            mappingSource: FaderMappingSource? = nil
        ) {
            self.timestamp = timestamp
            self.takeRelativeTime = takeRelativeTime
            self.deviceName = deviceName
            self.channel = channel
            self.controller = controller
            self.value = value
            self.normalizedValue = normalizedValue
            self.mappedControl = mappedControl
            self.mappingSource = mappingSource
        }
    }

    struct DetectedNotationFaderEvent: Codable, Equatable, Sendable {
        let startTime: Double
        let endTime: Double
        let eventKind: ScratchFaderEventKind
        let control: String
        let fromValue: Double
        let toValue: Double
        let source: String
        let confidence: Double
    }

    struct DetectedNotationSnapshot: Codable, Equatable, Sendable {
        let notationSource: String
        let notationConfidence: Double?
        let detectedLabel: String?
        let labelSource: String
        let labelConfidence: Double?
        let detectionSources: [String]
        let recordMovementEvents: [DetectedNotationRecordMovementEvent]
        let audioEvents: [DetectedNotationAudioEvent]
        let faderEvents: [DetectedNotationFaderEvent]
        let mixerMidiEvents: [RawMixerMIDIEvent]
        let capturedAt: Date

        var hasDetectedEvents: Bool {
            !recordMovementEvents.isEmpty || !audioEvents.isEmpty || !faderEvents.isEmpty
        }

        var hasDetectedMovementEvents: Bool {
            !recordMovementEvents.isEmpty
        }

        var hasAudioEvents: Bool {
            !audioEvents.isEmpty
        }

        /// Latest end-time across the lanes the captured-evidence chart
        /// actually renders as time intervals (movement / audio / fader).
        /// `nil` when none of those lanes have events. Mixer MIDI is
        /// represented here via the derived `faderEvents`; raw
        /// `RawMixerMIDIEvent` exposes only point-in-time samples and is
        /// not a duration source. Single source of truth for the captured
        /// chart, the Review target-chart viewport, and the D1 captured-
        /// chart diagnostic so the three cannot disagree about where the
        /// take ends. Computed only — no Codable / export-schema impact.
        var capturedEvidenceEndTime: Double? {
            let candidates = [
                recordMovementEvents.map(\.endTime).max(),
                audioEvents.map(\.endTime).max(),
                faderEvents.map(\.endTime).max()
            ].compactMap { $0 }
            return candidates.max()
        }

        var effectiveDetectedLabel: String? {
            guard hasDetectedEvents else { return nil }
            let trimmed = detectedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        var effectiveLabelConfidence: Double? {
            guard effectiveDetectedLabel != nil else { return nil }
            return labelConfidence
        }

        func withMixerMidiEvents(
            _ events: [RawMixerMIDIEvent],
            faderEvents explicitFaderEvents: [DetectedNotationFaderEvent]? = nil
        ) -> DetectedNotationSnapshot {
            let derivedFaderEvents = explicitFaderEvents ?? CaptureCore.deriveDetectedNotationFaderEvents(from: events)
            var updatedDetectionSources = detectionSources.filter { $0 != "midi" }
            if !derivedFaderEvents.isEmpty {
                updatedDetectionSources.append("midi")
            }
            return DetectedNotationSnapshot(
                notationSource: notationSource,
                notationConfidence: notationConfidence,
                detectedLabel: detectedLabel,
                labelSource: labelSource,
                labelConfidence: labelConfidence,
                detectionSources: updatedDetectionSources,
                recordMovementEvents: recordMovementEvents,
                audioEvents: audioEvents,
                faderEvents: derivedFaderEvents,
                mixerMidiEvents: events,
                capturedAt: capturedAt
            )
        }

        /// Corrects `detectionSources` provenance to say `"timecode_live"`
        /// instead of `"video"` when `recordMovementEvents` actually came
        /// from a trusted DVS timeline rather than camera hand-tracking.
        ///
        /// `RoutineNotationFusionEngine.snapshot(...)` always labels
        /// non-empty movement events `"video"`, since historically camera
        /// tracking was their only possible source. Rather than teach that
        /// already-shipping fusion logic about a second source, this is
        /// called immediately afterward — a pure post-processing step,
        /// mirroring `withMixerMidiEvents`'s "return a corrected copy"
        /// shape — only on takes where
        /// `TimecodeNotationCapturePrecedence.resolvedMovementEvents`
        /// actually selected the DVS-authoritative path. A no-op when
        /// `recordMovementEvents` is empty.
        func withTimecodeLiveMovementProvenance() -> DetectedNotationSnapshot {
            guard !recordMovementEvents.isEmpty else { return self }
            var updatedDetectionSources = detectionSources.filter { $0 != "video" }
            updatedDetectionSources.append("timecode_live")
            // RoutineNotationFusionEngine rebuilds every motion event it
            // emits with a hardcoded source ("video" for unmatched events,
            // "fused" when paired with a burst audio event) regardless of
            // what source the input event actually carried — a
            // pre-existing assumption from when camera was the only
            // possible motion source. This method's only call site
            // (MacCaptureEngine.finalizeRoutineRecording) invokes it
            // exactly when notation routing is enabled AND a trusted DVS
            // timeline was drained, which — per
            // TimecodeNotationCapturePrecedence — guarantees every event
            // in recordMovementEvents originated from DVS, never camera.
            // So it's correct to retag all of them here, not just the
            // top-level detectionSources label.
            let correctedEvents = recordMovementEvents.map { event in
                DetectedNotationRecordMovementEvent(
                    startTime: event.startTime,
                    endTime: event.endTime,
                    startPosition: event.startPosition,
                    endPosition: event.endPosition,
                    direction: event.direction,
                    movementKind: event.movementKind,
                    speed: event.speed,
                    confidence: event.confidence,
                    source: "timecode_live"
                )
            }
            return DetectedNotationSnapshot(
                notationSource: notationSource,
                notationConfidence: notationConfidence,
                detectedLabel: detectedLabel,
                labelSource: labelSource,
                labelConfidence: labelConfidence,
                detectionSources: updatedDetectionSources,
                recordMovementEvents: correctedEvents,
                audioEvents: audioEvents,
                faderEvents: faderEvents,
                mixerMidiEvents: mixerMidiEvents,
                capturedAt: capturedAt
            )
        }
    }

    static func deriveDetectedNotationFaderEvents(
        from mixerMidiEvents: [RawMixerMIDIEvent]
    ) -> [DetectedNotationFaderEvent] {
        struct PrimitiveEvent {
            let startTime: Double
            let endTime: Double
            let fromValue: Double
            let toValue: Double
            let confidence: Double
            let isCutCandidate: Bool

            var signedDelta: Double { toValue - fromValue }
        }

        let minimumValueDelta = 0.10
        let minimumCutDelta = 0.35
        let maximumCutDuration = 0.15
        let maximumPulseGap = 0.20
        let minimumConfidence = 0.75

        let crossfaderEvents = mixerMidiEvents
            .filter { $0.mappedControl == "crossfader" }
            .sorted { lhs, rhs in
                if lhs.takeRelativeTime == rhs.takeRelativeTime {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.takeRelativeTime < rhs.takeRelativeTime
            }

        guard crossfaderEvents.count >= 2 else { return [] }

        let primitives: [PrimitiveEvent] = zip(crossfaderEvents, crossfaderEvents.dropFirst()).compactMap { previous, current in
            let duration = current.takeRelativeTime - previous.takeRelativeTime
            let delta = abs(current.normalizedValue - previous.normalizedValue)
            guard duration > 0, delta >= minimumValueDelta else { return nil }

            let cutCandidate = delta >= minimumCutDelta && duration <= maximumCutDuration
            let durationFactor = cutCandidate
                ? max(0, 1 - (duration / maximumCutDuration))
                : 0
            let deltaFactor = min(1, delta)
            let confidence = min(
                0.97,
                max(
                    minimumConfidence,
                    cutCandidate
                        ? minimumConfidence + (durationFactor * 0.10) + (deltaFactor * 0.10)
                        : minimumConfidence + max(0, deltaFactor - minimumValueDelta) * 0.10
                )
            )

            return PrimitiveEvent(
                startTime: previous.takeRelativeTime,
                endTime: current.takeRelativeTime,
                fromValue: previous.normalizedValue,
                toValue: current.normalizedValue,
                confidence: confidence,
                isCutCandidate: cutCandidate
            )
        }

        guard !primitives.isEmpty else { return [] }

        func makeEvent(
            startTime: Double,
            endTime: Double,
            eventKind: ScratchFaderEventKind,
            fromValue: Double,
            toValue: Double,
            confidence: Double
        ) -> DetectedNotationFaderEvent {
            DetectedNotationFaderEvent(
                startTime: startTime,
                endTime: endTime,
                eventKind: eventKind,
                control: "crossfader",
                fromValue: min(1, max(0, fromValue)),
                toValue: min(1, max(0, toValue)),
                source: "midi",
                confidence: min(1, max(minimumConfidence, confidence))
            )
        }

        var derived: [DetectedNotationFaderEvent] = []
        var index = 0
        while index < primitives.count {
            let current = primitives[index]

            if index + 2 < primitives.count {
                let next = primitives[index + 1]
                let third = primitives[index + 2]
                let firstGap = next.startTime - current.endTime
                let secondGap = third.startTime - next.endTime
                let alternates = current.signedDelta.sign != next.signedDelta.sign &&
                    next.signedDelta.sign != third.signedDelta.sign
                if current.isCutCandidate,
                   next.isCutCandidate,
                   third.isCutCandidate,
                   alternates,
                   firstGap <= maximumPulseGap,
                   secondGap <= maximumPulseGap {
                    derived.append(
                        makeEvent(
                            startTime: current.startTime,
                            endTime: third.endTime,
                            eventKind: .transformPulse,
                            fromValue: current.fromValue,
                            toValue: third.toValue,
                            confidence: (current.confidence + next.confidence + third.confidence) / 3
                        )
                    )
                    index += 3
                    continue
                }
            }

            if index + 1 < primitives.count {
                let next = primitives[index + 1]
                let gap = next.startTime - current.endTime
                let reversesDirection = current.signedDelta.sign != next.signedDelta.sign
                if current.isCutCandidate,
                   next.isCutCandidate,
                   reversesDirection,
                   gap <= maximumPulseGap {
                    derived.append(
                        makeEvent(
                            startTime: current.startTime,
                            endTime: next.endTime,
                            eventKind: .pulse,
                            fromValue: current.fromValue,
                            toValue: next.toValue,
                            confidence: (current.confidence + next.confidence) / 2
                        )
                    )
                    index += 2
                    continue
                }
            }

            derived.append(
                makeEvent(
                    startTime: current.startTime,
                    endTime: current.endTime,
                    eventKind: current.isCutCandidate ? .cut : .unknown,
                    fromValue: current.fromValue,
                    toValue: current.toValue,
                    confidence: current.confidence
                )
            )
            index += 1
        }

        return derived
    }

    /// Decodes a relative ring-counter platter stream (e.g. RANE ONE MKII CC6)
    /// into physically-coherent movement events — WITHOUT touching the camera
    /// `HandDirectionTracker`.
    ///
    /// Sign contract (documented and tested, provisional on camera correlation):
    ///   positive CC6 delta → "forward", negative → "backward". This is
    ///   consistent with the verified ring-counter ("forward +1, reverse −1")
    ///   and with Take 002's single camera event (a `backward` stroke overlapping
    ///   a negative CC6 run).
    ///
    /// Modular signed deltas avoid false reversals at 127↔0 / 0↔127. Consecutive
    /// same-sign deltas (adjacent-event gaps ≤ `maxEventGap`) form a run; runs
    /// shorter than `minRunDuration`, or with fewer than `minRunSteps` net steps,
    /// are rejected as isolated one-step noise / stationary chatter. The
    /// integrated position is normalized to 0…1 over the stream's own min/max so
    /// the shared normalizer/fusion thresholds keep their existing [0,1] scale.
    /// Stage-by-stage counts of a platter telemetry decode, so the exact
    /// pipeline reduction (filtered → raw runs → noise-filtered → normalized)
    /// is observable and testable rather than a black box.
    struct PlatterDecodeDiagnostics: Equatable {
        /// CC6 events that matched controller/channel/device filters.
        let filteredEventCount: Int
        /// Same-sign runs before the noise-rejection gates.
        let rawRunCount: Int
        /// Runs surviving `minRunDuration` and `minRunSteps` (== the emitted
        /// event count — this is the decoder's "noise-filtered" stage).
        let noiseFilteredRunCount: Int
    }

    /// The run still in progress at the end of the input snapshot, when
    /// `decodePlatterCore` is asked not to force-close it. Distinct from
    /// `DetectedNotationRecordMovementEvent` on purpose — a trailing run has
    /// not been closed by a turnaround or a gap, so it is never a completed
    /// stroke, even if `meetsNoiseGates` happens to already be true.
    struct TrailingPlatterRun: Equatable, Sendable {
        let startTime: Double
        let currentTime: Double
        let startPosition: Double
        let currentPosition: Double
        let direction: String
        let movementKind: ScratchMovementKind
        /// Signed cumulative displacement (steps) since `startTime`.
        let displacement: Double
        /// Whether this run would already pass `minRunDuration`/`minRunSteps`
        /// if it were closed right now — informational only; it is still an
        /// open run and must never be treated as committed.
        let meetsNoiseGates: Bool
    }

    /// Stage-by-stage decode diagnostics for a platter telemetry stream.
    /// Mirrors `derivePlatterMovementEvents` exactly (same core, same filters),
    /// but returns the intermediate counts.
    static func platterMovementDecodeDiagnostics(
        from mixerMidiEvents: [RawMixerMIDIEvent],
        controller: Int,
        channel: Int? = nil,
        deviceName: String? = nil,
        ringModulus: Int = 128,
        minRunDuration: Double = 0.08,
        minRunSteps: Int = 8,
        maxEventGap: Double = 0.10
    ) -> PlatterDecodeDiagnostics {
        let core = decodePlatterCore(
            from: mixerMidiEvents, controller: controller, channel: channel,
            deviceName: deviceName, ringModulus: ringModulus,
            minRunDuration: minRunDuration, minRunSteps: minRunSteps,
            maxEventGap: maxEventGap)
        return core.diagnostics
    }

    static func derivePlatterMovementEvents(
        from mixerMidiEvents: [RawMixerMIDIEvent],
        controller: Int,
        channel: Int? = nil,
        deviceName: String? = nil,
        ringModulus: Int = 128,
        minRunDuration: Double = 0.08,
        minRunSteps: Int = 8,
        maxEventGap: Double = 0.10
    ) -> [DetectedNotationRecordMovementEvent] {
        let core = decodePlatterCore(
            from: mixerMidiEvents, controller: controller, channel: channel,
            deviceName: deviceName, ringModulus: ringModulus,
            minRunDuration: minRunDuration, minRunSteps: minRunSteps,
            maxEventGap: maxEventGap)
        return core.events
    }

    /// Finalized, presentation-only controller notation using the exact same
    /// filter/integrate/run segmentation and noise gates as canonical evidence.
    /// Unlike `derivePlatterMovementEvents`, this projects each accepted run
    /// from its raw step excursion onto a gesture-local coordinate and is never
    /// persisted, scored, or exported.
    static func deriveGestureRelativePlatterNotationEvents(
        from mixerMidiEvents: [RawMixerMIDIEvent],
        controller: Int,
        channel: Int? = nil,
        deviceName: String? = nil,
        ringModulus: Int = 128,
        minRunDuration: Double = 0.08,
        minRunSteps: Int = 8,
        maxEventGap: Double = 0.10,
        notationStepsPerRevolution: Double = PlatterCoordinateSemantics
            .raneOneMKIIDirectMIDIStepsPerRevolution
    ) -> [DetectedNotationRecordMovementEvent] {
        let core = decodePlatterCore(
            from: mixerMidiEvents, controller: controller, channel: channel,
            deviceName: deviceName, ringModulus: ringModulus,
            minRunDuration: minRunDuration, minRunSteps: minRunSteps,
            maxEventGap: maxEventGap)
        return core.events.compactMap {
            gestureRelativeNotationEventFromDecodedRun(
                $0,
                stepsPerRevolution: notationStepsPerRevolution
            )
        }
    }

    /// Shared decode core: filters, integrates modular signed deltas, segments
    /// same-sign runs, and emits movement events, returning both the events and
    /// the stage-by-stage diagnostics.
    ///
    /// `forceCloseTrailingRun`: when `true` (the default, and the only
    /// behavior used by `derivePlatterMovementEvents`/
    /// `platterMovementDecodeDiagnostics` — unchanged from before this
    /// parameter existed), the run still in progress at the end of
    /// `mixerMidiEvents` is force-closed and, if it passes the noise gates,
    /// emitted as a completed event exactly like every other run. That is
    /// correct for finalization (there is no "more data coming"), but it is
    /// NOT a live/provisional stroke — it's a genuinely completed event
    /// synthesized only because the input snapshot ended. When `false`
    /// (used by `derivePlatterMovementEventsWithProvisional` for a live,
    /// in-progress attempt), the trailing run is never force-closed into
    /// `events`; its live state is returned separately via `trailingRun` so
    /// callers can render it as an explicitly open/provisional stroke
    /// without it ever appearing in — or being mistaken for — a committed
    /// event.
    private static func decodePlatterCore(
        from mixerMidiEvents: [RawMixerMIDIEvent],
        controller: Int,
        channel: Int?,
        deviceName: String?,
        ringModulus: Int,
        minRunDuration: Double,
        minRunSteps: Int,
        maxEventGap: Double,
        forceCloseTrailingRun: Bool = true
    ) -> (events: [DetectedNotationRecordMovementEvent], diagnostics: PlatterDecodeDiagnostics, trailingRun: TrailingPlatterRun?) {
        let events = mixerMidiEvents
            .filter {
                $0.controller == controller
                    && (channel == nil || $0.channel == channel)
                    && (deviceName == nil || $0.deviceName == deviceName)
            }
            .sorted { $0.takeRelativeTime < $1.takeRelativeTime }
        let filteredEventCount = events.count
        guard events.count >= 2 else {
            return ([], PlatterDecodeDiagnostics(
                filteredEventCount: filteredEventCount, rawRunCount: 0,
                noiseFilteredRunCount: 0), nil)
        }

        let half = ringModulus / 2

        // 1. Unwrap modular signed deltas and integrate a cumulative position
        //    (steps). positions[i] = cumulative steps at event i.
        var cumulative = 0
        var positions: [Double] = [0]
        var deltas: [Int] = []
        deltas.reserveCapacity(events.count - 1)
        for i in 1..<events.count {
            var delta = events[i].value - events[i - 1].value
            if delta > half { delta -= ringModulus }
            else if delta < -half { delta += ringModulus }
            cumulative += delta
            deltas.append(delta)
            positions.append(Double(cumulative))
        }

        // 2. Segment deltas into same-sign runs. A zero delta is ignored; a gap
        //    larger than maxEventGap, or a sign flip, closes the current run.
        struct Run { let startIdx: Int; let endIdx: Int }
        var runs: [Run] = []
        var runSign = 0
        var runStart = 0
        for i in 0..<deltas.count {
            let sign = deltas[i] > 0 ? 1 : (deltas[i] < 0 ? -1 : 0)
            if sign == 0 { continue }
            let gap = events[i + 1].takeRelativeTime - events[i].takeRelativeTime
            let breaksRun = gap > maxEventGap || (runSign != 0 && sign != runSign)
            if runSign != 0 && breaksRun {
                runs.append(Run(startIdx: runStart, endIdx: i))
                runStart = i
                runSign = sign
            } else {
                if runSign == 0 { runStart = i }
                runSign = sign
            }
        }
        // The run still open when the input ends (`runSign != 0` after the
        // loop): force-closed into `runs` for finalization (unchanged
        // behavior), or reserved separately as `trailingRunCandidate` for a
        // live/provisional caller — never both, so a trailing run can never
        // be double-counted as both committed and provisional.
        var trailingRunCandidate: Run?
        if runSign != 0 {
            let trailing = Run(startIdx: runStart, endIdx: deltas.count)
            if forceCloseTrailingRun {
                runs.append(trailing)
            } else {
                trailingRunCandidate = trailing
            }
        }
        let rawRunCount = runs.count

        // 3. Normalize the integrated position to 0…1 over the stream's range.
        let minPos = positions.min() ?? 0
        let maxPos = positions.max() ?? 0
        let span = max(maxPos - minPos, 1.0)

        // 4. Emit events for runs that survive the noise-rejection gates.
        var result: [DetectedNotationRecordMovementEvent] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            let startTime = events[run.startIdx].takeRelativeTime
            let endTime = events[run.endIdx].takeRelativeTime
            let duration = endTime - startTime
            let startPos = (positions[run.startIdx] - minPos) / span
            let endPos = (positions[run.endIdx] - minPos) / span
            let displacement = positions[run.endIdx] - positions[run.startIdx]
            guard duration > 0,
                  duration >= minRunDuration,
                  abs(displacement) >= Double(minRunSteps) else { continue }
            let direction = displacement > 0 ? "forward" : "backward"
            let speed = abs(displacement) / duration
            // High-confidence direct telemetry: floor 0.7, rising toward 1.0 for
            // longer runs — never 1.0 merely because a source was detected.
            let confidence = min(0.95, 0.7 + Double(abs(displacement)) / 1000.0)
            result.append(DetectedNotationRecordMovementEvent(
                startTime: startTime,
                endTime: endTime,
                startPosition: startPos,
                endPosition: endPos,
                direction: direction,
                movementKind: direction == "forward" ? .normalPush : .normalPull,
                speed: speed,
                confidence: confidence,
                source: "controller"
            ))
        }
        // Describe the still-open trailing run (if any) using the exact same
        // math as every committed run above — never relabeling a finalized
        // event, since this run was deliberately excluded from `runs` and
        // never went through the emit/noise-gate loop as a candidate.
        var trailingRun: TrailingPlatterRun?
        if let trailing = trailingRunCandidate {
            let startTime = events[trailing.startIdx].takeRelativeTime
            let currentTime = events[trailing.endIdx].takeRelativeTime
            let startPos = (positions[trailing.startIdx] - minPos) / span
            let currentPos = (positions[trailing.endIdx] - minPos) / span
            let displacement = positions[trailing.endIdx] - positions[trailing.startIdx]
            let duration = currentTime - startTime
            let direction = displacement > 0 ? "forward" : "backward"
            trailingRun = TrailingPlatterRun(
                startTime: startTime,
                currentTime: currentTime,
                startPosition: startPos,
                currentPosition: currentPos,
                direction: direction,
                movementKind: direction == "forward" ? .normalPush : .normalPull,
                displacement: displacement,
                meetsNoiseGates: duration > 0 && duration >= minRunDuration && abs(displacement) >= Double(minRunSteps)
            )
        }
        return (result, PlatterDecodeDiagnostics(
            filteredEventCount: filteredEventCount, rawRunCount: rawRunCount,
            noiseFilteredRunCount: result.count), trailingRun)
    }

    struct ProvisionalPlatterMovement: Equatable, Sendable {
        let startTime: Double
        let currentTime: Double
        let startPosition: Double
        let currentPosition: Double
        let direction: String
        let movementKind: ScratchMovementKind
        let displacement: Double
    }

    struct PlatterMovementDecodeResult: Equatable, Sendable {
        /// Turnaround/gap-closed strokes. Append-only across successive
        /// calls with a growing `mixerMidiEvents` prefix — never mutated
        /// retroactively, since `decodePlatterCore`'s run segmentation is
        /// deterministic over the same prefix of events.
        let committedEvents: [DetectedNotationRecordMovementEvent]
        /// The current open stroke since the last committed turnaround, or
        /// nil if the platter is idle / has produced no run yet. Never fed
        /// into finalization — preview-only.
        let provisionalMovement: ProvisionalPlatterMovement?
    }

    /// Live/provisional variant of `derivePlatterMovementEvents`, sharing
    /// the exact same filter/integrate/segment core (`decodePlatterCore`)
    /// rather than a second reconstruction algorithm. The run still open at
    /// the end of `mixerMidiEvents` is never force-closed into a committed
    /// event — it is exposed separately as `provisionalMovement`. After that
    /// shared decode, committed/open controller runs are projected into the
    /// explicit gesture-relative notation coordinate; finalized/export
    /// evidence remains on `derivePlatterMovementEvents` and is not rewritten.
    /// Calling this repeatedly with a monotonically growing
    /// `mixerMidiEvents` prefix (e.g. from a live poll) yields a
    /// `committedEvents` array that only ever grows/extends, since a run
    /// already closed by an earlier call's data can never be re-opened by
    /// more data arriving after it.
    static func derivePlatterMovementEventsWithProvisional(
        from mixerMidiEvents: [RawMixerMIDIEvent],
        controller: Int,
        channel: Int? = nil,
        deviceName: String? = nil,
        ringModulus: Int = 128,
        minRunDuration: Double = 0.08,
        minRunSteps: Int = 8,
        maxEventGap: Double = 0.10,
        notationStepsPerRevolution: Double = PlatterCoordinateSemantics
            .raneOneMKIIDirectMIDIStepsPerRevolution
    ) -> PlatterMovementDecodeResult {
        let core = decodePlatterCore(
            from: mixerMidiEvents, controller: controller, channel: channel,
            deviceName: deviceName, ringModulus: ringModulus,
            minRunDuration: minRunDuration, minRunSteps: minRunSteps,
            maxEventGap: maxEventGap, forceCloseTrailingRun: false)
        let committed = core.events.compactMap {
            gestureRelativeNotationEventFromDecodedRun(
                $0,
                stepsPerRevolution: notationStepsPerRevolution
            )
        }
        let provisional = core.trailingRun.map {
            let coordinates = PlatterCoordinateSemantics.gestureRelativeNotation(
                signedDisplacementSteps: $0.displacement,
                stepsPerRevolution: notationStepsPerRevolution
            )
            return ProvisionalPlatterMovement(
                startTime: $0.startTime,
                currentTime: $0.currentTime,
                startPosition: coordinates.startPosition,
                currentPosition: coordinates.endPosition,
                direction: $0.direction,
                movementKind: $0.movementKind,
                displacement: $0.displacement
            )
        }
        return PlatterMovementDecodeResult(
            committedEvents: committed,
            provisionalMovement: provisional
        )
    }

    /// Shared iOS/macOS presentation view of a finalized notation snapshot.
    ///
    /// Canonical `recordMovementEvents` remain byte-for-byte unchanged for
    /// scoring, persistence, and export. When exactly one right-deck CC6 source
    /// is present, physical gesture excursions are re-derived from the raw MIDI
    /// evidence through the existing decoder. Ambiguous/missing raw evidence
    /// fails closed to an event-only local rebase that preserves the stored
    /// excursion and never guesses raw motor travel.
    static func gestureRelativeRecordMovementEventsForPresentation(
        from snapshot: DetectedNotationSnapshot,
        controller: Int = 6,
        channel: Int = 1
    ) -> [DetectedNotationRecordMovementEvent] {
        let canonical = snapshot.recordMovementEvents
        let hasControllerEvidence = canonical.contains(
            where: usesGestureRelativeControllerNotation
        ) || snapshot.detectionSources.contains("controller")
        guard hasControllerEvidence else {
            return canonical
        }

        let eligibleMIDI = snapshot.mixerMidiEvents.filter {
            $0.controller == controller && $0.channel == channel
        }
        let deviceNames = Set(eligibleMIDI.map(\.deviceName))
        guard deviceNames.count == 1, let deviceName = deviceNames.first else {
            return canonical.map(locallyRebasedControllerNotationEvent)
        }

        let controllerEvents = deriveGestureRelativePlatterNotationEvents(
            from: eligibleMIDI,
            controller: controller,
            channel: channel,
            deviceName: deviceName
        )
        guard !controllerEvents.isEmpty else {
            return canonical.map(locallyRebasedControllerNotationEvent)
        }

        // Preserve the finalized record's metadata whenever fusion retained the
        // decoder run. Only its coordinates are presentation-projected. This
        // keeps fusion's movement kind, confidence, source, speed, and timing
        // intact instead of replacing them with a fresh decoder record.
        var matchedControllerIndexes = Set<Int>()
        var expandedMergedControllerEvents: [DetectedNotationRecordMovementEvent] = []
        let projectedCanonical: [DetectedNotationRecordMovementEvent] = canonical.compactMap { event in
            guard usesGestureRelativeControllerNotation(event) else {
                return event
            }
            if let match = controllerEvents.indices.first(where: { index in
                guard !matchedControllerIndexes.contains(index) else { return false }
                let candidate = controllerEvents[index]
                return candidate.direction == event.direction
                    && abs(candidate.startTime - event.startTime) <= 1e-6
                    && abs(candidate.endTime - event.endTime) <= 1e-6
            }) {
                matchedControllerIndexes.insert(match)
                let coordinates = controllerEvents[match]
                return DetectedNotationRecordMovementEvent(
                    startTime: event.startTime,
                    endTime: event.endTime,
                    startPosition: coordinates.startPosition,
                    endPosition: coordinates.endPosition,
                    direction: event.direction,
                    movementKind: event.movementKind,
                    speed: event.speed,
                    confidence: event.confidence,
                    source: event.source
                )
            }

            // Fusion may merge two accepted same-direction decoder runs when a
            // tiny intervening reversal failed the decoder noise gates. The
            // merged canonical timing then covers multiple raw runs and cannot
            // exact-match either one. For presentation, expand it back to those
            // accepted shared-decoder runs so live and saved notation agree and
            // do not render the merged record plus both runs as duplicates.
            if let firstIndex = controllerEvents.indices.first(where: { index in
                !matchedControllerIndexes.contains(index)
                    && controllerEvents[index].direction == event.direction
                    && abs(controllerEvents[index].startTime - event.startTime) <= 1e-6
            }),
               let lastIndex = controllerEvents.indices.last(where: { index in
                !matchedControllerIndexes.contains(index)
                    && controllerEvents[index].direction == event.direction
                    && abs(controllerEvents[index].endTime - event.endTime) <= 1e-6
            }),
               firstIndex < lastIndex {
                let coveredIndexes = firstIndex...lastIndex
                let isCoveredBySameDirectionRuns = coveredIndexes.allSatisfy { index in
                    !matchedControllerIndexes.contains(index)
                        && controllerEvents[index].direction == event.direction
                        && controllerEvents[index].startTime >= event.startTime - 1e-6
                        && controllerEvents[index].endTime <= event.endTime + 1e-6
                }
                if isCoveredBySameDirectionRuns {
                    matchedControllerIndexes.formUnion(coveredIndexes)
                    expandedMergedControllerEvents.append(
                        contentsOf: coveredIndexes.map { controllerEvents[$0] }
                    )
                    return nil
                }
            }
            return locallyRebasedControllerNotationEvent(event)
        }

        // A controller run can pass the shared decoder gates yet be rejected
        // later by attempt-wide fusion normalization (the original Slice D
        // defect after a long free spin). It still belongs in notation-only
        // presentation, but never mutates the canonical snapshot used by
        // scoring, persistence, or export.
        let unmatchedControllerEvents = controllerEvents.indices.compactMap { index in
            matchedControllerIndexes.contains(index) ? nil : controllerEvents[index]
        }
        return (
            projectedCanonical
                + expandedMergedControllerEvents
                + unmatchedControllerEvents
        ).sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
    }

    /// Timeline end for presentation-only gesture notation. Canonical evidence
    /// remains the primary duration source; a decoder-valid controller run that
    /// fusion omitted may extend it, so overlay playback must include that run
    /// instead of stopping at the earlier canonical edge.
    static func gestureRelativeRecordMovementPresentationEndTime(
        from snapshot: DetectedNotationSnapshot,
        presentationEvents: [DetectedNotationRecordMovementEvent]
    ) -> Double? {
        [
            snapshot.capturedEvidenceEndTime,
            presentationEvents.map(\.endTime).max()
        ].compactMap { $0 }.max()
    }

    /// Whether iOS may move its raw decode anchor along motor rotation already
    /// rejected by the existing release gate. A committed stroke remains an
    /// immutable published prefix until it has genuinely left the live
    /// viewport; `live_preview` is open/provisional and is not an anchor block.
    static func canAdvanceLiveNotationAnchorPastSuppressedMotorRotation(
        publishedEvents: [DetectedNotationRecordMovementEvent],
        latestTime: TimeInterval,
        viewportDuration: TimeInterval
    ) -> Bool {
        let cutoff = max(0, latestTime - max(0, viewportDuration))
        return !publishedEvents.contains { event in
            event.source != "live_preview" && event.endTime >= cutoff
        }
    }

    /// Finds a bounded raw-stream anchor while retaining the complete recent
    /// window the existing motor-release classifier needs to recognize a
    /// reversal. The classifier can remain true for the first few backward
    /// packets; keeping this tail ensures those packets are decoded once the
    /// gate clears, preserving the pull's true onset and excursion.
    static func liveNotationAnchorIndexPreservingSuppressedMotorTail(
        in mixerMidiEvents: [RawMixerMIDIEvent],
        currentAnchorIndex: Int,
        controller: Int,
        channel: Int,
        latestTime: TimeInterval,
        lookBehindDuration: TimeInterval
    ) -> Int? {
        guard !mixerMidiEvents.isEmpty else { return nil }
        let lowerBound = max(0, min(currentAnchorIndex, mixerMidiEvents.count - 1))
        let tailStart = max(0, latestTime - max(0, lookBehindDuration))
        return (lowerBound..<mixerMidiEvents.count).last(where: { index in
            let event = mixerMidiEvents[index]
            return event.controller == controller
                && event.channel == channel
                && event.takeRelativeTime <= tailStart
        })
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
        var reviewDecision: CaptureReviewDecision?
        var reviewMetadata: CaptureReviewMetadata?
        var detectedNotation: DetectedNotationSnapshot?
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
            reviewDecision: CaptureReviewDecision? = nil,
            reviewMetadata: CaptureReviewMetadata? = nil,
            detectedNotation: DetectedNotationSnapshot? = nil,
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
            self.reviewDecision = reviewDecision
            self.reviewMetadata = reviewMetadata
            self.detectedNotation = detectedNotation
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

        func reviewed(
            status: CaptureReviewDecision.Status,
            label: String,
            detectedLabel: String?,
            confidence: Double?,
            reviewedAt: Date = Date()
        ) -> LocalRecordingSidecar {
            var updated = self
            updated.reviewDecision = CaptureReviewDecision(
                status: status,
                label: label,
                detectedLabel: detectedLabel,
                confidence: confidence,
                reviewedAt: reviewedAt
            )
            updated.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: reviewedAt,
                    category: "label_reviewed",
                    detail: "Review marked \(takeID) as \(label) with status \(status.rawValue)."
                )
            )
            return updated
        }

        func withReviewMetadata(
            _ metadata: CaptureReviewMetadata,
            audit reason: String,
            recordedAt: Date = Date()
        ) -> LocalRecordingSidecar {
            var updated = self
            updated.reviewMetadata = metadata
            updated.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: recordedAt,
                    category: "review_metadata_updated",
                    detail: reason
                )
            )
            return updated
        }

        func withDetectedNotation(
            _ detectedNotation: DetectedNotationSnapshot?,
            recordedAt: Date = Date()
        ) -> LocalRecordingSidecar {
            var updated = self
            updated.detectedNotation = detectedNotation
            updated.auditTrail.append(
                CaptureAuditEvent(
                    timestamp: recordedAt,
                    category: "notation_snapshot",
                    detail: detectedNotation?.hasDetectedEvents == true
                        ? "Captured detected notation snapshot with \(detectedNotation?.recordMovementEvents.count ?? 0) movement events and \(detectedNotation?.audioEvents.count ?? 0) audio events."
                        : "No detected notation events were available at save time."
                )
            )
            return updated
        }
    }
}

// MARK: - Capture readiness presentation model
//
// One semantic capture-readiness state, DERIVED from the real capture engine +
// session setup — never a manually-set UI boolean. Distinct from the per-input
// tiles: this is the single "can I record right now" verdict, plus the
// recording/finalizing/complete/failed lifecycle that follows.
//
// Enforces the hardware contract: connected ≠ ready, carrier detected ≠ DVS
// ready, DVS ready ≠ capture ready, MIDI detected ≠ crossfader mapped.

/// The five hardware lanes that feed Capture readiness. Kept SEPARATE from the
/// single presentation state so each lane's rich source state survives into the
/// UI and the READY gate reads one place.
enum CaptureLane: String, CaseIterable, Sendable {
    case audio
    case dvsTimecode
    case platter
    case crossfaderMIDI
    case camera

    var label: String {
        switch self {
        case .audio: return "Audio"
        case .dvsTimecode: return "DVS / timecode"
        case .platter: return "Platter"
        case .crossfaderMIDI: return "Crossfader / MIDI"
        case .camera: return "Camera"
        }
    }
}

/// One lane's readiness contribution: whether it gates READY (`isRequired`)
/// and whether it is truly usable (`isUsable`). A lane is *blocking* when it
/// is required but not usable.
struct CaptureLaneReadiness: Equatable, Sendable {
    var isRequired: Bool
    var isUsable: Bool

    /// Optional / off lane — never gates READY.
    static let notRequired = CaptureLaneReadiness(isRequired: false, isUsable: false)

    var isBlocking: Bool { isRequired && !isUsable }

    /// DVS lane — only `DVSSignalState.usable` is usable. Carrier-detected,
    /// weak, clipped, channel-fault, no-signal and lost are all NOT usable.
    static func dvs(_ signal: DVSSignalState, required: Bool) -> CaptureLaneReadiness {
        CaptureLaneReadiness(isRequired: required, isUsable: signal.isReady)
    }

    /// Controller lane — only `ControllerMappingState.dvsPlusMidiReady` (the
    /// true combined-ready state) is usable. `midiLearned` / `platterReady` /
    /// `controllerDetected` are NOT combined-ready.
    static func controller(_ mapping: ControllerMappingState, required: Bool) -> CaptureLaneReadiness {
        CaptureLaneReadiness(isRequired: required, isUsable: mapping.isReady)
    }

    /// Generic input lane (audio / platter / camera) — only `.ready` is usable.
    static func input(_ state: InputReadinessState, required: Bool) -> CaptureLaneReadiness {
        CaptureLaneReadiness(isRequired: required, isUsable: state == .ready)
    }

    /// Audio lane straight from the engine's availability signal. Audio is a
    /// blocking lane whenever a session is active.
    static func audio(isAvailable: Bool) -> CaptureLaneReadiness {
        CaptureLaneReadiness(isRequired: true, isUsable: isAvailable)
    }
}

/// The five Capture lanes. Defaults match the current product: only Audio is
/// blocking; DVS/timecode blocks only while timecode input mode is active;
/// Platter and Crossfader/MIDI are optional today; Camera never blocks.
struct CaptureLanes: Equatable, Sendable {
    var audio = CaptureLaneReadiness.audio(isAvailable: false)
    var dvsTimecode = CaptureLaneReadiness.notRequired
    var platter = CaptureLaneReadiness.notRequired
    var crossfaderMIDI = CaptureLaneReadiness.notRequired
    var camera = CaptureLaneReadiness.notRequired

    /// Lanes that currently gate READY (required and not yet usable).
    var blockingLanes: [CaptureLane] {
        var result: [CaptureLane] = []
        if audio.isBlocking { result.append(.audio) }
        if dvsTimecode.isBlocking { result.append(.dvsTimecode) }
        if platter.isBlocking { result.append(.platter) }
        if crossfaderMIDI.isBlocking { result.append(.crossfaderMIDI) }
        if camera.isBlocking { result.append(.camera) }
        return result
    }

    /// READY is reachable only when every blocking lane is truly usable.
    var isReady: Bool { blockingLanes.isEmpty }
}

enum CaptureReadiness: Equatable, Sendable {
    case setupRequired
    case hardwareDetected
    case needsAttention
    case ready
    case recording
    case finalizing
    case complete
    case incomplete
    case failed
    case timecodeLost
    case permissionRequired

    var label: String {
        switch self {
        case .setupRequired: return "SETUP REQUIRED"
        case .hardwareDetected: return "HARDWARE DETECTED"
        case .needsAttention: return "NEEDS ATTENTION"
        case .ready: return "READY"
        case .recording: return "RECORDING"
        case .finalizing: return "FINALIZING"
        case .complete: return "COMPLETE"
        case .incomplete: return "INCOMPLETE"
        case .failed: return "FAILED"
        case .timecodeLost: return "TIMECODE LOST"
        case .permissionRequired: return "PERMISSION REQUIRED"
        }
    }

    /// Semantic status colour — green only for `.complete`; red for recording/
    /// failure/interruption; amber for attention/incomplete/permission; bone
    /// for ready.
    var variant: StatusBadgeVariant {
        switch self {
        case .setupRequired: return .neutral
        case .hardwareDetected: return .info
        case .needsAttention: return .warning
        case .ready: return .ready
        case .recording: return .danger
        case .finalizing: return .info
        case .complete: return .success
        case .incomplete: return .warning
        case .failed: return .danger
        case .timecodeLost: return .danger
        case .permissionRequired: return .warning
        }
    }

    var isBlockingReady: Bool { self != .ready && self != .complete && self != .recording && self != .finalizing }

    /// Non-colour SF Symbol cue for the state — vital for users who can't
    /// distinguish red/green.
    var systemImage: String {
        switch self {
        case .setupRequired: return "circle.dashed"
        case .hardwareDetected: return "cable.connector"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .recording: return "record.circle.fill"
        case .finalizing: return "hourglass"
        case .complete: return "checkmark.circle.fill"
        case .incomplete: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .timecodeLost: return "waveform.badge.exclamationmark"
        case .permissionRequired: return "lock.fill"
        }
    }
}

/// Pure inputs for `CaptureReadiness.derive` — all primitives, so the mapping
/// is testable without any engine / `@MainActor` dependency. A view maps its
/// real engine + session state into this struct once, then reads the derived
/// state.
struct CaptureReadinessInput: Equatable, Sendable {
    var hasSession: Bool = false
    var isMetadataComplete: Bool = false
    var hasAudioPermission: Bool = true
    /// Any capture hardware seen at all (audio device or MIDI source) — used
    /// to distinguish "hardware present, not yet usable" from "nothing here".
    var hasDetectedHardware: Bool = false
    var lanes: CaptureLanes = .init()
    var isRecording: Bool = false
    var isFinalizing: Bool = false
    var didComplete: Bool = false
    var didFail: Bool = false
    var didEndIncomplete: Bool = false
    var isTimecodeLost: Bool = false
}

extension CaptureReadiness {
    /// Pure derivation. Lifecycle states dominate, then blocking interruptions,
    /// then setup/readiness gates. `.incomplete` (a take ended without a clean
    /// save) and `.failed` (a hard failure) are distinct from `.needsAttention`
    /// (a blocking lane is not usable *before* recording).
    static func derive(_ input: CaptureReadinessInput) -> CaptureReadiness {
        if input.isRecording { return .recording }
        if input.isFinalizing { return .finalizing }
        if input.didComplete { return .complete }
        if input.didFail { return .failed }
        if input.didEndIncomplete { return .incomplete }
        if input.isTimecodeLost { return .timecodeLost }
        if !input.hasAudioPermission { return .permissionRequired }
        if !input.hasSession { return .setupRequired }
        if !input.isMetadataComplete { return .setupRequired }
        if input.lanes.isReady { return .ready }
        // A blocking lane is not usable. Audio-not-usable with hardware present
        // is "hardware detected" (cyan info); every other blocking lane is
        // "needs attention" (resolve the input).
        if input.lanes.audio.isBlocking && input.hasDetectedHardware {
            return .hardwareDetected
        }
        return .needsAttention
    }
}

// MARK: - Review presentation model
//
// One semantic review state, DERIVED from the real session/take/export model —
// never a manually-set UI boolean. Green (`.confirmed` / `.exported`) appears
// only after real confirmation / a real export artifact; `.noTake` never
// fabricates captured evidence; `.issue` carries no valid-take claim.

enum ReviewPresentationState: Equatable, Sendable {
    case noTake
    case recording
    case finalizing
    case issue
    case ready
    case corrected
    case confirmed
    case exporting
    case exported
    case exportFailed

    var label: String {
        switch self {
        case .noTake: return "NO TAKE"
        case .recording: return "RECORDING"
        case .finalizing: return "FINALIZING"
        case .issue: return "ISSUE"
        case .ready: return "READY"
        case .corrected: return "CORRECTED"
        case .confirmed: return "CONFIRMED"
        case .exporting: return "EXPORTING"
        case .exported: return "EXPORTED"
        case .exportFailed: return "EXPORT FAILED"
        }
    }

    /// Semantic colour — green only for `.confirmed` / `.exported`; red for
    /// recording/failure; amber for issue; bone for ready. `.corrected` is
    /// cyan (informational): a label correction is a recorded human action,
    /// never presented as a green confirmation.
    var variant: StatusBadgeVariant {
        switch self {
        case .noTake: return .neutral
        case .recording: return .danger
        case .finalizing: return .info
        case .issue: return .warning
        case .ready: return .ready
        case .corrected: return .info
        case .confirmed: return .success
        case .exporting: return .info
        case .exported: return .success
        case .exportFailed: return .danger
        }
    }
}

/// Pure inputs for `ReviewPresentationState.derive` — all primitives.
struct ReviewPresentationInput: Equatable, Sendable {
    var hasTake: Bool = false
    var isRecording: Bool = false
    var isFinalizing: Bool = false
    var hasIssue: Bool = false
    /// The persisted label decision for the take. Only `.accepted` maps to
    /// `.confirmed` and only `.corrected` maps to `.corrected`; `nil` and
    /// `.unknown` fall through to `.ready`. Detection confidence is NOT part
    /// of this input — confidence stays informational and never triggers a
    /// confirmation.
    var decisionStatus: CaptureCore.CaptureReviewDecision.Status? = nil
    var isExporting: Bool = false
    var isExported: Bool = false
    var didExportFail: Bool = false
}

extension ReviewPresentationState {
    /// Pure derivation. Take lifecycle states dominate, then no-take, then the
    /// export lifecycle, then the label decision (confirmed/corrected) over
    /// ready.
    static func derive(_ input: ReviewPresentationInput) -> ReviewPresentationState {
        if input.isRecording { return .recording }
        if input.isFinalizing { return .finalizing }
        if input.hasIssue { return .issue }
        if !input.hasTake { return .noTake }
        if input.isExporting { return .exporting }
        if input.didExportFail { return .exportFailed }
        if input.isExported { return .exported }
        if input.decisionStatus == .accepted { return .confirmed }
        if input.decisionStatus == .corrected { return .corrected }
        return .ready
    }
}

// MARK: - Advanced Overview presentation model
//
// One authoritative summary of the Advanced workspace's five input lanes
// (Audio, DVS/timecode, MIDI/controller, optional Camera, Performer Monitor)
// plus the next required action. Every value is DERIVED from real owner state
// (capture engine, timecode pipeline, performer monitor broadcaster) — never a
// parallel capability model, never a manually-set UI boolean.
//
// Enforces the same hardware contract as `CaptureReadiness`: connected ≠
// ready, carrier-detected ≠ DVS ready, MIDI-detected ≠ crossfader-mapped,
// camera optional ≠ blocking.

/// The five input lanes that feed the Advanced Overview summary.
enum AdvancedOverviewLane: String, CaseIterable, Sendable {
    case audio
    case dvsTimecode
    case midiController
    case camera
    case performerMonitor

    var title: String {
        switch self {
        case .audio: return "Audio"
        case .dvsTimecode: return "DVS / timecode"
        case .midiController: return "MIDI / fader"
        case .camera: return "Camera"
        case .performerMonitor: return "Monitor"
        }
    }

    var systemImage: String {
        switch self {
        case .audio: return "waveform"
        case .dvsTimecode: return "waveform.badge.magnifyingglass"
        case .midiController: return "slider.horizontal.3"
        case .camera: return "video"
        case .performerMonitor: return "dot.radiowaves.left.and.right"
        }
    }
}

/// One semantic status for a summary lane or the next action. The six states
/// are deliberately distinct: "detected/connected" (present, not ready — cyan)
/// never collapses into "ready" (bone), and "needs attention" (amber, a fixable
/// problem) is not "setup required" (neutral, not configured yet). Hardware
/// identity and verification tier are NOT part of this axis — they surface
/// separately (controller name in MIDI & fader; registry tier is unwired).
enum AdvancedOverviewStatus: String, CaseIterable, Sendable {
    case setupRequired
    case needsAttention
    case detected
    case ready
    case recording
    case unavailable

    var label: String {
        switch self {
        case .setupRequired: return "SETUP REQUIRED"
        case .needsAttention: return "NEEDS ATTENTION"
        case .detected: return "DETECTED"
        case .ready: return "READY"
        case .recording: return "RECORDING"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .setupRequired: return .neutral
        case .needsAttention: return .warning
        case .detected: return .info
        case .ready: return .ready
        case .recording: return .danger
        case .unavailable: return .neutral
        }
    }
}

/// A single summary row: one lane and its derived readiness status.
struct AdvancedOverviewItem: Equatable, Sendable {
    let lane: AdvancedOverviewLane
    let status: AdvancedOverviewStatus
}

/// The single next required action, derived from the same lane statuses so the
/// header action can never contradict the summary badges.
enum AdvancedOverviewNextAction: Equatable, Sendable {
    case recording
    case createSession
    case fixAudio
    case connectController
    case mapCrossfader
    case ready

    var message: String {
        switch self {
        case .recording:
            return "Recording — press Stop to finish the take."
        case .createSession:
            return "Next: create a session to start capturing."
        case .fixAudio:
            return "Next: select an available audio input."
        case .connectController:
            return "Next: connect a controller to map the crossfader."
        case .mapCrossfader:
            return "Next: map the crossfader before capture."
        case .ready:
            return "Ready — configure hardware and diagnostics in the sections below."
        }
    }

    var systemImage: String {
        switch self {
        case .recording: return "record.circle.fill"
        case .createSession: return "plus.circle"
        case .fixAudio: return "exclamationmark.circle.fill"
        case .connectController: return "exclamationmark.circle.fill"
        case .mapCrossfader: return "exclamationmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }

    var variant: StatusBadgeVariant {
        switch self {
        case .recording: return .danger
        case .createSession: return .accent
        case .fixAudio: return .warning
        case .connectController: return .warning
        case .mapCrossfader: return .warning
        case .ready: return .accent
        }
    }
}

/// Pure inputs for `AdvancedOverviewSummary.derive` — all primitives plus one
/// shared signal-health enum, so the mapping is testable with no engine or
/// `@MainActor` dependency.
struct AdvancedOverviewInput: Equatable, Sendable {
    var hasSession: Bool = false
    var isRecording: Bool = false

    var hasAnyAudioDevice: Bool = false
    var isSelectedAudioAvailable: Bool = false

    var isDVSEnabled: Bool = false
    var dvsSignalHealth: SignalHealth = .noSignal

    var hasMIDIController: Bool = false
    var isCrossfaderMapped: Bool = false

    var isCameraActive: Bool = false
    var isLiveInputEnabled: Bool = false

    var isPerformerMonitorConnected: Bool = false
}

/// The derived Advanced Overview summary: the lane rows plus the single next
/// action. `derive` is the single authority the Overview view maps into.
struct AdvancedOverviewSummary: Equatable, Sendable {
    let items: [AdvancedOverviewItem]
    let nextAction: AdvancedOverviewNextAction

    static func derive(_ input: AdvancedOverviewInput) -> AdvancedOverviewSummary {
        var items: [AdvancedOverviewItem] = []

        // Audio — READY only when the selected input is actually present.
        let audioStatus: AdvancedOverviewStatus
        if !input.hasAnyAudioDevice {
            audioStatus = .setupRequired
        } else if !input.isSelectedAudioAvailable {
            audioStatus = .needsAttention
        } else {
            audioStatus = .ready
        }
        items.append(AdvancedOverviewItem(lane: .audio, status: audioStatus))

        // DVS / timecode — only a healthy, usable signal is READY. A disabled
        // timecode path is UNAVAILABLE (not "setup required", never "ready").
        // No-signal, weak, clipped and channel-fault are all NOT ready. (The
        // design system's `DVSSignalState.carrierDetected` has no `SignalHealth`
        // counterpart here, but it too is NOT ready — only `.usable` is.)
        let dvsStatus: AdvancedOverviewStatus
        if !input.isDVSEnabled {
            dvsStatus = .unavailable
        } else {
            switch input.dvsSignalHealth {
            case .usable: dvsStatus = .ready
            case .noSignal: dvsStatus = .setupRequired
            case .weak, .clipped, .channelFault: dvsStatus = .needsAttention
            }
        }
        items.append(AdvancedOverviewItem(lane: .dvsTimecode, status: dvsStatus))
        let isDVSUsable = (dvsStatus == .ready)

        // MIDI / controller — connected ≠ mapped; mapped ≠ DVS+MIDI ready.
        // This mirrors `ControllerMappingState.isReady`, where only
        // `dvsPlusMidiReady` (crossfader mapped AND DVS usable) is truly ready
        // and `midiLearned` (mapped, no usable DVS) is informational, not ready.
        let midiStatus: AdvancedOverviewStatus
        if !input.hasMIDIController {
            midiStatus = .setupRequired
        } else if !input.isCrossfaderMapped {
            midiStatus = .needsAttention
        } else if isDVSUsable {
            midiStatus = .ready
        } else {
            midiStatus = .detected
        }
        items.append(AdvancedOverviewItem(lane: .midiController, status: midiStatus))

        // Camera — optional, non-blocking, surfaced only when enabled/active.
        if input.isCameraActive || input.isLiveInputEnabled {
            items.append(AdvancedOverviewItem(
                lane: .camera,
                status: input.isCameraActive ? .detected : .unavailable
            ))
        }

        // Performer Monitor — connected is informational, never green-ready.
        items.append(AdvancedOverviewItem(
            lane: .performerMonitor,
            status: input.isPerformerMonitorConnected ? .detected : .setupRequired
        ))

        // Next action — recording dominates, then setup, then blocking lanes.
        // DVS, camera and monitor are deliberately non-blocking for the
        // Overview next action (they are optional/prototype surfaces).
        let nextAction: AdvancedOverviewNextAction
        if input.isRecording {
            nextAction = .recording
        } else if !input.hasSession {
            nextAction = .createSession
        } else if audioStatus != .ready {
            nextAction = .fixAudio
        } else if !input.hasMIDIController {
            nextAction = .connectController
        } else if !input.isCrossfaderMapped {
            nextAction = .mapCrossfader
        } else {
            nextAction = .ready
        }

        return AdvancedOverviewSummary(items: items, nextAction: nextAction)
    }
}
