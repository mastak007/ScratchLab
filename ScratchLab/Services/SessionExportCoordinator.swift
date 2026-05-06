import AVFoundation
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
#endif

struct SessionExportDeviceInfo: Codable, Equatable, Sendable {
    let sourceDeviceName: String
    let appSurface: String
    let cameraPosition: String?
    let audioInputName: String?
    let videoDeviceUniqueID: String?
    let videoDeviceName: String?
    let audioDeviceUniqueID: String?
    let audioDeviceName: String?
}

struct SessionExportMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_session_export_v4"

    let schemaVersion: String
    let sessionID: String
    let workflow: String
    let platform: String
    let sessionName: String
    let createdAt: Date
    let performerName: String?
    let scratchTypeID: String?
    let scratchTypeName: String?
    let drillMode: String?
    let bpm: Int?
    let captureMode: String
    let clickEnabled: Bool
    let beatEngineMode: String
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let engineVersion: String
    let countInBeats: Int
    let beatsPerBar: Int
    let clickAccentPattern: String
    let clickVersion: String
    let timingPrintedToRecording: String
    let handedness: String?
    let takeCount: Int
    let totalDurationSeconds: Double
    let deckProfile: String?
    let cameraProfile: String?
    let watchWrist: String?
    let notes: String?
    let deviceInfo: SessionExportDeviceInfo?

    init(
        sessionID: String,
        workflow: String,
        platform: String,
        sessionName: String,
        createdAt: Date,
        performerName: String? = nil,
        scratchTypeID: String? = nil,
        scratchTypeName: String? = nil,
        drillMode: String? = nil,
        bpm: Int? = nil,
        captureMode: String = CaptureSessionCaptureMode.timedClick.rawValue,
        clickEnabled: Bool = true,
        beatEngineMode: String = BeatEngineMode.clickTrack.rawValue,
        beatEnabled: Bool = false,
        beatPatternName: String? = nil,
        beatPatternVersion: String = CaptureBeatEngineDefaults.beatPatternVersion,
        swingAmount: Double = 0,
        engineVersion: String = CaptureBeatEngineDefaults.engineVersion,
        countInBeats: Int = CaptureClickTrackDefaults.countInBeats,
        beatsPerBar: Int = CaptureClickTrackDefaults.beatsPerBar,
        clickAccentPattern: String = CaptureClickTrackDefaults.clickAccentPattern,
        clickVersion: String = CaptureClickTrackDefaults.clickVersion,
        timingPrintedToRecording: String = TimingPrintedToRecordingState.unknown.rawValue,
        handedness: String? = nil,
        takeCount: Int,
        totalDurationSeconds: Double,
        deckProfile: String? = nil,
        cameraProfile: String? = nil,
        watchWrist: String? = nil,
        notes: String? = nil,
        deviceInfo: SessionExportDeviceInfo? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.workflow = workflow
        self.platform = platform
        self.sessionName = sessionName
        self.createdAt = createdAt
        self.performerName = performerName
        self.scratchTypeID = scratchTypeID
        self.scratchTypeName = scratchTypeName
        self.drillMode = drillMode
        self.bpm = bpm
        self.captureMode = captureMode
        self.clickEnabled = clickEnabled
        self.beatEngineMode = beatEngineMode
        self.beatEnabled = beatEnabled
        self.beatPatternName = beatPatternName
        self.beatPatternVersion = beatPatternVersion
        self.swingAmount = swingAmount
        self.engineVersion = engineVersion
        self.countInBeats = countInBeats
        self.beatsPerBar = beatsPerBar
        self.clickAccentPattern = clickAccentPattern
        self.clickVersion = clickVersion
        self.timingPrintedToRecording = timingPrintedToRecording
        self.handedness = handedness
        self.takeCount = takeCount
        self.totalDurationSeconds = totalDurationSeconds
        self.deckProfile = deckProfile
        self.cameraProfile = cameraProfile
        self.watchWrist = watchWrist
        self.notes = notes
        self.deviceInfo = deviceInfo
    }
}

extension SessionExportMetadata {
    init(
        config: CaptureSessionConfig,
        workflow: String,
        platform: String,
        sessionName: String,
        totalDurationSeconds: Double? = nil,
        deckProfile: String? = nil,
        cameraProfile: String? = nil,
        watchWrist: String? = nil,
        deviceInfo: SessionExportDeviceInfo? = nil
    ) {
        self.init(
            sessionID: config.sessionID,
            workflow: workflow,
            platform: platform,
            sessionName: sessionName,
            createdAt: config.createdAt,
            performerName: config.normalizedPerformerName,
            scratchTypeID: config.normalizedScratchTypeID,
            scratchTypeName: config.normalizedScratchTypeName,
            drillMode: config.normalizedDrillMode,
            bpm: config.bpm,
            captureMode: config.normalizedCaptureMode,
            clickEnabled: config.clickEnabled,
            beatEngineMode: config.normalizedBeatEngineMode,
            beatEnabled: config.beatEnabled,
            beatPatternName: config.normalizedBeatPatternName,
            beatPatternVersion: config.beatPatternVersion,
            swingAmount: config.swingAmount,
            engineVersion: config.engineVersion,
            countInBeats: config.countInBeats,
            beatsPerBar: config.beatsPerBar,
            clickAccentPattern: config.clickAccentPattern,
            clickVersion: config.clickVersion,
            timingPrintedToRecording: config.timingPrintedToRecording.rawValue,
            handedness: config.normalizedHandedness,
            takeCount: config.takeCount,
            totalDurationSeconds: totalDurationSeconds ?? config.takeDurationSeconds ?? 0,
            deckProfile: deckProfile,
            cameraProfile: cameraProfile,
            watchWrist: watchWrist,
            notes: config.normalizedNotes,
            deviceInfo: deviceInfo
        )
    }
}

struct SessionExportTake: Sendable {
    let takeID: String
    let takeNumber: Int
    let bpm: Int
    let mediaURL: URL
    let audioArtifactURL: URL?
    let sidecarURL: URL
    let watchCaptureSession: WatchMotionCaptureSession?
    let drillName: String?
    let duration: TimeInterval
    let quality: String?
    let comboTagged: Bool
    let audioPresent: Bool?
    let motionPresent: Bool?
    let syncStatus: String?
    let recordingStatus: String
    let verbalSlateUsed: Bool?
    let syncClapUsed: Bool?
    let note: String?
    let captureTiming: CaptureTimingMetadata?

    init(
        takeID: String,
        takeNumber: Int,
        bpm: Int,
        mediaURL: URL,
        audioArtifactURL: URL?,
        sidecarURL: URL,
        watchCaptureSession: WatchMotionCaptureSession?,
        drillName: String?,
        duration: TimeInterval,
        quality: String?,
        comboTagged: Bool,
        audioPresent: Bool?,
        motionPresent: Bool?,
        syncStatus: String?,
        recordingStatus: String,
        verbalSlateUsed: Bool?,
        syncClapUsed: Bool?,
        note: String?,
        captureTiming: CaptureTimingMetadata? = nil
    ) {
        self.takeID = takeID
        self.takeNumber = takeNumber
        self.bpm = bpm
        self.mediaURL = mediaURL
        self.audioArtifactURL = audioArtifactURL
        self.sidecarURL = sidecarURL
        self.watchCaptureSession = watchCaptureSession
        self.drillName = drillName
        self.duration = duration
        self.quality = quality
        self.comboTagged = comboTagged
        self.audioPresent = audioPresent
        self.motionPresent = motionPresent
        self.syncStatus = syncStatus
        self.recordingStatus = recordingStatus
        self.verbalSlateUsed = verbalSlateUsed
        self.syncClapUsed = syncClapUsed
        self.note = note
        self.captureTiming = captureTiming
    }
}

struct SessionExportTakeCaptureMetadata: Codable, Equatable, Sendable {
    let takeID: String
    let takeNumber: Int
    let bpm: Int?
    let captureMode: String
    let clickEnabled: Bool
    let beatEngineMode: String
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let engineVersion: String
    let countInBeats: Int
    let beatsPerBar: Int
    let clickStartHostTime: UInt64?
    let recordingStartHostTime: UInt64?
    let clickAccentPattern: String
    let clickVersion: String
    let timingPrintedToRecording: String
    let notationFile: String?
    let notationSource: String
    let labelSource: String
    let labelConfidence: Double?
    let notationConfidence: Double?
}

struct SessionExportMetadataDocument: Codable, Equatable, Sendable {
    let session: SessionExportMetadata
    let takes: [SessionExportTakeCaptureMetadata]
}

struct SessionExportArtifactMetadata: Codable, Equatable, Sendable {
    let takeID: String
    let takeNumber: Int
    let bpm: Int?
    let exportMixMode: String
    let captureQuality: String
    let timingPrintedToRecording: String
    let captureMode: String
    let clickEnabled: Bool
    let beatEngineMode: String
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let countInBeats: Int
    let beatsPerBar: Int
    let clickStartHostTime: UInt64?
    let recordingStartHostTime: UInt64?
    let clickVersion: String
    let engineVersion: String
    let scratchOnlyFile: String?
    let beatOnlyFile: String?
    let scratchWithBeatFile: String?
    let scratchOnlyAvailability: String
    let beatOnlyAvailability: String
    let scratchWithBeatAvailability: String
    let scratchFile: String?
    let timingFile: String?
    let rawTakeFile: String?
    let notationFile: String?
    let notationSource: String
    let labelSource: String
    let labelConfidence: Double?
    let notationConfidence: Double?
}

struct SessionExportArtifactMetadataDocument: Codable, Equatable, Sendable {
    let sessionID: String
    let sessionName: String
    let exportMixMode: String
    let captureQuality: String
    let timingPrintedToRecording: String
    let takes: [SessionExportArtifactMetadata]
}

enum SessionExportNotationSource: String, Codable, Equatable, Sendable {
    case detected
    case template
    case unavailable
}

enum SessionExportLabelSource: String, Codable, Equatable, Sendable {
    case detected
    case manual
    case corrected
    case unknown
}

struct SessionExportRecordMovementEvent: Codable, Equatable, Sendable {
    let direction: String?
    let startTime: Double?
    let endTime: Double?
    let startPosition: Double?
    let endPosition: Double?
    let movementKind: String?
    let speed: Double?
    let confidence: Double?
    let source: String?
}

struct SessionExportFaderEvent: Codable, Equatable, Sendable {
    let time: Double?
    let state: String?
    let confidence: Double?
}

struct SessionExportMixerMidiEvent: Codable, Equatable, Sendable {
    let time: Double?
    let status: Int?
    let data1: Int?
    let data2: Int?
    let channel: Int?
}

struct SessionExportNotationBeatGrid: Codable, Equatable, Sendable {
    let bpm: Int
    let beatsPerBar: Int
    let countInBeats: Int
}

struct SessionExportNotationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_detected_notation_v1"

    let schemaVersion: String
    let sessionID: String
    let takeID: String
    let takeNumber: Int
    let scratchType: String
    let bpm: Int?
    let captureMode: String
    let notationSource: SessionExportNotationSource
    let labelSource: SessionExportLabelSource
    let labelConfidence: Double?
    let notationConfidence: Double?
    let recordMovementEvents: [SessionExportRecordMovementEvent]
    let faderEvents: [SessionExportFaderEvent]
    let mixerMidiEvents: [SessionExportMixerMidiEvent]
    let beatGrid: SessionExportNotationBeatGrid?
    let notes: String

    init(
        sessionID: String,
        takeID: String,
        takeNumber: Int,
        scratchType: String,
        bpm: Int?,
        captureMode: String,
        notationSource: SessionExportNotationSource,
        labelSource: SessionExportLabelSource,
        labelConfidence: Double?,
        notationConfidence: Double?,
        recordMovementEvents: [SessionExportRecordMovementEvent],
        faderEvents: [SessionExportFaderEvent],
        mixerMidiEvents: [SessionExportMixerMidiEvent],
        beatGrid: SessionExportNotationBeatGrid?,
        notes: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.takeID = takeID
        self.takeNumber = takeNumber
        self.scratchType = scratchType
        self.bpm = bpm
        self.captureMode = captureMode
        self.notationSource = notationSource
        self.labelSource = labelSource
        self.labelConfidence = labelConfidence
        self.notationConfidence = notationConfidence
        self.recordMovementEvents = recordMovementEvents
        self.faderEvents = faderEvents
        self.mixerMidiEvents = mixerMidiEvents
        self.beatGrid = beatGrid
        self.notes = notes
    }
}

struct SessionExportPackage: Sendable {
    let metadata: SessionExportMetadata
    let takes: [SessionExportTake]
    let calibrationData: Data?
}

enum SessionExportSource: Sendable {
    case package(SessionExportPackage)
    case localRecordingSession(lastRecordingURL: URL, sessionName: String, config: CaptureSessionConfig?)
}

struct SessionExportResult: Identifiable, Equatable, Sendable {
    let archiveURL: URL
    let archiveSizeBytes: Int64
    let sessionName: String
    let createdAt: Date
    let shouldCleanupAfterUse: Bool

    var id: String { archiveURL.path }
    var displayName: String { archiveURL.lastPathComponent }
    var subject: String { "ScratchLab Session Export: \(sessionName)" }
    var formattedArchiveSize: String {
        ByteCountFormatter.string(fromByteCount: archiveSizeBytes, countStyle: .file)
    }
}

enum SessionExportState {
    case idle
    case validating
    case preparingArchive
    case readyToShare(SessionExportResult)
    case presentingShareSheet(SessionExportResult)
    case shareCompleted(SessionExportResult)
    case cancelled(SessionExportResult?)
    case failed(SessionExportError)
}

enum SessionExportError: Error, Equatable, Sendable {
    case sessionFolderNotFound
    case missingRequiredFiles
    case invalidSessionMetadata
    case unableToPrepareExport
    case unableToCreateArchive
    case unableToSaveArchive
    case unableToPresentShareOptions

    var userMessage: String {
        switch self {
        case .sessionFolderNotFound:
            return "Session folder not found."
        case .missingRequiredFiles:
            return "This session is missing required files."
        case .invalidSessionMetadata:
            return "This session has inconsistent metadata."
        case .unableToPrepareExport:
            return "Unable to prepare export."
        case .unableToCreateArchive:
            return "Unable to create ZIP archive."
        case .unableToSaveArchive:
            return "ScratchLab couldn't save to the selected location. Try Desktop or choose another folder."
        case .unableToPresentShareOptions:
            return "Unable to present sharing options."
        }
    }
}

enum TakeArtifactReadiness: Equatable, Sendable {
    case recording
    case finalizing
    case ready
    case missingAudio
    case missingVideo
    case failed(String)

    var badgeTitle: String {
        switch self {
        case .recording:
            return "Recording"
        case .finalizing:
            return "Finalizing"
        case .ready:
            return "Ready"
        case .missingAudio:
            return "Missing Audio"
        case .missingVideo:
            return "Missing Video"
        case .failed:
            return "Failed"
        }
    }
}

