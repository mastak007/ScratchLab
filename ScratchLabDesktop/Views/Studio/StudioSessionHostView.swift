#if os(macOS)
import AppKit
#endif
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

    @ObservedObject var store: RoutineSessionStore
    let selectedDraft: RoutineSessionDraft?

    @State private var secondaryDraftID: String?

    private static let appName = "ScratchLab"

    // Phase D-X1 — export-button state. `idle` (no export running),
    // `exporting` (button disabled, "Exporting…" label), `success`
    // (briefly shows the saved file name), `failure` (briefly shows
    // the error reason). The status auto-clears back to `.idle`
    // after a short interval so the surface stays clean.
    @State private var exportStatus: ExportStatus = .idle

    fileprivate enum ExportStatus: Equatable {
        case idle
        case exporting
        case success(fileName: String)
        case failure(reason: String)
    }

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
                if FeatureFlags.studioMultiTakeEnabled {
                    multiTakeSection(primary: draft)
                }
                if FeatureFlags.studioScrubEnabled {
                    StudioReplayScrubber(
                        contentStart: 0,
                        contentEnd: max(draft.config.takeDurationSeconds ?? 0, 1)
                    )
                }
                if FeatureFlags.studioArchaeologyEnabled {
                    StudioArchaeologyView(data: archaeologyData(for: draft))
                }
                if FeatureFlags.exportNotationOverlayVideoEnabled {
                    notationVideoExportCard
                }
                comingSoonCard
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Phase D-A4 multi-take

    /// Multi-take card. Always shows the menu (so the user can pick a
    /// secondary). When a secondary is picked, renders
    /// `StudioMultiTakeView` below the menu. Clearing the menu choice
    /// returns the card to its empty state. The card itself is gated
    /// by `FeatureFlags.studioMultiTakeEnabled`.
    @ViewBuilder
    private func multiTakeSection(primary: RoutineSessionDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            multiTakeMenuRow(primary: primary)
            if let secondary = secondaryDraft(excluding: primary.id) {
                StudioMultiTakeView(primary: primary, secondary: secondary)
            } else {
                Text(CoachCopy.Compare.emptySecondaryMessage(
                    primaryName: primary.config.studioDisplayTitle(defaultAppName: Self.appName)
                ))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func multiTakeMenuRow(primary: RoutineSessionDraft) -> some View {
        HStack(spacing: 12) {
            Menu(currentMultiTakeMenuLabel(primary: primary)) {
                ForEach(otherDrafts(excluding: primary.id)) { draft in
                    Button(draft.config.studioDisplayTitle(defaultAppName: Self.appName)) {
                        secondaryDraftID = draft.id
                    }
                }
                if !otherDrafts(excluding: primary.id).isEmpty,
                   secondaryDraftID != nil {
                    Divider()
                    Button(CoachCopy.Compare.clearMenuTitle) {
                        secondaryDraftID = nil
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private func currentMultiTakeMenuLabel(primary: RoutineSessionDraft) -> String {
        guard let secondary = secondaryDraft(excluding: primary.id) else {
            return CoachCopy.Compare.menuTitle
        }
        return "\(CoachCopy.Compare.menuTitle.replacingOccurrences(of: "…", with: ":")) \(secondary.config.studioDisplayTitle(defaultAppName: Self.appName))"
    }

    private func otherDrafts(excluding primaryID: String) -> [RoutineSessionDraft] {
        store.sessions
            .filter { $0.id != primaryID }
            .sorted { $0.sessionListFallbackOpenedAt > $1.sessionListFallbackOpenedAt }
    }

    /// Resolves the secondary draft if one is selected and still
    /// exists in the store. Defensively returns `nil` when the user
    /// has selected a draft and then deleted it elsewhere; the
    /// secondaryDraftID auto-clears next render.
    private func secondaryDraft(excluding primaryID: String) -> RoutineSessionDraft? {
        guard let id = secondaryDraftID, id != primaryID else { return nil }
        return store.sessions.first { $0.id == id }
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

    /// Phase D-X1 export-button card. Flag-gated; macOS-only call site.
    /// The button exports a transparent ProRes 4444 .mov from the
    /// bundled scratch fixture — this slice ships the pipeline entry
    /// point; per-session source plumbing is a future slice. Honest
    /// copy: "demo notation video", not "your take".
    private var notationVideoExportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CoachCopy.Export.header)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    presentNotationVideoExportPanel()
                } label: {
                    if case .exporting = exportStatus {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(CoachCopy.Export.exportingLabel)
                        }
                    } else {
                        Text(CoachCopy.Export.demoVideoButtonTitle)
                    }
                }
                .disabled(exportStatus == .exporting)
                Spacer(minLength: 0)
            }
            Text(CoachCopy.Export.demoVideoCaption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let statusText = exportStatusText {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(exportStatusColor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var exportStatusText: String? {
        switch exportStatus {
        case .idle, .exporting:
            return nil
        case .success(let fileName):
            return CoachCopy.Export.saveSuccess(fileName: fileName)
        case .failure(let reason):
            return CoachCopy.Export.saveFailure(reason: reason)
        }
    }

    private var exportStatusColor: Color {
        switch exportStatus {
        case .failure: return ScratchLabPalette.warning
        default:       return .secondary
        }
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

    // MARK: Phase D-X1 export pipeline

    #if os(macOS)
    private func presentNotationVideoExportPanel() {
        let panel = NSSavePanel()
        panel.title = CoachCopy.Export.savePanelTitle
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = CoachCopy.Export.defaultFileName
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        runNotationVideoExport(to: url)
    }

    private func runNotationVideoExport(to outputURL: URL) {
        exportStatus = .exporting
        Task.detached(priority: .userInitiated) {
            let result = Self.runDemoExport(to: outputURL)
            await MainActor.run {
                exportStatus = result
                Task {
                    // Auto-clear the status after a short interval so
                    // the surface stays clean. Cancellation-safe.
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    if exportStatus == result {
                        exportStatus = .idle
                    }
                }
            }
        }
    }

    /// Runs the export off the main thread. Uses an inline scratch
    /// fixture so the export pipeline is exercised end-to-end without
    /// depending on per-session data plumbing.
    private static func runDemoExport(to outputURL: URL) -> ExportStatus {
        let presentation = demoExportPresentationModel
        let state = demoExportReplayState
        let viewportRule = demoExportViewportRule
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: presentation,
            timingGrid: demoExportTimingGrid,
            viewportRule: viewportRule,
            width: Double(demoExportWidth),
            height: Double(demoExportHeight)
        )
        guard let request = NotationOverlayVideoExportRequest(
            frames: frames,
            outputURL: outputURL,
            width: demoExportWidth,
            height: demoExportHeight,
            frameRate: demoExportFrameRate
        ) else {
            return .failure(reason: "Invalid export request shape.")
        }
        do {
            let exported = try NotationOverlayVideoExporter().export(request)
            return .success(fileName: exported.lastPathComponent)
        } catch {
            return .failure(reason: String(describing: error))
        }
    }
    #else
    private func presentNotationVideoExportPanel() {}
    #endif

    // MARK: Demo export fixture
    //
    // Inline fixture used by the export button until per-session
    // plumbing lands. Three Baby-Scratch-style strokes covering ~3 s,
    // rendered at 60 fps over a 4 s window = ~180 frames. Small
    // enough to encode in a second or two; large enough to land a
    // working .mov in OBS / Premiere / FCP for smoke testing.

    private static let demoExportWidth: Int = 960
    private static let demoExportHeight: Int = 200
    private static let demoExportFrameRate: Int = 60

    private static let demoExportPresentationModel: NotationPresentationModel = {
        NotationPresentationModel(strokes: [
            NotationPresentationStroke(
                primitiveIndex: 0,
                startTime: 0.50, endTime: 1.00,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 1,
                startTime: 1.50, endTime: 2.00,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 2,
                startTime: 2.50, endTime: 3.00,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
        ])
    }()

    private static let demoExportReplayState: NotationReplayState = {
        var frames: [NotationReplayFrame] = []
        let total = 4 * demoExportFrameRate  // 4 seconds
        let step = 1.0 / Double(demoExportFrameRate)
        frames.reserveCapacity(total)
        for index in 0..<total {
            if let frame = NotationReplayFrame(
                index: index,
                time: Double(index) * step
            ) {
                frames.append(frame)
            }
        }
        return NotationReplayState(
            contentStart: 0,
            contentEnd: 4,
            frames: frames
        ) ?? NotationReplayState(contentStart: 0, contentEnd: 1, frames: [])!
    }()

    private static let demoExportTimingGrid: TimingGrid? = TimingGrid(
        beatsPerMinute: 120,
        beatsPerBar: 4,
        subdivisionsPerBeat: 4,
        origin: 0
    )

    private static let demoExportViewportRule: NotationViewportWindowRule
        = NotationViewportWindowRule(duration: 4, leadIn: 1)!
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
