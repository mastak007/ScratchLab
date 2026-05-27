import Foundation

// MARK: - SpatialPoint

/// A 3D point in the spatial-replay coordinate system. Pure value
/// type; no `simd` import so the projection module stays free of
/// platform-specific math kernels and visionOS / iOS / macOS render
/// surfaces can lift these points into their preferred vector types.
struct SpatialPoint: Equatable, Sendable, Codable {
    let x: Double
    let y: Double
    let z: Double
}

// MARK: - SpatialRibbonSegment

/// One stroke of the notation lane lifted into a 3D ribbon segment.
///
/// **Visual grammar (Phase D-S non-negotiable):**
/// - `kind == .audioOnset` → renderer draws solid geometry.
/// - `kind == .classifierDerived` → renderer draws dashed / translucent.
/// - `coachingKinds` are passed through unchanged so the consumer can
///   apply `CoachingEventDisplayability` tiering identically to the 2D
///   surface (no forked honesty grammar).
struct SpatialRibbonSegment: Equatable, Sendable, Codable {

    enum Kind: String, Equatable, Sendable, Codable {
        case audioOnset
        case classifierDerived
    }

    let primitiveIndex: Int
    let start: SpatialPoint
    let end: SpatialPoint
    let kind: Kind
    let coachingKinds: [CoachingEventKind]
}

// MARK: - SpatialOnsetMarker

/// A point-in-time audio-onset marker rendered as a solid sphere.
struct SpatialOnsetMarker: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let position: SpatialPoint
}

// MARK: - SpatialPlayheadGeometry

/// Optional 3D playhead matching the 2D playhead's parametric
/// position. `isWithinViewport == false` mirrors the 2D dim-state so
/// renderers can fade the geometry identically.
struct SpatialPlayheadGeometry: Equatable, Sendable, Codable {
    let position: SpatialPoint
    let height: Double
    let isWithinViewport: Bool
}

// MARK: - SpatialReplayProjection

/// Renderer-ready 3D geometry for a single replay frame. Carries the
/// ribbon, audio-onset markers, classifier-derived (dashed) markers
/// pre-split out of the ribbon's `Kind` so a renderer can iterate
/// just the markers it wants, and the optional playhead.
///
/// **Pure value type.** No `simd`, no ARKit, no RealityKit, no
/// AVFoundation, no Combine, no UIKit, no SwiftUI. The Phase D-S
/// AR-prep contract: this projection is the same on iOS, macOS, and
/// visionOS so consumer renderers do not fork.
struct SpatialReplayProjection: Equatable, Sendable, Codable {
    let ribbon: [SpatialRibbonSegment]
    let audioOnsets: [SpatialOnsetMarker]
    let classifierDerivedMarkers: [SpatialOnsetMarker]
    let playhead: SpatialPlayheadGeometry?
    let ribbonLength: Double
    let ribbonHeight: Double
    let ribbonDepth: Double
}

// MARK: - SpatialReplayProjector

/// Pure, deterministic mapper from a 2D `NotationReplayProjection`
/// (per-frame lane + gridline + playhead geometry) to a 3D
/// `SpatialReplayProjection`.
///
/// **Coordinate system:**
/// - X: viewport pixel space (unchanged from 2D).
/// - Y: vertical lane height (unchanged from 2D).
/// - Z: depth coefficient — `0` for audio-onset strokes (solid line
///   stays on the plane) and `depth` for classifier-derived strokes
///   (dashed segments float forward by the configured depth so the
///   renderer can distinguish them spatially as well as visually).
///
/// **Solid vs dashed split:** strokes whose `family == nil` are
/// treated as audio-onset (solid). Strokes with a `family` are
/// treated as classifier-derived (dashed translucent). This mirrors
/// the Phase B honesty grammar verbatim — audio-onset is the only
/// signal we are willing to draw solid; everything that flowed
/// through the family classifier is dashed.
///
/// Same input + same depth → byte-identical output across calls.
enum SpatialReplayProjector {

    /// Vertical-height boost applied to the 3D ribbon relative to the
    /// 2D viewport height. The default makes the ribbon read as a
    /// gentle arc in front of the platter without dominating the
    /// scene.
    static let defaultHeightCoefficient: Double = 1.0

    /// Forward-depth offset (along +Z) applied to classifier-derived
    /// strokes. Audio-onset strokes stay at depth `0` so the honest
    /// signal sits closest to the user.
    static let defaultClassifierDepth: Double = 0.06

    static func project(
        _ replay: NotationReplayProjection,
        depth: Double = SpatialReplayProjector.defaultClassifierDepth,
        heightCoefficient: Double = SpatialReplayProjector.defaultHeightCoefficient
    ) -> SpatialReplayProjection {
        let safeDepth = depth.isFinite && depth >= 0 ? depth : 0
        let safeHeight = heightCoefficient.isFinite && heightCoefficient > 0
            ? heightCoefficient
            : 1.0
        let length = replay.viewport.width
        let height = replay.viewport.height * safeHeight

        var ribbon: [SpatialRibbonSegment] = []
        ribbon.reserveCapacity(replay.laneGeometry.strokes.count)
        var onsets: [SpatialOnsetMarker] = []
        var classifierMarkers: [SpatialOnsetMarker] = []
        for stroke in replay.laneGeometry.strokes {
            let isClassifierDerived = stroke.family != nil
            let z: Double = isClassifierDerived ? safeDepth : 0
            let kind: SpatialRibbonSegment.Kind = isClassifierDerived
                ? .classifierDerived
                : .audioOnset
            let start = SpatialPoint(
                x: stroke.xStart,
                y: stroke.yStart * safeHeight,
                z: z
            )
            let end = SpatialPoint(
                x: stroke.xEnd,
                y: stroke.yEnd * safeHeight,
                z: z
            )
            ribbon.append(
                SpatialRibbonSegment(
                    primitiveIndex: stroke.primitiveIndex,
                    start: start, end: end,
                    kind: kind,
                    coachingKinds: stroke.coachingKinds
                )
            )
            // Point-in-time markers: when start == end the stroke is a
            // zero-duration tick. Surface those as markers so the
            // renderer can paint solid spheres (audio onset) or
            // dashed indicators (classifier-derived) at exactly that
            // point.
            if stroke.xStart == stroke.xEnd, stroke.yStart == stroke.yEnd {
                let marker = SpatialOnsetMarker(
                    primitiveIndex: stroke.primitiveIndex,
                    position: start
                )
                if isClassifierDerived {
                    classifierMarkers.append(marker)
                } else {
                    onsets.append(marker)
                }
            }
        }

        let playhead = replay.playhead.map { ph in
            SpatialPlayheadGeometry(
                position: SpatialPoint(x: ph.x, y: ph.yTop * safeHeight, z: 0),
                height: (ph.yBottom - ph.yTop) * safeHeight,
                isWithinViewport: ph.isWithinViewport
            )
        }

        return SpatialReplayProjection(
            ribbon: ribbon,
            audioOnsets: onsets,
            classifierDerivedMarkers: classifierMarkers,
            playhead: playhead,
            ribbonLength: length,
            ribbonHeight: height,
            ribbonDepth: safeDepth
        )
    }
}
