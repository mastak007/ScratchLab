import XCTest
import SwiftUI
@testable import ScratchLab

/// Locks the contract of `ScratchNotationSmoothPath.path(through:clampY:)`:
/// a pure, deterministic centripetal Catmull-Rom → cubic Bézier path
/// that interpolates every input knot, degrades safely on tiny inputs,
/// keeps every off-curve control point inside `clampY`, and leaves
/// collinear input straight.
final class ScratchNotationSmoothPathTests: XCTestCase {

    private let band: ClosedRange<CGFloat> = 0...100

    // MARK: - Element extraction helpers

    /// On-curve points in order: the destination of every `move`,
    /// `line`, `curve`, and `quadCurve` element.
    private func onCurvePoints(_ path: Path) -> [CGPoint] {
        var pts: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let to):                pts.append(to)
            case .line(let to):                pts.append(to)
            case .quadCurve(let to, _):        pts.append(to)
            case .curve(let to, _, _):         pts.append(to)
            case .closeSubpath:                break
            }
        }
        return pts
    }

    /// Every off-curve control point produced by `curve` / `quadCurve`.
    private func controlPoints(_ path: Path) -> [CGPoint] {
        var pts: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .quadCurve(_, let c):         pts.append(c)
            case .curve(_, let c1, let c2):    pts.append(c1); pts.append(c2)
            case .move, .line, .closeSubpath:  break
            }
        }
        return pts
    }

    private func assertPointsEqual(
        _ a: [CGPoint], _ b: [CGPoint], accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.count, b.count, "point count", file: file, line: line)
        for (lhs, rhs) in zip(a, b) {
            XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        }
    }

    // MARK: - Passes through all knots

    func testPassesThroughAllKnots() {
        let knots = [
            CGPoint(x: 0, y: 50),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 20, y: 70),
            CGPoint(x: 30, y: 30),
            CGPoint(x: 40, y: 60),
        ]
        let path = ScratchNotationSmoothPath.path(through: knots, clampY: band)
        // The on-curve points (move + each curve destination) must be
        // exactly the input knots, in order.
        assertPointsEqual(onCurvePoints(path), knots)
    }

    // MARK: - Degenerate inputs

    func testEmptyInputProducesEmptyPath() {
        let path = ScratchNotationSmoothPath.path(through: [], clampY: band)
        XCTAssertTrue(path.isEmpty)
        XCTAssertTrue(onCurvePoints(path).isEmpty)
    }

    func testSinglePointIsDegenerateMove() {
        let p = CGPoint(x: 5, y: 42)
        let path = ScratchNotationSmoothPath.path(through: [p], clampY: band)
        assertPointsEqual(onCurvePoints(path), [p])
        // A lone move has no curve/line elements.
        XCTAssertTrue(controlPoints(path).isEmpty)
    }

    func testTwoPointsAreStraightLine() {
        let a = CGPoint(x: 0, y: 10)
        let b = CGPoint(x: 30, y: 90)
        let path = ScratchNotationSmoothPath.path(through: [a, b], clampY: band)
        // Exactly a move + a line, no curves.
        assertPointsEqual(onCurvePoints(path), [a, b])
        XCTAssertTrue(controlPoints(path).isEmpty, "two points must not curve")
    }

    // MARK: - Clamp

    func testNoControlPointOutsideClampY() {
        // Knots near the band edges with sharp reversals — the natural
        // place for a Catmull-Rom curve to overshoot.
        let knots = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 100),
            CGPoint(x: 20, y: 0),
            CGPoint(x: 30, y: 100),
            CGPoint(x: 40, y: 0),
        ]
        let path = ScratchNotationSmoothPath.path(through: knots, clampY: band)
        for c in controlPoints(path) {
            XCTAssertGreaterThanOrEqual(c.y, band.lowerBound, "control y below band")
            XCTAssertLessThanOrEqual(c.y, band.upperBound, "control y above band")
        }
    }

    // MARK: - Collinear stays straight

    func testCollinearInputRemainsStraight() {
        // Points on the line y = 2x + 5. A correct interpolating spline
        // through collinear knots stays on that line, so every control
        // point must also satisfy the line equation.
        func lineY(_ x: CGFloat) -> CGFloat { 2 * x + 5 }
        let knots = (0...4).map { i -> CGPoint in
            let x = CGFloat(i) * 10
            return CGPoint(x: x, y: lineY(x))
        }
        let wideBand: ClosedRange<CGFloat> = 0...1000
        let path = ScratchNotationSmoothPath.path(through: knots, clampY: wideBand)
        for c in controlPoints(path) {
            XCTAssertEqual(c.y, lineY(c.x), accuracy: 1e-4,
                           "control point left the straight line")
        }
    }

    // MARK: - Determinism

    func testDeterministicOutput() {
        let knots = [
            CGPoint(x: 0, y: 12),
            CGPoint(x: 7, y: 88),
            CGPoint(x: 19, y: 33),
            CGPoint(x: 41, y: 71),
        ]
        let a = ScratchNotationSmoothPath.path(through: knots, clampY: band)
        let b = ScratchNotationSmoothPath.path(through: knots, clampY: band)
        XCTAssertEqual(a, b)
    }
}
