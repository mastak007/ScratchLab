// ReferenceAuthoringView.swift
// ScratchLabDesktop

import Combine
import SwiftUI

struct ReferenceAuthoringView: View {
    @StateObject private var viewModel: ReferenceAuthoringViewModel
    /// Held for the two live surfaces this screen renders: the camera preview
    /// (`captureSession`) and the live-notation tracker's data source. Neither
    /// starts, stops, or configures capture from here.
    private let captureEngine: MacCaptureEngine

    /// Live performed-notation tracker for whatever the notation lane is
    /// currently showing, or `nil` when the route is not active. A FRESH
    /// instance per mode change is the reset — the same ownership rule
    /// Capture uses — so neither a prior take nor the pre-record preview that
    /// preceded a take can leak into it.
    @State private var liveNotationTracker: LivePerformedNotationTracker?
    /// What `liveNotationTracker` is currently showing. Held so the lifecycle
    /// point below is idempotent: repeated syncs to the mode already running
    /// must not rebuild the tracker and throw away the trace on screen.
    @State private var liveNotationMode: LiveNotationMode = .off
    /// Last window-release count this route has acted on.
    ///
    /// A `Published` publisher replays its current value to each new
    /// subscriber, so the first delivery after `.onReceive` subscribes is the
    /// standing count, not a new release. Recording it here and acting only on
    /// a CHANGE is what makes one real release produce exactly one re-arm, and
    /// a replayed or duplicated value produce none.
    @State private var lastHandledMIDIWindowReleaseCount: Int?
    @State private var isShowingMIDIAddressDiagnostics = false
    /// Framing panel starts open — it is the thing being watched during a
    /// take — and can be folded away while configuring.
    @State private var isShowingFramingPanel = true
    /// The single tear candidate whose edit controls are expanded. At most
    /// one is ever expanded, and none by default, so a noisy take never
    /// renders dozens of open cards.
    @State private var selectedTearCandidateID: String?
    /// Which review groups are open. `nil` until the first review is shown, so
    /// the default set can be derived from that review's own groups.
    @State private var expandedTearGroupIDs: Set<String>?
    /// The EXISTING session-archive pipeline, reused verbatim for the raw
    /// diagnostic export. This screen adds no second archive format.
    @StateObject private var exportCoordinator = SessionExportCoordinator()

    /// What the live-notation lane is showing.
    ///
    /// Reference Authoring must show real platter movement BEFORE Record: it
    /// is the only place the operator can confirm the controller is actually
    /// reaching the app, and a lane that stays blank until Record cannot tell
    /// "rig is ready" apart from "no MIDI is arriving at all". `.preview` is
    /// that pre-record surface and `.take` is the in-take one.
    ///
    /// They are separate modes, not one long-lived tracker, because the mode
    /// change is the re-anchor: the take's trace must start at the take, and
    /// the preview must never be mistaken for it.
    enum LiveNotationMode: Equatable {
        /// Route inactive. No tracker, no preview accumulation.
        case off
        /// On the route, not recording. Presentation only.
        case preview
        /// A take is running. The take owns the MIDI window.
        case take
    }

    /// Minimum height the live-notation card is guaranteed.
    ///
    /// `ScratchPhraseChartView` derives its whole lane geometry from
    /// `size.height` (`laneHeight = size.height - strokeRegionTop`), so the
    /// card's height IS the vertical scale of the drawn stroke. In this screen
    /// the card sits inside a vertically-unbounded `ScrollView`, where
    /// `maxHeight: .infinity` resolves to the view's IDEAL height rather than
    /// filling anything — so it collapsed to roughly 20 pt. On take-004 the
    /// data path was healthy (`span 0.157`, 54 committed moves, `age 0.0s`)
    /// and that 15.7% of travel still drew only ~3 px, which reads as flat.
    /// Capture does not hit this because its copy of the card lives in a
    /// BOUNDED `ZStack` over the camera.
    ///
    /// 180 pt sits with the established single-lane phrase-chart heights in
    /// this codebase (118 / 120 / 150 / 160 / 190) once the card's own header
    /// row is accounted for, and well below the 320 pt minimum the STACKED
    /// target-plus-performance comparison uses — this is one performed lane,
    /// not a comparison. The renderer's y-scale is untouched; it simply gets a
    /// real box to draw in.
    private static let liveNotationMinimumHeight: CGFloat = 180

    /// Ceiling for the camera preview so the two panels coexist at the
    /// smallest supported window without the 16:9 preview claiming the whole
    /// scroll content and pushing notation off-screen. Framing stays a
    /// separate, clearly visible panel — notation is never overlaid on it.
    private static let cameraPreviewMaximumHeight: CGFloat = 360

    /// Drawing height for the canonical tear chart's lane.
    ///
    /// Sits just under `liveNotationMinimumHeight` so the chart's own header
    /// and reason rows fit inside the 180 pt box its call sites reserve,
    /// without the lane itself ever asking for unbounded height.
    private static let canonicalTearChartMinimumHeight: CGFloat = 140

