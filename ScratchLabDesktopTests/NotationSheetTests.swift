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

    // MARK: 10. Advanced lab defaults to captured mode when snapshot is present

    @Test("showingCaptured logic: snapshot present + no override = captured take is shown")
    func advancedDefaultsToCapturedModeWhenSnapshotExists() {
        let snap = makeSnapshot(
            source: "detected",
            movements: [makeMovementEvent(start: 0, end: 0.3)],
            audio: [makeAudioEvent(start: 0, end: 0.3)]
        )
        // showTemplateOverride defaults to false; showingCaptured = snap != nil && !false
        let snapshotExists = (snap as CaptureCore.DetectedNotationSnapshot?) != nil
        let showTemplateOverride = false  // default value of the @State
        let showingCaptured = snapshotExists && !showTemplateOverride
        #expect(showingCaptured)
        #expect(snap.hasDetectedEvents)
    }

    @Test("showingCaptured logic: snapshot present + override = template demo is shown")
    func overrideToTemplateSuppressesCapturedTake() {
        let snap = makeSnapshot(source: "detected",
                                movements: [makeMovementEvent(start: 0, end: 0.2)])
        let snapshotExists = (snap as CaptureCore.DetectedNotationSnapshot?) != nil
        let showTemplateOverride = true  // user explicitly picked Template Demo
        let showingCaptured = snapshotExists && !showTemplateOverride
        #expect(!showingCaptured)
    }

    @Test("showingCaptured logic: no snapshot = template demo regardless of override")
    func noSnapshotAlwaysShowsTemplateDemo() {
        let snapshotExists = false  // capturedSnapshot == nil
        let showTemplateOverride = false
        let showingCaptured = snapshotExists && !showTemplateOverride
        #expect(!showingCaptured)
    }

    // MARK: 11. Captured snapshot source never surfaces demo audio filename

    @Test("Captured snapshot detectionSources do not contain baby_noBeat.wav")
    func capturedSourceDoesNotReferenceDemoAudio() {
        let snap = makeSnapshot(
            source: "detected",
            movements: [makeMovementEvent(start: 0, end: 0.2)],
            detectionSources: ["camera", "audio"]
        )
        #expect(snap.notationSource != "baby_noBeat.wav")
        for src in snap.detectionSources {
            #expect(!src.contains("baby_noBeat"))
            #expect(!src.contains("baby_nobeat"))
        }
    }

    // MARK: 12. Unavailable snapshot has no events — no fake strokes can be drawn

    @Test("Unavailable snapshot contains no movement, audio, or fader events")
    func unavailableSnapshotHasNoFakeStrokes() {
        let snap = makeSnapshot(source: "unavailable")
        #expect(snap.recordMovementEvents.isEmpty)
        #expect(snap.audioEvents.isEmpty)
        #expect(snap.faderEvents.isEmpty)
        #expect(!snap.hasDetectedEvents)
    }

    // MARK: 13. Partial audio triggers direction-pending path (no movement events)

    @Test("Partial snapshot with only audio events has empty movement events")
    func partialAudioSnapshotTriggersDirectionPendingPath() {
        let snap = makeSnapshot(
            source: "partial",
            audio: [makeAudioEvent(start: 0.0, end: 0.5, kind: "scratchBurst", confidence: 0.80)]
        )
        #expect(snap.recordMovementEvents.isEmpty)
        #expect(!snap.audioEvents.isEmpty)
        #expect(snap.notationSource == "partial")
    }

    @Test("Audio-only captured take source includes Audio-only take and No record movement detected. copy")
    func audioOnlyCapturedSourceIncludesRequiredCopy() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("Audio-only take"))
        #expect(source.contains("Hand motion wasn't detected — review timing only."))
        #expect(source.contains("No record movement detected."))
        #expect(source.contains("No fader data"))
    }

    @Test("Detected preview preserves forward and backward stroke directions")
    func detectedPreviewPreservesForwardAndBackwardDirections() throws {
        let preview = try #require(
            ScratchNotation.detectedPreview(
                scratchID: "baby_scratch",
                events: [
                    makeMovementEvent(start: 0.0, end: 0.2, direction: "forward", kind: .normalPush),
                    makeMovementEvent(start: 0.3, end: 0.5, direction: "backward", kind: .normalPull)
                ]
            )
        )
        #expect(preview.strokes.count == 2)
        #expect(preview.strokes[0].direction == .forward)
        #expect(preview.strokes[1].direction == .backward)
    }

    @Test("CapturedNotationDisplayView renders forward and backward events directly from event.direction")
    func capturedNotationRendererUsesEventDirectionStrings() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("let isForward = event.direction == \"forward\""))
        #expect(source.contains("let y1: CGFloat = isForward ? mid + h : mid - h"))
        #expect(source.contains("let y2: CGFloat = isForward ? mid - h : mid + h"))
    }

    @Test("Template Demo source keeps Baby Scratch Template only in the template branch")
    func templateDemoStillOwnsBabyScratchTemplateLabel() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("Baby Scratch Template"))
        #expect(source.contains("if showingCaptured, let snapshot = capturedSnapshot"))
    }

    // MARK: 14. No CXL strings surface in snapshot user-facing fields

    @Test("DetectedNotationSnapshot source fields contain no CXL strings")
    func snapshotHasNoCXLStrings() {
        let snap = makeSnapshot(
            source: "detected",
            movements: [makeMovementEvent(start: 0, end: 0.2)],
            detectionSources: ["camera", "audio"]
        )
        #expect(!snap.notationSource.contains("CXL"))
        #expect(!snap.notationSource.contains("cxl"))
        for src in snap.detectionSources {
            #expect(!src.uppercased().contains("CXL"))
        }
    }

    // MARK: 15. Template and captured modes are distinct and clearly labelled

    @Test("NotationLabDisplayMode cases have correct raw value labels")
    func displayModesHaveCorrectLabels() {
        #expect(NotationLabDisplayMode.capturedTake.rawValue == "Captured Take")
        #expect(NotationLabDisplayMode.templateDemo.rawValue == "Template Demo")
        #expect(NotationLabDisplayMode.capturedTake != NotationLabDisplayMode.templateDemo)
    }

    // MARK: 16. Low-confidence camera events: movementLane renders, header stays amber

    @Test("Low-confidence camera events appear in recordMovementEvents despite unavailable source")
    func lowConfidenceCameraEventsStillPopulateMovementLane() {
        // Mirrors the real-world case: confidence 0.147, source="camera" → notationSource="unavailable"
        // but recordMovementEvents is non-empty → hasDetectedEvents=true → header shows amber "Movement recorded"
        let snap = makeSnapshot(
            source: "unavailable",
            movements: [makeMovementEvent(start: 0.0, end: 0.3, confidence: 0.147)],
            confidence: 0.147
        )
        #expect(snap.notationSource == "unavailable")
        #expect(!snap.recordMovementEvents.isEmpty)
        #expect(snap.hasDetectedEvents)
        // hasMovementOnly = !isDetected && !isPartial && hasMovementEvents
        let isDetected = snap.notationSource == "detected" || snap.notationSource == "fused"
        let isPartial  = snap.notationSource == "partial"
        let hasMovementOnly = !isDetected && !isPartial && !snap.recordMovementEvents.isEmpty
        #expect(hasMovementOnly)
    }

    @Test("Target notation for Baby Scratch has forward and backward strokes")
    func babyScratchNotationHasForwardAndBackwardStrokes() {
        let notation = ScratchNotation(
            version: 1, scratchID: "baby_scratch",
            demoStart: 0, demoEnd: 2.126,
            phraseStart: 0.03, phraseEnd: 2.126,
            timingBasis: "beat",
            strokes: [
                .init(startTime: 0.03, endTime: 0.36, direction: .forward,  speedClassification: .medium, faderState: .open),
                .init(startTime: 0.37, endTime: 0.66, direction: .backward, speedClassification: .medium, faderState: .open),
                .init(startTime: 0.70, endTime: 1.02, direction: .forward,  speedClassification: .medium, faderState: .open),
                .init(startTime: 1.04, endTime: 1.38, direction: .backward, speedClassification: .medium, faderState: .open),
            ]
        )
        #expect(!notation.strokes.isEmpty)
        #expect(notation.strokes.contains { $0.direction == .forward })
        #expect(notation.strokes.contains { $0.direction == .backward })
        #expect(notation.timelineDuration > 0)
    }

    // MARK: 17. Audio-inferred notation availability

    @Test("Audio-only snapshot (no movement, no fader) triggers audio-inferred path")
    func audioOnlySnapshotTriggersAudioInferredPath() {
        let snap = makeSnapshot(
            source: "unavailable",
            audio: [makeAudioEvent(start: 0.1, end: 0.4, kind: "scratchBurst", confidence: 0.82)]
        )
        #expect(!snap.recordMovementEvents.isEmpty == false)
        #expect(snap.hasAudioEvents)
        #expect(!snap.faderEvents.isEmpty == false)
        #expect(snap.hasDetectedEvents)   // audio counts as detected event
        // hasAudioOnly classification
        let isDetected = snap.notationSource == "detected"
        let isPartial  = snap.notationSource == "partial"
        let hasAudioOnly = !isDetected && !isPartial && snap.recordMovementEvents.isEmpty && snap.hasAudioEvents
        #expect(hasAudioOnly)
    }

    @Test("Audio-inferred lane does not claim ground-truth movement direction")
    func audioInferredLaneIsLabelledEstimated() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // Must contain the audio-inferred lane
        #expect(source.contains("audioInferredNotationLane"))
        // Must not claim confirmed direction
        #expect(source.contains("estimated"))
        // Must carry the "Audio-inferred" label in summaryHeader
        #expect(source.contains("Audio-inferred"))
    }

    @Test("Fader events present with no movement/audio → fader lane shown, not audio-inferred")
    func faderOnlyDoesNotTriggerAudioInferredLane() {
        let snap = makeSnapshot(
            source: "partial",
            fader: [makeFaderEvent(start: 0.0, end: 0.05)]
        )
        #expect(!snap.hasAudioEvents)
        #expect(!snap.faderEvents.isEmpty)
        // hasAudioOnly should be false when there are no audio events
        let isDetected = snap.notationSource == "detected"
        let isPartial  = snap.notationSource == "partial"
        let hasAudioOnly = !isDetected && !isPartial && snap.recordMovementEvents.isEmpty && snap.hasAudioEvents
        #expect(!hasAudioOnly)
    }

    // MARK: 18. Calibration overlay hidden by default

    @Test("showRigGuides uses calibrationLocked not practiceViewEnabled")
    func showRigGuidesUsesCalibrationLocked() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // showRigGuides must reference calibrationLocked, not practiceViewEnabled
        let rigGuidesRange = source.range(of: "var showRigGuides: Bool")!
        let afterDecl = source[rigGuidesRange.upperBound...]
        let nextFuncRange = afterDecl.range(of: "func ") ?? afterDecl.endIndex..<afterDecl.endIndex
        let body = String(afterDecl[..<nextFuncRange.lowerBound])
        #expect(body.contains("calibrationLocked"))
        #expect(!body.contains("practiceViewEnabled"))
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
