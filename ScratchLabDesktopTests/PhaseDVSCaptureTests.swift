import AudioToolbox
import AVFoundation
import XCTest
@testable import ScratchLab

final class PhaseDVSCaptureTests: XCTestCase {
    private func evidence(rejected: Set<Int> = [15,16,17,18,19], sign: Int = 1) -> PhaseDVSRecordingEvidence {
        let connection = UUID()
        let blocks = (0..<40).map { i in
            PhaseDVSRecordingEvidence.Block(start: -0.01 + Double(i) / 100, duration: 0.01,
                rawFrameOffset: i * 480, frameCount: 480, sampleTime: Double(i * 480),
                hostTime: UInt64(i + 1), confidence: rejected.contains(i) ? 0.2 : 0.9,
                delta: rejected.contains(i) ? nil : (i < 20 ? 0.01 : -0.01),
                rejection: rejected.contains(i) ? "low_confidence" : nil)
        }
        return .init(version: 1, sessionID: "session", takeID: "take", deviceUID: "S9-test",
            connectionID: connection, sampleRate: 48_000, controlChannels: [3,4], programmeChannels: [5,6],
            rawControlFileName: "control.wav", rawControlSHA256: String(repeating: "a", count: 64),
            rawFrameCount: 19_200, mediaDuration: 0.38, mediaStartHostSeconds: 10, firstAudioHostSeconds: 9.99,
            polarity: .init(deviceUID: "S9-test", connectionID: connection, decoderForwardSign: sign,
                confirmedAt: Date(timeIntervalSince1970: 0), acceptedBufferCount: 20), blocks: blocks)
    }

