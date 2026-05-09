import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

final class MotionWindowBuilderTests: XCTestCase {

    // MARK: - Frame fixtures

    /// Build a synthetic in-memory clip. Caller can mutate individual frames
    /// by index so tests can drop landmarks / push coordinates out of range.
    private func makeClipFrames(
        count: Int,
        timestampStart: Double = 0,
        timestampStep: Double = 1.0 / 30.0,
        mutate: (Int, inout ScratchMotionFrame) -> Void = { _, _ in }
    ) -> [ScratchMotionFrame] {
        var out: [ScratchMotionFrame] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var f = ScratchMotionFrame(
                timestamp: timestampStart + Double(i) * timestampStep,
                dominantHand: CGPoint(x: 0.5, y: 0.5),
                dominantHandWrist: CGPoint(x: 0.4, y: 0.6),
                dominantHandIndexTip: CGPoint(x: 0.5, y: 0.5),
                dominantHandThumbTip: CGPoint(x: 0.45, y: 0.55),
                dominantHandMiddleTip: CGPoint(x: 0.55, y: 0.45),
                dominantHandConfidence: 0.9,
                secondaryHandWrist: CGPoint(x: 0.7, y: 0.6),
                recordCenter: nil
            )
            mutate(i, &f)
            out.append(f)
        }
        return out
    }

    // MARK: - Window count math

    func test_windowing_emitsExpectedCountForSyntheticClip() {
        // 90 frames, 60-frame windows, 30-frame stride → starts at 0 and 30,
        // ending at 60 and 90 → exactly 2 windows.
        let frames = makeClipFrames(count: 90)
        let builder = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        )
        let windows = builder.windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].windowIndex, 0)
        XCTAssertEqual(windows[1].windowIndex, 1)
        XCTAssertEqual(windows[0].frameCount, 60)
        XCTAssertEqual(windows[1].frameCount, 60)
        // Window 0: frames 0..59 (last timestamp = 59/30 ≈ 1.9667 s)
        XCTAssertEqual(windows[0].startTimestamp, 0, accuracy: 1e-9)
        XCTAssertEqual(windows[0].endTimestamp, 59.0 / 30.0, accuracy: 1e-9)
        // Window 1: frames 30..89 (last timestamp = 89/30 ≈ 2.9667 s)
        XCTAssertEqual(windows[1].startTimestamp, 30.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(windows[1].endTimestamp, 89.0 / 30.0, accuracy: 1e-9)
    }

    func test_windowing_returnsEmptyForUndersizedClip() {
        let frames = makeClipFrames(count: 30)
        let builder = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        )
        let windows = builder.windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertTrue(windows.isEmpty)
    }

    func test_windowing_singleWindowWhenExactlyOneFits() {
        let frames = makeClipFrames(count: 60)
        let builder = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        )
        let windows = builder.windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].frameCount, 60)
    }

    func test_windowing_customWindowAndStride() {
        // 100 frames, window=20, stride=10
        // starts at 0, 10, 20, 30, 40, 50, 60, 70, 80
        // (start + 20) must be <= 100 → 9 windows
        let frames = makeClipFrames(count: 100)
        let builder = MotionWindowBuilder(
            configuration: .init(windowFrames: 20, strideFrames: 10)
        )
        let windows = builder.windows(forFrames: frames, classLabel: "tears", sourceFile: "y.jsonl")
        XCTAssertEqual(windows.count, 9)
        XCTAssertEqual(windows.first?.frameCount, 20)
    }

    // MARK: - Clamp + sentinel

    func test_clamp_pullsSlightlyOverOneIntoUnitSquare() {
        let frames = makeClipFrames(count: 60) { i, frame in
            if i == 10 {
                frame = ScratchMotionFrame(
                    timestamp: Double(i) / 30.0,
                    dominantHand: CGPoint(x: 1.0007, y: 0.5),
                    dominantHandWrist: CGPoint(x: 0.4, y: 1.0006),
                    dominantHandIndexTip: CGPoint(x: -0.001, y: 0.5),
                    dominantHandConfidence: 0.9
                )
            }
        }
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows.count, 1)
        let frame10 = windows[0].frames[10]
        XCTAssertEqual(frame10.dominantHandX, 1.0, accuracy: 1e-12)
        XCTAssertEqual(frame10.dominantHandWristY, 1.0, accuracy: 1e-12)
        XCTAssertEqual(frame10.dominantHandIndexTipX, 0.0, accuracy: 1e-12)
        XCTAssertTrue(frame10.dominantHandPresent)
        XCTAssertTrue(frame10.dominantHandWristPresent)
        XCTAssertTrue(frame10.dominantHandIndexTipPresent)
    }

    func test_missingPoint_becomesSentinelWithPresentFalse() {
        let frames = makeClipFrames(count: 60) { i, frame in
            if i == 5 {
                frame = ScratchMotionFrame(
                    timestamp: Double(i) / 30.0,
                    dominantHand: nil,
                    dominantHandWrist: nil,
                    dominantHandIndexTip: nil,
                    dominantHandThumbTip: nil,
                    dominantHandMiddleTip: nil,
                    dominantHandConfidence: 0,
                    secondaryHandWrist: nil,
                    recordCenter: nil
                )
            }
        }
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30, missingCoordinateSentinel: 0)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows.count, 1)
        let f = windows[0].frames[5]
        XCTAssertFalse(f.dominantHandPresent)
        XCTAssertFalse(f.dominantHandWristPresent)
        XCTAssertFalse(f.dominantHandIndexTipPresent)
        XCTAssertFalse(f.secondaryHandWristPresent)
        XCTAssertEqual(f.dominantHandX, 0)
        XCTAssertEqual(f.dominantHandY, 0)
        XCTAssertEqual(f.secondaryHandWristX, 0)
    }

    func test_customSentinelValue() {
        let frames = makeClipFrames(count: 60) { i, frame in
            if i == 0 {
                frame = ScratchMotionFrame(
                    timestamp: 0,
                    dominantHand: nil,
                    dominantHandConfidence: 0
                )
            }
        }
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30, missingCoordinateSentinel: -1)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows[0].frames[0].dominantHandX, -1)
        XCTAssertEqual(windows[0].frames[0].dominantHandY, -1)
        XCTAssertFalse(windows[0].frames[0].dominantHandPresent)
    }

    // MARK: - Aggregates

    func test_aggregates_zeroForStaticClip() {
        let frames = makeClipFrames(count: 60)  // every frame at (0.5, 0.5)
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        let agg = windows[0].aggregates
        XCTAssertEqual(agg.dominantHandPathLength, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.dominantWristPathLength, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.romX, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.romY, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.meanVelocity, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.maxVelocity, 0, accuracy: 1e-12)
        XCTAssertEqual(agg.centerLineCrossings, 0)
        XCTAssertEqual(agg.dominantHandMissingRatio, 0, accuracy: 1e-12)
    }

    func test_aggregates_centerLineCrossingsCounted() {
        // Sweep dominant hand x from 0.3 → 0.7 → 0.3 → 0.7 across 60 frames.
        // At centerLine = 0.5 we expect 3 sign flips (low→high, high→low, low→high).
        let frames = makeClipFrames(count: 60) { i, frame in
            let x: Double = {
                let phase = i / 15  // 4 phases of 15 frames
                switch phase {
                case 0: return 0.3
                case 1: return 0.7
                case 2: return 0.3
                default: return 0.7
                }
            }()
            frame = ScratchMotionFrame(
                timestamp: Double(i) / 30.0,
                dominantHand: CGPoint(x: x, y: 0.5),
                dominantHandWrist: CGPoint(x: x - 0.05, y: 0.6),
                dominantHandConfidence: 0.9
            )
        }
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30, centerLine: 0.5)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        XCTAssertEqual(windows[0].aggregates.centerLineCrossings, 3)
        XCTAssertEqual(windows[0].aggregates.romX, 0.4, accuracy: 1e-9)
    }

    func test_aggregates_missingRatio() {
        let frames = makeClipFrames(count: 60) { i, frame in
            if i % 3 == 0 {
                frame = ScratchMotionFrame(
                    timestamp: Double(i) / 30.0,
                    dominantHand: nil,
                    dominantHandWrist: nil,
                    dominantHandConfidence: 0
                )
            }
        }
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        // 20 of 60 frames have nil dominantHand & wrist
        XCTAssertEqual(windows[0].aggregates.dominantHandMissingRatio, 20.0 / 60.0, accuracy: 1e-12)
        XCTAssertEqual(windows[0].aggregates.dominantHandWristMissingRatio, 20.0 / 60.0, accuracy: 1e-12)
    }

    // MARK: - Class label / source file plumbing

    func test_preservesClassLabelAndSourceFile() {
        let frames = makeClipFrames(count: 60)
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forFrames: frames, classLabel: "transformer", sourceFile: "abc.jsonl")
        XCTAssertEqual(windows[0].classLabel, "transformer")
        XCTAssertEqual(windows[0].sourceFile, "abc.jsonl")
    }

    // MARK: - File I/O round trip

    func test_loadAndWindow_fromOnDiskJSONL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_window_io_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("baby_take01.jsonl")
        let frames = makeClipFrames(count: 75)
        let encoder = JSONEncoder()
        var text = ""
        for f in frames {
            let data = try encoder.encode(f)
            text.append(String(data: data, encoding: .utf8)!)
            text.append("\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)

        let windows = try MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forClipAt: url, classLabel: "baby")
        // 75 frames, window 60, stride 30 → starts 0, 15-cap → only start at 0 fits since 0+60=60 <= 75 but 30+60=90>75.
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].frameCount, 60)
        XCTAssertEqual(windows[0].sourceFile, "baby_take01.jsonl")
        XCTAssertEqual(windows[0].classLabel, "baby")
    }

    // MARK: - Codable round trip

    func test_window_roundTripsThroughJSON() throws {
        let frames = makeClipFrames(count: 60)
        let windows = MotionWindowBuilder(
            configuration: .init(windowFrames: 60, strideFrames: 30)
        ).windows(forFrames: frames, classLabel: "baby", sourceFile: "x.jsonl")
        let data = try JSONEncoder().encode(windows[0])
        let decoded = try JSONDecoder().decode(MotionFeatureWindow.self, from: data)
        XCTAssertEqual(decoded, windows[0])
    }
}
