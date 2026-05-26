import Foundation

/// Slice 4.4 — deterministic per-stroke timing diagnostics for the
/// macOS Review overlay.
///
/// `OverlayTimingDiagnostics.compute(overlay:toleranceSeconds:pairingRadiusSeconds:)`
/// inspects a `ReviewOverlayTimeline` and produces a categorical
/// finding for every authored target stroke and for every captured
/// stroke that could not be paired:
///
///   - `.matched`     `|offset| <= toleranceSeconds`
///   - `.early`       `offset < -toleranceSeconds`, within pairing radius
///   - `.late`        `offset >  toleranceSeconds`, within pairing radius
///   - `.missing`     target had no captured within pairing radius
///   - `.extra`       captured had no target within pairing radius
///
/// `offsetSeconds` is **signed** `captured.startTime - target.startTime`
/// — negative when the captured stroke fired before its target,
/// positive when it fired after. Times are in seconds. `offsetSeconds`
/// is `nil` for `.missing` and `.extra` (no pairing exists).
///
/// Pairing rule (deterministic):
///   1. Target events are processed in the order they appear in
///      `overlay.target.events` — the canonical
///      `SessionReplayTimeline` sort (`startTime` ascending, then
///      `Kind.laneOrder`, then `sourceIndex`).
///   2. For each target, the unclaimed captured movement event whose
///      `|offset|` is smallest is paired — provided `|offset|` is
///      `<= pairingRadiusSeconds` (radius boundary is inclusive).
///   3. **Tie-break** when two captured events are equidistant from
///      one target: the one with the smaller `sourceIndex` wins. The
///      source index is the captured event's position in the
///      original `DetectedNotationSnapshot.recordMovementEvents`
///      lane (preserved end-to-end by `SessionReplayTimeline.build`).
///   4. Captured events that remain unclaimed after every target has
///      been considered surface as `.extra`, in their source-index
///      order.
///
/// Match-vs-classify boundary: the `toleranceSeconds` boundary is
/// **inclusive** — a captured stroke at exactly
/// `target.startTime + toleranceSeconds` is `.matched`; one µs past
/// surfaces as `.late`. Mirror behaviour on the early side.
///
/// Scope (Slice 4.4, read-only, additive):
///   - movement-kind events only — audio / fader / MIDI lanes are
///     intentionally excluded so this slice does not promise a
///     diagnostic it cannot honestly deliver. Audio-onset pairing,
///     direction-mismatch flagging, and fader-cut alignment are
///     future slices.
///   - no UI markers (Slice B), no review-state side effects
///     (Slice C), no export manifest changes (Slice D).
///   - no scores, no percentages, no confidence values.
///   - no sidecar persistence, no `CaptureCore` mutation.
///
/// Determinism: given identical `(overlay, tolerance, pairingRadius)`
/// inputs, two `OverlayTimingDiagnostics` values compare equal and
/// encode to byte-identical JSON.
struct OverlayTimingDiagnostics: Equatable, Sendable, Codable {

    static let currentSchemaVersion = "scratchlab_overlay_diagnostics_v1"

    /// Default match tolerance (80 ms). `|offset| <=` this surfaces
    /// as `.matched`. Within reach of the audio-onset pipeline's
    /// expected timing precision — narrow enough that a clearly
    /// off-beat stroke still classifies, wide enough to absorb
    /// onset jitter.
    static let defaultToleranceSeconds: TimeInterval = 0.080

    /// Default outer pairing radius (500 ms). Beyond this a
    /// captured / target pairing cannot exist; the target surfaces
    /// as `.missing` and the captured as `.extra`. Picked so a
    /// captured stroke cannot accidentally adopt a neighbouring
    /// target at typical Baby Scratch tempos (~250 ms half-spacing
    /// at 90 BPM).
    static let defaultPairingRadiusSeconds: TimeInterval = 0.500

    let schemaVersion: String
    let toleranceSeconds: TimeInterval
    let pairingRadiusSeconds: TimeInterval
    let findings: [OverlayStrokeFinding]

