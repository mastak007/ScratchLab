// VirtualPlatter.swift
// ScratchLab
//
// Isolated prototype model for the new consumer "virtual platter" direction.
//
// This file is intentionally self-contained and has NO dependency on the
// capture pipeline, dataset/export code, or any ML / ScratchAnalyzer logic.
// Grading here is pure, exact gesture ground truth — no classifier.
//
// It is safe to delete this file (and VirtualPlatterPrototypeView.swift plus
// the DEBUG menu entry in MainMenuView.swift) to fully remove the prototype.

import CoreGraphics
import Foundation

// MARK: - Direction

/// Spin direction of the virtual record under the finger.
///
/// Naming mirrors the existing `ScratchMotionDirection` so the prototype reads
/// consistently with the rest of the codebase. "forward" means the record is
/// moving the way it would during normal playback (here: clockwise drag);
/// "backward" is a pull-back.
enum PlatterDirection: String, Equatable {
    case forward
    case backward
    case idle

    var label: String {
        switch self {
        case .forward: return "Forward"
        case .backward: return "Back"
        case .idle: return "Still"
        }
    }

    /// Sign of the angular velocity associated with this direction
    /// (+1 forward, -1 backward, 0 idle).
    var sign: Int {
        switch self {
        case .forward: return 1
        case .backward: return -1
        case .idle: return 0
        }
    }
}

// MARK: - Angle helpers (pure, testable)

enum PlatterGeometry {
    /// Screen-space angle (radians) of `point` measured about `center`.
    ///
    /// Uses screen coordinates (y grows downward, as in SwiftUI/UIKit), so a
    /// clockwise visual drag produces an increasing angle.
    static func angle(of point: CGPoint, about center: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    /// Shortest signed angular delta from `from` to `to`, normalized to
    /// (-π, π]. This is what makes wrap-around across the ±π seam behave.
    static func signedDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = to - from
        while delta <= -CGFloat.pi { delta += 2 * .pi }
        while delta > CGFloat.pi { delta -= 2 * .pi }
        return delta
    }
}

// MARK: - Record phase to sample position

/// Maps the virtual record phase to the sample position that should be heard.
///
/// The sample start is a fixed cue point inside the visible drill zone. The
/// mapping is intentionally pure so audio playback can be driven by record
/// motion without letting the player run as an autonomous one-shot.
enum VirtualPlatterSampleMapper {
    static let ghostSpan = 0.45
    static let cueFraction = 0.5

    static var cuePhase: Double { ghostSpan * cueFraction }

    /// Returns a normalized sample position for the current record phase.
    ///
    /// `nil` means the marker is in the silent prep zone before the cue for
    /// this turn. After the cue, the remaining turn is mapped linearly across
    /// the whole sample, so moving the record backward moves back through the
    /// same sample positions.
    static func normalizedSamplePosition(recordPhase: Double) -> Double? {
        guard recordPhase.isFinite else { return nil }

        let fraction = recordPhase - floor(recordPhase)
        guard fraction >= cuePhase else { return nil }

        let audibleSpan = max(1.0 - cuePhase, 0.0001)
        return min(max((fraction - cuePhase) / audibleSpan, 0), 1)
    }
}

// MARK: - Virtual platter

/// Tracks the virtual record position driven by a finger drag and derives
/// velocity, direction, and a simple normalized speed.
///
/// `ObservableObject` so the prototype SwiftUI surface can bind to it. The
/// logic is plain math with no UI/hardware dependency, so it is fully unit
/// testable by driving the same `begin/update/end` calls a gesture would.
final class VirtualPlatter: ObservableObject {

    /// Angular speed (radians/sec) that reads as a full-strength scratch
    /// (`normalizedSpeed` ≈ 1). Lowered from 4π (≈2 rev/s) so a normal
    /// finger scratch actually fills the meter instead of sitting near zero.
    let referenceAngularSpeed: CGFloat

    /// While moving, drop back to `.idle` below this smoothed speed.
    let idleAngularSpeed: CGFloat

    /// From idle, only wake into a direction once smoothed speed exceeds
    /// this. The gap vs `idleAngularSpeed` is hysteresis: it stops the
    /// forward/back/idle chatter you get from a single hard threshold and
    /// makes direction flips at a scratch turnaround read crisply.
    let wakeAngularSpeed: CGFloat

    /// Time constant (sec) of the velocity low-pass. Raw finger samples are
    /// jumpy; a short EMA gives the weighty, continuous feel of a record
    /// instead of a twitchy slider, while staying responsive enough that a
    /// flick still registers within a couple of frames.
    let velocitySmoothingTime: CGFloat

    /// Perceptual curve applied to normalized speed (`< 1` lifts slow moves).
    /// Makes gentle baby-scratch motion visible without losing fast headroom.
    let speedResponseExponent: Double

