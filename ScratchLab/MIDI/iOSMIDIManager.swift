import Combine
import CoreMIDI
import Foundation
import QuartzCore
import os

/// Thread-safe handoff for the audio-only platter fast path. CoreMIDI invokes
/// this before the parsed batch is enqueued on the main actor, while the
/// existing `onMessage` pipeline remains the sole UI/notation/MIDI-learn path.
private final class IOSMIDIPlatterMessageSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var handler: (@Sendable (ParsedMIDIMessage) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (ParsedMIDIMessage) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func receive(_ message: ParsedMIDIMessage) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(message)
    }
}

private func scratchLabIOSMIDIReadProc(
    packetList: UnsafePointer<MIDIPacketList>,
    readProcRefCon: UnsafeMutableRawPointer?,
    sourceConnectionRefCon: UnsafeMutableRawPointer?
) {
    guard let readProcRefCon else { return }
    let manager = Unmanaged<IOSMIDIManager>
        .fromOpaque(readProcRefCon)
        .takeUnretainedValue()
    manager.receive(packetList)
}

private func scratchLabIOSMIDINotifyProc(
    notification: UnsafePointer<MIDINotification>,
    refCon: UnsafeMutableRawPointer?
) {
    guard let refCon else { return }
    let manager = Unmanaged<IOSMIDIManager>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    manager.scheduleSourceRefresh()
}

/// iOS CoreMIDI transport only. This service discovers and listens to MIDI
/// sources, but deliberately performs no mapping, MIDI Learn, controller
/// action, calibration, platter, fader, or playback work.
@MainActor
final class IOSMIDIManager: ObservableObject {
    struct Source: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let uniqueID: MIDIUniqueID?
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var readinessState: MIDIReadinessState = .unavailable
    @Published private(set) var latestMessage: ParsedMIDIMessage?
    @Published private(set) var validMessageCount = 0

    /// Optional transport-level observation hook. Callers receive parsed
    /// messages only; no controller behaviour is attached here.
    var onMessage: ((ParsedMIDIMessage) -> Void)?

    private nonisolated let platterMessageSink = IOSMIDIPlatterMessageSink()

    /// Installs the audio-only CC6 consumer. Unlike `onMessage`, this callback
    /// runs on CoreMIDI's receive thread before the batch reaches the main
    /// actor, matching the macOS platter tracker's timing without moving any
    /// UI, notation, MIDI Learn, or hot-cue resolution off the main actor.
    func setPlatterAudioMessageHandler(
        _ handler: @escaping @Sendable (ParsedMIDIMessage) -> Void
    ) {
        platterMessageSink.setHandler(handler)
    }

    private struct ConnectedSource {
        let source: Source
        let endpoint: MIDIEndpointRef
    }

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedSources: [ConnectedSource] = []
    private var hasReceivedValidMessage = false

    #if DEBUG
    private var loggedSourceIDs = Set<String>()
    private var lastMessageLogUptime: TimeInterval = -.infinity
    private let messageLogInterval: TimeInterval = 1.0
    #endif

    init(automaticallyStarts: Bool = true) {
        if automaticallyStarts {
            start()
        }
    }

