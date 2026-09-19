import Foundation
import Synchronization

/// Immutable receive-time facts. Packet time is optional: receipt time is an
/// admission fence, never a substitute measurement timestamp. Not persisted.
struct MIDIIngressMetadata: Equatable, Sendable {
    let sourceID: String
    let sourceName: String
    let connectionID: UUID
    let packetTime: TimeInterval?
    let receivedAt: TimeInterval
    let attemptGeneration: UInt64
}

struct MIDIIngressMessage: Equatable, Sendable {
    let message: ParsedMIDIMessage
    let metadata: MIDIIngressMetadata
}

extension MIDIChannelMessageParser {
    /// All messages in a packet retain its timestamp; no invented spacing.
    static func parse(
        _ bytes: UnsafeRawBufferPointer,
        metadata: MIDIIngressMetadata,
        onMessage: (MIDIIngressMessage) -> Void
    ) {
        parse(bytes) { framed in
            if let message = framed.parsedMessage {
                onMessage(MIDIIngressMessage(message: message, metadata: metadata))
            }
        }
    }
}

/// iOS's existing raw evidence window, with admission and append owned by one
/// actor. The receive thread only loads an atomic ticket; it never waits for
/// the main actor or reads mutable buffers/mapping state. macOS retains its
/// existing capture owner and does not instantiate this model.
@MainActor
final class MIDIAttemptEvidence {
    nonisolated let ingressGeneration = Atomic<UInt64>(0)

    enum Interruption: String, Equatable {
        case sourceChanged, connectionChanged, sourceUnavailable, timestampUnavailable
    }

    private var nextGeneration: UInt64 = 0
    private(set) var activeGeneration: UInt64?
    private var connections: [String: UUID] = [:]
    private var selectedSourceID: String?
    private var activeConnectionID: UUID?
    private(set) var baseline: TimeInterval = 0
    private(set) var stopRelativeTime: TimeInterval?
    private(set) var interruption: Interruption?
    private(set) var platterEvents: [CaptureCore.RawMixerMIDIEvent] = []
    private(set) var crossfaderEvents: [CaptureCore.RawMixerMIDIEvent] = []
    private(set) var upfaderEvents: [CaptureCore.RawMixerMIDIEvent] = []

    func selectSource(_ id: String?, at now: TimeInterval) {
        if selectedSourceID != id, activeGeneration != nil {
            seal(at: now, reason: .sourceChanged)
        }
        selectedSourceID = id
    }

    func updateConnections(_ updated: [String: UUID], at now: TimeInterval) {
        if activeGeneration != nil,
           selectedSourceID.flatMap({ updated[$0] }) != activeConnectionID {
            seal(at: now, reason: .connectionChanged)
        }
        connections = updated
    }

    func begin(at now: TimeInterval) {
        clear(at: now)
        guard now.isFinite, now > 0,
              let id = selectedSourceID, let connection = connections[id] else {
            interruption = .sourceUnavailable
            return
        }
        // Zero is permanently closed. Exhaustion fails closed rather than
        // allowing an ancient ticket to become valid again.
        guard nextGeneration < UInt64.max else { return }
        nextGeneration += 1
        activeConnectionID = connection
        activeGeneration = nextGeneration
        stopRelativeTime = nil
        ingressGeneration.store(nextGeneration, ordering: .releasing)
    }

    func clear(at now: TimeInterval) {
        seal(at: now)
        platterEvents.removeAll()
        crossfaderEvents.removeAll()
        upfaderEvents.removeAll()
        baseline = now
        stopRelativeTime = 0
        interruption = nil
    }

    func seal(at now: TimeInterval, reason: Interruption? = nil) {
        ingressGeneration.store(0, ordering: .releasing)
        guard activeGeneration != nil else { return }
        activeGeneration = nil
        activeConnectionID = nil
        stopRelativeTime = max(0, now - baseline)
        interruption = reason
        if let reason {
            print("[MIDI-EVIDENCE] window sealed: \(reason.rawValue); start a new attempt to resume evidence")
        }
    }

    /// Admission and append are synchronous on the main actor. A queued A
    /// message cannot acquire B's ticket or B's clock when it is delivered.
    @discardableResult
    func record(
        _ ingress: MIDIIngressMessage,
        normalizedValue: Double,
        mappedControl: String? = nil,
        mappingSource: FaderMappingSource? = nil
    ) -> Bool {
        let metadata = ingress.metadata
        guard let activeGeneration,
              metadata.attemptGeneration == activeGeneration,
              metadata.sourceID == selectedSourceID,
              metadata.connectionID == activeConnectionID,
              metadata.receivedAt.isFinite, metadata.receivedAt > baseline else { return false }
        guard let time = metadata.packetTime, time.isFinite, time > 0,
              time <= metadata.receivedAt else {
            // A missing/invalid timestamp cannot be encoded as precise raw
            // evidence in the existing schema. Seal so later samples cannot
            // bridge the unplaceable packet. Preserve its absence explicitly
            // in ingress metadata and the window's interruption reason.
            seal(at: metadata.receivedAt, reason: .timestampUnavailable)
            return false
        }
        guard time >= baseline else { return false }
        let message = ingress.message
        let event = CaptureCore.RawMixerMIDIEvent(
            timestamp: time, takeRelativeTime: time - baseline,
            deviceIdentifier: metadata.sourceID, deviceName: metadata.sourceName,
            channel: Int(message.channel), controller: Int(message.controlNumber),
            value: Int(message.value), normalizedValue: normalizedValue,
            mappedControl: mappedControl, mappingSource: mappingSource
        )
        switch mappedControl {
        case "crossfader": crossfaderEvents.append(event)
        case "leftUpfader", "rightUpfader": upfaderEvents.append(event)
        case nil where message.messageType == .controlChange && message.controlNumber == 6:
            platterEvents.append(event)
        default: return false
        }
        return true
    }
}
