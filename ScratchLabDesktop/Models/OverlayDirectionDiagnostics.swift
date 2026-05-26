import Foundation

/// Slice 4.7 — deterministic direction-agreement diagnostics layered
/// on top of `OverlayTimingDiagnostics`.
///
/// `OverlayDirectionDiagnostics.compute(timingDiagnostics:overlay:)`
/// inspects every *paired* timing finding (`.matched`, `.early`,
/// `.late`) and decides whether the paired target stroke's direction
/// agrees with the captured stroke's direction:
///
///   - `.agree`     both sides report a direction tag and they match
///   - `.disagree`  both sides report a direction tag and they differ
///   - `.unknown`   either side's direction tag is missing or empty
///
/// `.missing` and `.extra` timing findings are excluded — they have
/// no pair to compare. Direction findings preserve the order of the
/// underlying paired timing findings exactly, so two equal
/// `(timingDiagnostics, overlay)` inputs always produce equal
/// `OverlayDirectionDiagnostics` outputs (and byte-identical JSON
/// encodings under a stable encoder).
///
/// Data source:
///   - Captured side: directions are read from `SessionReplayEvent.tag`
///     on `.recordMovement` events. The Slice 4.1
///     `SessionReplayTimeline.build(from:takeDuration:)` writes the
///     snapshot's `DetectedNotationRecordMovementEvent.direction`
///     raw value into that tag.
///   - Target side: when the overlay was projected from a
///     `ScratchNotation` (Slice 4.2's
///     `ReviewOverlayTimeline.build(targetNotation:...)`), the tag
///     holds `ScratchNotation.Stroke.direction.rawValue`.
///
/// Both come through as strings — the comparison is plain string
/// equality. The `tag` field is documented as informational on the
/// underlying timeline, which is the right semantic posture for a
/// *visual* diagnostic that does not feed replay correctness, scoring,
/// or export.
///
/// Scope (Slice 4.7, read-only, additive):
///   - movement-kind events only (already guaranteed by Slice 4.4 —
///     the timing diagnostics that feed this type filter to
///     `.recordMovement`)
///   - no UI, no review-state side effects, no export hooks, no
///     sidecar persistence
///   - no scores, no percentages, no confidence values, no grades
///   - no `.missing` / `.extra` representation — those are unpaired
///   - no ML
struct OverlayDirectionDiagnostics: Equatable, Sendable, Codable {

    static let currentSchemaVersion = "scratchlab_overlay_direction_v1"

    let schemaVersion: String
    let findings: [OverlayDirectionFinding]

    init(
        schemaVersion: String = OverlayDirectionDiagnostics.currentSchemaVersion,
        findings: [OverlayDirectionFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.findings = findings
    }

    /// Convenience: number of findings for each agreement category.
    var counts: [OverlayDirectionFinding.Agreement: Int] {
        var result: [OverlayDirectionFinding.Agreement: Int] = [:]
        for finding in findings {
            result[finding.agreement, default: 0] += 1
        }
        return result
    }

    /// Compute direction findings from already-computed timing
    /// diagnostics and the overlay they came from. Findings are
    /// emitted in the same order as the paired timing findings
    /// (`timingDiagnostics.findings` iterated, with `.missing` and
    /// `.extra` skipped).
    ///
    /// If a paired timing finding references a `targetSourceIndex` /
    /// `capturedSourceIndex` that cannot be resolved against
    /// `overlay.target` / `overlay.captured`, the finding is silently
    /// skipped — that should not happen when the timing diagnostics
    /// were computed from the same overlay, but the guard keeps the
    /// model safe if a caller hand-builds a mismatched pair.
    static func compute(
        timingDiagnostics: OverlayTimingDiagnostics,
        overlay: ReviewOverlayTimeline
    ) -> OverlayDirectionDiagnostics {
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

        var findings: [OverlayDirectionFinding] = []
        findings.reserveCapacity(timingDiagnostics.findings.count)

        for timing in timingDiagnostics.findings {
            switch timing.kind {
            case .matched, .early, .late:
                guard let tIndex = timing.targetSourceIndex,
                      let cIndex = timing.capturedSourceIndex,
                      let targetEvent = targetByIndex[tIndex],
                      let capturedEvent = capturedByIndex[cIndex]
                else { continue }

                let targetDirection = Self.nonEmptyTag(targetEvent.tag)
                let capturedDirection = Self.nonEmptyTag(capturedEvent.tag)
                let agreement: OverlayDirectionFinding.Agreement
                if let targetDirection, let capturedDirection {
                    agreement = (targetDirection == capturedDirection)
                        ? .agree
                        : .disagree
                } else {
                    agreement = .unknown
                }

                findings.append(OverlayDirectionFinding(
                    agreement: agreement,
                    targetSourceIndex: tIndex,
                    capturedSourceIndex: cIndex,
                    targetDirection: targetDirection,
                    capturedDirection: capturedDirection
                ))

            case .missing, .extra:
                // Unpaired — direction comparison does not apply.
                continue
            }
        }

        return OverlayDirectionDiagnostics(findings: findings)
    }

    /// Returns the tag if it is non-nil and non-empty; otherwise nil.
    /// "Missing direction" covers both `nil` and `""` so callers do
    /// not have to know which form a sloppy upstream produced.
    private static func nonEmptyTag(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return tag
    }
}

/// One paired direction-agreement decision. Constructed only by
/// `OverlayDirectionDiagnostics.compute(...)`.
struct OverlayDirectionFinding: Equatable, Sendable, Codable {

    /// String raw values are part of the type's persisted contract
    /// and must not change without a schemaVersion bump on
    /// `OverlayDirectionDiagnostics`.
    enum Agreement: String, Codable, Sendable, CaseIterable {
        case agree
        case disagree
        case unknown
    }

    let agreement: Agreement

    /// Source index of the paired target stroke in the original
    /// `recordMovementEvents` lane.
    let targetSourceIndex: Int

    /// Source index of the paired captured stroke in the original
    /// `recordMovementEvents` lane.
    let capturedSourceIndex: Int

    /// Direction tag observed on the target side, or `nil` when the
    /// tag is missing or empty (in which case `agreement` is
    /// `.unknown`).
    let targetDirection: String?

    /// Direction tag observed on the captured side, or `nil` when
    /// the tag is missing or empty.
    let capturedDirection: String?
}
