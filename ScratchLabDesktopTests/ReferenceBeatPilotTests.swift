import AVFoundation
import Combine
import CryptoKit
import Foundation
import QuartzCore
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
        try RealAudioIntegrationAdmission.requireOptIn()
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

    func testInstrumentedRaneShortfallCannotStopBeforeMeasuredVideoEnd() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("d881d076_regression")
        let start = 48_383.096663646
        let plannedStart = 48_383.225889375004
        let token = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: plannedStart)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: start), take)
        startCallback(engine, take)
        let duration = engine.routineMaximumTakeDurationSeconds
        XCTAssertEqual(duration, 13.462559062337581, accuracy: 1e-9)
        // Actual pre-mux movie end from session d881d076. The writer's own
        // counter was already 13.4016 s, but the samples only cover 12.36813 s.
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(start + 12.36813))
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(RoutineTakeTimeline.mediaSatisfiesRequest(
            requestedDurationSeconds: duration, actualMediaDurationSeconds: 12.36813))
        let firstEndFrame = start + ceil(duration * 30) / 30
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(firstEndFrame - 1.0 / 30))
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(firstEndFrame))
        XCTAssertLessThan(firstEndFrame - start - duration, 1.0 / 30)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .plannedDurationReached)
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(firstEndFrame + 1))
        // The UI's subsequent finalization request uses the same stop path.
        XCTAssertEqual(engine.requestRoutineRecordingStop(for: token, reason: .manual), .accepted)
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .plannedDurationReached)
    }

    func testManualStopRemainsManualAndCannotBeReclassifiedByALaterSample() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("manual")
        let token = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        startCallback(engine, take)
        XCTAssertEqual(engine.requestRoutineRecordingStop(for: token, reason: .manual), .accepted)
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(120))
        drainSessionQueue(engine)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .manual)
    }

    func testOpenEndedTakeStillStopsAtItsSafetyCapWithoutInventingAPlan() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("unplanned")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: nil,
            maximumSeconds: 64, plannedSeconds: nil)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 200), take)
        startCallback(engine, take)
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(263.99))
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(264))
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .mediaLimit)
        XCTAssertNil(engine.routinePlannedTakeDurationSeconds)
    }

    func testInvalidAndPreStartSamplesCannotStopAnUnclaimedOrActiveTake() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(200))
        let take = media("invalid_samples")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(200))
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        for time in [Double.nan, .infinity, -.infinity, -1, 99, 100, 113.333] {
            XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(time))
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testDelayedStartCallbackCannotIssueASecondStopOrRearmTheTimedStop() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        let take = media("delayed_start")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        startCallback(engine, take)
        startCallback(engine, take)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), .plannedDurationReached)
    }

    func testACompletedSampleStopDoesNotSuppressTheNextTakesStop() throws {
        let counter = StopCounter()
        let engine = makeEngine(counter: counter)
        for start in [100.0, 200.0] {
            let take = media("next_take")
            _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: start)
            XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: start), take)
            startCallback(engine, take)
            XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(start + 14))
            // Finalization drains the stopped take before the next can arm.
            let midiToken = try XCTUnwrap(engine.testOnly_midiTakeToken(for: take))
            XCTAssertNotNil(engine.testOnly_drainTakeMIDIWindow(token: midiToken))
        }
        XCTAssertEqual(counter.count, 2)
    }

    func testSampleManualAndWatchdogOrderingsIssueOneWriterStop() throws {
        // The watchdog invokes this same stopRoutineRecording entry point.
        // Exercise every ordering without sleeping or opening a camera.
        for order in [["sample", "manual", "watchdog"], ["sample", "watchdog", "manual"],
                      ["manual", "sample", "watchdog"], ["manual", "watchdog", "sample"],
                      ["watchdog", "sample", "manual"], ["watchdog", "manual", "sample"]] {
            let counter = StopCounter()
            let engine = makeEngine(counter: counter)
            let take = media("stop_order")
            _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
            XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
            startCallback(engine, take)
            for action in order {
                switch action {
                case "sample": _ = engine.testOnly_stopAtRoutineMovieSample(114)
                case "manual": engine.stopRoutineRecording(reason: .manual)
                default: engine.stopRoutineRecording(reason: .plannedDurationReached)
                }
                drainSessionQueue(engine)
            }
            XCTAssertEqual(counter.count, 1, order.description)
            XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil),
                order.first == "manual" ? .manual : .plannedDurationReached, order.description)
        }
    }

    func testWitnessedStopClosesMIDIAdmissionAtExactEndpoint() throws {
        let engine = makeEngine(counter: StopCounter())
        let take = media("midi_endpoint")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        let token = try XCTUnwrap(engine.testOnly_midiTakeToken(for: take))
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .take)
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 0)
        // Production opens MIDI in beginRoutineTakeTimelines immediately after
        // the first movie-sample claim, before didStartRecordingTo arrives.
        // This existing seam calls the same token-checked production function.
        engine.testOnly_openTakeMIDIEpoch(at: 100)
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, token)
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 100)
        startCallback(engine, take)
        for time in [100.1, 114.0] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 1, timestamp: time)
        }
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().map(\.timestamp), [100.1, 114.0])
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 2, timestamp: 114.1)
        let drained = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(drained.map(\.timestamp), [100.1, 114.0])
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 0)
    }

    func testDelayedMovieCallbackCannotRetainMIDIAfterItsWitnessedEndpoint() throws {
        let engine = makeEngine(counter: StopCounter())
        let take = media("delayed_midi_endpoint")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: 100)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), take)
        let token = try XCTUnwrap(engine.testOnly_midiTakeToken(for: take))
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .take)
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 0)
        // Production opens MIDI in beginRoutineTakeTimelines immediately after
        // the first movie-sample claim, before didStartRecordingTo arrives.
        // This existing seam calls the same token-checked production function.
        engine.testOnly_openTakeMIDIEpoch(at: 100)
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, token)
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 100)
        startCallback(engine, take)
        // MIDI can arrive before a delayed camera callback whose sample PTS is
        // earlier. Both timestamps are in the same host-clock domain.
        for time in [113.9, 114.0, 114.1] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 1, timestamp: time)
        }
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().map(\.timestamp), [113.9, 114.0, 114.1])
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        let drained = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(drained.map(\.timestamp), [113.9, 114.0],
            "Finalization must not receive MIDI beyond the witnessed movie boundary.")
    }

    private func endpointTake(_ name: String, start: Double = 100, maximum: Double = 40.0 / 3) throws
        -> (MacCaptureEngine, URL, RoutineRecordingRequestToken, MacCaptureEngine.MIDICaptureTakeToken) {
        let engine = makeEngine(counter: StopCounter())
        let take = media(name)
        let request = try engine.testOnly_prepareRoutineMediaStart(mediaURL: take, plannedStartHostTime: start,
            maximumSeconds: maximum, plannedSeconds: maximum)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: start), take)
        engine.testOnly_openTakeMIDIEpoch(at: start)
        startCallback(engine, take)
        return (engine, take, request, try XCTUnwrap(engine.testOnly_midiTakeToken(for: take)))
    }

    func testEndpointBoundsEveryControlWithoutSortingOrRewritingCapturedEvents() throws {
        let (engine, _, _, token) = try endpointTake("reordered_controls")
        let endpoint = 114.0
        let times = [114.2, 113.9, endpoint.nextUp, endpoint, 113.8, 115.0]
        for control in [6, 8, 10] {
            for time in times {
                engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                    controller: control, value: 42,
                    mappedControl: control == 8 ? "crossfader" : (control == 10 ? "channelFader" : nil),
                    timestamp: time)
            }
        }
        let observed = engine.capturedMidiCCEventsSnapshot()
        XCTAssertEqual(observed.count, 18)
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(endpoint))
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot(), observed,
            "Closure must not rewrite observed timestamps or destructively trim the retained buffer.")
        let finalized = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(finalized, observed.filter { $0.timestamp <= endpoint })
        XCTAssertEqual(finalized.count, 9)
        for control in [6, 8, 10] {
            XCTAssertEqual(finalized.filter { $0.controller == control }.map(\.timestamp), [113.9, 114, 113.8])
        }
    }

    func testEndpointSealLeavesAnAlreadyBoundedTakeByteEquivalent() throws {
        let (engine, _, _, token) = try endpointTake("unchanged")
        for time in [113.9, 100.0, 114.0] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                controller: 6, value: 42, timestamp: time)
        }
        let before = engine.capturedMidiCCEventsSnapshot()
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        let after = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(before), try encoder.encode(after))
    }

    func testManualAndWatchdogCloseUseTheirExistingHostTimeInsteadOfAFutureMovieEnd() throws {
        for reason in [CaptureStopReason.manual, .plannedDurationReached] {
            let start = CACurrentMediaTime()
            let (engine, _, _, token) = try endpointTake("wall_clock_stop", start: start)
            for time in [start, start + 60] {
                engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                    controller: 6, value: 42, timestamp: time)
            }
            // Same entry point used by manual Stop and the watchdog. No movie
            // endpoint exists here; the production writer-stop instant owns closure.
            engine.stopRoutineRecording(reason: reason)
            drainSessionQueue(engine)
            XCTAssertEqual(engine.testOnly_resolvedRoutineStopReason(captureError: nil), reason)
            XCTAssertFalse(engine.testOnly_stopAtRoutineMovieSample(start + 70))
            XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).map(\.timestamp), [start])
        }
    }

    func testSealedPredecessorAndStaleCloseCannotBoundSuccessorMIDI() throws {
        let (engine, _, firstRequest, firstToken) = try endpointTake("predecessor")
        for time in [113.9, 114.1] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                controller: 6, value: 42, timestamp: time)
        }
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: firstToken)).map(\.timestamp), [113.9])
        let second = media("successor")
        _ = try engine.testOnly_prepareRoutineMediaStart(mediaURL: second, plannedStartHostTime: 200)
        XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 200), second)
        engine.testOnly_openTakeMIDIEpoch(at: 200)
        startCallback(engine, second)
        let secondToken = try XCTUnwrap(engine.testOnly_midiTakeToken(for: second))
        engine.testOnly_closeTakeMIDIEpoch(at: 101, token: firstToken)
        guard case .rejected = engine.requestRoutineRecordingStop(for: firstRequest, reason: .manual) else {
            return XCTFail("The predecessor request must not stop the successor.")
        }
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 200)
        for time in [213.9, 214.0, 214.1] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                controller: 6, value: 42, timestamp: time)
        }
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(214))
        engine.testOnly_closeTakeMIDIEpoch(at: 250, token: secondToken)
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: secondToken)).map(\.timestamp), [213.9, 214.0])
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: firstToken))
    }

    func testRetiredIngressCannotAppendEvenWhenItsTimestampPrecedesTheEndpoint() throws {
        let (engine, _, _, token) = try endpointTake("delayed_ingress")
        engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
            controller: 6, value: 41, timestamp: 113.8)
        engine.testOnly_setMIDIAppendInterleavingHook { _ in
            engine.testOnly_setMIDIAppendInterleavingHook(nil)
            XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(114))
        }
        engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
            controller: 6, value: 42, timestamp: 113.9)
        for time in [113.7, 114.0, 114.1] {
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                controller: 6, value: 43, timestamp: time)
        }
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).map(\.timestamp), [113.8])
        XCTAssertGreaterThan(engine.testOnly_midiEventsRejectedAsStale, 0)
    }

    func testInvalidSuppliedCloseTimeCannotAuthorizeFinalizedMIDI() throws {
        for end in [Double.nan, .infinity, -.infinity, 99] {
            let (engine, _, _, token) = try endpointTake("invalid_close")
            engine.recordReceivedMIDICCEvent(sourceName: "Rane ONE MKII", channel: 1,
                controller: 6, value: 42, timestamp: 101)
            engine.testOnly_closeTakeMIDIEpoch(at: end, token: token)
            XCTAssertTrue(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).isEmpty)
        }
    }

    func testBoundedFinalizationProtectsPerformedProjectionAndSavedSidecarArtifacts() throws {
        let stream = LivePerformedNotationTrackerTests.raneRingStream(runs: 6)
        let endpoint = 114.0
        let (engine, _, _, token) = try endpointTake("performed_evidence", maximum: endpoint - 100)
        // Shift the existing synthetic decoder fixture near the witnessed end.
        // Explicit boundary probes avoid accumulating floating-point intervals.
        for (index, packet) in stream.enumerated() {
            let timestamp: Double
            switch index {
            case 719: timestamp = 113.9
            case 799: timestamp = 114.0
            case 879: timestamp = 114.1
            default: timestamp = 113 + Double(index + 1) / 800
            }
            engine.recordReceivedMIDICCEvent(sourceName: packet.deviceName, channel: packet.channel,
                controller: packet.controller, value: packet.value, timestamp: timestamp)
        }
        let observed = engine.capturedMidiCCEventsSnapshot()
        XCTAssertEqual(observed.count, stream.count)
        for timestamp in [113.9, 114.0, 114.1] {
            XCTAssertTrue(observed.contains { $0.timestamp == timestamp })
        }
        let expected = observed.filter { $0.timestamp <= endpoint }
        XCTAssertTrue(engine.testOnly_stopAtRoutineMovieSample(endpoint))
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot(), observed,
            "Sealing must not rewrite the observation history before finalization.")
        let finalized = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(finalized, expected)
        XCTAssertTrue(finalized.contains { $0.timestamp == 113.9 })
        XCTAssertTrue(finalized.contains { $0.timestamp == 114.0 })
        XCTAssertFalse(finalized.contains { $0.timestamp > endpoint })
        func snapshot(_ midi: [CaptureCore.RawMixerMIDIEvent]) -> CaptureCore.DetectedNotationSnapshot {
            let motion = MacCaptureEngine.resolvedControllerMovementEvents(
                selectedMIDISourceName: "Rane ONE MKII", capturedMidi: midi)
            return MacCaptureEngine.RoutineNotationFusionEngine().snapshot(
                audioSnapshot: ScratchAudioNotationSnapshot(audioEvents: [], confidence: nil),
                motionEvents: motion, detectedLabel: nil, labelSource: "unknown", labelConfidence: nil,
                capturedAt: Date(timeIntervalSince1970: 1_788_000_000)).withMixerMidiEvents(midi)
        }
        let bounded = snapshot(finalized)
        XCTAssertEqual(bounded, snapshot(expected))
        XCTAssertFalse(bounded.recordMovementEvents.isEmpty, "An empty projection cannot prove protection.")
        let projection = ReferenceTearCanonicalProjectionBuilder.project(movementEvents: bounded.recordMovementEvents)
        XCTAssertFalse(projection.isEmpty)
        XCTAssertEqual(projection, ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: snapshot(expected).recordMovementEvents))
        XCTAssertNotEqual(projection, ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: snapshot(observed).recordMovementEvents), "The excluded strokes must affect the unbounded control.")
        XCTAssertLessThanOrEqual(try XCTUnwrap(projection.timeRange).upperBound, endpoint - 100)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("endpoint.mov")
        // Same isolated PCM-WAV pattern as the finalized-media review tests.
        // A tail marker proves measurement consumes the last partial read too;
        // this supplies test media, never canonical scratch evidence.
        let audioURL = media.deletingPathExtension().appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount((endpoint - 100) * format.sampleRate)
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        audio.frameLength = frames
        try XCTUnwrap(audio.floatChannelData)[0].initialize(repeating: 0, count: Int(frames))
        audio.floatChannelData![0][Int(frames) - 1] = 0.75
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: audio)
        }
        XCTAssertEqual(try AVAudioFile(forReading: audioURL).length, Int64(frames),
            "The source fixture must contain every requested frame before assembly.")
        let audioBytes = try Data(contentsOf: audioURL)
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: media)
        let sidecar = CaptureCore.LocalRecordingSidecar(sessionID: "endpoint-session", takeID: "endpoint-take",
            appLocalTakeNumber: 1, recordingRole: "mac_routine_capture", platform: "macOS", appSurface: "CXL",
            sourceDeviceName: "Fixture", startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            recordingStatus: "completed", mediaFileName: media.lastPathComponent, sidecarFileName: sidecarURL.lastPathComponent)
            .withDetectedNotation(bounded)
        let bytes = try sidecar.encodedData()
        try bytes.write(to: sidecarURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let savedBytes = try Data(contentsOf: sidecarURL)
        XCTAssertEqual(savedBytes, bytes)
        let restored = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: savedBytes)
        XCTAssertEqual(restored.detectedNotation?.mixerMidiEvents, expected)
        XCTAssertEqual(restored.detectedNotation?.recordMovementEvents, bounded.recordMovementEvents)
        let artifacts = try ReferenceAuthoringCaptureBridge.buildArtifacts(mediaURL: media,
            expectedIdentity: TakeIdentity(sessionID: "endpoint-session", takeID: "endpoint-take", takeNumber: 1)).get()
        XCTAssertEqual(artifacts.rawMixerMIDIEvents, expected)
        XCTAssertEqual(artifacts.platterMovementEvents, bounded.recordMovementEvents)
        XCTAssertEqual(ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: artifacts.platterMovementEvents), projection)
        XCTAssertEqual(artifacts.audio.frameCount, Int64(frames))
        XCTAssertEqual(artifacts.audio.peakLevel, 0.75, "The final partial read must contribute to the peak.")
        XCTAssertEqual(artifacts.audio.sampleRate, format.sampleRate)
        XCTAssertEqual(artifacts.audio.currentSHA256, ReferencePackageIO.sha256Hex(audioBytes))
        XCTAssertEqual(try Data(contentsOf: audioURL), audioBytes)
        let binding = try XCTUnwrap(artifacts.tearEvidenceSourceBinding)
        XCTAssertEqual(binding.rawSidecarSHA256, ReferencePackageIO.sha256Hex(bytes))
        XCTAssertEqual(binding.rawSidecarData, bytes)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), bytes)
    }

    func testInvalidOrOverflowingSampleBoundsCannotClaimAStop() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertFalse(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: 120,
                mediaStartHostTime: 100, maximumDurationSeconds: duration))
        }
        for start in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertFalse(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: 120,
                mediaStartHostTime: start, maximumDurationSeconds: 10))
        }
        XCTAssertFalse(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: .greatestFiniteMagnitude,
            mediaStartHostTime: .greatestFiniteMagnitude, maximumDurationSeconds: .greatestFiniteMagnitude))
    }
}

