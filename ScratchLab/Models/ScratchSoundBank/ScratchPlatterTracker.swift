// ScratchPlatterTracker.swift
// ScratchLab — Platter CC6 Ring-Counter Tracker
//
// Pure-logic CC6 ring-counter unwrapper for Rane ONE MKII platters.
// Thread-safe via os_unfair_lock. No audio/MIDI dependency.
// No scoring. No routing.
//
// Rane ONE MKII: CC6 ±1 per event, ~3932 steps/rev, ~800–935 Hz update.
// Two independent decks: ch=4 (left), ch=5 (right).

import Foundation
import os

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

    /// Known platter channels: 4 = left deck, 5 = right deck.
    static let leftChannel = 4
    static let rightChannel = 5

    /// Wrap threshold — a CC6 delta larger than this is a 127↔0 boundary crossing.
    static let wrapThreshold = 64

    /// A deck channel for which no CC6 value has been received yet.
    private static let uninitialisedPrev: Int32 = -1

    // MARK: - Ingest

    /// Feed a raw CC6 value (0–127) for a deck channel.
    /// - Parameters:
    ///   - channel: MIDI channel (4 = left, 5 = right).
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
