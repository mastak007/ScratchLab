import XCTest
@testable import ScratchLab

/// Validation tests for the local-only `baby_platter.json` fixture
/// produced by `Tools/Fixtures/click_to_platter_timeline.py`.
///
/// Four of the five tests are gated by the `BABY_PLATTER_FIXTURE_PATH`
/// environment variable and skip cleanly when it is unset, so the test
/// bundle stays green on machines (and CI) that don't have the local
/// fixture. The fifth test, `testFixtureNotBundled`, always runs and is
/// the bundle-safety net: it fails if `baby_platter.json` ever shows up
/// in any loaded bundle (test bundle, host app, frameworks).
///
/// To enable the env-gated tests:
///
///     export BABY_PLATTER_FIXTURE_PATH="$PWD/Tests/Fixtures/LocalOnly/baby_platter.json"
///     xcodebuild test -scheme ScratchLab -destination 'platform=macOS' \
///         -only-testing:ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests
final class BabyPlatterFixtureDecodeTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the fixture URL from `BABY_PLATTER_FIXTURE_PATH`, or throws
    /// `XCTSkip` when the env var is unset or points at a missing file.
    private func fixtureURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BABY_PLATTER_FIXTURE_PATH"], !raw.isEmpty else {
            throw XCTSkip(
                "BABY_PLATTER_FIXTURE_PATH is unset; export it to the local baby_platter.json to enable"
            )
        }
        let url = URL(fileURLWithPath: raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "BABY_PLATTER_FIXTURE_PATH points at a non-existent file: \(raw)"
            )
        }
        return url
    }

    private func loadFixture() throws -> PlatterPositionTimeline {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PlatterPositionTimeline.self, from: data)
    }

    // MARK: - Env-gated decode + value tests

    /// JSON decodes cleanly, source label is correct, sample count is
    /// non-trivial, and the take duration is roughly the 26.75 s of the
    /// demo clip. Tolerance is loose so the test survives different
    /// click strides and click ranges.
    func testFixtureDecodes() throws {
        let timeline = try loadFixture()
        XCTAssertEqual(timeline.source, .coachAuthored,
                       "fixture should be coachAuthored, not liveCapture / bundledDemo")
        XCTAssertGreaterThan(timeline.samples.count, 100,
                             "expected at least 100 samples in a real fixture")
        let duration = timeline.endTime - timeline.startTime
        XCTAssertEqual(duration, 26.75, accuracy: 1.0,
                       "fixture duration \(duration)s should roughly match the 26.75 s demo")
    }

    /// No NaN / inf anywhere in the timeline. Cheap sanity that catches
    /// divide-by-zero or empty-interpolation regressions in the
    /// converter.
    func testFixtureSamplesAreFinite() throws {
        let timeline = try loadFixture()
        for (i, s) in timeline.samples.enumerated() {
            XCTAssertTrue(s.time.isFinite,
                          "sample \(i): time \(s.time) not finite")
            XCTAssertTrue(s.position.isFinite,
                          "sample \(i): position \(s.position) not finite")
            XCTAssertTrue(s.confidence.isFinite,
                          "sample \(i): confidence \(s.confidence) not finite")
        }
    }

    /// Confidence is in [0, 1] for every sample. The current converter
    /// emits exactly 1.0 (clicked) or 0.75 (interpolated); the bounds
    /// check is intentionally looser so a future tweak to the converter
    /// (e.g. graded uncertainty) does not require a test edit.
    func testFixtureConfidenceBounds() throws {
        let timeline = try loadFixture()
        for (i, s) in timeline.samples.enumerated() {
            XCTAssertGreaterThanOrEqual(s.confidence, 0.0,
                                        "sample \(i): confidence \(s.confidence) below 0")
            XCTAssertLessThanOrEqual(s.confidence, 1.0,
                                     "sample \(i): confidence \(s.confidence) above 1")
        }
    }

    /// The position trace should look like baby-scratch motion: span the
    /// platter axis far enough to be visible (≥ 0.05 of normalized
    /// image-width units) and cross the midpoint at least twice
    /// (back-and-forth).
    func testFixtureMovementResemblesBabyScratch() throws {
        let timeline = try loadFixture()
        guard let range = timeline.positionRange else {
            return XCTFail("positionRange is nil — samples must be empty")
        }
        let span = range.upperBound - range.lowerBound
        XCTAssertGreaterThan(span, 0.05,
                             "positionRange span \(span) is too narrow for real motion")

        // Count sign-flips of (position - midpoint) — back-and-forth
        // motion should cross the midpoint at least twice across the take.
        let midpoint = (range.lowerBound + range.upperBound) / 2
        var flips = 0
        var prevSign: Int?
        for s in timeline.samples {
            let v = s.position - midpoint
            if v == 0 { continue }
            let sign = v > 0 ? 1 : -1
            if let p = prevSign, p != sign { flips += 1 }
            prevSign = sign
        }
        XCTAssertGreaterThanOrEqual(flips, 2,
                                    "expected ≥ 2 midpoint sign flips for baby-scratch motion, got \(flips)")
    }

    // MARK: - Always-runs bundle-absence guard

    /// **Always runs**, even without the env var. Asserts the fixture
    /// has not been added to any loaded bundle: the test bundle, any
    /// host app, or any framework. This is the safety net that catches
    /// accidental Copy-Bundle-Resources drift in a future PR.
    func testFixtureNotBundled() {
        XCTAssertNil(
            Bundle.main.url(forResource: "baby_platter", withExtension: "json"),
            "baby_platter.json must not be present in Bundle.main at \(Bundle.main.bundleURL.path)"
        )
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            XCTAssertNil(
                bundle.url(forResource: "baby_platter", withExtension: "json"),
                "baby_platter.json leaked into bundle: \(bundle.bundleURL.path)"
            )
        }
    }
}
