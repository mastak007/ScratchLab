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

@MainActor
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
    func testGravitySurvivesRepeatedUpdatesIncludingSessionChanges() async {
        let view = PreviewView()
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)

        // Simulate SwiftUI re-invoking updateNSView after a session change.
        let session = AVCaptureSession()
        attach(view, to: session)
        await drainSessionQueue()
        view.updateGravity(.resizeAspect)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect, "gravity must not be reset by a session change")

        // A second unrelated update pass (e.g. an unrelated re-render).
        attach(view, to: session)
        await drainSessionQueue()
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
    func testAttachingAndDetachingAPreviewNeverStartsOrStopsTheSession() async {
        let session = AVCaptureSession()
        XCTAssertFalse(session.isRunning)

        let view = PreviewView()
        attach(view, to: session)
        await drainSessionQueue()
        XCTAssertFalse(session.isRunning, "attaching a preview must not start capture")
        XCTAssertTrue(view.previewLayer.session === session)

        MacCameraPreviewView.dismantleNSView(view, coordinator: ())
        await drainSessionQueue()
        XCTAssertNil(view.previewLayer.session, "dismantling detaches the preview layer")
        XCTAssertFalse(session.isRunning, "detaching a preview must not stop capture")
    }

    /// Two previews can observe one session at once — Capture's and the
    /// authoring screen's — without either taking it from the other.
    func testASecondPreviewOnTheSameSessionDoesNotDetachTheFirst() async {
        let session = AVCaptureSession()
        let capturePreview = PreviewView()
        let authoringPreview = PreviewView()

        attach(capturePreview, to: session)
        attach(authoringPreview, to: session)
        await drainSessionQueue()
        XCTAssertTrue(capturePreview.previewLayer.session === session)
        XCTAssertTrue(authoringPreview.previewLayer.session === session)

        MacCameraPreviewView.dismantleNSView(authoringPreview, coordinator: ())
        await drainSessionQueue()
        XCTAssertTrue(
            capturePreview.previewLayer.session === session,
            "leaving the authoring screen must not take the preview away from the main capture workflow"
        )
    }


    private let sessionQueue = DispatchQueue(
        label: "test.camera.session", autoreleaseFrequency: .workItem
    )

    private func attach(
        _ view: PreviewView,
        to session: AVCaptureSession,
        queue: DispatchQueue? = nil,
        assignSession: MacCaptureEngine.PreviewAttachment.AssignSession? = nil
    ) {
        view.updateSession(ownerID: ObjectIdentifier(session)) { layer in
            if let assignSession {
                return MacCaptureEngine.PreviewAttachment(
                    session: session, sessionQueue: queue ?? sessionQueue,
                    layer: layer, assignSession: assignSession
                )
            }
            return MacCaptureEngine.PreviewAttachment(
                session: session, sessionQueue: queue ?? sessionQueue, layer: layer
            )
        }
    }

    private func drainSessionQueue(_ queue: DispatchQueue? = nil) async {
        await withCheckedContinuation { continuation in
            (queue ?? sessionQueue).async { continuation.resume() }
        }
    }

    /// Models the exact old lock ordering without deliberately deadlocking
    /// XCTest: tryLock records the old synchronous setter's blocked boundary.
    /// The worker's release is driven by a main heartbeat, never a timer.
    func testDismantleReturnsDuringSessionWorkAndMainHeartbeatReleasesConfiguration() async {
        for phase in ["beginConfiguration", "commitConfiguration", "start", "stop", "reconfigure"] {
            let session = AVCaptureSession()
            let view = PreviewView()
            let probe = PreviewSessionAssignmentProbe()
            let detached = expectation(description: "detached after \(phase)")
            attach(view, to: session) { layer, session in
                if probe.assign(layer, session) && session == nil { detached.fulfill() }
            }
            await drainSessionQueue()
            let heartbeat = DispatchSemaphore(value: 0)
            await withCheckedContinuation { configurationStarted in
                sessionQueue.async {
                    probe.configurationLock.lock()
                    probe.record("configuration began")
                    configurationStarted.resume()
                    heartbeat.wait()
                    probe.record("configuration finished")
                    probe.configurationLock.unlock()
                }
            }
            // The original updateSession(nil) reached this setter on main
            // while configuration held its resource. Detect that ordering,
            // but do not wait and strand the test runner.
            XCTAssertFalse(probe.assign(view.previewLayer, nil))
            XCTAssertEqual(probe.events.last, "old main assignment would block")
            MacCameraPreviewView.dismantleNSView(view, coordinator: ())
            probe.record("dismantle returned")
            DispatchQueue.main.async {
                probe.record("main heartbeat")
                heartbeat.signal()
            }
            await fulfillment(of: [detached], timeout: 5)
            await drainSessionQueue()
            XCTAssertEqual(probe.events, [
                "attached", "configuration began", "old main assignment would block",
                "dismantle returned", "main heartbeat", "configuration finished", "detached"
            ], phase)
            XCTAssertNil(view.previewLayer.session)
            XCTAssertFalse(session.isRunning)
        }
    }

    func testSupersededQueuedAttachAndDetachAreIgnored() async {
        let session = AVCaptureSession()
        let view = PreviewView()
        let probe = PreviewSessionAssignmentProbe()
        sessionQueue.suspend()
        attach(view, to: session, assignSession: { layer, session in probe.assignIgnoringResult(layer, session) })
        view.detachSession()
        attach(view, to: session, assignSession: { layer, session in probe.assignIgnoringResult(layer, session) })
        sessionQueue.resume()
        await drainSessionQueue()
        XCTAssertEqual(probe.events, ["attached"], "Only the newest generation may reach AVFoundation")
        XCTAssertTrue(view.previewLayer.session === session)
        view.detachSession()
        await drainSessionQueue()
    }

    func testTeardownBeforeQueuedAttachDoesNotAttachAnObsoletePreview() async {
        let session = AVCaptureSession()
        let view = PreviewView()
        let probe = PreviewSessionAssignmentProbe()
        sessionQueue.suspend()
        attach(view, to: session, assignSession: { layer, session in probe.assignIgnoringResult(layer, session) })
        MacCameraPreviewView.dismantleNSView(view, coordinator: ())
        sessionQueue.resume()
        await drainSessionQueue()
        XCTAssertTrue(probe.events.isEmpty, "A never-attached layer needs no session mutation")
        XCTAssertNil(view.previewLayer.session)
    }

    func testRepeatedAttachAndDetachAreIdempotent() async {
        let session = AVCaptureSession()
        let view = PreviewView()
        let probe = PreviewSessionAssignmentProbe()
        for _ in 0..<3 { attach(view, to: session, assignSession: { layer, session in probe.assignIgnoringResult(layer, session) }) }
        await drainSessionQueue()
        for _ in 0..<3 { view.detachSession() }
        await drainSessionQueue()
        XCTAssertEqual(probe.events, ["attached", "detached"])
    }

    func testDelayedTeardownOfPreviewALeavesPreviewBAttached() async {
        let session = AVCaptureSession()
        var previewA: PreviewView? = PreviewView()
        let previewB = PreviewView()
        attach(previewA!, to: session)
        await drainSessionQueue()
        let layerA = previewA!.previewLayer
        sessionQueue.suspend()
        attach(previewB, to: session)
        MacCameraPreviewView.dismantleNSView(previewA!, coordinator: ())
        previewA = nil
        sessionQueue.resume()
        await drainSessionQueue()
        await drainSessionQueue() // includes the last handle's queued fallback cleanup
        XCTAssertNil(layerA.session)
        XCTAssertTrue(previewB.previewLayer.session === session)
        previewB.detachSession()
        await drainSessionQueue()
    }

    func testNavigationAwayAndBackRestoresTheSameSessionPreview() async {
        let session = AVCaptureSession()
        let view = PreviewView()
        attach(view, to: session)
        await drainSessionQueue()
        view.detachSession()
        await drainSessionQueue()
        XCTAssertNil(view.previewLayer.session)
        attach(view, to: session)
        await drainSessionQueue()
        XCTAssertTrue(view.previewLayer.session === session)
        XCTAssertFalse(session.isRunning)
        view.detachSession()
        await drainSessionQueue()
    }

    func testReplacingOwnerUsesANewLayerSoOldCleanupCannotDetachReplacement() async {
        let sessionA = AVCaptureSession()
        let sessionB = AVCaptureSession()
        let queueB = DispatchQueue(label: "test.camera.session.replacement")
        let view = PreviewView()
        view.updateGravity(.resizeAspect)
        attach(view, to: sessionA)
        await drainSessionQueue()
        let oldLayer = view.previewLayer
        sessionQueue.suspend()
        attach(view, to: sessionB, queue: queueB)
        await drainSessionQueue(queueB)
        XCTAssertFalse(view.previewLayer === oldLayer)
        XCTAssertTrue(view.previewLayer.session === sessionB)
        XCTAssertEqual(view.previewLayer.videoGravity, .resizeAspect)
        sessionQueue.resume()
        await drainSessionQueue()
        await drainSessionQueue()
        XCTAssertNil(oldLayer.session)
        XCTAssertTrue(view.previewLayer.session === sessionB)
        view.detachSession()
        await drainSessionQueue(queueB)
    }

    func testQueuedWorkRetainsLayerAndSessionButNotViewUntilFinalCleanup() async {
        weak var weakView: PreviewView?
        weak var weakLayer: AVCaptureVideoPreviewLayer?
        weak var weakSession: AVCaptureSession?
        sessionQueue.suspend()
        autoreleasepool {
            let session = AVCaptureSession()
            let view = PreviewView()
            weakView = view
            weakLayer = view.previewLayer
            weakSession = session
            attach(view, to: session)
            view.detachSession()
        }
        XCTAssertNil(weakView, "Queued work must not retain the NSView")
        XCTAssertNotNil(weakLayer, "The queued operation must keep its layer alive")
        XCTAssertNotNil(weakSession)
        sessionQueue.resume()
        await drainSessionQueue()
        await drainSessionQueue()
        // The view's main-thread layer-tree edits also belong to an implicit
        // Core Animation transaction. Complete that presentation lifetime,
        // just as the normal main run loop would, before checking ARC release.
        autoreleasepool { CATransaction.flush() }
        XCTAssertNil(weakLayer)
        XCTAssertNil(weakSession)
    }

    func testDestructionWithoutDismantleStillDetachesAndReleasesTheSession() async {
        var view: PreviewView? = PreviewView()
        var session: AVCaptureSession? = AVCaptureSession()
        weak var weakSession: AVCaptureSession?
        weakSession = session
        attach(view!, to: session!)
        await drainSessionQueue()
        let layer = view!.previewLayer
        XCTAssertTrue(layer.session === session)
        autoreleasepool { view = nil; session = nil }
        await drainSessionQueue()
        XCTAssertNil(layer.session)
        XCTAssertNil(weakSession)
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
                && source.contains("captureEngine: captureEngine"),
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

    /// Route activation requests live input; recording, approval and shared
    /// engine teardown remain owned elsewhere.
    func testReferenceAuthoringAppearanceAndDisappearancePreserveCaptureOwnership() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(source.contains(".task {\n            activateCaptureInput()"))
        for forbidden in [
            "captureEngine.stop()",
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
    ///
    /// GUARD HISTORY — see the twin guard in
    /// `LivePerformedNotationTrackerTests` for the full reasoning.
    ///
    /// Two blanket string bans were retired on 2026-09-06 because they had
    /// stopped describing reality once the tear repair routed canonical
    /// gesture records through the SHARED chart:
    ///
    /// - `ScratchPhraseChartView(` — that IS the shared canonical renderer.
    ///   Replaced by a POSITIVE assertion that it is used with
    ///   `ChartSource.canonical`.
    /// - `ScratchStrokeGeometry` — narrowed to
    ///   `ScratchStrokeGeometry.canonicalGeometry`, so naming the frame type
    ///   is allowed but CALLING the geometry layer directly is still banned.
    ///
    /// Every capture/approval/publication ban below is unchanged, and the
    /// pre-existing `Canvas` is pinned separately by
    /// `testThePreExistingTimelineCanvasIsPinnedAndNotWidened`.
    func testTheCanonicalRendererAndSafetyBoundariesAreUnchanged() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(source.contains("LivePerformedNotationCard("))
        XCTAssertTrue(
            source.contains("source: .canonical(projection.records, layer: .performance, frame: frame)"),
            "tear notation must reach the shared chart as canonical gesture records"
        )
        // Unchanged safety boundary: the authoring view starts no capture,
        // approves nothing, and packages/publishes nothing.
        for forbidden in [
            "ScratchMotionRenderer",
            "ScratchStrokeGeometry.canonicalGeometry",
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


/// Per-test model of the session's configuration resource. There is no actual
/// blocking setter: a contended main-thread attempt is an observed failure of
/// the old ordering. Queue barriers control the release in the executable test.
private final class PreviewSessionAssignmentProbe: @unchecked Sendable {
    let configurationLock = NSLock()
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] { eventLock.withLock { recordedEvents } }

    func record(_ event: String) {
        eventLock.withLock { recordedEvents.append(event) }
    }

    @discardableResult
    func assign(_ layer: AVCaptureVideoPreviewLayer, _ session: AVCaptureSession?) -> Bool {
        guard configurationLock.try() else {
            record(Thread.isMainThread ? "old main assignment would block" : "unexpected worker contention")
            return false
        }
        defer { configurationLock.unlock() }
        guard layer.session !== session else { return false }
        XCTAssertFalse(Thread.isMainThread, "AVFoundation association must run on the session owner")
        layer.session = session
        record(session == nil ? "detached" : "attached")
        return true
    }

    func assignIgnoringResult(_ layer: AVCaptureVideoPreviewLayer, _ session: AVCaptureSession?) {
        assign(layer, session)
    }
}

#if DEBUG
/// Executes the same activation method as the route's SwiftUI task, with a
/// real engine and its real start guard. Only external startup work is replaced.
@MainActor
final class ReferenceAuthoringRouteActivationTests: XCTestCase {
    private final class StartupSpy {
        var requests = 0
    }

    private func withStoppedEngine(
        liveInputEnabled: Bool = false,
        body: (MacCaptureEngine, StartupSpy) -> Void
    ) {
        let defaults = UserDefaults.standard // The verified, isolated test host domain.
        let cameraKey = "scratchlab.mac.selectedVideoDeviceUniqueID"
        let liveKey = "scratchlab.mac.liveInputEnabled"
        let oldCamera = defaults.object(forKey: cameraKey)
        let oldLive = defaults.object(forKey: liveKey)
        defaults.set("saved-authoring-camera", forKey: cameraKey)
        defaults.set(liveInputEnabled, forKey: liveKey)
        defer {
            defaults.set(oldCamera, forKey: cameraKey)
            defaults.set(oldLive, forKey: liveKey)
        }
        let spy = StartupSpy()
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.liveInputStartupOverride = { spy.requests += 1 }
        XCTAssertFalse(engine.captureSession.isRunning)
        XCTAssertFalse(engine.isRoutineRecording)
        XCTAssertEqual(spy.requests, 0)
        body(engine, spy)
        XCTAssertEqual(defaults.bool(forKey: liveKey), liveInputEnabled)
        XCTAssertEqual(defaults.string(forKey: cameraKey), "saved-authoring-camera")
        XCTAssertEqual(engine.selectedVideoDeviceUniqueID, "saved-authoring-camera")
        XCTAssertFalse(engine.isRoutineRecording)
        XCTAssertFalse(engine.isRoutineFinalizationPending)
        XCTAssertNil(engine.lastRoutineRecordingURL)
    }

    private func route(_ engine: MacCaptureEngine) -> ReferenceAuthoringView {
        ReferenceAuthoringView(engine: engine, companionReceiver: nil, operatorName: "Route test")
    }

    func testRestoredRouteStartsFreshEngineWithSavedCameraAndLiveInputDisabled() {
        withStoppedEngine { engine, spy in
            let restoredRoute = route(engine)
            restoredRoute.activateCaptureInput()
            XCTAssertEqual(spy.requests, 1)
        }
    }

    func testDirectEntryRequestsStartupWithoutBeginningRecording() {
        withStoppedEngine { engine, spy in
            route(engine).activateCaptureInput()
            XCTAssertEqual(spy.requests, 1)
        }
    }

    func testRepeatedAppearanceRequestsOnlyOneStartup() {
        withStoppedEngine { engine, spy in
            let authoringRoute = route(engine)
            for _ in 0..<25 { authoringRoute.activateCaptureInput() }
            XCTAssertEqual(spy.requests, 1)
        }
    }

    func testWindowRecreationAndRouteReentryReuseTheAuthoritativeSession() {
        withStoppedEngine { engine, spy in
            let originalSession = engine.captureSession
            for _ in 0..<5 {
                let recreatedRoute = route(engine)
                recreatedRoute.activateCaptureInput()
            }
            XCTAssertEqual(spy.requests, 1)
            XCTAssertTrue(engine.captureSession === originalSession)
            XCTAssertTrue(originalSession.inputs.isEmpty)
            XCTAssertTrue(originalSession.outputs.isEmpty)
        }
    }

    func testFreshEngineAfterRelaunchReceivesItsOwnStartupRequest() {
        withStoppedEngine { firstEngine, firstSpy in
            route(firstEngine).activateCaptureInput()
            withStoppedEngine { freshEngine, freshSpy in
                route(freshEngine).activateCaptureInput()
                route(freshEngine).activateCaptureInput()
                XCTAssertEqual(firstSpy.requests, 1)
                XCTAssertEqual(freshSpy.requests, 1)
                XCTAssertFalse(firstEngine.captureSession === freshEngine.captureSession)
            }
        }
    }

    func testExistingGlobalStartupAndAuthoringEntryShareTheStartGuard() {
        withStoppedEngine(liveInputEnabled: true) { engine, spy in
            engine.start()
            route(engine).activateCaptureInput()
            XCTAssertEqual(spy.requests, 1)
        }
    }

    func testReentrantActivationDuringStartupDoesNotCompete() {
        withStoppedEngine { engine, spy in
            engine.liveInputStartupOverride = { [weak engine] in
                spy.requests += 1
                engine?.start()
            }
            route(engine).activateCaptureInput()
            XCTAssertEqual(spy.requests, 1)
        }
    }

    func testReentryAfterAnOwnerStopsTheEngineRequestsStartupAgain() {
        withStoppedEngine { engine, spy in
            let originalSession = engine.captureSession
            route(engine).activateCaptureInput()
            engine.stop() // Simulates the existing lifecycle owner, not route disappearance.
            route(engine).activateCaptureInput()
            route(engine).activateCaptureInput()
            XCTAssertEqual(spy.requests, 2)
            XCTAssertTrue(engine.captureSession === originalSession)
        }
    }
}
#endif
