// CrossfaderCalibrationSweep — the pure state machine behind the mandatory
// three-position calibration flow (full left, centre, full right).
//
// The UI owns prompts and buttons; this owns the measurement rules. Keeping
// them apart is what lets the rules be tested without a controller attached,
// and what lets iOS reuse the identical flow if it ever drives calibration.
//
// A position is only accepted once the incoming stream has been STILL for
// `settleSampleCount` consecutive samples inside `settleTolerance`. Hardware
// crossfaders bounce off an end stop and controllers stream at up to ~800 Hz,
// so sampling "whatever value was current when the operator clicked" records
// the bounce, not the stop.
//
// Foundation only. No Core MIDI, no UI, no clock reads beyond the caller's
// supplied timestamps.

import Foundation

/// One live reading of the calibrated address, tagged with the identity of the
/// MIDI message it came from.
///
/// The host polls for the latest value on a timer, so the SAME message is read
/// many times over. `observationSequence` is a monotonically increasing counter
/// of messages actually received on that address, which is what lets the sweep
/// tell "the operator is holding the fader and it keeps sending" apart from
/// "nothing has arrived since app launch and we are re-reading a stale value".
///
/// Without this distinction a completely stationary — or entirely absent —
/// crossfader settles every step instantly, which is how the 2026-09-04
/// hardware smoke committed left 0 / centre 0 / right 126.
struct CrossfaderCalibrationObservation: Equatable, Sendable {
    let rawValue: Int
    /// Count of messages received on this address, monotonically increasing.
    /// Never reset by a step, a retry, or a take starting.
    let observationSequence: Int

    init(rawValue: Int, observationSequence: Int) {
        self.rawValue = rawValue
        self.observationSequence = observationSequence
    }
}

/// Live progress through the calibration sweep.
enum CrossfaderCalibrationSweepState: Equatable, Sendable {
    /// Showing `step`'s instruction and collecting NOTHING.
    ///
    /// The sweep used to begin sampling the instant it was created, so the
    /// fader's existing position plus its jitter could settle a position
    /// before the operator had read the instruction or moved anything. On the
    /// 2026-09-05 hardware test that produced two invalid sweeps in a row.
    /// A stage now waits here until the operator explicitly arms it.
    case awaitingArm(step: CrossfaderCalibrationStep)
    /// Armed and waiting for `step` to settle. `settledSampleCount` counts how
    /// far into the stability requirement the current hold has got.
    case capturing(step: CrossfaderCalibrationStep, settledSampleCount: Int)
    /// All three positions measured. The calibration still has to pass
    /// `validationIssues()` before it may be persisted.
    case complete(CrossfaderCalibration)

    var currentStep: CrossfaderCalibrationStep? {
        switch self {
        case .awaitingArm(let step): return step
        case .capturing(let step, _): return step
        case .complete: return nil
        }
    }

    /// `true` while the sweep is showing an instruction and deliberately
    /// ignoring every observation.
    var isAwaitingArm: Bool {
        if case .awaitingArm = self { return true }
        return false
    }

    var calibration: CrossfaderCalibration? {
        switch self {
        case .awaitingArm, .capturing: return nil
        case .complete(let calibration): return calibration
        }
    }
}

extension CrossfaderCalibrationStep {
    /// Label for the explicit capture action that arms this step.
    var captureActionTitle: String {
        switch self {
        case .fullLeft: return "Capture Full Left"
        case .center: return "Capture Centre"
        case .fullRight: return "Capture Full Right"
        }
    }

    var displayName: String {
        switch self {
        case .fullLeft: return "Full left"
        case .center: return "Centre"
        case .fullRight: return "Full right"
        }
    }
}

/// Drives one calibration sweep.
///
/// A value type: `ingest` returns the next sweep rather than mutating shared
/// state, so a caller can hold the sweep in SwiftUI state, replay it in a
/// test, or discard it without side effects.
struct CrossfaderCalibrationSweep: Equatable, Sendable {

