import SwiftUI
import AppKit
import QuartzCore

// MARK: - ViewModel

@MainActor
final class NotationVisualizerViewModel: ObservableObject {

    // MARK: Notation data (loaded once)

    let notation: ScratchNotation?
    // Display duration: the notation phrase window (e.g. 2.126s). Audio cycles are longer;
    // timing within each cycle is mapped via BabyScratchReferenceMotionTimeline.
    var loopDuration: TimeInterval { BabyScratchReferenceMotionTimeline.phraseEnd }

    // MARK: Shared coordinator — master clock for all timing

    private let demo: BabyScratchDemoPlaybackCoordinator

    // MARK: Playback state

    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var isPlaying = false

    // MARK: Motion history — timestamped in loop-time coords for canvas rendering

    struct MotionEvent {
        let loopTime: TimeInterval
        let wall: CFTimeInterval      // for expiry
        let direction: CXLDirection
    }
    private(set) var motionHistory: [MotionEvent] = []
    private let motionRetentionLoops: Double = 2.0

    // MARK: Score badge state

    struct ScoreBadge: Identifiable {
        let id = UUID()
        let classification: CXLTimingClassification
        let createdAt: CFTimeInterval
        var isVisible: Bool { CACurrentMediaTime() - createdAt < 1.8 }
    }
    @Published private(set) var recentBadges: [ScoreBadge] = []

    // MARK: Score counters

    @Published private(set) var onTimeCount = 0
    @Published private(set) var earlyCount = 0
    @Published private(set) var lateCount = 0
    @Published private(set) var wrongCount = 0
    @Published private(set) var missedCount = 0

    // MARK: Playback internals

    private var loopIndex = 0
    // Tracks which audio phrase cycle we are in, so we can detect cycle wrap.
    private var lastCycleIndex: Int = 0

    // Target-stroke firing: tracks which stroke start-times have been fired in the current loop
    private var firedStrokeIndicesThisLoop: Set<Int> = []
    private var lastTickLoopTime: TimeInterval = 0

    // Pending scores: (strokeIndex, direction, wallTimeFired)
    private struct PendingScore {
        let strokeIndex: Int
        let direction: CXLDirection
        let firedWall: CFTimeInterval
        let duration: Double?
    }
    private var pendingScores: [PendingScore] = []
    private let scoreWindowS: CFTimeInterval = 0.180   // ±180ms matching window

    // MARK: Init

    init(demo: BabyScratchDemoPlaybackCoordinator) {
        self.demo = demo
        notation = ScratchNotation.loadBabyScratchFromBundle()
    }

    // MARK: Playback control

    func play() {
        guard !isPlaying else { return }
        demo.playBabyScratch()
        isPlaying = demo.isPlaying
        playbackTime = BabyScratchDemoPlaybackCoordinator.notationPhraseTime(
            for: demo.currentAudioTime
        )
    }

