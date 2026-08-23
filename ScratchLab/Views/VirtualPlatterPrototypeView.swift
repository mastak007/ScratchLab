// VirtualPlatterPrototypeView.swift
// ScratchLab
//
// Isolated prototype screen for the new consumer "virtual platter" direction.
//
// This is a developer-only / DEBUG-gated prototype. It does NOT touch the
// capture pipeline, dataset/export code, or any ML. Grading is exact gesture
// ground truth via `ScratchLockEvaluator`.
//
// To fully remove the prototype: delete this file, VirtualPlatter.swift, and
// the `#if DEBUG` "Virtual Platter Prototype" entry in MainMenuView.swift.

import SwiftUI
import AVFoundation
import Combine
import os

struct VirtualPlatterPrototypeView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var platter = VirtualPlatter()
    @StateObject private var audio = VirtualPlatterAudio()
    @State private var mode: Mode = .freeSpin

    // Stage state
    @State private var stageClock: TimeInterval = 0
    @State private var stageRunning = false
    @State private var evaluator = ScratchLockEvaluator(stroke: Self.defaultStroke,
                                                        requiredCoverage: 0.45)
    @State private var assessment = LockAssessment(phase: .waiting, progress: 0)
    @State private var showSuccessFlare = false

    /// Motor transport. While on, the virtual record spins clockwise at a
    /// constant speed (advances record phase + the marker). Hand-scratch
    /// works whether this is on or off. Identical model in both modes.
    /// Driven by the app-level MIDI dispatch (or the on-screen Play button),
    /// so a controller PLAY flips it too.
    @EnvironmentObject private var transport: TransportState
    /// The app-level iOS scratch playback engine — receives platter position
    /// observations from this view.
    @EnvironmentObject private var playbackEngine: IOScratchPlaybackEngine

    /// THE single source of truth (record turns, 0.0 = 12 o'clock). The
    /// View owns and advances it; it drives the marker directly and is the
    /// target the audio engine chases. Finger owns it while gripped; the
    /// motor advances it only when finger is up and Play is on.
    @State private var recordPhase: Double = 0
    /// Last platter angle consumed, to derive per-update finger deltas.
    @State private var lastPlatterAngle: CGFloat = 0
    /// True while the clean one-shot `ahhh` is armed (record phase is still
    /// in the silent prep zone before the cue this turn).
    @State private var sampleArmed = true

    /// Gray ghost arc = the FULL scratch movement zone (turns of the
    /// record), drawn from 12 o'clock clockwise. The cue is the MIDDLE of
    /// the arc; before it is silent prep, after it record movement reads the
    /// bundled sample at the matching position.
    private static var ghostFraction: CGFloat { CGFloat(VirtualPlatterSampleMapper.ghostSpan) }
    private static var cueFractionOfGhost: CGFloat { CGFloat(VirtualPlatterSampleMapper.cueFraction) }

    /// Record phase (turns) of the cue = middle of the gray arc.
    private var cuePhase: Double { VirtualPlatterSampleMapper.cuePhase }

    /// One full virtual rotation every N seconds under the motor.
    private let motorRotationSeconds: Double = 3.0
    private var motorTurnsPerTick: Double { (1.0 / motorRotationSeconds) / 60.0 }

    // Short, snappy target: a ~1.8s window that opens quickly. With the
    // tuned speed normalization, 0.18 normalized ≈ a real (not feather)
    // scratch, and 0.45 coverage means ~0.8s of matched motion locks it.
    private static let defaultStroke = ScratchTargetStroke(
        direction: .forward,
        start: 0.6,
        end: 2.4,
        minimumNormalizedSpeed: 0.18
    )

    private let stageTick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private enum Mode: String, CaseIterable, Identifiable {
        case freeSpin = "Free Spin"
        case stage = "Stage Drill"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header
                    modePicker
                    platterCard
                    telemetryCard
                    if mode == .stage {
                        stageControlCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
        }
        .navigationBarHidden(true)
        .onReceive(stageTick) { _ in
            tick()
        }
        .onChange(of: mode) { _, _ in
            resetStage()
        }
        .onAppear { audio.start() }
        .onDisappear { audio.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(ScratchLabDesign.Surface.controlFill, in: Circle())
            }
            .accessibilityLabel("Back")

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(ScratchLabDesign.Sem.warning)
                    .frame(width: 8, height: 8)
                Text("Prototype")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ScratchLabDesign.Surface.controlFill, in: Capsule())
        }
        .overlay(
            Text("Virtual Platter")
                .font(ScratchLabDesign.Typo.title3)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
        )
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Platter

    private var platterCard: some View {
        VStack(spacing: 14) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                ZStack {
                    PlatterDisc(direction: platter.direction,
                                isActive: platter.isDragging)

                    if mode == .stage {
                        GhostTargetArc(stroke: Self.defaultStroke,
                                       fraction: Self.ghostFraction,
                                       cueFraction: Self.cueFractionOfGhost)
                            .frame(width: side * 0.82, height: side * 0.82)
                    }

                    LiveRibbon(
                        markerAngle: CGFloat(recordPhase * 2 * .pi),
                        direction: platter.direction,
                        normalizedSpeed: platter.normalizedSpeed
                    )
                    .frame(width: side * 0.82, height: side * 0.82)

                    PlatterMarker(normalizedSpeed: platter.normalizedSpeed,
                                  isActive: platter.isDragging)
                        .frame(width: side, height: side)
                        // The single source of truth: marker IS the record
                        // phase (turns → radians) that the audio chases.
                        .rotationEffect(.radians(recordPhase * 2 * .pi))

                    centerLabel

                    if showSuccessFlare {
                        SuccessFlare()
                            .frame(width: side, height: side)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Tiny "press into the record" feedback on grab.
                .scaleEffect(platter.isDragging ? 1.0 : 0.99)
                .animation(.easeOut(duration: 0.12), value: platter.isDragging)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Spindle dead-zone: a real record gives you
                            // nothing to grip dead-center, and micro-moves
                            // there spike angular velocity. Ignore the hub.
                            let dx = value.location.x - center.x
                            let dy = value.location.y - center.y
                            let radius = (dx * dx + dy * dy).squareRoot()
                            guard radius >= side * 0.13 else { return }

                            let now = ProcessInfo.processInfo.systemUptime
                            platter.updateDrag(to: value.location,
                                               center: center,
                                               timestamp: now)
                            // Finger owns the record now — advance phase
                            // immediately (no motor) for low latency.
                            advanceRecord(allowMotor: false)
                        }
                        .onEnded { _ in
                            platter.endDrag()
                            // Consume the final finger delta; finger is up
                            // so the motor takes over on the next tick.
                            advanceRecord(allowMotor: false)
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340)

            Button(action: togglePlay) {
                HStack(spacing: 8) {
                    Image(systemName: transport.isPlaying ? "stop.fill" : "play.fill")
                    Text(transport.isPlaying ? "Stop" : "Play")
                }
            }
            .scratchLabPrimaryButton(fillsWidth: true)
            .accessibilityLabel(transport.isPlaying ? "Stop" : "Play")

            Text(mode == .stage
                 ? "Press Play, then spin the record to match the ghost. The ahhh is fixed to the record: hold to stop, push/pull to move through it."
                 : "Press Play: the ahhh follows the record. Hold to stop, push forward to advance, pull back to reverse.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scratchLabCard(.standard)
    }

    // Specialized platter visualization: the backdrop keeps a fixed
    // low-opacity black wash (not a shared surface token) because it exists
    // purely for text legibility over the rotating disc art underneath, not
    // as generic card chrome. `directionColor` is preserved — it's the
    // functional rotation/direction encoding shared with `telemetryTile`.
    private var centerLabel: some View {
        VStack(spacing: 2) {
            Image(systemName: directionIcon)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(directionColor)
            Text(platter.direction.label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary.opacity(0.8))
        }
        .padding(14)
        .background(Color.black.opacity(0.45), in: Circle())
    }

    // MARK: - Telemetry

    private var telemetryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                telemetryTile(
                    title: "DIRECTION",
                    value: platter.direction.label,
                    accent: directionColor,
                    icon: directionIcon
                )
                telemetryTile(
                    title: "SPEED",
                    value: String(format: "%.0f%%", platter.normalizedSpeed * 100),
                    accent: ScratchLabDesign.Sem.accent,
                    icon: "speedometer"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NORMALIZED SPEED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ScratchLabDesign.Surface.controlFill)
                        Capsule()
                            .fill(directionColor)
                            .frame(width: proxy.size.width * CGFloat(platter.normalizedSpeed))
                    }
                }
                .frame(height: 10)
            }

            Text(String(format: "Angular velocity: %+.2f rad/s", platter.angularVelocity))
                .font(ScratchLabDesign.Typo.technical)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
        }
        .scratchLabCard(.standard)
    }

    // `accent` carries functional meaning for the DIRECTION tile
    // (`directionColor`, the shared rotation/direction encoding) but is a
    // plain product token for the SPEED tile — the caller decides which.
    private func telemetryTile(title: String, value: String, accent: Color, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
    }

    // MARK: - Stage controls

    // The border stays tied to `stagePhaseColor` — a functional playback-phase
    // encoding (waiting/active/locked/missed), not decoration, so it is kept
    // as a manual overlay rather than folded into a fixed `.scratchLabCard`
    // border variant.
    private var stageControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STAGE DRILL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                    Text(stagePhaseLabel)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(stagePhaseColor)
                }
                Spacer()
                Text(String(format: "%.1fs", stageClock))
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
            }

            ProgressView(value: assessment.progress)
                .tint(stagePhaseColor)

            Text("Target: spin \(Self.defaultStroke.direction.label.uppercased()) between "
                 + String(format: "%.0fs and %.0fs", Self.defaultStroke.start, Self.defaultStroke.end)
                 + ". Hold direction + speed to lock.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: startStage) {
                    Label(stageRunning ? "Restart" : "Start Drill", systemImage: "play.fill")
                }
                .scratchLabPrimaryButton(fillsWidth: true)

                Button(action: resetStage) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .scratchLabSecondaryButton(fillsWidth: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScratchLabDesign.Surface.card, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.card, style: .continuous)
                .stroke(stagePhaseColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Stage logic

    /// Re-cue: record phase 0 = 12 o'clock, marker reset, sample re-armed
    /// and stopped (clean slate for the next cue crossing).
    private func cueRecord() {
        platter.reset()
        recordPhase = 0
        lastPlatterAngle = platter.angle      // == 0 after reset
        sampleArmed = true
        audio.resetSample()
    }

    /// The ONE place record phase moves. Finger (when gripped & actually
    /// moving) owns it; otherwise the motor advances it when Play is on and
    /// the finger is up. Holding the record still freezes the phase.
    ///
    /// Audio (clean baseline): crossing the cue fires the unmodified `ahhh`
    /// from the top via `AVAudioPlayer`; from then on the sample is *gated by
    /// record motion* — it plays only while the record is actually advancing
    /// and `pause()`s the instant the record is held still or the finger
    /// lifts. Pulling back before the cue stops + re-arms it. `pause/resume`
    /// keep the read position so it stays bit-exact and glitch-free.
    ///
    /// TODO: true record-owned playback (sample position driven directly by
    /// record delta) is still the goal but is PARKED. A position-following
    /// `AVAudioSourceNode` was tried and degraded the sample (audible
    /// wobble), so it was rolled back — clean audio quality is the priority.
    /// Any future attempt must NOT regress the clean `ahhh`; do not attempt
    /// reverse or sample-progress-by-delta until a glitch-free approach is
    /// proven. The pure `VirtualPlatterSampleMapper.normalizedSamplePosition`
    /// (already unit-tested) is the intended math when that day comes.
    private func advanceRecord(allowMotor: Bool) {
        let delta = Double(platter.angle - lastPlatterAngle) / (2 * .pi)
        lastPlatterAngle = platter.angle

        // Is the record phase actually advancing right now? Reuse the exact
        // condition that gates the phase update below: finger gripped and not
        // held still, OR the motor driving it with the finger up. Held still
        // / finger up with the motor off ⇒ not moving ⇒ the audio freezes.
        let fingerMoving = platter.isDragging && platter.direction != .idle
        let motorMoving = !platter.isDragging && allowMotor && transport.isPlaying
        let recordIsMoving = fingerMoving || motorMoving

        if platter.isDragging {
            // Finger owns the record; the tuned idle/hysteresis in the
            // platter model decides "actually scratching" vs "held still".
            if platter.direction != .idle {
                recordPhase += delta
            }
            // else: gripped but still → HOLD (no phase change), motor off.
        } else if allowMotor && transport.isPlaying {
            recordPhase += motorTurnsPerTick
        }
        // else: finger up, motor off → frozen.

        // Motion-gated one-shot cue logic on the wrapped phase.
        let fr = recordPhase - floor(recordPhase)
        if fr < cuePhase {
            if !sampleArmed {
                audio.resetSample()   // pulled back before cue → reset + re-arm
                sampleArmed = true
            }
        } else if sampleArmed {
            audio.triggerOnce()       // first crossing this turn → clean ahhh
            sampleArmed = false
        } else if recordIsMoving {
            audio.resume()            // record still moving → keep playing
        } else {
            audio.pause()             // held still / finger lifted → freeze now
        }
    }

    private func togglePlay() {
        transport.toggle()
        if transport.isPlaying { cueRecord() }
    }

    private func startStage() {
        evaluator.reset()
        stageClock = 0
        assessment = LockAssessment(phase: .waiting, progress: 0)
        showSuccessFlare = false
        stageRunning = true
        // Same record model — re-cue so sample start sits at the ghost
        // start (12 o'clock). Audio is NOT gated by the drill.
        cueRecord()
    }

    private func resetStage() {
        stageRunning = false
        stageClock = 0
        evaluator.reset()
        assessment = LockAssessment(phase: .waiting, progress: 0)
        withAnimation { showSuccessFlare = false }
        cueRecord()
    }

    private func tick() {
        // Keep the platter model's tuned idle/hysteresis fresh so a held
        // finger reads as ".idle" and the record holds.
        platter.settle(at: ProcessInfo.processInfo.systemUptime)

        // The single place the record phase advances (finger or motor).
        advanceRecord(allowMotor: true)

        // Observe the current platter position into the scratch playback
        // engine (data-flow only — no audio, no seeking).
        let position = VirtualPlatterSampleMapper.platterPosition(
            recordPhase: recordPhase,
            direction: platter.direction,
            velocity: Double(platter.angularVelocity)
        )
        playbackEngine.updatePlatterPosition(position)

        guard mode == .stage, stageRunning else { return }
        stageClock += 1.0 / 60.0

        let wasSuccess = assessment.isSuccess
        assessment = evaluator.evaluate(
            direction: platter.direction,
            normalizedSpeed: platter.normalizedSpeed,
            at: stageClock
        )

        if assessment.isSuccess && !wasSuccess {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showSuccessFlare = true
            }
        }

        if stageClock > Self.defaultStroke.end + 1.2 {
            stageRunning = false
        }
    }

    // MARK: - Derived display

    private var directionColor: Color {
        switch platter.direction {
        case .forward: return Color(hex: "22C55E")
        case .backward: return Color(hex: "F59E0B")
        case .idle: return Color(hex: "64748B")
        }
    }

    private var directionIcon: String {
        switch platter.direction {
        case .forward: return "arrow.clockwise"
        case .backward: return "arrow.counterclockwise"
        case .idle: return "pause.fill"
        }
    }

    private var stagePhaseLabel: String {
        switch assessment.phase {
        case .waiting: return stageRunning ? "Get Ready" : "Idle"
        case .active: return "Tracking…"
        case .locked: return "Locked!"
        case .missed: return "Missed"
        }
    }

    private var stagePhaseColor: Color {
        switch assessment.phase {
        case .waiting: return Color(hex: "64748B")
        case .active: return Color(hex: "0EA5E9")
        case .locked: return Color(hex: "22C55E")
        case .missed: return Color(hex: "EF4444")
        }
    }
}

