#if os(macOS)
import SwiftUI

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

struct ScratchPlaybackLabView: View {
    @StateObject private var model = ScratchPlaybackLabModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
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
            controlsRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 940, minHeight: 720)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            activityIndicator

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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                readout("Raw pitch bend", String(model.rawPitchBend))
                readout("Previous raw", model.previousRawPitchBend.map(String.init) ?? "—")
                readout("Wrapped delta", String(format: "%+d", model.wrappedDelta))
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
                Text("Measure platter ticks")
                    .font(.subheadline.weight(.semibold))
                Text("Start, rotate the platter exactly one full revolution, then Finish.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.isMeasuringTicks {
                Button("Finish tick measurement") { model.finishTickMeasurement() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start tick measurement") { model.startTickMeasurement() }
            }

            if model.isMeasuringTicks || model.hasTickResult {
                Divider().frame(height: 34)
                HStack(spacing: 22) {
                    readout("Signed ticks", String(model.tickTotalSigned))
                    readout("Abs ticks", String(model.tickAbsoluteSum))
                    readout("Max delta", String(model.tickMaxDelta))
                    readout("Events", String(model.tickEventCount))
                    readout("Alias seen", model.tickAliasObserved ? "yes" : "no",
                            tint: model.tickAliasObserved ? .red : nil)
                    readout("Suggested",
                            model.tickSuggestedPer1000.map { String(format: "%.4f s/1k", $0) } ?? "—")
                }
            }

            Spacer()
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 20) {
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
                Slider(value: $model.sampleSecondsPer1000Ticks, in: 0.002...0.12)
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

#Preview {
    ScratchPlaybackLabView()
}
#endif
