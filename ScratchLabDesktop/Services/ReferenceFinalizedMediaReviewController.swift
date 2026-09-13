import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class ReferenceFinalizedMediaReviewController: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case playing(repetition: Int)
        case playingTake
        case stopped
        case missingAudio
        case missingVideo
        case unreadableMedia(String)
        case durationMismatch(wav: Double, mov: Double)
        case synchronizationUnavailable(String)
    }

    @Published private(set) var state: State = .synchronizationUnavailable("No finalized take is loaded.")
    @Published private(set) var boundBeatID: String?
    @Published private(set) var boundProductionMasterURL: URL?
    @Published private(set) var boundSparseAnalysisURL: URL?

    private var audioPlayer: AVPlayer?
    @Published private(set) var videoPlayer: AVPlayer?
    @Published private(set) var beatBindingIssue: String?
    @Published private(set) var secondaryCameraMessage: String?
    @Published private(set) var playbackMessage: String?
    private(set) var durationSeconds: Double = 0
    private var seekTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = UUID()
    private var loadedTakeID: String?

    func load(take: ReferenceAuthoringTake, mediaURL: URL?, beatRootURL: URL?) {
        loadTask?.cancel()
        stop()
        loadGeneration = UUID()
        let generation = loadGeneration
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        state = .loading
        loadedTakeID = take.evidence.metadata.referenceTakeID
        audioPlayer = nil
        videoPlayer = nil
        boundBeatID = nil
        boundProductionMasterURL = nil
        boundSparseAnalysisURL = nil
        beatBindingIssue = nil
        playbackMessage = nil
        secondaryCameraMessage = nil
        durationSeconds = 0
        guard let mediaURL else {
            state = .missingAudio
            return
        }
        let audioURL = mediaURL.deletingPathExtension().appendingPathExtension("wav")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            state = .missingAudio
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
            let audioAsset = AVURLAsset(url: audioURL)
            let wavDuration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            try Task.checkCancellation()
            guard wavDuration.isFinite, wavDuration > 0 else {
                state = .unreadableMedia(audioURL.lastPathComponent)
                return
            }
            audioPlayer = AVPlayer(playerItem: AVPlayerItem(asset: audioAsset))
            durationSeconds = wavDuration

            if FileManager.default.fileExists(atPath: mediaURL.path) {
                let videoAsset = AVURLAsset(url: mediaURL)
                let movDuration = CMTimeGetSeconds(try await videoAsset.load(.duration))
                try Task.checkCancellation()
                try Task.checkCancellation()
                guard movDuration.isFinite, movDuration > 0 else {
                    state = .unreadableMedia(mediaURL.lastPathComponent)
                    return
                }
                guard abs(wavDuration - movDuration) <= ReferenceWitnessedTimingValidator.durationToleranceSeconds else {
                    state = .durationMismatch(wav: wavDuration, mov: movDuration)
                    return
                }
                let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                try Task.checkCancellation()
                if let sourceAudio = audioTracks.first, let sourceVideo = videoTracks.first {
                    // One player owns both tracks, including the native video
                    // controls. The WAV is the sole audio source; camera audio
                    // cannot double it or diverge from the reviewed recording.
                    let composition = AVMutableComposition()
                    guard let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                              preferredTrackID: kCMPersistentTrackID_Invalid),
                          let videoTrack = composition.addMutableTrack(withMediaType: .video,
                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw ReviewError("Could not prepare recorded audio and video for playback.")
                    }
                    try audioTrack.insertTimeRange(CMTimeRange(start: .zero,
                        duration: CMTime(seconds: wavDuration, preferredTimescale: 48_000)),
                        of: sourceAudio, at: .zero)
                    try videoTrack.insertTimeRange(CMTimeRange(start: .zero,
                        duration: CMTime(seconds: min(wavDuration, movDuration), preferredTimescale: 48_000)),
                        of: sourceVideo, at: .zero)
                    videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    try Task.checkCancellation()
                    let item = AVPlayerItem(asset: composition)
                    if let sidecarURL = take.rawSidecarURL {
                        var secondTrack: AVMutableCompositionTrack?
                        do {
                            let sidecar = try SessionArchiveBuilder().decodeSidecarForAudit(at: sidecarURL)
                            if let camera = sidecar.secondaryCamera {
                                secondaryCameraMessage = camera.detail ?? "Second camera: \(camera.deviceName) · \(camera.status.rawValue)"
                                if let secondURL = try camera.verifiedURL(beside: mediaURL) {
                                    let asset = AVURLAsset(url: secondURL)
                                    if let source = try await asset.loadTracks(withMediaType: .video).first,
                                       let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                                        secondTrack = track
                                        let range = try await source.load(.timeRange)
                                        let end = CMTimeMinimum(CMTimeRangeGetEnd(range), CMTime(seconds: wavDuration, preferredTimescale: 48_000))
                                        guard end > range.start else { throw ReviewError("Second camera has no playable overlap.") }
                                        do {
                                            try track.insertTimeRange(CMTimeRange(start: range.start, end: end), of: source, at: range.start)
                                            track.preferredTransform = try await source.load(.preferredTransform)
                                            item.videoComposition = try await Self.twoCameraComposition(primary: videoTrack, second: track,
                                                duration: CMTime(seconds: wavDuration, preferredTimescale: 48_000), secondEnd: end)
                                        }
                                    }
                                }
                            }
                        } catch {
                            if let secondTrack { composition.removeTrack(secondTrack) }
                            item.videoComposition = nil
                            secondaryCameraMessage = "Second camera unavailable for review: \(error.localizedDescription). Main take remains playable."
                        }
                    }
                    let player = AVPlayer(playerItem: item)
                    audioPlayer = player
                    videoPlayer = player
                }
            }

            do {
                try bindBeat(for: take, mediaURL: mediaURL, rootURL: beatRootURL)
            } catch {
                // Missing or invalid beat evidence still blocks approval. It
                // must never hide the operator's own finalized recording.
                beatBindingIssue = error.localizedDescription
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if let item = audioPlayer?.currentItem {
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.loadGeneration else { return }
                        self.stop()
                    }
                }
            }
            state = videoPlayer == nil ? .missingVideo : .ready
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                state = .synchronizationUnavailable(error.localizedDescription)
            }
            guard generation == loadGeneration else { return }
            loadTask = nil
        }
    }

    static func twoCameraComposition(primary: AVCompositionTrack, second: AVCompositionTrack,
        duration: CMTime, secondEnd: CMTime) async throws -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 1688, height: 720)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        var layers: [AVVideoCompositionLayerInstruction] = []
        for (track, rect) in [(primary, CGRect(x: 0, y: 0, width: 1280, height: 720)),
                              (second, CGRect(x: 1280, y: 0, width: 408, height: 720))] {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(Self.aspectFitTransform(size: size, transform: transform, in: rect), at: .zero)
            if track === second { layer.setOpacity(0, at: secondEnd) }
            layers.append(layer)
        }
        instruction.layerInstructions = layers
        composition.instructions = [instruction]
        return composition
    }

    static func aspectFitTransform(size: CGSize, transform: CGAffineTransform, in rect: CGRect) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        guard bounds.width > 0, bounds.height > 0 else { return transform }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - bounds.width * scale) / 2,
                                           y: rect.minY + (rect.height - bounds.height * scale) / 2))
    }

    var canPlay: Bool {
        guard audioPlayer != nil, durationSeconds > 0 else { return false }
        switch state {
        case .ready, .stopped, .missingVideo, .playing, .playingTake: return true
        default: return false
        }
    }

    var isPlaying: Bool {
        switch state {
        case .playing, .playingTake: return true
        default: return false
        }
    }

    /// Clamp an audition to measured media; an out-of-range repetition must
    /// produce an explanation instead of seeking into silence.
    static func playableRange(start: Double, end: Double, duration: Double) -> ClosedRange<Double>? {
        ReferenceMediaTimeRange.clamped(start: start, end: end, duration: duration)
    }

    func playWholeTake() {
        playRange(start: 0, end: durationSeconds, playingState: .playingTake)
    }

    func play(repetition boundary: ReferenceRepetitionBoundary, take: ReferenceAuthoringTake, contextBeats: Double = 0) {
        guard canPlay, loadedTakeID == take.evidence.metadata.referenceTakeID else { return }
        guard Self.playableRange(start: boundary.startSeconds(metadata: take.evidence.metadata),
            end: boundary.endSeconds(metadata: take.evidence.metadata), duration: durationSeconds) != nil else {
            stop()
            playbackMessage = "That repetition is outside the recorded take. Adjust its start and end."
            return
        }
        let context = max(0, contextBeats) * 60 / Double(take.evidence.metadata.bpm)
        playRange(
            start: boundary.startSeconds(metadata: take.evidence.metadata) - context,
            end: boundary.endSeconds(metadata: take.evidence.metadata) + context,
            playingState: .playing(repetition: boundary.index)
        )
    }

    /// Seek the shared audio/video player to a trim edge without playing or
    /// modifying the recording. End uses the last frame inside the range.
    func previewBoundary(_ boundary: ReferenceRepetitionBoundary, take: ReferenceAuthoringTake, atEnd: Bool = false) {
        guard canPlay, loadedTakeID == take.evidence.metadata.referenceTakeID else { return }
        let start = boundary.startSeconds(metadata: take.evidence.metadata)
        let end = boundary.endSeconds(metadata: take.evidence.metadata)
        guard let range = Self.playableRange(start: start, end: end, duration: durationSeconds) else {
            stop()
            playbackMessage = "That repetition is outside the recorded take. Adjust its start and end."
            return
        }
        playRange(start: atEnd ? max(range.lowerBound, range.upperBound - 1 / 30) : range.lowerBound,
            end: range.upperBound, playingState: .stopped, autoplay: false)
    }

    private func playRange(start: Double, end: Double, playingState: State, autoplay: Bool = true) {
        guard canPlay, let audioPlayer else { return }
        guard let range = Self.playableRange(start: start, end: end, duration: durationSeconds) else {
            playbackMessage = "That repetition is outside the recorded take. Use Play whole take or adjust its start and end."
            return
        }
        stop()
        playbackMessage = nil
        let generation = playbackGeneration
        let videoPlayer = videoPlayer
        let startTime = CMTime(seconds: range.lowerBound, preferredTimescale: 48_000)
        seekTask = Task { [weak self] in
            let audioReady = await audioPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, let self, generation == playbackGeneration else { return }
            if let videoPlayer, videoPlayer !== audioPlayer {
                _ = await videoPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
            }
            guard audioReady else {
                playbackMessage = "The recording could not seek to that position. Try Play whole take."
                return
            }
            audioPlayer.currentItem?.forwardPlaybackEndTime = CMTime(
                seconds: range.upperBound, preferredTimescale: 48_000
            )
            if autoplay { audioPlayer.play() }
            state = playingState
        }
    }

    func stop() {
        playbackGeneration = UUID()
        seekTask?.cancel()
        seekTask = nil
        loadTask?.cancel()
        loadTask = nil
        audioPlayer?.pause()
        videoPlayer?.pause()
        if isPlaying { state = .stopped }
    }

    private func bindBeat(for take: ReferenceAuthoringTake, mediaURL: URL, rootURL: URL?) throws {
        guard take.evidence.metadata.captureIntent?.isMovementCheck != true else { return }
        guard let beat = take.evidence.metadata.captureIntent?.beatSpec else {
            throw ReviewError("The take has no exact BeatSpec binding.")
        }
        if beat.version == 2 {
            let savedRoot = mediaURL.deletingLastPathComponent().appendingPathComponent("beat_assets", isDirectory: true)
            let savedDirectory = savedRoot.appendingPathComponent(beat.id, isDirectory: true)
            let resolvedRoot = FileManager.default.fileExists(atPath: savedDirectory.path)
                ? savedRoot : ReferenceBeatAssetStore.defaultRootURL
            let prepared = try ReferenceBeatAssetStore.resolve(binding: beat, rootURL: resolvedRoot)
            boundBeatID = "\(beat.id)@\(beat.version)"
            boundProductionMasterURL = prepared.productionMasterURL
            boundSparseAnalysisURL = prepared.sparseAnalysisURL
            return
        }
        guard let rootURL else {
            throw ReviewError("Set CXL_BEAT_PILOT_ROOT to the unapproved candidate directory for synchronized review.")
        }
        let directory = rootURL.appendingPathComponent(beat.id, isDirectory: true)
        let master = directory.appendingPathComponent(beat.productionMasterFileName)
        let sparse = directory.appendingPathComponent(beat.sparseAnalysisMixFileName)
        guard try hash(master) == beat.productionMasterSHA256 else {
            throw ReviewError("Production beat hash does not match BeatSpec \(beat.id) v\(beat.version).")
        }
        guard try hash(sparse) == beat.sparseAnalysisMixSHA256 else {
            throw ReviewError("Sparse analysis mix hash does not match BeatSpec \(beat.id) v\(beat.version).")
        }
        boundBeatID = "\(beat.id)@\(beat.version)"
        boundProductionMasterURL = master
        boundSparseAnalysisURL = sparse
    }

    private func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ReviewError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
