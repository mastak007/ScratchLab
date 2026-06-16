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
}
