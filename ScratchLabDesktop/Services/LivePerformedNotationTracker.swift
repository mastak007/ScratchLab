// LivePerformedNotationTracker.swift
// ScratchLabDesktop
//
// Live, in-progress preview of a performer's real motion during an active
// Practice attempt or Capture take — visually distinct from target notation,
// never fed into Review/export, and built entirely on top of the pure
// decode functions `completeRoutineFinalization` itself uses
// (`CaptureCore.derivePlatterMovementEvents*`), never a second
// reconstruction algorithm.
//
// Construction is per-attempt/per-take: a fresh tracker baselines on the
// timestamp at construction time and only ever considers MIDI CC events
// appended after that baseline, so events from a prior attempt/take can
// never leak into a new one. See `MacCaptureEngine.capturedMidiCCEventsSnapshot()`
// / `.beginLiveMIDICapture()` / `.endLiveMIDICaptureIfIdle()` for the
// queue-confined, non-destructive accumulator this reads.

import Foundation
import QuartzCore
import Combine

/// Small dependency bundle a `LivePerformedNotationTracker` polls. Plain
/// closures rather than a reference to `MacCaptureEngine` — the tracker has
/// no dependency on the engine and is independently testable with synthetic
/// data.
struct LivePerformedNotationDataSource {
    /// The currently selected MIDI input source name — mirrors
    /// `MacCaptureEngine.selectedMIDIInputSourceName` ("Not Connected" when
    /// none selected).
    let selectedMIDISourceName: () -> String
    /// Queue-confined, non-destructive snapshot of accumulated MIDI CC
    /// telemetry — mirrors `MacCaptureEngine.capturedMidiCCEventsSnapshot()`.
    let capturedMidiCCEventsSnapshot: () -> [CaptureCore.RawMixerMIDIEvent]
    /// Non-destructive camera-fallback movement snapshot, or `nil` when no
    /// camera builder is currently active at all (distinct from "active but
    /// has seen no movement yet", which is an empty array).
    let cameraMovementEventsSnapshot: (_ now: CFTimeInterval) -> [CaptureCore.DetectedNotationRecordMovementEvent]?
}

/// Bounded, read-only counters describing ONE tracker poll.
///
/// Added after the 2026-09-05 authoring take rendered a visually flat trace.
/// Replaying that take's captured MIDI through this exact path produced a
/// healthy 0.718 vertical span for its first ~12 s and 0.036 for the trailing
/// 3.2 s window the card displays — so the chain was not flattening anything,
/// and no record existed of what the tracker actually held at the moment the
/// operator was watching. These counters make that attributable live.
///
/// Presentation only: nothing here is persisted, scored, exported, or allowed
/// to influence capture.
struct LiveNotationDiagnostics: Equatable, Sendable {
    /// Events in the engine's take-scoped buffer before any filtering.
    let rawSnapshotCount: Int
    /// Events surviving the tracker's baseline filter.
    let baselineMatchedCount: Int
    /// Committed movement events the decoder produced.
    let committedMovementCount: Int
    /// Whether an open provisional stroke is present.
    let hasProvisional: Bool
    /// Vertical span across every rendered stroke, in lane units.
    let renderedPositionSpan: Double
    /// Age of the newest event in the buffer, in seconds.
    let latestEventAge: Double
}

enum LiveNotationTrackingState: Equatable {
    case unavailable
    case waiting
    case tracking(
        committed: [CaptureCore.DetectedNotationRecordMovementEvent],
        provisional: CaptureCore.ProvisionalPlatterMovement?,
        continuousCommitted: [CaptureCore.DetectedNotationRecordMovementEvent],
        continuousProvisional: CaptureCore.ProvisionalPlatterMovement?
    )
}

/// Owns a live-notation polling loop for exactly one Practice attempt or one
/// Capture take. A fresh instance is still the reset at Restart/new take;
/// `freeze()` stops polling while retaining the completed Practice trace.
final class LivePerformedNotationTracker: ObservableObject {
    @Published private(set) var state: LiveNotationTrackingState = .waiting
    /// Latest poll's counters. DEBUG surfaces only; never read by rendering.
    @Published private(set) var diagnostics: LiveNotationDiagnostics?
    @Published private(set) var isFrozen = false
    @Published private(set) var frozenAt: Date?

    private let dataSource: LivePerformedNotationDataSource
    private let baselineTimestamp: Double
    private var frozenTimestamp: Double?
    private var timer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.scratchlab.livePerformedNotation.poll")

