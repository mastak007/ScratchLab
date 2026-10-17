// ReferenceAuthoringView.swift
// ScratchLabDesktop

import Combine
import AppKit
import AVKit
import SwiftUI

struct ReferenceAuthoringView: View {
    @StateObject private var viewModel: ReferenceAuthoringViewModel
    /// The full setup form needs current hardware state, not a new layout for
    /// every hand, meter and playhead publication. Live leaves observe their
    /// own data; form refreshes are coalesced without changing capture cadence.
    private let captureEngine: MacCaptureEngine
    @StateObject private var captureRefresh: ReferenceCaptureRefresh
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
    @State private var isCaptureFocused: Bool
    @State private var isShowingMIDIAddressDiagnostics = false
    private var selectedCapturePath: PhaseCapturePath? { captureEngine.phaseCapturePath }
    private var capturePathBinding: Binding<PhaseCapturePath?> {
        Binding(get: { captureEngine.phaseCapturePath }, set: { path in
            if path == .dvsThroughDJMS9 { _ = captureEngine.selectPhaseDVSInput() }
            else { captureEngine.selectExistingCapturePath() }
        })
    }
    @State private var selectedMIDIProfileID = "automatic"
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
    @State private var reviewMotionDisplay: ReferenceMotionDetailPages.Display = .recordedTravel
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

    /// The capture board keeps both camera feeds and both timing surfaces in
    /// the first desktop viewport while a take is running.
    private static let captureBoardCameraHeight: CGFloat = 380
    private static let captureBoardSecondaryCameraWidth: CGFloat = 250
    private static let captureBoardNotationHeight: CGFloat = 210

    /// Drawing height for the canonical tear chart's lane.
    ///
    /// Gives the review chart enough vertical range for direction changes to
    /// remain readable across a wide desktop window.
    private static let canonicalTearChartMinimumHeight: CGFloat = 240

