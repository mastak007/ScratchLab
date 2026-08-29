import Foundation

enum CaptureCanonicalRules {
    static let scratchTypeID = "baby_scratch"
    static let scratchTypeName = "baby"
    static let allowedBPMs: Set<Int> = [70, 90, 110]
    static let minimumWatchSampleCount = 10
    static let specVersion = "capture_spec_v1"
    static let allowedBPMList = [70, 90, 110]
    static let segmentCount = 3

    static let watchCSVHeader = [
        "elapsed_time",
        "core_motion_timestamp",
        "attitude_roll",
        "attitude_pitch",
        "attitude_yaw",
        "quaternion_x",
        "quaternion_y",
        "quaternion_z",
        "quaternion_w",
        "gravity_x",
        "gravity_y",
        "gravity_z",
        "user_accel_x",
        "user_accel_y",
        "user_accel_z",
        "rotation_rate_x",
        "rotation_rate_y",
        "rotation_rate_z"
    ]

    static let takeLogColumns = [
        "bpm",
        "take_number",
        "raw_camA",
        "raw_camB",
        "raw_audio",
        "raw_watch",
        "verbal_slate_used",
        "sync_clap_used",
        "notes"
    ]
}

enum SessionIdentity {
    static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}

struct TakeIdentity: Codable, Equatable, Sendable {
    let sessionID: String
    let takeID: String
    let takeNumber: Int
}

enum CaptureWatchSyncState: String, Codable, Equatable, Sendable {
    case notRequested
    case requested
    case acknowledged
    case timedOut
    case unavailable
    case failed

    var isSynchronized: Bool {
        self == .acknowledged
    }
}

struct CaptureAuditEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let detail: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.detail = detail
    }
}

struct WatchCaptureCommandPayload: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_control_command_v2"

    enum Command: String, Codable, Equatable, Sendable {
        case start
        case stop
    }

    let kind: String
    let commandID: String
    let command: Command
    let sessionID: String
    let takeID: String?
    let requestedAt: Date

    init(
        commandID: String = UUID().uuidString.lowercased(),
        command: Command,
        sessionID: String,
        takeID: String?,
        requestedAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.command = command
        self.sessionID = sessionID
        self.takeID = takeID
        self.requestedAt = requestedAt
    }
}

/// A control request initiated on Apple Watch for the paired iPhone's guided
/// capture state machine. This is intentionally distinct from
/// `WatchCaptureCommandPayload`, which travels in the opposite direction to
/// start/stop the watch motion recorder after iPhone capture is ready.
struct PhoneCaptureCommandPayload: Codable, Equatable, Sendable {
    static let packetKind = "phone_capture_control_command_v1"

    enum Command: String, Codable, Equatable, Sendable {
        case start
        case stop
    }

    let kind: String
    let commandID: String
    let command: Command
    let requestedAt: Date

    init(
        commandID: String = UUID().uuidString.lowercased(),
        command: Command,
        requestedAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.command = command
        self.requestedAt = requestedAt
    }
}

struct WatchCaptureControlReply: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_control_status_v2"

    let kind: String
    let commandID: String
    let sessionID: String
    let takeID: String?
    let syncState: CaptureWatchSyncState
    let detail: String?
    let acknowledgedAt: Date?

    init(
        commandID: String,
        sessionID: String,
        takeID: String?,
        syncState: CaptureWatchSyncState,
        detail: String?,
        acknowledgedAt: Date? = nil
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.sessionID = sessionID
        self.takeID = takeID
        self.syncState = syncState
        self.detail = detail
        self.acknowledgedAt = acknowledgedAt
    }
}

enum WatchAssociationResolver {
    static func isLinkedCaptureValid(
        sessionID: String,
        takeID: String,
        captureSession: WatchMotionCaptureSession
    ) -> Bool {
        guard captureSession.sessionID == sessionID else { return false }
        guard captureSession.takeID == takeID else { return false }
        guard captureSession.sampleCount >= CaptureCanonicalRules.minimumWatchSampleCount else { return false }
        guard captureSession.deviceRecordedAtEnd != nil else { return false }
        return captureSession.duration > 0
    }
}

