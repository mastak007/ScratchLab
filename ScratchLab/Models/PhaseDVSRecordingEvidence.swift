import Foundation

/// Evidence for the explicitly selected Phase B / DJM-S9 RCA route. Control
/// audio is retained separately from programme audio. No absolute position or
/// revolution calibration is claimed by this format.
struct PhaseDVSRecordingEvidence: Codable, Equatable, Sendable {
    static let source = "phase_dvs_s9"
    static let coordinateReference = "Phase DVS accepted control-tone displacement, normalised within this take; operator-confirmed polarity; no revolution calibration"
    static let minimumConfidence = 0.75

    struct Polarity: Codable, Equatable, Sendable {
        let deviceUID: String
        let connectionID: UUID
        let decoderForwardSign: Int
        let confirmedAt: Date
        let acceptedBufferCount: Int

        var isValid: Bool {
            !deviceUID.isEmpty && (decoderForwardSign == 1 || decoderForwardSign == -1) && acceptedBufferCount >= 20
        }
    }

    struct Block: Codable, Equatable, Sendable {
        /// Sample-clock bounds anchored to the first callback host timestamp.
        /// The original per-callback host timestamp is retained separately.
        let start: Double
        let duration: Double
        let rawFrameOffset: Int
        let frameCount: Int
        let sampleTime: Double
        let hostTime: UInt64
        let confidence: Double
        /// Decoder-convention displacement; nil means rejected/unknown.
        let delta: Double?
        let rejection: String?
    }

    let version: Int
    let sessionID: String
    let takeID: String
    let deviceUID: String
    let connectionID: UUID
    let sampleRate: Double
    let controlChannels: [Int]
    let programmeChannels: [Int]
    let rawControlFileName: String
    let rawControlSHA256: String
    let rawFrameCount: Int
    let mediaDuration: Double
    let mediaStartHostSeconds: Double
    let firstAudioHostSeconds: Double
    let polarity: Polarity
    let blocks: [Block]

    enum ValidationError: LocalizedError {
        case invalidEvidence
        var errorDescription: String? {
            "The Phase control signal, source identity or clock record is incomplete. Original source files are retained."
        }
    }

    func validate() throws {
        guard version == 1, !sessionID.isEmpty, !takeID.isEmpty,
              sampleRate == 48_000, controlChannels == [3, 4], programmeChannels == [5, 6],
              !deviceUID.isEmpty, polarity.isValid, polarity.deviceUID == deviceUID,
              polarity.connectionID == connectionID,
              rawControlFileName == URL(fileURLWithPath: rawControlFileName).lastPathComponent,
              !rawControlFileName.isEmpty, rawControlFileName.hasSuffix(".wav"),
              rawControlSHA256.count == 64, rawControlSHA256.allSatisfy({ $0.isHexDigit }),
              rawFrameCount > 0, rawFrameCount <= 195 * 48_000, mediaDuration.isFinite, mediaDuration > 0,
              mediaStartHostSeconds.isFinite, firstAudioHostSeconds.isFinite,
              mediaStartHostSeconds >= 0, firstAudioHostSeconds >= 0,
              mediaDuration <= 180, !blocks.isEmpty, blocks.count <= 40_000 else {
            throw ValidationError.invalidEvidence
        }
        var nextOffset = 0
        var previous: Block?
        for block in blocks {
            guard block.start.isFinite, block.duration.isFinite, block.duration > 0,
                  block.frameCount > 0, block.frameCount <= 8192,
                  abs(block.duration - Double(block.frameCount) / sampleRate) < 1e-9,
                  block.rawFrameOffset == nextOffset,
                  block.sampleTime.isFinite, block.hostTime > 0,
                  block.confidence.isFinite, (0...1).contains(block.confidence),
                  block.delta == nil || (block.delta!.isFinite && block.delta != 0
                    && abs(block.delta!) <= 20 * block.duration + 1e-9
                    && block.confidence >= Self.minimumConfidence && block.rejection == nil),
                  block.delta != nil || block.rejection != nil else {
                throw ValidationError.invalidEvidence
            }
            if let previous {
                // Discontinuities fail the take; they cannot be silently joined
                // into a programme WAV or hidden by sorting the evidence.
                guard block.sampleTime == previous.sampleTime + Double(previous.frameCount),
                      block.hostTime > previous.hostTime,
                      abs(block.start - (blocks[0].start + Double(block.rawFrameOffset) / sampleRate)) < 1e-7 else {
                    throw ValidationError.invalidEvidence
                }
            }
            nextOffset += block.frameCount
            previous = block
        }
        guard nextOffset == rawFrameCount, blocks[0].start <= 0,
              abs(blocks[0].start - (firstAudioHostSeconds - mediaStartHostSeconds)) < 1e-7,
              blocks.last!.start + blocks.last!.duration >= mediaDuration - 1 / sampleRate else {
            throw ValidationError.invalidEvidence
        }
    }

