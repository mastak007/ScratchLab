/// Evidence-based readiness for the CoreMIDI transport only. This does not
/// imply that a controller is mapped, calibrated, or controlling playback.
enum MIDIReadinessState: Equatable, Sendable {
    case unavailable
    case deviceConnected
    case receivingMessages

    static func classify(
        hasConnectedDevice: Bool,
        hasReceivedValidMessage: Bool
    ) -> MIDIReadinessState {
        guard hasConnectedDevice else { return .unavailable }
        return hasReceivedValidMessage ? .receivingMessages : .deviceConnected
    }
}
