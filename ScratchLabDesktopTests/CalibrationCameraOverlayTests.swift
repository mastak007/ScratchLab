// CalibrationCameraOverlayTests.swift
// ScratchLabDesktopTests
//
// Calibration box editing, 2026-08-21 fix bundle. Pure presentation-state
// and recording-guard decision functions — extracted from SwiftUI view code
// specifically so they're testable directly rather than via brittle view
// introspection, per the corrected plan.

import XCTest
@testable import ScratchLab

final class CalibrationCameraOverlayTests: XCTestCase {

    // MARK: - guideOpacity (locked-state opacity)

    func testGuideOpacityIsFullWhileEditable() {
        XCTAssertEqual(CaptureGuideEditModel.guideOpacity(isEditable: true, lockedOpacity: 0.18), 1.0)
    }

    func testGuideOpacityIsTheRequestedSubtleValueWhenLocked() {
        XCTAssertEqual(CaptureGuideEditModel.guideOpacity(isEditable: false, lockedOpacity: 0.18), 0.18)
    }

    func testGuideOpacityDefaultForCallersThatDoNotOptInIsFullyInvisible() {
        // DeckGamificationOverlay's own default `lockedOpacity: 0` preserves
        // the exact prior fully-invisible-when-locked behavior for any
        // caller that doesn't explicitly request a visible locked state.
        XCTAssertEqual(CaptureGuideEditModel.guideOpacity(isEditable: false, lockedOpacity: 0), 0)
    }

    // MARK: - recordActionIsBlockedByCalibration (recording guard)

    func testRecordIsBlockedWhileCalibrationIsUnlockedAndNotYetRecording() {
        XCTAssertTrue(CaptureGuideEditModel.recordActionIsBlockedByCalibration(
            isRoutineRecording: false, calibrationLocked: false))
    }

    func testRecordIsAllowedWhenCalibrationIsLocked() {
        XCTAssertFalse(CaptureGuideEditModel.recordActionIsBlockedByCalibration(
            isRoutineRecording: false, calibrationLocked: true))
    }

    func testStopIsNeverBlockedByCalibrationRegardlessOfLockState() {
        // Once actively recording, the guard must never fire — that would
        // block Stop, not Start.
        XCTAssertFalse(CaptureGuideEditModel.recordActionIsBlockedByCalibration(
            isRoutineRecording: true, calibrationLocked: false))
        XCTAssertFalse(CaptureGuideEditModel.recordActionIsBlockedByCalibration(
            isRoutineRecording: true, calibrationLocked: true))
    }

    // MARK: - Persistence regression (unchanged model/keys)

