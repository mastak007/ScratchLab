import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// A derived reference picture, never a replacement for captured evidence.
/// The stored projection goes straight to the same chart used by finalized review.
enum ReferenceNotationPNGExport {
    static let width = 1600
    static let height = 1420
    static let secondsPerRow = 4.0
    static let rowsPerPage = 4

    struct Request: Encodable, Sendable {
        let performer: String
        let sessionID: String
        let takeID: String
        let takeNumber: Int
        let scratchType: String
        let bpm: Int
        let beatsPerBar: Int
        let duration: Double
        let showBeatGrid: Bool
        let projection: ReferenceTearCanonicalProjection?
        let sourceIdentity: String

        init(performer: String, sessionID: String, takeID: String, takeNumber: Int,
             scratchType: String, bpm: Int, duration: Double, showBeatGrid: Bool,
             projection: ReferenceTearCanonicalProjection?, sourceIdentity: String,
             beatsPerBar: Int = 4) throws {
            // Bound allocations before converting an externally persisted duration to Int.
            guard duration.isFinite, duration > 0, duration <= 3600, bpm > 0, (1...32).contains(beatsPerBar) else {
                throw SessionExportError.invalidSessionMetadata
            }
            self.performer = performer; self.sessionID = sessionID; self.takeID = takeID
            self.takeNumber = takeNumber; self.scratchType = scratchType; self.bpm = bpm
            self.duration = duration; self.showBeatGrid = showBeatGrid
            self.beatsPerBar = beatsPerBar
            self.projection = projection; self.sourceIdentity = sourceIdentity
        }

        var identity: String { get throws { try ExportSemanticIdentity.digest(self) } }

        /// Whole bars for timed takes, never less than four seconds per row.
        /// The lower bound also preserves the existing 225-page allocation limit.
        var rowDuration: Double {
            guard showBeatGrid else { return secondsPerRow }
            let barDuration = Double(beatsPerBar) * 60 / Double(bpm)
            return max(secondsPerRow, ceil(secondsPerRow / barDuration) * barDuration)
        }

        /// Keep the final partial row at the same seconds-per-pixel scale.
        /// Unrecorded time stays blank outside the chart, not labelled unknown.
        func widthFraction(for range: ClosedRange<Double>) -> Double {
            min(1, max(0, (range.upperBound - range.lowerBound) / rowDuration))
        }

        var pageRanges: [[ClosedRange<Double>]] {
            let rows = (0..<Int(ceil(duration / rowDuration))).map { index in
                let start = Double(index) * rowDuration
                return start...min(duration, start + rowDuration)
            }
            return stride(from: 0, to: rows.count, by: rowsPerPage).map {
                Array(rows[$0..<min(rows.count, $0 + rowsPerPage)])
            }
        }

        func frame(for range: ClosedRange<Double>) -> ScratchStrokeGeometry.CanonicalFrame? {
            guard let projection else { return nil }
            return ScratchStrokeGeometry.CanonicalFrame(timeRange: range,
                positionRange: projection.positionRange ?? -0.5...0.5,
                coordinateSpace: projection.coordinateSpace, beatsPerMinute: Double(bpm))
        }
    }

    struct Preview: Sendable {
        let sourceIdentity: String
        let pages: [Data]
    }

    static func artifactKey(page: Int) -> String { String(format: "notation_png_%03d", page + 1) }
    static func relativePath(notationFileName: String, page: Int) -> String {
        let stem = URL(fileURLWithPath: notationFileName).deletingPathExtension().lastPathComponent
        return "notation/" + stem + String(format: "_reference_%03d.png", page + 1)
    }

    @MainActor
    static func addingPreviews(to package: SessionExportPackage) async throws -> SessionExportPackage {
        let requests = try await Task.detached(priority: .userInitiated) {
            try SessionArchiveBuilder().notationPNGRequests(for: package)
        }.value
        var result = package
        for request in requests {
            var pages: [Data] = []
            for index in request.pageRanges.indices {
                try Task.checkCancellation()
                pages.append(try render(request, page: index))
                // Yield between bounded images; never run on a capture/audio callback.
                await Task.yield()
            }
            result.notationPNGByTakeID[request.takeID] = Preview(sourceIdentity: try request.identity, pages: pages)
        }
        return result
    }

    @MainActor
    static func render(_ request: Request, page: Int) throws -> Data {
        guard request.pageRanges.indices.contains(page) else { throw SessionExportError.unableToRenderNotation }
        let renderer = ImageRenderer(content: ReferenceNotationPNGPage(request: request, page: page)
            .frame(width: CGFloat(width), height: CGFloat(height))
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw SessionExportError.unableToRenderNotation }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SessionExportError.unableToRenderNotation
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SessionExportError.unableToRenderNotation }
        return data as Data
    }

    static func probe(_ data: Data) throws -> [String: SessionExportProbeValue] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else {
            throw SessionExportError.unableToRenderNotation
        }
        return ["kind": .string("png"), "width": .int(width), "height": .int(height)]
    }
}

private struct ReferenceNotationPNGPage: View {
    let request: ReferenceNotationPNGExport.Request
    let page: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SL CAPTURE · CAPTURED NOTATION").font(.system(size: 26, weight: .bold))
            Text("\(request.performer) · \(request.scratchType) · Take \(request.takeNumber)"
                + (request.showBeatGrid ? " · \(request.bpm) BPM" : " · Movement check"))
                .font(.system(size: 19)).lineLimit(2)
            Text("Session \(request.sessionID)   Take \(request.takeID)")
                .font(.system(size: 12, design: .monospaced)).lineLimit(2)
            ForEach(Array(request.pageRanges[page].enumerated()), id: \.offset) { _, range in
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.3f–%.3f seconds", range.lowerBound, range.upperBound))
                        .font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
                    if let projection = request.projection, let frame = request.frame(for: range) {
                        GeometryReader { geometry in
                            // Enlarge the existing chart's strokes and labels only here.
                            // Its measured geometry and all other app charts are unchanged.
                            let scale: CGFloat = 1.5
                            let width = geometry.size.width * request.widthFraction(for: range)
                            ScratchPhraseChartView(
                                source: .canonical(projection.records, layer: .performance, frame: frame),
                                bpm: Double(request.bpm), showBeatGrid: request.showBeatGrid,
                                mixerFaders: projection.mixerFaders, showsMixerFaderLanes: true,
                                backgroundColor: .clear)
                                .frame(width: width / scale, height: 240 / scale)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: width, height: 240, alignment: .topLeading)
                                .clipped()
                        }
                        .frame(height: 240)
                    } else {
                        Text("MOTION UNKNOWN — no saved canonical notation available")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Dim/dashed platter = fader closed · Shaded gaps = unknown motion · Separate fader lanes retain recorded controls")
            Text("Same time and position scale on every row. Blank space after the final row is outside the recording.")
            Text("Travel uses this take’s saved coordinate scale. Visual reference only; not calibration, approval or training data.")
            Text("Motion gaps and confidence details are retained in the accompanying notation JSON.")
            Text("Page \(page + 1) of \(request.pageRanges.count) · \(request.duration, specifier: "%.3f") seconds total")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(32)
        .background(Color(red: 0.045, green: 0.055, blue: 0.075))
    }
}
