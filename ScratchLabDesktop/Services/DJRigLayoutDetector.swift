import Foundation
import Vision
import CoreMedia
import CoreGraphics
import QuartzCore

struct DJRigZone: Identifiable, Equatable {
    enum Role: String, CaseIterable, Identifiable {
        case leftDeck
        case mixer
        case rightDeck

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leftDeck: return "Left Deck"
            case .mixer: return "Mixer"
            case .rightDeck: return "Right Deck"
            }
        }
    }

    let role: Role
    let boundingBox: CGRect

    var id: Role { role }

    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
}

struct DJRigZoneTuning: Equatable {
    let mixerShare: CGFloat
    let deckHorizontalInset: CGFloat
    let mixerHorizontalInset: CGFloat
    let verticalInset: CGFloat

    static let standard = DJRigZoneTuning(
        mixerShare: 0.20,
        deckHorizontalInset: 0.010,
        mixerHorizontalInset: 0.008,
        verticalInset: 0.010
    )

    static let deskView = DJRigZoneTuning(
        mixerShare: 0.17,
        deckHorizontalInset: 0.006,
        mixerHorizontalInset: 0.004,
        verticalInset: 0.008
    )

    func withMixerShare(_ mixerShare: CGFloat) -> DJRigZoneTuning {
        DJRigZoneTuning(
            mixerShare: min(max(mixerShare, 0.12), 0.30),
            deckHorizontalInset: deckHorizontalInset,
            mixerHorizontalInset: mixerHorizontalInset,
            verticalInset: verticalInset
        )
    }
}

struct DJRigLayout: Equatable {
    let zones: [DJRigZone]
    let confidence: Float

    var unionBox: CGRect {
        zones.reduce(.null) { partial, zone in
            partial.union(zone.boundingBox)
        }
    }

    func zone(for role: DJRigZone.Role) -> DJRigZone? {
        zones.first(where: { $0.role == role })
    }

    static func zones(in rect: CGRect, tuning: DJRigZoneTuning = .standard) -> [DJRigZone] {
        let roles = DJRigZone.Role.allCases
        let mixerWidth = rect.width * tuning.mixerShare
        let deckWidth = max((rect.width - mixerWidth) / 2, 0.08)
        let widths: [CGFloat] = [deckWidth, mixerWidth, deckWidth]
        var currentX = rect.minX

        return roles.enumerated().map { index, role in
            let zoneWidth = widths[index]
            let insetX = role == .mixer ? tuning.mixerHorizontalInset : tuning.deckHorizontalInset
            let zoneRect = CGRect(
                x: currentX,
                y: rect.minY,
                width: zoneWidth,
                height: rect.height
            ).insetBy(
                dx: min(max(insetX, 0), zoneWidth * 0.12),
                dy: min(max(tuning.verticalInset, 0), rect.height * 0.15)
            )

            currentX += zoneWidth
            return DJRigZone(role: role, boundingBox: zoneRect)
        }
    }
}