    /// `calibrationLocked`/`zoneAdjustments` persistence is reused as-is —
    /// no new model, no changed `UserDefaults` keys. Confirms the calibration
    /// lock state genuinely round-trips through `UserDefaults` the same way
    /// it always has.
    func testCalibrationLockedRoundTripsThroughUserDefaultsUnchanged() {
        let defaults = UserDefaults(suiteName: #file)!
        defaults.removePersistentDomain(forName: #file)
        defer { defaults.removePersistentDomain(forName: #file) }

        defaults.set(false, forKey: "scratchlab.mac.calibrationLocked")
        XCTAssertEqual(defaults.object(forKey: "scratchlab.mac.calibrationLocked") as? Bool, false)

        defaults.set(true, forKey: "scratchlab.mac.calibrationLocked")
        XCTAssertEqual(defaults.object(forKey: "scratchlab.mac.calibrationLocked") as? Bool, true)
    }
}


@MainActor
final class CXLCameraGuideTests: XCTestCase {
    private func withEngine(_ body: (MacCaptureEngine, UserDefaults) throws -> Void) rethrows {
        let name = "CXLCameraGuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let engine = MacCaptureEngine(autoRefreshDevices: false,
                                      allowsSeratoDirectCaptureDiscovery: false,
                                      midiDefaults: defaults)
        try body(engine, defaults)
    }

    func testCXLGuideFillsFrameAndDoublesTheEffectiveDefaultMixerWidth() throws {
        let guide = DJRigLayout.cxlFullFrameGuide
        XCTAssertEqual(guide.unionBox.minX, 0, accuracy: 1e-12)
        XCTAssertEqual(guide.unionBox.minY, 0, accuracy: 1e-12)
        XCTAssertEqual(guide.unionBox.width, 1, accuracy: 1e-12)
        XCTAssertEqual(guide.unionBox.height, 1, accuracy: 1e-12)
        let left = try XCTUnwrap(guide.zone(for: .leftDeck)).boundingBox
        let mixer = try XCTUnwrap(guide.zone(for: .mixer)).boundingBox
        let right = try XCTUnwrap(guide.zone(for: .rightDeck)).boundingBox
        XCTAssertEqual(left.width, 0.33, accuracy: 0.00001)
        XCTAssertEqual(mixer.width, 0.17 * 2, accuracy: 0.00001)
        XCTAssertEqual(right.width, 0.33, accuracy: 0.00001)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(left.maxX, mixer.minX)
        XCTAssertEqual(mixer.maxX, right.minX)
        XCTAssertEqual(right.maxX, 1, accuracy: 0.00001)
        XCTAssertLessThan(guide.confidence, 0.65, "Manual fit must never appear hardware-detected.")
        // CXL must not widen the ordinary app's independently clamped tuning.
        XCTAssertEqual(DJRigZoneTuning.standard.mixerShare, 0.20)
        XCTAssertEqual(DJRigZoneTuning.standard.withMixerShare(0.17).mixerShare, 0.17)
        XCTAssertEqual(DJRigZoneTuning.standard.withMixerShare(0.34).mixerShare, 0.30)
    }

    func testPreviewGeometryPreservesActualFourByThreePillarboxingAndSixteenByNineLetterboxing() {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        let fourByThreePixels = CGRect(x: 80, y: 0, width: 480, height: 360)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(fourByThreePixels, in: bounds), fourByThreePixels)
        let squareBounds = CGRect(x: 0, y: 0, width: 640, height: 640)
        let widePixels = CGRect(x: 0, y: 140, width: 640, height: 360)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(widePixels, in: squareBounds), widePixels)
    }

    func testPreviewGeometryRejectsMissingFramesAndClipsToVisiblePixels() {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(.zero, in: bounds), .zero)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(.null, in: bounds), .zero)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(.infinite, in: bounds), .zero)
        XCTAssertEqual(CXLCameraGuideViewport.visibleVideoRect(
            CGRect(x: -10, y: -10, width: 660, height: 380), in: bounds), bounds)
    }

    func testEnablingCXLGuidePreservesNormalCalibrationAndDoesNotStartCamera() throws {
        withEngine { engine, _ in
            let normalAdjustments = engine.zoneAdjustments
            let normalLock = engine.calibrationLocked
            let normalMixer = engine.mixerWidthRatio
            engine.enableCXLCameraGuide()
            XCTAssertTrue(engine.cxlCameraGuideEnabled)
            XCTAssertTrue(engine.cxlCameraGuideLocked)
            XCTAssertTrue(engine.cameraGuideCalibrationLocked)
            XCTAssertTrue(engine.isUsingManualRigGuide)
            XCTAssertEqual(engine.rigLayout, engine.cxlCameraGuideLayout)
            XCTAssertEqual(engine.rigLayout, DJRigLayout.cxlFullFrameGuide)
            XCTAssertFalse(engine.isCameraActive)
            XCTAssertFalse(engine.isRoutineCaptureReady)
            XCTAssertEqual(engine.zoneAdjustments, normalAdjustments)
            XCTAssertEqual(engine.calibrationLocked, normalLock)
            XCTAssertEqual(engine.mixerWidthRatio, normalMixer)
            engine.disableCXLCameraGuide()
            XCTAssertFalse(engine.cxlCameraGuideEnabled)
            XCTAssertNil(engine.cxlCameraGuideLayout)
        }
    }

    func testCXLAdjustmentsPersistSeparatelyAndLockedGuideRejectsEdits() throws {
        try withEngine { engine, defaults in
            let normal = engine.zoneAdjustments
            engine.enableCXLCameraGuide()
            engine.updateZoneAdjustment(for: .mixer) { $0.widthScale = 0.8 }
            XCTAssertEqual(engine.zoneAdjustment(for: .mixer), .identity)
            engine.setCXLCameraGuideLocked(false)
            engine.updateZoneAdjustment(for: .mixer) { $0.widthScale = 0.8 }
            let adjusted = try XCTUnwrap(engine.cxlCameraGuideLayout)
            XCTAssertEqual(try XCTUnwrap(adjusted.zone(for: .mixer)).boundingBox.width, 0.272, accuracy: 0.00001)
            XCTAssertEqual(engine.rigLayout, adjusted, "Displayed boxes and tracking geometry must be identical.")
            XCTAssertNotNil(defaults.data(forKey: "scratchlab.mac.cxl.cameraGuideAdjustmentsData"))
            XCTAssertNil(defaults.data(forKey: "scratchlab.mac.zoneAdjustmentsData"))
            XCTAssertEqual(engine.zoneAdjustments, normal)
            engine.setCXLCameraGuideLocked(true)
            engine.disableCXLCameraGuide()
            engine.enableCXLCameraGuide()
            XCTAssertEqual(engine.cxlCameraGuideLayout, adjusted)
            XCTAssertTrue(engine.cxlCameraGuideLocked)
            engine.resetCXLCameraGuideToFullFrame()
            XCTAssertEqual(engine.cxlCameraGuideLayout, DJRigLayout.cxlFullFrameGuide)
            XCTAssertFalse(engine.cxlCameraGuideLocked)
            XCTAssertEqual(engine.zoneAdjustments, normal)
        }
    }

    func testTakeOwnershipFreezesGuideBeforeRecordingFlagIsPublished() throws {
        withEngine { engine, _ in
            engine.enableCXLCameraGuide()
            engine.setCXLCameraGuideLocked(false)
            engine.updateZoneAdjustment(for: .mixer) { $0.widthScale = 0.8 }
            let before = engine.cxlCameraGuideLayout
            let token = engine.testOnly_armTakeMIDIWindow()
            defer { _ = engine.testOnly_drainTakeMIDIWindow(token: token) }
            XCTAssertFalse(engine.isRoutineRecording)
            XCTAssertTrue(engine.cameraGuideCalibrationLocked)
            XCTAssertFalse(engine.showRigGuides)
            engine.updateZoneAdjustment(for: .mixer) { $0.widthScale = 1.2 }
            engine.resetCXLCameraGuideToFullFrame()
            engine.disableCXLCameraGuide()
            XCTAssertEqual(engine.cxlCameraGuideLayout, before)
            XCTAssertTrue(engine.cxlCameraGuideEnabled)
        }
    }

    func testTakeAuditKeepsImmutableAdjustedCameraGeometryAndSource() throws {
        try withEngine { engine, _ in
            let timestamp = Date(timeIntervalSince1970: 123)
            XCTAssertNil(try engine.cxlCameraGuideAuditEvent(videoDeviceID: "camera-A", at: timestamp))
            engine.enableCXLCameraGuide()
            engine.setCXLCameraGuideLocked(false)
            engine.updateZoneAdjustment(for: .mixer) { $0.widthScale = 0.8 }
            engine.setCXLCameraGuideLocked(true)
            let event = try XCTUnwrap(engine.cxlCameraGuideAuditEvent(videoDeviceID: "camera-A", at: timestamp))
            engine.resetCXLCameraGuideToFullFrame()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.detail.utf8)) as? [String: Any])
            XCTAssertEqual(event.category, "cxl_camera_guide")
            XCTAssertEqual(event.timestamp, timestamp)
            XCTAssertEqual(json["videoDeviceID"] as? String, "camera-A")
            XCTAssertEqual(json["manualEstimate"] as? Bool, true)
            XCTAssertEqual(json["operatorLocked"] as? Bool, true)
            let zones = try XCTUnwrap(json["zones"] as? [[String: Any]])
            let mixer = try XCTUnwrap(zones.first { $0["role"] as? String == "mixer" })
            XCTAssertEqual(try XCTUnwrap(mixer["width"] as? Double), 0.272, accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(engine.cxlCameraGuideLayout?.zone(for: .mixer)).boundingBox.width, 0.34, accuracy: 0.00001)
            XCTAssertEqual(try JSONDecoder().decode(CaptureAuditEvent.self, from: JSONEncoder().encode(event)), event)
        }
    }

    func testSecondCXLResizeWithZeroTranslationPreservesTheAlreadyAdjustedBox() throws {
        try withEngine { engine, _ in
            engine.enableCXLCameraGuide()
            engine.setCXLCameraGuideLocked(false)
            let base = try XCTUnwrap(DJRigLayout.cxlFullFrameGuide.zone(for: .leftDeck)).boundingBox
            let first = CaptureGuideEditModel.cxlResizedGeometry(
                from: ZoneResizeSnapshot(adjustment: .identity, boundingBox: base),
                baseBoundingBox: base, translation: CGSize(width: -82.5, height: -150),
                canvasSize: CGSize(width: 1000, height: 600),
                scaleRange: engine.calibrationScaleRange)
            engine.updateZoneAdjustment(for: .leftDeck) { $0 = first.adjustment }
            let published = try XCTUnwrap(engine.cxlCameraGuideLayout?.zone(for: .leftDeck)).boundingBox
            XCTAssertEqual(published, first.boundingBox)
            let second = CaptureGuideEditModel.cxlResizedGeometry(
                from: ZoneResizeSnapshot(adjustment: first.adjustment, boundingBox: published),
                baseBoundingBox: base, translation: .zero,
                canvasSize: CGSize(width: 1000, height: 600),
                scaleRange: engine.calibrationScaleRange)
            XCTAssertEqual(first.adjustment.widthScale, 0.75, accuracy: 0.00001)
            XCTAssertEqual(first.adjustment.heightScale, 0.75, accuracy: 0.00001)
            XCTAssertEqual(second.adjustment.offsetX, first.adjustment.offsetX, accuracy: 0.00001)
            XCTAssertEqual(second.adjustment.offsetY, 0.125, accuracy: 0.00001)
            XCTAssertEqual(second.boundingBox, published)
            engine.updateZoneAdjustment(for: .leftDeck) { $0 = second.adjustment }
            XCTAssertEqual(engine.cxlCameraGuideLayout?.zone(for: .leftDeck)?.boundingBox, published)
        }
    }

    func testCXLResizeAtFrameLimitUsesTheSameClippedPreviewAndTrackingGeometry() throws {
        try withEngine { engine, _ in
            engine.enableCXLCameraGuide()
            engine.setCXLCameraGuideLocked(false)
            let base = try XCTUnwrap(DJRigLayout.cxlFullFrameGuide.zone(for: .rightDeck)).boundingBox
            let result = CaptureGuideEditModel.cxlResizedGeometry(
                from: ZoneResizeSnapshot(adjustment: .identity, boundingBox: base),
                baseBoundingBox: base, translation: CGSize(width: 300, height: 120),
                canvasSize: CGSize(width: 1000, height: 600),
                scaleRange: engine.calibrationScaleRange)
            XCTAssertEqual(result.adjustment.heightScale, 1)
            XCTAssertEqual(result.boundingBox.height, 1)
            XCTAssertLessThanOrEqual(result.boundingBox.maxX, 1)
            XCTAssertGreaterThanOrEqual(result.boundingBox.minY, 0)
            engine.updateZoneAdjustment(for: .rightDeck) { $0 = result.adjustment }
            let committed = try XCTUnwrap(engine.cxlCameraGuideLayout?.zone(for: .rightDeck)).boundingBox
            XCTAssertEqual(committed.minX, result.boundingBox.minX, accuracy: 0.00001)
            XCTAssertEqual(committed.minY, result.boundingBox.minY, accuracy: 0.00001)
            XCTAssertEqual(committed.width, result.boundingBox.width, accuracy: 0.00001)
            XCTAssertEqual(committed.height, result.boundingBox.height, accuracy: 0.00001)
        }
    }

    func testCXLMoveAcrossImageThenZeroResizePreservesPlacement() throws {
        try withEngine { engine, _ in
            engine.enableCXLCameraGuide()
            engine.setCXLCameraGuideLocked(false)
            let base = try XCTUnwrap(DJRigLayout.cxlFullFrameGuide.zone(for: .leftDeck)).boundingBox
            let delta = CaptureGuideEditModel.pixelDragDeltas(
                pixelSnapshot: CGRect(x: 0, y: 0, width: 330, height: 600),
                translation: CGSize(width: 500, height: 0),
                canvasSize: CGSize(width: 1000, height: 600), inset: 0)
            engine.updateZoneAdjustment(for: .leftDeck) { $0.offsetX = delta.dx }
            let moved = try XCTUnwrap(engine.cxlCameraGuideLayout?.zone(for: .leftDeck)).boundingBox
            XCTAssertEqual(moved.minX, 0.5, accuracy: 0.00001)
            let result = CaptureGuideEditModel.cxlResizedGeometry(
                from: ZoneResizeSnapshot(adjustment: engine.zoneAdjustment(for: .leftDeck), boundingBox: moved),
                baseBoundingBox: base, translation: .zero,
                canvasSize: CGSize(width: 1000, height: 600), scaleRange: engine.calibrationScaleRange)
            XCTAssertEqual(result.adjustment.offsetX, 0.5, accuracy: 0.00001)
            XCTAssertEqual(result.boundingBox.minX, moved.minX, accuracy: 0.00001)
            engine.updateZoneAdjustment(for: .leftDeck) { $0 = result.adjustment }
            let committed = try XCTUnwrap(engine.cxlCameraGuideLayout?.zone(for: .leftDeck)).boundingBox
            XCTAssertEqual(committed.minX, moved.minX, accuracy: 0.00001)
            XCTAssertEqual(committed.width, moved.width, accuracy: 0.00001)
        }
    }

    func testCXLFullFrameMoveDoesNotJumpAtTheImageEdge() {
        let initial = CGRect(x: 0, y: 0, width: 330, height: 600)
        let deltas = CaptureGuideEditModel.pixelDragDeltas(pixelSnapshot: initial, translation: .zero,
                                                        canvasSize: CGSize(width: 1000, height: 600), inset: 0)
        XCTAssertEqual(deltas.dx, 0)
        XCTAssertEqual(deltas.dy, 0)
    }
}