    func pause() {
        demo.pause()
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func reset() {
        demo.stop()
        isPlaying = false
        playbackTime = 0
        loopIndex = 0
        lastCycleIndex = 0
        firedStrokeIndicesThisLoop = []
        lastTickLoopTime = 0
        pendingScores = []
        motionHistory = []
        recentBadges = []
        onTimeCount = 0
        earlyCount = 0
        lateCount = 0
        wrongCount = 0
        missedCount = 0
    }

    // MARK: Per-frame tick (called by the view's timer)

    func tick(captureEngine: MacCaptureEngine) {
        guard demo.playbackState == .playing else {
            ScratchLabRuntimeDiagnostics.shared.markNotationIdle()
            if isPlaying {
                isPlaying = false
            }
            if demo.playbackState == .stopped, playbackTime != 0 {
                playbackTime = 0
                lastTickLoopTime = 0
                lastCycleIndex = 0
            }
            return
        }

        let tickStartedAt = CACurrentMediaTime()
        let signpostID = ScratchLabPerformanceSignpost.begin("NotationTick")
        defer {
            ScratchLabPerformanceSignpost.end("NotationTick", signpostID)
            ScratchLabRuntimeDiagnostics.shared.recordNotationTick(
                durationSeconds: CACurrentMediaTime() - tickStartedAt
            )
        }

        // Auto-replay when the bundled demo audio reaches its end.
        if demo.playbackState == .playing && !demo.isPlaying {
            demo.replayBabyScratch()
            lastCycleIndex = 0
            guard demo.playbackState == .playing else {
                if isPlaying {
                    isPlaying = false
                }
                return
            }
        }

        // Audio player time is the master clock. Map it to notation phrase time.
        let audioTime = demo.currentAudioTime
        let cycleDur = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration

        let currentCycleIndex = cycleDur > 0 ? Int(audioTime / cycleDur) : 0
        let newLoopTime = BabyScratchDemoPlaybackCoordinator.notationPhraseTime(
            for: audioTime
        )
        if playbackTime != newLoopTime {
            playbackTime = newLoopTime
        }
        if !isPlaying {
            isPlaying = true
        }

        let now = CACurrentMediaTime()

        // A "loop" increments when we enter a new audio phrase cycle.
        let didWrap = currentCycleIndex > lastCycleIndex
        if didWrap {
            loopIndex += 1
            firedStrokeIndicesThisLoop = []
            if captureEngine.cxlIsRecording {
                captureEngine.cxlRecorder.recordLoopEnd()
                captureEngine.cxlRecorder.recordLoopStart()
            }
        }

        fireTargetStrokes(at: newLoopTime, prev: lastTickLoopTime, wrapped: didWrap, captureEngine: captureEngine, now: now)
        resolvePendingScores(captureEngine: captureEngine, now: now)
        pruneMotionHistory(loopTime: newLoopTime)
        pruneScoreBadges()

        lastCycleIndex = currentCycleIndex
        lastTickLoopTime = newLoopTime
    }

    // MARK: Motion observation (called by view on handMotionState change)

    func recordObservedMotion(_ state: MacCaptureEngine.HandMotionState, loopTime: TimeInterval) {
        let dir: CXLDirection
        switch state {
        case .movingRight: dir = .forward
        case .movingLeft:  dir = .back
        case .steady:      dir = .idle
        case .searching:   dir = .searching
        }
        let event = MotionEvent(loopTime: loopTime, wall: CACurrentMediaTime(), direction: dir)
        motionHistory.append(event)
        if motionHistory.count > 400 { motionHistory.removeFirst(100) }
    }

    // MARK: Private helpers

    private func fireTargetStrokes(
        at newTime: TimeInterval,
        prev prevTime: TimeInterval,
        wrapped: Bool,
        captureEngine: MacCaptureEngine,
        now: CFTimeInterval
    ) {
        guard let strokes = notation?.strokes else { return }
        for (i, stroke) in strokes.enumerated() {
            guard !firedStrokeIndicesThisLoop.contains(i) else { continue }
            let crossed = wrapped
                ? (stroke.startTime >= prevTime || stroke.startTime <= newTime)
                : (stroke.startTime >= prevTime && stroke.startTime <= newTime)
            guard crossed else { continue }
            firedStrokeIndicesThisLoop.insert(i)
            let dir: CXLDirection = stroke.direction == .forward ? .forward : .back
            let dur = stroke.duration
            var strokeIndex = -1
            if captureEngine.cxlIsRecording {
                strokeIndex = captureEngine.recordCXLTargetStroke(direction: dir, strokeDuration: dur)
            }
            pendingScores.append(PendingScore(
                strokeIndex: strokeIndex,
                direction: dir,
                firedWall: now,
                duration: dur
            ))
        }
    }

    private func resolvePendingScores(captureEngine: MacCaptureEngine, now: CFTimeInterval) {
        let resolved = pendingScores.filter { pending in
            now - pending.firedWall >= scoreWindowS
        }
        pendingScores.removeAll { pending in
            now - pending.firedWall >= scoreWindowS
        }
        for pending in resolved {
            let (observed, timingErrorMs) = bestMotionMatch(for: pending, now: now)
            let classification = CXLNotationCaptureRecorder.classify(
                target: pending.direction,
                observed: observed,
                timingErrorMs: timingErrorMs,
                confidence: observed == .idle || observed == .searching ? 0 : 0.8
            )
            if captureEngine.cxlIsRecording, pending.strokeIndex >= 0 {
                captureEngine.cxlRecorder.recordScore(
                    targetStrokeIndex: pending.strokeIndex,
                    targetDirection: pending.direction,
                    observedDirection: observed,
                    timingErrorMs: timingErrorMs,
                    confidence: observed == .idle ? 0 : 0.8,
                    signalSource: .camera
                )
            }
            tallyClassification(classification)
            let badge = ScoreBadge(classification: classification, createdAt: now)
            recentBadges.append(badge)
            if recentBadges.count > 6 { recentBadges.removeFirst() }
        }
    }

    private func bestMotionMatch(for pending: PendingScore, now: CFTimeInterval) -> (CXLDirection, Double) {
        // Find motion events near the stroke fire time
        let firedAt = pending.firedWall
        let window = scoreWindowS
        let nearby = motionHistory.filter { abs($0.wall - firedAt) <= window }
        guard let best = nearby.max(by: { abs($0.wall - firedAt) > abs($1.wall - firedAt) }) else {
            return (.idle, 999)
        }
        let timingErrorMs = (best.wall - firedAt) * 1000
        return (best.direction, timingErrorMs)
    }

    private func tallyClassification(_ c: CXLTimingClassification) {
        switch c {
        case .onTime:         onTimeCount += 1
        case .early:          earlyCount += 1
        case .late:           lateCount += 1
        case .wrongDirection: wrongCount += 1
        case .missed:         missedCount += 1
        case .idle:           break
        }
    }

    private func pruneMotionHistory(loopTime: TimeInterval) {
        // Keep last N full loops worth of history by wall clock
        let cutoff = CACurrentMediaTime() - loopDuration * motionRetentionLoops
        motionHistory.removeAll { $0.wall < cutoff }
    }

    private func pruneScoreBadges() {
        recentBadges.removeAll { !$0.isVisible }
    }
}

// MARK: - Top-level view

struct NotationVisualizerView: View {