enum CaptureCanonicalFormatting {
    static func sanitizeDJToken(_ performerName: String) -> String? {
        let filtered = performerName
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .uppercased()
        return filtered.isEmpty ? nil : filtered
    }

    static func sessionDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func bpmToken(_ bpm: Int) -> String {
        String(format: "%03d", bpm)
    }

    static func takeNumberToken(_ takeNumber: Int) -> String {
        String(format: "%02d", takeNumber)
    }

    static func exportScratchTypeToken(
        scratchTypeID: String?,
        scratchTypeName: String?,
        workflow: String
    ) -> String? {
        switch workflow {
        case "routine_capture", "guided_capture":
            if let scratchTypeID,
               let normalized = normalizedScratchTypeToken(from: scratchTypeID) {
                return normalized
            }
            if let scratchTypeName,
               let normalized = normalizedScratchTypeToken(from: scratchTypeName) {
                return normalized
            }
            return nil
        default:
            return CaptureCanonicalRules.scratchTypeName
        }
    }

    static func standardFileName(
        djToken: String,
        scratchTypeToken: String,
        bpm: Int,
        takeNumber: Int,
        source: String,
        fileExtension: String
    ) -> String {
        "\(djToken)_\(scratchTypeToken)_\(bpmToken(bpm))_take\(takeNumberToken(takeNumber))_\(source).\(fileExtension)"
    }

    private static func normalizedScratchTypeToken(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let separatorNormalized = trimmed
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let suffixTrimmed: String
        if separatorNormalized.hasSuffix("_scratch") {
            suffixTrimmed = String(separatorNormalized.dropLast("_scratch".count))
        } else {
            suffixTrimmed = separatorNormalized
        }
        let filtered = suffixTrimmed.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return filtered.isEmpty ? nil : filtered
    }

    static func watchCSV(for session: WatchMotionCaptureSession) -> String {
        let rows = session.samples.map { sample in
            let columns: [String] = [
                String(sample.elapsedTime),
                sample.coreMotionTimestamp.map { String($0) } ?? "",
                String(sample.attitudeRoll),
                String(sample.attitudePitch),
                String(sample.attitudeYaw),
                String(sample.quaternionX),
                String(sample.quaternionY),
                String(sample.quaternionZ),
                String(sample.quaternionW),
                String(sample.gravityX),
                String(sample.gravityY),
                String(sample.gravityZ),
                String(sample.userAccelerationX),
                String(sample.userAccelerationY),
                String(sample.userAccelerationZ),
                String(sample.rotationRateX),
                String(sample.rotationRateY),
                String(sample.rotationRateZ)
            ]
            return columns.joined(separator: ",")
        }

        return ([CaptureCanonicalRules.watchCSVHeader.joined(separator: ",")] + rows).joined(separator: "\n")
    }
}

final class WatchCaptureCommandCoordinator: @unchecked Sendable {
    private struct PendingCommand {
        let command: WatchCaptureCommandPayload
        let continuation: CheckedContinuation<WatchCaptureControlReply, Never>
    }

    private let stateLock = NSLock()
    private var pendingCommands: [String: PendingCommand] = [:]
    private var finalizedReplies: [String: WatchCaptureControlReply] = [:]

    func begin(command: WatchCaptureCommandPayload) async -> WatchCaptureControlReply {
        if let finalized = finalizedReply(for: command.commandID) {
            return finalized
        }

        return await withCheckedContinuation { continuation in
            stateLock.lock()
            if let finalized = finalizedReplies[command.commandID] {
                stateLock.unlock()
                continuation.resume(returning: finalized)
                return
            }

            pendingCommands[command.commandID] = PendingCommand(
                command: command,
                continuation: continuation
            )
            stateLock.unlock()
        }
    }

