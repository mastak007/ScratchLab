import Foundation
import CoreGraphics
import QuartzCore

// MARK: - Schema version

let cxlNotationCaptureSchemaVersion = "cxl_notation_capture_v1"

// MARK: - Direction / source enums

enum CXLDirection: String, Codable {
    case forward
    case back
    case idle
    case searching
}

enum CXLSignalSource: String, Codable {
    case camera
    case audio
    case fused
    case searching
}

enum CXLTimingClassification: String, Codable {
    case early
    case onTime         = "onTime"
    case late
    case wrongDirection = "wrongDirection"
    case missed
    case idle
}

// MARK: - Session metadata

struct CXLNotationCaptureSession: Codable {
    var schemaVersion: String
    var sessionId: String
    var createdAt: Date
    var scratchType: String
    var mode: String
    var bpm: Int?
    var loopDuration: Double?
    var cameraMode: String?
    var calibrationLocked: Bool
    var deckROI: CXLRect?
    var appBuildVersion: String?
    var notes: String?

    struct CXLRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

// MARK: - Events

struct CXLNotationCaptureEvent: Codable {
    var type: String
    // Shared timing
    var time: Double?
    var playbackTime: Double?
    var loopTime: Double?
    // captureStarted / captureStopped
    // (no extra fields beyond type + time)
    // loopStart / loopEnd
    var loopIndex: Int?
    // targetStroke
    var direction: CXLDirection?
    var strokeIndex: Int?
    var duration: Double?
    // motionStroke
    var detectedDirection: CXLDirection?
    var confidence: Double?
    var signalSource: CXLSignalSource?
    var handX: Double?
    var handY: Double?
    // audioScratch
    var rms: Double?
    var onset: Bool?
    // score
    var targetStrokeIndex: Int?
    var targetDirection: CXLDirection?
    var observedDirection: CXLDirection?
    var timingErrorMs: Double?
    var classification: CXLTimingClassification?
    // calibrationChanged
    var calibrationLocked: Bool?
}

// MARK: - Periodic samples

struct CXLNotationCaptureSample: Codable {
    var time: Double
    var playbackTime: Double
    var loopTime: Double
    var targetDirection: CXLDirection?
    var detectedDirection: CXLDirection
    var handX: Double?
    var handY: Double?
    var motionConfidence: Double
    var audioConfidence: Double?
    var signalSource: CXLSignalSource
    var timingErrorMs: Double?
    var calibrationLocked: Bool
}

// MARK: - Summary

struct CXLNotationCaptureSummary: Codable {
    var sessionId: String
    var scratchType: String
    var mode: String
    var durationSeconds: Double
    var targetStrokeCount: Int
    var motionStrokeCount: Int
    var audioScratchCount: Int
    var onTimeCount: Int
    var earlyCount: Int
    var lateCount: Int
    var wrongDirectionCount: Int
    var missedCount: Int
    var sampleCount: Int
    var exportedAt: Date
}

// MARK: - Recorder

final class CXLNotationCaptureRecorder {

    // Timing classification window (ms): within ±120ms = onTime
    static let onTimeWindowMs: Double = 120

    private(set) var isRecording = false
    private(set) var sessionId = ""
    private(set) var eventCount = 0
    private(set) var sampleCount = 0
    private(set) var lastExportPath: String?

    private var session: CXLNotationCaptureSession?
    private var sessionStartTime: Date?
    private var sessionStartWallClock: CFTimeInterval = 0
    private var events: [CXLNotationCaptureEvent] = []
    private var samples: [CXLNotationCaptureSample] = []
    private var lastSampleTime: CFTimeInterval = 0
    private let sampleInterval: CFTimeInterval = 1.0 / 10.0   // ~10 Hz
    private var nextStrokeIndex = 0
    private var loopDuration: Double = 0
    private var loopIndex = 0
    private var loopStartTime: Double = 0

    // MARK: - Session lifecycle

    func startSession(
        scratchType: String,
        mode: String,
        bpm: Int?,
        loopDuration: Double?,
        cameraMode: String?,
        calibrationLocked: Bool,
        deckROI: CXLNotationCaptureSession.CXLRect?,
        appBuildVersion: String? = nil,
        notes: String? = nil
    ) {
        guard !isRecording else { return }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let stamp = iso.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "T")
        let typeSlug = scratchType.replacingOccurrences(of: " ", with: "_").lowercased()
        let id = "\(stamp.prefix(19))_\(typeSlug)_\(String(format: "%03d", Int.random(in: 0...999)))"

        session = CXLNotationCaptureSession(
            schemaVersion: cxlNotationCaptureSchemaVersion,
            sessionId: id,
            createdAt: now,
            scratchType: scratchType,
            mode: mode,
            bpm: bpm,
            loopDuration: loopDuration,
            cameraMode: cameraMode,
            calibrationLocked: calibrationLocked,
            deckROI: deckROI,
            appBuildVersion: appBuildVersion,
            notes: notes
        )

