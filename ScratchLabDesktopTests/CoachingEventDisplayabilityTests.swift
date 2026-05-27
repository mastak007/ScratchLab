import XCTest
@testable import ScratchLab

/// Phase C foundation §0.9 — locks the `CoachingEventDisplayability`
/// resolver contract: pure presentation-layer projection from
/// (descriptor, paced, surfaceTier) → display state. No inference, no
/// numeric confidence on the wire, no UI.
final class CoachingEventDisplayabilityTests: XCTestCase {

    // MARK: - Helpers

    private func descriptor(
        isResearchOnly: Bool,
        kind: CoachingEventKind = .lateReversal,
        severity: CoachingEventSeverity = .notice
    ) -> CoachingEventDescriptor {
        CoachingEventDescriptor(
            kind: kind,
            severity: severity,
            displayName: "test",
            body: "test",
            isResearchOnly: isResearchOnly
        )
    }

    // MARK: - Coefficient mapping

    func testCoefficientMapping() {
        XCTAssertEqual(CoachingEventDisplayability.hidden.coefficient, 0.0)
        XCTAssertEqual(CoachingEventDisplayability.display(.advisory).coefficient, 0.4)
        XCTAssertEqual(CoachingEventDisplayability.display(.primary).coefficient, 1.0)
    }

    func testIsVisible() {
        XCTAssertFalse(CoachingEventDisplayability.hidden.isVisible)
        XCTAssertTrue(CoachingEventDisplayability.display(.advisory).isVisible)
        XCTAssertTrue(CoachingEventDisplayability.display(.primary).isVisible)
    }

    // MARK: - Resolver

    func testResolverHidesWhenPacerSuppressed() {
        // Pacer suppression always wins, even when the descriptor is
        // user-safe.
        let result = CoachingEventDisplayabilityResolver.resolve(
            .init(
                descriptor: descriptor(isResearchOnly: false),
                passedPacer: false,
                surfaceTier: .primary
            )
        )
        XCTAssertEqual(result, .hidden)
    }

    func testResolverHidesResearchOnlyDescriptor() {
        // isResearchOnly descriptors stay invisible to users even when
        // they survive the pacer at the strongest tier.
        let result = CoachingEventDisplayabilityResolver.resolve(
            .init(
                descriptor: descriptor(isResearchOnly: true),
                passedPacer: true,
                surfaceTier: .primary
            )
        )
        XCTAssertEqual(result, .hidden)
    }

    func testResolverEchoesAdvisoryTier() {
        let result = CoachingEventDisplayabilityResolver.resolve(
            .init(
                descriptor: descriptor(isResearchOnly: false),
                passedPacer: true,
                surfaceTier: .advisory
            )
        )
        XCTAssertEqual(result, .display(.advisory))
    }

    func testResolverEchoesPrimaryTier() {
        let result = CoachingEventDisplayabilityResolver.resolve(
            .init(
                descriptor: descriptor(isResearchOnly: false),
                passedPacer: true,
                surfaceTier: .primary
            )
        )
        XCTAssertEqual(result, .display(.primary))
    }

    func testResolverIsDeterministic() {
        let inputs = CoachingEventDisplayabilityResolver.Inputs(
            descriptor: descriptor(isResearchOnly: false),
            passedPacer: true,
            surfaceTier: .advisory
        )
        let first = CoachingEventDisplayabilityResolver.resolve(inputs)
        for _ in 0..<99 {
            XCTAssertEqual(CoachingEventDisplayabilityResolver.resolve(inputs), first)
        }
    }

    func testResearchOnlyVsPacerInteraction() {
        // Both gates must pass. Walk every combination of (paced ∈ {true,
        // false}) × (researchOnly ∈ {true, false}) × (tier ∈ {advisory,
        // primary}) and assert the output matches the resolver's
        // contract.
        for paced in [false, true] {
            for researchOnly in [false, true] {
                for tier: CoachingEventDisplayability.Tier in [.advisory, .primary] {
                    let result = CoachingEventDisplayabilityResolver.resolve(
                        .init(
                            descriptor: descriptor(isResearchOnly: researchOnly),
                            passedPacer: paced,
                            surfaceTier: tier
                        )
                    )
                    let expected: CoachingEventDisplayability
                    if !paced || researchOnly {
                        expected = .hidden
                    } else {
                        expected = .display(tier)
                    }
                    XCTAssertEqual(
                        result, expected,
                        "paced=\(paced), researchOnly=\(researchOnly), tier=\(tier)"
                    )
                }
            }
        }
    }
}
