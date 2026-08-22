import AVFoundation
import Combine
import CoreMIDI
import Foundation

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

    /// The active hot-cue player. Retained so playback is not cut short when a
    /// fresh `AVAudioPlayer` would otherwise deallocate at the end of the call.
    private var hotCuePlayer: AVAudioPlayer?

    init(transportState: TransportState, learnStore: MIDILearnedMappingStore = .default) {
        self.transportState = transportState
        self.learnStore = learnStore
    }

    /// Refresh the learned mapping for the active device so hot-cue presses
    /// resolve against the right per-device assignments.
    func updateMapping(deviceIdentifier: String?) {
        currentMapping = deviceIdentifier.flatMap { learnStore.load(deviceIdentifier: $0) }
    }

    /// Process one parsed MIDI message. Transport presses toggle the shared
    /// transport state; hot-cue pads resolve only while it is playing.
    func receive(_ message: ParsedMIDIMessage) {
        switch MIDIActionResolver.resolve(message: message, mapping: currentMapping) {
        case .transport:
            transportState.toggle()
            #if DEBUG
            print("[MIDI-DEBUG] transportPlay received")
            print("[MIDI-DEBUG] transport state = \(transportState.isPlaying ? "playing" : "stopped")")
            print("[MIDI-DEBUG] platter running = \(transportState.isPlaying)")
            #endif
        case .hotCue(_, let sampleID):
            guard transportState.isPlaying, let sampleID else { return }
            #if DEBUG
            print("[MIDI-DEBUG] hotcue resolved · sample=\(sampleID)")
            #endif
            playHotCue(sampleID: sampleID)
        case .crossfader, .upfader, .unknown:
            break
        }
    }

    /// Plays a resolved hot-cue sample immediately. Uses `AVAudioPlayer` — the
    /// same lightweight path `SampleManager` uses for previews — so playback
    /// coexists with the existing audio session: no session/category changes,
    /// no DVS routing impact.
    private func playHotCue(sampleID: String) {
        #if DEBUG
        print("[MIDI-DEBUG] hotcue playback requested · sample=\(sampleID)")
        #endif

        guard let url = ScratchSampleResolver.url(for: sampleID) else {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=not found (\(sampleID))")
            #endif
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            hotCuePlayer = player
            #if DEBUG
            print("[MIDI-DEBUG] sample loaded · \(sampleID)")
            #endif
            guard player.play() else {
                #if DEBUG
                print("[MIDI-DEBUG] sample playback failed · reason=play returned false")
                #endif
                return
            }
            #if DEBUG
            print("[MIDI-DEBUG] sample playback started · \(sampleID)")
            #endif
        } catch {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

}