    @EnvironmentObject private var captureEngine: MacCaptureEngine
    @ObservedObject private var demo: BabyScratchDemoPlaybackCoordinator
    @StateObject private var vm: NotationVisualizerViewModel

    let capturedSnapshot: CaptureCore.DetectedNotationSnapshot?

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(demo: BabyScratchDemoPlaybackCoordinator, capturedSnapshot: CaptureCore.DetectedNotationSnapshot? = nil) {
        _demo = ObservedObject(wrappedValue: demo)
        _vm = StateObject(wrappedValue: NotationVisualizerViewModel(demo: demo))
        self.capturedSnapshot = capturedSnapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            notationStatusBar
            if let snapshot = capturedSnapshot {
                CapturedNotationDisplayView(snapshot: snapshot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScratchNotationCanvasView(
                    notation: vm.notation,
                    playbackTime: vm.playbackTime,
                    loopDuration: vm.loopDuration
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                notationMotionLane
                notationTransportBar
            }
        }
        .background(Color(white: 0.10))
        .onAppear {
            if capturedSnapshot == nil {
                demo.configureBabyScratchIfNeeded()
            }
        }
        .onReceive(ticker) { _ in
            guard capturedSnapshot == nil else { return }
            vm.tick(captureEngine: captureEngine)
        }
        .onChange(of: captureEngine.handMotionState) { _, newState in
            guard capturedSnapshot == nil else { return }
            guard vm.isPlaying || captureEngine.cxlIsRecording else { return }
            vm.recordObservedMotion(newState, loopTime: vm.playbackTime)
        }
        .onDisappear {
            vm.pause()
        }
    }

    // MARK: Status bar

    private var notationStatusBar: some View {
        HStack(spacing: 16) {
            ScratchLabBrandMark(size: 22)

            if let snapshot = capturedSnapshot {
                Text("Notation Lab · Captured Notation")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                labelChip(
                    "Source: \(snapshot.notationSource)",
                    color: snapshot.notationSource == "detected"
                        ? Color(red: 0.2, green: 0.85, blue: 0.55)
                        : Color(red: 1.0, green: 0.75, blue: 0.0)
                )
                labelChip(
                    "\(snapshot.audioEvents.count) audio · \(snapshot.recordMovementEvents.count) movement",
                    color: Color(white: 0.45)
                )
                if let confidence = snapshot.notationConfidence {
                    labelChip(
                        "Confidence \(Int((confidence * 100).rounded()))%",
                        color: Color(white: 0.45)
                    )
                }
            } else {
                Text("Notation Lab · Advanced technical view")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                labelChip(
                    "Phrase \(String(format: "%.3f", vm.loopDuration))s",
                    color: Color(white: 0.45)
                )
                labelChip(
                    demo.isAudioAvailable ? "Audio ready" : "Audio missing",
                    color: demo.isAudioAvailable ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color(red: 1.0, green: 0.45, blue: 0.25)
                )
                labelChip(
                    "Source: \(ScratchLabDemoSessionBuilder.demoAudioFileName)",
                    color: Color(white: 0.45)
                )
                labelChip(
                    "Audio \(String(format: "%.1f", demo.currentAudioTime))s",
                    color: Color(white: 0.45)
                )
                labelChip(
                    vm.isPlaying ? "Playing" : "Paused",
                    color: vm.isPlaying ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color(white: 0.45)
                )
                labelChip(
                    captureEngine.cxlIsRecording ? "CXL REC" : "CXL Idle",
                    color: captureEngine.cxlIsRecording ? Color(red: 1.0, green: 0.25, blue: 0.25) : Color(white: 0.35)
                )
                labelChip(
                    "Baby Scratch Template",
                    color: Color(white: 0.35)
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(white: 0.13))
    }

    private func labelChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Motion lane

    private var notationMotionLane: some View {
        HStack(spacing: 0) {
            Text("MOTION")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.40))
                .frame(width: 56)

            ZStack(alignment: .leading) {
                Color(white: 0.11)
                motionDirectionIndicator
            }
        }
        .frame(height: 40)
        .background(Color(white: 0.11))
    }

    private var motionDirectionIndicator: some View {
        let state = captureEngine.handMotionState
        let (label, color): (String, Color) = switch state {
        case .movingRight: ("▶▶ Forward",  Color(red: 0.2,  green: 0.85, blue: 0.55))
        case .movingLeft:  ("◀◀ Back",     Color(red: 1.0,  green: 0.55, blue: 0.10))
        case .steady:      ("— Steady",    Color(white: 0.50))
        case .searching:   ("⊘ Searching", Color(white: 0.30))
        }
        return Text(label)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.leading, 16)
            .animation(.easeInOut(duration: 0.08), value: state)
    }

