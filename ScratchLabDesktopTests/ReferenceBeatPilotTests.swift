import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import ScratchLab

final class ReferenceBeatPilotTests: XCTestCase {
    func testGenerateCheckedInCandidatesWhenExplicitlyRequested() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchlab-cxl-beat-pilots-generated")
        XCTAssertEqual(try ReferenceBeatPilotGenerator.generateAll(at: output).count, 6)
    }

    func testCatalogIsExactlyTheSixUnapprovedCXLRecipes() {
        XCTAssertEqual(ReferenceBeatPilotCatalog.six.map(\.id), [
            "boom_bap_straight_80", "boom_bap_swing_90",
            "funk_break_straight_90", "funk_light_swing_100",
            "electro_straight_110", "half_time_80"
        ])
        XCTAssertEqual(Set(ReferenceBeatPilotCatalog.six.map(\.sampleRate)), [48_000])
    }

    func testGeneratorCreatesCompleteHashBoundCandidates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cxl-beat-pilots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifests = try ReferenceBeatPilotGenerator.generateAll(at: root)
        XCTAssertEqual(manifests.count, 6)
        for manifest in manifests {
            XCTAssertEqual(manifest.approvalState, "unapproved_pilot_candidate")
            XCTAssertEqual(manifest.loopStartFrame, manifest.countInFrameCount)
            XCTAssertEqual(manifest.totalFrameCount, manifest.countInFrameCount + manifest.loopFrameCount)
            XCTAssertTrue(issues(for: manifest.binding).isEmpty)
            let directory = root.appendingPathComponent(manifest.recipe.id)
            for artifact in [manifest.productionMaster, manifest.sparseAnalysisMix, manifest.rightsReceipt] + manifest.stems {
                let data = try Data(contentsOf: directory.appendingPathComponent(artifact.fileName))
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), artifact.sha256)
            }
        }
    }

    func testBindingRejectsMalformedHashAndFrameDrift() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cxl-beat-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(ReferenceBeatPilotGenerator.generateAll(at: root).first?.binding)
        let hashDrift = ReferenceBeatSpecBinding(
            id: original.id, version: original.version, family: original.family,
            bpm: original.bpm, feel: original.feel,
            countInFrameCount: original.countInFrameCount,
            loopStartFrame: original.loopStartFrame,
            loopFrameCount: original.loopFrameCount,
            sampleRate: original.sampleRate,
            productionMasterFileName: original.productionMasterFileName,
            productionMasterSHA256: String(repeating: "0", count: 63),
            sparseAnalysisMixFileName: original.sparseAnalysisMixFileName,
            sparseAnalysisMixSHA256: original.sparseAnalysisMixSHA256,
            availableStemSHA256: original.availableStemSHA256,
            rightsState: original.rightsState,
            provenance: original.provenance
        )
        XCTAssertFalse(issues(for: hashDrift).isEmpty)

        let frameDrift = ReferenceBeatSpecBinding(
            id: original.id, version: original.version, family: original.family,
            bpm: original.bpm, feel: original.feel,
            countInFrameCount: original.countInFrameCount,
            loopStartFrame: original.loopStartFrame + 1,
            loopFrameCount: original.loopFrameCount,
            sampleRate: original.sampleRate,
            productionMasterFileName: original.productionMasterFileName,
            productionMasterSHA256: original.productionMasterSHA256,
            sparseAnalysisMixFileName: original.sparseAnalysisMixFileName,
            sparseAnalysisMixSHA256: original.sparseAnalysisMixSHA256,
            availableStemSHA256: original.availableStemSHA256,
            rightsState: original.rightsState,
            provenance: original.provenance
        )
        XCTAssertFalse(issues(for: frameDrift).isEmpty)
    }

    private func issues(for beat: ReferenceBeatSpecBinding) -> [ReferenceCaptureIntentIssue] {
        ReferenceCaptureIntentValidator.issues(
            intent: ReferenceCaptureIntent(
                id: "test-intent", parentTechniqueID: "baby", variantID: "normal-right",
                recipeID: "test-recipe", startingPlatterDirection: .forward,
                faderForm: .crossfader, bpm: beat.bpm, beatsPerCycle: 4,
                plan: ReferenceCapturePlan(countInBars: 1, repetitionCount: 4, tailBars: 1),
                beatSpec: beat
            ),
            requireBeatSpec: true
        )
    }
}

