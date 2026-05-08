import XCTest
@testable import ScratchNotation

/// Belt-and-braces check that no source-side identifiers can sneak into a
/// generated/encoded notation timeline. The constraint list mirrors the
/// project's ASC-safe scrubbing requirements.
final class LeakScanTests: XCTestCase {

    private static let forbiddenTokens: [String] = [
        "/Users",
        "MakeMKV",
        "sourceMKV",
        "QBERT",
        "SXRATCH",
        "rightsStatus",
        "reviewStatus"
    ]

    func test_generatedJSON_containsNoForbiddenTokens() throws {
        let generator = ScratchNotationGenerator()
        let timeline = generator.generate(
            takeID: "baby_79bpm_take01",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 6.08,
            bpm: 79,
            audioOnsets: [
                AudioOnsetEvent(startTime: 0.0, endTime: 2.3, confidence: 0.9)
            ],
            audioSilences: [
                AudioSilenceEvent(startTime: 2.3, endTime: 6.08, confidence: 0.95)
            ],
            visualMotion: [
                VisualMotionEvent(direction: .forward, startTime: 0.0, endTime: 1.1, confidence: 0.85),
                VisualMotionEvent(direction: .back,    startTime: 1.1, endTime: 2.3, confidence: 0.85),
                VisualMotionEvent(direction: .still,   startTime: 2.3, endTime: 6.08, confidence: 0.9)
            ],
            beatGrid: BeatGrid(bpm: 79, firstBeatTime: 0, beatCount: 8)
        )

        let data = try NotationCodec.encode(timeline)
        let json = String(decoding: data, as: UTF8.self)
        for token in Self.forbiddenTokens {
            XCTAssertFalse(
                json.contains(token),
                "Forbidden token '\(token)' leaked into generated notation JSON"
            )
        }
    }

    func test_approvedJSON_containsNoForbiddenTokens() throws {
        var timeline = DatasetNotationTimeline(
            takeID: "x_120bpm_take03",
            scratchType: "baby",
            bpm: 120,
            beatMode: .beatPlusScratch,
            duration: 4.0,
            events: [
                DatasetNotationEvent(
                    type: .stroke,
                    direction: .forward,
                    startTime: 0,
                    endTime: 1,
                    beatPosition: 1,
                    source: .manual,
                    confidence: 1.0,
                    approved: true
                )
            ],
            approvalState: .approved
        )
        timeline.events.append(DatasetNotationEvent(
            type: .silence,
            direction: .none,
            startTime: 1,
            endTime: 4,
            source: .audio,
            confidence: 0.95,
            approved: true
        ))

        let data = try NotationCodec.encode(timeline)
        let json = String(decoding: data, as: UTF8.self)
        for token in Self.forbiddenTokens {
            XCTAssertFalse(json.contains(token),
                "Forbidden token '\(token)' leaked into approved notation JSON")
        }
    }

    /// Guardrail: ensure the model fields themselves don't include any of the
    /// forbidden identifiers as Codable property names. If somebody renames a
    /// property to e.g. `reviewStatus` this test will fail.
    func test_modelFieldNames_doNotIncludeForbiddenTokens() throws {
        let probe = DatasetNotationTimeline(
            takeID: "x",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 0.0,
            events: [
                DatasetNotationEvent(
                    type: .unknown, direction: .unknown,
                    startTime: 0, endTime: 0,
                    source: .audio, confidence: 0
                )
            ]
        )
        let json = String(decoding: try NotationCodec.encode(probe), as: UTF8.self)
        for token in Self.forbiddenTokens {
            XCTAssertFalse(json.contains(token), "Forbidden token '\(token)' in default-encoded model")
        }
    }
}