/// Exercises the actual ordinary start orchestration with synthetic preparation,
/// output and host clock. No audio device is started and no time elapses in tests.
final class OrdinaryTimedCaptureOriginTests: XCTestCase {
    private final class Fixture {
        let engine = ScratchLabBeatEngine()
        var now = AVAudioTime.hostTime(forSeconds: 100)
        var origins: [OrdinaryTimedCaptureOrigin] = []
        var callbacks: [(UInt64, () -> Void)] = []
        var beats: [Int] = []
        var recordings = 0
        var duringPreparation: (() throws -> Void)?
        let schedule: ScratchLabBeatEngine.PlaybackSchedule

        init(clickPrefix: Bool = false) throws {
            schedule = try ScratchLabBeatEngine.makePlaybackSchedule(mode: .boomBapTrainer,
                bpm: 95, sampleRate: 48_000, usesClickCountIn: clickPrefix)
            engine.testOnly_ordinaryPreparation = { [unowned self] in
                try self.duringPreparation?()
                return self.schedule
            }
            engine.testOnly_ordinaryHostTime = { [unowned self] in self.now }
            engine.testOnly_ordinaryPlaybackScheduled = { [unowned self] in self.origins.append($0) }
            engine.testOnly_ordinaryCallbackScheduled = { [unowned self] in self.callbacks.append(($0, $1)) }
        }

        func start() throws -> BeatEngineStartMetadata {
            try engine.start(mode: .boomBapTrainer, bpm: 95,
                onCountInBeat: { [unowned self] in self.beats.append($0) },
                onRecordingStart: { [unowned self] in self.recordings += 1 })
        }
    }

    func testZeroStartupDelayRetainsFourBeatMetadataAndPlaybackOrigin() throws {
        let f = try Fixture()
        let result = try f.start()
        XCTAssertEqual(result.clickStartHostTime, f.now + AVAudioTime.hostTime(forSeconds: 0.12))
        XCTAssertEqual(result.recordingStartHostTime,
            result.clickStartHostTime + AVAudioTime.hostTime(forSeconds: 4 * 60.0 / 95))
        XCTAssertEqual(f.origins.first?.playbackStartHostTime, result.clickStartHostTime)
        XCTAssertEqual(f.callbacks.last?.0, result.recordingStartHostTime)
    }

    func testHeldPreparationCannotCreateOriginOrCallbacksBeforeRelease() throws {
        let f = try Fixture()
        f.duringPreparation = {
            XCTAssertTrue(f.origins.isEmpty)
            XCTAssertTrue(f.callbacks.isEmpty)
            XCTAssertTrue(f.beats.isEmpty)
            XCTAssertEqual(f.recordings, 0)
            f.now += AVAudioTime.hostTime(forSeconds: 5)
            XCTAssertTrue(f.origins.isEmpty)
            XCTAssertTrue(f.callbacks.isEmpty)
            // Returning releases the held preparation result to production start.
        }
        let result = try f.start()
        XCTAssertEqual(result.clickStartHostTime, f.now + AVAudioTime.hostTime(forSeconds: 0.12))
        XCTAssertEqual(f.callbacks.last?.0, result.recordingStartHostTime)
    }

    func testLargeSyntheticPreparationDelayDoesNotLeakIntoCountIn() throws {
        let f = try Fixture()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 86_400) }
        let result = try f.start()
        XCTAssertGreaterThan(result.clickStartHostTime, f.now)
        XCTAssertEqual(result.recordingStartHostTime - result.clickStartHostTime,
            AVAudioTime.hostTime(forSeconds: 4 * 60.0 / 95))
        XCTAssertEqual(f.callbacks.map(\.0).last, result.recordingStartHostTime)
    }

    func testEveryCountInDeadlineUsesTheSameOrigin() throws {
        let f = try Fixture()
        let result = try f.start()
        XCTAssertEqual(f.callbacks.count, 5)
        for index in 0..<4 {
            XCTAssertEqual(f.callbacks[index].0, result.clickStartHostTime
                + AVAudioTime.hostTime(forSeconds: Double(index) * 60.0 / 95))
            f.callbacks[index].1()
        }
        XCTAssertEqual(f.beats, [1, 2, 3, 4])
        XCTAssertEqual(f.recordings, 0)
        f.callbacks[4].1()
        XCTAssertEqual(f.recordings, 1)
    }

    func testExplicitClickPrefixKeepsExactPCMCountInDuration() throws {
        let f = try Fixture(clickPrefix: true)
        let result = try f.start()
        XCTAssertEqual(result.recordingStartHostTime - result.clickStartHostTime,
            AVAudioTime.hostTime(forSeconds: f.schedule.countInDurationSeconds))
        XCTAssertEqual(f.callbacks.last?.0, result.recordingStartHostTime)
    }

    func testStopBoundaryRetainsPlannedMusicalEndAfterMeasuredCameraStart() throws {
        let f = try Fixture()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 40) }
        let result = try f.start()
        let planned = AVAudioTime.seconds(forHostTime: result.recordingStartHostTime)
        let actual = planned + 0.25
        let duration = MacCaptureEngine.routineMediaDuration(maximum: 24,
            plannedStart: planned, actualStart: actual)
        XCTAssertEqual(duration, 23.75)
        XCTAssertEqual(actual + duration, planned + 24)
        XCTAssertFalse(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: actual,
            mediaStartHostTime: actual, maximumDurationSeconds: duration))
        XCTAssertTrue(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: planned + 24,
            mediaStartHostTime: actual, maximumDurationSeconds: duration))
    }

    func testCaptureTimingRoundTripRetainsPostPreparationOriginWithoutSchemaChange() throws {
        let f = try Fixture()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 20) }
        let result = try f.start()
        let timing = CaptureTimingMetadata(clickStartHostTime: result.clickStartHostTime,
            recordingStartHostTime: result.recordingStartHostTime)
        let data = try JSONEncoder().encode(timing)
        XCTAssertEqual(try JSONDecoder().decode(CaptureTimingMetadata.self, from: data), timing)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["clickStartHostTime", "recordingStartHostTime"])
    }

    func testPreparationFailureProducesNeitherOriginNorCallbacks() throws {
        let f = try Fixture()
        f.duringPreparation = { throw CocoaError(.fileReadUnknown) }
        XCTAssertThrowsError(try f.start())
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertTrue(f.callbacks.isEmpty)
        XCTAssertEqual(f.recordings, 0)
    }

    func testCancellationBeforeOriginRejectsLatePreparationCompletion() throws {
        let f = try Fixture()
        f.duringPreparation = {
            f.engine.stop()
            f.now += AVAudioTime.hostTime(forSeconds: 50)
        }
        XCTAssertThrowsError(try f.start()) { error in
            XCTAssertEqual(error.localizedDescription, "The timed audio start was cancelled or replaced.")
        }
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertTrue(f.callbacks.isEmpty)
    }

    func testSuccessorBeforeOriginRejectsA1WithoutChangingA2() throws {
        let f = try Fixture()
        var successor: BeatEngineStartMetadata?
        f.duringPreparation = {
            f.duringPreparation = nil
            f.now += AVAudioTime.hostTime(forSeconds: 7)
            successor = try f.start()
            f.now += AVAudioTime.hostTime(forSeconds: 9)
        }
        XCTAssertThrowsError(try f.start())
        let a2 = try XCTUnwrap(successor)
        XCTAssertEqual(f.origins.count, 1)
        XCTAssertEqual(f.callbacks.count, 5)
        XCTAssertEqual(f.origins.first?.playbackStartHostTime, a2.clickStartHostTime)
        XCTAssertEqual(f.callbacks.last?.0, a2.recordingStartHostTime)
        f.callbacks.last?.1()
        XCTAssertEqual(f.recordings, 1)
    }

    func testObsoletePreparationFailureCannotCancelSuccessorCallbacks() throws {
        let f = try Fixture()
        f.duringPreparation = {
            f.duringPreparation = nil
            _ = try f.start()
            throw CocoaError(.fileReadUnknown)
        }
        XCTAssertThrowsError(try f.start())
        XCTAssertEqual(f.callbacks.count, 5)
        f.callbacks.last?.1()
        XCTAssertEqual(f.recordings, 1)
    }

    func testStoppedGenerationCannotDeliverAlreadyScheduledCallbacks() throws {
        let f = try Fixture()
        _ = try f.start()
        f.engine.stop()
        f.callbacks.forEach { $0.1() }
        XCTAssertTrue(f.beats.isEmpty)
        XCTAssertEqual(f.recordings, 0)
    }

    func testReplacedGenerationCannotDeliverAlreadyScheduledCallbacks() throws {
        let f = try Fixture()
        _ = try f.start()
        let old = f.callbacks
        f.callbacks.removeAll()
        _ = try f.start()
        old.forEach { $0.1() }
        XCTAssertTrue(f.beats.isEmpty)
        XCTAssertEqual(f.recordings, 0)
        f.callbacks.forEach { $0.1() }
        XCTAssertEqual(f.beats, [1, 2, 3, 4])
        XCTAssertEqual(f.recordings, 1)
    }

    func testDispatchDeadlineConversionDoesNotResampleNow() throws {
        let f = try Fixture()
        let result = try f.start()
        let expected = UInt64(AVAudioTime.seconds(forHostTime: result.recordingStartHostTime) * 1_000_000_000)
        XCTAssertEqual(OrdinaryTimedCaptureOrigin.deadline(for: result.recordingStartHostTime).uptimeNanoseconds, expected)
    }

    func testGeneratedExportStemIsInvariantToSyntheticStartupDelay() throws {
        let f = try Fixture()
        let zero = try f.start()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 86_400) }
        let delayed = try f.start()
        func render(_ m: BeatEngineStartMetadata) throws -> Data {
            let pcm = try ScratchLabBeatEngine.renderedTimingBuffer(mode: .boomBapTrainer,
                bpm: m.bpm, durationSeconds: 1, countInBeats: m.countInBeats,
                beatsPerBar: m.beatsPerBar, clickStartHostTime: m.clickStartHostTime,
                recordingStartHostTime: m.recordingStartHostTime, sampleRate: 48_000, channelCount: 1)
            return Data(bytes: try XCTUnwrap(pcm.floatChannelData)[0], count: Int(pcm.frameLength) * 4)
        }
        XCTAssertEqual(try render(zero), try render(delayed))
    }
    func testIOSAdapterConsumesTheSharedPreparedTimingValue() throws {
        try assertSharedAdapter(path: "ScratchLab/Views/CompanionCameraView.swift")
    }

    func testMacOSAdapterConsumesTheSharedPreparedTimingValue() throws {
        try assertSharedAdapter(path: "ScratchLabDesktop/Views/MacAnalyzerView.swift")
    }

    private func assertSharedAdapter(path: String) throws {
        let f = try Fixture()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 500) }
        let result = try f.start()
        XCTAssertEqual(result.captureTiming.clickStartHostTime, f.callbacks.first?.0)
        XCTAssertEqual(result.captureTiming.recordingStartHostTime, f.callbacks.last?.0)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        // Structural adapter check accompanies behavioral shared-value coverage;
        // a macOS test host cannot instantiate the iOS-only capture surface.
        XCTAssertTrue(source.contains("guard beatEngine.isCurrentTimedStart(started) else { return }"))
        XCTAssertTrue(source.contains("let captureTiming = started.captureTiming"))
    }

    func testPreOriginEventsRemainExcludedFromTheMeasuredTake() throws {
        let f = try Fixture()
        let requestTime = AVAudioTime.seconds(forHostTime: f.now)
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 50) }
        let result = try f.start()
        let mediaStart = AVAudioTime.seconds(forHostTime: result.recordingStartHostTime)
        XCTAssertNil(RoutineTakeTimeline.takeRelativeTime(hostTime: requestTime,
            mediaStartHostTime: mediaStart))
        XCTAssertNil(RoutineTakeTimeline.takeRelativeTime(hostTime: mediaStart - 0.25,
            mediaStartHostTime: mediaStart))
        XCTAssertEqual(RoutineTakeTimeline.takeRelativeTime(hostTime: mediaStart,
            mediaStartHostTime: mediaStart), 0)
        XCTAssertEqual(RoutineTakeTimeline.takeRelativeTime(hostTime: mediaStart + 1,
            mediaStartHostTime: mediaStart), 1)
    }

    func testFinalizationBackstopDoesNotCountStartupAsMediaDuration() throws {
        let f = try Fixture()
        f.duringPreparation = { f.now += AVAudioTime.hostTime(forSeconds: 50) }
        let result = try f.start()
        let mediaStart = AVAudioTime.seconds(forHostTime: result.recordingStartHostTime)
        let end = RoutineTakeTimeline.scheduledStopHostTime(mediaStartHostTime: mediaStart,
            requestedDurationSeconds: 24, graceSeconds: 0.75)
        XCTAssertEqual(end, mediaStart + 24.75)
        XCTAssertTrue(RoutineTakeTimeline.sampleReachesEnd(sampleHostTime: mediaStart + 24,
            mediaStartHostTime: mediaStart, maximumDurationSeconds: 24))
    }

    func testDelayedCaptureAdapterRejectsCancelledMetadata() throws {
        let f = try Fixture()
        let old = try f.start()
        XCTAssertTrue(f.engine.isCurrentTimedStart(old))
        f.engine.stop()
        XCTAssertFalse(f.engine.isCurrentTimedStart(old))
    }

    func testDelayedCaptureAdapterRejectsA1AfterA2Starts() throws {
        let f = try Fixture()
        let a1 = try f.start()
        let a2 = try f.start()
        XCTAssertFalse(f.engine.isCurrentTimedStart(a1))
        XCTAssertTrue(f.engine.isCurrentTimedStart(a2))
        XCTAssertNotEqual(a1.requestGeneration, a2.requestGeneration)
    }

}


