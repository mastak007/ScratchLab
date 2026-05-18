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

struct VirtualPlatterPrototypeView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var platter = VirtualPlatter()
    @State private var mode: Mode = .freeSpin

    // Stage state
    @State private var stageClock: TimeInterval = 0
    @State private var stageRunning = false
    @State private var evaluator = ScratchLockEvaluator(stroke: Self.defaultStroke,
                                                        requiredCoverage: 0.45)
    @State private var assessment = LockAssessment(phase: .waiting, progress: 0)
    @State private var showSuccessFlare = false

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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Back")

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hex: "F59E0B"))
                    .frame(width: 8, height: 8)
                Text("Prototype")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.76))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .overlay(
            Text("Virtual Platter")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
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
                        GhostTargetArc(stroke: Self.defaultStroke)
                            .frame(width: side * 0.82, height: side * 0.82)
                    }

                    LiveRibbon(
                        markerAngle: platter.angle,
                        direction: platter.direction,
                        normalizedSpeed: platter.normalizedSpeed
                    )
                    .frame(width: side * 0.82, height: side * 0.82)

                    PlatterMarker(normalizedSpeed: platter.normalizedSpeed,
                                  isActive: platter.isDragging)
                        .frame(width: side, height: side)
                        .rotationEffect(.radians(Double(platter.angle)))

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
                        }
                        .onEnded { _ in
                            platter.endDrag()
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340)

            Text(mode == .stage
                 ? "Spin the record to match the dim ghost target during its window."
                 : "Drag clockwise for forward, counter-clockwise for back.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Image(systemName: directionIcon)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(directionColor)
            Text(platter.direction.label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
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
                    accent: Color(hex: "0EA5E9"),
                    icon: "speedometer"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NORMALIZED SPEED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.46))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(directionColor)
                            .frame(width: proxy.size.width * CGFloat(platter.normalizedSpeed))
                    }
                }
                .frame(height: 10)
            }

            Text(String(format: "Angular velocity: %+.2f rad/s", platter.angularVelocity))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.56))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

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
                    .foregroundColor(.white.opacity(0.46))
                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Stage controls

    private var stageControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STAGE DRILL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.46))
                    Text(stagePhaseLabel)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(stagePhaseColor)
                }
                Spacer()
                Text(String(format: "%.1fs", stageClock))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            ProgressView(value: assessment.progress)
                .tint(stagePhaseColor)

            Text("Target: spin \(Self.defaultStroke.direction.label.uppercased()) between "
                 + String(format: "%.0fs and %.0fs", Self.defaultStroke.start, Self.defaultStroke.end)
                 + ". Hold direction + speed to lock.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: startStage) {
                    Label(stageRunning ? "Restart" : "Start Drill", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Button(action: resetStage) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(stagePhaseColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Stage logic

    private func startStage() {
        evaluator.reset()
        platter.reset()
        stageClock = 0
        assessment = LockAssessment(phase: .waiting, progress: 0)
        showSuccessFlare = false
        stageRunning = true
    }

    private func resetStage() {
        stageRunning = false
        stageClock = 0
        evaluator.reset()
        assessment = LockAssessment(phase: .waiting, progress: 0)
        withAnimation { showSuccessFlare = false }
    }

    private func tick() {
        // Run every frame in every mode so a finger held still on the
        // record decays to "Still" and the ribbon shrinks, instead of
        // freezing on a stale reading like a slider thumb.
        platter.settle(at: ProcessInfo.processInfo.systemUptime)

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

    var body: some View {
        // Dim, static target. ~30% of the ring; arrow conveys direction.
        ZStack {
            Circle()
                .trim(from: 0, to: 0.30)
                .stroke(
                    Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-15))
            Image(systemName: stroke.direction == .forward ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: 16, weight: .black))
                .foregroundColor(.white.opacity(0.35))
                .offset(x: 0, y: -1)
                .position(x: 0, y: 0)
                .offset(x: 0, y: 0)
                .frame(maxWidth: .infinity, alignment: .center)
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

#if DEBUG
struct VirtualPlatterPrototypeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            VirtualPlatterPrototypeView()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
