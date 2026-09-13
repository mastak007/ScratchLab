// ReferenceCapturePreflight — the live readiness check shown before a
// reference take, and the gate that blocks recording when it fails.
//
// This is a pure projection of live inputs into named checks. The macOS panel
// renders it; the record button reads `blocksRecording`. Keeping the decision
// here rather than in the view is what lets "can CXL record right now?" be
// tested without a controller, and what will let iOS present the same panel.
//
// A check is either satisfied, unsatisfied-and-blocking, or unsatisfied-and-
// advisory. Nothing is silently ignored: an input that is not required for the
// selected technique is still SHOWN, marked advisory, so the operator can see
// that ScratchLab knows it is absent.
//
// Foundation only. Pure value types.

import Foundation

// MARK: - Live input snapshot

/// One MIDI address the app has received traffic on since launch.
///
/// Purely diagnostic. Exists because the 2026-09-04 hardware smoke could not
/// distinguish "the crossfader is transmitting" from "the crossfader
/// transmitted at some point before the take and has been silent since", and
/// could not see that a control had been learned onto an address nothing was
/// actually sending on.
struct ReferenceLiveMIDIAddressObservation: Equatable, Sendable, Identifiable {
    let deviceName: String
    /// Channel as received in the byte stream, 0–15.
    let channel: Int
    let controller: Int
    let latestRawValue: Int
    /// Messages received on this address since app launch.
    let eventCount: Int
    /// Age of the most recent message, in seconds.
    let secondsSinceLastMessage: Double

    init(
        deviceName: String,
        channel: Int,
        controller: Int,
        latestRawValue: Int,
        eventCount: Int,
        secondsSinceLastMessage: Double
    ) {
        self.deviceName = deviceName
        self.channel = channel
        self.controller = controller
        self.latestRawValue = latestRawValue
        self.eventCount = eventCount
        self.secondsSinceLastMessage = secondsSinceLastMessage
    }

    var id: String { "\(deviceName)#\(channel)#\(controller)" }
    /// Channel as printed on hardware and in vendor documentation (1-based).
    var userFacingChannel: Int { channel + 1 }
    var displayName: String { "\(deviceName) · Ch\(userFacingChannel) CC\(controller)" }
}

/// Everything the preflight panel observes, sampled at one instant.
struct ReferencePreflightSnapshot: Equatable, Sendable {
    /// Connected controller name, or `nil` when no MIDI source is selected.
    let controllerName: String?
    let controllerIdentifier: String?
    /// The address crossfader traffic is arriving on, if any has arrived.
    let observedCrossfaderAddress: CrossfaderMIDIAddress?
    /// Latest raw crossfader value seen, `nil` if none yet.
    let latestCrossfaderRawValue: Int?
    /// The calibration on file for the observed address, if any.
    let calibration: CrossfaderCalibration?
    /// Crossfader MIDI messages seen SINCE APP LAUNCH — a lifetime total, not
    /// a take-scoped or panel-scoped one. On its own it says nothing about
    /// whether the fader is transmitting now; read it with
    /// `crossfaderSecondsSinceLastMessage`.
    let crossfaderEventCount: Int
    /// Age of the most recent crossfader message, in seconds. `nil` when none
    /// has ever arrived.
    ///
    /// The 2026-09-04 hardware smoke read a stale lifetime count of 1,089 as
    /// "the crossfader is working" and then recorded a take containing zero
    /// crossfader samples. This is the field that tells those two states
    /// apart.
    let crossfaderSecondsSinceLastMessage: Double?
    /// Crossfader messages captured INSIDE the currently recording take.
    /// Zero when no take is recording.
    let takeScopedCrossfaderEventCount: Int
    /// Whether a take is recording right now, so the panel can say whether
    /// `takeScopedCrossfaderEventCount` is meaningful yet.
    let isRecordingTake: Bool
    /// Every MIDI address that has carried traffic since launch, most recently
    /// active first. Diagnostic only — never a mapping or a decision.
    let observedMIDIAddresses: [ReferenceLiveMIDIAddressObservation]
    /// Platter MIDI messages seen since the panel opened.
    let platterEventCount: Int
    /// Whether the platter has moved recently enough to count as live.
    let platterIsMoving: Bool
    /// Program audio input peak, 0…1. `nil` when no audio device is selected.
    let audioInputPeakLevel: Double?
    let audioDeviceName: String?
    let watchIsReachable: Bool
    let watchMotionIsStreaming: Bool
    /// Selected camera device name, or `nil` when no video device is
    /// selected. Defaulted so existing callers (and every test written
    /// before this field existed) keep compiling unmodified.
    let cameraDeviceName: String?
    /// Whether the capture session's camera preview is actually running —
    /// distinct from a device merely being *selected*, the same distinction
    /// `MacCaptureEngine.isCameraActive` already draws.
    let cameraIsActive: Bool