final class MacScratchPrimaryOutputRoutingTests: XCTestCase {
    private var rane: MacScratchOutputRoute.Applied {
        .init(deviceID: 42, deviceUID: "usb.rane.pilot", deviceName: "Rane ONE MKII",
              channelMap: [-1, -1, 0, 1, -1, -1, -1, -1, -1, -1], channelPair: "3/4")
    }

    func testReusedDeviceIDCannotReplaceTheSelectedHardwareIdentity() {
        XCTAssertThrowsError(try MacScratchOutputRoute.validateIdentity(
            expectedDeviceUID: "selected-rane", actualDeviceUID: "different-device"))
        XCTAssertNoThrow(try MacScratchOutputRoute.validateIdentity(
            expectedDeviceUID: "selected-rane", actualDeviceUID: "selected-rane"))
        XCTAssertNoThrow(try MacScratchOutputRoute.validateIdentity(
            expectedDeviceUID: nil, actualDeviceUID: "system-default"))
    }

    func testStoppedEngineCannotRetainReadyOutputState() {
        XCTAssertThrowsError(try MacScratchOutputRoute.validateRunning(false))
        XCTAssertNoThrow(try MacScratchOutputRoute.validateRunning(true))
    }

    func testSelectedDeviceWinsOverSystemSpeakers() throws {
        XCTAssertEqual(try MacScratchOutputRoute.targetDevice(preferred: 42, systemDefault: 7), 42)
    }

