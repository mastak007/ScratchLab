import Foundation

/// Pure, testable geometry helper for the camera passthrough notation overlay.
///
/// Converts normalised notation time (`0…1` fraction) and travel (`0…1` fraction)
/// into angular positions on a calibrated platter circle, then projects those
/// angles to view-space `CGPoint` values via the calibration centre and radius.
///
/// Direction distinguishes forward (clockwise) from backward (counter-clockwise)
/// arc sweep so strokes read correctly against the physical platter rotation.
///
/// This helper is stateless — it only transforms numbers.  It does not import
/// SwiftUI, AppKit, or Core Graphics (except `CGPoint`/`CGFloat`), so every
/// function can be exercised in pure XCTest unit tests.
enum CameraNotationOverlayGeometry {

    // MARK: - Angle mapping

    /// Map a normalised time fraction `[0, 1]` to a platter angle in radians.
    ///
    /// - Parameter timeFraction: `0…1` where `0` = phrase start, `1` = phrase end.
    /// - Parameter startAngle:   angle (radians) at `timeFraction == 0`.
    ///                           Default `-.pi / 2` places 0 at 12 oʼclock.
    /// - Parameter arcSweep:     total angular sweep (radians) for the full
    ///                           phrase.  Default `2 * .pi` = one full revolution.
    /// - Returns: angle in radians, unclamped (callers may wrap / normalise).
    static func angle(
        timeFraction: Double,
        startAngle: Double = -.pi / 2,
        arcSweep: Double = 2 * .pi
    ) -> Double {
        let clamped = min(1.0, max(0.0, timeFraction))
        return startAngle + clamped * arcSweep
    }

    // MARK: - Point projection

    /// Project an angle and travel fraction onto a point in the calibrated
    /// platter view-space.
    ///
    /// - Parameter angle:          platter angle in radians (0 = right, increasing
    ///                             counter-clockwise per standard trigonometry).
    /// - Parameter travelFraction: `0…1` — `0` sits on the platter centre,
    ///                             `1` sits at the full calibrated radius.
    /// - Parameter center:         platter centre in view coordinates.
    /// - Parameter radius:         maximum platter radius in view points.
    /// - Returns: the projected point.
    static func point(
        angle: Double,
        travelFraction: Double,
        center: CGPoint,
        radius: CGFloat
    ) -> CGPoint {
        let clampedTravel = min(1.0, max(0.0, travelFraction))
        let r = radius * CGFloat(clampedTravel)
        return CGPoint(
            x: center.x + r * CGFloat(cos(angle)),
            y: center.y + r * CGFloat(sin(angle))
        )
    }

    // MARK: - Arc stroke parameters

    /// Parameters for drawing one notation event as an arc segment on the
    /// calibrated platter.
    struct ArcStroke {
        /// Start angle of the arc (radians).
        let startAngle: Double
        /// End angle of the arc (radians).  May be less than `startAngle` for
        /// backward strokes.
        let endAngle: Double
        /// Radial distance from platter centre for this stroke.
        /// Proportional to the eventʼs `travelFraction`.
        let radius: CGFloat
        /// `true` when the stroke sweeps clockwise (forward).
        let isForward: Bool
    }

    /// Derive arc stroke parameters from a single captured record-movement event.
    ///
    /// - Parameter event:      the captured movement event.
    /// - Parameter duration:   total phrase / take span (seconds).  Must be > 0.
    /// - Parameter maxRadius:  the calibrated platter radius in view points.
    /// - Parameter startAngle: angle (radians) at `time == 0` on the platter.
    /// - Parameter arcSweep:   total angular sweep for the full phrase duration.
    /// - Returns: `ArcStroke` ready for drawing, or `nil` when the event has
    ///            zero travel (silence / idle guard).
    static func arcStroke(
        for event: CaptureCore.DetectedNotationRecordMovementEvent,
        duration: TimeInterval,
        maxRadius: CGFloat,
        startAngle: Double = -.pi / 2,
        arcSweep: Double = 2 * .pi
    ) -> ArcStroke? {
        guard duration > 0 else { return nil }
        let travel = CapturedNotationStrokeGeometry.travelFraction(for: event)
        guard travel > 0 else { return nil }   // silence / idle → no stroke

        let fractionStart = event.startTime / duration
        let fractionEnd   = event.endTime   / duration

        let aStart = angle(timeFraction: fractionStart, startAngle: startAngle, arcSweep: arcSweep)
        let aEnd   = angle(timeFraction: fractionEnd,   startAngle: startAngle, arcSweep: arcSweep)
        let isForward = event.direction == "forward"

        return ArcStroke(
            startAngle: aStart,
            endAngle: aEnd,
            radius: maxRadius * CGFloat(travel),
            isForward: isForward
        )
    }

    // MARK: - Convenience: events → arc strokes

    /// Convert the visible events from a `LiveNotationOverlayModel` into a
    /// flat list of `ArcStroke` values for the given `currentTime`.
    ///
    /// The modelʼs `.captured` mode future-note guard and its zero-travel
    /// silence suppression are both honoured — this function only projects
    /// strokes that the model declares visible.
    static func arcStrokes(
        from model: LiveNotationOverlayModel,
        currentTime: TimeInterval,
        maxRadius: CGFloat,
        startAngle: Double = -.pi / 2,
        arcSweep: Double = 2 * .pi
    ) -> [ArcStroke] {
        model.visibleEvents(at: currentTime).compactMap { event in
            arcStroke(
                for: event,
                duration: model.duration,
                maxRadius: maxRadius,
                startAngle: startAngle,
                arcSweep: arcSweep
            )
        }
    }
}