    deinit {
        if inputPort != 0 {
            for connected in connectedSources {
                MIDIPortDisconnectSource(inputPort, connected.endpoint)
            }
            MIDIPortDispose(inputPort)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }

    func start() {
        guard midiClient == 0 else {
            refreshSources()
            return
        }

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let clientStatus = MIDIClientCreate(
            "ScratchLab.iOSMIDI" as CFString,
            scratchLabIOSMIDINotifyProc,
            refCon,
            &midiClient
        )
        guard clientStatus == noErr, midiClient != 0 else {
            midiClient = 0
            resetPublishedState()
            return
        }

        let portStatus = MIDIInputPortCreate(
            midiClient,
            "ScratchLab.iOSMIDIInput" as CFString,
            scratchLabIOSMIDIReadProc,
            refCon,
            &inputPort
        )
        guard portStatus == noErr, inputPort != 0 else {
            MIDIClientDispose(midiClient)
            midiClient = 0
            inputPort = 0
            resetPublishedState()
            return
        }

        refreshSources()
    }

    func refreshSources() {
        guard inputPort != 0 else {
            resetPublishedState()
            return
        }

        let discovered = discoverSources()
        let previousIDs = Set(connectedSources.map(\.source.id))
        let nextIDs = Set(discovered.map(\.source.id))

        for connected in connectedSources {
            MIDIPortDisconnectSource(inputPort, connected.endpoint)
        }
        connectedSources = discovered.filter {
            MIDIPortConnectSource(inputPort, $0.endpoint, nil) == noErr
        }

        if previousIDs != Set(connectedSources.map(\.source.id)) {
            hasReceivedValidMessage = false
            latestMessage = nil
            validMessageCount = 0
        }
        sources = connectedSources.map(\.source)
        readinessState = MIDIReadinessState.classify(
            hasConnectedDevice: !sources.isEmpty,
            hasReceivedValidMessage: hasReceivedValidMessage
        )

        #if DEBUG
        loggedSourceIDs.formIntersection(nextIDs)
        for source in sources where loggedSourceIDs.insert(source.id).inserted {
            print("[MIDI-DEBUG] device discovered · \(source.name)")
        }
        #endif
    }

    func stop() {
        if inputPort != 0 {
            for connected in connectedSources {
                MIDIPortDisconnectSource(inputPort, connected.endpoint)
            }
            connectedSources = []
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
        resetPublishedState()
    }

    nonisolated fileprivate func scheduleSourceRefresh() {
        Task { @MainActor [weak self] in
            self?.refreshSources()
        }
    }

    nonisolated fileprivate func receive(
        _ packetList: UnsafePointer<MIDIPacketList>
    ) {
        var parsedMessages: [ParsedMIDIMessage] = []
        let packetCount = Int(packetList.pointee.numPackets)
        guard packetCount > 0 else { return }

        let packetOffset = MemoryLayout<MIDIPacketList>
            .offset(of: \MIDIPacketList.packet)!
        var packet = UnsafeMutableRawPointer(
            mutating: UnsafeRawPointer(packetList).advanced(by: packetOffset)
        ).assumingMemoryBound(to: MIDIPacket.self)

        for _ in 0..<packetCount {
            let length = Int(packet.pointee.length)
            let dataOffset = MemoryLayout<MIDIPacket>
                .offset(of: \MIDIPacket.data)!
            let bytes = UnsafeRawBufferPointer(
                start: UnsafeRawPointer(packet).advanced(by: dataOffset),
                count: length
            )
            MIDIChannelMessageParser.parse(bytes) { message in
                if let parsed = message.parsedMessage {
                    parsedMessages.append(parsed)
                }
            }
            packet = MIDIPacketNext(packet)
        }

        guard !parsedMessages.isEmpty else { return }
        for message in parsedMessages
        where message.messageType == .controlChange
            && message.controlNumber == 6
            && (Int(message.channel) == ScratchPlatterTracker.leftChannel
                || Int(message.channel) == ScratchPlatterTracker.rightChannel) {
            platterMessageSink.receive(message)
        }
        Task { @MainActor [weak self] in
            self?.publish(parsedMessages)
        }
    }

    private func publish(_ messages: [ParsedMIDIMessage]) {
        guard !sources.isEmpty else { return }
        hasReceivedValidMessage = true
        validMessageCount &+= messages.count
        latestMessage = messages.last
        readinessState = .receivingMessages
        messages.forEach { onMessage?($0) }

        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMessageLogUptime >= messageLogInterval {
            lastMessageLogUptime = now
            print("[MIDI-DEBUG] message received · total=\(validMessageCount)")
        }
        #endif
    }

    private func discoverSources() -> [ConnectedSource] {
        let count = MIDIGetNumberOfSources()
        guard count > 0 else { return [] }

        var discovered: [ConnectedSource] = []
        discovered.reserveCapacity(count)
        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            var unmanagedName: Unmanaged<CFString>?
            let nameStatus = MIDIObjectGetStringProperty(
                endpoint,
                kMIDIPropertyDisplayName,
                &unmanagedName
            )
            let name = (nameStatus == noErr
                ? unmanagedName?.takeRetainedValue() as String?
                : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { continue }

            var uniqueID = MIDIUniqueID(0)
            let idStatus = MIDIObjectGetIntegerProperty(
                endpoint,
                kMIDIPropertyUniqueID,
                &uniqueID
            )
            let resolvedUniqueID = idStatus == noErr ? uniqueID : nil
            let sourceID = resolvedUniqueID.map { "midi_\($0)" }
                ?? "endpoint_\(endpoint)"
            discovered.append(
                ConnectedSource(
                    source: Source(
                        id: sourceID,
                        name: name,
                        uniqueID: resolvedUniqueID
                    ),
                    endpoint: endpoint
                )
            )
        }

        return discovered.sorted {
            $0.source.name.localizedCaseInsensitiveCompare($1.source.name)
                == .orderedAscending
        }
    }

    private func resetPublishedState() {
        connectedSources = []
        sources = []
        hasReceivedValidMessage = false
        readinessState = .unavailable
        latestMessage = nil
        validMessageCount = 0
        #if DEBUG
        loggedSourceIDs = []
        #endif
    }
}

// MARK: - Controller action dispatch

/// Main-thread controller-action dispatch for iOS. Bridges parsed MIDI from
/// `IOSMIDIManager` to the virtual-platter transport and hot-cue runtime.
///
/// References the shared `TransportState` the platter view reads: a controller
/// PLAY (transport Start/Stop press) toggles it on/off and the platter motor
/// spins the record. Hot-cue presses arm their assigned local sample regardless
/// of ScratchLab's transport state because Serato may own deck transport while
/// iOS still receives the controller's MIDI and platter movement.
/// Resolves transport against the hardware registry's `.transport`
/// bindings and hot cues against the learned mapping / pad router. No fader or
/// platter-motion mapping, no audio playback, no MIDI Learn.
@MainActor
final class IOSMIDIControllerDispatcher: ObservableObject {

    /// Shared transport state (play/stop) — the single source of truth the
    /// virtual platter and macOS transport paths observe.
    private let transportState: TransportState

    private let learnStore: MIDILearnedMappingStore
    private var currentMapping: MIDIDeviceMapping?
    /// Identity of the connected source, used only to let `MIDIActionResolver`
    /// consult a certified registry crossfader binding when no learned mapping
    /// covers the control. Nil when no device is selected.
    private var currentDeviceIdentity: MIDIDeviceIdentity?

    /// The iOS scratch playback boundary. The dispatcher resolves actions and
    /// delegates audio to this engine instead of owning playback itself.
    private let playbackEngine: IOScratchPlaybackEngine

    /// Platter CC6 ring-counter tracker, shared logic with the macOS runtime
    /// (`MacCaptureEngine`/`ScratchPlatterTracker`). Both decks are tracked for
    /// parity with macOS's diagnostics, but only the right platter (channel 1 /
    /// Deck 2) drives playback — same product decision macOS already applies.
    private let platterTracker = ScratchPlatterTracker()

    /// Audio-only tracker fed directly from CoreMIDI before the main-actor
    /// batch. It intentionally remains separate from `platterTracker`: the
    /// latter preserves the existing UI/notation/debug path byte-for-byte,
    /// while both reuse the same shared, thread-safe CC6 unwrap logic.
    private nonisolated let audioPlatterTracker = ScratchPlatterTracker()

    /// One platter revolution's worth of CC6 ring-counter steps. Mirrors the
    /// same measured Rane ONE MKII constant macOS keeps locally in
    /// `MacCaptureEngine`/`ScratchSamplePlaybackController` (each side owns its
    /// own copy there too — this isn't a new duplication pattern).
    private static let midiStepsPerRevolution: Double = 3932

    /// Per-attempt accumulation of raw CC6 platter telemetry, in the exact
    /// shared `CaptureCore.RawMixerMIDIEvent` shape macOS's
    /// `MacCaptureEngine.capturedMidiCCEvents` accumulates. Decoded by
    /// `platterMovementEvents` below via the same shared, unmodified
    /// `CaptureCore.derivePlatterMovementEvents` pure function macOS uses
    /// for Practice/Review notation — no separate decode algorithm. This is
    /// purely a notation/state feed; it plays no part in scratch audio or
    /// hotcue behaviour. Reset per attempt via `resetCapturedPlatterEvents()`.
    private(set) var capturedPlatterMIDIEvents: [CaptureCore.RawMixerMIDIEvent] = []
    /// Per-attempt learned crossfader telemetry. This stays separate from the
    /// platter array so the existing platter decoders keep their exact input,
    /// then both streams are merged only when the take snapshot is finalized.
    private(set) var capturedCrossfaderMIDIEvents: [CaptureCore.RawMixerMIDIEvent] = []
    /// Per-attempt upfader (channel-fader) telemetry. Kept in its own array
    /// for the same reason the crossfader is: the platter decoders must keep
    /// their exact input, and `deriveDetectedNotationFaderEvents` must keep
    /// seeing only crossfader samples. Upfader movement is recorded as raw
    /// evidence only - it drives gain, and the canonical notation model has
    /// no upfader lane, so nothing here is turned into notation events.
    private(set) var capturedUpfaderMIDIEvents: [CaptureCore.RawMixerMIDIEvent] = []
    /// Coalesced live renderer input. Raw platter MIDI can arrive much faster
    /// than SwiftUI should redraw, so this is refreshed at the same ~25 Hz
    /// cadence as the macOS live tracker rather than publishing every packet.
    @Published private(set) var livePlatterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []
    @Published private(set) var crossfaderMIDIValue: Int?
    @Published private(set) var leftUpfaderMIDIValue: Int?
    @Published private(set) var rightUpfaderMIDIValue: Int?
    @Published private(set) var lastHotCueIndex: Int?
    @Published private(set) var lastHotCueSampleID: String?
    private var captureBaselineTimestamp: Double = CACurrentMediaTime()
    private var liveNotationUpdateScheduled = false
    private static let liveNotationUpdateInterval: TimeInterval = 0.04
    private static let liveNotationWindowDuration: TimeInterval = 3.2
    /// Index into the append-only per-attempt raw stream. It moves only to an
    /// existing decoder-committed run boundary after that run leaves the live
    /// viewport, or along motor rotation already rejected by the pre-existing
    /// release gate. It never enters an active/visible scratch run.
    private var liveNotationDecodeAnchorIndex = 0
    /// Until the RANE touch-state message is captured, distinguish a released
    /// powered platter from hand motion by its sustained, stable 33⅓-RPM CC6
    /// rate. This gates only the live preview publication; raw attempt evidence
    /// and Result decoding remain untouched.
    private static let motorReleaseDetectionWindow: TimeInterval = 0.35
    private static let motorReleaseMinimumDuration: TimeInterval = 0.28
    private static let motorReleaseStepsPerSecondRange = 1_700.0...2_300.0
    private var isSuppressingReleasedMotorRotation = false
    private static let iOSPlatterDeviceName = "iOS RANE Platter"

    #if DEBUG
    private var lastPlatterDebugLogUptime: TimeInterval = -.infinity
    private let platterDebugLogInterval: TimeInterval = 0.5
    #endif

    init(
        transportState: TransportState,
        playbackEngine: IOScratchPlaybackEngine,
        learnStore: MIDILearnedMappingStore = .default
    ) {
        self.transportState = transportState
        self.playbackEngine = playbackEngine
        self.learnStore = learnStore
    }

    /// Refresh the learned mapping for the active device so hot-cue presses
    /// resolve against the right per-device assignments.
    func updateMapping(deviceIdentifier: String?, deviceName: String? = nil) {
        currentMapping = deviceIdentifier.flatMap { learnStore.load(deviceIdentifier: $0) }
        // Prefer the caller's live endpoint name; fall back to the saved
        // mapping's name so a previously-learned device keeps its identity.
        let resolvedName = deviceName ?? currentMapping?.deviceName
        currentDeviceIdentity = deviceIdentifier == nil
            ? nil
            : resolvedName.map { MIDIDeviceIdentity(sourceName: $0) }
    }

    /// The crossfader mapping provenance in effect for this device, or nil when
    /// neither a learned mapping nor a certified registry binding covers it.
    /// Drives Hardware Setup wording and the take's recorded evidence.
    var crossfaderMappingSource: FaderMappingSource? {
        if currentMapping?.control(for: .crossfader) != nil { return .learned }
        guard let currentDeviceIdentity,
              let match = MIDIHardwareRegistry.shared.bestMatch(for: currentDeviceIdentity),
              match.confidence == .certified,
              match.profile.bindings.contains(where: { $0.role.kind == .crossfader && !$0.isDiagnosticOnly })
        else { return nil }
        return .certifiedRegistry
    }

    /// Clears accumulated CC6 telemetry and rebaselines the take-relative
    /// clock. Call at the start of each new Practice attempt/take so a prior
    /// attempt's movement can never leak into the next one's notation trace.
    func resetCapturedPlatterEvents() {
        capturedPlatterMIDIEvents.removeAll()
        capturedCrossfaderMIDIEvents.removeAll()
        capturedUpfaderMIDIEvents.removeAll()
        livePlatterMovementEvents.removeAll()
        liveNotationDecodeAnchorIndex = 0
        captureBaselineTimestamp = CACurrentMediaTime()
        captureStopRelativeTime = nil
        isSuppressingReleasedMotorRotation = false
        #if DEBUG
        print("[SCRATCH-DEBUG] shared scratch state reset for new attempt")
        #endif
    }

    /// Take-relative instant Stop was requested, or nil while the take is still
    /// running. Finalization is not instantaneous — the movie-file callback can
    /// arrive well after Stop, and the finalization watchdog exists for exactly
    /// that window — so without this bound a fader move made after Stop would
    /// be decoded into the finished take's evidence.
    private var captureStopRelativeTime: Double?

    /// Marks the end of the take window. Called when Stop is requested, in the
    /// same `CACurrentMediaTime()` domain as `captureBaselineTimestamp`, so the
    /// bound never has to be reconciled against the sidecar's wall-clock dates.
    func markCaptureStopped() {
        guard captureStopRelativeTime == nil else { return }
        captureStopRelativeTime = max(0, CACurrentMediaTime() - captureBaselineTimestamp)
    }

    /// Drops events that arrived after Stop, via the shared boundary rule.
    /// Applied to the finalized snapshot only; the live preview is already
    /// gated on the recording flow state, so during a take this is a no-op.
    private func withinTakeWindow(
        _ events: [CaptureCore.RawMixerMIDIEvent]
    ) -> [CaptureCore.RawMixerMIDIEvent] {
        CaptureMotionEvidenceResolver.eventsWithinTakeWindow(
            events,
            stopRelativeTime: captureStopRelativeTime
        )
    }

    /// Canonical decoded movement events for the current attempt, via the
    /// same shared `CaptureCore.derivePlatterMovementEvents` decode macOS's
    /// `MacCaptureEngine.resolvedControllerMovementEvents` uses for its
    /// Practice/Review notation. Right deck only (channel 1), matching the
    /// single-loaded-sample product decision already applied throughout
    /// this dispatcher.
    var platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        CaptureCore.derivePlatterMovementEvents(
            from: withinTakeWindow(capturedPlatterMIDIEvents),
            controller: 6,
            channel: ScratchPlatterTracker.rightChannel
        )
    }

    /// Finalized Result-only notation coordinates. Canonical snapshot/export
    /// evidence continues to use `platterMovementEvents`; this view model
    /// reuses the shared decoder and projects accepted runs per gesture.
    var gestureRelativePlatterNotationEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        CaptureCore.deriveGestureRelativePlatterNotationEvents(
            from: withinTakeWindow(capturedPlatterMIDIEvents),
            controller: 6,
            channel: ScratchPlatterTracker.rightChannel
        )
    }

