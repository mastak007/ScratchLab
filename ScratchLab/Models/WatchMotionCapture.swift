import Foundation

enum WatchMotionCaptureCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct WatchMotionCaptureSession: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: String
    let takeID: String?
    let commandID: String?
    let requestedAt: Date
    let acknowledgedAt: Date?
    let syncState: CaptureWatchSyncState?
    let sourceDeviceName: String
    let sampleRateHz: Double
    let startedAt: Date
    let endedAt: Date
    let deviceRecordedAtStart: Date
    let deviceRecordedAtEnd: Date?
    let appVersion: String
    let timingMetadata: WatchMotionTimingMetadata?
    let samples: [WatchMotionSample]

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case takeID
        case commandID
        case requestedAt
        case acknowledgedAt
        case syncState
        case sourceDeviceName
        case sampleRateHz
        case startedAt
        case endedAt
        case deviceRecordedAtStart
        case deviceRecordedAtEnd
        case appVersion
        case timingMetadata
        case samples
    }

    init(
        id: UUID = UUID(),
        sessionID: String,
        takeID: String?,
        commandID: String?,
        requestedAt: Date,
        acknowledgedAt: Date?,
        syncState: CaptureWatchSyncState?,
        sourceDeviceName: String,
        sampleRateHz: Double,
        startedAt: Date,
        endedAt: Date,
        deviceRecordedAtStart: Date,
        deviceRecordedAtEnd: Date?,
        appVersion: String,
        timingMetadata: WatchMotionTimingMetadata?,
        samples: [WatchMotionSample]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.takeID = takeID
        self.commandID = commandID
        self.requestedAt = requestedAt
        self.acknowledgedAt = acknowledgedAt
        self.syncState = syncState
        self.sourceDeviceName = sourceDeviceName
        self.sampleRateHz = sampleRateHz
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deviceRecordedAtStart = deviceRecordedAtStart
        self.deviceRecordedAtEnd = deviceRecordedAtEnd
        self.appVersion = appVersion
        self.timingMetadata = timingMetadata
        self.samples = samples
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        takeID = try container.decodeIfPresent(String.self, forKey: .takeID)
        commandID = try container.decodeIfPresent(String.self, forKey: .commandID)
        let decodedStartedAt = try container.decode(Date.self, forKey: .startedAt)
        let decodedEndedAt = try container.decode(Date.self, forKey: .endedAt)
        requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt) ?? decodedStartedAt
        acknowledgedAt = try container.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        syncState = try container.decodeIfPresent(CaptureWatchSyncState.self, forKey: .syncState)
        sourceDeviceName = try container.decode(String.self, forKey: .sourceDeviceName)
        sampleRateHz = try container.decode(Double.self, forKey: .sampleRateHz)
        startedAt = decodedStartedAt
        endedAt = decodedEndedAt
        deviceRecordedAtStart = try container.decodeIfPresent(Date.self, forKey: .deviceRecordedAtStart) ?? decodedStartedAt
        deviceRecordedAtEnd = try container.decodeIfPresent(Date.self, forKey: .deviceRecordedAtEnd) ?? decodedEndedAt
        appVersion = try container.decode(String.self, forKey: .appVersion)
        timingMetadata = try container.decodeIfPresent(WatchMotionTimingMetadata.self, forKey: .timingMetadata)
        samples = try container.decode([WatchMotionSample].self, forKey: .samples)
    }

    var wallClockDuration: TimeInterval {
        max(endedAt.timeIntervalSince(startedAt), 0)
    }

    var duration: TimeInterval {
        timingMetadata?.sensorDuration ?? wallClockDuration
    }

    var sampleCount: Int {
        samples.count
    }
}

struct WatchMotionTimingMetadata: Codable, Equatable, Sendable {
    let clockSource: String
    let firstCoreMotionTimestamp: TimeInterval
    let lastCoreMotionTimestamp: TimeInterval
    let sensorDuration: TimeInterval
    let requestedSampleInterval: TimeInterval
    let averageSampleInterval: TimeInterval
    let minimumSampleInterval: TimeInterval
    let maximumSampleInterval: TimeInterval
    let sampleIntervalStandardDeviation: TimeInterval
    let maximumAbsoluteJitter: TimeInterval
    let estimatedDroppedSamples: Int
    let nonPositiveIntervalCount: Int
    let wallClockDuration: TimeInterval
    let wallClockMinusSensorDuration: TimeInterval

