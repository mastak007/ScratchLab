import Combine
import CoreMIDI
import Foundation
import QuartzCore

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
    @Published private(set) var capturedPlatterMIDIEvents: [CaptureCore.RawMixerMIDIEvent] = []
    private var captureBaselineTimestamp: Double = CACurrentMediaTime()
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
        captureBaselineTimestamp = CACurrentMediaTime()
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
        case .hotCue:
            let decision = HotCueTriggerResolver.resolve(action: action, transportState: transportState)
            #if DEBUG
            print("[MIDI-DEBUG] hotcue trigger decision · shouldTrigger=\(decision.shouldTrigger) sample=\(decision.sampleID ?? "nil")")
            #endif
            guard decision.shouldTrigger, let sampleID = decision.sampleID else { return }
            #if DEBUG
            print("[MIDI-DEBUG] hotcue resolved · sample=\(sampleID)")
            #endif
            playbackEngine.playHotCue(sampleID: sampleID)
        case .crossfader, .upfader, .unknown:
            break
        }
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
            print("[MIDI-DEBUG] platter CC6 received · channel=\(channel) value=\(message.value) delta=\(delta ?? 0)")
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
