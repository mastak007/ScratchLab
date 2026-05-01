// FormulaPlaygroundView.swift
// ScratchLab
// Debug-friendly screen for parsing scratch formulas into timeline events.

import SwiftUI

struct FormulaPlaygroundView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var progressManager: ProgressManager

    @State private var formulaText: String = "baby + chirp + flare1"
    @State private var astSummary: String = ""
    @State private var timeline: ScratchRenderTimeline?
    @State private var errorText: String?
    @State private var drillTimeline: ScratchRenderTimeline?
    @State private var showingGuidedDrill = false

    private let parser = ScratchFormulaParser()
    private let renderer = ScratchFormulaRenderer()
    private let catalog = ScratchFormulaCatalog.mvp

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "05070B"),
                    Color(hex: "101826")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Formula Lab")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Turn a scratch formula into timed drill steps and preview the result before starting a guided run.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Formula")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))

                        TextField("e.g. baby + chirp + flare1", text: $formulaText)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .padding(12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)

                        Button(action: evaluateFormula) {
                            Text("Parse Formula")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(hex: "0EA5E9"))
                                .cornerRadius(8)
                        }
                    }

                    supportedSymbols

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(12)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                    } else if let timeline {
                        resultCard(timeline: timeline)

                        Button(action: {
                            drillTimeline = timeline
                            showingGuidedDrill = true
                        }) {
                            Text("Start Guided Drill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(hex: "F59E0B"))
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Formula Lab")
        .toolbar {
            ToolbarItem {
                Button("Done") { dismiss() }
                    .foregroundColor(.yellow)
            }
        }
        .fullScreenCover(isPresented: $showingGuidedDrill, onDismiss: {
            drillTimeline = nil
        }) {
            if let drillTimeline {
                PracticeModeView(
                    scratch: scratchForDrill(from: drillTimeline),
                    drillTimeline: drillTimeline,
                    drillBPM: 90
                )
                .environmentObject(audioEngine)
                .environmentObject(progressManager)
            }
        }
        .onAppear {
            evaluateFormula()
        }
    }

    private var supportedSymbols: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SUPPORTED SYMBOLS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))

                Spacer()

                Text("\(catalog.entries.count) scratches")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "7DD3FC"))
            }

            Text("TTM-style aliases for the scratches already built into ScratchLab.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.62))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(catalog.entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)

                                Spacer()

                                HStack(spacing: 8) {
                                    Text(defaultTimingSummary(for: entry))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.62))

                                    Text(notationSpec(for: entry.id).sourceLabel)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color(hex: "7DD3FC"))
                                }
                            }

                            ScratchNotationPreview(scratchID: entry.id)
                                .frame(height: 56)

                            Text(aliasSummary(for: entry))
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(.white.opacity(0.82))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if index < catalog.entries.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 340)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    private func resultCard(timeline: ScratchRenderTimeline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TTM GRAPH")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))

            FormulaNotationSequenceView(timeline: timeline)

            Divider().overlay(Color.white.opacity(0.2))

            Text("AST")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Text(astSummary)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.white)

            Divider().overlay(Color.white.opacity(0.2))

            Text("TIMELINE (\(timeline.events.count) events, \(timeline.totalBeats.formatted(.number.precision(.fractionLength(0...2)))) beats)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))

            ForEach(Array(timeline.events.enumerated()), id: \.offset) { index, event in
                Text("\(index + 1). \(event.scratchID) | start \(event.startBeat.formatted(.number.precision(.fractionLength(0...2)))) | len \(event.durationBeats.formatted(.number.precision(.fractionLength(0...2)))) | \(event.direction.rawValue)")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    private func evaluateFormula() {
        do {
            let ast = try parser.parse(formulaText)
            let rendered = try renderer.render(ast: ast, catalog: catalog)
            astSummary = summarize(ast.root)
            timeline = rendered
            errorText = nil
        } catch {
            timeline = nil
            astSummary = ""
            print("Formula parsing error: \(error.localizedDescription)")
            errorText = "Unable to parse that formula. Check the symbols and try again."
        }
    }

    private func scratchForDrill(from timeline: ScratchRenderTimeline) -> Scratch {
        if let firstID = timeline.events.first?.scratchID,
           let resolved = ScratchLibrary.shared.scratch(byID: firstID) {
            return resolved
        }
        return ScratchLibrary.shared.scratch(byID: "baby_scratch") ?? ScratchLibrary.shared.allScratches[0]
    }

    private func summarize(_ node: ScratchFormulaNode) -> String {
        switch node {
        case .symbol(let symbol):
            return symbol
        case .scalar(let value):
            return value.formatted(.number.precision(.fractionLength(0...4)))
        case .unary(let op, let child):
            return "(\(op.rawValue)\(summarize(child)))"
        case .binary(let op, let lhs, let rhs):
            return "(\(summarize(lhs)) \(op.rawValue) \(summarize(rhs)))"
        }
    }

    private func aliasSummary(for entry: ScratchCatalogEntry) -> String {
        var seen: Set<String> = []
        let tokens = ([entry.id] + entry.aliases.sorted()).filter { seen.insert($0).inserted }
        return tokens.joined(separator: ", ")
    }

    private func defaultTimingSummary(for entry: ScratchCatalogEntry) -> String {
        let beatCount = entry.defaultBeats.formatted(.number.precision(.fractionLength(0...1)))
        return beatCount == "1" ? "1 beat" : "\(beatCount) beats"
    }

    private func notationSpec(for scratchID: String) -> ScratchNotationSpec {
        ScratchNotationLibrary.spec(for: scratchID)
    }
}

private struct FormulaNotationSequenceView: View {
    let timeline: ScratchRenderTimeline

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(timeline.events.enumerated()), id: \.offset) { index, event in
                    VStack(alignment: .leading, spacing: 5) {
                        ScratchNotationPreview(scratchID: event.scratchID, direction: event.direction)
                            .frame(width: 144, height: 62)

                        Text(graphCaption(for: event))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }

                    if index < timeline.events.count - 1 {
                        Text("+")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 18)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func graphCaption(for event: ScratchRenderEvent) -> String {
        let spec = ScratchNotationLibrary.spec(for: event.scratchID)
        let direction = event.direction == .reverse ? "rev" : "fwd"
        return "\(spec.title) · \(direction)"
    }
}

private struct ScratchNotationPreview: View {
    let scratchID: String
    var direction: ScratchDirection = .forward

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
                ScratchNotationLibrary.drawGrid(in: rect, context: &context)
                ScratchNotationLibrary.drawNotation(
                    for: scratchID,
                    direction: direction,
                    in: rect,
                    context: &context
                )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ScratchNotationSpec {
    let title: String
    let sourceLabel: String
    let template: ScratchNotationTemplate
}

private enum ScratchNotationTemplate {
    case baby
    case forward
    case backward
    case releaseDerived
    case tearDerived
    case chirp
    case scribble
    case stab
    case transform
    case crabDerived
    case flare1
    case orbit
    case flare2
    case twiddle
    case boomerangDerived
    case hydroplaneDerived
    case flare3
    case autobahnDerived
    case military
    case prizmDerived
}

private enum ScratchNotationMarkerStyle {
    case filledCircle
    case openCircle
    case verticalCut
}

private struct ScratchNotationMarker {
    let x: CGFloat
    let y: CGFloat
    let style: ScratchNotationMarkerStyle
}

private enum ScratchNotationLibrary {
    static func spec(for scratchID: String) -> ScratchNotationSpec {
        switch scratchID {
        case "baby_scratch":
            return ScratchNotationSpec(title: "Baby", sourceLabel: "PDF", template: .baby)
        case "forward_scratch":
            return ScratchNotationSpec(title: "Forward", sourceLabel: "PDF", template: .forward)
        case "backward_scratch":
            return ScratchNotationSpec(title: "Backward", sourceLabel: "PDF", template: .backward)
        case "release_scratch":
            return ScratchNotationSpec(title: "Release", sourceLabel: "Derived", template: .releaseDerived)
        case "tear":
            return ScratchNotationSpec(title: "Tear", sourceLabel: "Derived", template: .tearDerived)
        case "chirp":
            return ScratchNotationSpec(title: "Chirp", sourceLabel: "PDF", template: .chirp)
        case "scribble":
            return ScratchNotationSpec(title: "Scribble", sourceLabel: "PDF", template: .scribble)
        case "stab":
            return ScratchNotationSpec(title: "Stab", sourceLabel: "PDF", template: .stab)
        case "transform":
            return ScratchNotationSpec(title: "Transform", sourceLabel: "PDF", template: .transform)
        case "crab":
            return ScratchNotationSpec(title: "Crab", sourceLabel: "Derived", template: .crabDerived)
        case "flare_1click":
            return ScratchNotationSpec(title: "1-Click Flare", sourceLabel: "PDF", template: .flare1)
        case "orbit":
            return ScratchNotationSpec(title: "Orbit", sourceLabel: "PDF", template: .orbit)
        case "flare_2click":
            return ScratchNotationSpec(title: "2-Click Flare", sourceLabel: "PDF", template: .flare2)
        case "twiddle":
            return ScratchNotationSpec(title: "Twiddle", sourceLabel: "PDF", template: .twiddle)
        case "boomerang":
            return ScratchNotationSpec(title: "Boomerang", sourceLabel: "Derived", template: .boomerangDerived)
        case "hydroplane":
            return ScratchNotationSpec(title: "Hydroplane", sourceLabel: "Derived", template: .hydroplaneDerived)
        case "flare_3click":
            return ScratchNotationSpec(title: "3-Click Flare", sourceLabel: "PDF", template: .flare3)
        case "autobahn":
            return ScratchNotationSpec(title: "Autobahn", sourceLabel: "Derived", template: .autobahnDerived)
        case "military":
            return ScratchNotationSpec(title: "Military", sourceLabel: "PDF", template: .military)
        case "prizm":
            return ScratchNotationSpec(title: "Prizm", sourceLabel: "Derived", template: .prizmDerived)
        default:
            return ScratchNotationSpec(title: scratchID, sourceLabel: "Derived", template: .forward)
        }
    }

    static func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
        var grid = Path()
        let columns = 14
        let rows = 6

        for column in 0...columns {
            let x = rect.minX + rect.width * CGFloat(column) / CGFloat(columns)
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        for row in 0...rows {
            let y = rect.minY + rect.height * CGFloat(row) / CGFloat(rows)
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.7)
    }

    static func drawNotation(
        for scratchID: String,
        direction: ScratchDirection,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        let spec = spec(for: scratchID)
        let notationRect = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.08)
        var path = path(for: spec.template, in: notationRect)
        var markers = markers(for: spec.template, in: notationRect)

        if direction == .reverse {
            let mirror = CGAffineTransform(translationX: notationRect.midX * 2, y: 0).scaledBy(x: -1, y: 1)
            path = path.applying(mirror)
            markers = markers.map { marker in
                ScratchNotationMarker(
                    x: 1 - marker.x,
                    y: marker.y,
                    style: marker.style
                )
            }
        }

        context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 2.1)
        drawMarkers(markers, in: notationRect, context: &context)
    }

    private static func drawMarkers(_ markers: [ScratchNotationMarker], in rect: CGRect, context: inout GraphicsContext) {
        for marker in markers {
            let point = CGPoint(
                x: rect.minX + rect.width * marker.x,
                y: rect.minY + rect.height * marker.y
            )

            switch marker.style {
            case .filledCircle:
                let markerRect = CGRect(x: point.x - 3.2, y: point.y - 3.2, width: 6.4, height: 6.4)
                context.fill(Path(ellipseIn: markerRect), with: .color(.white.opacity(0.95)))

            case .openCircle:
                let markerRect = CGRect(x: point.x - 3.7, y: point.y - 3.7, width: 7.4, height: 7.4)
                context.stroke(Path(ellipseIn: markerRect), with: .color(.white.opacity(0.95)), lineWidth: 1.4)

            case .verticalCut:
                let markerRect = CGRect(x: point.x - 1, y: point.y - 8, width: 2, height: 16)
                context.fill(Path(CGRect(x: markerRect.minX, y: markerRect.minY, width: markerRect.width, height: markerRect.height)), with: .color(.white.opacity(0.95)))
            }
        }
    }

    private static func path(for template: ScratchNotationTemplate, in rect: CGRect) -> Path {
        switch template {
        case .baby:
            var path = sineWave(in: rect, xRange: 0.03...0.68, baseline: 0.6, amplitude: 0.18, cycles: 3.6)
            path.addLine(to: point(0.92, 0.16, in: rect))
            return path

        case .forward:
            return polyline(in: rect, points: [(0.08, 0.74), (0.92, 0.18)])

        case .backward:
            return polyline(in: rect, points: [(0.08, 0.18), (0.92, 0.74)])

        case .releaseDerived:
            return polyline(in: rect, points: [(0.1, 0.58), (0.28, 0.38), (0.92, 0.18)])

        case .tearDerived:
            return polyline(in: rect, points: [(0.08, 0.72), (0.3, 0.38), (0.46, 0.62), (0.66, 0.32), (0.92, 0.18)])

        case .chirp:
            return polyline(in: rect, points: [
                (0.08, 0.76), (0.18, 0.34), (0.28, 0.76),
                (0.38, 0.34), (0.48, 0.76),
                (0.58, 0.34), (0.68, 0.76),
                (0.78, 0.34), (0.9, 0.76)
            ])

        case .scribble:
            var path = sineWave(in: rect, xRange: 0.04...0.68, baseline: 0.62, amplitude: 0.1, cycles: 7.5)
            path.addLine(to: point(0.92, 0.18, in: rect))
            return path

        case .stab:
            var path = polyline(in: rect, points: [(0.54, 0.74), (0.92, 0.18)])
            for slashX in [0.14, 0.28, 0.42] {
                path.addPath(polyline(in: rect, points: [(slashX, 0.7), (slashX + 0.05, 0.38)]))
            }
            return path

        case .transform:
            return polyline(in: rect, points: [
                (0.06, 0.76), (0.26, 0.48), (0.44, 0.22),
                (0.6, 0.4), (0.78, 0.64), (0.94, 0.54)
            ])

        case .crabDerived:
            return sineWave(in: rect, xRange: 0.05...0.95, baseline: 0.58, amplitude: 0.22, cycles: 1.2)

        case .flare1:
            return sineWave(in: rect, xRange: 0.04...0.96, baseline: 0.58, amplitude: 0.24, cycles: 1.45)

        case .orbit:
            return sineWave(in: rect, xRange: 0.04...0.96, baseline: 0.58, amplitude: 0.24, cycles: 2.0)

        case .flare2:
            return sineWave(in: rect, xRange: 0.05...0.95, baseline: 0.58, amplitude: 0.18, cycles: 2.2)

        case .twiddle:
            return sineWave(in: rect, xRange: 0.05...0.95, baseline: 0.58, amplitude: 0.18, cycles: 3.0)

        case .boomerangDerived:
            return polyline(in: rect, points: [
                (0.08, 0.62), (0.26, 0.34), (0.46, 0.68), (0.64, 0.38), (0.92, 0.6)
            ])

        case .hydroplaneDerived:
            return polyline(in: rect, points: [
                (0.06, 0.28), (0.28, 0.74), (0.6, 0.58), (0.92, 0.46)
            ])

        case .flare3:
            return sineWave(in: rect, xRange: 0.05...0.95, baseline: 0.58, amplitude: 0.16, cycles: 2.9)

        case .autobahnDerived:
            var path = polyline(in: rect, points: [(0.56, 0.76), (0.92, 0.18)])
            for slashX in [0.12, 0.26, 0.4] {
                path.addPath(polyline(in: rect, points: [(slashX, 0.68), (slashX + 0.06, 0.44)]))
            }
            return path

        case .military:
            return sineWave(in: rect, xRange: 0.06...0.94, baseline: 0.58, amplitude: 0.16, cycles: 2.6)

        case .prizmDerived:
            return polyline(in: rect, points: [
                (0.08, 0.68), (0.28, 0.32), (0.44, 0.62), (0.62, 0.42), (0.82, 0.68), (0.92, 0.56)
            ])
        }
    }

    private static func markers(for template: ScratchNotationTemplate, in rect: CGRect) -> [ScratchNotationMarker] {
        switch template {
        case .flare1:
            return [
                .init(x: 0.08, y: 0.8, style: .openCircle),
                .init(x: 0.36, y: 0.47, style: .filledCircle),
                .init(x: 0.68, y: 0.47, style: .filledCircle),
                .init(x: 0.9, y: 0.8, style: .openCircle)
            ]

        case .orbit:
            return [
                .init(x: 0.08, y: 0.8, style: .openCircle),
                .init(x: 0.24, y: 0.46, style: .filledCircle),
                .init(x: 0.5, y: 0.8, style: .openCircle),
                .init(x: 0.66, y: 0.46, style: .filledCircle),
                .init(x: 0.9, y: 0.8, style: .openCircle)
            ]

        case .flare2:
            return [
                .init(x: 0.08, y: 0.8, style: .openCircle),
                .init(x: 0.24, y: 0.56, style: .filledCircle),
                .init(x: 0.4, y: 0.44, style: .filledCircle),
                .init(x: 0.58, y: 0.72, style: .filledCircle),
                .init(x: 0.74, y: 0.44, style: .filledCircle),
                .init(x: 0.9, y: 0.8, style: .openCircle)
            ]

        case .twiddle:
            return [
                .init(x: 0.08, y: 0.8, style: .openCircle),
                .init(x: 0.22, y: 0.48, style: .verticalCut),
                .init(x: 0.38, y: 0.64, style: .filledCircle),
                .init(x: 0.54, y: 0.46, style: .verticalCut),
                .init(x: 0.7, y: 0.62, style: .filledCircle),
                .init(x: 0.9, y: 0.8, style: .openCircle)
            ]

        case .flare3:
            return [
                .init(x: 0.08, y: 0.8, style: .openCircle),
                .init(x: 0.22, y: 0.58, style: .filledCircle),
                .init(x: 0.34, y: 0.46, style: .filledCircle),
                .init(x: 0.46, y: 0.58, style: .filledCircle),
                .init(x: 0.62, y: 0.7, style: .filledCircle),
                .init(x: 0.74, y: 0.52, style: .filledCircle),
                .init(x: 0.86, y: 0.64, style: .filledCircle),
                .init(x: 0.92, y: 0.8, style: .openCircle)
            ]

        case .crabDerived:
            return [
                .init(x: 0.18, y: 0.74, style: .verticalCut),
                .init(x: 0.34, y: 0.54, style: .filledCircle),
                .init(x: 0.5, y: 0.36, style: .filledCircle),
                .init(x: 0.66, y: 0.54, style: .filledCircle),
                .init(x: 0.82, y: 0.74, style: .verticalCut)
            ]

        case .transform:
            return [
                .init(x: 0.18, y: 0.6, style: .verticalCut),
                .init(x: 0.48, y: 0.28, style: .verticalCut),
                .init(x: 0.74, y: 0.58, style: .verticalCut)
            ]

        case .stab, .autobahnDerived:
            return [
                .init(x: 0.18, y: 0.54, style: .verticalCut),
                .init(x: 0.34, y: 0.54, style: .verticalCut),
                .init(x: 0.5, y: 0.54, style: .verticalCut)
            ]

        default:
            return []
        }
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    private static func polyline(in rect: CGRect, points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.0, first.1, in: rect))
        for pointValue in points.dropFirst() {
            path.addLine(to: point(pointValue.0, pointValue.1, in: rect))
        }
        return path
    }

    private static func sineWave(
        in rect: CGRect,
        xRange: ClosedRange<CGFloat>,
        baseline: CGFloat,
        amplitude: CGFloat,
        cycles: CGFloat
    ) -> Path {
        var path = Path()
        let samples = max(24, Int(cycles * 28))
        for sample in 0...samples {
            let t = CGFloat(sample) / CGFloat(samples)
            let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * t
            let y = baseline + sin(t * cycles * 2 * .pi) * amplitude
            let resolved = point(x, y, in: rect)
            if sample == 0 {
                path.move(to: resolved)
            } else {
                path.addLine(to: resolved)
            }
        }
        return path
    }
}

#if DEBUG
struct FormulaPlaygroundView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            FormulaPlaygroundView()
        }
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
    }
}
#endif