    // MARK: Transport bar

    private var notationTransportBar: some View {
        HStack(spacing: 0) {
            // Play / reset
            HStack(spacing: 8) {
                Button(action: { vm.togglePlay() }) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: { vm.reset() }) {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.55))
            }
            .padding(.horizontal, 18)

            Divider()
                .frame(height: 28)
                .background(Color(white: 0.25))

            // Score badges strip
            HStack(spacing: 6) {
                scoreBadge("ON", count: vm.onTimeCount, color: Color(red: 0.2, green: 0.85, blue: 0.55))
                scoreBadge("EARLY", count: vm.earlyCount, color: Color(red: 1.0, green: 0.85, blue: 0.0))
                scoreBadge("LATE", count: vm.lateCount, color: Color(red: 1.0, green: 0.55, blue: 0.0))
                scoreBadge("WRONG", count: vm.wrongCount, color: Color(red: 1.0, green: 0.25, blue: 0.25))
                scoreBadge("MISS", count: vm.missedCount, color: Color(white: 0.40))
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 0)

            Divider()
                .frame(height: 28)
                .background(Color(white: 0.25))

            // CXL controls
            HStack(spacing: 8) {
                if captureEngine.cxlIsRecording {
                    Button("Stop CXL") {
                        captureEngine.stopCXLCapture()
                        vm.pause()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 1.0, green: 0.25, blue: 0.25))
                    .font(.system(size: 11, weight: .semibold))

                    Button("Export") {
                        captureEngine.exportCXLSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.1, green: 0.45, blue: 1.0))
                    .font(.system(size: 11, weight: .semibold))
                } else {
                    Button("Start CXL") {
                        captureEngine.startCXLCapture(
                            mode: "notationCoach",
                            loopDuration: vm.loopDuration
                        )
                        vm.play()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.2, green: 0.75, blue: 0.3))
                    .font(.system(size: 11, weight: .semibold))

