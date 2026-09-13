// CrossfaderCalibration — the calibrated physical description of one
// crossfader, and the ONLY sanctioned way to turn a raw MIDI value from that
// fader into a normalized 0…1 position.
//
// Why this type exists
// --------------------
// Capture previously normalized every mixer CC as `Double(value) / 127.0`.
// That is a guess about the hardware, and on real hardware it is wrong. A
// RANE ONE MKII right-deck cut runs centre-to-left, so a complete, correct
// performance gesture only ever traverses raw 0…52 of the physical 0…127.
// Normalizing that against 127 compresses every real gesture into the bottom
// 41% of the scale, where the cut-classification gates cannot see it — which
// is how a take of clean cuts exported 12 of 20 derived fader events as
// `unknown`.
//
// The fix is not a wider gate. It is to record what the hardware actually
// does, once, and normalize against that.
//
// Layering rules (identical to the sibling `MIDILearnedMapping.swift`):
// - Pure value types. Foundation only. No Core MIDI, no audio, no UI, no I/O.
// - Deterministic: same raw value + same calibration -> same normalized value.
// - Fails closed. An absent or invalid calibration yields `nil`, never a
//   fabricated 0…127 fallback. A caller that wants raw values must ask for
//   raw values explicitly.
// - Shared by iOS and macOS. Nothing here knows which platform captured it.

import Foundation

// MARK: - Geometry

/// Which physical end of the crossfader throw leaves the calibrated deck
/// AUDIBLE.
///
/// This is a property of how the performer has the mixer wired and reversed,
/// not of the controller model, so it is captured per calibration rather than
/// inferred from a device name.
enum CrossfaderOpenEnd: String, Codable, Equatable, Sendable, CaseIterable {
    /// The deck is open at the far-left end of the throw.
    case left
    /// The deck is open at the far-right end of the throw.
    case right

    var displayName: String {
        switch self {
        case .left: return "Open at far left"
        case .right: return "Open at far right"
        }
    }
}

/// Which deck the calibrated fader half belongs to.
///
/// A scratch performance uses one deck's half of the throw. Validation of a
/// PERFORMANCE take is scoped to that half; the full throw is required only
/// while calibrating.
enum CrossfaderActiveDeck: String, Codable, Equatable, Sendable, CaseIterable {
    case leftDeck
    case rightDeck

    var displayName: String {
        switch self {
        case .leftDeck: return "Left deck"
        case .rightDeck: return "Right deck"
        }
    }
}

/// The three positions a calibration sweep must observe, in the order the
/// operator is asked for them.
enum CrossfaderCalibrationStep: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case fullLeft
    case center
    case fullRight

    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .fullLeft: return "Hold the crossfader hard against the LEFT end stop."
        case .center: return "Hold the crossfader at the CENTRE detent."
        case .fullRight: return "Hold the crossfader hard against the RIGHT end stop."
        }
    }

    var next: CrossfaderCalibrationStep? {
        switch self {
        case .fullLeft: return .center
        case .center: return .fullRight
        case .fullRight: return nil
        }
    }
}

// MARK: - MIDI address

/// The exact MIDI address a calibration belongs to.
///
/// A calibration is only valid for the device and address it was measured on.
/// Applying a RANE calibration to a DDJ's CC stream is the same class of error
/// as assuming 0…127, so the address travels with the calibration and is
/// checked on every use.
struct CrossfaderMIDIAddress: Codable, Equatable, Sendable {
    /// Stable Core MIDI identity (e.g. `"midi_<uniqueID>"`). Never a display
    /// name — names collide and change.
    let deviceIdentifier: String
    /// User-facing source name, for display and for export provenance.
    let deviceName: String
    /// MIDI channel as received in the byte stream, 0–15.
    let channel: Int
    /// CC controller number.
    let controller: Int

    init(deviceIdentifier: String, deviceName: String, channel: Int, controller: Int) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.channel = channel
        self.controller = controller
    }

    /// Channel as printed on hardware and in vendor documentation (1-based).
    var userFacingChannel: Int { channel + 1 }

    var displayName: String { "\(deviceName) · Ch\(userFacingChannel) CC\(controller)" }

    /// Address equality ignores `deviceName`, which is cosmetic and may be
    /// re-reported differently by Core MIDI between sessions.
    func matches(deviceIdentifier: String, channel: Int, controller: Int) -> Bool {
        self.deviceIdentifier == deviceIdentifier
            && self.channel == channel
            && self.controller == controller
    }
}

// MARK: - Calibration

/// What is wrong with a calibration, named precisely enough to act on.
///
/// A closed vocabulary: every case names a measurement or an address, never
/// performer content.
enum CrossfaderCalibrationIssue: Equatable, Sendable {
    case channelOutOfRange(Int)
    case controllerOutOfRange(Int)
    case rawValueOutOfRange(step: CrossfaderCalibrationStep, value: Int)
    case endpointsNotDistinct(left: Int, right: Int)
    case centerOutsideEndpoints(center: Int, left: Int, right: Int)
    case centerNotDistinctFromEndpoints(center: Int, left: Int, right: Int, minimumMargin: Int)
    case activeHalfTooNarrow(span: Int, minimumSpan: Int)
    case missingDeviceIdentifier
    case unsupportedSchemaVersion(found: Int, expected: Int)

