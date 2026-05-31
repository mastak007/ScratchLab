#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Scratch Playback Lab (first slice): macOS developer surface.
//
// Scope guardrails (deliberate):
// - Display + isolated playback only. Loads the bundled `ahhh.wav`, draws its
//   waveform with a platter-driven playhead, and plays scrub audio that ScratchLab
//   owns (NOT Serato). No notation, replay, coaching, capture, scoring, or export.
// - Reachable only from the Window menu, like the Controller Inspector. Suppressed
//   under test hosting.
//
// TODO (promotion): once platter-driven playback is proven here, promote this
// waveform + playhead surface into the main Practice view so ScratchLab behaves like
// Scratch Visualizer during practice. This window is temporary isolation, not the
// final UX — do not bury the long-term design under Advanced.
// TODO (next slice): add a separate beat layer with an on/off toggle (its own
// player, kept apart from ScratchLabBeatEngine and capture timing).

/// Honest onboarding/help copy for the private tester build. Pure text content, so the copy
/// can be asserted PROFILE.md-safe (no overclaiming) in tests. No marketing language.
enum TesterOnboardingContent {
    struct Section: Equatable {
        let title: String
        let body: [String]
    }

    static let title = "ScratchLab — private tester build"

    static let sections: [Section] = [
        Section(title: "What it does now", body: [
            "Captures platter and crossfader motion from a connected controller.",
            "Shows an estimated captured-notation preview of your scratch travel.",
            "Lets you replay and export the captured preview."
        ]),
        Section(title: "What it does not do yet", body: [
            "It does not score or grade your scratching.",
            "It does not name scratch techniques or claim exact technique detection.",
            "Captured notation is a preview — not a saved, scored, or final result."
        ]),
        Section(title: "Connect your controller", body: [
            "Connect a class-compliant MIDI controller (verified: RANE ONE / ONE MKII).",
            "Other gear shows an \"unverified mapping\" warning — run Verify controller mapping to check it."
        ]),
        Section(title: "Export diagnostics", body: [
            "Use Export tester bundle to save a folder of captured data to a location you choose.",
            "Nothing is uploaded — you choose what to send back."
        ]),
        Section(title: "Report issues", body: [
            "Send the diagnostics bundle with a short note on what you did and what you saw."
        ])
    ]

    /// Phrases that must never appear in user-facing tester copy (PROFILE.md safety).
    static let forbiddenPhrases = ["AI detects exactly", "real-time AI coach", "deep learning"]

    /// Every line of copy (title + section titles + bodies), for safety assertions.
    static var allText: [String] {
        [title] + sections.flatMap { [$0.title] + $0.body }
    }
}

struct ScratchPlaybackLabView: View {
    @StateObject private var model = ScratchPlaybackLabModel()
    @State private var showingOnboarding = false

