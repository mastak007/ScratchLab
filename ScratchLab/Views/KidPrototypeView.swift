// KidPrototypeView.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1, Slices 1 + 3).
//
// A hidden, feature-flagged iOS screen used only to validate the Kid Mode
// prototype assumptions (see analysis/kid_mode/
// KID_MODE_PROTOTYPE_VALIDATION_PLAN.md). It is reachable only when
// FeatureFlags.kidPrototypeEnabled is on, and re-checks the flag itself so the
// screen is inert if it is ever pushed with the flag off.
//
// Batch 1 scope only: finger -> position/velocity/direction (KidScrubInput)
// -> scrub audio (KidScrubAudioPlayer), plus a small read-out to confirm it
// responds. Deliberately NO ribbon renderer, NO trace buffer, NO target ghost,
// NO presentation modes, NO scoring, NO research logging — those are later
// batches.
//
// To remove the prototype: delete this file, the ScratchLab/Models/KidPrototype
// folder, and the FeatureFlags.kidPrototypeEnabled flag; remove the flag-gated
// entry in MainMenuView. Production is then byte-identical.

import SwiftUI

struct KidPrototypeView: View {

    var body: some View {
        Group {
            if FeatureFlags.kidPrototypeEnabled {
                KidPrototypeContentView()
            } else {
                KidPrototypeUnavailableView()
            }
        }
        .navigationTitle("Kid Mode Prototype")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Unavailable (flag off)

private struct KidPrototypeUnavailableView: View {
    var body: some View {
        ZStack {
            BackgroundView()
            Text("This internal prototype is not available.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(24)
        }
    }
}

// MARK: - Content (flag on)

private struct KidPrototypeContentView: View {

    @State private var input = KidScrubInput()
    @StateObject private var audio = KidScrubAudioHolder()

    /// Last drag translation consumed, so we can derive per-event deltas.
    @State private var lastTranslation: CGFloat = 0
    /// Timestamp of the last drag event, for deltaTime.
    @State private var lastEventTime: TimeInterval?
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    scrubPad
                    telemetry
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .onAppear { audio.player.start() }
        .onDisappear { audio.player.stop() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kid Mode Validation Prototype")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)

            Text("Internal validation prototype. Drag across the pad below to scrub the bundled sample. This proves finger → sound; it is not a finished feature and records nothing.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scrubPad: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isScrubbing ? 0.12 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(positionIndicator(width: width))
                .overlay(
                    Text("Drag here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                )
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
        }
        .frame(height: 220)
    }

    private func positionIndicator(width: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(directionColor)
                .frame(width: 4)
                .position(
                    x: CGFloat(input.position) * proxy.size.width,
                    y: proxy.size.height / 2
                )
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                let now = ProcessInfo.processInfo.systemUptime
                let translation = value.translation.width

                let pixelDelta = translation - lastTranslation
                lastTranslation = translation

                let deltaTime: TimeInterval
                if let last = lastEventTime {
                    deltaTime = now - last
                } else {
                    deltaTime = 0
                }
                lastEventTime = now

                // Map horizontal pixels to a normalized position delta.
                // The audio read head is delta-driven within a small anchor
                // window (not mapped 0…1 across the full sample).
                let normalizedDelta = Double(pixelDelta / width)
                input.update(delta: normalizedDelta, deltaTime: deltaTime)
                audio.player.moveReadHead(by: normalizedDelta)
            }
            .onEnded { _ in
                isScrubbing = false
                lastTranslation = 0
                lastEventTime = nil
                // Finger lifted: register a still frame so the read-out shows
                // idle. The audio read head holds and the de-click gain ramp
                // fades to silence — no explicit player call needed.
                input.update(delta: 0, deltaTime: 0)
            }
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 12) {
            telemetryRow(title: "Position", value: String(format: "%.3f", input.position))
            telemetryRow(title: "Velocity", value: String(format: "%+.2f /s", input.velocity))
            telemetryRow(title: "Direction", value: directionLabel)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func telemetryRow(title: String, value: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.46))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private var directionLabel: String {
        switch input.direction {
        case .forward: return "Forward"
        case .backward: return "Backward"
        case .idle: return "Idle"
        }
    }

    private var directionColor: Color {
        switch input.direction {
        case .forward: return Color(hex: "22C55E")
        case .backward: return Color(hex: "F59E0B")
        case .idle: return Color(hex: "64748B")
        }
    }
}

/// Owns the prototype audio player for the lifetime of the screen.
private final class KidScrubAudioHolder: ObservableObject {
    let player = KidScrubAudioPlayer()
}

#if DEBUG
struct KidPrototypeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            KidPrototypeView()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