/// 4B1: the real ordinary request/Stop boundary, with only platform preparation
/// replaced. Holds are released explicitly; no sleeps, polling or device routing.
@MainActor
final class OrdinaryRoutinePreparationOwnershipTests: XCTestCase {
    private enum PreparationFailure: Error { case rejected }
    private final class HeldPreparation: @unchecked Sendable {
        let entered: XCTestExpectation
        private let releaseGate = DispatchSemaphore(value: 0)
        init(_ name: String) { entered = XCTestExpectation(description: name) }
        func hold() { entered.fulfill(); releaseGate.wait() }
        func release() { releaseGate.signal() }
    }

    private func engine() -> MacCaptureEngine {
        let suite = "scratchlab.4b1.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
    }

    private func url(_ token: RoutineRecordingRequestToken) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("4b1-\(token.generation)-routine.mov")
    }

    private func drain(_ engine: MacCaptureEngine) async {
        let done = expectation(description: "owned preparation returned")
        engine.testOnly_afterSessionQueueDrains { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        // FIFO main-queue delivery is a completion barrier, not a polling loop.
        let published = expectation(description: "publication delivery barrier")
        DispatchQueue.main.async { published.fulfill() }
        await fulfillment(of: [published], timeout: 5)
    }

    func testStopDuringHeldPreparationPermanentlyRetiresRequest() async throws {
        let e = engine(), held = HeldPreparation("preparation held")
        defer { held.release() }
        e.testOnly_routinePreparation = { token in
            held.hold()
            return URL(fileURLWithPath: "/tmp/4b1-stopped-\(token.generation).mov")
        }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        e.stopRoutineRecording()
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        held.release()
        await drain(e)
        let result = try XCTUnwrap(e.routineRecordingBoundary(for: token))
        XCTAssertFalse(result.didStartRecording)
        XCTAssertNil(result.mediaURL, "Late preparation must not publish a successful prepared take.")
        XCTAssertNil(result.completion)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
        XCTAssertEqual(e.routineMediaStartHostTime, 0)
        XCTAssertFalse(e.isRoutineRecording)
        XCTAssertEqual(e.routineRecordingStatus, "Recording start cancelled.")
    }

    func testStopBeforeQueuedStartingPublicationCannotPublishRecording() async {
        let e = engine()
        e.testOnly_routinePreparation = { _ in URL(fileURLWithPath: "/tmp/4b1-never.mov") }
        let token = e.startRoutineRecording()
        e.stopRoutineRecording()
        await drain(e)
        XCTAssertFalse(e.isRoutineRecording)
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
    }

    func testOrdinaryToggleRecognizesPendingRequestBeforeUIFlagDelivery() async {
        let e = engine()
        e.testOnly_routinePreparation = { _ in URL(fileURLWithPath: "/tmp/4b1-toggle.mov") }
        let token = e.startRoutineRecording()
        e.toggleRoutineRecording()
        await drain(e)
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
    }

    func testLateFailureAfterStopKeepsCancellationState() async {
        let e = engine(), held = HeldPreparation("failing preparation held")
        defer { held.release() }
        e.testOnly_routinePreparation = { _ in held.hold(); throw PreparationFailure.rejected }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        e.stopRoutineRecording()
        let cancelled = e.routineRecordingBoundary(for: token)
        held.release()
        await drain(e)
        XCTAssertEqual(e.routineRecordingBoundary(for: token), cancelled)
        XCTAssertEqual(e.routineRecordingStatus, "Recording start cancelled.")
        XCTAssertFalse(e.isRoutineRecording)
    }

    private func successorCase(firstFails: Bool, stopAfterMIDI: Bool = false) async throws {
        let e = engine(), first = HeldPreparation("A1 held"), second = HeldPreparation("A2 held")
        defer { first.release(); second.release() }
        let firstURL = URL(fileURLWithPath: "/tmp/4b1-a1.mov")
        let secondURL = URL(fileURLWithPath: "/tmp/4b1-a2.mov")
        e.testOnly_routinePreparation = { token in
            if token.generation == 1 {
                if !stopAfterMIDI { first.hold() }
                if firstFails && !stopAfterMIDI { throw PreparationFailure.rejected }
                return firstURL
            }
            second.hold()
            return secondURL
        }
        if stopAfterMIDI {
            e.testOnly_beforeRoutineMediaArm = { token in
                if token.generation == 1 {
                    first.hold()
                    if firstFails { throw PreparationFailure.rejected }
                }
            }
        }
        let a1 = e.startRoutineRecording()
        await fulfillment(of: [first.entered], timeout: 5)
        e.stopRoutineRecording()
        e.stopRoutineRecording() // Duplicate may not enqueue a future unowned Stop.
        let cancelled = e.routineRecordingBoundary(for: a1)
        let a2 = e.startRoutineRecording()
        XCTAssertNil(e.routineRecordingBoundary(for: a2)?.startFailureDescription)
        first.release()
        await fulfillment(of: [second.entered], timeout: 5)
        XCTAssertEqual(e.routineRecordingBoundary(for: a1), cancelled)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
        XCTAssertNil(e.routineRecordingBoundary(for: a2)?.mediaURL)
        second.release()
        await drain(e)
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 200), secondURL)
        XCTAssertEqual(e.routineRecordingBoundary(for: a2)?.mediaURL, secondURL)
        XCTAssertNil(e.routineRecordingBoundary(for: a2)?.startFailureDescription)
        e.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: secondURL, from: [])
        await drain(e)
        XCTAssertTrue(e.routineRecordingBoundary(for: a2)?.didStartRecording == true)
        XCTAssertTrue(e.isRoutineRecording)
        // Avoid physical writer work; release only this synthetic test's window.
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }

    func testStoppedA1LateSuccessCannotMutateA2() async throws { try await successorCase(firstFails: false) }
    func testStoppedA1LateFailureCannotMutateA2() async throws { try await successorCase(firstFails: true) }
    func testCancelledMIDIOwnerCleansUpBeforeA2Preparation() async throws {
        try await successorCase(firstFails: false, stopAfterMIDI: true)
    }
    func testCancelledMIDIOwnerLateFailureCannotReleaseA2() async throws {
        try await successorCase(firstFails: true, stopAfterMIDI: true)
    }

    func testStopAfterMIDISetupBeforeMediaArmReleasesOnlyThatWindow() async {
        let e = engine(), held = HeldPreparation("MIDI armed, media not armed")
        defer { held.release() }
        e.testOnly_routinePreparation = { _ in URL(fileURLWithPath: "/tmp/4b1-midi.mov") }
        e.testOnly_beforeRoutineMediaArm = { _ in held.hold() }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertEqual(e.midiCaptureWindowTicket.owner, .take)
        e.stopRoutineRecording()
        held.release()
        await drain(e)
        XCTAssertNotEqual(e.midiCaptureWindowTicket.owner, .take)
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
    }

    func testStopAfterArmingBeforeFrameStillCancelsRequest() async {
        let e = engine()
        e.testOnly_routinePreparation = { _ in URL(fileURLWithPath: "/tmp/4b1-armed.mov") }
        let token = e.startRoutineRecording()
        await drain(e)
        e.stopRoutineRecording()
        await drain(e)
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
        XCTAssertNotEqual(e.midiCaptureWindowTicket.owner, .take)
    }

    func testDuplicateStopDoesNotChangeRetiredRequest() async {
        let e = engine(), held = HeldPreparation("duplicate Stop")
        defer { held.release() }
        e.testOnly_routinePreparation = { _ in held.hold(); return URL(fileURLWithPath: "/tmp/4b1-duplicate.mov") }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        e.stopRoutineRecording()
        let first = e.routineRecordingBoundary(for: token)
        e.stopRoutineRecording()
        held.release()
        await drain(e)
        XCTAssertEqual(e.routineRecordingBoundary(for: token), first)
    }

    func testUncancelledPreparationFailureStillReportsFailure() async {
        let e = engine()
        e.testOnly_routinePreparation = { _ in throw PreparationFailure.rejected }
        let token = e.startRoutineRecording()
        await drain(e)
        XCTAssertNotNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertFalse(e.isRoutineRecording)
        XCTAssertNotEqual(e.routineRecordingStatus, "Recording start cancelled.")
    }

    func testConcurrentSecondStartDoesNotStealPendingPreparation() async {
        let e = engine(), held = HeldPreparation("first request")
        defer { held.release() }
        let media = URL(fileURLWithPath: "/tmp/4b1-first.mov")
        e.testOnly_routinePreparation = { _ in held.hold(); return media }
        let a1 = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        let refused = e.startRoutineRecording()
        XCTAssertNotNil(e.routineRecordingBoundary(for: refused)?.startFailureDescription)
        held.release()
        await drain(e)
        XCTAssertNil(e.routineRecordingBoundary(for: a1)?.startFailureDescription)
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 100), media)
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }

    func testPreviouslyEmittedBeatTimingIsNotRecreatedByLatePreparation() async {
        let e = engine(), held = HeldPreparation("historical count-in")
        defer { held.release() }
        e.testOnly_routinePreparation = { _ in held.hold(); return URL(fileURLWithPath: "/tmp/4b1-history.mov") }
        let timing = CaptureTimingMetadata(clickStartHostTime: 100, recordingStartHostTime: 200)
        let token = e.startRoutineRecording(captureTiming: timing)
        await fulfillment(of: [held.entered], timeout: 5)
        e.stopRoutineRecording()
        held.release()
        await drain(e)
        XCTAssertEqual(e.routineMediaStartHostTime, 0)
        XCTAssertFalse(e.routineRecordingBoundary(for: token)?.didStartRecording ?? true)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.completion)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 1_000))
        XCTAssertEqual(timing.clickStartHostTime, 100)
        XCTAssertEqual(timing.recordingStartHostTime, 200)
    }
}


