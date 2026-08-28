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
/// PLAY (transport Start/Stop press) toggles it on/off, the platter motor then
/// spins the record, and hot-cue presses are only resolved while it is playing.
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
    /// Keep live position normalization local to the same rolling interval the
    /// Practice lane displays. Finalized Result notation continues to decode
    /// the complete attempt from `capturedPlatterMIDIEvents`.
    private static let liveNotationWindowDuration: TimeInterval = 3.2
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
    func updateMapping(deviceIdentifier: String?) {
        currentMapping = deviceIdentifier.flatMap { learnStore.load(deviceIdentifier: $0) }
    }

    /// Clears accumulated CC6 telemetry and rebaselines the take-relative
    /// clock. Call at the start of each new Practice attempt/take so a prior
    /// attempt's movement can never leak into the next one's notation trace.
    func resetCapturedPlatterEvents() {
        capturedPlatterMIDIEvents.removeAll()
        livePlatterMovementEvents.removeAll()
        captureBaselineTimestamp = CACurrentMediaTime()
        isSuppressingReleasedMotorRotation = false
        #if DEBUG
        print("[SCRATCH-DEBUG] shared scratch state reset for new attempt")
        #endif
    }

    /// Canonical decoded movement events for the current attempt, via the
    /// same shared `CaptureCore.derivePlatterMovementEvents` decode macOS's
    /// `MacCaptureEngine.resolvedControllerMovementEvents` uses for its
    /// Practice/Review notation. Right deck only (channel 1), matching the
    /// single-loaded-sample product decision already applied throughout
    /// this dispatcher.
    var platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        CaptureCore.derivePlatterMovementEvents(
            from: capturedPlatterMIDIEvents,
            controller: 6,
            channel: ScratchPlatterTracker.rightChannel
        )
    }

    /// Presentation-only movement stream for the active Practice surface.
    /// Unlike `platterMovementEvents` (which force-closes the trailing run for
    /// Result), this keeps the current run provisional and adapts it to the
    /// existing performed-notation event shape. The decoder and its noise/
    /// segmentation rules remain the shared `CaptureCore` implementation.
    private var decodedLivePlatterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        let result = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: liveNotationMIDIEvents,
            controller: 6,
            channel: ScratchPlatterTracker.rightChannel
        )
        guard let provisional = result.provisionalMovement else {
            return result.committedEvents
        }

        let duration = max(0, provisional.currentTime - provisional.startTime)
        let distance = abs(provisional.currentPosition - provisional.startPosition)
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
        return result.committedEvents + [preview]
    }

    /// Right-deck CC6 telemetry covering the visible live interval, plus the
    /// immediately preceding sample needed to preserve the first modular
    /// delta. Re-decoding this bounded slice rebases the decoder's existing
    /// 0...1 position normalization as the window advances, preventing a long
    /// forward or backward run from pinning the trace to an attempt-wide
    /// maximum or minimum. This is presentation-only; the source telemetry is
    /// never trimmed or mutated.
    private var liveNotationMIDIEvents: [CaptureCore.RawMixerMIDIEvent] {
        let matchesRightPlatter: (CaptureCore.RawMixerMIDIEvent) -> Bool = {
            $0.controller == 6 && $0.channel == ScratchPlatterTracker.rightChannel
        }
        guard let latestTime = capturedPlatterMIDIEvents.last(where: matchesRightPlatter)?.takeRelativeTime else {
            return []
        }

        let cutoff = max(0, latestTime - Self.liveNotationWindowDuration)
        var reversedWindow: [CaptureCore.RawMixerMIDIEvent] = []
        for event in capturedPlatterMIDIEvents.reversed() where matchesRightPlatter(event) {
            reversedWindow.append(event)
            if event.takeRelativeTime < cutoff {
                break
            }
        }
        return Array(reversedWindow.reversed())
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
            guard !suppressMotorRotation else { return }
            self.livePlatterMovementEvents = self.decodedLivePlatterMovementEvents
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

        let action = MIDIActionResolver.resolve(message: message, mapping: currentMapping)
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
            lastHotCueSampleID = sampleID
            #if DEBUG
            print("[MIDI-DEBUG] hotcue resolved · sample=\(sampleID)")
            #endif
            playbackEngine.playHotCue(sampleID: sampleID)
        case .crossfader(let value):
            crossfaderMIDIValue = value
            if let control = currentMapping?.control(for: .crossfader) {
                playbackEngine.setCrossfaderPosition(control.normalizedValue(from: value))
            }
        case .upfader(let deck, let value):
            if deck == 0 {
                leftUpfaderMIDIValue = value
            } else if deck == 1 {
                rightUpfaderMIDIValue = value
            }

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
