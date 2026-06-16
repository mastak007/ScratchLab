#if DEBUG

import SwiftUI

// MARK: - TimecodeInputStatusCard

/// DEBUG-only card showing live timecode input diagnostics.
///
/// Displays source state, L/R level bars, signal health badge, and
/// per-buffer warnings (silence, clipping, channel imbalance, mono suspect).
///
/// When a validation snapshot or fixture report is provided, a "Copy Report"
/// button appears at the bottom so the developer can copy the evidence-only
/// diagnostic summary to clipboard. The report is explicitly labelled
/// "prototype only" with no commercial compatibility claim.
///
/// **Batch 1:** Diagnostics only. No decoder, no commercial compatibility.
/// **Batch 9:** Copyable validation report support.
/// This card lives behind `#if DEBUG` and is not compiled in release builds.
struct TimecodeInputStatusCard: View {

    /// The tap to observe. Nil means "no tap configured."
    @ObservedObject var tap: TimecodeInputTap

    /// The diagnostics engine to use.
    let diagnostics: TimecodeSignalDiagnostics

    /// Optional live-session validation snapshot from the pipeline.
    /// When non-nil, included in the copyable report.
    var validationSnapshot: TimecodeValidationSnapshot? = nil

    /// Optional fixture validation report from the fixture loader.
    /// When non-nil, included in the copyable report.
    var fixtureReport: TimecodeFixtureValidationReport? = nil

