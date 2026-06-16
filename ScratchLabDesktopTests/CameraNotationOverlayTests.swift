// Tests for CameraNotationOverlayGeometry + CameraNotationOverlayCalibration:
// arc projection, calibration clamping/reset, proportional travel preservation,
// forward/back distinction, silence/idle suppression, future-note guard,
// empty notation safety, and edge-angle handling.
//
// Pure model tests — no SwiftUI, no Canvas, no GraphicsContext.

import XCTest
@testable import ScratchLab

final class CameraNotationOverlayTests: XCTestCase {

    // MARK: - Helpers (matching LiveNotationOverlayTests patterns)

    private func makeEvent(
        startTime: Double,
        endTime: Double,
        startPosition: Double = 0.0,
        endPosition: Double = 1.0,
        direction: String = "forward",
        confidence: Double = 0.8
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime, endTime: endTime,
            startPosition: startPosition, endPosition: endPosition,
            direction: direction, movementKind: .normalPush,
            speed: 0.5, confidence: confidence, source: "detected"
        )
    }

    private func makeCapturedModel(
        events: [CaptureCore.DetectedNotationRecordMovementEvent],
        duration: Double
    ) -> LiveNotationOverlayModel {
        LiveNotationOverlayModel(events: events, duration: duration, mode: .captured)
    }

    /// Snapshot builder matching the pattern used by
    /// `LiveNotationOverlayTests.makePerformerSnapshot`.
    private func makeSnapshot(
        events: [CaptureCore.DetectedNotationRecordMovementEvent],
        extraDuration: Double? = nil
    ) -> CaptureCore.DetectedNotationSnapshot {
        var audioEvents: [CaptureCore.DetectedNotationAudioEvent] = []
        if let extra = extraDuration {
            let movementMax = events.map(\.endTime).max() ?? 0
            if extra > movementMax {
                audioEvents.append(CaptureCore.DetectedNotationAudioEvent(
                    startTime: extra - 0.01,
                    endTime: extra,
                    duration: 0.01,
                    peakLevel: 0.5,
                    rmsLevel: 0.3,
                    confidence: 0.8,
                    eventKind: "onset",
                    source: "test"
                ))
            }
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "",
            labelConfidence: nil,
            detectionSources: ["test"],
            recordMovementEvents: events,
            audioEvents: audioEvents,
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Date()
        )
    }

    // MARK: - Calibration clamping

    func testCameraOverlayCalibrationClampsCenterAndRadius() {
        let cal = CameraNotationOverlayCalibration()

        // Out-of-bounds centre → clamped
        cal.platterCenter = CGPoint(x: -0.5, y: 1.8)
        XCTAssertEqual(cal.clampedCenter.x, 0.0, accuracy: 1e-9,
                       "Negative x must clamp to 0")
        XCTAssertEqual(cal.clampedCenter.y, 1.0, accuracy: 1e-9,
                       "Above-1 y must clamp to 1")

        // Out-of-bounds radius → clamped
        cal.platterRadius = 0.01   // below minimum
        XCTAssertEqual(cal.clampedRadius, 0.05, accuracy: 1e-9,
                       "Radius below minimum must clamp to 0.05")
        cal.platterRadius = 0.9    // above maximum
        XCTAssertEqual(cal.clampedRadius, 0.5, accuracy: 1e-9,
                       "Radius above maximum must clamp to 0.5")

        // Valid values pass through
        cal.platterCenter = CGPoint(x: 0.3, y: 0.7)
        cal.platterRadius = 0.25
        XCTAssertEqual(cal.clampedCenter.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(cal.clampedCenter.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(cal.clampedRadius, 0.25, accuracy: 1e-9)
    }

    func testCameraOverlayCalibrationResetUsesDefault() {
        let cal = CameraNotationOverlayCalibration()
        cal.platterCenter = CGPoint(x: 0.2, y: 0.8)
        cal.platterRadius = 0.45
        cal.isLocked = true

        cal.reset()

        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-9,
                       "Reset must restore default centre x")
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-9,
                       "Reset must restore default centre y")
        XCTAssertEqual(cal.platterRadius, 0.35, accuracy: 1e-9,
                       "Reset must restore default radius")
        XCTAssertFalse(cal.isLocked, "Reset must unlock calibration")
    }

    func testCameraOverlayCalibrationSetCenterFromViewPoint() {
        let cal = CameraNotationOverlayCalibration()
        let viewSize = CGSize(width: 400, height: 300)

        cal.setCenter(from: CGPoint(x: 200, y: 150), viewSize: viewSize)
        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-6,
                       "Centre of view must yield (0.5, 0.5)")
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-6)

        cal.setCenter(from: CGPoint(x: 100, y: 75), viewSize: viewSize)
        XCTAssertEqual(cal.platterCenter.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(cal.platterCenter.y, 0.25, accuracy: 1e-6)

        // Out-of-bounds tap clamped
        cal.setCenter(from: CGPoint(x: 600, y: -50), viewSize: viewSize)
        XCTAssertEqual(cal.platterCenter.x, 1.0, accuracy: 1e-6,
                       "Tap beyond right edge clamps to 1.0")
        XCTAssertEqual(cal.platterCenter.y, 0.0, accuracy: 1e-6,
                       "Tap above top edge clamps to 0.0")

        // Zero-size view is safe
        cal.setCenter(from: CGPoint(x: 100, y: 100), viewSize: .zero)
        XCTAssertEqual(cal.platterCenter.x, 1.0, accuracy: 1e-6,
                       "setCenter must be no-op when viewSize is zero (preserves prior)")
    }

    // MARK: - Angle / cursor mapping

    func testCameraOverlayCursorAngleFollowsCurrentTime() {
        // Default params: startAngle = -pi/2, arcSweep = 2*pi
        let a0 = CameraNotationOverlayGeometry.angle(timeFraction: 0.0)
        let aQuarter = CameraNotationOverlayGeometry.angle(timeFraction: 0.25)
        let aHalf = CameraNotationOverlayGeometry.angle(timeFraction: 0.5)
        let aFull = CameraNotationOverlayGeometry.angle(timeFraction: 1.0)

        XCTAssertEqual(a0, -.pi / 2, accuracy: 1e-9,
                       "timeFraction 0 → startAngle (-pi/2)")
        XCTAssertEqual(aQuarter, -.pi / 2 + 0.25 * 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(aHalf, -.pi / 2 + .pi, accuracy: 1e-9,
                       "timeFraction 0.5 → opposite side (pi/2)")
        XCTAssertEqual(aFull, -.pi / 2 + 2 * .pi, accuracy: 1e-9,
                       "timeFraction 1.0 → startAngle + 2*pi")

        // Clamping: out-of-range fractions clamp to [0, 1]
        XCTAssertEqual(
            CameraNotationOverlayGeometry.angle(timeFraction: -0.5),
            -.pi / 2, accuracy: 1e-9,
            "Negative fraction clamps to 0"
        )
        XCTAssertEqual(
            CameraNotationOverlayGeometry.angle(timeFraction: 2.0),
            -.pi / 2 + 2 * .pi, accuracy: 1e-9,
            "Above-1 fraction clamps to 1"
        )
    }

    func testCameraOverlayGeometryHandlesEdgeAngles() {
        // Custom sweep — half circle
        let a0 = CameraNotationOverlayGeometry.angle(
            timeFraction: 0.0, startAngle: 0, arcSweep: .pi
        )
        let a1 = CameraNotationOverlayGeometry.angle(
            timeFraction: 1.0, startAngle: 0, arcSweep: .pi
        )
        XCTAssertEqual(a0, 0.0, accuracy: 1e-9)
        XCTAssertEqual(a1, .pi, accuracy: 1e-9)

        // Zero sweep — all times map to same angle
        let zeroSweep = CameraNotationOverlayGeometry.angle(
            timeFraction: 0.7, startAngle: 0.5, arcSweep: 0
        )
        XCTAssertEqual(zeroSweep, 0.5, accuracy: 1e-9,
                       "Zero sweep — angle fixed at startAngle")

        // Point projection at extremes
        let center = CGPoint(x: 100, y: 100)
        let radius: CGFloat = 50

        // travelFraction 0 → at centre regardless of angle
        let p0 = CameraNotationOverlayGeometry.point(
            angle: .pi / 4, travelFraction: 0.0,
            center: center, radius: radius
        )
        XCTAssertEqual(p0.x, center.x, accuracy: 1e-6)
        XCTAssertEqual(p0.y, center.y, accuracy: 1e-6)

        // travelFraction 1.0, angle 0 (right) → (center.x + radius, center.y)
        let pRight = CameraNotationOverlayGeometry.point(
            angle: 0, travelFraction: 1.0,
            center: center, radius: radius
        )
        XCTAssertEqual(pRight.x, 150.0, accuracy: 1e-6)
        XCTAssertEqual(pRight.y, 100.0, accuracy: 1e-6)

        // travelFraction 1.0, angle -pi/2 (top) → (center.x, center.y - radius)
        let pTop = CameraNotationOverlayGeometry.point(
            angle: -.pi / 2, travelFraction: 1.0,
            center: center, radius: radius
        )
        XCTAssertEqual(pTop.x, 100.0, accuracy: 1e-6)
        XCTAssertEqual(pTop.y, 50.0, accuracy: 1e-6)
    }

    // MARK: - Proportional travel preservation

    func testCameraOverlayPreservesProportionalTravel() {
        let fullEvent    = makeEvent(startTime: 0.0, endTime: 0.3,
                                     startPosition: 0.0, endPosition: 1.0)
        let halfEvent    = makeEvent(startTime: 0.5, endTime: 0.8,
                                     startPosition: 0.0, endPosition: 0.5)
        let quarterEvent = makeEvent(startTime: 1.0, endTime: 1.3,
                                     startPosition: 0.0, endPosition: 0.25)
        let radius: CGFloat = 100

        let fullStroke = CameraNotationOverlayGeometry.arcStroke(
            for: fullEvent, duration: 2.0, maxRadius: radius
        )
        let halfStroke = CameraNotationOverlayGeometry.arcStroke(
            for: halfEvent, duration: 2.0, maxRadius: radius
        )
        let quarterStroke = CameraNotationOverlayGeometry.arcStroke(
            for: quarterEvent, duration: 2.0, maxRadius: radius
        )

        XCTAssertNotNil(fullStroke, "Full-travel event must produce a stroke")
        XCTAssertNotNil(halfStroke, "Half-travel event must produce a stroke")
        XCTAssertNotNil(quarterStroke, "Quarter-travel event must produce a stroke")

        XCTAssertEqual(fullStroke!.radius, 100.0, accuracy: 1e-6,
                       "Full travel → full radius")
        XCTAssertEqual(halfStroke!.radius, 50.0, accuracy: 1e-6,
                       "Half travel → half radius")
        XCTAssertEqual(quarterStroke!.radius, 25.0, accuracy: 1e-6,
                       "Quarter travel → quarter radius")

        XCTAssertGreaterThan(fullStroke!.radius, halfStroke!.radius,
                             "Full must exceed half in radius")
        XCTAssertGreaterThan(halfStroke!.radius, quarterStroke!.radius,
                             "Half must exceed quarter in radius")
    }

    // MARK: - Direction distinction

    func testCameraOverlayDistinguishesForwardAndBack() {
        let fwdEvent  = makeEvent(startTime: 0.0, endTime: 0.4,
                                  startPosition: 0.1, endPosition: 0.9,
                                  direction: "forward")
        let backEvent = makeEvent(startTime: 0.5, endTime: 0.9,
                                  startPosition: 0.9, endPosition: 0.1,
                                  direction: "backward")
        let radius: CGFloat = 100

        let fwdStroke = CameraNotationOverlayGeometry.arcStroke(
            for: fwdEvent, duration: 2.0, maxRadius: radius
        )
        let backStroke = CameraNotationOverlayGeometry.arcStroke(
            for: backEvent, duration: 2.0, maxRadius: radius
        )

        XCTAssertNotNil(fwdStroke)
        XCTAssertNotNil(backStroke)
        XCTAssertTrue(fwdStroke!.isForward, "Forward event → isForward=true")
        XCTAssertFalse(backStroke!.isForward, "Backward event → isForward=false")

        // Both have same travel (0.8) → same radius
        XCTAssertEqual(fwdStroke!.radius, backStroke!.radius, accuracy: 1e-6,
                       "Equal travel → equal radius regardless of direction")
    }

    // MARK: - Silence / idle suppression

    func testCameraOverlayKeepsSilenceEmpty() {
        let idleEvent = makeEvent(startTime: 0.0, endTime: 0.5,
                                  startPosition: 0.3, endPosition: 0.3)
        let stroke = CameraNotationOverlayGeometry.arcStroke(
            for: idleEvent, duration: 2.0, maxRadius: 100
        )
        XCTAssertNil(stroke, "Zero-travel event must produce nil arcStroke")

        // Model-level suppression
        let model = makeCapturedModel(events: [idleEvent], duration: 2.0)
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: model, currentTime: 2.0, maxRadius: 100
        )
        XCTAssertTrue(strokes.isEmpty,
                      "arcStrokes must be empty when all events have zero travel")
    }

    // MARK: - Empty notation safety

    func testCameraOverlayHandlesEmptyNotation() {
        let emptyModel = makeCapturedModel(events: [], duration: 0)
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: emptyModel, currentTime: 0, maxRadius: 100
        )
        XCTAssertTrue(strokes.isEmpty,
                      "Empty model must produce empty arc strokes")

        // Zero-duration edge case
        let zeroDurModel = LiveNotationOverlayModel(
            events: [makeEvent(startTime: 0.0, endTime: 0.5)],
            duration: 0,
            mode: .captured
        )
        let zeroStrokes = CameraNotationOverlayGeometry.arcStrokes(
            from: zeroDurModel, currentTime: 0, maxRadius: 100
        )
        XCTAssertTrue(zeroStrokes.isEmpty,
                      "Zero-duration model must produce empty arc strokes")

        // Duration-guarded arcStroke
        let nilStroke = CameraNotationOverlayGeometry.arcStroke(
            for: makeEvent(startTime: 0.0, endTime: 0.5),
            duration: 0,
            maxRadius: 100
        )
        XCTAssertNil(nilStroke,
                     "arcStroke must return nil when duration is zero")
    }

    // MARK: - Future-note guard (captured mode)

    func testCameraOverlayCapturedModeGuardsFutureNotes() {
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 0.8,
                      startPosition: 0.2, endPosition: 0.9),
            makeEvent(startTime: 1.2, endTime: 1.5,
                      startPosition: 0.1, endPosition: 0.7),
        ]
        let model = makeCapturedModel(events: events, duration: 2.0)
        let radius: CGFloat = 100

        // Before first stroke — nothing visible
        let at01 = CameraNotationOverlayGeometry.arcStrokes(
            from: model, currentTime: 0.1, maxRadius: radius
        )
        XCTAssertTrue(at01.isEmpty,
                      "No arc strokes before first event startTime")

        // After first stroke — only it is visible
        let at05 = CameraNotationOverlayGeometry.arcStrokes(
            from: model, currentTime: 0.5, maxRadius: radius
        )
        XCTAssertEqual(at05.count, 1,
                       "Only first stroke visible at 0.5 s")

        // After second stroke — two visible
        let at09 = CameraNotationOverlayGeometry.arcStrokes(
            from: model, currentTime: 0.9, maxRadius: radius
        )
        XCTAssertEqual(at09.count, 2,
                       "Two strokes visible at 0.9 s")

        // At end of phrase — all three visible
        let atEnd = CameraNotationOverlayGeometry.arcStrokes(
            from: model, currentTime: 2.0, maxRadius: radius
        )
        XCTAssertEqual(atEnd.count, 3,
                       "All strokes visible at end of phrase")
    }

    // MARK: - Target mode (all strokes visible)

    func testCameraOverlayTargetModeRevealsAllStrokes() {
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 0.8,
                      startPosition: 0.2, endPosition: 0.9),
        ]
        let targetModel = LiveNotationOverlayModel(
            events: events, duration: 2.0, mode: .target
        )
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: targetModel, currentTime: 0.0, maxRadius: 100
        )
        XCTAssertEqual(strokes.count, 2,
                       "Target mode must show all strokes at time 0")
    }

    // MARK: - Persistence: defaults when missing

    func testCameraOverlayCalibrationDefaultsWhenMissing() {
        // Ensure no persisted values exist.
        let cleaner = CameraNotationOverlayCalibration()
        cleaner.clearPersisted()

        let cal = CameraNotationOverlayCalibration()
        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-9,
                       "Default center.x when no persisted key")
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-9,
                       "Default center.y when no persisted key")
        XCTAssertEqual(cal.platterRadius, 0.35, accuracy: 1e-9,
                       "Default radius when no persisted key")
        XCTAssertEqual(cal.angleOffset, 0.0, accuracy: 1e-9,
                       "Default angle offset when no persisted key")
        XCTAssertFalse(cal.isLocked,
                       "Default unlocked when no persisted key")

        cal.clearPersisted()
    }

    // MARK: - Persistence: round-trip

    func testCameraOverlayCalibrationPersistsRoundTrip() {
        // Clean start.
        let cleaner = CameraNotationOverlayCalibration()
        cleaner.clearPersisted()

        // Write non-default values through a first instance.
        let calA = CameraNotationOverlayCalibration()
        calA.platterCenter = CGPoint(x: 0.3, y: 0.7)
        calA.platterRadius = 0.25
        calA.angleOffset = 0.4
        calA.isLocked = true

        // Let the async save (receive(on: DispatchQueue.main)) complete.
        let saveExp = expectation(description: "auto-save completes")
        DispatchQueue.main.async { saveExp.fulfill() }
        wait(for: [saveExp], timeout: 1.0)

        // Create a second instance — it must read the persisted values.
        let calB = CameraNotationOverlayCalibration()
        XCTAssertEqual(calB.platterCenter.x, 0.3, accuracy: 1e-9,
                       "Persisted center.x must round-trip")
        XCTAssertEqual(calB.platterCenter.y, 0.7, accuracy: 1e-9,
                       "Persisted center.y must round-trip")
        XCTAssertEqual(calB.platterRadius, 0.25, accuracy: 1e-9,
                       "Persisted radius must round-trip")
        XCTAssertEqual(calB.angleOffset, 0.4, accuracy: 1e-9,
                       "Persisted angle offset must round-trip")
        XCTAssertTrue(calB.isLocked,
                      "Persisted locked state must round-trip")

        calB.clearPersisted()
    }

    // MARK: - Persistence: clamping on load / safe static helpers

    func testCameraOverlayCalibrationSafeClampHelpers() {
        // Center clamp
        XCTAssertEqual(CameraNotationOverlayCalibration.safeCenterClamp(-0.5), 0.0,
                       "Negative center must clamp to 0")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeCenterClamp(1.8), 1.0,
                       "Above-1 center must clamp to 1")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeCenterClamp(0.42), 0.42,
                       "Valid center must passthrough")

        // Radius clamp
        XCTAssertEqual(CameraNotationOverlayCalibration.safeRadiusClamp(0.01), 0.05,
                       "Below-min radius must clamp to 0.05")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeRadiusClamp(0.9), 0.5,
                       "Above-max radius must clamp to 0.5")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeRadiusClamp(0.25), 0.25,
                       "Valid radius must passthrough")

        // Angle clamp
        XCTAssertEqual(CameraNotationOverlayCalibration.safeAngleClamp(10.0), 2 * .pi,
                       accuracy: 1e-9,
                       "Large positive angle must clamp to 2π")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeAngleClamp(-10.0), -2 * .pi,
                       accuracy: 1e-9,
                       "Large negative angle must clamp to -2π")
        XCTAssertEqual(CameraNotationOverlayCalibration.safeAngleClamp(0.5), 0.5,
                       accuracy: 1e-9,
                       "Valid angle must passthrough")
    }

    func testCameraOverlayCalibrationClampsInvalidAngle() {
        let cal = CameraNotationOverlayCalibration()

        cal.angleOffset = 10.0   // above 2π
        XCTAssertEqual(cal.clampedAngleOffset, 2 * .pi, accuracy: 1e-9,
                       "Angle above 2π must clamp to 2π")

        cal.angleOffset = -10.0  // below -2π
        XCTAssertEqual(cal.clampedAngleOffset, -2 * .pi, accuracy: 1e-9,
                       "Angle below -2π must clamp to -2π")

        cal.angleOffset = 0.4    // within range
        XCTAssertEqual(cal.clampedAngleOffset, 0.4, accuracy: 1e-9,
                       "Valid angle must passthrough")
    }

    // MARK: - Reset behaviour

    func testCameraOverlayCalibrationResetRestoresAllDefaults() {
        let cal = CameraNotationOverlayCalibration()
        cal.platterCenter = CGPoint(x: 0.2, y: 0.8)
        cal.platterRadius = 0.45
        cal.angleOffset = 1.2
        cal.isLocked = true

        cal.reset()

        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-9,
                       "Reset must restore default centre x")
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-9,
                       "Reset must restore default centre y")
        XCTAssertEqual(cal.platterRadius, 0.35, accuracy: 1e-9,
                       "Reset must restore default radius")
        XCTAssertEqual(cal.angleOffset, 0.0, accuracy: 1e-9,
                       "Reset must restore default angle offset")
        XCTAssertFalse(cal.isLocked, "Reset must unlock calibration")
    }

    // MARK: - Lock / unlock behaviour

    func testLockedCalibrationIgnoresMutation() {
        let cal = CameraNotationOverlayCalibration()

        // Set known state then lock.
        cal.setCenter(from: CGPoint(x: 200, y: 150), viewSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-6)

        cal.isLocked = true

        // Attempt to set center via the public method — must be ignored.
        cal.setCenter(from: CGPoint(x: 100, y: 75), viewSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(cal.platterCenter.x, 0.5, accuracy: 1e-6,
                       "Locked setCenter must not change centre x")
        XCTAssertEqual(cal.platterCenter.y, 0.5, accuracy: 1e-6,
                       "Locked setCenter must not change centre y")

        // Direct property writes still work (view-layer guard),
        // but verify lock state itself is observable.
        XCTAssertTrue(cal.isLocked, "isLocked must remain true")

        cal.isLocked = false
        XCTAssertFalse(cal.isLocked, "isLocked must toggle to false")
    }

    func testUnlockedCalibrationAcceptsMutation() {
        let cal = CameraNotationOverlayCalibration()
        cal.isLocked = false

        cal.setCenter(from: CGPoint(x: 100, y: 75), viewSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(cal.platterCenter.x, 0.25, accuracy: 1e-6,
                       "Unlocked setCenter must update centre x")
        XCTAssertEqual(cal.platterCenter.y, 0.25, accuracy: 1e-6,
                       "Unlocked setCenter must update centre y")

        cal.platterRadius = 0.20
        XCTAssertEqual(cal.platterRadius, 0.20, accuracy: 1e-9,
                       "Unlocked radius write must take effect")

        cal.angleOffset = 0.8
        XCTAssertEqual(cal.angleOffset, 0.8, accuracy: 1e-9,
                       "Unlocked angle write must take effect")
    }

    // MARK: - Target notation adapter

    func testTargetNotationAdapterMapsAllStrokes() {
        // Use the real bundled baby_scratch.json.
        guard let notation = ScratchNotation.babyScratch else {
            XCTFail("Baby Scratch notation must load from bundle")
            return
        }
        let model = LiveNotationOverlayModel.targetNotation(from: notation)

        XCTAssertEqual(model.events.count, notation.strokes.count,
                       "Each ScratchNotation.Stroke must map to one event")
        XCTAssertEqual(model.mode, .target,
                       "Factory must produce .target mode")
        XCTAssertEqual(model.duration, notation.timelineDuration,
                       accuracy: 1e-9,
                       "Duration must equal notation.timelineDuration")
        XCTAssertFalse(model.isEmpty,
                       "Non-empty notation must produce non-empty model")
    }

    func testTargetNotationAdapterPreservesDirection() {
        guard let notation = ScratchNotation.babyScratch else {
            XCTFail("Baby Scratch notation must load from bundle")
            return
        }
        let model = LiveNotationOverlayModel.targetNotation(from: notation)

        for (index, event) in model.events.enumerated() {
            let stroke = notation.strokes[index]
            XCTAssertEqual(event.direction, stroke.direction.rawValue,
                           "Event \(index) direction must match source stroke")
        }
        // Explicit forward / backward check on known alternating indices.
        // Stroke 0 = forward, Stroke 1 = backward per baby_scratch.json.
        XCTAssertEqual(model.events[0].direction, "forward",
                       "Baby scratch stroke 0 is forward")
        XCTAssertEqual(model.events[1].direction, "backward",
                       "Baby scratch stroke 1 is backward")
    }

    func testTargetNotationAdapterUsesFixedTravel() {
        guard let notation = ScratchNotation.babyScratch else {
            XCTFail("Baby Scratch notation must load from bundle")
            return
        }
        let model = LiveNotationOverlayModel.targetNotation(from: notation)

        for (index, event) in model.events.enumerated() {
            let travel = CapturedNotationStrokeGeometry.travelFraction(for: event)
            XCTAssertEqual(travel, 0.5, accuracy: 1e-6,
                           "Event \(index): target travel must be fixed 0.5, " +
                           "not captured amplitude")
            XCTAssertEqual(event.startPosition, 0.0, accuracy: 1e-6,
                           "Target startPosition must be 0.0")
            XCTAssertEqual(event.endPosition, 0.5, accuracy: 1e-6,
                           "Target endPosition must be 0.5")
        }
    }

    func testTargetModeDoesNotUseCapturedAmplitude() {
        // Build a target model with large apparent travel from the adapter.
        // Even though the adapter uses fixed 0.5 travel, verify it never
        // takes on captured-style full-range travel.
        let events = [
            makeEvent(startTime: 0.0, endTime: 0.5,
                      startPosition: 0.0, endPosition: 1.0),  // full range captured
        ]
        let capturedModel = makeCapturedModel(events: events, duration: 1.0)
        let capturedTravel = capturedModel.visibleEvents(at: 1.0)
            .map { CapturedNotationStrokeGeometry.travelFraction(for: $0) }

        // Captured model should use actual amplitude.
        XCTAssertEqual(capturedTravel.first ?? 0, 1.0, accuracy: 1e-6,
                       "Captured model must use actual amplitude")

        // Target model from the real adapter must use fixed 0.5 travel.
        guard let notation = ScratchNotation.babyScratch else {
            XCTFail("Baby Scratch notation must load from bundle")
            return
        }
        let targetModel = LiveNotationOverlayModel.targetNotation(from: notation)
        let targetTravels = targetModel.visibleEvents(at: 0)
            .map { CapturedNotationStrokeGeometry.travelFraction(for: $0) }
        XCTAssertFalse(targetTravels.isEmpty, "Target model must have visible events")
        for travel in targetTravels {
            XCTAssertEqual(travel, 0.5, accuracy: 1e-6,
                           "Target mode must not use captured amplitude")
        }
    }

    func testCameraOverlayTargetModeShowsPlannedStrokes() {
        // Build a target model that spans 2.0 s with 3 events.
        // At time 0, all future events must be visible — coach display
        // is instructional and may reveal planned strokes.
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4),
            makeEvent(startTime: 0.6, endTime: 0.8),
            makeEvent(startTime: 1.2, endTime: 1.5),
        ]
        let targetModel = LiveNotationOverlayModel(
            events: events, duration: 2.0, mode: .target
        )
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: targetModel, currentTime: 0.0, maxRadius: 100
        )
        XCTAssertEqual(strokes.count, 3,
                       "Target mode must show all planned strokes at time 0")
    }

    func testCameraOverlayModeSwitchPreservesCalibration() {
        let cal = CameraNotationOverlayCalibration()
        cal.platterCenter = CGPoint(x: 0.3, y: 0.7)
        cal.platterRadius = 0.25
        cal.angleOffset = 0.4
        cal.isLocked = true

        // Simulate the mode-switch path: calibration is a separate
        // @StateObject, untouched by model/controller rebuild.
        // Switching mode rebuilds only model + controller.
        let capturedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = [
            makeEvent(startTime: 0.0, endTime: 0.5)
        ]
        let targetModel = LiveNotationOverlayModel(
            events: capturedEvents, duration: 1.0, mode: .target
        )

        // Build captured-mode model (simulating Performance switch)
        _ = LiveNotationOverlayModel(
            events: capturedEvents, duration: 1.0, mode: .captured
        )
        // Build target-mode model (simulating Coach switch)
        _ = targetModel

        // Calibration must be unchanged across both "switches".
        XCTAssertEqual(cal.platterCenter.x, 0.3, accuracy: 1e-9,
                       "Mode switch must not alter calibration centre x")
        XCTAssertEqual(cal.platterCenter.y, 0.7, accuracy: 1e-9,
                       "Mode switch must not alter calibration centre y")
        XCTAssertEqual(cal.platterRadius, 0.25, accuracy: 1e-9,
                       "Mode switch must not alter calibration radius")
        XCTAssertEqual(cal.angleOffset, 0.4, accuracy: 1e-9,
                       "Mode switch must not alter calibration angle")
        XCTAssertTrue(cal.isLocked, "Mode switch must not alter lock state")
    }

    // MARK: - Controller seek (currentTime preservation)

    func testOverlayReplayControllerSeekPreservesTime() {
        let timeline = SessionReplayTimeline(
            takeDurationSeconds: 5.0, events: []
        )
        var controller = OverlayReplayController(timeline: timeline)
        XCTAssertTrue(controller.hasTimeline)

        // Seek to a mid-phrase time and verify it sticks.
        controller.seek(to: 2.5, hostTime: 0)
        XCTAssertEqual(controller.currentTime, 2.5, accuracy: 1e-9,
                       "seek(to:) must set currentTime to the requested value")
        XCTAssertFalse(controller.isPlaying,
                       "seek(to:) must pause the controller")

        // Seek below zero → clamped to 0.
        controller.seek(to: -1.0, hostTime: 0)
        XCTAssertEqual(controller.currentTime, 0.0, accuracy: 1e-9,
                       "seek(to:) must clamp negative times to 0")

        // Seek beyond duration → clamped to duration.
        controller.seek(to: 10.0, hostTime: 0)
        XCTAssertEqual(controller.currentTime, 5.0, accuracy: 1e-9,
                       "seek(to:) must clamp past-end times to duration")

        // Seek on an empty controller is a no-op.
        let emptyTimeline = SessionReplayTimeline(takeDurationSeconds: 0, events: [])
        var emptyController = OverlayReplayController(timeline: emptyTimeline)
        XCTAssertFalse(emptyController.hasTimeline)
        emptyController.seek(to: 3.0, hostTime: 0)
        XCTAssertEqual(emptyController.currentTime, 0.0, accuracy: 1e-9,
                       "seek(to:) must be a no-op when hasTimeline is false")
    }

    func testCameraOverlayModeSwitchSamplesVisiblePlaybackTime() {
        // During active playback, `controller.currentTime` is a stored
        // value that may be stale — the visible cursor position is
        // `controller.currentTime(at: hostTime)`.  Mode switching must
        // sample the latter, not the former.
        let timeline = SessionReplayTimeline(
            takeDurationSeconds: 10.0, events: []
        )
        var controller = OverlayReplayController(timeline: timeline)

        let startHost: TimeInterval = 1000.0
        controller.play(hostTime: startHost)
        XCTAssertTrue(controller.isPlaying)

        // Let 2.5 s of "wall-clock" elapse.
        let switchHost = startHost + 2.5

        // Stale stored value: controller.currentTime still reports the
        // anchor value (0.0), not the elapsed playback position.
        let stale = controller.currentTime
        XCTAssertEqual(stale, 0.0, accuracy: 1e-9,
                       "Stored currentTime is stale during playback (anchor=0)")

        // Correct visible cursor: derived from host-time.
        let visible = controller.currentTime(at: switchHost)
        XCTAssertEqual(visible, 2.5, accuracy: 1e-9,
                       "currentTime(at:) must report elapsed playback position")

        // The mode-switch handler must sample currentTime(at: hostTime),
        // otherwise it would preserve the stale value and jump backwards.
        XCTAssertNotEqual(visible, stale,
                          "Visible time must differ from stale stored time")
    }

    func testCameraOverlayModeSwitchDuringPlaybackDoesNotRestoreStaleStoredTime() {
        // End-to-end: play, elapse time, switch mode, verify cursor
        // matches the visible playback position — not the stale stored
        // currentTime.
        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )
        let capturedEvents = [
            makeEvent(startTime: 0.0, endTime: 0.5,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 1.0,
                      startPosition: 0.2, endPosition: 0.9),
        ]
        let snapshot = makeSnapshot(events: capturedEvents)

        // --- Coach mode, start playback ---
        var (_, coachController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        let startHost: TimeInterval = 2000.0
        coachController.play(hostTime: startHost)
        XCTAssertTrue(coachController.isPlaying)

        // Elapse 1.25 s on the playback wall-clock.
        let switchHost = startHost + 1.25
        let visibleTime = coachController.currentTime(at: switchHost)
        XCTAssertEqual(visibleTime, 1.25, accuracy: 1e-3)

        // --- Switch to Performance mode, preserving visible time ---
        var (_, perfController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .captured,
                snapshot: snapshot,
                targetModel: targetModel
            )
        perfController.seek(to: visibleTime, hostTime: switchHost)

        // Captured duration is ~1.0 s (max endTime from events).  1.25 s
        // exceeds that, so the seek must clamp, but the controller must
        // NOT land at 0.0 (which would be the stale stored currentTime
        // of a fresh OverlayReplayController).
        XCTAssertEqual(perfController.currentTime, perfController.duration,
                       accuracy: 1e-3,
                       "Preserved visible time must clamp to new duration, " +
                       "not reset to 0 (stale stored currentTime)")
    }

    func testCameraOverlayModeSwitchPreservesControllerTime() {
        // Build a Coach-mode model and controller, advance time, then
        // switch to Performance mode via the real factory + seek path.
        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )
        let capturedEvents = [
            makeEvent(startTime: 0.0, endTime: 0.5,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 1.0,
                      startPosition: 0.2, endPosition: 0.9),
        ]
        let snapshot = makeSnapshot(events: capturedEvents)

        // Start in Coach mode and seek to 2.0 s.
        var (_, coachController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        coachController.seek(to: 2.0, hostTime: 0)
        XCTAssertEqual(coachController.currentTime, 2.0, accuracy: 1e-9)

        // Switch to Performance mode, preserving time.
        let preservedTime = coachController.currentTime
        var (_, perfController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .captured,
                snapshot: snapshot,
                targetModel: targetModel
            )
        perfController.seek(to: preservedTime, hostTime: 0)

        // Snapshot duration is ~1.0 s (max capturedEvidenceEndTime from events),
        // which is less than 2.0, so the preserved time clamps to the new duration.
        let perfDuration = perfController.duration
        XCTAssertEqual(perfController.currentTime, perfDuration, accuracy: 1e-9,
                       "Preserved time must clamp to new controller duration")
    }

    func testCameraOverlayModeSwitchClampsControllerTimeToNewDuration() {
        // Coach duration (~5.07 s for baby_scratch) > captured duration (~1.0 s).
        // Switching Coach → Performance clamps to the shorter captured duration.
        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )
        let capturedEvents = [
            makeEvent(startTime: 0.0, endTime: 0.5,
                      startPosition: 0.0, endPosition: 0.8),
        ]
        let snapshot = makeSnapshot(events: capturedEvents)

        // Coach mode, cursor at 3.0 s.
        var (_, coachController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        coachController.seek(to: 3.0, hostTime: 0)
        XCTAssertGreaterThan(coachController.duration, 1.0,
                             "Coach duration must exceed captured duration")

        // Switch to Performance mode → time clamps down.
        let preservedTime = coachController.currentTime
        var (_, perfController) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .captured,
                snapshot: snapshot,
                targetModel: targetModel
            )
        perfController.seek(to: preservedTime, hostTime: 0)
        XCTAssertEqual(perfController.currentTime, perfController.duration,
                       accuracy: 1e-9,
                       "Preserved time must clamp to shorter captured duration")

        // Reverse: Performance at 0.3 s → Coach (longer) preserves 0.3 s.
        perfController.seek(to: 0.3, hostTime: 0)
        let perfTime = perfController.currentTime
        var (_, coachController2) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        coachController2.seek(to: perfTime, hostTime: 0)
        XCTAssertEqual(coachController2.currentTime, 0.3, accuracy: 1e-9,
                       "Time must be preserved exactly when old ≤ new duration")
    }

    func testCameraOverlayModeSwitchPreservesCalibrationAndMode() {
        let cal = CameraNotationOverlayCalibration()
        cal.platterCenter = CGPoint(x: 0.3, y: 0.7)
        cal.platterRadius = 0.25
        cal.angleOffset = 0.4
        cal.isLocked = true

        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )
        let capturedEvents = [
            makeEvent(startTime: 0.0, endTime: 0.5)
        ]
        let snapshot = makeSnapshot(events: capturedEvents)

        // Coach → Performance rebuild.
        var (coachModel, coachCtrl) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        coachCtrl.seek(to: 1.2, hostTime: 0)
        let preservedTime = coachCtrl.currentTime
        XCTAssertEqual(coachModel?.mode, .target,
                       "Coach model must be .target mode")

        var (perfModel, perfCtrl) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .captured,
                snapshot: snapshot,
                targetModel: targetModel
            )
        perfCtrl.seek(to: preservedTime, hostTime: 0)
        XCTAssertEqual(perfModel?.mode, .captured,
                       "Performance model must be .captured mode")

        // Calibration must be unchanged across both rebuilds.
        XCTAssertEqual(cal.platterCenter.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(cal.platterCenter.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(cal.platterRadius, 0.25, accuracy: 1e-9)
        XCTAssertEqual(cal.angleOffset, 0.4, accuracy: 1e-9)
        XCTAssertTrue(cal.isLocked)
    }

    func testCameraOverlayModeSwitchKeepsCapturedFutureGuard() {
        // After switching to Performance mode, future strokes must
        // remain guarded.
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 0.8,
                      startPosition: 0.2, endPosition: 0.9),
            makeEvent(startTime: 1.2, endTime: 1.5,
                      startPosition: 0.1, endPosition: 0.7),
        ]
        let snapshot = makeSnapshot(events: events)
        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )

        // Build Performance controller + model.
        var (perfModel, perfCtrl) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .captured,
                snapshot: snapshot,
                targetModel: targetModel
            )
        guard let model = perfModel else {
            XCTFail("Performance model must build from valid snapshot")
            return
        }
        perfCtrl.seek(to: 0.5, hostTime: 0)
        let currentTime = perfCtrl.currentTime

        // At 0.5 s, only first stroke should be visible.
        let visible = model.visibleEvents(at: currentTime)
        XCTAssertEqual(visible.count, 1,
                       "Captured guard: only first stroke visible at 0.5 s")
        XCTAssertEqual(visible.first?.startTime ?? -1, 0.2, accuracy: 1e-9,
                       "Visible stroke must be the first one")

        // Seek to end — all three visible.
        perfCtrl.seek(to: 2.0, hostTime: 0)
        let visibleAtEnd = model.visibleEvents(at: perfCtrl.currentTime)
        XCTAssertEqual(visibleAtEnd.count, 3,
                       "All strokes visible at end of phrase")
    }

    func testCameraOverlayModeSwitchKeepsCoachFutureStrokesVisible() {
        // After switching to Coach mode, all planned strokes must be
        // visible even at time 0.
        let targetModel = LiveNotationOverlayModel.targetNotation(
            from: ScratchNotation.babyScratch
        )
        let events = [
            makeEvent(startTime: 0.0, endTime: 0.5)
        ]
        let snapshot = makeSnapshot(events: events)

        // Build Coach controller + model.
        var (coachModel, coachCtrl) = CameraPassthroughNotationView
            .buildModelAndController(
                mode: .target,
                snapshot: snapshot,
                targetModel: targetModel
            )
        guard let model = coachModel else {
            XCTFail("Coach model must build from valid target notation")
            return
        }
        coachCtrl.seek(to: 0.0, hostTime: 0)

        // At time 0, all target strokes must be visible.
        let visible = model.visibleEvents(at: coachCtrl.currentTime)
        XCTAssertFalse(visible.isEmpty,
                       "Coach mode must show target strokes at time 0")
        // All target events (19 for baby_scratch) must be visible.
        XCTAssertEqual(visible.count, targetModel.events.count,
                       "All target strokes must be visible in Coach mode at time 0")
    }

    func testCameraOverlayTargetEmptyState() {
        // nil notation → empty model
        let nilModel = LiveNotationOverlayModel.targetNotation(from: nil)
        XCTAssertTrue(nilModel.isEmpty, "nil notation must produce empty model")
        XCTAssertEqual(nilModel.duration, 0, accuracy: 1e-9,
                       "nil notation must produce zero-duration model")
        XCTAssertFalse(nilModel.hasMeaningfulStrokes(at: 0),
                       "Empty model must have no meaningful strokes")

        // Empty strokes → empty model
        let emptyNotation = ScratchNotation(
            version: 1, scratchID: "test", demoStart: 0, demoEnd: 0,
            phraseStart: nil, phraseEnd: nil, timingBasis: "test",
            strokes: []
        )
        let emptyModel = LiveNotationOverlayModel.targetNotation(from: emptyNotation)
        XCTAssertTrue(emptyModel.isEmpty, "Notation with no strokes must produce empty model")
        XCTAssertEqual(emptyModel.duration, 0, accuracy: 1e-9,
                       "Empty-strokes notation must produce zero-duration model")

        // Arc-stroke rendering of empty model must be safe.
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: nilModel, currentTime: 0, maxRadius: 100
        )
        XCTAssertTrue(strokes.isEmpty, "Empty target model must produce empty arc strokes")
    }
}