    var coordinates: CaptureCore.PlatterNotationCoordinates {
        .normalizedTakeLocal(reference: Self.coordinateReference)
    }

    /// Derives only contiguous, confident travel. A rejected callback breaks
    /// the path. Silence never becomes a hold, and no lost travel is bridged.
    func motionEvidence() throws -> CaptureCore.PlatterMotionEvidence {
        try validate()
        return Self.project(blocks: blocks, duration: mediaDuration, forwardSign: polarity.decoderForwardSign)
    }

    /// In-memory preview uses the same projection as finalized evidence. It
    /// cannot be exported without the recording identity, raw WAV and checks.
    static func project(blocks: [Block], duration mediaDuration: Double, forwardSign: Int) -> CaptureCore.PlatterMotionEvidence {
        guard mediaDuration.isFinite, mediaDuration > 0, (forwardSign == 1 || forwardSign == -1) else {
            return .init(events: [], intervals: [], trajectorySegments: [])
        }
        struct Run {
            var points: [CaptureCore.PlatterTrajectorySample]
            var confidence: Double
            let sign: Int
        }
        var runs: [Run] = []
        var active: Run?
        var intervals: [CaptureCore.PlatterEvidenceInterval] = []
        var cursor = 0.0
        func close() {
            if let run = active { runs.append(run) }
            active = nil
        }
        for block in blocks {
            let start = max(0, block.start)
            let end = min(mediaDuration, block.start + block.duration)
            guard end > start else { continue }
            guard let delta = block.delta else {
                close()
                intervals.append(.init(startTime: start, endTime: end, kind: .unknown))
                continue
            }
            let displacement = delta * Double(forwardSign) * (end - start) / block.duration
            let sign = displacement > 0 ? 1 : -1
            if active?.sign != sign { close() }
            if active == nil {
                active = Run(points: [.init(takeRelativeTime: start, displacementSteps: cursor)],
                             confidence: block.confidence, sign: sign)
            }
            cursor += displacement
            active!.points.append(.init(takeRelativeTime: end, displacementSteps: cursor))
            active!.confidence = min(active!.confidence, block.confidence)
        }
        close()
        let positions = runs.flatMap { $0.points.map(\.displacementSteps) }
        let low = positions.min() ?? 0, span = (positions.max() ?? 0) - low
        guard span > 0, span.isFinite else {
            return .init(events: [], intervals: [.init(startTime: 0, endTime: mediaDuration, kind: .unknown)], trajectorySegments: [])
        }
        var events: [CaptureCore.DetectedNotationRecordMovementEvent] = []
        var trajectories: [CaptureCore.PlatterTrajectorySegment] = []
        for run in runs {
            let first = run.points.first!, last = run.points.last!
            let duration = last.takeRelativeTime - first.takeRelativeTime
            guard duration >= 0.08 else {
                intervals.append(.init(startTime: first.takeRelativeTime, endTime: last.takeRelativeTime, kind: .discardedMotion))
                continue
            }
            let start = (first.displacementSteps - low) / span
            let end = (last.displacementSteps - low) / span
            events.append(.init(startTime: first.takeRelativeTime, endTime: last.takeRelativeTime,
                startPosition: start, endPosition: end, direction: run.sign > 0 ? "forward" : "backward",
                // Existing DVS vocabulary: .hold means unclassified travel here,
                // not an observed stationary interval or a touch measurement.
                movementKind: .hold, speed: abs(end - start) / duration,
                confidence: run.confidence, source: Self.source))
            trajectories.append(.init(boundaryBefore: .unknown, samples: run.points.map {
                .init(takeRelativeTime: $0.takeRelativeTime, displacementSteps: ($0.displacementSteps - low) / span)
            }))
        }
        return .init(events: events, intervals: intervals.sorted { $0.startTime < $1.startTime }, trajectorySegments: trajectories)
    }
}