                    if captureEngine.cxlEventCount > 0 {
                        Button("Export") {
                            captureEngine.exportCXLSession()
                        }
                        .buttonStyle(.bordered)
                        .tint(Color(red: 0.1, green: 0.45, blue: 1.0))
                        .font(.system(size: 11, weight: .semibold))
                    }
                }

                if let path = captureEngine.cxlLastExportPath {
                    Button(action: { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }) {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 180)
                    .help(path)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 48)
        .background(Color(white: 0.13))
    }

    private func scoreBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.50))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(count > 0 ? color : Color(white: 0.30))
        }
    }
}

// MARK: - Timeline Canvas

struct NotationTimelineCanvas: View {

    @ObservedObject var vm: NotationVisualizerViewModel

    // Visual constants
    private let visibleWindowMultiplier: Double = 1.6  // shows 1.6 × phraseEnd of timeline
    private let playheadFraction: Double = 0.28        // playhead at 28% from left
    private let targetLaneHeightFraction: Double = 0.72
    private let gridMajorIntervalS: Double = 0.5       // major beat every 0.5s
    private let gridMinorIntervalS: Double = 0.125     // minor subdivision

    private let forwardColor  = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backColor     = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let gridMajor     = Color(white: 0.22)
    private let gridMinor     = Color(white: 0.155)
    private let playheadColor = Color.white
    private let dotColor      = Color(white: 0.82)

    var body: some View {
        Canvas { ctx, size in
            let now = vm.playbackTime
            let loop = vm.loopDuration
            let targetH = size.height * targetLaneHeightFraction
            let targetRect = CGRect(x: 0, y: 0, width: size.width, height: targetH)
            let motionY = targetH           // top of motion trace band (unused in canvas; lane is separate view)

            let visibleDuration = loop * visibleWindowMultiplier
            let pps = size.width / CGFloat(visibleDuration)
            let playheadX = size.width * CGFloat(playheadFraction)

            // 1. Background — draw darker band for target vs subtle for "history"
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))

            // 2. Grid — minor then major
            drawGrid(ctx: ctx, size: size, playheadX: playheadX, pps: pps, now: now, loop: loop)

            // 3. Target label
            drawLaneLabel(ctx: ctx, text: "TARGET", x: 6, y: 6)

            // 4. Target strokes (draw for current, prev, and next loop iterations)
            if let strokes = vm.notation?.strokes {
                for loopOffset in [-loop, 0, loop] {
                    for (i, stroke) in strokes.enumerated() {
                        drawStroke(
                            ctx: ctx,
                            stroke: stroke,
                            loopOffset: loopOffset,
                            now: now,
                            playheadX: playheadX,
                            pps: pps,
                            laneRect: targetRect,
                            canvasWidth: size.width
                        )
                        // Hold line between strokes
                        if i + 1 < strokes.count {
                            drawHold(
                                ctx: ctx,
                                from: stroke,
                                to: strokes[i + 1],
                                loopOffset: loopOffset,
                                now: now,
                                playheadX: playheadX,
                                pps: pps,
                                laneRect: targetRect,
                                canvasWidth: size.width
                            )
                        }
                    }
                }
            }

            // 5. Playhead
            var ph = Path()
            ph.move(to: CGPoint(x: playheadX, y: 0))
            ph.addLine(to: CGPoint(x: playheadX, y: size.height))
            ctx.stroke(ph, with: .color(playheadColor.opacity(0.90)), lineWidth: 1.5)

