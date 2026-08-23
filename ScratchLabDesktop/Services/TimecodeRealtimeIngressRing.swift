import AudioToolbox
import Dispatch
import Foundation
import Synchronization

// MARK: - Configuration

/// Fixed capacity plan for one `TimecodeRealtimeIngressRing`. Every dimension
/// is chosen once, validated at construction, and never changes for the
/// lifetime of the ring — the realtime producer must never trigger a
/// reallocation.
public struct TimecodeRealtimeIngressRingConfiguration: Equatable, Sendable {
    /// Number of ring slots. Must be at least 2 (one for the producer to be
    /// writing into while the consumer drains another). At 8 slots and the
    /// Rane's measured ~10.7 ms native hardware quantum (real hardware:
    /// `bufferFrameSize=512` @ 48 kHz), that is roughly 85 ms of buffering
    /// headroom before the ring can fill — far more than the ~5 ms worker
    /// drain interval should ever need under normal scheduling.
    public let slotCount: Int

    /// Hard ceiling on channels per slot. 32 is a fixed, generous constant
    /// chosen to comfortably exceed the Rane ONE MKII's 14 channels and any
    /// currently-supported pro DJ interface, specifically so the ring is
    /// never resized during a live session. A device reporting more
    /// channels than this is rejected (fails closed), never truncated.
    public let maximumChannelCount: Int

    /// Hard ceiling on frames per slot. 8,192 is set to twice the Rane's own
    /// HAL-advertised maximum buffer size (4,096 frames — real hardware:
    /// `range=[15...4096]`). The actual per-callback frame count under a
    /// render-quantum-driven input path is a hardware *hypothesis*, not a
    /// documented guarantee (`AVAudioSinkNode.h` only promises realtime-
    /// thread delivery, not a specific frame count) — this ceiling is
    /// deliberately well above the only concrete number measured so far.
    public let maximumFrameCountPerSlot: Int

    /// Precomputed `maximumChannelCount * maximumFrameCountPerSlot`, proven
    /// not to overflow at construction time. Stored so the ring never
    /// repeats this multiplication unchecked.
    let slotStride: Int

    /// Precomputed `slotCount * slotStride`, proven not to overflow at
    /// construction time.
    let sampleCapacity: Int

    /// Hard ceiling on the ring's one-time sample-storage allocation, in
    /// bytes. A configuration whose dimensions individually fit `Int32` and
    /// whose pairwise products don't overflow `Int` can still describe an
    /// absurd total allocation (e.g. thousands of slots × thousands of
    /// channels × hundreds of thousands of frames) that would crash with an
    /// allocation trap or OOM rather than fail cleanly. 256 MiB is generous
    /// headroom above the ~8 MiB `production` footprint while still
    /// rejecting configurations that were never intended to be real.
    public static let maximumSampleStorageByteSize = 256 * 1024 * 1024

    /// Fails (returns `nil`) rather than clamping or asserting — an invalid
    /// configuration must never silently become a different, smaller one.
    /// Validates, in order: positivity; that both maxima fit `Int32` (the
    /// per-slot metadata stores `frameCount`/`channelCount` as `Int32`, so a
    /// configuration that doesn't fit would make every later conversion in
    /// `publish` unchecked); that `maximumChannelCount *
    /// maximumFrameCountPerSlot` and `slotCount * slotStride` don't overflow
    /// `Int`; and that the resulting total byte allocation stays under
    /// `maximumSampleStorageByteSize`. All of this runs before the ring ever
    /// allocates a single pointer.
    public init?(
        slotCount: Int,
        maximumChannelCount: Int,
        maximumFrameCountPerSlot: Int
    ) {
        guard slotCount >= 2,
              maximumChannelCount >= 1,
              maximumFrameCountPerSlot >= 1 else {
            return nil
        }
        guard maximumChannelCount <= Int(Int32.max),
              maximumFrameCountPerSlot <= Int(Int32.max) else {
            return nil
        }
        let (slotStride, strideOverflowed) = maximumChannelCount.multipliedReportingOverflow(by: maximumFrameCountPerSlot)
        guard !strideOverflowed else { return nil }
        let (sampleCapacity, capacityOverflowed) = slotCount.multipliedReportingOverflow(by: slotStride)
        guard !capacityOverflowed else { return nil }
        let (byteSize, byteOverflowed) = sampleCapacity.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !byteOverflowed, byteSize <= Self.maximumSampleStorageByteSize else { return nil }

        self.slotCount = slotCount
        self.maximumChannelCount = maximumChannelCount
        self.maximumFrameCountPerSlot = maximumFrameCountPerSlot
        self.slotStride = slotStride
        self.sampleCapacity = sampleCapacity
    }

