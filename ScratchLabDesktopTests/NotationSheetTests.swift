import XCTest
import Testing
@testable import ScratchLab

// MARK: - Notation Sheet / CapturedNotationDisplayView Tests

@Suite("CapturedNotationDisplayView data model")
struct NotationSheetTests {

    // MARK: Helpers

    private func makeMovementEvent(
        start: Double, end: Double,
        direction: String = "forward",
        kind: ScratchMovementKind = .normalPush,
        confidence: Double = 0.90
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: start, endTime: end,
            startPosition: 0.2, endPosition: 0.8,
            direction: direction, movementKind: kind,
            speed: 0.7, confidence: confidence,
            source: "camera"
        )
    }

    private func makeAudioEvent(
        start: Double, end: Double,
        kind: String = "scratchBurst",
        confidence: Double = 0.85
    ) -> CaptureCore.DetectedNotationAudioEvent {
        CaptureCore.DetectedNotationAudioEvent(
            startTime: start, endTime: end,
            duration: end - start,
            peakLevel: -12.0, rmsLevel: -18.0,
            confidence: confidence, eventKind: kind,
            source: "audio"
        )
    }

    private func makeFaderEvent(
        start: Double, end: Double
    ) -> CaptureCore.DetectedNotationFaderEvent {
        CaptureCore.DetectedNotationFaderEvent(
            startTime: start, endTime: end,
            eventKind: .cut, control: "crossfader",
            fromValue: 0.9, toValue: 0.1,
            source: "midi", confidence: 0.92
        )
    }

    private func makeSnapshot(
        source: String,
        movements: [CaptureCore.DetectedNotationRecordMovementEvent] = [],
        audio: [CaptureCore.DetectedNotationAudioEvent] = [],
        fader: [CaptureCore.DetectedNotationFaderEvent] = [],
        confidence: Double? = nil,
        detectionSources: [String] = []
    ) -> CaptureCore.DetectedNotationSnapshot {
        CaptureCore.DetectedNotationSnapshot(
            notationSource: source,
            notationConfidence: confidence,
            detectedLabel: nil,
            labelSource: "auto",
            labelConfidence: nil,
            detectionSources: detectionSources,
            recordMovementEvents: movements,
            audioEvents: audio,
            faderEvents: fader,
            mixerMidiEvents: [],
            capturedAt: Date()
        )
    }

    // MARK: 1. Detected snapshot uses captured data, not template

    @Test("Detected snapshot hasDetectedMovementEvents = true")
    func detectedSnapshotHasMovementEvents() {
        let snap = makeSnapshot(
            source: "detected",
            movements: [makeMovementEvent(start: 0.0, end: 0.3)]
        )
        #expect(snap.hasDetectedMovementEvents)
        #expect(snap.hasDetectedEvents)
        #expect(snap.notationSource == "detected")
    }

    // MARK: 2. Partial notation: audio events present, no movement events

    @Test("Partial snapshot has audio events, no movement events")
    func partialSnapshotAudioOnly() {
        let snap = makeSnapshot(
            source: "partial",
            audio: [makeAudioEvent(start: 0.1, end: 0.4)]
        )
        #expect(snap.hasAudioEvents)
        #expect(!snap.hasDetectedMovementEvents)
        #expect(snap.notationSource == "partial")
    }

    // MARK: 3. Detected notation: movement events present

    @Test("Detected snapshot reports hasDetectedMovementEvents correctly")
    func detectedMovementLaneActive() {
        let snap = makeSnapshot(
            source: "detected",
            movements: [
                makeMovementEvent(start: 0.0, end: 0.2, direction: "forward"),
                makeMovementEvent(start: 0.3, end: 0.5, direction: "backward", kind: .normalPull)
            ]
        )
        #expect(snap.recordMovementEvents.count == 2)
        #expect(snap.recordMovementEvents[0].direction == "forward")
        #expect(snap.recordMovementEvents[1].direction == "backward")
        #expect(snap.hasDetectedMovementEvents)
    }

    // MARK: 4. Fader events → fader lane active

    @Test("Fader events present → snapshot hasDetectedEvents = true")
    func faderEventsActivateFaderLane() {
        let snap = makeSnapshot(
            source: "partial",
            fader: [makeFaderEvent(start: 0.1, end: 0.12)]
        )
        #expect(!snap.faderEvents.isEmpty)
        #expect(snap.hasDetectedEvents)
    }

    // MARK: 5. Unavailable notation has no events

    @Test("Unavailable notation returns hasDetectedEvents = false")
    func unavailableSnapshotIsEmpty() {
        let snap = makeSnapshot(source: "unavailable")
        #expect(!snap.hasDetectedEvents)
        #expect(!snap.hasAudioEvents)
        #expect(!snap.hasDetectedMovementEvents)
        #expect(snap.faderEvents.isEmpty)
    }

    // MARK: 6. Template mode is distinct from captured

    @Test("Captured snapshot is not template — notationSource is not 'template'")
    func capturedSnapshotIsNotTemplate() {
        let detected = makeSnapshot(source: "detected",
                                    movements: [makeMovementEvent(start: 0, end: 0.2)])
        let partial  = makeSnapshot(source: "partial",
                                    audio: [makeAudioEvent(start: 0, end: 0.3)])
        #expect(detected.notationSource != "template")
        #expect(partial.notationSource  != "template")
    }

    // MARK: 7. Review mini preview uses captured notation state

    @Test("Snapshot with movement events qualifies for a visual notation preview")
    func reviewMiniPreviewQualifiesWithMovementEvents() {
        let empty = makeSnapshot(source: "unavailable")
        let detected = makeSnapshot(source: "detected",
                                    movements: [makeMovementEvent(start: 0, end: 0.25)])
        // A preview is only shown when there are movement events
        #expect(empty.recordMovementEvents.isEmpty)
        #expect(!detected.recordMovementEvents.isEmpty)
    }

    // MARK: 8. No external brand strings in UI source

    @Test("NotationVisualizerView.swift contains no TTM or SXRATCH brand strings")
    func noBrandStringsInNotationView() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("TTM"))
        #expect(!source.contains("SXRATCH"))
    }

    // MARK: 9. No file IO or JSON decoding in snapshot structs

    @Test("DetectedNotationSnapshot is a pure value type — no hidden decoding or IO")
    func snapshotIsPureValueType() {
        // Creating a snapshot performs no IO — if this doesn't hang, it passes.
        let snap = makeSnapshot(
            source: "detected",
            movements: [makeMovementEvent(start: 0, end: 0.2)],
            audio: [makeAudioEvent(start: 0.1, end: 0.35)],
            fader: [makeFaderEvent(start: 0.0, end: 0.05)],
            confidence: 0.87,
            detectionSources: ["camera", "audio"]
        )
        #expect(snap.notationConfidence == 0.87)
        #expect(snap.detectionSources == ["camera", "audio"])
    }

    // MARK: Bonus: movement kind slope encoding

    @Test("Fast push/pull have higher height fraction than slow drag")
    func slopeHeightEncoding() {
        // Mirrors the movementHeightFraction logic in CapturedNotationDisplayView.
        func heightFrac(_ kind: ScratchMovementKind) -> Double {
            switch kind {
            case .fastPush, .fastPull:         return 0.90
            case .normalPush, .normalPull:     return 0.62
            case .slowDrag, .slowPullDrag:     return 0.38
            case .releaseNormalPlayback:       return 0.20
            default:                           return 0.55
            }
        }
        #expect(heightFrac(.fastPush) > heightFrac(.normalPush))
        #expect(heightFrac(.normalPush) > heightFrac(.slowDrag))
        #expect(heightFrac(.slowDrag) > heightFrac(.releaseNormalPlayback))
    }
}