    /// Consecutive in-tolerance samples required before a position is taken.
    static let defaultSettleSampleCount = 12
    /// How far the raw value may wander, in MIDI steps, and still count as held.
    static let defaultSettleTolerance = 1
    /// How many NEW messages must arrive on the calibrated address after a step
    /// begins before that step may capture a value.
    ///
    /// The settle counter alone is satisfied by a stale value re-read on a
    /// timer, so on its own it proves stability, not liveness. This proves the
    /// control is actually transmitting for THIS step; combined with
    /// `CrossfaderCalibration.minimumCenterMargin` (which proves the three
    /// measurements are actually different), a fader that is not moving cannot
    /// produce a committable calibration.
    static let defaultMinimumFreshObservations = 8

    let address: CrossfaderMIDIAddress
    let openEnd: CrossfaderOpenEnd
    let activeDeck: CrossfaderActiveDeck
    let settleSampleCount: Int
    let settleTolerance: Int
    let minimumFreshObservations: Int
    let operatorNote: String

    private(set) var state: CrossfaderCalibrationSweepState
    private(set) var capturedValues: [CrossfaderCalibrationStep: Int]
    /// The value the current hold is settling around, and how many samples
    /// have agreed with it so far.
    private var candidateValue: Int?
    private var candidateSampleCount: Int
    /// New messages seen on the calibrated address since the CURRENT step
    /// began. Reset when a step is captured and when a step is retried.
    private(set) var freshObservationCount: Int
    /// Observation sequence at the moment the CURRENT stage was armed.
    ///
    /// Only observations strictly newer than this belong to the stage. This
    /// is what makes "press Capture, THEN the fader's readings count" a real
    /// boundary rather than a UI convention — a cached app-lifetime value can
    /// never satisfy a stage, and a retry cannot be paid for by samples that
    /// arrived before it.
    private(set) var armBoundarySequence: Int?
    /// Highest observation sequence already fed into the current stage.
    private var lastIngestedSequence: Int?

    init(
        address: CrossfaderMIDIAddress,
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck,
        settleSampleCount: Int = CrossfaderCalibrationSweep.defaultSettleSampleCount,
        settleTolerance: Int = CrossfaderCalibrationSweep.defaultSettleTolerance,
        minimumFreshObservations: Int = CrossfaderCalibrationSweep.defaultMinimumFreshObservations,
        operatorNote: String = ""
    ) {
        self.address = address
        self.openEnd = openEnd
        self.activeDeck = activeDeck
        self.settleSampleCount = max(1, settleSampleCount)
        self.settleTolerance = max(0, settleTolerance)
        self.minimumFreshObservations = max(1, minimumFreshObservations)
        self.operatorNote = operatorNote
        self.state = .awaitingArm(step: .fullLeft)
        self.capturedValues = [:]
        self.candidateValue = nil
        self.candidateSampleCount = 0
        self.freshObservationCount = 0
        self.armBoundarySequence = nil
        self.lastIngestedSequence = nil
    }

    /// Arm the current stage at `observationSequence`.
    ///
    /// The operator has read the instruction and presented the position. Only
    /// observations after this boundary count toward the stage. A no-op when
    /// the sweep is already capturing or complete — a stage can never
    /// auto-arm, and arming twice cannot widen an existing window.
    func arming(atObservationSequence observationSequence: Int) -> CrossfaderCalibrationSweep {
        guard case .awaitingArm(let step) = state else { return self }
        var next = self
        next.armBoundarySequence = observationSequence
        next.lastIngestedSequence = nil
        next.candidateValue = nil
        next.candidateSampleCount = 0
        next.freshObservationCount = 0
        next.state = .capturing(step: step, settledSampleCount: 0)
        return next
    }

