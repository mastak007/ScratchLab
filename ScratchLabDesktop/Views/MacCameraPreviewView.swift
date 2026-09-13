import SwiftUI
import AVFoundation
import AppKit

struct MacCameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Defaults to `.resizeAspectFill` — every pre-existing call site keeps
    /// its current cropped-fill behavior unchanged. Practice's live camera
    /// passes `.resizeAspect` so the full frame is visible (letterboxed
    /// rather than cropped).
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.updateSession(session)
        view.updateGravity(videoGravity)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.updateSession(session)
        // Re-applied on every update, not only at construction — SwiftUI can
        // call `updateNSView` when the capture session changes or the view
        // re-renders, and the gravity must survive that, not just the
        // initial `makeNSView`.
        nsView.updateGravity(videoGravity)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) {
        nsView.updateSession(nil)
    }
}

final class PreviewView: NSView {
    override var wantsUpdateLayer: Bool { true }

    let previewLayer = AVCaptureVideoPreviewLayer()

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

    func updateSession(_ session: AVCaptureSession?) {
        guard previewLayer.session !== session else { return }
        previewLayer.session = session
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
    }
}
