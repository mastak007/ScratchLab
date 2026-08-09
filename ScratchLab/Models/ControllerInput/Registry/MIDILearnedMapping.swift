import Foundation

// MARK: - Learned MIDI Mapping Model
//
// Generic, Codable, versioned per-device mapping model for ScratchLab's MIDI Learn
// system. Each learned mapping ties a physical MIDI control to a semantic action
// (crossfader, upfader, hot cue, etc.) and persists per device so a Rane mapping
// is never silently applied to a Pioneer mixer.
//
// Scope guardrails (deliberate):
// - Pure value types only. No Core MIDI, no audio, no playback, no UI.
// - Lives alongside the existing Registry types (MIDIControlRole, MIDIControlBinding,
//   MIDIControllerProfile) and composes with them but does not replace them.
// - Learned user overrides take precedence over built-in profiles at resolve time;
//   this model stores them; the resolver is in the engine layer.

// MARK: - Semantic Action

/// The semantic action a user-learned MIDI control performs.
/// These are the concrete behaviours ScratchLab needs from mixer controls — more
/// specific than the registry's generic `MIDIControlRole.Kind`.
enum MIDISemanticAction: String, Codable, CaseIterable, Equatable {
    case crossfader
    case leftUpfader
    case rightUpfader
    case hotCue1
    case hotCue2
    case hotCue3
    case hotCue4
    case hotCue5
    case hotCue6
    case hotCue7
    case hotCue8
    case unassigned

    /// Hot-cue index (1–8), or nil for non-hot-cue actions.
    var hotCueIndex: Int? {
        switch self {
        case .hotCue1:  return 1
        case .hotCue2:  return 2
        case .hotCue3:  return 3
        case .hotCue4:  return 4
        case .hotCue5:  return 5
        case .hotCue6:  return 6
        case .hotCue7:  return 7
        case .hotCue8:  return 8
        default:         return nil
        }
    }

    /// The matching `MIDIControlRole.Kind` for profile-matching purposes.
    var roleKind: MIDIControlRole.Kind {
        switch self {
        case .crossfader:            return .crossfader
        case .leftUpfader, .rightUpfader: return .channelFader
        case .hotCue1, .hotCue2, .hotCue3, .hotCue4,
             .hotCue5, .hotCue6, .hotCue7, .hotCue8:
            return .pad
        case .unassigned:            return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .crossfader:    return "Crossfader"
        case .leftUpfader:   return "Left Upfader"
        case .rightUpfader:  return "Right Upfader"
        case .hotCue1:       return "Hot Cue 1"
        case .hotCue2:       return "Hot Cue 2"
        case .hotCue3:       return "Hot Cue 3"
        case .hotCue4:       return "Hot Cue 4"
        case .hotCue5:       return "Hot Cue 5"
        case .hotCue6:       return "Hot Cue 6"
        case .hotCue7:       return "Hot Cue 7"
        case .hotCue8:       return "Hot Cue 8"
        case .unassigned:    return "Unassigned"
        }
    }

    /// Short label used in MIDI Learn UI pickers.
    var shortLabel: String {
        switch self {
        case .crossfader:    return "XF"
        case .leftUpfader:   return "L↑"
        case .rightUpfader:  return "R↑"
        case .hotCue1:       return "Cue1"
        case .hotCue2:       return "Cue2"
        case .hotCue3:       return "Cue3"
        case .hotCue4:       return "Cue4"
        case .hotCue5:       return "Cue5"
        case .hotCue6:       return "Cue6"
        case .hotCue7:       return "Cue7"
        case .hotCue8:       return "Cue8"
        case .unassigned:    return "—"
        }
    }
}

// MARK: - MIDI Message Type (learned)

/// The MIDI message type a control uses. Mirrors `MIDIControlSignalType` but kept
/// intentionally simpler — only the two types real DJ mixer controls emit in practice.
enum LearnedMIDIMessageType: String, Codable, CaseIterable, Equatable {
    case controlChange
    case note

    var displayName: String {
        switch self {
        case .controlChange: return "CC"
        case .note:          return "Note"
        }
    }
}

// MARK: - Learned Control

/// One user-learned MIDI mapping for a single physical control.
/// Persisted per device; user-learned overrides take precedence over built-in profiles.
struct MIDILearnedControl: Codable, Equatable, Identifiable {
    /// Stable identifier for this learned entry (action-based, unique within a device).
    var id: String { action.rawValue }

    /// What this control does.
    let action: MIDISemanticAction

