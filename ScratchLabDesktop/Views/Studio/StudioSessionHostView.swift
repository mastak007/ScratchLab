import SwiftUI

// MARK: - StudioSessionHostView

/// Phase D0 — host surface for the Studio tab.
///
/// Renders either an "Open a session" placeholder when nothing is
/// selected, or a minimal session header when a draft is picked. The
/// host is the integration point for the D-A1+ analytic surfaces
/// (scrubber, archaeology, annotations, multi-take, drill authoring);
/// for D0 it intentionally shows the bare scaffold so the navigation
/// can be smoke-tested independently of analytics.
///
/// **macOS-only.** Reachable only when `FeatureFlags.studioModeEnabled`
/// is on at the `MacAnalyzerView` tab level. Read-only — the host
/// never writes back to `RoutineSessionStore` or any sidecar.
struct StudioSessionHostView: View {

    let selectedDraft: RoutineSessionDraft?

    private static let appName = "ScratchLab"

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()
            if let draft = selectedDraft {
                sessionContent(for: draft)
            } else {
                placeholder
            }
        }
    }

    private func sessionContent(for draft: RoutineSessionDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(for: draft)
                if FeatureFlags.studioScrubEnabled {
                    StudioReplayScrubber(
                        contentStart: 0,
                        contentEnd: max(draft.config.takeDurationSeconds ?? 0, 1)
                    )
                }
                if FeatureFlags.studioArchaeologyEnabled {
                    StudioArchaeologyView(data: archaeologyData(for: draft))
                }
                comingSoonCard
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for draft: RoutineSessionDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.config.studioDisplayTitle(defaultAppName: Self.appName))
                .font(.system(size: 22, weight: .bold))
                .lineLimit(2)
            Text(draft.config.scratchTypeAndBPMSummary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var comingSoonCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Studio analytics arrive in upcoming slices")
                .font(.system(size: 13, weight: .semibold))
            Text("Scrubber, phrase archaeology, annotations, and multi-take comparison ship behind their own flags. This pane is the navigation host.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Phase D-A2 — derives archaeology chart data from existing
    /// session state. Returns `.empty` for now because the live plumb
    /// from `RoutineSessionDraft` through `AudioPhraseSummary` +
    /// `PhraseBoundaryMapper` + `TimingDrift` is not yet wired in
    /// production. The renderer ships with this empty contract so the
    /// surface stays honest until the upstream derivation lands.
    private func archaeologyData(for draft: RoutineSessionDraft) -> StudioArchaeologyData {
        _ = draft
        return .empty
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("Open a session to inspect it.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Local helper

extension CaptureSessionConfig {
    /// Phase D0 display-title helper for the Studio surfaces. Mirrors
    /// the existing `CaptureSession.sessionName(defaultAppName:)`
    /// logic but reads `CaptureSessionConfig` directly so picker and
    /// host views can build the same title from a `RoutineSessionDraft`
    /// without going through the live capture wrapper. Read-only — the
    /// helper never mutates the config.
    func studioDisplayTitle(defaultAppName: String) -> String {
        let trimmedName = performerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? defaultAppName : trimmedName
        let scratchLabel: String? = {
            guard let scratchType, scratchType != .unknown else { return nil }
            return scratchType.title
        }()
        if captureMode == .calibrationNoClick, let scratchLabel {
            return "\(baseName) \(scratchLabel) Calibration"
        }
        if let bpm, let scratchLabel {
            return "\(baseName) \(scratchLabel) \(bpm) BPM"
        }
        if let scratchLabel {
            return "\(baseName) \(scratchLabel)"
        }
        return baseName
    }

    /// Compact one-liner reused by the Studio host header. Reads only
    /// fields already present on `CaptureSessionConfig` — no inference,
    /// no overclaim, no PROFILE.md-forbidden vocabulary — and falls
    /// back to just the scratch-type name when BPM is absent.
    var scratchTypeAndBPMSummary: String {
        let scratchLabel = scratchType?.title ?? "Scratch"
        if let bpm {
            return "\(scratchLabel) · \(bpm) BPM"
        }
        return scratchLabel
    }
}
