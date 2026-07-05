#if DEBUG
import Foundation

/// Background JSONL writer for periodic DVS hardware validation snapshots.
///
/// Writes to the app container's temporary directory, which is writable in a
/// sandboxed build.
/// All file I/O runs on a private utility queue; never on the audio or main thread.
final class DVSLiveLogger: ObservableObject {

    /// Absolute URL of the JSONL log file in the app container.
    let logURL: URL

    /// Human-readable status of the last write attempt.
    @Published private(set) var lastWriteStatus: String = "Not yet written"
    @Published private(set) var lastWriteTimestamp: Date?
    @Published private(set) var lastWriteError: String?
    @Published private(set) var totalLinesWritten = 0

    private let queue = DispatchQueue(label: "dvs.live.logger", qos: .utility)

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(logURL: URL? = nil) {
        self.logURL = logURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchLab/DVSDiagnostics", isDirectory: true)
            .appendingPathComponent("dvs_diagnostics.jsonl")
    }

    func append(_ entry: DVSLogEntry) {
        let url = logURL
        queue.async { [self] in
            let now = Date()
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeEntry(entry, to: url)
                DispatchQueue.main.async {
                    self.lastWriteStatus = "Write succeeded"
                    self.lastWriteTimestamp = now
                    self.lastWriteError = nil
                    self.totalLinesWritten += 1
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.lastWriteStatus = "Write failed"
                    self.lastWriteTimestamp = now
                    self.lastWriteError = message
                }
            }
        }
    }

    func clear() {
        let url = logURL
        queue.async { [self] in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                DispatchQueue.main.async {
                    self.lastWriteStatus = "Log cleared"
                    self.lastWriteTimestamp = nil
                    self.lastWriteError = nil
                    self.totalLinesWritten = 0
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.lastWriteStatus = "Clear failed"
                    self.lastWriteError = message
                }
            }
        }
    }

    // MARK: - Private

    private func writeEntry(_ entry: DVSLogEntry, to url: URL) throws {
        let data = try encoder.encode(entry)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let text = line + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: false, encoding: .utf8)
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
