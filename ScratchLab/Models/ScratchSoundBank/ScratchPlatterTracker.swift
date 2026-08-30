// ScratchPlatterTracker.swift
// ScratchLab — Platter CC6 Ring-Counter Tracker
//
// Pure-logic CC6 ring-counter unwrapper for Rane ONE MKII platters.
// Thread-safe via os_unfair_lock. No audio/MIDI dependency.
// No scoring. No routing.
//
// Rane ONE MKII: CC6 ±1 per event, ~800–935 Hz update.
// Two independent decks: ch=0 (left), ch=1 (right).

import Foundation
import os

/// Explicit coordinate semantics for platter motion.
///
/// Notation and sample playback deliberately consume different coordinates:
/// a committed notation stroke is local to that stroke, while sample playback
/// follows the full signed displacement from the hot-cue origin. Keeping both
/// transforms here, beside the raw ring-counter tracker, prevents presentation
/// code from accidentally reusing the audio clock's accumulated motor phase.
enum PlatterCoordinateSemantics {
    /// Direct-MIDI RANE ONE MKII resolution measured from powered-rotation
    /// hardware runs. The older 3,932-step value belongs to the DVS/timecode
    /// calibration and must not scale direct CC6 gesture travel.
    static let raneOneMKIIDirectMIDIStepsPerRevolution: Double = 3_600

    struct GestureRelativeCoordinates: Equatable, Sendable {
        let startPosition: Double
        let endPosition: Double
        /// Unsigned physical travel as a fraction of one platter revolution.
        /// Deliberately unbounded: a multi-revolution run remains > 1 rather
        /// than being clamped or rescaled by later motion.
        let excursion: Double
    }

    /// Rebase one decoder-committed directional run onto the notation baseline.
    /// Forward rises from baseline; backward returns to baseline. Direction,
    /// timing, and the run's real excursion are retained without consulting any
    /// earlier/later motor phase or inventing another gesture detector.
    static func gestureRelativeNotation(
        signedDisplacementSteps: Double,
        stepsPerRevolution: Double = raneOneMKIIDirectMIDIStepsPerRevolution
    ) -> GestureRelativeCoordinates {
        guard signedDisplacementSteps.isFinite,
              stepsPerRevolution.isFinite,
              stepsPerRevolution > 0 else {
            return GestureRelativeCoordinates(
                startPosition: 0,
                endPosition: 0,
                excursion: 0
            )
        }

        let excursion = abs(signedDisplacementSteps) / stepsPerRevolution
        if signedDisplacementSteps < 0 {
            return GestureRelativeCoordinates(
                startPosition: excursion,
                endPosition: 0,
                excursion: excursion
            )
        }
        return GestureRelativeCoordinates(
            startPosition: 0,
            endPosition: excursion,
            excursion: excursion
        )
    }

    /// Raw signed, unwrapped sample displacement from the hot-cue origin.
    /// No modulo, normalization, or clamp is allowed here: negative and
    /// past-end positions are required by the waveform's BEFORE START / PAST
    /// END states and by the audio renderer's authoritative playhead.
    static func samplePosition(
        rawSignedPosition: Double,
        hotCueOrigin: Double
    ) -> Double {
        rawSignedPosition - hotCueOrigin
    }
}

/// Pure presentation projection for the renderer's signed, unwrapped sample
/// position. Audio remains free to wrap inside the renderer; this projection
/// never does, so moving backward through the hot-cue origin cannot appear at
/// the end of the waveform and forward travel past the content cannot appear
/// back at its start.
struct PlatterSamplePositionProjection: Equatable, Sendable {
    enum Region: Equatable, Sendable {
        case unloaded
        case cue
        case start
        case middle
        case end
        case beforeStart
        case pastEnd
    }

    let framePosition: Double
    let positionSeconds: TimeInterval
    let progress: Double
    let region: Region

