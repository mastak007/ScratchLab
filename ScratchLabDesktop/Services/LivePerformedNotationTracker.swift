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

enum LiveNotationTrackingState: Equatable {
    case unavailable
    case waiting
    case tracking(
        committed: [CaptureCore.DetectedNotationRecordMovementEvent],
        provisional: CaptureCore.ProvisionalPlatterMovement?
    )
}

/// Owns a live-notation polling loop for exactly one Practice attempt or one
/// Capture take. A fresh instance is still the reset at Restart/new take;
/// `freeze()` stops polling while retaining the completed Practice trace.
final class LivePerformedNotationTracker: ObservableObject {
    @Published private(set) var state: LiveNotationTrackingState = .waiting
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

    static func renderedEvents(
        for state: LiveNotationTrackingState
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard case .tracking(let committed, let provisional) = state else { return [] }
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
        Task { @MainActor [weak self] in
            guard let self, !self.isFrozen else { return }
            self.state = newState
        }
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
            return .tracking(committed: controllerResult.committedEvents, provisional: controllerResult.provisionalMovement)
        }

        if let cameraEvents, !cameraEvents.isEmpty {
            return .tracking(committed: cameraEvents, provisional: nil)
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