    private func edited(_ edit: (inout [String: Any]) -> Void) throws -> PhaseDVSRecordingEvidence {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence())) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(PhaseDVSRecordingEvidence.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testRejectedSignalRemainsUnknownWithoutJoiningTravelOrInventingHold() throws {
        let result = try evidence().motionEvidence()
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.map(\.direction), ["forward", "backward"])
        XCTAssertEqual(result.trajectorySegments.count, 2)
        XCTAssertTrue(result.trajectorySegments.allSatisfy { $0.samples.count > 2 })
        XCTAssertEqual(result.intervals.count, 5)
        XCTAssertTrue(result.intervals.allSatisfy { $0.kind == .unknown })
        XCTAssertLessThan(result.events[0].endTime, result.events[1].startTime)
        XCTAssertEqual(result.events[0].startTime, 0)
        XCTAssertEqual(result.events.last!.endTime, 0.38, accuracy: 1e-9)
    }

    func testEntireRejectedTakeHasNoMotionOrStillness() throws {
        let result = try evidence(rejected: Set(0..<40)).motionEvidence()
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.trajectorySegments.isEmpty)
        XCTAssertEqual(result.intervals.map(\.kind), [.unknown])
    }

    func testPolarityChangesDirectionWithoutInventingRevolutionScale() throws {
        let source = evidence(sign: -1)
        XCTAssertEqual(try source.motionEvidence().events.map(\.direction), ["backward", "forward"])
        XCTAssertEqual(source.coordinates.basis, .normalizedTakeLocalDisplacement)
        XCTAssertEqual(try JSONDecoder().decode(PhaseDVSRecordingEvidence.self,
            from: JSONEncoder().encode(source)), source)
    }

    func testSampleLossFailsEvenWhenHostTimesAreMonotonic() throws {
        let broken = try edited { object in
            var blocks = object["blocks"] as! [[String: Any]]
            blocks[10]["sampleTime"] = 4801
            object["blocks"] = blocks
        }
        XCTAssertThrowsError(try broken.motionEvidence())
    }

    func testRawOffsetsCannotSkipOrRepeatFrames() throws {
        let broken = try edited { object in
            var blocks = object["blocks"] as! [[String: Any]]
            blocks[10]["rawFrameOffset"] = 4801
            object["blocks"] = blocks
        }
        XCTAssertThrowsError(try broken.validate())
    }

    func testLowConfidenceCannotBeReclassifiedAsAccepted() throws {
        let broken = try edited { object in
            var blocks = object["blocks"] as! [[String: Any]]
            blocks[15]["delta"] = 0.01
            blocks[15].removeValue(forKey: "rejection")
            object["blocks"] = blocks
        }
        XCTAssertThrowsError(try broken.validate())
    }

    func testConnectionAndDeviceCalibrationCannotBeReusedForAnotherSource() throws {
        for field in ["deviceUID", "connectionID"] {
            let broken = try edited { $0[field] = field == "deviceUID" ? "other" : UUID().uuidString }
            XCTAssertThrowsError(try broken.validate())
        }
    }

    func testMissingMovieCoverageAndUnsafeCompanionPathsFailClosed() throws {
        for change: (String, Any) in [("mediaDuration", 1.0), ("rawControlFileName", "../control.wav"), ("rawFrameCount", 1)] {
            let broken = try edited { $0[change.0] = change.1 }
            XCTAssertThrowsError(try broken.validate())
        }
    }

    func testSourceTagAloneDoesNotGrantControllerCalibration() throws {
        let source = evidence()
        let motion = try source.motionEvidence()
        XCTAssertFalse(motion.events.contains(where: CaptureCore.usesGestureRelativeControllerNotation))
        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: motion.events, platterTrajectorySegments: motion.trajectorySegments,
            platterEvidenceIntervals: motion.intervals, coordinates: source.coordinates)
        XCTAssertEqual(projection.coordinateSpace, source.coordinates.coordinateSpace)
        XCTAssertFalse(projection.records.isEmpty)
    }

    func testPhaseSelectedWithoutSignalCannotFallBackToCameraOrRaneMotion() {
        let source = LivePerformedNotationDataSource(selectedMIDISourceName: { "RANE ONE MKII" },
            capturedMidiCCEventsSnapshot: { [] }, cameraMovementEventsSnapshot: { _ in [] },
            phaseMotion: { .init(events: [], intervals: [], trajectorySegments: []) })
        let state = LivePerformedNotationTracker.computeState(dataSource: source, baselineTimestamp: 0)
        guard case .tracking(let committed, let provisional, _, _, let path, _, _, _) = state else {
            return XCTFail("Explicit Phase route must own the empty motion state")
        }
        XCTAssertTrue(committed.isEmpty); XCTAssertNil(provisional); XCTAssertTrue(path.isEmpty)
    }

    func testInterleavedIngressKeepsEveryChannelAndClockWithoutAliasing() {
        let config = TimecodeRealtimeIngressRingConfiguration(slotCount: 2, maximumChannelCount: 2, maximumFrameCountPerSlot: 8)!
        let ring = TimecodeRealtimeIngressRing(configuration: config)
        var samples: [Float] = [1,10,2,20,3,30,4,40]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var stamp = AudioTimeStamp(); stamp.mHostTime = 7; stamp.mSampleTime = 19
            stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            XCTAssertEqual(ring.publishInterleaved(bufferList: &list, channelCount: 2, sampleRate: 48_000, timestamp: stamp), .published)
        }
        samples[0] = 99
        XCTAssertEqual(ring.drainPending { slot in
            XCTAssertEqual(Array(slot.samples(forChannel: 0)), [1,2,3,4])
            XCTAssertEqual(Array(slot.samples(forChannel: 1)), [10,20,30,40])
            XCTAssertEqual(slot.hostTime, 7); XCTAssertEqual(slot.sampleTime, 19)
        }, 1)
    }

    func testInterleavedIngressRejectsMissingClockAndPartialFrames() {
        let ring = TimecodeRealtimeIngressRing(configuration: .production)
        var samples: [Float] = [1,2,3]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var stamp = AudioTimeStamp(); stamp.mHostTime = 1; stamp.mSampleTime = 0
            stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            XCTAssertNotEqual(ring.publishInterleaved(bufferList: &list, channelCount: 2, sampleRate: 48_000, timestamp: stamp), .published)
            list.mBuffers.mDataByteSize = 8; stamp.mFlags = []
            XCTAssertNotEqual(ring.publishInterleaved(bufferList: &list, channelCount: 2, sampleRate: 48_000, timestamp: stamp), .published)
        }
        XCTAssertEqual(ring.publishedCount, 0); XCTAssertEqual(ring.rejectedCount, 2)
    }
    private func sidecar(_ phase: PhaseDVSRecordingEvidence) throws -> CaptureCore.LocalRecordingSidecar {
        let motion = try phase.motionEvidence()
        var sidecar = CaptureCore.LocalRecordingSidecar(sessionID: phase.sessionID, takeID: phase.takeID,
            appLocalTakeNumber: 1, recordingRole: "camA", platform: "macOS", appSurface: "reference",
            sourceDeviceName: "Test", audioDeviceUniqueID: phase.deviceUID, audioDeviceName: "DJM-S9",
            startedAt: Date(timeIntervalSince1970: 0), recordingStatus: "completed",
            mediaFileName: "take.mov", sidecarFileName: "take.json")
        sidecar.phaseDVSEvidence = phase
        return sidecar.withDetectedNotation(.init(notationSource: PhaseDVSRecordingEvidence.source,
            notationConfidence: 0.9, detectedLabel: nil, labelSource: "test", labelConfidence: nil,
            detectionSources: [PhaseDVSRecordingEvidence.source], recordMovementEvents: motion.events,
            audioEvents: [], faderEvents: [], mixerMidiEvents: [], capturedAt: Date(timeIntervalSince1970: 0)))
    }

    func testBoundNotationRoundTripRejectsChangedControlEvidence() throws {
        let phase = evidence(), motion = try phase.motionEvidence()
        let original = try sidecar(phase)
        let binding = try ReferenceTearEvidenceCodec.makeSourceBinding(rawSidecarData: original.encodedData(), fileName: "take.json")
        let review = ReferenceTearSegmentationReviewBuilder.build(referenceTakeID: "reference",
            movementEvents: motion.events, platterEvidenceIntervals: motion.intervals,
            derivation: nil, coordinates: phase.coordinates)
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review, platterTrajectorySegments: motion.trajectorySegments)
        let bytes = try ReferenceTearEvidenceCodec.encode(sourceBinding: binding, review: review, projection: projection,
            performedLimitations: review.requiredIntrinsicComparisonLimitations)
        guard case .restored(let document) = try ReferenceTearEvidenceCodec.decode(bytes, expectedSource: binding) else {
            return XCTFail("Bound Phase evidence was not restored")
        }
        XCTAssertEqual(document.projection, projection)
        var changed = original
        changed.phaseDVSEvidence = evidence(sign: -1)
        let changedBinding = try ReferenceTearEvidenceCodec.makeSourceBinding(rawSidecarData: changed.encodedData(), fileName: "take.json")
        XCTAssertThrowsError(try ReferenceTearEvidenceCodec.encode(sourceBinding: changedBinding, review: review, projection: projection,
            performedLimitations: review.requiredIntrinsicComparisonLimitations))
    }

    private func writePCM(_ url: URL, frames: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<frames {
            pcm.floatChannelData![0][i] = Float(i) / 100_000
            pcm.floatChannelData![1][i] = -Float(i) / 200_000
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: pcm)
    }

    func testCameraBoundFinalizerKeepsStereoSamplesAndPortableRawControl() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("input.wav"), control = root.appendingPathComponent("control.wav")
        let output = root.appendingPathComponent("take.wav")
        try writePCM(program, frames: 19_200); try writePCM(control, frames: 19_200)
        let absolute = try edited { object in
            var blocks = object["blocks"] as! [[String: Any]]
            for i in blocks.indices { blocks[i]["start"] = (blocks[i]["start"] as! Double) + 10 }
            object["blocks"] = blocks
        }
        let result = try PhaseS9InputCapture.testOnly_finalizeRecordedInput(programmeURL: program,
            controlURL: control, destination: output, evidence: absolute, mediaStart: 10)
        XCTAssertEqual(result.frames, 18_240)
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(file.length, 18_240); XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(buffer.floatChannelData![0][0], Float(480) / 100_000)
        XCTAssertEqual(buffer.floatChannelData![1][18_239], -Float(18_719) / 200_000)
        XCTAssertEqual(try result.evidence.verifiedControlURL(beside: output), control)
        let sidecar = try sidecar(result.evidence)
        let artifacts = try SessionArchiveBuilder.boundBeatExportArtifacts(sidecar: sidecar,
            mediaURL: root.appendingPathComponent("take.mov"), sidecarURL: root.appendingPathComponent("take.json"), takeNumber: 1)
        XCTAssertEqual(Set(artifacts.map(\.source)), ["phase_dvs_control", "phase_dvs_sidecar"])
        try Data("changed".utf8).write(to: control)
        XCTAssertThrowsError(try result.evidence.verifiedControlURL(beside: output))
    }

    func testCameraBoundFinalizerRejectsTruncatedProgramme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("input.wav"), control = root.appendingPathComponent("control.wav")
        try writePCM(program, frames: 100); try writePCM(control, frames: 19_200)
        let absolute = try edited { object in
            var blocks = object["blocks"] as! [[String: Any]]
            for i in blocks.indices { blocks[i]["start"] = (blocks[i]["start"] as! Double) + 10 }
            object["blocks"] = blocks
        }
        XCTAssertThrowsError(try PhaseS9InputCapture.testOnly_finalizeRecordedInput(programmeURL: program,
            controlURL: control, destination: root.appendingPathComponent("take.wav"), evidence: absolute, mediaStart: 10)) { error in
            XCTAssertTrue(error.localizedDescription.contains("truncated"))
        }
    }

    func testExternalFaderPositionsCannotClaimScratchLabSoftwareGain() {
        let binding = ScratchMixerFaderEvidence.Binding(sourceID: "S9-test", connectionGeneration: 1,
            channel: 7, controller: 31, minimum: 0, maximum: 127, inverted: false,
            response: .init(zeroAt: 0, oneAt: 1, shape: .linear))
        var mixer = ScratchMixerFaderEvidence(version: 1, sessionID: "session", takeID: "take", epoch: 10,
            end: 1, sealed: true, overflowed: false, observations: [
                .init(control: .crossfader, time: 0, kind: .message, binding: binding, rawValue: 127),
                .init(control: .rightChannel, time: 0, kind: .message, binding: binding, rawValue: 127)])
        XCTAssertEqual(mixer.combinedSpans(in: 0...1).first?.gain, 1)
        mixer.gainAuthority = .externalUncalibrated
        XCTAssertTrue(mixer.spans(for: .crossfader, in: 0...1).allSatisfy { $0.gain == nil })
        XCTAssertTrue(mixer.combinedSpans(in: 0...1).allSatisfy { $0.state == nil })
    }

    func testMalformedPolarityCannotOverflowValidation() throws {
        let invalid = try edited { object in
            var polarity = object["polarity"] as! [String: Any]
            polarity["decoderForwardSign"] = Int.min
            object["polarity"] = polarity
        }
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertTrue(PhaseDVSRecordingEvidence.project(blocks: [], duration: 1, forwardSign: Int.min).events.isEmpty)
    }

}
