// ReferenceAuthoringView.swift
// ScratchLabDesktop

import Combine
import AppKit
import AVKit
import SwiftUI

struct ReferenceAuthoringView: View {
    @StateObject private var viewModel: ReferenceAuthoringViewModel
    /// Observed because this route owns the visible hardware selectors as well
    /// as the camera preview and live-notation data source. Device discovery
    /// remains owned by `MacCaptureEngine`; this view only presents and applies
    /// the operator's explicit choices.
    @ObservedObject private var captureEngine: MacCaptureEngine
    /// Optional because the DEBUG hardware route and focused view tests can
    /// run without a companion. Release injects the app-owned receiver, but
    /// nearby browsing remains off until the operator enables it in Setup.
    private let companionReceiver: CompanionCameraReceiver?

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
    /// Inspection focus is local to this view and never selects an approval.
    @State private var motionReviewFocus: ReferenceMotionReviewFocus?
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
        _captureEngine = ObservedObject(wrappedValue: engine)
        self.companionReceiver = companionReceiver
        _viewModel = StateObject(
            wrappedValue: ReferenceAuthoringViewModel(
                engine: engine,
                companionReceiver: companionReceiver,
                operatorName: operatorName
            )
        )
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CXL Reference Authoring")
                    .font(.title2.weight(.semibold))
                Text("Check one movement without a beat, or record four timed repetitions for reference review. Approval does not install or publish training data.")
                    .foregroundStyle(.secondary)