    /// How it reports over MIDI.
    let messageType: LearnedMIDIMessageType

    /// MIDI channel 0–15 (as received in the byte stream).
    let channel: Int

    /// CC controller number (for CC messages) or note number (for Note messages).
    let controlNumber: Int

    /// The deck this control targets (0 = left, 1 = right). Nil for deck-agnostic
    /// controls (e.g. crossfader).
    let deck: Int?

    /// Minimum observed value (after learning phase observation). Default 0.
    let minValue: Int

    /// Maximum observed value (after learning phase observation). Default 127.
    let maxValue: Int

    /// When true, the value range is inverted (127 → 0, 0 → 127).
    let inverted: Bool

    /// Assigned scratch sample ID for hot-cue actions. Nil for fader actions.
    let assignedSampleID: String?

    /// The ISO 8601 timestamp when this mapping was learned or last updated.
    let learnedAt: Date

    /// Whether this mapping was verified against real hardware (set by user action).
    let isVerified: Bool

    init(
        action: MIDISemanticAction,
        messageType: LearnedMIDIMessageType,
        channel: Int,
        controlNumber: Int,
        deck: Int? = nil,
        minValue: Int = 0,
        maxValue: Int = 127,
        inverted: Bool = false,
        assignedSampleID: String? = nil,
        learnedAt: Date = Date(),
        isVerified: Bool = false
    ) {
        self.action = action
        self.messageType = messageType
        self.channel = channel
        self.controlNumber = controlNumber
        self.deck = deck
        self.minValue = minValue
        self.maxValue = maxValue
        self.inverted = inverted
        self.assignedSampleID = assignedSampleID
        self.learnedAt = learnedAt
        self.isVerified = isVerified
    }

    /// Normalize a raw MIDI value (0–127) through this control's observed range and
    /// optional inversion. Result is clamped to 0.0…1.0.
    func normalizedValue(from rawValue: Int) -> Double {
        let clamped = max(minValue, min(maxValue, rawValue))
        let range = maxValue - minValue
        guard range > 0 else { return 0.0 }
        let linear = Double(clamped - minValue) / Double(range)
        return inverted ? (1.0 - linear) : linear
    }

    /// Returns true when this mapping can coexist with `other` (no collision).
    /// Two mappings collide when they listen on the same (channel, controlNumber, messageType).
    func isCompatible(with other: MIDILearnedControl) -> Bool {
        if self.action == other.action { return true } // same action is an update, not a collision
        return !(self.messageType == other.messageType
              && self.channel == other.channel
              && self.controlNumber == other.controlNumber)
    }

    /// Display-friendly label for this learned mapping.
    var displayName: String {
        let typeLabel = messageType == .controlChange
            ? "CC\(controlNumber)"
            : "Note\(controlNumber)"
        let chLabel = "Ch\(channel + 1)"
        return "\(action.displayName) — \(typeLabel) \(chLabel)"
    }
}

// MARK: - Device Mapping

/// Per-device collection of user-learned MIDI mappings.
/// Keyed by a stable Core MIDI unique ID string. Versioned for forward compatibility.
struct MIDIDeviceMapping: Codable, Equatable {
    /// Schema version this build writes and expects.
    static let currentSchemaVersion = 1

    let schemaVersion: Int

    /// Stable device identifier (e.g. "midi_<uniqueID>").
    let deviceIdentifier: String

    /// User-facing device name (from Core MIDI source display name).
    /// `var` because a mapping can be refreshed in place if the device is renamed.
    var deviceName: String

    /// The learned controls for this device, keyed by action.
    var controls: [MIDILearnedControl]

    /// The ISO 8601 timestamp when this device mapping was created.
    let createdAt: Date

    /// The ISO 8601 timestamp when this device mapping was last modified.
    var lastModifiedAt: Date

    init(
        schemaVersion: Int = MIDIDeviceMapping.currentSchemaVersion,
        deviceIdentifier: String,
        deviceName: String,
        controls: [MIDILearnedControl] = [],
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.controls = controls
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
    }

    /// Find a learned control by action. Returns nil if not learned.
    func control(for action: MIDISemanticAction) -> MIDILearnedControl? {
        controls.first { $0.action == action }
    }

    /// Whether any fader mapping exists.
    var hasFaderMappings: Bool {
        controls.contains { $0.action == .crossfader || $0.action == .leftUpfader || $0.action == .rightUpfader }
    }

    /// Whether any hot-cue mapping exists.
    var hasHotCueMappings: Bool {
        controls.contains { $0.action.hotCueIndex != nil }
    }