    func resolve(_ reply: WatchCaptureControlReply) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let finalized = finalizedReplies[reply.commandID] {
            if finalized.syncState == .timedOut && reply.syncState == .acknowledged {
                return WatchCaptureControlReply(
                    commandID: reply.commandID,
                    sessionID: reply.sessionID,
                    takeID: reply.takeID,
                    syncState: .timedOut,
                    detail: "Watch acknowledged too late; take remains degraded.",
                    acknowledgedAt: finalized.acknowledgedAt
                )
            }
            return nil
        }

        guard let pending = pendingCommands.removeValue(forKey: reply.commandID) else {
            finalizedReplies[reply.commandID] = reply
            return reply
        }

        finalizedReplies[reply.commandID] = reply
        pending.continuation.resume(returning: reply)
        return reply
    }

    func timeout(commandID: String) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let finalized = finalizedReplies[commandID] {
            return finalized
        }

        guard let pending = pendingCommands.removeValue(forKey: commandID) else {
            return finalizedReplies[commandID]
        }

        let timeoutReply = WatchCaptureControlReply(
            commandID: pending.command.commandID,
            sessionID: pending.command.sessionID,
            takeID: pending.command.takeID,
            syncState: .timedOut,
            detail: "Watch motion start timed out.",
            acknowledgedAt: nil
        )
        finalizedReplies[commandID] = timeoutReply
        pending.continuation.resume(returning: timeoutReply)
        return timeoutReply
    }

    func finalizedReply(for commandID: String) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finalizedReplies[commandID]
    }
}

// MARK: - Multichannel capture: program-pair selection & signal probe
//
// A Rane ONE MKII exposes ~14 CoreAudio channels, but ScratchLab must record
// exactly ONE explicitly-selected stereo program (master) pair — never the
// whole device. These pure, hardware-free types back:
//   * the Rane channel-map diagnostic (identify which pair carries program audio),
//   * per-device persistence of the resolved pair, and
//   * (Stage B) the canonical-stereo capture-health gate.
// Thresholds intentionally mirror `TimecodeSignalDiagnostics` so the capture
// path and the timecode path agree on what "silent" / "clipping" mean.

/// An explicitly-selected stereo program channel pair, as zero-based indices
/// into a capture device's interleaved channel order.
struct CaptureAudioProgramPair: Equatable, Codable, Sendable {
    let leftChannel: Int
    let rightChannel: Int

    init?(leftChannel: Int, rightChannel: Int) {
        guard leftChannel >= 0, rightChannel >= 0, leftChannel != rightChannel else { return nil }
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
    }

    /// The common adjacent ascending pair (`startChannel`, `startChannel + 1`).
    init?(startChannel: Int) {
        self.init(leftChannel: startChannel, rightChannel: startChannel + 1)
    }

    /// Human, 1-based label, e.g. `"1/2"`.
    var label: String { "\(leftChannel + 1)/\(rightChannel + 1)" }

    var maxChannelIndex: Int { max(leftChannel, rightChannel) }

    /// True when both channels exist in a stream carrying `channelCount` channels.
    func isResolvable(inChannelCount channelCount: Int) -> Bool {
        leftChannel >= 0 && rightChannel >= 0 && maxChannelIndex < channelCount
    }
}

/// Per-audio-device persistence of the resolved program pair, keyed by the
/// AVFoundation/CoreAudio device unique ID so each interface keeps its own
/// mapping. Ordinary 2-channel interfaces need no entry — absence resolves to
/// channels 0/1 at the call site.
enum CaptureAudioProgramPairStore {
    static let defaultsKeyPrefix = "scratchlab.capture.programPair."

    static func key(forDeviceUniqueID uid: String) -> String { defaultsKeyPrefix + uid }

