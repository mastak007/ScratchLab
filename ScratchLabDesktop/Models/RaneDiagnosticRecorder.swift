#if os(macOS)
import Foundation

// Scratch Playback Lab: RANE hardware diagnostic recorder.
//
// Scope guardrails (deliberate):
// - Pure value types + Foundation Codable only. No Core MIDI, no AVFoundation, no
//   device I/O, and NOTHING from notation / replay / beat engine / capture / scoring /
//   ML / export / app navigation. The lab model feeds it parsed events; file writing
//   lives in the model, not here.
// - Purpose: stop debugging the platter from screen-recorded video. Capture the raw
//   pitch-bend stream (and crossfader) to JSON so encoder behaviour can be inspected
//   offline.
//
// Timestamps are seconds-since-session-start (TimeInterval) supplied by the host, so
// the recorder and its summary are fully deterministic and unit-testable without a
// clock.

/// One recorded RANE platter diagnostic sample (captured on a pitch-bend event).
struct RaneDiagnosticEvent: Equatable, Codable {
    /// Seconds since the recording session started (monotonic, set by the host).
    let timestamp: TimeInterval
    /// Absolute 14-bit platter pitch-bend value for this event.
    let rawPitchBend: Int
    /// The previous raw pitch-bend value, or nil if this is the first tracked event.
    let previousRawPitchBend: Int?
    /// Shortest signed wrapped delta (ticks) the mapper applied for this event.
    let wrappedDelta: Int
    /// Sample-playback position (seconds) after this event was applied.
    let samplePositionSeconds: TimeInterval
    /// Normalised crossfader position 0...1, or nil if no valid crossfader value yet.
    let crossfader: Double?
    /// Latest value of the platter companion stream (CC6 on the deck channel), or nil
    /// if none seen yet. The RANE platter interleaves CC6 1:1 with the pitch bend; CC6
    /// appears to be a ±1 direction/step counter. Captured raw for offline decode — the
    /// mapper does not (yet) use it.
    let cc6: Int?
    /// Raw pitch-bend MIDI channel / deck this event arrived on (0 = left, 1 = right).
    let deck: Int
    /// Human-readable MIDI source name the event arrived from.
    let sourceName: String
    /// The real CoreMIDI event timestamp (transport host-clock seconds), as opposed to
    /// `timestamp` which is processing time. Lets the true per-event MIDI spacing be
    /// measured offline (delivery batching vs real timing). nil for v1/v2 captures.
    let hostTime: TimeInterval?
}

/// Pure summary of a diagnostic session, derived entirely from the recorded events.
/// Encodable so it travels inside the exported JSON alongside the raw events.
struct RaneDiagnosticSummary: Equatable, Codable {
    let eventCount: Int
    /// Largest `abs(wrappedDelta)` seen — the worst-case per-event jump.
    let maxAbsoluteDelta: Int
    /// Number of events whose raw value jumped across the 14-bit ring boundary
    /// (`abs(raw - previousRaw) > modulus/2`) — i.e. the encoder wrapped.
    let wrapCount: Int
    let minRawPitchBend: Int?
    let maxRawPitchBend: Int?
    /// Sum of `abs(wrappedDelta)` across the session — the true distance travelled in
    /// ticks (robust to wraps that net the signed total back toward zero).
    let totalAbsoluteTicks: Int
    /// In calibration mode (the user turns the platter exactly one revolution) the
    /// total absolute ticks ARE the measured ticks-per-revolution. nil outside
    /// calibration, or before any motion has been recorded.
    let estimatedTicksPerRevolution: Int?
    /// Events whose `abs(wrappedDelta)` exceeded the warn alias threshold (this
    /// includes events that also exceeded the fail threshold).
    let aliasWarningCount: Int
    /// Events whose `abs(wrappedDelta)` exceeded the fail alias threshold (direction
    /// may have aliased).
    let aliasFailCount: Int

    init(events: [RaneDiagnosticEvent], isCalibration: Bool) {
        let modulus = ScratchPlatterPlayheadMapper.ticksPerRevolution
        let warn = ScratchPlatterPlayheadMapper.aliasWarnThreshold
        let fail = ScratchPlatterPlayheadMapper.aliasFailThreshold

        eventCount = events.count
        maxAbsoluteDelta = events.map { abs($0.wrappedDelta) }.max() ?? 0
        totalAbsoluteTicks = events.reduce(0) { $0 + abs($1.wrappedDelta) }

        let raws = events.map(\.rawPitchBend)
        minRawPitchBend = raws.min()
        maxRawPitchBend = raws.max()

        wrapCount = events.reduce(0) { count, event in
            guard let previous = event.previousRawPitchBend else { return count }
            return abs(event.rawPitchBend - previous) > modulus / 2 ? count + 1 : count
        }

        aliasWarningCount = events.filter { abs($0.wrappedDelta) > warn }.count
        aliasFailCount = events.filter { abs($0.wrappedDelta) > fail }.count

        estimatedTicksPerRevolution = (isCalibration && totalAbsoluteTicks > 0) ? totalAbsoluteTicks : nil
    }
}

