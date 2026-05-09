//
//  FeatureCacheValidator.swift
//  MotionTrainer
//
//  Slice B of the Phase 2 action-classifier pipeline. Walks a feature cache
//  produced by `MotionFeatureExtractor` (one JSONL file per source clip,
//  one `ScratchMotionFrame` JSON object per line) and produces a structured
//  report of file counts, frame counts, hand-detection coverage,
//  out-of-range coordinates, and any structural problems (empty / malformed /
//  non-monotonic / unknown-class folders).
//
//  Pure Foundation — no Vision, no AVFoundation. Cheap to call from a unit
//  test or from the CLI's `--audit-cache` mode. Out-of-range coordinates
//  are *counted*, not fixed; the `MotionWindowBuilder` clamps them at
//  window-build time per the Slice B design (preserves information for
//  downstream classifiers while avoiding tiny Vision edge-extrapolation
//  values like 1.0007).
//

import Foundation
import ScratchLabML

// MARK: - Public report

/// Result of a single cache-audit pass. All counts are `Int` and all
/// coverage values are in `[0, 1]`. Lists are sorted lexicographically so
/// reports are reproducible across runs.
public struct FeatureCacheAuditReport: Sendable, Codable, Equatable {
    public let totalFiles: Int
    public let totalFrames: Int
    public let perClassFiles: [String: Int]
    public let perClassFrames: [String: Int]
    public let perClassDominantHandCoverage: [String: Double]
    public let perClassDominantHandWristCoverage: [String: Double]
    public let perClassSecondaryHandWristCoverage: [String: Double]
    public let dominantHandCoverage: Double
    public let dominantHandWristCoverage: Double
    public let secondaryHandWristCoverage: Double
    public let outOfRangeFrameCount: Int
    public let outOfRangeFraction: Double
    public let emptyFiles: [String]
    public let malformedFiles: [String]
    public let nonMonotonicFiles: [String]
    public let unknownClassFolders: [String]
    /// Classes whose `dominantHand` coverage was below the configured
    /// minimum. Empty when the threshold is satisfied.
    public let coverageBelowThresholdClasses: [String]
    /// Classes whose `dominantHandWrist` coverage was below the configured
    /// minimum. Empty when the threshold is satisfied.
    public let wristCoverageBelowThresholdClasses: [String]
    /// Set when an `expectedFileCount` was passed and didn't match the
    /// observed count. `nil` when no expectation was provided or it was met.
    public let unexpectedFileCount: UnexpectedFileCount?
    /// Convenience flag: `true` when no structural problems were found.
    /// "Structural" excludes the (informational) out-of-range counter.
    public let isStructurallyClean: Bool
    /// Convenience flag: `true` when `isStructurallyClean` AND every
    /// configured threshold (file count, hand coverage, wrist coverage,
    /// out-of-range fraction) was satisfied.
    public let meetsAllThresholds: Bool

    public struct UnexpectedFileCount: Sendable, Codable, Equatable {
        public let expected: Int
        public let observed: Int
        public init(expected: Int, observed: Int) {
            self.expected = expected
            self.observed = observed
        }
    }

    public init(
        totalFiles: Int,
        totalFrames: Int,
        perClassFiles: [String: Int],
        perClassFrames: [String: Int],
        perClassDominantHandCoverage: [String: Double],
        perClassDominantHandWristCoverage: [String: Double],
        perClassSecondaryHandWristCoverage: [String: Double],
        dominantHandCoverage: Double,
        dominantHandWristCoverage: Double,
        secondaryHandWristCoverage: Double,
        outOfRangeFrameCount: Int,
        outOfRangeFraction: Double,
        emptyFiles: [String],
        malformedFiles: [String],
        nonMonotonicFiles: [String],
        unknownClassFolders: [String],
        coverageBelowThresholdClasses: [String],
        wristCoverageBelowThresholdClasses: [String],
        unexpectedFileCount: UnexpectedFileCount?,
        isStructurallyClean: Bool,
        meetsAllThresholds: Bool
    ) {
        self.totalFiles = totalFiles
        self.totalFrames = totalFrames
        self.perClassFiles = perClassFiles
        self.perClassFrames = perClassFrames
        self.perClassDominantHandCoverage = perClassDominantHandCoverage
        self.perClassDominantHandWristCoverage = perClassDominantHandWristCoverage
        self.perClassSecondaryHandWristCoverage = perClassSecondaryHandWristCoverage
        self.dominantHandCoverage = dominantHandCoverage
        self.dominantHandWristCoverage = dominantHandWristCoverage
        self.secondaryHandWristCoverage = secondaryHandWristCoverage
        self.outOfRangeFrameCount = outOfRangeFrameCount
        self.outOfRangeFraction = outOfRangeFraction
        self.emptyFiles = emptyFiles
        self.malformedFiles = malformedFiles
        self.nonMonotonicFiles = nonMonotonicFiles
        self.unknownClassFolders = unknownClassFolders
        self.coverageBelowThresholdClasses = coverageBelowThresholdClasses
        self.wristCoverageBelowThresholdClasses = wristCoverageBelowThresholdClasses
        self.unexpectedFileCount = unexpectedFileCount
        self.isStructurallyClean = isStructurallyClean
        self.meetsAllThresholds = meetsAllThresholds
    }
}