final class ReferenceBeatAssetStoreTests: XCTestCase {
    func testRuntimeAssetsContainFourClicksThenExactSelectedPatternAt95BPM() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids = Set<String>()
        for mode in BeatEngineMode.practiceModes {
            let prepared = try ReferenceBeatAssetStore.prepare(mode: mode, bpm: 95, rootURL: root)
            XCTAssertTrue(ids.insert(prepared.binding.id).inserted)
            XCTAssertEqual(prepared.binding.version, 2)
            XCTAssertEqual(prepared.binding.sampleRate, 48_000)
            let beatFrames = Int64((60.0 / 95.0 * 48_000).rounded())
            XCTAssertEqual(prepared.binding.countInFrameCount, beatFrames * 4)
            XCTAssertEqual(prepared.binding.loopStartFrame, beatFrames * 4)
            XCTAssertEqual(prepared.binding.loopFrameCount, beatFrames * 16)
            let playback = try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: mode, bpm: 95)
            let expectedClicks = try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: 95, durationSeconds: Double(beatFrames * 4) / 48_000,
                sampleRate: 48_000, channelCount: 2, startBeatIndex: 0,
                exactFrameCount: AVAudioFrameCount(beatFrames * 4)
            )
            let expectedLoop = try ScratchLabBeatEngine.renderedTimingBuffer(
                mode: mode, bpm: 95, durationSeconds: Double(beatFrames * 16) / 48_000,
                countInBeats: 0, beatsPerBar: 4, clickStartHostTime: nil, recordingStartHostTime: nil,
                sampleRate: 48_000, channelCount: 2, exactFrameCount: AVAudioFrameCount(beatFrames * 16)
            )
            XCTAssertLessThanOrEqual(try maximumDifference(playback.countInBuffer, expectedClicks), 1.0 / 32_768.0)
            XCTAssertLessThanOrEqual(try maximumDifference(playback.loopBuffer, expectedLoop), 1.0 / 32_768.0)
            let clickSamples = try XCTUnwrap(playback.countInBuffer.floatChannelData)[0]
            for beat in 0..<4 {
                let start = Int(beatFrames) * beat
                XCTAssertGreaterThan((0..<960).map { abs(clickSamples[start + $0]) }.max() ?? 0, 0.1)
                XCTAssertEqual(clickSamples[start + 4_800], 0, "Each count-in beat has silence after the click, with no drums")
            }
            XCTAssertGreaterThan(ScratchLabBeatEngine.GeneratedAudioHeadroom.peakAmplitude(of: playback.loopBuffer), 0.3)
            let written = try readPCM(prepared.productionMasterURL)
            XCTAssertEqual(written.frameLength, playback.countInBuffer.frameLength + playback.loopBuffer.frameLength)
            XCTAssertEqual(written.format.channelCount, 2)
            XCTAssertEqual(try maximumDifference(playback.countInBuffer, written, rightOffset: 0), 0)
            XCTAssertEqual(try maximumDifference(playback.loopBuffer, written, rightOffset: Int(playback.countInBuffer.frameLength)), 0)
        }
    }

    func testPreparedAssetsReuseIdenticalBytesAndResolveAfterDirectoryCopy() throws {
        let root = temporaryRoot()
        let copiedRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: copiedRoot)
        }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, rootURL: root)
        let urls = [prepared.manifestURL, prepared.productionMasterURL, prepared.sparseAnalysisURL, prepared.rightsReceiptURL]
        let before = try urls.map { (try Data(contentsOf: $0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        XCTAssertEqual(try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, rootURL: root), prepared)
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), before[index].0)
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before[index].1)
        }
        try FileManager.default.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: prepared.directoryURL, to: copiedRoot.appendingPathComponent(prepared.binding.id))
        let copied = try ReferenceBeatAssetStore.resolve(binding: prepared.binding, rootURL: copiedRoot)
        XCTAssertEqual(copied.binding, prepared.binding)
        XCTAssertEqual(copied.mode, prepared.mode)
        XCTAssertEqual(try Data(contentsOf: copied.productionMasterURL), before[1].0)
        let otherBPM = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 96, rootURL: root)
        XCTAssertNotEqual(otherBPM.binding.id, prepared.binding.id)
        XCTAssertThrowsError(try ReferenceBeatAssetStore.resolve(binding: otherBPM.binding, rootURL: copiedRoot))
    }

    func testCorruptAssetsFailWithoutReplacingExistingBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .minimalFunk, bpm: 95, rootURL: root)
        for url in [prepared.productionMasterURL, prepared.sparseAnalysisURL, prepared.rightsReceiptURL, prepared.manifestURL] {
            let original = try Data(contentsOf: url)
            var corrupted = original
            corrupted[0] ^= 0x01
            try corrupted.write(to: url)
            XCTAssertThrowsError(try ReferenceBeatAssetStore.resolve(binding: prepared.binding, rootURL: root))
            XCTAssertThrowsError(try ReferenceBeatAssetStore.prepare(mode: .minimalFunk, bpm: 95, rootURL: root))
            XCTAssertEqual(try Data(contentsOf: url), corrupted, "A bound directory must never be regenerated over corruption")
            try original.write(to: url)
        }
        XCTAssertEqual(try ReferenceBeatAssetStore.resolve(binding: prepared.binding, rootURL: root), prepared)
        XCTAssertThrowsError(try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: .battleLoop, bpm: 95))
        XCTAssertThrowsError(try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: .minimalFunk, bpm: 96))
        XCTAssertThrowsError(try ReferenceBeatAssetStore.prepare(mode: .silent, bpm: 95, rootURL: root))
        XCTAssertThrowsError(try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 0, rootURL: root))
        XCTAssertThrowsError(try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, loopBeats: 3, rootURL: root))
    }

    func testMatchingHashCannotHideWrongPCMFormatOrFrameCount() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 95, rootURL: root)
        let originalManifest = try Data(contentsOf: prepared.manifestURL)
        let playback = try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: prepared.mode, bpm: 95)
        // Deliberately create a hash-consistent float32 WAV containing only the
        // loop. Both the declared file format and complete prefix are required.
        try FileManager.default.removeItem(at: prepared.productionMasterURL)
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: prepared.productionMasterURL, settings: playback.loopBuffer.format.settings)
            try file.write(from: playback.loopBuffer)
            if #available(macOS 15.0, *) { file.close() }
        }
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
        var binding = try XCTUnwrap(manifest["binding"] as? [String: Any])
        binding["productionMasterSHA256"] = SHA256.hash(data: try Data(contentsOf: prepared.productionMasterURL))
            .map { String(format: "%02x", $0) }.joined()
        manifest["binding"] = binding
        try JSONSerialization.data(withJSONObject: manifest).write(to: prepared.manifestURL)
        let changedBinding = try JSONDecoder().decode(ReferenceBeatSpecBinding.self, from: JSONSerialization.data(withJSONObject: binding))
        XCTAssertThrowsError(try ReferenceBeatAssetStore.resolve(binding: changedBinding, rootURL: root))
        XCTAssertThrowsError(try ReferenceBeatAssetStore.resolve(binding: prepared.binding, rootURL: root))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cxl-runtime-beat-\(UUID().uuidString)")
    }

    private func maximumDifference(_ left: AVAudioPCMBuffer, _ right: AVAudioPCMBuffer, rightOffset: Int = 0) throws -> Float {
        let lhs = try XCTUnwrap(left.floatChannelData)
        let rhs = try XCTUnwrap(right.floatChannelData)
        XCTAssertEqual(left.format.channelCount, right.format.channelCount)
        guard Int(left.frameLength) + rightOffset <= Int(right.frameLength) else {
            XCTFail("The written PCM does not cover the expected segment")
            return .infinity
        }
        var maximum: Float = 0
        for channel in 0..<Int(left.format.channelCount) {
            for frame in 0..<Int(left.frameLength) {
                maximum = max(maximum, abs(lhs[channel][frame] - rhs[channel][frame + rightOffset]))
            }
        }
        return maximum
    }

    private func readPCM(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        let destination = try XCTUnwrap(result.floatChannelData)
        let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var offset = 0
        while Int64(offset) < file.length {
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(4_096, file.length - Int64(offset))))
            guard chunk.frameLength > 0 else { throw ReferenceBeatAssetError.invalid("test fixture PCM ended early") }
            let source = try XCTUnwrap(chunk.floatChannelData)
            for channel in 0..<Int(file.processingFormat.channelCount) {
                destination[channel].advanced(by: offset).update(from: source[channel], count: Int(chunk.frameLength))
            }
            offset += Int(chunk.frameLength)
        }
        result.frameLength = AVAudioFrameCount(offset)
        return result
    }
}

