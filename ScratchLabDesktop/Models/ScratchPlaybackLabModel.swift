#if os(macOS)
import Foundation
import Combine

// Scratch Playback Lab: macOS view model.
//
// Scope guardrails (deliberate):
// - Display + isolated playback only. Owns a `CoreMIDIInputTransport` (input-only,
//   same pattern as the Controller Inspector), the pure platter mapper
//   (`ScratchPlatterPlayheadMapper`), and the isolated `ScratchPlaybackLabEngine`.
//   It writes nothing to disk or to any device, and changes no existing behaviour.
// - NOT notation, NOT replay, NOT coaching, NOT capture/scoring/export.
//
// TODO (next slice): add a separate beat layer (its own player, NOT
// ScratchLabBeatEngine / capture timing) with an on/off toggle.
// TODO (promotion): once platter-driven playback is proven, promote this waveform +
// playhead surface into the main Practice view so ScratchLab behaves like Scratch
// Visualizer during practice — this window is temporary isolation, not final UX.

/// Turns timestamped platter moves into a stable signed audio rate for the RANE CC6 path.
///
/// A single-event `moved / dt` is unusable at slow speed: CoreMIDI delivers the platter's
/// events in bursts (inter-event `dt` swings ~1–14 ms for the *same* slow rotation), so the
/// instantaneous rate spikes to near-1× and, because the engine holds the last rate between
/// events, those spikes are heard as correct-pitch "ah" bursts over the slow scratch.
///
/// Instead this measures the rate over a short *real-time* window: the net displacement over
/// the last `windowSeconds` divided by the real elapsed time of that window. A sub-millisecond
/// burst then contributes its net displacement over real time, not over a tiny `dt`, so the
/// rate reads the true slow speed; it stays correct (and responsive, ~window/2 group delay) at
/// all speeds. It re-`anchor`s to the mapper's absolute position on the first event or after a
/// `> idleTimeout` gap (mirroring the Scratch Visualizer path), and never mutes on its own —
/// a true stop still zeroes velocity through the host's existing idle handler. Pure/testable.
struct ScratchPlatterAudioDrive {
    enum Action: Equatable {
        /// Set the engine velocity to this windowed rate (sample-seconds of playback per real second).
        case glide(sampleSecondsPerSecond: Double)
        /// Snap/seek the engine to the mapper's true absolute sample position.
        case anchor
    }

    let windowSeconds: TimeInterval
    let idleTimeout: TimeInterval
    /// Minimum real-time span before a glide rate is trusted. When the history window
    /// spans less than this (e.g. a sub-millisecond delivery burst), the drive returns
    /// the last known good rate instead of computing a fresh rate that would spike to
    /// near-1×. Default 3 ms — longer than the worst sub-ms MIDI cluster, shorter than
    /// the ~14 ms burst gap so every non-first burst fills the window.
    let minimumSpan: TimeInterval
    /// (event time, cumulative sample-seconds travelled). Trimmed to roughly `windowSeconds`.
    private var history: [(time: TimeInterval, position: Double)] = []
    private var cumulativePosition: Double = 0
    private var lastTime: TimeInterval?
    /// Last glide rate the drive produced when the window span was ≥ minimumSpan.
    /// Used to hold a stable rate across sub-ms delivery bursts so the engine never
    /// gets a single-event "moved / dt" spike. Reset on `reset()` and after idle timeout.
    private var lastGlideRate: Double?

    init(windowSeconds: TimeInterval = 0.022,
         idleTimeout: TimeInterval = 0.18,
         minimumSpan: TimeInterval = 0.003) {
        self.windowSeconds = max(windowSeconds, 0)
        self.idleTimeout = max(idleTimeout, 0)
        self.minimumSpan = max(minimumSpan, 0)
    }

    mutating func reset() {
        history.removeAll(keepingCapacity: true)
        cumulativePosition = 0
        lastTime = nil
        lastGlideRate = nil
    }

    /// Ingests one platter move of `moved` sample-seconds that occurred at real time `time`.
    mutating func ingest(moved: Double, at time: TimeInterval) -> Action {
        if let last = lastTime, time - last > idleTimeout { reset() } // resume after idle: restart window
        let resumed = lastTime == nil
        cumulativePosition += moved
        lastTime = time
        history.append((time, cumulativePosition))
        // Keep the newest reference point that is still at/older than the window edge, so the
        // window spans ~windowSeconds (or the whole burst if shorter).
        let cutoff = time - windowSeconds
        while history.count >= 2 && history[1].time <= cutoff { history.removeFirst() }
        if resumed { return .anchor }                                 // first move: snap, don't glide
        let reference = history[0]
        let span = time - reference.time
        guard span > 0 else { return .anchor }
        // Sub-millisecond delivery bursts produce a single-event "moved / dt" spike that the
        // engine would hold until the next burst arrives. When the window span is too thin,
        // hold the last known good rate so the audio glides smoothly across the gap. If no
        // prior glide rate exists yet (start of rotation), anchor instead — a spike into
        // silence is inaudible, and the window fills in 3–4 ms.
        guard span >= minimumSpan else {
            if let last = lastGlideRate {
                return .glide(sampleSecondsPerSecond: last)
            }
            return .anchor
        }
        let rate = (cumulativePosition - reference.position) / span
        lastGlideRate = rate
        return .glide(sampleSecondsPerSecond: rate)
    }
}

/// One precomputed waveform column: the min and max sample value in a bin.
struct WaveformPeak: Equatable {
    let min: Float
    let max: Float

    /// Downsamples a mono buffer into `binCount` min/max columns for drawing.
    static func peaks(from samples: [Float], binCount: Int) -> [WaveformPeak] {
        guard binCount > 0, !samples.isEmpty else { return [] }
        let bins = Swift.min(binCount, samples.count)
        var peaks: [WaveformPeak] = []
        peaks.reserveCapacity(bins)
        let stride = Double(samples.count) / Double(bins)
        for bin in 0..<bins {
            let start = Int(Double(bin) * stride)
            let end = Swift.min(samples.count, Int(Double(bin + 1) * stride))
            var lo: Float = 0
            var hi: Float = 0
            if start < end {
                lo = samples[start]
                hi = samples[start]
                for index in (start + 1)..<end {
                    lo = Swift.min(lo, samples[index])
                    hi = Swift.max(hi, samples[index])
                }
            }
            peaks.append(WaveformPeak(min: lo, max: hi))
        }
        return peaks
    }
}

