#if DEBUG
import SwiftUI
import Combine

/// Mac Analyzer panel: DVS control-vinyl signal diagnostics.
///
/// Read-only view — surfaces diagnostics from a `TimecodeControlPipeline`
/// already owned by the parent screen. Isolated from unrelated app subsystems.
///
/// Layout is intentionally stable across live updates: every section is
/// always present once mounted (no block insertion/removal), values render
/// in fixed-height rows, and verbose per-channel/per-pair detail lives in a
/// collapsed disclosure group so hardware validation isn't disrupted by
/// layout reflow.
struct DVSControlVinylPanel: View {

    // Listening-fix (SwiftUI publish-during-render, uncommitted): plain
    // (not `@ObservedObject`) — `pipeline` is realtime, lock-protected
    // state updated by the DVS control worker at ~60 Hz; observing it
    // directly here re-ran this entire panel's body on every tick,
    // regardless of any coalescing on the pipeline's own `objectWillChange`
    // (dispatching an already-coalesced notification to the main queue
    // still doesn't guarantee it lands *between* SwiftUI render passes at
    // that rate). Reading `pipeline.*` as plain properties instead — every
    // read below is already thread-safe and always current — and gating
    // this view's re-render on `uiRefreshTick` (bumped by the existing
    // 4 Hz `timer` below, the same cadence this panel's log already used)
    // moves the redraw onto a bounded, main-actor-only cadence that is
    // never triggered from the realtime tick at all.
    let pipeline: TimecodeControlPipeline