    /// - Parameters:
    ///   - dataSource: how to read live evidence. Build one via
    ///     `MacCaptureEngine.makeLivePerformedNotationDataSource()`.
    ///   - now: the attempt/take-start timestamp, in the same
    ///     `CACurrentMediaTime()` domain `CaptureCore.RawMixerMIDIEvent.timestamp`
    ///     uses. Defaults to "now" — tests pass an explicit value.
    ///   - pollInterval: matches the ~25 Hz cadence already established for
    ///     `MacCaptureEngine.playbackPositionSnapshot` polling.
    init(
        dataSource: LivePerformedNotationDataSource,
        now: Double = CACurrentMediaTime(),
        pollInterval: TimeInterval = 0.04
    ) {
        self.dataSource = dataSource
        self.baselineTimestamp = now
        startPolling(interval: pollInterval)
    }

    deinit {
        timer?.cancel()
    }

    /// Stops polling without discarding the last visible trace. Practice
    /// freezes a completed attempt so the learner can inspect it until the
    /// next attempt replaces this tracker.
    func freeze() {
        guard !isFrozen else { return }
        isFrozen = true
        frozenAt = Date()
        frozenTimestamp = CACurrentMediaTime()
        timer?.cancel()
        timer = nil
    }

    /// Monotonic attempt-relative presentation time in the same
    /// `CACurrentMediaTime()` domain used to baseline incoming MIDI events.
    /// The live camera overlay and its notation playhead therefore share the
    /// tracker's real capture start instead of a separate wall-clock anchor.
    var elapsedTime: TimeInterval {
        max(0, (frozenTimestamp ?? CACurrentMediaTime()) - baselineTimestamp)
    }

