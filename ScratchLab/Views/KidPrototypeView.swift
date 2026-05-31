// KidPrototypeView.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1).
//
// Reachable only when FeatureFlags.kidPrototypeEnabled is on.
//
// Batch 1.5 — Touch-only manual scrub:
// A ribbon scrolls visually past 12 / AHH START so the user can anticipate
// the grab. Audio only plays while the user is touching; release fades to
// silence. No autoplay audio. No BPM grid. No scoring.
//
// Delete this file + KidPrototype folder + flag to remove the prototype.

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

// MARK: - Content

private struct KidPrototypeContentView: View {

    @Environment(\.scenePhase) private var scenePhase
    @State private var input = KidScrubInput()
    @StateObject private var audio = KidScrubAudioHolder()

    // How-to-play card.
    @State private var hasStarted = false
    @State private var showingHelp = false

    // Ribbon auto-scroll (visual only — no audio coupling).
    @State private var ribbonPhase: Double = 0.0
    private let twelveFraction: Double = 0.50       // 12 line at middle
    private let audioStopPhase: Double = 0.98       // silence just before wrap
    private let cycleDuration: Double = 1.8          // bottom→top visual period
    private let timer = Timer.publish(every: 1.0/60.0, on: .main, in: .common).autoconnect()

    // Drag state.
    @State private var isGrabbing = false
    @State private var isScrubbing = false
    @State private var accumLastTranslation: CGFloat = 0
    @State private var accumLastEventTime: TimeInterval?
    @State private var lastDragEventTime: TimeInterval = 0
    private let grabTimeout: TimeInterval = 1.0      // only catch truly stuck/cancelled gestures

    var body: some View {
        ZStack {
            BackgroundView()

            VStack(spacing: 0) {
                intro
                    .padding(.horizontal, 20).padding(.top, 8)
                ribbonLane
                    .padding(.horizontal, 20).padding(.vertical, 8)
                telemetry
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            .allowsHitTesting(hasStarted && !showingHelp)

            if !hasStarted || showingHelp { howToPlayCard }
        }
        .onAppear { audio.player.start() }
        .onDisappear {
            endTouchInteraction(reason: "disappear")
            audio.player.stop()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive || phase == .background {
                endTouchInteraction(reason: "scene-\(phase)")
            }
        }
        .onReceive(timer) { _ in
            guard hasStarted, !showingHelp else { return }

            // Timeout fail-safe: reset if touch state lingers with no movement.
            if isGrabbing {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastDragEventTime > grabTimeout {
                    endTouchInteraction(reason: "timeout")
                }
                return
            }

            ribbonPhase += (1.0 / 60.0) / cycleDuration
            if ribbonPhase >= 1.0 { ribbonPhase = 0.0 }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kid Mode Prototype")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Touch to grab · Swipe up = forward · Swipe down = reverse")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            Button { showingHelp = true } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Ribbon Lane

    private var ribbonLane: some View {
        GeometryReader { proxy in
            let h = max(proxy.size.height, 1)
            let w = max(proxy.size.width, 1)
            let twelveY = h * twelveFraction
            let ribbonY = h * (1.0 - ribbonPhase)
            let ribbonH: CGFloat = 36

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isGrabbing ? 0.10 : 0.04))

                // 12 / AHH START grab line.
                Rectangle().fill(Color.white.opacity(0.30))
                    .frame(height: 2)
                    .position(x: w / 2, y: twelveY)
                Text("12 / AHH START")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.60))
                    .position(x: w / 2 + 62, y: twelveY - 11)