                messagePanel
                stageHeading("Setup")
                    .id(ReferenceAuthoringNavigationRequest.Destination.setup.rawValue)
                hardwareSetupSection
                setupSection
                calibrationSection
                preflightSection
                stageHeading("Capture")
                    .id(ReferenceAuthoringNavigationRequest.Destination.capture.rawValue)
                recordingSection
                stageHeading("Review & Export")
                reviewSection
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onChange(of: viewModel.navigationRequest) { _, request in
            guard let request else { return }
            withAnimation { scroll.scrollTo(request.destination.rawValue, anchor: .top) }
        }
        .task {
            await captureEngine.startDeviceDiscoveryAfterViewMount(
                allowSeratoDirectCapture: false,
                requiresExplicitVideoSelection: true
            )
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
        .modifier(
            MacAnalyzerView.WatchStopDispatchInstaller(
                captureEngine: captureEngine,
                companionReceiver: companionReceiver
            )
        )
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
        .onChange(of: captureEngine.isRoutineRecording) { wasRecording, isRecording in
            if wasRecording && !isRecording { viewModel.captureRecordingDidStop() }
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
        // Use the engine's release publisher directly: this lifecycle edge is
        // an event count, not state to infer from a view refresh. Observing the
        // engine also keeps the hardware selectors current, while ownership
        // remains with the app's `StateObject`.
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
    }

    private func stageHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var hardwareSetupSection: some View {
        GroupBox("Hardware inputs") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("MIDI source", selection: midiSourceSelectionBinding) {
                    if captureEngine.availableMIDISources.isEmpty {
                        Text("No MIDI source detected").tag("")
                    } else {
                        ForEach(captureEngine.availableMIDISources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(
                    captureEngine.availableMIDISources.isEmpty
                        || hardwareSelectionIsLocked
                )
                .accessibilityIdentifier("cxl.hardware.midiSource")

                Text(
                    "MIDI: \(captureEngine.selectedMIDIInputSourceName) "
                        + "[\(captureEngine.selectedMIDIInputSourceID)] · "
                        + "\(captureEngine.midiListeningState) · "
                        + captureEngine.lastMIDICCMessage
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(crossfaderLearnStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch captureEngine.midiLearnState {
                    case .idle:
                        Button("Learn Crossfader") {
                            captureEngine.startMIDILearn()
                        }
                        .disabled(hardwareSelectionIsLocked)
                    case .listening:
                        Button("Cancel Learn") {
                            captureEngine.cancelMIDILearn()
                        }
                    case .learned:
                        Button("Learn Crossfader") {
                            captureEngine.startMIDILearn()
                        }
                        .disabled(hardwareSelectionIsLocked)
                        Button("Clear Crossfader Mapping") {
                            captureEngine.clearCrossfaderMapping()
                        }
                        .disabled(hardwareSelectionIsLocked)
                    case .listeningFor:
                        Button("Cancel Learn") {
                            captureEngine.cancelMIDILearn()
                        }
                    }
                }

                Picker("Camera input", selection: videoInputSelectionBinding) {
                    Text("Choose a camera…").tag("")
                    ForEach(captureEngine.availableVideoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(hardwareSelectionIsLocked)
                .accessibilityIdentifier("cxl.hardware.videoInput")

                if captureEngine.selectedVideoDeviceUniqueID.isEmpty {
                    Text("Camera: not selected")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Camera: \(captureEngine.selectedVideoDeviceName) "
                            + "[\(captureEngine.selectedVideoDeviceUniqueID)]"
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                Picker("Audio input", selection: audioInputSelectionBinding) {
                    if captureEngine.availableAudioDevices.isEmpty {
                        Text("No audio input detected").tag("")
                    } else {
                        ForEach(captureEngine.availableAudioDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(
                    captureEngine.availableAudioDevices.isEmpty
                        || audioSelectionIsLocked
                )
                .accessibilityIdentifier("cxl.hardware.audioInput")

                captureAudioMeter

                scratchOutputRoutingControls

                Text(
                    "Audio: \(captureEngine.selectedAudioDeviceName) "
                        + "[\(captureEngine.selectedAudioDeviceUniqueID)]"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                Text("This selects the audio device only. This screen does not yet prove a specific input pair or physical master-return signal.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Text("Audio input can be changed between takes. It reconnects automatically; no app restart is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(captureInputActivationButtonTitle) {
                    activateCaptureInput()
                }
                .disabled(!canActivateCaptureInput)
                .accessibilityIdentifier("cxl.hardware.activateCaptureInput")

                Text("Camera and microphone permission are requested only after you choose a camera and press Enable Selected Camera & Audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let companionReceiver {
                    CompanionRelaySetupView(receiver: companionReceiver)
                }

                Button("Refresh Hardware Inputs") {
                    captureEngine.refreshDevices(
                        allowSeratoDirectCapture: false,
                        requiresExplicitVideoSelection: true
                    )
                }
                .disabled(hardwareSelectionIsLocked)

                Text("Select the exact connected sources for this rig. The IDs shown here let the operator verify the source used by preflight and captured evidence; a pass on one controller does not validate a different controller setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var hardwareSelectionIsLocked: Bool {
        viewModel.isWorking
            || captureEngine.isCaptureInputStarting
            || captureEngine.isRoutineCaptureReady
            || captureEngine.isRoutineRecording
            || captureEngine.isRoutineFinalizationPending
    }

    private var audioSelectionIsLocked: Bool {
        viewModel.isWorking
            || viewModel.session.phase == .recording
            || captureEngine.isAudioInputSelectionLocked
    }

    private var canActivateCaptureInput: Bool {
        !captureEngine.selectedVideoDeviceUniqueID.isEmpty
            && !captureEngine.selectedAudioDeviceUniqueID.isEmpty
            && !hardwareSelectionIsLocked
    }

    private var captureInputActivationButtonTitle: String {
        if captureEngine.isRoutineCaptureReady {
            return "Selected Camera & Audio Enabled"
        }
        if captureEngine.isCaptureInputStarting {
            return "Enabling Selected Camera & Audio…"
        }
        return "Enable Selected Camera & Audio"
    }

    private var crossfaderLearnStatusText: String {
        switch captureEngine.midiLearnState {
        case .idle:
            return captureEngine.midiCrossfaderMappingStatus
        case .listening:
            return captureEngine.midiLearnFeedback.isEmpty
                ? "Move only the crossfader now."
                : captureEngine.midiLearnFeedback
        case .learned(let mapping):
            return "Learned crossfader: \(mapping.displayName)"
        case .listeningFor(let action):
            return "Learning \(action.displayName)…"
        }
    }

    private var midiSourceSelectionBinding: Binding<String> {
        Binding(
            get: { captureEngine.selectedMIDIInputSourceID },
            set: { captureEngine.selectedMIDIInputSourceID = $0 }
        )
    }

    private var audioInputSelectionBinding: Binding<String> {
        Binding(
            get: { captureEngine.selectedAudioDeviceUniqueID },
            set: { captureEngine.selectAudioInput(uniqueID: $0) }
        )
    }

    /// The internal scratch output actually feeding standalone capture.
    /// Raw Rane input activity remains a separate preflight signal.
    private var captureAudioMeter: some View {
        let level = captureEngine.activeScratchOutputSignalLevel
        let litSegments = CXLScratchOutputMeter.litSegments(peak: level)
        let levelText = CXLScratchOutputMeter.label(peak: level)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(captureEngine.scratchOutputSignalSourceLabel)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(levelText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(level == nil ? Color.orange : Color.secondary)
            }
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index >= 19 ? Color.red : index >= 17 ? Color.yellow : Color.green)
                        .opacity(index < litSegments ? 1 : 0.15)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ScratchLab AHHH output level")
            .accessibilityValue(levelText)

            if level == nil {
                Text("Waiting for ScratchLab output. Load AHHH if no sample is loaded.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("cxl.capture.audioMeter")
    }

    private var scratchOutputRoutingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("AHHH output", selection: Binding(
                get: { captureEngine.scratchPrimaryOutput },
                set: { captureEngine.setScratchPrimaryOutput($0) }
            )) {
                ForEach(ScratchPrimaryOutput.allCases) { output in
                    Text(output.label).tag(output)
                }
            }
            .disabled(audioSelectionIsLocked)
            .accessibilityIdentifier("cxl.hardware.primaryOutput")
            if let route = captureEngine.scratchOutputRoutingSnapshot {
                Text("AHHH playback: \(route.primaryDeviceName ?? "Not ready")\(route.outputChannelPair.map { " · " + $0 } ?? "")")
                    .font(.caption.weight(.semibold))
                if let error = route.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if route.pendingChange {
                    Text("Output change queued until this take has finished.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if captureEngine.scratchPrimaryOutput == .rane {
                    Toggle("Also hear AHHH on Mac (delayed)", isOn: Binding(
                        get: { captureEngine.scratchOutputRoutingSnapshot?.monitorEnabled ?? false },
                        set: { captureEngine.setScratchMacMonitorEnabled($0) }
                    ))
                    .disabled(audioSelectionIsLocked || route.status != "ready")
                    .accessibilityIdentifier("cxl.hardware.macMonitor")
                    if route.monitorEnabled {
                        Text(route.monitorError ?? route.monitorStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("AHHH playback: waiting for audio setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(captureEngine.scratchPrimaryOutput == .macSystemOutput
                 ? "AHHH plays directly through the macOS sound output. Choose Mac speakers in Sound settings to hear it there."
                 : "AHHH plays through the Rane. The optional Mac monitor adds delay.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Beat and count-in: macOS default output. Their Rane routing has not been verified; use Movement check (no beat) for the next scratch test.")
                .font(.caption).foregroundStyle(.orange)
            Text("This meter and the saved take use ScratchLab's generated scratch audio. The Rane's physical mixer can change the sound afterward.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("cxl.hardware.scratchOutputRouting")
    }

    private var videoInputSelectionBinding: Binding<String> {
        Binding(
            get: { captureEngine.selectedVideoDeviceUniqueID },
            set: { captureEngine.selectVideoInput(uniqueID: $0) }
        )
    }

    /// Explicit operator action is the only CXL path that requests camera and
    /// microphone permission or starts the selected devices. The engine owns
    /// the idempotent start guard, so repeated button presses cannot start a
    /// second session. Leaving this route does not own stopping the engine.
    @MainActor
    func activateCaptureInput() {
        captureEngine.start(
            allowSeratoDirectCapture: false,
            requiresExplicitVideoSelection: true
        )
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
    /// This lifecycle helper does not start, stop or configure the session,
    /// camera, or recording. The only engine state it touches is the MIDI
    /// accumulation window, and only through the two accessors that act solely
    /// while the preview owns that window.
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
                // CXL notation describes the physical gesture. It must keep
                // one take-local coordinate basis even when the AHHH sample
                // loops, stops, reloads, or briefly loses its playback anchor.
                dataSource: captureEngine.makeLivePerformedNotationDataSource(
                    includePlaybackLoopContext: false
                )
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

    /// Reuses the main app's loaded PCM overview with the current renderer
    /// cursor. Merely displaying it neither loads nor starts audio.
    private var samplePositionContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacSamplePositionWaveformView(
                waveform: captureEngine.playbackWaveformSnapshot,
                position: captureEngine.playbackPositionSnapshot,
                positionLabel: "PLAYHEAD",
                usesRenderedPlayhead: true
            )
            .frame(height: 112)

            if captureEngine.playbackWaveformSnapshot == nil {
                HStack {
                    Button("Load AHHH") { captureEngine.loadPlatterTestSample() }
                        .disabled(viewModel.isWorking || captureEngine.isAudioInputSelectionLocked)
                    Text("Load the ScratchLab sample, then move the right platter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !captureEngine.platterTestLoadStatus.isEmpty {
                    Text(captureEngine.platterTestLoadStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if let waveform = captureEngine.playbackWaveformSnapshot,
                   let position = captureEngine.playbackPositionSnapshot,
                   position.loadedSampleID == waveform.sampleID,
                   waveform.sampleRate > 0 {
                    let seconds = position.unwrappedFramePosition / waveform.sampleRate
                    Text(String(format: "Platter from cue: %+.2f s · The playhead above follows sample playback.", seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Camera framing + live performed notation.
    ///
    /// The preview renders the same
    /// `AVCaptureSession` the take is recorded from, so what CXL frames here
    /// is exactly what lands in the take's video; the notation card is the
    /// canonical `ScratchPhraseChartView` motion renderer Practice and Capture
    /// already use, reading the same live evidence
    /// `completeRoutineFinalization` reads. Camera guides configure the same
    /// measured image regions used by capture; live notation remains a preview.
    private var framingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            CXLCameraCalibrationPreview(
                captureEngine: captureEngine,
                previewHeight: Self.cameraPreviewMaximumHeight,
                captureInProgress: viewModel.isWorking || viewModel.session.phase == .recording
            )

            if !captureEngine.isCameraActive {
                Text("Camera preview is not running. Recording is blocked until the selected camera is active.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            samplePositionContent

            if let liveNotationTracker {
                // All CXL techniques share one measured position track. The
                // legacy performed card rebases each gesture independently,
                // which detaches unequal push/pull strokes at a reversal.
                // Keep real packet gaps and fader uncertainty in the existing
                // canonical projection; sample playback never wraps this lane.
                ReferenceLiveMotionContent(tracker: liveNotationTracker) { liveNotationTracker in
                    canonicalTearChart(
                        title: viewModel.selectedTechnique.map {
                            "YOUR MOTION — LIVE (\($0.displayName.uppercased()))"
                        } ?? "YOUR MOTION — LIVE",
                        projection: ReferenceTearCanonicalProjectionBuilder.project(
                            movementEvents: liveNotationTracker.continuousRenderedEvents,
                            platterEvidenceIntervals: liveNotationTracker.platterEvidenceIntervals,
                            derivation: liveNotationTracker.faderDerivation,
                            coordinates: liveNotationTracker.continuousPlatterCoordinates
                        ),
                        emptyMessage: "Waiting for movement…"
                    )
                }
                .frame(maxWidth: .infinity, minHeight: Self.liveNotationMinimumHeight)
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

                Picker("Capture", selection: $viewModel.capturePurpose) {
                    ForEach(ReferenceCapturePurpose.allCases) { purpose in
                        Text(purpose.displayName).tag(purpose)
                    }
                }
                if viewModel.capturePurpose == .movementCheck {
                    Text("Record one movement at your own pace, then stop. No beat or count-in plays. You can play and save the result; it is a movement check, not a canonical reference.")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
                if viewModel.capturePurpose == .canonicalReference {
                Stepper("Phrase length: \(viewModel.phraseBars) bar(s)", value: $viewModel.phraseBars, in: 1...16)
                Text("Length of one repetition. One bar is four beats; perform the same phrase four times.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(
                    "BPM: \(viewModel.bpm)",
                    value: $viewModel.bpm,
                    in: CaptureClickTrackDefaults.supportedBPMRange
                )
                Picker("Backing sound", selection: $viewModel.beatEngineMode) {
                    ForEach(BeatEngineMode.practiceModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button(viewModel.isPreviewingBeat ? "Stop preview" : "Preview backing sound") {
                    viewModel.toggleBeatPreview()
                }
                Text("Boom Bap Trainer is a straight drum beat. Minimal Funk adds swing; Battle Loop is more forceful. Click track plays metronome clicks only. Preview uses the Mac's selected sound output and does not record.")
                    .font(.caption).foregroundStyle(.secondary)
                }

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
                Text("Starting direction is your first record movement: push forward or pull back. Handedness is the hand moving the record and wearing the Watch.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Fader variant", selection: $viewModel.faderVariantRawValue) {
                    Text("Select fader variant").tag("")
                    ForEach(ReferenceFaderVariant.allCases, id: \.rawValue) { variant in
                        Text(variant.displayName).tag(variant.rawValue)
                    }
                }
                Text("For a plain Tear, choose Fader open throughout. Choose a cut variant only when intentionally using the fader.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Session notes", text: $viewModel.notes, axis: .vertical)
                    .lineLimit(2...4)

                Button("Apply Authoring Setup") {
                    viewModel.applySetup()
                }
                .disabled(viewModel.isWorking || viewModel.session.phase == .recording)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .disabled(viewModel.isWorking || viewModel.session.captureIntent != nil)
            if viewModel.session.captureIntent != nil {
                Text("Setup is fixed after the first Record. Retake keeps the same technique, tempo and backing sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Text("Active deck is the platter being scratched. Open end is the fader side where that deck is audible; keep the settings matching your completed calibration.")
                    .font(.caption).foregroundStyle(.secondary)

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
                    let satisfied = preflight.checks.filter { $0.status == .satisfied }
                    let blocking = preflight.checks.filter { $0.status == .blocking }
                    let advisory = preflight.checks.filter { $0.status == .advisory }
                    if !satisfied.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            preflightGrid(satisfied, columnCount: 2)
                                .frame(minWidth: 560)
                            preflightGrid(satisfied, columnCount: 1)
                        }
                    }
                    if !satisfied.isEmpty && (!blocking.isEmpty || !advisory.isEmpty) {
                        Divider()
                    }
                    ForEach(blocking) { check in
                        preflightRow(check)
                    }
                    ForEach(advisory) { check in
                        preflightRow(check)
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

    private func preflightGrid(_ checks: [ReferencePreflightCheck], columnCount: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: columnCount),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(checks) { check in
                preflightRow(check)
            }
        }
    }

    private func preflightRow(_ check: ReferencePreflightCheck) -> some View {
        HStack(alignment: .top) {
            Image(systemName: preflightSymbol(check.status))
                .foregroundStyle(preflightColor(check.status))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.callout.weight(.semibold))
                Text(check.detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preflightStatusLabel(check.status)): \(check.title). \(check.detail)")
    }

    private func preflightStatusLabel(_ status: ReferencePreflightCheck.Status) -> String {
        switch status {
        case .satisfied: return "Passed"
        case .blocking: return "Blocking error"
        case .advisory: return "Warning"
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
                captureAudioMeter
                if viewModel.session.selectedCapturePurpose == .movementCheck {
                    Text("Perform one slow movement, then press Stop and Finalize.")
                        .foregroundStyle(.secondary)
                    Text("Wait for Recording started before moving. No beat or count-in plays. Press Stop and Finalize when finished.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                Text("One count-in bar, four identical repetitions, then one clean tail bar.")
                    .foregroundStyle(.secondary)
                Text("Four count-in clicks, then \(viewModel.session.selectedBeatEngineMode.title) at \(viewModel.session.selectedBPM ?? viewModel.bpm) BPM. Recording finishes automatically after four repetitions and the tail bar. Stop and Finalize ends a diagnostic take early.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(viewModel.session.selectedCapturePurpose == .movementCheck ? "Record movement check" : "Record Draft") {
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
                framingContent
                if viewModel.session.confirmedCalibration == nil {
                    Text("Check Calibration in Live preflight before recording. A matching saved calibration is adopted when the take starts. An older take with unknown fader evidence cannot be repaired by calibrating afterward.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                rawExportControls
                if viewModel.session.latestRecordedTake != nil {
                    continuationControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    // MARK: - Raw diagnostic export

    private var continuationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Retake this scratch") {
                    viewModel.retake(isExportPreparing: exportCoordinator.isPreparing)
                }
                .disabled(viewModel.continuationBlockReason(newScratch: false,
                    isExportPreparing: exportCoordinator.isPreparing) != nil)
                Button("New scratch") {
                    viewModel.prepareNewScratch(isExportPreparing: exportCoordinator.isPreparing)
                }
                .disabled(viewModel.continuationBlockReason(newScratch: true,
                    isExportPreparing: exportCoordinator.isPreparing) != nil)
            }
            Text("Retake keeps the same setup. New scratch lets you choose a different technique. Previous takes stay saved; approval is separate.")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = viewModel.continuationBlockReason(newScratch: true,
                isExportPreparing: exportCoordinator.isPreparing) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

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
            if viewModel.isPreparingRawCaptureExport || exportCoordinator.isPreparing {
                ProgressView().controlSize(.small)
            }
            if viewModel.isPreparingRawCaptureExport {
                Text("Preparing capture…").font(.caption).foregroundStyle(.secondary)
            } else if let error = viewModel.rawCaptureExportError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if let status = exportCoordinator.statusMessage {
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
        Task {
            guard let source = await viewModel.rawCaptureExportSource(
                config: captureEngine.recordingSessionConfig
            ) else { return }
            exportCoordinator.saveArchiveCopy(for: source)
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if let take = viewModel.reviewedTake {
            GroupBox("5. Finalized take review") {
                VStack(alignment: .leading, spacing: 12) {
                    continuationControls
                    evidenceSummary(take)
                    ReferenceMediaReviewStatus(controller: viewModel.mediaReview)
                    if viewModel.session.takeInReview == nil {
                        Text("Previous take — read-only. You can play or save it; recording a new take starts a new review.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    // The detector is limited to Baby Scratch, so on a Tear
                    // take a "does not match" warning would read as the
                    // operator being contradicted by something that has no
                    // Tear vocabulary at all. State the limit instead.
                    let advisory = ReferenceAuthoringViewModel
                        .advisoryDetectionStatement(for: take)
                    Text(advisory.text)
                        .foregroundStyle(advisory.isDisagreement ? Color.orange : Color.secondary)

                    Divider()
                    if take.evidence.metadata.captureIntent?.isMovementCheck == true {
                        Text("Movement check — play and save").font(.headline)
                        Text("This check does not request canonical approval.")
                            .font(.caption).foregroundStyle(.secondary)
                        validationFindings(take.latestValidation.findings.filter { finding in
                            switch finding {
                            case .audioArtifactMissing, .audioArtifactUnreadable, .audioArtifactEmpty,
                                 .videoArtifactMissing, .videoArtifactUnreadable, .programAudioSilent,
                                 .sidecarMissing, .sidecarUnreadable, .fileNameSidecarMismatch,
                                 .artifactHashMismatch:
                                true
                            default:
                                false
                            }
                        })
                        DisclosureGroup("Reference approval checks") {
                            validationFindings(take.latestValidation.findings)
                        }
                    } else {
                        Text("Validation findings").font(.headline)
                        if take.latestValidation.findings.isEmpty {
                            Text("Recorded-evidence checks have no findings. Approval checks are shown below.")
                                .foregroundStyle(.secondary)
                        } else {
                            validationFindings(take.latestValidation.findings)
                        }
                    }

                    if take.evidence.metadata.lifecycleState != .approvedCanonical,
                       !viewModel.approvalBlockReasons.isEmpty {
                        Text("Approval unavailable").font(.headline)
                        ForEach(viewModel.approvalBlockReasons, id: \.self) { reason in
                            Text(reason).font(.callout).foregroundStyle(.orange)
                        }
                    }

                    Divider()
                    if take.evidence.metadata.captureIntent?.isMovementCheck == true {
                        Text("Movement check").font(.headline)
                        Text("Use Play whole take to review this movement. Save Capture exports the recorded files. No timed repetitions or canonical approval are assigned to this check.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Text("Four repetitions").font(.headline)
                    Text("Play each repetition to check it. Start and End beat trim its review range; Select for Approval chooses your best repetition. These controls do not change the original recording.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Beat \(take.evidence.metadata.countInBars * take.evidence.metadata.pattern.beatsPerBar) is the first beat after count-in. Review uses the recorded timing to find that beat in the media.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(take.evidence.boundaries.repetitions) { boundary in
                        repetitionRow(boundary, take: take)
                    }
                    }

                    Divider()
                    if take.evidence.metadata.technique == .tear {
                        tearSegmentationSection(take)
                        #if DEBUG
                        Divider()
                        tearComparisonSection(take)
                        #endif
                    } else {
                        recordedMotionSection(take)
                    }

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
                        HStack {
                            Button("Export Approved Package…") { exportApprovedPackage() }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.approvedPackageExportBlockReason != nil)
                            Button("Reopen & Verify Last Export") {
                                viewModel.reopenLastApprovedPackage()
                            }
                            .disabled(viewModel.approvedPackageURL == nil || viewModel.isExportingApprovedPackage)
                            if viewModel.isExportingApprovedPackage {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if let reason = viewModel.approvedPackageExportBlockReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("This creates a versioned, hashed reference package. It does not install or publish it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Next take") {
                            viewModel.prepareNextTake(isExportPreparing: exportCoordinator.isPreparing)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.nextTakeBlockReason(
                            isExportPreparing: exportCoordinator.isPreparing
                        ) != nil)
                        Text("Keeps this approved draft and returns to Record. Press Record Draft when ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reason = viewModel.nextTakeBlockReason(
                            isExportPreparing: exportCoordinator.isPreparing
                        ) {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Button("Reject Take") { viewModel.rejectTake() }
                                .disabled(!viewModel.canRejectReviewedTake)
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

    private func exportApprovedPackage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Approved Package Destination"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        viewModel.exportApprovedPackage(to: directory)
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
        emptyMessage: String,
        wrapPeriod: Double? = nil,
        recordedBPM: Int? = nil,
        reviewTake: ReferenceAuthoringTake? = nil
    ) -> some View {
        let chartBPM = Double(recordedBPM ?? viewModel.bpm)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.55))
            if let fullFrame = ReferenceAuthoringViewModel.canonicalFrame(
                for: projection,
                bpm: chartBPM
            ), !projection.isEmpty {
                let boundary = reviewTake.flatMap { focusedBoundary(for: $0) }
                let selectedRange = reviewTake.flatMap { take in
                    boundary.flatMap {
                        ReferenceMotionReviewViewport.range(for: $0, metadata: take.evidence.metadata,
                            recordedEnd: take.evidence.metadata.witnessedTiming?.measuredWAVDurationSeconds
                                ?? fullFrame.timeRange.upperBound)
                    }
                }
                let zoomed = selectedRange != nil && (reviewTake.map { motionReviewFocus?.takeID == $0.id
                    && motionReviewFocus?.isZoomed == true } ?? false)
                let frame = ReferenceMotionReviewViewport.frame(fullFrame, selectedRange: selectedRange, zoomed: zoomed)
                if let take = reviewTake, let boundary {
                    HStack {
                        Text("Highlighted repetition \(boundary.index + 1) · beats \(boundary.startBeat, specifier: "%.2f")–\(boundary.endBeat, specifier: "%.2f")")
                            .font(.caption)
                        Spacer()
                        Button(zoomed ? "Whole take" : "Zoom to repetition") {
                            motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary.index, isZoomed: !zoomed)
                        }
                        .disabled(selectedRange == nil)
                    }
                    if selectedRange == nil {
                        Text("This repetition is outside the recorded range. Adjust its Start and End beats.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                ScratchPhraseChartView(
                    source: .canonical(projection.records, layer: .performance, frame: frame),
                    bpm: chartBPM,
                    showBeatGrid: reviewTake?.evidence.metadata.captureIntent?.isMovementCheck != true,
                    wrapPeriod: wrapPeriod,
                    backgroundColor: .clear
                )
                // Bounded, never `maxHeight: .infinity`: this card also lives
                // inside an unbounded `ScrollView`, where `.infinity` resolves
                // to the IDEAL height and collapses the lane — the same trap
                // documented on `liveNotationMinimumHeight`.
                .frame(maxWidth: .infinity, minHeight: Self.canonicalTearChartMinimumHeight)
                .clipped()
                .overlay {
                    if let selectedRange, !zoomed {
                        ReferenceMotionSelectionOverlay(selectedRange: selectedRange, viewport: frame.timeRange)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ScratchPhraseChartView(
                    source: .empty(emptyMessage),
                    bpm: chartBPM,
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

    /// The recorded technique owns its review, independently of the next Setup.
    /// Shared motion geometry remains available without offering Tear corrections
    /// or labeling a different technique as a canonical Tear.
    private func recordedMotionSection(_ take: ReferenceAuthoringTake) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(take.evidence.metadata.technique.displayName) motion review").font(.headline)
            canonicalTearChart(
                title: "RECORDED PLATTER AND FADER MOTION",
                projection: take.tearProjection,
                emptyMessage: "No recorded platter motion is available.",
                recordedBPM: take.evidence.metadata.bpm,
                reviewTake: take
            )
            Text("\(take.tearReview.rawMovementEvents.count) platter movements · \(take.tearReview.faderIntervals.count) fader state intervals · \(take.tearReview.faderClicks.count) fader clicks")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Tear segmentation review

    #if DEBUG
    /// Explicit internal comparison of the current take; no capture or approval mutation.
    @ViewBuilder
    private func tearComparisonSection(_ take: ReferenceAuthoringTake) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tear comparison preview").font(.headline)
            Text("Internal provisional comparison: choose an authored teaching target and the performed gestures to compare. This preview does not approve a take or enable training.")
                .font(.caption).foregroundStyle(.secondary)
            Text(ReferenceAuthoringViewModel.tearComparisonToleranceText)
                .font(.caption).foregroundStyle(.secondary)
            Picker("Authored target", selection: Binding(
                get: { viewModel.tearComparisonTargetID },
                set: { viewModel.selectTearComparisonTarget($0) }
            )) {
                Text("Choose a target").tag(String?.none)
                ForEach(viewModel.tearComparisonTargets) { target in
                    Text(ReferenceAuthoringViewModel.tearComparisonTargetTitle(target)).tag(Optional(target.id))
                }
            }
            Picker("First performed gesture", selection: Binding(
                get: { viewModel.tearComparisonStartID },
                set: { viewModel.selectTearComparisonStart($0) }
            )) {
                Text("Choose a gesture").tag(String?.none)
                ForEach(viewModel.tearComparisonCandidates) { candidate in
                    Text(ReferenceAuthoringViewModel.tearComparisonCandidateTitle(candidate)).tag(Optional(candidate.id))
                }
            }
            Picker("Last performed gesture", selection: Binding(
                get: { viewModel.tearComparisonEndID },
                set: { viewModel.selectTearComparisonEnd($0) }
            )) {
                Text("Choose the range end").tag(String?.none)
                ForEach(viewModel.tearComparisonEndCandidates) { candidate in
                    Text(ReferenceAuthoringViewModel.tearComparisonCandidateTitle(candidate)).tag(Optional(candidate.id))
                }
            }
            .disabled(viewModel.tearComparisonStartID == nil)
            Text("Every gesture between the selected endpoints is included, in recorded order.")
                .font(.caption).foregroundStyle(.secondary)
            if let first = viewModel.tearComparisonSelectedCandidates.first {
                Text(String(format: "Alignment: %.3f s in this take → target beat 0, at %d BPM. Timing is relative to the selected start.",
                            first.span.startTime, take.evidence.metadata.bpm))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Compare from selected start") { viewModel.compareSelectedTear() }
                .disabled(viewModel.tearComparisonBlockReason != nil)
            if let reason = viewModel.tearComparisonBlockReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let result = viewModel.tearComparisonResult {
                ForEach(Array(result.dimensions.enumerated()), id: \.offset) { _, dimension in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(dimension.axis.title).font(.callout.weight(.semibold))
                            Spacer()
                            Text(dimension.assessment.title)
                            if let score = dimension.scorePercentage {
                                Text(String(format: "%.0f%%", score))
                            }
                        }
                        ForEach(Array(dimension.unavailableReasons.enumerated()), id: \.offset) { _, reason in
                            Text(reason.title).font(.caption).foregroundStyle(.secondary)
                        }
                        if !dimension.measurements.isEmpty {
                            DisclosureGroup("Evidence and differences") {
                                ForEach(Array(dimension.measurements.enumerated()), id: \.offset) { _, measurement in
                                    Text(measurement.detail).font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                SemanticErrorListView(errors: result.semanticErrors, maxErrors: result.semanticErrors.count)
                ForEach(Array(result.coaching.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.callout)
                }
            }
        }
    }
    #endif

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
                projection: take.tearProjection,
                emptyMessage: "No tear structure could be placed from this take's evidence.",
                recordedBPM: take.evidence.metadata.bpm,
                reviewTake: take
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

    private func validationFindings(_ findings: [ReferenceValidationFinding]) -> some View {
        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
            HStack(alignment: .top) {
                Image(systemName: finding.severity == .failure ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(finding.severity == .failure ? .red : .orange)
                Text(finding.message).font(.callout)
            }
        }
    }

    private func repetitionRow(
        _ boundary: ReferenceRepetitionBoundary,
        take: ReferenceAuthoringTake
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Repetition \(boundary.index + 1)").font(.callout.weight(.semibold))
                Spacer()
                Button(focusedBoundary(for: take)?.index == boundary.index ? "Notation highlighted" : "Show notation") {
                    focusMotion(on: boundary, take: take)
                }
                Button(take.evidence.boundaries.selectedRepetitionIndex == boundary.index ? "Selected" : "Select for Approval") {
                    focusMotion(on: boundary, take: take)
                    viewModel.selectRepetitionForApproval(boundary.index)
                }
                .disabled(!viewModel.canEditReviewedTake || take.evidence.boundaries.selectedRepetitionIndex == boundary.index)
            }
            HStack {
                ReferenceRepetitionPlaybackControls(controller: viewModel.mediaReview, boundary: boundary, take: take,
                    onPlay: { focusMotion(on: boundary, take: take) })
                Stepper(
                    "Start beat \(boundary.startBeat, specifier: "%.2f")",
                    value: startBeatBinding(for: boundary),
                    in: 0...Double(take.evidence.metadata.totalBeats),
                    step: 0.25
                )
                .disabled(!viewModel.canEditReviewedTake)
                Stepper(
                    "End beat \(boundary.endBeat, specifier: "%.2f")",
                    value: endBeatBinding(for: boundary),
                    in: 0...Double(take.evidence.metadata.totalBeats),
                    step: 0.25
                )
                .disabled(!viewModel.canEditReviewedTake)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if focusedBoundary(for: take)?.index == boundary.index {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    private func focusedBoundary(for take: ReferenceAuthoringTake) -> ReferenceRepetitionBoundary? {
        let index = motionReviewFocus?.takeID == take.id
            ? motionReviewFocus?.repetitionIndex : take.evidence.boundaries.selectedRepetitionIndex
        return take.evidence.boundaries.repetitions.first { $0.index == index }
    }

    private func focusMotion(on boundary: ReferenceRepetitionBoundary, take: ReferenceAuthoringTake) {
        motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary.index,
            isZoomed: motionReviewFocus?.takeID == take.id && motionReviewFocus?.isZoomed == true)
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

private struct CompanionRelaySetupView: View {
    @ObservedObject var receiver: CompanionCameraReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(
                receiver.isBrowsingForPeers
                    ? "iPhone & Watch Relay Enabled"
                    : "Enable iPhone & Watch Relay"
            ) {
                receiver.startBrowsingForCompanionIfNeeded()
            }
            .disabled(receiver.isBrowsingForPeers)
            .accessibilityIdentifier("cxl.hardware.enableCompanionRelay")

            Text(receiver.connectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Nearby-device discovery and its local-network permission start only after this button is pressed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReferenceMediaReviewStatus: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Play whole take") { controller.playWholeTake() }
                    .disabled(!controller.canPlay)
                Button("Stop playback") { controller.stop() }
                    .disabled(!controller.canPlay)
            }
            if let player = controller.videoPlayer {
                ReferenceRecordedVideo(player: player)
                    .frame(height: 240)
            }
            Text(summary).font(.caption)
                .foregroundStyle(isBlocking ? Color.orange : Color.secondary)
            if let message = controller.playbackMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let issue = controller.beatBindingIssue {
                Text("Recorded audio/video can be played. Beat validation for approval is unavailable: \(issue)")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let beat = controller.boundBeatID {
                Text("Exact beat binding: \(beat) · production and sparse mix hashes verified")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isBlocking: Bool {
        switch controller.state {
        case .ready, .playing, .playingTake, .stopped, .missingVideo: false
        default: true
        }
    }

    private var summary: String {
        switch controller.state {
        case .loading: "Loading the recorded audio and video…"
        case .ready: "Recorded audio and video are ready to play."
        case .playing(let repetition): "Playing repetition \(repetition + 1) from finalized media."
        case .playingTake: "Playing the whole recorded take."
        case .stopped: "Finalized-media audition stopped."
        case .missingAudio: "Required finalized WAV is missing; approval is blocked."
        case .missingVideo: "Optional finalized MOV is absent; WAV audition remains available."
        case .unreadableMedia(let file): "Finalized media is unreadable: \(file)."
        case .durationMismatch(let wav, let mov):
            String(format: "WAV/MOV duration mismatch: %.3f s / %.3f s.", wav, mov)
        case .synchronizationUnavailable(let detail): "Synchronization unavailable: \(detail)"
        }
    }
}

private struct ReferenceRepetitionPlaybackControls: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    let boundary: ReferenceRepetitionBoundary
    let take: ReferenceAuthoringTake
    var onPlay: () -> Void = {}

    var body: some View {
        HStack {
            Button("Play repetition") {
                onPlay()
                controller.play(repetition: boundary, take: take)
            }
                .disabled(!controller.canPlay)
            Button("Stop") { controller.stop() }
                .disabled(!controller.canPlay)
        }
    }
}

/// The route owns the tracker's lifetime; this child observes its bounded
/// publications so live geometry refreshes even when hardware UI is quiet.
private struct ReferenceLiveMotionContent<Content: View>: View {
    @ObservedObject var tracker: LivePerformedNotationTracker
    let content: (LivePerformedNotationTracker) -> Content

    var body: some View { content(tracker) }
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

/// The buttons above own audition ranges; hide competing native transport
/// controls so seeking or pausing cannot invalidate a selected repetition.
private struct ReferenceRecordedVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}


private struct ReferenceMotionReviewFocus {
    let takeID: String
    let repetitionIndex: Int
    let isZoomed: Bool
}

/// Presentation-only coordinates. Full records and their vertical frame stay
/// unchanged; beats use the same measured media origin as audio audition.
enum ReferenceMotionReviewViewport {
    static func range(for boundary: ReferenceRepetitionBoundary,
                      metadata: ReferenceTakeMetadata, recordedEnd: Double) -> ClosedRange<Double>? {
        ReferenceMediaTimeRange.clamped(start: boundary.startSeconds(metadata: metadata),
            end: boundary.endSeconds(metadata: metadata), duration: recordedEnd)
    }

    static func frame(_ fullFrame: ScratchStrokeGeometry.CanonicalFrame,
                      selectedRange: ClosedRange<Double>?, zoomed: Bool) -> ScratchStrokeGeometry.CanonicalFrame {
        guard zoomed, let selectedRange else { return fullFrame }
        return ScratchStrokeGeometry.CanonicalFrame(timeRange: selectedRange,
            positionRange: fullFrame.positionRange, coordinateSpace: fullFrame.coordinateSpace,
            beatsPerMinute: fullFrame.beatsPerMinute) ?? fullFrame
    }

    static func visibleFractions(_ selection: ClosedRange<Double>,
                                 in viewport: ClosedRange<Double>) -> ClosedRange<Double>? {
        let span = viewport.upperBound - viewport.lowerBound
        guard span.isFinite, span > 0 else { return nil }
        let start = max(selection.lowerBound, viewport.lowerBound)
        let end = min(selection.upperBound, viewport.upperBound)
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return ((start - viewport.lowerBound) / span)...((end - viewport.lowerBound) / span)
    }
}

private struct ReferenceMotionSelectionOverlay: View {
    let selectedRange: ClosedRange<Double>
    let viewport: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let fractions = ReferenceMotionReviewViewport.visibleFractions(selectedRange, in: viewport)
            let startX = CGFloat(fractions?.lowerBound ?? 1) * size.width
            let endX = CGFloat(fractions?.upperBound ?? 1) * size.width
            var outside = Path()
            outside.addRect(CGRect(x: 0, y: 0, width: startX, height: size.height))
            outside.addRect(CGRect(x: endX, y: 0, width: max(0, size.width - endX), height: size.height))
            context.fill(outside, with: .color(.black.opacity(0.5)))
            if fractions != nil {
                let selection = Path(CGRect(x: startX, y: 0, width: endX - startX, height: size.height))
                context.stroke(selection, with: .color(.accentColor.opacity(0.75)), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Digital sample-peak display, independent of Rane input gain or cue position.
/// The source reports true zero separately from an unavailable/stale callback.
enum CXLScratchOutputMeter {
    static func decibels(peak: Float?) -> Double? {
        guard let peak, peak.isFinite, peak >= 0 else { return nil }
        return peak == 0 ? -.infinity : 20 * log10(Double(peak))
    }

    static func litSegments(peak: Float?) -> Int {
        guard let db = decibels(peak: peak), db > -60 else { return 0 }
        return min(20, max(0, Int(ceil((min(db, 0) + 60) / 3))))
    }

    static func label(peak: Float?) -> String {
        guard let db = decibels(peak: peak) else { return "Unavailable" }
        if db == -.infinity { return "Silent" }
        if db < -60 { return "Below −60 dBFS" }
        return String(format: "%.1f dBFS", db)
    }
}
