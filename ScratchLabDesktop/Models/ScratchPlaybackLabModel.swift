#if os(macOS)
import Foundation
import Combine

// Scratch Playback Lab (first slice): macOS view model.
//
// Scope guardrails (deliberate):
// - Display + isolated playback only. Owns a `CoreMIDIInputTransport` (input-only,
//   same pattern as the Controller Inspector), the pure platter integrator
//   (`ScratchPlatterPlayheadMapper`), and the isolated `ScratchPlaybackLabEngine`.
//   It writes nothing to disk or to any device, and changes no existing behaviour.
// - NOT notation, NOT replay, NOT coaching, NOT capture/scoring/export. The
//   crossfader is read for display only; audio is not gated by it in this slice.
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
    @Published private(set) var rawPitchBend: Int = ScratchPlatterPlayheadMapper.defaultMotorBaseline
    @Published private(set) var platterRate: Double = 0
    @Published private(set) var samplePositionSeconds: TimeInterval = 0
    @Published private(set) var samplePositionFraction: Double = 0
    @Published private(set) var crossfader: Double = 0
    @Published private(set) var crossfaderRaw: Int = 0
    @Published private(set) var crossfaderChannel: Int?
    @Published private(set) var hasCrossfader = false
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
    /// Whether the *current* deck's baseline has been calibrated live (vs the fallback hint).
    @Published private(set) var baselineCalibrated = false

    // Config (bindable from the UI).
    @Published var selectedSourceName: String?
    /// Pitch-bend channel that drives the playhead: 0 = left platter, 1 = right.
    @Published var deckChannel: Int = 0 {
        didSet { loadDeckConfig(deckChannel) }
    }
    @Published var baseline: Int = ScratchPlatterPlayheadMapper.defaultMotorBaseline {
        didSet { mapper.calibrate(toBaseline: baseline) }
    }
    @Published var rateScale: Double = 1.0 / 4096.0 {
        didSet { mapper.rateScale = rateScale }
    }
    /// Pitch-bend units of dead zone around baseline; absorbs idle motor jitter.
    @Published var velocityDeadband: Int = 16 {
        didSet { mapper.velocityDeadband = velocityDeadband }
    }
    /// Lab-only: flip platter direction if the hardware reports the opposite sign.
    @Published var inverted: Bool = false {
        didSet { mapper.inverted = inverted }
    }
    /// Optional, off by default: gate sample output volume by crossfader position.
    @Published var applyCrossfaderToVolume: Bool = false {
        didSet { applyOutputGain() }
    }

    /// CC number observed for the crossfader readout (RANE ONE MKII = CC8). Matched on
    /// any channel so the value surfaces even if the channel assumption is off; the
    /// arriving channel is displayed (known map: raw ch 0xF).
    let crossfaderCC = 8

    var sampleDuration: TimeInterval { mapper.sampleDuration }

    private var mapper: ScratchPlatterPlayheadMapper
    private let engine = ScratchPlaybackLabEngine()
    private let transport: CoreMIDIInputTransport
    private var lastEventTimestamp: TimeInterval?
    private var displayTimer: Timer?
    private let rateWindow: TimeInterval = 1.0
    private let arrivingWindow: TimeInterval = 0.5

    // Per-deck baseline state (index by deck: 0 = left, 1 = right).
    private var deckBaselines: [Int] = [
        ScratchPlatterPlayheadMapper.defaultMotorBaseline,
        ScratchPlatterPlayheadMapper.defaultMotorBaseline,
    ]
    private var deckBaselineCalibrated: [Bool] = [false, false]

    // Latest values stashed on the MIDI path; copied into @Published at display rate.
    private var rawPitchBendLatest = ScratchPlatterPlayheadMapper.defaultMotorBaseline
    private var platterRateLatest: Double = 0
    private var crossfaderLatest: Double = 0
    private var crossfaderRawLatest: Int = 0
    private var crossfaderChannelLatest: Int?
    private var hasCrossfaderLatest = false
    private var lastEventTypeLatest = "—"
    // Wall-clock event stamps for rate and "arriving" liveness (pruned each tick).
    private var pitchBendEventDates: [Date] = []
    private var lastPitchBendDate: Date?
    private var lastCrossfaderDate: Date?
    private var lastPublishedPosition: TimeInterval = 0

    init(transport: CoreMIDIInputTransport = CoreMIDIInputTransport()) {
        self.transport = transport
        self.mapper = ScratchPlatterPlayheadMapper(
            sampleDuration: 0,
            velocityDeadband: 16
        )
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

    /// Sets the *current deck's* motor baseline to the most recent raw pitch-bend
    /// value (calibrate from the live idle stream while the platter spins untouched).
    func calibrateBaselineFromCurrent() {
        let deck = clampedDeck(deckChannel)
        deckBaselines[deck] = rawPitchBendLatest
        deckBaselineCalibrated[deck] = true
        baseline = rawPitchBendLatest      // didSet → mapper.calibrate
        baselineCalibrated = true
    }

    /// Returns the playhead to the start of the sample.
    func resetPlayhead() {
        mapper.resetPosition()
        engine.setTargetPosition(seconds: mapper.samplePosition)
    }

    // MARK: - Deck / gain helpers

    private func clampedDeck(_ channel: Int) -> Int {
        (channel == 0 || channel == 1) ? channel : 0
    }

    /// Loads the selected deck's stored baseline + calibration flag into the mapper.
    private func loadDeckConfig(_ channel: Int) {
        let deck = clampedDeck(channel)
        baseline = deckBaselines[deck]     // didSet → mapper.calibrate
        baselineCalibrated = deckBaselineCalibrated[deck]
    }

    /// Applies the lab output gain: crossfader position when gating is on, else full.
    private func applyOutputGain() {
        engine.setOutputGain(applyCrossfaderToVolume ? Float(crossfaderLatest) : 1.0)
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
        case .pitchBend where ScratchPlatterPlayheadMapper.isPitchBendChannel(parsed.channel, forDeck: deckChannel):
            guard let raw = parsed.value else { return }
            let dt: TimeInterval
            if let last = lastEventTimestamp { dt = event.timestamp - last } else { dt = 0 }
            lastEventTimestamp = event.timestamp
            rawPitchBendLatest = raw
            platterRateLatest = mapper.ingestPitchBend(raw, dt: dt)
            engine.setTargetPosition(seconds: mapper.samplePosition)
            let now = Date()
            pitchBendEventDates.append(now)
            lastPitchBendDate = now

        case .controlChange where parsed.controlNumber == crossfaderCC:
            if let value = parsed.value {
                crossfaderLatest = ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: value)
                crossfaderRawLatest = value
                crossfaderChannelLatest = parsed.channel
                hasCrossfaderLatest = true
                lastCrossfaderDate = Date()
                if applyCrossfaderToVolume { applyOutputGain() }
            }

        default:
            break
        }
    }

    // MARK: - Display publish (≈60 Hz)

    private func publishDisplayState() {
        let now = Date()

        rawPitchBend = rawPitchBendLatest
        platterRate = platterRateLatest
        samplePositionSeconds = mapper.samplePosition
        samplePositionFraction = mapper.positionFraction
        isAtStart = mapper.isAtStart
        isAtEnd = mapper.isAtEnd

        crossfader = crossfaderLatest
        crossfaderRaw = crossfaderRawLatest
        crossfaderChannel = crossfaderChannelLatest
        hasCrossfader = hasCrossfaderLatest

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
    }
}
#endif
