import XCTest
import AudioToolbox
@testable import ScratchLab

/// Deterministic coverage for `LowLatencySinkLifecycle` — the extracted
/// production-used lifecycle seam behind Slice 2's low-latency DVS
/// sink-node path. `MacCaptureEngine.refreshLowLatencyTimecodeInput()`/
/// `stopLowLatencyTimecodeInput()` call this exact same type
/// (`LowLatencySinkLifecycle.start`/`.stop`) with real closures wrapping
/// `AVAudioEngine`/`AVAudioSinkNode`/the heartbeat; these tests supply
/// recording and failure-simulating closures instead, so the *sequencing*
/// — state transitions, teardown order, idempotency, failed-start cleanup
/// completeness, and stale-session confinement — is proven without any
/// real `AVAudioEngine`, `AVAudioSinkNode`, or hardware anywhere in this
/// file.
///
/// **This does not prove real `AVAudioEngine` graph behavior.** It proves
/// that `MacCaptureEngine`'s own start/catch/stop sequencing is correct —
/// not that the Rane ONE MKII actually delivers sub-4,800-frame callbacks
/// through a real `AVAudioSinkNode` connection, or that a real engine
/// binds/starts cleanly against real AUHAL state. That still requires the
/// hardware acceptance run described in `AI_HANDOFF.md`.
final class LowLatencySinkLifecycleTests: XCTestCase {

    /// Records which closures were invoked, in order. `start`/`stop` invoke
    /// every closure synchronously on the calling thread, but this is made
    /// safe regardless.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []

        func record(_ name: String) {
            lock.withLock { calls.append(name) }
        }
    }

    private func makeActions(
        recorder: CallRecorder,
        startEngineThrows: Bool = false
    ) -> LowLatencySinkLifecycleActions {
        LowLatencySinkLifecycleActions(
            attachAndConnect: { _ in recorder.record("attachAndConnect") },
            startEngine: {
                recorder.record("startEngine")
                if startEngineThrows {
                    throw NSError(domain: "LowLatencySinkLifecycleTests", code: 1)
                }
            },
            stopEngine: { recorder.record("stopEngine") },
            disconnectAndDetach: { recorder.record("disconnectAndDetach") },
            resetEngine: { recorder.record("resetEngine") },
            markHeartbeatInstalled: { recorder.record("markHeartbeatInstalled") },
            resetHeartbeat: { recorder.record("resetHeartbeat") }
        )
    }

    // MARK: - 1. Successful transition to running

    func testSuccessfulStartTransitionsToRunning() {
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()
        let outcome = lifecycle.start(actions: makeActions(recorder: recorder), consumer: { _ in })

        guard case .started(let generation) = outcome else {
            XCTFail("expected .started, got \(outcome)")
            return
        }
        XCTAssertEqual(generation, 1)
        XCTAssertTrue(lifecycle.isSinkAttached)
        XCTAssertTrue(lifecycle.isHeartbeatInstalled)
        XCTAssertNotNil(lifecycle.currentSession)
        XCTAssertEqual(lifecycle.currentSession?.ring.isAcceptingWrites, true)
        XCTAssertEqual(recorder.calls, ["attachAndConnect", "markHeartbeatInstalled", "startEngine"])

        lifecycle.stop(actions: makeActions(recorder: recorder))
    }

    // MARK: - 2. Failed start invokes complete cleanup / partial setup failure leaves nothing behind

    func testFailedStartInvokesCompleteCleanup() {
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()
        var capturedRing: TimecodeRealtimeIngressRing?
        var actions = makeActions(recorder: recorder, startEngineThrows: true)
        actions.attachAndConnect = { ring in
            recorder.record("attachAndConnect")
            capturedRing = ring
        }

        let outcome = lifecycle.start(actions: actions, consumer: { _ in })

        XCTAssertEqual(outcome, .engineStartFailed)
        XCTAssertFalse(lifecycle.isSinkAttached, "a failed start must not leave the sink considered attached")
        XCTAssertFalse(lifecycle.isHeartbeatInstalled, "a failed start must not leave the heartbeat considered installed")
        XCTAssertNil(lifecycle.currentSession, "a failed start must not leave a published current session")
        XCTAssertEqual(
            capturedRing?.isAcceptingWrites, false,
            "a failed start must not leave the session's ring accepting writes"
        )
        XCTAssertEqual(
            recorder.calls,
            ["attachAndConnect", "markHeartbeatInstalled", "startEngine", "stopEngine", "disconnectAndDetach", "resetEngine", "resetHeartbeat"],
            "a failed start must trigger the complete teardown sequence, in order, exactly once"
        )
    }

    func testSessionConstructionFailureNeverCallsAnyGraphAction() {
        // drainInterval: 0 makes TimecodeRealtimeIngressWorker.init? fail,
        // so LowLatencySinkSession(...) itself returns nil before any
        // action closure is ever invoked.
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()

        let outcome = lifecycle.start(
            actions: makeActions(recorder: recorder),
            drainInterval: 0,
            consumer: { _ in }
        )

        XCTAssertEqual(outcome, .sessionConstructionFailed)
        XCTAssertFalse(lifecycle.isSinkAttached)
        XCTAssertFalse(lifecycle.isHeartbeatInstalled)
        XCTAssertNil(lifecycle.currentSession)
        XCTAssertEqual(recorder.calls, [], "no graph action may run if the session itself never constructed")
    }

    // MARK: - 3. Teardown order

    func testTeardownOrderMatchesRequiredSequence() {
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()

        let deliveryLock = NSLock()
        var deliveryCount = 0
        let startOutcome = lifecycle.start(
            actions: makeActions(recorder: recorder),
            consumer: { _ in deliveryLock.withLock { deliveryCount += 1 } }
        )
        guard case .started = startOutcome else {
            XCTFail("setup failed")
            return
        }

        let session = lifecycle.currentSession
        XCTAssertEqual(publish(session!.ring, channels: [[1, 2], [3, 4]]), .published)

        var ringWasAlreadyClosedWhenStopEngineRan = false
        var sessionWasStillPublishedDuringDisconnect = false
        var actions = makeActions(recorder: recorder)
        actions.stopEngine = {
            recorder.record("stopEngine")
            ringWasAlreadyClosedWhenStopEngineRan = (session?.ring.isAcceptingWrites == false)
        }
        actions.disconnectAndDetach = {
            recorder.record("disconnectAndDetach")
            sessionWasStillPublishedDuringDisconnect = (lifecycle.currentSession != nil)
        }

        lifecycle.stop(actions: actions)

        XCTAssertTrue(
            ringWasAlreadyClosedWhenStopEngineRan,
            "step (1) close producer acceptance must happen before step (2) stop producer"
        )
        XCTAssertTrue(
            sessionWasStillPublishedDuringDisconnect,
            "published session state must not be cleared before step (3) disconnect/detach runs"
        )
        XCTAssertNil(lifecycle.currentSession, "published session state must be cleared once stop() returns")
        XCTAssertFalse(lifecycle.isSinkAttached)
        XCTAssertEqual(
            recorder.calls.suffix(4),
            ["stopEngine", "disconnectAndDetach", "resetEngine", "resetHeartbeat"],
            "steps (2)-(5)'s observable actions must run in exactly this order"
        )

        // Step (4) synchronously stop the worker: whatever delivery count
        // existed the instant stop() returned is final — no wait needed to
        // prove this, matching TimecodeRealtimeIngressRingTests
        // .testWorkerStopSynchronouslyPreventsLaterDelivery's own guarantee,
        // now proven through the lifecycle's own stop() call rather than
        // the raw worker directly.
        let countAtStop = deliveryLock.withLock { deliveryCount }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(
            deliveryLock.withLock { deliveryCount }, countAtStop,
            "no further delivery may occur once the lifecycle's stop() has returned"
        )
    }

    // MARK: - 4. Repeated stop is idempotent

    func testRepeatedStopIsIdempotent() {
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()
        let startOutcome = lifecycle.start(actions: makeActions(recorder: recorder), consumer: { _ in })
        guard case .started = startOutcome else {
            XCTFail("setup failed")
            return
        }

        lifecycle.stop(actions: makeActions(recorder: recorder))
        let callsAfterFirstStop = recorder.calls

        lifecycle.stop(actions: makeActions(recorder: recorder))
        let callsAfterSecondStop = recorder.calls

        XCTAssertFalse(lifecycle.isSinkAttached)
        XCTAssertFalse(lifecycle.isHeartbeatInstalled)
        XCTAssertNil(lifecycle.currentSession)
        // disconnectAndDetach must not run again once isSinkAttached is
        // already false — the second stop() only re-runs stopEngine/
        // resetEngine/resetHeartbeat (all independently safe to repeat).
        XCTAssertEqual(
            Array(callsAfterSecondStop[callsAfterFirstStop.count...]),
            ["stopEngine", "resetEngine", "resetHeartbeat"],
            "a second stop() must not attempt another disconnectAndDetach"
        )

        // A third stop() for good measure — still safe, still no crash,
        // still consistent final state.
        lifecycle.stop(actions: makeActions(recorder: recorder))
        XCTAssertFalse(lifecycle.isSinkAttached)
        XCTAssertNil(lifecycle.currentSession)
    }

    // MARK: - 5. A stale prior-session callback remains confined to its old closed ring

    func testStaleSessionRemainsConfinedAcrossStartStopStart() {
        let lifecycle = LowLatencySinkLifecycle()
        let recorder = CallRecorder()

        let firstOutcome = lifecycle.start(actions: makeActions(recorder: recorder), consumer: { _ in })
        guard case .started(let firstGeneration) = firstOutcome else {
            XCTFail("first start failed")
            return
        }
        let sessionA = lifecycle.currentSession

        lifecycle.stop(actions: makeActions(recorder: recorder))

        let secondOutcome = lifecycle.start(actions: makeActions(recorder: recorder), consumer: { _ in })
        guard case .started(let secondGeneration) = secondOutcome else {
            XCTFail("second start failed")
            return
        }
        let sessionB = lifecycle.currentSession
        defer { lifecycle.stop(actions: makeActions(recorder: recorder)) }

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertTrue(sessionA !== sessionB, "each start must produce a genuinely distinct session")
        XCTAssertTrue(sessionA?.ring !== sessionB?.ring, "each start must produce a genuinely distinct ring")

        XCTAssertEqual(
            publish(sessionA!.ring, channels: [[1, 2], [3, 4]]),
            .rejectedNotAcceptingWrites,
            "the old, torn-down session's ring must remain closed regardless of the replacement session's state"
        )
        XCTAssertEqual(
            publish(sessionB!.ring, channels: [[1, 2], [3, 4]]),
            .published,
            "the replacement session's ring must accept writes normally"
        )
    }

    // MARK: - Fixture helper (mirrors TimecodeRealtimeIngressRingTests / LowLatencyTimecodeSinkSessionTests)

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
}
