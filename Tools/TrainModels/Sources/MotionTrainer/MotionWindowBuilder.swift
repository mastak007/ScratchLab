//
//  MotionWindowBuilder.swift
//  MotionTrainer
//
//  Slice B: turn per-clip JSONL feature streams into fixed-length windows
//  suitable for downstream training (Slice C: CreateML's
//  `MLActivityClassifier` or any tabular trainer). Each emitted window is
//  self-contained — class label, source-clip basename, the time range,
//  one densified feature row per frame, and per-window aggregates that
//  summarize motion energy / range / crossings.
//
//  Key design points:
//  - Coordinate clamping happens HERE, not at extraction time. Vision
//    sometimes returns y just over 1.0 at the frame edge; clamping at
//    window-build time preserves the underlying motion signal while
//    keeping the trainer's input domain to `[0, 1]`.
//  - Missing points are encoded with a `present` flag plus a sentinel
//    coordinate of 0 (JSON has no native NaN, and a separate flag is
//    cleaner than packing missingness into a coordinate). The trainer
//    can mask, impute, or carry-forward as it sees fit.
//  - Source-clip absolute paths are not written — only the basename. The
//    JSONL produced by Slice A already has this property, and the window
//    builder is a pure transform of those files.
//

import Foundation
import CoreGraphics
import ScratchLabML

// MARK: - Public types

/// One frame's worth of densified, clamped features. All point coordinates
/// are in `[0, 1]` with a top-left origin (matches the extractor); a `false`
/// `*Present` flag means Vision did not detect that landmark on that frame
/// and the corresponding `*X` / `*Y` are sentinel zeros.
public struct MotionFrameFeatures: Sendable, Codable, Equatable {
    public let timestamp: Double

    public let dominantHandX: Double
    public let dominantHandY: Double
    public let dominantHandPresent: Bool

    public let dominantHandWristX: Double
    public let dominantHandWristY: Double
    public let dominantHandWristPresent: Bool

    public let dominantHandIndexTipX: Double
    public let dominantHandIndexTipY: Double
    public let dominantHandIndexTipPresent: Bool

    public let dominantHandThumbTipX: Double
    public let dominantHandThumbTipY: Double
    public let dominantHandThumbTipPresent: Bool

    public let dominantHandMiddleTipX: Double
    public let dominantHandMiddleTipY: Double
    public let dominantHandMiddleTipPresent: Bool

    public let secondaryHandWristX: Double
    public let secondaryHandWristY: Double
    public let secondaryHandWristPresent: Bool

    public let recordCenterX: Double
    public let recordCenterY: Double
    public let recordCenterPresent: Bool

    public let dominantHandConfidence: Double
}

/// Per-window summary statistics. All distances and ROM values are in the
/// same `[0, 1]` normalized image-space units as the per-frame coordinates.
/// Velocities are normalized per second (using each frame's timestamp).
public struct MotionWindowAggregates: Sendable, Codable, Equatable {
    public let dominantWristPathLength: Double
    public let dominantHandPathLength: Double
    public let romX: Double
    public let romY: Double
    public let meanVelocity: Double
    public let maxVelocity: Double
    public let centerLineCrossings: Int
    public let dominantHandMissingRatio: Double
    public let dominantHandWristMissingRatio: Double

    public init(
        dominantWristPathLength: Double,
        dominantHandPathLength: Double,
        romX: Double,
        romY: Double,
        meanVelocity: Double,
        maxVelocity: Double,
        centerLineCrossings: Int,
        dominantHandMissingRatio: Double,
        dominantHandWristMissingRatio: Double
    ) {
        self.dominantWristPathLength = dominantWristPathLength
        self.dominantHandPathLength = dominantHandPathLength
        self.romX = romX
        self.romY = romY
        self.meanVelocity = meanVelocity
        self.maxVelocity = maxVelocity
        self.centerLineCrossings = centerLineCrossings
        self.dominantHandMissingRatio = dominantHandMissingRatio
        self.dominantHandWristMissingRatio = dominantHandWristMissingRatio
    }
}

/// One emitted window. `frames.count == frameCount`.
public struct MotionFeatureWindow: Sendable, Codable, Equatable {
    public let classLabel: String
    public let sourceFile: String
    public let windowIndex: Int
    public let startTimestamp: Double
    public let endTimestamp: Double
    public let frameCount: Int
    public let frames: [MotionFrameFeatures]
    public let aggregates: MotionWindowAggregates
}

// MARK: - Builder

public struct MotionWindowBuilder: Sendable {

    public struct Configuration: Sendable {
        /// Number of frames per window. Default 60 (≈ 2 s at 30 fps).
        public var windowFrames: Int
        /// Stride between consecutive window starts, measured in frames.
        /// Default 30 (≈ 1 s at 30 fps → 50% overlap).
        public var strideFrames: Int
        /// Minimum frame count a JSONL must contain before any windows are
        /// emitted. Default mirrors `windowFrames` (no partial windows).
        public var minimumFrameCountForBuild: Int
        /// Center-line value used for `centerLineCrossings`. Default 0.5
        /// (the image's vertical midline in normalized coordinates).
        public var centerLine: Double
        /// Sentinel value for missing point coordinates. Default 0.0; pair
        /// with the `*Present` flags to recover missingness downstream.
        public var missingCoordinateSentinel: Double