/// Pure, deterministic suggested default names for the Scratch Playback Lab exports. These
/// are the names the save panel pre-fills; the user picks the actual destination (so writes
/// are sandbox-safe). Preserving these keeps exported filenames identical to before.
enum PlaybackLabExport {
    static func timelineFilename(epoch: Int) -> String { "ScratchTimeline-\(epoch).json" }
    static func diagnosticFilename(epoch: Int) -> String { "RaneDiagnostic-\(epoch).json" }
    static func notationPNGFilename(epoch: Int) -> String { "ScratchNotation-\(epoch).png" }
    static func testerBundleFolderName(epoch: Int) -> String { "ScratchLab-Diagnostics-\(epoch)" }
    /// The RANE template file name (matches the previous `<identifier>.controller_profile_v1.json`).
    static let raneProfileTemplateFilename = "rane-one-mkii.controller_profile_v1.json"
}

@MainActor
final class ScratchPlaybackLabModel: ObservableObject {
    // Live readouts (published at display rate, not per-MIDI-event).
    @Published private(set) var rawPitchBend: Int = 0
    @Published private(set) var previousRawPitchBend: Int?
    @Published private(set) var wrappedDelta: Int = 0
    /// Latest CC6 step (±1) — the primary platter movement signal. 0 when idle.
    @Published private(set) var cc6Step: Int = 0
    @Published private(set) var samplePositionSeconds: TimeInterval = 0
    @Published private(set) var samplePositionFraction: Double = 0
    @Published private(set) var crossfader: Double = 0
    @Published private(set) var crossfaderRaw: Int = 0
    @Published private(set) var crossfaderChannel: Int?
    @Published private(set) var crossfaderValid = false
    @Published private(set) var eventRateHz: Double = 0
    @Published private(set) var sources: [MIDISourceInfo] = []
    @Published private(set) var isListening = false
    @Published private(set) var sampleLoaded = false
    @Published private(set) var waveformPeaks: [WaveformPeak] = []

    // QA / diagnostics (published at display rate).
    @Published private(set) var selectedSourceID: Int32?
    @Published private(set) var lastEventType: String = "—"
    @Published private(set) var pitchBendArriving = false
    @Published private(set) var crossfaderArriving = false
    @Published private(set) var playheadMoving = false
    @Published private(set) var audioRunning = false
    @Published private(set) var isAtStart = true
    @Published private(set) var isAtEnd = false

    // Scale / aliasing diagnostics.
    @Published private(set) var maxObservedDelta = 0
    @Published private(set) var aliasRisk: ScratchDeltaAliasRisk = .none
    @Published private(set) var deltaClamped = false

    // Tick-measurement ("rotate one revolution") workflow.
    @Published private(set) var isMeasuringTicks = false
    @Published private(set) var hasTickResult = false
    @Published private(set) var tickTotalSigned = 0
    @Published private(set) var tickAbsoluteSum = 0
    @Published private(set) var tickMaxDelta = 0
    @Published private(set) var tickEventCount = 0
    @Published private(set) var tickAliasObserved = false
    /// Suggested sensitivity (sample-seconds per 1000 ticks) from the last measurement.
    @Published private(set) var tickSuggestedPer1000: Double?

    // RANE diagnostic recorder (capture raw hardware events to JSON; no playback impact).
    @Published private(set) var isRecordingDiagnostics = false
    @Published private(set) var isCalibrationRecording = false
    @Published private(set) var diagnosticEventCount = 0
    @Published private(set) var diagnosticReachedCapacity = false
    @Published private(set) var diagnosticSummary: RaneDiagnosticSummary?
    @Published private(set) var lastDiagnosticExportPath: String?
    @Published private(set) var lastDiagnosticExportError: String?

    // Captured-timeline replay (Slice 9). A pure clock reviews the in-memory captured
    // timeline (play/pause/reset/scrub). It snapshots only the time bounds and never mutates
    // the timeline or any export.
    @Published private(set) var replayActive = false
    @Published private(set) var replayIsPlaying = false
    @Published private(set) var replayFraction: Double = 0
    @Published private(set) var replayCurrentTime: TimeInterval = 0
    @Published private(set) var replayDuration: TimeInterval = 0

    // Guided controller mapping check (experimental). A pure state machine walks the tester
    // through moving each control, infers candidate bindings, and lets them confirm. Held in
    // memory only — it drives no capture, persistence, or export.
    @Published private(set) var guidedMappingStep: GuidedMappingStep = .idle
    @Published private(set) var guidedCollectedCount = 0

    // Live sample-position timeline (notation is derived from real sample travel, not
    // from inferred full-stroke notes). Captured on every CC6 platter step.
    @Published private(set) var timelineEventCount = 0
    /// Span of sample actually travelled so far, `0...1` (the truthful stroke height).
    @Published private(set) var timelinePositionSpan: Double = 0
    @Published private(set) var timelineReachedCapacity = false
    @Published private(set) var lastTimelineExportPath: String?
    @Published private(set) var lastTimelineExportError: String?

    // Controller profile import/export status (Slice 7). Separate from timeline/session
    // exports; touches no existing export schema.
    @Published private(set) var lastProfileExportPath: String?
    @Published private(set) var lastProfileExportError: String?
    @Published private(set) var lastProfileImportName: String?
    @Published private(set) var lastProfileImportError: String?

    // Captured notation PNG export status (Slice 8). The image is rendered in the view via
    // the shared notation renderer; this only guards and writes the file. Does NOT touch the
    // timeline JSON export.
    @Published private(set) var lastNotationPNGExportPath: String?
    @Published private(set) var lastNotationPNGExportError: String?

