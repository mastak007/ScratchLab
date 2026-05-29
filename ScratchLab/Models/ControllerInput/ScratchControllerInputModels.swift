import Foundation

// Phase 1 hardware-input foundation: pure, normalized controller-input model.
//
// Scope guardrails (deliberate):
// - No device assumptions, no Core MIDI, no HID, no DVS, no audio engine.
// - No notation, coaching, replay, capture, scoring, ML, or export coupling.
// - Value types only here; transports/normalizer live alongside in this folder.
//
// These types are the canonical units the rest of ScratchLab will consume once
// real gesture capture exists. They are intentionally transport-agnostic so a
// future DVS/HID transport can be fused onto the same timeline.

// MARK: - Identity & enums

/// Identifies which deck a controller-input frame describes.
/// Raw values are stable so recorded gesture streams stay decodable across builds.
enum ScratchDeckID: Int, Sendable, Equatable, Hashable, CaseIterable {
    case left = 0
    case right = 1
}

/// Direction of platter travel for a sampled frame.
enum ScratchPlatterDirection: Int, Sendable, Equatable, Hashable {
    case reverse = -1
    case stopped = 0
    case forward = 1

    /// Derives a direction from a signed velocity. Velocities whose magnitude is
    /// at or below `threshold` are treated as `.stopped`.
    static func from(velocity: Double, threshold: Double = 0) -> ScratchPlatterDirection {
        if velocity > threshold { return .forward }
        if velocity < -threshold { return .reverse }
        return .stopped
    }
}

/// The transport an input event/frame originated from. Only `.midi` is exercised
/// in this slice; `.hid` and `.dvs` are reserved for future transports, and
/// `.synthetic` covers app-generated events (tests/replay).
enum ScratchTransportKind: String, Sendable, Equatable, Hashable {
    case midi
    case hid
    case dvs
    case synthetic
}

/// Describes where a frame's data came from, so future transports can be fused
/// into one timeline without losing provenance. No real device is bound yet.
struct ScratchInputSource: Sendable, Equatable, Hashable {
    /// Transport that produced the underlying events.
    var transport: ScratchTransportKind
    /// Opaque, stable identifier for the originating device (empty until bound).
    var deviceID: String
    /// Identifier of the device profile that decoded the events, if any.
    var profileID: String?

    init(transport: ScratchTransportKind, deviceID: String = "", profileID: String? = nil) {
        self.transport = transport
        self.deviceID = deviceID
        self.profileID = profileID
    }
}

// MARK: - Raw events

/// A raw, un-interpreted MIDI message as received from a transport. Bytes are
/// retained verbatim so decoding can be re-derived later; the timestamp is
/// monotonic seconds on a shared clock. Nothing here interprets the bytes.
struct MIDIRawEvent: Sendable, Equatable, Hashable {
    /// Monotonic receipt time in seconds (shared clock across transports).
    var timestamp: TimeInterval
    /// Raw MIDI bytes (status + data), stored verbatim.
    var bytes: [UInt8]

    init(timestamp: TimeInterval, bytes: [UInt8]) {
        self.timestamp = timestamp
        self.bytes = bytes
    }
}

/// Transport-agnostic wrapper around a raw input event, with a stable identity
/// for referencing from derived frames and recordings (the future source of truth).
struct ScratchRawInputEvent: Sendable, Equatable, Hashable, Identifiable {
    /// Stable per-event identifier (monotonic within a session).
    var id: UInt64
    /// Which transport produced this event.
    var transport: ScratchTransportKind
    /// Monotonic receipt time in seconds.
    var timestamp: TimeInterval
    /// Raw payload bytes (e.g. MIDI status+data), verbatim.
    var bytes: [UInt8]

    init(id: UInt64, transport: ScratchTransportKind, timestamp: TimeInterval, bytes: [UInt8]) {
        self.id = id
        self.transport = transport
        self.timestamp = timestamp
        self.bytes = bytes
    }

    /// Builds a raw input event from a MIDI raw event, preserving bytes/timestamp.
    init(id: UInt64, midi: MIDIRawEvent) {
        self.init(id: id, transport: .midi, timestamp: midi.timestamp, bytes: midi.bytes)
    }
}

// MARK: - Normalized frame

/// One normalized, sampled controller state — the canonical unit downstream
/// consumers (notation/replay/analysis, later) will read.
///
/// Semantics that matter:
/// - `platterPosition` is **accumulated / unwrapped** continuous displacement in
///   revolutions (signed; forward positive). It is NOT a 0–1 angle, so values
///   beyond one turn are retained verbatim.
/// - `platterVelocity` is signed revolutions/second (negative = reverse).
/// - `crossfaderPosition` / `crossfaderVelocity` are optional because platter-only
///   sources (e.g. a future DVS transport) may not provide a crossfader.
/// - `timestamp` is monotonic seconds on a shared clock, so future transports can
///   be fused onto one timeline.
struct ScratchInputFrame: Sendable, Equatable, Hashable {
    /// Monotonic seconds on the shared input clock.
    var timestamp: TimeInterval
    /// Which deck this frame describes.
    var deck: ScratchDeckID

    /// Accumulated, unwrapped platter displacement in revolutions (signed).
    var platterPosition: Double
    /// Signed platter velocity in revolutions/second (negative = reverse).
    var platterVelocity: Double

    /// Normalized crossfader position in 0...1, or nil if the source has no fader.
    var crossfaderPosition: Double?
    /// Signed crossfader velocity in units/second, or nil if unavailable.
    var crossfaderVelocity: Double?

    /// Provenance of this frame.
    var source: ScratchInputSource

    /// Number of raw events that contributed to this frame (0 if unknown).
    var rawEventCount: Int
    /// Identifiers of the raw events that produced this frame (may be empty).
    var rawEventIDs: [UInt64]

    init(
        timestamp: TimeInterval,
        deck: ScratchDeckID,
        platterPosition: Double,
        platterVelocity: Double,
        crossfaderPosition: Double? = nil,
        crossfaderVelocity: Double? = nil,
        source: ScratchInputSource,
        rawEventCount: Int = 0,
        rawEventIDs: [UInt64] = []
    ) {
        self.timestamp = timestamp
        self.deck = deck
        self.platterPosition = platterPosition
        self.platterVelocity = platterVelocity
        self.crossfaderPosition = crossfaderPosition
        self.crossfaderVelocity = crossfaderVelocity
        self.source = source
        self.rawEventCount = rawEventCount
        self.rawEventIDs = rawEventIDs
    }

    /// Platter direction derived from the current signed velocity. Kept computed
    /// (not stored) so direction can never disagree with velocity.
    var platterDirection: ScratchPlatterDirection {
        ScratchPlatterDirection.from(velocity: platterVelocity)
    }
}
