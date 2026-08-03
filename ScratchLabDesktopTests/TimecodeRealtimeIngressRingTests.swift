import XCTest
import AudioToolbox
@testable import ScratchLab

/// Deterministic coverage for `TimecodeRealtimeIngressRing`/`Worker` — the
/// Slice 1 realtime ingress primitive. No `AVAudioEngine`, no hardware, no
/// dependency on `MacCaptureEngine`/the DVS pipeline: every test constructs
/// its own `AudioBufferList` fixtures and talks to the ring/worker directly.
final class TimecodeRealtimeIngressRingTests: XCTestCase {

    private let smallConfig = TimecodeRealtimeIngressRingConfiguration(
        slotCount: 4, maximumChannelCount: 4, maximumFrameCountPerSlot: 16
    )!

    // MARK: - Fixture helper

    /// Builds a real, standalone `AudioBufferList` (one non-interleaved
    /// Float32 buffer per channel), matching the shape `MacCaptureEngine`'s
    /// own `audioPacket(from:)` already constructs elsewhere in this
    /// codebase. The caller must invoke the returned `cleanup` closure
    /// exactly once, after the list is no longer needed.
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
        frameCount: Int? = nil,
        expectedChannelCount: Int? = nil,
        sampleRate: Double = 48_000,
        hostTime: UInt64 = 0,
        sampleTime: Int64 = 0
    ) -> TimecodeRealtimeIngressPublishOutcome {
        let (list, cleanup) = makeAudioBufferListFixture(channels: channels)
        defer { cleanup() }
        return ring.publish(
            bufferList: list,
            frameCount: frameCount ?? (channels.first?.count ?? 0),
            expectedChannelCount: expectedChannelCount ?? channels.count,
            sampleRate: sampleRate,
            hostTime: hostTime,
            sampleTime: sampleTime
        )
    }

    // MARK: - 1. Configuration validation

    func testConfigurationRejectsInvalidValues() {
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 1, maximumChannelCount: 2, maximumFrameCountPerSlot: 16
        ), "fewer than 2 slots must be rejected")
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 4, maximumChannelCount: 0, maximumFrameCountPerSlot: 16
        ), "zero channels must be rejected")
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 4, maximumChannelCount: 2, maximumFrameCountPerSlot: 0
        ), "zero frames must be rejected")
        XCTAssertNotNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: 1
        ))
    }

    func testProductionConfigurationMatchesDocumentedDefaults() {
        let configuration = TimecodeRealtimeIngressRingConfiguration.production
        XCTAssertEqual(configuration.slotCount, 8)
        XCTAssertEqual(configuration.maximumChannelCount, 32)
        XCTAssertEqual(configuration.maximumFrameCountPerSlot, 8_192)
    }

    // MARK: - 2. Wraparound and data integrity

    func testWraparoundPreservesDataIntegrity() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 3, maximumChannelCount: 1, maximumFrameCountPerSlot: 4
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        var drainedValues: [[Float]] = []

        for round in 0..<10 {
            let value = Float(round)
            XCTAssertEqual(
                publish(ring, channels: [[value, value, value, value]], hostTime: UInt64(round)),
                .published
            )
            ring.drainPending { slot in
                drainedValues.append(Array(slot.samples(forChannel: 0)))
            }
        }

        XCTAssertEqual(drainedValues.count, 10)
        for (round, values) in drainedValues.enumerated() {
            XCTAssertEqual(values, Array(repeating: Float(round), count: 4))
        }
    }

    // MARK: - 3. Full-ring drop-newest

    func testFullRingDropsNewestAndPreservesOldest() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: 1
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)

        XCTAssertEqual(publish(ring, channels: [[1]]), .published)
        XCTAssertEqual(publish(ring, channels: [[2]]), .published)
        XCTAssertEqual(publish(ring, channels: [[3]]), .droppedRingFull)
        XCTAssertEqual(ring.droppedCount, 1)
        XCTAssertEqual(ring.publishedCount, 2)

        var drained: [Float] = []
        ring.drainPending { drained.append($0.samples(forChannel: 0)[0]) }
        XCTAssertEqual(drained, [1, 2], "oldest pending data must survive; the dropped newest value must never appear")
    }

    // MARK: - 4. Variable frame counts

    func testVariableFrameCountsDoNotCrossContaminate() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 4, maximumChannelCount: 1, maximumFrameCountPerSlot: 8
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        let frameCounts = [1, 8, 3, 5]

        for count in frameCounts {
            let channel = (0..<count).map { Float($0) }
            XCTAssertEqual(publish(ring, channels: [channel]), .published)
        }

        var drainedCounts: [Int] = []
        var drainedValues: [[Float]] = []
        ring.drainPending { slot in
            drainedCounts.append(slot.frameCount)
            drainedValues.append(Array(slot.samples(forChannel: 0)))
        }

        XCTAssertEqual(drainedCounts, frameCounts)
        for (index, count) in frameCounts.enumerated() {
            XCTAssertEqual(drainedValues[index], (0..<count).map { Float($0) })
        }
    }

    // MARK: - 5. 14-channel non-interleaved fidelity

    func testFourteenChannelNonInterleavedCopyFidelity() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 14, maximumFrameCountPerSlot: 16
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        let channels = (0..<14).map { channel in (0..<16).map { Float(channel * 100 + $0) } }

        XCTAssertEqual(publish(ring, channels: channels), .published)

        var drainedChannels: [[Float]] = []
        ring.drainPending { slot in
            XCTAssertEqual(slot.channelCount, 14)
            for channel in 0..<14 {
                drainedChannels.append(Array(slot.samples(forChannel: channel)))
            }
        }
        XCTAssertEqual(drainedChannels, channels)
    }

    // MARK: - 6. Malformed buffer count

    func testMismatchedBufferCountIsRejected() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let outcome = publish(ring, channels: [[1, 2], [3, 4], [5, 6]], expectedChannelCount: 2)
        XCTAssertEqual(outcome, .rejectedBufferCountMismatch)
        XCTAssertEqual(ring.rejectedCount, 1)
        XCTAssertEqual(ring.publishedCount, 0)
    }

    // MARK: - 7. Multi-channel-per-buffer rejection

    func testMultiChannelPerBufferIsRejected() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let (list, cleanup) = makeAudioBufferListFixture(channels: [[1, 2, 3, 4]])
        defer { cleanup() }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: abl[0].mDataByteSize, mData: abl[0].mData)

        let outcome = ring.publish(
            bufferList: list, frameCount: 2, expectedChannelCount: 1,
            sampleRate: 48_000, hostTime: 0, sampleTime: 0
        )
        XCTAssertEqual(outcome, .rejectedMultiChannelBuffer)
    }

    // MARK: - 8. Nil / undersized data rejection

    func testNilDataPointerIsRejected() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let (list, cleanup) = makeAudioBufferListFixture(channels: [[1, 2]])
        defer { cleanup() }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: abl[0].mDataByteSize, mData: nil)

        let outcome = ring.publish(
            bufferList: list, frameCount: 2, expectedChannelCount: 1,
            sampleRate: 48_000, hostTime: 0, sampleTime: 0
        )
        XCTAssertEqual(outcome, .rejectedNilData)
    }

    func testUndersizedDataByteSizeIsRejected() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let (list, cleanup) = makeAudioBufferListFixture(channels: [[1, 2, 3, 4]])
        defer { cleanup() }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        abl[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(MemoryLayout<Float>.size),
            mData: abl[0].mData
        )

        let outcome = ring.publish(
            bufferList: list, frameCount: 4, expectedChannelCount: 1,
            sampleRate: 48_000, hostTime: 0, sampleTime: 0
        )
        XCTAssertEqual(outcome, .rejectedUndersizedData)
    }

    // MARK: - 9. Over-bound frame/channel rejection

    func testOverBoundFrameCountIsRejected() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 2, maximumFrameCountPerSlot: 4
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        let channel = Array(repeating: Float(0), count: 8)
        let outcome = publish(ring, channels: [channel, channel])
        XCTAssertEqual(outcome, .rejectedInvalidFrameCount)
    }

    func testOverBoundChannelCountIsRejected() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 2, maximumFrameCountPerSlot: 4
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        let channel: [Float] = [1, 2]
        let outcome = publish(
            ring, channels: [channel, channel, channel], expectedChannelCount: 3
        )
        XCTAssertEqual(outcome, .rejectedInvalidChannelCount)
    }

    // MARK: - 10. Timestamp / sample-time preservation

    func testTimestampAndSampleTimePreservedThroughDrain() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        XCTAssertEqual(
            publish(
                ring, channels: [[1, 2], [3, 4]],
                sampleRate: 44_100, hostTime: 123_456_789, sampleTime: 987_654_321
            ),
            .published
        )

        var seen = false
        ring.drainPending { slot in
            seen = true
            XCTAssertEqual(slot.hostTime, 123_456_789)
            XCTAssertEqual(slot.sampleTime, 987_654_321)
            XCTAssertEqual(slot.sampleRate, 44_100)
        }
        XCTAssertTrue(seen)
    }

    // MARK: - 11. Accepting-writes closure

    func testCloseForWritingRejectsSubsequentPublishCalls() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        XCTAssertTrue(ring.isAcceptingWrites)
        XCTAssertEqual(publish(ring, channels: [[1, 2], [3, 4]]), .published)

        ring.closeForWriting()
        XCTAssertFalse(ring.isAcceptingWrites)
        XCTAssertEqual(publish(ring, channels: [[1, 2], [3, 4]]), .rejectedNotAcceptingWrites)
    }

    // MARK: - 12. Worker stop synchronously prevents later delivery

    func testWorkerStopSynchronouslyPreventsLaterDelivery() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let deliveryLock = NSLock()
        nonisolated(unsafe) var deliveries = 0
        let worker = TimecodeRealtimeIngressWorker(ring: ring, drainInterval: 0.001) { _ in
            deliveryLock.lock(); deliveries += 1; deliveryLock.unlock()
        }!

        for _ in 0..<50 {
            publish(ring, channels: [[1, 2], [3, 4]])
        }
        Thread.sleep(forTimeInterval: 0.05)

        worker.stop()
        deliveryLock.lock(); let deliveriesAtStop = deliveries; deliveryLock.unlock()

        Thread.sleep(forTimeInterval: 0.05)
        deliveryLock.lock(); let deliveriesAfterWait = deliveries; deliveryLock.unlock()
        XCTAssertEqual(deliveriesAfterWait, deliveriesAtStop, "stop() must guarantee no further delivery")
    }

    // MARK: - 13. Old ring/worker cannot deliver into a replacement session

    func testStoppedWorkerNeverDeliversIntoAReplacementSession() {
        let oldRing = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let oldLock = NSLock()
        nonisolated(unsafe) var oldDeliveries = 0
        let oldWorker = TimecodeRealtimeIngressWorker(ring: oldRing, drainInterval: 0.001) { _ in
            oldLock.lock(); oldDeliveries += 1; oldLock.unlock()
        }!

        XCTAssertEqual(publish(oldRing, channels: [[1, 2], [3, 4]]), .published)
        Thread.sleep(forTimeInterval: 0.02)
        oldLock.lock(); XCTAssertEqual(oldDeliveries, 1); oldLock.unlock()

        oldWorker.stop()
        oldLock.lock(); let deliveriesAtStop = oldDeliveries; oldLock.unlock()

        // A stray late producer that still retains the old ring must be
        // rejected, never queued for delivery.
        XCTAssertEqual(publish(oldRing, channels: [[1, 2], [3, 4]]), .rejectedNotAcceptingWrites)
        Thread.sleep(forTimeInterval: 0.02)
        oldLock.lock(); XCTAssertEqual(oldDeliveries, deliveriesAtStop); oldLock.unlock()

        // A "replacement session" is simply a new, independent ring/worker.
        let newRing = TimecodeRealtimeIngressRing(configuration: smallConfig)
        let newLock = NSLock()
        nonisolated(unsafe) var newDeliveries = 0
        let newWorker = TimecodeRealtimeIngressWorker(ring: newRing, drainInterval: 0.001) { _ in
            newLock.lock(); newDeliveries += 1; newLock.unlock()
        }!
        XCTAssertEqual(publish(newRing, channels: [[5, 6], [7, 8]]), .published)
        Thread.sleep(forTimeInterval: 0.02)
        newLock.lock(); XCTAssertEqual(newDeliveries, 1); newLock.unlock()
        oldLock.lock(); XCTAssertEqual(oldDeliveries, deliveriesAtStop, "the old worker must remain inert"); oldLock.unlock()
        newWorker.stop()
    }

    // MARK: - 14. Concurrent SPSC stress

    func testConcurrentSPSCStressAccountsForEveryAttempt() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 4, maximumChannelCount: 2, maximumFrameCountPerSlot: 16
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        let attempts = 20_000

        let drainedLock = NSLock()
        var drainedCount = 0
        let stopLock = NSLock()
        var producerFinished = false

        let consumerThread = Thread {
            while true {
                let drained = ring.drainPending { _ in
                    drainedLock.lock(); drainedCount += 1; drainedLock.unlock()
                }
                stopLock.lock(); let finished = producerFinished; stopLock.unlock()
                if finished, drained == 0 { break }
            }
        }
        consumerThread.start()

        let producerExpectation = expectation(description: "producer finished")
        DispatchQueue.global(qos: .userInitiated).async {
            let (list, cleanup) = self.makeAudioBufferListFixture(channels: [[1, 2, 3, 4], [5, 6, 7, 8]])
            defer { cleanup() }
            for _ in 0..<attempts {
                _ = ring.publish(
                    bufferList: list, frameCount: 4, expectedChannelCount: 2,
                    sampleRate: 48_000, hostTime: 0, sampleTime: 0
                )
            }
            stopLock.lock(); producerFinished = true; stopLock.unlock()
            producerExpectation.fulfill()
        }

        wait(for: [producerExpectation], timeout: 30)
        // Give the consumer thread a bounded window to notice completion and
        // drain whatever remains.
        let deadline = Date().addingTimeInterval(5)
        while !consumerThread.isFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let totalAccounted = Int(ring.publishedCount) + Int(ring.droppedCount) + Int(ring.rejectedCount)
        XCTAssertEqual(totalAccounted, attempts, "every attempted publish must be published, dropped, or rejected — never lost silently")
        drainedLock.lock()
        XCTAssertEqual(drainedCount, Int(ring.publishedCount), "every published slot must eventually be drained exactly once")
        drainedLock.unlock()
    }

    // MARK: - 15. Lifetime / no use-after-free

    func testRingDeallocatesCleanlyOnceAllReferencesAreReleased() {
        weak var weakRing: TimecodeRealtimeIngressRing?
        autoreleasepool {
            var ring: TimecodeRealtimeIngressRing? = TimecodeRealtimeIngressRing(configuration: .production)
            weakRing = ring
            XCTAssertEqual(publish(ring!, channels: [[1, 2], [3, 4]]), .published)
            ring!.drainPending { _ in }
            ring = nil
        }
        XCTAssertNil(weakRing, "the ring must deallocate once its last strong reference is released")
    }

    func testWorkerDeallocatesAndStopsWithoutCrashing() {
        weak var weakWorker: TimecodeRealtimeIngressWorker?
        autoreleasepool {
            let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
            var worker: TimecodeRealtimeIngressWorker? = TimecodeRealtimeIngressWorker(
                ring: ring, drainInterval: 0.001
            ) { _ in }
            weakWorker = worker
            publish(ring, channels: [[1, 2], [3, 4]])
            Thread.sleep(forTimeInterval: 0.01)
            worker = nil
        }
        XCTAssertNil(weakWorker, "the worker must deallocate (running its own deinit-triggered stop) without crashing")
    }

    // MARK: - 16. Self-stop from within a consumer callback

    /// A small lock-protected box so the worker can be referenced from
    /// inside its own consumer closure — the closure is constructed before
    /// the worker exists, so it captures this box by reference and the
    /// worker is assigned into it immediately after construction. The
    /// worker's timer can start ticking (and thus reading `worker`, on its
    /// own queue thread) before that assignment completes on the calling
    /// thread, so the getter/setter must be genuinely synchronized, not just
    /// `@unchecked Sendable` by assertion.
    private final class WorkerHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _worker: TimecodeRealtimeIngressWorker?
        var worker: TimecodeRealtimeIngressWorker? {
            get { lock.lock(); defer { lock.unlock() }; return _worker }
            set { lock.lock(); _worker = newValue; lock.unlock() }
        }
    }

    /// Direct regression for the review defect: `tick()` used to check
    /// `stopped` only once, before `drainPending` began, so if the first
    /// consumer callback in a multi-slot drain called `worker.stop()`, the
    /// self-stop path would mark `stopped` and return without a barrier —
    /// but `drainPending`'s loop kept calling the handler for the remaining
    /// already-pending slots, delivering to `consumer` after `stop()` had
    /// already returned. Publishes three slots, has the very first callback
    /// call `stop()`, and proves exactly one delivery occurred both at the
    /// moment `stop()` returned and after a further wait.
    func testSelfStopFromFirstCallbackPreventsLaterSlotsInTheSameDrain() {
        let configuration = TimecodeRealtimeIngressRingConfiguration(
            slotCount: 4, maximumChannelCount: 1, maximumFrameCountPerSlot: 1
        )!
        let ring = TimecodeRealtimeIngressRing(configuration: configuration)
        for value: Float in [1, 2, 3] {
            XCTAssertEqual(publish(ring, channels: [[value]]), .published)
        }

        let holder = WorkerHolder()
        let stateLock = NSLock()
        nonisolated(unsafe) var deliveryCount = 0
        nonisolated(unsafe) var stopReturned = false
        let stopReturnedExpectation = expectation(description: "stop() returned from the self-stop path")

        let worker = TimecodeRealtimeIngressWorker(ring: ring, drainInterval: 0.001) { _ in
            stateLock.lock()
            deliveryCount += 1
            let isFirstDelivery = deliveryCount == 1
            stateLock.unlock()
            if isFirstDelivery {
                holder.worker?.stop()
                stateLock.lock()
                stopReturned = true
                stateLock.unlock()
                stopReturnedExpectation.fulfill()
            }
        }!
        holder.worker = worker
        // Breaks the retain cycle worker -> consumer closure -> holder ->
        // worker deterministically at teardown, rather than relying on an
        // implicit release ordering.
        defer { holder.worker = nil }

        wait(for: [stopReturnedExpectation], timeout: 2)

        stateLock.lock()
        XCTAssertTrue(stopReturned, "the self-stop call must return")
        XCTAssertEqual(
            deliveryCount, 1,
            "only the callback that called stop() may run; the two later already-published slots in this same drain must not be delivered"
        )
        stateLock.unlock()

        Thread.sleep(forTimeInterval: 0.05)
        stateLock.lock()
        XCTAssertEqual(deliveryCount, 1, "no delivery may occur after the self-stop call returned")
        stateLock.unlock()
    }

    /// Companion regression proving `stop()` still keeps its external-thread
    /// guarantee: when called from a thread other than the worker's own
    /// queue while a callback is genuinely in-flight (sleeping), `stop()`
    /// must not return until that in-flight callback has finished.
    func testExternalThreadStopWaitsForAnInFlightCallbackToFinish() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        XCTAssertEqual(publish(ring, channels: [[1, 2], [3, 4]]), .published)

        let stateLock = NSLock()
        nonisolated(unsafe) var callbackFinished = false
        let callbackStartedExpectation = expectation(description: "in-flight callback started")

        let worker = TimecodeRealtimeIngressWorker(ring: ring, drainInterval: 0.001) { _ in
            callbackStartedExpectation.fulfill()
            Thread.sleep(forTimeInterval: 0.2)
            stateLock.lock(); callbackFinished = true; stateLock.unlock()
        }!

        wait(for: [callbackStartedExpectation], timeout: 2)
        // The callback above is still inside its 0.2s sleep on the worker's
        // own queue; `stop()` here runs on this (external) test thread.
        worker.stop()

        stateLock.lock()
        XCTAssertTrue(callbackFinished, "stop() must block until an in-flight callback has finished, not return early")
        stateLock.unlock()
    }

    // MARK: - 17. Configuration overflow / allocation-size guardrails

    func testConfigurationRejectsValuesThatDoNotFitInt32() {
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: Int(Int32.max) + 1, maximumFrameCountPerSlot: 1
        ), "maximumChannelCount must fit Int32 — the slot metadata stores it as Int32")
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: Int(Int32.max) + 1
        ), "maximumFrameCountPerSlot must fit Int32 — the slot metadata stores it as Int32")
        // Int32.max on any single dimension already implies a many-gigabyte
        // allocation, so it is rejected by the allocation-size cap below
        // rather than the Int32-fit check — both are guardrails and either
        // may be the one that catches a given oversized configuration.
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: Int(Int32.max), maximumFrameCountPerSlot: 1
        ))
    }

    func testConfigurationRejectsMultiplicationOverflow() {
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: Int(Int32.max), maximumFrameCountPerSlot: Int(Int32.max)
        ), "the final byte-size multiplication must be overflow-checked, not just individually Int32-bounded")
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: Int.max, maximumChannelCount: 2, maximumFrameCountPerSlot: 2
        ), "slotCount * slotStride must be overflow-checked (slotCount itself is not Int32-bounded)")
    }

    func testConfigurationRejectsAbsurdButNonOverflowingAllocationSize() {
        // Every individual field fits Int32 and no pairwise multiplication
        // overflows Int, but the total allocation would be ~3.7 GiB — must
        // still be rejected before any pointer allocation.
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 1_000, maximumChannelCount: 1_000, maximumFrameCountPerSlot: 100_000
        ))
    }

    func testConfigurationAcceptsExactAllocationSizeBoundaryAndRejectsOneFrameOver() {
        let maxBytes = TimecodeRealtimeIngressRingConfiguration.maximumSampleStorageByteSize
        let boundaryFrames = maxBytes / (2 * 1 * MemoryLayout<Float>.size)
        XCTAssertNotNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: boundaryFrames
        ), "exactly at the documented maximum allocation size must be accepted")
        XCTAssertNil(TimecodeRealtimeIngressRingConfiguration(
            slotCount: 2, maximumChannelCount: 1, maximumFrameCountPerSlot: boundaryFrames + 1
        ), "one frame past the documented maximum allocation size must be rejected")
    }

    // MARK: - 18. Invalid sample rate

    func testNonFiniteOrNonPositiveSampleRateIsRejected() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        for rate: Double in [0, -1, .nan, .infinity, -.infinity] {
            let outcome = publish(ring, channels: [[1, 2], [3, 4]], sampleRate: rate)
            XCTAssertEqual(outcome, .rejectedInvalidSampleRate, "sampleRate \(rate) must be rejected, never published as metadata")
        }
        XCTAssertEqual(ring.publishedCount, 0)
        XCTAssertEqual(ring.rejectedCount, 5)
    }

    // MARK: - 19. Worker drainInterval validation

    func testWorkerInitRejectsNonFiniteOrNonPositiveDrainIntervals() {
        let ring = TimecodeRealtimeIngressRing(configuration: smallConfig)
        for interval: TimeInterval in [0, -0.001, .nan, .infinity, -.infinity] {
            XCTAssertNil(
                TimecodeRealtimeIngressWorker(ring: ring, drainInterval: interval) { _ in },
                "drainInterval \(interval) must fail construction rather than being silently clamped to a default cadence"
            )
        }
    }
}