    init(
        controllerName: String?,
        controllerIdentifier: String?,
        observedCrossfaderAddress: CrossfaderMIDIAddress?,
        latestCrossfaderRawValue: Int?,
        calibration: CrossfaderCalibration?,
        crossfaderEventCount: Int,
        platterEventCount: Int,
        platterIsMoving: Bool,
        audioInputPeakLevel: Double?,
        audioDeviceName: String?,
        watchIsReachable: Bool,
        watchMotionIsStreaming: Bool,
        cameraDeviceName: String? = nil,
        cameraIsActive: Bool = false,
        crossfaderSecondsSinceLastMessage: Double? = nil,
        takeScopedCrossfaderEventCount: Int = 0,
        isRecordingTake: Bool = false,
        observedMIDIAddresses: [ReferenceLiveMIDIAddressObservation] = []
    ) {
        self.crossfaderSecondsSinceLastMessage = crossfaderSecondsSinceLastMessage
        self.takeScopedCrossfaderEventCount = takeScopedCrossfaderEventCount
        self.isRecordingTake = isRecordingTake
        self.observedMIDIAddresses = observedMIDIAddresses
        self.controllerName = controllerName
        self.controllerIdentifier = controllerIdentifier
        self.observedCrossfaderAddress = observedCrossfaderAddress
        self.latestCrossfaderRawValue = latestCrossfaderRawValue
        self.calibration = calibration
        self.crossfaderEventCount = crossfaderEventCount
        self.platterEventCount = platterEventCount
        self.platterIsMoving = platterIsMoving
        self.audioInputPeakLevel = audioInputPeakLevel
        self.audioDeviceName = audioDeviceName
        self.watchIsReachable = watchIsReachable
        self.watchMotionIsStreaming = watchMotionIsStreaming
        self.cameraDeviceName = cameraDeviceName
        self.cameraIsActive = cameraIsActive
    }

    /// Calibrated position of the latest raw value, or `nil` when either the
    /// value or the calibration is missing. Never falls back to `raw / 127`.
    var calibratedCrossfaderPosition: Double? {
        guard let raw = latestCrossfaderRawValue,
              let calibration,
              calibration.isUsable else { return nil }
        return calibration.normalized(rawValue: raw)
    }

    /// Open / closed / moving for the latest value, under `hysteresis`.
    func crossfaderGateState(
        hysteresis: CrossfaderHysteresis = .default
    ) -> CrossfaderGateState? {
        guard let position = calibratedCrossfaderPosition, hysteresis.isUsable else { return nil }
        return hysteresis.instantaneousState(forNormalizedPosition: position)
    }
}

// MARK: - Checks

/// One preflight row.
struct ReferencePreflightCheck: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        case satisfied
        /// Not satisfied, and recording is blocked.
        case blocking
        /// Not satisfied, recording is allowed, the operator is told.
        case advisory
    }

    let id: String
    let title: String
    /// Live value, e.g. "Rane ONE MKII · Ch16 CC8" or "raw 41 · 0.78 open".
    let detail: String
    let status: Status

    init(id: String, title: String, detail: String, status: Status) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// The full preflight result.
struct ReferencePreflightResult: Equatable, Sendable {
    let checks: [ReferencePreflightCheck]

    var blockingChecks: [ReferencePreflightCheck] {
        checks.filter { $0.status == .blocking }
    }

    var blocksRecording: Bool { !blockingChecks.isEmpty }

    /// One line for the record button's disabled explanation.
    var blockingSummary: String? {
        guard !blockingChecks.isEmpty else { return nil }
        return blockingChecks.map { "\($0.title): \($0.detail)" }.joined(separator: " · ")
    }
}

// MARK: - Evaluator

enum ReferenceCapturePreflight {

    /// Audio input peak below which we treat the program feed as dead.
    static let minimumAudioInputPeak: Double = 0.0005

    /// How recently a control must have sent a message to count as live.
    /// Matches the window the platter row already uses.
    static let recentActivityWindow: Double = 1.5

