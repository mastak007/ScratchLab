import Foundation

// MARK: - TimecodePlatterAdapter

/// Maps decoded timecode motion frames into the existing platter position
/// timeline path.
///
/// The adapter takes a `TimecodeDecodeResult` and produces a
/// `PlatterPositionTimeline` with `.timecodeFixture` or `.timecodeLive`
/// source (configurable at init), suitable for consumption by the existing
/// `ScratchMotionLane` renderer and notation pipeline — no second scratch
/// engine required.
///
/// ## Processing
///
/// 1. Filter frames by minimum confidence.
/// 2. Clamp velocity to a configurable maximum rate.
/// 3. Integrate delta positions into cumulative platter-axis displacement.
/// 4. Wrap in `PlatterPositionTimeline` with the configured source.
///
/// **Batch 2:** Prototype / fixture-driven only. Returns `nil` when the
/// decode result contains no trusted frames.
/// **Batch 3:** Also used by `TimecodeControlPipeline` with `.timecodeLive`
/// source for the prototype control path.
///
/// Access is internal — consumed via `@testable import ScratchLab` in tests.
/// The return type `PlatterPositionTimeline` is internal, so public methods
/// on this adapter would be rejected by the compiler.
struct TimecodePlatterAdapter: Sendable {

    // MARK: - Configuration

    /// Minimum confidence for a decoded frame to be included in the output
    /// timeline. Frames below this threshold are dropped.
    let minConfidence: Double

    /// Maximum absolute velocity allowed in position-units per second.
    /// Velocities whose absolute value exceeds this are clamped. This
    /// prevents a single bad decode from producing an extreme position jump.
    let maxRate: Double

    /// Label written into the output `PlatterPositionTimeline.Source`.
    /// Defaults to `.timecodeFixture`.
    let source: PlatterPositionTimeline.Source

    // MARK: - Init

    init(
        minConfidence: Double = 0.5,
        maxRate: Double = 5.0,
        source: PlatterPositionTimeline.Source = .timecodeFixture
    ) {
        self.minConfidence = minConfidence
        self.maxRate = maxRate
        self.source = source
    }

    // MARK: - Adapt

    /// Convert a decode result into a platter position timeline.
    ///
    /// - Parameters:
    ///   - result: The output from `TimecodePhaseDecoder.decode(_:)`.
    ///   - startingPosition: Position carried from the prior decode window.
    ///     Defaults to zero for standalone/fixture adaptation.
    /// - Returns: A `PlatterPositionTimeline` with `.timecodeFixture` source,
    ///   or `nil` if no frames survived confidence filtering.
    func adapt(
        _ result: TimecodeDecodeResult,
        startingPosition: Double = 0
    ) -> PlatterPositionTimeline? {
        // Filter by confidence
        let trusted = result.frames.filter { $0.confidence >= minConfidence }

        guard !trusted.isEmpty else { return nil }

        // Clamp velocity and integrate position
        var cumulativePosition = startingPosition
        var samples: [PlatterPositionSample] = []
        var previousTime: TimeInterval?

        for frame in result.frames {
            if frame.confidence < minConfidence {
                continue
            }

            let deltaPosition: Double
            if let prevTime = previousTime {
                let dt = frame.relativeTime - prevTime
                if dt > 0 {
                    // Compute effective rate and clamp if needed
                    let effectiveRate = abs(frame.deltaPosition) / dt
                    if effectiveRate > maxRate {
                        // Clamp: preserve sign, cap magnitude to maxRate * dt
                        let sign = frame.deltaPosition >= 0 ? 1.0 : -1.0
                        deltaPosition = sign * maxRate * dt
                    } else {
                        deltaPosition = frame.deltaPosition
                    }
                } else {
                    deltaPosition = frame.deltaPosition
                }
            } else {
                deltaPosition = frame.deltaPosition
            }

            cumulativePosition += deltaPosition
            previousTime = frame.relativeTime

            let sample = PlatterPositionSample(
                time: frame.relativeTime,
                position: cumulativePosition,
                confidence: frame.confidence
            )
            samples.append(sample)
        }

        guard !samples.isEmpty else { return nil }

        guard let startTime = samples.first?.time,
              let endTime = samples.last?.time,
              let timeline = PlatterPositionTimeline(
                source: source,
                startTime: startTime,
                endTime: endTime,
                samples: samples
              ) else {
            return nil
        }

        return timeline
    }
}
