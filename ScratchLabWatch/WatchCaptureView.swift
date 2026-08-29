import SwiftUI

struct WatchCaptureView: View {
    @EnvironmentObject private var recorder: WatchMotionRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Watch Capture")
                    .font(.headline)
                    .foregroundStyle(ScratchLabCoreColor.textPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start/Stop Take.")
                    Text("Send motion to your paired device.")
                }
                .font(.footnote)
                .foregroundStyle(ScratchLabCoreColor.textSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Start or stop a take. Send motion to your paired device.")

                statusCard

                Button(action: toggleCapture) {
                    VStack(spacing: 6) {
                        Image(systemName: recorder.isPhoneCaptureCommandPending
                            ? "hourglass"
                            : (recorder.isRecording ? "stop.fill" : "record.circle.fill"))
                            .font(.system(size: 30, weight: .bold))

                        Text(captureButtonTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(ScratchLabCoreColor.textPrimary)
                    .background(recorder.isRecording ? ScratchLabCoreColor.danger : ScratchLabCoreColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(recorder.isPhoneCaptureCommandPending || !canSendCaptureCommand)
                .accessibilityLabel(captureButtonAccessibilityLabel)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow(label: "Elapsed", value: recorder.elapsedDescription, tone: .neutral)
                    infoRow(label: "Motion", value: "\(recorder.sampleCount)", tone: .neutral)
                    infoRow(
                        label: "Connection",
                        value: recorder.isPhonePaired ? "Device Paired" : "Not Connected",
                        tone: recorder.isPhonePaired ? .info : .muted
                    )
                    infoRow(
                        label: "Transfer",
                        value: recorder.isPhoneReachable ? "Connected" : "Searching",
                        tone: recorder.isPhoneReachable ? .info : .muted
                    )
                }
                .font(.caption2)

                Text(watchInstruction)
                    .font(.caption2)
                    .foregroundStyle(ScratchLabCoreColor.textTertiary)
                    .padding(.top, 2)
                    .accessibilityLabel(watchInstruction)
            }
            .padding(14)
        }
        .background(
            LinearGradient(
                colors: [ScratchLabCoreColor.canvas, ScratchLabCoreColor.raised, ScratchLabCoreColor.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recorder.isRecording ? "Recording" : "Ready")
                .font(.caption.weight(.semibold))
                .foregroundStyle(recorder.isRecording ? ScratchLabCoreColor.danger : ScratchLabCoreColor.success)
                .accessibilityLabel(recorder.isRecording ? "Status: Recording" : "Status: Ready")

            Text(recorder.transferStatus)
                .font(.caption2)
                .foregroundStyle(WatchTransferStatusTone.tone(for: recorder.transferStatus).color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScratchLabCoreColor.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private enum InfoRowTone {
        case neutral
        case info
        case muted

        var color: Color {
            switch self {
            case .neutral: return ScratchLabCoreColor.textSecondary
            case .info:    return ScratchLabCoreColor.info
            case .muted:   return ScratchLabCoreColor.textTertiary
            }
        }
    }

    private func infoRow(label: String, value: String, tone: InfoRowTone) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(ScratchLabCoreColor.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(tone.color)
                .multilineTextAlignment(.trailing)
        }
    }

    private func toggleCapture() {
        recorder.requestPairedPhoneCapture(recorder.isRecording ? .stop : .start)
    }

    private var captureButtonTitle: String {
        guard recorder.isPhoneCaptureCommandPending else {
            if !canSendCaptureCommand {
                return "Open iPhone Capture"
            }
            return recorder.isRecording ? "Stop Take" : "Start Take"
        }
        return recorder.isRecording ? "Stopping…" : "Starting…"
    }

    /// Pairing alone is not enough for an immediate camera command. Starting
    /// is offered only while the foreground iPhone Capture screen is reachable;
    /// stopping remains available so an already-running local Watch take can
    /// still be ended safely if the live connection drops.
    private var canSendCaptureCommand: Bool {
        recorder.isRecording || recorder.isPhoneReachable
    }

    private var captureButtonAccessibilityLabel: String {
        if recorder.isRecording {
            return "Stop Take, recording in progress"
        }
        if !recorder.isPhoneReachable {
            return "Open Capture on iPhone and wait for Transfer Connected"
        }
        return "Start Take"
    }

    private var watchInstruction: String {
        recorder.isPhoneReachable
            ? "Keep the watch app open during recording."
            : "Open Capture on iPhone. Start Take becomes available when Transfer says Connected."
    }
}

/// Purely a display classification of `WatchMotionRecorder.transferStatus`'s
/// existing, unchanged strings — never adds a state or claims connectivity
/// the model doesn't already report. An unrecognized string (e.g. a future
/// wording change) safely falls back to `.neutral` rather than guessing.
private enum WatchTransferStatusTone {
    case success
    case warning
    case danger
    case info
    case neutral

    var color: Color {
        switch self {
        case .success: return ScratchLabCoreColor.success
        case .warning: return ScratchLabCoreColor.warning
        case .danger:  return ScratchLabCoreColor.danger
        case .info:    return ScratchLabCoreColor.info
        case .neutral: return ScratchLabCoreColor.textSecondary
        }
    }

    static func tone(for status: String) -> WatchTransferStatusTone {
        switch status {
        case "Ready":
            return .success
        case "Recording":
            return .danger
        case "Sent to your paired device.":
            return .success
        case "Queued the motion session for device import.":
            return .info
        case "Motion capture is unavailable on this watch.",
             "Unable to save the motion session.":
            return .danger
        case "No motion captured.",
             "Motion capture stopped. Try again.",
             "Pair your watch with your device to send sessions.",
             "Install ScratchLab on your paired device to receive watch captures.",
             "Saved on device. Open ScratchLab on your paired device later to import it.",
             "Saved on device. Install ScratchLab on your paired device to import it.",
             "Retrying send to your paired device…",
             "Watch connection needs attention.",
             "Couldn't send to your paired device. Will retry automatically.":
            return .warning
        default:
            return .neutral
        }
    }
}
