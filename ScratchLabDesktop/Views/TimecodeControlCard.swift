#if DEBUG

import SwiftUI

// MARK: - TimecodeControlCard

/// DEBUG-only card wrapping the Batch 1 `TimecodeInputStatusCard` and adding
/// Batch 3 mode, calibration, and pipeline status controls.
///
/// ## Sections
///
/// 1. **Diagnostics** — the existing `TimecodeInputStatusCard` (L/R levels,
///    health badge, warnings).
/// 2. **Mode & Calibration** — mode picker, channel picker, invert toggle,
///    rate-scale slider, min-confidence slider, reset button.
/// 3. **Pipeline Status** — decoded direction, rate, confidence, accepted /
///    dropped counters, last drop reason, source label.
///
/// **Batch 3:** Control pipeline only. No live AVCapture wiring.
struct TimecodeControlCard: View {

    @ObservedObject var pipeline: TimecodeControlPipeline

    /// Persisted mode so the picker survives view disappearance.
    @AppStorage("scratchlab.mac.timecodeMode") private var persistedModeRaw: String = TimecodeControlMode.disabled.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSection
            Divider().opacity(0.3)
#if ENABLE_TIMECODE_LIVE_TAP
            liveTapSection
            Divider().opacity(0.3)
#endif
            diagnosticsSection
            Divider().opacity(0.3)
            calibrationSection
            Divider().opacity(0.3)
            pipelineStatusSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScratchLabDesign.Card.compactPadding)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
        )
        .onAppear {
            // Restore persisted mode
            if let restored = TimecodeControlMode(rawValue: persistedModeRaw) {
                pipeline.mode = restored
            }
        }
        .onChange(of: pipeline.mode) { newMode in
            persistedModeRaw = newMode.rawValue
        }
    }

    // MARK: - Mode section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timecode Control")
                .font(.headline)

            Picker("Mode", selection: $pipeline.mode) {
                ForEach(TimecodeControlMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Diagnostics section

    private var diagnosticsSection: some View {
        TimecodeInputStatusCard(
            tap: pipeline.diagnosticsTap,
            diagnostics: TimecodeSignalDiagnostics()
        )
    }

    // MARK: - Calibration section

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibration")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // Channel picker
            HStack(spacing: 8) {
                Text("Channel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $pipeline.inputChannel) {
                    ForEach(TimecodeInputChannel.allCases, id: \.self) { ch in
                        Text(ch.label).tag(ch)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Invert direction
            Toggle(isOn: $pipeline.invertDirection) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                    Text("Invert direction")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Rate scale
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rate scale")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", pipeline.rateScale))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $pipeline.rateScale, in: 0.1...5.0, step: 0.1)
                    .controlSize(.small)
            }

            // Min confidence
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min confidence")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", pipeline.minConfidence))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $pipeline.minConfidence, in: 0.0...1.0, step: 0.05)
                    .controlSize(.small)
            }

            // Max rate
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max rate")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f u/s", pipeline.maxRate))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $pipeline.maxRate, in: 0.5...50.0, step: 0.5)
                    .controlSize(.small)
            }

            // Signal threshold
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Signal threshold")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.4f", pipeline.signalThresholdRMS))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $pipeline.signalThresholdRMS, in: 0.0001...0.1)
                    .controlSize(.small)
            }

            // Reset button
            HStack {
                Spacer()
                Button("Reset Calibration") {
                    pipeline.reset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
            }
        }
    }

    // MARK: - Pipeline status section

    private var pipelineStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            statusRow(label: "Mode", value: pipeline.mode.label)
            statusRow(label: "Source", value: pipeline.counters.sourceLabel, mono: true)
            statusRow(label: "Direction", value: pipeline.currentDirection.rawValue, mono: true,
                      color: directionColor)
            statusRow(label: "Rate", value: String(format: "%.2f u/s", pipeline.currentRate), mono: true)
            statusRow(label: "Confidence", value: String(format: "%.3f", pipeline.counters.averageConfidence), mono: true)

            Divider().opacity(0.2)

            // Counters grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                counterChip(label: "Accepted", count: pipeline.counters.acceptedMotionSamples, color: .green)
                counterChip(label: "Dropped", count: totalDropped, color: .orange)
                counterChip(label: "Silence", count: pipeline.counters.droppedSilence, color: .secondary)
                counterChip(label: "Clip", count: pipeline.counters.droppedClipped, color: .secondary)
                counterChip(label: "Ch Fault", count: pipeline.counters.droppedChannelFault, color: .secondary)
                counterChip(label: "Weak", count: pipeline.counters.droppedWeakSignal, color: .secondary)
                counterChip(label: "Low Conf", count: pipeline.counters.droppedLowConfidence, color: .secondary)
                counterChip(label: "Dir Changes", count: pipeline.counters.directionChanges, color: .secondary)
            }

            // Last drop reason
            if !pipeline.counters.lastDropReason.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    Text("Drop: \(pipeline.counters.lastDropReason)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            // Timeline info
            if let timeline = pipeline.latestPlatterTimeline {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Timeline: \(timeline.samples.count) samples, \(String(format: "%.2f", timeline.endTime - timeline.startTime))s")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var totalDropped: Int {
        pipeline.counters.droppedSilence
        + pipeline.counters.droppedClipped
        + pipeline.counters.droppedChannelFault
        + pipeline.counters.droppedWeakSignal
        + pipeline.counters.droppedLowConfidence
    }

    private var directionColor: Color {
        switch pipeline.currentDirection {
        case .forward:  return Color(nsColor: .systemGreen)
        case .backward: return Color(nsColor: .systemRed)
        case .unknown:  return Color(nsColor: .systemGray)
        }
    }

    // MARK: - Helpers

    private func statusRow(label: String, value: String, mono: Bool = false, color: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
        }
    }

    private func counterChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(count > 0 ? color : .secondary)
        }
    }

    // MARK: - Live tap section