extension OrdinaryRoutinePreparationOwnershipTests {
    func testCancelledReservationIsNotReusedBySuccessorBeforeFilesExist() {
        let ledger = RoutineRecordingBoundaryLedger()
        let a1 = ledger.beginRequest()
        XCTAssertTrue(ledger.admitPreparation(token: a1,
            reservedIdentity: TakeIdentity(sessionID: "session", takeID: "take-001", takeNumber: 1)))
        ledger.failStart(token: a1, description: "Cancelled")
        XCTAssertEqual(ledger.nextUnreservedTakeNumber(sessionID: "session", minimum: 1), 2)
        XCTAssertEqual(ledger.nextUnreservedTakeNumber(sessionID: "other", minimum: 1), 1)
        XCTAssertEqual(ledger.nextUnreservedTakeNumber(sessionID: "session", minimum: 5), 5)
    }

    func testStaleTokenStopCannotCancelArmedSuccessor() async {
        let e = engine(), held = HeldPreparation("A1 before stale Stop")
        defer { held.release() }
        e.testOnly_routinePreparation = { token in
            if token.generation == 1 { held.hold() }
            return URL(fileURLWithPath: "/tmp/4b1-stale-\(token.generation).mov")
        }
        let a1 = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        e.stopRoutineRecording()
        let a2 = e.startRoutineRecording()
        held.release()
        await drain(e)
        guard case .rejected = e.requestRoutineRecordingStop(for: a1) else {
            return XCTFail("An old cancelled token must remain rejected.")
        }
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 100),
            URL(fileURLWithPath: "/tmp/4b1-stale-\(a2.generation).mov"))
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }

    func testConfirmedOrdinaryStopStillRequestsWriterStop() async {
        let e = engine()
        let media = URL(fileURLWithPath: "/tmp/4b1-confirmed.mov")
        e.testOnly_routinePreparation = { _ in media }
        let stopped = expectation(description: "confirmed writer stopped")
        e.testOnly_routineMovieWriterStopOverride = { stopped.fulfill() }
        let token = e.startRoutineRecording()
        await drain(e)
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 100), media)
        e.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
        await drain(e)
        e.stopRoutineRecording()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(e.routineRecordingBoundary(for: token)?.didStartRecording == true)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }

    func testOrdinaryStopAfterFrameClaimDefersUntilWriterConfirmation() async {
        let e = engine()
        let media = URL(fileURLWithPath: "/tmp/4b1-claimed.mov")
        e.testOnly_routinePreparation = { _ in media }
        let stopped = expectation(description: "deferred writer stopped")
        e.testOnly_routineMovieWriterStopOverride = { stopped.fulfill() }
        let token = e.startRoutineRecording()
        await drain(e)
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 100), media)
        e.stopRoutineRecording()
        await drain(e)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        e.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(e.routineRecordingBoundary(for: token)?.didStartRecording == true)
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }
}


extension OrdinaryRoutinePreparationOwnershipTests {
    func testTokenStopPublicationCannotClearSuccessorRecordingState() async {
        let e = engine()
        e.testOnly_routinePreparation = { token in
            URL(fileURLWithPath: "/tmp/4b1-token-publication-\(token.generation).mov")
        }
        let a1 = e.startRoutineRecording()
        await drain(e)
        _ = e.requestRoutineRecordingStop(for: a1)
        // A2 owns state before the queued A1 cancellation is delivered.
        let a2 = e.startRoutineRecording()
        await drain(e)
        XCTAssertNil(e.routineRecordingBoundary(for: a2)?.startFailureDescription)
        XCTAssertTrue(e.isRoutineRecording)
        XCTAssertEqual(e.routineRecordingStatus, "Starting routine recording")
        e.stopRoutineRecording()
        await drain(e)
    }
}

// 4B2 exercises the real outer Watch owner, shared beat clock and 4B1 handoff.
// Only external reply delivery, audio output and camera preparation are replaced.
@MainActor
final class OrdinaryRoutineOuterStartTests: XCTestCase {
    @MainActor private final class HeldReply {
        let entered = XCTestExpectation(description: "Watch reply held")
        private var continuation: CheckedContinuation<WatchCaptureControlReply, Never>?
        func wait() async -> WatchCaptureControlReply {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
        func release(_ reply: WatchCaptureControlReply) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: reply)
        }
    }

    @MainActor private final class Fixture {
        let engine: MacCaptureEngine
        let beat = ScratchLabBeatEngine()
        let root: URL
        let defaults: UserDefaults
        let suite = "scratchlab.4b2.\(UUID().uuidString)"
        var configuration = CaptureSessionConfig(beatEngineMode: .boomBapTrainer)
        var origins: [OrdinaryTimedCaptureOrigin] = []
        var callbacks: [() -> Void] = []
        var started: [RoutineRecordingRequestToken: BeatEngineStartMetadata] = [:]
        var watchStops: [TakeIdentity] = []
        var acceptedReplies: [RoutineRecordingRequestToken] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("4b2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
            let schedule = try ScratchLabBeatEngine.makePlaybackSchedule(mode: .boomBapTrainer,
                bpm: 95, sampleRate: 48_000, usesClickCountIn: false)
            beat.testOnly_ordinaryPreparation = { schedule }
            beat.testOnly_ordinaryHostTime = { AVAudioTime.hostTime(forSeconds: 100) }
            beat.testOnly_ordinaryPlaybackScheduled = { [weak self] in self?.origins.append($0) }
            beat.testOnly_ordinaryCallbackScheduled = { [weak self] _, callback in self?.callbacks.append(callback) }
            engine.testOnly_routinePreparation = { [root] token in
                root.appendingPathComponent("take-\(token.generation).wav")
            }
            engine.watchStopRequestHandler = { [weak self] identity in
                self?.watchStops.append(identity)
                return WatchCaptureControlReply(commandID: UUID().uuidString, sessionID: identity.sessionID,
                    takeID: identity.takeID, syncState: .unavailable, detail: "Offline test")
            }
        }
        func begin() throws -> OrdinaryRoutineStartRequest {
            try engine.beginOrdinaryRoutineStart(configuration: configuration)
        }
        func reply(_ request: OrdinaryRoutineStartRequest, _ state: CaptureWatchSyncState = .acknowledged) -> WatchCaptureControlReply {
            WatchCaptureControlReply(commandID: UUID().uuidString, sessionID: request.identity.sessionID,
                takeID: request.identity.takeID, syncState: state, detail: "Offline test")
        }
        func resume(_ request: OrdinaryRoutineStartRequest,
                    send: () async -> WatchCaptureControlReply) async throws {
            guard await engine.awaitOrdinaryWatchReply(for: request, send: send) != nil else { return }
            acceptedReplies.append(request.token)
            // Same guarded post-await and final-delivery boundaries as the UI.
            guard engine.ownsOrdinaryRoutineStart(request) else { return }
            let metadata = try beat.start(mode: .boomBapTrainer, bpm: 95,
                onCountInBeat: nil, onRecordingStart: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.engine.ownsOrdinaryRoutineStart(request),
                              let metadata = self.started[request.token], self.beat.isCurrentTimedStart(metadata) else { return }
                        self.engine.startRoutineRecording(captureTiming: metadata.captureTiming, ordinaryStart: request)
                    }
                })
            started[request.token] = metadata
        }
        func clean() {
            _ = engine.cancelOrdinaryRoutineStart()
            beat.stop()
            if let midi = engine.midiCaptureWindowTicket.takeToken {
                _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: midi)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func drain(_ engine: MacCaptureEngine) async {
        let main = expectation(description: "MainActor callbacks delivered")
        DispatchQueue.main.async { main.fulfill() }
        await fulfillment(of: [main], timeout: 5)
        let worker = expectation(description: "media preparation completed")
        engine.testOnly_afterSessionQueueDrains { worker.fulfill() }
        await fulfillment(of: [worker], timeout: 5)
        let published = expectation(description: "state delivered")
        DispatchQueue.main.async { published.fulfill() }
        await fulfillment(of: [published], timeout: 5)
    }

    private func lateReply(_ state: CaptureWatchSyncState, afterRecording: Bool = false) async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let old = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        let b = try f.begin()
        XCTAssertNotEqual(a.identity, b.identity, "Outstanding wrist/file ownership cannot reuse a take.")
        try await f.resume(b) { f.reply(b) }
        let expectedOrigin = f.origins
        let expectedCallbacks = f.callbacks.count
        let expectedReply = f.engine.testOnly_pendingWatchReply
        if afterRecording {
            f.callbacks.last?()
            await drain(f.engine)
            let media = try XCTUnwrap(f.engine.testOnly_claimRoutineMediaStart(at: 200))
            f.engine.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
            await drain(f.engine)
            XCTAssertTrue(f.engine.routineRecordingBoundary(for: b.token)?.didStartRecording == true)
        }
        held.release(f.reply(a, state))
        try await old.value
        await drain(f.engine)
        XCTAssertEqual(f.origins, expectedOrigin)
        XCTAssertEqual(f.callbacks.count, expectedCallbacks)
        XCTAssertEqual(f.acceptedReplies, [b.token])
        XCTAssertNil(f.started[a.token])
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertFalse(f.engine.routineRecordingBoundary(for: a.token)?.didStartRecording ?? true)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: b.token)?.startFailureDescription)
        XCTAssertFalse(f.watchStops.contains(b.identity))
        if !afterRecording {
            XCTAssertEqual(f.engine.testOnly_pendingWatchReply, expectedReply)
            XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, b.identity)
            XCTAssertEqual(f.engine.watchOwnedTakeIdentity, b.identity)
            XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(b))
            f.callbacks.last?()
            await drain(f.engine)
            XCTAssertEqual(f.engine.routineRecordingBoundary(for: b.token)?.token, b.token)
            XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        } else {
            XCTAssertTrue(f.engine.isRoutineRecording)
            try await finalizeSuccessor(f, request: b)
        }
    }

    private func finalizeSuccessor(_ f: Fixture, request: OrdinaryRoutineStartRequest) async throws {
        let media = try XCTUnwrap(f.engine.routineRecordingBoundary(for: request.token)?.mediaURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        pcm.frameLength = 4_800
        for i in 0..<4_800 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.1) }
        do { let file = try AVAudioFile(forWriting: media, settings: format.settings); try file.write(from: pcm) }
        let files = try CaptureCore.LocalRecordingFiles.make(in: f.root,
            sessionID: request.identity.sessionID, takeNumber: request.identity.takeNumber, roleLabel: "routine")
        var sidecar = CaptureCore.LocalRecordingSidecar.recording(sessionID: request.identity.sessionID,
            sessionConfig: request.configuration, takeIdentity: request.identity, files: files,
            recordingRole: "mac_routine_capture", platform: "macOS", appSurface: "Offline ownership test",
            sourceDeviceName: "Synthetic", videoDeviceUniqueID: "synthetic", videoDeviceName: "Synthetic",
            audioDeviceUniqueID: "synthetic", audioDeviceName: "Synthetic",
            captureTiming: try XCTUnwrap(f.started[request.token]).captureTiming, startedAt: Date())
        sidecar.mediaFileName = media.lastPathComponent
        try f.engine.testOnly_prepareSidecar(sidecar, url: files.sidecarURL)
        let stopped = expectation(description: "successor writer Stop")
        f.engine.testOnly_routineMovieWriterStopOverride = { stopped.fulfill() }
        f.engine.stopRoutineRecording()
        await fulfillment(of: [stopped], timeout: 5)
        let midi = try XCTUnwrap(f.engine.midiCaptureWindowTicket.takeToken)
        let finalized = expectation(description: "successor finalization published")
        let observation = f.engine.$lastRoutineRecordingURL.sink { url in
            if url == media { finalized.fulfill() }
        }
        defer { observation.cancel() }
        f.engine.testOnly_finalizePreparedRoutine(mediaURL: media, token: midi)
        await fulfillment(of: [finalized], timeout: 5)
        await drain(f.engine)
        let completion = try XCTUnwrap(f.engine.routineRecordingBoundary(for: request.token)?.completion)
        XCTAssertTrue(completion.succeeded)
        XCTAssertEqual(completion.token, request.token)
        XCTAssertNotEqual(f.engine.midiCaptureWindowTicket.owner, .take)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: Data(contentsOf: files.sidecarURL))
        XCTAssertEqual(saved.takeID, request.identity.takeID)
        XCTAssertEqual(saved.recordingStatus, "completed")
    }

    func testHeldSuccessCannotReplaceSuccessorCountIn() async throws { try await lateReply(.acknowledged) }
    func testHeldFailureCannotFailSuccessor() async throws { try await lateReply(.failed) }
    func testHeldTimeoutCannotPublishIntoSuccessor() async throws { try await lateReply(.timedOut) }
    func testLateSuccessCannotRestartBeatDuringSuccessorRecording() async throws { try await lateReply(.acknowledged, afterRecording: true) }
    func testLateFailureCannotMutateRecordingSuccessor() async throws { try await lateReply(.failed, afterRecording: true) }
    func testLateTimeoutCannotMutateRecordingSuccessor() async throws { try await lateReply(.timedOut, afterRecording: true) }

    func testABAUsesRequestIdentityRatherThanEqualConfiguration() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a1 = try f.begin()
        let old = Task { try await f.resume(a1) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        f.configuration.bpm = 110
        let b = try f.begin()
        f.configuration = a1.configuration
        let a2 = try f.begin()
        XCTAssertNotEqual(a1.token, a2.token)
        XCTAssertEqual(a1.configuration, a2.configuration)
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineStart(b))
        try await f.resume(a2) { f.reply(a2) }
        held.release(f.reply(a1))
        try await old.value
        XCTAssertEqual(f.acceptedReplies, [a2.token])
        XCTAssertEqual(f.origins.count, 1)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(a2))
    }

    func testStopDuringWatchAwaitPermanentlyRetiresStart() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let old = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        f.engine.stopRoutineRecording()
        held.release(f.reply(a))
        try await old.value
        await drain(f.engine)
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertTrue(f.callbacks.isEmpty)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
        XCTAssertEqual(f.watchStops, [a.identity])
    }

    func testStopThenRetryIsNotHitByQueuedUnownedStop() async throws {
        let f = try Fixture()
        defer { f.clean() }
        _ = try f.begin()
        f.engine.stopRoutineRecording()
        let b = try f.begin()
        try await f.resume(b) { f.reply(b, .unavailable) }
        f.callbacks.last?()
        await drain(f.engine)
        XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        XCTAssertNil(f.engine.routineRecordingBoundary(for: b.token)?.startFailureDescription)
    }

    func testImmediateReplyRetainsFastPathAndSameTokenHandoff() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        try await f.resume(a) { f.reply(a) }
        f.callbacks.last?()
        await drain(f.engine)
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineStart(a), "Outer ownership is consumed atomically by 4B1.")
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertEqual(f.origins.count, 1)
    }

    func testNoWatchStillProceedsWithDegradedEvidence() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        try await f.resume(a) { f.reply(a, .unavailable) }
        XCTAssertEqual(f.origins.count, 1)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(a))
    }

    func testCurrentTimeoutStillProceeds() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        try await f.resume(a) { f.reply(a, .timedOut) }
        XCTAssertEqual(f.origins.count, 1)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(a))
    }

    func testCurrentWatchFailureStillProceeds() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        try await f.resume(a) { f.reply(a, .failed) }
        XCTAssertEqual(f.origins.count, 1)
    }

    func testQueuedRecordingCallbackCannotHandoffAfterSupersession() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        try await f.resume(a) { f.reply(a) }
        f.callbacks.last?() // queues the MainActor handoff
        let b = try f.begin()
        await drain(f.engine)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(b))
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
    }

    func testStaleExplicitHandoffCannotConsumeSuccessorReservation() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin(), b = try f.begin()
        XCTAssertEqual(f.engine.startRoutineRecording(ordinaryStart: a), a.token)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(b))
        try await f.resume(b) { f.reply(b) }
        f.callbacks.last?()
        await drain(f.engine)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: b.token)?.mediaURL)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
    }

    func testCancelledReadinessOwnerCannotSendWatchCommand() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let beforeReadiness = try f.begin()
        let newer = try f.begin()
        var sent = false
        let result = await f.engine.awaitOrdinaryWatchReply(for: beforeReadiness) {
            sent = true
            return f.reply(beforeReadiness)
        }
        XCTAssertNil(result)
        XCTAssertFalse(sent)
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(newer))
    }
}

