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
    @Published private(set) var hasCrossfader = false
    @Published private(set) var eventRateHz: Double = 0
    @Published private(set) var sources: [MIDISourceInfo] = []
    @Published private(set) var isListening = false
    @Published private(set) var sampleLoaded = false
    @Published private(set) var waveformPeaks: [WaveformPeak] = []

    // Config (bindable from the UI).
    @Published var selectedSourceName: String?
    /// Pitch-bend channel that drives the playhead: 0 = left platter, 1 = right.
    @Published var deckChannel: Int = 0
    @Published var baseline: Int = ScratchPlatterPlayheadMapper.defaultMotorBaseline {
        didSet { mapper.calibrate(toBaseline: baseline) }
    }
    @Published var rateScale: Double = 1.0 / 4096.0 {
        didSet { mapper.rateScale = rateScale }
    }

    /// CC number observed for the crossfader readout (RANE ONE MKII = CC8). Display
    /// only; channel is not constrained so the value surfaces regardless of deck.
    let crossfaderCC = 8

    var sampleDuration: TimeInterval { mapper.sampleDuration }

    private var mapper: ScratchPlatterPlayheadMapper
    private let engine = ScratchPlaybackLabEngine()
    private let transport: CoreMIDIInputTransport
    private var lastEventTimestamp: TimeInterval?
    private var displayTimer: Timer?
    private var recentTimestamps: [TimeInterval] = []
    private let rateWindow: TimeInterval = 1.0

    // Latest values stashed on the MIDI path; copied into @Published at display rate.
    private var rawPitchBendLatest = ScratchPlatterPlayheadMapper.defaultMotorBaseline
    private var platterRateLatest: Double = 0
    private var crossfaderLatest: Double = 0
    private var hasCrossfaderLatest = false

    init(transport: CoreMIDIInputTransport = CoreMIDIInputTransport()) {
        self.transport = transport
        self.mapper = ScratchPlatterPlayheadMapper(sampleDuration: 0)
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

    /// Sets the motor baseline to the most recent raw pitch-bend value (calibrate
    /// from the live idle stream while the platter spins untouched).
    func calibrateBaselineFromCurrent() {
        baseline = rawPitchBendLatest
    }

    /// Returns the playhead to the start of the sample.
    func resetPlayhead() {
        mapper.resetPosition()
        engine.setTargetPosition(seconds: mapper.samplePosition)
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

        switch parsed.messageType {
        case .pitchBend where parsed.channel == deckChannel:
            guard let raw = parsed.value else { return }
            let dt: TimeInterval
            if let last = lastEventTimestamp { dt = event.timestamp - last } else { dt = 0 }
            lastEventTimestamp = event.timestamp
            rawPitchBendLatest = raw
            platterRateLatest = mapper.ingestPitchBend(raw, dt: dt)
            engine.setTargetPosition(seconds: mapper.samplePosition)
            noteEventRate(at: event.timestamp)

        case .controlChange where parsed.controlNumber == crossfaderCC:
            if let value = parsed.value {
                crossfaderLatest = ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: value)
                hasCrossfaderLatest = true
            }

        default:
            break
        }
    }

    private func noteEventRate(at timestamp: TimeInterval) {
        recentTimestamps.append(timestamp)
        let cutoff = timestamp - rateWindow
        recentTimestamps.removeAll { $0 < cutoff }
    }

    // MARK: - Display publish (≈60 Hz)

    private func publishDisplayState() {
        rawPitchBend = rawPitchBendLatest
        platterRate = platterRateLatest
        samplePositionSeconds = mapper.samplePosition
        samplePositionFraction = mapper.positionFraction
        crossfader = crossfaderLatest
        hasCrossfader = hasCrossfaderLatest
        eventRateHz = Double(recentTimestamps.count) / rateWindow
    }
}
#endif
