//
//  ScratchActionClassifier.swift
//  ScratchLab
//
//  Phase 2 stub. The intent is to classify scratch motion from a window of
//  hand/record-trajectory features (Vision-derived), NOT from raw camera
//  frames. The interface here lets the rest of the app integrate against a
//  stable shape today; the implementation lands in Phase 2 once a feature
//  extractor (e.g. wrist + record-edge tracking) is in place.
//

import Foundation
import CoreGraphics

// MARK: - Motion frame

/// One feature-extracted observation in time. Phase 2 will populate this from
/// Vision's hand-pose / object-tracking output. Coordinates are normalized in
/// `[0, 1]` relative to the image with a top-left origin (x →, y ↓); depth /
/// velocity fields are reserved for later expansion.
///
/// Fields are intentionally optional so a single struct can represent
/// partial observations (Vision may detect a hand but not the record edge,
/// or vice versa). New optional fields may be appended over time; existing
/// call sites are not broken because every new field is defaulted.
public struct ScratchMotionFrame: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval
    public let dominantHand: CGPoint?
    public let recordEdgeAngle: Double?
    public let crossfaderPosition: Double?

    // Phase 2 additions — Vision-derived hand-pose landmarks and rig anchors.
    // Normalized to `[0, 1]` in image space (top-left origin) when present.
    public let dominantHandWrist: CGPoint?
    public let dominantHandIndexTip: CGPoint?
    public let dominantHandThumbTip: CGPoint?
    public let dominantHandMiddleTip: CGPoint?
    public let dominantHandConfidence: Float?
    public let secondaryHandWrist: CGPoint?
    public let recordCenter: CGPoint?

    public init(
        timestamp: TimeInterval,
        dominantHand: CGPoint? = nil,
        recordEdgeAngle: Double? = nil,
        crossfaderPosition: Double? = nil,
        dominantHandWrist: CGPoint? = nil,
        dominantHandIndexTip: CGPoint? = nil,
        dominantHandThumbTip: CGPoint? = nil,
        dominantHandMiddleTip: CGPoint? = nil,
        dominantHandConfidence: Float? = nil,
        secondaryHandWrist: CGPoint? = nil,
        recordCenter: CGPoint? = nil
    ) {
        self.timestamp = timestamp
        self.dominantHand = dominantHand
        self.recordEdgeAngle = recordEdgeAngle
        self.crossfaderPosition = crossfaderPosition
        self.dominantHandWrist = dominantHandWrist
        self.dominantHandIndexTip = dominantHandIndexTip
        self.dominantHandThumbTip = dominantHandThumbTip
        self.dominantHandMiddleTip = dominantHandMiddleTip
        self.dominantHandConfidence = dominantHandConfidence
        self.secondaryHandWrist = secondaryHandWrist
        self.recordCenter = recordCenter
    }
}

// MARK: - Result

public struct ScratchMotionPrediction: Sendable, Equatable {
    public let label: ScratchClassLabel
    public let confidence: Double
    public let windowEnd: TimeInterval

    public init(label: ScratchClassLabel, confidence: Double, windowEnd: TimeInterval) {
        self.label = label
        self.confidence = confidence
        self.windowEnd = windowEnd
    }
}

// MARK: - Errors

public enum ScratchActionClassifierError: Error, Equatable {
    /// No motion model has been trained or wired up yet (expected in Phase 1).
    case notImplemented
    case modelMissing(filename: String)
    case modelLoadFailed(underlying: String)
    case insufficientFrames(have: Int, need: Int)
}

// MARK: - Protocol

/// Stable interface for whatever motion model lands in Phase 2.
public protocol ScratchActionClassifying: AnyObject {
    /// Push a single motion observation into the rolling window.
    func ingest(frame: ScratchMotionFrame)
    /// Run inference on the current window if it has enough frames.
    func classifyCurrentWindow() throws -> ScratchMotionPrediction?
    /// Reset accumulated state.
    func reset()
}

// MARK: - Phase 1 stub

/// Placeholder implementation. Accepts ingestion calls so callers can wire up
/// without crashing, but never produces a prediction. Replace with a real
/// implementation in Phase 2 (likely backed by a small temporal model trained
/// on Vision-derived motion features rather than raw frames).
public final class ScratchActionClassifierStub: ScratchActionClassifying {
    public init() {}

    public func ingest(frame: ScratchMotionFrame) {
        // intentionally empty in the stub
    }

    public func classifyCurrentWindow() throws -> ScratchMotionPrediction? {
        throw ScratchActionClassifierError.notImplemented
    }

    public func reset() {}
}
