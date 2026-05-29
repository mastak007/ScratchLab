#if os(macOS)
import SwiftUI

// Phase 1 controller-input: Controller Inspector window (macOS, developer tool).
//
// Scope guardrails (deliberate):
// - Display-only. Shows live raw MIDI events and a detected-control summary so we
//   can answer: can ScratchLab receive usable platter / crossfader data directly
//   from the hardware over class-compliant Core MIDI, without Serato?
// - No notation, coaching, replay, scoring, export, ML, or device writes. It does
//   not change any existing product behaviour; it is reachable only from a
//   developer menu item / its own window.

struct ControllerInspectorView: View {
    @StateObject private var model = ControllerInspectorModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                rawEventLog
                    .frame(minWidth: 560)
                detectedControlsPanel
                    .frame(minWidth: 280)
            }
        }
        .frame(minWidth: 900, minHeight: 540)
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
            .frame(maxWidth: 280)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.eventCount) events")
                    .font(.system(.body, design: .monospaced))
                Text(String(format: "%.0f Hz", model.eventRateHz))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(model.isPaused ? "Resume" : "Pause") {
                model.togglePause()
            }

            Button("Clear") {
                model.clearLog()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var activityIndicator: some View {
        // Pulses green for ~0.25s after each shown event; refreshed by a timeline.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let active: Bool = {
                guard let last = model.lastEventDate else { return false }
                return context.date.timeIntervalSince(last) < 0.25
            }()
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
                Text(model.isRunning ? (model.isPaused ? "Paused" : "Listening") : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Raw event log

    private var rawEventLog: some View {
        Table(model.events) {
            TableColumn("Time") { event in
                Text(String(format: "%.3f", event.timestamp))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 78, ideal: 86)

            TableColumn("Source") { event in
                Text(event.sourceName).lineLimit(1)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Status") { event in
                Text(String(format: "0x%02X", event.parsed.statusByte))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 56, ideal: 60)

            TableColumn("Ch") { event in
                Text(event.parsed.channel.map { String($0 + 1) } ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 34, ideal: 38)

            TableColumn("Type") { event in
                Text(event.parsed.messageType.displayName).lineLimit(1)
            }
            .width(min: 110, ideal: 130)

            TableColumn("CC/Note") { event in
                Text(event.parsed.controlOrNoteNumber.map(String.init) ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 56, ideal: 64)

            TableColumn("Value") { event in
                Text(event.parsed.value.map(String.init) ?? "—")
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 50, ideal: 58)

            TableColumn("Raw bytes") { event in
                Text(event.hexBytes)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 160)
        }
    }

    // MARK: - Detected controls

    private var detectedControlsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Detected Controls")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if model.detectedControls.isEmpty {
                VStack {
                    Spacer()
                    Text("Move the crossfader, spin the platter,\ntouch it, press buttons…")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(model.detectedControls, id: \.id) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(stat.id.displayLabel)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("×\(stat.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text("last: \(stat.lastValue.map(String.init) ?? "—")")
                            Text(String(format: "%.0f Hz", stat.eventRate))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

#Preview {
    ControllerInspectorView()
}
#endif
