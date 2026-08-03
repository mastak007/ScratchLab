import XCTest
import AudioToolbox
import AVFoundation
@testable import ScratchLab

/// Deterministic coverage for Slice 2 — the low-latency DVS
/// `AVAudioSinkNode` ingress path's pure/testable seams:
/// `validateLowLatencySinkFormat`, `LowLatencySinkSession` (ring + worker +
/// generation bundling), and the ring-diagnostic formatter/marker-replace
/// helpers. No `AVAudioEngine`, no `AVAudioSinkNode`, no hardware — every
/// test talks directly to the pure types `MacCaptureEngine` wires the real
/// sink node to, exactly as `TimecodeRealtimeIngressRingTests` does for
/// Slice 1's ring/worker. The actual `AVAudioEngine`/`AVAudioSinkNode` graph
/// wiring inside `MacCaptureEngine.refreshLowLatencyTimecodeInput()` is
/// integration-level code that requires real hardware to meaningfully
/// exercise and is intentionally not faked here — see the real Rane
/// acceptance step in `AI_HANDOFF.md` for that verification.
final class LowLatencyTimecodeSinkSessionTests: XCTestCase {

    // MARK: - Fixture helpers (mirrors TimecodeRealtimeIngressRingTests)

    private func makeAudioBufferListFixture(
        channels: [[Float]]
    ) -> (list: UnsafeMutablePointer<AudioBufferList>, cleanup: () -> Void) {
        let channelCount = max(channels.count, 1)
        let byteSize = MemoryLayout<AudioBufferList>.size
            + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteSize,
            alignment: max(16, MemoryLayout<AudioBufferList>.alignment)
        )
        let listPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPointer.pointee = AudioBufferList(
            mNumberBuffers: UInt32(channels.count),
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        let abl = UnsafeMutableAudioBufferListPointer(listPointer)
        var channelBuffers: [UnsafeMutablePointer<Float>] = []
        for (index, channel) in channels.enumerated() {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(channel.count, 1))
            buffer.update(from: channel, count: channel.count)
            channelBuffers.append(buffer)
            abl[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(channel.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer)
            )
        }
        let cleanup = {
            for buffer in channelBuffers { buffer.deallocate() }
            rawPointer.deallocate()
        }
        return (listPointer, cleanup)
    }

    @discardableResult
    private func publish(
        _ ring: TimecodeRealtimeIngressRing,
        channels: [[Float]],
        sampleRate: Double = 48_000,
        hostTime: UInt64 = 0,
        sampleTime: Int64 = 0
    ) -> TimecodeRealtimeIngressPublishOutcome {
        let (list, cleanup) = makeAudioBufferListFixture(channels: channels)
        defer { cleanup() }
        return ring.publish(
            bufferList: list,
            frameCount: channels.first?.count ?? 0,
            expectedChannelCount: channels.count,
            sampleRate: sampleRate,
            hostTime: hostTime,
            sampleTime: sampleTime
        )
    }

    // MARK: - 1. Format validation (pure, no hardware)

    func testFormatValidationAcceptsFloat32NonInterleaved() {
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatFloat32,
                isInterleaved: false,
                sampleRate: 48_000,
                channelCount: 14,
                ringConfiguration: .production
            ),
            .valid
        )
    }

    func testFormatValidationRejectsNonFloat32() {
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatInt16,
                isInterleaved: false,
                sampleRate: 48_000,
                channelCount: 2,
                ringConfiguration: .production
            ),
            .rejectedUnsupportedCommonFormat
        )
    }

    func testFormatValidationRejectsInterleavedBuffers() {
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatFloat32,
                isInterleaved: true,
                sampleRate: 48_000,
                channelCount: 2,
                ringConfiguration: .production
            ),
            .rejectedInterleavedFormat
        )
    }

    func testFormatValidationRejectsNonFiniteOrNonPositiveSampleRate() {
        for sampleRate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(
                validateLowLatencySinkFormat(
                    commonFormat: .pcmFormatFloat32,
                    isInterleaved: false,
                    sampleRate: sampleRate,
                    channelCount: 2,
                    ringConfiguration: .production
                ),
                .rejectedInvalidSampleRate,
                "sampleRate \(sampleRate) must be rejected"
            )
        }
    }

    func testFormatValidationRejectsChannelCountOutOfRange() {
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatFloat32,
                isInterleaved: false,
                sampleRate: 48_000,
                channelCount: 0,
                ringConfiguration: .production
            ),
            .rejectedChannelCountOutOfRange,
            "zero channels must be rejected"
        )
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatFloat32,
                isInterleaved: false,
                sampleRate: 48_000,
                channelCount: TimecodeRealtimeIngressRingConfiguration.production.maximumChannelCount + 1,
                ringConfiguration: .production
            ),
            .rejectedChannelCountOutOfRange,
            "more channels than the ring's configured maximum must be rejected"
        )
        XCTAssertEqual(
            validateLowLatencySinkFormat(
                commonFormat: .pcmFormatFloat32,
                isInterleaved: false,
                sampleRate: 48_000,
                channelCount: TimecodeRealtimeIngressRingConfiguration.production.maximumChannelCount,
                ringConfiguration: .production
            ),
            .valid,
            "exactly the ring's configured maximum must be accepted"
        )
    }

    // MARK: - 1b. safeSampleTime — realtime-safe AudioTimeStamp.mSampleTime conversion

    func testSafeSampleTimeAcceptsOrdinaryValues() {
        XCTAssertEqual(safeSampleTime(0), 0)
        XCTAssertEqual(safeSampleTime(1_000), 1_000)
        XCTAssertEqual(safeSampleTime(-1_000), -1_000)
    }

    func testSafeSampleTimeRejectsNonFiniteValues() {
        XCTAssertNil(safeSampleTime(Double.nan), "NaN must not trap Int64(Double)")
        XCTAssertNil(safeSampleTime(Double.infinity), "+infinity must not trap Int64(Double)")
        XCTAssertNil(safeSampleTime(-Double.infinity), "-infinity must not trap Int64(Double)")
    }

    func testSafeSampleTimeAcceptsExactBoundariesAndRejectsOneStepBeyond() {
        // 2^63, exactly representable as Double. Int64.max (2^63 - 1) is
        // the largest value that fits — anything >= 2^63 does not.
        let twoTo63 = 9_223_372_036_854_775_808.0
        XCTAssertNil(safeSampleTime(twoTo63), "2^63 itself does not fit Int64 and must be rejected, not trapped")
        XCTAssertEqual(safeSampleTime(-twoTo63), Int64.min, "-2^63 is exactly Int64.min and must be accepted")
        // Near magnitude 2^63, Double's representable step (ULP) is 2^11 =
        // 2048 — subtracting less than that (e.g. 1_024) rounds right back
        // to -2^63 itself and would not actually test "below the boundary".
        // 4_096 is two full ULPs, guaranteeing a genuinely smaller, distinct
        // representable value.
        XCTAssertNil(safeSampleTime(-twoTo63 - 4_096), "anything below -2^63 must be rejected")
        // A value just under 2^63 must convert without trapping.
        XCTAssertNotNil(safeSampleTime(twoTo63 - 1_024))
    }

    func testSafeSampleTimeRejectsMagnitudesFarBeyondInt64Range() {
        XCTAssertNil(safeSampleTime(1.0e30), "an astronomically large finite value must not trap Int64(Double)")
        XCTAssertNil(safeSampleTime(-1.0e30))
    }

    // MARK: - 2. LowLatencySinkSession construction

    func testSessionConstructionFailsForInvalidDrainInterval() {
        for invalidInterval in [0.0, -0.001, Double.nan, Double.infinity] {
            XCTAssertNil(
                LowLatencySinkSession(
                    generation: 1,
                    drainInterval: invalidInterval,
                    consumer: { _ in }
                ),
                "drainInterval \(invalidInterval) must fail session construction, not silently default"
            )
        }
    }

    func testEachSessionGetsADistinctRingAndWorkerInstance() throws {
        let sessionA = try XCTUnwrap(LowLatencySinkSession(generation: 1, consumer: { _ in }))
        let sessionB = try XCTUnwrap(LowLatencySinkSession(generation: 2, consumer: { _ in }))
        defer {
            sessionA.tearDown()
            sessionB.tearDown()
        }
        XCTAssertNotEqual(sessionA.generation, sessionB.generation)
        XCTAssertTrue(sessionA.ring !== sessionB.ring, "each session must own a genuinely distinct ring instance")
        XCTAssertTrue(sessionA.worker !== sessionB.worker, "each session must own a genuinely distinct worker instance")
    }

    // MARK: - 3. Lifecycle: successful "start", orderly stop, repeated stop

    func testSessionAcceptsPublishesUntilTornDown() throws {
        let session = try XCTUnwrap(LowLatencySinkSession(generation: 1, consumer: { _ in }))
        defer { session.tearDown() }

        XCTAssertTrue(session.ring.isAcceptingWrites)
        XCTAssertEqual(publish(session.ring, channels: [[1, 2, 3], [4, 5, 6]]), .published)
        XCTAssertEqual(session.ring.publishedCount, 1)
    }

    func testTearDownClosesRingToNewWrites() throws {
        let session = try XCTUnwrap(LowLatencySinkSession(generation: 1, consumer: { _ in }))
        session.tearDown()

        XCTAssertFalse(session.ring.isAcceptingWrites)
        XCTAssertEqual(
            publish(session.ring, channels: [[1, 2], [3, 4]]),
            .rejectedNotAcceptingWrites,
            "a publish after tearDown() must be rejected, never silently accepted"
        )
    }

    func testRepeatedTearDownIsIdempotent() throws {
        let session = try XCTUnwrap(LowLatencySinkSession(generation: 1, consumer: { _ in }))
        session.tearDown()
        session.tearDown()
        session.tearDown()

        XCTAssertFalse(session.ring.isAcceptingWrites)
        XCTAssertEqual(publish(session.ring, channels: [[1], [2]]), .rejectedNotAcceptingWrites)
    }

    // MARK: - 4. Stale session cannot deliver into a replacement session

    func testStaleTornDownSessionCannotAffectAReplacementSessionsRing() throws {
        let sessionA = try XCTUnwrap(LowLatencySinkSession(generation: 1, consumer: { _ in }))
        sessionA.tearDown()

        let sessionB = try XCTUnwrap(LowLatencySinkSession(generation: 2, consumer: { _ in }))
        defer { sessionB.tearDown() }

        // sessionA's ring stays closed regardless of what happens to sessionB.
        XCTAssertEqual(publish(sessionA.ring, channels: [[1], [2]]), .rejectedNotAcceptingWrites)
        // sessionB is a completely independent, freshly-accepting ring.
        XCTAssertTrue(sessionB.ring.isAcceptingWrites)
        XCTAssertEqual(publish(sessionB.ring, channels: [[1], [2]]), .published)
        XCTAssertEqual(sessionB.ring.publishedCount, 1)
        XCTAssertEqual(sessionA.ring.publishedCount, 0, "sessionA must never receive sessionB's data or vice versa")
    }

    // MARK: - 5. Worker delivery into a consumer (stand-in for the adapter/heartbeat path)

    func testWorkerDeliversPublishedSlotsToConsumer() throws {
        let delivered = DeliveryRecorder()
        // Fulfilled from inside the consumer closure itself, on the
        // worker's own queue — `wait(for:)` below blocks until the real
        // delivery event occurs; the timeout is only a failure bound, never
        // the mechanism deciding whether delivery happened (matches
        // `TimecodeRealtimeIngressRingTests`'s own expectation-based tests).
        let deliveredExpectation = expectation(description: "worker delivered the published slot")
        let session = try XCTUnwrap(LowLatencySinkSession(
            generation: 1,
            drainInterval: 0.005,
            consumer: { slot in
                delivered.record(
                    frameCount: slot.frameCount,
                    channelCount: slot.channelCount,
                    firstSample: slot.samples(forChannel: 0)[0]
                )
                deliveredExpectation.fulfill()
            }
        ))
        defer { session.tearDown() }

        XCTAssertEqual(publish(session.ring, channels: [[10, 11, 12], [20, 21, 22]]), .published)

        wait(for: [deliveredExpectation], timeout: 2.0)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.lastFrameCount, 3)
        XCTAssertEqual(delivered.lastChannelCount, 2)
        XCTAssertEqual(delivered.lastFirstSample, 10)
    }

    // MARK: - 6. No delivery after stop() returns

    func testNoDeliveryAfterTearDownReturns() throws {
        let delivered = DeliveryRecorder()
        let session = try XCTUnwrap(LowLatencySinkSession(
            generation: 1,
            drainInterval: 0.005,
            consumer: { slot in
                delivered.record(
                    frameCount: slot.frameCount,
                    channelCount: slot.channelCount,
                    firstSample: slot.samples(forChannel: 0)[0]
                )
            }
        ))

        XCTAssertEqual(publish(session.ring, channels: [[1, 2], [3, 4]]), .published)
        session.tearDown()

        // `tearDown()` → `TimecodeRealtimeIngressWorker.stop()`'s existing
        // barrier synchronously guarantees no further consumer delivery once
        // this call returns (proven directly against the ring/worker in
        // `TimecodeRealtimeIngressRingTests
        // .testWorkerStopSynchronouslyPreventsLaterDelivery`). Reading
        // `delivered.count` here is therefore already a final, deterministic
        // snapshot — whatever it is (0 or 1, depending on whether the
        // worker's 5ms timer happened to fire before `tearDown()` ran), it
        // can never increase again. No wait is needed to establish this;
        // this assertion does not depend on timing.
        let countAtStop = delivered.count

        // Defense-in-depth only, reusing the same bounded-sleep-then-recheck
        // idiom `TimecodeRealtimeIngressRingTests` already uses for this
        // exact class of proof (a fixed wait here is legitimate because it
        // is proving an *absence* — nothing may happen in this window — not
        // waiting for a real event to decide correctness).
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(
            delivered.count, countAtStop,
            "no further delivery may occur once tearDown() has returned"
        )
    }

    // MARK: - 7. Ring-full drop-newest is surfaced honestly

    func testRingFullDropNewestIsSurfacedByTheDiagnosticCounters() throws {
        let smallConfig = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: 4
        )!
        // A drain interval long enough that the slots fill before the worker
        // has a realistic chance to drain any of them.
        let session = try XCTUnwrap(LowLatencySinkSession(
            generation: 1,
            ringConfiguration: smallConfig,
            drainInterval: 5.0,
            consumer: { _ in }
        ))
        defer { session.tearDown() }

        for value in 0..<5 {
            publish(session.ring, channels: [[Float(value), Float(value), Float(value), Float(value)]])
        }

        XCTAssertEqual(session.ring.publishedCount, 2, "only the ring's 2 slots can ever be published before it fills")
        XCTAssertEqual(session.ring.droppedCount, 3, "the remaining 3 publishes must be dropped-newest, not silently lost")

        let diagnostic = LowLatencySinkRingDiagnostic(
            publishedCount: session.ring.publishedCount,
            droppedCount: session.ring.droppedCount,
            rejectedCount: session.ring.rejectedCount
        )
        XCTAssertTrue(formatLowLatencySinkRingDiagnostic(diagnostic).contains("dropped=3"))
    }

    // MARK: - 8. Ring diagnostic marker replace/strip helper

    func testApplyingLowLatencySinkRingDiagnosticAppendsWhenAbsent() {
        let diagnostic = LowLatencySinkRingDiagnostic(publishedCount: 10, droppedCount: 1, rejectedCount: 0)
        let result = applyingLowLatencySinkRingDiagnostic(to: "device=Rane", diagnostic: diagnostic)
        XCTAssertEqual(result, "device=Rane | DVS sink ring: published=10 dropped=1 rejected=0")
    }

    func testApplyingLowLatencySinkRingDiagnosticReplacesWithoutDuplicating() {
        let first = applyingLowLatencySinkRingDiagnostic(
            to: "device=Rane",
            diagnostic: LowLatencySinkRingDiagnostic(publishedCount: 1, droppedCount: 0, rejectedCount: 0)
        )
        let second = applyingLowLatencySinkRingDiagnostic(
            to: first,
            diagnostic: LowLatencySinkRingDiagnostic(publishedCount: 2, droppedCount: 0, rejectedCount: 0)
        )
        XCTAssertEqual(second, "device=Rane | DVS sink ring: published=2 dropped=0 rejected=0")
        XCTAssertEqual(second.components(separatedBy: "DVS sink ring:").count, 2, "marker must appear at most once")
    }

    func testApplyingLowLatencySinkRingDiagnosticStripsMarkerWhenNil() {
        let withMarker = applyingLowLatencySinkRingDiagnostic(
            to: "device=Rane",
            diagnostic: LowLatencySinkRingDiagnostic(publishedCount: 1, droppedCount: 0, rejectedCount: 0)
        )
        let stripped = applyingLowLatencySinkRingDiagnostic(to: withMarker, diagnostic: nil)
        XCTAssertEqual(stripped, "device=Rane")
    }

    // MARK: - 9. Real Rane hardware finding regression: generic AVAudioFormat
    // reconstruction returns nil for 14 channels

    /// Documents, permanently, the exact real-hardware failure this task
    /// fixed — reproduced deterministically (not guessed) via a standalone
    /// script before this test was written. Guards against ever going back
    /// to reconstructing a generic format from only sample rate/channel
    /// count: `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`
    /// has no standard channel layout for 14 channels and returns `nil`,
    /// which is exactly why `handleLowLatencySinkDelivery` must use the
    /// exact, already-validated sink connection format instead.
    func testGenericAVAudioFormatReconstructionReturnsNilFor14Channels() {
        XCTAssertNil(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 14,
                interleaved: false
            ),
            "this is the exact real-hardware failure mode — 14 channels has no standard layout"
        )
    }

    // MARK: - 10. Adapter-path regression: real 14ch × 512f × 48kHz slot

    /// Builds a real 14-channel `AVAudioFormat` the way an actual
    /// `AVAudioIONode.inputFormat(forBus:)`/`outputFormat(forBus:)` would —
    /// via an explicit discrete channel layout — standing in for the real
    /// Rane hardware's `tapFormat` without needing hardware.
    private func makeDiscrete14ChannelFormat(sampleRate: Double = 48_000) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 14)
        )
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }

    func testAdapterPathConvertsReal14ChannelSlotAndPreservesPair3And4() throws {
        let originalSelection = TimecodeCMSampleBufferAdapter.channelPairSelection
        defer { TimecodeCMSampleBufferAdapter.channelPairSelection = originalSelection }
        TimecodeCMSampleBufferAdapter.channelPairSelection = .pair(startChannel: 2) // physical pair 3/4

        let sampleRate = 48_000.0
        let frameCount = 512
        let channelCount = 14
        // Distinct, deterministic per-channel data so exact channel-index
        // preservation (not just "some data flowed") is provable.
        let channels: [[Float]] = (0..<channelCount).map { channel in
            (0..<frameCount).map { frame in Float(channel) + Float(frame) / Float(frameCount) }
        }

        let ringConfiguration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: channelCount, maximumFrameCountPerSlot: frameCount
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: ringConfiguration)
        XCTAssertEqual(
            publish(ring, channels: channels, sampleRate: sampleRate, hostTime: 999),
            .published
        )

        let format = try makeDiscrete14ChannelFormat(sampleRate: sampleRate)

        var conversionOutcome: LowLatencySinkAdapterConversionOutcome?
        var adapterResult: TimecodeCMSampleBufferAdapter.StereoResult?
        ring.drainPending { slot in
            let outcome = makeLowLatencySinkPCMBuffer(fromSlot: slot, format: format)
            conversionOutcome = outcome
            if case .succeeded(let pcmBuffer) = outcome {
                adapterResult = TimecodeCMSampleBufferAdapter.stereoSampleResult(
                    fromPCMBuffer: pcmBuffer,
                    hostTime: slot.hostTime
                )
            }
        }

        guard case .succeeded = conversionOutcome else {
            XCTFail("expected PCM buffer conversion to succeed for a real 14ch/512f/48kHz slot — this is the exact real Rane capture scenario")
            return
        }
        let result = try XCTUnwrap(
            adapterResult,
            "heartbeat/callback delivery can only occur once the adapter actually produces a result"
        )

        XCTAssertEqual(result.sourceChannelCount, 14)
        XCTAssertEqual(result.selectedChannelPair, "3/4")
        XCTAssertEqual(result.frameCount, frameCount)
        XCTAssertEqual(result.sampleRate, sampleRate)
        XCTAssertEqual(result.hostTime, 999)
        // Physical pair 3/4 = 0-indexed channels 2 (left) and 3 (right).
        XCTAssertEqual(result.left[10], channels[2][10], accuracy: 0.000_001)
        XCTAssertEqual(result.right[10], channels[3][10], accuracy: 0.000_001)
        // Every original channel index must still be exactly what was
        // published — proves no collapsing/mixing occurred before the
        // adapter's own pair selection ran on channel 3/4 specifically.
        XCTAssertNotEqual(result.left[10], channels[4][10], "must not have collapsed a different pair's data into the selected pair")
    }

    func testAdapterPathFailsClosedOnChannelCountMismatch() throws {
        let frameCount = 512
        let channelCount = 14
        let channels: [[Float]] = (0..<channelCount).map { channel in
            (0..<frameCount).map { Float(channel) + Float($0) }
        }
        let ringConfiguration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: channelCount, maximumFrameCountPerSlot: frameCount
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: ringConfiguration)
        XCTAssertEqual(publish(ring, channels: channels), .published)

        // A format that does not match the slot's actual channel count —
        // must fail closed with a specific, diagnosable stage, never crash.
        let mismatchedFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )

        var outcome: LowLatencySinkAdapterConversionOutcome?
        ring.drainPending { slot in
            outcome = makeLowLatencySinkPCMBuffer(fromSlot: slot, format: mismatchedFormat)
        }
        guard case .failed(let stage) = outcome else {
            XCTFail("expected a closed failure, got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(stage, .channelCountMismatch)
    }

    // MARK: - 11. Worker-observed diagnostic reports real hardware evidence
    // without making fallback-freshness claims

    func testWorkerObservationDiagnosticReportsRealFrameCountWithoutFreshnessClaims() {
        let diagnostic = LowLatencySinkWorkerObservationDiagnostic(
            frameCount: 512, channelCount: 14, sampleRate: 48_000
        )
        let formatted = formatLowLatencySinkWorkerObservationDiagnostic(diagnostic)
        XCTAssertEqual(formatted, "512f@48000Hz,14ch")
        XCTAssertFalse(formatted.contains("route="), "must not make any fallback-routing claim — that's the heartbeat's job alone")
        XCTAssertFalse(formatted.lowercased().contains("fresh"), "must not make any freshness claim — that's the heartbeat's job alone")
    }

    func testApplyingLowLatencySinkWorkerObservationDiagnosticAppendsReplacesAndStrips() {
        let first = applyingLowLatencySinkWorkerObservationDiagnostic(
            to: "device=Rane",
            diagnostic: LowLatencySinkWorkerObservationDiagnostic(frameCount: 512, channelCount: 14, sampleRate: 48_000)
        )
        XCTAssertEqual(first, "device=Rane | DVS sink observed: 512f@48000Hz,14ch")

        let second = applyingLowLatencySinkWorkerObservationDiagnostic(
            to: first,
            diagnostic: LowLatencySinkWorkerObservationDiagnostic(frameCount: 256, channelCount: 14, sampleRate: 48_000)
        )
        XCTAssertEqual(second, "device=Rane | DVS sink observed: 256f@48000Hz,14ch")
        XCTAssertEqual(second.components(separatedBy: "DVS sink observed:").count, 2, "marker must appear at most once")

        let stripped = applyingLowLatencySinkWorkerObservationDiagnostic(to: second, diagnostic: nil)
        XCTAssertEqual(stripped, "device=Rane")
    }
}

/// Thread-safe recorder for consumer-delivery assertions — the worker calls
/// `consumer` from its own private serial queue, never the test's thread.
private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveryCount = 0
    private var frameCount = 0
    private var channelCount = 0
    private var firstSample: Float = 0

    func record(frameCount: Int, channelCount: Int, firstSample: Float) {
        lock.withLock {
            self.deliveryCount += 1
            self.frameCount = frameCount
            self.channelCount = channelCount
            self.firstSample = firstSample
        }
    }

    var count: Int { lock.withLock { deliveryCount } }
    var lastFrameCount: Int { lock.withLock { frameCount } }
    var lastChannelCount: Int { lock.withLock { channelCount } }
    var lastFirstSample: Float { lock.withLock { firstSample } }
}
