import SwiftUI
import AVFoundation

/// Camera passthrough notation overlay — Phase 1 manual / markerless prototype.
///
/// Layers a live camera preview, a manual platter calibration guide, and
/// captured-notation arc strokes into a single view.  No ARKit, no Vision
/// object tracking, no automatic platter detection.
///
/// ## Layers (back to front)
/// 1. **Camera preview** — `MacCameraPreviewView` using the caller-supplied
///    `AVCaptureSession`.
/// 2. **Notation overlay** — SwiftUI `Canvas` drawing:
///    - A platter guide circle at the calibrated centre / radius.
///    - Arc strokes for visible notation events, projected via
///      `CameraNotationOverlayGeometry`.
///    - A time-synced cursor dot on the platter edge.
/// 3. **Calibration controls** — radius slider, reset, lock toggle, and a
///    tap-to-set-centre gesture.
///
/// ## Reuse
/// - Camera feed: `MacCameraPreviewView` (existing `NSViewRepresentable`).
/// - Notation model: `LiveNotationOverlayModel` in `.captured` mode → future-
///   note guard + silence suppression.
/// - Stroke geometry: `CapturedNotationStrokeGeometry.travelFraction(for:)`
///   for proportional travel.
/// - Playback cursor: `OverlayReplayController` + `TimelineView`.
struct CameraPassthroughNotationView: View {

    let captureSession: AVCaptureSession
    let snapshot: CaptureCore.DetectedNotationSnapshot?

    @StateObject private var calibration = CameraNotationOverlayCalibration()
    @State private var controller: OverlayReplayController
    private let model: LiveNotationOverlayModel?

    // MARK: - Colours (match LiveNotationOverlayView)

    private let forwardColor  = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backColor     = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let guideColor    = Color.white.opacity(0.22)
    private let cursorColor   = Color.white
    private let controlBg     = Color.black.opacity(0.55)

    // MARK: - Init

    init(captureSession: AVCaptureSession,
         snapshot: CaptureCore.DetectedNotationSnapshot?) {
        self.captureSession = captureSession
        self.snapshot = snapshot

        if let snapshot, !snapshot.recordMovementEvents.isEmpty {
            let duration = max(snapshot.capturedEvidenceEndTime ?? 0, 0.1)
            self.model = LiveNotationOverlayModel(
                events: snapshot.recordMovementEvents,
                duration: duration,
                mode: .captured
            )
            let timeline = SessionReplayTimeline.build(
                from: snapshot,
                takeDuration: duration
            )
            self._controller = State(
                initialValue: OverlayReplayController(timeline: timeline)
            )
        } else {
            self.model = nil
            self._controller = State(
                initialValue: OverlayReplayController(
                    timeline: SessionReplayTimeline(takeDurationSeconds: 0, events: [])
                )
            )
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // ---- Layer 0: Camera preview ----
                MacCameraPreviewView(session: captureSession)

                // ---- Layer 1: Notation overlay ----
                if let model {
                    notationCanvas(model: model, viewSize: geo.size)
                } else {
                    emptyNotationOverlay(size: geo.size)
                }

                // ---- Layer 2: Calibration controls ----
                calibrationControls
            }
            .contentShape(Rectangle())
            .gesture(
                calibrationTapGesture(in: geo)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera passthrough notation overlay")
        }
    }

    // MARK: - Notation canvas (with playback)

    private func notationCanvas(model: LiveNotationOverlayModel,
                                viewSize: CGSize) -> some View {
        TimelineView(.animation(paused: !controller.isPlaying)) { context in
            let hostTime = context.date.timeIntervalSinceReferenceDate
            let currentTime = controller.currentTime(at: hostTime)
            Canvas(opaque: false) { ctx, size in
                drawPlatterGuide(context: ctx, size: size)
                drawArcStrokes(context: ctx, size: size,
                               model: model, currentTime: currentTime)
                drawCursor(context: ctx, size: size, currentTime: currentTime)
            }
            .onChange(of: shouldAutoStop(cursor: currentTime)) { _, atEnd in
                if atEnd { controller.tick(hostTime: hostTime) }
            }
        }
    }

    // MARK: - Empty notation state