final class ReferenceWitnessedTimingTests: XCTestCase {
    func testSyntheticFinalizedTimingPassesAndDriftFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cxl-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let beat = try XCTUnwrap(ReferenceBeatPilotGenerator.generateAll(at: root).first?.binding)
        let intent = ReferenceCaptureIntent(
            id: "intent", parentTechniqueID: "baby", variantID: "right-normal",
            recipeID: "plain", startingPlatterDirection: .forward,
            faderForm: .crossfader, bpm: beat.bpm, beatsPerCycle: 4,
            plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 0),
            beatSpec: beat
        )
        let planned = Double(beat.countInFrameCount + beat.loopFrameCount) / Double(beat.sampleRate)
        let good = ReferenceWitnessedTiming(
            clickStartHostTime: 1_000,
            intendedMediaOriginHostTime: 2_000,
            actualRecordingOriginHostTime: 2_001,
            sampleRate: beat.sampleRate,
            countInFrameCount: beat.countInFrameCount,
            loopStartFrame: beat.loopStartFrame,
            loopFrameCount: beat.loopFrameCount,
            beatsPerCycle: 4,
            plannedRepetitions: 4,
            plannedDurationSeconds: planned,
            measuredWAVDurationSeconds: planned,
            measuredMOVDurationSeconds: planned + 0.01,
            uncertaintySeconds: 1.0 / 48_000.0,
            source: .syntheticFixture
        )
        XCTAssertEqual(ReferenceWitnessedTimingValidator.issues(good, intent: intent), [])

        let drifted = ReferenceWitnessedTiming(
            clickStartHostTime: good.clickStartHostTime,
            intendedMediaOriginHostTime: good.intendedMediaOriginHostTime,
            actualRecordingOriginHostTime: good.actualRecordingOriginHostTime,
            sampleRate: good.sampleRate,
            countInFrameCount: good.countInFrameCount,
            loopStartFrame: good.loopStartFrame,
            loopFrameCount: good.loopFrameCount + 1,
            beatsPerCycle: good.beatsPerCycle,
            plannedRepetitions: good.plannedRepetitions,
            plannedDurationSeconds: good.plannedDurationSeconds,
            measuredWAVDurationSeconds: good.measuredWAVDurationSeconds + 1,
            measuredMOVDurationSeconds: good.measuredMOVDurationSeconds,
            uncertaintySeconds: good.uncertaintySeconds,
            source: .syntheticFixture
        )
        let issues = ReferenceWitnessedTimingValidator.issues(drifted, intent: intent)
        XCTAssertTrue(issues.contains(where: { $0.contains("loop boundaries") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("the capture plan requires") }))
    }

    func testMissingAndImpossibleOriginsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cxl-timing-origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let beat = try XCTUnwrap(ReferenceBeatPilotGenerator.generateAll(at: root).first?.binding)
        let intent = ReferenceCaptureIntent(
            id: "intent", parentTechniqueID: "tear", variantID: "right-normal",
            recipeID: "plain", startingPlatterDirection: .forward,
            faderForm: .faderOpenThroughout, bpm: beat.bpm, beatsPerCycle: 4,
            plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 0), beatSpec: beat
        )
        let planned = Double(beat.countInFrameCount + beat.loopFrameCount) / 48_000.0
        let invalid = ReferenceWitnessedTiming(
            clickStartHostTime: 0, intendedMediaOriginHostTime: 3_000,
            actualRecordingOriginHostTime: 2_000, sampleRate: 48_000,
            countInFrameCount: beat.countInFrameCount,
            loopStartFrame: beat.loopStartFrame, loopFrameCount: beat.loopFrameCount,
            beatsPerCycle: 4, plannedRepetitions: 4,
            plannedDurationSeconds: planned, measuredWAVDurationSeconds: planned,
            measuredMOVDurationSeconds: nil, uncertaintySeconds: 0,
            source: .syntheticFixture
        )
        let issues = ReferenceWitnessedTimingValidator.issues(invalid, intent: intent)
        XCTAssertTrue(issues.contains(where: { $0.contains("origin is missing") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("ordering") }))
    }
}

