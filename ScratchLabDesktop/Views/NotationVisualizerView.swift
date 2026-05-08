import SwiftUI
import AppKit
import QuartzCore

// MARK: - Display Mode

enum NotationLabDisplayMode: String, CaseIterable {
    case capturedTake = "Captured Take"
    case templateDemo = "Template Demo"
}

// MARK: - ViewModel

@MainActor
final class NotationVisualizerViewModel: ObservableObject {

    // MARK: Notation data (loaded once)

    let notation: ScratchNotation?
    // Display duration: the notation phrase window. Audio cycles are longer;
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
        ScratchLabPerformanceSignpost.event("CoachPlaybackTick", time: audioTime)
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
    /// True only when user has explicitly picked Template Demo while a snapshot exists.
    /// Starts false so any arriving snapshot immediately shows as Captured Take.
    @State private var showTemplateOverride = false

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(demo: BabyScratchDemoPlaybackCoordinator, capturedSnapshot: CaptureCore.DetectedNotationSnapshot? = nil) {
        _demo = ObservedObject(wrappedValue: demo)
        _vm = StateObject(wrappedValue: NotationVisualizerViewModel(demo: demo))
        self.capturedSnapshot = capturedSnapshot
    }

    /// Captured Take is shown when a snapshot exists AND the user hasn't overridden to template.
    private var showingCaptured: Bool { capturedSnapshot != nil && !showTemplateOverride }

    var body: some View {
        VStack(spacing: 0) {
            notationStatusBar
            if showingCaptured {
                if let snapshot = capturedSnapshot {
                    // Wrap the captured timeline in a vertically-scrollable
                    // container with sane horizontal margins so strokes don't
                    // explode on tall windows and the timeline always has
                    // room to breathe.
                    ScrollView(.vertical) {
                        CapturedNotationDisplayView(snapshot: snapshot)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 360)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noCapturedTakePane
                }
            } else {
                ScratchNotationCanvasView(
                    notation: vm.notation,
                    playbackTime: vm.playbackTime,
                    loopDuration: vm.loopDuration
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 220, maxHeight: 480)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                notationMotionLane
                    .padding(.horizontal, 18)
                Spacer(minLength: 0)
                notationTransportBar
            }
        }
        .background(Color(white: 0.10))
        .onAppear {
            if !showingCaptured {
                demo.configureBabyScratchIfNeeded()
            }
        }
        .onReceive(ticker) { _ in
            guard !showingCaptured else { return }
            vm.tick(captureEngine: captureEngine)
        }
        .onChange(of: captureEngine.handMotionState) { _, newState in
            guard !showingCaptured else { return }
            guard vm.isPlaying || captureEngine.cxlIsRecording else { return }
            vm.recordObservedMotion(newState, loopTime: vm.playbackTime)
        }
        .onChange(of: capturedSnapshot == nil) { _, isNil in
            if !isNil {
                // A snapshot just arrived — reset override so Captured Take is shown.
                showTemplateOverride = false
            }
        }
        .onChange(of: showTemplateOverride) { _, prefersTemplate in
            if prefersTemplate {
                demo.configureBabyScratchIfNeeded()
            }
        }
        .onDisappear {
            vm.pause()
        }
    }

    private var noCapturedTakePane: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No captured take selected.")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text("Record a take in Capture or open a saved take from Review.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status bar

