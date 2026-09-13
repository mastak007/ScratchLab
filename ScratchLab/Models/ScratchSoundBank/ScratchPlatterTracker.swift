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
import Synchronization

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

/// Identity of one transient direct-MIDI observation.
struct MIDIPlatterInputIdentity: Equatable, Sendable {
    let timestamp: Double
    let deviceName: String
    let channel: Int
    let value: Int
    let connectionGeneration: UInt64
}

struct MIDIPlatterStepObservation: Equatable, Sendable {
    let input: MIDIPlatterInputIdentity
    let accumulatedSteps: Int
}

/// Transient presentation correspondence from an actual MIDI audio publication.
/// Neither the packet identity nor the sample epoch is persisted as take data.
struct PlaybackLoopContext: Equatable, Sendable {
    let generation: UInt64
    let sampleID: String
    let validFromTimestamp: Double
    let anchor: MIDIPlatterInputIdentity
    let phaseSteps: Double
    let loopLengthInSteps: Double
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
    private var leftObservation: MIDIPlatterStepObservation?
    private var rightObservation: MIDIPlatterStepObservation?

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
    func ingest(channel: Int, value: Int, inputIdentity: MIDIPlatterInputIdentity? = nil) -> Int? {
        guard channel == Self.leftChannel || channel == Self.rightChannel else {
            return nil
        }
        let raw = Int32(value)
        let delta: Int32

        lock.lock()
        defer {
            let input = inputIdentity.flatMap { identity -> MIDIPlatterInputIdentity? in
                guard identity.channel == channel, identity.value == value,
                      identity.timestamp.isFinite, !identity.deviceName.isEmpty,
                      (0..<128).contains(value) else { return nil }
                return identity
            }
            if channel == Self.leftChannel {
                leftObservation = input.map { MIDIPlatterStepObservation(input: $0, accumulatedSteps: Int(leftSteps)) }
            } else {
                rightObservation = input.map { MIDIPlatterStepObservation(input: $0, accumulatedSteps: Int(rightSteps)) }
            }
            lock.unlock()
        }

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

    /// Reads identity and the existing integrator's result under the same lock.
    func latestObservation(for channel: Int) -> MIDIPlatterStepObservation? {
        lock.lock()
        defer { lock.unlock() }
        switch channel {
        case Self.leftChannel: return leftObservation
        case Self.rightChannel: return rightObservation
        default: return nil
        }
    }

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
            leftObservation = nil
        }
        if channel == nil || channel == Self.rightChannel {
            rightSteps = 0
            rightPrevValue = Self.uninitialisedPrev
            rightRecentDeltas.removeAll()
            rightObservation = nil
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

/// Deck-2 CC1/CC2 protocol supplied by the operator; not a certified Rane map.
/// CC1 is a modulo-128 phase counter, NOT an absolute revolution position.
/// No RPM/ticks-per-revolution calibration is inferred from these messages.
/// Use one decoder per endpoint connection. All state is lock-owned; ingress
/// uses a try-lock and drops contention rather than waiting on a MIDI thread.
final class RaneTwelvePlatterDecoder: @unchecked Sendable {
    static let positionMapping = "raneTwelveDeck2PositionV1"
    static let velocityMapping = "raneTwelveDeck2VelocityV1"

    struct Observation: Equatable, Sendable {
        let timestamp: Double
        let controller: UInt8
        let rawValue: UInt8
        let accumulatedTicks: Int
        /// Nil means the first position or an ambiguous/gapped observation.
        let deltaTicks: Int?
        /// CC2 code, signed under the supplied convention; not ticks/second.
        let signedVelocityCode: Int?
        let discontinuity: Bool
    }

    private struct State {
        var previous: UInt8?
        var previousTime: Double?
        var ticks = 0
        var latest: Observation?
        var lossGeneration: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let losses = Synchronization.Atomic<UInt64>(0)
    var droppedMessageCount: UInt64 { losses.load(ordering: .relaxed) }

    /// Complete MIDI 1 channel messages only. A modern CoreMIDI port carries
    /// these as UMP words; it does not deliver a three-byte packet list.
    @discardableResult
    func ingest(status: UInt8, controller: UInt8, value: UInt8, timestamp: Double) -> Observation? {
        guard status == 0xB1, controller == 1 || controller == 2, value < 128,
              timestamp.isFinite, timestamp >= 0 else { return nil }
        let generation = losses.load(ordering: .acquiring)
        let result = state.withLockIfAvailable { state -> Observation in
            let lost = state.lossGeneration != generation
            if lost {
                state.previous = nil
                state.previousTime = nil
                state.lossGeneration = generation
            }
            var delta: Int?
            var discontinuity = lost
            var velocity: Int?
            if controller == 1 {
                if let previous = state.previous, let time = state.previousTime {
                    let elapsed = timestamp - time
                    var change = Int(value) - Int(previous)
                    // 127 -> 0 becomes +1; 0 -> 127 becomes -1.
                    // This shortest-path inference requires less than half a
                    // counter cycle between observations. Lost full cycles
                    // cannot be recovered from a seven-bit phase counter.
                    if change > 64 { change -= 128 }
                    if change < -64 { change += 128 }
                    if elapsed < 0 || elapsed > 0.1 || abs(change) == 64 {
                        discontinuity = true
                    } else {
                        delta = change
                        state.ticks &+= change
                    }
                }
                state.previous = value
                state.previousTime = timestamp
            } else {
                // CC2 never increments displacement: that would count every
                // physical update twice. 0 is unspecified, so remains nil.
                switch value {
                case 1...63: velocity = Int(value)
                case 64: velocity = 0
                case 65...127: velocity = -(Int(value) - 64)
                default: velocity = nil
                }
            }
            let observation = Observation(timestamp: timestamp, controller: controller,
                rawValue: value, accumulatedTicks: state.ticks, deltaTicks: delta,
                signedVelocityCode: velocity, discontinuity: discontinuity)
            state.latest = observation
            return observation
        }
        guard let result else {
            losses.wrappingAdd(1, ordering: .releasing)
            return nil
        }
        return result
    }

    /// Read from the control/UI queue, not the audio render callback.
    func snapshot() -> Observation? { state.withLock { $0.latest } }
}
