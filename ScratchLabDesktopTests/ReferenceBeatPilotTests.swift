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
