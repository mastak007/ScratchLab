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

    // Config (bindable from the UI).
    @Published var selectedSourceName: String?
    /// Pitch-bend channel that drives the playhead: 0 = left platter, 1 = right.
    @Published var deckChannel: Int = 0 {
        didSet { mapper.resetTracking() } // re-seed so a stale angle can't jump
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
    /// Latest CC6 value (platter companion stream) — the primary platter movement signal.
    /// Stashed on the MIDI path; also attached to each recorded diagnostic event.
    private var lastCC6Value: Int?
    /// Latest signed CC6 step (±1), published at display rate for the lab readout.
    private var lastCC6StepLatest: Int = 0
    /// Wall-clock time of the last platter event (either stream); drives idle re-seed.
    private var lastPlatterEventDate: Date?

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
        engine.setVelocity(0)
        engine.setTargetPosition(seconds: mapper.samplePosition) // seek/snap to 0
    }

    /// Clears the running max-observed-delta / alias diagnostic.
    func resetMaxDelta() {
        mapper.resetMaxObservedDelta()
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

    /// Writes the captured session to a timestamped JSON file in ~/Downloads. Explicit
    /// user action only — never called automatically. Errors are surfaced via
    /// `lastDiagnosticExportError`; success via `lastDiagnosticExportPath`.
    func exportDiagnostics() {
        lastDiagnosticExportError = nil
        guard !recorder.events.isEmpty else {
            lastDiagnosticExportPath = nil
            lastDiagnosticExportError = "No diagnostic events to export."
            return
        }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            lastDiagnosticExportPath = nil
            lastDiagnosticExportError = "Could not locate the Downloads folder."
            return
        }
        let now = Date()
        let export = RaneDiagnosticSessionExport(
            events: recorder.events,
            isCalibration: recorder.isCalibration,
            exportedAtEpochSeconds: now.timeIntervalSince1970
        )
        let url = downloads.appendingPathComponent("RaneDiagnostic-\(Int(now.timeIntervalSince1970)).json")
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

        switch parsed.messageType {
        case .controlChange where parsed.controlNumber == 6:
            // PRIMARY platter driver: CC6 is a clean ±1 direction/step counter that does
            // not alias (unlike the pitch bend). Each step advances the playhead.
            guard let value = parsed.value else { return }
            reseedIfIdle()
            let wasSeeded = mapper.lastCC6Value != nil
            let step = mapper.ingestCC6(value)
            lastCC6Value = value
            lastCC6StepLatest = step
            // Drive the engine by continuous velocity (smooth across bursts), using the
            // REAL CoreMIDI event timestamp — not Date() — so the rate is accurate.
            let moved = Double(inverted ? -step : step) * mapper.sampleSecondsPerStep
            velocityEstimator.ingest(sampleSeconds: moved, at: event.timestamp)
            engine.setVelocity(velocityEstimator.velocity)
            // Tick measurement now counts CC6 steps over one revolution (~3,932).
            if isMeasuringTicks, wasSeeded {
                measurement.record(delta: step)
            }
            lastPlatterEventDate = Date()

        case .pitchBend where ScratchPlatterPlayheadMapper.isPitchBendChannel(parsed.channel, forDeck: deckChannel):
            // Pitch bend is DIAGNOSTIC ONLY now — it no longer moves the playhead (CC6
            // does). Tracked for the readout and the diagnostic recording.
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