    static func make(
        from samples: [WatchMotionSample],
        requestedSampleInterval: TimeInterval,
        wallClockDuration: TimeInterval
    ) -> WatchMotionTimingMetadata? {
        let timestamps = samples.compactMap(\.coreMotionTimestamp)
        guard let firstTimestamp = timestamps.first, let lastTimestamp = timestamps.last else {
            return nil
        }

        var intervalCount = 0
        var intervalSum: TimeInterval = 0
        var intervalSumSquares: TimeInterval = 0
        var minimumInterval = TimeInterval.greatestFiniteMagnitude
        var maximumInterval: TimeInterval = 0
        var maximumAbsoluteJitter: TimeInterval = 0
        var estimatedDroppedSamples = 0
        var nonPositiveIntervalCount = 0

        for (previousTimestamp, currentTimestamp) in zip(timestamps, timestamps.dropFirst()) {
            let interval = currentTimestamp - previousTimestamp
            if interval <= 0 {
                nonPositiveIntervalCount += 1
                continue
            }

            intervalCount += 1
            intervalSum += interval
            intervalSumSquares += interval * interval
            minimumInterval = min(minimumInterval, interval)
            maximumInterval = max(maximumInterval, interval)
            maximumAbsoluteJitter = max(maximumAbsoluteJitter, abs(interval - requestedSampleInterval))

            if requestedSampleInterval > 0 {
                let observedStepCount = Int(floor(interval / requestedSampleInterval))
                if observedStepCount > 1 {
                    estimatedDroppedSamples += observedStepCount - 1
                }
            }
        }

        let sensorDuration = max(lastTimestamp - firstTimestamp, 0)
        let averageSampleInterval = intervalCount > 0 ? intervalSum / Double(intervalCount) : requestedSampleInterval
        let meanSquare = intervalCount > 0 ? intervalSumSquares / Double(intervalCount) : 0
        let variance = max(meanSquare - (averageSampleInterval * averageSampleInterval), 0)

        return WatchMotionTimingMetadata(
            clockSource: "core_motion_timestamp",
            firstCoreMotionTimestamp: firstTimestamp,
            lastCoreMotionTimestamp: lastTimestamp,
            sensorDuration: sensorDuration,
            requestedSampleInterval: requestedSampleInterval,
            averageSampleInterval: averageSampleInterval,
            minimumSampleInterval: intervalCount > 0 ? minimumInterval : requestedSampleInterval,
            maximumSampleInterval: intervalCount > 0 ? maximumInterval : requestedSampleInterval,
            sampleIntervalStandardDeviation: sqrt(variance),
            maximumAbsoluteJitter: maximumAbsoluteJitter,
            estimatedDroppedSamples: estimatedDroppedSamples,
            nonPositiveIntervalCount: nonPositiveIntervalCount,
            wallClockDuration: wallClockDuration,
            wallClockMinusSensorDuration: wallClockDuration - sensorDuration
        )
    }
}

struct WatchMotionSample: Codable, Equatable, Sendable {
    let elapsedTime: TimeInterval
    let coreMotionTimestamp: TimeInterval?
    let attitudeRoll: Double
    let attitudePitch: Double
    let attitudeYaw: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let quaternionW: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double

    init(
        elapsedTime: TimeInterval,
        coreMotionTimestamp: TimeInterval? = nil,
        attitudeRoll: Double,
        attitudePitch: Double,
        attitudeYaw: Double,
        quaternionX: Double,
        quaternionY: Double,
        quaternionZ: Double,
        quaternionW: Double,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        userAccelerationX: Double,
        userAccelerationY: Double,
        userAccelerationZ: Double,
        rotationRateX: Double,
        rotationRateY: Double,
        rotationRateZ: Double
    ) {
        self.elapsedTime = elapsedTime
        self.coreMotionTimestamp = coreMotionTimestamp
        self.attitudeRoll = attitudeRoll
        self.attitudePitch = attitudePitch
        self.attitudeYaw = attitudeYaw
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.quaternionW = quaternionW
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
    }
}