    var message: String {
        switch self {
        case .channelOutOfRange(let channel):
            return "Crossfader calibration names MIDI channel \(channel), which is outside 0–15."
        case .controllerOutOfRange(let controller):
            return "Crossfader calibration names CC \(controller), which is outside 0–127."
        case .rawValueOutOfRange(let step, let value):
            return "Crossfader calibration recorded \(value) at \(step.rawValue), which is outside the MIDI range 0–127."
        case .endpointsNotDistinct(let left, let right):
            return "Crossfader calibration recorded the same value at both end stops (left \(left), right \(right)). Move the fader fully to each end and calibrate again."
        case .centerOutsideEndpoints(let center, let left, let right):
            return "Crossfader calibration recorded centre \(center), which is not between the end stops \(left) and \(right)."
        case .centerNotDistinctFromEndpoints(let center, let left, let right, let minimumMargin):
            return "Crossfader calibration recorded centre \(center), which is indistinguishable from an end stop (left \(left), right \(right)); centre must differ from both by at least \(minimumMargin) MIDI steps. Hold the fader at the CENTRE detent and calibrate again."
        case .activeHalfTooNarrow(let span, let minimumSpan):
            return "The calibrated active half spans only \(span) MIDI steps; at least \(minimumSpan) are required to derive open, closed and transition states."
        case .missingDeviceIdentifier:
            return "Crossfader calibration has no MIDI device identifier, so it cannot be matched to a controller."
        case .unsupportedSchemaVersion(let found, let expected):
            return "Crossfader calibration uses schema version \(found); this build reads version \(expected). Recalibrate the crossfader."
        }
    }
}

/// A measured crossfader, persisted and shipped with every reference take.
///
/// `normalized(rawValue:)` is the single conversion every consumer uses —
/// live preflight, capture, derivation, review and export all read the same
/// number, so what the operator saw during calibration is what lands in the
/// package.
struct CrossfaderCalibration: Codable, Equatable, Sendable, Identifiable {

    /// Bumped whenever the meaning of a persisted field changes. A calibration
    /// written by a newer schema is REJECTED, never reinterpreted.
    static let currentSchemaVersion = 1

    /// Smallest calibrated active half we will derive states from. Below this
    /// the hysteresis bands overlap and every sample is `transitioning`.
    static let minimumActiveHalfSpan = 16

    /// How far the centre measurement must sit from BOTH end stops before it
    /// counts as a distinct third measurement.
    ///
    /// A sweep that never moved records the same value three times. Two of
    /// those collapse into `endpointsNotDistinct`, but a sweep that captured
    /// one real end stop and two stale copies of the other (left 0, centre 0,
    /// right 126 — the 2026-09-04 hardware smoke) passed every earlier rule:
    /// the endpoints were distinct and the inclusive `centerOutsideEndpoints`
    /// bounds check accepted a centre sitting exactly ON an end stop. A
    /// calibration like that describes a two-point fader with no closed
    /// reference, which is not a three-position calibration at all.
    ///
    /// Set above `CrossfaderCalibrationSweep.defaultSettleTolerance` (1) so
    /// the margin is wider than the jitter a settled hold is allowed to carry,
    /// and a centre that merely *looks* like an end stop is rejected too.
    static let minimumCenterMargin = 2

    let schemaVersion: Int
    let address: CrossfaderMIDIAddress
    /// Raw value observed with the fader against the LEFT end stop.
    let fullLeftRawValue: Int
    /// Raw value observed at the CENTRE detent.
    let centerRawValue: Int
    /// Raw value observed with the fader against the RIGHT end stop.
    let fullRightRawValue: Int
    /// Which end of the throw leaves the calibrated deck audible.
    let openEnd: CrossfaderOpenEnd
    /// Which deck this calibration describes.
    let activeDeck: CrossfaderActiveDeck
    let calibratedAt: Date
    /// Free-text operator note, e.g. a mixer reverse-switch position. Never
    /// parsed; carried for provenance only.
    let operatorNote: String

    var id: String { "\(address.deviceIdentifier)#\(address.channel)#\(address.controller)" }

    init(
        schemaVersion: Int = CrossfaderCalibration.currentSchemaVersion,
        address: CrossfaderMIDIAddress,
        fullLeftRawValue: Int,
        centerRawValue: Int,
        fullRightRawValue: Int,
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck,
        calibratedAt: Date,
        operatorNote: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.address = address
        self.fullLeftRawValue = fullLeftRawValue
        self.centerRawValue = centerRawValue
        self.fullRightRawValue = fullRightRawValue
        self.openEnd = openEnd
        self.activeDeck = activeDeck
        self.calibratedAt = calibratedAt
        self.operatorNote = operatorNote
    }

    // MARK: Active half

