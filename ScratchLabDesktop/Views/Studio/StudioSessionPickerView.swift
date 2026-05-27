import SwiftUI

// MARK: - StudioSessionPickerView

/// Phase D0 — minimal session picker for Studio Mode.
///
/// Lists existing `RoutineSessionDraft` entries from
/// `RoutineSessionStore` in last-activity order so a user landing in
/// the Studio tab sees a real navigation entry point. Selection drives
/// the host view which (for D0) renders a placeholder; analytic
/// surfaces (D-A1+) plug in on later slices.
///
/// **macOS-only.** This view ships behind `FeatureFlags.studioModeEnabled`
/// at the `MacAnalyzerView` tab level — when the flag is off the tab
/// (and therefore this picker) is unreachable.
///
/// **No analytics.** This is navigation only. The picker reads
/// `RoutineSessionStore.sessions` (already in memory) and writes
/// nothing back.
struct StudioSessionPickerView: View {

    @ObservedObject var store: RoutineSessionStore
    @Binding var selection: String?

    private static let appName = "ScratchLab"

    var body: some View {
        let drafts = sortedDrafts
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.horizontal, 12)
                .padding(.top, 6)
            if drafts.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(drafts) { draft in
                        StudioSessionPickerRow(draft: draft)
                            .tag(draft.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 240)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Studio")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("Sessions")
                .font(.system(size: 18, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sessions yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Record a session in the Capture tab. It will appear here for inspection.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortedDrafts: [RoutineSessionDraft] {
        store.sessions.sorted { a, b in
            a.sessionListFallbackOpenedAt > b.sessionListFallbackOpenedAt
        }
    }
}

// MARK: - StudioSessionPickerRow

/// One row in the picker. Renders a session's display name plus the
/// scratch-type / BPM summary already exposed on `CaptureSessionConfig`.
/// Read-only — never mutates the draft.
struct StudioSessionPickerRow: View {

    let draft: RoutineSessionDraft

    private static let appName = "ScratchLab"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.config.studioDisplayTitle(defaultAppName: Self.appName))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(formattedTimestamp)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: draft.sessionListFallbackOpenedAt)
    }
}
