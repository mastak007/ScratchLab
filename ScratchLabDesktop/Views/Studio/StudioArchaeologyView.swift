import SwiftUI

// MARK: - StudioArchaeologyData

/// Pure input shape for Phase D-A2. Derived deterministically from
/// `AudioPhraseSummary`, `PhraseBoundaryMapper`, and `TimingDrift`
/// upstream; this slice ships only the renderer. The host passes
/// `.empty` until the upstream derivation plumbs through.
struct StudioArchaeologyData: Equatable, Sendable {

    struct PhraseHeatmapEntry: Equatable, Sendable {
        let phraseIndex: Int
        /// Drift density in [0, 1]. The renderer clamps; out-of-range
        /// values render at the nearest boundary so a bad upstream
        /// signal never produces a misleading-strength colour.
        let driftDensity: Double
    }

    struct SessionTimelineEntry: Equatable, Sendable {
        let time: TimeInterval
        let label: String
    }

    struct ReleaseTailEntry: Equatable, Sendable {
        let phraseIndex: Int
        let durationSeconds: Double
    }

    let phraseHeatmap: [PhraseHeatmapEntry]
    let sessionTimelineEntries: [SessionTimelineEntry]
    let releaseTails: [ReleaseTailEntry]
    let sessionDurationSeconds: TimeInterval

    static let empty = StudioArchaeologyData(
        phraseHeatmap: [],
        sessionTimelineEntries: [],
        releaseTails: [],
        sessionDurationSeconds: 0
    )

    var isEmpty: Bool {
        phraseHeatmap.isEmpty
            && sessionTimelineEntries.isEmpty
            && releaseTails.isEmpty
    }
}

// MARK: - StudioArchaeologyView

/// Phase D-A2 archaeology panels. Three deterministic charts —
/// per-phrase drift heatmap, session timeline, and release-tail
/// durations — each with a "what this shows / what it doesn't"
/// footer so a viewer can read the surface honestly.
///
/// **macOS-only.** Reachable only when `FeatureFlags.studioModeEnabled`
/// AND `FeatureFlags.studioArchaeologyEnabled` are on at the host
/// callsite. Read-only — no `ProgressManager`, sidecar, or capture
/// state writes.
struct StudioArchaeologyView: View {

    let data: StudioArchaeologyData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            phraseHeatmapCard
            sessionTimelineCard
            releaseTailsCard
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Archaeology")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("Read-only phrase + timing inspection.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Phrase heatmap

    private var phraseHeatmapCard: some View {
        archaeologyCard(
            title: "Phrase drift heatmap",
            footer: phraseHeatmapFooter
        ) {
            if data.phraseHeatmap.isEmpty {
                emptyChart("No phrase data on this session yet.")
            } else {
                phraseHeatmapChart
            }
        }
    }

    private var phraseHeatmapChart: some View {
        GeometryReader { geo in
            let count = max(1, data.phraseHeatmap.count)
            let cellWidth = geo.size.width / Double(count)
            HStack(spacing: 1) {
                ForEach(Array(data.phraseHeatmap.enumerated()), id: \.offset) { entry in
                    let clamped = min(max(entry.element.driftDensity, 0), 1)
                    Rectangle()
                        .fill(heatmapTint(for: clamped))
                        .frame(width: max(1, cellWidth - 1))
                        .accessibilityLabel(
                            "Phrase \(entry.element.phraseIndex), drift density \(Int(clamped * 100)) percent."
                        )
                }
            }
            .frame(height: 22)
        }
        .frame(height: 22)
    }

    private func heatmapTint(for value: Double) -> Color {
        // Honest grammar: faint info-blue at low density, warning-amber
        // at high. Never a "fail" red — the renderer encodes density,
        // not judgment.
        let info = ScratchLabPalette.info
        let warning = ScratchLabPalette.warning
        let mix = max(0, min(1, value))
        return Color(
            red: nsRGB(info).red * (1 - mix) + nsRGB(warning).red * mix,
            green: nsRGB(info).green * (1 - mix) + nsRGB(warning).green * mix,
            blue: nsRGB(info).blue * (1 - mix) + nsRGB(warning).blue * mix
        )
        .opacity(0.25 + 0.5 * mix)
    }

    private func nsRGB(_ color: Color) -> (red: Double, green: Double, blue: Double) {
        // Resolve to known sRGB values via NSColor on macOS so the
        // mix is deterministic across re-runs.
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private var phraseHeatmapFooter: String {
        "Shows per-phrase drift density. Does not show technique or musicality."
    }

    // MARK: Session timeline

    private var sessionTimelineCard: some View {
        archaeologyCard(
            title: "Session timeline",
            footer: sessionTimelineFooter
        ) {
            if data.sessionTimelineEntries.isEmpty {
                emptyChart("No timeline markers for this session yet.")
            } else {
                sessionTimelineChart
            }
        }
    }

    private var sessionTimelineChart: some View {
        GeometryReader { geo in
            let duration = max(data.sessionDurationSeconds, 0.001)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 1)
                ForEach(Array(data.sessionTimelineEntries.enumerated()), id: \.offset) { entry in
                    let position = max(0, min(1, entry.element.time / duration)) * geo.size.width
                    Circle()
                        .fill(ScratchLabPalette.info)
                        .frame(width: 6, height: 6)
                        .offset(x: position - 3)
                        .accessibilityLabel(
                            "\(entry.element.label) at \(String(format: "%.2f", entry.element.time)) seconds."
                        )
                }
            }
            .frame(height: 8, alignment: .center)
        }
        .frame(height: 18)
    }

    private var sessionTimelineFooter: String {
        "Marks phrase boundaries and significant events. Does not score the session."
    }

    // MARK: Release tails

    private var releaseTailsCard: some View {
        archaeologyCard(
            title: "Release-tail durations",
            footer: releaseTailsFooter
        ) {
            if data.releaseTails.isEmpty {
                emptyChart("No release-tail data yet.")
            } else {
                releaseTailsChart
            }
        }
    }

    private var releaseTailsChart: some View {
        let maxDuration = max(data.releaseTails.map(\.durationSeconds).max() ?? 0.001, 0.001)
        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(data.releaseTails.enumerated()), id: \.offset) { entry in
                    let height = max(2, (entry.element.durationSeconds / maxDuration) * geo.size.height)
                    Rectangle()
                        .fill(ScratchLabPalette.headingCyan.opacity(0.55))
                        .frame(height: height)
                        .accessibilityLabel(
                            "Phrase \(entry.element.phraseIndex) release tail \(String(format: "%.2f", entry.element.durationSeconds)) seconds."
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36)
    }

    private var releaseTailsFooter: String {
        "Shows how long each phrase trailed off. Does not compare phrases to each other."
    }

    // MARK: Shared scaffolding

    @ViewBuilder
    private func archaeologyCard<Content: View>(
        title: String,
        footer: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            content()
            Text(footer)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyChart(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
}