// MARK: - Platter visuals

private struct PlatterDisc: View {
    let direction: PlatterDirection
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: "1B2330"), Color(hex: "070A10")],
                        center: .center,
                        startRadius: 4,
                        endRadius: 220
                    )
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(isActive ? 0.22 : 0.10),
                                    lineWidth: 2)
                )

            ForEach(1..<6) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    .padding(CGFloat(ring) * 22)
            }

            Circle()
                .fill(Color(hex: "F59E0B").opacity(0.18))
                .frame(width: 64, height: 64)
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct PlatterMarker: View {
    let normalizedSpeed: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let head = 14 + 12 * CGFloat(normalizedSpeed)   // grows with speed
            let glow = 5 + 12 * CGFloat(normalizedSpeed)
            ZStack {
                Capsule()
                    .fill(Color(hex: "00D4FF"))
                    .frame(width: 4, height: side * 0.42)
                    .offset(y: -side * 0.21)
                    .opacity(isActive ? 1.0 : 0.7)
                Circle()
                    .fill(Color(hex: "00D4FF"))
                    .frame(width: head, height: head)
                    .offset(y: -side * 0.40)
                    .shadow(color: Color(hex: "00D4FF").opacity(0.85),
                            radius: glow)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.08), value: normalizedSpeed)
        }
    }
}

