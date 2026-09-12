import AVFoundation
import Foundation

enum ReferenceApprovedPackageCoordinator {
    static func export(
        take: ReferenceAuthoringTake,
        finalizedMediaURL: URL,
        parentDirectory: URL,
        builtAt: Date = Date()
    ) throws -> URL {
        guard take.evidence.metadata.lifecycleState == .approvedCanonical,
              take.evidence.metadata.reviewDecision?.outcome == .approved,
              take.latestValidation.passes,
              let selected = take.evidence.boundaries.selectedRepetition,
              take.evidence.metadata.captureIntent?.beatSpec != nil,
              take.evidence.metadata.witnessedTiming != nil,
              take.evidence.metadata.sourceState?.isTerminal == true else {
            throw ReferencePackageIOError.packageRejected([
                "Export requires one explicitly approved take with selected repetition, passing evidence, intent, BeatSpec, timing, media, and terminal source state."
            ])
        }
        let audioURL = finalizedMediaURL.deletingPathExtension().appendingPathExtension("wav")
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: finalizedMediaURL)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let selectedURL = scratch.appendingPathComponent("reference.wav")
        let selectedMediaRange = try extractSelectedAudio(
            sourceURL: audioURL,
            destinationURL: selectedURL,
            startSeconds: selected.startSeconds(metadata: take.evidence.metadata),
            endSeconds: selected.endSeconds(metadata: take.evidence.metadata)
        )