        public init(
            windowFrames: Int = 60,
            strideFrames: Int = 30,
            minimumFrameCountForBuild: Int? = nil,
            centerLine: Double = 0.5,
            missingCoordinateSentinel: Double = 0.0
        ) {
            self.windowFrames = windowFrames
            self.strideFrames = strideFrames
            self.minimumFrameCountForBuild = minimumFrameCountForBuild ?? windowFrames
            self.centerLine = centerLine
            self.missingCoordinateSentinel = missingCoordinateSentinel
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        precondition(configuration.windowFrames > 0, "windowFrames must be > 0")
        precondition(configuration.strideFrames > 0, "strideFrames must be > 0")
        self.configuration = configuration
    }

    /// Read every line of `clipURL` as a `ScratchMotionFrame` and emit
    /// `[MotionFeatureWindow]`. Coordinate clamping and missing-point
    /// sentinel substitution happen here. Frame ordering follows the
    /// JSONL line order; the cache is already monotonic per the audit.
    public func windows(
        forClipAt clipURL: URL,
        classLabel: String
    ) throws -> [MotionFeatureWindow] {
        let frames = try loadFrames(at: clipURL)
        return windowing(
            frames: frames,
            classLabel: classLabel,
            sourceFile: clipURL.lastPathComponent
        )
    }

    /// Pure-Swift entry point for tests / in-memory data. Identical
    /// semantics to `windows(forClipAt:classLabel:)` minus the file IO.
    public func windows(
        forFrames frames: [ScratchMotionFrame],
        classLabel: String,
        sourceFile: String
    ) -> [MotionFeatureWindow] {
        return windowing(
            frames: frames,
            classLabel: classLabel,
            sourceFile: sourceFile
        )
    }

    // MARK: - File IO