/// Pure, in-memory recorder for RANE platter diagnostics. The host (the lab model)
/// calls `start`/`stop` and feeds events while recording; the recorder accumulates them
/// and exposes a `summary`. No file or device I/O lives here.
struct RaneDiagnosticRecorder: Equatable {
    /// Hard ceiling on captured events. At ~935 platter events/sec this is ~4.5 minutes
    /// of recording (~24 MB live), bounding memory so a forgotten or runaway session
    /// can't grow without limit. Recording auto-stops once the cap is reached.
    static let maxEvents = 250_000

    private(set) var isRecording = false
    /// Whether the active (or most recent) recording is a one-revolution calibration.
    private(set) var isCalibration = false
    /// Set when a recording auto-stopped because it hit `maxEvents`. Cleared by `start`.
    private(set) var didReachCapacity = false
    private(set) var events: [RaneDiagnosticEvent] = []

    /// Begins a new recording, discarding any previously captured events. Pass
    /// `calibration: true` for a one-revolution run (drives the ticks-per-revolution
    /// estimate in the summary).
    mutating func start(calibration: Bool = false) {
        events.removeAll(keepingCapacity: true)
        isCalibration = calibration
        didReachCapacity = false
        isRecording = true
    }

    /// Stops recording. Captured events and the summary remain available for export.
    mutating func stop() {
        isRecording = false
    }

    /// Appends one event if recording; a no-op otherwise. Auto-stops and sets
    /// `didReachCapacity` once `maxEvents` have been captured (keeps the earliest
    /// events so the onset of a wrap/alias issue is preserved).
    mutating func record(_ event: RaneDiagnosticEvent) {
        guard isRecording else { return }
        guard events.count < Self.maxEvents else {
            isRecording = false
            didReachCapacity = true
            return
        }
        events.append(event)
        if events.count >= Self.maxEvents {
            isRecording = false
            didReachCapacity = true
        }
    }

    /// Discards captured events and clears the calibration flag (leaves `isRecording`).
    mutating func reset() {
        events.removeAll(keepingCapacity: true)
        isCalibration = false
    }

    /// The summary computed from the events captured so far.
    var summary: RaneDiagnosticSummary {
        RaneDiagnosticSummary(events: events, isCalibration: isCalibration)
    }
}

/// Codable export envelope: a schema-versioned header, the computed summary, and the
/// full event list. Encoded as deterministic pretty JSON for offline, diffable exports.
struct RaneDiagnosticSessionExport: Equatable, Codable {
    // v2 adds per-event `cc6`; v3 adds per-event `hostTime` (real CoreMIDI timestamp).
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    /// Wall-clock export time (epoch seconds), supplied by the host. Optional so the
    /// envelope stays deterministic in tests.
    let exportedAtEpochSeconds: TimeInterval?
    let isCalibration: Bool
    let summary: RaneDiagnosticSummary
    let events: [RaneDiagnosticEvent]

    init(events: [RaneDiagnosticEvent], isCalibration: Bool, exportedAtEpochSeconds: TimeInterval? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAtEpochSeconds = exportedAtEpochSeconds
        self.isCalibration = isCalibration
        self.summary = RaneDiagnosticSummary(events: events, isCalibration: isCalibration)
        self.events = events
    }

    /// Encodes to deterministic pretty-printed JSON (sorted keys) so exports diff cleanly.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// One named file in the tester diagnostics bundle.
struct DiagnosticsBundleFile: Equatable {
    let name: String
    let data: Data
}

/// Pure builder of a tester diagnostics bundle for pro-DJ testers to send back. It gathers
/// ONLY the explicitly provided pieces — captured timeline, RANE diagnostic, the controller
/// profile in effect, app/build info, detected MIDI source info, and a README. Optional
/// inputs are omitted when absent; no private or unrelated files are ever included, and no
/// network upload happens here. Building the file set is pure; writing is a thin step.
struct TesterDiagnosticsBundle: Equatable {
    let files: [DiagnosticsBundleFile]

    init(
        timelineJSON: Data?,
        raneDiagnosticJSON: Data?,
        controllerProfileJSON: Data,
        appBuildInfo: String,
        midiSourceInfo: String,
        readme: String
    ) {
        var files: [DiagnosticsBundleFile] = []
        if let timelineJSON {
            files.append(DiagnosticsBundleFile(name: "ScratchTimeline.json", data: timelineJSON))
        }
        if let raneDiagnosticJSON {
            files.append(DiagnosticsBundleFile(name: "RaneDiagnostic.json", data: raneDiagnosticJSON))
        }
        files.append(DiagnosticsBundleFile(name: "ControllerProfile.json", data: controllerProfileJSON))
        files.append(DiagnosticsBundleFile(name: "app-build-info.txt", data: Data(appBuildInfo.utf8)))
        files.append(DiagnosticsBundleFile(name: "midi-source-info.txt", data: Data(midiSourceInfo.utf8)))
        files.append(DiagnosticsBundleFile(name: "README.txt", data: Data(readme.utf8)))
        self.files = files
    }

    /// The file names included, for verification / display.
    var fileNames: [String] { files.map(\.name) }

    /// Writes the bundle as a folder under `directory`, returning the folder URL. Each file
    /// is written by its declared name; nothing else is added.
    @discardableResult
    func write(to directory: URL, folderName: String, fileManager: FileManager = .default) throws -> URL {
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
        }
        return folder
    }
}
#endif
