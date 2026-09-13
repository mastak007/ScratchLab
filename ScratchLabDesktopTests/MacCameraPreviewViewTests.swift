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

    // MARK: - Attaching a preview never owns or drives the session

    /// A preview layer is a VIEWER of a session, not a controller of one.
    /// Reference Authoring attaches a second preview to the engine's own
    /// running session, so this has to hold or opening the DEBUG route could
    /// disturb the capture the take is recorded from.
    func testAttachingAndDetachingAPreviewNeverStartsOrStopsTheSession() {
        let session = AVCaptureSession()
        XCTAssertFalse(session.isRunning)

        let view = PreviewView()
        view.updateSession(session)
        XCTAssertFalse(session.isRunning, "attaching a preview must not start capture")
        XCTAssertTrue(view.previewLayer.session === session)

        MacCameraPreviewView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.previewLayer.session, "dismantling detaches the preview layer")
        XCTAssertFalse(session.isRunning, "detaching a preview must not stop capture")
    }

    /// Two previews can observe one session at once — Capture's and the
    /// authoring screen's — without either taking it from the other.
    func testASecondPreviewOnTheSameSessionDoesNotDetachTheFirst() {
        let session = AVCaptureSession()
        let capturePreview = PreviewView()
        let authoringPreview = PreviewView()

        capturePreview.updateSession(session)
        authoringPreview.updateSession(session)
        XCTAssertTrue(capturePreview.previewLayer.session === session)
        XCTAssertTrue(authoringPreview.previewLayer.session === session)

        MacCameraPreviewView.dismantleNSView(authoringPreview, coordinator: ())
        XCTAssertTrue(
            capturePreview.previewLayer.session === session,
            "leaving the authoring screen must not take the preview away from the main capture workflow"
        )
    }

    // MARK: - Reference Authoring uses the engine's own session

    private func authoringViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/ReferenceAuthoringView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testReferenceAuthoringPreviewsTheEnginesOwnCaptureSession() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            // Matched on the binding, not on an indentation the layout can
            // change — the panel moved below the Record controls on
            // 2026-09-05 and a whitespace-sensitive literal broke with it.
            source.contains("MacCameraPreviewView(")
                && source.contains("session: captureEngine.captureSession"),
            "The authoring preview must render the engine's existing session, not one of its own."
        )
        XCTAssertFalse(
            source.contains("AVCaptureSession("),
            "Reference Authoring must never construct a second capture session."
        )
        XCTAssertFalse(
            source.contains("captureSession.startRunning") || source.contains("captureSession.stopRunning"),
            "The authoring screen must never start or stop the shared capture session."
        )
        XCTAssertFalse(
            source.contains("CalibrationCameraOverlay"),
            "This is a plain framing panel; a camera overlay was explicitly not wanted."
        )
    }

    func testReferenceAuthoringStatesTheCameraIsInactiveRatherThanShowingASilentBlackPanel() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("if !captureEngine.isCameraActive"),
            "Inactive-camera state must be read from the engine, not assumed from the preview."
        )
        XCTAssertTrue(
            source.contains("Camera preview is not running."),
            "An inactive camera must say so rather than presenting an unexplained black rectangle."
        )
    }

    /// Opening or leaving the DEBUG route must not touch capture. The only
    /// teardown the screen performs is its own transient work and its own
    /// notation tracker.
    func testReferenceAuthoringAppearanceAndDisappearanceTouchNoCaptureState() throws {
        let source = try authoringViewSource()
        for forbidden in [
            "startRoutineRecording",
            "stopRoutineRecording",
            "toggleRoutineRecording",
            "approveTakeInReview",
            "markTakePublished",
            "writePackage"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "The authoring view must not call \(forbidden) — capture, approval and publication are owned elsewhere."
            )
        }
        XCTAssertTrue(
            source.contains("viewModel.cancelTransientWorkForViewDisappearance()"),
            "Disappearance cancels only transient work."
        )
        XCTAssertTrue(
            source.contains("syncLiveNotationTracker(isRecording: false)"),
            "Disappearance drops the notation tracker, which is what cancels its poll timer."
        )
    }

    // MARK: - D6: the live-notation card must have a real height to draw in
    //
    // Take-004 proved the DATA path was healthy — raw 12,047, matched 12,045,
    // 54 committed movements plus an open provisional, position span 0.157,
    // latest age 0.0s — while the drawn trace still looked flat. The card had
    // been compressed to roughly 20 pt, so 0.157 of travel rendered as about
    // 3 px. `ScratchPhraseChartView` derives its lane geometry from
    // `size.height`, so the card's height IS the vertical scale.

    func testTheLiveNotationCardHasAMinimumHeightContract() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("private static let liveNotationMinimumHeight: CGFloat = 180"),
            "the notation card needs a guaranteed height, or the renderer has nothing to draw in"
        )
        XCTAssertTrue(
            source.contains("minHeight: Self.liveNotationMinimumHeight"),
            "the minimum must actually be applied to the card"
        )
    }

    /// 180 pt sits with the established single-lane phrase-chart heights
    /// (118 / 120 / 150 / 160 / 190) and below the 320 pt minimum the STACKED
    /// target-plus-performance comparison uses. It is not the whole window.
    func testTheNotationMinimumMatchesEstablishedSingleLaneSizing() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(source.contains("liveNotationMinimumHeight: CGFloat = 180"))
        XCTAssertFalse(
            source.contains("minHeight: .infinity"),
            "the card must not be hard-coded to the whole window height"
        )
        // Code-shaped, not prose: the file's own comments explain WHY
        // `maxHeight: .infinity` collapsed the card, so a bare substring match
        // would hit the explanation rather than a real modifier.
        XCTAssertFalse(
            source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
            "an unbounded ScrollView resolves maxHeight: .infinity to the IDEAL height, which is what collapsed the card"
        )
    }

    /// The DEBUG row is a sibling of the card, not a child, so it cannot take
    /// height from the notation's guaranteed minimum.
    func testTheDebugDiagnosticsRowSitsOutsideTheNotationHeight() throws {
        let source = try authoringViewSource()
        let cardRange = try XCTUnwrap(source.range(of: "LivePerformedNotationCard("))
        let minimumRange = try XCTUnwrap(source.range(of: "minHeight: Self.liveNotationMinimumHeight"))
        let debugRange = try XCTUnwrap(source.range(of: "LiveNotationDiagnosticsRow(tracker:"))
        XCTAssertLessThan(cardRange.lowerBound, minimumRange.lowerBound)
        XCTAssertLessThan(
            minimumRange.lowerBound, debugRange.lowerBound,
            "the height modifier must close over the card before the diagnostics row begins"
        )
    }

    /// The camera cannot claim the whole scroll content and push notation off
    /// screen at the smallest supported window.
    func testTheCameraPreviewCannotCompressTheNotationAway() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("private static let cameraPreviewMaximumHeight: CGFloat = 360"),
            "the 16:9 preview needs a ceiling so both panels fit"
        )
        XCTAssertTrue(
            source.contains("maxHeight: Self.cameraPreviewMaximumHeight"),
            "the ceiling must be applied to the preview"
        )
    }

    /// Framing and notation stay two separate panels; notation is never drawn
    /// over the camera image.
    func testCameraAndNotationRemainSeparatePanels() throws {
        let source = try authoringViewSource()
        XCTAssertFalse(
            source.contains("ZStack("),
            "notation must not be overlaid on the camera preview"
        )
        XCTAssertFalse(source.contains("CalibrationCameraOverlay"))
        XCTAssertTrue(
            source.contains("DisclosureGroup(isExpanded: $isShowingFramingPanel)"),
            "the collapsible framing group is preserved, so collapsing releases its space normally"
        )
    }

    /// The canonical renderer is still the one drawing, and the view still
    /// performs no capture, approval, packaging, publication or training work.
    func testTheCanonicalRendererAndSafetyBoundariesAreUnchanged() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(source.contains("LivePerformedNotationCard("))
        for forbidden in [
            "ScratchPhraseChartView(",
            "ScratchMotionRenderer",
            "ScratchStrokeGeometry",
            "startRoutineRecording",
            "stopRoutineRecording",
            "approveTakeInReview",
            "markTakePublished",
            "writePackage"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "the authoring view must not reference \(forbidden)"
            )
        }
    }

    func testTheDebugDiagnosticsRowIsExcludedFromRelease() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("#if DEBUG\n                LiveNotationDiagnosticsRow"),
            "the diagnostics row must stay behind a DEBUG gate"
        )
        XCTAssertTrue(
            source.contains("#if DEBUG\n/// Compact, bounded, read-only counters"),
            "the diagnostics view itself must compile out of Release"
        )
    }
}