    init(
        engine: MacCaptureEngine,
        companionReceiver: CompanionCameraReceiver?,
        operatorName: String
    ) {
        self.captureEngine = engine
        _viewModel = StateObject(
            wrappedValue: ReferenceAuthoringViewModel(
                engine: engine,
                companionReceiver: companionReceiver,
                operatorName: operatorName
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CXL Reference Authoring")
                    .font(.title2.weight(.semibold))
                Text("Record a diagnostic draft, review four repetitions, and explicitly approve one canonical draft. Approval does not install or publish training data.")
                    .foregroundStyle(.secondary)

                messagePanel
                setupSection
                calibrationSection
                preflightSection
                recordingSection
                // Directly under the Record controls on purpose: while a take
                // is running this is the only thing the operator watches, and
                // at the top of the page it sat off-screen behind a scroll.
                // Collapsible so it can be folded away during setup.
                framingSection
                reviewSection
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .task {
            activateCaptureInput()
            viewModel.refreshAutofilledPatternIdentity()
            viewModel.startPreflightPolling()
            // Reuse an exactly-matching saved calibration rather than asking
            // for another sweep every time this screen opens.
            viewModel.adoptPersistedCalibrationIfAvailable()
            // Entry and re-entry both have to resolve the mode explicitly.
            // `onChange` only fires on a transition and `@State` is reset by
            // the fresh view, so without this the lane would stay blank both
            // before Record and for the rest of a take the operator stepped
            // away from.
            syncLiveNotationTracker(mode: resolvedLiveNotationMode)
        }
        .onChange(of: viewModel.selectedTechnique) { _, _ in
            viewModel.refreshAutofilledPatternIdentity()
        }
        .onChange(of: viewModel.phraseBars) { _, _ in
            viewModel.refreshAutofilledPatternIdentity()
        }
        // Changing the deck or the open end changes WHICH stored calibration
        // is the exact match, so retry adoption rather than making the
        // operator press Apply Setup again to discover it.
        .onChange(of: viewModel.activeDeckRawValue) { _, _ in
            viewModel.adoptPersistedCalibrationIfAvailable()
        }
        .onChange(of: viewModel.crossfaderOpenEndRawValue) { _, _ in
            viewModel.adoptPersistedCalibrationIfAvailable()
        }
        .onChange(of: viewModel.session.phase == .recording) { _, _ in
            syncLiveNotationTracker(mode: resolvedLiveNotationMode)
        }
        // A stopped take is not a finished one. It keeps ownership of the
        // engine's MIDI accumulation window until that window is RELEASED —
        // by the finalization drain, or by an abandonment release on a path
        // that never drains, and in both cases only for the take that actually
        // owns it. Until then `beginLiveMIDICapture()` fails closed, so the
        // preview must re-arm on the release itself. Observing the release
        // counter rather than `isRoutineFinalizationPending` is what covers
        // the early-return finalization paths, which never set that flag and
        // so never publish a transition to observe; without this the lane
        // would stay blank for the rest of the session after take 1.
        //
        // `onReceive` on the engine's own publisher, NOT `onChange` of a
        // property: `captureEngine` is a plain `let`, not an `@ObservedObject`
        // or `@StateObject`, so this view is not a subscriber to its
        // `objectWillChange` and reading a property in `onChange` would
        // establish no observation at all — the handler would simply never
        // run. Engine ownership is deliberately unchanged; only the
        // observation boundary is made explicit.
        .onReceive(captureEngine.$midiCaptureWindowReleaseCount) { releaseCount in
            Self.handleMIDIWindowRelease(
                releaseCount,
                lastHandled: &lastHandledMIDIWindowReleaseCount,
                mode: liveNotationMode,
                captureEngine: captureEngine
            )
        }
        .onDisappear {
            viewModel.cancelTransientWorkForViewDisappearance()
            // The tracker owns a repeating timer; dropping it here is what
            // stops that timer when the screen goes away. It closes only the
            // preview accumulation window this route opened — the camera
            // session, engine ownership and any in-flight, stopped or
            // finalizing take are left alone, because
            // `endLiveMIDICaptureIfIdle()` acts only while the PREVIEW owns
            // the MIDI window, decided under the engine's own lock.
            syncLiveNotationTracker(mode: .off)
        }
    }

    /// Entry and restoration both need live authoring input, regardless of
    /// the global live-input preference. The engine owns the idempotent start
    /// guard, so recreating this view cannot start a second session. Leaving
    /// this route does not own stopping the shared engine.
    @MainActor
    func activateCaptureInput() {
        captureEngine.start()
    }

    /// Which mode the lane should be in right now.
    ///
    /// Keyed on the authoring session's own `.recording` phase rather than on
    /// `engine.isRoutineRecording`, which turns true earlier in the start
    /// sequence. The phase only becomes `.recording` after the bridge has
    /// confirmed the engine genuinely started, so a pre-record preview can
    /// never be relabelled as motion belonging to a take that has not begun.
    private var resolvedLiveNotationMode: LiveNotationMode {
        viewModel.session.phase == .recording ? .take : .preview
    }

    /// The ONE place the live-notation tracker is created or dropped.
    ///
    /// A fresh instance per MODE CHANGE is the reset — the same ownership rule
    /// Capture uses (`MacAnalyzerView.captureLiveNotationTracker`) — so no
    /// evidence from a prior take, a rejected take, a retake, or the
    /// pre-record preview can leak into the next thing shown. Crossing into
    /// `.take` therefore rebuilds the tracker rather than keeping the preview
    /// one, which is what re-anchors the trace to the take's own start.
    /// Dropping the instance cancels its poll timer through `deinit`.
    ///
    /// Capture ownership is untouched throughout: nothing here starts, stops
    /// or configures the session, the camera, or recording. The only engine
    /// state this touches is the MIDI accumulation window, and only through
    /// the two accessors that act solely while the preview owns that window.
    private func syncLiveNotationTracker(mode: LiveNotationMode) {
        Self.syncLiveNotationTracker(
            mode: mode,
            liveNotationMode: &liveNotationMode,
            liveNotationTracker: &liveNotationTracker,
            captureEngine: captureEngine
        )
    }

    // Uses the view's existing state directly. Tests exercise the same
    // transition and tracker construction; there is no second lifecycle.
    static func syncLiveNotationTracker(
        mode: LiveNotationMode,
        liveNotationMode: inout LiveNotationMode,
        liveNotationTracker: inout LivePerformedNotationTracker?,
        captureEngine: MacCaptureEngine
    ) {
        guard mode != liveNotationMode else { return }
        liveNotationMode = mode
        switch mode {
        case .off:
            liveNotationTracker = nil
            captureEngine.endLiveMIDICaptureIfIdle()
        case .preview, .take:
            if mode == .preview {
                // Only the pre-record preview needs a window opened. A take
                // arms and owns its own at media start, and opening one here
                // would be refused anyway while recording.
                captureEngine.beginLiveMIDICapture()
            }
            liveNotationTracker = LivePerformedNotationTracker(
                dataSource: captureEngine.makeLivePerformedNotationDataSource()
            )
        }
    }

    /// Re-opens the pre-record preview window once a take has released the
    /// MIDI accumulation window. No-op in any other mode, and it never builds
    /// a tracker — `.preview` already has one. `beginLiveMIDICapture()` is
    /// itself idempotent and claims the window only from `.idle`, so an
    /// early or repeated call is harmless.
    @discardableResult
    static func handleMIDIWindowRelease(
        _ releaseCount: Int,
        lastHandled: inout Int?,
        mode: LiveNotationMode,
        captureEngine: MacCaptureEngine
    ) -> Bool {
        guard let previous = lastHandled else {
            lastHandled = releaseCount
            return false // Initial subscription replay.
        }
        guard releaseCount > previous else { return false }
        lastHandled = releaseCount
        guard mode == .preview else { return false }
        captureEngine.beginLiveMIDICapture()
        return true
    }

    /// Camera framing + live performed notation.
    ///
    /// Both are PRESENTATION ONLY. The preview renders the same
    /// `AVCaptureSession` the take is recorded from, so what CXL frames here
    /// is exactly what lands in the take's video; the notation card is the
    /// canonical `ScratchPhraseChartView` motion renderer Practice and Capture
    /// already use, reading the same live evidence
    /// `completeRoutineFinalization` reads. Neither is scored, persisted,
    /// reviewed or exported, and neither is a second renderer.
    private var framingSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isShowingFramingPanel) {
                framingContent
            } label: {
                Text("Framing and live motion")
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var framingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacCameraPreviewView(
                captureEngine: captureEngine,
                videoGravity: .resizeAspect
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Self.cameraPreviewMaximumHeight)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !captureEngine.isCameraActive {
                Text("Camera preview is not running. Recording is blocked until the selected camera is active.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let liveNotationTracker {
                if viewModel.selectedTechnique != .tear {
                    LivePerformedNotationCard(
                        tracker: liveNotationTracker,
                        bpm: Double(viewModel.bpm)
                    )
                    // The minimum applies to the CARD only. The DEBUG diagnostics
                    // row below is a sibling in this stack, so it can never eat
                    // into the notation's guaranteed height.
                    .frame(maxWidth: .infinity, minHeight: Self.liveNotationMinimumHeight)
                } else {
                    // The LIVE view of a tear goes through the SAME canonical
                    // projection the finalized review uses, so a
                    // forward → hold → forward gesture cannot be drawn one way
                    // here and another way afterwards — and can never be drawn
                    // as a Baby-style reversal or as one uninterrupted
                    // diagonal. Presentation only: nothing here is persisted,
                    // scored, reviewed or exported.
                    canonicalTearChart(
                        title: "YOUR MOTION — LIVE (TEAR STRUCTURE)",
                        projection: ReferenceTearCanonicalProjectionBuilder.project(
                            movementEvents: liveNotationTracker.continuousRenderedEvents,
                            platterEvidenceIntervals: liveNotationTracker.platterEvidenceIntervals,
                            derivation: liveNotationTracker.faderDerivation,
                            coordinates: liveNotationTracker.continuousPlatterCoordinates
                        ),
                        emptyMessage: "Waiting for tear motion…"
                    )
                    .frame(maxWidth: .infinity, minHeight: Self.liveNotationMinimumHeight)
                }
                #if DEBUG
                LiveNotationDiagnosticsRow(tracker: liveNotationTracker)
                #endif
            } else {
                // Only reachable while the route is inactive; the lane is live
                // from entry onward. Same reserved height, so nothing shifts.
                Text("Live motion appears here while this screen is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.liveNotationMinimumHeight,
                        alignment: .topLeading
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var messagePanel: some View {
        if let message = viewModel.visibleMessage {
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var setupSection: some View {
        GroupBox("1. Technique, pattern and variant") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Operator: \(viewModel.session.operatorName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Technique", selection: $viewModel.selectedTechnique) {
                    Text("Select a technique").tag(Optional<ReferenceTechnique>.none)
                    ForEach(ReferenceTechnique.authorableSet) { technique in
                        Text(technique.displayName).tag(Optional(technique))
                    }
                }
                .pickerStyle(.menu)

                if case .flare = viewModel.selectedTechnique {
                    Text("Flare click count is part of the selected technique and must be chosen explicitly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.selectedTechnique == .tear {
                    Text("Tear is recorded as Tear. The selected technique is the take's metadata; automatic detection stays advisory and never overwrites it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    TextField("Pattern ID", text: $viewModel.patternID)
                    TextField("Pattern name", text: $viewModel.patternName)
                }
                Text("Both fill in from the technique and phrase length. Edit either one and it stays yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Phrase length: \(viewModel.phraseBars) bar(s)", value: $viewModel.phraseBars, in: 1...16)
                Stepper(
                    "BPM: \(viewModel.bpm)",
                    value: $viewModel.bpm,
                    in: CaptureClickTrackDefaults.supportedBPMRange
                )

                Picker("Starting direction", selection: $viewModel.startingDirectionRawValue) {
                    Text("Select direction").tag("")
                    ForEach(ReferenceStartingPlatterDirection.allCases, id: \.rawValue) { direction in
                        Text(direction.displayName).tag(direction.rawValue)
                    }
                }
                Picker("Handedness", selection: $viewModel.handednessRawValue) {
                    ForEach(CaptureSessionHandedness.allCases, id: \.rawValue) { handedness in
                        Text(handedness.rawValue.capitalized).tag(handedness.rawValue)
                    }
                }
                Picker("Fader variant", selection: $viewModel.faderVariantRawValue) {
                    Text("Select fader variant").tag("")
                    ForEach(ReferenceFaderVariant.allCases, id: \.rawValue) { variant in
                        Text(variant.displayName).tag(variant.rawValue)
                    }
                }
                TextField("Session notes", text: $viewModel.notes, axis: .vertical)
                    .lineLimit(2...4)

                Button("Apply Authoring Setup") {
                    viewModel.applySetup()
                }
                .disabled(viewModel.isWorking || viewModel.session.phase == .recording)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var calibrationSection: some View {
        GroupBox("2. Crossfader calibration") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Active deck", selection: $viewModel.activeDeckRawValue) {
                        ForEach(CrossfaderActiveDeck.allCases, id: \.rawValue) { deck in
                            Text(deck.displayName).tag(deck.rawValue)
                        }
                    }
                    Picker("Open end", selection: $viewModel.crossfaderOpenEndRawValue) {
                        ForEach(CrossfaderOpenEnd.allCases, id: \.rawValue) { end in
                            Text(end.displayName).tag(end.rawValue)
                        }
                    }
                }

                HStack {
                    Button(viewModel.session.confirmedCalibration == nil
                        ? "Start Calibration Sweep"
                        : "Recalibrate Crossfader") {
                        viewModel.recalibrateCrossfader()
                    }
                    .disabled(!viewModel.session.configurationIsComplete || viewModel.isWorking)
                    Button("Reuse Saved Calibration") {
                        viewModel.adoptPersistedCalibrationIfAvailable(announce: true)
                    }
                    .disabled(viewModel.session.confirmedCalibration != nil || viewModel.isWorking)
                }
                if let summary = viewModel.calibrationSourceSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("A saved calibration for this exact device, channel, CC, deck and open end is adopted automatically — the learned MIDI mapping is never relearned and no new sweep is required. Recalibrate only when the hardware or its wiring has changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let sweep = viewModel.session.calibrationSweep {
                    Text("Live raw value: \(viewModel.state.latestCalibrationRawValue.map(String.init) ?? "No traffic")")
                        .font(.system(.body, design: .monospaced))

                    calibrationStepRow(.fullLeft, sweep: sweep)
                    calibrationStepRow(.center, sweep: sweep)
                    calibrationStepRow(.fullRight, sweep: sweep)

                    switch sweep.state {
                    case .awaitingArm(let step):
                        // Unarmed: the instruction is on screen and NOTHING is
                        // being sampled. The operator presents the position,
                        // then presses Capture. Before D4 the sweep started
                        // sampling immediately and could settle a stage before
                        // the instruction had been read.
                        Text(step.prompt)
                            .font(.callout.weight(.semibold))
                        Text("Nothing is being recorded yet. Move the fader into position, then press the button below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(step.captureActionTitle) {
                            viewModel.armCalibrationCapture()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isWorking)
                    case .capturing(let step, let settledSampleCount):
                        Text(step.prompt)
                            .font(.callout.weight(.semibold))
                        ProgressView(value: sweep.settleProgress)
                        Text("Settled samples: \(settledSampleCount) / \(sweep.settleSampleCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Liveness is shown separately from stability on
                        // purpose: a stale value can hold the settle bar at
                        // 100% while nothing is transmitting at all.
                        ProgressView(value: sweep.freshObservationProgress)
                        Text("New crossfader messages this position: \(sweep.freshObservationCount) / \(sweep.minimumFreshObservations)")
                            .font(.caption)
                            .foregroundStyle(sweep.freshObservationCount == 0 ? .orange : .secondary)
                        if sweep.freshObservationCount == 0 {
                            Text("Nothing has arrived on the learned crossfader address since this position began. Move the crossfader.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Retry Current Position") {
                            viewModel.retryCalibrationStep()
                        }
                    case .complete(let calibration):
                        Text(calibration.isUsable
                            ? "Sweep settled and complete. Commit it before recording."
                            : calibration.validationIssues().map(\.message).joined(separator: " "))
                            .foregroundStyle(calibration.isUsable ? .green : .red)
                        Button("Commit Calibration") {
                            viewModel.commitCalibration()
                        }
                        .disabled(!calibration.isUsable || viewModel.isWorking)
                    }
                } else if let calibration = viewModel.session.confirmedCalibration {
                    // Truthful for BOTH ways a calibration reaches this state:
                    // swept and committed in this session, or adopted unchanged
                    // from the store. Calling an adopted one "Committed"
                    // overstates what the operator actually did here. HOW it
                    // was obtained is already stated by the
                    // `calibrationSourceSummary` caption above, so this line
                    // names the calibration in force and does not repeat it.
                    Text("Calibration in force: \(calibration.address.displayName), \(calibration.activeDeck.displayName), \(calibration.openEnd.displayName).")
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var preflightSection: some View {
        GroupBox("3. Live preflight") {
            VStack(alignment: .leading, spacing: 8) {
                if let preflight = viewModel.session.latestPreflight {
                    ForEach(preflight.checks) { check in
                        HStack(alignment: .top) {
                            Image(systemName: preflightSymbol(check.status))
                                .foregroundStyle(preflightColor(check.status))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title).font(.callout.weight(.semibold))
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Apply the setup to begin live checks.")
                        .foregroundStyle(.secondary)
                }

                midiAddressDiagnostics
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    /// Every MIDI address the app has actually received traffic on, with the
    /// age of its most recent message.
    ///
    /// Diagnostic only — it maps nothing and decides nothing. It exists
    /// because the 2026-09-04 smoke could not tell "the crossfader is
    /// transmitting" from "a control was learned onto an address that has
    /// been silent for minutes", and the take that followed contained zero
    /// crossfader samples.
    @ViewBuilder
    private var midiAddressDiagnostics: some View {
        if let snapshot = viewModel.session.latestPreflightSnapshot {
            DisclosureGroup(isExpanded: $isShowingMIDIAddressDiagnostics) {
                VStack(alignment: .leading, spacing: 4) {
                    if snapshot.observedMIDIAddresses.isEmpty {
                        Text("No MIDI traffic has been received on any address since launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.observedMIDIAddresses) { address in
                            Text(
                                String(
                                    format: "%@ · raw %d · %d msgs · last %.1fs ago",
                                    address.displayName,
                                    address.latestRawValue,
                                    address.eventCount,
                                    address.secondsSinceLastMessage
                                )
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(
                                address.secondsSinceLastMessage < ReferenceCapturePreflight.recentActivityWindow
                                    ? Color.primary
                                    : Color.secondary
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text("MIDI addresses seen (\(snapshot.observedMIDIAddresses.count))")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var recordingSection: some View {
        GroupBox("4. Record") {
            VStack(alignment: .leading, spacing: 10) {
                Text("One count-in bar, four identical repetitions, then one clean tail bar.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Record Draft") {
                        viewModel.startRecording()
                    }
                    .disabled(!canRecord)
                    Button("Stop and Finalize") {
                        viewModel.stopRecording()
                    }
                    .disabled(viewModel.session.phase != .recording || viewModel.isWorking)
                    Text(viewModel.workflowStatusText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if viewModel.session.confirmedCalibration == nil {
                    Text("No crossfader calibration is in force. This take will still record, finalize and export — its fader evidence will be recorded as explicitly unknown, and it cannot be approved as a canonical reference until a calibration is in place.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                rawExportControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    // MARK: - Raw diagnostic export

    /// Export the RAW capture, separately from canonical approval.
    ///
    /// This copies the already-finalized files through the existing
    /// `SessionExportCoordinator` archive pipeline — there is no second ZIP
    /// implementation here. It does not depend on repetition selection, fader
    /// calibration, tear-review corrections, or `approvalBlockReason`, and it
    /// approves, publishes, installs and registers nothing.
    @ViewBuilder
    private var rawExportControls: some View {
        Divider()
        HStack {
            Button("Save Capture…") { saveRawCapture() }
                .disabled(!viewModel.canExportRawCapture || exportCoordinator.isPreparing)
            if exportCoordinator.isPreparing {
                ProgressView().controlSize(.small)
            }
            if let status = exportCoordinator.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let reason = viewModel.rawCaptureExportBlockReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        Text(ReferenceAuthoringViewModel.rawCaptureExportDisclaimer)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func saveRawCapture() {
        guard let source = viewModel.rawCaptureExportSource(
            config: captureEngine.recordingSessionConfig
        ) else { return }
        exportCoordinator.saveArchiveCopy(for: source)
    }

    @ViewBuilder
    private var reviewSection: some View {
        if let take = viewModel.reviewedTake {
            GroupBox("5. Finalized take review") {
                VStack(alignment: .leading, spacing: 12) {
                    evidenceSummary(take)

                    // The detector is limited to Baby Scratch, so on a Tear
                    // take a "does not match" warning would read as the
                    // operator being contradicted by something that has no
                    // Tear vocabulary at all. State the limit instead.
                    let advisory = ReferenceAuthoringViewModel
                        .advisoryDetectionStatement(for: take)
                    Text(advisory.text)
                        .foregroundStyle(advisory.isDisagreement ? Color.orange : Color.secondary)

                    Divider()
                    Text("Validation findings").font(.headline)
                    if take.latestValidation.findings.isEmpty {
                        Text("No validation findings.").foregroundStyle(.green)
                    } else {
                        ForEach(Array(take.latestValidation.findings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .top) {
                                Image(systemName: finding.severity == .failure ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(finding.severity == .failure ? .red : .orange)
                                Text(finding.message).font(.callout)
                            }
                        }
                    }

                    Divider()
                    Text("Four repetitions").font(.headline)
                    Text("Audition is omitted: the existing lightweight player only resolves bundled Scratch Bank IDs and cannot safely play finalized WAV/MOV repetition ranges without a broader playback refactor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(take.evidence.boundaries.repetitions) { boundary in
                        repetitionRow(boundary, take: take)
                    }

                    Divider()
                    tearSegmentationSection(take)

                    TextField("Approval or rejection notes", text: $viewModel.reviewNotes, axis: .vertical)
                        .lineLimit(2...4)

                    // Approval's scope, stated wherever approval is offered.
                    // Approving marks ONE draft canonical inside this session.
                    // It is not an export, and it publishes, installs and
                    // enables nothing — those are separate, later actions.
                    Text("Approving a canonical draft is not export, publication, installation, or training eligibility. Use Save Capture… above to export the raw take; it is independent of approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if take.evidence.metadata.lifecycleState == .approvedCanonical {
                        Text("Approved canonical draft. Not published, not installed, not eligible for training.")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("Reject Take") { viewModel.rejectTake() }
                            Button("Retake") { viewModel.retake() }
                            Button("Approve Canonical Draft") { viewModel.approveCanonical() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!viewModel.canApprove)
                        }
                        // Say WHY it is unavailable. A dead button with no
                        // reason is what let the 2026-09-05 take look
                        // approvable against three blocking findings.
                        if let reason = viewModel.approvalBlockReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Canonical tear notation

    /// One canonical chart over projected `ScratchNotation.GestureRecord`s.
    ///
    /// Renders through the EXISTING shared chart
    /// (`ScratchPhraseChartView.ChartSource.canonical`), which draws holds as
    /// horizontal segments, closed-fader travel distinctly from sounding
    /// travel, explicit MOTION UNKNOWN / FADER UNKNOWN bands, and fader glyphs
    /// only from real fader observations. No second renderer and no second
    /// notation model exists for this screen.
    @ViewBuilder
    private func canonicalTearChart(
        title: String,
        projection: ReferenceTearCanonicalProjection,
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.55))
            if let frame = ReferenceAuthoringViewModel.canonicalFrame(
                for: projection,
                bpm: Double(viewModel.bpm)
            ), !projection.isEmpty {
                ScratchPhraseChartView(
                    source: .canonical(projection.records, layer: .performance, frame: frame),
                    bpm: Double(viewModel.bpm),
                    backgroundColor: .clear
                )
                // Bounded, never `maxHeight: .infinity`: this card also lives
                // inside an unbounded `ScrollView`, where `.infinity` resolves
                // to the IDEAL height and collapses the lane — the same trap
                // documented on `liveNotationMinimumHeight`.
                .frame(maxWidth: .infinity, minHeight: Self.canonicalTearChartMinimumHeight)
            } else {
                ScratchPhraseChartView(
                    source: .empty(emptyMessage),
                    bpm: Double(viewModel.bpm),
                    backgroundColor: .clear
                )
                .frame(maxWidth: .infinity, minHeight: Self.canonicalTearChartMinimumHeight)
            }
            ForEach(projection.reasons, id: \.rawValue) { reason in
                Text(reason.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tear segmentation review

    /// Inspect and correct one take's tear segmentation.
    ///
    /// Read-and-correct only. Nothing in this subtree approves a take,
    /// publishes a package, installs a reference or makes anything eligible
    /// for training — the status line says so on every render, because a
    /// screen that looks like a sign-off is how a draft becomes canonical by
    /// accident.
    @ViewBuilder
    private func tearSegmentationSection(_ take: ReferenceAuthoringTake) -> some View {
        let review = take.tearReview
        VStack(alignment: .leading, spacing: 10) {
            Text("Tear segmentation review").font(.headline)
            canonicalTearChart(
                title: "CANONICAL TEAR STRUCTURE — FINALIZED TAKE",
                projection: ReferenceTearCanonicalProjectionBuilder.project(review),
                emptyMessage: "No tear structure could be placed from this take's evidence."
            )
            .frame(maxWidth: .infinity, minHeight: Self.liveNotationMinimumHeight)
            Text(ReferenceAuthoringViewModel.tearReviewStatusText(review))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reason = viewModel.tearReviewBlockReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }

            tearOverviewChart(review)
            tearAggregateCounts(review)
            tearEvidenceSummary(review)

            if review.candidates.isEmpty {
                Text("No tear candidate to correct.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Grouped disclosure, not truncation: every candidate is filed
                // in exactly one group and every group lists all of its
                // gestures once opened. Nothing is deleted, merged, or
                // relabelled to shorten the list.
                ForEach(ReferenceAuthoringViewModel.tearCandidateGroups(review)) { group in
                    DisclosureGroup(isExpanded: tearGroupExpandedBinding(for: group, review: review)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(group.candidateIDs, id: \.self) { candidateID in
                                if let candidate = review.candidate(id: candidateID) {
                                    tearCandidateCard(candidate, review: review)
                                }
                            }
                        }
                    } label: {
                        Text(group.headline)
                            .font(.callout.weight(.semibold))
                    }
                }
            }

            TextField(
                "Tear review notes (attached to the next correction)",
                text: $viewModel.tearReviewNotes,
                axis: .vertical
            )
            .lineLimit(1...3)
            HStack {
                Button("Save Tear Review Notes") { viewModel.commitTearReviewNotes() }
                    .disabled(!viewModel.canCorrectTearReview)
                if !review.notes.isEmpty {
                    Text("Saved notes: \(review.notes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A compact timeline of the corrected segmentation, drawn before the
    /// gesture cards so the operator sees the whole take at a glance.
    private func tearOverviewChart(_ review: ReferenceTearSegmentationReview) -> some View {
        TearReviewTimelineChart(review: review)
    }

    /// The four counts the operator needs to size a take up at a glance:
    /// gestures, physical reversals, surviving holds and still-unknown
    /// candidates.
    private func tearAggregateCounts(_ review: ReferenceTearSegmentationReview) -> some View {
        HStack(spacing: 18) {
            tearCount(review.candidates.count, "gesture")
            tearCount(review.reversals.count, "reversal")
            tearCount(review.totalCountedTearHoldCount, "hold")
            tearCount(review.unknownCandidateCount, "unknown candidate")
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func tearCount(_ count: Int, _ singular: String) -> some View {
        Text("\(count) \(count == 1 ? singular : singular + "s")")
    }

    /// One gesture, collapsed to its headline by default and expanded only
    /// while it is the selected candidate. This keeps a noisy take from
    /// rendering dozens of open cards.
    private func tearCandidateCard(
        _ candidate: ReferenceTearCandidate,
        review: ReferenceTearSegmentationReview
    ) -> some View {
        DisclosureGroup(isExpanded: tearCandidateExpandedBinding(for: candidate)) {
            tearCandidateRow(candidate, review: review)
        } label: {
            HStack(spacing: 8) {
                Text(ReferenceAuthoringViewModel.tearCandidateHeadline(candidate))
                    .font(.callout.weight(.semibold))
                Spacer()
                if candidate.classificationDisagreesWithBoundaryCount {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("The reading in force disagrees with the surviving hold count.")
                }
            }
        }
    }

    private func tearGroupExpandedBinding(
        for group: ReferenceAuthoringViewModel.TearCandidateGroup,
        review: ReferenceTearSegmentationReview
    ) -> Binding<Bool> {
        Binding(
            get: {
                (expandedTearGroupIDs
                    ?? ReferenceAuthoringViewModel.defaultExpandedTearGroupIDs(review))
                    .contains(group.id)
            },
            set: { isExpanded in
                var ids = expandedTearGroupIDs
                    ?? ReferenceAuthoringViewModel.defaultExpandedTearGroupIDs(review)
                if isExpanded { ids.insert(group.id) } else { ids.remove(group.id) }
                expandedTearGroupIDs = ids
            }
        )
    }

    private func tearCandidateExpandedBinding(
        for candidate: ReferenceTearCandidate
    ) -> Binding<Bool> {
        Binding(
            get: { selectedTearCandidateID == candidate.id },
            set: { isExpanded in
                selectedTearCandidateID = isExpanded ? candidate.id : nil
            }
        )
    }

    /// Raw motion, derived intervals, reversals and fader evidence, stated as
    /// counts and spans. Textual detail that sits beside the overview chart
    /// (drawn separately by `tearOverviewChart`).
    private func tearEvidenceSummary(_ review: ReferenceTearSegmentationReview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ReferenceAuthoringViewModel.tearCoordinateContractText(review))
            Text("Raw platter movement events: \(review.rawMovementEvents.count)")
            Text("Derived intervals: \(review.travelIntervals.count) travel · \(review.stationaryIntervals.count) stationary · \(review.reversals.count) direction reversal\(review.reversals.count == 1 ? "" : "s")")
            Text("Fader evidence: \(review.faderIntervals.count) state interval\(review.faderIntervals.count == 1 ? "" : "s") · \(review.faderClicks.count) click\(review.faderClicks.count == 1 ? "" : "s")")
            ForEach(Array(review.reasons.enumerated()), id: \.offset) { _, reason in
                Text("• \(reason.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Derived intervals in detail") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(review.segments) { segment in
                        Text(tearSegmentLine(segment))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(review.reversals) { reversal in
                        Text(String(
                            format: "reversal  %.3f–%.3f s  %@ → %@",
                            reversal.span.startTime,
                            reversal.span.endTime,
                            reversal.from.rawValue,
                            reversal.to.rawValue
                        ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                    ForEach(Array(review.faderIntervals.enumerated()), id: \.offset) { _, interval in
                        Text(String(
                            format: "fader     %.3f–%.3f s  %@",
                            interval.startTime,
                            interval.endTime,
                            interval.state.rawValue
                        ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func tearSegmentLine(_ segment: ReferenceTearMotionSegment) -> String {
        let confidence = segment.confidence.map { String(format: "%.2f", $0) } ?? "—"
        return String(
            format: "%@ %.3f–%.3f s  conf %@",
            segment.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0),
            segment.span.startTime,
            segment.span.endTime,
            confidence
        )
    }

    private func tearCandidateRow(
        _ candidate: ReferenceTearCandidate,
        review: ReferenceTearSegmentationReview
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ReferenceAuthoringViewModel.tearCandidateHeadline(candidate))
                .font(.callout.weight(.semibold))

            Picker("Reading", selection: tearClassificationBinding(for: candidate)) {
                ForEach(ReferenceTearClassification.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.canCorrectTearReview)

            if let disagreement = ReferenceAuthoringViewModel.tearDisagreementText(candidate) {
                Text(disagreement).font(.caption).foregroundStyle(.orange)
            }
            if let correction = candidate.latestClassificationCorrection {
                Text(ReferenceAuthoringViewModel.tearCorrectionSummary(correction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if candidate.boundaries.isEmpty {
                Text("No tear boundary proposed inside this gesture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidate.boundaries) { boundary in
                    tearBoundaryRow(boundary, candidate: candidate)
                }
            }

            Button("Add Tear Boundary") {
                viewModel.addTearBoundary(
                    toCandidate: candidate.id,
                    startTime: candidate.span.startTime,
                    endTime: min(
                        candidate.span.endTime,
                        candidate.span.startTime + Self.addedTearBoundaryDuration
                    )
                )
            }
            .disabled(!viewModel.canCorrectTearReview)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Width of a freshly added boundary, before the operator nudges it.
    /// A starting point, never a measurement.
    private static let addedTearBoundaryDuration: Double = 0.05
    private static let tearBoundaryNudge: Double = 0.01

    private func tearBoundaryRow(
        _ boundary: ReferenceTearBoundary,
        candidate: ReferenceTearCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ReferenceAuthoringViewModel.tearBoundaryHeadline(boundary))
                .font(.caption.weight(.medium))
                .foregroundStyle(boundary.isRemoved ? Color.secondary : Color.primary)
            if let proposal = boundary.proposal, boundary.differsFromProposal {
                Text(String(
                    format: "Proposed %.3f–%.3f s · %@ · %@",
                    proposal.span.startTime,
                    proposal.span.endTime,
                    proposal.kind.displayName,
                    proposal.evidenceQuality.displayName
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let correction = boundary.latestCorrection {
                Text(ReferenceAuthoringViewModel.tearCorrectionSummary(correction))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("", selection: tearBoundaryKindBinding(boundary, candidate: candidate)) {
                    ForEach(ReferenceTearBoundaryKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Toggle("Ambiguous", isOn: tearBoundaryAmbiguityBinding(boundary, candidate: candidate))
                    .toggleStyle(.checkbox)
                Button(boundary.isRemoved ? "Restore" : "Remove") {
                    viewModel.setTearBoundaryRemoved(
                        inCandidate: candidate.id,
                        boundaryID: boundary.id,
                        removed: !boundary.isRemoved
                    )
                }
                Spacer()
            }
            .disabled(!viewModel.canCorrectTearReview)
            HStack(spacing: 8) {
                Stepper(
                    "Start \(boundary.span.startTime, specifier: "%.3f") s",
                    onIncrement: { moveTearBoundary(boundary, candidate: candidate, startDelta: Self.tearBoundaryNudge) },
                    onDecrement: { moveTearBoundary(boundary, candidate: candidate, startDelta: -Self.tearBoundaryNudge) }
                )
                Stepper(
                    "End \(boundary.span.endTime, specifier: "%.3f") s",
                    onIncrement: { moveTearBoundary(boundary, candidate: candidate, endDelta: Self.tearBoundaryNudge) },
                    onDecrement: { moveTearBoundary(boundary, candidate: candidate, endDelta: -Self.tearBoundaryNudge) }
                )
            }
            .disabled(!viewModel.canCorrectTearReview)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func moveTearBoundary(
        _ boundary: ReferenceTearBoundary,
        candidate: ReferenceTearCandidate,
        startDelta: Double = 0,
        endDelta: Double = 0
    ) {
        guard let live = viewModel.tearReview?
            .candidate(id: candidate.id)?
            .boundaries.first(where: { $0.id == boundary.id }) else { return }
        viewModel.moveTearBoundary(
            inCandidate: candidate.id,
            boundaryID: boundary.id,
            startTime: live.span.startTime + startDelta,
            endTime: live.span.endTime + endDelta
        )
    }

    private func tearClassificationBinding(
        for candidate: ReferenceTearCandidate
    ) -> Binding<ReferenceTearClassification> {
        Binding(
            get: {
                viewModel.tearReview?.candidate(id: candidate.id)?.effectiveClassification
                    ?? candidate.effectiveClassification
            },
            set: { viewModel.classifyTearCandidate(candidate.id, as: $0) }
        )
    }

    private func tearBoundaryKindBinding(
        _ boundary: ReferenceTearBoundary,
        candidate: ReferenceTearCandidate
    ) -> Binding<ReferenceTearBoundaryKind> {
        Binding(
            get: { boundary.kind },
            set: {
                viewModel.setTearBoundaryKind(
                    inCandidate: candidate.id,
                    boundaryID: boundary.id,
                    to: $0
                )
            }
        )
    }

    private func tearBoundaryAmbiguityBinding(
        _ boundary: ReferenceTearBoundary,
        candidate: ReferenceTearCandidate
    ) -> Binding<Bool> {
        Binding(
            get: { boundary.evidenceQuality.isAmbiguous },
            set: {
                viewModel.setTearBoundaryEvidenceQuality(
                    inCandidate: candidate.id,
                    boundaryID: boundary.id,
                    to: $0 ? .ambiguous : .clear
                )
            }
        )
    }

    private func evidenceSummary(_ take: ReferenceAuthoringTake) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Take \(take.evidence.metadata.takeNumber): \(take.evidence.metadata.technique.displayName) · \(take.evidence.metadata.pattern.name) · \(take.evidence.metadata.bpm) BPM")
                .font(.headline)
            Text("Audio: \(take.evidence.audio.fileName) · \(take.evidence.audio.byteCount) bytes · \(take.evidence.audio.frameCount.map(String.init) ?? "unknown") frames · peak \(take.evidence.audio.peakLevel.map { String(format: "%.4f", $0) } ?? "unknown")")
            if let video = take.evidence.video {
                Text("Video: \(video.fileName) · \(video.byteCount) bytes")
            } else {
                Text("Video: not present")
            }
            Text("Sidecar: \(take.evidence.sidecar.fileName) · \(take.evidence.sidecar.byteCount) bytes")
            Text("Platter events: \(take.evidence.platterMovementEventCount) · Crossfader samples: \(take.evidence.crossfaderRawSamples.count)")
            // Watch evidence is stated for every take, present or absent, and
            // comes from the finalized sidecar's own link — never from the
            // start handshake and never from a Watch merely being connected.
            Text(take.evidence.watchEvidence.operatorSummary)
                .foregroundStyle(
                    take.evidence.watchEvidence.isLinked
                        ? Color.secondary
                        : (take.evidence.watchEvidence.isTransferPending ? Color.orange : Color.red)
                )
            if viewModel.isWaitingForWatchTransfer {
                Text("Waiting for the Watch motion transfer to complete…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func repetitionRow(
        _ boundary: ReferenceRepetitionBoundary,
        take: ReferenceAuthoringTake
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Repetition \(boundary.index + 1)").font(.callout.weight(.semibold))
                Spacer()
                Button(take.evidence.boundaries.selectedRepetitionIndex == boundary.index ? "Selected" : "Select for Approval") {
                    viewModel.selectRepetitionForApproval(boundary.index)
                }
                .disabled(take.evidence.boundaries.selectedRepetitionIndex == boundary.index)
            }
            HStack {
                Stepper(
                    "Start beat \(boundary.startBeat, specifier: "%.2f")",
                    value: startBeatBinding(for: boundary),
                    in: 0...Double(take.evidence.metadata.totalBeats),
                    step: 0.25
                )
                Stepper(
                    "End beat \(boundary.endBeat, specifier: "%.2f")",
                    value: endBeatBinding(for: boundary),
                    in: 0...Double(take.evidence.metadata.totalBeats),
                    step: 0.25
                )
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func startBeatBinding(for boundary: ReferenceRepetitionBoundary) -> Binding<Double> {
        Binding(
            get: { currentBoundary(index: boundary.index)?.startBeat ?? boundary.startBeat },
            set: { newValue in
                let current = currentBoundary(index: boundary.index) ?? boundary
                viewModel.adjustRepetitionBoundary(
                    index: boundary.index,
                    startBeat: newValue,
                    endBeat: current.endBeat
                )
            }
        )
    }

    private func endBeatBinding(for boundary: ReferenceRepetitionBoundary) -> Binding<Double> {
        Binding(
            get: { currentBoundary(index: boundary.index)?.endBeat ?? boundary.endBeat },
            set: { newValue in
                let current = currentBoundary(index: boundary.index) ?? boundary
                viewModel.adjustRepetitionBoundary(
                    index: boundary.index,
                    startBeat: current.startBeat,
                    endBeat: newValue
                )
            }
        )
    }

    private func currentBoundary(index: Int) -> ReferenceRepetitionBoundary? {
        viewModel.reviewedTake?.evidence.boundaries.repetitions.first { $0.index == index }
    }

    /// Recording eligibility.
    ///
    /// Deliberately NOT gated on a crossfader calibration. A missing
    /// calibration costs the take its fader evidence — reported as explicit
    /// unknown, and blocking for canonical approval — but it must never cost
    /// the operator the raw diagnostic capture. The warning below says so
    /// before Record is pressed.
    private var canRecord: Bool {
        let phaseAllowsRecording = viewModel.session.phase == .readyToRecord
            || (viewModel.session.phase == .configuring && viewModel.session.configurationIsComplete)
        return phaseAllowsRecording
            && viewModel.session.latestPreflight?.blocksRecording == false
            && !viewModel.isWorking
    }

    private func calibrationStepName(_ step: CrossfaderCalibrationStep) -> String {
        switch step {
        case .fullLeft: return "Full left"
        case .center: return "Centre"
        case .fullRight: return "Full right"
        }
    }

    private func calibrationStepRow(
        _ step: CrossfaderCalibrationStep,
        sweep: CrossfaderCalibrationSweep
    ) -> some View {
        HStack {
            Text(calibrationStepName(step))
                .frame(width: 90, alignment: .leading)
            Text(calibrationStatus(step: step, sweep: sweep))
                .foregroundStyle(sweep.capturedValues[step] == nil ? Color.secondary : Color.green)
        }
    }

    private func calibrationStatus(
        step: CrossfaderCalibrationStep,
        sweep: CrossfaderCalibrationSweep
    ) -> String {
        if let value = sweep.capturedValues[step] {
            return "Settled at raw \(value)"
        }
        return sweep.state.currentStep == step ? "Hold now" : "Waiting"
    }

    private func preflightSymbol(_ status: ReferencePreflightCheck.Status) -> String {
        switch status {
        case .satisfied: return "checkmark.circle.fill"
        case .blocking: return "xmark.circle.fill"
        case .advisory: return "exclamationmark.triangle.fill"
        }
    }

    private func preflightColor(_ status: ReferencePreflightCheck.Status) -> Color {
        switch status {
        case .satisfied: return .green
        case .blocking: return .red
        case .advisory: return .orange
        }
    }

}

#if DEBUG
/// Compact, bounded, read-only counters for the live notation path.
///
/// Exists because the 2026-09-05 authoring take looked flat and nothing
/// recorded what the tracker actually held at that moment. Replaying that
/// take's captured MIDI proved the chain itself produces a healthy vertical
/// span, so the next physical test needs live counters to tell "the path saw
/// nothing" apart from "the displayed window covered a quiet period".
///
/// Reads published tracker state only. Starts, stops and configures nothing.
struct LiveNotationDiagnosticsRow: View {
    @ObservedObject var tracker: LivePerformedNotationTracker

    var body: some View {
        if let diagnostics = tracker.diagnostics {
            Text(
                String(
                    format: "raw %d · matched %d · moves %d%@ · span %.3f · age %@",
                    diagnostics.rawSnapshotCount,
                    diagnostics.baselineMatchedCount,
                    diagnostics.committedMovementCount,
                    diagnostics.hasProvisional ? "+open" : "",
                    diagnostics.renderedPositionSpan,
                    diagnostics.latestEventAge < 0
                        ? "—"
                        : String(format: "%.1fs", diagnostics.latestEventAge)
                )
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(diagnostics.renderedPositionSpan < 0.01 ? .orange : .secondary)
        } else {
            Text("live notation diagnostics: no poll yet")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
#endif

/// A qualitative timeline of one take's corrected tear segmentation.
///
/// The y-axis encodes only DIRECTION (forward above the midline, backward
/// below) and presence (hold on the midline, unknown region shaded) — never
/// an absolute platter position. This review's coordinates are normalised
/// over the take's own range (`.uncalibratedPlatterCoordinates`) and must not
/// be drawn as if calibrated. Genuine holds are horizontal spans; reversal
/// markers come from the repaired reversal list, so they represent physical
/// gesture reversals and never raw-event chatter. Fader state is drawn on its
/// own lane below the platter lane, and no click is drawn here at all.
struct TearReviewTimelineChart: View {
    let review: ReferenceTearSegmentationReview

    private var endTime: Double {
        let segmentsEnd = review.segments.map(\.span.endTime).max() ?? 0
        let faderEnd = review.faderIntervals.map(\.endTime).max() ?? 0
        return max(segmentsEnd, faderEnd)
    }

    var body: some View {
        let duration = max(endTime, 1e-9)
        Canvas { context, size in
            let x = { (time: Double) -> CGFloat in
                CGFloat(time / duration) * size.width
            }
            let midY = size.height * 0.40
            let travelHeight = size.height * 0.16

            for segment in review.segments {
                let rectWidth = max(x(segment.span.endTime) - x(segment.span.startTime), 1.5)
                switch segment.state {
                case .forward:
                    let rect = CGRect(
                        x: x(segment.span.startTime),
                        y: midY - travelHeight,
                        width: rectWidth,
                        height: travelHeight
                    )
                    context.fill(Path(rect), with: .color(.blue.opacity(0.7)))
                case .backward:
                    let rect = CGRect(
                        x: x(segment.span.startTime),
                        y: midY,
                        width: rectWidth,
                        height: travelHeight
                    )
                    context.fill(Path(rect), with: .color(.red.opacity(0.7)))
                case .stationary:
                    let rect = CGRect(
                        x: x(segment.span.startTime),
                        y: midY - 2,
                        width: rectWidth,
                        height: 4
                    )
                    context.fill(Path(rect), with: .color(.secondary))
                case .unknown, .released:
                    let rect = CGRect(
                        x: x(segment.span.startTime),
                        y: midY - travelHeight,
                        width: rectWidth,
                        height: travelHeight * 2
                    )
                    context.fill(Path(rect), with: .color(.gray.opacity(0.35)))
                }
            }

            for reversal in review.reversals {
                let lineX = x(reversal.span.startTime)
                var path = Path()
                path.move(to: CGPoint(x: lineX, y: midY - travelHeight - 2))
                path.addLine(to: CGPoint(x: lineX, y: midY + travelHeight + 2))
                context.stroke(path, with: .color(.orange), lineWidth: 1.5)
            }

            let faderY = size.height * 0.82
            let faderHeight = size.height * 0.12
            for interval in review.faderIntervals {
                let color: Color
                switch interval.state {
                case .open: color = .green.opacity(0.6)
                case .closed: color = .purple.opacity(0.6)
                case .transitioning: color = .yellow.opacity(0.6)
                }
                let rect = CGRect(
                    x: x(interval.startTime),
                    y: faderY,
                    width: max(x(interval.endTime) - x(interval.startTime), 1.5),
                    height: faderHeight
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(height: 110)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