    /// `true` only when a crossfader message arrived inside
    /// `recentActivityWindow`. A lifetime count with no recent message is
    /// explicitly NOT liveness.
    static func crossfaderIsRecentlyActive(snapshot: ReferencePreflightSnapshot) -> Bool {
        guard snapshot.crossfaderEventCount > 0,
              let age = snapshot.crossfaderSecondsSinceLastMessage else { return false }
        return age < recentActivityWindow
    }

    /// Row text that always distinguishes lifetime traffic from live traffic,
    /// and — while a take is recording — reports the take-scoped count, which
    /// is the number that actually reaches the sidecar.
    static func crossfaderDetail(snapshot: ReferencePreflightSnapshot) -> String {
        var parts: [String] = []
        if snapshot.crossfaderEventCount > 0 {
            parts.append("\(snapshot.crossfaderEventCount) since launch")
            if let age = snapshot.crossfaderSecondsSinceLastMessage {
                parts.append(
                    crossfaderIsRecentlyActive(snapshot: snapshot)
                        ? "moving now"
                        : String(format: "last message %.1fs ago — currently silent", age)
                )
            } else {
                parts.append("last message age unknown — treat as silent")
            }
        } else {
            parts.append("No crossfader traffic since launch. Move the crossfader.")
        }
        if snapshot.isRecordingTake {
            parts.append("\(snapshot.takeScopedCrossfaderEventCount) in this take")
        }
        return parts.joined(separator: " · ")
    }

    /// Evaluate readiness to record `technique` right now.
    ///
    /// Blocking conditions, in the order an operator would fix them:
    /// no controller, no crossfader traffic, no calibration for the observed
    /// address, a calibration measured on a different address, no platter
    /// traffic, a dead audio input, and no active camera. The Watch is
    /// advisory — a reference take is valid without it.
    static func evaluate(
        snapshot: ReferencePreflightSnapshot,
        technique: ReferenceTechnique,
        hysteresis: CrossfaderHysteresis = .default
    ) -> ReferencePreflightResult {
        var checks: [ReferencePreflightCheck] = []
        let expectation = technique.defaultFaderExpectation

        // Controller
        if let controllerName = snapshot.controllerName,
           !controllerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let identifier = snapshot.controllerIdentifier,
           !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            checks.append(
                ReferencePreflightCheck(
                    id: "controller",
                    title: "Controller",
                    detail: controllerName,
                    status: .satisfied
                )
            )
        } else {
            checks.append(
                ReferencePreflightCheck(
                    id: "controller",
                    title: "Controller",
                    detail: "No MIDI source selected.",
                    status: .blocking
                )
            )
        }