private struct GhostTargetArc: View {
    let stroke: ScratchTargetStroke
    /// Full scratch zone as a fraction of the ring (from 12 o'clock).
    let fraction: CGFloat
    /// Cue position as a fraction of the gray arc (~0.25 in from the start).
    let cueFraction: CGFloat

    var body: some View {
        // Gray arc = the FULL required scratch movement (pull-back + push).
        // It starts at 12 o'clock. The bright tick is the cue/sample start,
        // sitting ~25% in — so the first part of the arc is silent prep.
        ZStack {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Color.white.opacity(0.20),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Bright cue tick INSIDE the gray arc = where ahhh starts.
            Circle()
                .trim(from: fraction * cueFraction,
                      to: fraction * cueFraction + 0.013)
                .stroke(
                    Color(hex: "00D4FF"),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: stroke.direction == .forward ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: 16, weight: .black))
                .foregroundColor(.white.opacity(0.35))
        }
    }
}

private struct LiveRibbon: View {
    let markerAngle: CGFloat
    let direction: PlatterDirection
    let normalizedSpeed: Double

    var body: some View {
        // Streak length scales with speed (max ~0.34 turn ≈ 122°).
        let sweep = CGFloat(0.05 + 0.30 * normalizedSpeed)
        // Marker tip in atan2/screen convention. The marker art points up at
        // rest, so it sits π/2 behind the accumulated finger angle.
        let tip = Double(markerAngle) - .pi / 2
        // Trail sits *behind* the tip, opposite the travel direction, so it
        // reads as the record's recent path rather than a slider fill.
        let rotation: Double = direction == .forward
            ? tip - Double(sweep) * 2 * .pi
            : tip
        // Tie the streak colour to forward / back so direction is obvious.
        let color = direction == .backward
            ? Color(hex: "F59E0B")
            : Color(hex: "00D4FF")

        Circle()
            .trim(from: 0, to: sweep)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 9 + 9 * CGFloat(normalizedSpeed),
                                   lineCap: .round)
            )
            .rotationEffect(.radians(rotation))
            .opacity(direction == .idle ? 0 : 0.95)
            .animation(.easeOut(duration: 0.08), value: normalizedSpeed)
            .animation(.easeOut(duration: 0.12), value: direction)
    }
}