final class ReferencePerTakeSourceStateTests: XCTestCase {
    func testEveryTerminalSourceResultReopensExactly() throws {
        let identity = ReferenceTakeSourceIdentity(
            sessionID: "session", takeID: "take-001", takeNumber: 1, takeToken: "token-1"
        )
        let states: [ReferencePerTakeSourceState] = [
            .linked(identity: identity, motionFileName: "motion.json", sha256: String(repeating: "a", count: 64)),
            .notRequested(policy: "supported policy"),
            .unavailable(policy: "operator declared unavailable"),
            .identityMismatch(expected: identity, foundSessionID: "other", foundTakeID: "take-002"),
            .timedOut(identity: identity),
            .conflict(identity: identity, detail: "two artifacts claimed the same token")
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in states {
            XCTAssertTrue(state.isTerminal)
            XCTAssertEqual(try decoder.decode(ReferencePerTakeSourceState.self, from: encoder.encode(state)), state)
        }
        let waiting = ReferencePerTakeSourceState.waitingForLateTransfer(
            identity: identity, deadline: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertFalse(waiting.isTerminal)
        XCTAssertEqual(try decoder.decode(ReferencePerTakeSourceState.self, from: encoder.encode(waiting)), waiting)
    }
}

@MainActor
final class CXLBeatOutputRoutingTests: XCTestCase {
    private final class RouteSpy: BeatPlaybackOutputRouting {
        var prepared = 0
        var verified = 0
        var failPrepare = false
        var failVerify = false
        var route: BeatPlaybackOutputRoute?
        private(set) var audioEngine: AVAudioEngine?
        func prepare(_ engine: AVAudioEngine) throws {
            prepared += 1
            audioEngine = engine
            route = nil
            if failPrepare { throw MacScratchOutputRoute.Failure(message: "Selected Rane disconnected") }
            XCTAssertFalse(engine.isRunning)
        }
        func verify(_ engine: AVAudioEngine) throws {
            verified += 1
            XCTAssertTrue(engine.isRunning)
            if failVerify { throw MacScratchOutputRoute.Failure(message: "Output changed during count-in") }
            route = .init(deviceID: 42, deviceUID: "fixture.rane", deviceName: "Rane ONE MKII",
                          channelPair: "1/2", channelMap: [0, 1, -1, -1])
        }
    }

    func testBeatMapUsesLeftDeckAndKeepsScratchRightDeckUnchanged() throws {
        XCTAssertEqual(try MacScratchOutputRoute.channelMap(deviceName: "Rane ONE MKII",
            deviceChannels: 10, nodeChannels: 10, raneDeck: .left), [0, 1, -1, -1, -1, -1, -1, -1, -1, -1])
        XCTAssertEqual(try MacScratchOutputRoute.channelMap(deviceName: "Rane ONE MKII",
            deviceChannels: 10, nodeChannels: 10), [-1, -1, 0, 1, -1, -1, -1, -1, -1, -1])
        XCTAssertThrowsError(try MacScratchOutputRoute.channelMap(deviceName: "Rane Seventy-Two",
            deviceChannels: 10, nodeChannels: 10, raneDeck: .left))
        XCTAssertThrowsError(try MacScratchOutputRoute.channelMap(deviceName: "Rane ONE MKII",
            deviceChannels: 1, nodeChannels: 1, raneDeck: .left))
    }

    func testEveryPreviewModeRoutesBeforePlaybackIncludingClickOnly() throws {
        for mode in BeatEngineMode.practiceModes {
            let route = RouteSpy()
            let engine = ScratchLabBeatEngine(outputRouting: route)
            engine.setOutputGain(0)
            let started = try engine.start(mode: mode, bpm: 95, usesClickCountIn: true)
            defer { engine.stop() }
            XCTAssertEqual(route.prepared, 1, mode.rawValue)
            XCTAssertEqual(route.verified, 1, mode.rawValue)
            XCTAssertEqual(started.outputRoute, route.route)
            XCTAssertGreaterThan(started.recordingStartHostTime, started.clickStartHostTime)
        }
    }

    func testPreparedCaptureRechecksRouteAndKeepsBoundPCMUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let beat = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 95, loopBeats: 4, rootURL: root)
        let original = try Data(contentsOf: beat.productionMasterURL)
        let router = RouteSpy()
        let engine = ScratchLabBeatEngine(outputRouting: router)
        defer { engine.stop() }
        engine.setOutputGain(0)
        let started = try engine.start(preparedBeat: beat, mode: .boomBapTrainer, bpm: 95)
        XCTAssertEqual(started.outputRoute?.channelPair, "1/2")
        XCTAssertEqual(try engine.verifiedPreparedOutputRoute(), started.outputRoute)
        XCTAssertEqual(router.verified, 2)
        XCTAssertEqual(AVAudioTime.seconds(forHostTime: started.recordingStartHostTime - started.clickStartHostTime),
            Double(beat.binding.countInFrameCount) / Double(beat.binding.sampleRate), accuracy: 0.000001)
        router.failVerify = true
        XCTAssertThrowsError(try engine.verifiedPreparedOutputRoute())
        XCTAssertEqual(try Data(contentsOf: beat.productionMasterURL), original)
    }