    static func pair(
        forDeviceUniqueID uid: String,
        defaults: UserDefaults = .standard
    ) -> CaptureAudioProgramPair? {
        guard !uid.isEmpty, let data = defaults.data(forKey: key(forDeviceUniqueID: uid)) else { return nil }
        return try? JSONDecoder().decode(CaptureAudioProgramPair.self, from: data)
    }

    static func setPair(
        _ pair: CaptureAudioProgramPair?,
        forDeviceUniqueID uid: String,
        defaults: UserDefaults = .standard
    ) {
        guard !uid.isEmpty else { return }
        let k = key(forDeviceUniqueID: uid)
        guard let pair, let data = try? JSONEncoder().encode(pair) else {
            defaults.removeObject(forKey: k)
            return
        }
        defaults.set(data, forKey: k)
    }
}

/// Deterministic per-channel / per-pair signal statistics for a multichannel
/// capture buffer. No AVFoundation or hardware dependency; suitable for the
/// live diagnostic and for unit tests.
enum MultichannelSignalProbe {

    /// RMS (linear, full-scale) below this counts as silence.
    static let silenceRMS: Float = 0.001
    /// RMS below this is "weak" — present but under a usable program level.
    static let weakRMS: Float = 0.02
    /// |sample| at or above this counts as clipping.
    static let clippingPeak: Float = 0.999
    /// |DC mean| at or above this fraction of full-scale is an implausible
    /// pedestal for program audio (the failed Rane take's ch13 sat near −0.868).
    static let excessiveDCOffset: Float = 0.02
    /// |sample − mean| above this counts toward a channel's AC "activity"
    /// fraction. Measured against the mean so a pure-DC channel reads as
    /// inactive however large its offset.
    static let activityThreshold: Float = 0.003

    enum ChannelKind: String, Equatable, Sendable {
        case program          // plausible real audio
        case weakSignal       // audio, but low level
        case silent
        case dcHeavy          // large DC pedestal, little AC content
        case dataOrControl    // non-finite, or near-constant full-scale
        case noiseOnly        // above silence, essentially no structured activity
    }

    struct ChannelStats: Equatable, Sendable {
        let channelIndex: Int
        let frameCount: Int
        let rms: Float
        let peak: Float
        let dcOffset: Float
        let sampleActivity: Float
        let hasNonFiniteSamples: Bool

        var rmsDBFS: Float { MultichannelSignalProbe.dbfs(rms) }
        var peakDBFS: Float { MultichannelSignalProbe.dbfs(peak) }
        var isSilent: Bool { !hasNonFiniteSamples && rms < MultichannelSignalProbe.silenceRMS }
        var isClipping: Bool { peak >= MultichannelSignalProbe.clippingPeak }
        var hasExcessiveDC: Bool { dcOffset.isFinite && abs(dcOffset) >= MultichannelSignalProbe.excessiveDCOffset }

        var kind: ChannelKind {
            if hasNonFiniteSamples { return .dataOrControl }
            if peak >= 0.999 && rms >= 0.98 { return .dataOrControl }
            if isSilent { return .silent }
            if hasExcessiveDC && sampleActivity < 0.05 { return .dcHeavy }
            if rms < MultichannelSignalProbe.silenceRMS { return .silent }
            if sampleActivity < 0.02 { return .noiseOnly }
            if rms < MultichannelSignalProbe.weakRMS { return .weakSignal }
            return .program
        }
    }

    struct PairStats: Equatable, Sendable {
        let pair: CaptureAudioProgramPair
        let left: ChannelStats
        let right: ChannelStats
        let correlation: Float
        /// 0…1; higher means the pair looks more like real stereo program audio.
        let programLikelihood: Float

        var label: String { pair.label }
    }

    struct Snapshot: Equatable, Sendable {
        let channelCount: Int
        let sampleRate: Double
        let frameCount: Int
        let channels: [ChannelStats]
        let pairs: [PairStats]
        let recommendedPair: CaptureAudioProgramPair?

