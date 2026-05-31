import XCTest
@testable import ScratchLab

final class KidScrubInputTests: XCTestCase {

    // MARK: - Initial / reset state

    func testDefaultStartsCentredIdle() {
        let input = KidScrubInput()
        XCTAssertEqual(input.position, 0.5, accuracy: 1e-12)
        XCTAssertEqual(input.velocity, 0)
        XCTAssertEqual(input.direction, .idle)
    }

    func testResetReturnsToGivenPositionAndIdle() {
        var input = KidScrubInput()
        input.update(delta: 0.3, deltaTime: 0.1)
        input.reset(to: 0.2)
        XCTAssertEqual(input.position, 0.2, accuracy: 1e-12)
        XCTAssertEqual(input.velocity, 0)
        XCTAssertEqual(input.direction, .idle)
    }

    func testResetDefaultsToCentre() {
        var input = KidScrubInput(position: 0.9)
        input.reset()
        XCTAssertEqual(input.position, 0.5, accuracy: 1e-12)
    }

    // MARK: - Direction by sign

    func testPositiveDeltaIsForward() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.1, deltaTime: 0.1)
        XCTAssertEqual(input.direction, .forward)
        XCTAssertGreaterThan(input.velocity, 0)
    }

    func testNegativeDeltaIsBackward() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: -0.1, deltaTime: 0.1)
        XCTAssertEqual(input.direction, .backward)
        XCTAssertLessThan(input.velocity, 0)
    }

    func testZeroDeltaIsIdle() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0, deltaTime: 0.1)
        XCTAssertEqual(input.direction, .idle)
        XCTAssertEqual(input.velocity, 0)
    }

    func testNearZeroDeltaIsIdle() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: KidScrubInput.idleDeltaThreshold / 2, deltaTime: 0.1)
        XCTAssertEqual(input.direction, .idle)
        XCTAssertEqual(input.velocity, 0)
    }

    // MARK: - Position clamping

    func testPositionClampsAtUpperBound() {
        var input = KidScrubInput(position: 0.9)
        input.update(delta: 1.0, deltaTime: 0.1)
        XCTAssertEqual(input.position, 1.0, accuracy: 1e-12)
    }

    func testPositionClampsAtLowerBound() {
        var input = KidScrubInput(position: 0.1)
        input.update(delta: -1.0, deltaTime: 0.1)
        XCTAssertEqual(input.position, 0.0, accuracy: 1e-12)
    }

    func testInitClampsOutOfRangePosition() {
        XCTAssertEqual(KidScrubInput(position: 5).position, 1.0, accuracy: 1e-12)
        XCTAssertEqual(KidScrubInput(position: -5).position, 0.0, accuracy: 1e-12)
    }

    // MARK: - Finite / invalid input safety

    func testNaNDeltaDoesNotCorruptState() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: .nan, deltaTime: 0.1)
        XCTAssertTrue(input.position.isFinite)
        XCTAssertTrue(input.velocity.isFinite)
        XCTAssertEqual(input.direction, .idle)
    }

    func testInfiniteDeltaDoesNotCorruptState() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: .infinity, deltaTime: 0.1)
        XCTAssertTrue(input.position.isFinite)
        XCTAssertTrue(input.velocity.isFinite)
    }

    func testZeroDeltaTimeDoesNotProduceInfiniteVelocity() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.1, deltaTime: 0)
        XCTAssertTrue(input.velocity.isFinite)
        XCTAssertEqual(input.velocity, 0)
        // Position still advances even when the time is unusable.
        XCTAssertEqual(input.position, 0.6, accuracy: 1e-12)
    }

    func testNegativeDeltaTimeDoesNotProduceInfiniteVelocity() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.1, deltaTime: -0.1)
        XCTAssertTrue(input.velocity.isFinite)
        XCTAssertEqual(input.velocity, 0)
    }

    func testNaNDeltaTimeIsTreatedAsInvalid() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.1, deltaTime: .nan)
        XCTAssertTrue(input.velocity.isFinite)
        XCTAssertEqual(input.velocity, 0)
    }

    // MARK: - Velocity value + determinism

    func testVelocityIsDeltaOverTime() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.2, deltaTime: 0.5)
        XCTAssertEqual(input.velocity, 0.4, accuracy: 1e-12)
    }

    func testRepeatedUpdatesAreDeterministic() {
        var a = KidScrubInput()
        var b = KidScrubInput()
        for _ in 0..<50 {
            a.update(delta: 0.01, deltaTime: 1.0 / 60.0)
            b.update(delta: 0.01, deltaTime: 1.0 / 60.0)
        }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.position, b.position, accuracy: 1e-12)
    }

    func testForwardThenBackwardReturnsTowardOrigin() {
        var input = KidScrubInput(position: 0.5)
        input.update(delta: 0.2, deltaTime: 0.1)
        input.update(delta: -0.2, deltaTime: 0.1)
        XCTAssertEqual(input.position, 0.5, accuracy: 1e-12)
        XCTAssertEqual(input.direction, .backward)
    }
}
