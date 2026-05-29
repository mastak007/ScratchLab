//  ScratchNotationSmoothPath.swift
//  ScratchLab — rounded-curve path builder for notation traces.
//
//  Pure, deterministic geometry helper. Converts an ordered list of
//  polyline knots into one SwiftUI `Path` that passes THROUGH every
//  knot, using a centripetal Catmull-Rom spline expressed as cubic
//  Bézier segments.
//
//  Centripetal parameterisation (alpha = 0.5) is chosen deliberately:
//  Baby Scratch traces reverse sharply at every hump apex, and the
//  uniform / chordal Catmull-Rom variants overshoot and form cusps or
//  self-intersections at those reversals. The centripetal variant
//  stays local and loop-free, so the rounded humps read as scratch
//  motion rather than as ringing artefacts.
//
//  Presentation-only: the helper knows nothing about audio time,
//  phrases, or direction. Callers map their vertices to screen points
//  first, then hand the points here. Every OFF-curve control point's Y
//  is clamped into `clampY`, so the rounded curve can never bulge above
//  the lane's top or below its baseline (a cubic Bézier is bounded by
//  the convex hull of its four control points; the two on-curve knots
//  are assumed already inside `clampY`, so clamping the two control
//  points keeps the whole curve inside the band). On-curve knots are
//  emitted unchanged so the curve still interpolates the data exactly.
//
//  Degenerate inputs are safe: 0 points → empty path, 1 point → a
//  degenerate move, 2 points → a straight line (no curvature to round).

import SwiftUI

enum ScratchNotationSmoothPath {

    /// Builds a smoothed, knot-interpolating `Path` through `points`.
    /// Same input → byte-identical output (`Path` is `Equatable`). No
    /// clock, no I/O, no UI state.
    static func path(
        through points: [CGPoint],
        clampY: ClosedRange<CGFloat>
    ) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        guard points.count > 1 else {
            // Single point: degenerate path (a move with no line).
            path.move(to: first)
            return path
        }
        guard points.count > 2 else {
            // Two points: straight line — there is no interior knot to
            // curve around.
            path.move(to: points[0])
            path.addLine(to: points[1])
            return path
        }

        let n = points.count
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            // Endpoint duplication at the boundaries gives the first
            // and last segments a sensible tangent without a phantom
            // control knot.
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, n - 1)]

            // Centripetal knot spacing: tⱼ = tᵢ + |pⱼ − pᵢ|^0.5. The
            // epsilon floor keeps coincident knots from dividing by
            // zero and degrades that segment gracefully toward a line.
            let t0: CGFloat = 0
            let t1 = t0 + knotDelta(p0, p1)
            let t2 = t1 + knotDelta(p1, p2)
            let t3 = t2 + knotDelta(p2, p3)

            // Tangents at p1 and p2 (Barry–Goldman form for non-uniform
            // Catmull-Rom).
            let tan1 = add(
                sub(
                    divide(sub(p1, p0), t1 - t0),
                    divide(sub(p2, p0), t2 - t0)
                ),
                divide(sub(p2, p1), t2 - t1)
            )
            let tan2 = add(
                sub(
                    divide(sub(p2, p1), t2 - t1),
                    divide(sub(p3, p1), t3 - t1)
                ),
                divide(sub(p3, p2), t3 - t2)
            )

            let segment = (t2 - t1) / 3
            var c1 = add(p1, scale(tan1, segment))
            var c2 = sub(p2, scale(tan2, segment))

            // Clamp only the OFF-curve control points; the on-curve
            // knots (p1, p2) must stay exact so the curve interpolates.
            c1.y = min(max(c1.y, clampY.lowerBound), clampY.upperBound)
            c2.y = min(max(c2.y, clampY.lowerBound), clampY.upperBound)

            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// |pⱼ − pᵢ|^0.5 with a small floor so coincident knots never
    /// produce a zero denominator downstream.
    private static func knotDelta(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = (dx * dx + dy * dy).squareRoot()
        return max(distance.squareRoot(), 1e-6)
    }
}

// MARK: - CGPoint vector helpers (file-private)

private func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

private func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

private func scale(_ a: CGPoint, _ s: CGFloat) -> CGPoint {
    CGPoint(x: a.x * s, y: a.y * s)
}

private func divide(_ a: CGPoint, _ s: CGFloat) -> CGPoint {
    CGPoint(x: a.x / s, y: a.y / s)
}
