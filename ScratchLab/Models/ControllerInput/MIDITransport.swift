import Foundation

// Phase 1 MIDI transport seam.
//
// This is the boundary a real Core MIDI implementation will fill later. This
// slice ships ONLY a protocol and an inert stub:
// - No Core MIDI import.
// - No device assumptions, no hard-coded CC numbers, no RANE ONE mapping.
// - No Serato dependency, no UI.

/// Lifecycle + delivery boundary for a MIDI input transport.
///
/// Delivery thread is intentionally unspecified by the protocol; a real
/// implementation may call `onEvent` off the main thread, so consumers must not
/// assume the main thread.
protocol MIDITransport: AnyObject {
    /// True once `start()` has succeeded and before `stop()`.
    var isRunning: Bool { get }

    /// Invoked for each raw MIDI event. Set before `start()`.
    var onEvent: ((MIDIRawEvent) -> Void)? { get set }

    /// Begins listening. Idempotent: starting while running is a no-op.
    func start()

    /// Stops listening and releases resources. Idempotent.
    func stop()
}

/// Inert MIDI transport used until a real Core MIDI transport exists. It
/// connects to nothing and emits nothing on its own. Tests and (future) replay
/// can call `inject(_:)` to push synthetic events through the same delivery
/// path, which mirrors a real transport by only emitting while running.
final class StubMIDITransport: MIDITransport {
    private(set) var isRunning: Bool = false
    var onEvent: ((MIDIRawEvent) -> Void)?

    init() {}

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    /// Test/replay hook: deliver a synthetic event iff running. No-op when
    /// stopped, matching a real transport that only emits while active.
    func inject(_ event: MIDIRawEvent) {
        guard isRunning else { return }
        onEvent?(event)
    }
}