    /// Production defaults — see the per-field documentation above for why
    /// each was chosen. Total one-time allocation: 8 × 32 × 8,192 × 4 bytes
    /// ≈ 8 MiB, allocated once per ring instance, never resized.
    public static let production = TimecodeRealtimeIngressRingConfiguration(
        slotCount: 8,
        maximumChannelCount: 32,
        maximumFrameCountPerSlot: 8_192
    )!
}

// MARK: - Slot metadata

/// Plain, trivial (no reference-counted fields) per-slot metadata, stored
/// inline in a preallocated buffer — never a Swift `Array` element.
struct TimecodeRealtimeIngressSlotMetadata {
    var frameCount: Int32
    var channelCount: Int32
    var sampleRate: Float64
    var hostTime: UInt64
    var sampleTime: Int64

    static let empty = TimecodeRealtimeIngressSlotMetadata(
        frameCount: 0, channelCount: 0, sampleRate: 0, hostTime: 0, sampleTime: 0
    )
}

// MARK: - Publish outcome

/// Every possible result of a realtime `publish` call. Each rejection case
/// is independently testable — see `TimecodeRealtimeIngressRingTests`.
public enum TimecodeRealtimeIngressPublishOutcome: Equatable {
    case published
    case rejectedNotAcceptingWrites
    case rejectedInvalidFrameCount
    case rejectedInvalidChannelCount
    case rejectedBufferCountMismatch
    case rejectedMultiChannelBuffer
    case rejectedNilData
    case rejectedUndersizedData
    case rejectedInvalidSampleRate
    case droppedRingFull
}

// MARK: - Slot view (consumer side)

/// A read-only view into one drained slot's sample data, valid only for the
/// duration of the `drainPending` handler call that produced it. The pointer
/// it wraps refers directly into the ring's own preallocated storage — the
/// caller must not retain `samples(forChannel:)`'s result (or this view)
/// past the handler's return; the ring may overwrite that slot's memory as
/// soon as `drainPending` advances past it.
public struct TimecodeRealtimeIngressSlotView {
    public let channelCount: Int
    public let frameCount: Int
    public let sampleRate: Double
    public let hostTime: UInt64
    public let sampleTime: Int64

    private let channelBase: UnsafePointer<Float>
    private let frameStride: Int

    fileprivate init(
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        hostTime: UInt64,
        sampleTime: Int64,
        channelBase: UnsafePointer<Float>,
        frameStride: Int
    ) {
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.channelBase = channelBase
        self.frameStride = frameStride
    }

    /// Exactly `frameCount` valid samples for `channel`. Do not retain the
    /// returned buffer pointer beyond the enclosing `drainPending` call.
    public func samples(forChannel channel: Int) -> UnsafeBufferPointer<Float> {
        precondition(channel >= 0 && channel < channelCount, "channel out of range")
        return UnsafeBufferPointer(start: channelBase + channel * frameStride, count: frameCount)
    }
}

// MARK: - Ring

/// A preallocated, fixed-capacity single-producer/single-consumer ring for
/// carrying raw multichannel Float32 audio from a realtime audio callback to
/// a non-realtime worker, without locks, allocation, or dispatch on the
/// producer side.
///
/// `@unchecked Sendable` invariant — read this before touching this type:
/// - Exactly one producer thread may ever call `publish`, and it alone reads
///   and advances `writeCounter`.
/// - Exactly one consumer (drain) context may ever call `drainPending`, and
///   it alone reads and advances `readCounter`.
/// - The *raw sample and metadata storage is ordinary, non-atomic memory*.
///   It is **not** "behind `Atomic`" — nothing about the storage itself is
///   synchronized. Safety comes entirely from the release/acquire discipline
///   on `writeCounter`/`readCounter`: the producer's release-store of
///   `writeCounter` happens-after every store it made into that slot's
///   memory, and the consumer's acquire-load of `writeCounter` happens-
///   before it reads that same memory — this pairing is what makes the plain
///   memory safe to hand across threads, not any property of the memory
///   itself.
/// - A slot's memory cannot be reused by the producer until the consumer has
///   advanced `readCounter` past it (i.e., has released it) — `publish`
///   checks `writeCounter - readCounter < slotCount` before writing.
/// - A `TimecodeRealtimeIngressSlotView` handed to a `drainPending` handler
///   is only valid for the duration of that call; retaining it (or a pointer
///   obtained from it) afterward is undefined — the ring may overwrite that
///   memory on the very next `publish` once the slot is released.
public final class TimecodeRealtimeIngressRing: @unchecked Sendable {
    public let configuration: TimecodeRealtimeIngressRingConfiguration

