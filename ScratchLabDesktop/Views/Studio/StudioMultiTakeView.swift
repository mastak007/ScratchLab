import SwiftUI

// MARK: - StudioMultiTakeView

/// Phase D-A4 — side-by-side metadata comparison of two
/// `RoutineSessionDraft`s in the Studio host.
///
/// Renders the primary and secondary drafts as two equal columns
/// (title, scratch type, BPM, take length, created date) plus an
/// observational delta strip below — BPM and take-length differences
/// stated factually, never ranked. Per-session notation rendering is
/// deferred (placeholder); this slice ships the selection + layout
/// plumbing.
///
/// **Compare, never better.** Every string is observational. The view
/// has no winner badge, no "best of" verb, no grading vocabulary. The
/// doc's Phase D-A4 rule is enforced here in code: "compare" not
/// "better."
///
/// macOS-only via the host. Read-only — never mutates either draft.
struct StudioMultiTakeView: View {

    let primary: RoutineSessionDraft
    let secondary: RoutineSessionDraft

    private static let appName = "ScratchLab"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 18) {
                column(for: primary, label: CoachCopy.Compare.primaryColumn)
                column(for: secondary, label: CoachCopy.Compare.secondaryColumn)
            }
            deltaStrip
            Text(CoachCopy.Compare.placeholderNotation)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(CoachCopy.Compare.header)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            scratchEqualityBadge
        }
    }

    private var scratchEqualityBadge: some View {
        let sameScratch = primary.config.scratchType == secondary.config.scratchType
            && primary.config.scratchType != nil
        return Text(
            sameScratch
                ? CoachCopy.Compare.sameScratchBadge
                : CoachCopy.Compare.differentScratchBadge
        )
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(sameScratch ? .secondary : .tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel(
            sameScratch
                ? CoachCopy.Compare.sameScratchBadge
                : CoachCopy.Compare.differentScratchBadge
        )
    }

    // MARK: Columns

    private func column(
        for draft: RoutineSessionDraft,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(draft.config.studioDisplayTitle(defaultAppName: Self.appName))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            Text(draft.config.scratchTypeAndBPMSummary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            metaRow(
                value: takeLengthString(draft.config.takeDurationSeconds),
                label: "Take length"
            )
            metaRow(
                value: createdDateString(draft.config.createdAt),
                label: "Created"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metaRow(value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Delta strip

    private var deltaStrip: some View {
        let primaryBPM = primary.config.bpm
        let secondaryBPM = secondary.config.bpm
        let primaryLength = primary.config.takeDurationSeconds ?? 0
        let secondaryLength = secondary.config.takeDurationSeconds ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(CoachCopy.Compare.bpmDelta(primary: primaryBPM, secondary: secondaryBPM))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(CoachCopy.Compare.takeLengthDelta(primary: primaryLength, secondary: secondaryLength))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: Formatting

    private func takeLengthString(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        return String(format: "%.1f s", seconds)
    }

    private func createdDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