    /// Display-only render foundation (roadmap R0). The single source of truth
    /// the notation previews read for style/density. Defaults reproduce the
    /// current render exactly; no UI controls are surfaced yet.
    @State private var renderConfig = PlaybackLabRenderConfig()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let warning = model.controllerWarning {
                controllerWarningBanner(warning)
                Divider()
            }
            waveform
                .frame(minHeight: 200)
                .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 20) {
                readouts
                Divider()
                qaChecklist
                    .frame(width: 300)
            }
            .padding(16)
            Divider()
            calibrationRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            diagnosticsRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            guidedMappingRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            controllerProfilesRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            capturedNotation
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            controlsRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 940, minHeight: 720)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingOnboarding) { onboardingSheet }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            activityIndicator

            controllerProfileLabel

            Picker("Source", selection: $model.selectedSourceName) {
                Text("All Sources").tag(String?.none)
                ForEach(model.sources) { source in
                    Text(source.name).tag(String?.some(source.name))
                }
            }
            .frame(maxWidth: 240)

            Picker("Deck", selection: $model.deckChannel) {
                Text("Left (ch 1)").tag(0)
                Text("Right (ch 2)").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Spacer()

            Button("Reset playhead") { model.resetPlayhead() }
            Button { showingOnboarding = true } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("What this tester build does and doesn't do")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // Honest onboarding/help sheet for the private tester build.
    private var onboardingSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TesterOnboardingContent.title)
                .font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(TesterOnboardingContent.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.headline)
                            ForEach(section.body, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(line).font(.callout)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Got it") { showingOnboarding = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }

    // Read-only active controller profile ("RANE ONE MKII" or "Unverified"). No editor
    // and no MIDI learn yet — this just surfaces which mapping the lab is trusting.
    private var controllerProfileLabel: some View {
        let profile = model.activeControllerProfile
        return HStack(spacing: 6) {
            Image(systemName: profile.isVerified ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                .foregroundStyle(profile.isVerified ? Color.green : Color.orange)
            Text("Controller profile: \(profile.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Tester-safety banner: shown only when the active MIDI source is not the verified
    // controller, so captured notation from unsupported gear is never read as ground truth.
    private func controllerWarningBanner(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
    }

    private var activityIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isListening ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
            Text(model.isListening ? "Listening" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Waveform + playhead

    private var waveform: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.10))
            if model.sampleLoaded {
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                    drawPlayhead(context: context, size: size)
                }
            } else {
                Text("ahhh.wav not found in bundle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let peaks = model.waveformPeaks
        guard !peaks.isEmpty else { return }
        let midY = size.height / 2
        let columnWidth = size.width / CGFloat(peaks.count)
        var path = Path()
        for (index, peak) in peaks.enumerated() {
            let x = CGFloat(index) * columnWidth + columnWidth / 2
            let top = midY - CGFloat(peak.max) * midY
            let bottom = midY - CGFloat(peak.min) * midY
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: max(bottom, top + 1)))
        }
        context.stroke(path, with: .color(Color.cyan.opacity(0.65)), lineWidth: 1)

        // Played portion tint, left of the playhead.
        let playheadX = CGFloat(model.samplePositionFraction) * size.width
        context.fill(
            Path(CGRect(x: 0, y: 0, width: playheadX, height: size.height)),
            with: .color(Color.cyan.opacity(0.08))
        )
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        let x = CGFloat(model.samplePositionFraction) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Color.orange), lineWidth: 2)
    }

    // MARK: - Readouts

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                readout("CC6 step (drives playback)", String(format: "%+d", model.cc6Step),
                        tint: model.cc6Step > 0 ? .green : (model.cc6Step < 0 ? .orange : nil))
                readout("Raw pitch bend (diag)", String(model.rawPitchBend))
                readout("Wrapped delta (diag)", String(format: "%+d", model.wrappedDelta))
                readout("Event rate", String(format: "%.0f Hz", model.eventRateHz))
            }
            HStack(spacing: 28) {
                readout("Position", String(format: "%.3f s", model.samplePositionSeconds))
                readout("Position %", String(format: "%.1f%%", model.samplePositionFraction * 100))
                readout("Duration", String(format: "%.3f s", model.sampleDuration))
                readout("Clamp", clampLabel)
            }
            HStack(spacing: 28) {
                readout("Sensitivity", String(format: "%.4f s / 1k", model.sampleSecondsPer1000Ticks))
                readout("Max |delta|", String(model.maxObservedDelta), tint: aliasTint)
                readout("Alias", aliasLabel, tint: aliasTint)
                readout("Delta clamped", model.deltaClamped ? "yes" : "no")
            }
            HStack(spacing: 28) {
                readout("Crossfader", model.crossfaderValid ? String(format: "%.2f", model.crossfader) : "—")
                readout("Crossfader valid", model.crossfaderValid ? "yes" : "no")
                readout("XF channel", model.crossfaderChannel.map { "ch \($0 + 1)" } ?? "—")
            }

            if let warning = aliasWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(aliasTint ?? .secondary)
            }

            Text("RANE platter tracked as absolute angle → sample position (delta-with-wrap). Audio owned by ScratchLab (bundled ahhh.wav, not Serato). Clamp at sample ends; no wrap, no beat layer yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clampLabel: String {
        if model.isAtStart { return "at start" }
        if model.isAtEnd { return "at end" }
        return "—"
    }

    private var aliasLabel: String {
        switch model.aliasRisk {
        case .none: return "ok"
        case .warn: return "warn"
        case .fail: return "ALIAS"
        }
    }

    private var aliasTint: Color? {
        switch model.aliasRisk {
        case .none: return nil
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private var aliasWarning: String? {
        switch model.aliasRisk {
        case .none:
            return nil
        case .warn:
            return "Max per-event delta exceeded \(ScratchPlatterPlayheadMapper.aliasWarnThreshold) ticks — motion is getting large relative to the wrap window."
        case .fail:
            return "Max per-event delta exceeded \(ScratchPlatterPlayheadMapper.aliasFailThreshold) ticks — direction may alias. Scratch slower, lower sensitivity, or re-check platter resolution."
        }
    }

    private func readout(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tint ?? .primary)
        }
    }

    // MARK: - Calibration (rotate one revolution)

    private var calibrationRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Measure platter steps (CC6)")
                    .font(.subheadline.weight(.semibold))
                Text("Start, rotate the platter exactly one full revolution, then Finish (≈3932 steps).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.isMeasuringTicks {
                Button("Finish measurement") { model.finishTickMeasurement() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start measurement") { model.startTickMeasurement() }
            }

            if model.isMeasuringTicks || model.hasTickResult {
                Divider().frame(height: 34)
                HStack(spacing: 22) {
                    readout("Signed steps", String(model.tickTotalSigned))
                    readout("Abs steps", String(model.tickAbsoluteSum))
                    readout("Max step", String(model.tickMaxDelta))
                    readout("Events", String(model.tickEventCount))
                    readout("Suggested",
                            model.tickSuggestedPer1000.map { String(format: "%.4f s/1k", $0) } ?? "—")
                }
                if let suggested = model.tickSuggestedPer1000 {
                    Button("Apply suggested") { model.sampleSecondsPer1000Ticks = suggested }
                        .help("Set sensitivity to the measured ticks-per-revolution suggestion")
                }
            }

            Spacer()
        }
    }

    // MARK: - RANE diagnostic recorder (capture raw events → JSON)

    private var diagnosticsRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostic recorder")
                    .font(.subheadline.weight(.semibold))
                Text("Capture raw platter events to JSON. Calibration = rotate one revolution for a ticks/rev estimate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.isRecordingDiagnostics {
                Button("Stop recording") { model.stopDiagnosticRecording() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Record") { model.startDiagnosticRecording() }
                Button("Calibration record") { model.startDiagnosticRecording(calibration: true) }
            }

            Button("Export JSON") {
                presentSavePanel(suggestedName: PlaybackLabExport.diagnosticFilename(epoch: exportEpoch()),
                                 contentTypes: [.json]) { model.exportDiagnostics(to: $0) }
            }
            .disabled(model.isRecordingDiagnostics || model.diagnosticEventCount == 0)

            Divider().frame(height: 34)

            HStack(spacing: 22) {
                readout("State", model.isRecordingDiagnostics
                        ? (model.isCalibrationRecording ? "calibrating" : "recording")
                        : "idle",
                        tint: model.isRecordingDiagnostics ? .green : nil)
                readout("Events", String(model.diagnosticEventCount),
                        tint: model.diagnosticReachedCapacity ? .red : nil)
                if let summary = model.diagnosticSummary {
                    readout("Wraps", String(summary.wrapCount))
                    readout("Max delta", String(summary.maxAbsoluteDelta),
                            tint: summary.aliasFailCount > 0 ? .red : nil)
                    readout("Ticks/rev",
                            summary.estimatedTicksPerRevolution.map(String.init) ?? "—")
                }
            }

            Divider().frame(height: 34)

            // Sample-position timeline export (captured travel → JSON; no notation yet).
            VStack(alignment: .leading, spacing: 2) {
                Button("Export timeline JSON") {
                    presentSavePanel(suggestedName: PlaybackLabExport.timelineFilename(epoch: exportEpoch()),
                                     contentTypes: [.json]) { model.exportTimeline(to: $0) }
                }
                .disabled(model.timelineEventCount == 0)
                timelineExportStatus
            }

            Spacer()
        }
        .overlay(alignment: .bottomLeading) {
            diagnosticExportStatus
        }
    }

    @ViewBuilder
    private var timelineExportStatus: some View {
        if let error = model.lastTimelineExportError {
            Text("Timeline export failed: \(error)")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let path = model.lastTimelineExportPath {
            Text("Timeline → \(path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("\(model.timelineEventCount) samples captured")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var diagnosticExportStatus: some View {
        if model.diagnosticReachedCapacity {
            Text("Capacity cap reached (\(RaneDiagnosticRecorder.maxEvents) events) — recording stopped.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .offset(y: 18)
        } else if let error = model.lastDiagnosticExportError {
            Text("Export failed: \(error)")
                .font(.caption2)
                .foregroundStyle(.red)
                .offset(y: 18)
        } else if let path = model.lastDiagnosticExportPath {
            Text("Exported → \(path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .offset(y: 18)
        }
    }

    // MARK: - Guided controller mapping check (experimental; memory only)

    // A first-pass guided flow so a tester on unsupported gear can spin the platter and
    // move the crossfader, see what ScratchLab inferred, and confirm it. The result is an
    // EXPERIMENTAL mapping held in memory only — it drives no capture, persistence, or export.
    private var guidedMappingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Verify controller mapping")
                    .font(.subheadline.weight(.semibold))
                Text("experimental")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                Spacer()
            }
            guidedMappingBody
        }
    }

    @ViewBuilder
    private var guidedMappingBody: some View {
        switch model.guidedMappingStep {
        case .idle:
            HStack(spacing: 12) {
                Text("Check what ScratchLab thinks your platter and crossfader are. Builds an experimental mapping only — it is not used for capture yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start mapping check") { model.startGuidedMapping() }
            }
        case .spinPlatter:
            guidedStepRow(
                title: "Step 1 of 2 — Spin the platter forward and back.",
                nextTitle: "Next: crossfader"
            )
        case .moveCrossfader:
            guidedStepRow(
                title: "Step 2 of 2 — Move the crossfader fully open and closed.",
                nextTitle: "See result"
            )
        case .review(let candidates):
            guidedReview(candidates, confirmed: false)
        case .confirmed(let candidates):
            guidedReview(candidates, confirmed: true)
        }
    }

    private func guidedStepRow(title: String, nextTitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.medium))
                Text("\(model.guidedCollectedCount) MIDI events captured")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.cancelGuidedMapping() }
            Button(nextTitle) { model.advanceGuidedMapping() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func guidedReview(_ candidates: InferredMappingCandidates, confirmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            inferredControlLine(label: "Platter", candidate: candidates.platter)
            inferredControlLine(label: "Crossfader", candidate: candidates.crossfader)
            ForEach(candidates.notes, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if confirmed {
                    Label("Experimental mapping confirmed (memory only).",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Done") { model.cancelGuidedMapping() }
                } else {
                    Spacer()
                    Button("Cancel") { model.cancelGuidedMapping() }
                    Button("Confirm experimental mapping") { model.advanceGuidedMapping() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func inferredControlLine(label: String, candidate: InferredControlCandidate?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: candidate != nil ? "dot.radiowaves.left.and.right" : "questionmark.circle")
                .foregroundStyle(candidate != nil ? Color.green : Color.secondary)
            Text("\(label):").font(.caption.weight(.medium))
            if let candidate {
                Text(signalDescription(candidate.signal))
                    .font(.system(.caption, design: .monospaced))
                Text(String(format: "(%.0f%% confidence)", candidate.confidence * 100))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("not detected").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func signalDescription(_ signal: ControllerControlSignal) -> String {
        switch signal {
        case .controlChange(let number): return "CC\(number)"
        case .pitchBend: return "Pitch bend"
        }
    }

    // MARK: - Controller profiles (import / export)

    // Export the built-in RANE profile as an editable controller_profile_v1 template, or
    // import a profile JSON to persist for this tester. No timeline/session export is touched.
    private var controllerProfilesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Controller profiles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Export RANE template") {
                    presentSavePanel(suggestedName: PlaybackLabExport.raneProfileTemplateFilename,
                                     contentTypes: [.json]) { model.exportRaneProfileTemplate(to: $0) }
                }
                Button("Import profile…") { presentProfileImportPanel() }
                Button("Export tester bundle") {
                    presentSavePanel(suggestedName: PlaybackLabExport.testerBundleFolderName(epoch: exportEpoch()),
                                     contentTypes: []) { model.exportTesterDiagnostics(toFolder: $0) }
                }
            }
            profileExportStatus
            profileImportStatus
            diagnosticsBundleStatus
        }
    }

    @ViewBuilder
    private var diagnosticsBundleStatus: some View {
        if let error = model.lastDiagnosticsBundleError {
            Text("Tester bundle failed: \(error)")
                .font(.caption2).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
        } else if let path = model.lastDiagnosticsBundlePath {
            Text("Tester bundle → \(path)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var profileExportStatus: some View {
        if let error = model.lastProfileExportError {
            Text("Profile export failed: \(error)")
                .font(.caption2).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
        } else if let path = model.lastProfileExportPath {
            Text("Template → \(path)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var profileImportStatus: some View {
        if let error = model.lastProfileImportError {
            Text("Profile import failed: \(error)")
                .font(.caption2).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
        } else if let name = model.lastProfileImportName {
            Text("Imported: \(name)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func presentProfileImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import controller profile"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importProfile(from: url)
    }

    /// Current epoch seconds for the save-panel default file/folder names.
    private func exportEpoch() -> Int { Int(Date().timeIntervalSince1970) }

    /// Presents a save panel and calls `write` with the user-chosen URL. Sandbox-safe: the
    /// app only writes where the user pointed it (powerbox grants access to that URL), so no
    /// broad Downloads entitlement is needed. `contentTypes` empty = no extension restriction
    /// (used for the diagnostics folder).
    private func presentSavePanel(suggestedName: String,
                                  contentTypes: [UTType],
                                  write: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(url)
    }

    // MARK: - Captured notation preview (read-only)

    // Renders the live `ScratchSampleTimelineNotation.path` through the shared
    // `ScratchMotionRenderer`, so the captured travel is drawn as notation here
    // the same way Practice/Review draw it. Read-only and preview-only: no PNG,
    // no save, no export. Sample position maps straight onto lane height — a
    // partial scratch reads as partial height, never renormalised to full.
    private var capturedNotation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Captured notation")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("absolute sample position · preview only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Export PNG") { exportCapturedNotationPNG() }
                    .disabled(model.timelineEventCount == 0)
            }
            notationPNGExportStatus
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.10))
                if model.timelineEventCount == 0 {
                    Text("Scratch to capture notation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Canvas { context, size in
                        drawCapturedNotation(context: context, size: size)
                    }
                    .padding(8)
                }
            }
            .frame(height: 120)
            replayTransport
        }
    }

    // Minimal replay transport for reviewing the captured timeline (no target overlay yet).
    private var replayTransport: some View {
        HStack(spacing: 12) {
            if model.replayActive {
                Button(model.replayIsPlaying ? "Pause" : "Play") { model.toggleReplayPlayback() }
                    .buttonStyle(.borderedProminent)
                Button("Reset") { model.resetReplay() }
                Slider(
                    value: Binding(get: { model.replayFraction },
                                   set: { model.seekReplay(toFraction: $0) }),
                    in: 0...1
                )
                .frame(maxWidth: 280)
                Text(String(format: "%.2f / %.2f s", model.replayCurrentTime, model.replayDuration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Close") { model.endReplay() }
            } else {
                Button("Replay captured timeline") { model.startReplay() }
                    .disabled(model.timelineEventCount < 2)
                Text("Review the captured travel (play / pause / scrub). Does not change the capture.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func drawCapturedNotation(context: GraphicsContext, size: CGSize) {
        CapturedNotationRenderer.draw(model.timelineNotation, renderConfig: renderConfig,
                                      in: context, size: size)
        // Replay playhead (review only) — drawn here, not in the shared renderer, so the
        // exported PNG never carries the transient playhead line.
        if model.replayActive {
            let x = CGFloat(model.replayFraction) * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private var notationPNGExportStatus: some View {
        if let error = model.lastNotationPNGExportError {
            Text("PNG export failed: \(error)")
                .font(.caption2).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
        } else if let path = model.lastNotationPNGExportPath {
            Text("PNG → \(path)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    // Renders the captured notation to a PNG at a wide aspect (matching the preview's
    // truthful left→right layout), then asks for a user-selected destination (sandbox-safe)
    // and hands the bytes to the model to write there.
    private func exportCapturedNotationPNG() {
        let data = CapturedNotationImage.pngData(
            notation: model.timelineNotation,
            renderConfig: renderConfig,
            size: CGSize(width: 1200, height: 300)
        )
        presentSavePanel(suggestedName: PlaybackLabExport.notationPNGFilename(epoch: exportEpoch()),
                         contentTypes: [.png]) { model.exportCapturedNotationPNG(data, to: $0) }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 20) {
            Toggle("Loop playback", isOn: $model.loopPlayback)
            Toggle("Invert direction", isOn: $model.inverted)
            Toggle("Limit delta (safety)", isOn: $model.limitDeltaForSafety)
            Toggle("Apply crossfader to volume", isOn: $model.applyCrossfaderToVolume)
            Button("Reset max delta") { model.resetMaxDelta() }

            Spacer()

            HStack(spacing: 6) {
                Text("Sensitivity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.4f s/1k", model.sampleSecondsPer1000Ticks))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 70, alignment: .trailing)
                Slider(value: $model.sampleSecondsPer1000Ticks, in: 0.02...1.0)
                    .frame(width: 220)
            }
        }
    }

    // MARK: - Manual QA checklist

    private var qaChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual QA")
                .font(.headline)
            checklistRow("Selected source", value: model.selectedSourceName ?? "All sources",
                         ok: model.selectedSourceName != nil)
            checklistRow("Source unique ID", value: model.selectedSourceID.map(String.init) ?? "—",
                         ok: model.selectedSourceID != nil)
            checklistRow("Deck", value: model.deckChannel == 0 ? "Left" : "Right", ok: true)
            checklistRow("Playback mode", value: model.loopPlayback ? "loop" : "clamp", ok: true)
            checklistRow("Pitch Bend arriving", value: model.pitchBendArriving ? "yes" : "no",
                         ok: model.pitchBendArriving)
            checklistRow("Crossfader arriving", value: model.crossfaderArriving ? "yes" : "no",
                         ok: model.crossfaderArriving)
            checklistRow("Playhead moving", value: model.playheadMoving ? "yes" : "no",
                         ok: model.playheadMoving)
            checklistRow("Audio engine running", value: model.audioRunning ? "yes" : "no",
                         ok: model.audioRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checklistRow(_ label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// Shared captured-notation drawing, so the live preview and the PNG export render the
// SAME geometry through the SAME renderer — truthful absolute positions, no Fit-to-View
// and no vertical compression. Sample position maps straight onto lane height.
enum CapturedNotationRenderer {
    static func draw(_ notation: ScratchSampleTimelineNotation,
                     renderConfig: PlaybackLabRenderConfig,
                     in context: GraphicsContext,
                     size: CGSize) {
        guard !notation.isEmpty else { return }

        // Fit the WHOLE captured timeline left→right: first sample at the leading edge,
        // last at the trailing edge. A horizontal lane maps sample position onto height
        // (0 = bottom/rest, 1 = top/full), straight through with no renormalisation.
        let range = notation.path.timeRange
        let duration = max(range.upperBound - range.lowerBound, 0.001)
        let viewport = LaneViewport(size: size, now: range.lowerBound, axis: .horizontal,
                                    actionLineFraction: 0,
                                    secondsAhead: renderConfig.secondsAhead(forDuration: duration))

        // Subtle muted indicators: crossfader-closed spans get a faint band so their
        // timing is visible without dropping any travel from the path.
        for span in notation.mutedSpans {
            let x0 = viewport.pos(for: span.lowerBound)
            let x1 = viewport.pos(for: span.upperBound)
            let rect = CGRect(x: min(x0, x1), y: 0,
                              width: max(abs(x1 - x0), 1), height: size.height)
            context.fill(Path(rect), with: .color(.white.opacity(renderConfig.mutedAlpha)))
        }

        ScratchMotionRenderer.draw(notation.path, in: context,
                                   viewport: viewport, style: renderConfig.motionStyle)
    }
}

/// A standalone Canvas of the captured notation, used both inline and (via ImageRenderer)
/// for PNG export.
struct CapturedNotationCanvas: View {
    let notation: ScratchSampleTimelineNotation
    let renderConfig: PlaybackLabRenderConfig

    var body: some View {
        Canvas { context, size in
            CapturedNotationRenderer.draw(notation, renderConfig: renderConfig, in: context, size: size)
        }
    }
}

/// Off-screen PNG rendering of the captured notation. Reuses the same canvas/renderer as
/// the live preview so the exported image is truthful (no Fit-to-View, no compression).
enum CapturedNotationImage {
    /// Renders the captured notation to PNG data, or nil if there is nothing to draw.
    @MainActor
    static func pngData(notation: ScratchSampleTimelineNotation,
                        renderConfig: PlaybackLabRenderConfig,
                        size: CGSize,
                        scale: CGFloat = 2.0) -> Data? {
        guard !notation.isEmpty else { return nil }
        let content = CapturedNotationCanvas(notation: notation, renderConfig: renderConfig)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.10))
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}

#Preview {
    ScratchPlaybackLabView()
}
#endif