struct WatchMotionRelayBatch: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_batch_v1"

    let kind: String
    let captureID: UUID
    let context: WatchRelayTakeContext
    let commandID: String
    let requestedAt: Date
    let acknowledgedAt: Date?
    let sourceDeviceName: String
    let appVersion: String
    let sampleRateHz: Double
    let startedAt: Date
    let capturedAt: Date
    let endedAt: Date?
    let sequence: Int
    let isFinal: Bool
    let samples: [WatchMotionSample]

    init(
        captureID: UUID,
        context: WatchRelayTakeContext,
        commandID: String,
        requestedAt: Date,
        acknowledgedAt: Date?,
        sourceDeviceName: String,
        appVersion: String,
        sampleRateHz: Double,
        startedAt: Date,
        capturedAt: Date = Date(),
        endedAt: Date? = nil,
        sequence: Int,
        isFinal: Bool,
        samples: [WatchMotionSample]
    ) {
        self.kind = Self.packetKind
        self.captureID = captureID
        self.context = context
        self.commandID = commandID
        self.requestedAt = requestedAt
        self.acknowledgedAt = acknowledgedAt
        self.sourceDeviceName = sourceDeviceName
        self.appVersion = appVersion
        self.sampleRateHz = sampleRateHz
        self.startedAt = startedAt
        self.capturedAt = capturedAt
        self.endedAt = endedAt
        self.sequence = sequence
        self.isFinal = isFinal
        self.samples = samples
    }
}

struct WatchMotionRelayAcknowledgement: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_batch_ack_v1"

    let kind: String
    let captureID: UUID
    let sequence: Int
    let accepted: Bool

    init(batch: WatchMotionRelayBatch, accepted: Bool) {
        self.kind = Self.packetKind
        self.captureID = batch.captureID
        self.sequence = batch.sequence
        self.accepted = accepted
    }

    func accepts(_ batch: WatchMotionRelayBatch) -> Bool {
        kind == Self.packetKind
            && accepted
            && captureID == batch.captureID
            && sequence == batch.sequence
    }
}

struct WatchMotionRelayAssembler {
    enum Rejection: Equatable {
        case invalidPacket
        case unauthorizedContext
        case captureIdentityChanged
        case duplicateSequence
    }

    enum IngestResult: Equatable {
        case accepted
        case rejected(Rejection)
        case completed(WatchMotionCaptureSession)
    }

    private var captureID: UUID?
    private var batches: [Int: WatchMotionRelayBatch] = [:]
    private var finalSequence: Int?

    mutating func reset() {
        captureID = nil
        batches.removeAll(keepingCapacity: true)
        finalSequence = nil
    }

    mutating func ingest(
        _ batch: WatchMotionRelayBatch,
        accepting authorizedContext: WatchRelayTakeContext
    ) -> IngestResult {
        guard batch.kind == WatchMotionRelayBatch.packetKind, batch.sequence >= 0 else {
            return .rejected(.invalidPacket)
        }
        guard batch.context == authorizedContext else {
            return .rejected(.unauthorizedContext)
        }
        if let captureID, captureID != batch.captureID {
            return .rejected(.captureIdentityChanged)
        }
        guard batches[batch.sequence] == nil else {
            return .rejected(.duplicateSequence)
        }

        captureID = batch.captureID
        batches[batch.sequence] = batch
        if batch.isFinal {
            finalSequence = batch.sequence
        }

        guard let finalSequence,
              let firstBatch = batches[0],
              let finalBatch = batches[finalSequence],
              (0...finalSequence).allSatisfy({ batches[$0] != nil }) else {
            return .accepted
        }

        let samples = (0...finalSequence).flatMap { batches[$0]?.samples ?? [] }
        let endedAt = finalBatch.endedAt ?? finalBatch.capturedAt
        let wallClockDuration = max(endedAt.timeIntervalSince(firstBatch.startedAt), 0)
        let requestedSampleInterval = firstBatch.sampleRateHz > 0 ? 1.0 / firstBatch.sampleRateHz : 0
        let timingMetadata = WatchMotionTimingMetadata.make(
            from: samples,
            requestedSampleInterval: requestedSampleInterval,
            wallClockDuration: wallClockDuration
        )
        let session = WatchMotionCaptureSession(
            id: batch.captureID,
            sessionID: authorizedContext.sessionID,
            takeID: authorizedContext.takeID,
            commandID: firstBatch.commandID,
            requestedAt: firstBatch.requestedAt,
            acknowledgedAt: firstBatch.acknowledgedAt,
            syncState: .acknowledged,
            sourceDeviceName: firstBatch.sourceDeviceName,
            sampleRateHz: firstBatch.sampleRateHz,
            startedAt: firstBatch.startedAt,
            endedAt: endedAt,
            deviceRecordedAtStart: firstBatch.startedAt,
            deviceRecordedAtEnd: endedAt,
            appVersion: firstBatch.appVersion,
            timingMetadata: timingMetadata,
            samples: samples
        )
        return .completed(session)
    }
}
