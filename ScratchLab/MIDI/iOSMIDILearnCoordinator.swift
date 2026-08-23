import Combine
import Foundation

/// Main-thread MIDI Learn state for iOS. CoreMIDI transport remains owned by
/// `IOSMIDIManager`; this object only turns an explicitly requested next
/// message into the existing per-device learned-mapping model.
@MainActor
final class IOSMIDILearnCoordinator: ObservableObject {
    @Published private(set) var activeAction: MIDISemanticAction?
    @Published private(set) var currentMapping: MIDIDeviceMapping?
    @Published private(set) var feedback = ""
    @Published private(set) var selectedDeviceName: String?

    private let store: MIDILearnedMappingStore
    private var selectedDeviceID: String?

    init(store: MIDILearnedMappingStore = .default) {
        self.store = store
    }

    func selectDevice(id: String, name: String) {
        guard selectedDeviceID != id else {
            if selectedDeviceName != name { selectedDeviceName = name }
            return
        }
        activeAction = nil
        feedback = ""
        selectedDeviceID = id
        selectedDeviceName = name
        currentMapping = store.load(deviceIdentifier: id)
    }

    func clearDeviceSelection() {
        activeAction = nil
        currentMapping = nil
        feedback = ""
        selectedDeviceID = nil
        selectedDeviceName = nil
    }

    func startLearning(_ action: MIDISemanticAction) {
        guard selectedDeviceID != nil else {
            feedback = "Connect one MIDI device before learning a control."
            return
        }
        activeAction = action
        feedback = action.hotCueIndex == nil
            ? "Move the \(action.displayName.lowercased()) now."
            : "Press \(action.displayName.lowercased()) now."
    }

    func cancelLearning() {
        activeAction = nil
        feedback = ""
    }

    func receive(_ message: ParsedMIDIMessage) {
        guard let action = activeAction,
              let deviceID = selectedDeviceID,
              let deviceName = selectedDeviceName,
              let learnedType = learnedType(for: message, action: action) else { return }

        let controlNumber = learnedType == .controlChange
            ? Int(message.controlNumber)
            : Int(message.noteNumber)
        let control = MIDILearnedControl(
            action: action,
            messageType: learnedType,
            channel: Int(message.channel),
            controlNumber: controlNumber,
            deck: deck(for: action),
            minValue: 0,
            maxValue: 127,
            inverted: false,
            assignedSampleID: currentMapping?.control(for: action)?.assignedSampleID,
            learnedAt: Date(),
            isVerified: true,
            curveConfig: nil
        )

        var mapping = currentMapping
            ?? MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: deviceName)
        if let collision = mapping.collisionExists(for: control) {
            feedback = "That control is already mapped to \(collision.action.displayName). Move another control."
            return
        }
        mapping.deviceName = deviceName
        mapping.upsert(control)
        store.save(mapping)
        currentMapping = mapping
        activeAction = nil
        feedback = "Learned \(control.displayName)."
    }

    func clear(_ action: MIDISemanticAction) {
        guard let deviceID = selectedDeviceID, var mapping = currentMapping else { return }
        mapping.remove(action: action)
        if mapping.isEmpty {
            store.delete(deviceIdentifier: deviceID)
            currentMapping = nil
        } else {
            store.save(mapping)
            currentMapping = mapping
        }
        if activeAction == action { activeAction = nil }
        feedback = "Cleared \(action.displayName)."
    }

    func assignSample(_ sampleID: String?, to action: MIDISemanticAction) {
        guard action.hotCueIndex != nil,
              var mapping = currentMapping,
              let existing = mapping.control(for: action) else { return }
        let normalized = sampleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = MIDILearnedControl(
            action: existing.action,
            messageType: existing.messageType,
            channel: existing.channel,
            controlNumber: existing.controlNumber,
            deck: existing.deck,
            minValue: existing.minValue,
            maxValue: existing.maxValue,
            inverted: existing.inverted,
            assignedSampleID: normalized?.isEmpty == false ? normalized : nil,
            learnedAt: existing.learnedAt,
            isVerified: existing.isVerified,
            curveConfig: existing.curveConfig
        )
        mapping.upsert(updated)
        store.save(mapping)
        currentMapping = mapping
        feedback = updated.assignedSampleID.map {
            "Assigned \($0) to \(action.displayName)."
        } ?? "Removed the sample from \(action.displayName)."
    }

    func control(for action: MIDISemanticAction) -> MIDILearnedControl? {
        currentMapping?.control(for: action)
    }

    private func learnedType(
        for message: ParsedMIDIMessage,
        action: MIDISemanticAction
    ) -> LearnedMIDIMessageType? {
        if action.hotCueIndex != nil {
            switch message.messageType {
            case .noteOn where message.value > 0: return .note
            case .controlChange: return .controlChange
            default: return nil
            }
        }
        guard message.messageType == .controlChange else { return nil }
        return .controlChange
    }

    private func deck(for action: MIDISemanticAction) -> Int? {
        switch action {
        case .leftUpfader: return 0
        case .rightUpfader: return 1
        default: return nil
        }
    }
}
