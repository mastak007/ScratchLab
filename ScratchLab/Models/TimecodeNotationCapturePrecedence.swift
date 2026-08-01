import Foundation

/// Decides which movement-event source becomes a routine take's captured
/// notation `recordMovementEvents`: DVS-authoritative when notation routing
/// is enabled and a trusted timeline exists, camera otherwise — the two are
/// never merged.
///
/// Pure and side-effect-free: takes everything it needs as parameters and
/// makes no calls into `MacCaptureEngine`/`RoutineNotationFusionEngine`.
/// The caller is responsible for feeding the *result* into the existing,
/// unmodified `RoutineNotationFusionEngine.snapshot(motionEvents:...)` —
/// this type does not touch that engine's internals at all, keeping the
/// change surface on already-shipping fusion logic as small as possible.
enum TimecodeNotationCapturePrecedence {
    /// - When `notationRoutingEnabled` is `false` (today's only real state
    ///   — no UI enables this yet), returns `cameraMovementEvents`
    ///   unchanged. Zero behavior change for any existing capture.
    /// - When `notationRoutingEnabled` is `true` and the drained DVS
    ///   timeline produces at least one movement event via
    ///   `TimecodeNotationEventAdapter`, DVS becomes authoritative: returns
    ///   exactly those events. `cameraMovementEvents` is discarded
    ///   entirely — never merged with the DVS events.
    /// - When `notationRoutingEnabled` is `true` but no trusted DVS
    ///   movement was captured this take (`drainedTimecodeNotationTimeline`
    ///   is `nil`, or its samples don't form a real movement event), fails
    ///   closed: returns `[]`, not a camera fallback. A camera fallback
    ///   would be an *implicit* policy; if one is ever wanted it must be a
    ///   separate, user-visible decision — not automatic here.
    static func resolvedMovementEvents(
        notationRoutingEnabled: Bool,
        cameraMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
        drainedTimecodeNotationTimeline: PlatterPositionTimeline?
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard notationRoutingEnabled else { return cameraMovementEvents }
        guard let timeline = drainedTimecodeNotationTimeline else { return [] }
        return TimecodeNotationEventAdapter.makeMovementEvents(from: timeline)
    }
}
