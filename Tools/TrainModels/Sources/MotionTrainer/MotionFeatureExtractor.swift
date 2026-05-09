//
//  MotionFeatureExtractor.swift
//  MotionTrainer
//
//  Slice A of the Phase 2 action-classifier pipeline. Reads an mp4, samples
//  frames at a configurable rate, and runs `VNDetectHumanHandPoseRequest`
//  per frame to produce a `[ScratchMotionFrame]` time series. The result is
//  what the CLI writes out as JSONL — never a raw video tensor and never a
//  trained model.
//
//  Coordinate convention: every CGPoint in the emitted frames is in
//  normalized image space `[0, 1]` with a TOP-LEFT origin (x →, y ↓).
//  Vision returns landmarks in bottom-left normalized coordinates, so this
//  extractor flips y on the way out. The runtime feature extractor that
//  lands in a later slice should match this convention.
//
//  Crossfader / record-edge / record-center fields are left nil here. They
//  come from rig-layout detection that already exists in the desktop app's
//  `MacCaptureEngine`; factoring that out is a separate slice.
//

import Foundation
import AVFoundation
import CoreGraphics
import Vision
import ScratchLabML

public struct MotionFeatureExtractor: Sendable {

    public struct Configuration: Sendable {
        /// Frames per second to sample from the source clip. The actual count
        /// of emitted frames is `floor(duration * fps) + 1` clamped to >= 1.
        public var fps: Double
        /// Maximum hands Vision should track per frame. The dominant hand is
        /// chosen as the highest-confidence observation; if a second hand is
        /// present its wrist is captured in `secondaryHandWrist`.
        public var maximumHandCount: Int
        /// Tolerance (seconds) handed to AVAssetImageGenerator. A small value
        /// gives us frame-accurate sampling at the cost of more decode work.
        public var sampleToleranceSeconds: Double

        public init(
            fps: Double = 30,
            maximumHandCount: Int = 2,
            sampleToleranceSeconds: Double = 0.005
        ) {
            self.fps = fps
            self.maximumHandCount = maximumHandCount
            self.sampleToleranceSeconds = sampleToleranceSeconds
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Synchronously extract motion features from `clipURL`. Synchronous so
    /// the CLI can iterate clips serially without an async runtime; the
    /// underlying generator is driven via a dispatch group internally.
    public func extract(clipURL: URL) throws -> [ScratchMotionFrame] {
        guard configuration.fps > 0 else {
            return []
        }

        let asset = AVURLAsset(url: clipURL)
        let durationSeconds: Double
        do {
            durationSeconds = try syncDurationSeconds(of: asset)
        } catch {
            throw MotionTrainerError.clipUnreadable(
                path: clipURL.lastPathComponent,
                underlying: error.localizedDescription
            )
        }
        guard durationSeconds > 0 else {
            return []
        }

        let frameCount = max(1, Int((durationSeconds * configuration.fps).rounded(.down)) + 1)
        let timescale: CMTimeScale = 600
        let times: [NSValue] = (0..<frameCount).map { i in
            let seconds = min(Double(i) / configuration.fps, durationSeconds)
            return NSValue(time: CMTime(seconds: seconds, preferredTimescale: timescale))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: configuration.sampleToleranceSeconds,
            preferredTimescale: timescale
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: configuration.sampleToleranceSeconds,
            preferredTimescale: timescale
        )

        let images = collectImages(generator: generator, times: times)
        guard !images.isEmpty else {
            throw MotionTrainerError.extractionFailed(
                path: clipURL.lastPathComponent,
                underlying: "no decodable frames"
            )
        }

        return images
            .sorted { $0.requestedSeconds < $1.requestedSeconds }
            .map { sample in
                makeMotionFrame(from: sample.image, timestamp: sample.requestedSeconds)
            }
    }

    // MARK: - Frame collection

    private struct DecodedSample {
        let requestedSeconds: Double
        let image: CGImage
    }

    private func collectImages(
        generator: AVAssetImageGenerator,
        times: [NSValue]
    ) -> [DecodedSample] {
        var collected: [DecodedSample] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for _ in times { group.enter() }

        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
            defer { group.leave() }
            guard result == .succeeded, let image = image else { return }
            lock.lock()
            collected.append(DecodedSample(
                requestedSeconds: requested.seconds,
                image: image
            ))
            lock.unlock()
        }
        group.wait()
        return collected
    }

    // MARK: - Vision

    private func makeMotionFrame(from image: CGImage, timestamp: Double) -> ScratchMotionFrame {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = configuration.maximumHandCount

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ScratchMotionFrame(timestamp: timestamp)
        }

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

    private func recognizedPoints(for observation: VNHumanHandPoseObservation) -> DominantPoints {
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
    private func topLeftPoint(from point: VNRecognizedPoint) -> CGPoint? {
        guard point.confidence > 0 else { return nil }
        return CGPoint(x: point.location.x, y: 1.0 - point.location.y)
    }

    // MARK: - Asset duration (sync)

    private func syncDurationSeconds(of asset: AVURLAsset) throws -> Double {
        var loaded: Double?
        var caught: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let duration = try await asset.load(.duration)
                loaded = duration.seconds
            } catch {
                caught = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let caught { throw caught }
        return loaded ?? 0
    }
}