    /// Feed one raw MIDI value from the calibrated address.
    ///
    /// Samples from any other address must be filtered out by the caller —
    /// this type deliberately does not silently ignore them, because a sweep
    /// that quietly discards traffic is how a calibration ends up describing
    /// the wrong control.
    /// - Parameter isFreshObservation: `true` when this sample came from a MIDI
    ///   message that has not been fed in before. A host polling a "latest
    ///   value" cache passes `false` for every re-read of a message it has
    ///   already reported, which is what stops a stale value from settling a
    ///   step the operator never performed.
    func ingesting(
        rawValue: Int,
        observationSequence: Int,
        now: Date
    ) -> CrossfaderCalibrationSweep {
        // Unarmed stages collect nothing at all. This is the D4 boundary.
        guard case .capturing(let step, _) = state else { return self }
        guard let armBoundary = armBoundarySequence else { return self }
        // Anything at or before the arm boundary arrived BEFORE the operator
        // pressed Capture, so it describes a position they were not asked to
        // present yet.
        guard observationSequence > armBoundary else { return self }
        guard (0...127).contains(rawValue) else { return self }

        var next = self
        let isFreshObservation = observationSequence > (lastIngestedSequence ?? armBoundary)
        if isFreshObservation {
            next.freshObservationCount += 1
            next.lastIngestedSequence = observationSequence
        }
        if let candidate = candidateValue, abs(rawValue - candidate) <= settleTolerance {
            next.candidateSampleCount += 1
        } else {
            next.candidateValue = rawValue
            next.candidateSampleCount = 1
        }

        // Both gates must be met: the hold has to be STABLE (settle counter)
        // and the address has to be LIVE for this step (fresh counter). A
        // stationary or disconnected fader satisfies only the first.
        guard next.candidateSampleCount >= settleSampleCount,
              next.freshObservationCount >= minimumFreshObservations,
              let settled = next.candidateValue else {
            next.state = .capturing(step: step, settledSampleCount: next.candidateSampleCount)
            return next
        }

        next.capturedValues[step] = settled
        next.candidateValue = nil
        next.candidateSampleCount = 0
        next.freshObservationCount = 0
        // Completing a stage does NOT arm the next one. The operator has to
        // read the next instruction, present that position, and press Capture.
        next.armBoundarySequence = nil
        next.lastIngestedSequence = nil

        guard let following = step.next else {
            next.state = .complete(next.makeCalibration(now: now))
            return next
        }
        next.state = .awaitingArm(step: following)
        return next
    }

    /// Discard the current step's measurement and hold it again. Used by the
    /// UI's "redo this position" affordance.
    /// Discard the current step's measurement and return it to its UNARMED
    /// instructional state. Previously completed steps are untouched.
    func retryingCurrentStep() -> CrossfaderCalibrationSweep {
        guard let step = state.currentStep else { return self }
        var next = self
        next.capturedValues[step] = nil
        next.candidateValue = nil
        next.candidateSampleCount = 0
        // A retry re-requires live traffic for this step. Carrying the count
        // over would let the messages that produced the REJECTED measurement
        // pay for the replacement one, and dropping the arm boundary means
        // every observation received before re-arming is rejected too.
        next.freshObservationCount = 0
        next.armBoundarySequence = nil
        next.lastIngestedSequence = nil
        next.state = .awaitingArm(step: step)
        return next
    }

    /// Progress toward this step's liveness requirement, 0…1.
    var freshObservationProgress: Double {
        if case .awaitingArm = state { return 0 }
        guard case .capturing = state else { return 1 }
        return min(1, Double(freshObservationCount) / Double(minimumFreshObservations))
    }

    /// Progress through the current hold, 0…1, for a live meter.
    var settleProgress: Double {
        if case .awaitingArm = state { return 0 }
        guard case .capturing(_, let settled) = state else { return 1 }
        return min(1, Double(settled) / Double(settleSampleCount))
    }

    private func makeCalibration(now: Date) -> CrossfaderCalibration {
        CrossfaderCalibration(
            address: address,
            fullLeftRawValue: capturedValues[.fullLeft] ?? 0,
            centerRawValue: capturedValues[.center] ?? 0,
            fullRightRawValue: capturedValues[.fullRight] ?? 0,
            openEnd: openEnd,
            activeDeck: activeDeck,
            calibratedAt: now,
            operatorNote: operatorNote
        )
    }
}