struct TakeArtifactStatusSnapshot: Equatable, Sendable, Identifiable {
    let takeID: String
    let takeNumber: Int
    let bpm: Int?
    let audioSourceURL: URL?
    let videoSourceURL: URL?
    let audioExists: Bool
    let videoExists: Bool
    let audioBytes: Int64
    let videoBytes: Int64
    let finalizedAt: Date?
    let readiness: TakeArtifactReadiness
    let detectedNotation: CaptureCore.DetectedNotationSnapshot?
    let detectedLabel: String?
    let labelConfidence: Double?

    var id: String { takeID }
}

enum ArtifactPreflight {
    struct Configuration: Equatable, Sendable {
        let timeout: TimeInterval
        let pollInterval: TimeInterval
        let stabilityInterval: TimeInterval

        static let exportDefault = Configuration(
            timeout: 4.0,
            pollInterval: 0.2,
            stabilityInterval: 0.35
        )
    }

    struct FileCheckResult: Equatable, Sendable {
        let url: URL
        let exists: Bool
        let bytes: Int64
        let isStable: Bool
    }

    static func checkFileReady(
        url: URL,
        fileManager: FileManager = .default,
        configuration: Configuration = .exportDefault
    ) -> FileCheckResult {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        var lastObservedSize: Int64 = 0
        var lastObservedExists = false

        while Date() <= deadline {
            let current = fileState(at: url, fileManager: fileManager)
            lastObservedExists = current.exists
            lastObservedSize = current.bytes

            if current.exists, current.bytes > 0 {
                Thread.sleep(forTimeInterval: configuration.stabilityInterval)
                let stabilized = fileState(at: url, fileManager: fileManager)
                if stabilized.exists, stabilized.bytes == current.bytes, stabilized.bytes > 0 {
                    return FileCheckResult(
                        url: url,
                        exists: true,
                        bytes: stabilized.bytes,
                        isStable: true
                    )
                }
                lastObservedExists = stabilized.exists
                lastObservedSize = stabilized.bytes
            }

            Thread.sleep(forTimeInterval: configuration.pollInterval)
        }

        return FileCheckResult(
            url: url,
            exists: lastObservedExists,
            bytes: lastObservedSize,
            isStable: false
        )
    }

    private static func fileState(at url: URL, fileManager: FileManager) -> (exists: Bool, bytes: Int64) {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return (false, 0)
        }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return (true, bytes)
    }
}

struct SessionCanonicalMetadataSignature: Equatable {
    let sessionID: String
    let performerName: String?
    let scratchTypeID: String?
    let scratchTypeName: String?
    let drillMode: String?
    let captureMode: String
    let clickEnabled: Bool
    let beatEngineMode: String
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let engineVersion: String
    let countInBeats: Int
    let beatsPerBar: Int
    let clickAccentPattern: String
    let clickVersion: String
    let timingPrintedToRecording: String
    let handedness: String?
    let notes: String?

    init(config: CaptureSessionConfig) {
        sessionID = config.sessionID
        performerName = config.normalizedPerformerName
        scratchTypeID = config.normalizedScratchTypeID
        scratchTypeName = config.normalizedScratchTypeName
        drillMode = config.normalizedDrillMode
        captureMode = config.normalizedCaptureMode
        clickEnabled = config.clickEnabled
        beatEngineMode = config.normalizedBeatEngineMode
        beatEnabled = config.beatEnabled
        beatPatternName = config.normalizedBeatPatternName
        beatPatternVersion = config.beatPatternVersion
        swingAmount = config.swingAmount
        engineVersion = config.engineVersion
        countInBeats = config.countInBeats
        beatsPerBar = config.beatsPerBar
        clickAccentPattern = config.clickAccentPattern
        clickVersion = config.clickVersion
        timingPrintedToRecording = config.timingPrintedToRecording.rawValue
        handedness = config.normalizedHandedness
        notes = config.normalizedNotes
    }

    init(metadata: SessionExportMetadata) {
        sessionID = metadata.sessionID
        performerName = metadata.performerName
        scratchTypeID = metadata.scratchTypeID
        scratchTypeName = metadata.scratchTypeName
        drillMode = metadata.drillMode
        captureMode = metadata.captureMode
        clickEnabled = metadata.clickEnabled
        beatEngineMode = metadata.beatEngineMode
        beatEnabled = metadata.beatEnabled
        beatPatternName = metadata.beatPatternName
        beatPatternVersion = metadata.beatPatternVersion
        swingAmount = metadata.swingAmount
        engineVersion = metadata.engineVersion
        countInBeats = metadata.countInBeats
        beatsPerBar = metadata.beatsPerBar
        clickAccentPattern = metadata.clickAccentPattern
        clickVersion = metadata.clickVersion
        timingPrintedToRecording = metadata.timingPrintedToRecording
        handedness = metadata.handedness
        notes = metadata.notes
    }
}

enum SessionExportProbeValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }
}

enum SessionExportMetadataResolver {
    static func validatedSessionConfig(
        from sidecar: CaptureCore.LocalRecordingSidecar
    ) -> CaptureSessionConfig? {
        guard let sessionConfig = sidecar.sessionConfig,
              sessionConfig.sessionID == sidecar.sessionID else {
            return nil
        }
        return sessionConfig
    }

    static func sessionMatchedPreferredConfig(
        _ preferredConfig: CaptureSessionConfig?,
        sessionID: String
    ) -> CaptureSessionConfig? {
        guard let preferredConfig,
              preferredConfig.sessionID == sessionID else {
            return nil
        }
        return preferredConfig
    }

    static func mergedConfig(
        preferredConfig: CaptureSessionConfig?,
        seedSidecar: CaptureCore.LocalRecordingSidecar,
        sidecars: [CaptureCore.LocalRecordingSidecar],
        fallbackSessionID: String,
        createdAt: Date,
        updatedAt: Date,
        takeCount: Int,
        totalDurationSeconds: Double
    ) -> CaptureSessionConfig {
        let matchedPreferredConfig = sessionMatchedPreferredConfig(
            preferredConfig,
            sessionID: fallbackSessionID
        )
        let seedConfig = validatedSessionConfig(from: seedSidecar)
        let sidecarConfig = sidecars.compactMap(validatedSessionConfig(from:)).first

        var config = seedConfig
            ?? sidecarConfig
            ?? matchedPreferredConfig
            ?? CaptureSessionConfig.routineCapture(
                sessionID: fallbackSessionID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                takeCount: takeCount,
                takeDurationSeconds: totalDurationSeconds
            )
        config.sessionID = fallbackSessionID
        config.createdAt = createdAt
        config.updatedAt = updatedAt
        config.takeCount = takeCount
        config.takeDurationSeconds = totalDurationSeconds
        return config
    }

    static func metadataMatchesSidecars(
        _ metadata: SessionExportMetadata,
        sidecars: [CaptureCore.LocalRecordingSidecar]
    ) -> Bool {
        let metadataSignature = SessionCanonicalMetadataSignature(metadata: metadata)
        let sidecarSignatures = sidecars.compactMap { sidecar -> SessionCanonicalMetadataSignature? in
            guard let sessionConfig = validatedSessionConfig(from: sidecar) else { return nil }
            return SessionCanonicalMetadataSignature(config: sessionConfig)
        }

        guard !sidecarSignatures.isEmpty else { return true }
        return sidecarSignatures.allSatisfy { $0 == metadataSignature }
    }
}

enum SessionShareOutcome: Sendable {
    case completed
    case cancelled
    case failed
}

struct SessionShareRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let archiveURL: URL
    let subject: String
}

struct SessionValidationReport: Equatable, Sendable {
    let suggestedError: SessionExportError
    let issues: [String]

    var summaryText: String {
        issues.first ?? suggestedError.userMessage
    }
}

@MainActor
final class SessionExportCoordinator: ObservableObject {
    @Published private(set) var state: SessionExportState = .idle
    @Published private(set) var lastResult: SessionExportResult?
    @Published private(set) var statusMessage: String?
    @Published private(set) var sizeWarning: String?
    @Published private(set) var validationReport: SessionValidationReport?
    @Published var shareRequest: SessionShareRequest?

    private var cleanupWorkItem: DispatchWorkItem?
    private let archiveBuilder = SessionArchiveBuilder()
    private let journalRootDirectoryOverride: URL?
    #if os(macOS)
    private let archiveSaveDestinationProvider: @MainActor (String) -> URL?
    #endif

    #if os(macOS)
    init(
        journalRootDirectoryOverride: URL? = nil,
        archiveSaveDestinationProvider: @escaping @MainActor (String) -> URL? = SessionExportCoordinator.defaultArchiveSaveDestination
    ) {
        self.archiveSaveDestinationProvider = archiveSaveDestinationProvider
        self.journalRootDirectoryOverride = journalRootDirectoryOverride
        archiveBuilder.cleanupStaleExports()
    }
    #else
    init(journalRootDirectoryOverride: URL? = nil) {
        self.journalRootDirectoryOverride = journalRootDirectoryOverride
        archiveBuilder.cleanupStaleExports()
    }
    #endif

    var isPreparing: Bool {
        switch state {
        case .validating, .preparingArchive:
            return true
        default:
            return false
        }
    }

    func prepareShare(
        for source: SessionExportSource,
        options: SessionExportOptions = SessionExportOptions()
    ) {
        guard !isPreparing else { return }

        cleanupWorkItem?.cancel()
        archiveBuilder.cleanupStaleExports()
        shareRequest = nil
        sizeWarning = nil
        validationReport = nil
        state = .validating
        statusMessage = "Preparing session..."

        Task {
            do {
                let report = await Task.detached(priority: .userInitiated) {
                    SessionArchiveBuilder().validationReport(for: source)
                }.value
                if let report {
                    validationReport = report
                    recordValidationBlockIfNeeded(for: source, report: report)
                    handleFailure(report.suggestedError)
                    statusMessage = report.summaryText
                    return
                }

                let package = try await Task.detached(priority: .userInitiated) {
                    try SessionArchiveBuilder().preparePackage(from: source)
                }.value

                state = .preparingArchive
                statusMessage = "Creating ZIP archive..."

                let result = try await Task.detached(priority: .userInitiated) {
                    try SessionArchiveBuilder().createArchive(from: package, options: options)
                }.value

                lastResult = result
                validationReport = nil
                sizeWarning = result.archiveSizeBytes >= SessionArchiveBuilder.largeArchiveWarningThreshold
                    ? "This session may be too large for email. AirDrop or cloud upload is recommended."
                    : nil
                state = .readyToShare(result)
                statusMessage = "Ready to share"
                shareRequest = SessionShareRequest(archiveURL: result.archiveURL, subject: result.subject)
            } catch let exportError as SessionExportError {
                handleFailure(exportError)
            } catch {
                print("Session export failed: \(error)")
                handleFailure(.unableToCreateArchive)
            }
        }
    }

    #if os(macOS)
    func saveArchiveCopy(
        for source: SessionExportSource,
        options: SessionExportOptions = SessionExportOptions()
    ) {
        guard !isPreparing else { return }

        cleanupWorkItem?.cancel()
        archiveBuilder.cleanupStaleExports()
        shareRequest = nil
        sizeWarning = nil
        validationReport = nil
        state = .validating
        statusMessage = "Preparing session..."

        Task {
            do {
                let report = await Task.detached(priority: .userInitiated) {
                    SessionArchiveBuilder().validationReport(for: source)
                }.value
                if let report {
                    validationReport = report
                    recordValidationBlockIfNeeded(for: source, report: report)
                    handleFailure(report.suggestedError)
                    statusMessage = report.summaryText
                    return
                }

                let package = try await Task.detached(priority: .userInitiated) {
                    try SessionArchiveBuilder().preparePackage(from: source)
                }.value

                state = .preparingArchive
                statusMessage = "Creating ZIP archive..."

                let result = try await Task.detached(priority: .userInitiated) {
                    try SessionArchiveBuilder().createArchive(from: package, options: options)
                }.value

                statusMessage = "Choose save location"
                guard let destinationURL = archiveSaveDestinationProvider(result.displayName) else {
                    try? FileManager.default.removeItem(at: result.archiveURL)
                    state = lastResult.map(SessionExportState.cancelled) ?? .idle
                    statusMessage = "Save cancelled."
                    return
                }

                let savedURL = try await Task.detached(priority: .userInitiated) {
                    try Self.copyArchive(result.archiveURL, to: destinationURL)
                }.value
                if !Self.urlsMatchSameFileLocation(savedURL, result.archiveURL) {
                    try? FileManager.default.removeItem(at: result.archiveURL)
                }

                let savedResult = SessionExportResult(
                    archiveURL: savedURL,
                    archiveSizeBytes: result.archiveSizeBytes,
                    sessionName: result.sessionName,
                    createdAt: result.createdAt,
                    shouldCleanupAfterUse: false
                )
                lastResult = savedResult
                validationReport = nil
                sizeWarning = savedResult.archiveSizeBytes >= SessionArchiveBuilder.largeArchiveWarningThreshold
                    ? "This session may be too large for email. AirDrop or cloud upload is recommended."
                    : nil
                state = .shareCompleted(savedResult)
                statusMessage = "Export saved."
            } catch let exportError as SessionExportError {
                handleFailure(exportError)
            } catch {
                print("Session export save failed: \(error)")
                handleFailure(.unableToSaveArchive)
            }
        }
    }
    #endif

    func showFailure(_ error: SessionExportError) {
        validationReport = nil
        handleFailure(error)
    }

    func markSharePresented() {
        guard let lastResult else { return }
        state = .presentingShareSheet(lastResult)
        statusMessage = "Ready to share"
    }

    func handleShareOutcome(_ outcome: SessionShareOutcome) {
        shareRequest = nil

        switch outcome {
        case .completed:
            state = lastResult.map(SessionExportState.shareCompleted) ?? .shareCompleted(
                SessionExportResult(
                    archiveURL: FileManager.default.temporaryDirectory.appendingPathComponent("scratchlab.zip"),
                    archiveSizeBytes: 0,
                    sessionName: "ScratchLab Session",
                    createdAt: Date(),
                    shouldCleanupAfterUse: true
                )
            )
            statusMessage = "Export complete."
            scheduleCleanupIfNeeded(after: 120)
        case .cancelled:
            state = .cancelled(lastResult)
            statusMessage = "Share cancelled."
            scheduleCleanupIfNeeded(after: 120)
        case .failed:
            handleFailure(.unableToPresentShareOptions)
        }
    }

    #if os(macOS)
    func revealLastArchiveInFinder() {
        guard let archiveURL = lastResult?.archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
    }

    #if DEBUG
    func copyLastArchivePath() {
        guard let archivePath = lastResult?.archiveURL.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(archivePath, forType: .string)
    }
    #endif
    #endif

    private func handleFailure(_ error: SessionExportError) {
        if let lastResult {
            state = .failed(error)
            scheduleCleanupIfNeeded(after: 120)
            self.lastResult = lastResult
        } else {
            state = .failed(error)
        }
        switch error {
        case .unableToSaveArchive:
            statusMessage = "Export failed: \(error.userMessage)"
        default:
            statusMessage = validationReport?.summaryText ?? error.userMessage
        }
    }

