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
        previewLayer.frame = bounds
    }
}
