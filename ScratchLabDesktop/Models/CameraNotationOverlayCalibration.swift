import Foundation
import CoreGraphics

/// Observable calibration state for the manual camera passthrough overlay.
///
/// Holds a normalised platter centre (`0…1` in each axis, relative to the
/// camera preview viewport) and a normalised radius (`0…1`, fraction of the
/// shorter viewport dimension) along with a lock toggle and reset action.
///
/// This is a standalone `ObservableObject` — the camera passthrough view owns
/// it via `@StateObject` so it survives SwiftUI body rebuilds.
///
/// No ARKit, no Vision tracking, no automatic detection.  The user manually
/// taps the platter centre and drags a slider for radius.
final class CameraNotationOverlayCalibration: ObservableObject {

    // MARK: - Published state

    /// Normalised platter centre (each axis `0…1` relative to the camera
    /// preview viewport).  `(0.5, 0.5)` is the viewport centre.
    @Published var platterCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// Normalised platter radius expressed as a fraction of the shorter
    /// viewport dimension.  Default `0.35` gives a visible circle that
    /// occupies ~70 % of the shorter axis.
    @Published var platterRadius: CGFloat = 0.35

    /// When `true`, tap-to-set-centre and the radius slider are disabled.
    @Published var isLocked: Bool = false

    // MARK: - Clamped accessors

    /// Platter centre clamped to `[0, 1]` on each axis.
    var clampedCenter: CGPoint {
        CGPoint(
            x: min(1.0, max(0.0, platterCenter.x)),
            y: min(1.0, max(0.0, platterCenter.y))
        )
    }

    /// Platter radius clamped to `[0.05, 0.5]` so it never vanishes or
    /// exceeds half the viewport.
    var clampedRadius: CGFloat {
        min(0.5, max(0.05, platterRadius))
    }

    /// Validated radius suitable for the slider range.
    static let radiusRange: ClosedRange<CGFloat> = 0.05 ... 0.50

    // MARK: - Actions

    /// Set the platter centre from a tap point in view coordinates.
    ///
    /// - Parameter point:  the tap location in the viewʼs own coordinate space.
    /// - Parameter viewSize: the current size of the camera preview view.
    func setCenter(from point: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let normalised = CGPoint(
            x: point.x / viewSize.width,
            y: point.y / viewSize.height
        )
        platterCenter = CGPoint(
            x: min(1.0, max(0.0, normalised.x)),
            y: min(1.0, max(0.0, normalised.y))
        )
    }

    /// Reset calibration to sensible defaults and unlock.
    func reset() {
        platterCenter = CGPoint(x: 0.5, y: 0.5)
        platterRadius = 0.35
        isLocked = false
    }
}