        /// The "CH 1/2 …" block described in the diagnostic spec.
        var reportText: String {
            var lines: [String] = []
            lines.append(String(
                format: "device: %d ch @ %.0f Hz, %d frames",
                channelCount, sampleRate, frameCount
            ))
            if let recommendedPair {
                lines.append("recommended program pair: CH \(recommendedPair.label)")
            } else {
                lines.append("recommended program pair: (none — no pair looks like program audio)")
            }
            for pairStats in pairs {
                lines.append("")
                lines.append("CH \(pairStats.label)")
                lines.append(String(
                    format: "L RMS: %@   R RMS: %@",
                    Self.db(pairStats.left.rmsDBFS), Self.db(pairStats.right.rmsDBFS)
                ))
                lines.append(String(
                    format: "L peak: %@   R peak: %@",
                    Self.db(pairStats.left.peakDBFS), Self.db(pairStats.right.peakDBFS)
                ))
                lines.append(String(
                    format: "L DC: %+.5f   R DC: %+.5f",
                    pairStats.left.dcOffset, pairStats.right.dcOffset
                ))
                lines.append(String(
                    format: "corr: %+.3f   likelihood: %.2f",
                    pairStats.correlation, pairStats.programLikelihood
                ))
                lines.append("status: L \(pairStats.left.kind.rawValue) / R \(pairStats.right.kind.rawValue)")
            }
            return lines.joined(separator: "\n")
        }

        private static func db(_ value: Float) -> String {
            value <= -160 ? "  -inf dBFS" : String(format: "%7.1f dBFS", value)
        }
    }

    static func dbfs(_ linear: Float) -> Float {
        guard linear.isFinite, linear > 0 else { return -160 }
        return 20 * log10(linear)
    }

    /// Analyse planar per-channel Float samples (one array per channel).
    static func analyze(planarChannels: [[Float]], sampleRate: Double) -> Snapshot? {
        guard !planarChannels.isEmpty else { return nil }
        let frameCount = planarChannels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return nil }

        let channels = planarChannels.enumerated().map { index, samples in
            channelStats(channelIndex: index, samples: samples, limit: frameCount)
        }

        var pairs: [PairStats] = []
        var start = 0
        while start + 1 < channels.count {
            if let pair = CaptureAudioProgramPair(startChannel: start) {
                pairs.append(pairStats(
                    pair: pair,
                    left: channels[start],
                    right: channels[start + 1],
                    leftSamples: planarChannels[start],
                    rightSamples: planarChannels[start + 1],
                    limit: frameCount
                ))
            }
            start += 2
        }

        let recommendedPair = pairs
            .max(by: { $0.programLikelihood < $1.programLikelihood })
            .flatMap { $0.programLikelihood >= 0.5 ? $0.pair : nil }