    private func recordValidationBlockIfNeeded(for source: SessionExportSource, report: SessionValidationReport) {
        guard case .localRecordingSession(let lastRecordingURL, _, _) = source else { return }
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRecordingURL)
        guard let sidecar = try? SessionArchiveBuilder().decodeSidecarForAudit(at: sidecarURL) else { return }
        guard let storageKind = Self.storageKind(for: lastRecordingURL) else { return }
        try? CaptureJournalStore.appendValidationBlocked(
            storageKind: storageKind,
            sessionID: sidecar.sessionID,
            relatedFileNames: [lastRecordingURL.lastPathComponent, sidecarURL.lastPathComponent],
            issues: report.issues,
            rootDirectoryOverride: journalRootDirectoryOverride
        )
    }

    private static func storageKind(for recordingURL: URL) -> StagedCaptureStorageKind? {
        let path = recordingURL.path
        if path.contains("/CompanionCaptures/") {
            return .companion
        }
        if path.contains("/RoutineCaptures/") {
            return .routine
        }
        return nil
    }

    private func scheduleCleanupIfNeeded(after delay: TimeInterval) {
        guard let lastResult, lastResult.shouldCleanupAfterUse else { return }
        let archiveURL = lastResult.archiveURL

        cleanupWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        cleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    #if os(macOS)
    private static func defaultArchiveSaveDestination(suggestedFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Choose where to save the ScratchLab session ZIP."
        panel.nameFieldStringValue = suggestedFileName
        panel.prompt = "Save ZIP"
        panel.title = "Save Session ZIP"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    nonisolated static func securityScopedAccessURL(
        for destinationURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        // Avoid URL normalization here — iCloud Drive and network volume paths
        // can lose their sandbox security scope when resolved to a canonical form.
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        return destinationURL.deletingLastPathComponent()
    }

    nonisolated private static func copyArchive(_ sourceURL: URL, to destinationURL: URL) throws -> URL {
        final class CoordinatedCopyState {
            var error: Error?
        }

        let fileManager = FileManager.default
        do {
            if urlsMatchSameFileLocation(sourceURL, destinationURL) {
                return sourceURL
            }
            let securityScopedURL = securityScopedAccessURL(for: destinationURL, fileManager: fileManager)
            let startedAccess = securityScopedURL.startAccessingSecurityScopedResource()
            defer {
                if startedAccess {
                    securityScopedURL.stopAccessingSecurityScopedResource()
                }
            }
            var coordinationError: NSError?
            let coordinatedCopyState = CoordinatedCopyState()
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: destinationURL, options: [], error: &coordinationError) { coordinatedURL in
                do {
                    if fileManager.fileExists(atPath: coordinatedURL.path) {
                        try fileManager.removeItem(at: coordinatedURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: coordinatedURL)
                } catch {
                    coordinatedCopyState.error = error
                }
            }
            if coordinationError != nil || coordinatedCopyState.error != nil {
                // Fallback: try a direct copy without file coordination.
                // Some cloud filesystems (Google Drive, certain iCloud configurations)
                // fail NSFileCoordinator but succeed with a plain copyItem.
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    throw SessionExportError.unableToSaveArchive
                }
            }
            return destinationURL
        } catch {
            throw (error as? SessionExportError) ?? .unableToSaveArchive
        }
    }

    nonisolated private static func urlsMatchSameFileLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
    #endif
}

struct SessionArchiveBuilder: Sendable {
    static let largeArchiveWarningThreshold: Int64 = 20 * 1024 * 1024
    typealias ArtifactProbeOverride = @Sendable (_ source: String, _ fileURL: URL?, _ generatedData: Data?) throws -> [String: SessionExportProbeValue]

    private struct VideoProbeSummary: Sendable {
        let width: Int
        let height: Int
        let duration: Double
        let frameRate: Double?
        let codec: String?
    }

    private final class AsyncProbeBox<T: Sendable>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let artifactProbeOverride: ArtifactProbeOverride?

    init(artifactProbeOverride: ArtifactProbeOverride? = nil) {
        self.artifactProbeOverride = artifactProbeOverride
    }

    private struct CanonicalTakeLogRow {
        let bpm: Int
        let takeNumber: Int
        let rawCamA: String
        let rawCamB: String
        let rawAudio: String
        let rawWatch: String
        let verbalSlateUsed: Bool
        let syncClapUsed: Bool
        let notes: String
    }

    private struct CanonicalArtifactRecord: Codable {
        let path: String
        let bytes: Int64
        let sha256: String
        let probe: [String: SessionExportProbeValue]
    }

    private struct CanonicalTakeManifestRecord: Codable {
        let djName: String
        let date: String
        let scratchType: String
        let bpm: Int
        let takeNumber: Int
        let segmentCount: Int
        let cameraID: String
        let audioSource: String
        let watchSource: String
        let verbalSlateUsed: Bool
        let syncClapUsed: Bool
        let notes: String
        let stemAvailability: [String: String]
        let files: [String: String]
        let artifacts: [String: CanonicalArtifactRecord]

        enum CodingKeys: String, CodingKey {
            case djName = "dj_name"
            case date
            case scratchType = "scratch_type"
            case bpm
            case takeNumber = "take_number"
            case segmentCount = "segment_count"
            case cameraID = "camera_id"
            case audioSource = "audio_source"
            case watchSource = "watch_source"
            case verbalSlateUsed = "verbal_slate_used"
            case syncClapUsed = "sync_clap_used"
            case notes
            case stemAvailability = "stem_availability"
            case files
            case artifacts
        }
    }

    private struct CanonicalSessionManifest: Codable {
        let specVersion: String
        let djName: String
        let djToken: String
        let date: String
        let scratchType: String
        let allowedBPMs: [Int]
        let segmentCount: Int
        let verbalSlateRequired: Bool
        let syncClapRequired: Bool
        let sessionRoot: String
        let notes: String
        let takes: [CanonicalTakeManifestRecord]

        enum CodingKeys: String, CodingKey {
            case specVersion = "spec_version"
            case djName = "dj_name"
            case djToken = "dj_token"
            case date
            case scratchType = "scratch_type"
            case allowedBPMs = "allowed_bpms"
            case segmentCount = "segment_count"
            case verbalSlateRequired = "verbal_slate_required"
            case syncClapRequired = "sync_clap_required"
            case sessionRoot = "session_root"
            case notes
            case takes
        }
    }

    private struct CanonicalTakeContext {
        let take: SessionExportTake
        let sidecar: CaptureCore.LocalRecordingSidecar
        let canonicalBPM: Int
        let videoFileName: String
        let primaryAudioFileName: String
        let scratchOnlyRelativePath: String
        let beatOnlyFileName: String?
        let scratchWithBeatFileName: String?
        let stemAvailability: [String: String]
        let watchFileName: String?
        let notationFileName: String
        let notationDocument: SessionExportNotationDocument
        let captureMetadata: SessionExportTakeCaptureMetadata
        let verbalSlateUsed: Bool
        let syncClapUsed: Bool
        let notes: String
    }

    private struct CanonicalSessionContext {
        let manifest: CanonicalSessionManifest
        let takeLogRows: [CanonicalTakeLogRow]
        let takes: [CanonicalTakeContext]
        let sessionRootName: String
    }

    private struct ResolvedNotationExport {
        let fileName: String
        let relativePath: String
        let document: SessionExportNotationDocument
    }

    private struct ResolvedAudioStemExport {
        let scratchOnlyRelativePath: String
        let beatOnlyRelativePath: String?
        let scratchWithBeatRelativePath: String?
        let scratchOnlyAvailability: String
        let beatOnlyAvailability: String
        let scratchWithBeatAvailability: String
    }

    func preparePackage(from source: SessionExportSource) throws -> SessionExportPackage {
        switch source {
        case .package(let package):
            let hydratedPackage = hydratePackageForExport(package)
            if let report = packageValidationReport(for: hydratedPackage) {
                throw report.suggestedError
            }
            try validatePackageContents(hydratedPackage)
            return hydratedPackage
        case .localRecordingSession(let lastRecordingURL, let sessionName, let config):
            if let report = validationReport(
                for: .localRecordingSession(
                    lastRecordingURL: lastRecordingURL,
                    sessionName: sessionName,
                    config: config
                )
            ) {
                throw report.suggestedError
            }
            let package = try packageForLocalRecordingSession(
                lastRecordingURL: lastRecordingURL,
                sessionName: sessionName,
                config: config
            )
            try validatePackageContents(package)
            return package
        }
    }

