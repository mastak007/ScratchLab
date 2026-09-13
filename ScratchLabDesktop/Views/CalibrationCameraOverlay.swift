// CalibrationCameraOverlay.swift
// ScratchLabDesktop
//
// Deck/mixer calibration box display placed directly on the camera image,
// shared by Practice's and Capture's camera cards (Karl's directive,
// 2026-08-21 fix bundle). Reuses `DeckGamificationOverlay` and the exact
// same `captureEngine.zoneAdjustments`/`calibrationLocked` state already
// used by the Performer Monitor window's own calibration editor and by
// Advanced's coarse Lock/Unlock + slider entry point — one calibration
// model, three presentations.
//
// The manual "Edit Boxes" affordance is available in normal builds so macOS
// matches the iOS calibration interaction. Editing remains disabled while a
// take is recording, and all changes persist through the shared calibration
// model.

import SwiftUI

struct CalibrationCameraOverlay: View {
    @ObservedObject var captureEngine: MacCaptureEngine

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DeckGamificationOverlay(detector: captureEngine, lockedOpacity: 0.18)
                // Defense in depth beyond the Record-button guard
                // (`handleRoutineRecordingButton`, which refuses to start a
                // take at all while unlocked): hit-testing is also forced
                // off here whenever a take is actively recording.
                .allowsHitTesting(!captureEngine.isRoutineRecording)

            editBoxesControl
                .padding(10)
        }
    }

    private var editBoxesControl: some View {
        Button {
            captureEngine.calibrationLocked.toggle()
        } label: {
            Label(
                captureEngine.calibrationLocked ? "Edit Boxes" : "Done",
                systemImage: captureEngine.calibrationLocked ? "pencil" : "checkmark"
            )
            .font(.system(size: 12, weight: .bold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(captureEngine.isRoutineRecording)
        .help(
            captureEngine.isRoutineRecording
                ? "Calibration can't be edited while recording."
                : (captureEngine.calibrationLocked ? "Edit deck and mixer boxes" : "Finish editing calibration boxes")
        )
    }
}