        // Crossfader address
        if let address = snapshot.observedCrossfaderAddress {
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderAddress",
                    title: "Crossfader MIDI",
                    detail: address.displayName,
                    status: .satisfied
                )
            )
        } else {
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderAddress",
                    title: "Crossfader MIDI",
                    detail: "No crossfader traffic detected. Move the crossfader.",
                    status: .blocking
                )
            )
        }

        // Raw value
        checks.append(
            ReferencePreflightCheck(
                id: "crossfaderRaw",
                title: "Raw crossfader",
                detail: snapshot.latestCrossfaderRawValue.map(String.init) ?? "—",
                status: snapshot.latestCrossfaderRawValue == nil ? .blocking : .satisfied
            )
        )

        // Calibration + calibrated value + gate state
        if let calibration = snapshot.calibration, calibration.isUsable {
            let addressMatches = snapshot.observedCrossfaderAddress.map { observed in
                calibration.address.matches(
                    deviceIdentifier: observed.deviceIdentifier,
                    channel: observed.channel,
                    controller: observed.controller
                )
            } ?? true
            checks.append(
                ReferencePreflightCheck(
                    id: "calibration",
                    title: "Calibration",
                    detail: addressMatches
                        ? "Active half \(calibration.activeHalfRawBounds.lowerBound)–\(calibration.activeHalfRawBounds.upperBound), \(calibration.activeDeck.displayName), \(calibration.openEnd.displayName)."
                        : "Calibrated on \(calibration.address.displayName), but traffic is arriving on a different address.",
                    status: addressMatches ? .satisfied : .blocking
                )
            )
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderCalibrated",
                    title: "Calibrated value",
                    detail: snapshot.calibratedCrossfaderPosition
                        .map { String(format: "%.3f", $0) } ?? "—",
                    status: snapshot.calibratedCrossfaderPosition == nil ? .blocking : .satisfied
                )
            )
            let gate = snapshot.crossfaderGateState(hysteresis: hysteresis)
            let gateIsBlocking = expectation.requiresContinuouslyOpenFader && gate != .open
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderState",
                    title: "Fader state",
                    detail: gate.map(\.displayName)
                        ?? "Unknown — calibrate the crossfader.",
                    status: gate == nil
                        ? .blocking
                        : (gateIsBlocking ? .blocking : .satisfied)
                )
            )
        } else {
            checks.append(
                ReferencePreflightCheck(
                    id: "calibration",
                    title: "Calibration",
                    detail: snapshot.calibration == nil
                        ? "No calibration on file for this crossfader. Run calibration first."
                        : "The stored calibration is unusable. Recalibrate.",
                    status: .blocking
                )
            )
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderCalibrated",
                    title: "Calibrated value",
                    detail: "—",
                    status: .blocking
                )
            )
            checks.append(
                ReferencePreflightCheck(
                    id: "crossfaderState",
                    title: "Fader state",
                    detail: "Unknown — calibrate the crossfader.",
                    status: .blocking
                )
            )
        }

        // Crossfader liveness.
        //
        // The lifetime count alone is NOT evidence the fader is transmitting:
        // it never decreases and is never reset, so it keeps reading
        // "satisfied" for the rest of the app's life after a single message.
        // Satisfied requires a message inside `recentActivityWindow`, the same
        // rule the platter row already applies.
        checks.append(
            ReferencePreflightCheck(
                id: "crossfaderEvents",
                title: "Crossfader events",
                detail: Self.crossfaderDetail(snapshot: snapshot),
                status: Self.crossfaderIsRecentlyActive(snapshot: snapshot) ? .satisfied : .advisory
            )
        )

        // Platter
        let platterSatisfied = snapshot.platterEventCount > 0 && snapshot.platterIsMoving
        checks.append(
            ReferencePreflightCheck(
                id: "platter",
                title: "Platter",
                detail: snapshot.platterEventCount > 0
                    ? (snapshot.platterIsMoving
                        ? "\(snapshot.platterEventCount) events, moving."
                        : "\(snapshot.platterEventCount) events, currently still.")
                    : "No platter traffic detected. Touch the platter.",
                status: platterSatisfied
                    ? .satisfied
                    : (expectation.requiresPlatterMotion && snapshot.platterEventCount == 0
                        ? .blocking
                        : .advisory)
            )
        )

        // Audio input
        if let peak = snapshot.audioInputPeakLevel {
            let deviceLabel = snapshot.audioDeviceName ?? "Audio input"
            checks.append(
                ReferencePreflightCheck(
                    id: "audioInput",
                    title: "Audio input",
                    detail: String(format: "%@ · peak %.4f", deviceLabel, peak),
                    status: peak > minimumAudioInputPeak ? .satisfied : .blocking
                )
            )
        } else {
            checks.append(
                ReferencePreflightCheck(
                    id: "audioInput",
                    title: "Audio input",
                    detail: "No audio input selected.",
                    status: .blocking
                )
            )
        }

        // Camera
        if let cameraDeviceName = snapshot.cameraDeviceName,
           !cameraDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            checks.append(
                ReferencePreflightCheck(
                    id: "camera",
                    title: "Camera",
                    detail: snapshot.cameraIsActive
                        ? cameraDeviceName
                        : "\(cameraDeviceName) — preview is not running.",
                    status: snapshot.cameraIsActive ? .satisfied : .blocking
                )
            )
        } else {
            checks.append(
                ReferencePreflightCheck(
                    id: "camera",
                    title: "Camera",
                    detail: "No camera selected.",
                    status: .blocking
                )
            )
        }

        // Watch — BLOCKING.
        //
        // Was advisory while authoring had no Watch wiring at all, which made
        // the row read as "we noticed, carry on" for a take that could never
        // carry wrist evidence. Reference authoring now performs the same
        // paired start handshake Capture does and refuses to start recording
        // without an acknowledgement, so an unreachable Watch is a condition
        // the operator must fix before recording, not one to note afterwards.
        // `ReferenceValidator.watchEvidenceMissing` is the matching gate on
        // approval.
        checks.append(
            ReferencePreflightCheck(
                id: "watch",
                title: "Apple Watch",
                detail: snapshot.watchIsReachable
                    ? (snapshot.watchMotionIsStreaming ? "Connected, motion streaming." : "Connected, motion idle.")
                    : "Not connected. A canonical reference take requires linked watch motion.",
                status: snapshot.watchIsReachable ? .satisfied : .blocking
            )
        )

        return ReferencePreflightResult(checks: checks)
    }
}