    @StateObject private var logger = DVSLiveLogger()
    @State private var copyConfirmed = false
#if ENABLE_TIMECODE_LIVE_TAP
    @State private var isDetailsExpanded = false
#endif
    @State private var uiRefreshTick = 0

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlsSection
            liveReadingsSection
            statusSection
            outputCaptureSection
#if ENABLE_TIMECODE_LIVE_TAP
            detailsSection
#endif
            logSection
        }
        .padding()
        .transaction { $0.animation = nil }
        .onReceive(timer) { _ in
            logger.append(makeLogEntry())
            uiRefreshTick += 1
        }
    }

    // MARK: - Output capture (manual diagnostics, DEBUG-only)

    /// Manual post-mixer output capture: Start installs/arms the tap and shows
    /// "Capture armed"; Stop & Export removes the tap, finalizes the captured
    /// frames and exports immediately, showing the exact success path or error
    /// in the UI (and console). Independent of platter stop / pause / ramp /
    /// engine teardown. Status re-read from the shared control each tick.
    private var outputCaptureSection: some View {
        GroupBox("Output Capture (manual diagnostics)") {
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow("Status",
                              ScratchSamplePlaybackController.OutputCaptureDiagnosticsControl.shared.status.isEmpty
                                  ? "Capture idle"
                                  : ScratchSamplePlaybackController.OutputCaptureDiagnosticsControl.shared.status)
                HStack(spacing: 8) {
                    Button("Start Output Capture") {
                        ScratchSamplePlaybackController.OutputCaptureDiagnosticsControl.shared.start()
                    }
                    Button("Stop & Export") {
                        ScratchSamplePlaybackController.OutputCaptureDiagnosticsControl.shared.stopAndExport()
                    }
                }
                Text("Capture is written to ~/Library/Containers/com.machelpnz.scratchlab/Data/Library/Application Support/ScratchLab/Diagnostics/scratchlab-output-capture.wav")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: - Controls (stable — mode, live tap, pair/channel selection, health)

    private var controlsSection: some View {
        GroupBox("Controls") {
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow("Mode", pipeline.mode.shortLabel)
                diagnosticRow("Live tap", liveTapStatusText)

#if ENABLE_TIMECODE_LIVE_TAP
                Picker("USB channel pair", selection: channelPairSelectionBinding) {
                    Text("Auto").tag(TimecodeCMSampleBufferAdapter.ChannelPairSelection.auto)
                    if case let .pair(startChannel) = TimecodeCMSampleBufferAdapter.channelPairSelection,
                       !pairOptions.contains(startChannel) {
                        Text("\(startChannel + 1)/\(startChannel + 2)")
                            .tag(
                                TimecodeCMSampleBufferAdapter.ChannelPairSelection.pair(
                                    startChannel: startChannel
                                )
                            )
                    }
                    ForEach(pairOptions, id: \.self) { startChannel in
                        Text("\(startChannel + 1)/\(startChannel + 2)")
                            .tag(
                                TimecodeCMSampleBufferAdapter.ChannelPairSelection.pair(
                                    startChannel: startChannel
                                )
                            )
                    }
                }
                .pickerStyle(.menu)

                diagnosticRow("Channel mode", pipeline.inputChannel.label)
                diagnosticRow("Auto-recommended pair", diagnostics?.autoRecommendedChannelPair ?? "—")
#else
                diagnosticRow("USB channel pair", "Not compiled")
#endif
                diagnosticRow("Signal health", pipeline.signalHealth.rawValue)
            }
            .padding(4)
        }
    }

    private var liveTapStatusText: String {
#if ENABLE_TIMECODE_LIVE_TAP
        pipeline.liveTapEnabled ? "On" : "Off"
#else
        "Not compiled"
#endif
    }

    // MARK: - Live readings (stable — updates in place, never inserts/removes rows)

    private var liveReadingsSection: some View {
        GroupBox("Live Readings") {
            VStack(alignment: .leading, spacing: 6) {
                levelRow(label: "RMS", value: rms, tint: .accentColor)
                levelRow(label: "Peak", value: peak, tint: peak > 0.95 ? .red : .orange)
                diagnosticRow("Frequency", frequencyHz.map { "~\(Int($0)) Hz" } ?? "—")

                Divider()

                HStack(spacing: 16) {
                    directionBadge
                    diagnosticRow("Speed", String(format: "%.2f×", relativeRate))
                    diagnosticRow("Conf.", String(format: "%.0f%%", confidence * 100))
                }

                diagnosticRow("Selected pair", diagnostics?.selectedChannelPair ?? "—")
                diagnosticRow(
                    "Adapter format",
                    diagnostics.map { "\($0.formatSummary) @ \(Int($0.sampleRate)) Hz" } ?? "—"
                )
            }
            .padding(4)
        }
    }

    private func levelRow(label: String, value: Float, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(tint.opacity(0.25))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * CGFloat(min(value * 4, 1)))
                    }
            }
            .frame(height: 6)
            Text(String(format: "%.4f", value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 55, alignment: .trailing)
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(minHeight: 16)
    }

    private var directionBadge: some View {
        let (label, color): (String, Color) = {
            switch direction {
            case .forward:  return ("▶ Forward",  .green)
            case .backward: return ("◀ Backward", .blue)
            case .stopped:  return ("■ Stopped",  .secondary)
            case .unknown:  return ("? Unknown",  .secondary)
            }
        }()
        return Text(label)
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(color)
            .frame(minWidth: 100, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Status (fixed-height rows in place of appearing/disappearing blocks)

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 6) {
                diagnosticRow("Last drop", pipeline.lastDropReason?.rawValue ?? "None")
                diagnosticRow("Setup", hasSignal ? "OK — signal present" : setupSummary)
                    .help(setupChecklistTooltip)
                diagnosticRow("Pair warning", diagnostics?.warning ?? "None")
            }
            .padding(4)
        }
    }

    private var setupSummary: String {
        "No signal — check turntable, cable, input, mode, live tap"
    }

    private var setupChecklistTooltip: String {
        [
            "Turntable is on and needle is down",
            "Phono cable connected to audio interface",
            "Correct input device selected in Mac Analyzer",
            "Timecode mode set to Diagnostics or Prototype",
            "Live tap enabled (ENABLE_TIMECODE_LIVE_TAP flag)"
        ].joined(separator: "\n")
    }

    // MARK: - Details (collapsed by default — verbose per-channel/per-pair diagnostics)

