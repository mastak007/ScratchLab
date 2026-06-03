// ScratchLabCore — pure C++ notation/movement analysis core (Slice 1) implementation.

#include "ScratchAnalysisCore.hpp"

#include <algorithm>
#include <cmath>

namespace scratchlab {
namespace core {

namespace {

/// Add a warning kind at most once, preserving first-seen order (keeps output deterministic).
void addWarningOnce(std::vector<ScratchWarning>& warnings, ScratchWarning warning) {
    if (std::find(warnings.begin(), warnings.end(), warning) == warnings.end()) {
        warnings.push_back(warning);
    }
}

double clamp01(double value) {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

/// Sanitize the crossfader open threshold: a non-finite value falls back to 0 (treat
/// every sample as potentially open), then the result is clamped to 0...1 so the
/// comparison against clamped sample values is always well-defined.
double sanitizeCutWidth(double cutWidth) {
    if (!std::isfinite(cutWidth)) return 0.0;
    return clamp01(cutWidth);
}

/// True if any crossfader sample within [startTime, endTime] reads open (>= cutWidth).
/// `sortedCrossfader` is assumed sorted by time and `cutWidth` is already sanitized to
/// 0...1. With no crossfader events the caller reports unknown; this helper only runs
/// when at least one event exists.
bool spanIsAudible(const std::vector<CrossfaderEvent>& sortedCrossfader,
                   double startTime,
                   double endTime,
                   double cutWidth) {
    for (const CrossfaderEvent& event : sortedCrossfader) {
        if (event.timeSeconds < startTime) continue;
        if (event.timeSeconds > endTime) break; // sorted: nothing further is in span
        if (clamp01(event.value) >= cutWidth) {
            return true;
        }
    }
    return false;
}

} // namespace

AnalysisResult analyzeScratch(
    const std::vector<PlatterEvent>& platter,
    const std::vector<CrossfaderEvent>& crossfader,
    const Calibration& calibration) {
    AnalysisResult result;

    // Rule 1: empty platter input -> no strokes, emptyInput warning.
    if (platter.empty()) {
        addWarningOnce(result.warnings, ScratchWarning::emptyInput);
        return result;
    }

    // Rule 2: invalid calibration -> no strokes, invalidCalibration warning.
    if (!std::isfinite(calibration.stepsPerRevolution) ||
        calibration.stepsPerRevolution <= 0.0) {
        addWarningOnce(result.warnings, ScratchWarning::invalidCalibration);
        return result;
    }

    // Determinism: work on sorted copies so callers need not pre-sort. std::stable_sort
    // keeps the original relative order of events sharing a timestamp.
    std::vector<PlatterEvent> events = platter;
    std::stable_sort(events.begin(), events.end(),
                     [](const PlatterEvent& a, const PlatterEvent& b) {
                         return a.timeSeconds < b.timeSeconds;
                     });

    std::vector<CrossfaderEvent> faderEvents = crossfader;
    std::stable_sort(faderEvents.begin(), faderEvents.end(),
                     [](const CrossfaderEvent& a, const CrossfaderEvent& b) {
                         return a.timeSeconds < b.timeSeconds;
                     });
    const bool hasFaderEvents = !faderEvents.empty();
    const double cutWidth = sanitizeCutWidth(calibration.crossfaderCutWidth);

    // Segment into runs of same-sign movement.
    // Rule 3: cc6Step == 0 means "no movement" and is skipped entirely — it neither opens,
    // extends, nor splits a stroke, and contributes 0 to travel.
    bool inStroke = false;
    int currentSign = 0;            // +1 forward, -1 reverse
    double groupStart = 0.0;
    double groupEnd = 0.0;
    long long groupStepSum = 0;     // signed sum of cc6Step across the group

    auto finalizeGroup = [&]() {
        if (!inStroke) return;
        Stroke stroke;
        stroke.direction = currentSign > 0 ? StrokeDirection::forward : StrokeDirection::reverse;
        stroke.startTime = groupStart;
        stroke.endTime = groupEnd;
        // Rule 5: travel from signed CC6 magnitude only — never pitch bend, never duration.
        stroke.travelPercent =
            std::abs(static_cast<double>(groupStepSum)) / calibration.stepsPerRevolution * 100.0;
        // Rule 6: with no crossfader telemetry, audibility is unknown (do not guess).
        // Otherwise gate on whether any in-span sample is open at the sanitized threshold.
        if (!hasFaderEvents) {
            stroke.audibleState = AudibleState::unknown;
        } else {
            stroke.audibleState =
                spanIsAudible(faderEvents, stroke.startTime, stroke.endTime, cutWidth)
                    ? AudibleState::audible
                    : AudibleState::cut;
        }
        result.strokes.push_back(stroke);
        inStroke = false;
    };

    for (const PlatterEvent& event : events) {
        const int step = event.cc6Step;
        if (step == 0) {
            continue; // no movement
        }
        // Rule 3: non-unit magnitude is still honored by its signed value; flag once.
        if (step != 1 && step != -1) {
            addWarningOnce(result.warnings, ScratchWarning::nonUnitStep);
        }

        const int sign = step > 0 ? 1 : -1;
        if (inStroke && sign == currentSign) {
            // Extend the current run.
            groupEnd = event.timeSeconds;
            groupStepSum += step;
        } else {
            // Rule 4: a direction reversal (or the first movement) starts a new stroke.
            finalizeGroup();
            inStroke = true;
            currentSign = sign;
            groupStart = event.timeSeconds;
            groupEnd = event.timeSeconds;
            groupStepSum = step;
        }
    }
    finalizeGroup();

    return result;
}

} // namespace core
} // namespace scratchlab