    /// Canonical renderer input. The open run is represented as a preview
    /// event so the normal diagonal scratch geometry updates before the next
    /// turnaround commits it. This value is presentation-only and is never
    /// persisted, scored, reviewed, or exported.
    var renderedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        Self.renderedEvents(for: state)
    }

    /// Which coordinate `renderedEvents` positions are ACTUALLY in.
    ///
    /// The controller branch of `computeState` comes from
    /// `derivePlatterMovementEventsWithProvisional`, which divides raw CC6 step
    /// displacement by `PlatterCoordinateSemantics
    /// .raneOneMKIIDirectMIDIStepsPerRevolution` — genuine revolutions. The
    /// camera fallback branch emits builder events in no declared platter
    /// coordinate, and an empty state claims nothing. This declaration is made
    /// HERE, at the boundary that knows which branch ran, and never inferred
    /// downstream: an identically-sourced event persisted by finalization is
    /// span-normalised instead, so `source` alone cannot settle the unit.
    var platterCoordinates: CaptureCore.PlatterNotationCoordinates {
        Self.platterCoordinates(for: state)
    }

    static func platterCoordinates(
        for state: LiveNotationTrackingState
    ) -> CaptureCore.PlatterNotationCoordinates {
        let rendered = renderedEvents(for: state)
        guard !rendered.isEmpty,
              rendered.allSatisfy(CaptureCore.usesGestureRelativeControllerNotation) else {
            return .normalizedTakeLocal(
                reference: "live movement is not gesture-relative controller "
                    + "telemetry, so no platter calibration is claimed"
            )
        }
        return .raneOneMKIIDirectMIDI()
    }

    static func renderedEvents(
        for state: LiveNotationTrackingState
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard case .tracking(let committed, let provisional, _, _) = state else { return [] }
        guard let provisional else { return committed }
        let duration = max(0, provisional.currentTime - provisional.startTime)
        // Keep controller speed in raw steps/second, matching committed
        // controller events. The positions above are now gesture-relative
        // notation coordinates; deriving speed from them would divide the
        // physical excursion by the platter calibration a second time when
        // the shared performed-stroke adapter projects this preview.
        let distance = abs(provisional.displacement)
        let preview = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: provisional.startTime,
            endTime: provisional.currentTime,
            startPosition: provisional.startPosition,
            endPosition: provisional.currentPosition,
            direction: provisional.direction,
            movementKind: provisional.movementKind,
            speed: duration > 0 ? distance / duration : 0,
            confidence: 0.5,
            source: "live_preview"
        )
        return committed + [preview]
    }

    /// Continuous renderer input for the canonical Tear projection. Unlike
    /// `renderedEvents` these positions are NOT gesture-relative, so a
    /// reversal apex shared between a forward and a backward run stays one
    /// position-continuous trajectory. Positions are re-normalised over a
    /// rolling presentation window so a free-running platter (several
    /// off-screen revolutions) cannot permanently pin the current Tear at the
    /// top of the lane. Presentation-only, like `renderedEvents`.
    static func continuousRenderedEvents(
        for state: LiveNotationTrackingState
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard case .tracking(_, _, let continuousCommitted, let continuousProvisional) = state else { return [] }
        var events = continuousCommitted
        if let continuousProvisional {
            let duration = max(0, continuousProvisional.currentTime - continuousProvisional.startTime)
            let distance = abs(continuousProvisional.displacement)
            events.append(CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: continuousProvisional.startTime,
                endTime: continuousProvisional.currentTime,
                startPosition: continuousProvisional.startPosition,
                endPosition: continuousProvisional.currentPosition,
                direction: continuousProvisional.direction,
                movementKind: continuousProvisional.movementKind,
                speed: duration > 0 ? distance / duration : 0,
                confidence: 0.5,
                source: "live_preview"
            ))
        }
        return windowNormalized(events)
    }

    /// Rolling window (seconds) over which continuous live Tear positions are
    /// re-normalised, matching `LivePerformedNotationCard.renderedDomain`.
    private static let continuousTearWindowSeconds: TimeInterval = 3.2

    /// Re-normalise the continuous trajectory over the rolling presentation
    /// window, dropping motion older than the window so historical free-spin
    /// cannot bias the current Tear's vertical scale. One affine transform is
    /// applied to the whole visible trajectory — preserving ordering, signed
    /// direction, relative displacement, and reversal-apex continuity — never
    /// a per-run or per-candidate transform.
    private static func windowNormalized(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard let latest = events.map(\.endTime).max() else { return [] }
        let windowStart = max(0, latest - continuousTearWindowSeconds)
        let visible = events.filter { $0.endTime >= windowStart }
        let positions = visible.flatMap { [$0.startPosition, $0.endPosition] }
        guard let low = positions.min(), let high = positions.max(), high > low else {
            return visible
        }
        let span = high - low
        func normalized(_ position: Double) -> Double { (position - low) / span }
        return visible.map { event in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: event.startTime,
                endTime: event.endTime,
                startPosition: normalized(event.startPosition),
                endPosition: normalized(event.endPosition),
                direction: event.direction,
                movementKind: event.movementKind,
                speed: event.speed,
                confidence: event.confidence,
                source: event.source
            )
        }
    }

    /// Continuous global span-normalised platter telemetry for the canonical
    /// Tear projection, exposed as an instance convenience alongside
    /// `renderedEvents`.
    var continuousRenderedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        Self.continuousRenderedEvents(for: state)
    }

    /// Coordinate `continuousRenderedEvents` positions are ACTUALLY in: the
    /// global span-normalised take-local basis (0..1), never per-run
    /// gesture-relative revolutions.
    var continuousPlatterCoordinates: CaptureCore.PlatterNotationCoordinates {
        .normalizedTakeLocal(
            reference: "continuous window-normalised platter telemetry "
                + "for the canonical Tear projection"
        )
    }

    private func startPolling(interval: TimeInterval) {
        let source = DispatchSource.makeTimerSource(queue: pollQueue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    private func tick() {
        let dataSource = self.dataSource
        let baseline = self.baselineTimestamp
        let newState = Self.computeState(dataSource: dataSource, baselineTimestamp: baseline)
        let newDiagnostics = Self.diagnostics(
            dataSource: dataSource,
            baselineTimestamp: baseline,
            state: newState
        )
        Task { @MainActor [weak self] in
            guard let self, !self.isFrozen else { return }
            self.state = newState
            self.diagnostics = newDiagnostics
        }
    }

    /// Pure counter derivation, testable without a timer. Reads the same
    /// snapshot `computeState` reads; adds no second source of truth.
    static func diagnostics(
        dataSource: LivePerformedNotationDataSource,
        baselineTimestamp: Double,
        state: LiveNotationTrackingState,
        now: Double = CACurrentMediaTime()
    ) -> LiveNotationDiagnostics {
        let snapshot = dataSource.capturedMidiCCEventsSnapshot()
        let matched = snapshot.filter { $0.timestamp > baselineTimestamp }
        let rendered = renderedEvents(for: state)
        let positions = rendered.flatMap { [$0.startPosition, $0.endPosition] }
        let span = (positions.max() ?? 0) - (positions.min() ?? 0)
        let committedCount: Int
        let hasProvisional: Bool
        if case .tracking(let committed, let provisional, _, _) = state {
            committedCount = committed.count
            hasProvisional = provisional != nil
        } else {
            committedCount = 0
            hasProvisional = false
        }
        return LiveNotationDiagnostics(
            rawSnapshotCount: snapshot.count,
            baselineMatchedCount: matched.count,
            committedMovementCount: committedCount,
            hasProvisional: hasProvisional,
            renderedPositionSpan: span,
            latestEventAge: matched.last.map { max(0, now - $0.timestamp) } ?? -1
        )
    }

    /// Pure decision function — no timer, no `@Published`, no main-actor
    /// hop — so it can be unit-tested directly and drives `tick()` above.
    ///
    /// Precedence mirrors `completeRoutineFinalization` exactly: MIDI
    /// controller telemetry is preferred when it has produced any
    /// committed or provisional movement; camera evidence is the fallback,
    /// used only when the controller path is currently empty. `.unavailable`
    /// only when neither a named controller source nor an active camera
    /// builder exists at all.
    static func computeState(
        dataSource: LivePerformedNotationDataSource,
        baselineTimestamp: Double
    ) -> LiveNotationTrackingState {
        let sourceName = dataSource.selectedMIDISourceName()
        let trimmedSourceName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControllerSource = !trimmedSourceName.isEmpty && trimmedSourceName != "Not Connected"
        let cameraEvents = dataSource.cameraMovementEventsSnapshot(CACurrentMediaTime())
        let hasCameraSource = cameraEvents != nil

        guard hasControllerSource || hasCameraSource else {
            return .unavailable
        }

        let midiSnapshot = dataSource.capturedMidiCCEventsSnapshot()
            .filter { $0.timestamp > baselineTimestamp }

        let controllerResult = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: sourceName,
            capturedMidi: midiSnapshot
        )
        let usesController = !controllerResult.committedEvents.isEmpty || controllerResult.provisionalMovement != nil
        if usesController {
            return .tracking(
                committed: controllerResult.committedEvents,
                provisional: controllerResult.provisionalMovement,
                continuousCommitted: controllerResult.continuousEvents,
                continuousProvisional: controllerResult.continuousProvisionalMovement
            )
        }

        if let cameraEvents, !cameraEvents.isEmpty {
            return .tracking(
                committed: cameraEvents,
                provisional: nil,
                continuousCommitted: cameraEvents,
                continuousProvisional: nil
            )
        }

        return .waiting
    }
}