    /// The raw value at which the calibrated deck is fully CLOSED (silent).
    ///
    /// The closed end is the centre detent, not the far end stop: past centre
    /// the deck is still silent, so travel beyond it carries no additional
    /// information about this deck.
    var closedRawValue: Int { centerRawValue }

    /// The raw value at which the calibrated deck is fully OPEN.
    var openRawValue: Int {
        switch openEnd {
        case .left: return fullLeftRawValue
        case .right: return fullRightRawValue
        }
    }

    /// The raw value at the far end of the throw, past closed. Positions
    /// beyond `closedRawValue` in this direction are still fully closed for
    /// this deck; they are recorded so a take can prove the fader was parked
    /// rather than disconnected.
    var beyondClosedRawValue: Int {
        switch openEnd {
        case .left: return fullRightRawValue
        case .right: return fullLeftRawValue
        }
    }

    /// Signed span of the calibrated active half, open minus closed.
    var activeHalfSignedSpan: Int { openRawValue - closedRawValue }

    /// Magnitude of the calibrated active half, in MIDI steps.
    var activeHalfSpan: Int { abs(activeHalfSignedSpan) }

    /// Inclusive raw bounds of the active half, ascending.
    var activeHalfRawBounds: ClosedRange<Int> {
        let lower = min(closedRawValue, openRawValue)
        let upper = max(closedRawValue, openRawValue)
        return lower...upper
    }

    // MARK: Normalization

    /// Normalized position of `rawValue` across the CALIBRATED ACTIVE HALF:
    /// `0.0` fully closed, `1.0` fully open.
    ///
    /// Travel past the closed end (the other deck's half) clamps to `0.0`,
    /// which is correct — that region is silent for this deck and carries no
    /// gradation. Travel past the open end clamps to `1.0`.
    ///
    /// Returns `nil` for a calibration that has not passed `validationIssues()`
    /// or for a raw value outside the MIDI range, so a caller can never
    /// silently normalize against a degenerate span.
    func normalized(rawValue: Int) -> Double? {
        guard validationIssues().isEmpty else { return nil }
        guard (0...127).contains(rawValue) else { return nil }
        let span = Double(activeHalfSignedSpan)
        guard span != 0 else { return nil }
        let position = Double(rawValue - closedRawValue) / span
        return min(1.0, max(0.0, position))
    }

    /// `true` when `rawValue` lies inside the calibrated active half (with a
    /// one-step tolerance at each end for controller jitter at the stops).
    func isWithinActiveHalf(rawValue: Int) -> Bool {
        let bounds = activeHalfRawBounds
        return rawValue >= bounds.lowerBound - 1 && rawValue <= bounds.upperBound + 1
    }

    // MARK: Validation

    func validationIssues() -> [CrossfaderCalibrationIssue] {
        var issues: [CrossfaderCalibrationIssue] = []
        if schemaVersion != Self.currentSchemaVersion {
            issues.append(.unsupportedSchemaVersion(
                found: schemaVersion,
                expected: Self.currentSchemaVersion
            ))
        }
        if address.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingDeviceIdentifier)
        }
        if !(0...15).contains(address.channel) {
            issues.append(.channelOutOfRange(address.channel))
        }
        if !(0...127).contains(address.controller) {
            issues.append(.controllerOutOfRange(address.controller))
        }
        for (step, value) in [
            (CrossfaderCalibrationStep.fullLeft, fullLeftRawValue),
            (CrossfaderCalibrationStep.center, centerRawValue),
            (CrossfaderCalibrationStep.fullRight, fullRightRawValue)
        ] where !(0...127).contains(value) {
            issues.append(.rawValueOutOfRange(step: step, value: value))
        }
        // Everything below reads the three measurements; only run it when
        // they are in range, so one bad sweep does not produce five messages
        // that all describe the same mistake.
        guard issues.isEmpty else { return issues }

        if fullLeftRawValue == fullRightRawValue {
            issues.append(.endpointsNotDistinct(left: fullLeftRawValue, right: fullRightRawValue))
            return issues
        }
        let endpointBounds = min(fullLeftRawValue, fullRightRawValue)...max(fullLeftRawValue, fullRightRawValue)
        if !endpointBounds.contains(centerRawValue) {
            issues.append(.centerOutsideEndpoints(
                center: centerRawValue,
                left: fullLeftRawValue,
                right: fullRightRawValue
            ))
            return issues
        }
        if abs(centerRawValue - fullLeftRawValue) < Self.minimumCenterMargin
            || abs(centerRawValue - fullRightRawValue) < Self.minimumCenterMargin {
            issues.append(.centerNotDistinctFromEndpoints(
                center: centerRawValue,
                left: fullLeftRawValue,
                right: fullRightRawValue,
                minimumMargin: Self.minimumCenterMargin
            ))
            return issues
        }
        if activeHalfSpan < Self.minimumActiveHalfSpan {
            issues.append(.activeHalfTooNarrow(
                span: activeHalfSpan,
                minimumSpan: Self.minimumActiveHalfSpan
            ))
        }
        return issues
    }

    var isUsable: Bool { validationIssues().isEmpty }
}
