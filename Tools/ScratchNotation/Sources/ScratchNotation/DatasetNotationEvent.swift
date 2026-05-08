//
//  DatasetNotationEvent.swift
//  ScratchNotation
//
//  Single annotation in a take's timeline.
//

import Foundation

public enum DatasetNotationEventType: String, Codable, Sendable, CaseIterable {
    case stroke
    case hold
    case silence
    case unknown
}

public enum DatasetNotationDirection: String, Codable, Sendable, CaseIterable {
    case forward
    case back
    case none
    case unknown
}

public enum DatasetNotationSource: String, Codable, Sendable, CaseIterable {
    case audio
    case vision
    case fused
    case manual
}

public struct DatasetNotationEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var type: DatasetNotationEventType
    public var direction: DatasetNotationDirection
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var beatPosition: Double?
    public var source: DatasetNotationSource
    public var confidence: Double
    public var approved: Bool

    public var duration: TimeInterval { max(0, endTime - startTime) }

    public init(
        id: UUID = UUID(),
        type: DatasetNotationEventType,
        direction: DatasetNotationDirection,
        startTime: TimeInterval,
        endTime: TimeInterval,
        beatPosition: Double? = nil,
        source: DatasetNotationSource,
        confidence: Double,
        approved: Bool = false
    ) {
        self.id = id
        self.type = type
        self.direction = direction
        self.startTime = startTime
        self.endTime = endTime
        self.beatPosition = beatPosition
        self.source = source
        self.confidence = max(0, min(1, confidence))
        self.approved = approved
    }
}
