// ScratchLabCore — pure C++ notation/movement analysis core (Slice 1).
//
// Plain value types only. No Swift, no Objective-C++, no UI, no MIDI I/O, no audio
// playback, no third-party dependencies. This header declares the data shapes the
// offline analysis consumes and produces; logic lives in ScratchAnalysisCore.{hpp,cpp}.
//
// Naming: travel is measured in CC6 *steps per revolution* (`stepsPerRevolution`).
// The RANE 14-bit pitch-bend ticks are diagnostic-only elsewhere and never enter this
// core — travel percent is derived purely from signed CC6 steps.

#ifndef SCRATCHLAB_CORE_SCRATCH_NOTATION_TYPES_HPP
#define SCRATCHLAB_CORE_SCRATCH_NOTATION_TYPES_HPP

#include <vector>

namespace scratchlab {
namespace core {

/// Platter rotation direction for one stroke. forward = CC6 step > 0, reverse = CC6 step < 0.
enum class StrokeDirection {
    forward,
    reverse,
};

/// Whether a stroke was heard through the crossfader or cut to silence.
/// `unknown` is used when no crossfader telemetry was supplied: the core declines to
/// guess audibility rather than defaulting to audible, keeping downstream honesty.
enum class AudibleState {
    unknown,
    audible,
    cut,
};

/// Non-fatal advisories surfaced alongside results. Each kind is reported at most once.
enum class ScratchWarning {
    emptyInput,         ///< No platter events supplied; no strokes produced.
    invalidCalibration, ///< stepsPerRevolution <= 0 or non-finite; no strokes produced.
    nonUnitStep,        ///< A platter event carried |cc6Step| != 1 (still used by magnitude).
};

/// A single platter movement event. `cc6Step` is the signed CC6 ring step (normally +-1;
/// forward = positive, reverse = negative). `timeSeconds` is seconds from capture start.
struct PlatterEvent {
    double timeSeconds;
    int cc6Step;
};

/// A crossfader position sample, normalized 0...1 (0 = fully cut, 1 = fully open).
struct CrossfaderEvent {
    double timeSeconds;
    double value;
};

/// Calibration for converting CC6 steps into travel percent.
struct Calibration {
    double stepsPerRevolution; ///< CC6 steps per physical platter revolution (e.g. 3932).
    double crossfaderCutWidth; ///< Open threshold: a sample >= this (0...1) is audible.
};

/// One segmented stroke: a run of same-direction platter movement.
struct Stroke {
    StrokeDirection direction;
    double startTime;     ///< First contributing event time in the group.
    double endTime;       ///< Last contributing event time in the group.
    double travelPercent; ///< abs(sum of cc6Step) / stepsPerRevolution * 100.
    AudibleState audibleState;
};

/// Result of analyzeScratch: ordered strokes plus de-duplicated warnings.
struct AnalysisResult {
    std::vector<Stroke> strokes;
    std::vector<ScratchWarning> warnings;
};

} // namespace core
} // namespace scratchlab

#endif // SCRATCHLAB_CORE_SCRATCH_NOTATION_TYPES_HPP