    private let sampleStorage: UnsafeMutablePointer<Float>
    private let slotMetadataStorage: UnsafeMutablePointer<TimecodeRealtimeIngressSlotMetadata>
    private let slotStride: Int

    private let writeCounter = Atomic<UInt64>(0)
    private let readCounter = Atomic<UInt64>(0)
    private let acceptingWritesFlag = Atomic<Bool>(true)

    private let publishedCounter = Atomic<UInt64>(0)
    private let droppedCounter = Atomic<UInt64>(0)
    private let rejectedCounter = Atomic<UInt64>(0)

    public init(configuration: TimecodeRealtimeIngressRingConfiguration) {
        self.configuration = configuration
        self.slotStride = configuration.slotStride
        let sampleCapacity = configuration.sampleCapacity
        let sampleStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCapacity)
        sampleStorage.initialize(repeating: 0, count: sampleCapacity)
        self.sampleStorage = sampleStorage
        let metadataStorage = UnsafeMutablePointer<TimecodeRealtimeIngressSlotMetadata>.allocate(
            capacity: configuration.slotCount
        )
        metadataStorage.initialize(repeating: .empty, count: configuration.slotCount)
        self.slotMetadataStorage = metadataStorage
    }

    deinit {
        sampleStorage.deallocate()
        slotMetadataStorage.deallocate()
    }

    // MARK: Diagnostics (safe to read from any thread — relaxed is
    // sufficient, these are informational counters, not synchronization).

    public var isAcceptingWrites: Bool {
        acceptingWritesFlag.load(ordering: .acquiring)
    }

    public var publishedCount: UInt64 { publishedCounter.load(ordering: .relaxed) }
    public var droppedCount: UInt64 { droppedCounter.load(ordering: .relaxed) }
    public var rejectedCount: UInt64 { rejectedCounter.load(ordering: .relaxed) }

    /// Closes producer acceptance. Called by the owning session's teardown
    /// sequence (`TimecodeRealtimeIngressWorker.stop()`) — never by the
    /// realtime producer itself.
    ///
    /// **The actual guarantee, precisely:** any `publish` call that *observes*
    /// `acceptingWritesFlag` as already closed (i.e. its own initial flag
    /// load happens after this store) is rejected with
    /// `.rejectedNotAcceptingWrites` before touching any slot memory. This is
    /// **not** a guarantee that every racing producer call is rejected: a
    /// `publish` invocation that had already loaded `true` — i.e. was already
    /// past that guard — *before* `closeForWriting()` ran may still finish
    /// its validation and copy and publish one final slot afterward. That is
    /// safe (the slot-reuse invariant above still holds; the write goes into
    /// a slot the consumer hasn't claimed), just not instantaneous.
    ///
    /// `closeForWriting()` and `TimecodeRealtimeIngressWorker.stop()`'s
    /// barrier together synchronize **consumer delivery only** — they
    /// guarantee no further call to the drain handler, not that the external
    /// realtime producer has stopped calling `publish`. The producer is a
    /// live audio callback this type does not own or control. A future
    /// owner (Slice 2, wiring a real `AVAudioEngine`/`AVAudioSinkNode`
    /// producer to this ring) must itself disconnect or retire the producer
    /// callback — and keep the ring instance alive until it can prove no
    /// producer call can still be in flight or newly invoked — before
    /// releasing/deallocating the ring. This is not currently a production
    /// hazard: Slice 1 is not wired into any live capture path, so nothing
    /// calls `publish` outside of tests.
    public func closeForWriting() {
        acceptingWritesFlag.store(false, ordering: .releasing)
    }

    // MARK: - Realtime producer entry point
    //
    // Must perform, on every call: no allocation, no locks, no dispatch, no
    // logging, no `AVAudioPCMBuffer` construction, no adapter/heartbeat/
    // fixture call. `UnsafeMutableAudioBufferListPointer` is a thin,
    // allocation-free wrapper already used elsewhere in this codebase for
    // exactly this purpose (see `MacCaptureEngine.audioPacket(from:)`).

    /// Validates and copies one realtime callback's audio into the ring, or
    /// rejects it. Never partially publishes a slot: every validation runs
    /// to completion before any sample data is copied, and the write-counter
    /// publish only happens after every channel has been copied in full.
    @discardableResult
    public func publish(
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        expectedChannelCount: Int,
        sampleRate: Double,
        hostTime: UInt64,
        sampleTime: Int64
    ) -> TimecodeRealtimeIngressPublishOutcome {
        guard acceptingWritesFlag.load(ordering: .acquiring) else {
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
            return .rejectedNotAcceptingWrites
        }
        guard frameCount > 0, frameCount <= configuration.maximumFrameCountPerSlot else {
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
            return .rejectedInvalidFrameCount
        }
        guard expectedChannelCount > 0, expectedChannelCount <= configuration.maximumChannelCount else {
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
            return .rejectedInvalidChannelCount
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
            return .rejectedInvalidSampleRate
        }

        let listPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard listPointer.count == expectedChannelCount else {
            rejectedCounter.wrappingAdd(1, ordering: .relaxed)
            return .rejectedBufferCountMismatch
        }

        let requiredByteSize = frameCount * MemoryLayout<Float>.size
        for buffer in listPointer {
            guard buffer.mNumberChannels == 1 else {
                rejectedCounter.wrappingAdd(1, ordering: .relaxed)
                return .rejectedMultiChannelBuffer
            }
            guard buffer.mData != nil else {
                rejectedCounter.wrappingAdd(1, ordering: .relaxed)
                return .rejectedNilData
            }
            guard Int(buffer.mDataByteSize) >= requiredByteSize else {
                rejectedCounter.wrappingAdd(1, ordering: .relaxed)
                return .rejectedUndersizedData
            }
        }

        // Capacity check: this producer is the sole writer of writeCounter,
        // so a relaxed load of its own prior value is sufficient; readCounter
        // is acquire-loaded because the consumer's release-store of it must
        // be visible before this producer trusts a slot is free to reuse.
        let writeIndex = writeCounter.load(ordering: .relaxed)
        let readIndex = readCounter.load(ordering: .acquiring)
        guard writeIndex &- readIndex < UInt64(configuration.slotCount) else {
            // Full ring: preserve oldest pending data, drop this (newest)
            // input. The producer never advances readCounter itself and
            // never overwrites an unread slot — doing either would race
            // with the consumer, which is the one thing this design must
            // never allow.
            droppedCounter.wrappingAdd(1, ordering: .relaxed)
            return .droppedRingFull
        }

        let slot = Int(writeIndex % UInt64(configuration.slotCount))
        let slotBase = sampleStorage + slot * slotStride
        for (channel, buffer) in listPointer.enumerated() {
            let destination = slotBase + channel * configuration.maximumFrameCountPerSlot
            let source = buffer.mData!.assumingMemoryBound(to: Float.self)
            destination.update(from: source, count: frameCount)
        }
        slotMetadataStorage[slot] = TimecodeRealtimeIngressSlotMetadata(
            frameCount: Int32(frameCount),
            channelCount: Int32(expectedChannelCount),
            sampleRate: sampleRate,
            hostTime: hostTime,
            sampleTime: sampleTime
        )

        // Release: publishes both the sample data and metadata stores above
        // to any thread that subsequently acquire-loads this counter.
        writeCounter.store(writeIndex &+ 1, ordering: .releasing)
        publishedCounter.wrappingAdd(1, ordering: .relaxed)
        return .published
    }

    // MARK: - Non-realtime consumer entry point

    /// Drains every currently-published slot, calling `handler` once per
    /// slot in publish order. `handler` is non-escaping: it must not store
    /// the `TimecodeRealtimeIngressSlotView` (or any pointer derived from
    /// it) anywhere that outlives this call. Safe to call from exactly one
    /// consumer context; never call this concurrently from two threads.
    @discardableResult
    public func drainPending(_ handler: (TimecodeRealtimeIngressSlotView) -> Void) -> Int {
        var drained = 0
        while true {
            let readIndex = readCounter.load(ordering: .relaxed)
            // Acquire: makes every store the producer performed into this
            // slot (sample data + metadata) visible before we read them.
            let writeIndex = writeCounter.load(ordering: .acquiring)
            guard readIndex != writeIndex else { break }

            let slot = Int(readIndex % UInt64(configuration.slotCount))
            let metadata = slotMetadataStorage[slot]
            let channelBase = UnsafePointer(sampleStorage + slot * slotStride)
            let view = TimecodeRealtimeIngressSlotView(
                channelCount: Int(metadata.channelCount),
                frameCount: Int(metadata.frameCount),
                sampleRate: metadata.sampleRate,
                hostTime: metadata.hostTime,
                sampleTime: metadata.sampleTime,
                channelBase: channelBase,
                frameStride: configuration.maximumFrameCountPerSlot
            )
            handler(view)

            // Release: signals to the producer that this slot's memory may
            // now be reused. Must happen only after `handler` has finished
            // reading it.
            readCounter.store(readIndex &+ 1, ordering: .releasing)
            drained += 1
        }
        return drained
    }
}

