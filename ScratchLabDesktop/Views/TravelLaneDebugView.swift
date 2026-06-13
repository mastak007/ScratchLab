#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

// TravelLaneDebugView — DEBUG-only, macOS-only A/B of the notation motion lane.
//
//   • Top lane (current production): excursion from the speed bucket
//     (`ScratchStrokeGeometry.motionPath(for:)`) over a hand-authored sample — a short FAST flick
//     still slams the rail. This lane always shows the sample (the "what the current renderer does"
//     reference); it is not rebuilt from loaded files (a LaneStroke speed bucket can't be derived
//     from a cc6 timeline). Hidden in CXL review mode.
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
//
// CXL review mode (default): turntablist-friendly labels, sensitivity presets, and only the green
// travel lane. Toggle "Show technical details" to reveal the full engineering view — the toggle
// preserves all state (loaded take, sensitivity, stroke height, calibration, lane output).

// MARK: - Sensitivity preset (DEBUG-only, CXL review mode)

/// DEBUG sensitivity presets for CXL review mode — map turntablist-friendly labels to
/// noiseGateThreshold values. NOT production; not persisted.
private enum SensitivityPreset: String, CaseIterable {
    case sensitive = "Sensitive"
    case normal = "Normal"
    case strict = "Strict"

    var threshold: Double {
        switch self {
        case .sensitive: return 0.0
        case .normal:    return 0.02
        case .strict:    return 0.05
        }
    }
}

struct TravelLaneDebugView: View {
    @State private var fullScaleTravelPercent: Double = 1.0
    @State private var stepsPerRevolution: Double = 3932      // RANE-measured default; editable
    @State private var crossfaderCutWidth: Double = 0.05      // editable
    @State private var noiseGateThreshold: Double = 0.02      // CXL default: Normal (0.02); 0=off

    @State private var loadedModel: ScratchNotationLaneDisplayModel?  // nil → hand-authored sample
    @State private var loadedName: String?
    @State private var showImporter = false
    @State private var loadError: String?

    /// CXL review mode toggle — defaults to turntablist-friendly labels (false).
    /// Advanced mode (true) reveals full engineering controls. Toggling preserves all state.
    @State private var showAdvanced: Bool = false

    /// CXL sensitivity preset — maps to noiseGateThreshold. nil when user has set a freeform
    /// value via the raw slider in Advanced mode.
    @State private var sensitivityPreset: SensitivityPreset? = .normal

    /// Zoom level for the travel lane — 1/2/4x. Wider canvas → higher pointsPerSecond → zoom.
    /// Display-only; does not change stroke geometry or model.
    @State private var laneZoom: Int = 1

    private let sampleDuration: TimeInterval = 4.0