    private func emptyNotationOverlay(size: CGSize) -> some View {
        Canvas(opaque: false) { ctx, size in
            drawPlatterGuide(context: ctx, size: size)
        }
        .overlay(alignment: .center) {
            Text("No captured notation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.38))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Drawing helpers

    /// Compute the view-space platter centre and radius from calibration state.
    private func platterViewParams(size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let c = calibration.clampedCenter
        let r = calibration.clampedRadius
        let shortAxis = min(size.width, size.height)
        return (
            center: CGPoint(x: c.x * size.width, y: c.y * size.height),
            radius: r * shortAxis
        )
    }

    /// Draw the calibration guide circle.
    private func drawPlatterGuide(context: GraphicsContext, size: CGSize) {
        let params = platterViewParams(size: size)
        let rect = CGRect(
            x: params.center.x - params.radius,
            y: params.center.y - params.radius,
            width:  params.radius * 2,
            height: params.radius * 2
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(guideColor),
            lineWidth: 1.5
        )
        // Centre crosshair
        let ch: CGFloat = 8
        var crossX = Path()
        crossX.move(to: CGPoint(x: params.center.x - ch, y: params.center.y))
        crossX.addLine(to: CGPoint(x: params.center.x + ch, y: params.center.y))
        var crossY = Path()
        crossY.move(to: CGPoint(x: params.center.x, y: params.center.y - ch))
        crossY.addLine(to: CGPoint(x: params.center.x, y: params.center.y + ch))
        context.stroke(crossX, with: .color(guideColor), lineWidth: 1)
        context.stroke(crossY, with: .color(guideColor), lineWidth: 1)
    }

    /// Draw arc strokes for every visible notation event.
    private func drawArcStrokes(context: GraphicsContext, size: CGSize,
                                model: LiveNotationOverlayModel,
                                currentTime: TimeInterval) {
        let params = platterViewParams(size: size)
        let strokes = CameraNotationOverlayGeometry.arcStrokes(
            from: model,
            currentTime: currentTime,
            maxRadius: params.radius
        )
        for stroke in strokes {
            let alpha = 0.55  // base alpha; could modulate by confidence if desired
            let color = stroke.isForward ? forwardColor : backColor
            var path = Path()
            path.addArc(
                center: params.center,
                radius: stroke.radius,
                startAngle: Angle(radians: stroke.startAngle),
                endAngle: Angle(radians: stroke.endAngle),
                clockwise: stroke.isForward
            )
            context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 3)
            // Dot at start of arc
            let startPoint = CameraNotationOverlayGeometry.point(
                angle: stroke.startAngle,
                travelFraction: stroke.radius / max(params.radius, 0.001),
                center: params.center,
                radius: stroke.radius
            )
            drawDot(context: context, at: startPoint)
            // Dot at end of arc
            let endPoint = CameraNotationOverlayGeometry.point(
                angle: stroke.endAngle,
                travelFraction: stroke.radius / max(params.radius, 0.001),
                center: params.center,
                radius: stroke.radius
            )
            drawDot(context: context, at: endPoint)
        }
    }

    private func drawDot(context: GraphicsContext, at point: CGPoint) {
        let r: CGFloat = 3
        let rect = CGRect(x: point.x - r, y: point.y - r,
                          width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.5)))
    }

    /// Draw the time-synced cursor dot at the platter edge.
    private func drawCursor(context: GraphicsContext, size: CGSize,
                            currentTime: TimeInterval) {
        guard let model else { return }
        let params = platterViewParams(size: size)
        let fraction = model.cursorFraction(at: currentTime)
        let angle = CameraNotationOverlayGeometry.angle(timeFraction: fraction)
        let cursorPoint = CameraNotationOverlayGeometry.point(
            angle: angle,
            travelFraction: 1.0,  // cursor sits on the platter edge
            center: params.center,
            radius: params.radius
        )
        // Glow ring
        let glowR: CGFloat = 7
        let glowRect = CGRect(x: cursorPoint.x - glowR, y: cursorPoint.y - glowR,
                              width: glowR * 2, height: glowR * 2)
        context.fill(
            Path(ellipseIn: glowRect),
            with: .color(cursorColor.opacity(0.18))
        )
        // Core dot
        let dotR: CGFloat = 4
        let dotRect = CGRect(x: cursorPoint.x - dotR, y: cursorPoint.y - dotR,
                             width: dotR * 2, height: dotR * 2)
        context.fill(
            Path(ellipseIn: dotRect),
            with: .color(cursorColor.opacity(0.9))
        )
    }

    // MARK: - Calibration controls

    private var calibrationControls: some View {
        VStack(spacing: 10) {
            // Transport row (only when notation model exists)
            if model != nil {
                transportRow
                Divider().background(Color.white.opacity(0.2))
            }

            // Radius slider
            HStack {
                Text("Radius")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                Slider(
                    value: Binding(
                        get: { calibration.clampedRadius },
                        set: { calibration.platterRadius = $0 }
                    ),
                    in: CameraNotationOverlayCalibration.radiusRange
                )
                .disabled(calibration.isLocked)
                Text(String(format: "%.2f", calibration.clampedRadius))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(minWidth: 36, alignment: .trailing)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    calibration.isLocked.toggle()
                } label: {
                    Label(
                        calibration.isLocked ? "Unlock" : "Lock",
                        systemImage: calibration.isLocked ? "lock.fill" : "lock.open"
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(calibration.isLocked ? .green : nil)

                Button {
                    calibration.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(calibration.isLocked)

                Spacer(minLength: 8)

                Text("Tap platter centre to calibrate")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(controlBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                controller.restart(
                    hostTime: Date().timeIntervalSinceReferenceDate
                )
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.hasTimeline)

            Button {
                let hostTime = Date().timeIntervalSinceReferenceDate
                if controller.isPlaying {
                    controller.pause(hostTime: hostTime)
                } else {
                    controller.play(hostTime: hostTime)
                }
            } label: {
                Image(systemName: controller.isPlaying
                    ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!controller.hasTimeline)

            TimelineView(.animation(paused: !controller.isPlaying)) { context in
                let cursor = controller.currentTime(
                    at: context.date.timeIntervalSinceReferenceDate
                )
                Text(String(format: "%.1fs / %.1fs", cursor, controller.duration))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.8))
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Gesture

    private func calibrationTapGesture(in geo: GeometryProxy) -> some Gesture {
        SpatialTapGesture()
            .onEnded { event in
                guard !calibration.isLocked else { return }
                let point = CGPoint(x: event.location.x, y: event.location.y)
                calibration.setCenter(from: point, viewSize: geo.size)
            }
    }

    // MARK: - Helpers

    private func shouldAutoStop(cursor: TimeInterval) -> Bool {
        guard controller.isPlaying else { return false }
        return cursor >= controller.duration
    }
}