    init(
        schemaVersion: String = OverlayTimingDiagnostics.currentSchemaVersion,
        toleranceSeconds: TimeInterval,
        pairingRadiusSeconds: TimeInterval,
        findings: [OverlayStrokeFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.toleranceSeconds = toleranceSeconds
        self.pairingRadiusSeconds = pairingRadiusSeconds
        self.findings = findings
    }

    /// Convenience: number of findings for each kind.
    var counts: [OverlayStrokeFinding.Kind: Int] {
        var result: [OverlayStrokeFinding.Kind: Int] = [:]
        for finding in findings {
            result[finding.kind, default: 0] += 1
        }
        return result
    }

    static func compute(
        overlay: ReviewOverlayTimeline,
        toleranceSeconds: TimeInterval = defaultToleranceSeconds,
        pairingRadiusSeconds: TimeInterval = defaultPairingRadiusSeconds
    ) -> OverlayTimingDiagnostics {
        let tolerance = max(0, toleranceSeconds)
        // Radius must dominate tolerance; otherwise the "between
        // tolerance and radius" early/late band would be empty and a
        // sloppy caller could silently turn every match into a miss.
        let radius = max(tolerance, max(0, pairingRadiusSeconds))

        let targets = overlay.target.events.filter { $0.kind == .recordMovement }
        let capturedAll = overlay.captured.events.filter { $0.kind == .recordMovement }

        var claimed = Array(repeating: false, count: capturedAll.count)
        var findings: [OverlayStrokeFinding] = []
        findings.reserveCapacity(targets.count + capturedAll.count)

        for target in targets {
            var bestCapturedIndex: Int? = nil
            var bestAbsOffset: TimeInterval = .infinity
            var bestSignedOffset: TimeInterval = 0

            for (cIndex, captured) in capturedAll.enumerated() where !claimed[cIndex] {
                let offset = captured.startTime - target.startTime
                let absOffset = abs(offset)
                if absOffset > radius { continue }

                let strictlyBetter = absOffset < bestAbsOffset
                let tieBreakBySourceIndex: Bool = {
                    guard absOffset == bestAbsOffset,
                          let currentBest = bestCapturedIndex else { return false }
                    return captured.sourceIndex < capturedAll[currentBest].sourceIndex
                }()

                if strictlyBetter || tieBreakBySourceIndex {
                    bestAbsOffset = absOffset
                    bestSignedOffset = offset
                    bestCapturedIndex = cIndex
                }
            }

            if let cIndex = bestCapturedIndex {
                claimed[cIndex] = true
                let captured = capturedAll[cIndex]
                let kind: OverlayStrokeFinding.Kind
                if abs(bestSignedOffset) <= tolerance {
                    kind = .matched
                } else if bestSignedOffset < 0 {
                    kind = .early
                } else {
                    kind = .late
                }
                findings.append(OverlayStrokeFinding(
                    kind: kind,
                    offsetSeconds: bestSignedOffset,
                    targetSourceIndex: target.sourceIndex,
                    capturedSourceIndex: captured.sourceIndex
                ))
            } else {
                findings.append(OverlayStrokeFinding(
                    kind: .missing,
                    offsetSeconds: nil,
                    targetSourceIndex: target.sourceIndex,
                    capturedSourceIndex: nil
                ))
            }
        }

        for (cIndex, captured) in capturedAll.enumerated() where !claimed[cIndex] {
            findings.append(OverlayStrokeFinding(
                kind: .extra,
                offsetSeconds: nil,
                targetSourceIndex: nil,
                capturedSourceIndex: captured.sourceIndex
            ))
        }

        return OverlayTimingDiagnostics(
            toleranceSeconds: tolerance,
            pairingRadiusSeconds: radius,
            findings: findings
        )
    }
}

/// One categorical timing decision for a target stroke, a captured
/// stroke, or a target/captured pair. Constructed only by
/// `OverlayTimingDiagnostics.compute(...)` — the static factory is
/// the single source of truth for the invariants between `kind`,
/// `offsetSeconds`, `targetSourceIndex`, and `capturedSourceIndex`.
struct OverlayStrokeFinding: Equatable, Sendable, Codable {

    /// String raw values are part of the type's persisted contract
    /// and must not change without a schemaVersion bump on
    /// `OverlayTimingDiagnostics`.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case matched
        case early
        case late
        case missing
        case extra
    }

    let kind: Kind

    /// Signed offset in seconds: `captured.startTime - target.startTime`.
    /// `nil` for `.missing` and `.extra` — there is no pairing to
    /// measure.
    let offsetSeconds: TimeInterval?