            // Playhead time label
            let timeLabel = String(format: "%.3fs", now)
            ctx.draw(
                Text(timeLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6)),
                at: CGPoint(x: playheadX + 4, y: size.height - 12),
                anchor: .leading
            )

            // 6. Score badges near playhead (latest at top)
            var badgeY: CGFloat = 20
            for badge in vm.recentBadges.reversed().prefix(4) {
                let age = CACurrentMediaTime() - badge.createdAt
                let alpha = max(0, 1.0 - age / 1.5)
                drawScoreBadge(ctx: ctx, classification: badge.classification, x: playheadX + 8, y: badgeY, alpha: alpha)
                badgeY += 18
            }

            // 7. Divider between target and motion (motion lane is separate SwiftUI view)
            var divLine = Path()
            divLine.move(to: CGPoint(x: 0, y: targetH))
            divLine.addLine(to: CGPoint(x: size.width, y: targetH))
            ctx.stroke(divLine, with: .color(Color(white: 0.28)), lineWidth: 1)

        }
    }

    // MARK: Grid drawing

    private func drawGrid(ctx: GraphicsContext, size: CGSize, playheadX: CGFloat, pps: CGFloat, now: Double, loop: Double) {
        let visibleDuration = Double(size.width) / Double(pps)
        let tStart = now - Double(playheadX) / Double(pps)
        let tEnd   = tStart + visibleDuration

        // Minor grid
        let minorStart = (tStart / gridMinorIntervalS).rounded(.down) * gridMinorIntervalS
        var t = minorStart
        while t <= tEnd {
            let isMajor = abs(t.truncatingRemainder(dividingBy: gridMajorIntervalS)) < 0.001
            let x = playheadX + CGFloat(t - now) * pps
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(isMajor ? gridMajor : gridMinor), lineWidth: isMajor ? 0.8 : 0.4)

            if isMajor {
                let beatLabel = String(format: "%.2f", t.truncatingRemainder(dividingBy: loop))
                ctx.draw(
                    Text(beatLabel)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35)),
                    at: CGPoint(x: x + 3, y: size.height - 2),
                    anchor: .bottomLeading
                )
            }
            t += gridMinorIntervalS
        }
    }

    // MARK: Stroke drawing

    private func drawStroke(
        ctx: GraphicsContext,
        stroke: ScratchNotation.Stroke,
        loopOffset: Double,
        now: Double,
        playheadX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let x1 = xFor(stroke.startTime + loopOffset, now: now, playheadX: playheadX, pps: pps)
        let x2 = xFor(stroke.endTime   + loopOffset, now: now, playheadX: playheadX, pps: pps)
        guard x2 >= -40, x1 <= canvasWidth + 40 else { return }

        let isForward = stroke.direction == .forward
        let baseColor = isForward ? forwardColor : backColor

        // Y: forward stroke rises (bottom→top), backward falls (top→bottom)
        let margin = laneRect.height * 0.10
        let yTop    = laneRect.minY + margin
        let yBottom = laneRect.maxY - margin
        let y1 = isForward ? yBottom : yTop
        let y2 = isForward ? yTop    : yBottom

        let isPast = x2 < playheadX
        let alpha: Double = isPast ? 0.25 : 1.0

        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        ctx.stroke(path, with: .color(baseColor.opacity(alpha)), lineWidth: isPast ? 1.5 : 2.5)

        // Boundary dots
        let dotR: CGFloat = isPast ? 3 : 4.5
        let dotAlpha = alpha
        drawDot(ctx: ctx, at: CGPoint(x: x1, y: y1), radius: dotR, color: dotColor.opacity(dotAlpha))
        drawDot(ctx: ctx, at: CGPoint(x: x2, y: y2), radius: dotR, color: dotColor.opacity(dotAlpha))
    }

    private func drawHold(
        ctx: GraphicsContext,
        from stroke: ScratchNotation.Stroke,
        to next: ScratchNotation.Stroke,
        loopOffset: Double,
        now: Double,
        playheadX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let holdStart = stroke.endTime + loopOffset
        let holdEnd   = next.startTime + loopOffset
        guard holdEnd > holdStart else { return }

        let x1 = xFor(holdStart, now: now, playheadX: playheadX, pps: pps)
        let x2 = xFor(holdEnd,   now: now, playheadX: playheadX, pps: pps)
        guard x2 >= -40, x1 <= canvasWidth + 40 else { return }

        let margin = laneRect.height * 0.10
        let yTop    = laneRect.minY + margin
        let yBottom = laneRect.maxY - margin
        // After forward stroke: hold at top; after backward stroke: hold at bottom
        let yHold: CGFloat = stroke.direction == .forward ? yTop : yBottom

        let isPast = x2 < playheadX
        var path = Path()
        path.move(to: CGPoint(x: x1, y: yHold))
        path.addLine(to: CGPoint(x: x2, y: yHold))
        ctx.stroke(path, with: .color(Color(white: 0.30).opacity(isPast ? 0.15 : 0.45)), lineWidth: 1.0)
    }

    private func drawDot(ctx: GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color) {
        let r = radius
        ctx.fill(
            Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
            with: .color(color)
        )
    }

    private func drawLaneLabel(ctx: GraphicsContext, text: String, x: CGFloat, y: CGFloat) {
        ctx.draw(
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.35)),
            at: CGPoint(x: x, y: y),
            anchor: .topLeading
        )
    }

    private func drawScoreBadge(ctx: GraphicsContext, classification: CXLTimingClassification, x: CGFloat, y: CGFloat, alpha: Double) {
        let (label, color): (String, Color) = switch classification {
        case .onTime:         ("ON TIME",   Color(red: 0.2, green: 0.88, blue: 0.55))
        case .early:          ("EARLY",     Color(red: 1.0, green: 0.85, blue: 0.0))
        case .late:           ("LATE",      Color(red: 1.0, green: 0.55, blue: 0.1))
        case .wrongDirection: ("WRONG DIR", Color(red: 1.0, green: 0.25, blue: 0.25))
        case .missed:         ("MISS",      Color(white: 0.45))
        case .idle:           ("",          .clear)
        }
        guard !label.isEmpty else { return }
        ctx.draw(
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(color.opacity(alpha)),
            at: CGPoint(x: x, y: y),
            anchor: .leading
        )
    }

    // MARK: Time → X

    private func xFor(_ t: Double, now: Double, playheadX: CGFloat, pps: CGFloat) -> CGFloat {
        playheadX + CGFloat(t - now) * pps
    }
}

