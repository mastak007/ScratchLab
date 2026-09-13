import SwiftUI
import AVFoundation
import AppKit

struct MacCameraPreviewView: NSViewRepresentable {
    let captureEngine: MacCaptureEngine
    /// Defaults to `.resizeAspectFill` — every pre-existing call site keeps
    /// its current cropped-fill behavior unchanged. Practice's live camera
    /// passes `.resizeAspect` so the full frame is visible (letterboxed
    /// rather than cropped).
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// CXL overlays use AVFoundation's displayed image rectangle, excluding
    /// letterboxing. Ordinary preview callers don't request this callback.
    var onVideoRectChange: ((CGRect) -> Void)? = nil
    var showsUnmirroredVideo = false

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.updateSession(captureEngine, showsUnmirroredVideo: showsUnmirroredVideo)
        view.updateGravity(videoGravity)
        view.onVideoRectChange = onVideoRectChange
        view.scheduleVideoRectUpdate()
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.updateSession(captureEngine, showsUnmirroredVideo: showsUnmirroredVideo)
        // Re-applied on every update, not only at construction — SwiftUI can
        // call `updateNSView` when the capture session changes or the view
        // re-renders, and the gravity must survive that, not just the
        // initial `makeNSView`.
        nsView.updateGravity(videoGravity)
        nsView.onVideoRectChange = onVideoRectChange
        nsView.scheduleVideoRectUpdate()
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.detachSession()
    }
}

@MainActor
final class PreviewView: NSView {
    override var wantsUpdateLayer: Bool { true }

    private(set) var previewLayer = AVCaptureVideoPreviewLayer()
    private var sessionOwnerID: ObjectIdentifier?
    private var attachment: MacCaptureEngine.PreviewAttachment?
    var onVideoRectChange: ((CGRect) -> Void)?
    private var lastReportedVideoRect: CGRect?

    /// Publish after SwiftUI/AppKit updates, never while SwiftUI is evaluating
    /// a body. A 4:3 camera and a 16:9 camera therefore use their real visible
    /// pixel bounds instead of stretching calibration across black bars.
    func scheduleVideoRectUpdate() {
        guard onVideoRectChange != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let callback = self.onVideoRectChange else { return }
            let converted = self.previewLayer.layerRectConverted(
                fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
            let visible = CXLCameraGuideViewport.visibleVideoRect(converted, in: self.bounds)
            guard self.lastReportedVideoRect != visible else { return }
            self.lastReportedVideoRect = visible
            callback(visible)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspectFill
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSession(_ engine: MacCaptureEngine, showsUnmirroredVideo: Bool = false) {
        updateSession(ownerID: ObjectIdentifier(engine.captureSession), makeAttachment: engine.makePreviewAttachment)
        if showsUnmirroredVideo { attachment?.setVideoMirrored(false) }
    }

    /// The factory binds each layer to its session owner. The internal seam
    /// also lets tests exercise the real queue ordering without opening devices.
    func updateSession(
        ownerID: ObjectIdentifier,
        makeAttachment: (AVCaptureVideoPreviewLayer) -> MacCaptureEngine.PreviewAttachment
    ) {
        if sessionOwnerID != ownerID {
            attachment?.setAttached(false)
            if sessionOwnerID != nil {
                // A different owner gets a different layer. Old queued cleanup
                // can therefore never detach the replacement owner's preview.
                let gravity = previewLayer.videoGravity
                previewLayer.removeFromSuperlayer()
                previewLayer = AVCaptureVideoPreviewLayer()
                previewLayer.videoGravity = gravity
                layer?.addSublayer(previewLayer)
                needsLayout = true
            }
            sessionOwnerID = ownerID
            attachment = makeAttachment(previewLayer)
        }
        attachment?.setAttached(true)
    }

    func detachSession() {
        // No AVFoundation access here, including no synchronous session getter.
        attachment?.setAttached(false)
    }

    func updateGravity(_ gravity: AVLayerVideoGravity) {
        guard previewLayer.videoGravity != gravity else { return }
        previewLayer.videoGravity = gravity
    }

    override func layout() {
        super.layout()
        // Slice X.Perf.1: AVCaptureVideoPreviewLayer is a CALayer, so a
        // bare `frame = bounds` assignment runs through Core Animation's
        // default 0.25 s easeInOut implicit transition. During a live
        // window resize that produces a visible "preview chases the
        // window edge" lag. Wrapping the assignment in a CATransaction
        // with actions disabled snaps the layer to the new bounds in
        // the same render cycle as the host view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        scheduleVideoRectUpdate()
    }
}


/// Coordinate validation after AVFoundation's metadata-to-preview conversion.
/// Both preview and Vision use the same uncropped camera image; only its
/// containing rectangle changes when the window or camera aspect ratio changes.
enum CXLCameraGuideViewport {
    static func visibleVideoRect(_ converted: CGRect, in bounds: CGRect) -> CGRect {
        guard !converted.isNull, !converted.isInfinite,
              [converted.minX, converted.minY, converted.width, converted.height,
               bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              converted.width > 0, converted.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let visible = converted.intersection(bounds)
        return visible.isNull || visible.isEmpty ? .zero : visible
    }
}

/// CXL reuses the capture engine, real tracking zones and existing move/resize
/// editor. It does not open a camera, initiate capture or detect hardware.
struct CXLCameraCalibrationPreview: View {
    @ObservedObject var captureEngine: MacCaptureEngine
    var previewHeight: CGFloat = 360
    var captureInProgress: Bool = false
    @State private var displayedVideoRect: CGRect = .zero

    private var editsDisabled: Bool {
        captureInProgress || captureEngine.isAudioInputSelectionLocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacCameraPreviewView(
                captureEngine: captureEngine,
                videoGravity: .resizeAspect,
                onVideoRectChange: { displayedVideoRect = $0 },
                showsUnmirroredVideo: true
            )
            .frame(maxWidth: .infinity)
            .frame(height: previewHeight)
            .overlay(alignment: .topLeading) {
                if captureEngine.isCameraActive, !displayedVideoRect.isEmpty {
                    DeckGamificationOverlay(
                        detector: captureEngine,
                        lockedOpacity: 0.45,
                        allowsEditing: !editsDisabled
                    )
                    .frame(width: displayedVideoRect.width, height: displayedVideoRect.height)
                    .position(x: displayedVideoRect.midX, y: displayedVideoRect.midY)
                    .allowsHitTesting(!editsDisabled && !captureEngine.cameraGuideCalibrationLocked)
                }
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Text("Camera boxes · manual estimate")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(captureEngine.cxlCameraGuideLocked ? "Adjust camera boxes" : "Lock camera boxes") {
                    captureEngine.setCXLCameraGuideLocked(!captureEngine.cxlCameraGuideLocked)
                }
                Button("Fit full frame") {
                    captureEngine.resetCXLCameraGuideToFullFrame()
                }
            }
            .disabled(editsDisabled)
            Text(editsDisabled
                 ? "Camera boxes are fixed during capture."
                 : captureEngine.cxlCameraGuideLocked
                    ? "Left platter · wide mixer · right platter. Adjust the boxes to match your camera view."
                    : "Drag a box to move it; drag its green corner to resize. Lock when the boxes match your equipment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { captureEngine.enableCXLCameraGuide() }
        .onChange(of: captureEngine.isAudioInputSelectionLocked) { _, locked in
            if !locked { captureEngine.enableCXLCameraGuide() }
        }
        .onDisappear { captureEngine.disableCXLCameraGuide() }
    }
}