    private var notationStatusBar: some View {
        HStack(spacing: 16) {
            ScratchLabBrandMark(size: 22)

            if capturedSnapshot != nil {
                Picker("Mode", selection: Binding<NotationLabDisplayMode>(
                    get: { showingCaptured ? .capturedTake : .templateDemo },
                    set: { showTemplateOverride = ($0 == .templateDemo) }
                )) {
                    ForEach(NotationLabDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            } else {
                Text("Notation Lab")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 0)

            if showingCaptured, let snapshot = capturedSnapshot {
                labelChip(
                    snapshot.notationSource == "detected" ? "Detected"
                        : snapshot.notationSource == "partial" ? "Partial"
                        : "Unavailable",
                    color: snapshot.notationSource == "detected"
                        ? Color(red: 0.2, green: 0.85, blue: 0.55)
                        : snapshot.notationSource == "partial"
                            ? Color(red: 1.0, green: 0.75, blue: 0.0)
                            : Color(white: 0.40)
                )
                if !snapshot.detectionSources.isEmpty {
                    labelChip(
                        snapshot.detectionSources.joined(separator: " + "),
                        color: Color(white: 0.45)
                    )
                }
                if let confidence = snapshot.notationConfidence {
                    labelChip(
                        "Confidence \(Int((confidence * 100).rounded()))%",
                        color: Color(white: 0.45)
                    )
                }
            } else {
                labelChip(
                    "Baby Scratch Template",
                    color: Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.75)
                )
                labelChip(
                    "Phrase \(String(format: "%.3f", vm.loopDuration))s",
                    color: Color(white: 0.45)
                )
                labelChip(
                    demo.isAudioAvailable ? "Audio ready" : "Audio missing",
                    color: demo.isAudioAvailable ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color(red: 1.0, green: 0.45, blue: 0.25)
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
                    captureEngine.cxlIsRecording ? "Recording" : "Idle",
                    color: captureEngine.cxlIsRecording ? Color(red: 1.0, green: 0.25, blue: 0.25) : Color(white: 0.35)
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
        case .steady:      ("— Steady",    Color(white: 0.62))
        case .searching:   ("⊘ Searching", Color(white: 0.55))
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

            // Capture controls
            HStack(spacing: 8) {
                if captureEngine.cxlIsRecording {
                    Button("Stop Recording") {
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
                    Button("Start Recording") {
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(count > 0 ? color : .secondary)
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
        ScratchLabPerformanceSignpost.event("TargetNotationRender")
        return Canvas { ctx, size in
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
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.55)),
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

    // Palette
    private let forwardColor = Color(red: 0.25, green: 0.88, blue: 0.55)
    private let backColor    = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let audioColor   = Color(red: 0.55, green: 0.75, blue: 1.00)
    private let cutColor     = Color(red: 1.00, green: 0.72, blue: 0.10)
    private let faderColor   = Color(red: 1.00, green: 0.50, blue: 0.20)
    private let gapColor     = Color(white: 0.38)
    private let labelColor   = Color(white: 0.52)

    private var hasMovementEvents: Bool { !snapshot.recordMovementEvents.isEmpty }
    private var hasAudioEvents: Bool { !snapshot.audioEvents.isEmpty }
    private var hasFaderEvents: Bool { !snapshot.faderEvents.isEmpty }
    private var isAudioOnlyPartial: Bool {
        snapshot.notationSource == "partial" && !hasMovementEvents && hasAudioEvents
    }
    private var visibleDetectionSources: [String] {
        snapshot.detectionSources.filter { source in
            let lowercased = source.lowercased()
            return !lowercased.contains("baby_nobeat")
                && !lowercased.contains("baby_nobeat.wav")
                && !lowercased.contains("baby_no beat")
                && !lowercased.contains("baby scratch template")
        }
    }

    // Shared timeline scale — recomputed once from the widest lane
    private var totalDuration: Double {
        let movEnd = snapshot.recordMovementEvents.map(\.endTime).max() ?? 0
        let audEnd = snapshot.audioEvents.map(\.endTime).max() ?? 0
        let fadEnd = snapshot.faderEvents.map(\.endTime).max() ?? 0
        return max(movEnd, audEnd, fadEnd, 1.0)
    }

    var body: some View {
        ScratchLabPerformanceSignpost.event(
            "CapturedNotationRender",
            count: snapshot.recordMovementEvents.count
        )
        return GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    summaryHeader
                    if !snapshot.hasDetectedEvents {
                        unavailablePane
                    } else {
                        beatGridRuler(width: geo.size.width)
                        if hasMovementEvents {
                            movementLane(width: geo.size.width)
                        } else if hasAudioEvents {
                            audioInferredNotationLane(width: geo.size.width)
                        } else {
                            partialMovementPlaceholder
                        }
                        if hasAudioEvents {
                            audioLane(width: geo.size.width)
                        }
                        faderLane(width: geo.size.width)
                        notationLegend
                    }
                }
                .padding(14)
            }
        }
        .background(Color(white: 0.095))
    }

    // MARK: Summary header

    private var summaryHeader: some View {
        let isDetected     = snapshot.notationSource == "detected"
        let isPartial      = snapshot.notationSource == "partial"
        let hasMovementOnly  = !isDetected && !isPartial && hasMovementEvents
        let hasAudioOnly     = !isDetected && !isPartial && !hasMovementEvents && hasAudioEvents
        let sourceLabel: String = {
            if isDetected            { return "Detected notation" }
            if isAudioOnlyPartial    { return "Audio-only take" }
            if isPartial             { return "Partial notation" }
            if hasMovementOnly       { return "Movement recorded" }
            if hasAudioOnly          { return "Audio-inferred" }
            return "Unavailable"
        }()
        let sourceColor: Color = isDetected ? forwardColor
            : (isPartial || hasMovementOnly) ? cutColor
            : hasAudioOnly ? Color(red: 1.00, green: 0.72, blue: 0.10)
            : labelColor
        let sourceIcon: String = {
            if isDetected         { return "checkmark.seal.fill" }
            if isPartial          { return "waveform.path.badge.plus" }
            if hasMovementOnly    { return "figure.wave" }
            if hasAudioOnly       { return "ear.and.waveform" }
            return "waveform.path.ecg"
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Label(sourceLabel, systemImage: sourceIcon)
                    .font(.system(size: (isAudioOnlyPartial || hasAudioOnly) ? 15 : 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(sourceColor)

                Spacer(minLength: 0)

                if let conf = snapshot.notationConfidence {
                    headerChip("\(Int((conf * 100).rounded()))% confidence", color: labelColor)
                }
                if !visibleDetectionSources.isEmpty {
                    headerChip(visibleDetectionSources.joined(separator: " + "), color: labelColor)
                }
                if hasFaderEvents {
                    headerChip("MIDI fader", color: faderColor)
                }
            }

            if isAudioOnlyPartial {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hand motion wasn't detected — review timing only.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("No record movement detected.")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(labelColor)
                }
            } else if hasAudioOnly {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio activity detected. Direction wasn't confirmed visually — these are estimates from sound.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Audio inferred")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(labelColor)
                }
            }

            HStack(spacing: 8) {
                summaryCountChip("Record movement \(snapshot.recordMovementEvents.count)", color: hasMovementEvents ? forwardColor : labelColor)
                summaryCountChip("Audio \(snapshot.audioEvents.count)", color: hasAudioEvents ? audioColor : labelColor)
                summaryCountChip("Fader \(snapshot.faderEvents.count)", color: hasFaderEvents ? faderColor : labelColor)
                summaryCountChip("Mixer MIDI \(snapshot.mixerMidiEvents.count)", color: snapshot.mixerMidiEvents.isEmpty ? labelColor : cutColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, (isAudioOnlyPartial || hasAudioOnly) ? 16 : 11)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.bottom, 8)
    }

    // MARK: Beat grid / time ruler

    private func beatGridRuler(width: CGFloat) -> some View {
        let laneWidth = max(width - 56, 200.0)
        let duration = totalDuration
        let scale = CGFloat(laneWidth) / CGFloat(duration)
        let step = gridTickInterval(for: duration)

        return ZStack(alignment: .topLeading) {
            Color(white: 0.115)
            Canvas { ctx, size in
                let labelX: CGFloat = 56
                var t = 0.0
                while t <= duration + step * 0.5 {
                    let x = labelX + CGFloat(t) * scale
                    let isMajor = t.truncatingRemainder(dividingBy: step * 2).magnitude < step * 0.05
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: isMajor ? 0 : size.height * 0.55))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(line,
                               with: .color(Color(white: isMajor ? (isAudioOnlyPartial ? 0.42 : 0.30) : (isAudioOnlyPartial ? 0.28 : 0.20))),
                               lineWidth: isMajor ? (isAudioOnlyPartial ? 1.4 : 1.0) : (isAudioOnlyPartial ? 0.85 : 0.5))
                    if isMajor {
                        ctx.draw(
                            Text(String(format: "%.1fs", t))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color(white: 0.42)),
                            at: CGPoint(x: x + 3, y: 3),
                            anchor: .topLeading
                        )
                    }
                    t += step
                }
                // Lane label
                ctx.draw(
                    Text("TIME")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(white: 0.55)),
                    at: CGPoint(x: 6, y: size.height / 2),
                    anchor: .leading
                )
            }
        }
        .frame(height: isAudioOnlyPartial ? 34 : 24)
        .background(Color(white: 0.115), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 6)
    }

    // MARK: Record movement lane

    private func movementLane(width: CGFloat) -> some View {
        let laneWidth = max(width - 56, 200.0)
        let duration = totalDuration
        let scale = CGFloat(laneWidth) / CGFloat(duration)
        let laneH: CGFloat = 96

        return VStack(alignment: .leading, spacing: 0) {
            laneHeader("RECORD", icon: "arrow.left.arrow.right")
            Canvas { ctx, size in
                let labelX: CGFloat = 56
                let mid = size.height / 2

                // Mid baseline
                var baseline = Path()
                baseline.move(to: CGPoint(x: labelX, y: mid))
                baseline.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(baseline, with: .color(Color(white: 0.22)), lineWidth: 0.5)

                drawSharedGrid(ctx: ctx, size: size, duration: duration, scale: scale, labelX: labelX)

                for event in snapshot.recordMovementEvents {
                    let x1 = labelX + CGFloat(event.startTime) * scale
                    let x2 = labelX + CGFloat(event.endTime) * scale
                    let isForward = event.direction == "forward"
                    let heightFrac = movementHeightFraction(kind: event.movementKind)
                    let h = (size.height * 0.44) * CGFloat(heightFrac)

                    // Forward = rises (bottom to top); backward = falls (top to bottom)
                    let y1: CGFloat = isForward ? mid + h : mid - h
                    let y2: CGFloat = isForward ? mid - h : mid + h
                    let col = isForward ? forwardColor : backColor

                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))
                    ctx.stroke(path,
                               with: .color(col.opacity(0.55 + event.confidence * 0.45)),
                               lineWidth: 2.5)

                    let r: CGFloat = 4
                    ctx.fill(Path(ellipseIn: CGRect(x: x1 - r, y: y1 - r, width: r * 2, height: r * 2)),
                             with: .color(Color(white: 0.82)))
                    ctx.fill(Path(ellipseIn: CGRect(x: x2 - r, y: y2 - r, width: r * 2, height: r * 2)),
                             with: .color(Color(white: 0.82)))
                }

                // Forward / Back axis labels
                ctx.draw(
                    Text("FWD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(forwardColor.opacity(0.55)),
                    at: CGPoint(x: 4, y: mid - size.height * 0.38),
                    anchor: .leading
                )
                ctx.draw(
                    Text("BACK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(backColor.opacity(0.55)),
                    at: CGPoint(x: 4, y: mid + size.height * 0.30),
                    anchor: .leading
                )
            }
            .frame(height: laneH)
        }
        .background(Color(white: 0.108))
        .padding(.bottom, 1)
    }

    // MARK: Audio-inferred notation lane
    // Shown when audioEvents exist but no movementEvents are available.
    // Renders onset markers (amber ticks) — does NOT assign F/B direction.
    // Clearly labelled as estimated/audio-inferred, not ground-truth movement.

    private func audioInferredNotationLane(width: CGFloat) -> some View {
        let laneWidth = max(width - 56, 200.0)
        let duration = totalDuration
        let scale = CGFloat(laneWidth) / CGFloat(duration)
        let laneH: CGFloat = 88
        let inferredColor = Color(red: 1.00, green: 0.72, blue: 0.10)

        return VStack(alignment: .leading, spacing: 0) {
            laneHeader("AUDIO INFERRED", icon: "ear.and.waveform")
            Canvas { ctx, size in
                let labelX: CGFloat = 56
                let mid = size.height / 2

                drawSharedGrid(ctx: ctx, size: size, duration: duration, scale: scale, labelX: labelX)

                // Baseline
                var baseline = Path()
                baseline.move(to: CGPoint(x: labelX, y: mid))
                baseline.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(baseline, with: .color(Color(white: 0.22)), lineWidth: 0.5)

                // Onset tick marks — amber vertical bars, height scaled by confidence
                for event in snapshot.audioEvents {
                    let x = labelX + CGFloat(event.startTime) * scale
                    let barH = size.height * 0.38 * CGFloat(0.5 + event.confidence * 0.5)
                    let top    = mid - barH
                    let bottom = mid + barH

                    var bar = Path()
                    bar.move(to: CGPoint(x: x, y: top))
                    bar.addLine(to: CGPoint(x: x, y: bottom))
                    ctx.stroke(bar,
                               with: .color(inferredColor.opacity(0.55 + event.confidence * 0.35)),
                               style: StrokeStyle(lineWidth: 3, dash: [4, 3]))

                    // Dot at peak
                    let r: CGFloat = 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: top - r, width: r * 2, height: r * 2)),
                             with: .color(inferredColor.opacity(0.75)))
                }

                // Disclaimer label at right
                ctx.draw(
                    Text("estimated")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(inferredColor.opacity(0.45)),
                    at: CGPoint(x: size.width - 4, y: size.height - 4),
                    anchor: .bottomTrailing
                )
            }
            .frame(height: laneH)
        }
        .background(Color(white: 0.108))
        .padding(.bottom, 1)
    }

    // Slope height: faster = steeper
    private func movementHeightFraction(kind: ScratchMovementKind) -> Double {
        switch kind {
        case .fastPush, .fastPull:         return 0.90
        case .normalPush, .normalPull:     return 0.62
        case .slowDrag, .slowPullDrag:     return 0.38
        case .releaseNormalPlayback:       return 0.20
        default:                           return 0.55
        }
    }

    // MARK: Partial placeholder when no movement events

    private var partialMovementPlaceholder: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path.badge.plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(audioColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Audio-only take")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("No record movement detected.")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(audioColor)
                Text("Hand motion wasn't detected — review timing only.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(labelColor)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(Color(white: 0.108), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 8)
    }

    // MARK: Audio event lane

    private func audioLane(width: CGFloat) -> some View {
        let laneWidth = max(width - 56, 200.0)
        let duration = totalDuration
        let scale = CGFloat(laneWidth) / CGFloat(duration)
        let laneHeight: CGFloat = isAudioOnlyPartial ? 108 : 56

        return VStack(alignment: .leading, spacing: 0) {
            laneHeader("AUDIO", icon: "waveform")
            Canvas { ctx, size in
                let labelX: CGFloat = 56
                drawSharedGrid(ctx: ctx, size: size, duration: duration, scale: scale, labelX: labelX)

                for event in snapshot.audioEvents {
                    let x = labelX + CGFloat(event.startTime) * scale
                    let w = max(isAudioOnlyPartial ? 16 : 6, CGFloat(event.duration) * scale)
                    let color = audioEventColor(event.eventKind)
                    let blockH = size.height * (isAudioOnlyPartial ? 0.72 : 0.58) * CGFloat(0.68 + event.confidence * 0.32)
                    let blockY = (size.height - blockH) / 2

                    // Rounded block
                    let rect = CGRect(x: x, y: blockY, width: w, height: blockH)
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: isAudioOnlyPartial ? 8 : 4),
                        with: .color(color.opacity(0.55 + event.confidence * 0.35))
                    )

                    // Kind label inside wide-enough blocks
                    if w > (isAudioOnlyPartial ? 44 : 32) {
                        let shortLabel = audioEventShortLabel(event.eventKind)
                        ctx.draw(
                            Text(shortLabel)
                                .font(.system(size: isAudioOnlyPartial ? 10 : 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.65)),
                            at: CGPoint(x: x + (isAudioOnlyPartial ? 8 : 3), y: size.height / 2),
                            anchor: .leading
                        )
                    }
                }
            }
            .frame(height: laneHeight)
        }
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 8)
    }

    private func audioEventColor(_ kind: String) -> Color {
        switch kind {
        case "scratchBurst": return audioColor
        case "possibleDrag": return forwardColor
        case "possibleCut":  return cutColor
        default:             return gapColor
        }
    }

    private func audioEventShortLabel(_ kind: String) -> String {
        switch kind {
        case "scratchBurst": return "SCRATCH"
        case "possibleDrag": return "DRAG"
        case "possibleCut":  return "CUT"
        default:             return kind
        }
    }

    // MARK: Fader lane

    private func faderLane(width: CGFloat) -> some View {
        let laneWidth = max(width - 56, 200.0)
        let duration = totalDuration
        let scale = CGFloat(laneWidth) / CGFloat(duration)

        if snapshot.faderEvents.isEmpty {
            return AnyView(
                HStack(spacing: 8) {
                    laneHeader("FADER", icon: "slider.horizontal.3")
                    Text("No fader data captured.")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(Color(white: 0.095), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                laneHeader("FADER", icon: "slider.horizontal.3")
                Canvas { ctx, size in
                    let labelX: CGFloat = 56
                    let top    = size.height * 0.12
                    let bottom = size.height * 0.88
                    let mid    = size.height / 2

                    // Baseline
                    var base = Path()
                    base.move(to: CGPoint(x: labelX, y: mid))
                    base.addLine(to: CGPoint(x: size.width, y: mid))
                    ctx.stroke(base, with: .color(Color(white: 0.22)), lineWidth: 0.5)

                    drawSharedGrid(ctx: ctx, size: size, duration: duration, scale: scale, labelX: labelX)

                    for event in snapshot.faderEvents {
                        let x1 = labelX + CGFloat(event.startTime) * scale
                        let x2 = labelX + CGFloat(event.endTime) * scale
                        let y1 = bottom - CGFloat(event.fromValue) * (bottom - top)
                        let y2 = bottom - CGFloat(event.toValue) * (bottom - top)
                        let col = faderEventColor(event.eventKind)

                        var path = Path()
                        path.move(to: CGPoint(x: x1, y: y1))
                        path.addLine(to: CGPoint(x: x2, y: y2))
                        ctx.stroke(path,
                                   with: .color(col.opacity(0.50 + event.confidence * 0.50)),
                                   lineWidth: 2.5)

                        if event.eventKind == .pulse || event.eventKind == .transformPulse {
                            let mx = (x1 + x2) / 2
                            var marker = Path()
                            marker.move(to: CGPoint(x: mx, y: top))
                            marker.addLine(to: CGPoint(x: mx, y: bottom))
                            ctx.stroke(marker,
                                       with: .color(col.opacity(0.60)),
                                       lineWidth: event.eventKind == .transformPulse ? 2.0 : 1.2)
                        }

                        let r: CGFloat = 3.5
                        ctx.fill(Path(ellipseIn: CGRect(x: x1 - r, y: y1 - r, width: r * 2, height: r * 2)),
                                 with: .color(Color(white: 0.82)))
                        ctx.fill(Path(ellipseIn: CGRect(x: x2 - r, y: y2 - r, width: r * 2, height: r * 2)),
                                 with: .color(Color(white: 0.82)))
                    }
                }
                .frame(height: 64)
            }
            .background(Color(white: 0.096), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 8)
        )
    }

    private func faderEventColor(_ kind: ScratchFaderEventKind) -> Color {
        switch kind {
        case .cut:            return cutColor
        case .pulse:          return faderColor
        case .transformPulse: return backColor
        case .open:           return forwardColor
        case .closed:         return Color(red: 1.0, green: 0.25, blue: 0.25)
        case .flareClick:     return Color(red: 0.75, green: 0.45, blue: 1.00)
        case .unknown:        return gapColor
        }
    }

    // MARK: Legend

    private var notationLegend: some View {
        // Each legend item carries a non-colour cue: a slope glyph + letter
        // ("↗ F" / "↘ B") for directional strokes, an SF Symbol for
        // non-directional events. A colour-blind user can still tell
        // Forward from Back by the arrow and the F/B letter, which match
        // the chart's per-stroke labels in ScratchPhraseChartView.
        // ViewThatFits picks the single-row layout when the panel is wide
        // enough; on narrow stage widths it falls back to two rows so the
        // legend never clips or shrinks below 10pt.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                legendItem(color: forwardColor,                            label: "Forward",       glyph: "↗ F")
                legendItem(color: backColor,                               label: "Back",          glyph: "↘ B")
                legendItem(color: ScratchLabDesign.Notation.audioInferred, label: "Audio inferred", systemImage: "ear.and.waveform")
                legendItem(color: audioColor,                              label: "Scratch burst",  systemImage: "waveform")
                legendItem(color: cutColor,                                label: "Drag / cut",     systemImage: "scissors")
                legendItem(color: faderColor,                              label: "Fader",          systemImage: "slider.horizontal.3")
                legendItem(color: gapColor,                                label: "Silence",        systemImage: "pause")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    legendItem(color: forwardColor,                            label: "Forward",       glyph: "↗ F")
                    legendItem(color: backColor,                               label: "Back",          glyph: "↘ B")
                    legendItem(color: ScratchLabDesign.Notation.audioInferred, label: "Audio inferred", systemImage: "ear.and.waveform")
                    legendItem(color: audioColor,                              label: "Scratch burst",  systemImage: "waveform")
                }
                HStack(spacing: 14) {
                    legendItem(color: cutColor,                                label: "Drag / cut",     systemImage: "scissors")
                    legendItem(color: faderColor,                              label: "Fader",          systemImage: "slider.horizontal.3")
                    legendItem(color: gapColor,                                label: "Silence",        systemImage: "pause")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func legendItem(color: Color, label: String, glyph: String? = nil, systemImage: String? = nil) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 16, height: 6)
            if let glyph {
                Text(glyph)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(labelColor)
        }
    }

    // MARK: Unavailable

    private var unavailablePane: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30))
                .foregroundStyle(labelColor)
            Text("No notation detected for this take.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    // MARK: Helpers

    private func laneHeader(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
    }

    private func headerChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 4))
    }

    private func summaryCountChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // Shared vertical grid lines across all lanes (keeps lanes visually aligned)
    private func drawSharedGrid(
        ctx: GraphicsContext,
        size: CGSize,
        duration: Double,
        scale: CGFloat,
        labelX: CGFloat
    ) {
        let step = gridTickInterval(for: duration)
        var t = step
        while t <= duration + step * 0.5 {
            let x = labelX + CGFloat(t) * scale
            let isMajor = t.truncatingRemainder(dividingBy: step * 2).magnitude < step * 0.05
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line,
                       with: .color(Color(white: isMajor ? (isAudioOnlyPartial ? 0.34 : 0.22) : (isAudioOnlyPartial ? 0.24 : 0.155))),
                       lineWidth: isMajor ? (isAudioOnlyPartial ? 1.0 : 0.7) : (isAudioOnlyPartial ? 0.65 : 0.35))
            t += step
        }
    }

    private func gridTickInterval(for duration: Double) -> Double {
        switch duration {
        case ..<1.0:   return 0.10
        case ..<3.0:   return 0.25
        case ..<8.0:   return 0.50
        case ..<20.0:  return 1.0
        default:       return 2.0
        }
    }
}
