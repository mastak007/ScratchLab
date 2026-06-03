// ScratchLabCore tests — standalone C++ harness (no XCTest, no app dependencies).
//
// Build & run directly:
//   clang++ -std=c++20 -I ScratchLabCore \
//     ScratchLabCore/ScratchAnalysisCore.cpp \
//     Tests/ScratchLabCoreTests/ScratchAnalysisCoreTests.cpp \
//     -o /tmp/ScratchAnalysisCoreTests && /tmp/ScratchAnalysisCoreTests
//
// Exits non-zero if any check fails.

#include "ScratchAnalysisCore.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace scratchlab::core;

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool condition, const std::string& message, int line) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::printf("  FAIL (line %d): %s\n", line, message.c_str());
    }
}

#define CHECK(cond, msg) check((cond), (msg), __LINE__)

bool approxEqual(double a, double b, double epsilon = 1e-9) {
    return std::fabs(a - b) <= epsilon;
}

bool hasWarning(const AnalysisResult& result, ScratchWarning warning) {
    for (ScratchWarning w : result.warnings) {
        if (w == warning) return true;
    }
    return false;
}

const Calibration kRane{3932.0, 0.05};

// 1. Same-direction CC6 becomes one stroke.
void testSameDirectionOneStroke() {
    std::printf("test: same-direction CC6 becomes one stroke\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(result.strokes.size() == 1, "expected exactly one stroke");
    if (result.strokes.size() == 1) {
        const Stroke& s = result.strokes.front();
        CHECK(s.direction == StrokeDirection::forward, "direction forward");
        CHECK(approxEqual(s.startTime, 0.0), "startTime is first event time");
        CHECK(approxEqual(s.endTime, 0.2), "endTime is last event time");
        CHECK(approxEqual(s.travelPercent, 3.0 / 3932.0 * 100.0), "travel uses summed steps");
        CHECK(s.audibleState == AudibleState::unknown, "no crossfader telemetry -> unknown");
    }
    CHECK(result.warnings.empty(), "no warnings for clean unit-step input");
}

// 2. Direction reversal splits strokes.
void testReversalSplits() {
    std::printf("test: direction reversal splits strokes\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, -1}, {0.3, -1}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(result.strokes.size() == 2, "expected two strokes");
    if (result.strokes.size() == 2) {
        CHECK(result.strokes[0].direction == StrokeDirection::forward, "first stroke forward");
        CHECK(approxEqual(result.strokes[0].startTime, 0.0), "first stroke start");
        CHECK(approxEqual(result.strokes[0].endTime, 0.1), "first stroke end at last forward event");
        CHECK(result.strokes[1].direction == StrokeDirection::reverse, "second stroke reverse");
        CHECK(approxEqual(result.strokes[1].startTime, 0.2), "second stroke start at reversal");
        CHECK(approxEqual(result.strokes[1].endTime, 0.3), "second stroke end");
    }
}

// 3 & 4. Short movement gives smaller travel percent; longer movement gives larger.
void testTravelScalesWithMovement() {
    std::printf("test: travel percent scales with movement length\n");
    std::vector<PlatterEvent> shortMove{{0.0, 1}, {0.1, 1}};
    std::vector<PlatterEvent> longMove{
        {0.0, 1}, {0.1, 1}, {0.2, 1}, {0.3, 1}, {0.4, 1},
        {0.5, 1}, {0.6, 1}, {0.7, 1}, {0.8, 1}, {0.9, 1}};
    AnalysisResult shortResult = analyzeScratch(shortMove, {}, kRane);
    AnalysisResult longResult = analyzeScratch(longMove, {}, kRane);
    CHECK(shortResult.strokes.size() == 1 && longResult.strokes.size() == 1,
          "each input yields one stroke");
    if (shortResult.strokes.size() == 1 && longResult.strokes.size() == 1) {
        const double shortTravel = shortResult.strokes.front().travelPercent;
        const double longTravel = longResult.strokes.front().travelPercent;
        CHECK(approxEqual(shortTravel, 2.0 / 3932.0 * 100.0), "short travel = 2 steps");
        CHECK(approxEqual(longTravel, 10.0 / 3932.0 * 100.0), "long travel = 10 steps");
        CHECK(shortTravel < longTravel, "shorter movement -> smaller travel percent");
    }
}

// 5. Fader closed marks cut.
void testFaderClosedMarksCut() {
    std::printf("test: fader closed marks cut\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}};
    std::vector<CrossfaderEvent> fader{{0.0, 0.0}, {0.1, 0.0}, {0.2, 0.0}};
    AnalysisResult result = analyzeScratch(platter, fader, kRane);
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().audibleState == AudibleState::cut,
              "closed fader across span -> cut");
    }
}

// 6. Fader open marks audible.
void testFaderOpenMarksAudible() {
    std::printf("test: fader open marks audible\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}};
    std::vector<CrossfaderEvent> fader{{0.0, 0.0}, {0.1, 1.0}, {0.2, 0.0}};
    AnalysisResult result = analyzeScratch(platter, fader, kRane);
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().audibleState == AudibleState::audible,
              "any open sample in span -> audible");
    }
}