extension OrdinaryRoutineOuterStartTests {
    func testCancelledAwaitingTaskCannotResumeCurrentCapture() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let task = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        task.cancel()
        held.release(f.reply(a))
        try await task.value
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineStart(a))
    }

    func testCancelledOldTaskCannotCancelSuccessor() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let task = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        let b = try f.begin()
        task.cancel()
        held.release(f.reply(a))
        try await task.value
        XCTAssertTrue(f.engine.ownsOrdinaryRoutineStart(b))
        XCTAssertNil(f.engine.routineRecordingBoundary(for: b.token)?.startFailureDescription)
    }

    func testPreparedMediaRefusesAnotherOuterStartBeforeUIFlagDelivery() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        _ = f.engine.startRoutineRecording(ordinaryStart: a)
        XCTAssertThrowsError(try f.begin())
        await drain(f.engine)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
    }

    func testOtherMediaAdmissionRetiresOuterAwait() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let task = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        let otherIdentity = try f.engine.reserveNextRoutineTakeIdentity()
        f.engine.applyPendingWatchReply(WatchCaptureControlReply(commandID: UUID().uuidString,
            sessionID: otherIdentity.sessionID, takeID: otherIdentity.takeID,
            syncState: .acknowledged, detail: "Other capture surface"))
        let mediaOwner = f.engine.startRoutineRecording()
        held.release(f.reply(a))
        try await task.value
        await drain(f.engine)
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: mediaOwner)?.mediaURL)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: mediaOwner)?.startFailureDescription)
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, otherIdentity)
        XCTAssertFalse(f.watchStops.contains(otherIdentity))
    }

    func testHandoffKeepsAdmittedConfigurationWhenFormChanges() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        var later = a.configuration; later.bpm = 140; later.notes = "later form"
        f.engine.recordingSessionConfig = later
        _ = f.engine.startRoutineRecording(ordinaryStart: a)
        await drain(f.engine)
        XCTAssertEqual(f.engine.recordingSessionConfig, a.configuration)
    }

    func testStopAfterHandoffUsesExisting4B1PreparationCancellation() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        _ = f.engine.startRoutineRecording(ordinaryStart: a)
        f.engine.stopRoutineRecording()
        await drain(f.engine)
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineCapture(a))
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
    }
}


extension OrdinaryRoutineOuterStartTests {
    func testOrdinaryToggleStopsPendingWatchRequest() async throws {
        let f = try Fixture(), held = HeldReply()
        defer { f.clean() }
        let a = try f.begin()
        let task = Task { try await f.resume(a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        f.engine.toggleRoutineRecording()
        held.release(f.reply(a))
        try await task.value
        XCTAssertTrue(f.origins.isEmpty)
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineStart(a))
    }

    func testCurrentPreparationFailureStopsOnlyItsAcknowledgedWatch() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.begin()
        _ = await f.engine.awaitOrdinaryWatchReply(for: a) { f.reply(a) }
        f.engine.testOnly_routinePreparation = { _ in throw NSError(domain: "Offline preparation", code: 1) }
        _ = f.engine.startRoutineRecording(ordinaryStart: a)
        await drain(f.engine)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
        XCTAssertEqual(f.watchStops, [a.identity])
        XCTAssertNil(f.engine.watchOwnedTakeIdentity)
    }
}

// 4B3 calls the production CXL admission and post-Watch continuation. Only
// external Watch delivery, audible output and camera preparation are replaced.
@MainActor
final class PreparedCXLStartOwnershipTests: XCTestCase {
    @MainActor private final class HeldReply {
        let entered = XCTestExpectation(description: "CXL Watch continuation held")
        var continuation: CheckedContinuation<WatchCaptureControlReply, Never>?
        func wait() async -> WatchCaptureControlReply {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release(_ reply: WatchCaptureControlReply) {
            let pending = continuation; continuation = nil; pending?.resume(returning: reply)
        }
    }

