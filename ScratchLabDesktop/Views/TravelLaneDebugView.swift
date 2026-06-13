#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

// TravelLaneDebugView — DEBUG-only, macOS-only A/B of the notation motion lane.
//
//   • Top lane (current production): excursion from the speed bucket
//     (`ScratchStrokeGeometry.motionPath(for:)`) over a hand-authored sample — a short FAST flick
//     still slams the rail. This lane always shows the sample (the "what the current renderer does"
//     reference); it is not rebuilt from loaded files (a LaneStroke speed bucket can't be derived
//     from a cc6 timeline).
//   • Bottom lane (proposed): excursion from platter travel
//     (`ScratchNotationTravelMotionPath.motionPath(for:scaling:.absoluteAboveBaseline)`). It uses
//     the DEBUG above-baseline mode so (a) the fullScaleTravelPercent slider is visibly meaningful —
//     lower scale = taller strokes, higher scale = shorter (the default `.perPhrase` fit cancels a
//     uniform scale) — and (b) every stroke rises ABOVE a single baseline: reverse is a return
//     stroke above the line, never a below-the-line dip (direction is carried by the renderer's
//     forward/reverse colour, not by sign). It shows EITHER the hand-authored sample OR — via the
//     DEBUG "Load…" button — a RECORDED ScratchTimeline JSON the user picks, decoded through
//     `ScratchTimelineProvenance` (Data → analyze → intent → display). Timing (x) comes from the
//     stroke times.
//
// Stage B boundary: this loads a *recorded* timeline, not live capture. The ONLY file I/O is the
// user-selected `.fileImporter` read below (DEBUG, macOS) — no hardcoded paths, no bundled/committed
// export, no live MIDI/engine/playback, no production renderer change. Calibration and
// fullScaleTravelPercent are explicit debug inputs. If nothing is loaded (or a load fails), the
// travel lane falls back to the hand-authored sample. Reachable in DEBUG builds via the macOS
// Window menu ("Travel Lane Debug") or the Xcode `#Preview`; absent from release builds.

struct TravelLaneDebugView: View {
    @State private var fullScaleTravelPercent: Double = 1.0
    @State private var stepsPerRevolution: Double = 3932      // RANE-measured default; editable
    @State private var crossfaderCutWidth: Double = 0.05      // editable
    @State private var noiseGateThreshold: Double = 0.0       // DEBUG: 0=off; silences strokes below this normalizedTravel

    @State private var loadedModel: ScratchNotationLaneDisplayModel?  // nil → hand-authored sample
    @State private var loadedName: String?
    @State private var showImporter = false
    @State private var loadError: String?

    private let sampleDuration: TimeInterval = 4.0

