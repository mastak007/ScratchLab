import XCTest
@testable import ScratchLab

/// Phase C6b — locks the contract of `ScratchReviewHintPicker`: pure,
/// deterministic, read-only consumption of `ScratchProgress` fields
/// plus an injected `now`. Never mutates `isMastered`, never affects
/// scoring, never persists.
final class ScratchReviewHintPickerTests: XCTestCase {

    // MARK: - Helpers

    private func anchor() -> Date {
        // 2026-01-15T12:00:00Z — fixed clock for all fixtures.
        Date(timeIntervalSince1970: 1768564800)
    }

    private func date(daysAgo: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    }

    private func context(
        isMastered: Bool = true,
        masteredDate: Date? = nil,
        bestAccuracy: Double = 92,
        recentAccuracies: [Double] = [],
        now: Date? = nil
    ) -> ScratchReviewHintPicker.Context {
        let resolvedNow = now ?? anchor()
        return ScratchReviewHintPicker.Context(
            isMastered: isMastered,
            masteredDate: masteredDate,
            bestAccuracy: bestAccuracy,
            recentAccuracies: recentAccuracies,
            now: resolvedNow
        )
    }

    // MARK: - Not mastered → no hint

    func testNotMasteredSuppressesHint() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            isMastered: false,
            masteredDate: nil,
            recentAccuracies: [60, 60, 60, 60, 60],
            now: now
        ))
        XCTAssertNil(result)
    }

    // MARK: - Stale trigger

    func testStaleFiresAtThreshold() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 14, from: now),
            now: now
        ))
        XCTAssertEqual(result, .stale(daysSinceMastered: 14))
    }

    func testStaleFiresBeyondThreshold() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 30, from: now),
            now: now
        ))
        XCTAssertEqual(result, .stale(daysSinceMastered: 30))
    }

    func testStaleDoesNotFireBelowThreshold() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 13, from: now),
            recentAccuracies: [92, 92, 92, 92, 92],
            now: now
        ))
        XCTAssertNil(result)
    }

    func testStaleWithoutMasteredDateFallsThroughToRegressionCheck() {
        // Defensive: a mastered scratch missing its masteredDate
        // shouldn't crash or fire a stale hint with nil days. The
        // picker should silently skip the stale branch and fall
        // through to regression evaluation.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: nil,
            recentAccuracies: [92, 92, 92, 92, 92],
            now: now
        ))
        XCTAssertNil(result)
    }

    // MARK: - Regression trigger

    func testRegressionFiresAtThreshold() {
        // Best 92, last 5 average 77 → 15-point drop → fires.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 3, from: now),
            bestAccuracy: 92,
            recentAccuracies: [77, 77, 77, 77, 77],
            now: now
        ))
        XCTAssertEqual(result, .regression)
    }

    func testRegressionFiresBeyondThreshold() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 3, from: now),
            bestAccuracy: 95,
            recentAccuracies: [60, 60, 60, 60, 60],
            now: now
        ))
        XCTAssertEqual(result, .regression)
    }

    func testRegressionDoesNotFireBelowThreshold() {
        // 92 best, 80 average → 12-point drop, below threshold.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 3, from: now),
            bestAccuracy: 92,
            recentAccuracies: [80, 80, 80, 80, 80],
            now: now
        ))
        XCTAssertNil(result)
    }

    func testRegressionNeedsFullSample() {
        // Fewer than 5 samples in recentAccuracies → picker cannot
        // evaluate regression. Suppress.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 3, from: now),
            bestAccuracy: 92,
            recentAccuracies: [60, 60, 60, 60],
            now: now
        ))
        XCTAssertNil(result)
    }

    func testRegressionUsesLastFiveOnly() {
        // First two samples are at 95; last 5 are at 70 → regression
        // fires because only the trailing window matters.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 3, from: now),
            bestAccuracy: 95,
            recentAccuracies: [95, 95, 70, 70, 70, 70, 70],
            now: now
        ))
        XCTAssertEqual(result, .regression)
    }

    // MARK: - Stale wins over regression

    func testStaleWinsOverRegressionWhenBothApply() {
        // Both triggers apply; stale fires first by priority.
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 20, from: now),
            bestAccuracy: 95,
            recentAccuracies: [60, 60, 60, 60, 60],
            now: now
        ))
        XCTAssertEqual(result, .stale(daysSinceMastered: 20))
    }

    // MARK: - Silence default

    func testSteadyStateSuppressesHint() {
        let now = anchor()
        let result = ScratchReviewHintPicker.pick(from: context(
            masteredDate: date(daysAgo: 5, from: now),
            bestAccuracy: 92,
            recentAccuracies: [90, 91, 92, 91, 90],
            now: now
        ))
        XCTAssertNil(result)
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let now = anchor()
        let ctx = context(
            masteredDate: date(daysAgo: 14, from: now),
            now: now
        )
        let first = ScratchReviewHintPicker.pick(from: ctx)
        for _ in 0..<99 {
            XCTAssertEqual(ScratchReviewHintPicker.pick(from: ctx), first)
        }
    }
}