final class DJRigLayoutDetector {
    private let activeDetectionInterval: TimeInterval = 0.45
    private let lockedDetectionInterval: TimeInterval = 1.8
    private let activeStaleLayoutAllowance: TimeInterval = 1.4
    private let lockedStaleLayoutAllowance: TimeInterval = 4.0
    private let smoothingAlpha: CGFloat = 0.24
    private let smoothingDeadband: CGFloat = 0.012
    private let detectionBounds = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.90)
    private var lastDetectionTime: CFTimeInterval = 0
    private var lastSuccessfulLayoutTime: CFTimeInterval = 0
    private var cachedLayout: DJRigLayout?

    func reset() {
        lastDetectionTime = 0
        lastSuccessfulLayoutTime = 0
        cachedLayout = nil
    }

    func prioritizeNextDetection() {
        lastDetectionTime = 0
    }

    func detectLayout(in pixelBuffer: CVPixelBuffer, useLockedCadence: Bool = false) -> DJRigLayout? {
        let now = CACurrentMediaTime()
        let detectionInterval = resolvedDetectionInterval(useLockedCadence: useLockedCadence)
        let staleLayoutAllowance = resolvedStaleLayoutAllowance(useLockedCadence: useLockedCadence)
        guard now - lastDetectionTime >= detectionInterval else { return cachedLayout }
        lastDetectionTime = now

        let rectangles = detectRectangles(in: pixelBuffer)
        guard let detectedLayout = inferLayout(from: rectangles) else {
            if let cachedLayout, now - lastSuccessfulLayoutTime <= staleLayoutAllowance {
                return cachedLayout
            }
            cachedLayout = nil
            return nil
        }

        let stabilizedLayout = stabilizedLayout(from: detectedLayout)
        cachedLayout = stabilizedLayout
        lastSuccessfulLayoutTime = now
        return stabilizedLayout
    }

    private func resolvedDetectionInterval(useLockedCadence: Bool) -> TimeInterval {
        guard useLockedCadence, cachedLayout != nil else { return activeDetectionInterval }
        return lockedDetectionInterval
    }

    private func resolvedStaleLayoutAllowance(useLockedCadence: Bool) -> TimeInterval {
        guard useLockedCadence, cachedLayout != nil else { return activeStaleLayoutAllowance }
        return lockedStaleLayoutAllowance
    }

    private func detectRectangles(in pixelBuffer: CVPixelBuffer) -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 10
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 4.0
        request.minimumSize = 0.08
        request.minimumConfidence = 0.45
        request.quadratureTolerance = 25

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private func inferLayout(from rectangles: [VNRectangleObservation]) -> DJRigLayout? {
        let candidates = rectangles
            .filter { observation in
                observation.boundingBox.width > 0.12 &&
                observation.boundingBox.height > 0.08 &&
                observation.boundingBox.maxY < 0.95 &&
                observation.boundingBox.minY > 0.02
            }
            .sorted {
                ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
            }

        guard !candidates.isEmpty else { return nil }

        let unionBox: CGRect
        let confidence: Float

        if let rigBox = candidates.first(where: { $0.boundingBox.width > 0.58 && $0.boundingBox.height > 0.20 }) {
            unionBox = rigBox.boundingBox
            confidence = rigBox.confidence
        } else {
            let selected = Array(candidates.prefix(min(3, candidates.count)))
            unionBox = selected.reduce(.null) { partial, observation in
                partial.union(observation.boundingBox)
            }
            confidence = selected.map(\.confidence).reduce(0, +) / Float(max(1, selected.count))
        }

        guard !unionBox.isNull, unionBox.width > 0.36, unionBox.height > 0.16 else { return nil }

        let paddedBox = unionBox.insetBy(dx: -0.02, dy: -0.015)
            .intersection(detectionBounds)
        guard paddedBox.width > 0.30, paddedBox.height > 0.15 else { return nil }

        return DJRigLayout(zones: DJRigLayout.zones(in: paddedBox, tuning: .standard), confidence: confidence)
    }

    private func stabilizedLayout(from layout: DJRigLayout) -> DJRigLayout {
        guard let cachedLayout else { return layout }

        let previousUnion = cachedLayout.unionBox
        let currentUnion = layout.unionBox
        let deltas = [
            abs(currentUnion.minX - previousUnion.minX),
            abs(currentUnion.minY - previousUnion.minY),
            abs(currentUnion.width - previousUnion.width),
            abs(currentUnion.height - previousUnion.height)
        ]

        guard deltas.contains(where: { $0 >= smoothingDeadband }) else {
            return cachedLayout
        }

        let stabilizedUnion = CGRect(
            x: stabilizedValue(from: previousUnion.minX, to: currentUnion.minX),
            y: stabilizedValue(from: previousUnion.minY, to: currentUnion.minY),
            width: max(stabilizedValue(from: previousUnion.width, to: currentUnion.width), 0.30),
            height: max(stabilizedValue(from: previousUnion.height, to: currentUnion.height), 0.15)
        ).intersection(detectionBounds)

        guard stabilizedUnion.width > 0.30, stabilizedUnion.height > 0.15 else {
            return layout
        }

        let confidence = max(0, min(1, (cachedLayout.confidence * 0.35) + (layout.confidence * 0.65)))
        return DJRigLayout(
            zones: DJRigLayout.zones(in: stabilizedUnion, tuning: .standard),
            confidence: confidence
        )
    }

    private func stabilizedValue(from previous: CGFloat, to current: CGFloat) -> CGFloat {
        let delta = current - previous
        guard abs(delta) >= smoothingDeadband else { return previous }
        return previous + (delta * smoothingAlpha)
    }
}
