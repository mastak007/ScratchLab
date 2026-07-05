#if DEBUG
import Foundation

/// Throttled background JSONL writer for DVS hardware validation.
///
/// On init, attempts to resolve the log file to the project's scratchpad
/// directory (using #file). If the App Sandbox blocks that path, falls back
/// to FileManager.temporaryDirectory — always writable in a sandboxed build.
/// All file I/O runs on a private utility queue; never on the audio or main thread.
final class DVSLiveLogger: ObservableObject {

    /// Resolved log file URL — project scratchpad when writable, temp dir otherwise.
    @Published private(set) var logURL: URL

    /// Human-readable status of the last write attempt.
    @Published private(set) var lastWriteStatus: String = "Not yet written"

    private static let minInterval: TimeInterval = 1.0 / 5.0  // 5 Hz throttle

    private let queue = DispatchQueue(label: "dvs.live.logger", qos: .utility)
    private var lastWriteDate: Date = .distantPast

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        logURL = Self.resolveLogURL()
    }

    func append(_ entry: DVSLogEntry) {
        let url = logURL
        queue.async { [self] in
            let now = Date()
            guard now.timeIntervalSince(lastWriteDate) >= DVSLiveLogger.minInterval else { return }
            lastWriteDate = now
            let status = writeEntry(entry, to: url)
            DispatchQueue.main.async { self.lastWriteStatus = status }
        }
    }

    func clear() {
        let url = logURL
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
        DispatchQueue.main.async { self.lastWriteStatus = "Log cleared" }
    }

    // MARK: - Private

    /// Try project scratchpad first; fall back to temp dir if the sandbox blocks it.
    private static func resolveLogURL() -> URL {
        let preferred = URL(fileURLWithPath: #file)  // .../ScratchLabDesktop/Services/DVSLiveLogger.swift
            .deletingLastPathComponent()              // .../ScratchLabDesktop/Services/
            .deletingLastPathComponent()              // .../ScratchLabDesktop/
            .deletingLastPathComponent()              // project root
            .appendingPathComponent("scratchpad/dvs_live/dvs_diagnostics.jsonl")

        let dir = preferred.deletingLastPathComponent()
        if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
            return preferred
        }

        // App Sandbox blocked the project-root path — fall back to temp dir.
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("dvs_live/dvs_diagnostics.jsonl")
        try? FileManager.default.createDirectory(
            at: fallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return fallback
    }

    private func writeEntry(_ entry: DVSLogEntry, to url: URL) -> String {
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else {
            return "encode error"
        }
        let text = line + "\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try handle.close()
            } else {
                try text.write(to: url, atomically: false, encoding: .utf8)
            }
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            return String(format: "OK %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        } catch {
            return "write error: \(error.localizedDescription)"
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
