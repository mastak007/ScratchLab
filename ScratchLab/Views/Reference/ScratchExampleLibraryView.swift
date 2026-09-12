import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CryptoKit

/// Shared viewing and advisory workspace. It never owns capture configuration,
/// an approval record or a practice score.
@MainActor
struct ScratchExampleLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var review = ScratchExampleReviewState()
    @State private var showImporter = false
    @State private var importVideo = true
    @State private var showExporter = false
    let initialAudioURL: URL?
    let initialVideoURL: URL?

    init(initialAudioURL: URL? = nil, initialVideoURL: URL? = nil) {
        self.initialAudioURL = initialAudioURL
        self.initialVideoURL = initialVideoURL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Watch a reference, compare a finished take, or request an estimated technique reading.")
                    Text("Reference names come from the source dataset and await expert review. These examples are not approved canonical takes.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let library = review.library {
                        examplePicker(library)
                        referencePlayers
                        comparison
                        analysisResults
                        DisclosureGroup("Source and model limitations") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(library.manifest.limitations, id: \.self) { Text($0) }
                                Text(library.manifest.selection)
                            }.font(.caption).padding(.top, 6)
                        }
                    } else if review.loading {
                        ProgressView("Loading reference library…")
                    } else {
                        Button("Retry loading library") { Task { await review.load() } }
                    }
                    if let error = review.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding().frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Reference examples")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 650, idealWidth: 950, minHeight: 550, idealHeight: 780)
        #endif
        .task {
            await review.load()
            if !Task.isCancelled {
                await review.useTake(audio: initialAudioURL, video: initialVideoURL)
            }
        }
        .onDisappear { review.close() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importVideo ? [.movie] : [.audio]) { result in
            switch result {
            case .success(let url):
                Task { await review.importTake(url, video: importVideo) }
            case .failure(let error): review.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExporter, document: AdvisoryReportDocument(data: review.reportData), contentType: .json, defaultFilename: "scratch-advisory-review") { result in
            if case .failure(let error) = result { review.error = error.localizedDescription }
        }
    }

    private func examplePicker(_ library: ScratchExampleLibrary) -> some View {
        VStack(alignment: .leading) {
            Picker("Technique example", selection: $review.exampleID) {
                ForEach(library.manifest.examples) { example in
                    Text(example.displayName)
                        .tag(example.id)
                }
            }.onChange(of: review.exampleID) { _, _ in review.changeExample() }
            if let example = review.example {
                HStack {
                    Picker("Camera", selection: $review.angleID) {
                        ForEach(example.angles) { angle in Text(angle.id.replacingOccurrences(of: "_", with: " ")).tag(angle.id) }
                    }
                    Picker("Audio", selection: $review.audioVariant) {
                        ForEach(example.audioOptions) { option in Text(option.title).tag(option.id) }
                    }
                }
                .onChange(of: review.angleID) { _, _ in review.prepareReference() }
                .onChange(of: review.audioVariant) { _, _ in review.prepareReference() }
                if let sequence = example.sequence {
                    Text("Whole sequence · \(example.angles.count) camera views · \(sequence.endSeconds - sequence.startSeconds, specifier: "%.1f") seconds")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The sequence keeps the scratch performances and their breaks together. Source timing is preserved; exact hand-to-sound alignment remains unverified.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(sequence.warnings, id: \.self) { warning in
                        Text(warning).font(.callout).foregroundStyle(.orange)
                    }
                } else {
                    Text("Source take: \(example.take) · \(example.angles.count) camera views")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var referencePlayers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference").font(.headline)
            if review.preparing { ProgressView("Checking reference files…") }
            if let player = review.referenceVideo {
                VideoPlayer(player: player).frame(height: 270)
                HStack {
                    Button("Play reference") { review.pauseAll(); player.seek(to: .zero); player.play() }
                    Button("Stop reference") { player.pause() }
                }
            }
            Text("The selected audio plays with every camera angle.")
                .font(.caption).foregroundStyle(.secondary)
            if !review.handFrames.isEmpty {
                DisclosureGroup("Estimated hand paths") {
                    ScratchExampleHandPaths(frames: review.handFrames)
                    Text("Image coordinates: cyan primary wrist, pink secondary wrist. Missing or off-image points and large jumps break the path. Hand slots can switch; these paths do not measure platter travel, pauses or fader state.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Your finished take").font(.headline)
            HStack {
                Button("Choose take video…") { importVideo = true; showImporter = true }
                Button("Choose take audio…") { importVideo = false; showImporter = true }
                if review.hasTake { Button("Clear take") { review.clearTake() } }
            }.disabled(review.analyzing || review.importing)
            if review.importing { ProgressView("Preparing take…") }
            if let player = review.takeVideo {
                VideoPlayer(player: player).frame(height: 270)
                if review.takeVideoHasAudio {
                    Toggle("Hear take video's audio", isOn: $review.hearTakeVideoAudio)
                        .onChange(of: review.hearTakeVideoAudio) { _, enabled in player.isMuted = !enabled }
                } else { Text("This video has no embedded audio track.").font(.caption).foregroundStyle(.secondary) }
            }
            if let media = review.importedVideo { Text("Video: \(media.originalFilename)").font(.caption) }
            if let media = review.importedAudio {
                Text("Audio: \(media.originalFilename)").font(.caption)
                Button("Play take audio") { review.pauseAll(); review.takeAudio?.seek(to: .zero); review.takeAudio?.play() }
            }
            if review.hasTake {
                Button("Stop all playback") { review.pauseAll() }
                Text("Compare using each video's playback controls. No timing alignment or score is inferred. Select the separate captured WAV for audio analysis.")
                    .font(.caption).foregroundStyle(.secondary)
                if review.analyzing {
                    HStack { ProgressView("Analyzing finished media…"); Button("Cancel analysis") { review.cancelAnalysis() } }
                } else {
                    Button("Estimate technique from this take") { review.analyze() }
                        .disabled(review.importing)
                }
                Text("Optional on-device analysis, up to 2 minutes. Audio and camera motion are separate estimates. Unseen-performance accuracy has not been established; estimates do not change your selected technique, score or approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var analysisResults: some View {
        if let report = review.report {
            VStack(alignment: .leading, spacing: 10) {
                Text("Estimated technique readings").font(.headline)
                Text("Model score is not accuracy or a calibrated probability.").font(.caption)
                ForEach(report.issues.indices, id: \.self) { i in
                    Text("\(report.issues[i].modality.rawValue): \(report.issues[i].message)").foregroundStyle(.orange)
                }
                ForEach(report.windows) { window in
                    DisclosureGroup {
                        ForEach(window.qualityNotes, id: \.self) { Text($0).font(.caption) }
                        Text("Media SHA256: \(window.sourceSHA256)\nModel SHA256: \(window.modelSHA256)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    } label: {
                        Text(String(format: "%@ · %.2f–%.2f s · %@ · model score %.3f", window.modality.rawValue.capitalized,
                                    window.startSeconds, window.endSeconds,
                                    ScratchClassLabel(rawValue: window.label)?.displayName ?? window.label, window.modelScore))
                    }
                }
                Button("Save analysis report…") { showExporter = true }
                Text("The report retains file/model identities, window times and limitations. It is separate from the capture export and canonical review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private final class ScratchExampleReviewState: ObservableObject {
    @Published var library: ScratchExampleLibrary?
    @Published var exampleID = ""
    @Published var angleID = ""
    @Published var audioVariant = "noBeat"
    @Published var loading = false
    @Published var preparing = false
    @Published var importing = false
    @Published var analyzing = false
    @Published var error: String?
    @Published var referenceVideo: AVPlayer?
    @Published var takeVideo: AVPlayer?
    @Published var takeAudio: AVPlayer?
    @Published var audioURL: URL?
    @Published var videoURL: URL?
    @Published var handFrames: [ScratchMotionFrame] = []
    @Published var report: OfflineScratchAdvisoryReport?
    @Published var reportData = Data()
    @Published var importedVideo: ScratchExampleImportedMedia?
    @Published var importedAudio: ScratchExampleImportedMedia?
    @Published var takeVideoHasAudio = false
    @Published var hearTakeVideoAudio = false
    private var importTask: Task<Void, Never>?
    private var playbackObservations: [String: NSKeyValueObservation] = [:]
    private var referenceTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var ownedDirectory: URL?
    private var closed = false

    var example: ScratchExampleLibrary.Example? { library?.manifest.examples.first { $0.id == exampleID } }
    var hasTake: Bool { audioURL != nil || videoURL != nil }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await ScratchExampleLibrary.loadBundled()
            try Task.checkCancellation()
            guard !closed else { return }
            library = loaded
            exampleID = loaded.manifest.examples.first?.id ?? ""
            changeExample()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func changeExample() {
        angleID = example?.angles.first?.id ?? ""
        if let example, example.audioAssetIDs[audioVariant] == nil {
            audioVariant = example.preferredAudioID
        }
        prepareReference()
    }

    func prepareReference() {
        referenceTask?.cancel()
        releasePlayer(referenceVideo, key: "referenceVideo")
        referenceVideo = nil; handFrames = []; preparing = false
        guard let library, let example,
              let angle = example.angles.first(where: { $0.id == angleID }),
              let audioID = example.audioAssetIDs[audioVariant] else { return }
        preparing = true; error = nil
        referenceTask = Task {
            do {
                let video = try await library.verifiedURL(assetID: angle.videoAssetID)
                let audio = try await library.verifiedURL(assetID: audioID)
                let item = try await ScratchExampleReferencePlayback.makePlayerItem(videoURL: video, audioURL: audio)
                var frames: [ScratchMotionFrame] = []
                if let cacheID = angle.handCacheAssetID {
                    let cache = try await library.verifiedURL(assetID: cacheID)
                    frames = try await Task.detached {
                        let text = try String(contentsOf: cache, encoding: .utf8)
                        return try text.split(separator: "\n").map { try JSONDecoder().decode(ScratchMotionFrame.self, from: Data($0.utf8)) }
                    }.value
                }
                try Task.checkCancellation()
                guard !closed else { return }
                let videoPlayer = AVPlayer(playerItem: item)
                referenceVideo = videoPlayer
                observePlayback(videoPlayer, key: "referenceVideo", name: "Reference playback")
                handFrames = frames
                preparing = false
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription; preparing = false }
            }
        }
    }

    func useTake(audio: URL?, video: URL?) async {
        if let video { await importTake(video, video: true) }
        if let audio, !closed { await importTake(audio, video: false) }
    }

    func importTake(_ source: URL, video: Bool) async {
        guard !closed, !analyzing, !importing, !Task.isCancelled else { return }
        importing = true; error = nil
        let pending = Task { await performImport(source, video: video) }
        importTask = pending
        await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
        importTask = nil
        importing = false
    }

    private func performImport(_ source: URL, video: Bool) async {
        guard !closed, !Task.isCancelled else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        var preparedCopy: URL?
        do {
            if ownedDirectory == nil {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchExampleReview-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                ownedDirectory = directory
            }
            guard let directory = ownedDirectory else { return }
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            preparedCopy = destination
            let copied = try await ScratchExampleMediaImporter.copyVerified(source: source, destination: destination)
            let details = try await ScratchExampleMediaImporter.validateMedia(at: destination, video: video)
            try Task.checkCancellation()
            guard !closed else { try? FileManager.default.removeItem(at: destination); return }
            let player = AVPlayer(url: destination)
            if video {
                let previous = videoURL
                releasePlayer(takeVideo, key: "takeVideo")
                importedVideo = copied; videoURL = destination
                takeVideoHasAudio = details.hasAudio
                hearTakeVideoAudio = details.hasAudio && audioURL == nil
                player.isMuted = !hearTakeVideoAudio
                takeVideo = player
                observePlayback(player, key: "takeVideo", name: "Take video")
                removeOwnedCopy(previous)
            } else {
                let previous = audioURL
                releasePlayer(takeAudio, key: "takeAudio")
                importedAudio = copied; audioURL = destination; takeAudio = player
                // The movie remains independently auditionable with its toggle.
                hearTakeVideoAudio = false; takeVideo?.isMuted = true
                observePlayback(player, key: "takeAudio", name: "Take audio")
                removeOwnedCopy(previous)
            }
            preparedCopy = nil
            report = nil; reportData = Data()
        } catch is CancellationError {
        } catch { if !closed { self.error = error.localizedDescription } }
        if let preparedCopy { try? FileManager.default.removeItem(at: preparedCopy) }
    }

    func analyze() {
        guard let library, hasTake, !analyzing, !importing, !closed else { return }
        pauseAll(); error = nil; report = nil; reportData = Data(); analyzing = true
        let audio = audioURL, video = videoURL
        let takeSources = [importedAudio, importedVideo].compactMap { $0 }
        let reference = ScratchExampleAdvisoryExport.ReferenceContext(
            catalogueID: library.manifest.id, sourceManifestSHA256: library.manifest.sourceManifestSHA256,
            exampleID: exampleID, angleID: angleID, audioVariant: audioVariant
        )
        analysisTask = Task {
            defer { analyzing = false }
            var setupIssues: [OfflineAdvisoryIssue] = []
            do {
                var sound: OfflineAdvisoryModelSource?, action: OfflineAdvisoryModelSource?
                for modality in OfflineAdvisoryModality.allCases {
                    guard modality == .audio ? audio != nil : video != nil else { continue }
                    do {
                        guard let model = library.manifest.models.first(where: { $0.modality == modality.rawValue }),
                              let asset = library.manifest.assets.first(where: { $0.id == model.assetID }) else {
                            throw ScratchExampleReviewError.invalid("The \(modality.rawValue) model is absent from this library.")
                        }
                        let url = try await library.verifiedURL(assetID: model.assetID)
                        try Task.checkCancellation()
                        let source = OfflineAdvisoryModelSource(modelURL: url, sourceSHA256: asset.sha256)
                        if modality == .audio { sound = source } else { action = source }
                    } catch is CancellationError { throw CancellationError() }
                    catch { setupIssues.append(.init(modality: modality, message: error.localizedDescription)) }
                }
                let result = try await OfflineScratchAdvisoryService().analyze(audioURL: audio, videoURL: video, soundModel: sound, actionModel: action)
                try Task.checkCancellation()
                let combined = OfflineScratchAdvisoryReport(
                    schema: result.schema, generatedAt: result.generatedAt, windows: result.windows,
                    issues: Self.mergedIssues(setupIssues, result.issues), sources: result.sources, limitations: result.limitations
                )
                let envelope = ScratchExampleAdvisoryExport(reference: reference, importedMedia: takeSources, advisory: combined)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(envelope)
                guard !closed else { return }
                report = combined; reportData = data
            } catch is CancellationError {} catch {
                guard !closed else { return }
                if case OfflineScratchAdvisoryError.noResults(let issues) = error {
                    self.error = OfflineScratchAdvisoryError.noResults(Self.mergedIssues(setupIssues, issues)).localizedDescription
                } else { self.error = error.localizedDescription }
            }
        }
    }

    private static func mergedIssues(_ setup: [OfflineAdvisoryIssue], _ analysis: [OfflineAdvisoryIssue]) -> [OfflineAdvisoryIssue] {
        setup + analysis.filter { issue in !setup.contains { $0.modality == issue.modality } }
    }

    func cancelAnalysis() { analysisTask?.cancel() }
    func pauseAll() { [referenceVideo, takeVideo, takeAudio].forEach { $0?.pause() } }
    func clearTake() {
        guard !analyzing, !importing else { return }
        releasePlayer(takeVideo, key: "takeVideo"); releasePlayer(takeAudio, key: "takeAudio")
        takeVideo = nil; takeAudio = nil
        audioURL = nil; videoURL = nil; importedAudio = nil; importedVideo = nil
        takeVideoHasAudio = false; hearTakeVideoAudio = false
        report = nil; reportData = Data()
        if let directory = ownedDirectory {
            do { try FileManager.default.removeItem(at: directory); ownedDirectory = nil }
            catch { self.error = "Could not remove temporary review files: " + error.localizedDescription }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true; referenceTask?.cancel(); analysisTask?.cancel(); importTask?.cancel(); pauseAll()
        releasePlayer(referenceVideo, key: "referenceVideo")
        releasePlayer(takeVideo, key: "takeVideo"); releasePlayer(takeAudio, key: "takeAudio")
        referenceVideo = nil; takeVideo = nil; takeAudio = nil
        let pending = [analysisTask, importTask].compactMap { $0 }
        let directory = ownedDirectory
        Task {
            do { try await ScratchExampleMediaImporter.removeDirectory(directory, after: pending) }
            catch { self.error = "Could not remove temporary review files: " + error.localizedDescription }
        }
    }

    private func removeOwnedCopy(_ url: URL?) {
        guard let url, let directory = ownedDirectory,
              url.deletingLastPathComponent() == directory else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { self.error = "Could not remove the previous temporary copy: " + error.localizedDescription }
    }

    private func releasePlayer(_ player: AVPlayer?, key: String) {
        playbackObservations.removeValue(forKey: key)?.invalidate()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    private func observePlayback(_ player: AVPlayer, key: String, name: String) {
        guard let item = player.currentItem else { return }
        playbackObservations[key] = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The media could not be played."
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, !self.closed,
                      [self.referenceVideo, self.takeVideo, self.takeAudio].contains(where: { $0 === player }) else { return }
                self.error = "\(name): \(message)"
            }
        }
    }

}

/// The reference WAV is the sole soundtrack for every view of that performance.
/// A single item keeps native play/pause/seek on one timeline, without modifying
/// source files or inventing a camera/audio synchronization correction.
@MainActor
enum ScratchExampleReferencePlayback {
    static func makePlayerItem(videoURL: URL, audioURL: URL) async throws -> AVPlayerItem {
        try Task.checkCancellation()
        let video = AVURLAsset(url: videoURL)
        let audio = AVURLAsset(url: audioURL)
        guard try await video.load(.isPlayable), try await audio.load(.isPlayable),
              let sourceVideo = try await video.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audio.loadTracks(withMediaType: .audio).first else {
            throw ScratchExampleReviewError.invalid("The reference needs a playable camera video and its matching audio file.")
        }
        let videoDuration = try await video.load(.duration)
        let audioDuration = try await audio.load(.duration)
        guard videoDuration.seconds.isFinite, videoDuration.seconds > 0,
              audioDuration.seconds.isFinite, audioDuration.seconds > 0 else {
            throw ScratchExampleReviewError.invalid("The reference video or audio has no finite playback duration.")
        }
        let transform = try await sourceVideo.load(.preferredTransform)
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScratchExampleReviewError.invalid("Could not prepare reference video and audio for playback.")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: sourceAudio, at: .zero)
        videoTrack.preferredTransform = transform
        return AVPlayerItem(asset: composition)
    }
}

private struct ScratchExampleHandPaths: View {
    let frames: [ScratchMotionFrame]
    var body: some View {
        Canvas { context, size in
            for secondary in [false, true] {
                var previous: CGPoint?
                var path = Path()
                for frame in frames {
                    let point = secondary ? frame.secondaryHandWrist : frame.dominantHandWrist
                    guard let point, point.x.isFinite, point.y.isFinite,
                          (0...1).contains(point.x), (0...1).contains(point.y) else { previous = nil; continue }
                    let display = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if let prior = previous, hypot(point.x - prior.x, point.y - prior.y) <= 0.15 {
                        path.addLine(to: display)
                    } else { path.move(to: display) }
                    previous = point
                }
                context.stroke(path, with: .color(secondary ? .pink : .cyan), lineWidth: 2)
            }
        }
        .frame(height: 180).background(Color.black).accessibilityLabel("Estimated primary and secondary wrist paths in normalized image coordinates")
    }
}

private struct AdvisoryReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ScratchExampleImportedMedia: Codable, Sendable, Equatable {
    let originalFilename: String
    let originalSHA256: String
    let copiedSHA256: String
    let byteCount: Int64
    let reviewURL: URL
}

struct ScratchExampleAdvisoryExport: Codable {
    struct ReferenceContext: Codable, Equatable {
        let catalogueID: String
        let sourceManifestSHA256: String
        let exampleID: String
        let angleID: String
        let audioVariant: String
    }
    let schema: String
    let reference: ReferenceContext
    let importedMedia: [ScratchExampleImportedMedia]
    let advisory: OfflineScratchAdvisoryReport

    init(reference: ReferenceContext, importedMedia: [ScratchExampleImportedMedia], advisory: OfflineScratchAdvisoryReport) {
        schema = "scratchlab_example_advisory_review_v1"
        self.reference = reference
        self.importedMedia = importedMedia
        self.advisory = advisory
    }
}

enum ScratchExampleReviewError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Owns only immutable copies inside this review's temporary directory. The
/// original is hashed again after copying, so a growing/replaced take cannot
/// silently become a stable but incomplete review file.
enum ScratchExampleMediaImporter {
    struct MediaDetails: Sendable {
        let duration: Double
        let hasAudio: Bool
    }

    private struct Fingerprint: Equatable {
        let sha256: String
        let byteCount: Int64
    }

    static func copyVerified(source: URL, destination: URL) async throws -> ScratchExampleImportedMedia {
        let work = Task.detached(priority: .utility) {
            try copyVerifiedSynchronously(source: source, destination: destination)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The post-copy hook makes a source mutation deterministic in regression
    /// tests. Production uses the nil default and has no test-only branch.
    static func copyVerifiedSynchronously(
        source: URL, destination: URL, afterCopy: (() throws -> Void)? = nil
    ) throws -> ScratchExampleImportedMedia {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL, source.standardizedFileURL != destination.standardizedFileURL,
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ScratchExampleReviewError.invalid("Choose a regular finalized media file.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ScratchExampleReviewError.invalid("The temporary destination already exists; no file was overwritten.")
        }
        let original = try fingerprint(source)
        var keepCopy = false
        defer { if !keepCopy { try? FileManager.default.removeItem(at: destination) } }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ScratchExampleReviewError.invalid("The temporary media copy could not be created.")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: bytes)
            }
            try output.synchronize()
        }
        try afterCopy?()
        let copy = try fingerprint(destination)
        let current = try fingerprint(source)
        guard original == current, original == copy else {
            throw ScratchExampleReviewError.invalid("The source changed while preparing its copy. Finish recording, then choose the finalized file again.")
        }
        try Task.checkCancellation()
        keepCopy = true
        return .init(originalFilename: source.lastPathComponent, originalSHA256: original.sha256,
                     copiedSHA256: copy.sha256, byteCount: copy.byteCount, reviewURL: destination)
    }

    static func validateMedia(at url: URL, video: Bool) async throws -> MediaDetails {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: video ? .video : .audio)
        guard playable, duration.isFinite, duration > 0, !tracks.isEmpty else {
            throw ScratchExampleReviewError.invalid("The selected file has no playable \(video ? "video" : "audio") track with a finite duration.")
        }
        let hasAudio = video ? try await !asset.loadTracks(withMediaType: .audio).isEmpty : true
        try Task.checkCancellation()
        return .init(duration: duration, hasAudio: hasAudio)
    }

    static func removeDirectory(_ directory: URL?, after pending: [Task<Void, Never>]) async throws {
        for task in pending { await task.value }
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
            count += Int64(bytes.count)
        }
        return .init(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count)
    }
}