                // Labels.
                Text("↑ forward")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.18))
                    .position(x: w / 2, y: 14)
                Text("↓ reverse")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.18))
                    .position(x: w / 2, y: h - 14)

                // Ribbon: amber when grabbed or above 12, dim when below.
                Capsule()
                    .fill(ribbonPhase >= twelveFraction || isGrabbing
                        ? Color(hex: "F59E0B").opacity(isGrabbing ? 1.0 : 0.75)
                        : Color(hex: "F59E0B").opacity(0.3))
                    .frame(width: w - 6, height: ribbonH)
                    .position(x: w / 2, y: ribbonY)

                if isGrabbing {
                    Circle().fill(Color.white)
                        .frame(width: 8, height: 8)
                        .position(x: 22, y: ribbonY)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(isGrabbing ? 0.18 : 0.08), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture(height: h))
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drag

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let now = ProcessInfo.processInfo.systemUptime
                lastDragEventTime = now
                let translation = value.translation.height
                let px = translation - accumLastTranslation
                accumLastTranslation = translation

                let dt: TimeInterval
                if let last = accumLastEventTime { dt = now - last }
                else { dt = 0 }
                accumLastEventTime = now

                // Negate: SwiftUI height + down → swipe UP = phase increase.
                let nd = -Double(px / height)
                input.update(delta: nd, deltaTime: dt)

                if !isGrabbing {
                    isGrabbing = true
                    audio.player.beginGrab()
                    audio.player.jumpTo(t: ribbonPhase)
                }

                isScrubbing = true

                let nextPhase = min(1.0, max(0.0, ribbonPhase + nd))
                let gated = nextPhase >= twelveFraction && nextPhase <= audioStopPhase
                audio.player.setAudioGate(gated)

                if gated {
                    audio.player.moveReadHead(by: nd)
                }

                ribbonPhase = nextPhase
            }
            .onEnded { _ in
                endTouchInteraction(reason: "dragEnded")
            }
    }

    // MARK: - Touch Reset

    /// Single panic/reset path for all touch-exit scenarios.
    /// Call from onEnded, onDisappear, scene background, timeout, and
    /// any Start/Stop/Pause button.
    private func endTouchInteraction(reason: String) {
        isGrabbing = false
        isScrubbing = false
        accumLastTranslation = 0
        accumLastEventTime = nil
        lastDragEventTime = 0
        audio.player.endGrab()
        audio.player.setAudioGate(false)
        input.update(delta: 0, deltaTime: 0)
    }

    // MARK: - Telemetry

    private var telemetry: some View {
        HStack(spacing: 24) {
            chip("PHASE", String(format: "%.2f", ribbonPhase))
            chip("VEL",   String(format: "%+.1f", input.velocity))
            chip("DIR",   dirLabel)
        }
    }
    private func chip(_ l: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(l).font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.35))
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.white)
        }
    }
    private var dirLabel: String {
        switch input.direction {
        case .forward: return "FWD"
        case .backward: return "REV"
        case .idle: return "—"
        }
    }

    // MARK: - How-to-play

    private var howToPlayCard: some View {
        Color.black.opacity(0.55).ignoresSafeArea().overlay {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 24) {
                    Text("How to play")
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                    VStack(alignment: .leading, spacing: 20) {
                        step(1, "Watch for the ribbon", "It loops past the 12 / AHH START line.")
                        step(2, "Grab the ahh", "Touch when the ribbon reaches 12.")
                        step(3, "Move the sound", "Swipe up for forward. Swipe down for reverse. Hold for silence.")
                    }
                    Button {
                        endTouchInteraction(reason: "startPractice")
                        hasStarted = true; showingHelp = false
                        ribbonPhase = 0.0
                        audio.player.jumpTo(t: 0.0)
                    } label: {
                        Text("Start Practice")
                            .font(.system(size: 17, weight: .semibold)).foregroundColor(.black)
                            .padding(.horizontal, 40).padding(.vertical, 14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.15)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 24)
                Spacer()
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Text(detail).font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

private final class KidScrubAudioHolder: ObservableObject {
    let player = KidScrubAudioPlayer()
}

#if DEBUG
struct KidPrototypeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { KidPrototypeView() }
            .preferredColorScheme(.dark)
    }
}
#endif
