#if os(macOS)
import Foundation
import CoreMIDI
import Darwin

// Phase 1 controller-input: real Core MIDI input transport (macOS, input-only).
//
// Scope guardrails (deliberate):
// - INPUT ONLY. Opens a Core MIDI client + input port, connects to all sources,
//   and forwards every raw event. It writes nothing to any device (no LEDs, no
//   motor, no SysEx out) and decodes nothing about meaning.
// - No device assumptions, no hard-coded CC numbers, no RANE ONE mapping, no
//   Serato. The whole point is to *observe* what the hardware actually sends.
// - Class-compliant Core MIDI only — no HID, no USB, no entitlement beyond the
//   sandbox the app already ships with.
// - Bytes are preserved verbatim into `MIDIRawEvent`; the timestamp is monotonic
//   seconds derived from the packet's `MIDITimeStamp` (or receipt time if 0).

/// Monotonic seconds from a mach host-time stamp, on one shared clock so MIDI
/// (and any future transport) are directly comparable.
struct MIDIMonotonicClock {
    private let scale: Double // host ticks → seconds

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // ticks * (numer/denom) = nanoseconds → seconds.
        scale = (Double(info.numer) / Double(info.denom)) / 1_000_000_000.0
    }

    func seconds(fromHostTime hostTime: UInt64) -> TimeInterval {
        Double(hostTime) * scale
    }

    func now() -> TimeInterval {
        seconds(fromHostTime: mach_absolute_time())
    }
}

/// A MIDI source as seen by Core MIDI, for the Inspector's source picker.
struct MIDISourceInfo: Sendable, Equatable, Hashable, Identifiable {
    /// Core MIDI unique ID (stable per device while connected).
    let id: Int32
    /// Display name (e.g. "RANE ONE").
    let name: String
}

/// Real Core MIDI input transport. Conforms to the existing `MIDITransport`
/// seam (whole-message delivery via `onEvent`) and additionally exposes a
/// source-tagged path (`onSourcedEvent`) the Inspector uses to label each event.
final class CoreMIDIInputTransport: MIDITransport {
    private(set) var isRunning = false

    /// `MIDITransport` seam: whole-message delivery, source-agnostic.
    var onEvent: ((MIDIRawEvent) -> Void)?

    /// Richer delivery used by the Inspector: source name + raw event. Always
    /// called on the main queue. Set before `start()`.
    var onSourcedEvent: ((String, MIDIRawEvent) -> Void)?

    /// Called (on the main queue) whenever the set of available sources changes,
    /// including hot-plug. Set before `start()`.
    var onSourcesChanged: (([MIDISourceInfo]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private let clock = MIDIMonotonicClock()

    /// Endpoint → display name, used to label events arriving on the MIDI thread.
    /// Guarded by `nameLock` because the receive block runs off-main.
    private var sourceNames: [MIDIEndpointRef: String] = [:]
    private var connectedSources: Set<MIDIEndpointRef> = []
    private let nameLock = NSLock()

    init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let clientName = "ScratchLab Controller Inspector" as CFString
        let status = MIDIClientCreateWithBlock(clientName, &client) { [weak self] notificationPtr in
            self?.handleNotification(notificationPtr)
        }
        guard status == noErr else {
            isRunning = false
            return
        }

        let portName = "ScratchLab Input" as CFString
        let portStatus = MIDIInputPortCreateWithBlock(client, portName, &inputPort) { [weak self] packetListPtr, srcConnRefCon in
            self?.handlePackets(packetListPtr, srcConnRefCon: srcConnRefCon)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            isRunning = false
            return
        }

        isRunning = true
        refreshAndConnectSources()
    }

    func stop() {
        guard isRunning || client != MIDIClientRef() else { return }
        if inputPort != MIDIPortRef() {
            for source in connectedSources {
                MIDIPortDisconnectSource(inputPort, source)
            }
            MIDIPortDispose(inputPort)
            inputPort = MIDIPortRef()
        }
        if client != MIDIClientRef() {
            MIDIClientDispose(client)
            client = MIDIClientRef()
        }
        nameLock.lock()
        connectedSources.removeAll()
        sourceNames.removeAll()
        nameLock.unlock()
        isRunning = false
    }

    // MARK: - Sources

    /// Enumerates current Core MIDI sources, connects any not yet connected, and
    /// caches their names. Safe to call repeatedly (idempotent per endpoint).
    private func refreshAndConnectSources() {
        guard isRunning else { return }
        let count = MIDIGetNumberOfSources()
        var infos: [MIDISourceInfo] = []
        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != MIDIEndpointRef() else { continue }
            let name = displayName(for: endpoint)
            let uniqueID = uniqueID(for: endpoint)
            infos.append(MIDISourceInfo(id: uniqueID, name: name))

            nameLock.lock()
            sourceNames[endpoint] = name
            let alreadyConnected = connectedSources.contains(endpoint)
            nameLock.unlock()

            if !alreadyConnected {
                // Pass the endpoint ref as the connection refCon so the receive
                // block can recover which source an event came from.
                let refCon = UnsafeMutableRawPointer(bitPattern: UInt(endpoint))
                if MIDIPortConnectSource(inputPort, endpoint, refCon) == noErr {
                    nameLock.lock()
                    connectedSources.insert(endpoint)
                    nameLock.unlock()
                }
            }
        }
        let snapshot = infos
        DispatchQueue.main.async { [weak self] in
            self?.onSourcesChanged?(snapshot)
        }
    }

    private func displayName(for endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        if status == noErr, let value = name?.takeRetainedValue() {
            return value as String
        }
        return "MIDI Source \(endpoint)"
    }

    private func uniqueID(for endpoint: MIDIEndpointRef) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value)
        return value
    }

    // MARK: - Core MIDI callbacks

    private func handleNotification(_ notificationPtr: UnsafePointer<MIDINotification>) {
        // Re-enumerate when the MIDI setup changes (hot-plug / unplug).
        if notificationPtr.pointee.messageID == .msgSetupChanged {
            DispatchQueue.main.async { [weak self] in
                self?.refreshAndConnectSources()
            }
        }
    }

    private func handlePackets(_ packetListPtr: UnsafePointer<MIDIPacketList>, srcConnRefCon: UnsafeMutableRawPointer?) {
        // Recover the originating endpoint from the connection refCon and look up
        // its cached name (the lock keeps this consistent with hot-plug updates).
        let endpoint = MIDIEndpointRef(UInt(bitPattern: srcConnRefCon))
        nameLock.lock()
        let sourceName = sourceNames[endpoint] ?? "Unknown Source"
        nameLock.unlock()

        // Keep the MIDI thread's work to: copy bytes, split, timestamp, hand off.
        var pending: [MIDIRawEvent] = []
        for packet in packetListPtr.unsafeSequence() {
            let length = Int(packet.pointee.length)
            guard length > 0 else { continue }
            let packetBytes: [UInt8] = withUnsafeBytes(of: packet.pointee.data) { buffer in
                Array(buffer.prefix(length))
            }
            let hostTime = packet.pointee.timeStamp
            // A timeStamp of 0 means "now"; substitute receipt time on one clock.
            let timestamp = hostTime == 0 ? clock.now() : clock.seconds(fromHostTime: hostTime)

            for message in MIDIMessageParsing.splitIntoMessages(packetBytes) {
                pending.append(MIDIRawEvent(timestamp: timestamp, bytes: message))
            }
        }

        guard !pending.isEmpty else { return }
        let events = pending
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                self.onEvent?(event)
                self.onSourcedEvent?(sourceName, event)
            }
        }
    }
}
#endif