    var pastEndOvershootSeconds: TimeInterval {
        guard region == .pastEnd else { return 0 }
        return max(0, positionSeconds - durationSeconds)
    }

    private let durationSeconds: TimeInterval

    static func resolve(
        framePosition: Double,
        contentFrameCount: Int,
        sampleRate: Double,
        cueToleranceSeconds: TimeInterval = 0.005
    ) -> PlatterSamplePositionProjection {
        guard framePosition.isFinite,
              contentFrameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              cueToleranceSeconds.isFinite,
              cueToleranceSeconds >= 0 else {
            return PlatterSamplePositionProjection(
                framePosition: 0,
                positionSeconds: 0,
                progress: 0,
                region: .unloaded,
                durationSeconds: 0
            )
        }

        let contentFrames = Double(contentFrameCount)
        let positionSeconds = framePosition / sampleRate
        let durationSeconds = contentFrames / sampleRate
        let progress = min(max(framePosition / contentFrames, 0), 1)
        let toleranceFrames = max(1, sampleRate * cueToleranceSeconds)

        let region: Region
        if framePosition < -toleranceFrames {
            region = .beforeStart
        } else if framePosition > contentFrames + toleranceFrames {
            region = .pastEnd
        } else if abs(framePosition) <= toleranceFrames {
            region = .cue
        } else if progress < 1.0 / 3.0 {
            region = .start
        } else if progress < 2.0 / 3.0 {
            region = .middle
        } else {
            region = .end
        }

        return PlatterSamplePositionProjection(
            framePosition: framePosition,
            positionSeconds: positionSeconds,
            progress: progress,
            region: region,
            durationSeconds: durationSeconds
        )
    }
}

/// Accumulated platter position from CC6 ring-counter events, per deck.
/// Thread-safe. Call `ingest(channel:value:)` from the MIDI receive thread
/// and read position/velocity from any thread.
final class ScratchPlatterTracker {

    /// Signed accumulated CC6 steps for a single deck.
    private var leftSteps: Int32 = 0
    private var rightSteps: Int32 = 0
    private var leftPrevValue: Int32 = -1     // -1 = uninitialised
    private var rightPrevValue: Int32 = -1

    /// Recent-direction tracking for velocity estimation.
    private var leftRecentDeltas: [Int32] = []
    private var rightRecentDeltas: [Int32] = []
    private let maxRecentDeltas = 16

    private let lock = OSAllocatedUnfairLock()

    // MARK: - Constants

    /// Known platter channels: 0 = left deck, 1 = right deck.
    static let leftChannel = 0
    static let rightChannel = 1

    /// Wrap threshold — a CC6 delta larger than this is a 127↔0 boundary crossing.
    static let wrapThreshold = 64

    /// A deck channel for which no CC6 value has been received yet.
    private static let uninitialisedPrev: Int32 = -1

    // MARK: - Ingest

    /// Feed a raw CC6 value (0–127) for a deck channel.
    /// - Parameters:
    ///   - channel: MIDI channel (0 = left, 1 = right).
    ///   - value: Raw CC6 data byte (0–127).
    /// - Returns: The signed delta applied (normally ±1), or nil if the channel
    ///   is not a known platter channel.
    @discardableResult
    func ingest(channel: Int, value: Int) -> Int? {
        guard channel == Self.leftChannel || channel == Self.rightChannel else {
            return nil
        }
        let raw = Int32(value)
        let delta: Int32

        lock.lock()
        defer { lock.unlock() }

        if channel == Self.leftChannel {
            if leftPrevValue == Self.uninitialisedPrev {
                leftPrevValue = raw
                return 0
            }
            let prev = leftPrevValue
            leftPrevValue = raw
            delta = unwrap(raw: raw, prev: prev)
            leftSteps &+= delta   // wrapping add for overflow safety
            trackDelta(&leftRecentDeltas, delta: delta)
        } else {
            if rightPrevValue == Self.uninitialisedPrev {
                rightPrevValue = raw
                return 0
            }
            let prev = rightPrevValue
            rightPrevValue = raw
            delta = unwrap(raw: raw, prev: prev)
            rightSteps &+= delta
            trackDelta(&rightRecentDeltas, delta: delta)
        }
        return Int(delta)
    }