// MARK: - CapturedNotationDisplayView

struct CapturedNotationDisplayView: View {

    let snapshot: CaptureCore.DetectedNotationSnapshot

    private let forwardColor   = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backColor      = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let audioColor     = Color(red: 0.45, green: 0.75, blue: 1.00)
    private let cutColor       = Color(red: 1.00, green: 0.85, blue: 0.00)
    private let gapColor       = Color(white: 0.40)
    private let labelColor     = Color(white: 0.50)

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    sourceHeader
                    if snapshot.recordMovementEvents.isEmpty && snapshot.audioEvents.isEmpty {
                        unavailablePane
                    } else {
                        if !snapshot.audioEvents.isEmpty {
                            audioLane(width: geo.size.width)
                        }
                        if !snapshot.recordMovementEvents.isEmpty {
                            movementLane(width: geo.size.width)
                        } else if !snapshot.audioEvents.isEmpty {
                            partialMessage
                        }
                    }
                }
            }
        }
        .background(Color(white: 0.10))
    }

    private var sourceHeader: some View {
        HStack(spacing: 12) {
            Group {
                switch snapshot.notationSource {
                case "detected":
                    Label("Detected notation", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(forwardColor)
                case "partial":
                    Label("Partial notation — audio only", systemImage: "waveform.path.badge.plus")
                        .foregroundStyle(audioColor)
                default:
                    Label("Notation unavailable", systemImage: "waveform.path.ecg")
                        .foregroundStyle(labelColor)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))

            Spacer()

            if let conf = snapshot.notationConfidence {
                Text("Confidence \(Int((conf * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(labelColor)
            }
            Text(snapshot.detectionSources.joined(separator: " + "))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(white: 0.14))
    }

    private var partialMessage: some View {
        Label(
            "Notation detected from audio — direction pending video/motion confirmation.",
            systemImage: "waveform.path.badge.plus"
        )
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(audioColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var unavailablePane: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 32))
                .foregroundStyle(labelColor)
            Text("Notation unavailable for this take.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func audioLane(width: CGFloat) -> some View {
        let timelineWidth = max(width - 80, 200.0)
        let duration = snapshot.audioEvents.map(\.endTime).max() ?? 1.0
        let scale = timelineWidth / max(duration, 0.001)

        return VStack(alignment: .leading, spacing: 0) {
            laneHeader("AUDIO", count: snapshot.audioEvents.count)
            Canvas { ctx, size in
                for event in snapshot.audioEvents {
                    let x = CGFloat(event.startTime) * scale + 60
                    let w = max(2, CGFloat(event.duration) * scale)
                    let rect = CGRect(x: x, y: size.height * 0.25, width: w, height: size.height * 0.5)
                    let color: Color
                    switch event.eventKind {
                    case "scratchBurst":  color = audioColor
                    case "possibleDrag":  color = forwardColor
                    case "possibleCut":   color = cutColor
                    default:              color = gapColor
                    }
                    ctx.fill(Path(rect), with: .color(color.opacity(0.7 + event.confidence * 0.3)))
                }
                drawTimeAxis(ctx: ctx, size: size, duration: duration, scale: scale)
            }
            .frame(height: 60)
            audioEventList
        }
        .background(Color(white: 0.12))
        .padding(.bottom, 2)
    }

    private func movementLane(width: CGFloat) -> some View {
        let timelineWidth = max(width - 80, 200.0)
        let duration = snapshot.recordMovementEvents.map(\.endTime).max() ?? 1.0
        let scale = timelineWidth / max(duration, 0.001)
        let laneH: CGFloat = 70

        return VStack(alignment: .leading, spacing: 0) {
            laneHeader("RECORD MOVEMENT", count: snapshot.recordMovementEvents.count)
            Canvas { ctx, size in
                let mid = size.height / 2
                let h = size.height * 0.38

                for event in snapshot.recordMovementEvents {
                    let x1 = CGFloat(event.startTime) * scale + 60
                    let x2 = CGFloat(event.endTime) * scale + 60
                    let isForward = event.direction == "forward"
                    let y1: CGFloat = isForward ? mid + h : mid - h
                    let y2: CGFloat = isForward ? mid - h : mid + h
                    let col = isForward ? forwardColor : backColor

                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))
                    ctx.stroke(path, with: .color(col.opacity(0.5 + event.confidence * 0.5)), lineWidth: 2.5)

                    let r: CGFloat = 4
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x1 - r, y: y1 - r, width: r * 2, height: r * 2)),
                        with: .color(Color(white: 0.82))
                    )
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x2 - r, y: y2 - r, width: r * 2, height: r * 2)),
                        with: .color(Color(white: 0.82))
                    )
                }
                drawTimeAxis(ctx: ctx, size: size, duration: duration, scale: scale)
            }
            .frame(height: laneH)
        }
        .background(Color(white: 0.115))
        .padding(.bottom, 2)
    }

    private func laneHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(labelColor)
            Text("\(count) events")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var audioEventList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(snapshot.audioEvents.enumerated()), id: \.offset) { _, event in
                HStack(spacing: 8) {
                    Text(event.eventKind)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(eventKindColor(event.eventKind))
                        .frame(width: 100, alignment: .leading)
                    Text(String(format: "%.3f–%.3f s", event.startTime, event.endTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(labelColor)
                    Text(String(format: "conf %.2f", event.confidence))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func eventKindColor(_ kind: String) -> Color {
        switch kind {
        case "scratchBurst":  return audioColor
        case "possibleDrag":  return forwardColor
        case "possibleCut":   return cutColor
        default:              return gapColor
        }
    }

    private func drawTimeAxis(ctx: GraphicsContext, size: CGSize, duration: Double, scale: CGFloat) {
        let step = tickInterval(for: duration)
        var t = 0.0
        while t <= duration + step {
            let x = CGFloat(t) * scale + 60
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(Color(white: 0.22)), lineWidth: 0.5)
            ctx.draw(
                Text(String(format: "%.2f", t))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(white: 0.30)),
                at: CGPoint(x: x + 2, y: size.height - 2),
                anchor: .bottomLeading
            )
            t += step
        }
    }

    private func tickInterval(for duration: Double) -> Double {
        switch duration {
        case ..<1.0:  return 0.1
        case ..<5.0:  return 0.5
        case ..<15.0: return 1.0
        default:      return 2.0
        }
    }
}
