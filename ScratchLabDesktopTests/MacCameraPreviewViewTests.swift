// MacCameraPreviewViewTests.swift
// ScratchLabDesktopTests
//
// Camera cropping fix, 2026-08-21: `MacCameraPreviewView`/`PreviewView`
// gained a `videoGravity` parameter (default `.resizeAspectFill`, unchanged
// for every pre-existing caller) so Practice's live camera can request
// `.resizeAspect` (full frame visible, letterboxed) without touching
// Capture's or Performer Monitor's cropped-fill behavior.
//
// These tests exercise `PreviewView` directly — the real `AVCaptureVideoPreviewLayer`
// host — rather than driving SwiftUI's `NSViewRepresentable` update cycle,
// since `MacCameraPreviewView.updateNSView` is a thin, one-line forward to
// `PreviewView.updateGravity(_:)`.

import AVFoundation
import XCTest
@testable import ScratchLab

final class MacCameraPreviewViewTests: XCTestCase {

    func testDefaultGravityIsResizeAspectFill() {
        let view = PreviewView()
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspectFill)
    }

    func testUpdateGravityAppliesResizeAspectForPractice() {
        let view = PreviewView()
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)
    }

    /// SwiftUI can call `updateNSView` repeatedly — when the capture session
    /// changes, or on an unrelated re-render — and the gravity setting must
    /// survive every one of those calls, not just the initial construction.
    func testGravitySurvivesRepeatedUpdatesIncludingSessionChanges() {
        let view = PreviewView()
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)

        // Simulate SwiftUI re-invoking updateNSView after a session change.
        let session = AVCaptureSession()
        view.updateSession(session)
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect, "gravity must not be reset by a session change")

        // A second unrelated update pass (e.g. an unrelated re-render).
        view.updateSession(session)
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)
    }

    func testGravityCanSwitchBackToAspectFillForCaptureStyleCallers() {
        let view = PreviewView()
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)
        view.updateGravity(.resizeAspectFill)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspectFill)
    }
}