// 7. 3574 vs 3932 changes travel percent correctly.
void testCalibrationChangesTravel() {
    std::printf("test: calibration 3574 vs 3932 changes travel percent\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}, {0.3, 1}};
    AnalysisResult coarse = analyzeScratch(platter, {}, Calibration{3574.0, 0.05});
    AnalysisResult fine = analyzeScratch(platter, {}, Calibration{3932.0, 0.05});
    CHECK(coarse.strokes.size() == 1 && fine.strokes.size() == 1, "one stroke each");
    if (coarse.strokes.size() == 1 && fine.strokes.size() == 1) {
        CHECK(approxEqual(coarse.strokes.front().travelPercent, 4.0 / 3574.0 * 100.0),
              "3574 divisor travel value");
        CHECK(approxEqual(fine.strokes.front().travelPercent, 4.0 / 3932.0 * 100.0),
              "3932 divisor travel value");
        CHECK(coarse.strokes.front().travelPercent > fine.strokes.front().travelPercent,
              "smaller stepsPerRevolution -> larger travel percent");
    }
}

// 8. Deterministic output for same input (incl. defensive sorting of unsorted input).
void testDeterministic() {
    std::printf("test: deterministic output for same input\n");
    // Intentionally unsorted by time to exercise the defensive sort.
    std::vector<PlatterEvent> platter{{0.2, -1}, {0.0, 1}, {0.3, -1}, {0.1, 1}};
    AnalysisResult a = analyzeScratch(platter, {}, kRane);
    AnalysisResult b = analyzeScratch(platter, {}, kRane);
    CHECK(a.strokes.size() == b.strokes.size(), "stroke counts match across runs");
    CHECK(a.strokes.size() == 2, "unsorted input still segments into 2 strokes");
    bool identical = a.strokes.size() == b.strokes.size();
    for (size_t i = 0; identical && i < a.strokes.size(); ++i) {
        identical = a.strokes[i].direction == b.strokes[i].direction &&
                    approxEqual(a.strokes[i].startTime, b.strokes[i].startTime) &&
                    approxEqual(a.strokes[i].endTime, b.strokes[i].endTime) &&
                    approxEqual(a.strokes[i].travelPercent, b.strokes[i].travelPercent) &&
                    a.strokes[i].audibleState == b.strokes[i].audibleState;
    }
    CHECK(identical, "field-by-field identical output across runs");
    if (a.strokes.size() == 2) {
        CHECK(a.strokes[0].direction == StrokeDirection::forward, "sorted: forward first");
        CHECK(approxEqual(a.strokes[0].startTime, 0.0), "sorted: forward starts at t=0");
        CHECK(a.strokes[1].direction == StrokeDirection::reverse, "sorted: reverse second");
    }
}

// 9. Empty input warning.
void testEmptyInputWarning() {
    std::printf("test: empty input warning\n");
    AnalysisResult result = analyzeScratch({}, {}, kRane);
    CHECK(result.strokes.empty(), "no strokes for empty input");
    CHECK(hasWarning(result, ScratchWarning::emptyInput), "emptyInput warning present");
}

// 10. Invalid calibration warning.
void testInvalidCalibrationWarning() {
    std::printf("test: invalid calibration warning\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}};
    AnalysisResult zero = analyzeScratch(platter, {}, Calibration{0.0, 0.05});
    CHECK(zero.strokes.empty(), "no strokes when stepsPerRevolution is 0");
    CHECK(hasWarning(zero, ScratchWarning::invalidCalibration), "invalidCalibration for 0");
    AnalysisResult negative = analyzeScratch(platter, {}, Calibration{-10.0, 0.05});
    CHECK(hasWarning(negative, ScratchWarning::invalidCalibration), "invalidCalibration for negative");
    AnalysisResult nan = analyzeScratch(platter, {}, Calibration{std::nan(""), 0.05});
    CHECK(hasWarning(nan, ScratchWarning::invalidCalibration), "invalidCalibration for NaN");
}

// 11. Non-unit CC6 step warning.
void testNonUnitStepWarning() {
    std::printf("test: non-unit CC6 step warning\n");
    std::vector<PlatterEvent> platter{{0.0, 2}, {0.1, 2}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(hasWarning(result, ScratchWarning::nonUnitStep), "nonUnitStep warning present");
    CHECK(result.strokes.size() == 1, "non-unit steps still segment");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().direction == StrokeDirection::forward, "positive -> forward");
        CHECK(approxEqual(result.strokes.front().travelPercent, 4.0 / 3932.0 * 100.0),
              "magnitude honored: 2 + 2 = 4 steps");
    }
}

// 12. Missing crossfader telemetry gives AudibleState::unknown (Slice 1.1).
void testMissingCrossfaderUnknown() {
    std::printf("test: missing crossfader telemetry -> unknown\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().audibleState == AudibleState::unknown,
              "no crossfader events -> unknown, not a guess");
    }
}