        return Snapshot(
            channelCount: channels.count,
            sampleRate: sampleRate,
            frameCount: frameCount,
            channels: channels,
            pairs: pairs,
            recommendedPair: recommendedPair
        )
    }

    /// Analyse an interleaved buffer of `frameCount * channelCount` samples.
    static func analyzeInterleaved(
        _ interleaved: [Float],
        channelCount: Int,
        sampleRate: Double
    ) -> Snapshot? {
        guard channelCount > 0, interleaved.count >= channelCount else { return nil }
        let frameCount = interleaved.count / channelCount
        guard frameCount > 0 else { return nil }
        var planar = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                planar[channel][frame] = interleaved[base + channel]
            }
        }
        return analyze(planarChannels: planar, sampleRate: sampleRate)
    }

    // MARK: - Internals

    static func channelStats(channelIndex: Int, samples: [Float], limit: Int) -> ChannelStats {
        let count = min(limit, samples.count)
        guard count > 0 else {
            return ChannelStats(
                channelIndex: channelIndex, frameCount: 0, rms: 0, peak: 0,
                dcOffset: 0, sampleActivity: 0, hasNonFiniteSamples: false
            )
        }
        var sum: Double = 0
        var sumSquares: Double = 0
        var peak: Float = 0
        var nonFinite = false
        for index in 0..<count {
            let value = samples[index]
            if !value.isFinite {
                nonFinite = true
                continue
            }
            let magnitude = abs(value)
            sum += Double(value)
            sumSquares += Double(value) * Double(value)
            if magnitude > peak { peak = magnitude }
        }
        let n = Double(count)
        let mean = sum / n
        let rms = Float((sumSquares / n).squareRoot())

        // AC activity: fraction of finite samples that swing away from the mean.
        var activeCount = 0
        for index in 0..<count {
            let value = samples[index]
            guard value.isFinite else { continue }
            if abs(value - Float(mean)) > activityThreshold { activeCount += 1 }
        }
        return ChannelStats(
            channelIndex: channelIndex,
            frameCount: count,
            rms: rms.isFinite ? rms : 0,
            peak: peak,
            dcOffset: Float(mean),
            sampleActivity: Float(activeCount) / Float(count),
            hasNonFiniteSamples: nonFinite
        )
    }

    static func pairStats(
        pair: CaptureAudioProgramPair,
        left: ChannelStats,
        right: ChannelStats,
        leftSamples: [Float],
        rightSamples: [Float],
        limit: Int
    ) -> PairStats {
        let correlation = pearsonCorrelation(leftSamples, rightSamples, limit: limit)
        let likelihood = programLikelihood(left: left, right: right, correlation: correlation)
        return PairStats(
            pair: pair,
            left: left,
            right: right,
            correlation: correlation,
            programLikelihood: likelihood
        )
    }

    static func pearsonCorrelation(_ a: [Float], _ b: [Float], limit: Int) -> Float {
        let count = min(limit, min(a.count, b.count))
        guard count > 1 else { return 0 }
        var sumA: Double = 0, sumB: Double = 0
        for index in 0..<count {
            let x = a[index], y = b[index]
            guard x.isFinite, y.isFinite else { return 0 }
            sumA += Double(x); sumB += Double(y)
        }
        let meanA = sumA / Double(count)
        let meanB = sumB / Double(count)
        var covariance: Double = 0, varA: Double = 0, varB: Double = 0
        for index in 0..<count {
            let dx = Double(a[index]) - meanA
            let dy = Double(b[index]) - meanB
            covariance += dx * dy
            varA += dx * dx
            varB += dy * dy
        }
        guard varA > 0, varB > 0 else { return 0 }
        let result = covariance / (varA.squareRoot() * varB.squareRoot())
        return Float(max(-1, min(1, result)))
    }

    static func programLikelihood(
        left: ChannelStats,
        right: ChannelStats,
        correlation: Float
    ) -> Float {
        var score: Float = 0

        for channel in [left, right] {
            switch channel.kind {
            case .program: score += 0.35
            case .weakSignal: score += 0.12
            case .noiseOnly: score += 0.02
            case .silent, .dcHeavy, .dataOrControl: score -= 0.30
            }
        }

        // Both channels sitting in a plausible program band.
        let bandOK = [left, right].allSatisfy { $0.rmsDBFS <= -3 && $0.rmsDBFS >= -55 }
        if bandOK { score += 0.20 }

        // Real stereo: correlated enough to be one performance, decorrelated
        // enough not to be dual-mono / a duplicated data line.
        let magnitude = abs(correlation)
        if magnitude > 0.05 && magnitude < 0.985 { score += 0.15 }
        if magnitude >= 0.999 { score -= 0.10 }

        // Hard disqualifiers.
        if left.isClipping || right.isClipping { score *= 0.5 }
        if left.hasExcessiveDC || right.hasExcessiveDC { score *= 0.3 }
        if left.hasNonFiniteSamples || right.hasNonFiniteSamples { score = 0 }
        if left.isSilent || right.isSilent { score *= 0.15 }

        return max(0, min(1, score))
    }
}
