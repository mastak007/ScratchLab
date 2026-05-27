#if DEBUG
import SwiftUI

// MARK: - DebugPhraseBoundaryMark

/// A single phrase's horizontal span, projected onto a lane viewport
/// in pixel space. Pure value type — Phase B AR-prep contract: no
/// SwiftUI-bound coordinate spaces in presentation models.
struct DebugPhraseBoundaryMark: Equatable, Sendable {
    let phraseIndex: Int
    let xStart: Double
    let xEndExclusive: Double
}

// MARK: - DebugDriftMark

/// A single drift coaching event, projected onto a lane viewport in
/// pixel space. Kind preserves the underlying `CoachingEventKind` so
/// downstream renderers can route to a semantic palette alias by name.
struct DebugDriftMark: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case early
        case late
    }

    let x: Double
    let kind: Kind
}

// MARK: - DebugSubstrateOverlayGeometry

/// Renderer-ready geometry for the DEBUG substrate visibility overlay
/// (Phase B0). Carries projected phrase boundaries and drift event
/// markers; no view, no clock, no Combine, no AVFoundation.
struct DebugSubstrateOverlayGeometry: Equatable, Sendable {
    let phraseBoundaries: [DebugPhraseBoundaryMark]
    let driftMarks: [DebugDriftMark]
}

// MARK: - DebugSubstrateOverlayMapper

/// Pure, deterministic projection of `[PhraseBoundary]` and
/// `[CoachingEvent]` onto a `NotationLaneViewport`, producing a
/// `DebugSubstrateOverlayGeometry`.
///
/// Same inputs → byte-identical output. The mapper consults only the
/// supplied grid for time projection of phrase boundaries; coaching
/// events use their already-finite `time` directly. Non-finite values
/// and out-of-viewport positions clamp to `[0, viewport.width]` like
/// `NotationLaneGeometryMapper`.
enum DebugSubstrateOverlayMapper {

    static func makeOverlay(
        boundaries: [PhraseBoundary],
        coachingEvents: [CoachingEvent],
        grid: TimingGrid,
        viewport: NotationLaneViewport
    ) -> DebugSubstrateOverlayGeometry {
        let span = viewport.endTime - viewport.startTime

        var phraseBoundaries: [DebugPhraseBoundaryMark] = []
        phraseBoundaries.reserveCapacity(boundaries.count)
        for boundary in boundaries {
            let startTime = grid.time(of: boundary.start)
            let endTime = grid.time(of: boundary.endExclusive)
            guard startTime.isFinite, endTime.isFinite else { continue }
            let xStart = mapX(time: startTime, viewport: viewport, span: span)
            let xEnd = mapX(time: endTime, viewport: viewport, span: span)
            phraseBoundaries.append(
                DebugPhraseBoundaryMark(
                    phraseIndex: boundary.phraseIndex,
                    xStart: xStart,
                    xEndExclusive: xEnd
                )
            )
        }

        var driftMarks: [DebugDriftMark] = []
        driftMarks.reserveCapacity(coachingEvents.count)
        for event in coachingEvents {
            let kind: DebugDriftMark.Kind
            switch event.kind {
            case .earlyReversal: kind = .early
            case .lateReversal:  kind = .late
            default: continue
            }
            guard event.time.isFinite else { continue }
            let x = mapX(time: event.time, viewport: viewport, span: span)
            driftMarks.append(DebugDriftMark(x: x, kind: kind))
        }

        return DebugSubstrateOverlayGeometry(
            phraseBoundaries: phraseBoundaries,
            driftMarks: driftMarks
        )
    }

    private static func mapX(
        time: TimeInterval,
        viewport: NotationLaneViewport,
        span: TimeInterval
    ) -> Double {
        guard span > 0 else { return 0 }
        let normalized = (time - viewport.startTime) / span
        let x = normalized * viewport.width
        return min(max(x, 0), viewport.width)
    }
}

// MARK: - DebugSubstrateOverlay

/// A DEBUG-only `Canvas` overlay that paints `PhraseBoundaryMapper`
/// outputs and `DriftCoachingEvaluator` markers on top of an existing
/// `NotationLaneGeometryView`. Released builds compile the entire file
/// out — there is no production caller, no flag, no user-facing copy.
///
/// **Style:** phrase boundaries draw as thin vertical cyan lines at
/// each phrase start; drift markers draw as small filled circles —
/// info-blue for early at the top rail, warning-amber for late at the
/// bottom rail. Colors come from `ScratchLabPalette` semantic aliases
/// so the Phase D-S spatial renderer can consume the same names.
struct DebugSubstrateOverlay: View {

    let overlay: DebugSubstrateOverlayGeometry

    var body: some View {
        Canvas { context, size in
            drawPhraseBoundaries(in: &context, size: size)
            drawDriftMarks(in: &context, size: size)
        }
        .allowsHitTesting(false)
    }

    private func drawPhraseBoundaries(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for boundary in overlay.phraseBoundaries {
            var path = Path()
            path.move(to: CGPoint(x: boundary.xStart, y: 0))
            path.addLine(to: CGPoint(x: boundary.xStart, y: size.height))
            context.stroke(
                path,
                with: .color(ScratchLabPalette.headingCyan.opacity(0.65)),
                lineWidth: 1.0
            )
        }
    }

    private func drawDriftMarks(
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let radius: Double = 3.5
        let yEarly = size.height * 0.12
        let yLate = size.height * 0.88
        for mark in overlay.driftMarks {
            let center: CGPoint
            let color: Color
            switch mark.kind {
            case .early:
                center = CGPoint(x: mark.x, y: yEarly)
                color = ScratchLabPalette.info.opacity(0.85)
            case .late:
                center = CGPoint(x: mark.x, y: yLate)
                color = ScratchLabPalette.warning.opacity(0.85)
            }
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }
}

#endif