// MARK: - Validator

public struct FeatureCacheValidator: Sendable {

    public struct Configuration: Sendable {
        /// If non-nil, the auditor compares the observed total file count
        /// against this expectation and surfaces a mismatch in the report.
        public var expectedFileCount: Int?
        /// Lowest acceptable per-class `dominantHand` coverage in `[0, 1]`.
        /// Default 0.5 — anything lower is almost certainly a tracking
        /// failure rather than a hard scratch-occlusion edge case.
        public var minimumDominantHandCoverage: Double
        /// Lowest acceptable per-class `dominantHandWrist` coverage in
        /// `[0, 1]`. Default 0.5 (same rationale as above).
        public var minimumDominantHandWristCoverage: Double
        /// Allowed class folder names. When `nil`, the validator accepts
        /// every `ScratchClassLabel` raw value as valid; folders outside
        /// this set are reported as `unknownClassFolders`.
        public var allowedClassNames: Set<String>?
        /// Maximum tolerated fraction of frames that contain at least one
        /// out-of-range coordinate. Vision occasionally returns y just
        /// above 1.0 when a hand grazes the frame edge. Default 0.05 (5%).
        public var maximumOutOfRangeFraction: Double

        public init(
            expectedFileCount: Int? = nil,
            minimumDominantHandCoverage: Double = 0.5,
            minimumDominantHandWristCoverage: Double = 0.5,
            allowedClassNames: Set<String>? = nil,
            maximumOutOfRangeFraction: Double = 0.05
        ) {
            self.expectedFileCount = expectedFileCount
            self.minimumDominantHandCoverage = minimumDominantHandCoverage
            self.minimumDominantHandWristCoverage = minimumDominantHandWristCoverage
            self.allowedClassNames = allowedClassNames
            self.maximumOutOfRangeFraction = maximumOutOfRangeFraction
        }
    }

    public enum AuditError: Error, Equatable {
        case cacheNotFound(path: String)
        case cacheNotADirectory(path: String)
        case cacheUnreadable(path: String)
    }

    public init() {}

    /// Walk `cacheURL/<class>/*.jsonl`, parse every line, and return a
    /// structured report. The validator never throws on data-quality
    /// problems (those are reflected in the report); it only throws when
    /// the cache directory itself is missing or unreadable.
    public func audit(
        at cacheURL: URL,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) throws -> FeatureCacheAuditReport {

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: cacheURL.path, isDirectory: &isDir) else {
            throw AuditError.cacheNotFound(path: cacheURL.path)
        }
        guard isDir.boolValue else {
            throw AuditError.cacheNotADirectory(path: cacheURL.path)
        }

