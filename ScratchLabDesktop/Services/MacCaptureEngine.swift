import Foundation
import AVFoundation
import Vision
import SwiftUI
import AppKit
import CoreAudio
import CoreMedia
import AudioToolbox
import CoreMIDI
import Accelerate
import CoreImage
import ImageIO

private enum ScratchLabDesktopDefaultsKey {
    static let selectedAudioDeviceUniqueID = "scratchlab.mac.selectedAudioDeviceUniqueID"
    static let selectedVideoDeviceUniqueID = "scratchlab.mac.selectedVideoDeviceUniqueID"
    static let calibrationLocked = "scratchlab.mac.calibrationLocked"
    static let practiceViewEnabled = "scratchlab.mac.practiceViewEnabled"
    static let useDJPerspective = "scratchlab.mac.useDJPerspective"
    static let manualRigGuideEnabled = "scratchlab.mac.manualRigGuideEnabled"
    static let rigHorizontalOffset = "scratchlab.mac.rigHorizontalOffset"
    static let rigVerticalOffset = "scratchlab.mac.rigVerticalOffset"
    static let rigWidthScale = "scratchlab.mac.rigWidthScale"
    static let rigHeightScale = "scratchlab.mac.rigHeightScale"
    static let mixerWidthRatio = "scratchlab.mac.mixerWidthRatio"
    static let zoneAdjustmentsData = "scratchlab.mac.zoneAdjustmentsData"
}

final class MacCaptureEngine: NSObject, ObservableObject {
    private enum DirectCaptureRoute {
        case nativeSeratoVirtualAudio
        case privateProcessTap
    }

    private enum RoutineRecordingError: LocalizedError {
        case missingVideo
        case missingAudio
        case sessionNotReady
        case selectedVideoUnavailable
        case selectedAudioUnavailable
        case missingVideoConnection
        case missingAudioConnection

        var errorDescription: String? {
            switch self {
            case .missingVideo:
                return "Pick a camera before starting a routine recording."
            case .missingAudio:
                return "Pick the routed audio input before starting a routine recording."
            case .sessionNotReady:
                return "The capture session is still starting up. Try recording again in a moment."
            case .selectedVideoUnavailable:
                return "The selected camera is unavailable. Pick the camera again and retry."
            case .selectedAudioUnavailable:
                return "The selected audio input is unavailable. Pick the audio source again and retry."
            case .missingVideoConnection:
                return "ScratchLab could not attach the selected camera for recording. Retry after the preview reconnects."
            case .missingAudioConnection:
                return "ScratchLab could not attach the selected audio input for recording. Retry after the audio route reconnects."
            }
        }
    }

    struct ZoneAdjustment: Equatable {
        var offsetX: Double = 0
        var offsetY: Double = 0
        var widthScale: Double = 1
        var heightScale: Double = 1

        static let identity = ZoneAdjustment()

        var isIdentity: Bool {
            self == .identity
        }
    }

    private struct StoredZoneAdjustment: Codable {
        let role: String
        let offsetX: Double
        let offsetY: Double
        let widthScale: Double
        let heightScale: Double
    }

    private struct PreparedRoutineRecording {
        let mediaURL: URL
        let audioURL: URL
        let sidecarURL: URL
        let sidecar: CaptureCore.LocalRecordingSidecar
    }

    private struct RoutineAudioCaptureDiagnosticsSnapshot {
        let buffersReceived: Int
        let buffersAppended: Int
        let buffersSkipped: Int
        let lastErrorMessage: String?
    }