        sessionId = id
        sessionStartTime = now
        sessionStartWallClock = CACurrentMediaTime()
        events = []
        samples = []
        eventCount = 0
        sampleCount = 0
        nextStrokeIndex = 0
        loopIndex = 0
        loopStartTime = 0
        self.loopDuration = loopDuration ?? 0
        isRecording = true

        appendEvent(.init(type: "captureStarted", time: 0, playbackTime: 0, loopTime: 0))
    }

    func stopSession() {
        guard isRecording else { return }
        let t = elapsed()
        appendEvent(.init(type: "captureStopped", time: t, playbackTime: t, loopTime: loopTimeAt(t)))
        isRecording = false
    }

    // MARK: - Target strokes

    /// Record what should happen — the notation / expected stroke.
    /// Direction must come from the notation playback engine, never from live hand detection.
    @discardableResult
    func recordTargetStroke(
        direction: CXLDirection,
        strokeDuration: Double? = nil
    ) -> Int {
        guard isRecording else { return -1 }
        let t = elapsed()
        let idx = nextStrokeIndex
        nextStrokeIndex += 1
        var event = CXLNotationCaptureEvent(type: "targetStroke")
        event.time = t
        event.playbackTime = t
        event.loopTime = loopTimeAt(t)
        event.direction = direction
        event.strokeIndex = idx
        event.loopIndex = loopIndex > 0 ? loopIndex : nil
        event.duration = strokeDuration
        appendEvent(event)
        return idx
    }

    // MARK: - Motion strokes

    func recordMotionStroke(
        detectedDirection: CXLDirection,
        confidence: Double,
        signalSource: CXLSignalSource,
        handX: Double?,
        handY: Double?
    ) {
        guard isRecording else { return }
        let t = elapsed()
        var event = CXLNotationCaptureEvent(type: "motionStroke")
        event.time = t
        event.playbackTime = t
        event.loopTime = loopTimeAt(t)
        event.detectedDirection = detectedDirection
        event.confidence = confidence
        event.signalSource = signalSource
        event.handX = handX
        event.handY = handY
        appendEvent(event)
    }

    // MARK: - Audio scratch

    func recordAudioScratch(
        confidence: Double,
        rms: Double?,
        onset: Bool?
    ) {
        guard isRecording else { return }
        let t = elapsed()
        var event = CXLNotationCaptureEvent(type: "audioScratch")
        event.time = t
        event.playbackTime = t
        event.loopTime = loopTimeAt(t)
        event.confidence = confidence
        event.rms = rms
        event.onset = onset
        appendEvent(event)
    }

    // MARK: - Score

    func recordScore(
        targetStrokeIndex: Int,
        targetDirection: CXLDirection,
        observedDirection: CXLDirection,
        timingErrorMs: Double,
        confidence: Double,
        signalSource: CXLSignalSource
    ) {
        guard isRecording else { return }
        let classification = classify(
            target: targetDirection,
            observed: observedDirection,
            timingErrorMs: timingErrorMs,
            confidence: confidence
        )
        var event = CXLNotationCaptureEvent(type: "score")
        event.targetStrokeIndex = targetStrokeIndex
        event.targetDirection = targetDirection
        event.observedDirection = observedDirection
        event.timingErrorMs = timingErrorMs
        event.classification = classification
        event.confidence = confidence
        event.signalSource = signalSource
        appendEvent(event)
    }

    // MARK: - Loop boundaries

    func recordLoopStart() {
        guard isRecording else { return }
        let t = elapsed()
        loopStartTime = t
        var event = CXLNotationCaptureEvent(type: "loopStart")
        event.time = t
        event.playbackTime = t
        event.loopTime = 0
        event.loopIndex = loopIndex
        appendEvent(event)
    }

    func recordLoopEnd() {
        guard isRecording else { return }
        let t = elapsed()
        var event = CXLNotationCaptureEvent(type: "loopEnd")
        event.time = t
        event.playbackTime = t
        event.loopTime = loopTimeAt(t)
        event.loopIndex = loopIndex
        appendEvent(event)
        loopIndex += 1
    }

    // MARK: - Calibration change

    func recordCalibrationChanged(locked: Bool) {
        guard isRecording else { return }
        let t = elapsed()
        var event = CXLNotationCaptureEvent(type: "calibrationChanged")
        event.time = t
        event.playbackTime = t
        event.loopTime = loopTimeAt(t)
        event.calibrationLocked = locked
        appendEvent(event)
    }

    // MARK: - Periodic samples (throttled to sampleInterval)

    func recordSample(
        targetDirection: CXLDirection?,
        detectedDirection: CXLDirection,
        handX: Double?,
        handY: Double?,
        motionConfidence: Double,
        audioConfidence: Double?,
        signalSource: CXLSignalSource,
        timingErrorMs: Double?,
        calibrationLocked: Bool
    ) {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= sampleInterval else { return }
        lastSampleTime = now

        let t = elapsed()
        let sample = CXLNotationCaptureSample(
            time: t,
            playbackTime: t,
            loopTime: loopTimeAt(t),
            targetDirection: targetDirection,
            detectedDirection: detectedDirection,
            handX: handX,
            handY: handY,
            motionConfidence: motionConfidence,
            audioConfidence: audioConfidence,
            signalSource: signalSource,
            timingErrorMs: timingErrorMs,
            calibrationLocked: calibrationLocked
        )
        samples.append(sample)
        sampleCount = samples.count
    }