    /// Checks whether a new learned control collides with any existing mapping
    /// (excluding the same action, which would be an update).
    func collisionExists(for candidate: MIDILearnedControl) -> MIDILearnedControl? {
        controls.first { !candidate.isCompatible(with: $0) }
    }

    /// Replace or add a learned control, and bump `lastModifiedAt`.
    mutating func upsert(_ control: MIDILearnedControl) {
        if let existingIndex = controls.firstIndex(where: { $0.action == control.action }) {
            controls[existingIndex] = control
        } else {
            controls.append(control)
        }
        lastModifiedAt = Date()
    }

    /// Remove a learned mapping for an action.
    mutating func remove(action: MIDISemanticAction) {
        controls.removeAll { $0.action == action }
        lastModifiedAt = Date()
    }

    /// Remove all learned mappings for this device.
    mutating func clearAll() {
        controls.removeAll()
        lastModifiedAt = Date()
    }

    /// Whether the mapping is empty (no learned controls).
    var isEmpty: Bool { controls.isEmpty }

    /// Decodes a device mapping, failing closed on unsupported schema versions.
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> MIDIDeviceMapping {
        let mapping = try decoder.decode(MIDIDeviceMapping.self, from: data)
        guard mapping.schemaVersion == currentSchemaVersion else {
            throw MIDIDeviceMappingError.unsupportedSchemaVersion(mapping.schemaVersion)
        }
        return mapping
    }
}

// MARK: - Errors

enum MIDIDeviceMappingError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case fileNotFound
    case encodeFailed
}

// MARK: - Persistence Store

/// Manages persistent storage and retrieval of per-device learned MIDI mappings.
///
/// Each device's mappings are stored as a separate JSON file, keyed by the stable
/// device identifier. This provides isolation (Rane mappings are never applied to
/// Pioneer) and simple operations (load one device, save one device, delete one device).
///
/// `load`/`save`/`delete` perform synchronous file I/O on the calling thread — they
/// are not internally queued or dispatched. Callers must invoke this store from a
/// context where synchronous disk access is acceptable (e.g. the main thread from a
/// user action), never from a realtime callback such as the CoreMIDI input block.
final class MIDILearnedMappingStore: Sendable {

    /// Default store at `~/Library/Application Support/ScratchLab/MIDIMappings/`.
    static let `default` = MIDILearnedMappingStore()

    private let baseURL: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = appSupport.appendingPathComponent("ScratchLab/MIDIMappings", isDirectory: true)
        }
        // Synchronous and one-time: a `save()` called immediately after init must
        // never race an async directory-creation task and silently no-op.
        try? fileManager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    /// Filename for a device mapping, derived from the stable device identifier.
    private func fileURL(for deviceIdentifier: String) -> URL {
        // Sanitize the identifier: replace path-unfriendly characters.
        let safe = deviceIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return baseURL.appendingPathComponent("\(safe).json")
    }

    // MARK: - Load

    /// Load the learned mapping for a device, or nil if none exists or decode fails.
    func load(deviceIdentifier: String) -> MIDIDeviceMapping? {
        try? loadOrThrow(deviceIdentifier: deviceIdentifier)
    }

    /// Load the learned mapping for a device, or nil if none exists.
    /// Unlike `load(deviceIdentifier:)`, a corrupt or unreadable file throws instead of
    /// silently returning nil, so callers can surface a persistence error to the user.
    func loadOrThrow(deviceIdentifier: String) throws -> MIDIDeviceMapping? {
        let url = fileURL(for: deviceIdentifier)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try MIDIDeviceMapping.decode(from: data, decoder: decoder)
    }

    /// Load all stored device mappings.
    func loadAll() -> [MIDIDeviceMapping] {
        guard let files = try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MIDIDeviceMapping? in
                guard let data = try? Data(contentsOf: url),
                      let mapping = try? MIDIDeviceMapping.decode(from: data, decoder: decoder)
                else { return nil }
                return mapping
            }
    }

    // MARK: - Save

    /// Save (create or update) the learned mapping for a device.
    func save(_ mapping: MIDIDeviceMapping) {
        let url = fileURL(for: mapping.deviceIdentifier)
        guard let data = try? encoder.encode(mapping) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Delete

    /// Delete the learned mapping for a device.
    func delete(deviceIdentifier: String) {
        let url = fileURL(for: deviceIdentifier)
        try? fileManager.removeItem(at: url)
    }

    /// List all device identifiers with stored mappings.
    func storedDeviceIdentifiers() -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