#if ENABLE_TIMECODE_LIVE_TAP
    private var detailsSection: some View {
        GroupBox("Details") {
            DisclosureGroup("Per-channel / per-pair diagnostics", isExpanded: $isDetailsExpanded) {
                if let diagnostics {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            diagnosticRow("Sample rate", "\(diagnostics.sampleRate) Hz")
                            diagnosticRow("Source channels", "\(diagnostics.sourceChannelCount)")

                            Divider()
                            Text("Per channel")
                                .font(.caption.bold())
                            ForEach(diagnostics.perChannelDiagnostics, id: \.channelIndex) { channel in
                                Text(channelDiagnosticText(channel))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(channel.isNearSilent ? .secondary : .primary)
                                    .textSelection(.enabled)
                            }

                            Divider()
                            Text("Per pair")
                                .font(.caption.bold())
                            ForEach(diagnostics.perPairDiagnostics, id: \.startChannel) { pair in
                                Text(pairDiagnosticText(pair))
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxHeight: 220)
                } else {
                    Text("Waiting for a live audio buffer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .font(.caption.bold())
            .padding(4)
        }
    }

    private var diagnostics: TimecodeCMSampleBufferAdapter.DiagnosticsSnapshot? {
        TimecodeCMSampleBufferAdapter.latestDiagnostics
    }

    private var pairOptions: [Int] {
        guard let count = diagnostics?.sourceChannelCount, count > 1 else { return [] }
        return Array(stride(from: 0, to: count - 1, by: 2))
    }

    private var channelPairSelectionBinding:
        Binding<TimecodeCMSampleBufferAdapter.ChannelPairSelection> {
        Binding(
            get: { TimecodeCMSampleBufferAdapter.channelPairSelection },
            set: { TimecodeCMSampleBufferAdapter.channelPairSelection = $0 }
        )
    }

    private func channelDiagnosticText(
        _ channel: TimecodeCMSampleBufferAdapter.ChannelDiagnostic
    ) -> String {
        let raw = channel.maxAbsRaw.map(String.init) ?? "—"
        let state = (channel.isNearSilent ? "  SILENT" : "")
            + (channel.isClipping ? "  CLIPPING" : "")
        return "Ch \(channel.channelIndex + 1)  "
            + "RMS \(String(format: "%.5f", channel.rms))  "
            + "Peak \(String(format: "%.5f", channel.peak))  "
            + "Raw \(raw)  ~\(Int(channel.dominantFrequencyHz)) Hz\(state)"
    }

    private func pairDiagnosticText(
        _ pair: TimecodeCMSampleBufferAdapter.PairDiagnostic
    ) -> String {
        let state = pair.rejectionReason.map { "Rejected: \($0)" } ?? "Candidate"
        return "\(pair.label)  "
            + "RMS \(String(format: "%.5f", pair.rms))  "
            + "Peak \(String(format: "%.5f", pair.peak))  "
            + "Corr \(String(format: "%.3f", pair.correlation))  \(state)"
    }
#endif

    // MARK: - Live log (fixed position, always last)

    private var logSection: some View {
        GroupBox("Live Log") {
            VStack(alignment: .leading, spacing: 6) {
                Text(logger.logURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                diagnosticRow("Status", logger.lastWriteStatus)
                diagnosticRow(
                    "Last write",
                    logger.lastWriteTimestamp?.formatted(date: .omitted, time: .standard) ?? "—"
                )
                diagnosticRow("Lines written", "\(logger.totalLinesWritten)")
                diagnosticRow("Error", logger.lastWriteError ?? "None")
                HStack(spacing: 8) {
                    Button("Write test line") {
                        logger.append(makeLogEntry())
                    }
                    .controlSize(.small)
                    Button(copyConfirmed ? "Copied" : "Copy log path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logger.logURL.path, forType: .string)
                        copyConfirmed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copyConfirmed = false
                        }
                    }
                    .controlSize(.small)
                    Button("Clear live log") {
                        logger.clear()
                    }
                    .controlSize(.small)
                }
            }
            .padding(4)
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(
                    label == "Status" && value.hasSuffix("failed") ? Color.red : Color.primary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(minHeight: 16)
    }

    // MARK: - Log entry builder

    private func makeLogEntry() -> DVSLogEntry {
        let d = pipeline.latestDiagnosis
        let c = pipeline.counters
#if ENABLE_TIMECODE_LIVE_TAP
        let adapter = TimecodeCMSampleBufferAdapter.latestDiagnostics
        let sourceChannelCount = adapter?.sourceChannelCount ?? 0
        let selectedChannelPair = adapter?.selectedChannelPair ?? "—"
        let autoRecommendedChannelPair = adapter?.autoRecommendedChannelPair
        let perChannelRMS = adapter?.perChannelDiagnostics.map(\.rms) ?? []
        let perChannelPeak = adapter?.perChannelDiagnostics.map(\.peak) ?? []
        let perPairRMS = adapter?.perPairDiagnostics.map(\.rms) ?? []
        let perPairPeak = adapter?.perPairDiagnostics.map(\.peak) ?? []
        let adapterFormat = adapter.map {
            "\($0.formatSummary) @ \($0.sampleRate) Hz"
        } ?? "Unavailable"
        let adapterWarning = adapter?.warning
#else
        let sourceChannelCount = 0
        let selectedChannelPair = "Unavailable"
        let autoRecommendedChannelPair: String? = nil
        let perChannelRMS: [Float] = []
        let perChannelPeak: [Float] = []
        let perPairRMS: [Float] = []
        let perPairPeak: [Float] = []
        let adapterFormat = "Unavailable"
        let adapterWarning: String? = nil
#endif
        let totalDropped = c.droppedSilence + c.droppedClipped + c.droppedWeakSignal
            + c.droppedChannelFault + c.droppedLowConfidence
        return DVSLogEntry(
            timestamp: Date(),
            sampleRate: pipeline.diagnosticsTap.sampleRate,
            channelCount: pipeline.diagnosticsTap.channelCount,
            selectedChannelMode: pipeline.inputChannel.rawValue,
            leftRMS: d?.leftRMS ?? 0,
            rightRMS: d?.rightRMS,
            leftPeak: d?.leftPeak ?? 0,
            rightPeak: d?.rightPeak,
            signalHealth: pipeline.signalHealth.rawValue,
            hasSignal: hasSignal,
            direction: pipeline.currentDirection.rawValue,
            speed: abs(pipeline.currentRate),
            rawRate: pipeline.currentRate,
            smoothedRate: c.smoothedRate,
            confidence: c.averageConfidence,
            minConfidence: pipeline.minConfidence,
            maxRate: pipeline.maxRate,
            dropReason: pipeline.lastDropReason?.rawValue,
            dominantFrequencyHz: d?.zcrFrequencyEstimateLeft,
            zeroCrossingRateLeft: d?.zeroCrossingRateLeft,
            phaseDelta: pipeline.latestDecodeResult?.frames.last?.deltaPosition,
            acceptedCount: c.acceptedMotionSamples,
            droppedCount: totalDropped,
            silenceCount: c.droppedSilence,
            weakCount: c.droppedWeakSignal,
            lowConfidenceCount: c.droppedLowConfidence,
            clippedCount: c.droppedClipped,
            sourceChannelCount: sourceChannelCount,
            selectedChannelPair: selectedChannelPair,
            autoRecommendedChannelPair: autoRecommendedChannelPair,
            perChannelRMS: perChannelRMS,
            perChannelPeak: perChannelPeak,
            perPairRMS: perPairRMS,
            perPairPeak: perPairPeak,
            adapterFormat: adapterFormat,
            adapterWarning: adapterWarning,
            rawDecodeTrace: c.rawDecodeTrace,
            calibratedTrace: c.calibratedTrace,
            heldDropoutCount: c.heldDropoutCount,
            longDropoutCount: c.longDropoutCount
        )
    }

    // MARK: - Derived state

    private var hasSignal: Bool {
        switch pipeline.signalHealth {
        case .noSignal, .weak: return false
        default: return true
        }
    }

    private var rms: Float { pipeline.latestDiagnosis?.leftRMS ?? 0 }
    private var peak: Float { pipeline.latestDiagnosis?.leftPeak ?? 0 }
    private var frequencyHz: Float? { pipeline.latestDiagnosis?.zcrFrequencyEstimateLeft }
    private var relativeRate: Double { abs(pipeline.currentRate) }
    private var confidence: Double { pipeline.counters.averageConfidence }

    private var direction: DVSTimecodeStatus.Direction {
        switch pipeline.currentDirection {
        case .forward:  return .forward
        case .backward: return .backward
        case .unknown:  return abs(pipeline.currentRate) < 0.05 ? .stopped : .unknown
        }
    }
}

#if DEBUG
struct DVSControlVinylPanel_Previews: PreviewProvider {
    static var previews: some View {
        DVSControlVinylPanel(
            pipeline: TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        )
        .frame(width: 340)
        .previewDisplayName("DVS Panel — idle")
    }
}
#endif
#endif
