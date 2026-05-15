import SwiftUI
import AVFoundation
import AppKit

struct MacCameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.updateSession(session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.updateSession(session)
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