#if ENABLE_TIMECODE_LIVE_TAP
    private var liveTapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Tap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Status")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                liveTapStatusBadge()
            }

            Toggle(isOn: $pipeline.liveTapEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                    Text("Enable live timecode tap")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(pipeline.mode == .disabled)

            // Last buffer age
            if pipeline.liveTapEnabled, let lastBuffer = pipeline.lastBufferReceivedAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Last buffer: \(RelativeDateTimeFormatter().localizedString(for: lastBuffer, relativeTo: Date()))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Prototype disclaimer
            Text("Prototype — live audio tap for timecode decoding")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }

    private func liveTapStatusBadge() -> some View {
        let status = liveTapStatus
        return HStack(spacing: 4) {
            Circle()
                .fill(Color(status.color))
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(status.color))
        }
    }

    private var liveTapStatus: (label: String, color: Color) {
        guard pipeline.liveTapEnabled else {
            return ("Disabled", Color(nsColor: .secondaryLabelColor))
        }
        guard pipeline.mode != .disabled else {
            return ("Mode off", Color(nsColor: .secondaryLabelColor))
        }
        if let lastBuffer = pipeline.lastBufferReceivedAt {
            let age = Date().timeIntervalSince(lastBuffer)
            if age < 0.5 {
                return ("Receiving", .green)
            } else if age < 2.0 {
                return ("Stale", .orange)
            }
        }
        return ("Waiting", .yellow)
    }
#endif
}

// MARK: - Standalone debug host

/// Self-contained DEBUG host for previewing and manually testing the
/// timecode control card with synthetic feed buttons.
struct TimecodeControlCard_Host: View {
    @StateObject private var pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)

    /// Accumulate raw buffers here for manual flush; the pipeline also
    /// accumulates internally, but these are the raw [Float] arrays we
    /// need for flushDecode().
    @State private var feedCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                TimecodeControlCard(pipeline: pipeline)

                // Test-feed buttons
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test Feed (accumulates until flush)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        feedButton("Silence", color: .gray) {
                            feedSilence()
                        }
                        feedButton("Healthy", color: .green) {
                            feedHealthy()
                        }
                        feedButton("Forward", color: .blue) {
                            feedForwardProgression(count: 5)
                        }
                        feedButton("Backward", color: .red) {
                            feedBackwardProgression(count: 5)
                        }
                    }

                    HStack(spacing: 8) {
                        feedButton("Clipped", color: .orange) {
                            feedClipped()
                        }
                        feedButton("Ch Fault", color: .yellow) {
                            feedChannelFault()
                        }
                        feedButton("Weak", color: .secondary) {
                            feedWeak()
                        }

                        Button("Flush + Reset") {
                            pipeline.flushDecode()
                            pipeline.reset()
                            feedCount = 0
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.accentColor)
                    }
                }

                Text("Buffers fed: \(feedCount)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 600)
    }

    // MARK: - Feed helpers

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441
    private let timePerBuffer: TimeInterval = 441.0 / 44100.0

    private func sineTone(frequency: Float, amplitude: Float, phaseOffset: Float = 0) -> [Float] {
        (0..<framesPerBuffer).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t + phaseOffset)
        }
    }

    private func feedSilence() {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedHealthy() {
        let tone = sineTone(frequency: carrierFrequency, amplitude: 0.3)
        pipeline.pushStereoBuffer(left: tone, right: tone, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedForwardProgression(count: Int) {
        for i in 0..<count {
            let left = sineTone(frequency: carrierFrequency, amplitude: 0.5, phaseOffset: 0)
            let right = sineTone(frequency: carrierFrequency, amplitude: 0.5,
                                 phaseOffset: 0.3 * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
            feedCount += 1
        }
        pipeline.flushDecode()
    }

    private func feedBackwardProgression(count: Int) {
        for i in 0..<count {
            let left = sineTone(frequency: carrierFrequency, amplitude: 0.5, phaseOffset: 0)
            let right = sineTone(frequency: carrierFrequency, amplitude: 0.5,
                                 phaseOffset: -0.3 * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
            feedCount += 1
        }
        pipeline.flushDecode()
    }

    private func feedClipped() {
        let clip = sineTone(frequency: carrierFrequency, amplitude: 1.0)
        pipeline.pushStereoBuffer(left: clip, right: clip, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedChannelFault() {
        let tone = sineTone(frequency: carrierFrequency, amplitude: 0.3)
        let silence = [Float](repeating: 0, count: framesPerBuffer)
        pipeline.pushStereoBuffer(left: tone, right: silence, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedWeak() {
        let weak = sineTone(frequency: carrierFrequency, amplitude: 0.005)
        pipeline.pushStereoBuffer(left: weak, right: weak, sampleRate: sampleRate)
        feedCount += 1
    }

    // MARK: - Button helper

    private func feedButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(color)
    }
}

// MARK: - Preview

#Preview {
    TimecodeControlCard_Host()
        .frame(width: 440, height: 800)
}

#endif // DEBUG
