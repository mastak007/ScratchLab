import XCTest
@testable import ScratchNotation

final class NotationCodecTests: XCTestCase {

    func test_approvedTimeline_roundTripsThroughJSON() throws {
        let original = DatasetNotationTimeline(
            takeID: "test_120bpm_take01",
            scratchType: "baby",
            bpm: 120,
            beatMode: .noBeat,
            duration: 6.0,
            events: [
                DatasetNotationEvent(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    type: .stroke,
                    direction: .forward,
                    startTime: 0.5,
                    endTime: 1.0,
                    beatPosition: 1.0,
                    source: .fused,
                    confidence: 0.92,
                    approved: true
                ),
                DatasetNotationEvent(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    type: .silence,
                    direction: .none,
                    startTime: 1.0,
                    endTime: 6.0,
                    beatPosition: 2.0,
                    source: .audio,
                    confidence: 0.95,
                    approved: true
                )
            ],
            approvalState: .approved
        )

        let data = try NotationCodec.encode(original)
        let decoded = try NotationCodec.decode(data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.approvalState, .approved)
        XCTAssertTrue(decoded.events.allSatisfy { $0.approved })
        XCTAssertEqual(decoded.schemaVersion, DatasetNotationTimeline.currentSchemaVersion)
    }

    func test_writeAndReadFromTempFile() throws {
        let timeline = DatasetNotationTimeline(
            takeID: "x",
            scratchType: "baby",
            bpm: 100,
            beatMode: .beatPlusScratch,
            duration: 1.0,
            events: [
                DatasetNotationEvent(
                    type: .hold,
                    direction: .none,
                    startTime: 0,
                    endTime: 1.0,
                    source: .vision,
                    confidence: 0.4
                )
            ],
            approvalState: .needsReview
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_notation_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent(NotationFile.inferredFilename)
        try NotationCodec.write(timeline, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = try NotationCodec.read(from: url)
        XCTAssertEqual(reloaded, timeline)
    }

    func test_jsonOutput_hasStableKeyOrdering() throws {
        let timeline = DatasetNotationTimeline(
            takeID: "x",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 1.0
        )
        let a = try NotationCodec.encode(timeline)
        let b = try NotationCodec.encode(timeline)
        XCTAssertEqual(a, b, "Encoder output must be deterministic for diff-friendly sidecars")
    }
}