        let classFolders: [URL]
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            classFolders = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw AuditError.cacheUnreadable(path: cacheURL.path)
        }

        let allowed: Set<String> = configuration.allowedClassNames
            ?? Set(ScratchClassLabel.allCases.map { $0.rawValue })

        var totalFiles = 0
        var totalFrames = 0
        var perClassFiles: [String: Int] = [:]
        var perClassFrames: [String: Int] = [:]
        var perClassDomFrames: [String: Int] = [:]
        var perClassWristFrames: [String: Int] = [:]
        var perClassSecondaryFrames: [String: Int] = [:]
        var domFrames = 0
        var wristFrames = 0
        var secondaryFrames = 0
        var outOfRangeFrames = 0
        var emptyFiles: [String] = []
        var malformedFiles: [String] = []
        var nonMonotonicFiles: [String] = []
        var unknownClassFolders: [String] = []

        for folder in classFolders {
            let cls = folder.lastPathComponent
            if !allowed.contains(cls) {
                unknownClassFolders.append(cls)
                // Still walk the folder so the report's totals stay
                // consistent with what's on disk — but tagging it as
                // unknown lets the caller filter it out.
            }

            let files = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let jsonlFiles = files
                .filter { $0.pathExtension.lowercased() == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for file in jsonlFiles {
                totalFiles += 1
                perClassFiles[cls, default: 0] += 1

                let result = inspectFile(at: file)
                if result.isEmpty {
                    emptyFiles.append("\(cls)/\(file.lastPathComponent)")
                    continue
                }
                if result.isMalformed {
                    malformedFiles.append("\(cls)/\(file.lastPathComponent)")
                    continue
                }
                if result.isNonMonotonic {
                    nonMonotonicFiles.append("\(cls)/\(file.lastPathComponent)")
                }
                totalFrames += result.frameCount
                perClassFrames[cls, default: 0] += result.frameCount
                perClassDomFrames[cls, default: 0] += result.dominantHandCount
                perClassWristFrames[cls, default: 0] += result.dominantHandWristCount
                perClassSecondaryFrames[cls, default: 0] += result.secondaryHandWristCount
                domFrames += result.dominantHandCount
                wristFrames += result.dominantHandWristCount
                secondaryFrames += result.secondaryHandWristCount
                outOfRangeFrames += result.outOfRangeFrameCount
            }
        }

        // Coverage helpers. Guard against zero-frame classes to avoid
        // emitting NaN; "no frames" is reported as 0.0 coverage so the
        // threshold check correctly flags it.
        let domCoverage = totalFrames > 0 ? Double(domFrames) / Double(totalFrames) : 0
        let wristCoverage = totalFrames > 0 ? Double(wristFrames) / Double(totalFrames) : 0
        let secondaryCoverage = totalFrames > 0 ? Double(secondaryFrames) / Double(totalFrames) : 0
        let outOfRangeFraction = totalFrames > 0
            ? Double(outOfRangeFrames) / Double(totalFrames) : 0

        var perClassDomCov: [String: Double] = [:]
        var perClassWristCov: [String: Double] = [:]
        var perClassSecondaryCov: [String: Double] = [:]
        var coverageBelow: [String] = []
        var wristBelow: [String] = []
        for cls in perClassFrames.keys.sorted() {
            let frames = perClassFrames[cls] ?? 0
            let dom = perClassDomFrames[cls] ?? 0
            let wrist = perClassWristFrames[cls] ?? 0
            let sec = perClassSecondaryFrames[cls] ?? 0
            let domCov = frames > 0 ? Double(dom) / Double(frames) : 0
            let wristCov = frames > 0 ? Double(wrist) / Double(frames) : 0
            let secCov = frames > 0 ? Double(sec) / Double(frames) : 0
            perClassDomCov[cls] = domCov
            perClassWristCov[cls] = wristCov
            perClassSecondaryCov[cls] = secCov
            if domCov < configuration.minimumDominantHandCoverage {
                coverageBelow.append(cls)
            }
            if wristCov < configuration.minimumDominantHandWristCoverage {
                wristBelow.append(cls)
            }
        }

        let unexpected: FeatureCacheAuditReport.UnexpectedFileCount? = {
            guard let expected = configuration.expectedFileCount,
                  expected != totalFiles else {
                return nil
            }
            return .init(expected: expected, observed: totalFiles)
        }()

        let structurallyClean = emptyFiles.isEmpty
            && malformedFiles.isEmpty
            && nonMonotonicFiles.isEmpty
            && unknownClassFolders.isEmpty
        let meetsThresholds = structurallyClean
            && coverageBelow.isEmpty
            && wristBelow.isEmpty
            && unexpected == nil
            && outOfRangeFraction <= configuration.maximumOutOfRangeFraction

        return FeatureCacheAuditReport(
            totalFiles: totalFiles,
            totalFrames: totalFrames,
            perClassFiles: perClassFiles,
            perClassFrames: perClassFrames,
            perClassDominantHandCoverage: perClassDomCov,
            perClassDominantHandWristCoverage: perClassWristCov,
            perClassSecondaryHandWristCoverage: perClassSecondaryCov,
            dominantHandCoverage: domCoverage,
            dominantHandWristCoverage: wristCoverage,
            secondaryHandWristCoverage: secondaryCoverage,
            outOfRangeFrameCount: outOfRangeFrames,
            outOfRangeFraction: outOfRangeFraction,
            emptyFiles: emptyFiles.sorted(),
            malformedFiles: malformedFiles.sorted(),
            nonMonotonicFiles: nonMonotonicFiles.sorted(),
            unknownClassFolders: unknownClassFolders.sorted(),
            coverageBelowThresholdClasses: coverageBelow,
            wristCoverageBelowThresholdClasses: wristBelow,
            unexpectedFileCount: unexpected,
            isStructurallyClean: structurallyClean,
            meetsAllThresholds: meetsThresholds
        )
    }

    // MARK: - Per-file inspection

    private struct PerFileSummary {
        var isEmpty: Bool
        var isMalformed: Bool
        var isNonMonotonic: Bool
        var frameCount: Int
        var dominantHandCount: Int
        var dominantHandWristCount: Int
        var secondaryHandWristCount: Int
        var outOfRangeFrameCount: Int
    }

    private func inspectFile(at url: URL) -> PerFileSummary {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return PerFileSummary(
                isEmpty: true, isMalformed: false, isNonMonotonic: false,
                frameCount: 0, dominantHandCount: 0,
                dominantHandWristCount: 0, secondaryHandWristCount: 0,
                outOfRangeFrameCount: 0
            )
        }
        if text.isEmpty {
            return PerFileSummary(
                isEmpty: true, isMalformed: false, isNonMonotonic: false,
                frameCount: 0, dominantHandCount: 0,
                dominantHandWristCount: 0, secondaryHandWristCount: 0,
                outOfRangeFrameCount: 0
            )
        }

        let decoder = JSONDecoder()
        var frames = 0
        var domHand = 0
        var domWrist = 0
        var secWrist = 0
        var oor = 0
        var lastTimestamp: Double = -.infinity
        var monotonic = true
        var anyValid = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineData = Data(line.utf8)
            guard let frame = try? decoder.decode(ScratchMotionFrame.self, from: lineData) else {
                return PerFileSummary(
                    isEmpty: false, isMalformed: true, isNonMonotonic: false,
                    frameCount: 0, dominantHandCount: 0,
                    dominantHandWristCount: 0, secondaryHandWristCount: 0,
                    outOfRangeFrameCount: 0
                )
            }
            anyValid = true
            frames += 1
            if frame.timestamp + 1e-9 < lastTimestamp {
                monotonic = false
            }
            lastTimestamp = frame.timestamp

            if frame.dominantHand != nil { domHand += 1 }
            if frame.dominantHandWrist != nil { domWrist += 1 }
            if frame.secondaryHandWrist != nil { secWrist += 1 }

            if frameHasOutOfRangePoint(frame) {
                oor += 1
            }
        }

        if !anyValid {
            return PerFileSummary(
                isEmpty: true, isMalformed: false, isNonMonotonic: false,
                frameCount: 0, dominantHandCount: 0,
                dominantHandWristCount: 0, secondaryHandWristCount: 0,
                outOfRangeFrameCount: 0
            )
        }

        return PerFileSummary(
            isEmpty: false, isMalformed: false, isNonMonotonic: !monotonic,
            frameCount: frames,
            dominantHandCount: domHand,
            dominantHandWristCount: domWrist,
            secondaryHandWristCount: secWrist,
            outOfRangeFrameCount: oor
        )
    }

    private func frameHasOutOfRangePoint(_ frame: ScratchMotionFrame) -> Bool {
        let points: [CGPoint?] = [
            frame.dominantHand,
            frame.dominantHandWrist,
            frame.dominantHandIndexTip,
            frame.dominantHandThumbTip,
            frame.dominantHandMiddleTip,
            frame.secondaryHandWrist,
            frame.recordCenter,
        ]
        for case let p? in points {
            if !(0.0 <= p.x && p.x <= 1.0 && 0.0 <= p.y && p.y <= 1.0) {
                return true
            }
        }
        return false
    }
}