// 13. Duplicate timestamps preserve input order through stable-sort.
void testDuplicateTimestampsStableOrder() {
    std::printf("test: duplicate timestamps preserve input order (stable-sort)\n");
    // Two opposite-sign events share t=0.0; stable-sort must keep input order, so the
    // first-listed sign defines the first stroke.
    std::vector<PlatterEvent> forwardFirst{{0.0, 1}, {0.0, -1}};
    AnalysisResult a = analyzeScratch(forwardFirst, {}, kRane);
    CHECK(a.strokes.size() == 2, "forward-first: two strokes");
    if (a.strokes.size() == 2) {
        CHECK(a.strokes[0].direction == StrokeDirection::forward, "forward-first: stroke 0 forward");
        CHECK(a.strokes[1].direction == StrokeDirection::reverse, "forward-first: stroke 1 reverse");
    }
    std::vector<PlatterEvent> reverseFirst{{0.0, -1}, {0.0, 1}};
    AnalysisResult b = analyzeScratch(reverseFirst, {}, kRane);
    CHECK(b.strokes.size() == 2, "reverse-first: two strokes");
    if (b.strokes.size() == 2) {
        CHECK(b.strokes[0].direction == StrokeDirection::reverse, "reverse-first: stroke 0 reverse");
        CHECK(b.strokes[1].direction == StrokeDirection::forward, "reverse-first: stroke 1 forward");
    }
}