    init(
        engine: MacCaptureEngine,
        companionReceiver: CompanionCameraReceiver?,
        operatorName: String,
        startsInCaptureView: Bool = false
    ) {
        _isCaptureFocused = State(initialValue: startsInCaptureView)
        captureEngine = engine
        _captureRefresh = StateObject(wrappedValue: ReferenceCaptureRefresh(
            changes: engine.objectWillChange.eraseToAnyPublisher()))
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
        let _ = captureRefresh
        ScrollViewReader { scroll in
        VStack(spacing: 0) {
        if isCaptureFocused {
            focusedCaptureContent
        } else {
        ScrollView {
            authoringFormContent
        }
        .onAppear {
            if case .reviewing = viewModel.session.phase {
                scroll.scrollTo(ReferenceAuthoringNavigationRequest.Destination.review.rawValue, anchor: .top)
            }
        }
        }
        }
        .onChange(of: viewModel.navigationRequest) { _, request in
            guard let request else { return }
            withAnimation { scroll.scrollTo(request.destination.rawValue, anchor: .top) }
        }

        .task {
            await viewModel.refreshSavedDrafts()
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
        .onChange(of: viewModel.reviewedTake?.id) { _, _ in
            motionReviewFocus = nil
            reviewMotionDisplay = .recordedTravel
        }
        .onChange(of: viewModel.reviewedTake?.evidence.boundaries.repetitions) { _, _ in
            // A trim changes the inspected window; restore the compact chart height.
            motionReviewFocus?.heightScale = 1
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
        .onChange(of: viewModel.session.phase == .recording) { _, isRecording in
            syncLiveNotationTracker(mode: resolvedLiveNotationMode)
            if !isRecording, case .reviewing = viewModel.session.phase {
                isCaptureFocused = false
            }
        }
        .onReceive(captureEngine.$isRoutineRecording.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)) { isRecording in
            if !isRecording { viewModel.captureRecordingDidStop() }
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
            captureEngine.disableCXLCameraGuide()
        }
        }
    }

    private var authoringFormContent: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("SL Capture Reference Authoring")
                    .font(.title2.weight(.semibold))
                Text("Check one movement without a beat, or record four timed repetitions for reference review. Approval does not install or publish training data.")
                    .foregroundStyle(.secondary)



                messagePanel
                savedDraftsSection
                if !viewModel.isReviewingSavedDraft {
                    stageHeading("Setup")
                        .id(ReferenceAuthoringNavigationRequest.Destination.setup.rawValue)
                    hardwareSetupSection
                    setupSection
                    calibrationSection
                    preflightSection
                    stageHeading("Capture")
                        .id(ReferenceAuthoringNavigationRequest.Destination.capture.rawValue)
                    recordingSection
                }
                stageHeading("Review & Export")
                    .id(ReferenceAuthoringNavigationRequest.Destination.review.rawValue)
                reviewSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Picker("Capture pathway", selection: capturePathBinding) {
                    Text("Existing hardware route").tag(nil as PhaseCapturePath?)
                    Text("Phase DVS + DJM-S9").tag(PhaseCapturePath.dvsThroughDJMS9 as PhaseCapturePath?)
                }
                .pickerStyle(.menu)
                .disabled(hardwareSelectionIsLocked)
                if selectedCapturePath == .dvsThroughDJMS9 {
                    Text(PhaseCapturePath.dvsThroughDJMS9.setupInstruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Connect Phase Input") { captureEngine.enablePhaseInput() }
                        Button("Check Forward") { captureEngine.beginPhaseForwardCheck() }
                        Button("Confirm Forward") { captureEngine.confirmPhaseForwardCheck() }
                    }
                    .disabled(hardwareSelectionIsLocked)
                    Text(captureEngine.phaseInputStatus).font(.caption).foregroundStyle(.secondary)
                }

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

                Picker("Controller profile", selection: $selectedMIDIProfileID) {
                    Text("Automatic / Custom MIDI Learn").tag("automatic")
                    ForEach(availableMIDIProfileOptions, id: \.identifier) { profile in
                        Text(profile.displayName).tag(profile.identifier)
                    }
                }
                .pickerStyle(.menu)
                .disabled(hardwareSelectionIsLocked)
                .onChange(of: selectedMIDIProfileID) { _, profileID in
                    guard profileID != "automatic",
                          let source = captureEngine.availableMIDISources.first(where: {
                              MIDIHardwareRegistry.shared.bestMatch(
                                  for: MIDIDeviceIdentity(sourceName: $0.name)
                              )?.profile.identifier == profileID
                    }) else {
                        return
                    }
                    captureEngine.selectedMIDIInputSourceID = source.id
                }
                .onChange(of: captureEngine.selectedMIDIInputSourceID) { _, sourceID in
                    selectedMIDIProfileID = profileIdentifier(for: sourceID)
                }
                .onChange(of: captureEngine.availableMIDISources) { _, _ in
                    selectedMIDIProfileID = profileIdentifier(for: captureEngine.selectedMIDIInputSourceID)
                }

                Text("Known DDJ and DJM-S9 profiles appear when their MIDI endpoint is connected. For any other controller, leave this on Automatic / Custom MIDI Learn and use the mapping panel below to learn the crossfader and both deck faders from the controls you move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let profile = MIDIHardwareRegistry.shared.bestMatch(
                    for: MIDIDeviceIdentity(sourceName: captureEngine.selectedMIDIInputSourceName)
                )?.profile,
                   profile.identifier != "pioneer-djm-s9",
                   profile.identifier != "rane-one" {
                    Text("Profile: \(profile.displayName) · \(profile.deckCount) deck MIDI layout · verification required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(
                    "MIDI: \(captureEngine.selectedMIDIInputSourceName) "
                        + "[\(captureEngine.selectedMIDIInputSourceID)] · "
                        + "\(captureEngine.midiListeningState) · "
                        + captureEngine.lastMIDICCMessage
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                if MIDIHardwareRegistry.shared.bestMatch(
                    for: MIDIDeviceIdentity(sourceName: captureEngine.selectedMIDIInputSourceName)
                )?.profile.identifier == "pioneer-djm-s9" {
                    Label {
                        Text(PhaseCapturePath.dvsThroughDJMS9.setupInstruction)
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cxl.hardware.phaseDVSSetup")
                }

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

                Picker("Separate Twelve platter", selection: Binding(
                    get: { captureEngine.selectedTwelveMIDIInputSourceID },
                    set: { captureEngine.selectTwelveMIDIInput(sourceID: $0) }
                )) {
                    Text("None — use main MIDI source").tag("")
                    ForEach(captureEngine.availableMIDISources.filter { $0.id != captureEngine.selectedMIDIInputSourceID }) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .disabled(audioSelectionIsLocked || viewModel.isWorking || exportCoordinator.isPreparing)
                Text(captureEngine.twelveMIDIStatus).font(.caption).foregroundStyle(.secondary)
                Text("For Seventy-Two + Twelve: select the mixer above for faders and hot cues, then the Twelve here. Set the Twelve to Deck 2. Confirm forward/back movement before recording.")
                    .font(.caption).foregroundStyle(.secondary)

                MacMIDIControlSetupView(captureEngine: captureEngine)
                    .disabled(viewModel.isWorking || exportCoordinator.isPreparing)
                    .onChange(of: captureEngine.scratchUSBOutputPairsByUID) { _, _ in viewModel.stopBeatPreview() }

                cameraSetupControls

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

                Text(selectedCapturePath == .dvsThroughDJMS9
                    ? "Phase B: control tone on S9 USB 3/4; Serato programme on 5/6. Serato provides the scratch sound. Keep the verified mixer routing unchanged."
                    : "This selects the audio device only. This screen does not yet prove a specific input pair or physical master-return signal.")
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
                    CompanionRelaySetupView(receiver: companionReceiver, locked: cameraSelectionIsLocked)
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

    private var cameraSetupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Camera input", selection: videoInputSelectionBinding) {
                Text("Choose a camera…").tag("")
                ForEach(captureEngine.availableVideoDevices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .pickerStyle(.menu)
            .disabled(cameraSelectionIsLocked)
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

            SecondaryCameraSetupView(recorder: captureEngine.secondaryCamera,
                devices: captureEngine.availableVideoDevices,
                primaryID: captureEngine.selectedVideoDeviceUniqueID, locked: cameraSelectionIsLocked)

            Button("Reconnect selected cameras") {
                captureEngine.reconnectSelectedVideoInput()
                if let device = captureEngine.availableVideoDevices.first(where: {
                    $0.uniqueID == captureEngine.secondaryCamera.selectedID
                }) {
                    captureEngine.secondaryCamera.configure(device: device,
                        primaryID: captureEngine.selectedVideoDeviceUniqueID)
                }
            }
            .disabled(cameraSelectionIsLocked || !captureEngine.isRoutineCaptureReady)
            Text("You can change either camera between takes. Reconnect retries the current cameras; saved recordings keep their original views.")
                .font(.caption).foregroundStyle(.secondary)

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

    private var cameraSelectionIsLocked: Bool {
        audioSelectionIsLocked || exportCoordinator.isPreparing
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

    private var availableMIDIProfileOptions: [MIDIControllerProfile] {
        var profiles: [MIDIControllerProfile] = []
        for source in captureEngine.availableMIDISources {
            guard let profile = MIDIHardwareRegistry.shared.bestMatch(
                for: MIDIDeviceIdentity(sourceName: source.name)
            )?.profile,
            profile.identifier != "rane-one",
            !profiles.contains(where: { $0.identifier == profile.identifier }) else {
                continue
            }
            profiles.append(profile)
        }
        return profiles.sorted { $0.displayName < $1.displayName }
    }

    private func profileIdentifier(for sourceID: String) -> String {
        guard let source = captureEngine.availableMIDISources.first(where: { $0.id == sourceID }),
              let profile = MIDIHardwareRegistry.shared.bestMatch(
                  for: MIDIDeviceIdentity(sourceName: source.name)
              )?.profile,
              ["pioneer-ddj-rev5", "pioneer-ddj-rev7", "pioneer-ddj-flx10", "pioneer-djm-s9"].contains(profile.identifier) else {
            return "automatic"
        }
        return profile.identifier
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
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
        let isPhase = selectedCapturePath == .dvsThroughDJMS9
        let level = isPhase ? captureEngine.phaseInputSnapshot()?.programmePeak : captureEngine.activeScratchOutputSignalLevel
        let litSegments = CXLScratchOutputMeter.litSegments(peak: level)
        let levelText = CXLScratchOutputMeter.label(peak: level)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isPhase ? "S9 programme input · USB 5/6" : captureEngine.scratchOutputSignalSourceLabel)
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
            .accessibilityLabel(isPhase ? "S9 programme input level" : "ScratchLab AHHH output level")
            .accessibilityValue(levelText)

            // This meter appears twice above Review. Inserting/removing its
            // warning whenever callbacks go stale shifts the entire document,
            // including controls that are currently below the viewport.
            Text(level == nil
                 ? (isPhase ? "Connect the Phase input to read programme audio." : "Waiting for ScratchLab output. Load AHHH if no sample is loaded.")
                 : "Output meter is receiving samples.")
                .font(.caption)
                .foregroundStyle(level == nil ? Color.orange : Color.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cxl.capture.audioMeterStatus")
        }
        .accessibilityIdentifier("cxl.capture.audioMeter")
        }
    }

    private var phaseAudioOwnerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Serato provides the scratch sound").font(.headline)
            Text("Right deck: REL. Phase B RCA to S9 channel 2 LINE. SL Capture records control tone on USB 3/4 and programme audio on 5/6.")
            Text("Use Serato to load and cue AHHH. Keep other decks and mixer effects out of this scratch-only return.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var scratchOutputRoutingControls: some View {
        if selectedCapturePath == .dvsThroughDJMS9 {
            phaseAudioOwnerContent
        } else {
        VStack(alignment: .leading, spacing: 6) {
            Picker("AHHH output", selection: Binding(
                get: { captureEngine.scratchPrimaryOutput },
                set: { viewModel.stopBeatPreview(); captureEngine.setScratchPrimaryOutput($0) }
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
            Text(captureEngine.scratchPrimaryOutput == .rane
                 ? "Beat and scratch use the USB pairs in Mixer & Hot-Cue Mapping. Automatic routing on Rane ONE uses beat 1/2 and scratch 3/4. Check both in headphones; configure the Seventy-Two pairs explicitly."
                 : "Beat and count-in follow the Mac output. Choose Rane output to hear both decks through the Rane headphones.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Capture keeps scratch and beat separate for scratch-only, beat-only and scratch-with-beat export.")
                .font(.caption).foregroundStyle(.secondary)
            Text("This meter and the saved take use ScratchLab's generated scratch audio. The Rane's physical mixer can change the sound afterward.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("cxl.hardware.scratchOutputRouting")
        }
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
                ),
                preparesCanonicalProjection: true
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
    @State private var selectedScratchSampleID = "dvs_ahhh"

    @ViewBuilder
    private var samplePositionContent: some View {
        if selectedCapturePath == .dvsThroughDJMS9 {
            phaseAudioOwnerContent
        } else {
        VStack(alignment: .leading, spacing: 6) {
            ReferenceCaptureWaveform(engine: captureEngine)
            .frame(height: 112)

            HStack {
                Picker("Scratch sample", selection: $selectedScratchSampleID) {
                    Text("AHHH").tag("dvs_ahhh")
                    Text("Fresh").tag("fresh")
                    Text("Ah yeah").tag("ah_yeah")
                    Text("Check it out").tag("check_it_out")
                }
                Button("Load / Re-cue") {
                    captureEngine.loadScratchSample(selectedScratchSampleID)
                }
            }
            .disabled(viewModel.isWorking || captureEngine.isAudioInputSelectionLocked || exportCoordinator.isPreparing)
            Text("Load a sample, then move the right platter. Load / Re-cue returns to its start without playing a preview.")
                .font(.caption).foregroundStyle(.secondary)
            if !captureEngine.platterTestLoadStatus.isEmpty {
                Text(captureEngine.platterTestLoadStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if captureEngine.playbackWaveformSnapshot != nil {
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
        captureBoard(cameraHeight: Self.captureBoardCameraHeight,
                     notationHeight: Self.canonicalTearChartMinimumHeight,
                     showsSetupControls: true)
    }

    private func captureBoard(cameraHeight: CGFloat, notationHeight: CGFloat,
                              showsSetupControls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                captureBoardTile(selectedCapturePath == .dvsThroughDJMS9 ? "SERATO AUDIO" : "AHHH PLAYHEAD") {
                    verticalSamplePositionContent(cameraHeight: cameraHeight, showsSetupControls: showsSetupControls)
                }
                .frame(width: 132)

                captureBoardTile("MAIN CAMERA") {
                    VStack(alignment: .leading, spacing: 6) {
                        CXLCameraCalibrationPreview(
                            captureEngine: captureEngine,
                            previewHeight: cameraHeight,
                            captureInProgress: !showsSetupControls || viewModel.isWorking || viewModel.session.phase == .recording,
                            showsCalibrationControls: showsSetupControls,
                            keepsCameraGuideOnDisappear: true
                        )
                        .overlay {
                            if !captureEngine.isCameraActive && !showsSetupControls {
                                Text("Camera preview is not running. Return to setup to activate the selected camera.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            }
                        }
                        if showsSetupControls && !captureEngine.isCameraActive {
                            Text("Camera preview is not running. Recording is blocked until the selected camera is active.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                if showsSetupControls || !captureEngine.secondaryCamera.selectedID.isEmpty {
                captureBoardTile("IPHONE / SECOND CAMERA") {
                    SecondaryCameraLiveView(
                        recorder: captureEngine.secondaryCamera,
                        // Reserve its spacing and two-line status inside this tile.
                        previewHeight: max(0, cameraHeight - 36)
                    )
                    .frame(width: Self.captureBoardSecondaryCameraWidth,
                           height: cameraHeight,
                           alignment: .top)
                    .background(Color.black)
                }
                .frame(width: Self.captureBoardSecondaryCameraWidth)
                }
            }

            captureBoardTile("LIVE NOTATION") {
                liveNotationContent(chartHeight: notationHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func verticalSamplePositionContent(cameraHeight: CGFloat, showsSetupControls: Bool) -> some View {
        if selectedCapturePath == .dvsThroughDJMS9 {
            if showsSetupControls {
                phaseAudioOwnerContent
            } else {
                Text("Serato scratch audio\nProgramme input\nUSB 5/6")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: cameraHeight, alignment: .center)
            }
        } else {
        VStack(alignment: .center, spacing: 8) {
            ReferenceCaptureWaveform(engine: captureEngine)
            .frame(width: cameraHeight, height: 104)
            .rotationEffect(.degrees(-90))
            .frame(width: 104, height: cameraHeight)

            if showsSetupControls && captureEngine.playbackWaveformSnapshot == nil {
                Button("Load AHHH") { captureEngine.loadPlatterTestSample() }
                    .disabled(viewModel.isWorking || captureEngine.isAudioInputSelectionLocked)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: cameraHeight, alignment: .top)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func captureBoardTile<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func liveNotationContent(chartHeight: CGFloat) -> some View {
        if let liveNotationTracker {
            ReferenceLiveMotionContent(tracker: liveNotationTracker) { liveNotationTracker in
                canonicalTearChart(
                    title: viewModel.selectedTechnique.map {
                        "YOUR MOTION — LIVE (\($0.displayName.uppercased()))"
                    } ?? "YOUR MOTION — LIVE",
                    projection: liveNotationTracker.canonicalProjection,
                    emptyMessage: "Waiting for movement…",
                    preparedReasons: liveNotationTracker.canonicalProjection.reasons,
                    preparedChart: liveNotationTracker.presentation.canonicalChart,
                    isLive: true,
                    chartHeight: chartHeight
                )
            }
            .frame(maxWidth: .infinity, minHeight: Self.captureBoardNotationHeight)
            #if DEBUG
            LiveNotationDiagnosticsRow(tracker: liveNotationTracker)
            #endif
        } else {
            Text("Live motion appears here while this screen is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.captureBoardNotationHeight, alignment: .topLeading)
        }
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

    private var savedDraftsSection: some View {
        GroupBox {
            DisclosureGroup("Saved drafts (\(viewModel.savedDrafts.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Finalized takes are saved on this Mac. Record now and reopen a draft here for review later. Keep the original recordings in the capture library.")
                        .font(.caption).foregroundStyle(.secondary)
                    if viewModel.savedDrafts.isEmpty {
                        Text("No saved drafts yet. New finalized takes will appear here.")
                            .font(.caption)
                    }
                    ForEach(viewModel.savedDrafts) { draft in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(draft.title).font(.callout)
                                Text("\(draft.status) · \(draft.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open for Review") { viewModel.reopenDraft(draft.id) }
                                .disabled(!viewModel.canOpenSavedDraft || exportCoordinator.isPreparing || draft.status == "Rejected")
                        }
                    }
                }.padding(.top, 8)
            }
            if let error = viewModel.draftSaveError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = viewModel.draftLibraryError {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var setupSection: some View {
        GroupBox("1. Technique, pattern and variant") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("DJ / performer name", text: $viewModel.performerName)
                    .disabled(viewModel.isWorking || viewModel.session.captureIntent != nil)
                Text("Enter the DJ who is performing. Use New scratch before changing performers.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Button(viewModel.isPreparingBeatPreview ? "Cancel preview preparation" : (viewModel.isPreviewingBeat ? "Stop preview" : "Preview backing sound")) {
                    viewModel.toggleBeatPreview()
                }
                Text("Six original backing variations are available: Dusty Break, Funk Pocket, Battle Break, Ghost Pocket, Pocket Double, and Drop Theory. Click track plays metronome clicks only. Preview follows the chosen output and does not record.")
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
                Text("Starting direction is your first record movement: push forward or pull back. Handedness is the hand moving the record. If using a Watch, wear it on that wrist.")
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
                    // Status changes update the same cell. Moving live checks
                    // between grids and full-width rows made the page jump.
                    preflightGrid(preflight.checks)
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

    private func preflightGrid(_ checks: [ReferencePreflightCheck]) -> some View {
        // This is a small, bounded checklist in a longer scroll document.
        // Measure every row now: lazy offscreen height estimates can move the
        // current scroll offset when a live status changes below the viewport.
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: checks.count, by: 2)), id: \.self) { index in
                GridRow(alignment: .top) {
                    preflightRow(checks[index])
                    if index + 1 < checks.count {
                        preflightRow(checks[index + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
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
                Text(check.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
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

    private func startFocusedRecording() {
        guard canRecord else { return }
        isCaptureFocused = true
        viewModel.startRecording()
    }

    private var canLeaveCaptureView: Bool {
        !viewModel.isWorking && !viewModel.isPreparingRecordedTake
            && !captureEngine.isRoutineRecording && !captureEngine.isRoutineFinalizationPending
    }

    /// Replaces the form in the same window. The lifecycle modifiers remain
    /// outside this branch, so entering focus cannot create another session,
    /// re-arm the take's MIDI window, or cancel the in-flight finalization.
    private var focusedCaptureContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPTURE").font(.headline)
                    Text(viewModel.workflowStatusText)
                        .font(.caption.monospacedDigit()).lineLimit(1)
                }
                Spacer()
                Button("Record") { startFocusedRecording() }
                    .disabled(!canRecord)
                Button("Stop and Finalize") { viewModel.stopRecording() }
                    .disabled(!viewModel.canStopRecording)
                Button("Back to setup") { isCaptureFocused = false }
                    .disabled(!canLeaveCaptureView)
            }
            .frame(height: 48)
            .accessibilityIdentifier("cxl.capture.focusControls")

            GeometryReader { geometry in
                let layout = ReferenceCaptureFocusLayout(availableHeight: geometry.size.height)
                captureBoard(cameraHeight: layout.cameraHeight,
                             notationHeight: layout.notationHeight,
                             showsSetupControls: false)
            }

            // Messages retain their full text without changing board height.
            ScrollView {
                Text(viewModel.visibleMessage ?? "Wait for Recording started before performing.")
                    .font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 44)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("cxl.capture.focusedWorkspace")
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
                        startFocusedRecording()
                    }
                    .disabled(!canRecord)
                    Button("Open Capture View") { isCaptureFocused = true }
                        .disabled(viewModel.isWorking)
                    Button("Stop and Finalize") {
                        viewModel.stopRecording()
                    }
                    .disabled(!viewModel.canStopRecording)
                    if viewModel.isPreparingRecordedTake {
                        ProgressView().controlSize(.small)
                    }
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
            let reason = viewModel.continuationBlockReason(newScratch: true,
                isExportPreparing: exportCoordinator.isPreparing)
            // Keep the save-status slot at its natural wrapped height so
            // committing a trim does not move the notation below it.
            Text(reason ?? "Wait for the current operation to finish.")
                .font(.caption).foregroundStyle(.secondary)
                .opacity(reason == nil ? 0 : 1)
                .accessibilityHidden(reason == nil)
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

    private func saveRawCapture(approvingCanonical: Bool = false) {
        Task {
            guard let source = await viewModel.rawCaptureExportSource(
                config: captureEngine.recordingSessionConfig,
                approvingCanonical: approvingCanonical
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
                    if !viewModel.isReviewingSavedDraft {
                        Button("Change cameras for next take") { viewModel.showCameraSetup() }
                            .disabled(!viewModel.canOpenSavedDraft || cameraSelectionIsLocked)
                    }
                    HStack {
                        Button("Save for Later") { viewModel.saveDraftForLater() }
                            .disabled(!viewModel.canOpenSavedDraft || exportCoordinator.isPreparing)
                        if viewModel.draftSaveError == nil,
                           viewModel.savedDrafts.contains(where: { $0.id == take.id }) {
                            Text("Draft saved on this Mac. Detailed review can wait.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    evidenceSummary(take)
                    ReferenceMediaReviewStatus(controller: viewModel.mediaReview,
                        showsVideo: focusedBoundary(for: take) == nil)
                    if viewModel.isShowingReadOnlyTake {
                        readOnlyTakeStatus(take)
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
                        Text("Movement check").font(.headline)
                        Text("Use Play whole take to review this movement. Save Capture exports the recorded files. No timed repetitions or canonical approval are assigned to this check.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Text("Four repetitions").font(.headline)
                    Text("Play each repetition to check it. Start and End beat trim its review range. Mark as Preferred records the performer's best repetition (1–4); it is saved with the draft, included in Save Capture and used if you approve. Change your pick by marking another repetition, or use Clear. Marking does not approve the take or change the original recording.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preferred = take.evidence.boundaries.selectedRepetitionIndex {
                        Text("Preferred: repetition \(preferred + 1)" + (take.preferenceMark.map {
                            " · marked by \($0.markedBy) · \($0.markedAt.formatted(date: .abbreviated, time: .shortened))"
                        } ?? ""))
                        .font(.caption.weight(.semibold))
                    } else {
                        Text("No preferred repetition marked.").font(.caption).foregroundStyle(.secondary)
                    }
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

                    reviewCompletionControls(take)

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

                    TextField("Review notes (saved with the draft and Save Capture)", text: $viewModel.reviewNotes, axis: .vertical)
                        .lineLimit(2...4)
                        .disabled(!viewModel.canEditReviewedTake)

                    // Approval's scope, stated wherever approval is offered.
                    // Approving marks ONE draft canonical inside this session.
                    // It is not an export, and it publishes, installs and
                    // enables nothing — those are separate, later actions.
                    Text("Approval marks the selected repetition as a canonical draft. Approve & Save Capture also opens the capture ZIP save dialog. Neither action publishes, installs or enables training.")
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
                    } else if !viewModel.isShowingReadOnlyTake {
                        HStack {
                            Button("Reject Take") { viewModel.rejectTake() }
                                .disabled(!viewModel.canRejectReviewedTake)
                            Button("Approve & Save Capture…") { saveRawCapture(approvingCanonical: true) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!viewModel.canApprove)
                            Button("Approve Canonical Draft Only") { viewModel.approveCanonical() }
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
                    rawExportControls
                }
                .disabled(exportCoordinator.isPreparing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    private func readOnlyTakeStatus(_ take: ReferenceAuthoringTake) -> some View {
        HStack {
            Text("Previous take · read-only. Playback and Save Capture are available.")
                .font(.callout).foregroundStyle(.secondary)
            if viewModel.savedDrafts.contains(where: { $0.id == take.id }) {
                Button("Open for Review") { viewModel.reopenDraft(take.id) }
                    .disabled(!viewModel.canOpenSavedDraft || exportCoordinator.isPreparing)
            }
        }
    }

    private func reviewCompletionControls(_ take: ReferenceAuthoringTake) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.isShowingReadOnlyTake,
               take.evidence.metadata.lifecycleState != .approvedCanonical,
               take.evidence.metadata.captureIntent?.isMovementCheck != true {
                Button("Approve & Save Capture…") { saveRawCapture(approvingCanonical: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canApprove)
                if let reason = viewModel.approvalBlockReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            } else if take.evidence.metadata.lifecycleState == .approvedCanonical {
                Text("Canonical draft approved. Save Capture exports the ZIP; cancelling a save keeps the approved draft.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = viewModel.visibleMessage {
                Text(message).font(.caption).textSelection(.enabled)
            }
            rawExportControls
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
        reviewTake: ReferenceAuthoringTake? = nil,
        preparedReasons: [ReferenceTearProjectionReason]? = nil,
        preparedChart: ScratchStrokeGeometry.PreparedCanonicalChart? = nil,
        isLive: Bool = false,
        chartHeight: CGFloat? = nil
    ) -> some View {
        let minimumChartHeight = chartHeight ?? (reviewTake == nil ? Self.canonicalTearChartMinimumHeight : 400)
        let chartBPM = Double(recordedBPM ?? viewModel.bpm)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.55))
            if let sourceFrame = preparedChart?.frame ?? ReferenceAuthoringViewModel.canonicalFrame(
                for: projection,
                bpm: chartBPM
            ), !projection.isEmpty {
                // Review spans recorded media, including silence before/after
                // decoded motion. Canonical evidence/export keeps its own frame.
                let recordedDuration = reviewTake?.evidence.metadata.witnessedTiming?.measuredWAVDurationSeconds
                let fullFrame = recordedDuration.flatMap { duration -> ScratchStrokeGeometry.CanonicalFrame? in
                    guard duration.isFinite, duration > 0 else { return nil }
                    return ScratchStrokeGeometry.CanonicalFrame(timeRange: 0...duration,
                        positionRange: sourceFrame.positionRange, coordinateSpace: sourceFrame.coordinateSpace,
                        beatsPerMinute: sourceFrame.beatsPerMinute)
                } ?? sourceFrame
                let boundary = reviewTake.flatMap { focusedBoundary(for: $0) }
                let focus = reviewTake.flatMap { motionReviewFocus?.takeID == $0.id ? motionReviewFocus : nil }
                let selectedRange = reviewTake.flatMap { take in
                    if let boundary {
                        return ReferenceMotionReviewViewport.range(for: boundary, metadata: take.evidence.metadata,
                            recordedEnd: take.evidence.metadata.witnessedTiming?.measuredWAVDurationSeconds
                                ?? fullFrame.timeRange.upperBound)
                    }
                    return ReferenceMotionReviewViewport.section(in: fullFrame.timeRange, index: focus?.sectionIndex ?? 0)
                }
                let zoomed = selectedRange != nil && (focus?.isZoomed ?? true)
                let heightScale = focus?.heightScale ?? 1
                let selectedFrame = ReferenceMotionReviewViewport.frame(fullFrame,
                    selectedRange: selectedRange, zoomed: true)
                let fittedFrame = selectedRange == nil ? nil
                    : selectedFrame.fittedVisibleMotionFrame(in: projection.records, layer: .performance)
                let frame = zoomed ? fittedFrame ?? selectedFrame : fullFrame
                let displayHeight = ReferenceMotionReviewViewport.displayHeight(
                    base: minimumChartHeight, scale: heightScale)
                if let take = reviewTake {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let boundary {
                                Text("Repetition \(boundary.index + 1) · beats \(boundary.startBeat, specifier: "%.2f")–\(boundary.endBeat, specifier: "%.2f")")
                            } else if let selectedRange {
                                Button("Previous section") {
                                    motionReviewFocus = .init(takeID: take.id, repetitionIndex: -1,
                                        isZoomed: true, sectionIndex: max(0, (focus?.sectionIndex ?? 0) - 1))
                                }
                                .disabled((focus?.sectionIndex ?? 0) == 0)
                                Text("\(selectedRange.lowerBound, specifier: "%.2f")–\(selectedRange.upperBound, specifier: "%.2f") s")
                                    .monospacedDigit()
                                Button("Next section") {
                                    motionReviewFocus = .init(takeID: take.id, repetitionIndex: -1,
                                        isZoomed: true, sectionIndex: (focus?.sectionIndex ?? 0) + 1)
                                }
                                .disabled(ReferenceMotionReviewViewport.section(in: fullFrame.timeRange,
                                    index: (focus?.sectionIndex ?? 0) + 1) == nil)
                            }
                            Spacer()
                            Button(zoomed ? "Whole take" : (boundary == nil ? "Zoom to section" : "Zoom to repetition")) {
                                motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary?.index ?? -1,
                                    isZoomed: !zoomed, sectionIndex: focus?.sectionIndex ?? 0)
                            }
                            .disabled(selectedRange == nil)
                        }
                        .font(.caption)
                        HStack(spacing: 10) {
                            Text("Height")
                            Button("−") {
                                motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary?.index ?? -1,
                                    isZoomed: zoomed, sectionIndex: focus?.sectionIndex ?? 0,
                                    heightScale: max(1, heightScale / 2))
                            }
                            .accessibilityLabel("Decrease chart height")
                            .disabled(heightScale <= 1)
                            Text("\(heightScale, specifier: "%.0f")×")
                                .monospacedDigit().frame(width: 28)
                            Button("+") {
                                motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary?.index ?? -1,
                                    isZoomed: zoomed, sectionIndex: focus?.sectionIndex ?? 0,
                                    heightScale: min(2, heightScale * 2))
                            }
                            .accessibilityLabel("Increase chart height")
                            .disabled(heightScale >= 2)
                            Button("Reset height") {
                                motionReviewFocus = .init(takeID: take.id, repetitionIndex: boundary?.index ?? -1,
                                    isZoomed: zoomed, sectionIndex: focus?.sectionIndex ?? 0)
                            }
                            .disabled(heightScale <= 1)
                            Text(!zoomed ? "Whole-take scale" : (fullFrame.timeRange.upperBound - fullFrame.timeRange.lowerBound < 8
                                ? "Complete recording" : "Complete repetition · at least 8 seconds"))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        if zoomed {
                            Picker("Display", selection: $reviewMotionDisplay) {
                                Text("Recorded travel").tag(ReferenceMotionDetailPages.Display.recordedTravel)
                                Text("Movement detail").tag(ReferenceMotionDetailPages.Display.movementDetail)
                                if reviewTake?.recordedSamplePlayback != nil {
                                    Text("Sample position").tag(ReferenceMotionDetailPages.Display.samplePosition)
                                }
                            }
                            .pickerStyle(.segmented).frame(maxWidth: 500)
                        }
                    }
                    if selectedRange == nil {
                        Text("This repetition is outside the recorded range. Adjust its Start and End beats.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let take = reviewTake, zoomed {
                    ReferenceMotionDetailView(controller: viewModel.mediaReview,
                        takeID: take.id,
                        request: .init(records: projection.records, fullFrame: fullFrame,
                            mixerFaders: projection.mixerFaders, samplePlayback: take.recordedSamplePlayback,
                            showBeatGrid: take.evidence.metadata.captureIntent?.isMovementCheck != true,
                            beatOffset: take.evidence.metadata.mediaTimeOrigin?.recordingStartOffsetSeconds ?? 0,
                            unavailableReason: take.samplePlaybackUnavailableReason,
                            selectedRange: selectedRange, display: reviewMotionDisplay),
                        height: displayHeight, boundary: boundary, metadata: take.evidence.metadata,
                        canEdit: viewModel.canEditReviewedTake && !exportCoordinator.isPreparing,
                        commitBoundary: { adjusted in
                            viewModel.adjustRepetitionBoundary(index: adjusted.index,
                                startBeat: adjusted.startBeat, endBeat: adjusted.endBeat, expectedTakeID: take.id)
                        })
                        .id(take.id)
                } else {
                    ScratchPhraseChartView(
                        source: preparedChart.map { .preparedCanonical($0) }
                            ?? .canonical(projection.records, layer: .performance, frame: frame),
                        bpm: chartBPM,
                        showBeatGrid: reviewTake?.evidence.metadata.captureIntent?.isMovementCheck != true,
                        beatTimelineOffsetSeconds: reviewTake?.evidence.metadata.mediaTimeOrigin?.recordingStartOffsetSeconds ?? 0,
                        wrapPeriod: wrapPeriod,
                        mixerFaders: projection.mixerFaders,
                        showsMixerFaderLanes: true,
                        backgroundColor: .clear
                    )
                    // Bounded, never `maxHeight: .infinity`: this card also lives
                    // inside an unbounded `ScrollView`, where `.infinity` resolves
                    // to the IDEAL height and collapses the lane — the same trap
                    // documented on `liveNotationMinimumHeight`.
                    .frame(maxWidth: .infinity)
                    .frame(height: displayHeight)
                    .clipped()
                    .overlay {
                        if let selectedRange, !zoomed {
                            if let take = reviewTake, let boundary {
                                ReferenceMotionTimelineEditor(takeID: take.id, boundary: boundary,
                                    metadata: take.evidence.metadata, viewport: frame.timeRange,
                                    recordedDuration: recordedDuration ?? frame.timeRange.upperBound,
                                    canEdit: viewModel.canEditReviewedTake && !exportCoordinator.isPreparing,
                                    editingBegan: { viewModel.mediaReview.stop() }, commit: { adjusted in
                                        viewModel.adjustRepetitionBoundary(index: adjusted.index,
                                            startBeat: adjusted.startBeat, endBeat: adjusted.endBeat, expectedTakeID: take.id)
                                    })
                                    .id(ReferenceMotionTimelineEditor.identity(takeID: take.id,
                                        boundary: boundary, viewport: frame.timeRange,
                                        canEdit: viewModel.canEditReviewedTake && !exportCoordinator.isPreparing))
                            } else {
                                ReferenceMotionSelectionOverlay(selectedRange: selectedRange, viewport: frame.timeRange)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .overlay {
                        if let take = reviewTake {
                            ReferenceReviewPlaybackOverlay(controller: viewModel.mediaReview,
                                takeID: take.id, viewport: frame.timeRange)
                        }
                    }
                }
            } else {
                ScratchPhraseChartView(
                    source: .empty(emptyMessage),
                    bpm: chartBPM,
                    backgroundColor: .clear
                )
                .frame(maxWidth: .infinity, minHeight: minimumChartHeight)
            }
            if isLive {
                // Keep changing evidence messages from moving the surrounding
                // controls. Every reason remains readable in this scroll area.
                ScrollView {
                    projectionReasons(preparedReasons ?? projection.reasons)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 64)
            } else {
                projectionReasons(preparedReasons ?? projection.presentationReasons)
            }
        }
    }

    private func projectionReasons(_ reasons: [ReferenceTearProjectionReason]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reasons, id: \.rawValue) { reason in
                Text(reason.detail).font(.caption2).foregroundStyle(.secondary)
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
            .disabled(!viewModel.canCorrectTearReview)
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
                        : ((take.evidence.watchEvidence.isTransferPending || take.evidence.watchEvidence.isAbsent) ? Color.orange : Color.red)
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
                if viewModel.isShowingReadOnlyTake {
                    Text("Read-only").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(focusedBoundary(for: take)?.index == boundary.index ? "Review selected" : "Review bounds") {
                    focusMotion(on: boundary, take: take)
                    viewModel.mediaReview.previewBoundary(boundary, take: take)
                }
                Button(take.evidence.boundaries.selectedRepetitionIndex == boundary.index ? "Preferred" : "Mark as Preferred") {
                    focusMotion(on: boundary, take: take)
                    viewModel.mediaReview.previewBoundary(boundary, take: take)
                    viewModel.markPreferredRepetition(boundary.index)
                }
                .disabled(!viewModel.canEditReviewedTake || take.evidence.boundaries.selectedRepetitionIndex == boundary.index)
                if take.evidence.boundaries.selectedRepetitionIndex == boundary.index {
                    Button("Clear") { viewModel.clearPreferredRepetition() }
                        .disabled(!viewModel.canEditReviewedTake)
                }
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
            if focusedBoundary(for: take)?.index == boundary.index {
                VStack(alignment: .leading, spacing: 12) {
                    ReferenceBoundaryMediaReview(
                        controller: viewModel.mediaReview,
                        boundary: boundary,
                        take: take
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    canonicalTearChart(
                        title: "REPETITION NOTATION",
                        projection: take.tearProjection,
                        emptyMessage: "No notation is available for this take.",
                        recordedBPM: take.evidence.metadata.bpm,
                        reviewTake: take
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
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
        // Keep an explicitly chosen invalid boundary available for correction.
        if motionReviewFocus?.takeID == take.id,
           let selected = take.evidence.boundaries.repetitions.first(where: { $0.index == index }) {
            return selected
        }
        return ReferenceMotionReviewViewport.preferredBoundary(in: take.evidence.boundaries.repetitions,
            preferredIndex: index, metadata: take.evidence.metadata,
            recordedEnd: take.evidence.metadata.witnessedTiming?.measuredWAVDurationSeconds
                ?? take.tearProjection.timeRange?.upperBound ?? 0)
            ?? take.evidence.boundaries.repetitions.first
    }

    private func focusMotion(on boundary: ReferenceRepetitionBoundary, take: ReferenceAuthoringTake) {
        motionReviewFocus = ReferenceMotionReviewFocus.selecting(takeID: take.id,
            repetitionIndex: boundary.index, current: motionReviewFocus)
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
    var locked: Bool

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

            if receiver.isBrowsingForPeers {
                Button("Reconnect iPhone relay") { receiver.reconnectCompanion() }
                    .disabled(locked || receiver.relayedWatchCaptureStore.activeTakeContext != nil)
                ForEach(receiver.discoveredPeers) { peer in
                    Button("Connect to \(peer.name)") { receiver.connect(to: peer) }
                        .disabled(locked || !receiver.connectedPeerNames.isEmpty)
                }
            }
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

/// Only this inexpensive leaf samples the WAV-backed player. The parent view
/// keeps its fitted geometry stable while playback advances. Paused boundary
/// seeks are refreshed by the controller's existing completion publication.
private struct ReferenceReviewPlaybackOverlay: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    let takeID: String
    let viewport: ClosedRange<Double>

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !controller.isPlaying)) { _ in
            ScratchPhrasePlayhead(mediaTime: controller.currentPlaybackTime(for: takeID), viewport: viewport)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The readout uses precomputed recorded-motion metrics, independently of the
/// fitted/emphasized chart. Playback ticks only select an existing interval.
private struct ReferenceReviewMovementReadout: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    let takeID: String
    let movements: ScratchStrokeGeometry.RecordedMotionReadout
    let usesSamplePosition: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !controller.isPlaying)) { _ in
            let time = controller.currentPlaybackTime(for: takeID)
            VStack(alignment: .leading, spacing: 3) {
                if let time, let movement = movements.at(time) {
                    Text("Recorded platter: \(direction(movement.direction).lowercased()) · duration \(movement.span.duration, specifier: "%.2f") s")
                        .font(.caption.weight(.semibold))
                    if let previous = movement.previousDirection, let mean = movement.meanRatio {
                        Text(comparison(previous: previous, mean: mean, peak: movement.peakRatio))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(usesSamplePosition
                            ? "Physical speed comparison is unavailable in sample-position view."
                            : "Speed comparison needs an adjacent measured movement.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("At playhead").font(.caption.weight(.semibold))
                    Text(time.flatMap { movements.unavailableReason(at: $0) }
                        ?? "No reliable measured movement at the playhead.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44, alignment: .topLeading)
            .clipped()
        }
        .help("Recorded durations may begin or end partway through a physical gesture. Speed ratios compare adjacent recorded movements on the same scale; 1× means equal speed. Peak uses a 40 ms window. These are not calibrated physical speeds.")
    }

    private func direction(_ value: ScratchNotationDirection) -> String {
        switch value {
        case .forward: return "Forward"
        case .backward: return "Backward"
        }
    }

    private func comparison(previous: ScratchNotationDirection, mean: Double, peak: Double?) -> String {
        let average = String(format: "%.2f", mean)
        let reference = direction(previous).lowercased()
        if let peak {
            return "Compared with preceding \(reference): average speed \(average)× · peak speed \(String(format: "%.2f", peak))× (40 ms)"
        }
        return "Compared with preceding \(reference): average speed \(average)× · too short for a 40 ms peak comparison"
    }
}

/// Static review geometry is prepared off the UI thread. The complete
/// repetition stays visible while only the independent playback cursor moves.
struct ReferenceMotionDetailPages: Equatable, Sendable {
    /// Mutually exclusive presentation choices. Sample playback coordinates
    /// must never silently replace measured platter travel or receive the
    /// per-movement emphasis intended for complete physical strokes.
    enum Display: Hashable, Sendable {
        case recordedTravel
        case movementDetail
        case samplePosition
    }

    struct Request: Equatable, Sendable {
        let records: [ScratchNotation.GestureRecord]
        let fullFrame: ScratchStrokeGeometry.CanonicalFrame
        let mixerFaders: ScratchMixerFaderEvidence?
        let samplePlayback: RecordedPlaybackLoopTimeline?
        let showBeatGrid: Bool
        let beatOffset: Double
        var unavailableReason: String? = nil
        var selectedRange: ClosedRange<Double>? = nil
        var display: Display = .recordedTravel
    }
    /// An explicit, pinned inspection request. Only the button captures the
    /// owned WAV time; playback ticks never enter this preparation identity.
    struct InspectionRequest: Equatable, Sendable {
        let takeID: String
        let range: ClosedRange<Double>
        let source: Request

        init?(takeID: String, mediaTime: Double?, source: Request) {
            let available = source.fullFrame.timeRange
            guard !takeID.isEmpty, let mediaTime, mediaTime.isFinite,
                  available.contains(mediaTime) else { return nil }
            let duration = min(2, available.upperBound - available.lowerBound)
            let start = max(available.lowerBound, min(mediaTime - duration / 2, available.upperBound - duration))
            let end = min(available.upperBound, start + duration)
            guard start.isFinite, end.isFinite, end > start else { return nil }
            self.takeID = takeID
            self.range = start...end
            self.source = source
        }

        func matches(takeID: String, source: Request) -> Bool {
            self.takeID == takeID && self.source == source
        }
    }

    /// Use one affine vertical fit for every measured point in this window.
    /// Close-up is always recorded platter travel, including when the main
    /// view has explicitly selected non-metric emphasis or sample position.
    static func prepareInspection(_ request: InspectionRequest) -> Page? {
        guard !Task.isCancelled else { return nil }
        let source = request.source
        let frame = ReferenceMotionReviewViewport.frame(source.fullFrame,
            selectedRange: request.range, zoomed: true, records: source.records)
        return .init(chart: .init(records: source.records, layer: .performance,
            frame: frame, mixerFaders: source.mixerFaders), resets: [])
    }

    struct Page: Equatable, Sendable {
        let chart: ScratchStrokeGeometry.PreparedCanonicalChart
        let resets: [ScratchStrokeGeometry.PlaybackResetMarker]
        var isMovementDetail = false
    }
    let pages: [Page]
    let overview: ScratchStrokeGeometry.PreparedCanonicalChart
    let usesSamplePosition: Bool
    let movements: ScratchStrokeGeometry.RecordedMotionReadout

    static func prepare(_ request: Request) -> Self {
        let full = request.fullFrame
        let overview = ScratchStrokeGeometry.PreparedCanonicalChart(records: request.records,
            layer: .performance, frame: full, mixerFaders: request.mixerFaders)
        let sample = request.display == .samplePosition ? request.samplePlayback.flatMap {
            ScratchStrokeGeometry.samplePlaybackChart(timeline: $0, records: request.records,
                frame: full, mixerFaders: request.mixerFaders)
        } : nil
        let movements = ScratchStrokeGeometry.RecordedMotionReadout(records: request.records,
            coordinateSpace: full.coordinateSpace, permitsComparison: sample == nil)
        let selected = request.selectedRange ?? full.timeRange.lowerBound...min(full.timeRange.upperBound, full.timeRange.lowerBound + 8)
        guard let window = ScratchStrokeGeometry.reviewTimeRange(selected: selected, within: full.timeRange),
              !Task.isCancelled else { return .init(pages: [], overview: overview, usesSamplePosition: sample != nil, movements: movements) }
        let page: Page
        if let detail = sample?.windowed(to: window) {
            page = .init(chart: detail.prepared, resets: detail.resets)
        } else {
            let frame = ReferenceMotionReviewViewport.frame(full, selectedRange: window,
                zoomed: true, records: request.records)
            page = .init(chart: .init(records: request.records, layer: .performance,
                frame: frame, mixerFaders: request.mixerFaders), resets: [])
        }
        let displayed: Page
        if request.display == .movementDetail,
           let detail = ScratchStrokeGeometry.movementDetailChart(page.chart, resetMarkers: page.resets) {
            displayed = .init(chart: detail, resets: page.resets, isMovementDetail: true)
        } else {
            displayed = page
        }
        return Self(pages: [displayed], overview: overview, usesSamplePosition: sample != nil, movements: movements)
    }

    func pageIndex(at time: Double) -> Int { 0 }
}

private struct ReferenceMotionDetailView: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    let takeID: String
    let request: ReferenceMotionDetailPages.Request
    let height: CGFloat
    let boundary: ReferenceRepetitionBoundary?
    let metadata: ReferenceTakeMetadata
    let canEdit: Bool
    let commitBoundary: (ReferenceRepetitionBoundary) -> Void
    @State private var prepared: ReferenceMotionDetailPages?
    @State private var preparedTakeID: String?
    @State private var preparedRequest: ReferenceMotionDetailPages.Request?
    @State private var inspectionRequest: ReferenceMotionDetailPages.InspectionRequest?
    @State private var preparedInspectionRequest: ReferenceMotionDetailPages.InspectionRequest?
    @State private var preparedInspection: ReferenceMotionDetailPages.Page?

    private var currentInspection: ReferenceMotionDetailPages.InspectionRequest? {
        guard let inspectionRequest, inspectionRequest.matches(takeID: takeID, source: request) else { return nil }
        return inspectionRequest
    }

    var body: some View {
        Group {
            if let prepared, preparedTakeID == takeID, preparedRequest == request, let page = prepared.pages.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Visible \(page.chart.frame.timeRange.lowerBound, specifier: "%.2f")–\(page.chart.frame.timeRange.upperBound, specifier: "%.2f") s")
                            .monospacedDigit()
                        Spacer()
                        Button("Inspect at playhead") {
                            // Read once with the controller's exact loaded-take
                            // guard, then pause. A stale player returns nil.
                            let time = controller.currentPlaybackTime(for: takeID)
                            controller.stop()
                            inspectionRequest = .init(takeID: takeID, mediaTime: time, source: request)
                        }
                        .disabled(controller.currentPlaybackTime(for: takeID) == nil)
                        if currentInspection != nil {
                            Button("Hide close-up") { inspectionRequest = nil }
                        }
                    }
                    .font(.caption)
                    .frame(height: 24)
                    ScratchPhraseChartView(source: .preparedCanonical(page.chart),
                        bpm: request.fullFrame.beatsPerMinute, showBeatGrid: request.showBeatGrid,
                        beatTimelineOffsetSeconds: request.beatOffset,
                        showsMixerFaderLanes: true, reviewDetail: true,
                        sampleResetMarkers: page.resets, samplePosition: prepared.usesSamplePosition,
                        backgroundColor: .clear)
                        .frame(height: height)
                        .clipped()
                        .overlay {
                            if let selected = request.selectedRange,
                               let fractions = ReferenceMotionReviewViewport.visibleFractions(
                                selected, in: page.chart.frame.timeRange),
                               fractions.lowerBound > 0 || fractions.upperBound < 1 {
                                // Keep the extra eight-second context readable
                                // while marking the actual repetition bounds.
                                ReferenceMotionSelectionOverlay(selectedRange: selected,
                                    viewport: page.chart.frame.timeRange)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            ReferenceReviewPlaybackOverlay(controller: controller,
                                takeID: takeID, viewport: page.chart.frame.timeRange)
                        }
                    ReferenceReviewMovementReadout(controller: controller, takeID: takeID,
                        movements: prepared.movements, usesSamplePosition: prepared.usesSamplePosition)
                    Text(page.isMovementDetail
                        ? "Movement detail changes each movement’s height. Do not compare speed from slopes between movements."
                        : (request.display == .movementDetail
                            ? "Movement detail is unavailable for this evidence; recorded travel is shown."
                            : (prepared.usesSamplePosition
                                ? "Sample playback coordinates · loop boundaries may split a scratch. Use Recorded travel to compare platter speed."
                                : "Recorded travel · one shared scale: gentler slopes mean slower movement; steeper slopes mean faster movement.")))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(height: 28, alignment: .topLeading)
                    Text("Shaded ? intervals mark uncertain motion; the curve is withheld where the evidence is insufficient.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .opacity(page.chart.geometry.missingMotion.isEmpty ? 0 : 1)
                        .frame(height: 28, alignment: .topLeading)
                    Text(prepared.usesSamplePosition
                        ? "Sample position · recorded loop/cue boundaries"
                        : (request.display == .samplePosition
                            ? (request.unavailableReason ?? "Sample position unavailable; recorded travel is shown.")
                            : "Continuous platter travel · sample boundaries do not reset this trace"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(height: 16, alignment: .topLeading)
                    HStack {
                        Text("WHOLE TAKE · RECORDED TRAVEL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        Spacer()
                        if boundary != nil {
                            Text(canEdit ? "Drag the box to move the repetition · drag its edges to trim" : "Repetition bounds · read-only")
                                .font(.caption2)
                        }
                    }.foregroundStyle(.secondary).frame(height: 16)
                    ScratchPhraseChartView(source: .preparedCanonical(prepared.overview),
                        bpm: request.fullFrame.beatsPerMinute, showBeatGrid: false,
                        showsMixerFaderLanes: true, backgroundColor: .clear)
                        .frame(height: 86)
                        .clipped()
                        .overlay {
                            if let boundary {
                                ReferenceMotionTimelineEditor(takeID: takeID, boundary: boundary,
                                    metadata: metadata, viewport: request.fullFrame.timeRange,
                                    recordedDuration: request.fullFrame.timeRange.upperBound,
                                    canEdit: canEdit, editingBegan: { controller.stop() }, commit: commitBoundary)
                                    .id(ReferenceMotionTimelineEditor.identity(takeID: takeID,
                                        boundary: boundary, viewport: request.fullFrame.timeRange, canEdit: canEdit))
                            } else {
                                ReferenceMotionSelectionOverlay(selectedRange: page.chart.frame.timeRange,
                                    viewport: request.fullFrame.timeRange).allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            ReferenceReviewPlaybackOverlay(controller: controller,
                                takeID: takeID, viewport: request.fullFrame.timeRange)
                        }
                    if let inspection = currentInspection {
                        inspectionChart(inspection)
                    }
                }
            } else {
                Text("Preparing repetition notation…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: height + 284)
            }
        }
        .task(id: request) {
            let input = request
            let requestedTakeID = takeID
            let work = Task.detached(priority: .userInitiated) { ReferenceMotionDetailPages.prepare(input) }
            let result = await withTaskCancellationHandler(operation: { await work.value },
                onCancel: { work.cancel() })
            guard !Task.isCancelled, input == request, requestedTakeID == takeID else { return }
            preparedTakeID = requestedTakeID
            preparedRequest = input
            prepared = result
        }
        .onChange(of: request) { _, source in
            // Discard the pin, rather than merely hiding it: returning to a
            // previous display mode or boundary must not resurrect old focus.
            if let inspectionRequest, !inspectionRequest.matches(takeID: takeID, source: source) {
                self.inspectionRequest = nil
            }
        }
        .task(id: currentInspection) {
            guard let input = currentInspection else {
                preparedInspection = nil
                preparedInspectionRequest = nil
                return
            }
            let work = Task.detached(priority: .userInitiated) {
                ReferenceMotionDetailPages.prepareInspection(input)
            }
            let result = await withTaskCancellationHandler(operation: { await work.value },
                onCancel: { work.cancel() })
            guard !Task.isCancelled, input.matches(takeID: takeID, source: request) else { return }
            preparedInspectionRequest = input
            preparedInspection = result
        }
    }

    private func inspectionChart(_ inspection: ReferenceMotionDetailPages.InspectionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECORDED TRAVEL CLOSE-UP · \(inspection.range.lowerBound, specifier: "%.2f")–\(inspection.range.upperBound, specifier: "%.2f") s")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Pinned view · one shared height scale. Gentler slopes are slower; steeper slopes are faster.")
                .font(.caption2).foregroundStyle(.secondary)
            Group {
                if preparedInspectionRequest == inspection, let page = preparedInspection {
                    ScratchPhraseChartView(source: .preparedCanonical(page.chart),
                        bpm: request.fullFrame.beatsPerMinute, showBeatGrid: request.showBeatGrid,
                        beatTimelineOffsetSeconds: request.beatOffset,
                        showsMixerFaderLanes: true, reviewDetail: true, backgroundColor: .clear)
                        .overlay {
                            ReferenceReviewPlaybackOverlay(controller: controller,
                                takeID: takeID, viewport: inspection.range)
                        }
                } else {
                    Text("Preparing recorded travel close-up…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 240)
            .clipped()
        }
        .padding(.top, 6)
    }
}

private struct ReferenceMediaReviewStatus: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    var showsVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Play whole take") { controller.playWholeTake() }
                    .disabled(!controller.canPlay)
                Button("Stop playback") { controller.stop() }
                    .disabled(!controller.canPlay)
            }
            if showsVideo, let player = controller.videoPlayer {
                ReferenceRecordedVideo(player: player)
                    .frame(height: 240)
            } else if !showsVideo {
                Text("Video is beside the selected repetition's boundary controls below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(summary).font(.caption)
                .foregroundStyle(isBlocking ? Color.orange : Color.secondary)
            if let message = controller.secondaryCameraMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
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

/// Uses the very same player as whole-take review: one audio clock and both
/// recorded angles, kept beside the trim controls while the operator reviews.
private struct ReferenceBoundaryMediaReview: View {
    @ObservedObject var controller: ReferenceFinalizedMediaReviewController
    let boundary: ReferenceRepetitionBoundary
    let take: ReferenceAuthoringTake

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let player = controller.videoPlayer {
                ReferenceRecordedVideo(player: player)
                    .frame(width: 200, height: 112)
                    .overlay(alignment: .bottomLeading) {
                        TimelineView(.animation(minimumInterval: 0.1, paused: !controller.isPlaying)) { _ in
                            let time = controller.currentPlaybackTime(for: take.id)
                            Text(time.map { String(format: "Recorded take · %.2f s", $0) } ?? "Recorded take")
                                .font(.caption.monospacedDigit()).padding(4)
                                .background(.black.opacity(0.7)).foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Show start") { controller.previewBoundary(boundary, take: take) }
                    Button("Show end") { controller.previewBoundary(boundary, take: take, atEnd: true) }
                    Button("Play with rest context") {
                        controller.play(repetition: boundary, take: take, contextBeats: 4)
                    }
                    Button("Play whole take") { controller.playWholeTake() }
                }.disabled(!controller.canPlay)
                Text("Review the full repetition below. Drag its timeline box or edges to set the range; original media stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = controller.playbackMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: boundary) { old, new in
            // One atomic move changes both edges; issue exactly one seek.
            controller.previewBoundary(new, take: take,
                atEnd: old.startBeat == new.startBeat && old.endBeat != new.endBeat)
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

/// One bounded form refresh stream, independent of the raw capture streams.
/// Delivery is asynchronous because ObservableObject publishes before its
/// values change. A trailing update preserves the last change in a burst.
final class ReferenceCaptureRefresh: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?

    init(changes: AnyPublisher<Void, Never>,
         interval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(200)) {
        subscription = changes
            .throttle(for: interval, scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
    }
}

/// The moving cursor retains the engine's display cadence without refreshing
/// every hardware selector, calibration row and preflight control above it.
private struct ReferenceCaptureWaveform: View {
    @ObservedObject var engine: MacCaptureEngine

    var body: some View {
        MacSamplePositionWaveformView(waveform: engine.playbackWaveformSnapshot,
            position: engine.playbackPositionSnapshot,
            positionLabel: "PLAYHEAD", usesRenderedPlayhead: true)
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


struct ReferenceMotionReviewFocus: Equatable {
    let takeID: String
    let repetitionIndex: Int
    let isZoomed: Bool
    var sectionIndex: Int = 0
    var heightScale: Double = 1

    static func selecting(takeID: String, repetitionIndex: Int, current: Self?) -> Self {
        if let current, current.takeID == takeID, current.repetitionIndex == repetitionIndex {
            return current
        }
        return .init(takeID: takeID, repetitionIndex: repetitionIndex, isZoomed: true)
    }
}

/// Presentation-only framing. Saved records and export coordinates stay
/// unchanged; beats use the same measured media origin as audio audition.
enum ReferenceMotionReviewViewport {
    static func range(for boundary: ReferenceRepetitionBoundary,
                      metadata: ReferenceTakeMetadata, recordedEnd: Double) -> ClosedRange<Double>? {
        ReferenceMediaTimeRange.clamped(start: boundary.startSeconds(metadata: metadata),
            end: boundary.endSeconds(metadata: metadata), duration: recordedEnd)
    }

    static func preferredBoundary(in boundaries: [ReferenceRepetitionBoundary], preferredIndex: Int?,
                                  metadata: ReferenceTakeMetadata,
                                  recordedEnd: Double) -> ReferenceRepetitionBoundary? {
        let valid = boundaries.filter { range(for: $0, metadata: metadata, recordedEnd: recordedEnd) != nil }
        return valid.first { $0.index == preferredIndex } ?? valid.first
    }

    /// Beatless movement checks have no repetitions. Inspect fixed eight-second
    /// sections without inventing repetition metadata or following playback.
    static func section(in timeRange: ClosedRange<Double>, index: Int) -> ClosedRange<Double>? {
        guard index >= 0, timeRange.lowerBound.isFinite, timeRange.upperBound.isFinite else { return nil }
        let start = timeRange.lowerBound + Double(index) * 8
        let end = min(start + 8, timeRange.upperBound)
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return start...end
    }

    static func frame(_ fullFrame: ScratchStrokeGeometry.CanonicalFrame,
                      selectedRange: ClosedRange<Double>?, zoomed: Bool,
                      records: [ScratchNotation.GestureRecord] = []) -> ScratchStrokeGeometry.CanonicalFrame {
        guard zoomed, let selectedRange,
              let selected = ScratchStrokeGeometry.CanonicalFrame(timeRange: selectedRange,
                positionRange: fullFrame.positionRange, coordinateSpace: fullFrame.coordinateSpace,
                beatsPerMinute: fullFrame.beatsPerMinute) else { return fullFrame }
        guard let fitted = selected.fittedVisibleMotionFrame(in: records, layer: .performance) else { return selected }
        return fitted
    }

    /// Enlarge the canvas, not the coordinate range: every measured extremum
    /// and unknown interval must remain visible at both supported heights.
    static func displayHeight(base: CGFloat, scale: Double) -> CGFloat {
        let boundedScale = scale.isFinite ? min(2, max(1, scale)) : 1
        return base * CGFloat(boundedScale)
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

/// A local drag preview changes only the overlay. One release commits both
/// authored beats through the existing guarded save/revalidation path.
private struct ReferenceMotionTimelineEditor: View {
    let takeID: String
    let boundary: ReferenceRepetitionBoundary
    let metadata: ReferenceTakeMetadata
    let viewport: ClosedRange<Double>
    let recordedDuration: Double
    let canEdit: Bool
    let editingBegan: () -> Void
    let commit: (ReferenceRepetitionBoundary) -> Void

    private struct DragState {
        let takeID: String
        let original: ReferenceRepetitionBoundary
        let edge: ReferenceRepetitionBoundary.DragEdge
        let viewport: ClosedRange<Double>
        let width: CGFloat
        var proposed: ReferenceRepetitionBoundary
    }
    @State private var drag: DragState?

    // Parent identity tears down an in-flight gesture when its source changes;
    // old cumulative translation can never restart against a new take/range.
    static func identity(takeID: String, boundary: ReferenceRepetitionBoundary,
                         viewport: ClosedRange<Double>, canEdit: Bool) -> String {
        "\(takeID)/\(boundary.index)/\(boundary.startBeat)/\(boundary.endBeat)/\(viewport.lowerBound)/\(viewport.upperBound)/\(canEdit)"
    }

    private var displayed: ReferenceRepetitionBoundary { drag?.proposed ?? boundary }
    private var selectedRange: ClosedRange<Double>? {
        ReferenceMotionReviewViewport.range(for: displayed, metadata: metadata,
            recordedEnd: recordedDuration)
    }

    var body: some View {
        GeometryReader { geometry in
            if let selectedRange,
               let fractions = ReferenceMotionReviewViewport.visibleFractions(selectedRange, in: viewport) {
                let left = CGFloat(fractions.lowerBound) * geometry.size.width
                let right = CGFloat(fractions.upperBound) * geometry.size.width
                ZStack(alignment: .topLeading) {
                    ReferenceMotionSelectionOverlay(selectedRange: selectedRange, viewport: viewport)
                        .allowsHitTesting(false)
                    if canEdit {
                        // Separate edge hit targets win over the movable body.
                        Rectangle().fill(Color.accentColor.opacity(0.08))
                            .frame(width: max(0, right - left - 24), height: geometry.size.height)
                            .contentShape(Rectangle())
                            .offset(x: left + 12)
                            .gesture(dragGesture(.move, width: geometry.size.width))
                            .accessibilityLabel("Move repetition range")
                            .accessibilityValue(Text("Beats \(displayed.startBeat, specifier: "%.2f") to \(displayed.endBeat, specifier: "%.2f")"))
                            .accessibilityAdjustableAction { adjust(.move, direction: $0) }
                            .help("Drag left or right to move both boundaries together")
                        handle(.start, at: left, size: geometry.size, compact: right - left < 24)
                        handle(.end, at: right, size: geometry.size, compact: right - left < 24)
                        // A narrow trimmed range still has a usable move grip.
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 22)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                            .position(x: min(max(16, (left + right) / 2), max(16, geometry.size.width - 16)),
                                y: geometry.size.height - 11)
                            .highPriorityGesture(dragGesture(.move, width: geometry.size.width))
                            .accessibilityLabel("Move repetition range grip")
                            .accessibilityAdjustableAction { adjust(.move, direction: $0) }
                    }
                    if drag != nil {
                        Text("In \(displayed.startBeat, specifier: "%.2f") · Out \(displayed.endBeat, specifier: "%.2f") beats")
                            .font(.caption.monospacedDigit()).padding(4)
                            .background(.black.opacity(0.8)).foregroundStyle(.white)
                            .padding(.leading, 24).allowsHitTesting(false)
                    }
                }
            }
        }
        .coordinateSpace(name: "repetitionTimeline")
        .onChange(of: takeID) { _, _ in drag = nil }
        .onChange(of: boundary) { _, _ in drag = nil }
        .onChange(of: viewport) { _, _ in drag = nil }
        .onChange(of: canEdit) { _, allowed in if !allowed { drag = nil } }
        .onDisappear { drag = nil }
    }

    private func handle(_ edge: ReferenceRepetitionBoundary.DragEdge, at x: CGFloat,
                        size: CGSize, compact: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
            .overlay {
                Image(systemName: "line.3.horizontal")
                    .rotationEffect(.degrees(90)).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            // Stagger handles for sub-pixel/very narrow selections so one
            // edge never covers the other's entire hit target.
            .frame(width: 20, height: compact ? size.height * 0.42 : size.height)
            .contentShape(Rectangle())
            .position(x: min(max(10, x), max(10, size.width - 10)),
                y: compact ? size.height * (edge == .start ? 0.23 : 0.69) : size.height / 2)
            .highPriorityGesture(dragGesture(edge, width: size.width))
            .accessibilityLabel(edge == .start ? "Repetition in point" : "Repetition out point")
            .accessibilityValue(String(format: "Beat %.2f", edge == .start ? displayed.startBeat : displayed.endBeat))
            .accessibilityAdjustableAction { adjust(edge, direction: $0) }
            .help(edge == .start ? "Drag to trim the start" : "Drag to trim the end")
    }

    private func dragGesture(_ edge: ReferenceRepetitionBoundary.DragEdge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("repetitionTimeline"))
            .onChanged { value in
                guard canEdit, width.isFinite, width > 0 else { drag = nil; return }
                if drag == nil {
                    editingBegan()
                    drag = DragState(takeID: takeID, original: boundary, edge: edge,
                        viewport: viewport, width: width, proposed: boundary)
                }
                guard var current = drag, current.takeID == takeID, current.original == boundary,
                      current.viewport == viewport, current.edge == edge else { drag = nil; return }
                let seconds = Double(value.translation.width / current.width)
                    * (current.viewport.upperBound - current.viewport.lowerBound)
                guard let proposed = current.original.adjustedForDrag(deltaSeconds: seconds, edge: edge,
                    metadata: metadata, recordedDurationSeconds: recordedDuration) else { return }
                current.proposed = proposed
                drag = current
            }
            .onEnded { value in
                defer { drag = nil }
                guard canEdit, let current = drag, current.takeID == takeID,
                      current.original == boundary, current.viewport == viewport, current.edge == edge else { return }
                let seconds = Double(value.translation.width / current.width)
                    * (current.viewport.upperBound - current.viewport.lowerBound)
                guard let proposed = current.original.adjustedForDrag(deltaSeconds: seconds, edge: edge,
                    metadata: metadata, recordedDurationSeconds: recordedDuration), proposed != boundary else { return }
                commit(proposed)
            }
    }

    private func adjust(_ edge: ReferenceRepetitionBoundary.DragEdge, direction: AccessibilityAdjustmentDirection) {
        guard canEdit, metadata.bpm > 0 else { return }
        let sign: Double
        switch direction {
        case .increment: sign = 1
        case .decrement: sign = -1
        @unknown default: return
        }
        guard let proposed = boundary.adjustedForDrag(deltaSeconds: sign * 15 / Double(metadata.bpm),
            edge: edge, metadata: metadata, recordedDurationSeconds: recordedDuration), proposed != boundary else { return }
        editingBegan()
        commit(proposed)
    }
}

struct ReferenceMotionSelectionOverlay: View {
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

/// The board receives a finite camera and notation budget even on a 13-inch
/// display. Status text and changing evidence cannot resize these regions.
struct ReferenceCaptureFocusLayout: Equatable {
    let cameraHeight: CGFloat
    let notationHeight: CGFloat

    init(availableHeight: CGFloat) {
        let height = availableHeight.isFinite ? max(420, availableHeight) : 548
        cameraHeight = max(140, min(380, (height - 170) * 0.52))
        notationHeight = max(100, height - cameraHeight - 170)
    }
}