        let encoder = ReferencePackageIO.encoder
        guard let calibration = take.evidence.metadata.crossfaderCalibration,
              let derivation = take.evidence.derivation else {
            throw ReferencePackageIOError.packageRejected([
                "Approved package export requires calibrated fader samples and their derivation."
            ])
        }
        let rawFader = take.evidence.crossfaderRawSamples.map {
            ReferenceCalibratedFaderSample(
                takeRelativeTime: $0.takeRelativeTime,
                rawValue: $0.rawValue,
                normalizedPosition: $0.normalizedPosition,
                audibleGain: $0.audibleGain
            )
        }
        let platter: [ReferencePlatterEvent] = try take.evidence.platterMovementEvents.map {
            guard let direction = ScratchNotationDirection(rawValue: $0.direction) else {
                throw ReferencePackageIOError.packageRejected([
                    "Platter evidence contains an unsupported direction: \($0.direction)."
                ])
            }
            return ReferencePlatterEvent(
                startTime: $0.startTime,
                endTime: $0.endTime,
                direction: direction,
                startPosition: $0.startPosition,
                endPosition: $0.endPosition,
                speed: $0.speed
            )
        }
        let calibrated = ReferenceCalibratedFaderDocument(
            calibration: calibration,
            curveResponse: take.evidence.crossfaderTakeStartState?.crossfaderCurveResponse,
            hysteresis: take.evidence.metadata.hysteresis,
            maximumCutDurationSeconds: CrossfaderStateDeriver.defaultMaximumCutDuration,
            maximumPulseGapSeconds: CrossfaderStateDeriver.defaultMaximumPulseGap,
            samples: rawFader,
            derivation: derivation
        )
        let notation = NotationEvidence(
            tearReview: take.tearReview,
            tearProjection: take.tearProjection,
            performedLimitations: take.tearPerformedLimitations
        )
        let rawMIDIData = try encoder.encode(take.evidence.rawMixerMIDIEvents)
        let platterData = try encoder.encode(platter)
        let rawFaderData = try encoder.encode(rawFader)
        let calibratedData = try encoder.encode(calibrated)
        let notationData = try encoder.encode(notation)
        let validationData = try encoder.encode(ReferenceValidationRecord(report: take.latestValidation))
        var inputs: [ReferencePackageInput] = []
        inputs.append(.init(role: .referenceAudio, packagePath: "audio/reference.wav", sourceURL: selectedURL))
        inputs.append(.init(role: .fullTakeAudio, packagePath: "audio/full_take.wav", sourceURL: audioURL))
        inputs.append(.init(role: .takeSidecar, packagePath: "evidence/take.json", sourceURL: sidecarURL))
        inputs.append(.init(role: .rawMIDI, packagePath: "evidence/raw_midi.json", data: rawMIDIData))
        inputs.append(.init(role: .platterTimeline, packagePath: "evidence/platter.json", data: platterData))
        inputs.append(.init(role: .crossfaderRaw, packagePath: "evidence/crossfader_raw.json", data: rawFaderData))
        inputs.append(.init(role: .crossfaderCalibrated, packagePath: "evidence/crossfader_calibrated.json", data: calibratedData))
        inputs.append(.init(role: .notationEvidence, packagePath: "evidence/notation.json", data: notationData))
        inputs.append(.init(role: .validationReport, packagePath: "evidence/validation.json", data: validationData))
        inputs.append(contentsOf: try boundBeatInputs(
            binding: take.evidence.metadata.captureIntent!.beatSpec!,
            rootURL: finalizedMediaURL.deletingLastPathComponent().appendingPathComponent("beat_assets", isDirectory: true)
        ))
        if take.evidence.metadata.sourceState?.explicitlyOmitsWatch != true {
            guard case .linked(let identity, let motionName, let motionHash) = take.evidence.metadata.sourceState,
                  let motionName, let motionHash,
                  let sidecar = try? SessionArchiveBuilder().decodeSidecarForAudit(at: sidecarURL),
                  sidecar.sessionID == identity.sessionID, sidecar.takeID == identity.takeID,
                  sidecar.linkedMotionFileName == motionName,
                  let motion = SessionArchiveBuilder().resolveLinkedWatchCaptureArtifact(for: sidecar) else {
                throw ReferencePackageIOError.packageRejected(["The exact linked Watch recording is unavailable for this approved take."])
            }
            let motionData = try Data(contentsOf: motion.fileURL)
            guard ReferencePackageIO.sha256Hex(motionData) == motionHash else {
                throw ReferencePackageIOError.packageRejected(["The linked Watch recording no longer matches the approved source hash."])
            }
            inputs.append(.init(role: .watchMotion, packagePath: "evidence/watch_motion.json", data: motionData))
        }
        let capturedSidecar = try SessionArchiveBuilder().decodeSidecarForAudit(at: sidecarURL)
        if let secondURL = try capturedSidecar.secondaryCamera?.verifiedURL(beside: finalizedMediaURL) {
            inputs.append(.init(role: .secondaryVideo, packagePath: "video/second_camera.mov", sourceURL: secondURL))
        }
        if FileManager.default.fileExists(atPath: finalizedMediaURL.path) {
            inputs.append(.init(role: .referenceVideo, packagePath: "video/full_take.mov", sourceURL: finalizedMediaURL))
        }