    // MARK: - Position

    /// Signed accumulated steps for a deck (0 if no events have been received).
    func accumulatedSteps(for channel: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        switch channel {
        case Self.leftChannel:  return Int(leftSteps)
        case Self.rightChannel: return Int(rightSteps)
        default:                return 0
        }
    }

    // MARK: - Velocity / Direction

    /// Net direction of recent movement. Returns nil if no movement data exists.
    func recentDirection(for channel: Int) -> ScratchPlatterDirection? {
        lock.lock()
        defer { lock.unlock() }
        let deltas: [Int32]
        switch channel {
        case Self.leftChannel:  deltas = leftRecentDeltas
        case Self.rightChannel: deltas = rightRecentDeltas
        default:                return nil
        }
        let net = deltas.reduce(0, +)
        if net > 0 { return .forward }
        if net < 0 { return .backward }
        return nil
    }

    /// Smoothed recent velocity in CC6 steps per second.
    /// Returns 0 if insufficient data.
    func recentVelocity(for channel: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let deltas: [Int32]
        switch channel {
        case Self.leftChannel:  deltas = leftRecentDeltas
        case Self.rightChannel: deltas = rightRecentDeltas
        default:                return 0
        }
        guard deltas.count >= 2 else { return 0 }
        let absSum = deltas.reduce(0) { $0 + abs($1) }
        // Rough estimate: assume ~800 Hz event rate for recent deltas buffer
        let stepsPerSecond = Double(absSum) * (800.0 / Double(deltas.count))
        return stepsPerSecond
    }

    /// Returns true if the deck has received any CC6 events.
    func hasReceivedEvents(for channel: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch channel {
        case Self.leftChannel:  return leftPrevValue != Self.uninitialisedPrev
        case Self.rightChannel: return rightPrevValue != Self.uninitialisedPrev
        default:                return false
        }
    }

    // MARK: - Shared position

    /// Assemble the shared `PlatterPosition` for a deck from this tracker's
    /// state. The normalized sample position is a playback-engine concern (it
    /// needs the loaded sample length), so it is left 0 here.
    func platterPosition(for channel: Int) -> PlatterPosition {
        let direction: PlatterDirection
        switch recentDirection(for: channel) {
        case .forward: direction = .forward
        case .backward: direction = .backward
        case nil: direction = .idle
        }
        return PlatterPosition(
            phase: Double(accumulatedSteps(for: channel)),
            direction: direction,
            velocity: recentVelocity(for: channel),
            normalizedPosition: 0
        )
    }

    // MARK: - Reset

    /// Reset accumulated position and history for one or both decks.
    func reset(channel: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if channel == nil || channel == Self.leftChannel {
            leftSteps = 0
            leftPrevValue = Self.uninitialisedPrev
            leftRecentDeltas.removeAll()
        }
        if channel == nil || channel == Self.rightChannel {
            rightSteps = 0
            rightPrevValue = Self.uninitialisedPrev
            rightRecentDeltas.removeAll()
        }
    }

    // MARK: - Private

    private func unwrap(raw: Int32, prev: Int32) -> Int32 {
        var delta = raw - prev
        if delta > Int32(Self.wrapThreshold) {
            delta -= 128
        } else if delta < -Int32(Self.wrapThreshold) {
            delta += 128
        }
        return delta
    }

    private func trackDelta(_ buffer: inout [Int32], delta: Int32) {
        buffer.append(delta)
        if buffer.count > maxRecentDeltas {
            buffer.removeFirst(buffer.count - maxRecentDeltas)
        }
    }
}

// MARK: - ScratchPlatterDirection

enum ScratchPlatterDirection: Equatable {
    case forward
    case backward
}
