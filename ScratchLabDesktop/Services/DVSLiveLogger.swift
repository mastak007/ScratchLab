#if DEBUG
import Foundation

/// Throttled background JSONL writer for DVS hardware validation.
///
/// Writes to scratchpad/dvs_live/dvs_diagnostics.jsonl in the project root at
/// 5 Hz max. All file I/O runs on a private utility queue — never on the audio
/// or main thread.
final class DVSLiveLogger {

    /// Absolute path to the JSONL log file, derived from source location at
    /// compile time so it always lands in the project scratchpad regardless of
    /// where Xcode launches the app from.
    static let logURL: URL = {
        URL(fileURLWithPath: #file)          // .../ScratchLabDesktop/Services/DVSLiveLogger.swift
            .deletingLastPathComponent()      // .../ScratchLabDesktop/Services/
            .deletingLastPathComponent()      // .../ScratchLabDesktop/
            .deletingLastPathComponent()      // project root
            .appendingPathComponent("scratchpad/dvs_live/dvs_diagnostics.jsonl")
    }()

    private static let minInterval: TimeInterval = 1.0 / 5.0  // 5 Hz throttle

    private let queue = DispatchQueue(label: "dvs.live.logger", qos: .utility)
    private var lastWriteDate: Date = .distantPast

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func append(_ entry: DVSLogEntry) {
        queue.async { [self] in
            let now = Date()
            guard now.timeIntervalSince(lastWriteDate) >= DVSLiveLogger.minInterval else { return }
            lastWriteDate = now
            writeEntry(entry)
        }
    }

    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: DVSLiveLogger.logURL)
        }
    }

    private func writeEntry(_ entry: DVSLogEntry) {
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let dir = DVSLiveLogger.logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = line + "\n"
        if FileManager.default.fileExists(atPath: DVSLiveLogger.logURL.path) {
            guard let handle = try? FileHandle(forWritingTo: DVSLiveLogger.logURL) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: DVSLiveLogger.logURL, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Log entry

struct DVSLogEntry: Encodable {
    let timestamp: Date
    let sampleRate: Double
    let channelCount: Int
    let selectedChannelMode: String
    let leftRMS: Float
    let rightRMS: Float?
    let leftPeak: Float
    let rightPeak: Float?
    let signalHealth: String
    let hasSignal: Bool
    let direction: String
    let speed: Double
    let rawRate: Double
    let smoothedRate: Double
    let confidence: Double
    let minConfidence: Double
    let maxRate: Double
    let dropReason: String?
    let dominantFrequencyHz: Float?
    let zeroCrossingRateLeft: Float?
    let phaseDelta: Double?
    let acceptedCount: Int
    let droppedCount: Int
    let silenceCount: Int
    let weakCount: Int
    let lowConfidenceCount: Int
    let clippedCount: Int
}
#endif