    // MARK: - Export

    struct ExportResult {
        let directoryURL: URL
        let sessionFile: URL
        let eventsFile: URL
        let samplesFile: URL
        let summaryFile: URL
    }

    @discardableResult
    func exportSession() throws -> ExportResult {
        guard let session else {
            throw CXLExportError.noActiveSession
        }

        let directory = try exportDirectoryURL(for: session.sessionId)
        let result = ExportResult(
            directoryURL: directory,
            sessionFile: directory.appendingPathComponent("session.json"),
            eventsFile: directory.appendingPathComponent("events.jsonl"),
            samplesFile: directory.appendingPathComponent("samples.jsonl"),
            summaryFile: directory.appendingPathComponent("summary.csv")
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        // session.json
        let sessionData = try encoder.encode(session)
        try sessionData.write(to: result.sessionFile, options: .atomic)

        // events.jsonl
        let eventsData = try encodeJSONL(events, encoder: encoder)
        try eventsData.write(to: result.eventsFile, options: .atomic)

        // samples.jsonl
        let samplesData = try encodeJSONL(samples, encoder: encoder)
        try samplesData.write(to: result.samplesFile, options: .atomic)

        // summary.csv
        let summaryData = buildSummaryCSV(session: session)
        try summaryData.write(to: result.summaryFile, atomically: true, encoding: .utf8)

        lastExportPath = directory.path
        return result
    }

    // MARK: - Private helpers

    private func elapsed() -> Double {
        CACurrentMediaTime() - sessionStartWallClock
    }

    private func loopTimeAt(_ playbackTime: Double) -> Double {
        guard loopDuration > 0 else { return playbackTime - loopStartTime }
        return playbackTime.truncatingRemainder(dividingBy: loopDuration)
    }

    private func appendEvent(_ event: CXLNotationCaptureEvent) {
        events.append(event)
        eventCount = events.count
    }

    private func classify(
        target: CXLDirection,
        observed: CXLDirection,
        timingErrorMs: Double,
        confidence: Double
    ) -> CXLTimingClassification {
        Self.classify(target: target, observed: observed, timingErrorMs: timingErrorMs, confidence: confidence)
    }

    /// Public so tests can verify classification logic without going through a full export cycle.
    static func classify(
        target: CXLDirection,
        observed: CXLDirection,
        timingErrorMs: Double,
        confidence: Double
    ) -> CXLTimingClassification {
        if observed == .idle || confidence < 0.10 {
            return .idle
        }
        if target != .idle && target != .searching && observed != target {
            return .wrongDirection
        }
        if timingErrorMs < -onTimeWindowMs {
            return .early
        }
        if timingErrorMs > onTimeWindowMs {
            return .late
        }
        return .onTime
    }

    private func exportDirectoryURL(for sessionId: String) throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let dir = base
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("CXL_Dataset", isDirectory: true)
            .appendingPathComponent("session_\(sessionId)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func encodeJSONL<T: Encodable>(_ items: [T], encoder: JSONEncoder) throws -> Data {
        var lines = items.compactMap { item -> Data? in
            try? encoder.encode(item)
        }
        lines = lines.map { lineData in
            var d = lineData
            d.append(contentsOf: "\n".utf8)
            return d
        }
        return lines.reduce(Data()) { $0 + $1 }
    }

    private func buildSummaryCSV(session: CXLNotationCaptureSession) -> String {
        let duration = elapsed()
        var onTime = 0, early = 0, late = 0, wrong = 0, missed = 0
        for event in events where event.type == "score" {
            switch event.classification {
            case .onTime:         onTime += 1
            case .early:          early += 1
            case .late:           late += 1
            case .wrongDirection: wrong += 1
            case .missed:         missed += 1
            default: break
            }
        }
        let targetCount = events.filter { $0.type == "targetStroke" }.count
        let motionCount = events.filter { $0.type == "motionStroke" }.count
        let audioCount  = events.filter { $0.type == "audioScratch" }.count

        let header = "sessionId,scratchType,mode,durationSeconds,targetStrokeCount,motionStrokeCount,audioScratchCount,onTime,early,late,wrongDirection,missed,sampleCount,exportedAt"
        let iso = ISO8601DateFormatter()
        let row = [
            session.sessionId,
            session.scratchType,
            session.mode,
            String(format: "%.2f", duration),
            "\(targetCount)", "\(motionCount)", "\(audioCount)",
            "\(onTime)", "\(early)", "\(late)", "\(wrong)", "\(missed)",
            "\(samples.count)",
            iso.string(from: Date())
        ].joined(separator: ",")

        return header + "\n" + row + "\n"
    }
}

// MARK: - Errors

enum CXLExportError: LocalizedError {
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .noActiveSession: return "No notation capture session is active. Start a session before exporting."
        }
    }
}
