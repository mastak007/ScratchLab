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

/// A real, change-only MIDI control observation, validated by its connection
/// owner. This is transient live presentation state, never a recorded packet.
struct LiveCrossfaderStateSnapshot: Equatable, Sendable {
    let sourceIdentifier: String
    let channel: Int
    let controller: Int
    let connectionGeneration: UInt64
    let calibrationID: String
    let calibration: CrossfaderCalibration
    let rawValue: Int
    let observedHostTime: Double
    let observationSequence: Int
    let windowStartHostTime: Double
    /// First observation under this exact connection/mapping/calibration.
    let validFromHostTime: Double

    func hasSameProvenance(as other: Self) -> Bool {
        sourceIdentifier == other.sourceIdentifier && channel == other.channel
            && controller == other.controller && connectionGeneration == other.connectionGeneration
            && calibrationID == other.calibrationID && calibration == other.calibration
            && windowStartHostTime == other.windowStartHostTime
            && validFromHostTime == other.validFromHostTime
    }
}

/// Small dependency bundle a `LivePerformedNotationTracker` polls. Plain
/// closures rather than a reference to `MacCaptureEngine` — the tracker has
/// no dependency on the engine and is independently testable with synthetic
/// data.
struct LivePerformedNotationDataSource {
    /// The currently selected MIDI input source name — mirrors
    /// `MacCaptureEngine.selectedMIDIInputSourceName` ("Not Connected" when
    /// none selected).
    let selectedMIDISourceName: () -> String
    /// Stable Core MIDI identity for exact calibration/event correlation.
    let selectedMIDISourceIdentifier: () -> String
    /// Queue-confined, non-destructive snapshot of accumulated MIDI CC
    /// telemetry — mirrors `MacCaptureEngine.capturedMidiCCEventsSnapshot()`.
    let capturedMidiCCEventsSnapshot: () -> [CaptureCore.RawMixerMIDIEvent]
    /// Non-destructive camera-fallback movement snapshot, or `nil` when no
    /// camera builder is currently active at all (distinct from "active but
    /// has seen no movement yet", which is an empty array).
    let cameraMovementEventsSnapshot: (_ now: CFTimeInterval) -> [CaptureCore.DetectedNotationRecordMovementEvent]?
    /// The active crossfader calibration (already resolved against the
    /// selected source's learned mapping), or `nil`. The tracker derives
    /// take-scoped, time-aligned crossfader state from the CC snapshot through
    /// the existing `CrossfaderStateDeriver`. Defaults to `nil` so synthetic
    /// data sources that only exercise platter motion stay source-compatible.
    let activeCrossfaderCalibration: () -> CrossfaderCalibration?
    /// Immutable state captured at this take's media-start boundary.
    let activeCrossfaderTakeStartState: () -> CaptureCore.CrossfaderTakeStartState?
    /// When supplied, nil explicitly invalidates buffered fader evidence.
    /// The owner checks the live connection, learned address and calibration.
    let activeCrossfaderState: (() -> LiveCrossfaderStateSnapshot?)?
    /// Correlated MIDI packet and sample-relative phase, captured by the
    /// active playback owner. Nil means the loop cannot be aligned truthfully.
    /// Transient presentation input; never supplied to physical decoding.
    let activePlaybackLoopContext: () -> PlaybackLoopContext?