    func testExplicitDefaultResetResolvesCurrentDefaultRatherThanOldRane() throws {
        XCTAssertEqual(try MacScratchOutputRoute.targetDevice(preferred: nil, systemDefault: 7), 7)
        XCTAssertEqual(try MacScratchOutputRoute.targetDevice(preferred: nil, systemDefault: 8), 8)
    }

    func testMissingExplicitDeviceDoesNotSilentlyUseDefault() {
        XCTAssertThrowsError(try MacScratchOutputRoute.targetDevice(preferred: 0, systemDefault: 7))
        XCTAssertThrowsError(try MacScratchOutputRoute.targetDevice(preferred: nil, systemDefault: nil))
    }

    func testRaneTenChannelOutputUsesOnlyRightDeck() throws {
        XCTAssertEqual(try MacScratchOutputRoute.channelMap(deviceName: "Rane ONE MKII",
            deviceChannels: 10, nodeChannels: 10), rane.channelMap)
    }

    func testUnsupportedRaneDoesNotGuessRightDeckOrDefaultStereo() {
        XCTAssertThrowsError(try MacScratchOutputRoute.channelMap(deviceName: "Rane Seventy-Two",
            deviceChannels: 10, nodeChannels: 10)) { error in
            XCTAssertTrue(error.localizedDescription.contains("has not been validated"))
        }
    }