    private var calibration: ScratchAnalysisCalibration {
        .init(stepsPerRevolution: stepsPerRevolution, crossfaderCutWidth: crossfaderCutWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(windowTitle).font(.headline)

            // Speed-bucket lane — engineering A/B reference; hidden in CXL review mode.
            if showAdvanced {
                labelledLane("Current — speed bucket (hand-authored sample)", color: .cyan) { ctx, size in
                    ScratchMotionRenderer.draw(speedBucketPath, in: ctx,
                                               viewport: viewport(size: size, start: 0, span: sampleDuration),
                                               style: .target)
                }
            }

            // Zoom-aware travel lane: wider canvas inside ScrollView clips to visible width.
            // Window stays at 560px regardless of zoom. LaneViewport maps wider canvas to
            // more pointsPerSecond — display-only zoom, no stroke geometry change.
            let zoomedLane = labelledLane(travelLaneTitle, color: .green) { ctx, size in
                let window = travelWindow
                ScratchMotionRenderer.draw(travelPath, in: ctx,
                                           viewport: viewport(size: size, start: window.start, span: window.span),
                                           style: .user)
            }
            if laneZoom > 1 {
                GeometryReader { geo in
                    let visibleWidth = geo.size.width
                    ScrollView(.horizontal, showsIndicators: true) {
                        zoomedLane.frame(width: visibleWidth * CGFloat(laneZoom))
                    }
                }
                .frame(height: 110)   // caption + spacing + 90px canvas
            } else {
                zoomedLane
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
            // --- Load / unload (label varies by mode) ---
            loadControls

            // --- Stats line (label varies by mode) ---
            statsLine

            // --- Take classification (CXL mode only, loaded take only) ---
            if !showAdvanced, let classification = takeClassification {
                Text(classification.text)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(classification.color)
            }

            if showAdvanced {
                advancedControls
            } else {
                cxlControls
            }

            // --- Mode toggle ---
            Divider()
            Button(showAdvanced ? "Hide technical details" : "Show technical details…") {
                showAdvanced.toggle()
            }
            .font(.caption)
        }
    }

    // MARK: - Load controls

    @ViewBuilder
    private var loadControls: some View {
        HStack {
            Button(showAdvanced ? "Load recorded ScratchTimeline JSON…" : "Load take…") {
                showImporter = true
            }
            if loadedModel != nil {
                Button(showAdvanced ? "Use sample" : "Use demo strokes") {
                    loadedModel = nil; loadedName = nil; loadError = nil
                }
            }
            loadedIndicator
        }
        if let loadError { Text(loadError).font(.caption).foregroundStyle(.red).lineLimit(2) }
    }

    private var loadedIndicator: some View {
        let text: String
        if showAdvanced {
            text = loadedName.map { "loaded: \($0)" } ?? "using hand-authored sample"
        } else {
            text = loadedName.map { "Loaded take: \($0)" } ?? "using demo strokes"
        }
        return Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - CXL controls (turntablist-friendly)

    @ViewBuilder
    private var cxlControls: some View {
        // Sensitivity presets
        VStack(alignment: .leading, spacing: 4) {
            Text("Movement sensitivity:").font(.caption)
            HStack(spacing: 8) {
                ForEach(SensitivityPreset.allCases, id: \.self) { preset in
                    Button {
                        sensitivityPreset = preset
                        noiseGateThreshold = preset.threshold
                    } label: {
                        Text(preset.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(sensitivityPreset == preset ? .accentColor : .secondary)
                }
            }
        }

        // Stroke height (CXL label for fullScaleTravelPercent)
        slider("Stroke height", value: $fullScaleTravelPercent, range: 0.2...3.0, fmt: "%.1f")

        // Zoom picker
        VStack(alignment: .leading, spacing: 4) {
            Text("Zoom:").font(.caption)
            Picker("Zoom", selection: $laneZoom) {
                Text("1x").tag(1)
                Text("2x").tag(2)
                Text("4x").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }

    // MARK: - Advanced controls (engineering)

    @ViewBuilder
    private var advancedControls: some View {
        slider("fullScaleTravelPercent", value: $fullScaleTravelPercent, range: 0.2...3.0, fmt: "%.2f")
        slider("stepsPerRevolution (reload to apply)", value: $stepsPerRevolution, range: 500...5000, fmt: "%.0f")
        slider("crossfaderCutWidth (reload to apply)", value: $crossfaderCutWidth, range: 0...0.5, fmt: "%.2f")

        // Raw noiseGateThreshold slider — moving it clears the CXL preset
        VStack(alignment: .leading, spacing: 2) {
            slider("noiseGateThreshold (normalizedTravel)", value: $noiseGateThreshold, range: 0.0...0.1, fmt: "%.4f")
                .onChange(of: noiseGateThreshold) { _, _ in
                    sensitivityPreset = nil  // freeform — no preset matches
                }
            if let preset = sensitivityPreset {
                Text("Preset: \(preset.rawValue)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Stats line (CXL vs engineering)

    private var statsLine: some View {
        let model = travelModel
        let stats = model.stats
        if showAdvanced {
            // Engineering stats — identical to the view before CXL mode was added.
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
        } else {
            // CXL turntablist-friendly stats
            let silenced = model.strokes.filter { $0.normalizedTravel < noiseGateThreshold }.count
            let silencedText = noiseGateThreshold > 0 && silenced > 0
                ? " (filtered: \(silenced))" : ""
            return Text("Movement strokes: \(stats.meaningfulTravelStrokes) | " +
                        "Hand jitters: \(stats.microTravelStrokes) | " +
                        "Biggest movement: \(String(format: "%.0f", stats.maxTravelPercent))% rotation\(silencedText)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: - Take classification (CXL mode, heuristic only)

    /// Heuristic take check for CXL review mode. NOT a persisted classification — computed
    /// live from the current stats and never written back. nil when no take is loaded.
    private var takeClassification: (text: String, color: Color)? {
        guard loadedModel != nil else { return nil }  // no classification for demo strokes
        let s = travelModel.stats
        guard s.totalStrokes > 0 else { return nil }

        let meaningfulPct = Double(s.meaningfulTravelStrokes) / Double(s.totalStrokes)
        let microPct = Double(s.microTravelStrokes) / Double(s.totalStrokes)
        let zeroPct = Double(s.zeroDurationStrokes) / Double(s.totalStrokes)

        if s.meaningfulTravelStrokes == 0 && s.microTravelStrokes > 0 {
            return ("Take check: Try Strict sensitivity", .blue)
        }
        if microPct > 0.30 {
            return ("Take check: Noisy movement", .orange)
        }
        if meaningfulPct >= 0.70 && zeroPct <= 0.10 {
            return ("Take check: Looks clean", .green)
        }
        return nil  // inconclusive — show nothing
    }

    // MARK: - Slider helper

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
                // Try old RANE-format ScratchTimeline first (cc6Step events → C++ analysis).
                if let model = try? ScratchTimelineProvenance.displayModel(
                    from: data, calibration: calibration, fullScaleTravelPercent: fullScaleTravelPercent) {
                    loadedModel = model
                    loadedName = url.lastPathComponent
                    loadError = nil
                    return
                }
                // Fall back: try detected-notation sidecar (recordMovementEvents → direct preview).
                let preview = try ScratchDetectedNotationLaneAdapter.previewModel(from: data)
                loadedModel = ScratchNotationLaneDisplayAdapter.displayModel(
                    from: preview, fullScaleTravelPercent: fullScaleTravelPercent)
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

    /// Window title varies by mode: CXL sees turntablist wording, Advanced shows engineering terms.
    private var windowTitle: String {
        showAdvanced ? "Notation lane: speed-bucket vs travel (DEBUG)" : "Scratch movement review"
    }

    /// Lane title varies by mode: CXL uses turntablist terms, Advanced uses engineering terms.
    private var travelLaneTitle: String {
        if showAdvanced {
            return loadedModel == nil
                ? "Proposed — travel above baseline (hand-authored sample)"
                : "Proposed — travel above baseline (loaded recording)"
        }
        return loadedModel == nil
            ? "Record movement (demo strokes)"
            : "Record movement"
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