// MARK: - Worker

/// Drains a `TimecodeRealtimeIngressRing` on a fixed cadence, entirely off
/// the realtime audio thread. Owns exactly one persistent serial queue and
/// one persistent timer, both created once in `init` — never recreated per
/// tick.
///
/// Deliberately generic: this worker does not depend on `MacCaptureEngine`,
/// `TimecodeCMSampleBufferAdapter`, the DVS heartbeat, fixture recording,
/// playback, or notation. Slice 1 only proves the ring/worker mechanism;
/// wiring a real consumer (adapter + heartbeat + fixture recording) into
/// production capture is later, separate work.
public final class TimecodeRealtimeIngressWorker: @unchecked Sendable {
    private let ring: TimecodeRealtimeIngressRing
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let timer: DispatchSourceTimer
    private let stopped = Atomic<Bool>(false)
    private let consumer: @Sendable (TimecodeRealtimeIngressSlotView) -> Void

    /// Fails (returns `nil`) if `drainInterval` is not finite and strictly
    /// positive, rather than silently clamping it to some default cadence —
    /// a caller that passes zero, negative, `NaN`, or infinite must be told
    /// its configuration is invalid, not handed a worker running on an
    /// unintended interval.
    public init?(
        ring: TimecodeRealtimeIngressRing,
        drainInterval: TimeInterval = 0.005,
        queueLabel: String = "com.machelpnz.scratchlab.timecode-realtime-ingress-worker",
        consumer: @escaping @Sendable (TimecodeRealtimeIngressSlotView) -> Void
    ) {
        guard drainInterval.isFinite, drainInterval > 0 else {
            return nil
        }
        self.ring = ring
        self.consumer = consumer
        let queue = DispatchQueue(label: queueLabel)
        queue.setSpecific(key: queueKey, value: ())
        self.queue = queue

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + drainInterval, repeating: drainInterval, leeway: .milliseconds(1))
        self.timer = timer
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
    }

    private func tick() {
        guard !stopped.load(ordering: .acquiring) else { return }
        // `stopped` is re-checked before *every* delivery below, not just
        // once before the drain begins: `drainPending` may hand back
        // several pending slots in one call, and a consumer callback is
        // free to invoke `stop()` on the currently-executing slot. Because
        // that inline `stop()` runs on this worker's own queue, it takes the
        // `DispatchSpecificKey` self-stop path — it marks `stopped` and
        // returns without a barrier, but does not itself unwind this
        // `drainPending` loop. Re-checking `stopped` here (rather than only
        // in `tick`'s outer guard) is what stops every later queued slot in
        // *this same drain* from reaching `consumer`, honoring `stop()`'s
        // guarantee even when it's invoked from inside a callback.
        ring.drainPending { [weak self, consumer] slot in
            guard let self, !self.stopped.load(ordering: .acquiring) else { return }
            consumer(slot)
        }
    }

    /// Synchronously guarantees that no consumer callback from this worker
    /// executes again after this method returns.
    ///
    /// Order matters: (1) close the ring's producer acceptance first, so a
    /// producer callback racing this teardown observes the closed ring
    /// rather than publishing a slot this worker is about to stop draining;
    /// (2) mark this worker stopped, so an already-queued or in-flight timer
    /// tick no-ops instead of draining; (3) cancel the persistent timer, so
    /// no further tick is scheduled; (4) synchronously barrier the worker's
    /// own serial queue — because the queue is strictly serial and FIFO, an
    /// empty `sync` block enqueued after cancellation only runs once any
    /// tick that was already executing or already queued at the moment of
    /// cancellation has fully completed, which is exactly the guarantee
    /// required. If `stop()` is itself invoked from inside a consumer
    /// closure running on this worker's own queue, the `DispatchSpecificKey`
    /// check below skips the barrier (a serial queue can never be
    /// re-entered by a second block while the first is running, so no
    /// further tick can be concurrently in flight — and `queue.sync` from
    /// the queue's own execution context would otherwise deadlock).
    public func stop() {
        ring.closeForWriting()
        stopped.store(true, ordering: .releasing)
        timer.cancel()
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return
        }
        queue.sync {}
    }

    deinit {
        if !stopped.load(ordering: .acquiring) {
            stop()
        }
    }
}