    init(
        selectedMIDISourceName: @escaping () -> String,
        selectedMIDISourceIdentifier: @escaping () -> String = { "" },
        capturedMidiCCEventsSnapshot: @escaping () -> [CaptureCore.RawMixerMIDIEvent],
        cameraMovementEventsSnapshot: @escaping (_ now: CFTimeInterval) -> [CaptureCore.DetectedNotationRecordMovementEvent]?,
        activeCrossfaderCalibration: @escaping () -> CrossfaderCalibration? = { nil },
        activeCrossfaderTakeStartState: @escaping () -> CaptureCore.CrossfaderTakeStartState? = { nil },
        activeCrossfaderState: (() -> LiveCrossfaderStateSnapshot?)? = nil,
        activePlaybackLoopContext: @escaping () -> PlaybackLoopContext? = { nil }
    ) {
        self.selectedMIDISourceName = selectedMIDISourceName
        self.selectedMIDISourceIdentifier = selectedMIDISourceIdentifier
        self.capturedMidiCCEventsSnapshot = capturedMidiCCEventsSnapshot
        self.cameraMovementEventsSnapshot = cameraMovementEventsSnapshot
        self.activeCrossfaderCalibration = activeCrossfaderCalibration
        self.activeCrossfaderTakeStartState = activeCrossfaderTakeStartState
        self.activeCrossfaderState = activeCrossfaderState
        self.activePlaybackLoopContext = activePlaybackLoopContext
    }
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
        continuousProvisional: CaptureCore.ProvisionalPlatterMovement?,
        trajectorySegments: [CaptureCore.PlatterTrajectorySegment],
        platterEvidenceIntervals: [CaptureCore.PlatterEvidenceInterval],
        faderDerivation: CrossfaderDerivation?,
        /// Sample-loop length in the same calibrated platter revolutions as
        /// the aligned continuous positions; nil when alignment is unknown.
        wrapPeriod: Double?
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
        guard case .tracking(let committed, let provisional, _, _, _, _, _, _) = state else { return [] }
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
    /// position-continuous trajectory. An aligned sample loop retains its
    /// playback scale and origin; otherwise the rolling window is fitted to
    /// visible motion. Presentation-only, like `renderedEvents`.
    static func continuousRenderedEvents(
        for state: LiveNotationTrackingState
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard case .tracking(_, _, let continuousCommitted, let continuousProvisional, _, _, _, let period) = state else { return [] }
        var events = continuousCommitted
        // The general preview may show any open run. Canonical Tear review
        // only sees it after the shared decoder's evidence gates pass, so an
        // unfinished tail cannot invalidate already committed gestures.
        if let continuousProvisional, continuousProvisional.meetsNoiseGates {
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
                confidence: 0.80,
                source: "live_preview"
            ))
        }
        // A correlated loop projection already has a stable scale and origin.
        // Min/max fitting here would destroy both. Unaligned previews retain
        // their established rolling normalization.
        return period == nil ? windowNormalized(events) : windowVisible(events)
    }

    /// Rolling window (seconds) over which continuous live Tear positions are
    /// re-normalised, matching `LivePerformedNotationCard.renderedDomain`.
    private static let continuousTearWindowSeconds: TimeInterval = 3.2

    /// Retain the established rolling time window without changing coordinates.
    private static func windowVisible(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard let latest = events.map(\.endTime).max() else { return [] }
        let windowStart = max(0, latest - continuousTearWindowSeconds)
        return events.filter { $0.endTime >= windowStart }
    }

    /// Fit unaligned telemetry with one affine transform over visible motion.
    private static func windowNormalized(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        let visible = windowVisible(events)
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

    /// Continuous presentation input for the canonical Tear projection.
    var continuousRenderedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        Self.continuousRenderedEvents(for: state)
    }

    /// The aligned path reconstructs raw steps and divides by the established
    /// direct-MIDI steps/revolution calibration. The fallback remains fitted.
    var continuousPlatterCoordinates: CaptureCore.PlatterNotationCoordinates {
        continuousWrapPeriod == nil
            ? .normalizedTakeLocal(reference: "continuous window-normalised platter telemetry for the canonical Tear projection")
            : .raneOneMKIIDirectMIDI()
    }

    /// Dense measured platter trajectory from the same decoder pass as the
    /// live movement events. This remains raw step-domain evidence here; no
    /// presentation coordinate claim is made by this accessor.
    var platterTrajectorySegments: [CaptureCore.PlatterTrajectorySegment] {
        if case .tracking(_, _, _, _, let trajectory, _, _, _) = state {
            return trajectory
        }
        return []
    }

    /// `decodePlatterCore`'s provenance intervals (observed stillness, packet
    /// gaps, clock discontinuities) for the canonical live Tear projection.
    var platterEvidenceIntervals: [CaptureCore.PlatterEvidenceInterval] {
        if case .tracking(_, _, _, _, _, let intervals, _, _) = state { return intervals }
        return []
    }

    /// Take-scoped, time-aligned crossfader derivation for the canonical live
    /// Tear projection, or `nil` when no usable calibration / CC8 evidence
    /// exists (the projection then truthfully reports FADER UNKNOWN).
    var faderDerivation: CrossfaderDerivation? {
        if case .tracking(_, _, _, _, _, _, let derivation, _) = state { return derivation }
        return nil
    }

    /// Loop length in calibrated revolutions, retaining the playback origin.
    /// An unknown alignment keeps the existing unwrapped presentation.
    var continuousWrapPeriod: Double? {
        if case .tracking(_, _, _, _, _, _, _, let period) = state { return period }
        return nil
    }

    /// Convert the existing decoder's coordinates with ONE affine transform.
    /// The requested anchor position comes from that same decoder pass; this
    /// method never integrates MIDI or estimates phase from a ring value.
    private static func loopAlignedContinuous(
        result: CaptureCore.PlatterMovementDecodeResult,
        context: PlaybackLoopContext?,
        confirmedContext: PlaybackLoopContext?,
        anchorPacket: CaptureCore.RawMixerMIDIEvent?
    ) -> (events: [CaptureCore.DetectedNotationRecordMovementEvent], provisional: CaptureCore.ProvisionalPlatterMovement?, period: Double)? {
        guard let context, let confirmedContext, let anchorPacket,
              context.generation == confirmedContext.generation,
              context.sampleID == confirmedContext.sampleID,
              context.validFromTimestamp == confirmedContext.validFromTimestamp,
              context.anchor.connectionGeneration == confirmedContext.anchor.connectionGeneration,
              context.anchor.deviceName == confirmedContext.anchor.deviceName,
              context.anchor.channel == 1, confirmedContext.anchor.channel == 1,
              !context.sampleID.isEmpty,
              context.phaseSteps.isFinite,
              context.loopLengthInSteps.isFinite, context.loopLengthInSteps > 0,
              context.loopLengthInSteps == confirmedContext.loopLengthInSteps,
              context.validFromTimestamp.isFinite,
              anchorPacket.timestamp.isFinite, anchorPacket.takeRelativeTime.isFinite,
              anchorPacket.timestamp >= context.validFromTimestamp,
              let referenceSteps = result.referencePositionSteps, referenceSteps.isFinite,
              result.normalizationOriginSteps.isFinite,
              result.normalizationSpanSteps.isFinite, result.normalizationSpanSteps > 0 else { return nil }

        var intervals = result.continuousEvents.map { $0.startTime...$0.endTime }
        if let provisional = result.continuousProvisionalMovement {
            intervals.append(provisional.startTime...provisional.currentTime)
        }
        guard let latest = intervals.map(\.upperBound).max() else { return nil }
        let visible = intervals.filter { $0.upperBound >= max(0, latest - continuousTearWindowSeconds) }
        guard let first = visible.map(\.lowerBound).min() else { return nil }
        let hostOrigin = anchorPacket.timestamp - anchorPacket.takeRelativeTime
        // Never apply a newly loaded sample or ownership epoch to older motion.
        guard first + hostOrigin >= context.validFromTimestamp else { return nil }
        let connectedStart = min(first, anchorPacket.takeRelativeTime)
        let connectedEnd = max(latest, anchorPacket.takeRelativeTime)
        let hasUncertainConnection = result.platterEvidenceIntervals.contains { interval in
            guard interval.endTime >= connectedStart, interval.startTime <= connectedEnd else { return false }
            switch interval.kind {
            case .observedStillness, .discardedMotion: return false
            case .packetGap, .clockDiscontinuity, .insufficientSampling, .unknown: return true
            }
        }
        guard !hasUncertainConnection else { return nil }
        let stepsPerRevolution = PlatterCoordinateSemantics.raneOneMKIIDirectMIDIStepsPerRevolution
        let period = context.loopLengthInSteps / stepsPerRevolution
        guard period.isFinite, period > 0 else { return nil }
        func position(_ normalized: Double) -> Double {
            (context.phaseSteps + result.normalizationOriginSteps
                + normalized * result.normalizationSpanSteps - referenceSteps) / stepsPerRevolution
        }
        let events = result.continuousEvents.map { event in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: event.startTime, endTime: event.endTime,
                startPosition: position(event.startPosition), endPosition: position(event.endPosition),
                direction: event.direction, movementKind: event.movementKind,
                speed: event.speed, confidence: event.confidence, source: event.source
            )
        }
        let provisional = result.continuousProvisionalMovement.map { event in
            CaptureCore.ProvisionalPlatterMovement(
                startTime: event.startTime, currentTime: event.currentTime,
                startPosition: position(event.startPosition), currentPosition: position(event.currentPosition),
                direction: event.direction, movementKind: event.movementKind,
                displacement: event.displacement,
                meetsNoiseGates: event.meetsNoiseGates
            )
        }
        guard events.allSatisfy({ $0.startPosition.isFinite && $0.endPosition.isFinite }),
              provisional.map({ $0.startPosition.isFinite && $0.currentPosition.isFinite }) ?? true else { return nil }
        return (events, provisional, period)
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
        if case .tracking(let committed, let provisional, _, _, _, _, _, _) = state {
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

        let loopContext = dataSource.activePlaybackLoopContext()
        let initialFaderState = dataSource.activeCrossfaderState?()
        let midiSnapshot = dataSource.capturedMidiCCEventsSnapshot()
            .filter { $0.timestamp > baselineTimestamp }
        let matchingAnchors = midiSnapshot.filter { packet in
            guard let anchor = loopContext?.anchor else { return false }
            return packet.controller == 6 && packet.channel == anchor.channel
                && packet.deviceName == anchor.deviceName && packet.timestamp == anchor.timestamp
                && packet.value == anchor.value
        }
        let anchorPacket = matchingAnchors.count == 1 ? matchingAnchors[0] : nil

        let controllerResult = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: sourceName,
            capturedMidi: midiSnapshot,
            referencePacket: anchorPacket
        )
        let aligned = loopAlignedContinuous(
            result: controllerResult, context: loopContext,
            confirmedContext: dataSource.activePlaybackLoopContext(), anchorPacket: anchorPacket
        )
        let usesController = !controllerResult.committedEvents.isEmpty || controllerResult.provisionalMovement != nil

        // A change-only MIDI control keeps its observed position while the
        // same connection remains valid. Extend only this live presentation,
        // through movement already observed; finalized derivation is unchanged.
        let confirmedFaderState = dataSource.activeCrossfaderState?()
        let liveFaderState = initialFaderState.flatMap { initial in
            confirmedFaderState.flatMap { initial.hasSameProvenance(as: $0) ? $0 : nil }
        }
        let observedEnd = usesController
            ? max(controllerResult.continuousEvents.map(\.endTime).max() ?? 0,
                  controllerResult.continuousProvisionalMovement?.currentTime ?? 0)
            : (cameraEvents?.map(\.endTime).max() ?? 0)
        let faderDerivation = Self.deriveCrossfader(
            midiSnapshot: midiSnapshot,
            selectedSourceIdentifier: dataSource.selectedMIDISourceIdentifier(),
            calibration: dataSource.activeCrossfaderCalibration(),
            takeStartState: dataSource.activeCrossfaderTakeStartState(),
            liveState: liveFaderState,
            requiresLiveState: dataSource.activeCrossfaderState != nil,
            baselineTimestamp: baselineTimestamp,
            observedEnd: observedEnd
        )

        if usesController {
            return .tracking(
                committed: controllerResult.committedEvents,
                provisional: controllerResult.provisionalMovement,
                continuousCommitted: aligned?.events ?? controllerResult.continuousEvents,
                continuousProvisional: aligned?.provisional ?? controllerResult.continuousProvisionalMovement,
                trajectorySegments: controllerResult.trajectorySegments,
                platterEvidenceIntervals: controllerResult.platterEvidenceIntervals,
                faderDerivation: faderDerivation,
                wrapPeriod: aligned?.period
            )
        }

        if let cameraEvents, !cameraEvents.isEmpty {
            return .tracking(
                committed: cameraEvents,
                provisional: nil,
                continuousCommitted: cameraEvents,
                continuousProvisional: nil,
                trajectorySegments: [],
                platterEvidenceIntervals: [],
                faderDerivation: faderDerivation,
                // Camera evidence carries no platter-step basis, so there is
                // nothing to state a loop period against.
                wrapPeriod: nil
            )
        }

        return .waiting
    }

    /// Reuse the production crossfader deriver against the take-scoped,
    /// already-baseline-filtered CC snapshot. Returns `nil` when the
    /// calibration is unusable or no matching CC8 evidence exists — never a
    /// fabricated state.
    private static func deriveCrossfader(
        midiSnapshot: [CaptureCore.RawMixerMIDIEvent],
        selectedSourceIdentifier: String,
        calibration: CrossfaderCalibration?,
        takeStartState: CaptureCore.CrossfaderTakeStartState?,
        liveState: LiveCrossfaderStateSnapshot?,
        requiresLiveState: Bool,
        baselineTimestamp: Double,
        observedEnd: Double
    ) -> CrossfaderDerivation? {
        guard let calibration, calibration.isUsable,
              !selectedSourceIdentifier.isEmpty,
              calibration.address.deviceIdentifier == selectedSourceIdentifier else { return nil }
        if requiresLiveState {
            guard let state = liveState,
                  state.sourceIdentifier == selectedSourceIdentifier,
                  state.channel == calibration.address.channel,
                  state.controller == calibration.address.controller,
                  state.calibrationID == calibration.id,
                  state.calibration == calibration,
                  state.connectionGeneration > 0, state.observationSequence > 0,
                  state.observedHostTime.isFinite, state.windowStartHostTime.isFinite,
                  state.validFromHostTime.isFinite,
                  state.observedHostTime >= state.validFromHostTime,
                  calibration.normalized(rawValue: state.rawValue) != nil else { return nil }
        }
        var rawEvents = midiSnapshot
            .filter {
                $0.channel == calibration.address.channel
                    && $0.controller == calibration.address.controller
                    && $0.deviceIdentifier == selectedSourceIdentifier
                    && (!requiresLiveState || ($0.calibrationID == calibration.id
                        && $0.timestamp >= (liveState?.validFromHostTime ?? .infinity)))
            }
            .map { (takeRelativeTime: $0.takeRelativeTime, rawValue: $0.value) }
        let takeStartMatchesLiveState = !requiresLiveState || {
            guard let state = takeStartState, let live = liveState,
                  state.midiConnectionGeneration == live.connectionGeneration,
                  state.midiSourceID == live.sourceIdentifier,
                  state.channel == live.channel, state.controller == live.controller,
                  state.calibrationID == live.calibrationID,
                  let observedTime = state.observedTakeRelativeTime else { return false }
            return live.windowStartHostTime + observedTime >= live.validFromHostTime - 1e-9
        }()
        if rawEvents.isEmpty,
           takeStartMatchesLiveState,
           let state = takeStartState,
           state.isUsableSnapshot,
           state.takeGeneration != nil,
           state.midiConnectionGeneration != nil,
           state.midiSourceID == selectedSourceIdentifier,
           state.channel == calibration.address.channel,
           state.controller == calibration.address.controller,
           state.calibrationID == calibration.id,
           let rawValue = state.rawValue,
           let observedTime = state.observedTakeRelativeTime,
           observedTime < 0 {
            rawEvents = [(takeRelativeTime: 0, rawValue: rawValue)]
        }
        guard !rawEvents.isEmpty || liveState != nil else { return nil }
        let response = (takeStartMatchesLiveState ? takeStartState?.crossfaderCurveResponse : nil) ?? FaderCurveResponse(
            zeroAt: 0,
            oneAt: MIDIFaderCurveConstants.sharpScratchCutInWidth,
            shape: .linear
        )
        guard let derivation = CrossfaderStateDeriver.derive(
            rawEvents: rawEvents,
            calibration: calibration,
            response: response
        ) else { return nil }
        guard let state = liveState,
              let position = calibration.normalized(rawValue: state.rawValue) else { return derivation }
        let start = max(0, baselineTimestamp - state.windowStartHostTime,
                        state.validFromHostTime - state.windowStartHostTime,
                        state.observedHostTime - state.windowStartHostTime)
        guard observedEnd.isFinite, observedEnd > start else { return derivation }
        let gain = FaderCurveResponse.gain(forNormalizedPosition: position, response: response)
        let gate = CrossfaderHysteresis.default.instantaneousState(forNormalizedPosition: gain)
        var intervals = derivation.intervals
        var lower = max(start, intervals.last?.endTime ?? start)
        var startPosition = gain
        guard observedEnd > lower else { return derivation }
        if let last = intervals.last, last.state == gate, last.endTime >= start {
            lower = last.startTime
            startPosition = last.startPosition
            intervals.removeLast()
        }
        intervals.append(CrossfaderStateInterval(state: gate, startTime: lower, endTime: observedEnd,
            startPosition: startPosition, endPosition: gain))
        // Holding a real position creates coverage, never an extra MIDI event
        // or a fader click. Historical intervals and semantic events survive.
        return CrossfaderDerivation(intervals: intervals, events: derivation.events)
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
