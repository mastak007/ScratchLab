//
//  NotationEvidence.swift
//  ScratchNotation
//
//  Inputs to `ScratchNotationGenerator`. These are intentionally decoupled
//  from any concrete extractor (Vision, custom DSP, manual annotation) so the
//  generator can be unit-tested with synthetic evidence.
//

import Foundation

// MARK: - Audio evidence

public struct AudioOnsetEvent: Codable, Sendable, Equatable {
    /// Start of the detected scratch sound, in seconds from the take's t=0.
    public let startTime: TimeInterval
    /// End of the detected scratch sound, in seconds from t=0.
    public let endTime: TimeInterval
    /// Onset detector confidence in `[0, 1]`.
    public let confidence: Double

    public init(startTime: TimeInterval, endTime: TimeInterval, confidence: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = max(0, min(1, confidence))
    }
}

public struct AudioSilenceEvent: Codable, Sendable, Equatable {
    /// Start of a continuous silent region, seconds from t=0.
    public let startTime: TimeInterval
    /// End of the silent region.
    public let endTime: TimeInterval
    /// Silence detector confidence in `[0, 1]`.
    public let confidence: Double

    public init(startTime: TimeInterval, endTime: TimeInterval, confidence: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = max(0, min(1, confidence))
    }
}

// MARK: - Visual evidence

public enum VisualMotionDirection: String, Codable, Sendable {
    case forward
    case back
    case still
}

public struct VisualMotionEvent: Codable, Sendable, Equatable {
    public let direction: VisualMotionDirection
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double

    public init(direction: VisualMotionDirection,
                startTime: TimeInterval,
                endTime: TimeInterval,
                confidence: Double) {
        self.direction = direction
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = max(0, min(1, confidence))
    }
}

// MARK: - Beat grid

/// Regular metronome grid for a take. `firstBeatTime` anchors beat 0 in seconds
/// from t=0; `beatPosition(at:)` reports fractional beat indices (e.g. 2.5 ==
/// halfway between beats 2 and 3).
public struct BeatGrid: Codable, Sendable, Equatable {
    public let bpm: Double
    public let firstBeatTime: TimeInterval
    public let beatCount: Int

    public init(bpm: Double, firstBeatTime: TimeInterval, beatCount: Int) {
        self.bpm = bpm
        self.firstBeatTime = firstBeatTime
        self.beatCount = beatCount
    }

    public var beatLength: TimeInterval {
        guard bpm > 0 else { return 0 }
        return 60.0 / bpm
    }

    public func beatPosition(at time: TimeInterval) -> Double? {
        guard beatLength > 0 else { return nil }
        return (time - firstBeatTime) / beatLength
    }
}