    func testUnavailableRouteNeverSchedulesCountInOrRecording() throws {
        for mode in BeatEngineMode.practiceModes {
            let route = RouteSpy()
            route.failPrepare = true
            let engine = ScratchLabBeatEngine(outputRouting: route)
            defer { engine.stop() }
            XCTAssertThrowsError(try engine.start(mode: mode, bpm: 95, usesClickCountIn: true,
                onCountInBeat: { _ in XCTFail("No count-in on a failed route") },
                onRecordingStart: { XCTFail("No recording on a failed route") })) { error in
                    XCTAssertTrue(error.localizedDescription.contains("disconnected"))
                }
            XCTAssertEqual(route.prepared, 1)
            XCTAssertEqual(route.verified, 0)
            XCTAssertFalse(route.audioEngine?.isRunning ?? true)
        }
    }

    func testActualMacOutputReadbackSurvivesRestart() throws {
        let router = MacReferenceBeatOutputRouter {
            .init(deviceID: nil, deviceName: "System Default", deviceUID: nil)
        }
        let engine = ScratchLabBeatEngine(outputRouting: router)
        defer { engine.stop() }
        engine.setOutputGain(0)
        for _ in 0..<2 {
            let started = try engine.start(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true)
            let route = try XCTUnwrap(started.outputRoute)
            XCTAssertEqual(route.deviceID, MacScratchOutputRoute.defaultOutputDeviceID())
            XCTAssertEqual(route.deviceUID, MacScratchOutputRoute.deviceUID(route.deviceID))
            XCTAssertEqual(route.channelPair, "1/2")
            XCTAssertEqual(Array(route.channelMap.prefix(2)), [0, 1])
            engine.stop()
        }
    }
}

