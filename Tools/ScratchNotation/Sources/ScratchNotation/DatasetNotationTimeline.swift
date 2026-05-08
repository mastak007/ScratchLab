//
//  DatasetNotationTimeline.swift
//  ScratchNotation
//
//  Per-take ordered event list plus context (scratch type, bpm, beat mode,
//  approval state). Versioned with `schemaVersion` so older sidecar files
//  can be migrated by future readers.
//

import Foundation

public enum DatasetNotationBeatMode: String, Codable, Sendable, CaseIterable {
    /// Scratch audio only — metronome track absent.
    case noBeat
    /// Metronome track only — scratch audio absent.
    case beatOnly
    /// Both metronome and scratch audio mixed together.
    case beatPlusScratch
    /// Beat mode could not be determined or is not applicable.
    case unknown
}

public enum DatasetNotationApprovalState: String, Codable, Sendable, CaseIterable {
    case inferred
    case needsReview
    case approved
    case rejected
}

public struct DatasetNotationTimeline: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public var takeID: String
    public var scratchType: String
    public var bpm: Int?
    public var beatMode: DatasetNotationBeatMode
    public var duration: TimeInterval
    public var events: [DatasetNotationEvent]
    public var approvalState: DatasetNotationApprovalState
    public var schemaVersion: Int

    public init(
        takeID: String,
        scratchType: String,
        bpm: Int? = nil,
        beatMode: DatasetNotationBeatMode,
        duration: TimeInterval,
        events: [DatasetNotationEvent] = [],
        approvalState: DatasetNotationApprovalState = .inferred,
        schemaVersion: Int = DatasetNotationTimeline.currentSchemaVersion
    ) {
        self.takeID = takeID
        self.scratchType = scratchType
        self.bpm = bpm
        self.beatMode = beatMode
        self.duration = max(0, duration)
        self.events = events
        self.approvalState = approvalState
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Conventional sidecar filenames

public enum NotationFile {
    /// Auto-generated notation produced by `ScratchNotationGenerator`.
    public static let inferredFilename = "notation.inferred.json"
    /// Human-reviewed notation. Kept separate so review work is never clobbered
    /// by a re-run of the generator.
    public static let approvedFilename = "notation.approved.json"
}