    func validationReport(for source: SessionExportSource) -> SessionValidationReport? {
        switch source {
        case .package(let package):
            return packageValidationReport(for: hydratePackageForExport(package))
        case .localRecordingSession(let lastRecordingURL, _, let config):
            do {
                let sessionDirectory = lastRecordingURL.deletingLastPathComponent()
                let seedSidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRecordingURL)
                guard FileManager.default.fileExists(atPath: lastRecordingURL.path) else {
                    return SessionValidationReport(
                        suggestedError: .sessionFolderNotFound,
                        issues: [SessionExportError.sessionFolderNotFound.userMessage]
                    )
                }
                guard FileManager.default.fileExists(atPath: seedSidecarURL.path),
                      let seedSidecar = try? decodeSidecar(at: seedSidecarURL) else {
                    return SessionValidationReport(
                        suggestedError: .missingRequiredFiles,
                        issues: [SessionExportError.missingRequiredFiles.userMessage]
                    )
                }
                let localIssues = localRecordingBlockingIssues(
                    in: sessionDirectory,
                    seedSidecar: seedSidecar,
                    fileManager: FileManager.default
                )
                if !localIssues.isEmpty {
                    return SessionValidationReport(
                        suggestedError: .invalidSessionMetadata,
                        issues: localIssues
                    )
                }

                let package = try packageForLocalRecordingSession(
                    lastRecordingURL: lastRecordingURL,
                    sessionName: "",
                    config: config
                )
                let issues = packageValidationIssues(package)
                return issues.isEmpty ? nil : SessionValidationReport(
                    suggestedError: issues.contains(where: { $0.localizedCaseInsensitiveContains("missing") })
                        ? .missingRequiredFiles
                        : .invalidSessionMetadata,
                    issues: issues
                )
            } catch let error as SessionExportError {
                return SessionValidationReport(
                    suggestedError: error,
                    issues: [error.userMessage]
                )
            } catch {
                return SessionValidationReport(
                    suggestedError: .unableToPrepareExport,
                    issues: ["ScratchLab could not prepare this staged session for validation."]
                )
            }
        }
    }

    func createArchive(
        from package: SessionExportPackage,
        options: SessionExportOptions = SessionExportOptions(),
        in archiveDirectory: URL? = nil
    ) throws -> SessionExportResult {
        let fileManager = FileManager.default
        let archiveDirectory = try archiveDirectory ?? shareArchiveDirectoryURL(fileManager: fileManager)
        try validateArchiveDirectoryWritable(archiveDirectory, fileManager: fileManager)

        let canonicalContext = try canonicalContext(for: package)
        let folderName = canonicalContext.sessionRootName
        let stagingRoot = archiveDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let stagedSessionURL = stagingRoot.appendingPathComponent(folderName, isDirectory: true)
        let archiveURL = archiveDirectory
            .appendingPathComponent(folderName)
            .appendingPathExtension("zip")
        let signpostID = ScratchLabPerformanceSignpost.begin("ExportZIP")
        defer { ScratchLabPerformanceSignpost.end("ExportZIP", signpostID) }

        do {
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }

            try fileManager.createDirectory(at: stagedSessionURL, withIntermediateDirectories: true)
            try stagePackage(package, options: options, at: stagedSessionURL, fileManager: fileManager)
            try fileManager.zipItem(
                at: stagedSessionURL,
                to: archiveURL,
                shouldKeepParent: true,
                compressionMethod: .deflate
            )
            let archiveSize = try fileSize(for: archiveURL, fileManager: fileManager)
            return SessionExportResult(
                archiveURL: archiveURL,
                archiveSizeBytes: archiveSize,
                sessionName: package.metadata.sessionName,
                createdAt: package.metadata.createdAt,
                shouldCleanupAfterUse: true
            )
        } catch let exportError as SessionExportError {
            try? cleanupStagingRoot(stagingRoot, fileManager: fileManager)
            throw exportError
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            try? cleanupStagingRoot(stagingRoot, fileManager: fileManager)
            throw SessionExportError.unableToCreateArchive
        }
    }

    func canonicalPreview(for package: SessionExportPackage) throws -> (manifestData: Data, takeLogCSV: String) {
        let context = try canonicalContext(for: package)
        return (
            manifestData: try Self.jsonEncoder.encode(context.manifest),
            takeLogCSV: makeCanonicalTakeLogCSV(from: context.takeLogRows)
        )
    }

    func metadataDocument(for package: SessionExportPackage) throws -> SessionExportMetadataDocument {
        let hydratedPackage = hydratePackageForExport(package)
        let takes = try hydratedPackage.takes.map { take in
            try resolvedTakeCaptureMetadata(for: take, packageMetadata: hydratedPackage.metadata)
        }

        return SessionExportMetadataDocument(session: hydratedPackage.metadata, takes: takes)
    }

    func exportMetadataDocument(
        for package: SessionExportPackage,
        options: SessionExportOptions
    ) throws -> SessionExportArtifactMetadataDocument {
        let hydratedPackage = hydratePackageForExport(package)
        let artifactMetadata = try hydratedPackage.takes.map { take -> SessionExportArtifactMetadata in
            let captureMetadata = try resolvedTakeCaptureMetadata(for: take, packageMetadata: hydratedPackage.metadata)
            let sidecar = try decodeSidecar(at: take.sidecarURL)
            let notationExport = try resolvedNotationExport(
                for: take,
                sidecar: sidecar,
                packageMetadata: hydratedPackage.metadata
            )
            let djToken = try canonicalPerformerToken(from: hydratedPackage.metadata)
            let scratchTypeToken = try canonicalScratchTypeToken(from: hydratedPackage.metadata)
            let canonicalBPM = captureMetadata.bpm ?? take.bpm
            let canReadAudioStem = take.audioArtifactURL.flatMap { try? AVAudioFile(forReading: $0) } != nil
            let canRenderBeatStem = (captureMetadata.captureMode == CaptureSessionCaptureMode.timedClick.rawValue
                || captureMetadata.clickEnabled
                || captureMetadata.beatEnabled)
                && canReadAudioStem
            let audioStemExport = resolvedAudioStemExport(
                djToken: djToken,
                scratchTypeToken: scratchTypeToken,
                canonicalBPM: canonicalBPM,
                takeNumber: take.takeNumber,
                audioExtension: "wav",
                shouldRenderBeatStem: canRenderBeatStem
            )
            let timingPrintedState = TimingPrintedToRecordingState(
                rawValue: captureMetadata.timingPrintedToRecording
            ) ?? .unknown
            let captureQuality = captureQualityForExport(
                timingPrintedToRecording: timingPrintedState,
                mixMode: options.mixMode
            )
            let mixPaths = exportArtifactPaths(
                for: take,
                options: options
            )

            return SessionExportArtifactMetadata(
                takeID: captureMetadata.takeID,
                takeNumber: captureMetadata.takeNumber,
                bpm: captureMetadata.bpm,
                exportMixMode: options.mixMode.rawValue,
                captureQuality: captureQuality.rawValue,
                timingPrintedToRecording: captureMetadata.timingPrintedToRecording,
                captureMode: captureMetadata.captureMode,
                clickEnabled: captureMetadata.clickEnabled,
                beatEngineMode: captureMetadata.beatEngineMode,
                beatEnabled: captureMetadata.beatEnabled,
                beatPatternName: captureMetadata.beatPatternName,
                beatPatternVersion: captureMetadata.beatPatternVersion,
                swingAmount: captureMetadata.swingAmount,
                countInBeats: captureMetadata.countInBeats,
                beatsPerBar: captureMetadata.beatsPerBar,
                clickStartHostTime: captureMetadata.clickStartHostTime,
                recordingStartHostTime: captureMetadata.recordingStartHostTime,
                clickVersion: captureMetadata.clickVersion,
                engineVersion: captureMetadata.engineVersion,
                scratchOnlyFile: audioStemExport.scratchOnlyRelativePath,
                beatOnlyFile: audioStemExport.beatOnlyRelativePath,
                scratchWithBeatFile: audioStemExport.scratchWithBeatRelativePath,
                scratchOnlyAvailability: audioStemExport.scratchOnlyAvailability,
                beatOnlyAvailability: audioStemExport.beatOnlyAvailability,
                scratchWithBeatAvailability: audioStemExport.scratchWithBeatAvailability,
                scratchFile: mixPaths.scratchFile,
                timingFile: mixPaths.timingFile,
                rawTakeFile: mixPaths.rawTakeFile,
                notationFile: notationExport.relativePath,
                notationSource: notationExport.document.notationSource.rawValue,
                labelSource: notationExport.document.labelSource.rawValue,
                labelConfidence: notationExport.document.labelConfidence,
                notationConfidence: notationExport.document.notationConfidence
            )
        }

        let aggregateTimingPrintedToRecording: TimingPrintedToRecordingState
        if let firstTimingPrinted = artifactMetadata.first?.timingPrintedToRecording,
           artifactMetadata.dropFirst().allSatisfy({ $0.timingPrintedToRecording == firstTimingPrinted }) {
            aggregateTimingPrintedToRecording = TimingPrintedToRecordingState(rawValue: firstTimingPrinted) ?? .unknown
        } else {
            aggregateTimingPrintedToRecording = .unknown
        }
        let aggregateCaptureQuality = artifactMetadata.reduce(CaptureQuality.clean) { current, item in
            let next = CaptureQuality(rawValue: item.captureQuality) ?? .mixed
            switch (current, next) {
            case (.processed, _), (_, .processed):
                return .processed
            case (.mixed, _), (_, .mixed):
                return .mixed
            default:
                return .clean
            }
        }

        return SessionExportArtifactMetadataDocument(
            sessionID: hydratedPackage.metadata.sessionID,
            sessionName: hydratedPackage.metadata.sessionName,
            exportMixMode: options.mixMode.rawValue,
            captureQuality: aggregateCaptureQuality.rawValue,
            timingPrintedToRecording: aggregateTimingPrintedToRecording.rawValue,
            takes: artifactMetadata
        )
    }

    func cleanupStaleExports(olderThan age: TimeInterval = 86_400) {
        let fileManager = FileManager.default
        guard let archiveDirectory = try? shareArchiveDirectoryURL(fileManager: fileManager) else { return }
        let cutoffDate = Date().addingTimeInterval(-age)
        let contents = (try? fileManager.contentsOfDirectory(
            at: archiveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoffDate else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    func archiveURL(for metadata: SessionExportMetadata, in directory: URL) -> URL {
        directory
            .appendingPathComponent(archiveFolderName(for: metadata))
            .appendingPathExtension("zip")
    }

    private func packageForLocalRecordingSession(
        lastRecordingURL: URL,
        sessionName: String,
        config providedConfig: CaptureSessionConfig?
    ) throws -> SessionExportPackage {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: lastRecordingURL.path) else {
            throw SessionExportError.sessionFolderNotFound
        }

        let sessionDirectory = lastRecordingURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            throw SessionExportError.sessionFolderNotFound
        }

        let seedSidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRecordingURL)
        guard fileManager.fileExists(atPath: seedSidecarURL.path),
              let seedSidecar = try? decodeSidecar(at: seedSidecarURL) else {
            throw SessionExportError.missingRequiredFiles
        }

        let unresolvedIssues = localRecordingBlockingIssues(
            in: sessionDirectory,
            seedSidecar: seedSidecar,
            fileManager: fileManager
        )
        guard unresolvedIssues.isEmpty else {
            throw SessionExportError.invalidSessionMetadata
        }

        let takes = try matchingCompatibleLocalRecordingSidecarURLs(
            in: sessionDirectory,
            seedSidecar: seedSidecar,
            fileManager: fileManager
        )
            .compactMap { sidecarURL -> SessionExportTake? in
                guard let sidecar = try? decodeSidecar(at: sidecarURL),
                sidecar.recordingStatus == "completed" else {
                    return nil
                }

                let snapshot = localRecordingArtifactStatus(
                    for: sidecar,
                    sessionDirectory: sessionDirectory,
                    fileManager: fileManager,
                    preflightConfiguration: .exportDefault
                )
                guard snapshot.readiness == .ready,
                      let mediaURL = snapshot.videoSourceURL,
                      let audioArtifactURL = snapshot.audioSourceURL else {
                    return nil
                }

                let duration = max(
                    0,
                    (sidecar.endedAt ?? sidecar.startedAt).timeIntervalSince(sidecar.startedAt)
                )
                let linkedWatchCapture = self.resolveLinkedWatchCapture(for: sidecar)

                return SessionExportTake(
                    takeID: sidecar.takeID,
                    takeNumber: sidecar.appLocalTakeNumber,
                    bpm: SessionExportMetadataResolver.validatedSessionConfig(from: sidecar)?.bpm ?? 0,
                    mediaURL: mediaURL,
                    audioArtifactURL: audioArtifactURL,
                    sidecarURL: sidecarURL,
                    watchCaptureSession: linkedWatchCapture,
                    drillName: nil,
                    duration: duration,
                    quality: nil,
                    comboTagged: false,
                    audioPresent: true,
                    motionPresent: linkedWatchCapture != nil,
                    syncStatus: sidecar.watchSyncState.rawValue,
                    recordingStatus: sidecar.recordingStatus,
                    verbalSlateUsed: false,
                    syncClapUsed: false,
                    note: nil,
                    captureTiming: sidecar.captureTiming
                )
            }
            .sorted { $0.takeNumber < $1.takeNumber }

        guard !takes.isEmpty else {
            throw SessionExportError.missingRequiredFiles
        }

        let completedSidecars = takes.compactMap { try? decodeSidecar(at: $0.sidecarURL) }
        let earliestTakeDate = completedSidecars.map(\.startedAt).min() ?? seedSidecar.startedAt
        let latestTakeDate = completedSidecars.map { $0.endedAt ?? $0.startedAt }.max() ?? earliestTakeDate
        let totalDurationSeconds = takes.reduce(0) { $0 + $1.duration }
        let cleanSessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = SessionExportMetadataResolver.mergedConfig(
            preferredConfig: providedConfig,
            seedSidecar: seedSidecar,
            sidecars: completedSidecars,
            fallbackSessionID: seedSidecar.sessionID,
            createdAt: earliestTakeDate,
            updatedAt: latestTakeDate,
            takeCount: takes.count,
            totalDurationSeconds: totalDurationSeconds
        )
        let metadata = SessionExportMetadata(
            config: config,
            workflow: "routine_capture",
            platform: seedSidecar.platform,
            sessionName: cleanSessionName.isEmpty ? "Routine Capture" : cleanSessionName,
            totalDurationSeconds: totalDurationSeconds,
            deviceInfo: deviceInfo(from: seedSidecar)
        )

        return SessionExportPackage(metadata: metadata, takes: takes, calibrationData: nil)
    }

    private func validatePackageContents(_ package: SessionExportPackage) throws {
        _ = try canonicalContext(for: package)
    }

    private func shareArchiveDirectoryURL(fileManager: FileManager) throws -> URL {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let archiveDirectory = cachesDirectory.appendingPathComponent("ScratchLabSessionExports", isDirectory: true)
        do {
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            return archiveDirectory
        } catch {
            throw SessionExportError.unableToPrepareExport
        }
    }

    private func validateArchiveDirectoryWritable(_ archiveDirectory: URL, fileManager: FileManager) throws {
        let probeURL = archiveDirectory.appendingPathComponent(".write-test-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probeURL.path, contents: Data()) else {
            throw SessionExportError.unableToPrepareExport
        }
        try? fileManager.removeItem(at: probeURL)
    }

    private func stagePackage(
        _ package: SessionExportPackage,
        options: SessionExportOptions,
        at stagedSessionURL: URL,
        fileManager: FileManager
    ) throws {
        let context = try canonicalContext(for: package)
        try createCanonicalDirectorySkeleton(
            at: stagedSessionURL,
            allowedBPMs: context.manifest.allowedBPMs,
            fileManager: fileManager
        )

        for takeContext in context.takes {
            let videoURL = stagedSessionURL
                .appendingPathComponent("video", isDirectory: true)
                .appendingPathComponent(takeContext.videoFileName)
            let audioURL = stagedSessionURL
                .appendingPathComponent(takeContext.scratchOnlyRelativePath)
            let notationURL = stagedSessionURL
                .appendingPathComponent("notation", isDirectory: true)
                .appendingPathComponent(takeContext.notationFileName)
            try fileManager.copyItem(at: takeContext.take.mediaURL, to: videoURL)
            guard let audioArtifactURL = takeContext.take.audioArtifactURL else {
                throw SessionExportError.missingRequiredFiles
            }
            try fileManager.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: audioArtifactURL, to: audioURL)
            if takeContext.stemAvailability["beat_only"] == "available"
                || takeContext.stemAvailability["scratch_with_beat"] == "available" {
                let beatBuffer = try renderedBeatStemBuffer(
                    for: takeContext.take,
                    captureMetadata: takeContext.captureMetadata,
                    scratchAudioURL: audioArtifactURL
                )
                if let beatOnlyFileName = takeContext.beatOnlyFileName {
                    let beatOnlyURL = stagedSessionURL
                        .appendingPathComponent("audio", isDirectory: true)
                        .appendingPathComponent(beatOnlyFileName)
                    try writeAudioBuffer(beatBuffer, to: beatOnlyURL)
                }
                if let scratchWithBeatFileName = takeContext.scratchWithBeatFileName {
                    let scratchWithBeatURL = stagedSessionURL
                        .appendingPathComponent("audio", isDirectory: true)
                        .appendingPathComponent(scratchWithBeatFileName)
                    let mixedBuffer = try mixedScratchWithTimingBuffer(
                        scratchURL: audioArtifactURL,
                        timingBuffer: beatBuffer
                    )
                    try writeAudioBuffer(mixedBuffer, to: scratchWithBeatURL)
                }
            }
            let notationData = try Self.jsonEncoder.encode(takeContext.notationDocument)
            try notationData.write(to: notationURL, options: .atomic)

            if let watchFileName = takeContext.watchFileName,
               let watchCaptureSession = takeContext.take.watchCaptureSession {
                let watchURL = stagedSessionURL
                    .appendingPathComponent("watch", isDirectory: true)
                    .appendingPathComponent(watchFileName)
                let watchCSV = CaptureCanonicalFormatting.watchCSV(for: watchCaptureSession)
                try watchCSV.write(to: watchURL, atomically: true, encoding: .utf8)
            }
        }

        let manifestsURL = stagedSessionURL.appendingPathComponent("manifests", isDirectory: true)
        let manifestURL = manifestsURL.appendingPathComponent("session_manifest.json")
        let manifestData = try Self.jsonEncoder.encode(context.manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        let takeLogURL = manifestsURL.appendingPathComponent("take_log.csv")
        let takeLogCSV = makeCanonicalTakeLogCSV(from: context.takeLogRows)
        try takeLogCSV.write(to: takeLogURL, atomically: true, encoding: .utf8)

        let metadataDocumentURL = manifestsURL.appendingPathComponent("session_metadata.json")
        let metadataDocument = try metadataDocument(for: package)
        let metadataData = try Self.jsonEncoder.encode(metadataDocument)
        try metadataData.write(to: metadataDocumentURL, options: .atomic)

        let exportMetadataDocumentURL = manifestsURL.appendingPathComponent("export_metadata.json")
        let exportMetadataDocument = try exportMetadataDocument(for: package, options: options)
        let exportMetadataData = try Self.jsonEncoder.encode(exportMetadataDocument)
        try exportMetadataData.write(to: exportMetadataDocumentURL, options: .atomic)

        try stageExportMixArtifacts(
            package,
            options: options,
            at: stagedSessionURL,
            fileManager: fileManager
        )
    }

    private func makeCanonicalTakeLogCSV(from rows: [CanonicalTakeLogRow]) -> String {
        let header = CaptureCanonicalRules.takeLogColumns
        let body = rows.map { row in
            [
                csvField("\(row.bpm)"),
                csvField("\(row.takeNumber)"),
                csvField(row.rawCamA),
                csvField(row.rawCamB),
                csvField(row.rawAudio),
                csvField(row.rawWatch),
                csvField(row.verbalSlateUsed ? "true" : "false"),
                csvField(row.syncClapUsed ? "true" : "false"),
                csvField(row.notes)
            ]
            .joined(separator: ",")
        }

        return ([header.joined(separator: ",")] + body).joined(separator: "\n")
    }

    func decodeSidecarForAudit(at url: URL) throws -> CaptureCore.LocalRecordingSidecar {
        try decodeSidecar(at: url)
    }

    private func decodeSidecar(at url: URL) throws -> CaptureCore.LocalRecordingSidecar {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)
    }

    private struct ExportArtifactPaths {
        let scratchFile: String?
        let timingFile: String?
        let rawTakeFile: String?
    }

    private struct ResolvedTakeCaptureValues {
        let bpm: Int?
        let canonicalBPM: Int?
        let captureMode: String
        let clickEnabled: Bool
        let beatEngineMode: String
        let beatEnabled: Bool
        let beatPatternName: String?
        let beatPatternVersion: String
        let swingAmount: Double
        let engineVersion: String
        let countInBeats: Int
        let beatsPerBar: Int
        let clickAccentPattern: String
        let clickVersion: String
        let timingPrintedToRecording: String
        let clickStartHostTime: UInt64?
        let recordingStartHostTime: UInt64?
    }

    private func resolvedTakeCaptureValues(
        for take: SessionExportTake,
        sidecar: CaptureCore.LocalRecordingSidecar,
        packageMetadata: SessionExportMetadata
    ) -> ResolvedTakeCaptureValues {
        let config = SessionExportMetadataResolver.validatedSessionConfig(from: sidecar)
        let captureMode = config?.captureMode.rawValue ?? packageMetadata.captureMode
        let metadataBPM = config?.bpm ?? packageMetadata.bpm
        let canonicalBPM: Int?
        if let metadataBPM {
            canonicalBPM = metadataBPM
        } else if CaptureClickTrackDefaults.supportedBPMRange.contains(take.bpm) {
            canonicalBPM = take.bpm
        } else if captureMode == CaptureSessionCaptureMode.calibrationNoClick.rawValue {
            canonicalBPM = CaptureClickTrackDefaults.defaultTimedBPM
        } else {
            canonicalBPM = nil
        }
        let captureTiming = take.captureTiming ?? sidecar.captureTiming

        return ResolvedTakeCaptureValues(
            bpm: metadataBPM,
            canonicalBPM: canonicalBPM,
            captureMode: captureMode,
            clickEnabled: config?.clickEnabled ?? packageMetadata.clickEnabled,
            beatEngineMode: config?.normalizedBeatEngineMode ?? packageMetadata.beatEngineMode,
            beatEnabled: config?.beatEnabled ?? packageMetadata.beatEnabled,
            beatPatternName: config?.normalizedBeatPatternName ?? packageMetadata.beatPatternName,
            beatPatternVersion: config?.beatPatternVersion ?? packageMetadata.beatPatternVersion,
            swingAmount: config?.swingAmount ?? packageMetadata.swingAmount,
            engineVersion: config?.engineVersion ?? packageMetadata.engineVersion,
            countInBeats: config?.countInBeats ?? packageMetadata.countInBeats,
            beatsPerBar: config?.beatsPerBar ?? packageMetadata.beatsPerBar,
            clickAccentPattern: config?.clickAccentPattern ?? packageMetadata.clickAccentPattern,
            clickVersion: config?.clickVersion ?? packageMetadata.clickVersion,
            timingPrintedToRecording: config?.timingPrintedToRecording.rawValue ?? packageMetadata.timingPrintedToRecording,
            clickStartHostTime: captureTiming?.clickStartHostTime,
            recordingStartHostTime: captureTiming?.recordingStartHostTime
        )
    }

    private func resolvedTakeCaptureMetadata(
        for take: SessionExportTake,
        packageMetadata: SessionExportMetadata
    ) throws -> SessionExportTakeCaptureMetadata {
        let sidecar = try decodeSidecar(at: take.sidecarURL)
        let captureValues = resolvedTakeCaptureValues(
            for: take,
            sidecar: sidecar,
            packageMetadata: packageMetadata
        )
        let notationExport = try resolvedNotationExport(
            for: take,
            sidecar: sidecar,
            packageMetadata: packageMetadata
        )

        return SessionExportTakeCaptureMetadata(
            takeID: take.takeID,
            takeNumber: take.takeNumber,
            bpm: captureValues.bpm,
            captureMode: captureValues.captureMode,
            clickEnabled: captureValues.clickEnabled,
            beatEngineMode: captureValues.beatEngineMode,
            beatEnabled: captureValues.beatEnabled,
            beatPatternName: captureValues.beatPatternName,
            beatPatternVersion: captureValues.beatPatternVersion,
            swingAmount: captureValues.swingAmount,
            engineVersion: captureValues.engineVersion,
            countInBeats: captureValues.countInBeats,
            beatsPerBar: captureValues.beatsPerBar,
            clickStartHostTime: captureValues.clickStartHostTime,
            recordingStartHostTime: captureValues.recordingStartHostTime,
            clickAccentPattern: captureValues.clickAccentPattern,
            clickVersion: captureValues.clickVersion,
            timingPrintedToRecording: captureValues.timingPrintedToRecording,
            notationFile: notationExport.relativePath,
            notationSource: notationExport.document.notationSource.rawValue,
            labelSource: notationExport.document.labelSource.rawValue,
            labelConfidence: notationExport.document.labelConfidence,
            notationConfidence: notationExport.document.notationConfidence
        )
    }

    private func notationFileName(for takeNumber: Int) -> String {
        "take-\(String(format: "%03d", takeNumber))_detected_notation.json"
    }

    private func resolvedNotationExport(
        for take: SessionExportTake,
        sidecar: CaptureCore.LocalRecordingSidecar,
        packageMetadata: SessionExportMetadata
    ) throws -> ResolvedNotationExport {
        let captureValues = resolvedTakeCaptureValues(
            for: take,
            sidecar: sidecar,
            packageMetadata: packageMetadata
        )
        let fileName = notationFileName(for: take.takeNumber)
        let relativePath = "notation/\(fileName)"
        let scratchType = {
            let normalizedID = packageMetadata.scratchTypeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedID.isEmpty {
                return normalizedID
            }
            let normalizedName = packageMetadata.scratchTypeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalizedName.isEmpty {
                return normalizedName
            }
            return "unknown"
        }()
        let reviewDecision = sidecar.reviewDecision
        let labelSource: SessionExportLabelSource
        switch reviewDecision?.status {
        case .accepted:
            labelSource = reviewDecision?.detectedLabel == nil ? .manual : .detected
        case .corrected:
            labelSource = .corrected
        case .unknown:
            labelSource = .unknown
        case nil:
            if sidecar.detectedNotation?.labelSource == SessionExportLabelSource.detected.rawValue {
                labelSource = .detected
            } else {
                labelSource = .unknown
            }
        }

        let detectedNotation = sidecar.detectedNotation
        let detectedMovementEvents = (detectedNotation?.recordMovementEvents ?? []).map {
            SessionExportRecordMovementEvent(
                direction: $0.direction,
                startTime: $0.startTime,
                endTime: $0.endTime,
                startPosition: $0.startPosition,
                endPosition: $0.endPosition,
                movementKind: $0.movementKind.rawValue,
                speed: $0.speed,
                confidence: $0.confidence,
                source: $0.source
            )
        }
        let notationSource: SessionExportNotationSource = detectedMovementEvents.isEmpty ? .unavailable : .detected
        let beatGrid = captureValues.bpm.map {
            SessionExportNotationBeatGrid(
                bpm: $0,
                beatsPerBar: captureValues.beatsPerBar,
                countInBeats: captureValues.countInBeats
            )
        }
        let labelConfidence = reviewDecision?.confidence ?? detectedNotation?.labelConfidence
        let notes = detectedMovementEvents.isEmpty
            ? "No notation events detected"
            : (take.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? take.note!
                : "")

        let notationDocument = SessionExportNotationDocument(
            sessionID: sidecar.sessionID,
            takeID: sidecar.takeID,
            takeNumber: take.takeNumber,
            scratchType: scratchType,
            bpm: captureValues.bpm,
            captureMode: captureValues.captureMode,
            notationSource: notationSource,
            labelSource: labelSource,
            labelConfidence: labelConfidence,
            notationConfidence: notationSource == .detected ? detectedNotation?.notationConfidence : nil,
            recordMovementEvents: detectedMovementEvents,
            faderEvents: [],
            mixerMidiEvents: [],
            beatGrid: beatGrid,
            notes: notes
        )
        return ResolvedNotationExport(
            fileName: fileName,
            relativePath: relativePath,
            document: notationDocument
        )
    }

    private func resolvedAudioStemExport(
        djToken: String,
        scratchTypeToken: String,
        canonicalBPM: Int,
        takeNumber: Int,
        audioExtension: String,
        shouldRenderBeatStem: Bool
    ) -> ResolvedAudioStemExport {
        let primaryAudioFileName = CaptureCanonicalFormatting.standardFileName(
            djToken: djToken,
            scratchTypeToken: scratchTypeToken,
            bpm: canonicalBPM,
            takeNumber: takeNumber,
            source: "scratch_only",
            fileExtension: audioExtension
        )
        let beatOnlyRelativePath: String?
        let scratchWithBeatRelativePath: String?
        if shouldRenderBeatStem {
            let beatOnlyFileName = CaptureCanonicalFormatting.standardFileName(
                djToken: djToken,
                scratchTypeToken: scratchTypeToken,
                bpm: canonicalBPM,
                takeNumber: takeNumber,
                source: "beat_only",
                fileExtension: audioExtension
            )
            let scratchWithBeatFileName = CaptureCanonicalFormatting.standardFileName(
                djToken: djToken,
                scratchTypeToken: scratchTypeToken,
                bpm: canonicalBPM,
                takeNumber: takeNumber,
                source: "scratch_with_beat",
                fileExtension: audioExtension
            )
            beatOnlyRelativePath = "audio/\(beatOnlyFileName)"
            scratchWithBeatRelativePath = "audio/\(scratchWithBeatFileName)"
        } else {
            beatOnlyRelativePath = nil
            scratchWithBeatRelativePath = nil
        }

        return ResolvedAudioStemExport(
            scratchOnlyRelativePath: "audio/\(primaryAudioFileName)",
            beatOnlyRelativePath: beatOnlyRelativePath,
            scratchWithBeatRelativePath: scratchWithBeatRelativePath,
            scratchOnlyAvailability: "available",
            beatOnlyAvailability: shouldRenderBeatStem ? "available" : "unavailable",
            scratchWithBeatAvailability: shouldRenderBeatStem ? "available" : "unavailable"
        )
    }

    private func canonicalPerformerToken(from metadata: SessionExportMetadata) throws -> String {
        guard let performerName = metadata.performerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !performerName.isEmpty,
              let djToken = CaptureCanonicalFormatting.sanitizeDJToken(performerName) else {
            throw SessionExportError.invalidSessionMetadata
        }
        return djToken
    }

    private func canonicalScratchTypeToken(from metadata: SessionExportMetadata) throws -> String {
        guard let token = CaptureCanonicalFormatting.exportScratchTypeToken(
            scratchTypeID: metadata.scratchTypeID,
            scratchTypeName: metadata.scratchTypeName,
            workflow: metadata.workflow
        ) else {
            throw SessionExportError.invalidSessionMetadata
        }
        return token
    }

    private func renderedBeatStemBuffer(
        for take: SessionExportTake,
        captureMetadata: SessionExportTakeCaptureMetadata,
        scratchAudioURL: URL
    ) throws -> AVAudioPCMBuffer {
        let scratchAudioFile = try AVAudioFile(forReading: scratchAudioURL)
        let scratchFormat = scratchAudioFile.processingFormat
        return try ScratchLabBeatEngine.renderedTimingBuffer(
            mode: BeatEngineMode(rawValue: captureMetadata.beatEngineMode) ?? .silent,
            bpm: captureMetadata.bpm ?? CaptureClickTrackDefaults.defaultTimedBPM,
            durationSeconds: max(0, take.duration),
            countInBeats: captureMetadata.countInBeats,
            beatsPerBar: captureMetadata.beatsPerBar,
            clickStartHostTime: captureMetadata.clickStartHostTime,
            recordingStartHostTime: captureMetadata.recordingStartHostTime,
            sampleRate: scratchFormat.sampleRate,
            channelCount: scratchFormat.channelCount
        )
    }

    private func generatedAudioArtifactRecord(
        source: String,
        buffer: AVAudioPCMBuffer,
        stagedURL: URL,
        fileManager: FileManager
    ) throws -> CanonicalArtifactRecord {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ScratchLabStemArtifacts", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try writeAudioBuffer(buffer, to: temporaryURL)
        return try artifactRecord(
            source: source,
            fileURL: temporaryURL,
            stagedURL: stagedURL
        )
    }

    private func stageExportMixArtifacts(
        _ package: SessionExportPackage,
        options: SessionExportOptions,
        at stagedSessionURL: URL,
        fileManager: FileManager
    ) throws {
        guard options.mixMode != .scratchOnly else { return }

        for take in package.takes {
            guard let scratchAudioURL = take.audioArtifactURL else {
                throw SessionExportError.missingRequiredFiles
            }

            let sidecar = try decodeSidecar(at: take.sidecarURL)
            let captureMetadata = try resolvedTakeCaptureMetadata(for: take, packageMetadata: package.metadata)
            let captureValues = resolvedTakeCaptureValues(
                for: take,
                sidecar: sidecar,
                packageMetadata: package.metadata
            )
            let artifactPaths = exportArtifactPaths(for: take, options: options)
            let scratchAudioFile = try AVAudioFile(forReading: scratchAudioURL)
            let scratchFormat = scratchAudioFile.processingFormat

            let timingBuffer = try ScratchLabBeatEngine.renderedTimingBuffer(
                mode: BeatEngineMode(rawValue: captureMetadata.beatEngineMode) ?? .silent,
                bpm: captureValues.canonicalBPM ?? CaptureClickTrackDefaults.defaultTimedBPM,
                durationSeconds: max(0, take.duration),
                countInBeats: captureMetadata.countInBeats,
                beatsPerBar: captureMetadata.beatsPerBar,
                clickStartHostTime: captureMetadata.clickStartHostTime,
                recordingStartHostTime: captureMetadata.recordingStartHostTime,
                sampleRate: scratchFormat.sampleRate,
                channelCount: scratchFormat.channelCount
            )

            if let timingFile = artifactPaths.timingFile {
                let timingURL = stagedSessionURL.appendingPathComponent(timingFile)
                try fileManager.createDirectory(
                    at: timingURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeAudioBuffer(timingBuffer, to: timingURL)
            }

            switch options.mixMode {
            case .scratchOnly:
                break
            case .scratchWithTiming:
                if let scratchFile = artifactPaths.scratchFile {
                    let scratchURL = stagedSessionURL.appendingPathComponent(scratchFile)
                    try fileManager.createDirectory(
                        at: scratchURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let mixedBuffer = try mixedScratchWithTimingBuffer(
                        scratchURL: scratchAudioURL,
                        timingBuffer: timingBuffer
                    )
                    try writeAudioBuffer(mixedBuffer, to: scratchURL)
                }
                if let rawTakeFile = artifactPaths.rawTakeFile {
                    let rawTakeURL = stagedSessionURL.appendingPathComponent(rawTakeFile)
                    try fileManager.createDirectory(
                        at: rawTakeURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: rawTakeURL.path) {
                        try fileManager.removeItem(at: rawTakeURL)
                    }
                    try fileManager.copyItem(at: scratchAudioURL, to: rawTakeURL)
                }
            case .timingOnly:
                break
            case .stemsFolder:
                if let scratchFile = artifactPaths.scratchFile {
                    let scratchURL = stagedSessionURL.appendingPathComponent(scratchFile)
                    try fileManager.createDirectory(
                        at: scratchURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: scratchURL.path) {
                        try fileManager.removeItem(at: scratchURL)
                    }
                    try fileManager.copyItem(at: scratchAudioURL, to: scratchURL)
                }
            }
        }
    }

    private func exportArtifactPaths(
        for take: SessionExportTake,
        options: SessionExportOptions
    ) -> ExportArtifactPaths {
        let takeFolder = "take_\(CaptureCore.LocalRecordingNaming.paddedTakeNumber(take.takeNumber))"
        switch options.mixMode {
        case .scratchOnly:
            return ExportArtifactPaths(scratchFile: nil, timingFile: nil, rawTakeFile: nil)
        case .scratchWithTiming:
            let baseFolder = "mixes/\(takeFolder)"
            return ExportArtifactPaths(
                scratchFile: "\(baseFolder)/scratch.wav",
                timingFile: "\(baseFolder)/timing.wav",
                rawTakeFile: "\(baseFolder)/raw_take.wav"
            )
        case .timingOnly:
            return ExportArtifactPaths(
                scratchFile: nil,
                timingFile: "mixes/\(takeFolder)/timing.wav",
                rawTakeFile: nil
            )
        case .stemsFolder:
            let baseFolder = "stems/\(takeFolder)"
            return ExportArtifactPaths(
                scratchFile: "\(baseFolder)/scratch.wav",
                timingFile: "\(baseFolder)/timing.wav",
                rawTakeFile: nil
            )
        }
    }

    private func captureQualityForExport(
        timingPrintedToRecording: TimingPrintedToRecordingState,
        mixMode: ExportMixMode
    ) -> CaptureQuality {
        switch mixMode {
        case .scratchOnly, .stemsFolder:
            return timingPrintedToRecording == .notPrinted ? .clean : .mixed
        case .scratchWithTiming, .timingOnly:
            return .processed
        }
    }

    private func mixedScratchWithTimingBuffer(
        scratchURL: URL,
        timingBuffer: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        let scratchFile = try AVAudioFile(forReading: scratchURL)
        let scratchFormat = scratchFile.processingFormat
        guard let scratchBuffer = AVAudioPCMBuffer(
            pcmFormat: scratchFormat,
            frameCapacity: AVAudioFrameCount(scratchFile.length)
        ) else {
            throw SessionExportError.unableToPrepareExport
        }
        try scratchFile.read(into: scratchBuffer)

        guard let mixedBuffer = AVAudioPCMBuffer(
            pcmFormat: scratchFormat,
            frameCapacity: max(scratchBuffer.frameCapacity, timingBuffer.frameCapacity)
        ),
        let mixedChannels = mixedBuffer.floatChannelData,
        let scratchChannels = scratchBuffer.floatChannelData,
        let timingChannels = timingBuffer.floatChannelData else {
            throw SessionExportError.unableToPrepareExport
        }

        let frameCount = max(Int(scratchBuffer.frameLength), Int(timingBuffer.frameLength))
        mixedBuffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(scratchFormat.channelCount) {
            mixedChannels[channel].initialize(repeating: 0, count: frameCount)
        }

        for frame in 0..<frameCount {
            for channel in 0..<Int(scratchFormat.channelCount) {
                let scratchSample = frame < Int(scratchBuffer.frameLength)
                    ? scratchChannels[channel][frame]
                    : 0
                let timingSample = frame < Int(timingBuffer.frameLength)
                    ? timingChannels[min(channel, Int(timingBuffer.format.channelCount) - 1)][frame]
                    : 0
                mixedChannels[channel][frame] = max(
                    -1,
                    min(1, scratchSample + (timingSample * 0.55))
                )
            }
        }

        return mixedBuffer
    }

    private func writeAudioBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func deviceInfo(from sidecar: CaptureCore.LocalRecordingSidecar) -> SessionExportDeviceInfo {
        SessionExportDeviceInfo(
            sourceDeviceName: sidecar.sourceDeviceName,
            appSurface: sidecar.appSurface,
            cameraPosition: sidecar.cameraPosition,
            audioInputName: sidecar.audioInputName,
            videoDeviceUniqueID: sidecar.videoDeviceUniqueID,
            videoDeviceName: sidecar.videoDeviceName,
            audioDeviceUniqueID: sidecar.audioDeviceUniqueID,
            audioDeviceName: sidecar.audioDeviceName
        )
    }

    func matchingLocalRecordingSidecarURLs(
        in sessionDirectory: URL,
        seedSessionID: String,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .filter {
            CaptureCore.LocalRecordingNaming.appLocalTakeNumber(
                for: $0.deletingPathExtension().lastPathComponent,
                sessionID: seedSessionID
            ) != nil
        }
        .sorted { lhs, rhs in
            let lhsTakeNumber = CaptureCore.LocalRecordingNaming.appLocalTakeNumber(
                for: lhs.deletingPathExtension().lastPathComponent,
                sessionID: seedSessionID
            ) ?? Int.max
            let rhsTakeNumber = CaptureCore.LocalRecordingNaming.appLocalTakeNumber(
                for: rhs.deletingPathExtension().lastPathComponent,
                sessionID: seedSessionID
            ) ?? Int.max
            if lhsTakeNumber == rhsTakeNumber {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsTakeNumber < rhsTakeNumber
        }
    }

    func localRecordingArtifactStatuses(
        lastRecordingURL: URL,
        fileManager: FileManager = .default,
        preflightConfiguration: ArtifactPreflight.Configuration = .exportDefault
    ) -> [TakeArtifactStatusSnapshot] {
        let sessionDirectory = lastRecordingURL.deletingLastPathComponent()
        let seedSidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRecordingURL)
        guard fileManager.fileExists(atPath: seedSidecarURL.path),
              let seedSidecar = try? decodeSidecar(at: seedSidecarURL) else {
            return []
        }

        let sidecarURLs = (try? matchingCompatibleLocalRecordingSidecarURLs(
            in: sessionDirectory,
            seedSidecar: seedSidecar,
            fileManager: fileManager
        )) ?? []

        return sidecarURLs.compactMap { sidecarURL in
            guard let sidecar = try? decodeSidecar(at: sidecarURL) else { return nil }
            return localRecordingArtifactStatus(
                for: sidecar,
                sessionDirectory: sessionDirectory,
                fileManager: fileManager,
                preflightConfiguration: preflightConfiguration
            )
        }
    }

    private func localRecordingBlockingIssues(
        in sessionDirectory: URL,
        seedSidecar: CaptureCore.LocalRecordingSidecar,
        fileManager: FileManager,
        preflightConfiguration: ArtifactPreflight.Configuration = .exportDefault
    ) -> [String] {
        let sidecarURLs = (try? matchingCompatibleLocalRecordingSidecarURLs(
            in: sessionDirectory,
            seedSidecar: seedSidecar,
            fileManager: fileManager
        )) ?? []

        return sidecarURLs.compactMap { sidecarURL in
            guard let sidecar = try? decodeSidecar(at: sidecarURL) else {
                return "ScratchLab could not read \(sidecarURL.lastPathComponent)."
            }
            let snapshot = localRecordingArtifactStatus(
                for: sidecar,
                sessionDirectory: sessionDirectory,
                fileManager: fileManager,
                preflightConfiguration: preflightConfiguration
            )
            return issueMessage(for: snapshot)
        }
    }

    private func localRecordingArtifactStatus(
        for sidecar: CaptureCore.LocalRecordingSidecar,
        sessionDirectory: URL,
        fileManager: FileManager,
        preflightConfiguration: ArtifactPreflight.Configuration
    ) -> TakeArtifactStatusSnapshot {
        let mediaURL = sessionDirectory.appendingPathComponent(sidecar.mediaFileName)
        let audioURL = sessionDirectory
            .appendingPathComponent(mediaURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")
        let bpm = SessionExportMetadataResolver.validatedSessionConfig(from: sidecar)?.bpm
        let detectedLabel = sidecar.reviewDecision?.detectedLabel
            ?? sidecar.detectedNotation?.detectedLabel
            ?? sidecar.reviewDecision?.label
        let labelConfidence = sidecar.reviewDecision?.confidence ?? sidecar.detectedNotation?.labelConfidence

        if sidecar.recordingStatus == "recording" {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: fileManager.fileExists(atPath: audioURL.path),
                videoExists: fileManager.fileExists(atPath: mediaURL.path),
                audioBytes: (try? fileSize(for: audioURL, fileManager: fileManager)) ?? 0,
                videoBytes: (try? fileSize(for: mediaURL, fileManager: fileManager)) ?? 0,
                finalizedAt: sidecar.endedAt,
                readiness: .recording,
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }

        if sidecar.recordingStatus != "completed" {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: fileManager.fileExists(atPath: audioURL.path),
                videoExists: fileManager.fileExists(atPath: mediaURL.path),
                audioBytes: (try? fileSize(for: audioURL, fileManager: fileManager)) ?? 0,
                videoBytes: (try? fileSize(for: mediaURL, fileManager: fileManager)) ?? 0,
                finalizedAt: sidecar.endedAt,
                readiness: .failed(sidecar.errorDescription ?? "Capture did not complete."),
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }

        let videoCheck = ArtifactPreflight.checkFileReady(
            url: mediaURL,
            fileManager: fileManager,
            configuration: preflightConfiguration
        )
        guard videoCheck.exists else {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: fileManager.fileExists(atPath: audioURL.path),
                videoExists: false,
                audioBytes: (try? fileSize(for: audioURL, fileManager: fileManager)) ?? 0,
                videoBytes: 0,
                finalizedAt: sidecar.endedAt,
                readiness: .missingVideo,
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }
        guard videoCheck.isStable else {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: fileManager.fileExists(atPath: audioURL.path),
                videoExists: true,
                audioBytes: (try? fileSize(for: audioURL, fileManager: fileManager)) ?? 0,
                videoBytes: videoCheck.bytes,
                finalizedAt: sidecar.endedAt,
                readiness: .finalizing,
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }

        if !fileManager.fileExists(atPath: audioURL.path) {
            do {
                _ = try derivedAudioArtifactURL(
                    for: mediaURL,
                    in: sessionDirectory,
                    fileManager: fileManager
                )
            } catch {
                return TakeArtifactStatusSnapshot(
                    takeID: sidecar.takeID,
                    takeNumber: sidecar.appLocalTakeNumber,
                    bpm: bpm,
                    audioSourceURL: audioURL,
                    videoSourceURL: mediaURL,
                    audioExists: false,
                    videoExists: true,
                    audioBytes: 0,
                    videoBytes: videoCheck.bytes,
                    finalizedAt: sidecar.endedAt,
                    readiness: .missingAudio,
                    detectedNotation: sidecar.detectedNotation,
                    detectedLabel: detectedLabel,
                    labelConfidence: labelConfidence
                )
            }
        }

        let audioCheck = ArtifactPreflight.checkFileReady(
            url: audioURL,
            fileManager: fileManager,
            configuration: preflightConfiguration
        )
        if !audioCheck.exists || audioCheck.bytes <= 0 {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: audioCheck.exists,
                videoExists: true,
                audioBytes: audioCheck.bytes,
                videoBytes: videoCheck.bytes,
                finalizedAt: sidecar.endedAt,
                readiness: .missingAudio,
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }
        guard audioCheck.isStable else {
            return TakeArtifactStatusSnapshot(
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                bpm: bpm,
                audioSourceURL: audioURL,
                videoSourceURL: mediaURL,
                audioExists: true,
                videoExists: true,
                audioBytes: audioCheck.bytes,
                videoBytes: videoCheck.bytes,
                finalizedAt: sidecar.endedAt,
                readiness: .finalizing,
                detectedNotation: sidecar.detectedNotation,
                detectedLabel: detectedLabel,
                labelConfidence: labelConfidence
            )
        }

        return TakeArtifactStatusSnapshot(
            takeID: sidecar.takeID,
            takeNumber: sidecar.appLocalTakeNumber,
            bpm: bpm,
            audioSourceURL: audioURL,
            videoSourceURL: mediaURL,
            audioExists: true,
            videoExists: true,
            audioBytes: audioCheck.bytes,
            videoBytes: videoCheck.bytes,
            finalizedAt: sidecar.endedAt,
            readiness: .ready,
            detectedNotation: sidecar.detectedNotation,
            detectedLabel: detectedLabel,
            labelConfidence: labelConfidence
        )
    }

    private func issueMessage(for snapshot: TakeArtifactStatusSnapshot) -> String? {
        let takeLabel = formattedTakeLabel(snapshot.takeNumber)
        switch snapshot.readiness {
        case .recording, .finalizing:
            return "\(takeLabel) audio is still finalizing. Try again in a moment."
        case .missingAudio:
            return "\(takeLabel) audio is missing. Retake it before export."
        case .missingVideo:
            return "\(takeLabel) video is missing. Retake it before export."
        case .failed(let message):
            return "\(takeLabel) failed: \(message)"
        case .ready:
            return nil
        }
    }

    private func formattedTakeLabel(_ takeNumber: Int) -> String {
        "Take \(String(format: "%03d", takeNumber))"
    }

    private func matchingCompatibleLocalRecordingSidecarURLs(
        in sessionDirectory: URL,
        seedSidecar: CaptureCore.LocalRecordingSidecar,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let sidecarURLs = try matchingLocalRecordingSidecarURLs(
            in: sessionDirectory,
            seedSessionID: seedSidecar.sessionID,
            fileManager: fileManager
        )
        guard let seedSignature = metadataSignature(for: seedSidecar) else {
            return sidecarURLs
        }

        return sidecarURLs.filter { sidecarURL in
            guard let sidecar = try? decodeSidecar(at: sidecarURL),
                  let sidecarSignature = metadataSignature(for: sidecar) else {
                return false
            }
            return sidecarSignature == seedSignature
        }
    }

    private func metadataSignature(
        for sidecar: CaptureCore.LocalRecordingSidecar
    ) -> SessionCanonicalMetadataSignature? {
        guard let sessionConfig = SessionExportMetadataResolver.validatedSessionConfig(from: sidecar) else {
            return nil
        }
        return SessionCanonicalMetadataSignature(config: sessionConfig)
    }

    private func packageValidationIssues(_ package: SessionExportPackage) -> [String] {
        var issues: [String] = []
        if package.takes.isEmpty {
            issues.append("No takes are available for export.")
        }
        if package.metadata.takeCount != package.takes.count {
            issues.append("Session metadata take count does not match the staged takes.")
        }
        if package.metadata.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Session ID is missing from export metadata.")
        }
        let exportScratchTypeToken = CaptureCanonicalFormatting.exportScratchTypeToken(
            scratchTypeID: package.metadata.scratchTypeID,
            scratchTypeName: package.metadata.scratchTypeName,
            workflow: package.metadata.workflow
        )
        if usesLegacyCanonicalScratchContract(workflow: package.metadata.workflow) {
            if package.metadata.scratchTypeID != CaptureCanonicalRules.scratchTypeID {
                issues.append("Scratch type must match the canonical baby scratch contract.")
            }
        } else if exportScratchTypeToken == nil {
            issues.append("Scratch type is required before export.")
        }
        if (package.metadata.performerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Performer name is required before export.")
        }

        for take in package.takes {
            let takeLabel = formattedTakeLabel(take.takeNumber)
            let videoCheck = ArtifactPreflight.checkFileReady(url: take.mediaURL)
            if !videoCheck.exists || videoCheck.bytes <= 0 {
                issues.append("\(takeLabel) video is missing. Retake it before export.")
            } else if !videoCheck.isStable {
                issues.append("\(takeLabel) video is still finalizing. Try again in a moment.")
            }
            if !FileManager.default.fileExists(atPath: take.sidecarURL.path) {
                issues.append("Take \(take.takeID) is missing \(take.sidecarURL.lastPathComponent).")
            }
            if let audioArtifactURL = take.audioArtifactURL {
                let audioCheck = ArtifactPreflight.checkFileReady(url: audioArtifactURL)
                if !audioCheck.exists || audioCheck.bytes <= 0 {
                    issues.append("\(takeLabel) audio is missing. Retake it before export.")
                } else if !audioCheck.isStable {
                    issues.append("\(takeLabel) audio is still finalizing. Try again in a moment.")
                }
            } else {
                issues.append("\(takeLabel) audio is missing. Retake it before export.")
            }
            if take.recordingStatus != "completed" {
                if take.recordingStatus == "recording" {
                    issues.append("\(takeLabel) audio is still finalizing. Try again in a moment.")
                } else {
                    issues.append("\(takeLabel) failed and is not exportable.")
                }
            }
            if let motionPresent = take.motionPresent, motionPresent,
               let watchCaptureSession = take.watchCaptureSession {
                if !WatchAssociationResolver.isLinkedCaptureValid(
                    sessionID: package.metadata.sessionID,
                    takeID: take.takeID,
                    captureSession: watchCaptureSession
                ) {
                    issues.append("Take \(take.takeID) has a watch artifact that is not linked to this session/take.")
                }
            } else if take.motionPresent == true {
                issues.append("Take \(take.takeID) claims watch motion, but no linked watch artifact was supplied.")
            }
        }

        if issues.isEmpty {
            do {
                _ = try canonicalPreview(for: package)
            } catch let error as SessionExportError {
                issues.append(error.userMessage)
            } catch {
                issues.append("ScratchLab could not validate the canonical export artifacts.")
            }
        }

        return Array(NSOrderedSet(array: issues)) as? [String] ?? issues
    }

    private func packageValidationReport(for package: SessionExportPackage) -> SessionValidationReport? {
        let issues = packageValidationIssues(package)
        return issues.isEmpty ? nil : SessionValidationReport(
            suggestedError: issues.contains(where: { $0.localizedCaseInsensitiveContains("missing") })
                ? .missingRequiredFiles
                : .invalidSessionMetadata,
            issues: issues
        )
    }

    private func usesLegacyCanonicalScratchContract(workflow: String) -> Bool {
        switch workflow {
        case "routine_capture", "guided_capture", "demo_mode":
            return false
        default:
            return true
        }
    }

    private func hydratePackageForExport(_ package: SessionExportPackage) -> SessionExportPackage {
        let fileManager = FileManager.default
        let hydratedTakes = package.takes.map { take in
            let resolvedAudioArtifactURL: URL?
            if let audioArtifactURL = take.audioArtifactURL {
                resolvedAudioArtifactURL = audioArtifactURL
            } else {
                resolvedAudioArtifactURL = try? self.derivedAudioArtifactURL(
                    for: take.mediaURL,
                    in: take.mediaURL.deletingLastPathComponent(),
                    fileManager: fileManager
                )
            }

            let resolvedVerbalSlateUsed: Bool?
            let resolvedSyncClapUsed: Bool?
            if package.metadata.workflow == "guided_capture" {
                resolvedVerbalSlateUsed = take.verbalSlateUsed ?? false
                resolvedSyncClapUsed = take.syncClapUsed ?? false
            } else {
                resolvedVerbalSlateUsed = take.verbalSlateUsed
                resolvedSyncClapUsed = take.syncClapUsed
            }

            let resolvedAudioPresent: Bool?
            if let audioPresent = take.audioPresent {
                resolvedAudioPresent = audioPresent
            } else if resolvedAudioArtifactURL != nil {
                resolvedAudioPresent = true
            } else {
                resolvedAudioPresent = nil
            }

            return SessionExportTake(
                takeID: take.takeID,
                takeNumber: take.takeNumber,
                bpm: take.bpm,
                mediaURL: take.mediaURL,
                audioArtifactURL: resolvedAudioArtifactURL,
                sidecarURL: take.sidecarURL,
                watchCaptureSession: take.watchCaptureSession,
                drillName: take.drillName,
                duration: take.duration,
                quality: take.quality,
                comboTagged: take.comboTagged,
                audioPresent: resolvedAudioPresent,
                motionPresent: take.motionPresent,
                syncStatus: take.syncStatus,
                recordingStatus: take.recordingStatus,
                verbalSlateUsed: resolvedVerbalSlateUsed,
                syncClapUsed: resolvedSyncClapUsed,
                note: take.note,
                captureTiming: take.captureTiming
            )
        }

        return SessionExportPackage(
            metadata: package.metadata,
            takes: hydratedTakes,
            calibrationData: package.calibrationData
        )
    }

    private func cleanupStagingRoot(_ stagingRoot: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        try fileManager.removeItem(at: stagingRoot)
    }

    private func fileSize(for url: URL, fileManager: FileManager) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func archiveFolderName(for metadata: SessionExportMetadata) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy_MM_dd"
        let dateString = formatter.string(from: metadata.createdAt)
        let sanitizedSessionName = sanitizedArchiveLabel(for: metadata, allowedBPMs: nil)
        return "session_\(dateString)_\(sanitizedSessionName)"
    }

    private func archiveFolderName(
        for metadata: SessionExportMetadata,
        allowedBPMs: [Int]
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy_MM_dd"
        let dateString = formatter.string(from: metadata.createdAt)
        let sanitizedSessionName = sanitizedArchiveLabel(for: metadata, allowedBPMs: allowedBPMs)
        return "session_\(dateString)_\(sanitizedSessionName)"
    }

    func derivedAudioArtifactURL(
        for mediaURL: URL,
        in sessionDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let audioURL = sessionDirectory
            .appendingPathComponent(mediaURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")

        if fileManager.fileExists(atPath: audioURL.path) {
            _ = try probeAudio(url: audioURL)
            return audioURL
        }

        try extractLinearPCMAudio(from: mediaURL, to: audioURL, fileManager: fileManager)
        _ = try probeAudio(url: audioURL)
        return audioURL
    }

    private func extractLinearPCMAudio(
        from mediaURL: URL,
        to audioURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: audioURL.path) {
            try? fileManager.removeItem(at: audioURL)
        }

        do {
            let asset = AVURLAsset(url: mediaURL)
            let audioTrack = try runAsyncProbe {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let audioTrack = audioTracks.first else {
                    throw SessionExportError.missingRequiredFiles
                }
                return audioTrack
            }
            let loadedDescriptions: [CMFormatDescription] = try runAsyncProbe {
                try await audioTrack.load(.formatDescriptions)
            }
            guard
                let formatDescription = loadedDescriptions.first,
                let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            else {
                throw SessionExportError.missingRequiredFiles
            }

            let streamDescription = streamDescriptionPointer.pointee
            let channelCount = AVAudioChannelCount(streamDescription.mChannelsPerFrame)
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: streamDescription.mSampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                throw SessionExportError.unableToPrepareExport
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw SessionExportError.unableToPrepareExport
            }
            reader.add(output)
            guard reader.startReading() else {
                throw SessionExportError.missingRequiredFiles
            }

            let destinationFile = try AVAudioFile(
                forWriting: audioURL,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )

            while let sampleBuffer = output.copyNextSampleBuffer() {
                let buffer = try pcmBuffer(from: sampleBuffer, format: outputFormat)
                try destinationFile.write(from: buffer)
            }

            if reader.status == .failed || reader.status == .cancelled {
                throw reader.error ?? SessionExportError.missingRequiredFiles
            }
        } catch {
            try? fileManager.removeItem(at: audioURL)
            throw SessionExportError.missingRequiredFiles
        }
    }

    private func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.int16ChannelData else {
            throw SessionExportError.unableToPrepareExport
        }
        buffer.frameLength = frameCount

        let audioBufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, Int(format.channelCount) - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw SessionExportError.unableToPrepareExport
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let bytesPerChannelFrame = max(1, bytesPerFrame / Int(format.channelCount))
        let expectedByteCount = Int(frameCount) * bytesPerChannelFrame

        if sourceBuffers.count == 1,
           Int(format.channelCount) > 1,
           let interleavedSource = sourceBuffers.first?.mData?.assumingMemoryBound(to: Int16.self) {
            let interleavedFrameWidth = Int(format.channelCount)
            for frameIndex in 0..<Int(frameCount) {
                for channelIndex in 0..<Int(format.channelCount) {
                    channelData[channelIndex][frameIndex] = interleavedSource[(frameIndex * interleavedFrameWidth) + channelIndex]
                }
            }
            return buffer
        }

        for (channelIndex, sourceBuffer) in sourceBuffers.enumerated() {
            guard channelIndex < Int(format.channelCount),
                  let sourceData = sourceBuffer.mData else {
                continue
            }
            memcpy(channelData[channelIndex], sourceData, min(expectedByteCount, Int(sourceBuffer.mDataByteSize)))
        }

        return buffer
    }

    private func canonicalContext(for package: SessionExportPackage) throws -> CanonicalSessionContext {
        guard !package.takes.isEmpty else {
            throw SessionExportError.missingRequiredFiles
        }
        guard package.metadata.takeCount == package.takes.count,
              !package.metadata.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionExportError.invalidSessionMetadata
        }
        let exportScratchTypeToken = CaptureCanonicalFormatting.exportScratchTypeToken(
            scratchTypeID: package.metadata.scratchTypeID,
            scratchTypeName: package.metadata.scratchTypeName,
            workflow: package.metadata.workflow
        )
        if usesLegacyCanonicalScratchContract(workflow: package.metadata.workflow) {
            guard package.metadata.scratchTypeID == CaptureCanonicalRules.scratchTypeID else {
                throw SessionExportError.invalidSessionMetadata
            }
        } else {
            guard exportScratchTypeToken != nil else {
                throw SessionExportError.invalidSessionMetadata
            }
        }
        guard let performerName = package.metadata.performerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !performerName.isEmpty,
              let djToken = CaptureCanonicalFormatting.sanitizeDJToken(performerName) else {
            throw SessionExportError.invalidSessionMetadata
        }
        let resolvedScratchTypeToken = exportScratchTypeToken ?? CaptureCanonicalRules.scratchTypeName

        let dateString = CaptureCanonicalFormatting.sessionDateString(package.metadata.createdAt)
        let fileManager = FileManager.default
        var seenTakeIDs = Set<String>()
        var seenTakeKeys = Set<String>()
        var decodedSidecars: [CaptureCore.LocalRecordingSidecar] = []
        var takeContexts: [CanonicalTakeContext] = []
        var bpmCoverage = Set<Int>()

        for take in package.takes.sorted(by: { lhs, rhs in
            if lhs.bpm == rhs.bpm {
                return lhs.takeNumber < rhs.takeNumber
            }
            return lhs.bpm < rhs.bpm
        }) {
            guard fileManager.fileExists(atPath: take.mediaURL.path),
                  fileManager.fileExists(atPath: take.sidecarURL.path) else {
                throw SessionExportError.missingRequiredFiles
            }
            guard let audioArtifactURL = take.audioArtifactURL,
                  fileManager.fileExists(atPath: audioArtifactURL.path) else {
                throw SessionExportError.missingRequiredFiles
            }
            guard take.recordingStatus == "completed",
                  let verbalSlateUsed = take.verbalSlateUsed,
                  let syncClapUsed = take.syncClapUsed else {
                throw SessionExportError.invalidSessionMetadata
            }
            if let audioPresent = take.audioPresent, !audioPresent {
                throw SessionExportError.invalidSessionMetadata
            }

            let sidecar = try decodeSidecar(at: take.sidecarURL)
            let captureValues = resolvedTakeCaptureValues(
                for: take,
                sidecar: sidecar,
                packageMetadata: package.metadata
            )
            let canReadAudioStem = (try? AVAudioFile(forReading: audioArtifactURL)) != nil
            guard let canonicalBPM = captureValues.canonicalBPM,
                  CaptureClickTrackDefaults.supportedBPMRange.contains(canonicalBPM) else {
                throw SessionExportError.invalidSessionMetadata
            }
            guard sidecar.sessionID == package.metadata.sessionID,
                  sidecar.takeID == take.takeID,
                  sidecar.appLocalTakeNumber == take.takeNumber else {
                throw SessionExportError.invalidSessionMetadata
            }
            if let configuredBPM = captureValues.bpm, configuredBPM != canonicalBPM {
                throw SessionExportError.invalidSessionMetadata
            }

            let takeKey = "\(canonicalBPM)-\(take.takeNumber)"
            guard seenTakeIDs.insert(take.takeID).inserted,
                  seenTakeKeys.insert(takeKey).inserted else {
                throw SessionExportError.invalidSessionMetadata
            }

            if sidecar.linkedMotionFileName != nil || take.motionPresent == true {
                guard let watchCaptureSession = take.watchCaptureSession,
                      WatchAssociationResolver.isLinkedCaptureValid(
                        sessionID: package.metadata.sessionID,
                        takeID: take.takeID,
                        captureSession: watchCaptureSession
                      ) else {
                    throw SessionExportError.invalidSessionMetadata
                }
            } else if let motionPresent = take.motionPresent, motionPresent {
                throw SessionExportError.invalidSessionMetadata
            }

            let videoExtension = take.mediaURL.pathExtension.lowercased()
            let audioExtension = audioArtifactURL.pathExtension.lowercased()
            guard videoExtension == "mov", audioExtension == "wav" else {
                throw SessionExportError.invalidSessionMetadata
            }

            let videoFileName = CaptureCanonicalFormatting.standardFileName(
                djToken: djToken,
                scratchTypeToken: resolvedScratchTypeToken,
                bpm: canonicalBPM,
                takeNumber: take.takeNumber,
                source: "camA",
                fileExtension: videoExtension
            )
            let audioStemExport = resolvedAudioStemExport(
                djToken: djToken,
                scratchTypeToken: resolvedScratchTypeToken,
                canonicalBPM: canonicalBPM,
                takeNumber: take.takeNumber,
                audioExtension: audioExtension,
                shouldRenderBeatStem: (captureValues.captureMode == CaptureSessionCaptureMode.timedClick.rawValue
                    || captureValues.clickEnabled
                    || captureValues.beatEnabled)
                    && canReadAudioStem
            )
            let watchFileName = take.watchCaptureSession.map {
                _ in CaptureCanonicalFormatting.standardFileName(
                    djToken: djToken,
                    scratchTypeToken: resolvedScratchTypeToken,
                    bpm: canonicalBPM,
                    takeNumber: take.takeNumber,
                    source: "watch",
                    fileExtension: "csv"
                )
            }
            let notationExport = try resolvedNotationExport(
                for: take,
                sidecar: sidecar,
                packageMetadata: package.metadata
            )
            let captureMetadata = try resolvedTakeCaptureMetadata(
                for: take,
                packageMetadata: package.metadata
            )

            decodedSidecars.append(sidecar)
            bpmCoverage.insert(canonicalBPM)
            takeContexts.append(
                CanonicalTakeContext(
                    take: take,
                    sidecar: sidecar,
                    canonicalBPM: canonicalBPM,
                    videoFileName: videoFileName,
                    primaryAudioFileName: URL(fileURLWithPath: audioStemExport.scratchOnlyRelativePath).lastPathComponent,
                    scratchOnlyRelativePath: audioStemExport.scratchOnlyRelativePath,
                    beatOnlyFileName: audioStemExport.beatOnlyRelativePath.map { URL(fileURLWithPath: $0).lastPathComponent },
                    scratchWithBeatFileName: audioStemExport.scratchWithBeatRelativePath.map { URL(fileURLWithPath: $0).lastPathComponent },
                    stemAvailability: [
                        "scratch_only": audioStemExport.scratchOnlyAvailability,
                        "beat_only": audioStemExport.beatOnlyAvailability,
                        "scratch_with_beat": audioStemExport.scratchWithBeatAvailability
                    ],
                    watchFileName: watchFileName,
                    notationFileName: notationExport.fileName,
                    notationDocument: notationExport.document,
                    captureMetadata: captureMetadata,
                    verbalSlateUsed: verbalSlateUsed,
                    syncClapUsed: syncClapUsed,
                    notes: take.note ?? ""
                )
            )
        }

        let manifestAllowedBPMs = try manifestAllowedBPMs(for: package.metadata.workflow, bpmCoverage: bpmCoverage)
        guard !manifestAllowedBPMs.isEmpty else {
            throw SessionExportError.invalidSessionMetadata
        }
        guard SessionExportMetadataResolver.metadataMatchesSidecars(
            package.metadata,
            sidecars: decodedSidecars
        ) else {
            throw SessionExportError.invalidSessionMetadata
        }

        let sessionRootName = archiveFolderName(
            for: package.metadata,
            allowedBPMs: manifestAllowedBPMs
        )
        let manifestTakes = try takeContexts.map { context in
            let files = try canonicalFilesMap(for: context, sessionRootURL: URL(fileURLWithPath: "/tmp/\(sessionRootName)"))
            let artifacts = try canonicalArtifactsMap(for: context, sessionRootURL: URL(fileURLWithPath: "/tmp/\(sessionRootName)"))
            return CanonicalTakeManifestRecord(
                djName: performerName,
                date: dateString,
                scratchType: resolvedScratchTypeToken,
                bpm: context.canonicalBPM,
                takeNumber: context.take.takeNumber,
                segmentCount: CaptureCanonicalRules.segmentCount,
                cameraID: "camA",
                audioSource: "serato",
                watchSource: context.watchFileName == nil ? "none" : "watch",
                verbalSlateUsed: context.verbalSlateUsed,
                syncClapUsed: context.syncClapUsed,
                notes: context.notes,
                stemAvailability: context.stemAvailability,
                files: files,
                artifacts: artifacts
            )
        }

        let manifest = CanonicalSessionManifest(
            specVersion: CaptureCanonicalRules.specVersion,
            djName: performerName,
            djToken: djToken,
            date: dateString,
            scratchType: resolvedScratchTypeToken,
            allowedBPMs: manifestAllowedBPMs,
            segmentCount: CaptureCanonicalRules.segmentCount,
            verbalSlateRequired: true,
            syncClapRequired: true,
            sessionRoot: sessionRootName,
            notes: package.metadata.notes ?? "",
            takes: manifestTakes
        )

        let takeLogRows = takeContexts.map {
            CanonicalTakeLogRow(
                bpm: $0.canonicalBPM,
                takeNumber: $0.take.takeNumber,
                rawCamA: "",
                rawCamB: "",
                rawAudio: "",
                rawWatch: "",
                verbalSlateUsed: $0.verbalSlateUsed,
                syncClapUsed: $0.syncClapUsed,
                notes: $0.notes
            )
        }

        return CanonicalSessionContext(
            manifest: manifest,
            takeLogRows: takeLogRows,
            takes: takeContexts,
            sessionRootName: sessionRootName
        )
    }

    private func manifestAllowedBPMs(
        for workflow: String,
        bpmCoverage: Set<Int>
    ) throws -> [Int] {
        let sortedCoverage = bpmCoverage.sorted()
        switch workflow {
        case "routine_capture", "guided_capture", "demo_mode":
            guard !sortedCoverage.isEmpty,
                  sortedCoverage.allSatisfy({ CaptureClickTrackDefaults.supportedBPMRange.contains($0) }) else {
                throw SessionExportError.invalidSessionMetadata
            }
            return sortedCoverage
        default:
            guard bpmCoverage == CaptureCanonicalRules.allowedBPMs else {
                throw SessionExportError.invalidSessionMetadata
            }
            return CaptureCanonicalRules.allowedBPMList
        }
    }

    private func createCanonicalDirectorySkeleton(
        at stagedSessionURL: URL,
        allowedBPMs: [Int],
        fileManager: FileManager
    ) throws {
        let bpmDirectories = allowedBPMs.map { "\($0)bpm" }
        let requiredDirectories = [
            "raw",
            "audio",
            "video",
            "watch",
            "notation",
            "manifests"
        ] + bpmDirectories

        for directory in requiredDirectories {
            try fileManager.createDirectory(
                at: stagedSessionURL.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func canonicalFilesMap(for context: CanonicalTakeContext, sessionRootURL: URL) throws -> [String: String] {
        var files: [String: String] = [
            "camA": "video/\(context.videoFileName)",
            "serato": context.scratchOnlyRelativePath,
            "scratch_only": context.scratchOnlyRelativePath,
            "notation": "notation/\(context.notationFileName)"
        ]
        if let beatOnlyFileName = context.beatOnlyFileName {
            files["beat_only"] = "audio/\(beatOnlyFileName)"
        }
        if let scratchWithBeatFileName = context.scratchWithBeatFileName {
            files["scratch_with_beat"] = "audio/\(scratchWithBeatFileName)"
        }
        if let watchFileName = context.watchFileName {
            files["watch"] = "watch/\(watchFileName)"
        }
        return files
    }

    private func canonicalArtifactsMap(for context: CanonicalTakeContext, sessionRootURL: URL) throws -> [String: CanonicalArtifactRecord] {
        var artifacts: [String: CanonicalArtifactRecord] = [:]

        let videoTargetURL = sessionRootURL.appendingPathComponent("video/\(context.videoFileName)")
        artifacts["camA"] = try artifactRecord(
            source: "camA",
            fileURL: context.take.mediaURL,
            stagedURL: videoTargetURL
        )

        guard let audioArtifactURL = context.take.audioArtifactURL else {
            throw SessionExportError.missingRequiredFiles
        }
        let audioTargetURL = sessionRootURL.appendingPathComponent(context.scratchOnlyRelativePath)
        let scratchArtifact = try artifactRecord(
            source: "scratch_only",
            fileURL: audioArtifactURL,
            stagedURL: audioTargetURL
        )
        artifacts["serato"] = scratchArtifact
        artifacts["scratch_only"] = scratchArtifact

        if let beatOnlyFileName = context.beatOnlyFileName {
            let beatBuffer = try renderedBeatStemBuffer(
                for: context.take,
                captureMetadata: context.captureMetadata,
                scratchAudioURL: audioArtifactURL
            )
            artifacts["beat_only"] = try generatedAudioArtifactRecord(
                source: "beat_only",
                buffer: beatBuffer,
                stagedURL: sessionRootURL.appendingPathComponent("audio/\(beatOnlyFileName)"),
                fileManager: FileManager.default
            )
            if let scratchWithBeatFileName = context.scratchWithBeatFileName {
                let mixedBuffer = try mixedScratchWithTimingBuffer(
                    scratchURL: audioArtifactURL,
                    timingBuffer: beatBuffer
                )
                artifacts["scratch_with_beat"] = try generatedAudioArtifactRecord(
                    source: "scratch_with_beat",
                    buffer: mixedBuffer,
                    stagedURL: sessionRootURL.appendingPathComponent("audio/\(scratchWithBeatFileName)"),
                    fileManager: FileManager.default
                )
            }
        }

        if let watchCaptureSession = context.take.watchCaptureSession,
           let watchFileName = context.watchFileName {
            let csvData = Data(CaptureCanonicalFormatting.watchCSV(for: watchCaptureSession).utf8)
            let watchTargetURL = sessionRootURL.appendingPathComponent("watch/\(watchFileName)")
            artifacts["watch"] = try artifactRecord(
                source: "watch",
                generatedData: csvData,
                stagedURL: watchTargetURL
            )
        }

        return artifacts
    }

    private func artifactRecord(
        source: String,
        fileURL: URL? = nil,
        generatedData: Data? = nil,
        stagedURL: URL
    ) throws -> CanonicalArtifactRecord {
        let data: Data
        if let generatedData {
            data = generatedData
        } else if let fileURL {
            data = try Data(contentsOf: fileURL)
        } else {
            throw SessionExportError.missingRequiredFiles
        }

        return CanonicalArtifactRecord(
            path: stagedURL.pathComponents.suffix(2).joined(separator: "/"),
            bytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            probe: try artifactProbe(source: source, fileURL: fileURL, generatedData: generatedData)
        )
    }

    private func artifactProbe(
        source: String,
        fileURL: URL?,
        generatedData: Data?
    ) throws -> [String: SessionExportProbeValue] {
        if let artifactProbeOverride {
            let overrideSource: String
            switch source {
            case "scratch_only", "beat_only", "scratch_with_beat", "raw_original":
                overrideSource = "serato"
            default:
                overrideSource = source
            }
            return try artifactProbeOverride(overrideSource, fileURL, generatedData)
        }
        switch source {
        case "camA":
            guard let fileURL else { throw SessionExportError.missingRequiredFiles }
            return try probeVideo(url: fileURL)
        case "serato", "scratch_only", "beat_only", "scratch_with_beat", "raw_original":
            guard let fileURL else { throw SessionExportError.missingRequiredFiles }
            return try probeAudio(url: fileURL)
        case "watch":
            guard let generatedData else { throw SessionExportError.missingRequiredFiles }
            return try probeWatchCSV(data: generatedData)
        default:
            throw SessionExportError.invalidSessionMetadata
        }
    }

    private func probeVideo(url: URL) throws -> [String: SessionExportProbeValue] {
        let summary = try runAsyncProbe {
            let asset = AVURLAsset(url: url)
            let durationTime = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw SessionExportError.invalidSessionMetadata
            }
            let naturalSize = try await track.load(.naturalSize)
            let width = Int(naturalSize.width.rounded())
            let height = Int(naturalSize.height.rounded())
            let duration = round(durationTime.seconds * 1_000_000) / 1_000_000
            guard duration > 0, width > 0, height > 0 else {
                throw SessionExportError.invalidSessionMetadata
            }

            let frameRateValue = try await track.load(.nominalFrameRate)
            let frameRate = frameRateValue > 0
                ? round(Double(frameRateValue) * 10_000) / 10_000
                : nil

            let descriptions = try await track.load(.formatDescriptions)
            let codec: String?
            if let description = descriptions.first {
                let subtype = CMFormatDescriptionGetMediaSubType(description)
                codec = videoCodecName(for: subtype)
            } else {
                codec = nil
            }

            return VideoProbeSummary(
                width: width,
                height: height,
                duration: duration,
                frameRate: frameRate,
                codec: codec
            )
        }

        var payload: [String: SessionExportProbeValue] = [
            "kind": .string("video"),
            "duration_seconds": .double(summary.duration),
            "width": .int(summary.width),
            "height": .int(summary.height)
        ]

        if let frameRate = summary.frameRate {
            payload["frame_rate_fps"] = .double(frameRate)
        }
        if let codecName = summary.codec {
            payload["codec"] = .string(codecName)
        }
        return payload
    }

    private func runAsyncProbe<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = AsyncProbeBox<T>()
        Task {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            box.semaphore.signal()
        }
        box.semaphore.wait()
        guard let result = box.result else {
            throw SessionExportError.invalidSessionMetadata
        }
        return try result.get()
    }

    private func probeAudio(url: URL) throws -> [String: SessionExportProbeValue] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = Int(format.sampleRate.rounded())
        let channelCount = Int(format.channelCount)
        let frameCount = Int(audioFile.length)
        let sampleWidthBytes = max(1, Int(audioFile.fileFormat.streamDescription.pointee.mBitsPerChannel) / 8)
        let duration = sampleRate > 0 ? round((Double(frameCount) / Double(sampleRate)) * 1_000_000) / 1_000_000 : 0
        guard sampleRate > 0, channelCount > 0, frameCount >= 0 else {
            throw SessionExportError.invalidSessionMetadata
        }

        return [
            "kind": .string("audio"),
            "duration_seconds": .double(duration),
            "sample_rate_hz": .int(sampleRate),
            "channel_count": .int(channelCount),
            "frame_count": .int(frameCount),
            "sample_width_bytes": .int(sampleWidthBytes)
        ]
    }

    private func probeWatchCSV(data: Data) throws -> [String: SessionExportProbeValue] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionExportError.invalidSessionMetadata
        }
        let rows = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = rows.first,
              header.split(separator: ",").map(String.init) == CaptureCanonicalRules.watchCSVHeader else {
            throw SessionExportError.invalidSessionMetadata
        }
        let dataRowCount = rows.dropFirst().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard dataRowCount >= CaptureCanonicalRules.minimumWatchSampleCount else {
            throw SessionExportError.invalidSessionMetadata
        }

        return [
            "kind": .string("csv"),
            "row_count": .int(dataRowCount + 1),
            "data_row_count": .int(dataRowCount),
            "column_count": .int(CaptureCanonicalRules.watchCSVHeader.count)
        ]
    }

    private func videoCodecName(for subtype: FourCharCode) -> String? {
        switch subtype {
        case kCMVideoCodecType_H264:
            return "h264"
        case kCMVideoCodecType_HEVC:
            return "hevc"
        case kCMVideoCodecType_JPEG:
            return "mjpeg"
        case kCMVideoCodecType_AppleProRes422:
            return "prores"
        default:
            return nil
        }
    }

    private func resolveLinkedWatchCapture(for sidecar: CaptureCore.LocalRecordingSidecar) -> WatchMotionCaptureSession? {
        let candidateDirectories = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("WatchMotionCaptures", isDirectory: true),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ScratchLab", isDirectory: true)
                .appendingPathComponent("RelayedWatchCaptures", isDirectory: true)
        ]
        guard let fileName = sidecar.linkedMotionFileName else { return nil }

        for directory in candidateDirectories.compactMap({ $0 }) {
            let fileURL = directory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: fileURL),
                  let capture = try? WatchMotionCaptureCodec.decoder.decode(WatchMotionCaptureSession.self, from: data) else {
                continue
            }
            if WatchAssociationResolver.isLinkedCaptureValid(
                sessionID: sidecar.sessionID,
                takeID: sidecar.takeID,
                captureSession: capture
            ) {
                return capture
            }
        }

        return nil
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowedCharacters.contains(scalar) ? Character(scalar) : "_"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .lowercased()
        return collapsed.isEmpty ? "scratchlab_session" : collapsed
    }

    private func sanitizedArchiveLabel(
        for metadata: SessionExportMetadata,
        allowedBPMs: [Int]?
    ) -> String {
        guard let allowedBPMs, !allowedBPMs.isEmpty else {
            return sanitizedFileName(metadata.sessionName)
        }

        let bpmLabel = allowedBPMs.sorted().map(String.init).joined(separator: "_") + "_bpm"
        let performerLabel = {
            let trimmed = metadata.performerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Unknown Performer" : trimmed
        }()
        let scratchLabel = {
            let trimmedName = metadata.scratchTypeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedName.isEmpty { return trimmedName }
            let trimmedID = metadata.scratchTypeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedID.isEmpty ? "Scratch" : trimmedID
        }()

        return sanitizedFileName("\(performerLabel)_\(scratchLabel)_\(bpmLabel)")
    }

    private func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

}