    private func loadFrames(at url: URL) throws -> [ScratchMotionFrame] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var frames: [ScratchMotionFrame] = []
        frames.reserveCapacity(64)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineData = Data(line.utf8)
            let frame = try decoder.decode(ScratchMotionFrame.self, from: lineData)
            frames.append(frame)
        }
        return frames
    }

    // MARK: - Window slicing

    private func windowing(
        frames: [ScratchMotionFrame],
        classLabel: String,
        sourceFile: String
    ) -> [MotionFeatureWindow] {
        guard frames.count >= configuration.minimumFrameCountForBuild else {
            return []
        }
        let densified = frames.map(densify)

        let windowFrames = configuration.windowFrames
        let stride = configuration.strideFrames
        // Number of window starts that fit entirely in the densified array.
        // Standard `floor((N - W) / S) + 1` formula, clamped to >= 0.
        let usable = densified.count - windowFrames
        let windowCount = usable < 0 ? 0 : (usable / stride) + 1
        guard windowCount > 0 else { return [] }

        var windows: [MotionFeatureWindow] = []
        windows.reserveCapacity(windowCount)
        for w in 0..<windowCount {
            let start = w * stride
            let end = start + windowFrames
            let slice = Array(densified[start..<end])
            let aggregates = computeAggregates(over: slice)
            windows.append(MotionFeatureWindow(
                classLabel: classLabel,
                sourceFile: sourceFile,
                windowIndex: w,
                startTimestamp: slice.first?.timestamp ?? 0,
                endTimestamp: slice.last?.timestamp ?? 0,
                frameCount: slice.count,
                frames: slice,
                aggregates: aggregates
            ))
        }
        return windows
    }

    // MARK: - Densification (clamp + sentinel)

    private func densify(_ frame: ScratchMotionFrame) -> MotionFrameFeatures {
        let dom = projectPoint(frame.dominantHand)
        let wrist = projectPoint(frame.dominantHandWrist)
        let index = projectPoint(frame.dominantHandIndexTip)
        let thumb = projectPoint(frame.dominantHandThumbTip)
        let middle = projectPoint(frame.dominantHandMiddleTip)
        let secWrist = projectPoint(frame.secondaryHandWrist)
        let recCenter = projectPoint(frame.recordCenter)
        return MotionFrameFeatures(
            timestamp: frame.timestamp,
            dominantHandX: dom.x,
            dominantHandY: dom.y,
            dominantHandPresent: dom.present,
            dominantHandWristX: wrist.x,
            dominantHandWristY: wrist.y,
            dominantHandWristPresent: wrist.present,
            dominantHandIndexTipX: index.x,
            dominantHandIndexTipY: index.y,
            dominantHandIndexTipPresent: index.present,
            dominantHandThumbTipX: thumb.x,
            dominantHandThumbTipY: thumb.y,
            dominantHandThumbTipPresent: thumb.present,
            dominantHandMiddleTipX: middle.x,
            dominantHandMiddleTipY: middle.y,
            dominantHandMiddleTipPresent: middle.present,
            secondaryHandWristX: secWrist.x,
            secondaryHandWristY: secWrist.y,
            secondaryHandWristPresent: secWrist.present,
            recordCenterX: recCenter.x,
            recordCenterY: recCenter.y,
            recordCenterPresent: recCenter.present,
            dominantHandConfidence: frame.dominantHandConfidence.map(Double.init) ?? 0
        )
    }

    private struct ProjectedPoint {
        let x: Double
        let y: Double
        let present: Bool
    }

    private func projectPoint(_ point: CGPoint?) -> ProjectedPoint {
        guard let p = point else {
            return ProjectedPoint(
                x: configuration.missingCoordinateSentinel,
                y: configuration.missingCoordinateSentinel,
                present: false
            )
        }
        return ProjectedPoint(
            x: clamp01(Double(p.x)),
            y: clamp01(Double(p.y)),
            present: true
        )
    }

    private func clamp01(_ v: Double) -> Double {
        if v.isNaN { return configuration.missingCoordinateSentinel }
        if v < 0 { return 0 }
        if v > 1 { return 1 }
        return v
    }

    // MARK: - Aggregates

    private func computeAggregates(over slice: [MotionFrameFeatures]) -> MotionWindowAggregates {
        guard !slice.isEmpty else {
            return MotionWindowAggregates(
                dominantWristPathLength: 0,
                dominantHandPathLength: 0,
                romX: 0, romY: 0,
                meanVelocity: 0, maxVelocity: 0,
                centerLineCrossings: 0,
                dominantHandMissingRatio: 1,
                dominantHandWristMissingRatio: 1
            )
        }

        var wristPath: Double = 0
        var handPath: Double = 0
        var prevWrist: (x: Double, y: Double)?
        var prevHand: (x: Double, y: Double, t: Double)?

        var minHandX: Double = .infinity
        var maxHandX: Double = -.infinity
        var minHandY: Double = .infinity
        var maxHandY: Double = -.infinity
        var sumVelocity: Double = 0
        var velocitySamples: Int = 0
        var maxVelocity: Double = 0

        var crossings: Int = 0
        var prevSide: Int? = nil  // -1 = left of center, +1 = right
        var domMissing: Int = 0
        var wristMissing: Int = 0

        for f in slice {
            if !f.dominantHandPresent { domMissing += 1 }
            if !f.dominantHandWristPresent { wristMissing += 1 }

            // Wrist path length
            if f.dominantHandWristPresent {
                if let p = prevWrist {
                    wristPath += hypot(f.dominantHandWristX - p.x,
                                       f.dominantHandWristY - p.y)
                }
                prevWrist = (f.dominantHandWristX, f.dominantHandWristY)
            } else {
                prevWrist = nil  // gap → don't fabricate distance across it
            }

            // Hand path length, ROM, velocity, crossings — all anchored
            // on the dominant hand point.
            if f.dominantHandPresent {
                let x = f.dominantHandX
                let y = f.dominantHandY
                minHandX = min(minHandX, x)
                maxHandX = max(maxHandX, x)
                minHandY = min(minHandY, y)
                maxHandY = max(maxHandY, y)
                if let p = prevHand {
                    let dx = x - p.x
                    let dy = y - p.y
                    let dist = hypot(dx, dy)
                    handPath += dist
                    let dt = f.timestamp - p.t
                    if dt > 0 {
                        let v = dist / dt
                        sumVelocity += v
                        maxVelocity = max(maxVelocity, v)
                        velocitySamples += 1
                    }
                }
                prevHand = (x, y, f.timestamp)
                let side = x < configuration.centerLine ? -1 : 1
                if let prev = prevSide, prev != side {
                    crossings += 1
                }
                prevSide = side
            } else {
                // Reset side tracking across gaps so we don't count a
                // resume-after-occlusion as a crossing.
                prevHand = nil
                prevSide = nil
            }
        }

        let romX = (maxHandX > -.infinity && minHandX < .infinity) ? (maxHandX - minHandX) : 0
        let romY = (maxHandY > -.infinity && minHandY < .infinity) ? (maxHandY - minHandY) : 0
        let meanVel = velocitySamples > 0 ? sumVelocity / Double(velocitySamples) : 0
        let domMissingRatio = Double(domMissing) / Double(slice.count)
        let wristMissingRatio = Double(wristMissing) / Double(slice.count)

        return MotionWindowAggregates(
            dominantWristPathLength: wristPath,
            dominantHandPathLength: handPath,
            romX: romX,
            romY: romY,
            meanVelocity: meanVel,
            maxVelocity: maxVelocity,
            centerLineCrossings: crossings,
            dominantHandMissingRatio: domMissingRatio,
            dominantHandWristMissingRatio: wristMissingRatio
        )
    }
}
