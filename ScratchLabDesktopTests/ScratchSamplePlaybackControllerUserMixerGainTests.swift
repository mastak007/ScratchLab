// ScratchSamplePlaybackControllerUserMixerGainTests.swift
// Controller-level coverage of learned mixer faders driving scratch-sample
// audio gain: the right-upfader gain, the crossfader's right-deck cut
// curve, their multiplicative combination, and — critically — that the
// SAME gain applies whether motion is driven by the direct-MIDI continuous
// path (`testOnly_midiCoalescingTick`) or the DVS continuous path
// (`positionDidChangeContinuous`), since both publish to the one shared
// `dvsContinuousRenderer` instance.
//
// Uses the synthetic-sample seam (`testOnly_installSyntheticSample`), like
// the sibling MIDI-platter test file, so every test here also runs under
// the command-line harness that cannot resolve app-bundle fixtures. Does
// not modify `ScratchSamplePlaybackControllerTests.swift` or its existing
// (unrelated, pre-existing) `setCrossfader`/`crossfaderGate` coverage.

import XCTest
import AVFoundation
@testable import ScratchLab

final class ScratchSamplePlaybackControllerUserMixerGainTests: XCTestCase {

    private static let rate: Double = 44_100

    private func makeSyntheticLoopBuffer(frames: Int = 8_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = 0.8 * Float(sin(Double(i) * 2 * .pi / 100))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    private func makeController() throws -> (
        controller: ScratchSamplePlaybackController,
        setNow: (TimeInterval) -> Void,
        setSteps: (Int) -> Void
    ) {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        return (controller, { clock.now = $0 }, { steps.value = $0 })
    }

    /// Renders `frameCount` frames through the controller's continuous
    /// renderer and returns the peak absolute sample — a cheap proxy for
    /// "how loud is this gain setting" without needing exact waveform
    /// alignment.
    private func peakAmplitude(_ controller: ScratchSamplePlaybackController, frames: Int = 4_000) -> Float {
        var buffer = [Float](repeating: 0, count: frames)
        buffer.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: frames)
        }
        return buffer.map { abs($0) }.max() ?? 0
    }

    /// `targetUserMixerGain` (the render core's un-ramped mirror of the
    /// last published value) only updates during an actual render call
    /// (`ingestUserMixerGain` runs inside `performRender`) — publishing
    /// alone does not touch it. Forces one minimal render (1 frame, far
    /// too short to move the click-free ramp meaningfully) so reading it
    /// immediately afterward reflects the latest publish rather than a
    /// stale default.
    private func publishedTargetUserMixerGain(_ controller: ScratchSamplePlaybackController) -> Double {
        var scratch = [Float](repeating: 0, count: 1)
        scratch.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 1)
        }
        return controller.dvsContinuousRenderer.testOnly_coreTargetUserMixerGain
    }

    // MARK: - Regression #1: unmapped defaults to unity

    func testFreshControllerDefaultsToUnityGain() throws {
        let (controller, _, _) = try makeController()
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0)
    }

    // MARK: - Regression #2: right upfader bottom/top/mid

    func testRightUpfaderBottomProducesZero() throws {
        let (controller, _, _) = try makeController()
        controller.setRightUpfaderGain(0.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.0)
    }

    func testRightUpfaderTopProducesOne() throws {
        let (controller, _, _) = try makeController()
        controller.setRightUpfaderGain(0.0)
        controller.waitForAudioQueue()
        controller.setRightUpfaderGain(1.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0)
    }

    func testRightUpfaderMidpointProducesExpectedNormalizedGain() throws {
        let (controller, _, _) = try makeController()
        controller.setRightUpfaderGain(0.5)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.5, accuracy: 0.001)
    }

    // MARK: - Regression #4: crossfader left edge / cut-in boundary / center / right

    func testCrossfaderLeftEdgeProducesZero() throws {
        let (controller, _, _) = try makeController()
        controller.setCrossfaderPosition(0.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.0)
    }

    func testCrossfaderCutInBoundaryReachesOne() throws {
        let (controller, _, _) = try makeController()
        let cutIn = ScratchSamplePlaybackController.crossfaderCutInWidth
        controller.setCrossfaderPosition(cutIn)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0, accuracy: 0.001)
    }

    func testCrossfaderCenterAndRightRemainAtOne() throws {
        let (controller, _, _) = try makeController()
        for position in [0.5, 0.75, 1.0] {
            controller.setCrossfaderPosition(position)
            controller.waitForAudioQueue()
            XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0,
                "crossfader position \(position) (center/right) must remain at full scratch gain")
        }
    }

    // MARK: - Regression #5: combined gain

    func testCombinedRightUpfaderAndCrossfaderGainIsMultiplicative() throws {
        let (controller, _, _) = try makeController()
        controller.setRightUpfaderGain(0.6)
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(1.0) // fully right → cut curve gain 1.0
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.6, accuracy: 0.001)

        // Now close the crossfader most of the way through its cut-in
        // region: combined gain must be the product of both.
        let halfCutIn = ScratchSamplePlaybackController.crossfaderCutInWidth / 2
        controller.setCrossfaderPosition(halfCutIn)
        controller.waitForAudioQueue()
        let expected = 0.6 * 0.5
        XCTAssertEqual(publishedTargetUserMixerGain(controller), expected, accuracy: 0.001)
    }

    // MARK: - Regression #6: malformed/extreme inputs stay finite and clamped

    func testMalformedAndExtremeInputsAreFiniteAndClamped() throws {
        let (controller, _, _) = try makeController()

        controller.setRightUpfaderGain(.nan)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0)

        controller.setRightUpfaderGain(500.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0)

        controller.setRightUpfaderGain(1.0)
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(-999.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0,
            "an extreme negative crossfader position must clamp to the left edge (gain 0), not crash or go negative")

        controller.setCrossfaderPosition(.infinity)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0,
            "non-finite input must fail toward silence, not full volume")
    }

    // MARK: - Regression #11: DVS and direct-MIDI paths share the same user mixer gain

    func testDVSAndDirectMIDIPathsApplyTheSameLearnedMixerGain() throws {
        let (controller, setNow, setSteps) = try makeController()

        // Set a distinctive, non-unity combined gain once, as a learned
        // fader would.
        controller.setRightUpfaderGain(0.4)
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(1.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.4, accuracy: 0.001)

        // Direct-MIDI continuous path: drive a coalesced tick, then render
        // long enough for the click-free ramp to settle, and read the
        // ACTUAL (ramped) gain the render callback is applying — not just
        // the published target — while MIDI motion is what's active.
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick()
        setNow(1.0 / 60.0); setSteps(400)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true,
            "sanity: the MIDI path must be the one publishing motion")
        _ = peakAmplitude(controller, frames: 3_000) // let the gain ramp settle
        let gainDuringMIDIMotion = controller.dvsContinuousRenderer.testOnly_coreUserMixerGain

        // DVS continuous path: drive a tick through the other entry point.
        // The learned gain was never re-set — if it were tracked
        // separately per motion source, this would silently revert to
        // unity instead of staying at 0.4. (Two ticks: DVS's own position
        // tracking primes on the first real tick, exactly like the
        // existing DVS renderer tests already establish.)
        let window = 1.0 / 60.0
        controller.positionDidChangeContinuous(steps: 440, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 480, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true,
            "sanity: the DVS path must also be publishing motion")
        _ = peakAmplitude(controller, frames: 3_000) // let the gain ramp settle
        let gainDuringDVSMotion = controller.dvsContinuousRenderer.testOnly_coreUserMixerGain

        // The learned gain must still be 0.4 — unaffected by which motion
        // source is driving the renderer — proving both paths are gated
        // by the identical shared user mixer gain, not independent state.
        XCTAssertEqual(gainDuringMIDIMotion, 0.4, accuracy: 0.01)
        XCTAssertEqual(gainDuringDVSMotion, 0.4, accuracy: 0.01)
    }

    // MARK: - Pure cut-curve function

    func testCrossfaderRightDeckGainCurveShape() {
        let cutIn = ScratchSamplePlaybackController.crossfaderCutInWidth
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: 0), 0)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: cutIn), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: cutIn / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: 0.5), 1.0)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: 1.0), 1.0)
    }

    func testCrossfaderRightDeckGainCurveHandlesMalformedInput() {
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: .nan), 0)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: .infinity), 0,
            "non-finite input must fail toward silence, not full volume")
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: -5.0), 0)
        XCTAssertEqual(ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: 5.0), 1.0)
    }

    // MARK: - Configurable fader curves

    func testApplyCrossfaderCurveChangesShapeAppliedToSubsequentPositions() throws {
        let (controller, _, _) = try makeController()
        // Full-width Blend curve instead of the default narrow Sharp Scratch cut-in.
        controller.applyCrossfaderCurve(FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear))
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(0.5)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.5, accuracy: 0.001,
            "under a full-width Blend curve, midpoint gain must be 0.5 — the default Sharp Scratch curve would have already saturated to 1.0 here")
    }

    func testApplyRightUpfaderCurveChangesShapeAppliedToSubsequentPositions() throws {
        let (controller, _, _) = try makeController()
        // Sharp Cut instead of the default full-width Linear.
        let sharpCut = FaderCurvePreset.sharpCut.fixedResponse!
        controller.applyRightUpfaderCurve(sharpCut)
        controller.waitForAudioQueue()
        controller.setRightUpfaderGain(sharpCut.oneAt)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0, accuracy: 0.001,
            "Sharp Cut reaches unity at its narrow boundary, unlike the default Linear curve")
    }

    /// A curve change resets ONLY the affected control to unity — the
    /// other fader's current contribution is preserved (Correction 3).
    func testCurveChangeResetsOnlyAffectedControlToUnity() throws {
        let (controller, _, _) = try makeController()
        controller.setRightUpfaderGain(0.4)
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(1.0) // fully open -> cut curve gain 1.0
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.4, accuracy: 0.001)

        // Changing the CROSSFADER's curve must reset only the crossfader's
        // contribution — the right-upfader's 0.4 must survive untouched.
        controller.applyCrossfaderCurve(FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear))
        controller.waitForAudioQueue()
        // Crossfader's own contribution reset to unity; combined with the
        // UNCHANGED right-upfader 0.4 the product must still read 0.4.
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.4, accuracy: 0.001,
            "right-upfader's current contribution must be untouched by a crossfader curve change")
    }

    /// A curve change must never recompute gain from a stale prior
    /// position — only the NEXT matching event applies the new curve
    /// (Correction 3).
    func testCurveChangeDoesNotRecomputeFromStalePosition() throws {
        let (controller, _, _) = try makeController()
        // Position the crossfader deep in "open" territory under the default curve.
        controller.setCrossfaderPosition(1.0)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0, accuracy: 0.001)

        // Swap to a curve where 1.0 is still fully open — but the point is
        // that the controller must not "remember" the 1.0 and recompute;
        // it must simply reset to unity until a fresh event arrives.
        controller.applyCrossfaderCurve(FaderCurveResponse(zeroAt: 0.9, oneAt: 0.95, shape: .linear))
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 1.0, accuracy: 0.001,
            "reset-to-unity, not a replay of the last position under the new curve")

        // A fresh matching event now applies the new curve.
        controller.setCrossfaderPosition(0.925) // midpoint of the new [0.9, 0.95] window
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.5, accuracy: 0.01)
    }

    func testCombinedGainWithNonDefaultCurvesRemainsMultiplicative() throws {
        let (controller, _, _) = try makeController()
        controller.applyRightUpfaderCurve(FaderCurvePreset.linear.fixedResponse!)
        controller.applyCrossfaderCurve(FaderCurvePreset.blend.fixedResponse!)
        controller.waitForAudioQueue()

        controller.setRightUpfaderGain(0.6)
        controller.waitForAudioQueue()
        controller.setCrossfaderPosition(0.5)
        controller.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(controller), 0.6 * 0.5, accuracy: 0.001)
    }
}