    // Tester diagnostics bundle status (Slice 10). One folder of the pieces a pro-DJ tester
    // can send back. No network upload; touches no existing export schema.
    @Published private(set) var lastDiagnosticsBundlePath: String?
    @Published private(set) var lastDiagnosticsBundleError: String?

    // Config (bindable from the UI).
    @Published var selectedSourceName: String?
    /// Pitch-bend channel that drives the playhead: 0 = left platter, 1 = right.
    @Published var deckChannel: Int = 0 {
        didSet { mapper.resetTracking() } // re-seed so a stale angle can't jump
    }
    /// Position-signal mode. `.auto` mirrors Scratch Visualizer ("SV Midi Out", clean
    /// pitch-bend position) automatically and leaves the RANE on CC6; `.mirrorSV` / `.rane`
    /// are manual overrides. Changing it re-seeds tracking so nothing jumps.
    @Published var sourceMode: PlaybackLabSourceMode = .auto {
        didSet {
            mapper.resetTracking()
            velocityEstimator.reset()
            lastSVEventTimestamp = nil // re-anchor SV audio after a mode change
            cc6AudioDrive.reset() // re-anchor RANE audio after a mode change
        }
    }
    /// Sensitivity, expressed as sample-seconds moved per 1000 CC6 steps (nicer UI
    /// numbers than per-step). One platter revolution is ~3,932 CC6 steps, so the
    /// default ~0.266 maps roughly one revolution onto a ~1 s sample.
    @Published var sampleSecondsPer1000Ticks: Double = 0.5 {
        didSet { mapper.sampleSecondsPerStep = sampleSecondsPer1000Ticks / 1000.0 }
    }
    /// Lab-only: flip platter direction if the hardware reports the opposite sign.
    @Published var inverted: Bool = false {
        didSet { mapper.inverted = inverted }
    }
    /// Optional anti-explosion cap on the per-event delta applied to the playhead.
    /// Off by default so real behaviour is visible; the raw delta stays on display.
    @Published var limitDeltaForSafety: Bool = false {
        didSet {
            mapper.deltaSafetyLimit = limitDeltaForSafety ? ScratchPlatterPlayheadMapper.aliasFailThreshold : nil
        }
    }
    /// Optional, off by default: gate sample output volume by crossfader position.
    /// Only takes effect once a valid crossfader CC has been received (never mutes
    /// to silence before then).
    @Published var applyCrossfaderToVolume: Bool = false {
        didSet { applyOutputGain() }
    }
    /// Loop the sample at its boundaries (default) instead of clamping at 0/end, so
    /// continuous platter rotation keeps the sound cycling rather than sticking. Turn
    /// off for the debug clamp behaviour.
    @Published var loopPlayback: Bool = true {
        didSet {
            mapper.boundaryMode = loopPlayback ? .loop : .clamp
            engine.setLoops(loopPlayback)
        }
    }

    /// CC number observed for the crossfader readout (RANE ONE MKII = CC8). Matched on
    /// any channel so the value surfaces even if the channel assumption is off; the
    /// arriving channel is displayed (known map: raw ch 0xF).
    let crossfaderCC = 8

    var sampleDuration: TimeInterval { mapper.sampleDuration }

    /// The controller profile currently treated as active — the verified built-in RANE
    /// profile when the active source is recognized, otherwise `.unverified`. Purely
    /// derived from `selectedSourceName` + `sources` (both @Published, so the view
    /// refreshes it automatically); it stores nothing and mutates no timeline/capture/
    /// export state. Switching source (and therefore active profile) cannot alter captured
    /// data because this is read-only.
    var activeControllerProfile: ActiveControllerProfile {
        ActiveControllerProfile.resolve(
            selectedSourceName: selectedSourceName,
            availableSourceNames: sources.map(\.name)
        )
    }

    /// Warning shown when the active controller profile is unverified; nil when verified.
    /// Routed through `activeControllerProfile` so it always matches the displayed profile.
    var controllerWarning: String? {
        activeControllerProfile.warning
    }

    /// Whether the lab is (or will be) mirroring Scratch Visualizer's pitch-bend position
    /// rather than driving the playhead from CC6. True when forced, or in Auto when an SV
    /// source is selected/available. Display-only hint; the per-event decision is authoritative.
    var isMirroringScratchVisualizer: Bool {
        switch sourceMode {
        case .mirrorSV: return true
        case .rane: return false
        case .auto:
            if ScratchVisualizerMirror.isScratchVisualizerSource(name: selectedSourceName) { return true }
            return selectedSourceName == nil
                && sources.contains { ScratchVisualizerMirror.isScratchVisualizerSource(name: $0.name) }
        }
    }

    private var mapper: ScratchPlatterPlayheadMapper
    private let engine = ScratchPlaybackLabEngine()
    private let transport: CoreMIDIInputTransport
    private var displayTimer: Timer?
    private let rateWindow: TimeInterval = 1.0
    private let arrivingWindow: TimeInterval = 0.5
    /// A gap longer than this between platter events means the platter effectively
    /// stopped; re-seed tracking so the next event moves relative to the current angle.
    private let idleResetInterval: TimeInterval = 0.1

