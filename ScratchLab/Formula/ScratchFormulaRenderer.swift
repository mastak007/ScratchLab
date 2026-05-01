// ScratchFormulaRenderer.swift
// ScratchLab
// Converts parsed formula AST into timeline events for app-specific playback.

import Foundation

struct ScratchRenderEvent: Equatable, Codable {
    let scratchID: String
    let startBeat: Double
    let durationBeats: Double
    let direction: ScratchDirection
}

struct ScratchRenderTimeline: Equatable, Codable {
    let events: [ScratchRenderEvent]
    let totalBeats: Double
}

enum ScratchFormulaRenderError: Error, LocalizedError {
    case unknownSymbol(String)
    case scalarStandalone(Double)
    case invalidRepeat(Double)
    case invalidScale(Double)

    var errorDescription: String? {
        switch self {
        case .unknownSymbol(let symbol):
            return "Unknown scratch symbol '\(symbol)'."
        case .scalarStandalone(let value):
            return "Scalar \(value) cannot stand alone in a formula."
        case .invalidRepeat(let value):
            return "Repeat value must be a positive whole number, got \(value)."
        case .invalidScale(let value):
            return "Scale value must be > 0, got \(value)."
        }
    }
}

private struct RenderFragment {
    var events: [ScratchRenderEvent]
    var beats: Double
}

struct ScratchFormulaRenderer {
    private let parser = ScratchFormulaParser()

    func render(formula: String, catalog: ScratchFormulaCatalog = .mvp) throws -> ScratchRenderTimeline {
        let ast = try parser.parse(formula)
        return try render(ast: ast, catalog: catalog)
    }

    func render(ast: ScratchFormulaAST, catalog: ScratchFormulaCatalog = .mvp) throws -> ScratchRenderTimeline {
        let fragment = try buildFragment(for: ast.root, catalog: catalog)
        return ScratchRenderTimeline(events: fragment.events, totalBeats: fragment.beats)
    }

    private func buildFragment(for node: ScratchFormulaNode, catalog: ScratchFormulaCatalog) throws -> RenderFragment {
        switch node {
        case .symbol(let symbol):
            guard let entry = catalog.resolve(symbol) else {
                throw ScratchFormulaRenderError.unknownSymbol(symbol)
            }
            return RenderFragment(
                events: [.init(
                    scratchID: entry.id,
                    startBeat: 0,
                    durationBeats: entry.defaultBeats,
                    direction: .forward
                )],
                beats: entry.defaultBeats
            )

        case .scalar(let value):
            throw ScratchFormulaRenderError.scalarStandalone(value)

        case .unary(let op, let child):
            var fragment = try buildFragment(for: child, catalog: catalog)
            if op == .reverse {
                fragment.events = fragment.events.map { event in
                    ScratchRenderEvent(
                        scratchID: event.scratchID,
                        startBeat: event.startBeat,
                        durationBeats: event.durationBeats,
                        direction: event.direction == .forward ? .reverse : .forward
                    )
                }
            }
            return fragment

        case .binary(let op, let lhs, let rhs):
            switch op {
            case .chain:
                let left = try buildFragment(for: lhs, catalog: catalog)
                let right = try buildFragment(for: rhs, catalog: catalog)
                let shiftedRight = right.events.map { event in
                    ScratchRenderEvent(
                        scratchID: event.scratchID,
                        startBeat: event.startBeat + left.beats,
                        durationBeats: event.durationBeats,
                        direction: event.direction
                    )
                }
                return RenderFragment(events: left.events + shiftedRight, beats: left.beats + right.beats)

            case .repeatCount:
                let left = try buildFragment(for: lhs, catalog: catalog)
                guard case .scalar(let scalarValue) = rhs else {
                    throw ScratchFormulaRenderError.invalidRepeat(-1)
                }
                guard scalarValue > 0, scalarValue.rounded() == scalarValue else {
                    throw ScratchFormulaRenderError.invalidRepeat(scalarValue)
                }

                let repeatCount = Int(scalarValue)
                var events: [ScratchRenderEvent] = []
                events.reserveCapacity(left.events.count * repeatCount)

                for i in 0..<repeatCount {
                    let offset = Double(i) * left.beats
                    events.append(contentsOf: left.events.map { event in
                        ScratchRenderEvent(
                            scratchID: event.scratchID,
                            startBeat: event.startBeat + offset,
                            durationBeats: event.durationBeats,
                            direction: event.direction
                        )
                    })
                }

                return RenderFragment(events: events, beats: left.beats * Double(repeatCount))

            case .stretch:
                let left = try buildFragment(for: lhs, catalog: catalog)
                guard case .scalar(let scalarValue) = rhs else {
                    throw ScratchFormulaRenderError.invalidScale(-1)
                }
                guard scalarValue > 0 else {
                    throw ScratchFormulaRenderError.invalidScale(scalarValue)
                }

                let scaledEvents = left.events.map { event in
                    ScratchRenderEvent(
                        scratchID: event.scratchID,
                        startBeat: event.startBeat / scalarValue,
                        durationBeats: event.durationBeats / scalarValue,
                        direction: event.direction
                    )
                }
                return RenderFragment(events: scaledEvents, beats: left.beats / scalarValue)
            }
        }
    }
}
