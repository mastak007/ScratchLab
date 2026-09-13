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
/// Capture take. Discard the instance (let it deinit, which cancels the
/// timer) at Restart/Stop/completion/session-change/disappearance — there is
/// no reset method by design, since a fresh instance is the reset.
final class LivePerformedNotationTracker: ObservableObject {
    @Published private(set) var state: LiveNotationTrackingState = .waiting

    private let dataSource: LivePerformedNotationDataSource
    private let baselineTimestamp: Double
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
            self?.state = newState
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

/// Live performed-notation card for Practice (during a scored attempt) and
/// Capture (while actively recording) — its own separate card/region, never
/// layered on the camera image (that's reserved for `CalibrationCameraOverlay`).
/// Visually distinct from target notation: a different hue, and the
/// provisional (uncommitted) stroke rendered dashed/lower-opacity so it is
/// never mistaken for confirmed evidence.
struct LivePerformedNotationCard: View {
    @ObservedObject var tracker: LivePerformedNotationTracker
    /// True while the calibration box editor is open — the card dims
    /// strongly rather than competing visually with the edit handles, per
    /// Karl's directive. The two surfaces are already separate regions
    /// (this card is never on the camera), so this is a plain
    /// visibility/opacity binding, not a z-order fix.
    var isDimmedForCalibrationEditing: Bool = false

    private static let viewportSeconds: Double = 3.2
    private static let committedColor = Color(red: 0.55, green: 0.35, blue: 1.0)
    private static let provisionalColor = Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("YOUR MOTION — LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                Spacer()
                Text(stateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor)
            }

            Canvas { context, size in
                draw(in: context, size: size)
            }
            .frame(height: 64)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .opacity(isDimmedForCalibrationEditing ? 0.15 : 1)
        .allowsHitTesting(!isDimmedForCalibrationEditing)
        .animation(.easeInOut(duration: 0.2), value: isDimmedForCalibrationEditing)
    }

    private var stateLabel: String {
        switch tracker.state {
        case .unavailable: return "Live notation unavailable — no platter or camera signal"
        case .waiting: return "Waiting for movement…"
        case .tracking: return "Tracking"
        }
    }

    private var stateColor: Color {
        switch tracker.state {
        case .unavailable: return Color(white: 0.5)
        case .waiting: return Color(nsColor: .systemYellow)
        case .tracking: return Color(nsColor: .systemGreen)
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard case .tracking(let committed, let provisional) = tracker.state else { return }
        let midY = size.height / 2
        let amplitude = size.height * 0.38

        // Trailing time window: right edge = "now" (the latest evidence —
        // the provisional stroke's current time, or the last committed
        // event's end time if idle).
        let now = provisional?.currentTime ?? committed.last?.endTime ?? 0
        let windowStart = now - Self.viewportSeconds

        func xPosition(for time: Double) -> CGFloat {
            let fraction = (time - windowStart) / Self.viewportSeconds
            return CGFloat(max(0, min(1, fraction))) * size.width
        }
        func yPosition(forward: Bool) -> CGFloat {
            forward ? midY - amplitude / 2 : midY + amplitude / 2
        }

        var path = Path()
        var hasStarted = false
        for event in committed where event.endTime >= windowStart {
            let x0 = xPosition(for: event.startTime)
            let x1 = xPosition(for: event.endTime)
            let y = yPosition(forward: event.direction == "forward")
            if !hasStarted {
                path.move(to: CGPoint(x: x0, y: y))
                hasStarted = true
            }
            path.addLine(to: CGPoint(x: x0, y: y))
            path.addLine(to: CGPoint(x: x1, y: y))
        }
        context.stroke(path, with: .color(Self.committedColor), lineWidth: 2.5)

        if let provisional, provisional.currentTime >= windowStart {
            var provisionalPath = Path()
            let x0 = xPosition(for: provisional.startTime)
            let x1 = xPosition(for: provisional.currentTime)
            let y = yPosition(forward: provisional.direction == "forward")
            provisionalPath.move(to: CGPoint(x: x0, y: y))
            provisionalPath.addLine(to: CGPoint(x: x1, y: y))
            context.stroke(
                provisionalPath,
                with: .color(Self.provisionalColor),
                style: StrokeStyle(lineWidth: 2.5, dash: [5, 4])
            )
        }
    }
}