private struct SuccessFlare: View {
    @State private var pop = false

    var body: some View {
        ZStack {
            // One-shot expanding ring — a quick satisfying hit, not a
            // never-ending pulse that nags after the lock lands.
            Circle()
                .stroke(Color(hex: "22C55E"), lineWidth: 5)
                .scaleEffect(pop ? 1.18 : 0.55)
                .opacity(pop ? 0 : 0.9)
            Circle()
                .fill(Color(hex: "22C55E").opacity(0.16))
                .scaleEffect(pop ? 1.0 : 0.6)
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(Color(hex: "22C55E"))
                Text("LOCKED")
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(.white)
            }
            .scaleEffect(pop ? 1.0 : 0.7)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                pop = true
            }
        }
    }
}

// MARK: - Record audio (DEBUG prototype only)

/// Clean baseline + motion gating. Built on the dead-simple `AVAudioPlayer`
/// path that was audible and clean on device: the bundled `ahhh` played
/// forward at its original speed/pitch (`enableRate = false`, bit-exact).
/// The View starts it from the top when the record phase crosses the cue,
/// then `pause()`s / `resume()`s it as the record stops / moves so the sample
/// is record-gated instead of an autonomous one-shot. `pause()` keeps the
/// read position, so resuming continues seamlessly — no restart, no glitch.
///
/// Deliberately NOT a scrubber/chunk-scheduler/resampler and NOT reverse —
/// those produced silence / mangled "boohooing" audio.
///
/// TODO: record-owned playback (sample position driven directly by record
/// delta) is still wanted but PARKED. Two approaches have now regressed the
/// audio on device and were rolled back: (1) per-tick
/// `AVAudioPlayerNode.scheduleBuffer(...[.interrupts])` chunking → silence /
/// "boohoo"; (2) a position-following `AVAudioSourceNode` (linear-interpolated
/// glide to a record-driven read position) → audible wobble. Clean sample
/// quality is the priority over delta-accurate scrubbing. Do NOT reattempt
/// reverse or sample-progress-by-delta until a genuinely glitch-free read is
/// proven offline first. The pure, unit-tested
/// `VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase:)` holds
/// the intended math for that future work.
///
/// No capture/export/ML/dataset. iOS-only, DEBUG-gated; delete with prototype.
final class VirtualPlatterAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {

    private var player: AVAudioPlayer?

    /// True once the one-shot has played all the way through this turn. While
    /// set, `resume()` refuses to restart it: the sample only plays again
    /// after a pull-back before the cue re-arms it (`resetSample`). This is
    /// what stops it running autonomously after the finger lifts.
    private var playbackFinished = false

    override init() {
        super.init()
        guard
            let url = Bundle.main.url(forResource: "ahhh",
                                      withExtension: "wav",
                                      subdirectory: "VirtualPlatter"),
            let player = try? AVAudioPlayer(contentsOf: url)
        else {
            return
        }
        player.enableRate = false      // no pitch/time warp — original ahhh
        player.numberOfLoops = 0       // one-shot
        player.delegate = self         // detect natural end of the one-shot
        // prepareToPlay is deferred to start(): it warms the hardware decode
        // buffers and can block, so it runs off the main thread there.
        self.player = player
    }

    func start() {
        #if canImport(UIKit)
        // The synchronous AVAudioSession configuration has no async overload
        // that resolves here, so move the blocking work off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            self?.player?.prepareToPlay()
        }
        #else
        player?.prepareToPlay()
        #endif
    }

    func stop() {
        player?.stop()
        #if canImport(UIKit)
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
        }
        #endif
    }

    /// Start the unmodified `ahhh` from the top — the record just crossed the
    /// cue this turn.
    func triggerOnce() {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        playbackFinished = false
        player.play()
    }

    /// Resume from the paused position while the record keeps moving forward
    /// past the cue. No-op if already playing, or if the one-shot has already
    /// finished this turn — it never auto-replays on its own.
    func resume() {
        guard let player, !player.isPlaying, !playbackFinished else { return }
        player.play()
    }

    /// Freeze the sample exactly where it is (record held still / finger
    /// lifted). `pause()` keeps the read position so a later `resume()`
    /// continues seamlessly — no restart, no glitch, sample stays clean.
    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
    }

    /// Stop + rewind so the next cue crossing plays cleanly from the top.
    func resetSample() {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        playbackFinished = false
    }

    /// One-shot reached its natural end: latch it so motion can't re-trigger
    /// it until a pull-back before the cue re-arms the sample.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackFinished = true
    }

    deinit {
        player?.stop()
    }
}

#if DEBUG
struct VirtualPlatterPrototypeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            VirtualPlatterPrototypeView()
        }
        .environmentObject(TransportState())
        .environmentObject(IOScratchPlaybackEngine())
        .preferredColorScheme(.dark)
    }
}
#endif