    @State private var latestDiagnosis: TimecodeSignalDiagnostics.Diagnosis?
    @State private var timer: Timer?
    @State private var copyConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            sourceRow
            levelRow
            healthRow
            warningsRow
            reportSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScratchLabDesign.Card.compactPadding)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
        )
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Timecode Input")
                .font(.headline)

            Spacer(minLength: 8)

            statusBadge
        }
    }

    private var statusBadge: some View {
        let isActive = tap.latestBuffer.samples.count > 0
        return Label(
            isActive ? "Receiving" : "Idle",
            systemImage: isActive ? "waveform.circle.fill" : "circle.dashed"
        )
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(isActive ? Color(nsColor: .systemGreen) : .secondary)
    }

    // MARK: - Source

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Text("Source")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(sourceLabel)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)

            if let format = formatLabel {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(format)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceLabel: String {
        "\(Int(tap.sampleRate)) Hz · \(tap.channelCount)ch"
    }

    private var formatLabel: String? {
        guard tap.totalFrameCount > 0 else { return nil }
        let duration = Double(tap.totalFrameCount) / tap.sampleRate
        return String(format: "%.1fs", duration)
    }

    // MARK: - Levels

    private var levelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            levelBar(label: "L", rms: latestSample?.leftRMS ?? 0, peak: latestSample?.leftPeak ?? 0)
            if tap.channelCount >= 2 {
                levelBar(label: "R", rms: latestSample?.rightRMS ?? 0, peak: latestSample?.rightPeak ?? 0)
            }
        }
    }

    private var latestSample: TimecodeInputSample? {
        tap.latestSample
    }

    private func levelBar(label: String, rms: Float, peak: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 8)

                    // RMS bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(levelColor(rms))
                        .frame(width: geo.size.width * CGFloat(rms), height: 8)

                    // Peak indicator line
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * CGFloat(peak) - 1, y: -2)
                }
            }
            .frame(height: 12)

            Text(String(format: "%.0f%%", rms * 100))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func levelColor(_ rms: Float) -> Color {
        switch rms {
        case ..<0.001: return Color(nsColor: .systemGray)
        case ..<0.02:  return Color(nsColor: .systemYellow)
        case ..<0.999: return Color(nsColor: .systemGreen)
        default:       return Color(nsColor: .systemRed)
        }
    }

    // MARK: - Health

    private var healthRow: some View {
        HStack(spacing: 8) {
            Text("Health")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            healthBadge
        }
    }

    private var healthBadge: some View {
        let health = latestDiagnosis?.health ?? .noSignal
        return Text(health.rawValue)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(healthColor(health))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(healthColor(health).opacity(0.12), in: Capsule(style: .continuous))
    }

    private func healthColor(_ health: SignalHealth) -> Color {
        switch health {
        case .noSignal:    return Color(nsColor: .systemGray)
        case .weak:        return Color(nsColor: .systemYellow)
        case .usable:      return Color(nsColor: .systemGreen)
        case .clipped:     return Color(nsColor: .systemOrange)
        case .channelFault: return Color(nsColor: .systemRed)
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warningsRow: some View {
        if let diag = latestDiagnosis {
            VStack(alignment: .leading, spacing: 4) {
                if diag.isSilent {
                    warningLine("No signal detected")
                }
                if diag.isClipping {
                    warningLine("Clipping detected")
                }
                if diag.isChannelImbalanced {
                    warningLine("Channel imbalance")
                }
                if diag.isMonoSuspect {
                    warningLine("Mono suspect — one channel silent")
                }
                if !diag.isSilent && !diag.isClipping && !diag.isChannelImbalanced && !diag.isMonoSuspect {
                    warningLine("No warnings")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Diagnostics pending…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func warningLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .systemYellow))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Report (Batch 9)

    /// True when at least one report source is available.
    private var hasReport: Bool {
        validationSnapshot != nil || fixtureReport != nil
    }

    @ViewBuilder
    private var reportSection: some View {
        if hasReport {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Validation Report")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button(action: copyReport) {
                        Label(
                            copyConfirmation ? "Copied" : "Copy Report",
                            systemImage: copyConfirmation ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copyConfirmation ? Color(nsColor: .systemGreen) : .secondary)
                }

                // Compact summary line
                if let snap = validationSnapshot {
                    Text("[Live] \(snap.validationStatus.label) — \(snap.acceptedMotionSamples) accepted, "
                         + "conf \(String(format: "%.3f", snap.decoderConfidence))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let report = fixtureReport {
                    Text(report.compactSummary)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("Prototype only — not a compatibility claim")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func copyReport() {
        var lines: [String] = []

        if let snap = validationSnapshot {
            lines.append(snap.debugText)
        }

        if let report = fixtureReport {
            if !lines.isEmpty { lines.append("") }
            lines.append(report.debugText)
        }

        guard !lines.isEmpty else { return }

        let combined = lines.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)

        copyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copyConfirmation = false
        }
    }

    // MARK: - Refresh

    private func refresh() {
        let buffer = tap.latestBuffer
        if !buffer.samples.isEmpty {
            latestDiagnosis = diagnostics.diagnose(buffer)
        }
    }
}

// MARK: - Standalone debug host (for preview / standalone use)

/// A self-contained DEBUG host that creates its own tap and provides a
/// test-feed button so a developer can verify the card renders without
/// wiring to a live audio source.
struct TimecodeInputStatusCard_Host: View {
    @StateObject private var tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
    private let diagnostics = TimecodeSignalDiagnostics()

    var body: some View {
        VStack(spacing: 18) {
            TimecodeInputStatusCard(tap: tap, diagnostics: diagnostics)

            HStack(spacing: 8) {
                Button("Feed silence") {
                    let silence = [Float](repeating: 0, count: 1024)
                    tap.push(samplesLeft: silence, samplesRight: silence, hostTime: mach_absolute_time())
                    _ = tap.drain()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Feed healthy") {
                    let healthy = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 0.3)
                    tap.push(samplesLeft: healthy, samplesRight: healthy, hostTime: mach_absolute_time())
                    _ = tap.drain()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Feed clipped") {
                    let clipped = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 1.0)
                    tap.push(samplesLeft: clipped, samplesRight: clipped, hostTime: mach_absolute_time())
                    _ = tap.drain()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Feed channel fault") {
                    let tone = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 0.3)
                    let silence = [Float](repeating: 0, count: 1024)
                    tap.push(samplesLeft: tone, samplesRight: silence, hostTime: mach_absolute_time())
                    _ = tap.drain()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Drain & Reset") {
                _ = tap.drainAndDiagnose(with: diagnostics)
                tap.reset()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
    }

    private func sineTone(frequency: Float, sampleRate: Double, frameCount: Int, amplitude: Float) -> [Float] {
        (0..<frameCount).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t)
        }
    }
}

// MARK: - Preview

#Preview {
    TimecodeInputStatusCard_Host()
        .frame(width: 420)
}

#endif // DEBUG