    @MainActor private final class Fixture {
        let engine: MacCaptureEngine
        let bridge: ReferenceAuthoringCaptureBridge
        let root: URL
        let defaults: UserDefaults
        let suite = "scratchlab.4b3.\(UUID().uuidString)"
        let configuration: ReferenceAuthoringBridgeTakeConfiguration
        var beats: [RoutineRecordingRequestToken] = []
        var watchStops: [TakeIdentity] = []
        var metadata: [RoutineRecordingRequestToken: BeatEngineStartMetadata] = [:]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("4b3-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
            bridge = ReferenceAuthoringCaptureBridge(engine: engine)
            let prepared = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, loopBeats: 4,
                rootURL: root.appendingPathComponent("beats"))
            let intent = ReferenceCaptureIntent(id: "4b3-recipe", parentTechniqueID: "tear", variantID: "tear.forward",
                recipeID: "tear_1bar", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
                bpm: 95, beatsPerCycle: 4,
                plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1), beatSpec: prepared.binding)
            configuration = .init(technique: .tear, bpm: 95, beatEngineMode: .battleLoop,
                captureIntent: intent, preparedBeat: prepared)
            bridge.testOnly_preparedBeatStart = { [weak self] request in
                guard let self else { throw ScratchLabBeatEngineError.unableToStartAudio }
                self.beats.append(request.token)
                let result = Self.timing(request)
                self.metadata[request.token] = result
                return result
            }
            engine.testOnly_routinePreparation = { [root] token in
                root.appendingPathComponent("take-\(token.generation).wav")
            }
            engine.watchStopRequestHandler = { [weak self] identity in
                self?.watchStops.append(identity)
                return WatchCaptureControlReply(commandID: UUID().uuidString, sessionID: identity.sessionID,
                    takeID: identity.takeID, syncState: .unavailable, detail: "Offline")
            }
        }
        static func timing(_ request: RoutineStartRequest) -> BeatEngineStartMetadata {
            let click = AVAudioTime.hostTime(forSeconds: 100 + Double(request.token.generation))
            return .init(bpm: 95, countInBeats: 4, beatsPerBar: 4,
                clickStartHostTime: click, recordingStartHostTime: click + AVAudioTime.hostTime(forSeconds: 4 * 60.0 / 95),
                clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
                clickVersion: CaptureClickTrackDefaults.clickVersion,
                beatEngineMode: .battleLoop, beatEnabled: true, beatPatternName: BeatEngineMode.battleLoop.beatPatternName,
                beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion, swingAmount: 0,
                engineVersion: CaptureBeatEngineDefaults.engineVersion)
        }
        func cxl() throws -> RoutineStartRequest { try bridge.beginPendingStart(configuration: configuration) }
        func ordinary() throws -> RoutineStartRequest {
            try engine.beginOrdinaryRoutineStart(configuration: CaptureSessionConfig(bpm: 110, beatEngineMode: .boomBapTrainer))
        }
        func reply(_ request: RoutineStartRequest, _ state: CaptureWatchSyncState = .acknowledged) -> WatchCaptureControlReply {
            .init(commandID: UUID().uuidString, sessionID: request.identity.sessionID,
                takeID: request.identity.takeID, syncState: state, detail: "Offline")
        }
        func resume(_ request: RoutineStartRequest, _ reply: WatchCaptureControlReply) throws -> RoutineRecordingRequestToken {
            try bridge.continuePendingStart(request, configuration: configuration, reply: reply)
        }
        func clean() {
            engine.stopRoutineRecording()
            if let midi = engine.midiCaptureWindowTicket.takeToken {
                _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: midi)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func drain(_ engine: MacCaptureEngine) async {
        let queued = expectation(description: "session queue drained")
        engine.testOnly_afterSessionQueueDrains { queued.fulfill() }
        await fulfillment(of: [queued], timeout: 5)
        let published = expectation(description: "MainActor publication drained")
        DispatchQueue.main.async { published.fulfill() }
        await fulfillment(of: [published], timeout: 5)
    }
    private func hold(_ f: Fixture, request: RoutineStartRequest, reply: HeldReply) -> Task<Bool, Never> {
        Task {
            let value = await reply.wait()
            do { _ = try f.resume(request, value); return true }
            catch { f.bridge.abandonPendingStart(request); return false }
        }
    }
    private func activate(_ f: Fixture, _ request: RoutineStartRequest, cxl: Bool) async throws {
        if cxl { XCTAssertEqual(try f.resume(request, f.reply(request)), request.token) }
        else {
            XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(request), for: request))
            f.metadata[request.token] = Fixture.timing(request)
            XCTAssertEqual(f.engine.startRoutineRecording(for: request,
                captureTiming: f.metadata[request.token]?.captureTiming), request.token)
        }
        await drain(f.engine)
        let media = try XCTUnwrap(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        f.engine.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
        await drain(f.engine)
        XCTAssertTrue(f.engine.routineRecordingBoundary(for: request.token)?.didStartRecording == true)
    }
    private func finalize(_ f: Fixture, _ request: RoutineStartRequest) async throws {
        let media = try XCTUnwrap(f.engine.routineRecordingBoundary(for: request.token)?.mediaURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        pcm.frameLength = 4_800
        for i in 0..<4_800 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.1) }
        do { let file = try AVAudioFile(forWriting: media, settings: format.settings); try file.write(from: pcm) }
        let files = try CaptureCore.LocalRecordingFiles.make(in: f.root,
            sessionID: request.identity.sessionID, takeNumber: request.identity.takeNumber, roleLabel: "routine")
        var sidecar = CaptureCore.LocalRecordingSidecar.recording(sessionID: request.identity.sessionID,
            sessionConfig: request.configuration, takeIdentity: request.identity, files: files,
            recordingRole: "mac_routine_capture", platform: "macOS", appSurface: "Offline CXL ownership test",
            sourceDeviceName: "Synthetic", videoDeviceUniqueID: "synthetic", videoDeviceName: "Synthetic",
            audioDeviceUniqueID: "synthetic", audioDeviceName: "Synthetic",
            captureTiming: try XCTUnwrap(f.metadata[request.token]).captureTiming, startedAt: Date())
        sidecar.mediaFileName = media.lastPathComponent
        try f.engine.testOnly_prepareSidecar(sidecar, url: files.sidecarURL)
        let stopped = expectation(description: "current writer Stop")
        f.engine.testOnly_routineMovieWriterStopOverride = { stopped.fulfill() }
        f.engine.stopRoutineRecording()
        await fulfillment(of: [stopped], timeout: 5)
        let midi = try XCTUnwrap(f.engine.midiCaptureWindowTicket.takeToken)
        let finalized = expectation(description: "current finalization published")
        let observation = f.engine.$lastRoutineRecordingURL.sink { if $0 == media { finalized.fulfill() } }
        defer { observation.cancel() }
        f.engine.testOnly_finalizePreparedRoutine(mediaURL: media, token: midi)
        await fulfillment(of: [finalized], timeout: 5)
        await drain(f.engine)
        let completion = try XCTUnwrap(f.engine.routineRecordingBoundary(for: request.token)?.completion)
        XCTAssertTrue(completion.succeeded)
        XCTAssertEqual(completion.token, request.token)
        XCTAssertNotEqual(f.engine.midiCaptureWindowTicket.owner, .take)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: Data(contentsOf: files.sidecarURL))
        XCTAssertEqual(saved.takeID, request.identity.takeID)
        XCTAssertEqual(saved.recordingStatus, "completed")
    }
    private func crossMode(_ state: CaptureWatchSyncState, active: Bool = false) async throws {
        let f = try Fixture(), held = HeldReply(); defer { f.clean() }
        let a = try f.cxl(), old = hold(f, request: a, reply: held)
        await fulfillment(of: [held.entered], timeout: 5)
        let b = try f.ordinary()
        let bReply = f.reply(b)
        XCTAssertTrue(f.engine.applyPendingWatchReply(bReply, for: b))
        if active { try await activate(f, b, cxl: false) }
        let expectedTiming = f.metadata[b.token]
        held.release(f.reply(a, state))
        let admitted = await old.value
        XCTAssertFalse(admitted)
        await drain(f.engine)
        XCTAssertTrue(f.beats.isEmpty, "Stale CXL cannot establish any new origin/audio effect")
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertEqual(f.metadata[b.token], expectedTiming)
        XCTAssertFalse(f.watchStops.contains(b.identity))
        if !active {
            XCTAssertTrue(f.engine.ownsRoutineStart(b))
            XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, b.identity)
            XCTAssertEqual(f.engine.testOnly_pendingWatchReply, bReply)
            XCTAssertEqual(f.engine.watchOwnedTakeIdentity, b.identity)
            try await activate(f, b, cxl: false)
        }
        try await finalize(f, b)
    }
    func testLateCXLSuccessCannotConsumeOrdinaryReservationAndSuccessorFinalizes() async throws { try await crossMode(.acknowledged) }
    func testLateCXLFailureCannotClearOrdinaryStateAndSuccessorFinalizes() async throws { try await crossMode(.failed) }
    func testLateCXLTimeoutCannotReplaceOrdinaryStateAndSuccessorFinalizes() async throws { try await crossMode(.timedOut) }
    func testLateCXLSuccessCannotAffectActiveOrdinaryCapture() async throws { try await crossMode(.acknowledged, active: true) }
    func testLateCXLFailureCannotAffectActiveOrdinaryCapture() async throws { try await crossMode(.failed, active: true) }
    func testLateCXLTimeoutCannotAffectActiveOrdinaryCapture() async throws { try await crossMode(.timedOut, active: true) }

    func testCancelledCXLQueuedCleanupCannotRetireOrdinarySuccessor() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        XCTAssertTrue(f.engine.cancelPendingRoutineStart(a))
        let cleanup = Task { @MainActor in f.bridge.abandonPendingStart(a) }
        let b = try f.ordinary()
        XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(b), for: b))
        await cleanup.value
        await drain(f.engine)
        f.bridge.abandonPendingStart(a)
        XCTAssertTrue(f.engine.ownsRoutineStart(b))
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, b.identity)
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, b.identity)
        XCTAssertFalse(f.watchStops.contains(b.identity))
        try await activate(f, b, cxl: false)
        try await finalize(f, b)
    }
    func testCrossModeABAIgnoresEqualRecipeAndLateCleanup() async throws {
        let f = try Fixture(), held = HeldReply(); defer { f.clean() }
        let a1 = try f.cxl(), old = hold(f, request: a1, reply: held)
        await fulfillment(of: [held.entered], timeout: 5)
        let b = try f.ordinary(), a2 = try f.cxl()
        XCTAssertNotEqual(a1.token, a2.token)
        XCTAssertFalse(f.engine.ownsRoutineStart(b))
        XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(a2), for: a2))
        held.release(f.reply(a1)); let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, a2.identity)
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, a2.identity)
        try await activate(f, a2, cxl: true)
        try await finalize(f, a2)
    }
    func testDirectCXLSuccessorCannotBeConsumedByOldContinuation() async throws {
        let f = try Fixture(), held = HeldReply(); defer { f.clean() }
        let a1 = try f.cxl(), old = hold(f, request: a1, reply: held)
        await fulfillment(of: [held.entered], timeout: 5)
        let a2 = try f.cxl()
        XCTAssertNotEqual(a1.identity, a2.identity)
        held.release(f.reply(a1)); let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(f.engine.ownsRoutineStart(a2))
        try await activate(f, a2, cxl: true)
        try await finalize(f, a2)
    }
    func testLateOrdinaryReplyCannotDamagePreparedCXL() async throws {
        let f = try Fixture(), held = HeldReply(); defer { f.clean() }
        let a = try f.ordinary()
        let old = Task { await f.engine.awaitOrdinaryWatchReply(for: a) { await held.wait() } }
        await fulfillment(of: [held.entered], timeout: 5)
        let b = try f.cxl()
        XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(b), for: b))
        held.release(f.reply(a)); let accepted = await old.value
        XCTAssertNil(accepted)
        XCTAssertTrue(f.engine.ownsRoutineStart(b))
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, b.identity)
        try await activate(f, b, cxl: true)
        try await finalize(f, b)
    }
    func testStaleReservationConsumptionCannotTakeCurrentIdentity() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl(), b = try f.ordinary()
        _ = f.engine.startRoutineRecording(for: a)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertTrue(f.engine.ownsRoutineStart(b))
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, b.identity)
    }
    func testStaleReservationCancellationCannotClearCurrentWatch() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl(), b = try f.cxl(), reply = f.reply(b)
        XCTAssertTrue(f.engine.applyPendingWatchReply(reply, for: b))
        XCTAssertFalse(f.engine.cancelPendingRoutineStart(a))
        XCTAssertEqual(f.engine.testOnly_pendingWatchReply, reply)
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, b.identity)
        XCTAssertTrue(f.engine.ownsRoutineStart(b))
    }
    func testReplacementDuringPreparedAudioCannotSlipThroughMediaHandoff() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        var b: RoutineStartRequest?
        f.bridge.testOnly_preparedBeatStart = { request in
            b = try f.ordinary()
            return Fixture.timing(request)
        }
        XCTAssertThrowsError(try f.resume(a, f.reply(a)))
        f.bridge.abandonPendingStart(a)
        let successor = try XCTUnwrap(b)
        XCTAssertTrue(f.engine.ownsRoutineStart(successor))
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, successor.identity)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
    }
    func testPendingCXLStopPreventsLaterBeatOrActivation() async throws {
        let f = try Fixture(), held = HeldReply(); defer { f.clean() }
        let a = try f.cxl(), old = hold(f, request: a, reply: held)
        await fulfillment(of: [held.entered], timeout: 5)
        f.engine.stopRoutineRecording()
        held.release(f.reply(a)); let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(f.beats.isEmpty)
        XCTAssertNil(f.engine.testOnly_pendingRoutineTakeIdentity)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
    }
    func testCurrentCXLConsumesItsExactReservationAndConfiguration() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        f.engine.recordingSessionConfig = CaptureSessionConfig(bpm: 70)
        try await activate(f, a, cxl: true)
        XCTAssertFalse(f.engine.ownsRoutineStart(a))
        XCTAssertNil(f.engine.testOnly_pendingRoutineTakeIdentity)
        XCTAssertNil(f.engine.testOnly_pendingWatchReply)
        XCTAssertEqual(f.engine.recordingSessionConfig, a.configuration)
        XCTAssertEqual(f.beats, [a.token])
        try await finalize(f, a)
    }
    func testPendingCancellationAfterHandoffCannotCancelActiveCXL() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        try await activate(f, a, cxl: true)
        XCTAssertFalse(f.engine.cancelPendingRoutineStart(a))
        f.bridge.abandonPendingStart(a)
        await drain(f.engine)
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
        XCTAssertFalse(f.watchStops.contains(a.identity))
        try await finalize(f, a)
    }
    func testStalePendingCleanupCannotStopActiveCXLSuccessor() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a1 = try f.cxl(), a2 = try f.cxl()
        try await activate(f, a2, cxl: true)
        f.bridge.abandonPendingStart(a1)
        XCTAssertFalse(f.engine.cancelPendingRoutineStart(a1))
        await drain(f.engine)
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertFalse(f.watchStops.contains(a2.identity))
        try await finalize(f, a2)
    }
    func testCurrentPreparedAudioFailureCleansOnlyItsPendingOwner() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        f.bridge.testOnly_preparedBeatStart = { _ in throw ScratchLabBeatEngineError.unableToStartAudio }
        XCTAssertThrowsError(try f.resume(a, f.reply(a)))
        f.bridge.abandonPendingStart(a)
        await drain(f.engine)
        XCTAssertFalse(f.engine.ownsRoutineStart(a))
        XCTAssertNil(f.engine.testOnly_pendingRoutineTakeIdentity)
        XCTAssertNil(f.engine.testOnly_pendingWatchReply)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: a.token)?.mediaURL)
        XCTAssertTrue(f.watchStops.contains(a.identity))
    }
    func testCurrentWatchTimeoutStillAllowsEstablishedDegradedCapture() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        XCTAssertEqual(try f.resume(a, f.reply(a, .timedOut)), a.token)
        await drain(f.engine)
        XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        XCTAssertEqual(f.beats, [a.token])
        f.engine.stopRoutineRecording()
        await drain(f.engine)
    }
    func testCurrentWatchFailureStillAllowsEstablishedDegradedCapture() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        XCTAssertEqual(try f.resume(a, f.reply(a, .failed)), a.token)
        await drain(f.engine)
        XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        XCTAssertEqual(f.beats, [a.token])
        f.engine.stopRoutineRecording()
        await drain(f.engine)
    }
}

extension PreparedCXLStartOwnershipTests {
    func testLedgerConsumesOnlyTheOwnersExactReservation() {
        let ledger = RoutineRecordingBoundaryLedger()
        let a = ledger.beginRequest()
        let identity = TakeIdentity(sessionID: "a", takeID: "take-a", takeNumber: 1)
        let other = TakeIdentity(sessionID: "b", takeID: "take-b", takeNumber: 2)
        ledger.admitOuterStart(token: a)
        ledger.reserveOuterIdentity(identity, token: a)
        XCTAssertFalse(ledger.admitPreparation(token: a, reservedIdentity: other, requiresOuterOwnership: true))
        XCTAssertTrue(ledger.ownsOuterStart(a))
        XCTAssertNil(ledger.pendingPreparation)
        XCTAssertTrue(ledger.admitPreparation(token: a, reservedIdentity: identity, requiresOuterOwnership: true))
        XCTAssertFalse(ledger.ownsOuterStart(a))
        XCTAssertTrue(ledger.ownsPreparation(token: a))
        XCTAssertNil(ledger.retireOuterStart(expected: a))
    }
    func testLedgerExpectedCancellationDoesNotRetireReplacement() {
        let ledger = RoutineRecordingBoundaryLedger()
        let a = ledger.beginRequest(), b = ledger.beginRequest()
        ledger.admitOuterStart(token: a)
        ledger.admitOuterStart(token: b)
        XCTAssertNil(ledger.retireOuterStart(expected: a))
        XCTAssertTrue(ledger.ownsOuterStart(b))
        XCTAssertEqual(ledger.retireOuterStart(expected: b)?.token, b)
    }
    func testPreparedTimingReachesMediaAdmissionWithoutASecondOrigin() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        _ = try f.resume(a, f.reply(a))
        await drain(f.engine)
        let metadata = try XCTUnwrap(f.metadata[a.token])
        let planned = AVAudioTime.seconds(forHostTime: metadata.recordingStartHostTime)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: planned - ReferenceRecordingOriginPolicy.maximumPrerollSeconds - 1))
        XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: planned))
        XCTAssertEqual(f.beats, [a.token])
        f.engine.stopRoutineRecording()
        await drain(f.engine)
    }
    func testMovementCheckKeepsSilentUntimedOwnerHandoff() async throws {
        let f = try Fixture(); defer { f.clean() }
        let intent = ReferenceCaptureIntent(id: "4b3-movement", parentTechniqueID: "tear", variantID: "tear.forward",
            recipeID: "movement", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
            bpm: 95, beatsPerCycle: 4,
            plan: .init(countInBars: 0, repetitionCount: 1, tailBars: 0), beatSpec: nil, purpose: .movementCheck)
        let configuration = ReferenceAuthoringBridgeTakeConfiguration(technique: .tear, bpm: 95,
            captureIntent: intent)
        let a = try f.bridge.beginPendingStart(configuration: configuration)
        XCTAssertEqual(try f.bridge.continuePendingStart(a, configuration: configuration, reply: f.reply(a)), a.token)
        await drain(f.engine)
        XCTAssertTrue(f.beats.isEmpty)
        XCTAssertNil(a.configuration.plannedTakeDurationSeconds)
        XCTAssertNotNil(f.engine.testOnly_claimRoutineMediaStart(at: 1), "No invented beat origin gates movement capture")
        f.engine.stopRoutineRecording()
        await drain(f.engine)
    }
}

extension PreparedCXLStartOwnershipTests {
    func testCXLStopAfterReservationConsumptionUsesExistingMediaOwner() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.cxl()
        XCTAssertEqual(try f.resume(a, f.reply(a)), a.token)
        XCTAssertFalse(f.engine.ownsRoutineStart(a))
        f.engine.stopRoutineRecording()
        await drain(f.engine)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.startFailureDescription)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: 200))
        XCTAssertFalse(f.engine.ownsOrdinaryRoutineCapture(a))
        XCTAssertTrue(f.watchStops.contains(a.identity))
    }
}

extension PreparedCXLStartOwnershipTests {
    func testOldFinalizationCancellationCannotCancelNewPendingCXLStart() async throws {
        let f = try Fixture(); defer { f.clean() }
        let driver = ReferenceAuthoringWorkerDriver(bridge: f.bridge, engine: f.engine)
        let a = try f.cxl()
        XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(a), for: a))
        driver.cancelPendingFinalizationWait()
        await drain(f.engine)
        XCTAssertTrue(f.engine.ownsRoutineStart(a))
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, a.identity)
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, a.identity)
        XCTAssertFalse(f.watchStops.contains(a.identity))
        try await activate(f, a, cxl: true)
        try await finalize(f, a)
    }
    func testLateExplicitCXLAbandonCannotCancelSameBridgeSuccessor() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a1 = try f.cxl(), a2 = try f.cxl()
        XCTAssertEqual(a1.identity.sessionID, a2.identity.sessionID)
        XCTAssertTrue(f.engine.applyPendingWatchReply(f.reply(a2), for: a2))
        f.bridge.abandonPendingStart(a1)
        XCTAssertTrue(f.engine.ownsRoutineStart(a2))
        XCTAssertEqual(f.engine.testOnly_pendingRoutineTakeIdentity, a2.identity)
        XCTAssertEqual(f.engine.watchOwnedTakeIdentity, a2.identity)
        try await activate(f, a2, cxl: true)
        try await finalize(f, a2)
    }
}