// 14. Zero-step between same-sign movement does not split the stroke.
void testZeroStepSameSignNoSplit() {
    std::printf("test: zero-step between same-sign movement does not split\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 0}, {0.2, 1}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(result.strokes.size() == 1, "still one forward stroke");
    if (result.strokes.size() == 1) {
        const Stroke& s = result.strokes.front();
        CHECK(s.direction == StrokeDirection::forward, "forward");
        CHECK(approxEqual(s.startTime, 0.0), "start at first move");
        CHECK(approxEqual(s.endTime, 0.2), "end at last move (zero event skipped)");
        CHECK(approxEqual(s.travelPercent, 2.0 / 3932.0 * 100.0), "zero contributes no travel");
    }
}

// 15. Zero-step between opposite-sign movement creates no extra stroke; reversal still splits.
void testZeroStepOppositeSignSplit() {
    std::printf("test: zero-step between opposite-sign movement splits cleanly\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 0}, {0.2, -1}};
    AnalysisResult result = analyzeScratch(platter, {}, kRane);
    CHECK(result.strokes.size() == 2, "exactly two strokes (no phantom stroke from zero)");
    if (result.strokes.size() == 2) {
        CHECK(result.strokes[0].direction == StrokeDirection::forward, "stroke 0 forward");
        CHECK(approxEqual(result.strokes[0].endTime, 0.0), "forward ends before zero event");
        CHECK(result.strokes[1].direction == StrokeDirection::reverse, "stroke 1 reverse");
        CHECK(approxEqual(result.strokes[1].startTime, 0.2), "reverse starts at the -1 event");
    }
}

// 16. Unsorted crossfader input still gates correctly (defensive sort).
void testUnsortedCrossfaderGates() {
    std::printf("test: unsorted crossfader input still gates correctly\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}};
    // Open sample (1.0) sits at t=0.1 but is supplied out of time order.
    std::vector<CrossfaderEvent> fader{{0.2, 0.0}, {0.0, 0.0}, {0.1, 1.0}};
    AnalysisResult result = analyzeScratch(platter, fader, kRane);
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().audibleState == AudibleState::audible,
              "open sample found despite unsorted input");
    }
}

// 17. crossfaderCutWidth below 0 clamps to 0 (a 0.0 sample then reads open).
void testCutWidthBelowZeroClamps() {
    std::printf("test: crossfaderCutWidth below 0 clamps to 0\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}};
    std::vector<CrossfaderEvent> fader{{0.0, 0.0}, {0.1, 0.0}};
    AnalysisResult result = analyzeScratch(platter, fader, Calibration{3932.0, -1.0});
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        CHECK(result.strokes.front().audibleState == AudibleState::audible,
              "threshold clamped to 0: a 0.0 sample is >= 0 -> audible");
    }
}

// 18. crossfaderCutWidth above 1 clamps to 1 (a fully-open 1.0 sample reads audible).
void testCutWidthAboveOneClamps() {
    std::printf("test: crossfaderCutWidth above 1 clamps to 1\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}};
    // Fully open sample at 1.0. Without clamping, threshold 5.0 would never be met -> cut.
    std::vector<CrossfaderEvent> openFader{{0.0, 1.0}, {0.1, 1.0}};
    AnalysisResult open = analyzeScratch(platter, openFader, Calibration{3932.0, 5.0});
    CHECK(open.strokes.size() == 1 && open.strokes.front().audibleState == AudibleState::audible,
          "threshold clamped to 1: a 1.0 sample is >= 1 -> audible");
    // A partly-open 0.9 sample stays below the clamped threshold of 1 -> cut.
    std::vector<CrossfaderEvent> partFader{{0.0, 0.9}, {0.1, 0.9}};
    AnalysisResult part = analyzeScratch(platter, partFader, Calibration{3932.0, 5.0});
    CHECK(part.strokes.size() == 1 && part.strokes.front().audibleState == AudibleState::cut,
          "0.9 < clamped threshold 1 -> cut");
}

// 19. Non-finite crossfaderCutWidth falls back safely (to 0).
void testCutWidthNonFiniteFallback() {
    std::printf("test: non-finite crossfaderCutWidth falls back safely\n");
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}};
    std::vector<CrossfaderEvent> fader{{0.0, 0.5}, {0.1, 0.5}};
    AnalysisResult nan = analyzeScratch(platter, fader, Calibration{3932.0, std::nan("")});
    CHECK(nan.strokes.size() == 1 && nan.strokes.front().audibleState == AudibleState::audible,
          "NaN cutWidth -> fallback 0 -> 0.5 sample audible");
    const double inf = std::numeric_limits<double>::infinity();
    AnalysisResult infinite = analyzeScratch(platter, fader, Calibration{3932.0, inf});
    CHECK(infinite.strokes.size() == 1 && infinite.strokes.front().audibleState == AudibleState::audible,
          "infinite cutWidth -> fallback 0 -> 0.5 sample audible");
}

// 20. travelPercent over 100 stays over 100 and is not capped.
void testTravelPercentNotCapped() {
    std::printf("test: travelPercent over 100 is not capped\n");
    // 5 steps over a 2-step revolution -> 250%.
    std::vector<PlatterEvent> platter{{0.0, 1}, {0.1, 1}, {0.2, 1}, {0.3, 1}, {0.4, 1}};
    AnalysisResult result = analyzeScratch(platter, {}, Calibration{2.0, 0.05});
    CHECK(result.strokes.size() == 1, "one stroke");
    if (result.strokes.size() == 1) {
        const double travel = result.strokes.front().travelPercent;
        CHECK(approxEqual(travel, 250.0), "5 steps / 2 per rev * 100 = 250");
        CHECK(travel > 100.0, "travel percent left uncapped as diagnostic evidence");
    }
}

} // namespace

int main() {
    testSameDirectionOneStroke();
    testReversalSplits();
    testTravelScalesWithMovement();
    testFaderClosedMarksCut();
    testFaderOpenMarksAudible();
    testCalibrationChangesTravel();
    testDeterministic();
    testEmptyInputWarning();
    testInvalidCalibrationWarning();
    testNonUnitStepWarning();
    // Slice 1.1 hardening.
    testMissingCrossfaderUnknown();
    testDuplicateTimestampsStableOrder();
    testZeroStepSameSignNoSplit();
    testZeroStepOppositeSignSplit();
    testUnsortedCrossfaderGates();
    testCutWidthBelowZeroClamps();
    testCutWidthAboveOneClamps();
    testCutWidthNonFiniteFallback();
    testTravelPercentNotCapped();

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures == 0) {
        std::printf("ALL TESTS PASSED\n");
        return 0;
    }
    std::printf("TESTS FAILED\n");
    return 1;
}
