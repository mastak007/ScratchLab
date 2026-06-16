import Foundation
import CoreGraphics
import Combine

/// Observable calibration state for the manual camera passthrough overlay.
///
/// Holds a normalised platter centre (`0…1` in each axis, relative to the
/// camera preview viewport), a normalised radius (`0…1`, fraction of the
/// shorter viewport dimension), an optional angle offset (radians) that
/// rotates the whole notation projection, and a lock toggle.
///
/// Calibration is persisted to `UserDefaults` so it survives app sessions
/// and overlay close/reopen.  Values are clamped on load — invalid or
/// missing keys fall back to sensible defaults.
///
/// This is a standalone `ObservableObject` — the camera passthrough view owns
/// it via `@StateObject` so it survives SwiftUI body rebuilds.
///
/// No ARKit, no Vision tracking, no automatic detection.  The user manually
/// taps the platter centre and drags sliders for radius / angle.
final class CameraNotationOverlayCalibration: ObservableObject {

    // MARK: - UserDefaults keys

    private enum Key {
        static let centerX     = "scratchlab.mac.cameraOverlay.platterCenterX"
        static let centerY     = "scratchlab.mac.cameraOverlay.platterCenterY"
        static let radius      = "scratchlab.mac.cameraOverlay.platterRadius"
        static let angleOffset = "scratchlab.mac.cameraOverlay.angleOffset"
        static let isLocked    = "scratchlab.mac.cameraOverlay.isLocked"
    }

    // MARK: - Published state

    /// Normalised platter centre (each axis `0…1` relative to the camera
    /// preview viewport).  `(0.5, 0.5)` is the viewport centre.
    @Published var platterCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// Normalised platter radius expressed as a fraction of the shorter
    /// viewport dimension.  Default `0.35` gives a visible circle that
    /// occupies ~70 % of the shorter axis.
    @Published var platterRadius: CGFloat = 0.35

    /// Optional rotational offset for the notation start angle (radians).
    /// Positive rotates clockwise.  Default `0`.
    @Published var angleOffset: Double = 0.0

    /// When `true`, tap-to-set-centre, radius slider, angle slider, and
    /// the reset button are all disabled.
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

    /// Angle offset wrapped to `[-2π, 2π]` so sliders stay usable.
    /// The geometry layer normalises internally as needed.
    var clampedAngleOffset: Double {
        min(2 * .pi, max(-2 * .pi, angleOffset))
    }

    /// Validated radius suitable for the slider range.
    static let radiusRange: ClosedRange<CGFloat> = 0.05 ... 0.50

    /// Validated angle offset range suitable for the slider.
    static let angleOffsetRange: ClosedRange<Double> = -.pi ... .pi

    // MARK: - Combine plumbing

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        loadFromDefaults()
        // Persist whenever any calibration property changes.  Use
        // objectWillChange (which fires before @Published mutations) and
        // defer to the next main-queue tick so the property values have
        // landed before we read them.
        objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.saveToDefaults()
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard

        let loadedX = defaults.double(forKey: Key.centerX)
        let loadedY = defaults.double(forKey: Key.centerY)
        let loadedRadius = defaults.double(forKey: Key.radius)
        let loadedAngle = defaults.double(forKey: Key.angleOffset)

        // Only restore if keys exist (detect unset vs explicit 0 by checking
        // whether the key is registered).  UserDefaults.double(forKey:) returns 0
        // for missing keys, so we check explicitly.
        if defaults.object(forKey: Key.centerX) != nil {
            platterCenter.x = Self.safeCenterClamp(loadedX)
        }
        if defaults.object(forKey: Key.centerY) != nil {
            platterCenter.y = Self.safeCenterClamp(loadedY)
        }
        if defaults.object(forKey: Key.radius) != nil {
            platterRadius = Self.safeRadiusClamp(loadedRadius)
        }
        if defaults.object(forKey: Key.angleOffset) != nil {
            angleOffset = Self.safeAngleClamp(loadedAngle)
        }
        isLocked = defaults.bool(forKey: Key.isLocked)
    }

    private func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(platterCenter.x,  forKey: Key.centerX)
        defaults.set(platterCenter.y,  forKey: Key.centerY)
        defaults.set(platterRadius,    forKey: Key.radius)
        defaults.set(angleOffset,      forKey: Key.angleOffset)
        defaults.set(isLocked,         forKey: Key.isLocked)
    }

    /// Remove persisted calibration so the next init returns to defaults.
    func clearPersisted() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.centerX)
        defaults.removeObject(forKey: Key.centerY)
        defaults.removeObject(forKey: Key.radius)
        defaults.removeObject(forKey: Key.angleOffset)
        defaults.removeObject(forKey: Key.isLocked)
    }

    // MARK: - Safe clamping helpers (pure — testable without UserDefaults)

    static func safeCenterClamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    static func safeRadiusClamp(_ value: Double) -> Double {
        min(0.5, max(0.05, value))
    }

    static func safeAngleClamp(_ value: Double) -> Double {
        min(2 * .pi, max(-2 * .pi, value))
    }

    // MARK: - Actions

    /// Set the platter centre from a tap point in view coordinates.
    ///
    /// - Parameter point:  the tap location in the viewʼs own coordinate space.
    /// - Parameter viewSize: the current size of the camera preview view.
    ///
    /// No-op when `isLocked` is true (defense-in-depth; the view also guards).
    func setCenter(from point: CGPoint, viewSize: CGSize) {
        guard !isLocked else { return }
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

    /// Reset calibration to sensible defaults, unlock, and persist the reset.
    func reset() {
        platterCenter = CGPoint(x: 0.5, y: 0.5)
        platterRadius = 0.35
        angleOffset = 0.0
        isLocked = false
        // Persist the reset state immediately so a crash/close after reset
        // doesnʼt resurrect the old calibration.
        saveToDefaults()
    }
}