    private enum RoutineAudioCaptureWriterError: LocalizedError {
        case unsupportedSourceFormat
        case unableToReadSampleBuffer
        case unableToCreateDestination

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat:
                return "ScratchLab could not prepare the raw audio stem."
            case .unableToReadSampleBuffer:
                return "ScratchLab could not read an incoming audio buffer."
            case .unableToCreateDestination:
                return "ScratchLab could not create the raw audio stem file."
            }
        }
    }

    private final class RoutineAudioCaptureWriter {
        private let destinationURL: URL
        private var destinationFile: AVAudioFile?

        private(set) var buffersReceived = 0
        private(set) var buffersAppended = 0
        private(set) var buffersSkipped = 0
        private(set) var lastErrorMessage: String?

        init(destinationURL: URL) {
            self.destinationURL = destinationURL
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            buffersReceived += 1

            do {
                let pcmBuffer = try Self.pcmBuffer(from: sampleBuffer)
                try ensureDestinationFile(for: pcmBuffer.format)
                guard let destinationFile else {
                    throw RoutineAudioCaptureWriterError.unableToCreateDestination
                }
                try destinationFile.write(from: pcmBuffer)
                buffersAppended += 1
            } catch {
                buffersSkipped += 1
                lastErrorMessage = error.localizedDescription
            }
        }

        func diagnosticsSnapshot() -> RoutineAudioCaptureDiagnosticsSnapshot {
            RoutineAudioCaptureDiagnosticsSnapshot(
                buffersReceived: buffersReceived,
                buffersAppended: buffersAppended,
                buffersSkipped: buffersSkipped,
                lastErrorMessage: lastErrorMessage
            )
        }

        private func ensureDestinationFile(for format: AVAudioFormat) throws {
            if destinationFile != nil { return }

            try? FileManager.default.removeItem(at: destinationURL)
            destinationFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }

        private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            let asbd = asbdPointer.pointee
            let channelCount = max(1, Int(asbd.mChannelsPerFrame))
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let commonFormat: AVAudioCommonFormat
            switch (isFloat, Int(asbd.mBitsPerChannel)) {
            case (true, 32):
                commonFormat = .pcmFormatFloat32
            case (false, 16):
                commonFormat = .pcmFormatInt16
            case (false, 32):
                commonFormat = .pcmFormatInt32
            default:
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            guard let format = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: !isNonInterleaved
            ) else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }
            buffer.frameLength = frameCount

            let sourceBufferCount = isNonInterleaved ? channelCount : 1
            let audioBufferListSize = MemoryLayout<AudioBufferList>.size
                + max(0, sourceBufferCount - 1) * MemoryLayout<AudioBuffer>.size
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
                throw RoutineAudioCaptureWriterError.unableToReadSampleBuffer
            }

            let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard sourceBuffers.count == destinationBuffers.count else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            for index in 0..<sourceBuffers.count {
                guard let sourceData = sourceBuffers[index].mData,
                      let destinationData = destinationBuffers[index].mData else {
                    throw RoutineAudioCaptureWriterError.unableToReadSampleBuffer
                }
                memcpy(
                    destinationData,
                    sourceData,
                    min(Int(destinationBuffers[index].mDataByteSize), Int(sourceBuffers[index].mDataByteSize))
                )
            }

            return buffer
        }
    }

    struct CompletedRoutineCaptureSnapshot: Equatable {
        let mediaURL: URL
        let sidecarURL: URL
        let sessionID: String
        let takeID: String
        let endedAt: Date
    }

    struct PerformerMonitorZone: Codable {
        let role: String
        let title: String
        let minX: Double
        let minY: Double
        let width: Double
        let height: Double
    }

    struct PerformerMonitorFrame: Codable {
        let timestamp: TimeInterval
        let jpegData: Data
        let guidanceCue: String
        let guidanceDetail: String
        let scratchStatusTitle: String
        let rigStatusTitle: String
        let audioPercent: String
        let detectionCount: Int
        let highlightedZoneRole: String
        let zones: [PerformerMonitorZone]
    }

    enum HandMotionState: Equatable {
        case searching
        case steady
        case movingLeft
        case movingRight

        var title: String {
            switch self {
            case .searching: return "Show your hand"
            case .steady: return "Hand steady"
            case .movingLeft: return "Back stroke"
            case .movingRight: return "Forward stroke"
            }
        }

        var detail: String {
            switch self {
            case .searching: return "No confident hand pose yet."
            case .steady: return "Camera sees your hand and is waiting for movement."
            case .movingLeft: return "Detected the reverse-back stroke."
            case .movingRight: return "Detected the forward stroke."
            }
        }

        var icon: String {
            switch self {
            case .searching: return "hand.raised.slash.fill"
            case .steady: return "hand.raised.fill"
            case .movingLeft: return "arrow.left.circle.fill"
            case .movingRight: return "arrow.right.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .searching: return Color(hex: "9E9E9E")
            case .steady: return Color(hex: "00BCD4")
            case .movingLeft, .movingRight: return Color(hex: "4CAF50")
            }
        }
    }

    @Published var availableAudioDevices: [AVCaptureDevice] = []
    @Published var availableVideoDevices: [AVCaptureDevice] = []
    @Published private(set) var availableMIDISourceNames: [String] = []
    @Published var selectedAudioDeviceUniqueID: String = UserDefaults.standard.string(forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceUniqueID) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedAudioDeviceUniqueID, forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceUniqueID)
            syncDirectCaptureStatus(using: availableAudioDevices)
            resetAudioSignalLevel()
            guard oldValue != selectedAudioDeviceUniqueID, isRunning else { return }
            reconfigureSession()
        }
    }
    @Published var selectedVideoDeviceUniqueID: String = UserDefaults.standard.string(forKey: ScratchLabDesktopDefaultsKey.selectedVideoDeviceUniqueID) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedVideoDeviceUniqueID, forKey: ScratchLabDesktopDefaultsKey.selectedVideoDeviceUniqueID)
            resetAudioSignalLevel()
            guard oldValue != selectedVideoDeviceUniqueID, isRunning else { return }
            reconfigureSession()
        }
    }
    @Published var audioLevel: Float = 0
    @Published private(set) var hasPublishedAudioLevel = false
    @Published var handDetected = false
    @Published var handPosition: CGPoint?
    @Published var handMotionState: HandMotionState = .searching
    @Published var lastScratchDetection: MacScratchDetectionResult?
    @Published var scratchDetectionCount = 0
    @Published var rigLayout: DJRigLayout?
    @Published var highlightedZoneRole: DJRigZone.Role = .leftDeck
    @Published var sessionStars = 0
    @Published var calibrationLocked: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.calibrationLocked) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(calibrationLocked, forKey: ScratchLabDesktopDefaultsKey.calibrationLocked)
            guard oldValue != calibrationLocked else { return }
            videoQueue.async {
                if self.calibrationLocked {
                    self.rigLayoutDetector.prioritizeNextDetection()
                } else {
                    self.clearFixedRigLayout(prioritizeDetection: true)
                    self.resetPublishedVideoState()
                }
            }
        }
    }
    @Published var practiceViewEnabled: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.practiceViewEnabled) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(practiceViewEnabled, forKey: ScratchLabDesktopDefaultsKey.practiceViewEnabled)
        }
    }
    @Published var useDJPerspective: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.useDJPerspective) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useDJPerspective, forKey: ScratchLabDesktopDefaultsKey.useDJPerspective)
        }
    }
    @Published var manualRigGuideEnabled: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.manualRigGuideEnabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(manualRigGuideEnabled, forKey: ScratchLabDesktopDefaultsKey.manualRigGuideEnabled)
            guard oldValue != manualRigGuideEnabled else { return }
            videoQueue.async {
                self.clearFixedRigLayout(prioritizeDetection: true)
                self.resetPublishedVideoState()
            }
        }
    }
    @Published private(set) var isUsingManualRigGuide = false
    @Published var rigHorizontalOffset: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigHorizontalOffset) as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(rigHorizontalOffset, forKey: ScratchLabDesktopDefaultsKey.rigHorizontalOffset)
        }
    }
    @Published var rigVerticalOffset: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigVerticalOffset) as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(rigVerticalOffset, forKey: ScratchLabDesktopDefaultsKey.rigVerticalOffset)
        }
    }
    @Published var rigWidthScale: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigWidthScale) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(rigWidthScale, forKey: ScratchLabDesktopDefaultsKey.rigWidthScale)
        }
    }
    @Published var rigHeightScale: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigHeightScale) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(rigHeightScale, forKey: ScratchLabDesktopDefaultsKey.rigHeightScale)
        }
    }
    @Published var mixerWidthRatio: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.mixerWidthRatio) as? Double ?? 0.17 {
        didSet {
            UserDefaults.standard.set(mixerWidthRatio, forKey: ScratchLabDesktopDefaultsKey.mixerWidthRatio)
        }
    }
    @Published private(set) var zoneAdjustments: [DJRigZone.Role: ZoneAdjustment] = MacCaptureEngine.loadZoneAdjustments() {
        didSet {
            Self.persistZoneAdjustments(zoneAdjustments)
        }
    }
    @Published private(set) var performerMonitorFrame: PerformerMonitorFrame?
    @Published var statusMessage = "Requesting camera and microphone access"
    @Published private(set) var directCaptureStatus = "Open Serato DJ Pro to prepare Direct Capture."
    @Published private(set) var directCaptureDeviceUID: String?
    @Published private(set) var isCameraActive = false
    @Published private(set) var isRoutineRecording = false
    @Published private(set) var routineRecordingStatus = "Pick camera and audio to record a routine."
    @Published private(set) var lastRoutineRecordingURL: URL?
    @Published private(set) var lastRoutineRecordingSessionID: String?
    @Published private(set) var routineTakeArtifactStatuses: [TakeArtifactStatusSnapshot] = []
    @Published private(set) var routineAudioBuffersReceived = 0
    @Published private(set) var routineAudioBuffersAppended = 0
    @Published private(set) var routineAudioBuffersSkipped = 0
    @Published private(set) var lastRoutineAudioWriterError: String?

    // CXL notation capture
    let cxlRecorder = CXLNotationCaptureRecorder()
    @Published private(set) var cxlIsRecording = false
    @Published private(set) var cxlSessionId = ""
    @Published private(set) var cxlEventCount = 0
    @Published private(set) var cxlSampleCount = 0
    @Published private(set) var cxlLastExportPath: String?
    @Published private(set) var cxlLastExportError: String?

    let captureSession = AVCaptureSession()
    let calibrationOffsetRange: ClosedRange<Double> = -0.28...0.28
    let calibrationScaleRange: ClosedRange<Double> = 0.65...1.85
    let mixerWidthRange: ClosedRange<Double> = 0.10...0.30

    static let unavailableAudioPercent = "0%"

    var selectedAudioDeviceName: String {
        let selectedName = availableAudioDevices
            .first(where: { $0.uniqueID == selectedAudioDeviceUniqueID })?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedName, !selectedName.isEmpty {
            return selectedName
        }
        return "Default audio input"
    }

    var selectedVideoDeviceName: String {
        let selectedName = availableVideoDevices
            .first(where: { $0.uniqueID == selectedVideoDeviceUniqueID })?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedName, !selectedName.isEmpty {
            return selectedName
        }
        return "Default camera"
    }

    var isSelectedAudioInputAvailable: Bool {
        availableAudioDevices.contains(where: { $0.uniqueID == selectedAudioDeviceUniqueID })
    }

    var currentAudioSignalLevel: Float {
        guard isSelectedAudioInputAvailable,
              hasPublishedAudioLevel,
              audioLevel.isFinite else { return 0 }
        return min(max(audioLevel, 0), 1)
    }

    var formattedAudioSignalPercent: String {
        Self.formattedAudioPercent(for: currentAudioSignalLevel, hasPublishedAudioLevel: true)
    }

    var audioReadinessText: String {
        guard !selectedAudioDeviceUniqueID.isEmpty else { return "Choose input" }
        guard isSelectedAudioInputAvailable else { return "Audio Missing" }
        return "Audio Ready"
    }

    var audioSignalStatusText: String {
        guard isSelectedAudioInputAvailable else { return "No input" }
        guard currentAudioSignalLevel > 0.001 else { return "No signal" }
        return "Signal \(formattedAudioSignalPercent)"
    }

    var formattedAudioPercent: String {
        formattedAudioSignalPercent
    }

    var practiceAudioStatusText: String {
        audioReadinessText
    }

    var practiceAudioStatusColor: Color {
        audioReadinessText == "Audio Ready" ? Color(hex: "4CAF50") : .secondary
    }

    var audioMeterColor: Color {
        let level = currentAudioSignalLevel
        guard level > 0.001 else { return Color(hex: "9E9E9E") }
        if level >= 0.65 { return Color(hex: "4CAF50") }
        if level >= 0.3 { return Color(hex: "FFC107") }
        return Color(hex: "FF7043")
    }

    static func formattedAudioPercent(
        for audioLevel: Float?,
        hasPublishedAudioLevel: Bool,
        unavailablePlaceholder: String = unavailableAudioPercent
    ) -> String {
        guard hasPublishedAudioLevel, let audioLevel, audioLevel.isFinite else {
            return unavailablePlaceholder
        }

        let clampedLevel = min(max(audioLevel, 0), 1)
        return "\(Int((clampedLevel * 100).rounded()))%"
    }

    var statusIcon: String {
        switch handMotionState {
        case .searching: return "dot.radiowaves.left.and.right"
        case .steady: return "hand.raised.fill"
        case .movingLeft, .movingRight: return "waveform.path.ecg"
        }
    }

    var statusColor: Color {
        handMotionState.color
    }

    var scratchStatusTitle: String {
        guard let lastScratchDetection else {
            return currentAudioSignalLevel > 0.03 ? "Processing" : "Ready"
        }

        if Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return "Baby Scratch Detected"
        }

        return currentAudioSignalLevel > 0.03 ? "Processing" : "Ready"
    }

    var scratchStatusDetail: String {
        guard let lastScratchDetection else {
            if currentAudioSignalLevel > 0.03 {
                return "Signal is live. Play a clean forward-and-back baby scratch and the analyzer will lock it."
            }
            return "Pick a routed DJ source like BlackHole, Loopback, or your interface and start playback."
        }

        return "Last hit \(Int(lastScratchDetection.accuracy))% accuracy, \(Int(lastScratchDetection.confidence))% confidence. Session detections: \(scratchDetectionCount)."
    }

    var scratchStatusIcon: String {
        if let lastScratchDetection, Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return "waveform.badge.checkmark"
        }
        return currentAudioSignalLevel > 0.03 ? "waveform" : "waveform.slash"
    }

    var scratchStatusColor: Color {
        if let lastScratchDetection, Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return Color(hex: "4CAF50")
        }
        return currentAudioSignalLevel > 0.03 ? Color(hex: "00BCD4") : Color(hex: "9E9E9E")
    }

    var canUseDirectSeratoCapture: Bool {
        guard let directCaptureDeviceUID else { return false }
        return availableAudioDevices.contains { $0.uniqueID == directCaptureDeviceUID }
    }

    var isUsingDirectSeratoCapture: Bool {
        guard let directCaptureDeviceUID else { return false }
        return selectedAudioDeviceUniqueID == directCaptureDeviceUID
    }

    var babyScratchGuidanceTitle: String {
        switch handMotionState {
        case .searching:
            return "Show the scratch hand"
        case .steady:
            return "Ready for the next baby"
        case .movingLeft:
            return "Back stroke"
        case .movingRight:
            return "Forward stroke"
        }
    }

    var babyScratchGuidanceCue: String {
        switch handMotionState {
        case .searching:
            return "Place hand over the record"
        case .steady:
            return "Start a smooth sweep"
        case .movingLeft:
            return "Back — now reverse forward"
        case .movingRight:
            return "Forward — now reverse back"
        }
    }

    var babyScratchGuidanceDetail: String {
        switch handMotionState {
        case .searching:
            return "Keep the scratching hand visible above one deck so ScratchLab can read the baby-scratch direction."
        case .steady:
            return "Hand tracking is live. Make one clean forward sweep, then reverse back for the baby scratch."
        case .movingLeft:
            return "Back stroke detected (\(coachConfidenceSourcePhrase)). Reverse forward on the next stroke to complete the baby scratch."
        case .movingRight:
            return "Forward stroke detected (\(coachConfidenceSourcePhrase)). Reverse back on the next stroke to complete the baby scratch."
        }
    }

    /// Confidence percentage from the direction tracker (0-100).
    var coachConfidencePercent: Int {
        let baseConfidence = Int((handDirectionTracker.confidence * 100).rounded())
        guard hasActiveCoachMotion,
              let audioConfidence = recentAudioScratchConfidence else {
            return baseConfidence
        }

        let conservativeAudioBoost = min(10, Int((audioConfidence * 0.10).rounded()))
        return min(100, baseConfidence + conservativeAudioBoost)
    }

    /// Human-readable signal source for the current coach state.
    /// "Fused" = camera motion and recent audio onset both active.
    /// Audio alone does not drive direction — it only confirms activity.
    var coachSignalSource: String {
        let recentAudio = recentAudioScratchConfidence != nil
        if hasActiveCoachMotion && recentAudio { return "Fused" }
        if recentAudio { return "Audio" }
        if handDetected { return "Camera" }
        return "Searching"
    }

    private var hasActiveCoachMotion: Bool {
        handMotionState == .movingLeft || handMotionState == .movingRight
    }

    private var recentAudioScratchConfidence: Double? {
        guard let lastScratchDetection,
              Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 else {
            return nil
        }
        return lastScratchDetection.confidence
    }

    private var coachConfidenceSourcePhrase: String {
        let source = coachSignalSource.lowercased()
        guard coachConfidencePercent > 0 else { return source }
        return "\(coachConfidencePercent)% confidence, \(source)"
    }

    var visibleStarCount: Int {
        min(sessionStars, 5)
    }

    var routineRecordingsFolderURL: URL? {
        try? recordingsDirectoryURL()
    }

    func rescanRoutineCaptures() {
        recoverInterruptedRoutineCaptures()
        restoreLatestCompletedRoutineCapture()
        refreshRoutineArtifactStatuses()
    }

    var selectedVideoDevice: AVCaptureDevice? {
        availableVideoDevices.first(where: { $0.uniqueID == selectedVideoDeviceUniqueID })
    }

    func reserveNextRoutineTakeIdentity() throws -> TakeIdentity {
        let directory = try recordingsDirectoryURL()
        let sessionID = recordingSessionConfig?.sessionID ?? CaptureCore.LocalRecordingNaming.sessionID()
        let takeNumber = try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber)
        pendingRoutineTakeIdentity = takeIdentity
        return takeIdentity
    }

    func applyPendingWatchReply(_ reply: WatchCaptureControlReply?) {
        pendingWatchReply = reply
    }

    @MainActor
    func cancelPendingRoutineReservation() -> TakeIdentity? {
        let pendingIdentity = pendingRoutineTakeIdentity
        pendingRoutineTakeIdentity = nil
        pendingWatchReply = nil
        return pendingIdentity
    }

    var selectedVideoSourceDescription: String {
        guard let device = selectedVideoDevice else { return "No camera selected" }
        if isDeskViewCamera(device) {
            return "Desk View"
        }
        if isBuiltInMacCamera(device) {
            return "Built-in Camera"
        }
        if isPhoneContinuityCamera(device) {
            return "External Camera"
        }
        return "External Camera"
    }

    var isUsingMacCameraForDesktopDeck: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isBuiltInMacCamera(device)
    }

    var hasDeskViewCameraOption: Bool {
        availableVideoDevices.contains(where: isDeskViewCamera)
    }

    var isUsingDeskViewCamera: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isDeskViewCamera(device)
    }

    var isUsingContinuityCamera: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isPhoneContinuityCamera(device)
    }

    var showRigGuides: Bool {
        !practiceViewEnabled
    }

    func zoneAdjustment(for role: DJRigZone.Role) -> ZoneAdjustment {
        zoneAdjustments[role] ?? .identity
    }

    func updateZoneAdjustment(for role: DJRigZone.Role, mutate: (inout ZoneAdjustment) -> Void) {
        var updated = zoneAdjustment(for: role)
        mutate(&updated)
        setZoneAdjustment(updated, for: role)
    }

    func resetZoneAdjustments() {
        zoneAdjustments = [:]
    }

    func resetCalibration() {
        rigHorizontalOffset = 0
        rigVerticalOffset = 0
        rigWidthScale = 1
        rigHeightScale = 1
        mixerWidthRatio = 0.17
        resetZoneAdjustments()
        videoQueue.async {
            self.clearFixedRigLayout(prioritizeDetection: true)
            self.resetPublishedVideoState()
        }
        Task { @MainActor in
            self.rigLayout = nil
            self.isUsingManualRigGuide = false
        }
    }

    var rigStatusTitle: String {
        guard let rigLayout else {
            return "Rig guide waiting"
        }

        if isUsingManualRigGuide {
            return "Manual deck guide active"
        }

        if rigLayout.confidence >= 0.65 {
            return "Decks and mixer recognized"
        }

        return "Rig outline is forming"
    }

    var rigStatusDetail: String {
        guard rigLayout != nil else {
            return "Show the left deck, mixer, and right deck in one shot. The overlay will split the rig into playable zones."
        }

        if isUsingManualRigGuide {
            return "Auto-detect missed this angle, so the manual rig guide is driving the overlay. Use Deck Calibration to line the boxes up with your decks and mixer."
        }

        return "Recognition active. Perform clean scratches to progress. Use Deck Calibration if the layout drifts."
    }

    private let sessionQueue = DispatchQueue(label: "scratchlab.mac.capture.session")
    private let videoQueue = DispatchQueue(label: "scratchlab.mac.capture.video")
    private let audioQueue = DispatchQueue(label: "scratchlab.mac.capture.audio")
    private let performerMonitorDemandQueue = DispatchQueue(label: "scratchlab.mac.capture.performer-demand")
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let scratchDetector = MacScratchDetector()
    private let rigLayoutDetector = DJRigLayoutDetector()
    private let handDirectionTracker = HandDirectionTracker()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let performerMonitorCIContext = CIContext()
    private let seratoBundleIdentifiers = ["com.serato.seratodj"]
    private let seratoVirtualAudioDeviceName = "Serato Virtual Audio"
    private let seratoDirectCaptureDeviceName = "ScratchLab Direct Serato"
    private let seratoDirectCaptureDeviceUIDValue = "com.machelpnz.scratchlab.mac.serato-direct-capture"

    private var isRunning = false
    private let activeHandPoseInterval: CFTimeInterval = 0.12
    private var lastVisionFrameTime: CFTimeInterval = 0
    private var lastPerformerMonitorFrameTime: CFTimeInterval = 0
    private let audioLevelPublishInterval: CFTimeInterval = 0.05
    private var lastPublishedAudioLevelTime: CFTimeInterval = 0
    private var smoothedHandPoint: CGPoint?
    private var missedHandTrackingFrames = 0

    #if DEBUG
    private var debugFramesReceived = 0
    private var debugFramesAnalyzed = 0
    private var debugHandObservationsFound = 0
    private var debugDirectionChanges = 0
    private var debugMissedFrameCount = 0
    private var debugLastROI: CGRect = .zero
    #endif
    private var lastStarAwardAt: Date?
    private var lastPublishedRigLayout: DJRigLayout?
    private var lastPublishedUsesManualRigGuide = false
    private var lastPublishedHandDetected = false
    private var lastPublishedHandPosition: CGPoint?
    private var lastPublishedHandMotionState: HandMotionState = .searching
    private var performerMonitorStreamingEnabled = false
    private var seratoDirectCaptureTapID = AudioObjectID(0)
    private var seratoDirectCaptureAggregateDeviceID = AudioObjectID(0)
    private var seratoDirectCaptureProcessIdentifiers: [pid_t] = []
    private var directCaptureRoute: DirectCaptureRoute?
    var recordingSessionConfig: CaptureSessionConfig?
    private var activeRoutineRecordingSidecar: CaptureCore.LocalRecordingSidecar?
    private var activeRoutineRecordingSidecarURL: URL?
    private var activeRoutineAudioCaptureWriter: RoutineAudioCaptureWriter?
    private var pendingRoutineTakeIdentity: TakeIdentity?
    private var pendingWatchReply: WatchCaptureControlReply?
    private var routineArtifactRefreshTask: Task<Void, Never>?
    private var fixedRigLayout: DJRigLayout?
    private var fixedRigLayoutUsesManualGuide = false
    private let autoRefreshDevicesOnInit: Bool
    private let audioSignalStaleInterval: CFTimeInterval = 0.8
    private let audioSignalDecayPollInterval: CFTimeInterval = 0.25
    private var lastReceivedAudioSampleTime: CFTimeInterval = 0
    private var audioSignalDecayTimer: DispatchSourceTimer?
    private static let routineSidecarDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    override init() {
        autoRefreshDevicesOnInit = true
        super.init()
        configureInitialState()
    }

    init(autoRefreshDevices: Bool) {
        autoRefreshDevicesOnInit = autoRefreshDevices
        super.init()
        configureInitialState()
    }

    private func configureInitialState() {
        handPoseRequest.maximumHandCount = 1
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        movieOutput.movieFragmentInterval = .invalid
        startAudioSignalDecayTimer()
        rescanRoutineCaptures()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceApplicationChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceApplicationChange(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        if autoRefreshDevicesOnInit {
            refreshDevices()
        }
    }

    deinit {
        audioSignalDecayTimer?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        destroySeratoDirectCapture()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isCameraActive = true
        resetAudioSignalLevel()
        refreshDevices()
        requestPermissionsAndConfigure()
    }

    func stop() {
        isRunning = false
        isCameraActive = false
        scratchDetector.reset()
        rigLayoutDetector.reset()
        handDirectionTracker.reset()
        setPerformerMonitorStreamingEnabled(false)
        lastScratchDetection = nil
        scratchDetectionCount = 0
        rigLayout = nil
        isUsingManualRigGuide = false
        highlightedZoneRole = .leftDeck
        sessionStars = 0
        smoothedHandPoint = nil
        missedHandTrackingFrames = 0
        performerMonitorFrame = nil
        lastStarAwardAt = nil
        resetAudioSignalLevel()
        videoQueue.async {
            self.clearFixedRigLayout()
            self.resetPublishedVideoState()
        }
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.audioQueue.async {
                self.activeRoutineAudioCaptureWriter = nil
                self.publishRoutineAudioCaptureDiagnostics(nil)
            }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func setPerformerMonitorStreamingEnabled(_ enabled: Bool) {
        performerMonitorDemandQueue.sync {
            performerMonitorStreamingEnabled = enabled
        }

        guard !enabled else { return }
        Task { @MainActor in
            if self.performerMonitorFrame != nil {
                self.performerMonitorFrame = nil
            }
        }
    }

    func resetScratchRatingSession() {
        audioQueue.async {
            self.scratchDetector.reset()
            self.lastPublishedAudioLevelTime = 0
        }

        Task { @MainActor in
            self.resetAudioSignalLevel()
            self.lastScratchDetection = nil
            self.scratchDetectionCount = 0
            self.highlightedZoneRole = .leftDeck
            self.sessionStars = 0
            self.lastStarAwardAt = nil
        }
    }

    // MARK: - CXL notation capture

    func startCXLCapture(
        scratchType: String = "baby_scratch",
        mode: String = "scratchRating",
        bpm: Int? = nil,
        loopDuration: Double? = nil
    ) {
        let roi = fixedRigLayout.map { layout -> CXLNotationCaptureSession.CXLRect? in
            let box = layout.unionBox
            return CXLNotationCaptureSession.CXLRect(
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height
            )
        } ?? nil

        cxlRecorder.startSession(
            scratchType: scratchType,
            mode: mode,
            bpm: bpm,
            loopDuration: loopDuration,
            cameraMode: selectedVideoSourceDescription,
            calibrationLocked: calibrationLocked,
            deckROI: roi,
            appBuildVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        publishCXLState()
    }

    func stopCXLCapture() {
        cxlRecorder.stopSession()
        publishCXLState()
    }

    func exportCXLSession() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let result = try self.cxlRecorder.exportSession()
                await MainActor.run {
                    self.cxlLastExportPath = result.directoryURL.path
                    self.cxlLastExportError = nil
                    self.publishCXLState()
                }
            } catch {
                await MainActor.run {
                    self.cxlLastExportError = error.localizedDescription
                    self.publishCXLState()
                }
            }
        }
    }

    /// Record a target stroke from the notation playback engine.
    /// Direction must come from the notation timeline — not from live hand detection.
    @discardableResult
    func recordCXLTargetStroke(direction: CXLDirection, strokeDuration: Double? = nil) -> Int {
        let idx = cxlRecorder.recordTargetStroke(direction: direction, strokeDuration: strokeDuration)
        publishCXLState()
        return idx
    }

    private func publishCXLState() {
        Task { @MainActor in
            self.cxlIsRecording = self.cxlRecorder.isRecording
            self.cxlSessionId = self.cxlRecorder.sessionId
            self.cxlEventCount = self.cxlRecorder.eventCount
            self.cxlSampleCount = self.cxlRecorder.sampleCount
            self.cxlLastExportPath = self.cxlRecorder.lastExportPath
        }
    }

    private func cxlDirectionFrom(_ state: HandMotionState) -> CXLDirection {
        switch state {
        case .movingRight: return .forward
        case .movingLeft:  return .back
        case .steady:      return .idle
        case .searching:   return .searching
        }
    }

    private func cxlSignalSource() -> CXLSignalSource {
        switch coachSignalSource {
        case "Fused":     return .fused
        case "Audio":     return .audio
        case "Camera":    return .camera
        default:          return .searching
        }
    }

    private func requestPermissionsAndConfigure() {
        requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            self.requestAccess(for: .audio) { [weak self] audioGranted in
                guard let self else { return }

                Task { @MainActor in
                    if !videoGranted || !audioGranted {
                        self.statusMessage = "Grant camera and microphone access in System Settings"
                        self.isCameraActive = false
                    } else {
                        self.statusMessage = "Configuring capture session"
                    }
                }

                self.reconfigureSession()
            }
        }
    }

    private func requestAccess(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    func refreshSeratoDirectCapture() {
        refreshDevices()
    }

    func useDirectSeratoCapture() {
        guard let directCaptureDeviceUID, availableAudioDevices.contains(where: { $0.uniqueID == directCaptureDeviceUID }) else {
            refreshDevices()
            return
        }

        selectedAudioDeviceUniqueID = directCaptureDeviceUID
        directCaptureStatus = "\(seratoDirectCaptureDeviceName) is selected and feeding the analyzer."
    }

    func toggleRoutineRecording() {
        isRoutineRecording ? stopRoutineRecording() : startRoutineRecording()
    }

    @MainActor
    func reportRoutineRecordingIssue(_ message: String) {
        routineRecordingStatus = message
    }

    func startRoutineRecording(captureTiming: CaptureTimingMetadata? = nil) {
        let selectedVideoID = selectedVideoDeviceUniqueID
        let selectedAudioID = selectedAudioDeviceUniqueID
        let audioDevices = availableAudioDevices
        let videoDevices = availableVideoDevices

        Task { @MainActor in
            self.isRoutineRecording = true
            self.routineRecordingStatus = "Starting routine recording"
        }

        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            guard !selectedVideoID.isEmpty else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.missingVideo.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard !selectedAudioID.isEmpty else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.missingAudio.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard videoDevices.contains(where: { $0.uniqueID == selectedVideoID }) else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.selectedVideoUnavailable.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard audioDevices.contains(where: { $0.uniqueID == selectedAudioID }) else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.selectedAudioUnavailable.errorDescription ?? "Unable to start recording."
                }
                return
            }

            do {
                if !self.captureSessionHasInput(matching: selectedVideoID, mediaType: .video)
                    || !self.captureSessionHasInput(matching: selectedAudioID, mediaType: .audio) {
                    self.configureCaptureSession(
                        selectedAudioID: selectedAudioID,
                        selectedVideoID: selectedVideoID,
                        audioDevices: audioDevices,
                        videoDevices: videoDevices
                    )
                }

                guard self.captureSession.isRunning else {
                    throw RoutineRecordingError.sessionNotReady
                }
                guard self.captureSessionHasInput(matching: selectedVideoID, mediaType: .video) else {
                    throw RoutineRecordingError.missingVideoConnection
                }
                guard self.captureSessionHasInput(matching: selectedAudioID, mediaType: .audio) else {
                    throw RoutineRecordingError.missingAudioConnection
                }

                let preparedRecording = try self.prepareRoutineRecording(
                    selectedVideoID: selectedVideoID,
                    selectedAudioID: selectedAudioID,
                    videoDevices: videoDevices,
                    audioDevices: audioDevices,
                    captureTiming: captureTiming
                )
                try? CaptureJournalStore.appendTransactionBegan(
                    storageKind: .routine,
                    sessionID: preparedRecording.sidecar.sessionID,
                    takeID: preparedRecording.sidecar.takeID,
                    sidecarFileName: preparedRecording.sidecar.sidecarFileName,
                    mediaFileName: preparedRecording.sidecar.mediaFileName
                )
                try self.writeRoutineRecordingSidecar(preparedRecording.sidecar, to: preparedRecording.sidecarURL)
                self.activeRoutineRecordingSidecar = preparedRecording.sidecar
                self.activeRoutineRecordingSidecarURL = preparedRecording.sidecarURL
                self.audioQueue.sync {
                    self.activeRoutineAudioCaptureWriter = RoutineAudioCaptureWriter(destinationURL: preparedRecording.audioURL)
                    self.publishRoutineAudioCaptureDiagnostics(self.activeRoutineAudioCaptureWriter?.diagnosticsSnapshot())
                }
                Task { @MainActor in
                    self.routineRecordingStatus = "Starting routine recording"
                }
                self.movieOutput.startRecording(to: preparedRecording.mediaURL, recordingDelegate: self)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = message
                }
            }
        }
    }

    func stopRoutineRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                }
                return
            }
            Task { @MainActor in
                self.routineRecordingStatus = "Finishing routine recording"
                if let sidecar = self.activeRoutineRecordingSidecar {
                    self.upsertRoutineTakeArtifactStatus(
                        self.provisionalRoutineTakeArtifactStatus(for: sidecar, readiness: .finalizing)
                    )
                }
            }
            self.movieOutput.stopRecording()
        }
    }

    func refreshDevices() {
        var audioDevices = discoverAudioDevices()
        refreshSeratoDirectCaptureState(discoveredAudioDevices: audioDevices)
        if directCaptureRoute == .privateProcessTap {
            audioDevices = discoverAudioDevices()
        }

        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let discoveredVideoDevices = videoDiscovery.devices
        let companionDeskViewDevices = discoveredVideoDevices
            .filter { !isDeskViewCamera($0) }
            .compactMap(\.companionDeskViewCamera)
        let videoDevices = uniqueVideoDevices(discoveredVideoDevices + companionDeskViewDevices)
            .sorted { $0.localizedName < $1.localizedName }

        availableAudioDevices = audioDevices
        availableVideoDevices = videoDevices
        availableMIDISourceNames = discoverMIDISourceNames()

        if !audioDevices.contains(where: { $0.uniqueID == selectedAudioDeviceUniqueID }) {
            selectedAudioDeviceUniqueID = audioDevices.first?.uniqueID ?? ""
        }

        if !videoDevices.contains(where: { $0.uniqueID == selectedVideoDeviceUniqueID }) {
            selectedVideoDeviceUniqueID = videoDevices.first?.uniqueID ?? ""
        }

        syncDirectCaptureStatus(using: audioDevices)
    }

    func preferMacCameraForDesktopDeck(force: Bool = false) {
        guard let preferredDevice = preferredDesktopDeckCamera else { return }
        guard force || (!isUsingMacCameraForDesktopDeck && !isUsingDeskViewCamera) else { return }
        selectedVideoDeviceUniqueID = preferredDevice.uniqueID
    }

    func preferDeskViewCamera(force: Bool = false) {
        guard let preferredDevice = preferredDeskViewCamera else { return }
        guard force || selectedVideoDeviceUniqueID != preferredDevice.uniqueID else { return }
        selectedVideoDeviceUniqueID = preferredDevice.uniqueID
    }

    @objc private func handleWorkspaceApplicationChange(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              shouldTrackSeratoApplication(application) else {
            return
        }

        DispatchQueue.main.async {
            self.refreshDevices()
        }
    }

    private func shouldTrackSeratoApplication(_ application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier, seratoBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        guard let localizedName = application.localizedName?.lowercased() else { return false }
        return localizedName.contains("serato dj")
    }

    private func refreshSeratoDirectCaptureState(discoveredAudioDevices: [AVCaptureDevice]) {
        guard #available(macOS 14.2, *) else {
            directCaptureStatus = "Direct Serato Capture needs macOS 14.2 or later."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            destroySeratoDirectCapture()
            return
        }

        let runningSeratoApps = runningSeratoApplications()
        let currentProcessIdentifiers = runningSeratoApps.map(\.processIdentifier).sorted()

        guard !currentProcessIdentifiers.isEmpty else {
            directCaptureStatus = "Open Serato DJ Pro to create the ScratchLab Direct Serato input."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            destroySeratoDirectCapture()
            return
        }

        if let seratoVirtualAudioDevice = discoveredAudioDevices.first(where: isSeratoVirtualAudioDevice(_:)) {
            directCaptureDeviceUID = seratoVirtualAudioDevice.uniqueID
            directCaptureRoute = .nativeSeratoVirtualAudio
            directCaptureStatus = isUsingDirectSeratoCapture
                ? "Audio is connected and ready."
                : "Direct Capture is ready."
            destroySeratoDirectCapture()
            return
        }

        if seratoDirectCaptureTapID != 0,
           seratoDirectCaptureAggregateDeviceID != 0,
           currentProcessIdentifiers == seratoDirectCaptureProcessIdentifiers {
            directCaptureDeviceUID = seratoDirectCaptureDeviceUIDValue
            directCaptureRoute = .privateProcessTap
            return
        }

        destroySeratoDirectCapture()

        let processObjectIDs = currentProcessIdentifiers.compactMap(audioProcessObjectID(for:))
        guard !processObjectIDs.isEmpty else {
            directCaptureStatus = "Direct Capture is getting ready."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        let tapDescription = CATapDescription()
        tapDescription.name = seratoDirectCaptureDeviceName
        tapDescription.uuid = UUID()
        tapDescription.processes = processObjectIDs
        tapDescription.isExclusive = false
        tapDescription.isPrivate = true
        tapDescription.isMixdown = true
        tapDescription.isMono = false
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            print("Unable to create Serato process tap: \(tapStatus)")
            directCaptureStatus = "Direct Capture is unavailable right now. Restart Serato and try again."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        let tapDictionary: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: 1
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: seratoDirectCaptureDeviceName,
            kAudioAggregateDeviceUIDKey: seratoDirectCaptureDeviceUIDValue,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapDictionary],
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]

        var aggregateDeviceID = AudioObjectID(0)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            print("Unable to publish Serato direct-capture input: \(aggregateStatus)")
            directCaptureStatus = "Direct Capture is unavailable right now. Restart Serato and try again."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        seratoDirectCaptureTapID = tapID
        seratoDirectCaptureAggregateDeviceID = aggregateDeviceID
        seratoDirectCaptureProcessIdentifiers = currentProcessIdentifiers
        directCaptureDeviceUID = seratoDirectCaptureDeviceUIDValue
        directCaptureRoute = .privateProcessTap
        directCaptureStatus = "Direct Capture is ready. Choose it from Source or use Direct Capture."
    }

    private func discoverAudioDevices() -> [AVCaptureDevice] {
        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return audioDiscovery.devices.sorted { $0.localizedName < $1.localizedName }
    }

    private func runningSeratoApplications() -> [NSRunningApplication] {
        let bundleMatches = seratoBundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        let nameMatches = NSWorkspace.shared.runningApplications.filter(shouldTrackSeratoApplication(_:))
        let uniqueMatches = Dictionary(grouping: bundleMatches + nameMatches, by: \.processIdentifier)
            .compactMap { $0.value.first }

        return uniqueMatches
            .filter { !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func audioProcessObjectID(for processIdentifier: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = processIdentifier
        var processObjectID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &propertySize,
            &processObjectID
        )

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return processObjectID
    }

    private func isSeratoVirtualAudioDevice(_ device: AVCaptureDevice) -> Bool {
        device.localizedName.localizedCaseInsensitiveContains(seratoVirtualAudioDeviceName)
    }

    private func syncDirectCaptureStatus(using audioDevices: [AVCaptureDevice]) {
        guard let directCaptureDeviceUID else { return }

        if audioDevices.contains(where: { $0.uniqueID == directCaptureDeviceUID }) {
            directCaptureStatus = isUsingDirectSeratoCapture
                ? "Audio is connected and ready."
                : "Direct Capture is ready."
        } else if seratoDirectCaptureAggregateDeviceID != 0 {
            directCaptureStatus = "Direct Capture is getting ready."
        }
    }

    private func destroySeratoDirectCapture() {
        if seratoDirectCaptureAggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(seratoDirectCaptureAggregateDeviceID)
            seratoDirectCaptureAggregateDeviceID = 0
        }

        if #available(macOS 14.2, *), seratoDirectCaptureTapID != 0 {
            AudioHardwareDestroyProcessTap(seratoDirectCaptureTapID)
            seratoDirectCaptureTapID = 0
        }

        seratoDirectCaptureProcessIdentifiers.removeAll()
    }

    private func reconfigureSession() {
        let selectedAudioID = selectedAudioDeviceUniqueID
        let selectedVideoID = selectedVideoDeviceUniqueID
        let audioDevices = availableAudioDevices
        let videoDevices = availableVideoDevices

        sessionQueue.async {
            self.configureCaptureSession(
                selectedAudioID: selectedAudioID,
                selectedVideoID: selectedVideoID,
                audioDevices: audioDevices,
                videoDevices: videoDevices
            )

            Task { @MainActor in
                self.lastScratchDetection = nil
                self.scratchDetectionCount = 0
                self.rigLayout = nil
                self.isUsingManualRigGuide = false
                self.highlightedZoneRole = .leftDeck
                self.sessionStars = 0
                self.smoothedHandPoint = nil
                self.missedHandTrackingFrames = 0
                let audioName = audioDevices.first(where: { $0.uniqueID == selectedAudioID })?.localizedName ?? "No audio input"
                let videoName = videoDevices.first(where: { $0.uniqueID == selectedVideoID })?.localizedName ?? "No camera"
                self.statusMessage = "Connected to \(audioName) and \(videoName)."
            }
        }
    }

    private func configureCaptureSession(
        selectedAudioID: String,
        selectedVideoID: String,
        audioDevices: [AVCaptureDevice],
        videoDevices: [AVCaptureDevice]
    ) {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        if let videoDevice = videoDevices.first(where: { $0.uniqueID == selectedVideoID }),
           let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
           captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        if let audioDevice = audioDevices.first(where: { $0.uniqueID == selectedAudioID }),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        captureSession.commitConfiguration()
        scratchDetector.reset()
        rigLayoutDetector.reset()
        videoQueue.async {
            self.clearFixedRigLayout()
            self.resetPublishedVideoState()
        }

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
        Task { @MainActor in
            self.isCameraActive = self.captureSession.isRunning
        }
    }

    private func captureSessionHasInput(matching uniqueID: String, mediaType: AVMediaType) -> Bool {
        captureSession.inputs.contains { input in
            guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
            return deviceInput.device.uniqueID == uniqueID && deviceInput.device.hasMediaType(mediaType)
        }
    }

    private func prepareRoutineRecording(
        selectedVideoID: String,
        selectedAudioID: String,
        videoDevices: [AVCaptureDevice],
        audioDevices: [AVCaptureDevice],
        captureTiming: CaptureTimingMetadata?
    ) throws -> PreparedRoutineRecording {
        let directory = try recordingsDirectoryURL()
        let startedAt = Date()
        let sessionID = recordingSessionConfig?.sessionID
            ?? CaptureCore.LocalRecordingNaming.sessionID()
        let takeIdentity: TakeIdentity
        if let pendingRoutineTakeIdentity {
            takeIdentity = pendingRoutineTakeIdentity
        } else {
            takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(
                sessionID: sessionID,
                takeNumber: try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
            )
        }
        let files = try CaptureCore.LocalRecordingFiles.make(
            in: directory,
            sessionID: sessionID,
            takeNumber: takeIdentity.takeNumber,
            roleLabel: "routine"
        )
        let audioURL = directory
            .appendingPathComponent(files.baseName)
            .appendingPathExtension("wav")

        let videoDeviceName = videoDevices.first(where: { $0.uniqueID == selectedVideoID })?.localizedName ?? "Unknown video input"
        let audioDeviceName = audioDevices.first(where: { $0.uniqueID == selectedAudioID })?.localizedName ?? "Unknown audio input"
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: recordingSessionConfig,
            takeIdentity: takeIdentity,
            files: files,
            recordingRole: "mac_routine_capture",
            platform: "macOS",
            appSurface: "ScratchLab Routine Recorder",
            sourceDeviceName: Host.current().localizedName ?? "Computer",
            videoDeviceUniqueID: selectedVideoID,
            videoDeviceName: videoDeviceName,
            audioDeviceUniqueID: selectedAudioID,
            audioDeviceName: audioDeviceName,
            captureTiming: captureTiming,
            startedAt: startedAt
        )
        let syncedSidecar = pendingWatchReply.map { sidecar.withWatchSync($0) } ?? sidecar
        pendingRoutineTakeIdentity = nil
        pendingWatchReply = nil

        return PreparedRoutineRecording(
            mediaURL: files.mediaURL,
            audioURL: audioURL,
            sidecarURL: files.sidecarURL,
            sidecar: syncedSidecar
        )
    }

    private func recordingsDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        let directory = baseDirectory
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineCaptures", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func finalizeRoutineRecording(outputFileURL: URL, error: Error?) -> (statusMessage: String, sessionID: String?, sidecar: CaptureCore.LocalRecordingSidecar?) {
        defer {
            activeRoutineRecordingSidecar = nil
            activeRoutineRecordingSidecarURL = nil
            pendingRoutineTakeIdentity = nil
            pendingWatchReply = nil
        }

        let captureErrorDescription = error?.localizedDescription
        guard var sidecar = activeRoutineRecordingSidecar else {
            if captureErrorDescription != nil {
                return ("Recording ended before it could be saved.", nil, nil)
            }
            return ("Finalizing \(outputFileURL.lastPathComponent)...", nil, nil)
        }

        sidecar = sidecar.finalized(
            mediaFileName: outputFileURL.lastPathComponent,
            captureErrorDescription: captureErrorDescription
        )
        let sidecarURL = activeRoutineRecordingSidecarURL
            ?? CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: outputFileURL)

        do {
            try? CaptureJournalStore.appendMediaCommitted(
                storageKind: .routine,
                sidecar: sidecar
            )
            try writeRoutineRecordingSidecar(sidecar, to: sidecarURL)
            try? CaptureJournalStore.appendTransactionFinalized(
                storageKind: .routine,
                sidecar: sidecar
            )
            if captureErrorDescription != nil {
                return ("Recording ended before it could be saved completely.", nil, sidecar)
            }
            return ("Finalizing \(outputFileURL.lastPathComponent)...", sidecar.sessionID, sidecar)
        } catch {
            if captureErrorDescription != nil {
                return ("Recording ended before it could be saved completely.", nil, sidecar)
            }
            return ("Finalizing \(outputFileURL.lastPathComponent)...", nil, sidecar)
        }
    }

    private func writeRoutineRecordingSidecar(_ sidecar: CaptureCore.LocalRecordingSidecar, to url: URL) throws {
        let data = try sidecar.encodedData()
        try data.write(to: url, options: .atomic)
        try? CaptureAuditStore.persist(sidecar: sidecar, storageKind: .routine)
    }

    private func recoverInterruptedRoutineCaptures() {
        do {
            let directory = try recordingsDirectoryURL()
            let report = StagedCaptureRecoveryManager().recoverRecordingDirectory(
                at: directory,
                storageKind: .routine
            )
            if let summaryText = report.summaryText {
                routineRecordingStatus = summaryText
            }
        } catch {
            routineRecordingStatus = "Routine capture recovery needs attention."
        }
    }

    private func restoreLatestCompletedRoutineCapture() {
        guard !isRoutineRecording else { return }

        do {
            let directory = try recordingsDirectoryURL()
            let preferredSessionID = recordingSessionConfig?.sessionID
            guard let snapshot = Self.latestCompletedRoutineCapture(
                in: directory,
                preferredSessionID: preferredSessionID
            ) else {
                if preferredSessionID != nil {
                    lastRoutineRecordingURL = nil
                    lastRoutineRecordingSessionID = nil
                }
                return
            }

            lastRoutineRecordingURL = snapshot.mediaURL
            lastRoutineRecordingSessionID = snapshot.sessionID
            routineRecordingStatus = "Ready to export \(snapshot.mediaURL.lastPathComponent)."
        } catch {
            routineRecordingStatus = "Routine capture recovery needs attention."
        }
    }

    private func refreshRoutineArtifactStatuses() {
        routineArtifactRefreshTask?.cancel()
        guard let directory = routineRecordingsFolderURL,
              let lastRoutineRecordingURL else {
            routineTakeArtifactStatuses = []
            return
        }

        let lastURL = lastRoutineRecordingURL
        routineArtifactRefreshTask = Task { [weak self] in
            let statuses = await Task.detached(priority: .userInitiated) {
                SessionArchiveBuilder().localRecordingArtifactStatuses(
                    lastRecordingURL: lastURL
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.routineRecordingsFolderURL == directory else { return }
                self.routineTakeArtifactStatuses = statuses
                if let latest = statuses.last {
                    self.applyRoutineArtifactStatusToMessage(latest)
                }
            }
        }
    }

    @MainActor
    private func applyRoutineArtifactStatusToMessage(_ status: TakeArtifactStatusSnapshot) {
        let takeLabel = "Take \(String(format: "%03d", status.takeNumber))"
        switch status.readiness {
        case .recording:
            routineRecordingStatus = "Recording \(takeLabel.lowercased())"
        case .finalizing:
            routineRecordingStatus = "\(takeLabel) is finalizing..."
        case .ready:
            if let videoSourceURL = status.videoSourceURL {
                routineRecordingStatus = "Ready to export \(videoSourceURL.lastPathComponent)."
            } else {
                routineRecordingStatus = "\(takeLabel) is ready to export."
            }
        case .missingAudio:
            routineRecordingStatus = "\(takeLabel) audio is missing or still finalizing."
        case .missingVideo:
            routineRecordingStatus = "\(takeLabel) video is missing or still finalizing."
        case .failed(let message):
            routineRecordingStatus = "\(takeLabel) failed: \(message)"
        }
    }

    @MainActor
    private func upsertRoutineTakeArtifactStatus(_ status: TakeArtifactStatusSnapshot) {
        var statuses = routineTakeArtifactStatuses.filter { $0.takeID != status.takeID }
        statuses.append(status)
        routineTakeArtifactStatuses = statuses.sorted { lhs, rhs in
            if lhs.takeNumber == rhs.takeNumber {
                return lhs.takeID < rhs.takeID
            }
            return lhs.takeNumber < rhs.takeNumber
        }
        applyRoutineArtifactStatusToMessage(status)
    }

    private func provisionalRoutineTakeArtifactStatus(
        for sidecar: CaptureCore.LocalRecordingSidecar,
        readiness: TakeArtifactReadiness
    ) -> TakeArtifactStatusSnapshot {
        let baseDirectory = activeRoutineRecordingSidecarURL?.deletingLastPathComponent()
            ?? routineRecordingsFolderURL
            ?? FileManager.default.temporaryDirectory
        let mediaURL = baseDirectory.appendingPathComponent(sidecar.mediaFileName)
        let audioURL = baseDirectory
            .appendingPathComponent(mediaURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")
        let videoExists = FileManager.default.fileExists(atPath: mediaURL.path)
        let audioExists = FileManager.default.fileExists(atPath: audioURL.path)
        return TakeArtifactStatusSnapshot(
            takeID: sidecar.takeID,
            takeNumber: sidecar.appLocalTakeNumber,
            bpm: sidecar.sessionConfig?.bpm,
            audioSourceURL: audioURL,
            videoSourceURL: mediaURL,
            audioExists: audioExists,
            videoExists: videoExists,
            audioBytes: fileSizeOrZero(at: audioURL),
            videoBytes: fileSizeOrZero(at: mediaURL),
            finalizedAt: sidecar.endedAt,
            readiness: readiness
        )
    }

    private func fileSizeOrZero(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func latestCompletedRoutineCapture(
        in directory: URL,
        preferredSessionID: String? = nil,
        fileManager: FileManager = .default
    ) -> CompletedRoutineCaptureSnapshot? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { sidecarURL -> CompletedRoutineCaptureSnapshot? in
                guard let data = try? Data(contentsOf: sidecarURL),
                      let sidecar = try? routineSidecarDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data),
                      sidecar.recordingStatus == "completed" else {
                    return nil
                }
                if let preferredSessionID, sidecar.sessionID != preferredSessionID {
                    return nil
                }

                let mediaURL = directory.appendingPathComponent(sidecar.mediaFileName)
                guard fileManager.fileExists(atPath: mediaURL.path) else { return nil }

                return CompletedRoutineCaptureSnapshot(
                    mediaURL: mediaURL,
                    sidecarURL: sidecarURL,
                    sessionID: sidecar.sessionID,
                    takeID: sidecar.takeID,
                    endedAt: sidecar.endedAt ?? sidecar.startedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.endedAt != rhs.endedAt {
                    return lhs.endedAt > rhs.endedAt
                }
                return lhs.mediaURL.lastPathComponent > rhs.mediaURL.lastPathComponent
            }
            .first
    }

    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let signpostID = ScratchLabPerformanceSignpost.begin("CameraFrameProcess")
        defer { ScratchLabPerformanceSignpost.end("CameraFrameProcess", signpostID) }

        let now = CACurrentMediaTime()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        #if DEBUG
        debugFramesReceived += 1
        #endif

        let detectedLayout = fixedRigLayout == nil
            ? rigLayoutDetector.detectLayout(in: pixelBuffer, useLockedCadence: calibrationLocked)
            : nil
        let resolvedLayout = resolveFixedRigLayout(from: detectedLayout)
        let calibratedLayout = applyCalibration(to: resolvedLayout)
        let perspectiveLayout = applyPerspective(to: calibratedLayout)
        let layout = applyZoneCalibration(to: perspectiveLayout)
        let usesManualRigGuide = layout != nil && fixedRigLayoutUsesManualGuide
        publishRigLayoutIfNeeded(layout, usesManualRigGuide: usesManualRigGuide)
        if shouldPublishPerformerMonitorFrame {
            publishPerformerMonitorFrame(from: pixelBuffer, layout: layout, at: now)
        }

        // Hand pose always runs at the active rate; the rig detector manages its own cadence.
        guard now - lastVisionFrameTime >= activeHandPoseInterval else { return }
        lastVisionFrameTime = now

        #if DEBUG
        debugFramesAnalyzed += 1
        let trackingRegion = resolvedHandTrackingRegion(for: layout)
        debugLastROI = trackingRegion
        #else
        let trackingRegion = resolvedHandTrackingRegion(for: layout)
        #endif

        handPoseRequest.regionOfInterest = trackingRegion
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try requestHandler.perform([handPoseRequest])
            guard let observation = handPoseRequest.results?.first,
                  let rawTrackedPoint = trackedHandPoint(from: observation, layout: layout, trackingRegion: trackingRegion) else {
                handleHandTrackingMiss()
                return
            }

            #if DEBUG
            debugHandObservationsFound += 1
            let prevState = lastPublishedHandMotionState
            #endif

            missedHandTrackingFrames = 0

            // Feed the raw point into the tracker (unsmoothed = accurate velocity).
            let direction = handDirectionTracker.recordObservation(rawPoint: rawTrackedPoint, at: now)
            let movementState = handMotionState(from: direction)

            #if DEBUG
            if movementState != prevState { debugDirectionChanges += 1 }
            #endif

            // Use the smoothed point only for display position.
            let currentPoint = smoothedTrackingPoint(from: rawTrackedPoint)
            publishHandTrackingIfNeeded(detected: true, position: currentPoint, state: movementState)
        } catch {
            Task { @MainActor in
                self.statusMessage = "Hand tracking paused. Adjust framing and try again."
            }
        }
    }

    private func handMotionState(from direction: HandDirectionTracker.Direction) -> HandMotionState {
        // Vision uses un-mirrored pixel-buffer coordinates on macOS (AVCaptureVideoDataOutput
        // does not mirror; only the preview layer mirrors for front-facing cameras).
        // Convention: x increases rightward in the frame. For a front-facing camera looking at
        // the DJ, frame-right = DJ's physical left. A right-hand forward scratch stroke moves
        // the hand to the DJ's left → frame-right → x increases → .movingForward.
        // Desk View (top-down) maps differently; that limitation is documented in HandDirectionTracker.
        switch direction {
        case .movingForward:  return .movingRight
        case .movingBackward: return .movingLeft
        case .idle:           return .steady
        case .searching:      return .searching
        }
    }

    private func publishPerformerMonitorFrame(from pixelBuffer: CVPixelBuffer, layout: DJRigLayout?, at now: CFTimeInterval) {
        guard now - lastPerformerMonitorFrameTime >= 0.20 else { return }
        lastPerformerMonitorFrameTime = now

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        guard sourceWidth > 0 else { return }

        let maxOutputWidth: CGFloat = 960
        let scale = min(maxOutputWidth / sourceWidth, 1)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let outputImage = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = performerMonitorCIContext.jpegRepresentation(
            of: outputImage,
            colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55]
        ) else {
            return
        }

        let zones = (layout?.zones ?? []).map { zone in
            PerformerMonitorZone(
                role: zone.role.rawValue,
                title: zone.role.title,
                minX: zone.boundingBox.minX,
                minY: zone.boundingBox.minY,
                width: zone.boundingBox.width,
                height: zone.boundingBox.height
            )
        }

        DispatchQueue.main.async {
            self.performerMonitorFrame = PerformerMonitorFrame(
                timestamp: Date().timeIntervalSince1970,
                jpegData: jpegData,
                guidanceCue: self.babyScratchGuidanceCue,
                guidanceDetail: self.babyScratchGuidanceDetail,
                scratchStatusTitle: self.scratchStatusTitle,
                rigStatusTitle: self.rigStatusTitle,
                audioPercent: self.formattedAudioPercent,
                detectionCount: self.scratchDetectionCount,
                highlightedZoneRole: self.highlightedZoneRole.rawValue,
                zones: zones
            )
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let signpostID = ScratchLabPerformanceSignpost.begin("AudioAnalyze")
        defer { ScratchLabPerformanceSignpost.end("AudioAnalyze", signpostID) }

        guard let audioPacket = Self.audioPacket(from: sampleBuffer) else { return }

        let measuredLevel = Self.level(from: audioPacket.samples)
        let hasFiniteMeasuredLevel = measuredLevel.isFinite
        let sanitizedLevel = hasFiniteMeasuredLevel ? min(max(measuredLevel, 0), 1) : 0
        let detection = scratchDetector.process(samples: audioPacket.samples, sampleRate: audioPacket.sampleRate)
        let now = CACurrentMediaTime()
        let shouldPublishAudioLevel = now - lastPublishedAudioLevelTime >= audioLevelPublishInterval
        if shouldPublishAudioLevel {
            lastPublishedAudioLevelTime = now
        }

        guard shouldPublishAudioLevel || detection != nil else { return }

        Task { @MainActor in
            if shouldPublishAudioLevel {
                self.publishAudioSignalLevel(
                    hasFiniteMeasuredLevel ? sanitizedLevel : nil,
                    receivedAt: now
                )
            }
            if let detection {
                self.lastScratchDetection = detection
                self.scratchDetectionCount += 1
                self.rewardScratchIfNeeded(detection)
                if self.cxlRecorder.isRecording {
                    self.cxlRecorder.recordAudioScratch(
                        confidence: detection.confidence / 100.0,
                        rms: nil,
                        onset: true
                    )
                    self.publishCXLState()
                }
            }
        }
    }

    private func rewardScratchIfNeeded(_ detection: MacScratchDetectionResult) {
        guard detection.accuracy >= 45 else { return }

        let now = Date()
        if let lastStarAwardAt, now.timeIntervalSince(lastStarAwardAt) < 0.45 {
            return
        }
        lastStarAwardAt = now

        sessionStars += 1
        let roles = DJRigZone.Role.allCases
        let currentIndex = roles.firstIndex(of: highlightedZoneRole) ?? 0
        highlightedZoneRole = roles[(currentIndex + 1) % roles.count]
    }

    private func resolveFixedRigLayout(from detectedLayout: DJRigLayout?) -> DJRigLayout? {
        // Invariant: once fixedRigLayout is set it is frozen until the user explicitly resets
        // (resetCalibration, camera source change, manualRigGuideEnabled toggle, or stop).
        // The rig detector is skipped entirely when fixedRigLayout != nil (see processVideoSampleBuffer),
        // so live detection can never silently shift the hand ROI after the first lock.
        if let fixedRigLayout {
            return fixedRigLayout
        }

        if let detectedLayout {
            fixedRigLayout = detectedLayout
            fixedRigLayoutUsesManualGuide = false
            return detectedLayout
        }

        guard manualRigGuideEnabled else { return nil }
        let fallbackLayout = manualFallbackLayout()
        fixedRigLayout = fallbackLayout
        fixedRigLayoutUsesManualGuide = true
        return fallbackLayout
    }

    private func applyCalibration(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }
        let adjustedUnion = adjustedBoundingBox(layout.unionBox)
        return DJRigLayout(zones: DJRigLayout.zones(in: adjustedUnion, tuning: currentZoneTuning), confidence: layout.confidence)
    }

    private func applyZoneCalibration(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }

        let adjustedZones = layout.zones.map { zone in
            DJRigZone(
                role: zone.role,
                boundingBox: adjustedBoundingBox(zone.boundingBox, using: zoneAdjustment(for: zone.role))
            )
        }

        return DJRigLayout(zones: adjustedZones, confidence: layout.confidence)
    }

    private func manualFallbackLayout() -> DJRigLayout {
        let union: CGRect
        if isUsingDeskViewCamera {
            union = CGRect(x: 0.03, y: 0.08, width: 0.94, height: 0.62)
        } else {
            union = CGRect(x: 0.12, y: 0.18, width: 0.76, height: 0.48)
        }
        return DJRigLayout(zones: DJRigLayout.zones(in: union, tuning: currentZoneTuning), confidence: 0.32)
    }

    private func trackedHandPoint(from observation: VNHumanHandPoseObservation, layout: DJRigLayout?, trackingRegion: CGRect) -> CGPoint? {
        let deckZones = layout?.zones.filter { $0.role != .mixer } ?? []
        let mixerZone = layout?.zone(for: .mixer)
        let highlightedZone = layout?.zone(for: highlightedZoneRole)
        let jointNames: [VNHumanHandPoseObservation.JointName] = [
            .indexTip, .middleTip, .ringTip, .littleTip, .thumbTip,
            .indexDIP, .middleDIP, .ringDIP, .littleDIP, .thumbIP,
            .indexPIP, .middlePIP, .ringPIP, .littlePIP,
            .wrist
        ]
        let jointWeights: [VNHumanHandPoseObservation.JointName: CGFloat] = [
            .indexTip: 1.0,
            .middleTip: 0.95,
            .ringTip: 0.85,
            .littleTip: 0.7,
            .thumbTip: 0.75,
            .indexDIP: 0.78,
            .middleDIP: 0.74,
            .ringDIP: 0.66,
            .littleDIP: 0.58,
            .thumbIP: 0.55,
            .indexPIP: 0.42,
            .middlePIP: 0.40,
            .ringPIP: 0.34,
            .littlePIP: 0.28,
            .wrist: 0.12
        ]

        var bestCandidate: (point: CGPoint, score: CGFloat)?

        for jointName in jointNames {
            guard let recognizedPoint = try? observation.recognizedPoint(jointName),
                  recognizedPoint.confidence >= 0.16 else {
                continue
            }

            let point = recognizedPoint.location
            guard trackingRegion.contains(point) else { continue }

            var score = CGFloat(recognizedPoint.confidence) * 1.6
            score += jointWeights[jointName] ?? 0
            score += (1 - point.y) * 0.95

            if deckZones.contains(where: { expanded($0.boundingBox, dx: 0.04, dy: 0.08).contains(point) }) {
                score += 0.45
            } else {
                score -= 0.18
            }

            if let highlightedZone, expanded(highlightedZone.boundingBox, dx: 0.03, dy: 0.08).contains(point) {
                score += 0.25
            }

            if let mixerZone, expanded(mixerZone.boundingBox, dx: 0.02, dy: 0.06).contains(point) {
                score -= 0.22
            }

            if let bestCandidate, score <= bestCandidate.score {
                continue
            }
            bestCandidate = (point, score)
        }

        return bestCandidate?.point
    }

    private func preferredHandTrackingRegion(for layout: DJRigLayout?) -> CGRect {
        let base = layout?.unionBox ?? CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.72)
        return expanded(base, dx: 0.10, dy: 0.18)
            .intersection(CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.94))
    }

    private func resolvedHandTrackingRegion(for layout: DJRigLayout?) -> CGRect {
        let region = preferredHandTrackingRegion(for: layout)
        guard !region.isNull, !region.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return region
    }

    private func smoothedTrackingPoint(from point: CGPoint) -> CGPoint {
        guard let smoothedHandPoint else {
            self.smoothedHandPoint = point
            return point
        }

        let alpha: CGFloat = 0.34
        let smoothed = CGPoint(
            x: smoothedHandPoint.x + ((point.x - smoothedHandPoint.x) * alpha),
            y: smoothedHandPoint.y + ((point.y - smoothedHandPoint.y) * alpha)
        )
        self.smoothedHandPoint = smoothed
        return smoothed
    }

    private func handleHandTrackingMiss() {
        missedHandTrackingFrames += 1

        #if DEBUG
        debugMissedFrameCount += 1
        #endif

        let direction = handDirectionTracker.recordMiss()

        if direction == .searching {
            // Extended miss — clear all hand state.
            smoothedHandPoint = nil
            publishHandTrackingIfNeeded(detected: false, position: nil, state: .searching)
        } else {
            // Brief miss — hold the last position and direction so the coach doesn't flicker.
            let movementState = handMotionState(from: direction)
            publishHandTrackingIfNeeded(
                detected: smoothedHandPoint != nil,
                position: smoothedHandPoint,
                state: movementState
            )
        }
    }

    private var shouldPublishPerformerMonitorFrame: Bool {
        performerMonitorDemandQueue.sync { performerMonitorStreamingEnabled }
    }

    private var shouldProcessCaptureSamples: Bool {
        isRunning || isRoutineRecording || cxlRecorder.isRecording || shouldPublishPerformerMonitorFrame
    }

    private func publishRigLayoutIfNeeded(_ layout: DJRigLayout?, usesManualRigGuide: Bool) {
        guard lastPublishedRigLayout != layout || lastPublishedUsesManualRigGuide != usesManualRigGuide else {
            return
        }

        lastPublishedRigLayout = layout
        lastPublishedUsesManualRigGuide = usesManualRigGuide

        Task { @MainActor in
            self.rigLayout = layout
            self.isUsingManualRigGuide = usesManualRigGuide
        }
    }

    private func publishHandTrackingIfNeeded(detected: Bool, position: CGPoint?, state: HandMotionState) {
        let stateChanged = lastPublishedHandMotionState != state
        guard lastPublishedHandDetected != detected
            || lastPublishedHandPosition != position
            || stateChanged else {
            return
        }

        let prevState = lastPublishedHandMotionState
        lastPublishedHandDetected = detected
        lastPublishedHandPosition = position
        lastPublishedHandMotionState = state

        // Capture tracker values before crossing thread boundary.
        let motionConfidence = Double(handDirectionTracker.confidence)
        let cxlDir = cxlDirectionFrom(state)
        let cxlSrc = cxlSignalSource()
        let cxlPrevDir = cxlDirectionFrom(prevState)

        Task { @MainActor in
            self.handDetected = detected
            self.handPosition = position
            self.handMotionState = state

            // CXL: record motion stroke on active-direction transitions.
            if self.cxlRecorder.isRecording && stateChanged {
                let wasActive = prevState == .movingLeft || prevState == .movingRight
                let nowActive = state == .movingLeft || state == .movingRight
                _ = cxlPrevDir  // suppress unused warning
                if nowActive || (wasActive && !nowActive) {
                    self.cxlRecorder.recordMotionStroke(
                        detectedDirection: cxlDir,
                        confidence: motionConfidence,
                        signalSource: cxlSrc,
                        handX: position.map { Double($0.x) },
                        handY: position.map { Double($0.y) }
                    )
                    self.publishCXLState()
                }
            }

            // CXL: periodic sample (throttled inside recordSample).
            if self.cxlRecorder.isRecording {
                self.cxlRecorder.recordSample(
                    targetDirection: nil,
                    detectedDirection: cxlDir,
                    handX: position.map { Double($0.x) },
                    handY: position.map { Double($0.y) },
                    motionConfidence: motionConfidence,
                    audioConfidence: self.recentAudioScratchConfidence,
                    signalSource: cxlSrc,
                    timingErrorMs: nil,
                    calibrationLocked: self.calibrationLocked
                )
                self.publishCXLState()
            }
        }
    }

    private func resetPublishedVideoState() {
        handDirectionTracker.reset()
        smoothedHandPoint = nil
        missedHandTrackingFrames = 0
        lastPublishedRigLayout = nil
        lastPublishedUsesManualRigGuide = false
        lastPublishedHandDetected = false
        lastPublishedHandPosition = nil
        lastPublishedHandMotionState = .searching
    }

    private func expanded(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        rect.insetBy(dx: -dx, dy: -dy)
    }

    private func applyPerspective(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }

        let sortedZones = layout.zones.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        let shouldUseDJPerspective = useDJPerspective && !isUsingDeskViewCamera
        let orderedRoles: [DJRigZone.Role] = shouldUseDJPerspective
            ? [.rightDeck, .mixer, .leftDeck]
            : [.leftDeck, .mixer, .rightDeck]

        let remappedZones = zip(sortedZones, orderedRoles).map { zone, role in
            DJRigZone(role: role, boundingBox: zone.boundingBox)
        }

        return DJRigLayout(zones: remappedZones, confidence: layout.confidence)
    }

    private func adjustedBoundingBox(_ rect: CGRect) -> CGRect {
        let widthScale = CGFloat(rigWidthScale)
        let heightScale = CGFloat(rigHeightScale)
        let offsetX = CGFloat(rigHorizontalOffset)
        let offsetY = CGFloat(rigVerticalOffset)

        let scaledWidth = min(max(rect.width * widthScale, 0.08), 0.98)
        let scaledHeight = min(max(rect.height * heightScale, 0.08), 0.96)
        let centerX = rect.midX + offsetX
        let centerY = rect.midY + offsetY

        let proposed = CGRect(
            x: centerX - (scaledWidth / 2),
            y: centerY - (scaledHeight / 2),
            width: scaledWidth,
            height: scaledHeight
        )

        return proposed.intersection(CGRect(x: 0.01, y: 0.02, width: 0.98, height: 0.96))
    }

    private func adjustedBoundingBox(_ rect: CGRect, using adjustment: ZoneAdjustment) -> CGRect {
        let widthScale = CGFloat(adjustment.widthScale)
        let heightScale = CGFloat(adjustment.heightScale)
        let offsetX = CGFloat(adjustment.offsetX)
        let offsetY = CGFloat(adjustment.offsetY)

        let scaledWidth = min(max(rect.width * widthScale, 0.05), 0.98)
        let scaledHeight = min(max(rect.height * heightScale, 0.05), 0.96)
        let centerX = rect.midX + offsetX
        let centerY = rect.midY + offsetY

        let minX = max(0.01, min(centerX - (scaledWidth / 2), 0.99 - scaledWidth))
        let minY = max(0.02, min(centerY - (scaledHeight / 2), 0.98 - scaledHeight))

        return CGRect(x: minX, y: minY, width: scaledWidth, height: scaledHeight)
    }

    private var preferredDesktopDeckCamera: AVCaptureDevice? {
        availableVideoDevices.first(where: isBuiltInMacCamera) ?? availableVideoDevices.first
    }

    private var currentZoneTuning: DJRigZoneTuning {
        let base = isUsingDeskViewCamera ? DJRigZoneTuning.deskView : DJRigZoneTuning.standard
        return base.withMixerShare(CGFloat(mixerWidthRatio))
    }

    private var preferredDeskViewCamera: AVCaptureDevice? {
        if let selectedVideoDevice,
           let companionDeskViewCamera = selectedVideoDevice.companionDeskViewCamera {
            return companionDeskViewCamera
        }

        if let continuityCompanion = availableVideoDevices
            .filter({ !isDeskViewCamera($0) })
            .compactMap(\.companionDeskViewCamera)
            .first {
            return continuityCompanion
        }

        return availableVideoDevices.first(where: isDeskViewCamera)
    }

    private func uniqueVideoDevices(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seenDeviceIDs: Set<String> = []
        var uniqueDevices: [AVCaptureDevice] = []

        for device in devices where seenDeviceIDs.insert(device.uniqueID).inserted {
            uniqueDevices.append(device)
        }

        return uniqueDevices
    }

    private func isDeskViewCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .deskViewCamera || device.localizedName.localizedCaseInsensitiveContains("Desk View")
    }

    private func isBuiltInMacCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInWideAngleCamera || device.localizedName.localizedCaseInsensitiveContains("MacBook")
    }

    private func isPhoneContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera
            || device.modelID.localizedCaseInsensitiveContains("iPhone")
            || device.localizedName.localizedCaseInsensitiveContains("iPhone")
    }

    private func setZoneAdjustment(_ adjustment: ZoneAdjustment, for role: DJRigZone.Role) {
        var updated = zoneAdjustments
        if adjustment.isIdentity {
            updated.removeValue(forKey: role)
        } else {
            updated[role] = adjustment
        }
        zoneAdjustments = updated
    }

    private func clearFixedRigLayout(prioritizeDetection: Bool = false) {
        fixedRigLayout = nil
        fixedRigLayoutUsesManualGuide = false
        if prioritizeDetection {
            rigLayoutDetector.prioritizeNextDetection()
        }
    }

    private static func loadZoneAdjustments() -> [DJRigZone.Role: ZoneAdjustment] {
        guard let data = UserDefaults.standard.data(forKey: ScratchLabDesktopDefaultsKey.zoneAdjustmentsData),
              let storedAdjustments = try? JSONDecoder().decode([StoredZoneAdjustment].self, from: data) else {
            return [:]
        }

        return storedAdjustments.reduce(into: [:]) { partial, stored in
            guard let role = DJRigZone.Role(rawValue: stored.role) else { return }
            partial[role] = ZoneAdjustment(
                offsetX: stored.offsetX,
                offsetY: stored.offsetY,
                widthScale: stored.widthScale,
                heightScale: stored.heightScale
            )
        }
    }

    private static func persistZoneAdjustments(_ zoneAdjustments: [DJRigZone.Role: ZoneAdjustment]) {
        let storedAdjustments = zoneAdjustments.map { role, adjustment in
            StoredZoneAdjustment(
                role: role.rawValue,
                offsetX: adjustment.offsetX,
                offsetY: adjustment.offsetY,
                widthScale: adjustment.widthScale,
                heightScale: adjustment.heightScale
            )
        }.sorted { $0.role < $1.role }

        if let data = try? JSONEncoder().encode(storedAdjustments) {
            UserDefaults.standard.set(data, forKey: ScratchLabDesktopDefaultsKey.zoneAdjustmentsData)
        }
    }

    private struct AudioPacket {
        let samples: [Float]
        let sampleRate: Double
    }

    private static func audioPacket(from sampleBuffer: CMSampleBuffer) -> AudioPacket? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1,
                                              mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        var channelSamples: [[Float]] = []

        for buffer in buffers {
            guard let rawData = buffer.mData else { continue }

            if isFloat && bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                channelSamples.append(Array(UnsafeBufferPointer(start: samples, count: sampleCount)))
            } else if bitsPerChannel == 16 {
                let samples = rawData.assumingMemoryBound(to: Int16.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int16.max) })
            } else if bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Int32.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int32.max) })
            }
        }

        guard !channelSamples.isEmpty else { return nil }

        let monoSamples: [Float]
        if buffers.count == 1 && channelCount > 1 && !isNonInterleaved {
            let interleaved = channelSamples[0]
            let frameCount = interleaved.count / channelCount
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channelIndex in 0..<channelCount {
                    frameSum += interleaved[(frameIndex * channelCount) + channelIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelCount)
            }
            monoSamples = downmixed
        } else if channelSamples.count > 1 {
            let frameCount = channelSamples.map(\.count).min() ?? 0
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channel in channelSamples {
                    frameSum += channel[frameIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelSamples.count)
            }
            monoSamples = downmixed
        } else {
            monoSamples = channelSamples[0]
        }

        return AudioPacket(samples: monoSamples, sampleRate: asbd.mSampleRate)
    }

    private static func level(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return min(max(rms * 10, 0), 1)
    }

    @MainActor
    func publishAudioSignalLevel(_ measuredLevel: Float?, receivedAt: CFTimeInterval = CACurrentMediaTime()) {
        lastReceivedAudioSampleTime = receivedAt
        lastPublishedAudioLevelTime = receivedAt

        guard let measuredLevel, measuredLevel.isFinite else {
            if !hasPublishedAudioLevel {
                audioLevel = 0
            }
            return
        }

        let sanitizedLevel = min(max(measuredLevel, 0), 1)
        let currentLevel = audioLevel.isFinite ? audioLevel : 0
        audioLevel = min(max((currentLevel * 0.55) + (sanitizedLevel * 0.45), 0), 1)
        hasPublishedAudioLevel = true
    }

    func refreshAudioSignalForCurrentTime(now: CFTimeInterval = CACurrentMediaTime()) {
        guard hasPublishedAudioLevel else { return }
        guard lastReceivedAudioSampleTime > 0,
              now - lastReceivedAudioSampleTime >= audioSignalStaleInterval else { return }
        resetAudioSignalLevel()
    }

    func resetAudioSignalLevel() {
        audioLevel = 0
        hasPublishedAudioLevel = false
        lastReceivedAudioSampleTime = 0
        lastPublishedAudioLevelTime = 0
    }

    private func appendRoutineAudioSampleBufferIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard isRoutineRecording || movieOutput.isRecording,
              let writer = activeRoutineAudioCaptureWriter else { return }
        writer.append(sampleBuffer)
        publishRoutineAudioCaptureDiagnostics(writer.diagnosticsSnapshot())
    }

    private func publishRoutineAudioCaptureDiagnostics(_ snapshot: RoutineAudioCaptureDiagnosticsSnapshot?) {
        Task { @MainActor in
            self.routineAudioBuffersReceived = snapshot?.buffersReceived ?? 0
            self.routineAudioBuffersAppended = snapshot?.buffersAppended ?? 0
            self.routineAudioBuffersSkipped = snapshot?.buffersSkipped ?? 0
            self.lastRoutineAudioWriterError = snapshot?.lastErrorMessage
        }
    }

    private func startAudioSignalDecayTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(
            deadline: .now() + audioSignalDecayPollInterval,
            repeating: audioSignalDecayPollInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshAudioSignalForCurrentTime()
            }
        }
        audioSignalDecayTimer = timer
        timer.resume()
    }

    private func discoverMIDISourceNames() -> [String] {
        var names: [String] = []
        let sourceCount = MIDIGetNumberOfSources()
        guard sourceCount > 0 else { return names }

        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            var unmanagedName: Unmanaged<CFString>?
            let propertyStatus = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
            let trimmedName = (propertyStatus == noErr ? unmanagedName?.takeRetainedValue() as String? : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let trimmedName, !trimmedName.isEmpty {
                names.append(trimmedName)
            }
        }

        return Array(Set(names)).sorted()
    }

    #if DEBUG
    /// Snapshot of detection counters for in-session debugging.
    struct DebugStats {
        let framesReceived: Int
        let framesAnalyzed: Int
        let handObservationsFound: Int
        let directionChanges: Int
        let missedFrames: Int
        let currentROI: CGRect
        let audioScratchCount: Int
    }

    func captureDebugStats() -> DebugStats {
        DebugStats(
            framesReceived: debugFramesReceived,
            framesAnalyzed: debugFramesAnalyzed,
            handObservationsFound: debugHandObservationsFound,
            directionChanges: debugDirectionChanges,
            missedFrames: debugMissedFrameCount,
            currentROI: debugLastROI,
            audioScratchCount: scratchDetectionCount
        )
    }
    #endif
}

