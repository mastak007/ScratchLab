//
//  ReviewAudioOnsetSourceResolverTests.swift
//  ScratchLabMLTests — Slice S
//
//  Resolves which input pipeline the Review preview should pull from.
//  These are tiny pure-function tests, but they encode the product
//  rules the rest of the slice depends on:
//
//    * selected take + saved audio events → selectedTakeSavedEvents
//    * selected take + zero saved audio events → unavailable
//      (NEVER falls through to live — that would leak unrelated audio
//      activity from a different session into the selected-take view)
//    * no selected take + live activity → liveDiagnostics
//    * no selected take + no live activity → unavailable
//

import XCTest
@testable import ScratchLabML

final class ReviewAudioOnsetSourceResolverTests: XCTestCase {

    func testSelectedTakeWithSavedEventsPicksSelectedTakeSource() {
        let s = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: true,
            takeAudioEventCount: 12,
            liveTimingCandidateCount: 999
        )
        XCTAssertEqual(s, .selectedTakeSavedEvents,
                       "saved-events on the selected take must outrank live")
    }

    func testSelectedTakeWithNoSavedEventsDoesNotFallThroughToLive() {
        let s = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: true,
            takeAudioEventCount: 0,
            liveTimingCandidateCount: 999
        )
        XCTAssertEqual(s, .unavailable,
                       "even with live activity present, a selected take with no audio events must not fall back to live — live diagnostics may reflect a different session entirely")
    }

    func testNoSelectedTakeWithLiveActivityPicksLive() {
        let s = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: false,
            takeAudioEventCount: 0,
            liveTimingCandidateCount: 7
        )
        XCTAssertEqual(s, .liveDiagnostics)
    }

    func testNoSelectedTakeAndNoLiveActivityIsUnavailable() {
        let s = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: false,
            takeAudioEventCount: 0,
            liveTimingCandidateCount: 0
        )
        XCTAssertEqual(s, .unavailable)
    }

    func testNoSelectedTakeIgnoresTakeAudioEventCount() {
        // A pathological combination — caller shouldn't pass non-zero
        // takeAudioEventCount with hasSelectedTake = false — but the
        // resolver must still be deterministic. Live decides.
        let withLive = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: false,
            takeAudioEventCount: 50,
            liveTimingCandidateCount: 1
        )
        let withoutLive = ReviewAudioOnsetSourceResolver.resolve(
            hasSelectedTake: false,
            takeAudioEventCount: 50,
            liveTimingCandidateCount: 0
        )
        XCTAssertEqual(withLive, .liveDiagnostics)
        XCTAssertEqual(withoutLive, .unavailable)
    }

    func testResolverIsPureForRepeatedCalls() {
        // Same inputs must produce the same answer every time.
        for _ in 0..<5 {
            let s = ReviewAudioOnsetSourceResolver.resolve(
                hasSelectedTake: true,
                takeAudioEventCount: 1,
                liveTimingCandidateCount: 100
            )
            XCTAssertEqual(s, .selectedTakeSavedEvents)
        }
    }
}
