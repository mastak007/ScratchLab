import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// A derived reference picture, never a replacement for captured evidence.
/// The explicit display derivative uses the same chart as finalized review;
/// canonical evidence remains stored separately, unchanged.
enum ReferenceNotationPNGExport {
    static let width = 1600
    static let height = 1420
    static let secondsPerRow = 4.0
    static let rowsPerPage = 2
    static let chartHeight: CGFloat = 440

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
        let beatTimelineOffsetSeconds: Double
        let projection: ReferenceTearCanonicalProjection?
        let sourceIdentity: String
        let repetitions: [ReferenceReviewMetadataDocument.Repetition]

        init(performer: String, sessionID: String, takeID: String, takeNumber: Int,
             scratchType: String, bpm: Int, duration: Double, showBeatGrid: Bool,
             projection: ReferenceTearCanonicalProjection?, sourceIdentity: String,
             beatsPerBar: Int = 4, beatTimelineOffsetSeconds: Double = 0,
             repetitions: [ReferenceReviewMetadataDocument.Repetition] = []) throws {
            // Bound allocations before converting an externally persisted duration to Int.
            guard duration.isFinite, duration > 0, duration <= 3600, bpm > 0, (1...32).contains(beatsPerBar),
                  beatTimelineOffsetSeconds.isFinite, beatTimelineOffsetSeconds >= 0 else {
                throw SessionExportError.invalidSessionMetadata
            }
            self.performer = performer; self.sessionID = sessionID; self.takeID = takeID
            self.takeNumber = takeNumber; self.scratchType = scratchType; self.bpm = bpm
            self.duration = duration; self.showBeatGrid = showBeatGrid
            self.beatTimelineOffsetSeconds = beatTimelineOffsetSeconds
            self.beatsPerBar = beatsPerBar
            self.projection = projection; self.sourceIdentity = sourceIdentity
            self.repetitions = repetitions
        }

        // Internal derived-picture identity, not a stored capture/schema revision.
        // Old pictures must not be mistaken for this layout at identical bounds.
        private struct RenderIdentity: Encodable { let revision: Int; let request: Request }
        var identity: String { get throws { try ExportSemanticIdentity.digest(RenderIdentity(revision: 3, request: self)) } }

        struct RepetitionEdge {
            let repetitionNumber: Int
            let time: Double
            let isStart: Bool
        }

        func repetitionEdges(in range: ClosedRange<Double>) -> [RepetitionEdge] {
            repetitions.flatMap { repetition -> [RepetitionEdge] in
                guard let start = repetition.startSeconds, let end = repetition.endSeconds,
                      start.isFinite, end.isFinite, end > start else { return [] }
                return [RepetitionEdge(repetitionNumber: repetition.repetitionNumber, time: start, isStart: true),
                        RepetitionEdge(repetitionNumber: repetition.repetitionNumber, time: end, isStart: false)]
                    .filter { range.contains($0.time) }
            }
        }

        func repetitionDescription(in range: ClosedRange<Double>) -> String {
            let descriptions = repetitions.compactMap { repetition -> String? in
                guard let start = repetition.startSeconds, let end = repetition.endSeconds,
                      start.isFinite, end.isFinite, end > start,
                      start < range.upperBound, end > range.lowerBound else { return nil }
                return String(format: "R%d in %.3f / out %.3f s", repetition.repetitionNumber, start, end)
            }
            return descriptions.isEmpty ? "No saved repetition timing for this row" : descriptions.joined(separator: " · ")
        }

        var coordinateDescription: String {
            switch projection?.coordinateSpace {
            case .normalizedTakeLocalDisplacement: "Take-local displacement · not revolutions; values differ between takes"
            case .platterRevolutions: "Recorded platter revolutions"
            case .samplePosition: "Source sample position · not physical platter travel"
            case nil: "Coordinate scale unavailable"
            }
        }

        /// Whole bars for timed takes, never less than four seconds per row.
        /// The lower bound also preserves the bounded 450-page allocation limit.
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
                coordinateSpace: projection.coordinateSpace, beatsPerMinute: Double(bpm))?
                .fittingVisibleMotion(in: projection.records, layer: .performance)
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
        // Pin the raster/color conversion as well as the geometry. The implicit
        // cgImage path can vary antialiased channels by one level between calls.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SessionExportError.unableToRenderNotation
        }
        renderer.render(rasterizationScale: 1) { _, draw in draw(context) }
        guard let image = context.makeImage() else { throw SessionExportError.unableToRenderNotation }
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
                    Text(String(format: "%.3f–%.3f seconds", range.lowerBound, range.upperBound)
                        + " · " + request.repetitionDescription(in: range))
                        .font(.system(size: 14, design: .monospaced)).lineLimit(2)
                        .frame(height: 34, alignment: .topLeading)
                    if let projection = request.projection, let frame = request.frame(for: range) {
                        Text(String(format: "Y %.5g…%.5g · ", frame.positionRange.lowerBound, frame.positionRange.upperBound)
                            + request.coordinateDescription)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(height: 18, alignment: .topLeading)
                        GeometryReader { geometry in
                            // Enlarge the existing chart's strokes and labels only here.
                            // Its measured geometry and all other app charts are unchanged.
                            let scale: CGFloat = 1.5
                            let width = geometry.size.width * request.widthFraction(for: range)
                            ScratchPhraseChartView(
                                source: .canonical(projection.records, layer: .performance, frame: frame),
                                bpm: Double(request.bpm), showBeatGrid: request.showBeatGrid,
                                beatTimelineOffsetSeconds: request.beatTimelineOffsetSeconds,
                                mixerFaders: projection.mixerFaders, showsMixerFaderLanes: true, reviewDetail: true,
                                backgroundColor: .clear)
                                .frame(width: width / scale, height: ReferenceNotationPNGExport.chartHeight / scale)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: width, height: ReferenceNotationPNGExport.chartHeight, alignment: .topLeading)
                                .overlay {
                                    Canvas { context, size in
                                        for edge in request.repetitionEdges(in: range) {
                                            let x = CGFloat((edge.time - range.lowerBound) / (range.upperBound - range.lowerBound)) * size.width
                                            var line = Path(); line.move(to: .init(x: x, y: 0))
                                            line.addLine(to: .init(x: x, y: size.height))
                                            context.stroke(line, with: .color(.yellow.opacity(0.7)),
                                                style: .init(lineWidth: 1, dash: edge.isStart ? [] : [5, 4]))
                                        }
                                    }
                                }
                                .clipped()
                        }
                        .frame(height: ReferenceNotationPNGExport.chartHeight)
                    } else {
                        Text("MOTION UNKNOWN — no saved canonical notation available")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: ReferenceNotationPNGExport.chartHeight)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(ReferenceRecordedMotionReview.explanation)
            Text("Dim/dashed platter = fader closed · Grey gaps = unknown motion · Separate fader lanes retain recorded controls")
            Text("Same time scale on every row. Each row has its own fixed linear height scale: compare slopes within a row, not across rows.")
            Text("Gold lines = saved repetition in (solid) / out (dashed). Blank space after the final row is outside the recording.")
            Text("Measured curves retain their original timing and shape. Visual reference only; not calibration, approval or training data.")
            Text("Motion gaps and confidence details are retained in the accompanying notation JSON.")
            Text("Page \(page + 1) of \(request.pageRanges.count) · \(request.duration, specifier: "%.3f") seconds total")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(32)
        .background(Color(red: 0.045, green: 0.055, blue: 0.075))
    }
}
