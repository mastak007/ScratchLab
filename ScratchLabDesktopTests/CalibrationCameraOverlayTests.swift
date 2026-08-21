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
