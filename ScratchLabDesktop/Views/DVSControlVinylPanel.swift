#if DEBUG
import SwiftUI

/// Mac Analyzer panel: DVS control-vinyl signal diagnostics.
///
/// Read-only view — surfaces diagnostics from a `TimecodeControlPipeline`
/// already owned by the parent screen. No scoring, playback, or notation
/// wiring. Isolated from MIDI, sample routing, and camera subsystems.
struct DVSControlVinylPanel: View {

    @ObservedObject var pipeline: TimecodeControlPipeline

    @State private var tick = false
    @State private var copyConfirmed = false

    private let logger = DVSLiveLogger()
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            signalSection
            motionSection
            if let reason = pipeline.lastDropReason {
                dropsSection(reason: reason)
            }
            if !hasSignal {
                setupGuidanceSection
            }
            logSection
        }
        .padding()
        .onReceive(timer) { _ in
            tick.toggle()
            logger.append(makeLogEntry())
        }
    }

    // MARK: - Signal

    private var signalSection: some View {
        GroupBox("Signal") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(hasSignal ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(hasSignal ? "Signal present" : "No signal")
                        .font(.system(.body, design: .monospaced))
                }

                if hasSignal {
                    HStack(spacing: 4) {
                        Text("RMS")
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: geo.size.width * CGFloat(min(rms * 4, 1)))
                                }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.4f", rms))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 55, alignment: .trailing)
                    }

                    HStack(spacing: 4) {
                        Text("Peak")
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.orange.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(peak > 0.95 ? Color.red : Color.orange)
                                        .frame(width: geo.size.width * CGFloat(min(peak, 1)))
                                }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.4f", peak))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 55, alignment: .trailing)
                    }

                    if let freq = frequencyHz {
                        HStack {
                            Text("~\(Int(freq)) Hz").font(.system(.caption, design: .monospaced))
                            Text("carrier estimate").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Motion

    private var motionSection: some View {
        GroupBox("Motion") {
            HStack(spacing: 16) {
                directionBadge
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f×", relativeRate))
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Conf.")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", confidence * 100))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(confidence > 0.6 ? Color.primary : Color.orange)
                    }
                }
                Spacer()
            }
            .padding(4)
        }
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Drops

    private func dropsSection(reason: TimecodeDropoutReason) -> some View {
        GroupBox("Last Drop") {
            Text(reason.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(4)
        }
    }

    // MARK: - Setup guidance

    private var setupGuidanceSection: some View {
        GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 4) {
                Text("No DVS signal detected. Check:")
                    .font(.caption.bold())
                    .padding(.bottom, 2)
                setupItem("Turntable is on and needle is down")
                setupItem("Phono cable connected to audio interface")
                setupItem("Correct input device selected in Mac Analyzer")
                setupItem("Timecode mode set to Diagnostics or Prototype")
                setupItem("Live tap enabled (ENABLE_TIMECODE_LIVE_TAP flag)")
            }
            .padding(4)
        }
    }

    private func setupItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Live log

    private var logSection: some View {
        GroupBox("Live Log") {
            VStack(alignment: .leading, spacing: 6) {
                Text(DVSLiveLogger.logURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button(copyConfirmed ? "Copied" : "Copy log path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DVSLiveLogger.logURL.path, forType: .string)
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

    // MARK: - Log entry builder

    private func makeLogEntry() -> DVSLogEntry {
        let d = pipeline.latestDiagnosis
        let c = pipeline.counters
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
            clippedCount: c.droppedClipped
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