    /// Raw take-relative controller evidence, ordered across platter and
    /// crossfader streams for sidecar persistence and canonical export.
    var capturedMixerMIDIEvents: [CaptureCore.RawMixerMIDIEvent] {
        (withinTakeWindow(capturedPlatterMIDIEvents)
            + withinTakeWindow(capturedCrossfaderMIDIEvents)
            + withinTakeWindow(capturedUpfaderMIDIEvents)).sorted { lhs, rhs in
            if lhs.takeRelativeTime == rhs.takeRelativeTime {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.takeRelativeTime < rhs.takeRelativeTime
        }
    }

    /// Shared crossfader-event derivation used by both the live Capture HUD
    /// and the finalized take snapshot. No presentation-specific inference.
    var capturedCrossfaderEvents: [CaptureCore.DetectedNotationFaderEvent] {
        CaptureCore.deriveDetectedNotationFaderEvents(from: withinTakeWindow(capturedCrossfaderMIDIEvents))
    }

    /// Provenance actually recorded on this take's crossfader evidence, for
    /// review and export. Derived from the persisted events rather than the
    /// live device state, so a mid-take device change cannot retroactively
    /// relabel evidence that was already captured.
    var capturedCrossfaderMappingSource: FaderMappingSource? {
        let sources = Set(withinTakeWindow(capturedCrossfaderMIDIEvents).compactMap(\.mappingSource))
        // A learned mapping outranks a registry default if both somehow appear.
        if sources.contains(.learned) { return .learned }
        return sources.contains(.certifiedRegistry) ? .certifiedRegistry : nil
    }

    /// Final take evidence in the same `DetectedNotationSnapshot` schema used
    /// by macOS and canonical export. Returns nil only when the controller did
    /// not produce any platter or crossfader evidence during this take.
    func detectedNotationSnapshot(capturedAt: Date = Date()) -> CaptureCore.DetectedNotationSnapshot? {
        let mixerEvents = capturedMixerMIDIEvents
        let movementEvents = platterMovementEvents
        let faderEvents = capturedCrossfaderEvents
        guard !mixerEvents.isEmpty || !movementEvents.isEmpty || !faderEvents.isEmpty else {
            return nil
        }

        let confidences = movementEvents.map(\.confidence) + faderEvents.map(\.confidence)
        let notationConfidence = confidences.isEmpty
            ? nil
            : confidences.reduce(0, +) / Double(confidences.count)
        var detectionSources: [String] = []
        if !movementEvents.isEmpty {
            detectionSources.append("controller")
        }
        if !faderEvents.isEmpty {
            detectionSources.append("midi")
        }

        return CaptureCore.DetectedNotationSnapshot(
            notationSource: confidences.isEmpty ? "unavailable" : "detected",
            notationConfidence: notationConfidence,
            detectedLabel: nil,
            labelSource: "unknown",
            labelConfidence: nil,
            detectionSources: detectionSources,
            recordMovementEvents: movementEvents,
            audioEvents: [],
            faderEvents: faderEvents,
            mixerMidiEvents: mixerEvents,
            capturedAt: capturedAt
        )
    }

    /// Presentation-only movement stream for the active Practice surface.
    /// Unlike `platterMovementEvents` (which force-closes the trailing run for
    /// Result), this keeps the current run provisional and adapts it to the
    /// existing performed-notation event shape. The decoder and its noise/
    /// segmentation rules remain the shared `CaptureCore` implementation.
    private func decodeLivePlatterMovementEvents() -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        let result = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: liveNotationMIDIEvents,
            controller: 6,
            channel: ScratchPlatterTracker.rightChannel
        )
        let latestTime = capturedPlatterMIDIEvents.last(where: isRightPlatterEvent)?
            .takeRelativeTime ?? 0
        let cutoff = max(0, latestTime - Self.liveNotationWindowDuration)
        let committed = result.committedEvents.filter { $0.endTime >= cutoff }
        advanceLiveNotationAnchor(
            past: result.committedEvents,
            before: cutoff
        )
        guard let provisional = result.provisionalMovement else {
            return committed
        }

