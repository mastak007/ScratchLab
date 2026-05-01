import SwiftUI

struct WatchCaptureView: View {
    @EnvironmentObject private var recorder: WatchMotionRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Watch Capture")
                    .font(.headline)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start/Stop Take.")
                    Text("Send motion to your paired device.")
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Start or stop a take. Send motion to your paired device.")

                statusCard

                Button(action: toggleCapture) {
                    VStack(spacing: 6) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 30, weight: .bold))

                        Text(recorder.isRecording ? "Stop Take" : "Start Take")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(recorder.isRecording ? Color.red : Color.cyan.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow(label: "Elapsed", value: recorder.elapsedDescription)
                    infoRow(label: "Motion", value: "\(recorder.sampleCount)")
                    infoRow(label: "Connection", value: recorder.isPhonePaired ? "Device Paired" : "Not Connected")
                    infoRow(label: "Transfer", value: recorder.isPhoneReachable ? "Connected" : "Searching")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))

                Text("Keep the watch app open during recording.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityLabel("Keep the watch app open during recording.")
            }
            .padding(14)
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color.blue.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recorder.isRecording ? "Recording" : "Ready")
                .font(.caption.weight(.semibold))
                .foregroundStyle(recorder.isRecording ? .red : .cyan)

            Text(recorder.transferStatus)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func toggleCapture() {
        if recorder.isRecording {
            recorder.stopCapture()
        } else {
            recorder.startCapture()
        }
    }
}
