import SwiftUI

// MARK: - ScratchLab macOS design components
//
// macOS-only presentation components that build on the shared cross-platform
// foundation in `ScratchLab/DesignSystem/ScratchLabDesignSystem.swift`. The
// tokens, StatusBadge, Chip, shared Button hierarchy, and SurfaceCard live in
// that shared file so both the macOS and iPhone/iPad targets compile them.
// This file holds only components whose behavior is macOS-specific.

// MARK: - StepHeader
//
// Numbered workflow-step caption ("① SET UP THE SESSION") used by the Capture
// sidebar's configure → readiness → record → review sequence. Number badge
// uses the accent role; the title reuses the metric-label eyebrow type role.

struct ScratchLabStepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(ScratchLabDesign.Sem.accent.opacity(0.16)))
                .overlay(Circle().stroke(ScratchLabDesign.Sem.accent.opacity(0.35), lineWidth: 1))

            Text(title.uppercased())
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(.secondary)
                .kerning(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)")
    }
}

// MARK: - SemanticErrorListView
//
// Reusable list of the formal TIMING / PLATTER / FADER semantic errors
// (`SemanticError`, from `ScratchPerformanceComparison`). Renders only the
// most actionable errors first — the derivation already sorts timing →
// platter → fader — each as one concise row: a monospaced family eyebrow, a
// direct kind label, and the performed-side explanation. The expected
// behaviour stays available as a hover tooltip (`.help`, macOS-only) so the
// full expected → performed pair is reachable without cluttering the row.
// Family colour is a restrained accent, never a full-red wash.

struct SemanticErrorListView: View {
    let errors: [SemanticError]
    var maxErrors: Int = 4

    private var visible: [SemanticError] {
        Array(errors.prefix(maxErrors))
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, error in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(error.familyLabel)
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(Self.familyColor(error.family))
                            .kerning(0.4)
                        Text(error.kindLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(error.performed)
                            .font(ScratchLabDesign.Typo.bodySecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(error.expected)
                }
            }
        }
    }

    private static func familyColor(_ family: SemanticError.Family) -> Color {
        switch family {
        case .timing: return ScratchLabDesign.Sem.warning
        case .platter: return ScratchLabDesign.Sem.info
        case .fader:  return ScratchLabDesign.Notation.fader
        }
    }
}