    // Latest values stashed on the MIDI path; copied into @Published at display rate.
    private var rawPitchBendLatest: Int = 0
    private var previousRawLatest: Int?
    private var wrappedDeltaLatest: Int = 0
    private var crossfaderLatest: Double = 0
    private var crossfaderRawLatest: Int = 0
    private var crossfaderChannelLatest: Int?
    private var crossfaderValidLatest = false
    private var lastEventTypeLatest = "—"
    // Wall-clock event stamps for rate and "arriving" liveness (pruned each tick).
    private var pitchBendEventDates: [Date] = []
    private var lastPitchBendDate: Date?
    private var lastCrossfaderDate: Date?
    private var lastPublishedPosition: TimeInterval = 0
    private var measurement = PlatterTickMeasurement()
    /// Smooths CC6 step rate into a continuous scrub velocity (sample-seconds/sec) the
    /// audio engine integrates, so playback stays smooth across bursty MIDI delivery.
    private var velocityEstimator = ScratchScrubVelocityEstimator()
    /// Gap (real time) with no platter events after which playback glides to a stop.
    private let velocityIdleTimeout: TimeInterval = 0.18
    private var recorder = RaneDiagnosticRecorder()
    private var recordingStartDate: Date?
    /// Controller profile persistence store (Application Support/ScratchLab/ControllerProfiles).
    private let profileStore = ControllerProfileStore(directory: ScratchPlaybackLabModel.controllerProfilesDirectory)
    /// Live sample-position travel capture. Appended on each CC6 step using the real
    /// sample position the platter reached, so notation can be derived from actual travel.
    private var timeline = ScratchSampleTimeline()
    /// Latest CC6 value (platter companion stream) — the primary platter movement signal.
    /// Stashed on the MIDI path; also attached to each recorded diagnostic event.
    private var lastCC6Value: Int?
    /// Latest signed CC6 step (±1), published at display rate for the lab readout.
    private var lastCC6StepLatest: Int = 0
    /// Wall-clock time of the last platter event (either stream); drives idle re-seed.
    private var lastPlatterEventDate: Date?
    /// Guided mapping check state machine (experimental; memory only). The MIDI path feeds
    /// it parsed events while collecting; step transitions happen on explicit user actions.
    private var guidedSession = GuidedMappingSession()
    /// Real (CoreMIDI) timestamp of the previous Scratch Visualizer pitch-bend event, used to
    /// glide the audio at the instantaneous rate between SV position samples. nil = re-anchor.
    private var lastSVEventTimestamp: TimeInterval?
    /// Windowed-rate driver for RANE CC6 audio: converts bursty platter events into a stable
    /// signed rate over a short real-time window so slow rotation can't spike to near-1×.
    private var cc6AudioDrive = ScratchPlatterAudioDrive()
    /// Captured-timeline replay clock (review only); advanced by the display tick.
    private var replay = CapturedTimelineReplay(timeline: ScratchSampleTimeline())
    /// Wall-clock time of the last replay advance, for the real-time delta.
    private var lastReplayTickDate: Date?