/// Holds only the device boundary, with the real bounded admission/publication
/// pipeline. XCTest deadlines diagnose hangs; no production timeout is added.
@MainActor
final class BeatResponsivenessTests: XCTestCase {
    private final class HeldBinding: @unchecked Sendable {
        let entered = XCTestExpectation(description: "device worker entered")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var origins = 0
        func prepare() {
            XCTAssertFalse(Thread.isMainThread)
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first { entered.fulfill(); release.wait() }
        }
        func recordOrigin() { lock.withLock { origins += 1 } }
        var counts: (Int, Int) { lock.withLock { (calls, origins) } }
    }
    private enum BindingFailure: Error { case refused }

    private func engine(_ held: HeldBinding, failFirst: Bool = false) throws -> ScratchLabBeatEngine {
        let engine = ScratchLabBeatEngine()
        let schedule = try ScratchLabBeatEngine.makePlaybackSchedule(mode: .boomBapTrainer,
            bpm: 95, sampleRate: 48_000, usesClickCountIn: true)
        engine.testOnly_ordinaryPreparation = {
            held.prepare()
            if failFirst && held.counts.0 == 1 { throw BindingFailure.refused }
            return schedule
        }
        engine.testOnly_ordinaryHostTime = { AVAudioTime.hostTime(forSeconds: 100) }
        engine.testOnly_ordinaryPlaybackScheduled = { _ in held.recordOrigin() }
        engine.testOnly_ordinaryCallbackScheduled = { _, _ in }
        return engine
    }
    private func drain(_ engine: ScratchLabBeatEngine) async {
        let done = expectation(description: "device queue drained")
        engine.audioOperationQueue.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        let main = expectation(description: "publication drained")
        DispatchQueue.main.async { main.fulfill() }
        await fulfillment(of: [main], timeout: 5)
    }

    func testMainRequestReturnsWhileBindingHeldAndOnlyThenPublishesReadiness() async throws {
        let held = HeldBinding(), done = expectation(description: "ready")
        let e = try engine(held)
        defer { e.stop() }
        var result: BeatEngineStartMetadata?
        let generation = e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            result = try? $0.get(); done.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertNil(result)
        XCTAssertTrue(e.isCurrentRequest(generation))
        XCTAssertEqual(held.counts.1, 0)
        held.release.signal()
        await fulfillment(of: [done], timeout: 5)
        let metadata = try XCTUnwrap(result)
        XCTAssertTrue(e.isCurrentTimedStart(metadata))
        XCTAssertEqual(metadata.requestGeneration, generation)
        XCTAssertEqual(metadata.clickStartHostTime, AVAudioTime.hostTime(forSeconds: 100) + AVAudioTime.hostTime(forSeconds: 0.12))
        XCTAssertEqual(held.counts.1, 1)
    }

    func testBindingFailurePublishesCurrentFailureWithoutBlockingMain() async throws {
        let held = HeldBinding(), done = expectation(description: "failure")
        let e = try engine(held, failFirst: true)
        var failed = false
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            if case .failure(let error) = $0 { failed = error is BindingFailure }
            done.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertFalse(failed)
        held.release.signal()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(failed)
        XCTAssertEqual(held.counts.1, 0)
    }

    func testStopRetiresClientBeforeHeldCallReturnsWithoutClaimingPhysicalCancellation() async throws {
        let held = HeldBinding(), retired = expectation(description: "logical request retired")
        let e = try engine(held)
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            if case .success = $0 { XCTFail("Stopped request published readiness") }
            retired.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        e.stop()
        await fulfillment(of: [retired], timeout: 5)
        XCTAssertEqual(held.counts.1, 0)
        XCTAssertEqual(e.testOnly_pendingOperationCount, 1)
        held.release.signal()
        await drain(e)
        XCTAssertEqual(held.counts.1, 0)
    }

    func testThousandReplacementsUseOnePendingSlotAndOnlyNewestOrigin() async throws {
        let held = HeldBinding(), first = expectation(description: "first retired")
        let latest = expectation(description: "latest ready")
        let e = try engine(held)
        defer { e.stop() }
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            if case .success = $0 { XCTFail("Stale first request") }; first.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        var successes = 0, completions = 0
        for index in 0..<1_000 {
            e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
                completions += 1
                if case .success = $0 { successes += 1; XCTAssertEqual(index, 999) }
                if index == 999 { latest.fulfill() }
            }
            XCTAssertEqual(e.testOnly_pendingOperationCount, 1)
        }
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(held.counts.0, 1)
        held.release.signal()
        await fulfillment(of: [latest], timeout: 5)
        XCTAssertEqual(held.counts.0, 2)
        XCTAssertEqual(held.counts.1, 1)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(completions, 1_000)
    }

    func testLateFirstFailureCannotFailSuccessor() async throws {
        let held = HeldBinding(), first = expectation(description: "first retired")
        let latest = expectation(description: "new ready")
        let e = try engine(held, failFirst: true)
        defer { e.stop() }
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            if case .success = $0 { XCTFail("obsolete success") }; first.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true) {
            if case .failure(let error) = $0 { XCTFail("successor failed: \(error)") }; latest.fulfill()
        }
        await fulfillment(of: [first], timeout: 5)
        held.release.signal()
        await fulfillment(of: [latest], timeout: 5)
        XCTAssertEqual(held.counts.1, 1)
    }

    func testPracticePreviewIsPendingAndStopRemainsResponsiveDuringHeldBinding() async throws {
        let held = HeldBinding(), e = try engine(held)
        let suite = "scratchlab.beat-responsive.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PracticeBeatStore(defaults: defaults, beatEngine: e)
        store.selectBeatMode(.boomBapTrainer)
        store.setBeatEnabled(true)
        store.togglePlayback()
        XCTAssertTrue(store.isPreparingPlayback)
        XCTAssertFalse(store.isPlaying)
        await fulfillment(of: [held.entered], timeout: 5)
        store.togglePlayback()
        XCTAssertFalse(store.isPreparingPlayback)
        XCTAssertFalse(store.isPlaying)
        held.release.signal()
        await drain(e)
        XCTAssertFalse(store.isPlaying)
        XCTAssertNil(store.playbackErrorMessage)
        XCTAssertEqual(held.counts.1, 0)
    }

    func testReadinessPublishesBeforeImmediateCountInCallbacks() async throws {
        let held = HeldBinding(), e = try engine(held)
        let complete = expectation(description: "all callbacks"), ready = expectation(description: "ready")
        defer { e.stop() }
        e.testOnly_ordinaryCallbackScheduled = { _, callback in callback() }
        var hasMetadata = false, beats: [Int] = []
        e.requestStart(mode: .boomBapTrainer, bpm: 95, usesClickCountIn: true,
            onCountInBeat: { XCTAssertTrue(hasMetadata); beats.append($0) },
            onRecordingStart: { XCTAssertTrue(hasMetadata); complete.fulfill() }) {
                if case .success = $0 { hasMetadata = true }; ready.fulfill()
            }
        await fulfillment(of: [held.entered], timeout: 5)
        held.release.signal()
        await fulfillment(of: [ready, complete], timeout: 5)
        XCTAssertEqual(beats, [1, 2, 3, 4])
    }

    func testPreparedOutputHeldStopPreventsOriginAndReadiness() async throws {
        let held = HeldBinding(), e = ScratchLabBeatEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let beat = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, loopBeats: 4, rootURL: root)
        e.testOnly_preparedOutput = { held.prepare() }
        e.testOnly_preparedPlaybackScheduled = { _ in held.recordOrigin() }
        let retired = expectation(description: "prepared retired")
        e.requestPreparedStart(beat, mode: .battleLoop, bpm: 95, isStillOwned: { true }) {
            if case .success = $0 { XCTFail("stopped prepared request ready") }; retired.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        e.stop()
        await fulfillment(of: [retired], timeout: 5)
        held.release.signal()
        await drain(e)
        XCTAssertEqual(held.counts.1, 0)
    }

    func testPreparedOutputPublishesBoundPCMMetadataOnlyAfterCompletion() async throws {
        let held = HeldBinding(), e = ScratchLabBeatEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { e.stop(); try? FileManager.default.removeItem(at: root) }
        let beat = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, loopBeats: 4, rootURL: root)
        e.testOnly_preparedOutput = { held.prepare() }
        e.testOnly_preparedPlaybackScheduled = { _ in held.recordOrigin() }
        var metadata: BeatEngineStartMetadata?
        let ready = expectation(description: "prepared ready")
        e.requestPreparedStart(beat, mode: .battleLoop, bpm: 95, isStillOwned: { true }) {
            metadata = try? $0.get(); ready.fulfill()
        }
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertNil(metadata)
        held.release.signal()
        await fulfillment(of: [ready], timeout: 5)
        let value = try XCTUnwrap(metadata)
        XCTAssertTrue(e.isCurrentTimedStart(value))
        XCTAssertEqual(value.beatEngineMode, .battleLoop)
        XCTAssertEqual(AVAudioTime.seconds(forHostTime: value.recordingStartHostTime - value.clickStartHostTime),
            Double(beat.binding.countInFrameCount) / Double(beat.binding.sampleRate), accuracy: 1e-8)
        XCTAssertEqual(held.counts.1, 1)
    }
}


extension OrdinaryRoutinePreparationOwnershipTests {
    func testAdmittedRoutedInputStoppedWhileDEBUGPreparationHeldCannotArm() async throws {
        let e = engine(), held = HeldPreparation("admissible input, preparation held")
        defer { held.release() }
        e.recordingSessionConfig = CaptureSessionConfig(captureMode: .calibrationNoClick, beatEngineMode: .silent)
        e.testOnly_routineAudioInputChoice = .init(uniqueID: "synthetic-routed", name: "USB Audio Codec")
        e.testOnly_routinePreparation = { _ in held.hold(); return URL(fileURLWithPath: "/tmp/admitted-stopped.mov") }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        e.stopRoutineRecording()
        let cancelled = e.routineRecordingBoundary(for: token)
        held.release()
        await drain(e)
        XCTAssertEqual(e.routineRecordingBoundary(for: token), cancelled)
        XCTAssertFalse(e.isRoutineRecording)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
        XCTAssertFalse(e.routineRecordingBoundary(for: token)?.didStartRecording ?? true)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.completion)
        XCTAssertNotEqual(e.midiCaptureWindowTicket.owner, .take)
    }

    func testUnsuitableMicrophoneRefusesBeforeDEBUGPreparationAndMediaArm() async throws {
        let e = engine()
        e.recordingSessionConfig = CaptureSessionConfig(captureMode: .calibrationNoClick, beatEngineMode: .silent)
        e.testOnly_routineAudioInputChoice = .init(uniqueID: "BuiltInMicrophoneDevice", name: "Built-in Microphone")
        let media = url(RoutineRecordingRequestToken(generation: 1))
        e.testOnly_routinePreparation = { _ in
            XCTFail("Unsuitable capture must not enter deterministic preparation.")
            return media
        }
        e.testOnly_beforeRoutineMediaArm = { _ in XCTFail("Refused capture must never reach media arming.") }
        var recordingPublications: [Bool] = []
        let observation = e.$isRoutineRecording.sink { recordingPublications.append($0) }
        defer { observation.cancel() }

        let token = e.startRoutineRecording()
        await drain(e)
        let refused = try XCTUnwrap(e.routineRecordingBoundary(for: token))
        XCTAssertEqual(refused.startFailureDescription, MacCaptureEngine.isolatedCaptureBuiltInMicrophoneMessage)
        XCTAssertEqual(e.routineRecordingStatus, MacCaptureEngine.isolatedCaptureBuiltInMicrophoneMessage)
        XCTAssertFalse(recordingPublications.contains(true))
        XCTAssertFalse(e.isRoutineRecording)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100))
        XCTAssertNotEqual(e.midiCaptureWindowTicket.owner, .take)
        XCTAssertNil(refused.takeID)
        XCTAssertNil(refused.mediaURL)
        XCTAssertFalse(refused.didStartRecording)
        XCTAssertFalse(refused.didEnterFinalization)
        XCTAssertNil(refused.completion)
        XCTAssertNil(e.testOnly_activeSidecar)
        XCTAssertEqual(e.routineMediaStartHostTime, 0)

        // An unsolicited writer confirmation cannot promote the refused request.
        e.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
        await drain(e)
        XCTAssertEqual(e.routineRecordingBoundary(for: token), refused)
        XCTAssertFalse(recordingPublications.contains(true))
    }

    private func admittedDEBUGPreparation(choice: MacCaptureEngine.AudioInputDeviceChoice,
                                          configuration: CaptureSessionConfig) async throws {
        let e = engine(), held = HeldPreparation("admitted preparation held")
        defer { held.release() }
        e.recordingSessionConfig = configuration
        e.testOnly_routineAudioInputChoice = choice
        let media = URL(fileURLWithPath: "/tmp/admitted-debug-preparation.mov")
        e.testOnly_routinePreparation = { _ in held.hold(); return media }
        let token = e.startRoutineRecording()
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertNil(e.testOnly_claimRoutineMediaStart(at: 100), "Preparation has not completed.")
        XCTAssertFalse(e.routineRecordingBoundary(for: token)?.didStartRecording ?? true)
        held.release()
        await drain(e)
        XCTAssertTrue(e.isRoutineRecording)
        XCTAssertEqual(e.routineRecordingStatus, "Starting routine recording")
        XCTAssertEqual(e.testOnly_claimRoutineMediaStart(at: 100), media)
        XCTAssertFalse(e.routineRecordingBoundary(for: token)?.didStartRecording ?? true)
        e.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
        await drain(e)
        XCTAssertTrue(e.routineRecordingBoundary(for: token)?.didStartRecording == true)
        XCTAssertNil(e.routineRecordingBoundary(for: token)?.startFailureDescription)
        XCTAssertEqual(e.routineRecordingBoundary(for: token)?.mediaURL, media)
        XCTAssertTrue(e.isRoutineRecording)
        if let midi = e.midiCaptureWindowTicket.takeToken { _ = e.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
    }

    func testSuitableRoutedInputStillPreparesAndStartsThroughDEBUGHook() async throws {
        try await admittedDEBUGPreparation(choice: .init(uniqueID: "synthetic-routed", name: "USB Audio Codec"),
            configuration: CaptureSessionConfig(captureMode: .calibrationNoClick, beatEngineMode: .silent))
    }

    func testBuiltInMicrophoneStillAdmittedOutsideIsolatedSilentMode() async throws {
        try await admittedDEBUGPreparation(choice: .init(uniqueID: "BuiltInMicrophoneDevice", name: "Built-in Microphone"),
            configuration: CaptureSessionConfig(captureMode: .timedClick, beatEngineMode: .clickTrack))
    }
}

