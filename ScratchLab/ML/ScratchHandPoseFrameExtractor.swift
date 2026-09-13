// Shared Vision-to-feature conversion used by the existing extraction tool
// and offline app analysis. Hand slots are chosen by observation confidence on
// each frame; they are not persistent person/left/right/dominant-hand identity.
import Foundation
import CoreGraphics
import Vision

public enum ScratchHandPoseFrameExtractor {
    public static func frame(
        from image: CGImage,
        timestamp: Double,
        maximumHandCount: Int = 2
    ) throws -> ScratchMotionFrame {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHandCount

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? [])
            .sorted { $0.confidence > $1.confidence }

        guard let dominant = observations.first else {
            return ScratchMotionFrame(timestamp: timestamp)
        }

        let dominantPoints = recognizedPoints(for: dominant)
        let secondaryWrist: CGPoint? = observations.dropFirst().first.flatMap { secondary in
            recognizedPoints(for: secondary).wrist
        }

        let primaryHandPoint = dominantPoints.indexTip ?? dominantPoints.wrist

        return ScratchMotionFrame(
            timestamp: timestamp,
            dominantHand: primaryHandPoint,
            recordEdgeAngle: nil,
            crossfaderPosition: nil,
            dominantHandWrist: dominantPoints.wrist,
            dominantHandIndexTip: dominantPoints.indexTip,
            dominantHandThumbTip: dominantPoints.thumbTip,
            dominantHandMiddleTip: dominantPoints.middleTip,
            dominantHandConfidence: dominant.confidence,
            secondaryHandWrist: secondaryWrist,
            recordCenter: nil
        )
    }

    private struct DominantPoints {
        var wrist: CGPoint?
        var indexTip: CGPoint?
        var thumbTip: CGPoint?
        var middleTip: CGPoint?
    }

    private static func recognizedPoints(for observation: VNHumanHandPoseObservation) -> DominantPoints {
        var points = DominantPoints()
        if let wrist = try? observation.recognizedPoint(.wrist) {
            points.wrist = topLeftPoint(from: wrist)
        }
        if let index = try? observation.recognizedPoint(.indexTip) {
            points.indexTip = topLeftPoint(from: index)
        }
        if let thumb = try? observation.recognizedPoint(.thumbTip) {
            points.thumbTip = topLeftPoint(from: thumb)
        }
        if let middle = try? observation.recognizedPoint(.middleTip) {
            points.middleTip = topLeftPoint(from: middle)
        }
        return points
    }

    /// Vision returns normalized points with a bottom-left origin and a
    /// confidence in `[0, 1]`. Drop low-confidence detections (they're
    /// usually off-image extrapolations) and flip y so callers see
    /// top-left-origin coordinates that match CGImage / SwiftUI.
    private static func topLeftPoint(from point: VNRecognizedPoint) -> CGPoint? {
        guard point.confidence > 0 else { return nil }
        return CGPoint(x: point.location.x, y: 1.0 - point.location.y)
    }

}
