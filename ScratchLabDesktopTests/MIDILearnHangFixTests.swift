// MIDILearnHangFixTests.swift
// ScratchLabDesktopTests
//
// Focused, deterministic regression tests for the Rane ONE MKII hardware
// hang/crash on clicking Learn Left Upfader / Learn Right Upfader / Learn
// Crossfader. Root cause was three compounding defects, all in
// MacCaptureEngine:
//
//   A) `recordReceivedMIDICCEvent`'s UI-monitor throttle had a
//      `|| isMidiLearn` bypass, so during any active learn EVERY CC event
//      (including the platter's ~800 Hz CC6 flood) triggered an unthrottled
//      `DispatchQueue.main.async` publish.
//   B) `recordReceivedMIDICCEvent` ALSO independently re-implemented
//      crossfader learning (`if learning { ...; applyLearnedCrossfaderMapping
//      (...) }`), completely separate from the real action-aware consumer
//      (`evaluateMIDILearnForCC`). Since `isMIDILearning` is true for ANY
//      learn action (not just crossfader), starting Learn Left/Right Upfader
//      while the platter was spinning caused THIS duplicate path to call
//      `applyLearnedCrossfaderMapping` (synchronous JSON encode + UserDefaults
//      write) on every single CC6 event — at ~800 Hz, directly on the
//      CoreMIDI callback thread.
//   C) `activeMIDILearnAction` was `@Published` but was read (unlocked) and
//      written (under `midiCaptureLock`) from the CoreMIDI callback thread —
//      a data race on Combine's property-wrapper machinery from a realtime
//      thread.
//
// Kept in its own file/class (mirroring MIDILearnEngineTests.swift and
// MIDILearnedMappingTests.swift) rather than appended to
// CaptureReliabilityPhase1Tests.swift's giant XCTestCase class, which is
// known (see project memory) to only run a subset of its own declared tests
// under this environment's `xcodebuild test -only-testing:.../ClassName`.

import XCTest
@testable import ScratchLab

final class MIDILearnHangFixTests: XCTestCase {

    private func cleanUpMIDIMapping(deviceIdentifier: String) {
        MIDILearnedMappingStore.default.delete(deviceIdentifier: deviceIdentifier)
    }

    // MARK: 1. Bounded-time Learn button API under continuous MIDI traffic