        let duration = max(0, provisional.currentTime - provisional.startTime)
        // Match finalized controller events: speed remains raw steps/second,
        // while start/currentPosition are the shared gesture-relative notation
        // coordinate. This prevents the presentation adapter from applying the
        // platter scale twice to an open stroke.
        let distance = abs(provisional.displacement)
        let preview = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: provisional.startTime,
            endTime: provisional.currentTime,
            startPosition: provisional.startPosition,
            endPosition: provisional.currentPosition,
            direction: provisional.direction,
            movementKind: provisional.movementKind,
            speed: duration > 0 ? distance / duration : 0,
            confidence: 0.5,
            source: "live_preview"
        )
        return committed + [preview]
    }

    private func isRightPlatterEvent(
        _ event: CaptureCore.RawMixerMIDIEvent
    ) -> Bool {
        event.controller == 6 && event.channel == ScratchPlatterTracker.rightChannel
    }

    /// A decoder-boundary-anchored suffix. Unlike the former time-cut slice,
    /// this cannot start inside a committed or provisional run, so coordinates
    /// and timing of every still-visible stroke remain append-only.
    private var liveNotationMIDIEvents: [CaptureCore.RawMixerMIDIEvent] {
        guard liveNotationDecodeAnchorIndex < capturedPlatterMIDIEvents.count else {
            return []
        }
        return Array(capturedPlatterMIDIEvents.dropFirst(liveNotationDecodeAnchorIndex))
    }

    private func advanceLiveNotationAnchor(
        past committedEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
        before cutoff: TimeInterval
    ) {
        guard let boundaryTime = committedEvents
            .filter({ $0.endTime < cutoff })
            .map(\.endTime)
            .max(),
              liveNotationDecodeAnchorIndex < capturedPlatterMIDIEvents.count else {
            return
        }
        let candidateIndexes = liveNotationDecodeAnchorIndex..<capturedPlatterMIDIEvents.count
        guard let boundaryIndex = candidateIndexes.last(where: { index in
            let event = capturedPlatterMIDIEvents[index]
            return isRightPlatterEvent(event)
                && event.takeRelativeTime <= boundaryTime + 1e-9
        }) else {
            return
        }
        liveNotationDecodeAnchorIndex = boundaryIndex
    }

    /// While the existing motor-release gate suppresses free rotation, bound
    /// decode work but retain one complete classifier window. The gate can stay
    /// true for the first few reverse packets; that tail must survive so a pull
    /// keeps its exact onset and excursion when suppression clears.
    private func advanceLiveNotationAnchorPastSuppressedMotorRotation() {
        guard let latestIndex = capturedPlatterMIDIEvents.indices.last(where: {
            isRightPlatterEvent(capturedPlatterMIDIEvents[$0])
        }) else {
            return
        }
        let latestTime = capturedPlatterMIDIEvents[latestIndex].takeRelativeTime
        guard CaptureCore.canAdvanceLiveNotationAnchorPastSuppressedMotorRotation(
            publishedEvents: livePlatterMovementEvents,
            latestTime: latestTime,
            viewportDuration: Self.liveNotationWindowDuration
        ) else {
            return
        }
        guard let boundedIndex = CaptureCore
            .liveNotationAnchorIndexPreservingSuppressedMotorTail(
                in: capturedPlatterMIDIEvents,
                currentAnchorIndex: liveNotationDecodeAnchorIndex,
                controller: 6,
                channel: ScratchPlatterTracker.rightChannel,
                latestTime: latestTime,
                lookBehindDuration: Self.motorReleaseDetectionWindow
            ) else {
            return
        }
        liveNotationDecodeAnchorIndex = boundedIndex
    }

    private func scheduleLiveNotationUpdate() {
        guard !liveNotationUpdateScheduled else { return }
        liveNotationUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveNotationUpdateInterval) { [weak self] in
            guard let self else { return }
            self.liveNotationUpdateScheduled = false
            let suppressMotorRotation = self.isLikelyReleasedMotorRotation
            #if DEBUG
            if suppressMotorRotation != self.isSuppressingReleasedMotorRotation {
                print("[NOTATION-DEBUG] released motor rotation \(suppressMotorRotation ? "suppressed" : "ended")")
            }
            #endif
            self.isSuppressingReleasedMotorRotation = suppressMotorRotation
            guard !suppressMotorRotation else {
                self.advanceLiveNotationAnchorPastSuppressedMotorRotation()
                return
            }
            self.livePlatterMovementEvents = self.decodeLivePlatterMovementEvents()
        }
    }

    /// Presentation-only release inference for the motorized right platter.
    /// A real scratch reversal exits immediately because any backward travel
    /// fails the forward-dominance gate. A short forward push also remains
    /// visible because it cannot satisfy the sustained-duration gate.
    private var isLikelyReleasedMotorRotation: Bool {
        let matchesRightDeck: (CaptureCore.RawMixerMIDIEvent) -> Bool = {
            $0.controller == 6 && $0.channel == ScratchPlatterTracker.rightChannel
        }
        guard let latest = capturedPlatterMIDIEvents.last(where: matchesRightDeck) else { return false }
        let cutoff = latest.takeRelativeTime - Self.motorReleaseDetectionWindow
        var reversedRecent: [CaptureCore.RawMixerMIDIEvent] = []
        for event in capturedPlatterMIDIEvents.reversed() {
            if event.takeRelativeTime < cutoff { break }
            if matchesRightDeck(event) { reversedRecent.append(event) }
        }
        let recent = reversedRecent.reversed()
        guard let first = recent.first, recent.count >= 2 else { return false }
        let duration = latest.takeRelativeTime - first.takeRelativeTime
        guard duration >= Self.motorReleaseMinimumDuration else { return false }

        var forwardSteps = 0
        var backwardSteps = 0
        var previousValue = first.value
        for event in recent.dropFirst() {
            var delta = event.value - previousValue
            if delta > 64 { delta -= 128 }
            else if delta < -64 { delta += 128 }
            if delta > 0 { forwardSteps += delta }
            else if delta < 0 { backwardSteps += -delta }
            previousValue = event.value
        }

        let totalTravel = forwardSteps + backwardSteps
        guard totalTravel > 0 else { return false }
        let forwardFraction = Double(forwardSteps) / Double(totalTravel)
        let signedRate = Double(forwardSteps - backwardSteps) / duration
        return forwardFraction >= 0.98
            && Self.motorReleaseStepsPerSecondRange.contains(signedRate)
    }

    /// Process one parsed MIDI message. Transport presses toggle the shared
    /// transport state; hot-cue pads resolve through the shared trigger resolver.
    func receive(_ message: ParsedMIDIMessage) {
        // Platter fast path — mirrors macOS's `MacCaptureEngine
        // .dispatchMIDIChannelVoiceMessage`, which intercepts the raw CC6
        // ring-counter on channel 0/1 before generic action resolution.
        // `MIDIActionResolver` deliberately has no platter-movement case (it
        // only knows transport/hot-cue/crossfader/upfader), so without this,
        // platter CC6 messages fell through to `.unknown` and were dropped —
        // the iOS parity gap this fixes.
        if message.messageType == .controlChange, message.controlNumber == 6,
           Int(message.channel) == ScratchPlatterTracker.leftChannel || Int(message.channel) == ScratchPlatterTracker.rightChannel {
            handlePlatterCC(message)
            return
        }

        let action = MIDIActionResolver.resolve(
            message: message,
            mapping: currentMapping,
            identity: currentDeviceIdentity
        )
        switch action {
        case .transport:
            transportState.toggle()
            #if DEBUG
            print("[MIDI-DEBUG] transportPlay received")
            print("[MIDI-DEBUG] transport state = \(transportState.isPlaying ? "playing" : "stopped")")
            print("[MIDI-DEBUG] platter running = \(transportState.isPlaying)")
            #endif
        case .hotCue(let semanticAction, _):
            let decision = HotCueTriggerResolver.resolve(action: action)
            #if DEBUG
            print("[MIDI-DEBUG] hotcue trigger decision · shouldTrigger=\(decision.shouldTrigger) sample=\(decision.sampleID ?? "nil")")
            #endif
            guard decision.shouldTrigger, let sampleID = decision.sampleID else { return }
            lastHotCueIndex = semanticAction?.hotCueIndex
            lastHotCueSampleID = playbackEngine.audioOwnershipMode.allowsLocalScratchPlayback
                ? sampleID
                : nil
            #if DEBUG
            print("[MIDI-DEBUG] hotcue resolved · sample=\(sampleID)")
            #endif
            playbackEngine.playHotCue(sampleID: sampleID)
        case .crossfader(let value, let source):
            crossfaderMIDIValue = value
            // A learned control carries the user's own min/max/inverted
            // calibration. A certified registry binding has none, so it uses the
            // plain 7-bit range the profile documents — never a learned control's
            // calibration borrowed from a different action.
            let learnedControl = currentMapping?.control(for: .crossfader)
            let normalizedValue = learnedControl?.normalizedValue(from: value)
                ?? MIDIControlNormalization.sevenBit(value)
            let eventTimestamp = CACurrentMediaTime()
            capturedCrossfaderMIDIEvents.append(
                CaptureCore.RawMixerMIDIEvent(
                    timestamp: eventTimestamp,
                    takeRelativeTime: max(0, eventTimestamp - captureBaselineTimestamp),
                    deviceName: currentMapping?.deviceName
                        ?? currentDeviceIdentity?.sourceName
                        ?? "iOS MIDI Controller",
                    channel: Int(message.channel),
                    controller: Int(message.controlNumber),
                    value: value,
                    normalizedValue: normalizedValue,
                    mappedControl: "crossfader",
                    mappingSource: source
                )
            )
            // Evidence-only for the certified-registry fallback: recognising a
            // crossfader from the hardware registry must never start cutting
            // ScratchLab's audio on a device the user never mapped. Only an
            // explicit learned mapping drives audible playback.
            if source == .learned {
                playbackEngine.setCrossfaderPosition(normalizedValue)
            }
        case .upfader(let deck, let value):
            if deck == 0 {
                leftUpfaderMIDIValue = value
            } else if deck == 1 {
                rightUpfaderMIDIValue = value
            }

            // Raw evidence only, mirroring the crossfader path. Without this
            // the upfader drove audible gain while leaving no trace in
            // `mixerMidiEvents`, so a take's exported evidence silently
            // omitted an entire control stream.
            let upfaderControl = deck == 0 ? "leftUpfader" : "rightUpfader"
            let upfaderLearnedControl = currentMapping?
                .control(for: deck == 0 ? .leftUpfader : .rightUpfader)
            let upfaderTimestamp = CACurrentMediaTime()
            capturedUpfaderMIDIEvents.append(
                CaptureCore.RawMixerMIDIEvent(
                    timestamp: upfaderTimestamp,
                    takeRelativeTime: max(0, upfaderTimestamp - captureBaselineTimestamp),
                    deviceName: currentMapping?.deviceName
                        ?? currentDeviceIdentity?.sourceName
                        ?? "iOS MIDI Controller",
                    channel: Int(message.channel),
                    controller: Int(message.controlNumber),
                    value: value,
                    normalizedValue: upfaderLearnedControl?.normalizedValue(from: value)
                        ?? MIDIControlNormalization.sevenBit(value),
                    mappedControl: upfaderControl
                )
            )

            // The loaded scratch sample remains right-deck-owned, so the
            // right upfader is the primary gain source. If this device has
            // no right-upfader mapping at all, fall back to routing the
            // left upfader through the same gain path — otherwise a
            // single mapped channel fader learned as "left" would have no
            // audible effect (the fader moves in the debug readout but
            // never reaches playback).
            if deck == 1, let control = currentMapping?.control(for: .rightUpfader) {
                playbackEngine.setRightUpfaderGain(control.normalizedValue(from: value))
            } else if deck == 0,
                      currentMapping?.control(for: .rightUpfader) == nil,
                      let control = currentMapping?.control(for: .leftUpfader) {
                playbackEngine.setRightUpfaderGain(control.normalizedValue(from: value))
            }
        case .unknown:
            break
        }
    }

    /// CoreMIDI-thread fast path used only to publish the right-deck absolute
    /// phase to the audio clock. No ObservableObject or Practice state is
    /// touched here.
    nonisolated func receivePlatterAudioMessage(_ message: ParsedMIDIMessage) {
        let channel = Int(message.channel)
        guard message.messageType == .controlChange,
              message.controlNumber == 6,
              channel == ScratchPlatterTracker.leftChannel
                || channel == ScratchPlatterTracker.rightChannel else { return }
        audioPlatterTracker.ingest(channel: channel, value: Int(message.value))
        guard channel == ScratchPlatterTracker.rightChannel else { return }
        playbackEngine.publishRawPlatterPhase(
            Double(audioPlatterTracker.accumulatedSteps(for: channel))
        )
    }

    /// Decode one raw CC6 platter ring-counter event and, for the right deck
    /// only (channel 1 — same single-loaded-sample product decision macOS
    /// applies), publish the resulting `PlatterPosition` to the playback
    /// engine. The left deck (channel 0) is tracked for parity/diagnostics
    /// but never drives playback, matching macOS.
    private func handlePlatterCC(_ message: ParsedMIDIMessage) {
        let channel = Int(message.channel)
        let delta = platterTracker.ingest(channel: channel, value: Int(message.value))
        let steps = platterTracker.accumulatedSteps(for: channel)
        let direction = platterTracker.recentDirection(for: channel)

        // Notation/state feed only — parallel to (not a replacement for)
        // the audio-driving `platterTracker.ingest` above. Recorded for
        // both decks, matching this dispatcher's existing "both decks
        // tracked for parity/diagnostics" precedent; `platterMovementEvents`
        // filters to the right deck at decode time, same as macOS.
        let eventTimestamp = CACurrentMediaTime()
        capturedPlatterMIDIEvents.append(CaptureCore.RawMixerMIDIEvent(
            timestamp: eventTimestamp,
            takeRelativeTime: max(0, eventTimestamp - captureBaselineTimestamp),
            deviceName: Self.iOSPlatterDeviceName,
            channel: channel,
            controller: 6,
            value: Int(message.value),
            normalizedValue: Double(message.value) / 127.0,
            mappedControl: nil
        ))
        if channel == ScratchPlatterTracker.rightChannel {
            scheduleLiveNotationUpdate()
        }
        #if DEBUG
        let shouldLogSharedState = capturedPlatterMIDIEvents.count % 32 == 0
        if shouldLogSharedState {
            print("[SCRATCH-DEBUG] shared scratch state updated · capturedEvents=\(capturedPlatterMIDIEvents.count)")
        }
        #endif

        #if DEBUG
        let shouldLog: Bool = {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPlatterDebugLogUptime >= platterDebugLogInterval else { return false }
            lastPlatterDebugLogUptime = now
            return true
        }()
        if shouldLog {
            print("[MIDI-DEBUG] platter movement received · channel=\(channel) value=\(message.value) delta=\(delta ?? 0)")
            print("[MIDI-DEBUG] platter decoded · steps=\(steps) direction=\(String(describing: direction))")
        }
        #endif

        guard channel == ScratchPlatterTracker.rightChannel else { return }

        let platterDirection: PlatterDirection
        switch direction {
        case .forward: platterDirection = .forward
        case .backward: platterDirection = .backward
        case nil: platterDirection = .idle
        }
        let normalized = Self.normalizedPosition(forSteps: steps)
        let position = PlatterPosition(
            phase: Double(steps),
            direction: platterDirection,
            velocity: platterTracker.recentVelocity(for: channel),
            normalizedPosition: normalized
        )
        #if DEBUG
        if shouldLog {
            print("[MIDI-DEBUG] platter normalizedPosition update · \(normalized)")
        }
        #endif
        playbackEngine.updatePlatterPosition(position)
    }

    /// Maps accumulated CC6 steps onto a 0...1 sample position, one platter
    /// revolution = one pass through the loaded sample (wrapping). Pure
    /// control-path math — no clock, no velocity-driven playback; the
    /// position only ever moves in direct response to a real MIDI delta.
    private static func normalizedPosition(forSteps steps: Int) -> Double {
        let wrapped = Double(steps).truncatingRemainder(dividingBy: midiStepsPerRevolution)
        return wrapped < 0 ? (wrapped + midiStepsPerRevolution) / midiStepsPerRevolution
                            : wrapped / midiStepsPerRevolution
    }

}