/// Historical completion survives; only the current exact request may publish UI state.
@MainActor
final class RoutineFinalizationPublicationOwnershipTests: XCTestCase {
    @MainActor private final class Fixture {
        let test: XCTestCase
        let engine: MacCaptureEngine
        let root: URL
        let defaults: UserDefaults
        let suite = "scratchlab.finalization-owner.\(UUID().uuidString)"
        let config = CaptureSessionConfig(captureMode: .calibrationNoClick, beatEngineMode: .silent)
        var held: [RoutineRecordingRequestToken: @MainActor () -> Void] = [:]
        var arrivals: [RoutineRecordingRequestToken: XCTestExpectation] = [:]

        init(_ test: XCTestCase) throws {
            self.test = test
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
            engine.testOnly_routineAudioInputChoice = .init(uniqueID: "synthetic", name: "USB Audio Codec")
            engine.testOnly_holdRoutineFinalizationPublication = { [weak self] token, publish in
                guard let self, let token else { return XCTFail("Fixture requires an actual recording token.") }
                self.held[token] = publish
                self.arrivals.removeValue(forKey: token)?.fulfill()
            }
        }
        func drain() async {
            let queued = test.expectation(description: "session queue completed")
            engine.testOnly_afterSessionQueueDrains { queued.fulfill() }
            await test.fulfillment(of: [queued], timeout: 5)
            let published = test.expectation(description: "main publication barrier")
            DispatchQueue.main.async { published.fulfill() }
            await test.fulfillment(of: [published], timeout: 5)
        }
        func start(_ name: String) async throws -> RoutineStartRequest {
            let media = root.appendingPathComponent(name).appendingPathExtension("wav")
            engine.testOnly_routinePreparation = { _ in media }
            let request = try engine.beginRoutineStart(configuration: config)
            XCTAssertEqual(engine.startRoutineRecording(for: request), request.token)
            await drain()
            XCTAssertEqual(engine.testOnly_claimRoutineMediaStart(at: 100), media)
            engine.fileOutput(AVCaptureMovieFileOutput(), didStartRecordingTo: media, from: [])
            await drain()
            XCTAssertTrue(engine.isRoutineRecording)
            XCTAssertTrue(engine.routineRecordingBoundary(for: request.token)?.didStartRecording == true)
            return request
        }
        func holdFinalization(_ request: RoutineStartRequest, sidecar: Bool, error: Error? = nil) async throws {
            let media = try XCTUnwrap(engine.routineRecordingBoundary(for: request.token)?.mediaURL)
            if sidecar {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
                pcm.frameLength = 4_800
                for i in 0..<4_800 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.1) }
                do { let file = try AVAudioFile(forWriting: media, settings: format.settings); try file.write(from: pcm) }
                let files = try CaptureCore.LocalRecordingFiles.make(in: root,
                    sessionID: request.identity.sessionID, takeNumber: request.identity.takeNumber, roleLabel: "routine")
                var data = CaptureCore.LocalRecordingSidecar.recording(sessionID: request.identity.sessionID,
                    sessionConfig: request.configuration, takeIdentity: request.identity, files: files,
                    recordingRole: "mac_routine_capture", platform: "macOS", appSurface: "Offline publication test",
                    sourceDeviceName: "Synthetic", videoDeviceUniqueID: "synthetic", videoDeviceName: "Synthetic",
                    audioDeviceUniqueID: "synthetic", audioDeviceName: "Synthetic", startedAt: Date())
                data.mediaFileName = media.lastPathComponent
                try engine.testOnly_prepareSidecar(data, url: files.sidecarURL)
            }
            let stopped = test.expectation(description: "owned writer stopped")
            engine.testOnly_routineMovieWriterStopOverride = { stopped.fulfill() }
            engine.stopRoutineRecording()
            await test.fulfillment(of: [stopped], timeout: 5)
            await drain()
            let midi = try XCTUnwrap(engine.midiCaptureWindowTicket.takeToken)
            let arrived = test.expectation(description: "finalization publication held")
            arrivals[request.token] = arrived
            engine.testOnly_finalizePreparedRoutine(mediaURL: media, token: midi, error: error)
            await test.fulfillment(of: [arrived], timeout: 5)
            await drain()
            XCTAssertNotEqual(engine.midiCaptureWindowTicket.owner, .take)
        }
        func release(_ request: RoutineStartRequest) throws { try XCTUnwrap(held[request.token])() }
        func clean() {
            engine.testOnly_holdRoutineFinalizationPublication = nil
            held.removeAll()
            if let midi = engine.midiCaptureWindowTicket.takeToken { _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: midi) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Also used by the reconciled original early-return test after this repair passes.
    static func verifyEarlyReturnContract(in test: XCTestCase) async throws {
        let f = try Fixture(test); defer { f.clean() }
        enum Failure: Error { case preparation }
        f.engine.testOnly_routinePreparation = { [root = f.root] _ in root.appendingPathComponent("failed.wav") }
        f.engine.testOnly_beforeRoutineMediaArm = { _ in throw Failure.preparation }
        let failed = f.engine.startRoutineRecording()
        await f.drain()
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: failed)?.startFailureDescription)
        XCTAssertNotEqual(f.engine.midiCaptureWindowTicket.owner, .take)
        XCTAssertFalse(f.engine.isRoutineRecording)
        XCTAssertFalse(f.engine.isRoutineFinalizationPending)
        XCTAssertNil(f.engine.testOnly_claimRoutineMediaStart(at: 100))
        f.engine.testOnly_beforeRoutineMediaArm = nil
        let a = try await f.start("a")
        let midiA = try XCTUnwrap(f.engine.midiCaptureWindowTicket.takeToken)
        let releases = f.engine.midiCaptureWindowReleaseCount
        try await f.holdFinalization(a, sidecar: false)
        XCTAssertEqual(f.engine.midiCaptureWindowReleaseCount, releases + 1)
        XCTAssertFalse(f.engine.testOnly_releaseAbandonedTakeMIDIWindow(token: midiA))
        let b = try await f.start("b")
        let bWindow = f.engine.midiCaptureWindowTicket
        let bState = f.engine.routineRecordingBoundary(for: b.token)
        let bStatus = f.engine.routineRecordingStatus
        let bURL = f.engine.lastRoutineRecordingURL
        let bSession = f.engine.lastRoutineRecordingSessionID
        try f.release(a)
        try f.release(a) // Duplicate current-state publication is harmless.
        f.engine.testOnly_finalizeWithoutSidecar(mediaURL: try XCTUnwrap(bState?.mediaURL).deletingLastPathComponent().appendingPathComponent("a.wav"), token: midiA)
        await f.drain()
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertFalse(f.engine.isRoutineFinalizationPending)
        XCTAssertEqual(f.engine.midiCaptureWindowTicket, bWindow)
        XCTAssertEqual(f.engine.routineRecordingBoundary(for: b.token), bState)
        XCTAssertEqual(f.engine.routineRecordingStatus, bStatus)
        XCTAssertEqual(f.engine.lastRoutineRecordingURL, bURL)
        XCTAssertEqual(f.engine.lastRoutineRecordingSessionID, bSession)
        let aCompletion = try XCTUnwrap(f.engine.routineRecordingBoundary(for: a.token)?.completion)
        XCTAssertFalse(aCompletion.succeeded)
        XCTAssertEqual(aCompletion.token, a.token)
        XCTAssertEqual(aCompletion.statusMessage, "Recording finalization did not produce a completed sidecar.")
        try await f.holdFinalization(b, sidecar: true)
        XCTAssertTrue(f.engine.isRoutineFinalizationPending)
        let bFinalizing = f.engine.routineRecordingStatus
        try f.release(a)
        XCTAssertTrue(f.engine.isRoutineFinalizationPending)
        XCTAssertEqual(f.engine.routineRecordingStatus, bFinalizing)
        try f.release(b)
        await f.drain()
        XCTAssertFalse(f.engine.isRoutineFinalizationPending)
        XCTAssertFalse(f.engine.isRoutineRecording)
        XCTAssertTrue(f.engine.routineRecordingBoundary(for: b.token)?.completion?.succeeded == true)
        XCTAssertEqual(f.engine.lastRoutineRecordingURL, bState?.mediaURL)
        XCTAssertEqual(f.engine.lastRoutineRecordingSessionID, b.identity.sessionID)
    }

    func testNoSidecarReleaseThenSuccessorRejectsLatePublicationAndStillFinalizes() async throws {
        try await Self.verifyEarlyReturnContract(in: self)
    }

    func testA1ThenBThenSameSemanticA2RejectsA1Publication() async throws {
        let f = try Fixture(self); defer { f.clean() }
        let a1 = try await f.start("same-a")
        try await f.holdFinalization(a1, sidecar: false)
        let b = try await f.start("b")
        try await f.holdFinalization(b, sidecar: false)
        let a2 = try await f.start("same-a")
        let a2State = f.engine.routineRecordingBoundary(for: a2.token)
        XCTAssertEqual(f.engine.routineRecordingBoundary(for: a1.token)?.takeID, a2State?.takeID)
        XCTAssertEqual(a1.identity.sessionID, a2.identity.sessionID)
        XCTAssertNotEqual(a1.token, a2.token)
        let window = f.engine.midiCaptureWindowTicket, status = f.engine.routineRecordingStatus
        try f.release(a1); try f.release(b); try f.release(a1)
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertEqual(f.engine.midiCaptureWindowTicket, window)
        XCTAssertEqual(f.engine.routineRecordingStatus, status)
        XCTAssertEqual(f.engine.routineRecordingBoundary(for: a2.token), a2State)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a1.token)?.completion)
        try await f.holdFinalization(a2, sidecar: true)
        try f.release(a2)
        XCTAssertTrue(f.engine.routineRecordingBoundary(for: a2.token)?.completion?.succeeded == true)
    }

    func testCurrentNoSidecarFailurePublishesHistoricalErrorExactlyOnce() async throws {
        let f = try Fixture(self); defer { f.clean() }
        let a = try await f.start("error")
        let error = NSError(domain: "OfflineFinalization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic finalization failure"])
        try await f.holdFinalization(a, sidecar: false, error: error)
        try f.release(a)
        let completion = try XCTUnwrap(f.engine.routineRecordingBoundary(for: a.token)?.completion)
        XCTAssertFalse(completion.succeeded)
        XCTAssertEqual(completion.statusMessage, error.localizedDescription)
        XCTAssertFalse(f.engine.isRoutineRecording)
        XCTAssertFalse(f.engine.isRoutineFinalizationPending)
        let b = try await f.start("successor")
        let status = f.engine.routineRecordingStatus
        try f.release(a)
        XCTAssertEqual(f.engine.routineRecordingBoundary(for: a.token)?.completion, completion)
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertEqual(f.engine.routineRecordingStatus, status)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: b.token)?.completion)
    }

    func testNormalSidecarPublicationIsCurrentOnceAndCannotOverwriteSuccessor() async throws {
        let f = try Fixture(self); defer { f.clean() }
        let a = try await f.start("normal")
        try await f.holdFinalization(a, sidecar: true)
        XCTAssertTrue(f.engine.isRoutineFinalizationPending)
        XCTAssertThrowsError(try f.engine.beginRoutineStart(configuration: f.config))
        try f.release(a)
        await f.drain()
        XCTAssertTrue(f.engine.routineRecordingBoundary(for: a.token)?.completion?.succeeded == true)
        XCTAssertEqual(f.engine.lastRoutineRecordingSessionID, a.identity.sessionID)
        let b = try await f.start("b")
        let status = f.engine.routineRecordingStatus
        let url = f.engine.lastRoutineRecordingURL
        try f.release(a)
        await f.drain()
        XCTAssertTrue(f.engine.isRoutineRecording)
        XCTAssertEqual(f.engine.routineRecordingStatus, status)
        XCTAssertEqual(f.engine.lastRoutineRecordingURL, url)
        XCTAssertNil(f.engine.routineRecordingBoundary(for: b.token)?.completion)
    }

    func testPendingSuccessorAndItsCancellationNeverRestoreHistoricalOwner() async throws {
        let f = try Fixture(self); defer { f.clean() }
        let a = try await f.start("a")
        try await f.holdFinalization(a, sidecar: false)
        let b = try f.engine.beginRoutineStart(configuration: f.config)
        let status = f.engine.routineRecordingStatus
        try f.release(a)
        XCTAssertTrue(f.engine.ownsRoutineStart(b))
        XCTAssertEqual(f.engine.routineRecordingStatus, status)
        XCTAssertNotNil(f.engine.routineRecordingBoundary(for: a.token)?.completion)
        _ = f.engine.cancelPendingRoutineStart(b)
        try f.release(a)
        XCTAssertEqual(f.engine.routineRecordingStatus, status)
    }
}
