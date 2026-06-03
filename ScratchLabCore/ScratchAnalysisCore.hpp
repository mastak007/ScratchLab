// ScratchLabCore — pure C++ notation/movement analysis core (Slice 1).
//
// Offline, deterministic stroke segmentation from platter (CC6) + crossfader events.
// See ScratchNotationTypes.hpp for the value types. No I/O, no app dependencies.

#ifndef SCRATCHLAB_CORE_SCRATCH_ANALYSIS_CORE_HPP
#define SCRATCHLAB_CORE_SCRATCH_ANALYSIS_CORE_HPP

#include "ScratchNotationTypes.hpp"

#include <vector>

namespace scratchlab {
namespace core {

/// Segment platter movement into strokes and classify each as audible/cut.
///
/// Pure and deterministic: inputs are defensively copied and stable-sorted by time, so
/// callers need not pre-sort and identical inputs always yield identical output.
///
/// Behavior summary (full rules documented in the .cpp):
///  - Empty platter input -> no strokes, warning emptyInput.
///  - stepsPerRevolution <= 0 or non-finite -> no strokes, warning invalidCalibration.
///  - cc6Step == 0 events are ignored (no movement; never start/extend/split a stroke).
///  - |cc6Step| != 1 is still used by signed magnitude; warning nonUnitStep is added once.
///  - Consecutive same-sign movement is one stroke; a sign change splits strokes.
///  - travelPercent = abs(sum of cc6Step in group) / stepsPerRevolution * 100.
///  - Crossfader: with no crossfader events, default audible. Otherwise a stroke is
///    audible iff some crossfader event within [startTime, endTime] has a clamped
///    value >= crossfaderCutWidth; else it is cut.
AnalysisResult analyzeScratch(
    const std::vector<PlatterEvent>& platter,
    const std::vector<CrossfaderEvent>& crossfader,
    const Calibration& calibration);

} // namespace core
} // namespace scratchlab

#endif // SCRATCHLAB_CORE_SCRATCH_ANALYSIS_CORE_HPP