extension MacCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            appendRoutineAudioSampleBufferIfNeeded(sampleBuffer)
        }
        guard shouldProcessCaptureSamples else { return }
        let signpostID = ScratchLabPerformanceSignpost.begin("CaptureFrameProcess")
        defer { ScratchLabPerformanceSignpost.end("CaptureFrameProcess", signpostID) }

        if output is AVCaptureVideoDataOutput {
            processVideoSampleBuffer(sampleBuffer)
        } else {
            processAudioSampleBuffer(sampleBuffer)
        }
    }
}

extension MacCaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.isRoutineRecording = true
            self.routineRecordingStatus = "Recording \(fileURL.lastPathComponent)"
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        audioQueue.sync {
            let snapshot = self.activeRoutineAudioCaptureWriter?.diagnosticsSnapshot()
            self.activeRoutineAudioCaptureWriter = nil
            self.publishRoutineAudioCaptureDiagnostics(snapshot)
        }
        let completion = finalizeRoutineRecording(outputFileURL: outputFileURL, error: error)
        Task { @MainActor in
            self.isRoutineRecording = false

            if error == nil {
                self.lastRoutineRecordingURL = outputFileURL
                if let sidecar = completion.sidecar {
                    self.upsertRoutineTakeArtifactStatus(
                        self.provisionalRoutineTakeArtifactStatus(for: sidecar, readiness: .finalizing)
                    )
                }
            }

            self.lastRoutineRecordingSessionID = completion.sessionID
            self.routineRecordingStatus = completion.statusMessage
            self.refreshRoutineArtifactStatuses()
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let red = Double((int >> 16) & 0xFF) / 255.0
        let green = Double((int >> 8) & 0xFF) / 255.0
        let blue = Double(int & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
