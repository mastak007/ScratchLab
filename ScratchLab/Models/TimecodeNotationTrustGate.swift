import Foundation

// MARK: - TimecodeNotationTrustDecision

/// Reason the DVS pipeline's decoded motion is not currently trusted enough
/// to drive notation, or `.trusted` when it is.
///
/// Mirrors `TimecodePlaybackBridgeDecision`'s fail-closed gate order and
/// thresholds exactly (Control Prototype mode, live Live Tap, usable and
/// fresh signal, confidence above threshold, known direction, a valid
/// platter timeline, validation passed, no replay conflict), evaluated
/// completely independently of playback so the two bridges cannot silently
/// diverge on what counts as trustworthy motion.
enum TimecodeNotationTrustDecision: String, CaseIterable, Equatable, Hashable, Sendable {
    case notationRoutingDisabled
    case pipelineDisabled
    case diagnosticsOnly
    case replayActive
    case liveTapOff
    case unusableSignalHealth
    case staleSignal
    case lowConfidence
    case missingTimeline
    case unknownDirection
    case validationRequired
    case trusted

    var label: String {
        switch self {
        case .notationRoutingDisabled: return "Notation routing disabled"
        case .pipelineDisabled:        return "Timecode pipeline disabled"
        case .diagnosticsOnly:         return "Diagnostics-only mode"
        case .replayActive:            return "Replay is active"
        case .liveTapOff:              return "Live timecode tap is off"
        case .unusableSignalHealth:    return "Signal health is not usable"
        case .staleSignal:             return "Latest input buffer is stale"
        case .lowConfidence:           return "Confidence is below threshold"
        case .missingTimeline:         return "No trusted platter timeline"
        case .unknownDirection:        return "Platter direction is unknown"
        case .validationRequired:      return "Validation has not passed"
        case .trusted:                 return "All gates passed"
        }
    }
}

#if DEBUG
/// Per-take observability for the DVS-to-notation trust path.
///
/// This value is intentionally DEBUG-only and is not Codable, so it cannot
/// become part of the routine export schema by accident.
struct TimecodeNotationDiagnostics: Equatable, Sendable {
    private(set) var lastDecision: TimecodeNotationTrustDecision?
    private(set) var decisionCounts: [TimecodeNotationTrustDecision: Int] = [:]
    private(set) var accumulatedSampleCount = 0
    private(set) var finalizedSampleCount = 0
    private(set) var finalizedEventCount = 0

    var totalDecisionCount: Int {
        decisionCounts.values.reduce(0, +)
    }

    mutating func record(_ decision: TimecodeNotationTrustDecision) {
        lastDecision = decision
        decisionCounts[decision, default: 0] += 1
    }

    mutating func updateAccumulatedSampleCount(_ count: Int) {
        accumulatedSampleCount = max(0, count)
    }

    mutating func finalize(sampleCount: Int, eventCount: Int) {
        finalizedSampleCount = max(0, sampleCount)
        finalizedEventCount = max(0, eventCount)
    }

    func decisionCountsDescription(includingZeros: Bool = false) -> String {
        let entries = TimecodeNotationTrustDecision.allCases.compactMap { decision -> String? in
            let count = decisionCounts[decision, default: 0]
            guard includingZeros || count > 0 else { return nil }
            return "\(decision.rawValue)=\(count)"
        }
        return entries.isEmpty ? "none" : entries.joined(separator: ", ")
    }
}
#endif

// MARK: - TimecodeNotationTrustGate

/// Pure, side-effect-free trust gate for routing decoded DVS motion into
/// notation.
///
/// Deliberately independent of `TimecodePlaybackBridge`: it holds no state,
/// shares no enable flag, and evaluating it never enables, disables, or
/// otherwise touches `playbackDriveEnabled`. Enabling notation routing must
/// never enable playback, and enabling playback must never enable notation
/// routing — the two are separate, orthogonal decisions layered on the same
/// underlying pipeline.
///
/// The gate order and thresholds intentionally match
/// `TimecodePlaybackBridge.evaluate(pipeline:now:)` step for step so a
/// future change to one set of safety rules doesn't accidentally leave the
/// other one looser. If those checks ever need to diverge for a real
/// reason, that divergence should be a deliberate, documented decision —
/// not an accident of two copies drifting apart.
enum TimecodeNotationTrustGate {
    /// Evaluates whether `pipeline`'s current decoded state is trusted for
    /// notation routing right now.
    ///
    /// Returns `.trusted` together with the pipeline's current
    /// `PlatterPositionTimeline` when every gate passes, or the first
    /// failing gate's reason with a `nil` timeline otherwise. Never
    /// mutates `pipeline`.
    static func evaluate(
        pipeline: TimecodeControlPipeline,
        notationRoutingEnabled: Bool,
        isReplayActive: Bool,
        minConfidence: Double,
        staleThreshold: TimeInterval = 2.0,
        validationRequired: Bool = true,
        validationOverride: Bool = false,
        now: Date = Date()
    ) -> (decision: TimecodeNotationTrustDecision, timeline: PlatterPositionTimeline?) {
        guard notationRoutingEnabled else {
            return (.notationRoutingDisabled, nil)
        }

        switch pipeline.mode {
        case .disabled:
            return (.pipelineDisabled, nil)
        case .diagnosticsOnly:
            return (.diagnosticsOnly, nil)
        case .controlPrototype:
            break
        }

        if isReplayActive {
            return (.replayActive, nil)
        }

        guard pipeline.liveTapEnabled else {
            return (.liveTapOff, nil)
        }

        guard pipeline.signalHealth == .usable else {
            return (.unusableSignalHealth, nil)
        }

        if let lastBuffer = pipeline.lastBufferReceivedAt {
            let age = now.timeIntervalSince(lastBuffer)
            if age > staleThreshold {
                return (.staleSignal, nil)
            }
        }

        guard pipeline.counters.averageConfidence >= minConfidence
            || pipeline.counters.acceptedMotionSamples > 0 else {
            return (.lowConfidence, nil)
        }

        guard let timeline = pipeline.latestPlatterTimeline, !timeline.samples.isEmpty else {
            return (.missingTimeline, nil)
        }

        guard pipeline.currentDirection != .unknown else {
            return (.unknownDirection, nil)
        }

        if validationRequired {
            let snapshot = pipeline.makeValidationSnapshot(now: now)
            let statusOK = snapshot.validationStatus == .usablePrototypeControl
            if !statusOK && !validationOverride {
                return (.validationRequired, nil)
            }
        }

        return (.trusted, timeline)
    }
}
