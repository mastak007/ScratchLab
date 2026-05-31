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

// MARK: - Lane Geometry (shared by drawing and audio gate)

/// Single source of truth for all y-position math in the lane.
/// iOS y=0 at top, increases downward: smaller y = visually higher.
private struct KidLaneGeometry {
    let height: CGFloat
    let twelveFraction: Double   // 0.50
    let audioStopPhase: Double   // 0.98

    var twelveY: CGFloat { height * CGFloat(twelveFraction) }
    var topStopY: CGFloat { height * CGFloat(1.0 - audioStopPhase) }

    func ribbonCenterY(for phase: Double) -> CGFloat {
        height * CGFloat(1.0 - phase)
    }

    /// True when the ribbon centre is at/above the 12 line AND below the top-stop zone.
    func visualAudioAllowed(for phase: Double) -> Bool {
        let y = ribbonCenterY(for: phase)
        return y <= twelveY && y >= topStopY
    }
}

// MARK: - Content

private struct KidPrototypeContentView: View {

    @Environment(\.scenePhase) private var scenePhase
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
    @State private var scratchArmed = false
    @State private var accumLastTranslation: CGFloat = 0

    // Gate dedup — avoid redundant setAudioGate lock calls.
    @State private var lastAudioGate: Bool = false

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
            guard hasStarted, !showingHelp, !isGrabbing else { return }

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
            let geo = KidLaneGeometry(
                height: h,
                twelveFraction: twelveFraction,
                audioStopPhase: audioStopPhase
            )
            let ribbonY = geo.ribbonCenterY(for: ribbonPhase)
            let ribbonH: CGFloat = 36
            let allowed = geo.visualAudioAllowed(for: ribbonPhase)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isGrabbing ? 0.10 : 0.04))

                // 12 / AHH START grab line.
                Rectangle().fill(Color.white.opacity(0.30))
                    .frame(height: 2)
                    .position(x: w / 2, y: geo.twelveY)
                Text("12 / AHH START")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.60))
                    .position(x: w / 2 + 62, y: geo.twelveY - 11)

                // Labels.
                Text("↑ forward")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.18))
                    .position(x: w / 2, y: 14)
                Text("↓ reverse")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.18))
                    .position(x: w / 2, y: h - 14)

                // Ribbon: green when audio allowed; red when grabbing but
                // not allowed; amber when auto-scrolling above 12; dim otherwise.
                Capsule()
                    .fill(ribbonFill(allowed: allowed))
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
            .gesture(dragGesture(geo: geo))
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ribbon colour matches what the user hears:
    /// - grabbing + audio allowed → green
    /// - grabbing + not allowed  → red
    /// - auto-scroll: allowed    → amber (above 12, below top stop)
    /// - auto-scroll: not allowed → grey (below 12 or in top stop zone)
    private func ribbonFill(allowed: Bool) -> Color {
        if isGrabbing {
            return allowed ? Color.green : Color.red
        }
        // Auto-scroll — visual only, no audio. Use the same geometry check
        // as the audio gate so the colour always matches eligibility.
        return allowed ? Color(hex: "F59E0B").opacity(0.75) : Color(hex: "F59E0B").opacity(0.3)
    }

    // MARK: - Drag

    private func dragGesture(geo: KidLaneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation.height
                let px = translation - accumLastTranslation
                accumLastTranslation = translation

                // Negate: SwiftUI height + down → swipe UP = phase increase.
                let nd = -Double(px / geo.height)

                if !isGrabbing {
                    isGrabbing = true
                    audio.player.beginGrab()
                    audio.player.jumpTo(t: ribbonPhase)
                }

                if scratchArmed {
                    // Active scratch — bounce inside the allowed band.
                    // Audio tracks the touch delta regardless of visual clamp.
                    let proposed = ribbonPhase + nd
                    if proposed > audioStopPhase {
                        ribbonPhase = audioStopPhase
                    } else if proposed < twelveFraction {
                        ribbonPhase = twelveFraction
                    } else {
                        ribbonPhase = proposed
                    }

                    if !lastAudioGate {
                        lastAudioGate = true
                        audio.player.setAudioGate(true)
                    }
                    audio.player.moveReadHead(by: nd)
                } else {
                    // Not armed — must visually enter the allowed zone first.
                    // Below 12 or in top-stop = silent.  No audio arm.
                    let proposed = min(1.0, max(0.0, ribbonPhase + nd))
                    if geo.visualAudioAllowed(for: proposed) {
                        scratchArmed = true
                        if !lastAudioGate {
                            lastAudioGate = true
                            audio.player.setAudioGate(true)
                        }
                        audio.player.moveReadHead(by: nd)
                    } else {
                        if lastAudioGate {
                            lastAudioGate = false
                            audio.player.setAudioGate(false)
                        }
                    }
                    ribbonPhase = proposed
                }
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
        scratchArmed = false
        accumLastTranslation = 0
        lastAudioGate = false
        audio.player.endGrab()
        audio.player.setAudioGate(false)
    }

    // MARK: - Telemetry

    private var telemetry: some View {
        HStack(spacing: 24) {
            chip("PHASE", String(format: "%.2f", ribbonPhase))
        }
    }
    private func chip(_ l: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(l).font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.35))
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.white)
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