// MARK: - Rendering

import SwiftUI

/// Live performed-notation card for Capture (while actively recording) and
/// any standalone diagnostic presentation. Practice's canonical Copy screen
/// now reads the same tracker directly into its camera overlay, while Capture
/// keeps this separate card. Both routes use the same canonical platter
/// geometry; neither feeds Review or export.
struct LivePerformedNotationCard: View {
    @ObservedObject var tracker: LivePerformedNotationTracker
    var bpm: Double = 90
    /// True while the calibration box editor is open — the card dims
    /// strongly rather than competing visually with the edit handles, per
    /// Karl's directive. This is a plain visibility/opacity binding so the
    /// calibration handles remain readable when the transparent notation
    /// canvas is composited over the camera.
    var isDimmedForCalibrationEditing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tracker.isFrozen ? "YOUR MOTION — COMPLETED ATTEMPT" : "YOUR MOTION — LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                Spacer()
                Text(stateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor)
            }

            ScratchPhraseChartView(
                source: tracker.renderedEvents.isEmpty
                    ? .empty(emptyMessage)
                    : .performedPlatter(tracker.renderedEvents),
                bpm: bpm,
                capturedWindow: renderedDomain,
                backgroundColor: .clear
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isDimmedForCalibrationEditing ? 0.15 : 1)
        .allowsHitTesting(!isDimmedForCalibrationEditing)
        .animation(.easeInOut(duration: 0.2), value: isDimmedForCalibrationEditing)
    }

    private var stateLabel: String {
        if tracker.isFrozen {
            return tracker.renderedEvents.isEmpty ? "No movement captured" : "Attempt complete"
        }
        switch tracker.state {
        case .unavailable: return "Live notation unavailable — no platter or camera signal"
        case .waiting: return "Waiting for movement…"
        case .tracking: return "Tracking"
        }
    }

    private var stateColor: Color {
        if tracker.isFrozen {
            return tracker.renderedEvents.isEmpty ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
        }
        switch tracker.state {
        case .unavailable: return Color(white: 0.5)
        case .waiting: return Color(nsColor: .systemYellow)
        case .tracking: return Color(nsColor: .systemGreen)
        }
    }

    private var emptyMessage: String {
        switch tracker.state {
        case .unavailable: return "No platter or camera signal"
        case .waiting: return tracker.isFrozen ? "No movement captured" : "Waiting for movement…"
        case .tracking: return "Waiting for movement…"
        }
    }

    private var renderedDomain: ClosedRange<TimeInterval>? {
        guard let first = tracker.renderedEvents.first,
              let last = tracker.renderedEvents.last else { return nil }
        let end = max(first.startTime + 3.2, last.endTime)
        return max(0, end - 3.2)...end
    }
}
