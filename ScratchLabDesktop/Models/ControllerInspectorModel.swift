#if os(macOS)
import Foundation
import Combine

// Phase 1 controller-input: Controller Inspector view model (macOS, display-only).
//
// Scope guardrails (deliberate):
// - Display + in-memory only. Holds the live raw-event log and detected-control
//   summary for the Inspector window. Writes nothing to disk and nothing to any
//   device, and changes no existing product behaviour.
// - Owns a `CoreMIDIInputTransport`; connects to all sources for discovery and
//   filters what is *shown* by the user's selected source (nil = all sources).

/// One row in the Inspector's raw-event log. Carries the source name, the
/// verbatim raw event, and a derived parsed view. The raw bytes are never reduced
/// to a tag — they are kept whole on `raw.bytes`.
struct InspectorMIDIEvent: Identifiable, Equatable {
    let id: UInt64
    let sourceName: String
    let raw: MIDIRawEvent
    let parsed: ParsedMIDIMessage

    var timestamp: TimeInterval { raw.timestamp }
    var bytes: [UInt8] { raw.bytes }
    var hexBytes: String { MIDIMessageParsing.hexString(raw.bytes) }

    init(id: UInt64, sourceName: String, raw: MIDIRawEvent) {
        self.id = id
        self.sourceName = sourceName
        self.raw = raw
        self.parsed = MIDIMessageParsing.parse(raw.bytes)
    }
}

/// Observable model backing `ControllerInspectorView`.
@MainActor
final class ControllerInspectorModel: ObservableObject {
    /// Available MIDI sources (all are connected for discovery).
    @Published private(set) var sources: [MIDISourceInfo] = []
    /// Source whose events are shown; nil means "all sources".
    @Published var selectedSourceName: String? = nil

    /// Most-recent events (newest first), capped to `maxLoggedEvents`.
    @Published private(set) var events: [InspectorMIDIEvent] = []
    /// Total events received since the last clear (may exceed the visible cap).
    @Published private(set) var eventCount: Int = 0
    /// Detected-control stats ordered by activity.
    @Published private(set) var detectedControls: [DetectedControlStat] = []

    @Published private(set) var isRunning = false
    @Published var isPaused = false
    /// Wall-clock time of the most recent shown event, for the activity indicator.
    @Published private(set) var lastEventDate: Date?
    /// Overall events/second over a short sliding window.
    @Published private(set) var eventRateHz: Double = 0

    /// Maximum rows retained in the visible log (in-memory only).
    let maxLoggedEvents = 1000

    private let transport: CoreMIDIInputTransport
    private var summary = DetectedControlSummary()
    private var nextEventID: UInt64 = 0
    /// Monotonic timestamps of recent events for the sliding-window rate.
    private var recentTimestamps: [TimeInterval] = []
    private let rateWindow: TimeInterval = 1.0

    init(transport: CoreMIDIInputTransport = CoreMIDIInputTransport()) {
        self.transport = transport
        transport.onSourcedEvent = { [weak self] sourceName, event in
            // Delivered on the main queue by the transport.
            MainActor.assumeIsolated {
                self?.ingest(sourceName: sourceName, event: event)
            }
        }
        transport.onSourcesChanged = { [weak self] infos in
            MainActor.assumeIsolated {
                self?.sources = infos
            }
        }
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        transport.start()
        isRunning = transport.isRunning
    }

    func stop() {
        transport.stop()
        isRunning = false
    }

    func togglePause() {
        isPaused.toggle()
    }

    /// Clears the visible log, counts, and detected-control summary (memory only).
    func clearLog() {
        events.removeAll()
        eventCount = 0
        summary.clear()
        detectedControls = []
        recentTimestamps.removeAll()
        eventRateHz = 0
        lastEventDate = nil
    }

    // MARK: - Ingest

    private func ingest(sourceName: String, event: MIDIRawEvent) {
        guard !isPaused else { return }
        // Source filter: nil selection shows everything.
        if let selected = selectedSourceName, selected != sourceName {
            return
        }

        let inspectorEvent = InspectorMIDIEvent(id: nextEventID, sourceName: sourceName, raw: event)
        nextEventID += 1

        events.insert(inspectorEvent, at: 0)
        if events.count > maxLoggedEvents {
            events.removeLast(events.count - maxLoggedEvents)
        }
        eventCount += 1

        summary.record(inspectorEvent.parsed, at: event.timestamp)
        detectedControls = summary.mostActive

        updateRate(at: event.timestamp)
        lastEventDate = Date()
    }

    private func updateRate(at timestamp: TimeInterval) {
        recentTimestamps.append(timestamp)
        let cutoff = timestamp - rateWindow
        recentTimestamps.removeAll { $0 < cutoff }
        // Events within the last `rateWindow` seconds → Hz.
        eventRateHz = Double(recentTimestamps.count) / rateWindow
    }
}
#endif
