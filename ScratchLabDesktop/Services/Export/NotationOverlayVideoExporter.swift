#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation
import OSLog

// MARK: - NotationOverlayVideoExportRequest

/// Configuration for a single notation-overlay video export. All
/// fields are required and validated by the exporter before any file
/// I/O begins. Pure value type — no view, no clock.
struct NotationOverlayVideoExportRequest: Equatable {
    let frames: [CinematicFrame]
    let outputURL: URL
    let width: Int
    let height: Int
    let frameRate: Int

    init?(frames: [CinematicFrame], outputURL: URL, width: Int, height: Int, frameRate: Int = 60) {
        guard width > 0, height > 0 else { return nil }
        guard frameRate > 0, frameRate <= 240 else { return nil }
        self.frames = frames
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

// MARK: - NotationOverlayVideoExportError

enum NotationOverlayVideoExportError: Error, CustomStringConvertible {
    case noFrames
    case writerSetupFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed
    case frameRenderFailed
    case sessionStartFailed
    case sessionFinishFailed(String)

    var description: String {
        switch self {
        case .noFrames:                    return "noFrames"
        case .writerSetupFailed(let why):  return "writerSetupFailed(\(why))"
        case .pixelBufferPoolUnavailable:  return "pixelBufferPoolUnavailable"
        case .pixelBufferAllocationFailed: return "pixelBufferAllocationFailed"
        case .frameRenderFailed:           return "frameRenderFailed"
        case .sessionStartFailed:          return "sessionStartFailed"
        case .sessionFinishFailed(let why): return "sessionFinishFailed(\(why))"
        }
    }
}

// MARK: - NotationOverlayVideoExporter

/// Phase D-X1 — transparent notation-overlay video exporter. Writes a
/// ProRes 4444 `.mov` file (alpha-capable codec) containing only the
/// notation / timing / playhead layer, droppable directly into OBS,
/// Premiere, or Final Cut.
///
/// **macOS-only.** Imports `AVFoundation` and `CoreVideo` — those are
/// confined to this file. The pure rendering work lives in
/// `CinematicFrameRenderer`; this exporter only wraps the encoder.
///
/// **App-Store-safe.** The exporter produces a file. It makes no
/// claim, surfaces no inferred labels, and never re-derives from the
/// source capture. Determinism: same `request.frames` and same
/// dimensions produce a byte-identical pixel stream (encoder header
/// timestamps may vary; the deterministic gate is on the rendered
/// pixel buffers, not the file bytes).
///
/// **Flag-gated.** Callers must check
/// `FeatureFlags.exportNotationOverlayVideoEnabled` before invoking;
/// the type itself is unconditional so tests can reach it without
/// flag overrides.
final class NotationOverlayVideoExporter {

    private static let logger = Logger(
        subsystem: "com.machelpnz.scratchlab.mac",
        category: "NotationOverlayVideoExporter"
    )

    /// Synchronously writes a transparent notation-overlay video to
    /// the request's output URL. Returns the output URL on success.
    @discardableResult
    func export(_ request: NotationOverlayVideoExportRequest) throws -> URL {
        guard !request.frames.isEmpty else { throw NotationOverlayVideoExportError.noFrames }

        try removeExistingFile(at: request.outputURL)
        let writer = try makeAssetWriter(for: request)
        let input = makeWriterInput(for: request)
        guard writer.canAdd(input) else {
            throw NotationOverlayVideoExportError.writerSetupFailed("cannot add input")
        }
        writer.add(input)
        let adaptor = makeAdaptor(for: input, width: request.width, height: request.height)

        guard writer.startWriting() else {
            throw NotationOverlayVideoExportError.writerSetupFailed(
                writer.error?.localizedDescription ?? "unknown writer error"
            )
        }
        writer.startSession(atSourceTime: .zero)

        try appendFrames(request: request, input: input, adaptor: adaptor)

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            semaphore.signal()
        }
        semaphore.wait()

        if let finishError {
            throw NotationOverlayVideoExportError.sessionFinishFailed(
                finishError.localizedDescription
            )
        }
        return request.outputURL
    }

    // MARK: Helpers

    private func removeExistingFile(at url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }

    private func makeAssetWriter(
        for request: NotationOverlayVideoExportRequest
    ) throws -> AVAssetWriter {
        do {
            let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = false
            return writer
        } catch {
            throw NotationOverlayVideoExportError.writerSetupFailed(
                error.localizedDescription
            )
        }
    }

    private func makeWriterInput(
        for request: NotationOverlayVideoExportRequest
    ) -> AVAssetWriterInput {
        // ProRes 4444 carries an alpha channel — the whole point of
        // D-X1's transparent overlay output. H.264 / HEVC would drop
        // the alpha and defeat the export.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: request.width,
            AVVideoHeightKey: request.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func makeAdaptor(
        for input: AVAssetWriterInput,
        width: Int,
        height: Int
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )
    }

    private func appendFrames(
        request: NotationOverlayVideoExportRequest,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws {
        let timescale: Int32 = Int32(max(1, request.frameRate))
        for (index, frame) in request.frames.enumerated() {
            // Block until the writer signals it can accept more data.
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let image = CinematicFrameRenderer.renderImage(
                frame: frame,
                width: request.width,
                height: request.height
            ) else {
                throw NotationOverlayVideoExportError.frameRenderFailed
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw NotationOverlayVideoExportError.pixelBufferPoolUnavailable
            }
            guard let buffer = makePixelBuffer(from: image, pool: pool) else {
                throw NotationOverlayVideoExportError.pixelBufferAllocationFailed
            }
            let presentation = CMTime(value: Int64(index), timescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: presentation) {
                throw NotationOverlayVideoExportError.frameRenderFailed
            }
        }
    }

    private func makePixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

#endif