    /// Accumulated record position in radians. Not wrapped, so it grows or
    /// shrinks past ±2π as you keep spinning — this is the "track position".
    /// Tracks the finger 1:1 with no smoothing, so the record stays glued
    /// to the fingertip.
    @Published private(set) var angle: CGFloat = 0

    /// Smoothed signed angular velocity in radians/sec (+ forward, − back).
    @Published private(set) var angularVelocity: CGFloat = 0

    /// Derived forward / backward / idle state.
    @Published private(set) var direction: PlatterDirection = .idle

    /// Curved, clamped speed in 0...1 for meters and the live ribbon.
    @Published private(set) var normalizedSpeed: Double = 0

    /// True while a finger is down on the platter.
    @Published private(set) var isDragging: Bool = false

    private var lastAngle: CGFloat = 0
    private var lastTimestamp: TimeInterval?
    /// Timestamp of the most recent real drag sample, so `settle(at:)` can
    /// tell "finger paused mid-press" from "still actively scratching".
    private var lastInputTimestamp: TimeInterval?
    private var isInMotion = false

    /// Below this gap (sec) since the last drag sample, `settle` leaves the
    /// velocity alone — the finger is still feeding updates this frame.
    private let staleInputInterval: TimeInterval = 0.045

    init(referenceAngularSpeed: CGFloat = 9.0,
         idleAngularSpeed: CGFloat = 0.7,
         wakeAngularSpeed: CGFloat = 1.1,
         velocitySmoothingTime: CGFloat = 0.07,
         speedResponseExponent: Double = 0.75) {
        self.referenceAngularSpeed = max(referenceAngularSpeed, 0.0001)
        self.idleAngularSpeed = max(idleAngularSpeed, 0)
        self.wakeAngularSpeed = max(wakeAngularSpeed, idleAngularSpeed)
        self.velocitySmoothingTime = max(velocitySmoothingTime, 0.0001)
        self.speedResponseExponent = max(speedResponseExponent, 0.0001)
    }

    /// Finger touched down. Anchors the angle reference; no motion yet.
    func beginDrag(at point: CGPoint, center: CGPoint, timestamp: TimeInterval) {
        isDragging = true
        lastAngle = PlatterGeometry.angle(of: point, about: center)
        lastTimestamp = timestamp
        lastInputTimestamp = timestamp
        angularVelocity = 0
        normalizedSpeed = 0
        isInMotion = false
        direction = .idle
    }

    /// Finger moved. Advances `angle` by the shortest signed delta (1:1, no
    /// smoothing) and derives a smoothed velocity / direction / speed.
    func updateDrag(to point: CGPoint, center: CGPoint, timestamp: TimeInterval) {
        if !isDragging {
            beginDrag(at: point, center: center, timestamp: timestamp)
            return
        }

        let currentAngle = PlatterGeometry.angle(of: point, about: center)
        let delta = PlatterGeometry.signedDelta(from: lastAngle, to: currentAngle)
        angle += delta

        if let last = lastTimestamp {
            let dt = timestamp - last
            if dt > 0 {
                let rawVelocity = delta / CGFloat(dt)
                applySmoothing(towards: rawVelocity, dt: CGFloat(dt))
            }
        }

        refreshDerivedState()

        lastAngle = currentAngle
        lastTimestamp = timestamp
        lastInputTimestamp = timestamp
    }

    /// Called every display frame while a finger is down. If the finger has
    /// stopped feeding samples (held still on the record) the smoothed
    /// velocity decays toward zero so the platter reads "Still" and the
    /// ribbon shrinks, instead of holding a stale speed like a slider would.
    func settle(at timestamp: TimeInterval) {
        guard isDragging,
              let lastInput = lastInputTimestamp,
              timestamp - lastInput > staleInputInterval,
              let last = lastTimestamp else { return }

        let dt = timestamp - last
        guard dt > 0 else { return }

        applySmoothing(towards: 0, dt: CGFloat(dt))
        refreshDerivedState()
        lastTimestamp = timestamp
    }

    /// Finger lifted. Motion stops immediately (no inertia in the prototype).
    func endDrag() {
        isDragging = false
        angularVelocity = 0
        normalizedSpeed = 0
        isInMotion = false
        direction = .idle
        lastTimestamp = nil
        lastInputTimestamp = nil
    }

    /// Reset everything back to a fresh platter.
    func reset() {
        endDrag()
        angle = 0
        lastAngle = 0
    }

    // MARK: - Internals

    /// Time-aware exponential moving average toward `target`.
    private func applySmoothing(towards target: CGFloat, dt: CGFloat) {
        let alpha = 1 - exp(-dt / velocitySmoothingTime)
        angularVelocity += alpha * (target - angularVelocity)
    }