// MARK: - CXL independent audit 2026-09-13 (audit-owned, not part of the candidate diff)
//
// These assert the REQUIRED behaviour. All three failed on d86a369 before
// correction, documenting two defects in how measured camera start
// timing meets witnessed-timing validation. They drive the production
// origin/timing builders and the candidate's own musical-end rule; nothing
// here reimplements validation.
final class CXLIndependentAuditTimingTests: XCTestCase {
    private let bpm = 90
    private let countInFrames: Int64 = 128_000 // 4 beats @ 90 BPM, 48 kHz (retained take 64b341bc)

    private func intent() -> ReferenceCaptureIntent {
        let beat = ReferenceBeatSpecBinding(id: "audit-90", version: 1, family: "fixture", bpm: bpm,
            feel: .straight, countInFrameCount: countInFrames, loopStartFrame: countInFrames,
            loopFrameCount: countInFrames * 4, sampleRate: 48_000,
            productionMasterFileName: "master.wav", productionMasterSHA256: String(repeating: "a", count: 64),
            sparseAnalysisMixFileName: "analysis.wav", sparseAnalysisMixSHA256: String(repeating: "b", count: 64),
            availableStemSHA256: [:], rightsState: .procedurallyGeneratedOriginal, provenance: "Synthetic audit fixture")
        return ReferenceCaptureIntent(id: "audit", parentTechniqueID: "baby_scratch", variantID: "baby_audit",
            recipeID: "baby_scratch_1bar", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
            bpm: bpm, beatsPerCycle: 4, plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1), beatSpec: beat)
    }

    /// Issues for a take whose first movie sample lands `startErrorSeconds`
    /// from the planned first performance beat. `measured` mirrors what
    /// `processRoutineMovieSample` writes; otherwise the planned timing
    /// prepared at count-in is persisted. Audio length follows
    /// `MacCaptureEngine.routineMediaDuration` (musical end preserved).
    private func issues(startErrorSeconds: Double, measured: Bool) throws -> [String] {
        let intent = intent()
        let clickSeconds = 103_041.782
        let click = AVAudioTime.hostTime(forSeconds: clickSeconds)
        let plannedSeconds = AVAudioTime.seconds(forHostTime: click) + Double(countInFrames) / 48_000
        let actualSeconds = plannedSeconds + startErrorSeconds
        let persistedStart = measured ? actualSeconds : plannedSeconds
        let timing = CaptureTimingMetadata(clickStartHostTime: click,
            recordingStartHostTime: AVAudioTime.hostTime(forSeconds: persistedStart),
            recordingStartOffsetSeconds: persistedStart - AVAudioTime.seconds(forHostTime: click))
        let duration = MacCaptureEngine.routineMediaDuration(maximum: 40.0 / 3,
            plannedStart: plannedSeconds, actualStart: actualSeconds)
        let frames = Int64((duration * 44_100).rounded())
        let sidecar = CaptureCore.LocalRecordingSidecar(sessionID: "audit-session",
            sessionConfig: CaptureSessionConfig(bpm: bpm, referenceCaptureIntent: intent),
            takeID: "take-001", appLocalTakeNumber: 1, recordingRole: "mac_routine_capture",
            platform: "macOS", appSurface: "ScratchLab Routine Recorder", sourceDeviceName: "DJ",
            captureTiming: timing, startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            recordingStatus: "completed", mediaFileName: "audit_take001_routine.mov",
            sidecarFileName: "audit_take001_routine.json", watchSyncState: .notRequested)
        let origin = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: timing))
        let witnessed = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeWitnessedTiming(sidecar: sidecar,
            audio: .init(fileName: "audit.wav", exists: true, byteCount: frames * 8,
                frameCount: frames, sampleRate: 44_100), videoURL: nil, mediaTimeOrigin: origin))
        return ReferenceWitnessedTimingValidator.issues(witnessed, intent: intent, mediaTimeOrigin: origin)
    }

    /// Candidate claims the first frame at host >= planned - 0.15 s. At 30 fps
    /// that is 117-150 ms early. A correctly captured, complete take must validate.
    func testAuditOnTimeTakeWithCandidateCameraPrerollValidates() throws {
        for early in [-0.15, -0.133, -0.117] {
            let found = try issues(startErrorSeconds: early, measured: true)
            XCTAssertEqual(found, [], "Complete on-time take (camera \(early)s before beat 1) was rejected: \(found)")
        }
    }

    /// Export consequence: a measured (non-count-in) origin must still render
    /// the bound beat stem aligned to the recorded media, not reject the take.
    func testAuditBoundBeatStemAcceptsMeasuredCameraPrerollOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .minimalFunk, bpm: 90, loopBeats: 4, rootURL: root)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let countIn = Double(prepared.binding.countInFrameCount) / Double(prepared.binding.sampleRate)
        XCTAssertNoThrow(try SessionArchiveBuilder.renderedBoundBeatStem(binding: prepared.binding, beatRootURL: root,
            recordingStartOffsetSeconds: countIn - 0.133, outputFormat: format, frameCount: 44_100),
            "Beat-stem export rejects the measured origin the candidate persists for an on-time take.")
    }

    /// The field defect: camera first sample ~1.03 s after beat 1, stop at the
    /// musical end, so repetition 1 is missing its first second.
    func testAuditLateCameraStartMissingRepetitionOneDoesNotValidate() throws {
        // Baseline-shaped evidence (planned origin persisted) IS caught today.
        XCTAssertFalse(try issues(startErrorSeconds: 1.03, measured: false).isEmpty)
        // Candidate-shaped evidence (measured origin persisted) must also be caught.
        let found = try issues(startErrorSeconds: 1.03, measured: true)
        XCTAssertFalse(found.isEmpty,
            "A take whose media starts 1.03 s after the first performance beat validated cleanly.")
    }

    func testOriginBoundsRejectExcessPrerollAndLateStarts() throws {
        for delta in [-0.151, -1.0, 0.034, 1.03] {
            XCTAssertFalse(try issues(startErrorSeconds: delta, measured: true).isEmpty)
        }
        XCTAssertEqual(try issues(startErrorSeconds: 0, measured: true), [])
        XCTAssertEqual(try issues(startErrorSeconds: 1.0 / 30, measured: true), [])
    }

    func testBeatStemContainsExactCountInTailThenFirstLoopSample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .minimalFunk, bpm: 90, loopBeats: 4, rootURL: root)
        let played = try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: prepared.mode, bpm: 90)
        let preroll = 6_384 // 133 ms at 48 kHz
        let countIn = Int(played.countInBuffer.frameLength)
        let stem = try SessionArchiveBuilder.renderedBoundBeatStem(binding: prepared.binding, beatRootURL: root,
            recordingStartOffsetSeconds: Double(countIn - preroll) / 48_000,
            outputFormat: played.loopBuffer.format, frameCount: AVAudioFrameCount(preroll + 512))
        for channel in 0..<2 {
            XCTAssertEqual(Data(bytes: stem.floatChannelData![channel], count: preroll * 4),
                Data(bytes: played.countInBuffer.floatChannelData![channel] + countIn - preroll, count: preroll * 4))
            XCTAssertEqual(Data(bytes: stem.floatChannelData![channel] + preroll, count: 512 * 4),
                Data(bytes: played.loopBuffer.floatChannelData![channel], count: 512 * 4))
        }
    }

    func testWatchStopMergeRetainsMeasuredOriginAndLatestDiskLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "audit-origin-\(UUID().uuidString)"))
        let engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
        let media = root.appendingPathComponent("audit_take001_routine.mov")
        let url = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: media)
        let click = AVAudioTime.hostTime(forSeconds: 100)
        let countIn = Double(countInFrames) / 48_000
        let planned = CaptureTimingMetadata(clickStartHostTime: click,
            recordingStartHostTime: AVAudioTime.hostTime(forSeconds: 100 + countIn),
            recordingStartOffsetSeconds: countIn)
        let sidecar = CaptureCore.LocalRecordingSidecar(sessionID: "audit", sessionConfig: nil,
            takeID: "take-001", appLocalTakeNumber: 1, recordingRole: "mac_routine_capture",
            platform: "macOS", appSurface: "fixture", sourceDeviceName: "fixture", captureTiming: planned,
            startedAt: Date(), recordingStatus: "recording", mediaFileName: media.lastPathComponent,
            sidecarFileName: url.lastPathComponent, watchSyncState: .acknowledged)
        try engine.testOnly_prepareSidecar(sidecar, url: url)
        let actual = 100 + countIn - 0.133
        engine.testOnly_recordMeasuredOrigin(actual, mediaURL: media)
        // A late relay writes a link into the older, planned-timing disk copy.
        let linked = sidecar.linkingWatchCapture(id: UUID(), fileName: "motion.json")
        try linked.encodedData().write(to: url, options: .atomic)
        let identity = TakeIdentity(sessionID: "audit", takeID: "take-001", takeNumber: 1)
        let sent = CaptureWatchStopDiagnostics(outcome: .sent, sessionID: "audit", takeID: "take-001",
            requestedAt: Date(), motionTransferState: .pending)
        engine.testOnly_persistWatchStop(sent, identity: identity)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.captureTiming?.recordingStartHostTime, AVAudioTime.hostTime(forSeconds: actual))
        XCTAssertEqual(try XCTUnwrap(stored.captureTiming?.recordingStartOffsetSeconds), countIn - 0.133, accuracy: 0.000001)
        XCTAssertEqual(stored.linkedMotionFileName, "motion.json")
        XCTAssertEqual(stored.captureTiming, engine.testOnly_activeSidecar?.captureTiming)

        // An old camera callback must not change this take's origin.
        engine.testOnly_recordMeasuredOrigin(200, mediaURL: root.appendingPathComponent("other.mov"))
        XCTAssertEqual(engine.testOnly_activeSidecar?.captureTiming, stored.captureTiming)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            if index.isMultiple(of: 2) { engine.testOnly_recordMeasuredOrigin(actual, mediaURL: media) }
            else { engine.testOnly_persistWatchStop(sent, identity: identity) }
        }
        XCTAssertEqual(engine.testOnly_activeSidecar?.captureTiming, stored.captureTiming)

        let stopped = CaptureWatchStopDiagnostics(outcome: .stopped, sessionID: "audit", takeID: "take-001",
            requestedAt: sent.requestedAt, resolvedAt: Date().addingTimeInterval(1), motionTransferState: .pending)
        let finalSnapshot = stored.mergingLatestWatchStopDiagnostics(from: stored.withWatchStopDiagnostics(stopped))
        XCTAssertEqual(finalSnapshot.watchStopDiagnostics, stopped)
        XCTAssertEqual(finalSnapshot.captureTiming, stored.captureTiming)
        XCTAssertEqual(finalSnapshot.mergingLatestWatchStopDiagnostics(from: stored).watchStopDiagnostics, stopped)
    }
}