    func testFaderLearnButtonsRemainResponsiveUnderConcurrentCC6Flood() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_concurrent_flood"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // A background queue stands in for the CoreMIDI callback thread,
        // continuously hammering the exact entry point real CC6 traffic
        // would hit, concurrently with the "button click" on this thread.
        let floodQueue = DispatchQueue(label: "test.cc6.flood")
        let floodLock = NSLock()
        var floodShouldStop = false
        floodQueue.async {
            var i = 0
            while true {
                floodLock.lock()
                let stop = floodShouldStop
                floodLock.unlock()
                if stop { break }
                _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 6, value: i % 128)
                i += 1
            }
        }
        defer {
            floodLock.lock()
            floodShouldStop = true
            floodLock.unlock()
        }

        for action: MIDISemanticAction in [.crossfader, .leftUpfader, .rightUpfader] {
            let start = Date()
            engine.startMIDILearn(for: action)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 1.0, "startMIDILearn(for: \(action)) must return within a bounded time even under a concurrent CC6 flood — this is exactly the click that hung on hardware")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(engine.activeMIDILearnAction, action)
            engine.cancelMIDILearn()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: 2. 10,000 CC6 events during each fader Learn

    func testTenThousandCC6EventsDuringEachFaderLearnCauseNoMutationAndBoundedPublication() {
        // MacCaptureEngine restores the legacy crossfader preference during
        // init. Preserve the user's value while ensuring this flood test
        // starts from the nil mapping its assertions require.
        let legacyMappingKey = "scratchlab.mac.crossfaderMIDIMapping"
        let originalLegacyMapping = UserDefaults.standard.object(forKey: legacyMappingKey)
        UserDefaults.standard.removeObject(forKey: legacyMappingKey)
        defer {
            if let originalLegacyMapping {
                UserDefaults.standard.set(originalLegacyMapping, forKey: legacyMappingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyMappingKey)
            }
        }

        for action: MIDISemanticAction in [.crossfader, .leftUpfader, .rightUpfader] {
            let deviceID = "midi_test_hang_10k_\(action.rawValue)"
            cleanUpMIDIMapping(deviceIdentifier: deviceID)
            let engine = MacCaptureEngine(autoRefreshDevices: false)
            engine.selectedMIDIInputSourceID = deviceID
            defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

            engine.startMIDILearn(for: action)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            let start = Date()
            for i in 0..<10_000 {
                let value = i % 128
                let result = engine.evaluateMIDILearnForCC(channel: 1, controller: 6, value: value)
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Test", channel: 1, controller: 6, value: value,
                    consumedByLearn: result.consumedByLearn
                )
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5.0, "10,000 CC6 events must never hang or take unbounded time — this is the exact flood rate (~800 Hz) that hit the hardware hang")

            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            XCTAssertEqual(engine.activeMIDILearnAction, action, "The learn session must remain active — CC6 must never end or steal it")
            XCTAssertNil(engine.crossfaderCCMapping, "CC6 must never be captured as the crossfader mapping")
            XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: action), "CC6 must never be captured as any learned control")
            XCTAssertLessThanOrEqual(
                engine.testOnly_midiMonitorPublishCount, 50,
                "10,000 events over the throttled ~4 Hz monitor channel must yield a small, bounded publication count, never one per event"
            )

            engine.cancelMIDILearn()
        }
    }

    // MARK: 3 & 4. Exactly-once win for left/right upfader

    func testLeftUpfaderLearnWinsExactlyOnceOnIntendedCC() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_left_upfader_once"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let first = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 64)
        let second = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 70)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(first.consumedByLearn, "The first eligible event must win the session")
        XCTAssertFalse(second.consumedByLearn, "A second event after the session already ended must not also be consumed")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.controlNumber, 20)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.deck, 0)
        XCTAssertNil(engine.activeMIDILearnAction, "Learn must end after exactly one event wins")
    }

    func testRightUpfaderLearnWinsExactlyOnceOnIntendedCC() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_right_upfader_once"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let first = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 64)
        let second = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 70)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(first.consumedByLearn)
        XCTAssertFalse(second.consumedByLearn)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 21)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.deck, 1)
        XCTAssertNil(engine.activeMIDILearnAction)
    }

    // MARK: 5. Crossfader accepts CC8 raw channel 15 while CC6 traffic continues

    func testCrossfaderLearnAcceptsCC8Channel15WhileCC6TrafficContinues() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_crossfader_cc8_amid_cc6"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        for i in 0..<500 {
            _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 6, value: i % 128)
        }
        let result = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(result.consumedByLearn)
        XCTAssertEqual(result.crossfaderMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
    }

    // MARK: 6. Repeated MIDI after completion cannot relearn or overwrite

    func testRepeatedMIDIAfterLearnCompletionCannotRelearnOrOverwrite() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_no_relearn_after_completion"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))

        // Further traffic after learning already ended — including on the
        // exact CC/channel just learned, and on an unrelated controller.
        for i in 0..<1000 {
            _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: i % 128)
            _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: i % 128)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8),
            "The mapping must remain exactly what was learned — never re-learned or overwritten by later traffic"
        )
        XCTAssertNil(engine.activeMIDILearnAction)
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader), "Unrelated later traffic must not spuriously learn a different action")
    }

    // MARK: 7. Learn → Cancel → Learn another action rejects stale state/publications

    func testCancelThenLearnAnotherActionDoesNotLeakStaleSessionState() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_cancel_then_learn_another"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.cancelMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(engine.activeMIDILearnAction)

        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeMIDILearnAction, .rightUpfader)

        let strayResult = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 64)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(strayResult.consumedByLearn, "The currently-active session (right upfader) claims the first eligible event")
        XCTAssertEqual(
            engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 20,
            "The claimed binding belongs to the CURRENTLY active action — never a leaked leftUpfader session from before the cancel"
        )
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader), "The cancelled left-upfader session must never have been learned")
    }

    func testStaleNoMIDIWarningFromCancelledGenerationNeverApplies() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hang_stale_generation"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // First session: crossfader — its delayed "no MIDI" warning uses
        // distinct text ("Check IAC Driver...") from any other action's.
        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.cancelMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Second session: a different generation, different action.
        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Let both sessions' 2.5s delayed warnings get a chance to fire.
        RunLoop.main.run(until: Date().addingTimeInterval(2.7))

        XCTAssertNotEqual(
            engine.midiLearnFeedback,
            "No MIDI received. Check IAC Driver / MixEmergency MIDI Out.",
            "The cancelled crossfader session's stale, generation-mismatched warning must never overwrite the active left-upfader session's feedback"
        )
        XCTAssertEqual(engine.activeMIDILearnAction, .leftUpfader, "The active session must still be the second one, untouched by the first's stale task")
    }

    // MARK: 8. No persistence or sample-load runs on the calling (CoreMIDI/main) thread

    // Note: these two tests prove "does not BLOCK the caller" via a timing
    // bound, not "has not completed yet" via an immediate snapshot check.
    // The persistence/sample-load queues are separate background threads,
    // not `DispatchQueue.main` — unlike a same-thread queue, a background
    // thread can genuinely start running the enqueued work in parallel the
    // instant it's dispatched, with no requirement that the calling thread
    // yield first. An immediate "hasn't happened yet" assertion is therefore
    // an inherent race (confirmed flaky against `ScratchSamplePlaybackController`'s
    // sample-buffer cache, which can make a repeat load near-instant) — a
    // bounded-time "the call returned fast, so it can't have done blocking
    // file I/O inline" assertion is the robust way to prove the same thing.

    func testCrossfaderLearnPersistenceDoesNotBlockTheCallingThread() {
        let deviceID = "midi_test_hang_no_sync_persistence"
        let defaultsKey = "scratchlab.mac.crossfaderMIDIMapping"
        let originalLegacyMapping = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            cleanUpMIDIMapping(deviceIdentifier: deviceID)
            if let originalLegacyMapping {
                UserDefaults.standard.set(originalLegacyMapping, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = deviceID

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let start = Date()
        let result = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.consumedByLearn)
        XCTAssertLessThan(elapsed, 0.05, "Learning the crossfader must enqueue persistence and return immediately, never block on JSON encode + UserDefaults I/O inline")

        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(
            UserDefaults.standard.data(forKey: defaultsKey),
            "Persistence must complete once the queue is drained"
        )
    }

    func testHotCueSampleLoadDoesNotBlockTheCallingThread() {
        let defaults = UserDefaults(suiteName: "MIDILearnHangFixTests.hotcue.\(UUID().uuidString)")!
        ScratchAudioOwnershipMode.scratchLabStandalone.persist(to: defaults)
        let engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
        let deviceID = "midi_test_hang_no_sync_sample_load"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue1)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("ahhh", hotCueIndex: 1)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let start = Date()
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 127)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "Resolving a hot-cue press must enqueue the sample load onto the playback controller's own audio queue and return immediately, never block on file I/O inline")

        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID, "ahhh")
    }

    // MARK: - Calibration publication bound
    //
    // Found during the pre-commit review of this checkpoint:
    // `evaluateCalibrationForCC`'s live-value publish had no throttle or
    // coalescing gate at all — every matching fader CC event triggered its
    // own `DispatchQueue.main.async`, the same unbounded-publication pattern
    // that caused the button hang (defect A above), just on the calibration
    // channel instead of the MIDI-monitor channel. Fixed with the same
    // bounded/coalesced/pending-flag design, plus a generation token (new
    // requirement here) so a publication enqueued before Cancel/Finish/a new
    // session can never restore stale values afterward.

    private func learnControl(_ engine: MacCaptureEngine, action: MIDISemanticAction, channel: Int, controller: Int) {
        engine.startMIDILearn(for: action)
        _ = engine.evaluateMIDILearnForCC(channel: channel, controller: controller, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // 1. 10,000 matching fader events produce correct raw min/max.
    func testTenThousandMatchingFaderEventsProduceCorrectRawMinMax() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calib_pub_10k_raw"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        learnControl(engine, action: .leftUpfader, channel: 0, controller: 20)
        engine.startCalibration(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Full 0...127 sweep, out of order, repeated many times over.
        for i in 0..<10_000 {
            engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: i % 128)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.minValue, 0, "The raw accumulator must have captured the true minimum despite the throttled publish")
        XCTAssertEqual(control?.maxValue, 127, "The raw accumulator must have captured the true maximum despite the throttled publish")
    }

    // 2. UI publication count remains bounded, not matching the event count.
    func testCalibrationPublicationCountIsBoundedNotOneToOneWithEvents() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calib_pub_bounded_count"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        learnControl(engine, action: .rightUpfader, channel: 1, controller: 21)
        engine.startCalibration(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let start = Date()
        for i in 0..<10_000 {
            engine.evaluateCalibrationForCC(channel: 1, controller: 21, value: i % 128)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0, "10,000 matching fader events must never hang or take unbounded time")

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThanOrEqual(
            engine.testOnly_calibrationObservedPublishCount, 50,
            "10,000 events over the throttled calibration-observed channel must yield a small, bounded publication count, never one per event"
        )

        engine.cancelCalibration()
    }

    // 3. Cancel with a publication pending: stale values cannot reappear.
    func testCancelWithPublicationPendingCannotRestoreStaleValues() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calib_pub_cancel_pending"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        learnControl(engine, action: .crossfader, channel: 15, controller: 8)
        engine.startCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // This first matching event synchronously enqueues a publish (it is
        // still only PENDING — nothing has yielded to the run loop yet).
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 10)

        // Cancel before that pending publication has a chance to run.
        engine.cancelCalibration()

        // Now let both the stale publication and the cancel's own publish drain.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(engine.calibrationObservedMin, "A stale pending publication must never restore calibration UI after Cancel")
        XCTAssertNil(engine.calibrationObservedMax, "A stale pending publication must never restore calibration UI after Cancel")
        XCTAssertNil(engine.activeCalibrationAction)
    }

    // 4. Finish with a publication pending: stale values cannot reappear.
    func testFinishWithPublicationPendingCannotRestoreStaleValues() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calib_pub_finish_pending"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        learnControl(engine, action: .leftUpfader, channel: 0, controller: 20)
        engine.startCalibration(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Enqueue a pending publish, then immediately finish (a valid, wide
        // range so finish actually succeeds and persists) before that
        // publication has a chance to run.
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 10)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 110)
        engine.finishCalibration()

        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(engine.calibrationObservedMin, "A stale pending publication must never restore calibration UI after Finish")
        XCTAssertNil(engine.calibrationObservedMax, "A stale pending publication must never restore calibration UI after Finish")
        XCTAssertNil(engine.activeCalibrationAction)
        // The finish itself must still have correctly persisted, independent
        // of the discarded stale publication.
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.minValue, 10)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.maxValue, 110)
    }

    // 5. Starting a new calibration: the old generation cannot overwrite it.
    func testNewCalibrationSessionRejectsStalePublicationFromOldGeneration() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calib_pub_new_generation"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        learnControl(engine, action: .crossfader, channel: 15, controller: 8)
        engine.startCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Enqueue a pending publish for the OLD generation, then immediately
        // cancel and start a NEW calibration session before it runs.
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 10)
        engine.cancelCalibration()
        engine.startCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // A genuine event in the NEW session must be reflected correctly —
        // proving the old generation's stale value (10) never leaked in.
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 99)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.calibrationObservedMin, 99, "The old generation's stale publication must never overwrite the new session's values")
        XCTAssertEqual(engine.calibrationObservedMax, 99)
    }
}