    private func refreshDerivedState() {
        let speed = abs(angularVelocity)
        let base = min(1.0, Double(speed / referenceAngularSpeed))
        normalizedSpeed = pow(base, speedResponseExponent)

        if isInMotion {
            if speed < idleAngularSpeed {
                isInMotion = false
                direction = .idle
            } else {
                direction = angularVelocity >= 0 ? .forward : .backward
            }
        } else if speed >= wakeAngularSpeed {
            isInMotion = true
            direction = angularVelocity >= 0 ? .forward : .backward
        } else {
            direction = .idle
        }

        // While idle, pin the speed reading to 0. Sub-wake digitizer noise
        // otherwise leaves a tiny shimmering velocity that pulses the
        // speed-reactive marker glow/size — the "slight idle jitter". This
        // only touches the idle case: the 1:1 finger-glued angle, the
        // direction-flip logic, in-motion speed feel, and lock grading are
        // all unchanged.
        if direction == .idle {
            normalizedSpeed = 0
        }
    }
}

// MARK: - Exact ground-truth grading (no ML)

/// A known target stroke the player should match: a single direction held,
/// above a minimum speed, during a fixed time window. This is the ground
/// truth — there is no classifier or audio analysis involved.
struct ScratchTargetStroke: Equatable {
    let direction: PlatterDirection
    /// Window start/end in seconds, relative to the stage clock.
    let start: TimeInterval
    let end: TimeInterval
    /// Minimum normalized speed (0...1) that counts as "really moving".
    let minimumNormalizedSpeed: Double

    init(direction: PlatterDirection,
         start: TimeInterval,
         end: TimeInterval,
         minimumNormalizedSpeed: Double = 0.12) {
        self.direction = direction
        self.start = start
        self.end = max(end, start)
        self.minimumNormalizedSpeed = minimumNormalizedSpeed
    }

    var duration: TimeInterval { end - start }
}

/// Result of comparing live motion against a `ScratchTargetStroke`.
struct LockAssessment: Equatable {
    enum Phase: String, Equatable {
        case waiting   // before the window
        case active    // inside the window, not yet locked
        case locked    // matched long enough — success
        case missed    // window passed without enough match
    }

    let phase: Phase
    /// Fraction of the required matched time achieved so far (0...1).
    let progress: Double

    var isSuccess: Bool { phase == .locked }
}

/// Stateful evaluator that accumulates how long the live direction matched the
/// target inside its window. Pure logic — feed it the platter's derived
/// `direction` / `normalizedSpeed` and a clock; it never touches audio or ML.
struct ScratchLockEvaluator {
    let stroke: ScratchTargetStroke
    /// Fraction of the window that must be matched to lock (0...1).
    let requiredCoverage: Double

    private(set) var matchedDuration: TimeInterval = 0
    private(set) var locked: Bool = false
    private var lastTimestamp: TimeInterval?

    init(stroke: ScratchTargetStroke, requiredCoverage: Double = 0.6) {
        self.stroke = stroke
        self.requiredCoverage = min(max(requiredCoverage, 0.0001), 1)
    }

    private var requiredMatchedDuration: TimeInterval {
        max(stroke.duration * requiredCoverage, 0.0001)
    }

    /// Advance the evaluator. Returns the current assessment.
    mutating func evaluate(direction: PlatterDirection,
                           normalizedSpeed: Double,
                           at timestamp: TimeInterval) -> LockAssessment {
        defer { lastTimestamp = timestamp }

        // Before the window opens.
        if timestamp < stroke.start {
            return LockAssessment(phase: .waiting, progress: 0)
        }

        // Inside the window: accumulate matched time.
        if timestamp <= stroke.end {
            if let last = lastTimestamp, timestamp > last {
                let dt = timestamp - last
                let directionMatches = direction == stroke.direction
                let fastEnough = normalizedSpeed >= stroke.minimumNormalizedSpeed
                if directionMatches && fastEnough {
                    matchedDuration += dt
                }
            }

            if matchedDuration >= requiredMatchedDuration {
                locked = true
            }

            let progress = min(1.0, matchedDuration / requiredMatchedDuration)
            return LockAssessment(phase: locked ? .locked : .active,
                                  progress: progress)
        }

        // Window closed.
        let progress = min(1.0, matchedDuration / requiredMatchedDuration)
        if locked || matchedDuration >= requiredMatchedDuration {
            return LockAssessment(phase: .locked, progress: 1)
        }
        return LockAssessment(phase: .missed, progress: progress)
    }

    mutating func reset() {
        matchedDuration = 0
        locked = false
        lastTimestamp = nil
    }
}