        let metadata = take.evidence.metadata
        let referenceID = ReferencePackageManifest.makeReferenceID(
            technique: metadata.technique,
            patternID: metadata.pattern.id
        )
        let decision = metadata.reviewDecision!
        let directoryName = "\(referenceID)_v\(metadata.referenceVersion)"
        return try ReferencePackageIO.writePackage(
            inputs: inputs,
            parentDirectory: parentDirectory,
            packageDirectoryName: directoryName
        ) { records in
            ReferencePackageManifest(
                referenceID: referenceID,
                referenceVersion: metadata.referenceVersion,
                packageBuiltAt: builtAt,
                metadata: metadata,
                boundaries: take.evidence.boundaries,
                selectedRepetitionIndex: selected.index,
                publishedPhraseStartSeconds: selectedMediaRange.lowerBound,
                publishedPhraseEndSeconds: selectedMediaRange.upperBound,
                publishedPhraseBeats: metadata.pattern.phraseBeats,
                approval: decision,
                validation: ReferenceValidationRecord(report: take.latestValidation),
                artifacts: records
            )
        }
    }

    static func boundBeatInputs(binding: ReferenceBeatSpecBinding, rootURL: URL) throws -> [ReferencePackageInput] {
        let prepared = try ReferenceBeatAssetStore.resolve(binding: binding, rootURL: rootURL)
        let assets: [(ReferenceArtifactRecord.Role, URL)] = [
            (.beatProductionMaster, prepared.productionMasterURL),
            (.beatSparseAnalysis, prepared.sparseAnalysisURL),
            (.beatManifest, prepared.manifestURL),
            (.beatRightsReceipt, prepared.rightsReceiptURL)
        ]
        return assets.map { role, url in
            ReferencePackageInput(role: role, packagePath: "beat_assets/\(binding.id)/\(url.lastPathComponent)", sourceURL: url)
        }
    }

    static func copyAndReopen(
        packageURL: URL,
        secondRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ReferencePackageManifest {
        try fileManager.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let copied = secondRoot.appendingPathComponent(packageURL.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: copied.path) { try fileManager.removeItem(at: copied) }
        try fileManager.copyItem(at: packageURL, to: copied)
        let issues = ReferencePackageIO.verify(packageURL: copied, fileManager: fileManager)
        guard issues.isEmpty else { throw ReferencePackageIOError.packageRejected(issues) }
        return try ReferencePackageIO.readManifest(atPackageURL: copied, fileManager: fileManager)
    }

    @discardableResult
    static func extractSelectedAudio(
        sourceURL: URL,
        destinationURL: URL,
        startSeconds: Double,
        endSeconds: Double
    ) throws -> ClosedRange<Double> {
        let source = try AVAudioFile(forReading: sourceURL)
        let sampleRate = source.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0,
              let range = ReferenceMediaTimeRange.clamped(
                start: startSeconds, end: endSeconds, duration: Double(source.length) / sampleRate
              ) else { throw ReferencePackageIOError.couldNotCreatePackage("selected repetition is outside the recorded audio") }
        let start = max(0, AVAudioFramePosition((range.lowerBound * sampleRate).rounded()))
        let end = min(source.length, AVAudioFramePosition((range.upperBound * sampleRate).rounded()))
        let frames = max(0, end - start)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: AVAudioFrameCount(min(frames, 16_384))
              ) else { throw ReferencePackageIOError.couldNotCreatePackage("selected repetition is empty") }
        source.framePosition = start
        // The caller immediately hashes/reopens this WAV. Finalize its header
        // before returning, including on older systems with no explicit close.
        try autoreleasepool {
            let destination = try AVAudioFile(forWriting: destinationURL, settings: source.fileFormat.settings)
            var copiedFrames: AVAudioFramePosition = 0
            while copiedFrames < frames {
                let remaining = frames - copiedFrames
                let requested = AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity)))
                buffer.frameLength = 0
                try source.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else {
                    throw ReferencePackageIOError.couldNotCreatePackage(
                        "selected repetition audio ended before its measured boundary: read \(copiedFrames) of \(frames) frames from frame \(start)"
                    )
                }
                // A successful AVAudioFile read may be shorter than requested
                // without reaching EOF. Keep reading; never pad or skip data.
                buffer.frameLength = AVAudioFrameCount(min(Int64(buffer.frameLength), remaining))
                try destination.write(from: buffer)
                copiedFrames += Int64(buffer.frameLength)
            }
            guard copiedFrames == frames, destination.framePosition == frames else {
                throw ReferencePackageIOError.couldNotCreatePackage("selected repetition frame count changed while writing")
            }
            if #available(macOS 15.0, *) { destination.close() }
        }
        return (Double(start) / sampleRate)...(Double(end) / sampleRate)
    }

    private struct NotationEvidence: Codable {
        let tearReview: ReferenceTearSegmentationReview
        let tearProjection: ReferenceTearCanonicalProjection
        let performedLimitations: [String: [CanonicalTearComparison.UnavailableReason]]
    }
}