    /// Source index of the paired target stroke. `nil` for `.extra`.
    let targetSourceIndex: Int?

    /// Source index of the paired captured stroke. `nil` for
    /// `.missing`.
    let capturedSourceIndex: Int?
}

/// Slice 4.5 — one drawable marker positioned on the Review overlay
/// lane view. Resolves an `OverlayStrokeFinding` to a `(lane,
/// timeSeconds)` placement so the renderer never has to walk the
/// `ReviewOverlayTimeline` to look up event start times.
///
/// Constructed only by `OverlayTimingDiagnostics.markers(for:)` —
/// findings whose source indices cannot be resolved against the
/// supplied overlay are silently dropped (should not occur when the
/// diagnostics value was produced by `compute(overlay:)` against the
/// same overlay).
struct OverlayDiagnosticMarker: Equatable, Sendable {

    /// Which of the two stacked lanes the marker anchors to.
    enum Lane: String, Sendable {
        /// Target / ghost lane (top). Used for `.missing` findings —
        /// "the authored target stroke had no captured counterpart".
        case target
        /// Captured / primary lane (bottom). Used for `.matched`,
        /// `.early`, `.late`, `.extra` findings — they all anchor to
        /// a captured stroke.
        case captured
    }

    let kind: OverlayStrokeFinding.Kind
    let lane: Lane

    /// Seconds along the overlay axis. Equal to the anchored event's
    /// `startTime`.
    let timeSeconds: TimeInterval

    let targetSourceIndex: Int?
    let capturedSourceIndex: Int?
}

extension OverlayTimingDiagnostics {

    /// Maps every `OverlayStrokeFinding` to a drawable marker
    /// anchored at the corresponding event's `startTime` along the
    /// shared overlay axis. Order matches `findings` order so two
    /// equal `(diagnostics, overlay)` inputs produce equal output
    /// arrays — the same determinism guarantee `compute(overlay:)`
    /// already provides for findings.
    ///
    /// Lane anchoring:
    ///   - `.missing`  → `.target`     (anchored on the target stroke
    ///                                  that had no captured pair)
    ///   - everything else → `.captured` (anchored on the captured
    ///                                  stroke being judged)
    ///
    /// Findings whose `targetSourceIndex` / `capturedSourceIndex`
    /// cannot be resolved against `overlay.target` /
    /// `overlay.captured` are dropped silently. This should never
    /// happen when both values come from the same overlay (the slice
    /// 4.4 `compute(...)` only produces source indices it has just
    /// read from the same overlay), but the guard keeps the renderer
    /// safe if a caller hand-builds a mismatched pair.
    func markers(for overlay: ReviewOverlayTimeline) -> [OverlayDiagnosticMarker] {
        let targetMovements = overlay.target.events
            .filter { $0.kind == .recordMovement }
        let capturedMovements = overlay.captured.events
            .filter { $0.kind == .recordMovement }

        // Source indices are unique within a lane (one entry per
        // `recordMovementEvents` array position), so the dictionary
        // build cannot collide.
        let targetByIndex = Dictionary(
            uniqueKeysWithValues: targetMovements.map { ($0.sourceIndex, $0) }
        )
        let capturedByIndex = Dictionary(
            uniqueKeysWithValues: capturedMovements.map { ($0.sourceIndex, $0) }
        )

        var markers: [OverlayDiagnosticMarker] = []
        markers.reserveCapacity(findings.count)

        for finding in findings {
            switch finding.kind {
            case .matched, .early, .late, .extra:
                guard let cIndex = finding.capturedSourceIndex,
                      let captured = capturedByIndex[cIndex]
                else { continue }
                markers.append(OverlayDiagnosticMarker(
                    kind: finding.kind,
                    lane: .captured,
                    timeSeconds: captured.startTime,
                    targetSourceIndex: finding.targetSourceIndex,
                    capturedSourceIndex: cIndex
                ))
            case .missing:
                guard let tIndex = finding.targetSourceIndex,
                      let target = targetByIndex[tIndex]
                else { continue }
                markers.append(OverlayDiagnosticMarker(
                    kind: finding.kind,
                    lane: .target,
                    timeSeconds: target.startTime,
                    targetSourceIndex: tIndex,
                    capturedSourceIndex: nil
                ))
            }
        }
        return markers
    }
}