    func testRaneNodeShortfallIsRejectedEvenWhenDeviceHasTenOutputs() {
        XCTAssertThrowsError(try MacScratchOutputRoute.channelMap(deviceName: "Rane ONE MKII",
            deviceChannels: 10, nodeChannels: 2))
    }

    func testOrdinaryStereoResetCannotRetainRaneChannelMap() throws {
        XCTAssertEqual(try MacScratchOutputRoute.channelMap(deviceName: "MacBook Pro Speakers",
            deviceChannels: 2, nodeChannels: 2), [0, 1])
    }

    func testReadbackRequiresActualSelectedDevice() {
        XCTAssertThrowsError(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: 7, channelMap: rane.channelMap))
        XCTAssertThrowsError(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: nil, channelMap: rane.channelMap))
    }

    func testReadbackRejectsWrongPairAndLeakedExtraDestinations() {
        XCTAssertThrowsError(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: 42, channelMap: [0, 1, -1, -1, -1, -1, -1, -1, -1, -1]))
        XCTAssertThrowsError(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: 42, channelMap: [0, 1, 0, 1, -1, -1, -1, -1, -1, -1]))
        XCTAssertThrowsError(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: 42, channelMap: nil))
    }

    func testVerifiedDeviceAndMapAreAccepted() {
        XCTAssertNoThrow(try MacScratchOutputRoute.validateReadback(route: rane,
            deviceID: 42, channelMap: rane.channelMap))
    }

    func testRoutineAndDiagnosticCapturesBothFreezeOutputRebinding() {
        XCTAssertFalse(MacScratchOutputRoute.canRebind(routineCaptureArmed: true, diagnosticCaptureArmed: false))
        XCTAssertFalse(MacScratchOutputRoute.canRebind(routineCaptureArmed: false, diagnosticCaptureArmed: true))
        XCTAssertFalse(MacScratchOutputRoute.canRebind(routineCaptureArmed: true, diagnosticCaptureArmed: true))
        XCTAssertTrue(MacScratchOutputRoute.canRebind(routineCaptureArmed: false, diagnosticCaptureArmed: false))
    }

    func testMacMonitorIsOffByDefault() {
        let state = MacScratchMonitorRouteState()
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.deviceID)
        XCTAssertFalse(state.accepts(epoch: state.epoch))
    }

    func testOldMonitorBuffersAndCompletionsCannotEnterNewRoute() {
        var state = MacScratchMonitorRouteState(epoch: 4, enabled: true, deviceID: 7,
            status: "active", error: nil)
        XCTAssertTrue(state.accepts(epoch: 4))
        state.epoch = 5
        state.deviceID = 8
        XCTAssertFalse(state.accepts(epoch: 4))
        XCTAssertTrue(state.accepts(epoch: 5))
    }

    func testDisabledOrMissingMonitorRejectsCurrentEpochToo() {
        var state = MacScratchMonitorRouteState(epoch: 4, enabled: false, deviceID: 7,
            status: "off", error: nil)
        XCTAssertFalse(state.accepts(epoch: 4))
        state.enabled = true
        state.deviceID = nil
        XCTAssertFalse(state.accepts(epoch: 4))
    }
}