    private var calibration: ScratchAnalysisCalibration {
        .init(stepsPerRevolution: stepsPerRevolution, crossfaderCutWidth: crossfaderCutWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notation lane: speed-bucket vs travel (DEBUG)").font(.headline)

            labelledLane("Current — speed bucket (hand-authored sample)", color: .cyan) { ctx, size in
                ScratchMotionRenderer.draw(speedBucketPath, in: ctx,
                                           viewport: viewport(size: size, start: 0, span: sampleDuration),
                                           style: .target)
            }

            labelledLane(travelLaneTitle, color: .green) { ctx, size in
                let window = travelWindow
                ScratchMotionRenderer.draw(travelPath, in: ctx,
                                           viewport: viewport(size: size, start: window.start, span: window.span),
                                           style: .user)
            }

            controls
        }
        .padding()
        .frame(width: 560)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Load recorded ScratchTimeline JSON…") { showImporter = true }
                if loadedModel != nil {
                    Button("Use sample") { loadedModel = nil; loadedName = nil; loadError = nil }
                }
                Text(loadedName.map { "loaded: \($0)" } ?? "using hand-authored sample")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let loadError { Text(loadError).font(.caption).foregroundStyle(.red).lineLimit(2) }

            // DEBUG stats line — computed live from the travel model (no hardcoded counts)
            statsLine

            slider("fullScaleTravelPercent", value: $fullScaleTravelPercent, range: 0.2...3.0, fmt: "%.2f")
            slider("stepsPerRevolution (reload to apply)", value: $stepsPerRevolution, range: 500...5000, fmt: "%.0f")
            slider("crossfaderCutWidth (reload to apply)", value: $crossfaderCutWidth, range: 0...0.5, fmt: "%.2f")
            slider("noiseGateThreshold (normalizedTravel)", value: $noiseGateThreshold, range: 0.0...0.1, fmt: "%.4f")
        }
    }

    // MARK: - Stats line (DEBUG, computed live)

    private var statsLine: some View {
        let model = travelModel
        let stats = model.stats
        let silenced = model.strokes.filter { $0.normalizedTravel < noiseGateThreshold }.count
        let rendered = stats.totalStrokes - silenced
        let silencedText = noiseGateThreshold > 0
            ? " | silenced: \(silenced)" : ""
        return Text("strokes: \(stats.totalStrokes) | meaningful: \(stats.meaningfulTravelStrokes) | " +
                    "micro: \(stats.microTravelStrokes) | zero-dur: \(stats.zeroDurationStrokes) | " +
                    "rail hits: \(stats.railHitStrokes) | " +
                    "max travel: \(String(format: "%.1f", stats.maxTravelPercent))% | " +
                    "rendered: \(rendered)\(silencedText)")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(3)
    }

    @ViewBuilder
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String) -> some View {
        HStack {
            Text("\(label): \(value.wrappedValue, specifier: fmt)").font(.caption).monospacedDigit()
                .frame(width: 280, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    // MARK: - File import (DEBUG-only, user-selected — the only file I/O here)

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                loadedModel = try ScratchTimelineProvenance.displayModel(
                    from: data, calibration: calibration, fullScaleTravelPercent: fullScaleTravelPercent)
                loadedName = url.lastPathComponent
                loadError = nil
            } catch {
                loadedModel = nil; loadedName = nil          // fall back to sample
                loadError = "Load failed: \(error)"
            }
        case .failure(let error):
            loadedModel = nil; loadedName = nil          // fall back to sample
            loadError = "Load failed: \(error)"
        }
    }

    // MARK: - Lane sub-view

    @ViewBuilder
    private func labelledLane(_ title: String, color: Color,
                              draw: @escaping (GraphicsContext, CGSize) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(color)
            Canvas { context, size in draw(context, size) }
                .frame(height: 90)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func viewport(size: CGSize, start: TimeInterval, span: TimeInterval) -> LaneViewport {
        LaneViewport(size: size, now: start, axis: .horizontal,
                     actionLineFraction: 0, secondsAhead: max(span, 0.001))
    }

    private var travelLaneTitle: String {
        loadedModel == nil
            ? "Proposed — travel above baseline (hand-authored sample)"
            : "Proposed — travel above baseline (loaded recording)"
    }

    // MARK: - Sample (DEBUG only; not derived, not production)

    private var speedBucketPath: MotionPath {
        let strokes = [
            LaneStroke(startTime: 0.2, endTime: 0.5, direction: .forward, speed: .fast, faderState: .open, isGhost: false),
            LaneStroke(startTime: 1.0, endTime: 1.6, direction: .forward, speed: .fast, faderState: .open, isGhost: false),
            LaneStroke(startTime: 2.2, endTime: 2.8, direction: .backward, speed: .medium, faderState: .open, isGhost: false),
        ]
        let content = LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil,
                                  duration: sampleDuration, loops: false)
        return ScratchStrokeGeometry.motionPath(for: content)
    }

    private var sampleTravelPreview: ScratchNotationLanePreviewModel {
        ScratchNotationLanePreviewModel(strokes: [
            .init(direction: .forward, startTime: 0.2, endTime: 0.5, travelPercent: 0.2, audibleState: .audible),
            .init(direction: .forward, startTime: 1.0, endTime: 1.6, travelPercent: 1.0, audibleState: .audible),
            .init(direction: .reverse, startTime: 2.2, endTime: 2.8, travelPercent: 0.5, audibleState: .cut),
        ], warnings: [])
    }

    /// The active travel display model: loaded recording (re-scaled live by the slider) or sample.
    /// Calibration is baked into a loaded model at load time; the fullScale slider re-scales live by
    /// reconstructing a preview from the loaded model's raw travelPercent.
    private var travelModel: ScratchNotationLaneDisplayModel {
        let preview: ScratchNotationLanePreviewModel
        if let loaded = loadedModel {
            preview = ScratchNotationLanePreviewModel(
                strokes: loaded.strokes.map {
                    .init(direction: $0.direction, startTime: $0.startTime, endTime: $0.endTime,
                          travelPercent: $0.travelPercent, audibleState: $0.audibleState)
                },
                warnings: loaded.warnings)
        } else {
            preview = sampleTravelPreview
        }
        return ScratchNotationLaneDisplayAdapter.displayModel(from: preview, fullScaleTravelPercent: fullScaleTravelPercent)
    }

    private var travelWindow: (start: TimeInterval, span: TimeInterval) {
        let starts = travelModel.strokes.map(\.startTime)
        let ends = travelModel.strokes.map(\.endTime)
        guard let first = starts.min(), let last = ends.max(), last > first else {
            return (0, sampleDuration)
        }
        let margin = (last - first) * 0.05
        return (first - margin, (last - first) + 2 * margin)
    }

    private var travelPath: MotionPath {
        let last = travelModel.strokes.map(\.endTime).max() ?? sampleDuration
        // DEBUG validation lane uses `.absoluteAboveBaseline`: the fullScaleTravelPercent slider is
        // visibly meaningful (the default `.perPhrase` fit cancels a uniform scale) AND every stroke
        // rises above a single baseline — notation-truthful, never dipping below the line.
        // noiseGateThreshold silences strokes below the threshold as flat holds (timing preserved).
        return ScratchNotationTravelMotionPath.motionPath(
            for: travelModel, duration: max(last, sampleDuration),
            scaling: .absoluteAboveBaseline,
            noiseGateThreshold: noiseGateThreshold)
    }
}

#Preview("Travel lane A/B") {
    TravelLaneDebugView()
}
#endif