/// F5: a Stop landing between the first movie-sample claim and
/// `didStartRecordingTo` must survive into that exact take. These drive the
/// production arming, claim, stop request and start delegate without a camera
/// or movie writer; the observer sits on the single writer-stop call.
final class RoutineStopDuringStartTests: XCTestCase {
    private final class StopCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeEngine(counter: StopCounter) -> MacCaptureEngine {
        let suite = "com.machelpnz.scratchlab.tests.stop-during-start.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
        engine.testOnly_routineMovieWriterStopOverride = { counter.increment() }
        return engine
    }

    private func media(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)_\(name)_routine.mov")
    }

    /// Bounded: a regression that blocks the session queue fails in seconds.
    private func drainSessionQueue(_ engine: MacCaptureEngine, file: StaticString = #filePath, line: UInt = #line) {
        let drained = expectation(description: "session queue drained")
        engine.testOnly_afterSessionQueueDrains { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func startCallback(_ engine: MacCaptureEngine, _ url: URL) {
        engine.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: url, from: [])
        drainSessionQueue(engine)
    }

    func testStopBetweenFrameClaimAndStartCallbackStopsThatTakeAsManual() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("take001")
        let token = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 99.87), take)
        XCTAssertEqual(engine.requestRoutineRecordingStop(for: token, reason: .manual), .accepted)
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 0, "The writer has not confirmed its start yet.")
        startCallback(engine, take)
        XCTAssertEqual(counter.count, 1, "A Stop requested before didStartRecordingTo was lost.")
        let boundary = try XCTUnwrap(engine.routineRecordingBoundary(for: token))
        XCTAssertTrue(boundary.didStartRecording)
        XCTAssertTrue(boundary.stopWasRequested)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .manual)
        startCallback(engine, take)
        XCTAssertEqual(counter.count, 1, "A duplicate start callback must not stop the writer again.")
    }

    func testStartCallbackForAnotherFileCannotConsumeTheDeferredStop() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("take001")
        let token = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        XCTAssertEqual(engine.requestRoutineRecordingStop(for: token, reason: .manual), .accepted)
        startCallback(engine, media("stale"))
        XCTAssertEqual(counter.count, 0)
        startCallback(engine, take)
        XCTAssertEqual(counter.count, 1)
    }

    func testStopBeforeFirstFrameCancelsWithoutClaimingOrStoppingAWriter() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("take001")
        let token = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        guard case .rejected = engine.requestRoutineRecordingStop(for: token, reason: .manual) else {
            return XCTFail("A Stop before the first sample must cancel the start.")
        }
        XCTAssertNil(engine.testOnly_claimRoutineMediaStart(at: 100))
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 0)
        let boundary = try XCTUnwrap(engine.routineRecordingBoundary(for: token))
        XCTAssertFalse(boundary.didStartRecording)
        XCTAssertNotNil(boundary.startFailureDescription)
    }

    func testStaleStopForEarlierGenerationCannotStopTheNextTake() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let first = media("take001"), second = media("take002")
        let firstToken = try engine.testOnly_prepareRoutineMediaStart(mediaURL: first, plannedStartHostTime: 100)
        guard case .rejected = engine.requestRoutineRecordingStop(for: firstToken, reason: .manual) else {
            return XCTFail("Expected cancellation of the first request.")
        }
        let secondToken = try engine.testOnly_prepareRoutineMediaStart(mediaURL: second, plannedStartHostTime: 200)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 200), second)
        startCallback(engine, second)
        guard case .rejected = engine.requestRoutineRecordingStop(for: firstToken, reason: .manual) else {
            return XCTFail("A stale generation must be rejected.")
        }
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(engine.routineRecordingBoundary(for: secondToken)?.stopWasRequested, false)
        XCTAssertEqual(engine.requestRoutineRecordingStop(for: secondToken, reason: .manual), .accepted)
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 1, "The confirmed current take must stop.")
    }
}
