import XCTest
@testable import ScratchLab

/// Phase C6a — locks the contract of `PracticeMilestonePicker`: pure,
/// deterministic, read-only consumption of post-session
/// `ProgressManager` state. No clock, no I/O, no UI.
final class PracticeMilestonePickerTests: XCTestCase {

    // MARK: - Helpers

    private func context(
        total: Int = 5,
        streak: Int = 0,
        scratchName: String? = "Baby Scratch",
        practiceCount: Int? = 5
    ) -> PracticeMilestonePicker.Context {
        PracticeMilestonePicker.Context(
            totalScratchAttempts: total,
            currentStreak: streak,
            scratchName: scratchName,
            scratchPracticeCount: practiceCount
        )
    }

    // MARK: - First session

    func testFirstSessionFiresAtTotalOne() {
        let result = PracticeMilestonePicker.pick(from: context(total: 1))
        XCTAssertEqual(result, .firstSession)
    }

    func testFirstSessionDoesNotFireAtTotalZero() {
        // Defensive: if recorder somehow runs before increment, we
        // still avoid claiming "first session" on a zero-state.
        let result = PracticeMilestonePicker.pick(from: context(total: 0))
        XCTAssertNil(result)
    }

    func testFirstSessionDoesNotFireAtTotalTwo() {
        let result = PracticeMilestonePicker.pick(from: context(total: 2))
        XCTAssertNil(result)
    }

    // MARK: - Streak day

    func testSevenDayStreakFires() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 10, streak: 7)
        )
        XCTAssertEqual(result, .streakDay(7))
    }

    func testSixDayStreakDoesNotFire() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 10, streak: 6)
        )
        XCTAssertNil(result)
    }

    func testEightDayStreakDoesNotFire() {
        // Streak milestones are exact tier matches today — fires only
        // on the day the user crosses the threshold.
        let result = PracticeMilestonePicker.pick(
            from: context(total: 10, streak: 8)
        )
        XCTAssertNil(result)
    }

    // MARK: - Per-scratch practice count

    func testHundredTakesFiresWithScratchName() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 50, streak: 0, scratchName: "Baby Scratch", practiceCount: 100)
        )
        XCTAssertEqual(result, .scratchPracticeCount(scratchName: "Baby Scratch", count: 100))
    }

    func testHundredTakesRequiresScratchName() {
        // Without a scratch name we cannot render honest copy; suppress.
        let result = PracticeMilestonePicker.pick(
            from: context(total: 50, streak: 0, scratchName: nil, practiceCount: 100)
        )
        XCTAssertNil(result)
    }

    func testNinetyNineTakesDoesNotFire() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 50, streak: 0, scratchName: "Baby Scratch", practiceCount: 99)
        )
        XCTAssertNil(result)
    }

    func testOneHundredOneTakesDoesNotFire() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 50, streak: 0, scratchName: "Baby Scratch", practiceCount: 101)
        )
        XCTAssertNil(result)
    }

    // MARK: - Priority

    func testFirstSessionWinsOverStreak() {
        // Constructed scenario where both could theoretically fire;
        // first session takes priority.
        let result = PracticeMilestonePicker.pick(
            from: context(total: 1, streak: 7)
        )
        XCTAssertEqual(result, .firstSession)
    }

    func testStreakWinsOverScratchPracticeCount() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 50, streak: 7, scratchName: "Baby Scratch", practiceCount: 100)
        )
        XCTAssertEqual(result, .streakDay(7))
    }

    // MARK: - Silence default

    func testNothingFiresForUnremarkableSession() {
        let result = PracticeMilestonePicker.pick(
            from: context(total: 12, streak: 3, scratchName: "Baby Scratch", practiceCount: 7)
        )
        XCTAssertNil(result)
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let ctx = context(total: 1)
        let first = PracticeMilestonePicker.pick(from: ctx)
        for _ in 0..<99 {
            XCTAssertEqual(PracticeMilestonePicker.pick(from: ctx), first)
        }
    }
}