    init(transport: CoreMIDIInputTransport = CoreMIDIInputTransport()) {
        self.transport = transport
        self.mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerStep: 0.5 / 1000.0,
                                                   sampleDuration: 0, boundaryMode: .loop)
        transport.onSourcedEvent = { [weak self] sourceName, event in
            MainActor.assumeIsolated { self?.ingest(sourceName: sourceName, event: event) }
        }
        transport.onSourcesChanged = { [weak self] infos in
            MainActor.assumeIsolated { self?.sources = infos }
        }
    }

    // MARK: - Lifecycle

    func start() {
        loadSampleIfNeeded()
        clearTimeline()
        engine.setLoops(loopPlayback)
        transport.start()
        isListening = transport.isRunning
        engine.start()
        audioRunning = engine.isRunning
        applyOutputGain()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishDisplayState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        transport.stop()
        engine.stop()
        isListening = false
    }

    // MARK: - Actions

    /// Returns the playhead to the start of the sample and re-seeds tracking so the
    /// next platter event moves relative to the current angle (no jump).
    func resetPlayhead() {
        mapper.resetPosition()
        mapper.resetTracking()
        velocityEstimator.reset()
        lastSVEventTimestamp = nil
        cc6AudioDrive.reset()
        engine.setVelocity(0)
        engine.setTargetPosition(seconds: mapper.samplePosition) // seek/snap to 0
        clearTimeline()
    }

    /// Discards the captured sample-position timeline (the travel record), starting a
    /// fresh capture. Does not touch the playhead or audio.
    func clearTimeline() {
        timeline.clear()
        timelineEventCount = 0
        timelinePositionSpan = 0
        timelineReachedCapacity = false
    }

    /// Notation geometry derived from the live captured timeline — the absolute
    /// sample-position path the preview renders (0 = sample start / rest edge,
    /// 1 = sample end / full travel; partial travel is NOT renormalised). Pure
    /// and derived; nothing is persisted and no export schema is touched. The
    /// preview reads this on each redraw; `timelineEventCount` is the published
    /// trigger that drives those redraws while scratching.
    var timelineNotation: ScratchSampleTimelineNotation {
        ScratchSampleTimelineNotation(timeline: timeline)
    }

    /// Writes the currently held sample-position timeline as JSON to a user-selected
    /// destination `url` (chosen via a save panel, so it is sandbox-safe — the app only
    /// writes where the user pointed it, never blindly to ~/Downloads). Explicit user action
    /// only. The raw travel is enough to regenerate notation later; no strokes are invented.
    /// Errors surface via `lastTimelineExportError`, success via `lastTimelineExportPath`.
    func exportTimeline(to url: URL) {
        lastTimelineExportError = nil
        guard !timeline.isEmpty else {
            lastTimelineExportPath = nil
            lastTimelineExportError = "No timeline events to export."
            return
        }
        let export = ScratchSampleTimelineExport(
            timeline: timeline,
            exportedAtEpochSeconds: Date().timeIntervalSince1970
        )
        do {
            let data = try export.jsonData()
            try data.write(to: url, options: .atomic)
            lastTimelineExportPath = url.path
        } catch {
            lastTimelineExportPath = nil
            lastTimelineExportError = error.localizedDescription
        }
    }

    /// Clears the running max-observed-delta / alias diagnostic.
    func resetMaxDelta() {
        mapper.resetMaxObservedDelta()
    }

    // MARK: - Controller profile import / export

    /// Application Support directory for saved controller profiles.
    static var controllerProfilesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScratchLab/ControllerProfiles", isDirectory: true)
    }

    /// Exports the built-in RANE profile as a `controller_profile_v1` JSON template to a
    /// user-selected destination `url` (chosen via a save panel; sandbox-safe). A tester can
    /// edit it and send it back. Explicit user action; never automatic.
    func exportRaneProfileTemplate(to url: URL) {
        lastProfileExportError = nil
        do {
            let data = try ControllerProfileStore.encodeDocument(.raneOneMKII)
            try data.write(to: url, options: .atomic)
            lastProfileExportPath = url.path
        } catch {
            lastProfileExportPath = nil
            lastProfileExportError = error.localizedDescription
        }
    }

    /// Imports a controller profile from a file URL: validates it (fails closed on unknown
    /// format/version), and persists custom profiles to the store. The built-in RANE profile
    /// cannot be overwritten. Touches no timeline/session export schema.
    func importProfile(from url: URL) {
        lastProfileImportError = nil
        lastProfileImportName = nil
        do {
            let profile = try profileStore.load(at: url)
            if ControllerProfileStore.builtInIdentifiers.contains(profile.identifier) {
                // Valid file, but it is the read-only built-in — surface it without saving.
                lastProfileImportName = "\(profile.displayName) (built-in — not overwritten)"
            } else {
                try profileStore.save(profile)
                lastProfileImportName = profile.displayName
            }
        } catch {
            lastProfileImportError = error.localizedDescription
        }
    }

    // MARK: - Tester diagnostics bundle

    /// The controller profile actually in effect (built-in RANE constants drive the lab even
    /// when the active source is unverified).
    private var effectiveProfile: ControllerProfile {
        if case .builtIn(let profile) = activeControllerProfile { return profile }
        return .raneOneMKII
    }

    /// Builds and writes a tester diagnostics bundle as a folder at the user-selected
    /// destination `folderURL` (chosen via a save panel; sandbox-safe — the folder is created
    /// exactly where the user pointed it). Contents: the captured timeline JSON (if any), the
    /// RANE diagnostic JSON (if any), the controller profile in effect, app/build info,
    /// detected MIDI source info, and a README. No network upload; no existing export schema
    /// is touched. Explicit user action only.
    func exportTesterDiagnostics(toFolder folderURL: URL) {
        lastDiagnosticsBundleError = nil
        let now = Date()
        let timelineJSON = timeline.isEmpty
            ? nil
            : try? ScratchSampleTimelineExport(timeline: timeline, exportedAtEpochSeconds: now.timeIntervalSince1970).jsonData()
        let raneJSON = recorder.events.isEmpty
            ? nil
            : try? RaneDiagnosticSessionExport(events: recorder.events, isCalibration: recorder.isCalibration, exportedAtEpochSeconds: now.timeIntervalSince1970).jsonData()
        do {
            let profileJSON = try ControllerProfileStore.encodeDocument(effectiveProfile)
            let bundle = TesterDiagnosticsBundle(
                timelineJSON: timelineJSON,
                raneDiagnosticJSON: raneJSON,
                controllerProfileJSON: profileJSON,
                appBuildInfo: Self.appBuildInfoText(),
                midiSourceInfo: midiSourceInfoText(),
                readme: Self.testerReadmeText()
            )
            // Reuse the tested bundle writer: create the user-chosen folder and write into it.
            let folder = try bundle.write(
                to: folderURL.deletingLastPathComponent(),
                folderName: folderURL.lastPathComponent
            )
            lastDiagnosticsBundlePath = folder.path
        } catch {
            lastDiagnosticsBundlePath = nil
            lastDiagnosticsBundleError = error.localizedDescription
        }
    }

    /// App name / version / build and OS version for the bundle (no user identifiers).
    private static func appBuildInfoText() -> String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "ScratchLab"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        App: \(name)
        Version: \(version) (build \(build))
        macOS: \(os)
        """
    }

    /// Detected MIDI source info + active profile context for the bundle.
    private func midiSourceInfoText() -> String {
        let sourceLines = sources.isEmpty
            ? "  (none connected)"
            : sources.map { "  - \($0.name) (id \($0.id))" }.joined(separator: "\n")
        let warning = controllerWarning.map { "\nWarning: \($0)" } ?? ""
        return """
        Selected source: \(selectedSourceName ?? "All sources")
        Active controller profile: \(activeControllerProfile.displayName)
        Available MIDI sources:
        \(sourceLines)\(warning)
        """
    }

    /// PROFILE.md-safe README describing the bundle for a tester.
    private static func testerReadmeText() -> String {
        """
        ScratchLab — tester diagnostics bundle

        This folder contains an estimated, on-device capture from the Scratch Playback Lab,
        for review by the ScratchLab team. It contains no account details and no audio.

        Files (present only when captured):
        - ScratchTimeline.json   Captured sample-position travel (the notation preview source).
        - RaneDiagnostic.json    Raw platter diagnostic events, if a recording was made.
        - ControllerProfile.json The controller mapping ScratchLab applied (controller_profile_v1).
        - app-build-info.txt     App version / build / macOS version.
        - midi-source-info.txt   Detected MIDI sources and the active profile.

        Notes:
        - Captured notation is an estimated preview, not a scored result.
        - Nothing here is uploaded anywhere; you choose what to send back.
        """
    }

    // MARK: - Captured-timeline replay (review only)

    /// Begins a replay session over a snapshot of the current captured timeline and starts
    /// playing. Does nothing useful (zero-duration) if fewer than two samples are captured.
    func startReplay() {
        replay = CapturedTimelineReplay(timeline: timeline)
        replay.play()
        replayActive = true
        lastReplayTickDate = Date()
        publishReplayState()
    }

    /// Toggles play/pause on the active replay (no-op if no replay session).
    func toggleReplayPlayback() {
        guard replayActive else { return }
        if replay.isPlaying {
            replay.pause()
        } else {
            replay.play()
            lastReplayTickDate = Date()
        }
        publishReplayState()
    }

    /// Returns the replay playhead to the start and pauses.
    func resetReplay() {
        replay.reset()
        lastReplayTickDate = nil
        publishReplayState()
    }

    /// Scrubs the replay playhead to a fraction `0...1` of the captured span.
    func seekReplay(toFraction fraction: Double) {
        guard replayActive else { return }
        replay.seek(toFraction: fraction)
        lastReplayTickDate = Date()
        publishReplayState()
    }

    /// Ends the replay session (clears the review overlay).
    func endReplay() {
        replayActive = false
        replay.pause()
        lastReplayTickDate = nil
        publishReplayState()
    }

    private func publishReplayState() {
        replayIsPlaying = replay.isPlaying
        replayFraction = replay.fraction
        replayCurrentTime = replay.currentTime - replay.startTime
        replayDuration = replay.duration
    }

    // MARK: - Captured notation PNG export

    /// Writes a pre-rendered captured-notation PNG to a user-selected destination `url`
    /// (chosen via a save panel; sandbox-safe). The image is rendered in the view (SwiftUI
    /// ImageRenderer) from the same notation/renderer as the live preview, so absolute
    /// positions stay truthful. Guards an empty timeline and a nil/empty render. Does not
    /// touch the timeline JSON export. Explicit user action only.
    func exportCapturedNotationPNG(_ pngData: Data?, to url: URL) {
        lastNotationPNGExportError = nil
        guard !timeline.isEmpty else {
            lastNotationPNGExportPath = nil
            lastNotationPNGExportError = "No captured notation to export."
            return
        }
        guard let pngData, !pngData.isEmpty else {
            lastNotationPNGExportPath = nil
            lastNotationPNGExportError = "Could not render the captured notation image."
            return
        }
        do {
            try pngData.write(to: url, options: .atomic)
            lastNotationPNGExportPath = url.path
        } catch {
            lastNotationPNGExportPath = nil
            lastNotationPNGExportError = error.localizedDescription
        }
    }

    // MARK: - Guided controller mapping check (experimental; memory only)

    /// Starts the guided mapping check at its first step (spin the platter).
    func startGuidedMapping() {
        guidedSession.start()
        guidedMappingStep = guidedSession.step
        guidedCollectedCount = guidedSession.collected.count
    }

    /// Advances the guided mapping check: platter step → crossfader step → inference review
    /// → confirm. Inference runs when leaving the crossfader step.
    func advanceGuidedMapping() {
        guidedSession.advance()
        guidedMappingStep = guidedSession.step
        guidedCollectedCount = guidedSession.collected.count
    }

    /// Cancels the guided mapping check and clears its in-memory collection.
    func cancelGuidedMapping() {
        guidedSession.cancel()
        guidedMappingStep = guidedSession.step
        guidedCollectedCount = 0
    }

    // MARK: - Tick measurement ("rotate one revolution")

    /// Begins accumulating wrapped per-event deltas. Re-seeds tracking so the first
    /// event during measurement does not record a giant delta from a stale angle.
    func startTickMeasurement() {
        measurement = PlatterTickMeasurement()
        isMeasuringTicks = true
        hasTickResult = false
        mapper.resetTracking()
        publishTickState()
    }

    /// Stops accumulating and freezes the measured result.
    func finishTickMeasurement() {
        isMeasuringTicks = false
        hasTickResult = measurement.eventCount > 0
        publishTickState()
    }

    private func publishTickState() {
        tickTotalSigned = measurement.totalSignedTicks
        tickAbsoluteSum = measurement.absoluteTickSum
        tickMaxDelta = measurement.maxPerEventDelta
        tickEventCount = measurement.eventCount
        tickAliasObserved = measurement.aliasObserved
        // Suggest a sensitivity that maps one measured revolution to the whole sample.
        if let perTick = measurement.suggestedSampleSecondsPerTick(targetSeconds: max(mapper.sampleDuration, 0.001)) {
            tickSuggestedPer1000 = perTick * 1000.0
        } else {
            tickSuggestedPer1000 = nil
        }
    }

    // MARK: - RANE diagnostic recording

    /// Begins capturing raw platter pitch-bend events to memory. Pass `calibration: true`
    /// for a one-revolution run (drives the ticks-per-revolution estimate). Capture is
    /// in-memory only; nothing is written to disk until `exportDiagnostics()`.
    func startDiagnosticRecording(calibration: Bool = false) {
        recorder.start(calibration: calibration)
        recordingStartDate = Date()
        isRecordingDiagnostics = true
        isCalibrationRecording = calibration
        diagnosticEventCount = 0
        diagnosticReachedCapacity = false
        diagnosticSummary = nil
        lastDiagnosticExportError = nil
    }

    /// Stops capturing and freezes the summary. Captured events remain available for
    /// export until the next `startDiagnosticRecording`.
    func stopDiagnosticRecording() {
        recorder.stop()
        isRecordingDiagnostics = false
        diagnosticEventCount = recorder.events.count
        diagnosticReachedCapacity = recorder.didReachCapacity
        diagnosticSummary = recorder.summary
    }

    /// Writes the captured RANE diagnostic session as JSON to a user-selected destination
    /// `url` (chosen via a save panel; sandbox-safe). Explicit user action only — never called
    /// automatically. Errors surface via `lastDiagnosticExportError`; success via
    /// `lastDiagnosticExportPath`.
    func exportDiagnostics(to url: URL) {
        lastDiagnosticExportError = nil
        guard !recorder.events.isEmpty else {
            lastDiagnosticExportPath = nil
            lastDiagnosticExportError = "No diagnostic events to export."
            return
        }
        let export = RaneDiagnosticSessionExport(
            events: recorder.events,
            isCalibration: recorder.isCalibration,
            exportedAtEpochSeconds: Date().timeIntervalSince1970
        )
        do {
            let data = try export.jsonData()
            try data.write(to: url, options: .atomic)
            lastDiagnosticExportPath = url.path
        } catch {
            lastDiagnosticExportPath = nil
            lastDiagnosticExportError = error.localizedDescription
        }
    }

    // MARK: - Gain

    /// Applies the lab output gain: crossfader position when gating is on AND a valid
    /// crossfader value has been received; full gain otherwise (never mutes blindly).
    private func applyOutputGain() {
        engine.setOutputGain(
            ScratchPlatterPlayheadMapper.outputGain(
                applyGating: applyCrossfaderToVolume,
                crossfaderValid: crossfaderValidLatest,
                crossfader: crossfaderLatest
            )
        )
    }

    // MARK: - Sample

    private func loadSampleIfNeeded() {
        guard !sampleLoaded else { return }
        let loaded = engine.loadSample()
        sampleLoaded = loaded
        guard loaded else { return }
        mapper.sampleDuration = engine.duration
        waveformPeaks = WaveformPeak.peaks(from: engine.monoSamples, binCount: 1200)
    }

    // MARK: - MIDI ingest (per-event; cheap, no @Published writes)

    private func ingest(sourceName: String, event: MIDIRawEvent) {
        if let selected = selectedSourceName, selected != sourceName { return }
        let parsed = MIDIMessageParsing.parse(event.bytes)
        lastEventTypeLatest = parsed.messageType.displayName

        // Feed the guided mapping check while it is collecting (no @Published writes here;
        // the live count surfaces at display rate). Independent of capture/playback below.
        guidedSession.record(parsed)

        switch parsed.messageType {
        case .controlChange where parsed.controlNumber == 6
            && !ScratchVisualizerMirror.isActive(mode: sourceMode, sourceName: sourceName):
            // PRIMARY platter driver (RANE): CC6 is a clean ±1 direction/step counter that
            // does not alias (unlike the pitch bend). Each step advances the playhead. Skipped
            // while mirroring Scratch Visualizer, whose position comes from pitch bend instead.
            guard let value = parsed.value else { return }
            reseedIfIdle()
            let wasSeeded = mapper.lastCC6Value != nil
            let step = mapper.ingestCC6(value)
            lastCC6Value = value
            lastCC6StepLatest = step
            // Drive the engine from the RAW instantaneous rate (immediate, and drift-free
            // per segment since rate·dt == moved), re-anchoring to the mapper's absolute
            // position after an idle gap — the same model the SV path uses below. Uses the
            // REAL CoreMIDI event timestamp — not Date() — so the rate is accurate. The EMA
            // estimator is still fed, but ONLY for the timeline's direction sign (below),
            // never the audio rate, so playback is not smeared or lagged.
            let moved = Double(inverted ? -step : step) * mapper.sampleSecondsPerStep
            switch cc6AudioDrive.ingest(moved: moved, at: event.timestamp) {
            case .glide(let rate): engine.setVelocity(rate)
            case .anchor: engine.setTargetPosition(seconds: mapper.samplePosition)
            }
            velocityEstimator.ingest(sampleSeconds: moved, at: event.timestamp)
            // Capture the real sample position the platter reached, so notation can be
            // derived from actual travel rather than inferred full-stroke notes. Only on
            // a true move (skip the seeding event, which does not advance the playhead).
            if wasSeeded {
                timeline.append(
                    timeSeconds: event.timestamp,
                    position: mapper.positionFraction,
                    velocity: velocityEstimator.velocity,
                    crossfader: crossfaderValidLatest ? crossfaderLatest : nil,
                    cc6Step: step
                )
            }
            // Tick measurement now counts CC6 steps over one revolution (~3,932).
            if isMeasuringTicks, wasSeeded {
                measurement.record(delta: step)
            }
            lastPlatterEventDate = Date()

        case .pitchBend where ScratchVisualizerMirror.isActive(mode: sourceMode, sourceName: sourceName):
            // SCRATCH VISUALIZER MIRROR: SV's clean 14-bit pitch bend is an ABSOLUTE sample
            // position (8192 = start, 16383 = end). Seek the playhead there and capture it so
            // the same timeline / notation / replay / PNG pipeline mirrors SV. RANE hardware
            // never reaches this branch in Auto (its platter pitch bend aliases — it stays
            // CC6-driven below). SV has no crossfader, so the segment is left open (nil),
            // never marked muted.
            guard let raw = parsed.value else { return }
            let svNow = Date()
            let lastFraction = mapper.positionFraction
            let fraction = ScratchVisualizerMirror.positionFraction(pitchBend: raw)
            mapper.seek(toPositionFraction: fraction)
            // AUDIO: glide at the INSTANTANEOUS rate (ΔP / Δt) between SV position samples.
            // SV emits ~56 events/sec (~17 ms apart) — sparser than the ~12 ms audio quantum —
            // so snapping to each position would gate the audio into a machine-gun chop. A
            // continuous glide at the exact per-segment rate fills the gaps smoothly AND stays
            // locked to SV's position (per-segment displacement = ΔP, no drift). Raw, not
            // EMA-smoothed, so fast reversals are not smeared. After an idle gap we re-anchor
            // (snap-seek, no glide) so a resume doesn't start from a stale spot.
            let svMoved = (fraction - lastFraction) * mapper.sampleDuration
            if let last = lastSVEventTimestamp {
                let dt = event.timestamp - last
                if dt > 0 && dt <= velocityIdleTimeout {
                    engine.setVelocity(svMoved / dt)
                } else {
                    engine.setVelocity(0)
                    engine.setTargetPosition(seconds: mapper.samplePosition) // re-anchor
                }
            } else {
                engine.setTargetPosition(seconds: mapper.samplePosition) // first event: anchor
            }
            lastSVEventTimestamp = event.timestamp
            // Smoothed velocity kept only for the timeline's direction sign / notation.
            let svVelocity = velocityEstimator.ingest(sampleSeconds: svMoved, at: event.timestamp)
            // Diagnostic readout (tracking does NOT move the playhead — the seek above did).
            previousRawLatest = mapper.lastRawPitchBend
            mapper.trackPitchBend(raw)
            rawPitchBendLatest = raw
            wrappedDeltaLatest = mapper.lastWrappedDelta
            lastCC6StepLatest = 0
            pitchBendEventDates.append(svNow)
            lastPitchBendDate = svNow
            lastPlatterEventDate = svNow
            timeline.append(
                timeSeconds: event.timestamp,
                position: mapper.positionFraction,
                velocity: svVelocity,
                crossfader: nil,
                cc6Step: nil
            )
            // SV can be recorded too (this is how SV diagnostic captures are made).
            if isRecordingDiagnostics {
                let elapsed = recordingStartDate.map { svNow.timeIntervalSince($0) } ?? 0
                recorder.record(RaneDiagnosticEvent(
                    timestamp: elapsed,
                    rawPitchBend: raw,
                    previousRawPitchBend: previousRawLatest,
                    wrappedDelta: mapper.lastWrappedDelta,
                    samplePositionSeconds: mapper.samplePosition,
                    crossfader: nil,
                    cc6: nil,
                    deck: parsed.channel ?? deckChannel,
                    sourceName: sourceName,
                    hostTime: event.timestamp
                ))
            }

        case .pitchBend where ScratchPlatterPlayheadMapper.isPitchBendChannel(parsed.channel, forDeck: deckChannel):
            // Pitch bend is DIAGNOSTIC ONLY for the RANE — it no longer moves the playhead
            // (CC6 does). Tracked for the readout and the diagnostic recording.
            guard let raw = parsed.value else { return }
            reseedIfIdle()
            previousRawLatest = mapper.lastRawPitchBend
            mapper.trackPitchBend(raw)
            rawPitchBendLatest = raw
            wrappedDeltaLatest = mapper.lastWrappedDelta
            let now = Date()
            pitchBendEventDates.append(now)
            lastPitchBendDate = now
            lastPlatterEventDate = now
            // Diagnostic capture (no @Published writes here — surfaced at display rate).
            if isRecordingDiagnostics {
                let elapsed = recordingStartDate.map { now.timeIntervalSince($0) } ?? 0
                recorder.record(RaneDiagnosticEvent(
                    timestamp: elapsed,
                    rawPitchBend: raw,
                    previousRawPitchBend: previousRawLatest,
                    wrappedDelta: mapper.lastWrappedDelta,
                    samplePositionSeconds: mapper.samplePosition,
                    crossfader: crossfaderValidLatest ? crossfaderLatest : nil,
                    cc6: lastCC6Value,
                    deck: deckChannel,
                    sourceName: sourceName,
                    hostTime: event.timestamp
                ))
            }

        case .controlChange where parsed.controlNumber == crossfaderCC:
            if let value = parsed.value {
                crossfaderLatest = ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: value)
                crossfaderRawLatest = value
                crossfaderChannelLatest = parsed.channel
                crossfaderValidLatest = true
                lastCrossfaderDate = Date()
                if applyCrossfaderToVolume { applyOutputGain() }
            }

        default:
            break
        }
    }

    /// Re-seed tracking after an idle gap so a resume moves relative to the current
    /// position rather than producing a jump from a stale value.
    private func reseedIfIdle() {
        if let last = lastPlatterEventDate, Date().timeIntervalSince(last) > idleResetInterval {
            mapper.resetTracking()
        }
    }

    // MARK: - Display publish (≈60 Hz)

    private func publishDisplayState() {
        let now = Date()

        // Glide to a stop if the platter stream has gone quiet (no events to refresh
        // velocity). The envelope fades out smoothly when velocity reaches 0.
        if let last = lastPlatterEventDate, now.timeIntervalSince(last) > velocityIdleTimeout,
           velocityEstimator.velocity != 0 {
            velocityEstimator.reset()
            engine.setVelocity(0)
        }

        rawPitchBend = rawPitchBendLatest
        previousRawPitchBend = previousRawLatest
        wrappedDelta = wrappedDeltaLatest
        cc6Step = lastCC6StepLatest
        samplePositionSeconds = mapper.samplePosition
        samplePositionFraction = mapper.positionFraction
        isAtStart = mapper.isAtStart
        isAtEnd = mapper.isAtEnd

        maxObservedDelta = mapper.maxObservedDelta
        aliasRisk = ScratchPlatterPlayheadMapper.aliasRisk(forDelta: mapper.maxObservedDelta)
        deltaClamped = mapper.lastDeltaClamped
        if isMeasuringTicks { publishTickState() }

        crossfader = crossfaderLatest
        crossfaderRaw = crossfaderRawLatest
        crossfaderChannel = crossfaderChannelLatest
        crossfaderValid = crossfaderValidLatest

        lastEventType = lastEventTypeLatest
        selectedSourceID = sources.first { $0.name == selectedSourceName }?.id
        audioRunning = engine.isRunning

        // Event rate over the sliding window (wall-clock pruned so it decays to 0).
        pitchBendEventDates.removeAll { now.timeIntervalSince($0) > rateWindow }
        eventRateHz = Double(pitchBendEventDates.count) / rateWindow

        pitchBendArriving = lastPitchBendDate.map { now.timeIntervalSince($0) < arrivingWindow } ?? false
        crossfaderArriving = lastCrossfaderDate.map { now.timeIntervalSince($0) < arrivingWindow } ?? false

        // Playhead is "moving" if the position changed since the last publish.
        playheadMoving = abs(mapper.samplePosition - lastPublishedPosition) > 1.0e-6
        lastPublishedPosition = mapper.samplePosition

        // Sample-position timeline: surface live travel stats (the MIDI path never
        // writes @Published state). Notation will later be derived from this capture.
        timelineEventCount = timeline.count
        timelinePositionSpan = timeline.positionSpan
        timelineReachedCapacity = timeline.didReachCapacity

        // Guided mapping check: surface the live collected-event count while collecting.
        if guidedSession.isCollecting {
            guidedCollectedCount = guidedSession.collected.count
        }

        // Captured-timeline replay: advance the playhead by the real elapsed delta.
        if replayActive, replay.isPlaying {
            let last = lastReplayTickDate ?? now
            replay.tick(deltaSeconds: now.timeIntervalSince(last))
            lastReplayTickDate = now
            publishReplayState()
        }

        // Diagnostic recorder: surface live count and reflect an auto-stop at capacity
        // (the MIDI path never writes @Published state).
        diagnosticEventCount = recorder.events.count
        if isRecordingDiagnostics, !recorder.isRecording {
            isRecordingDiagnostics = false
            diagnosticReachedCapacity = recorder.didReachCapacity
            diagnosticSummary = recorder.summary
        }
    }
}
#endif
