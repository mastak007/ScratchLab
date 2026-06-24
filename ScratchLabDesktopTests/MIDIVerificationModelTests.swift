import XCTest
@testable import ScratchLab

/// Pro-DJ MIDI registry layer — verification plan/result models and the user override /
/// calibration model. Pure models only: events are built from the pure `MIDIMessageParsing`
/// parser; no Core MIDI, no audio, no playback, no engine or RANE scratch-zone code.
final class MIDIVerificationModelTests: XCTestCase {

    // MARK: - Helpers

    /// A Control Change message on `channel` / `cc` (value irrelevant to matching).
    private func cc(_ number: UInt8, channel: UInt8 = 0, value: UInt8 = 64) -> ParsedMIDIMessage {
        MIDIMessageParsing.parse([0xB0 | channel, number, value])
    }
    /// A pitch-bend message on `channel`.
    private func bend(channel: UInt8 = 0) -> ParsedMIDIMessage {
        MIDIMessageParsing.parse([0xE0 | channel, 0x00, 0x40])
    }
    /// A Note On message on `channel` / `note`.
    private func note(_ number: UInt8, channel: UInt8 = 0) -> ParsedMIDIMessage {
        MIDIMessageParsing.parse([0x90 | channel, number, 100])
    }

    // MARK: - Plan creation

    func testPlanSkipsDiagnosticBindings() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        // 2 platters + 1 crossfader + 2 channel faders (L+R) + 2 pitch pairs (L+R)
        // + 2 transport Start/Stop (L+R) + 1 SYNC + 2 PFL cue (L+R)
        // + 8 EQ/gain (4 L + 4 R) + 16 pads (8 L + 8 R) = 36 verifiable.
        // The 2 diagnostic pitch-bend streams are excluded.
        XCTAssertEqual(plan.steps.count, 36)
        XCTAssertEqual(plan.profileIdentifier, "rane-one")
        XCTAssertFalse(plan.steps.contains { $0.binding.isDiagnosticOnly })
        XCTAssertFalse(plan.steps.contains { $0.binding.signal == .pitchBend })
    }

    func testPlanStepCarriesInstructionAndThreshold() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let platterStep = plan.steps.first { $0.role.kind == .platterMovement }
        XCTAssertNotNil(platterStep)
        XCTAssertEqual(platterStep?.requiredEventCount, 4)
        XCTAssertEqual(platterStep?.instruction, platterStep?.role.defaultInstruction)

        let crossfaderStep = plan.steps.first { $0.role.kind == .crossfader }
        XCTAssertEqual(crossfaderStep?.requiredEventCount, 2)
    }

    // MARK: - Binding match honours channel

    func testBindingMatchHonoursChannel() {
        let deck0 = MIDIControlBinding(
            role: MIDIControlRole(kind: .platterMovement, deck: 0),
            signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
            channel: 0
        )
        XCTAssertTrue(deck0.matches(cc(6, channel: 0)))
        XCTAssertFalse(deck0.matches(cc(6, channel: 1)))  // right deck's CC6 is a different control
        XCTAssertFalse(deck0.matches(cc(8, channel: 0)))  // crossfader, not platter
    }

    // MARK: - Verification result pass/fail

    func testEvaluateReportsPerStepPassAndFail() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)

        // Exercise only the LEFT platter (channel 0) and the crossfader (channel 15);
        // never the right.
        var messages: [ParsedMIDIMessage] = []
        messages.append(contentsOf: (0..<6).map { _ in cc(6, channel: 0) })  // ≥4 → left platter passes
        messages.append(contentsOf: (0..<3).map { _ in cc(8, channel: 15) })  // ≥2 → crossfader passes
        // right platter (channel 1, CC6): 0 events → fails

        let result = MIDIVerificationResult.evaluate(plan: plan, messages: messages)

        XCTAssertFalse(result.allPassed)
        XCTAssertEqual(result.passedCount, 2)
        // 34 failures: right platter + left channel fader + right channel fader
        // + 2 pitch pairs (L+R) + 2 transport (L+R) + 1 SYNC + 2 PFL (L+R)
        // + 8 EQ/gain (4 L + 4 R) + 16 pads (8 L + 8 R).
        XCTAssertEqual(result.failedCount, 34)
        XCTAssertEqual(result.summary, "2/36 controls verified")

        let failed = result.failedRoles
        XCTAssertEqual(failed.count, 34)
        // Right platter is the first failure (step 2 in the plan, before other new controls).
        XCTAssertEqual(failed.first?.kind, .platterMovement)
        XCTAssertEqual(failed.first?.deck, 1)
    }

    func testEvaluateAllPass() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        var messages: [ParsedMIDIMessage] = []
        // Platters: 5 CC6 events each (requires ≥4).
        messages.append(contentsOf: (0..<5).map { _ in cc(6, channel: 0) })
        messages.append(contentsOf: (0..<5).map { _ in cc(6, channel: 1) })
        // Crossfader: 3 CC8 events on ch=15 (requires ≥2).
        messages.append(contentsOf: (0..<3).map { _ in cc(8, channel: 15) })
        // Channel faders: 2 CC28 events each on ch=0 and ch=1 (requires ≥2).
        messages.append(cc(28, channel: 0))
        messages.append(cc(28, channel: 0))
        messages.append(cc(28, channel: 1))
        messages.append(cc(28, channel: 1))
        // Pitch pairs: 2 CC9 events each on ch=0 and ch=1 (high-res pair, requires ≥2).
        messages.append(cc(9, channel: 0))
        messages.append(cc(9, channel: 0))
        messages.append(cc(9, channel: 1))
        messages.append(cc(9, channel: 1))
        // EQ/gain (left ch=0, right ch=1): CC22-25, each 1 event (requires 1 each).
        for cc_num: UInt8 in [22, 23, 24, 25] {
            messages.append(cc(cc_num, channel: 0))
            messages.append(cc(cc_num, channel: 1))
        }
        // Transport Start/Stop (requires 1 each): left ch=0 note=0, right ch=1 note=0.
        messages.append(note(0, channel: 0))
        messages.append(note(0, channel: 1))
        // SYNC: ch=1 note=2 (requires 1).
        messages.append(note(2, channel: 1))
        // PFL cue (requires 1 each): left ch=0 note=27, right ch=1 note=27.
        messages.append(note(27, channel: 0))
        messages.append(note(27, channel: 1))
        // Left deck pads (ch=4, notes 20–27): 1 note each.
        for n: UInt8 in 20...27 { messages.append(note(n, channel: 4)) }
        // Right deck pads (ch=5, notes 20–27): 1 note each.
        for n: UInt8 in 20...27 { messages.append(note(n, channel: 5)) }

        let result = MIDIVerificationResult.evaluate(plan: plan, messages: messages)
        XCTAssertTrue(result.allPassed)
        XCTAssertEqual(result.passedCount, 36)
        XCTAssertTrue(result.failedRoles.isEmpty)
    }

    func testEvaluateIgnoresUnrelatedTraffic() {
        // A button profile step should not be satisfied by pitch-bend / unrelated CC noise.
        let buttonBinding = MIDIControlBinding(
            role: MIDIControlRole(kind: .pad, deck: 0, label: "Pad 1"),
            signal: .note(number: 36),
            channel: 0
        )
        let profile = MIDIControllerProfile(
            identifier: "pad-test", displayName: "Pad Test",
            confidence: .community, matching: MIDIProfileMatching(),
            deckCount: 1, bindings: [buttonBinding]
        )
        let plan = MIDIVerificationPlan.make(for: profile)

        let noise = [bend(channel: 0), cc(20, channel: 0), bend(channel: 1)]
        XCTAssertFalse(MIDIVerificationResult.evaluate(plan: plan, messages: noise).allPassed)

        let hit = [note(36, channel: 0)]
        XCTAssertTrue(MIDIVerificationResult.evaluate(plan: plan, messages: hit).allPassed)
    }

    func testResultCodableRoundtrip() throws {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let result = MIDIVerificationResult.evaluate(plan: plan, messages: (0..<5).map { _ in cc(6, channel: 0) })
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(MIDIVerificationResult.self, from: data), result)
    }

    func testPlanCodableRoundtrip() throws {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(MIDIVerificationPlan.self, from: data), plan)
    }

    // MARK: - User override / calibration

    func testUserOverrideCodableRoundtrip() throws {
        let override = MIDIUserOverrideProfile(
            baseProfileIdentifier: "rane-one",
            deviceIdentity: MIDIDeviceIdentity(sourceName: "RANE ONE", uniqueID: 42, manufacturer: "RANE"),
            bindingOverrides: [
                MIDIControlBinding(
                    role: MIDIControlRole(kind: .crossfader),
                    signal: .highResCCPair(msb: 31, lsb: 63),
                    channel: 6
                )
            ],
            calibration: MIDICalibration(
                platterRotation: MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 3932, sampleRevolutions: 3),
                platterDirection: .correct,
                crossfaderRange: MIDICrossfaderRange(rawMin: 0, rawMax: 127),
                crossfaderOrientation: .inverted
            ),
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(override)
        let decoded = try MIDIUserOverrideProfile.decode(from: data)
        XCTAssertEqual(decoded, override)
        XCTAssertTrue(decoded.isVerified)
    }

    func testUserOverrideUnknownSchemaFailsClosed() throws {
        let future = MIDIUserOverrideProfile(
            schemaVersion: MIDIUserOverrideProfile.currentSchemaVersion + 1,
            baseProfileIdentifier: "rane-one"
        )
        let data = try JSONEncoder().encode(future)
        XCTAssertThrowsError(try MIDIUserOverrideProfile.decode(from: data)) { error in
            XCTAssertEqual(
                error as? MIDIControllerProfileError,
                .unsupportedSchemaVersion(MIDIUserOverrideProfile.currentSchemaVersion + 1)
            )
        }
    }

    func testAppliedOverrideReplacesBindingAndDowngradesConfidence() {
        // Override the crossfader to a 14-bit pair; base stays untouched.
        let override = MIDIUserOverrideProfile(
            baseProfileIdentifier: "rane-one",
            bindingOverrides: [
                MIDIControlBinding(role: MIDIControlRole(kind: .crossfader),
                                   signal: .highResCCPair(msb: 31, lsb: 63), channel: 6)
            ]
        )
        let base = MIDIControllerProfile.raneOneSeed
        let merged = override.applied(to: base)

        XCTAssertEqual(merged.identifier, base.identifier)
        XCTAssertEqual(merged.confidence, .community)                 // downgraded due to edits
        XCTAssertEqual(merged.binding(for: .crossfader)?.signal, .highResCCPair(msb: 31, lsb: 63))
        XCTAssertEqual(merged.bindings.count, base.bindings.count)    // replaced, not appended
        // Base profile is unchanged.
        XCTAssertEqual(base.binding(for: .crossfader)?.signal, .absoluteCC(number: 8))
        XCTAssertEqual(base.confidence, .certified)
    }

    func testAppliedOverrideAppendsNewBinding() {
        // Use .deckSelect — not in the seed — to exercise the append path.
        // .channelFader deck 1 is now in the seed (added via verified re-capture),
        // so use a role that is genuinely absent.
        let override = MIDIUserOverrideProfile(
            baseProfileIdentifier: "rane-one",
            bindingOverrides: [
                MIDIControlBinding(
                    role: MIDIControlRole(kind: .deckSelect, deck: 0, label: "Deck Select Left"),
                    signal: .note(number: 42), channel: 1)
            ]
        )
        let base = MIDIControllerProfile.raneOneSeed
        let merged = override.applied(to: base)
        XCTAssertEqual(merged.bindings.count, base.bindings.count + 1)
        XCTAssertNotNil(merged.binding(for: .deckSelect, deck: 0))
    }

    func testEmptyOverrideKeepsConfidence() {
        let override = MIDIUserOverrideProfile(baseProfileIdentifier: "rane-one")
        XCTAssertEqual(override.applied(to: .raneOneSeed).confidence, .certified)
    }

    // MARK: - NRPN / RPN must not false-match ordinary CC

    func testNRPNDoesNotMatchOrdinaryCC() {
        let binding = MIDIControlBinding(
            role: MIDIControlRole(kind: .unknown),
            signal: .nrpn(parameter: 1234),
            channel: 0
        )
        // Ordinary CC traffic (including the data-entry CC6/CC38 used by real NRPN) must
        // not be mistaken for an NRPN parameter change until a real decoder exists.
        XCTAssertFalse(binding.matches(cc(99, channel: 0)))
        XCTAssertFalse(binding.matches(cc(6, channel: 0)))
        XCTAssertFalse(binding.matches(cc(38, channel: 0)))
    }

    func testRPNDoesNotMatchOrdinaryCC() {
        let binding = MIDIControlBinding(
            role: MIDIControlRole(kind: .unknown),
            signal: .rpn(parameter: 0),
            channel: 0
        )
        XCTAssertFalse(binding.matches(cc(101, channel: 0)))
        XCTAssertFalse(binding.matches(cc(100, channel: 0)))
    }

    func testNRPNStepNeverVerifiesFromCCNoise() {
        let profile = MIDIControllerProfile(
            identifier: "nrpn-test", displayName: "NRPN Test",
            confidence: .community, matching: MIDIProfileMatching(),
            deckCount: 0,
            bindings: [MIDIControlBinding(role: MIDIControlRole(kind: .unknown), signal: .nrpn(parameter: 1), channel: 0)]
        )
        let plan = MIDIVerificationPlan.make(for: profile)
        let ccNoise = (0..<50).map { _ in cc(20, channel: 0) }
        XCTAssertFalse(MIDIVerificationResult.evaluate(plan: plan, messages: ccNoise).allPassed)
    }

    // MARK: - First-class verification checks (Fix 3)

    func testPlanEncodesPlatterChecks() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let platterStep = plan.steps.first { $0.role.kind == .platterMovement }
        XCTAssertEqual(
            platterStep?.checks,
            [.platterForwardMotion, .platterBackwardMotion, .platterFullRotationCalibration, .platterNoAliasingNoise]
        )
    }

    func testPlanEncodesCrossfaderChecks() {
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let crossfaderStep = plan.steps.first { $0.role.kind == .crossfader }
        XCTAssertEqual(
            crossfaderStep?.checks,
            [.crossfaderMinMax, .crossfaderInversion, .crossfaderCutThreshold, .crossfaderQuickCuts]
        )
    }

    func testResultSummarizesPassFailPerCheck() {
        // A platter step that is live but fails the no-aliasing check.
        let platterResult = MIDIVerificationStepResult(
            role: MIDIControlRole(kind: .platterMovement, deck: 0),
            expectedSignal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
            observedEventCount: 10,
            requiredEventCount: 4,
            checkOutcomes: [
                MIDIVerificationCheckOutcome(check: .platterForwardMotion, passed: true,
                                             measurement: .platterDirection(.correct)),
                MIDIVerificationCheckOutcome(check: .platterBackwardMotion, passed: true,
                                             measurement: .platterDirection(.correct)),
                MIDIVerificationCheckOutcome(check: .platterFullRotationCalibration, passed: true,
                                             measurement: .platterRotation(MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 3932, sampleRevolutions: 2))),
                MIDIVerificationCheckOutcome(check: .platterNoAliasingNoise, passed: false,
                                             measurement: .platterNoise(MIDIPlatterNoiseMetrics(totalEvents: 200, aliasedEventCount: 12, maxPerEventDelta: 9000)),
                                             detail: "noisy on slow reverse")
            ]
        )
        let result = MIDIVerificationResult(profileIdentifier: "rane-one", stepResults: [platterResult])

        // Liveness passed, but a failing check fails the step overall.
        XCTAssertTrue(platterResult.livenessPassed)
        XCTAssertFalse(platterResult.checksPassed)
        XCTAssertFalse(platterResult.passed)

        XCTAssertEqual(result.passedCheckCount, 3)
        XCTAssertEqual(result.failedChecks, [.platterNoAliasingNoise])
        XCTAssertEqual(result.checkSummary, "3/4 checks passed")
        XCTAssertFalse(result.allPassed)
    }

    func testResultWithChecksCodableRoundtrip() {
        let stepResult = MIDIVerificationStepResult(
            role: MIDIControlRole(kind: .crossfader),
            expectedSignal: .absoluteCC(number: 8),
            observedEventCount: 5,
            requiredEventCount: 2,
            checkOutcomes: [
                MIDIVerificationCheckOutcome(check: .crossfaderMinMax, passed: true,
                                             measurement: .crossfaderRange(MIDICrossfaderRange(rawMin: 0, rawMax: 127))),
                MIDIVerificationCheckOutcome(check: .crossfaderInversion, passed: false,
                                             measurement: .crossfaderOrientation(.inverted)),
                MIDIVerificationCheckOutcome(check: .crossfaderCutThreshold, passed: true,
                                             measurement: .crossfaderCutThreshold(MIDICrossfaderCutThreshold(positionFraction: 0.04, rawValue: 5))),
                MIDIVerificationCheckOutcome(check: .crossfaderQuickCuts, passed: true,
                                             measurement: .quickCut(MIDIQuickCutMetrics(cutCount: 8, fastestCutSeconds: 0.03, medianCutSeconds: 0.05)))
            ]
        )
        let result = MIDIVerificationResult(profileIdentifier: "rane-one", stepResults: [stepResult])
        do {
            let data = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(MIDIVerificationResult.self, from: data)
            XCTAssertEqual(decoded, result)
            XCTAssertEqual(decoded.failedChecks, [.crossfaderInversion])
        } catch {
            XCTFail("round-trip threw: \(error)")
        }
    }

    func testPlanWithChecksCodableRoundtrip() throws {
        // The plan itself carries the encoded checks; round-trip must preserve them.
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(MIDIVerificationPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
        XCTAssertTrue(decoded.steps.contains { $0.checks.contains(.platterFullRotationCalibration) })
        XCTAssertTrue(decoded.steps.contains { $0.checks.contains(.crossfaderQuickCuts) })
    }

    // MARK: - Non-RANE shape coverage (synthetic fixtures only — NOT certified hardware)

    /// A deckless, crossfader-only mixer shape (DJM-S9-style). Synthetic test fixture.
    private func decklessMixerFixture() -> MIDIControllerProfile {
        MIDIControllerProfile(
            identifier: "test-deckless-mixer",
            displayName: "Test Deckless Mixer (synthetic)",
            confidence: .community,
            matching: MIDIProfileMatching(),
            deckCount: 0,
            bindings: [
                MIDIControlBinding(role: MIDIControlRole(kind: .crossfader),
                                   signal: .absoluteCC(number: 8), channel: 6),
                MIDIControlBinding(role: MIDIControlRole(kind: .channelFader, deck: 0),
                                   signal: .absoluteCC(number: 19), channel: 0),
                MIDIControlBinding(role: MIDIControlRole(kind: .channelFader, deck: 1),
                                   signal: .absoluteCC(number: 19), channel: 1)
            ],
            notes: "Synthetic fixture — not a certified hardware profile."
        )
    }

    /// A multi-control player/controller shape (DDJ/CDJ/XDJ-style): jog/platter +
    /// transport + pads. Synthetic test fixture.
    private func multiControlPlayerFixture() -> MIDIControllerProfile {
        MIDIControllerProfile(
            identifier: "test-multi-control-player",
            displayName: "Test Multi-Control Player (synthetic)",
            confidence: .community,
            matching: MIDIProfileMatching(),
            deckCount: 2,
            bindings: [
                MIDIControlBinding(role: MIDIControlRole(kind: .platterMovement, deck: 0),
                                   signal: .relativeCC(number: 34, encoding: .twosComplement), channel: 0),
                MIDIControlBinding(role: MIDIControlRole(kind: .needleStrip, deck: 0),
                                   signal: .highResCCPair(msb: 2, lsb: 34), channel: 0),
                MIDIControlBinding(role: MIDIControlRole(kind: .transport, deck: 0, label: "Play/Pause"),
                                   signal: .note(number: 11), channel: 0),
                MIDIControlBinding(role: MIDIControlRole(kind: .pad, deck: 0, label: "Pad 1"),
                                   signal: .note(number: 36), channel: 7),
                MIDIControlBinding(role: MIDIControlRole(kind: .tempo, deck: 0),
                                   signal: .highResCCPair(msb: 0, lsb: 32), channel: 0)
            ],
            notes: "Synthetic fixture — not a certified hardware profile."
        )
    }

    func testDecklessMixerShapeIsRepresentable() throws {
        let mixer = decklessMixerFixture()
        XCTAssertEqual(mixer.deckCount, 0)
        XCTAssertNil(mixer.binding(for: .platterMovement))           // a mixer has no platter
        XCTAssertNotNil(mixer.binding(for: .crossfader))
        XCTAssertEqual(mixer.bindings.filter { $0.role.kind == .channelFader }.count, 2)
        XCTAssertNotEqual(mixer.confidence, .certified)              // synthetic, not certified

        // Codable round-trip preserves the deckless shape.
        let data = try JSONEncoder().encode(mixer)
        XCTAssertEqual(try MIDIControllerProfile.decode(from: data), mixer)

        // A verification plan builds for it (crossfader gets crossfader checks).
        let plan = MIDIVerificationPlan.make(for: mixer)
        XCTAssertEqual(plan.steps.count, 3)
        let crossfaderStep = plan.steps.first { $0.role.kind == .crossfader }
        XCTAssertEqual(crossfaderStep?.checks.first, .crossfaderMinMax)
    }

    func testMultiControlPlayerShapeIsRepresentable() throws {
        let player = multiControlPlayerFixture()
        XCTAssertEqual(player.deckCount, 2)
        XCTAssertNotNil(player.binding(for: .platterMovement, deck: 0))
        XCTAssertNotNil(player.binding(for: .transport, deck: 0))
        XCTAssertNotNil(player.binding(for: .needleStrip, deck: 0))
        XCTAssertNotNil(player.binding(for: .pad, deck: 0))
        XCTAssertNotEqual(player.confidence, .certified)

        // Codable round-trip preserves the multi-role shape (incl. relative + note + 14-bit).
        let data = try JSONEncoder().encode(player)
        XCTAssertEqual(try MIDIControllerProfile.decode(from: data), player)

        // Platter step carries the full platter check set; the pad note verifies cleanly.
        let plan = MIDIVerificationPlan.make(for: player)
        let platterStep = plan.steps.first { $0.role.kind == .platterMovement }
        XCTAssertEqual(platterStep?.checks.count, 4)

        let padResult = MIDIVerificationResult.evaluate(plan: plan, messages: [note(36, channel: 7)])
        XCTAssertTrue(padResult.stepResults.contains { $0.role.kind == .pad && $0.livenessPassed })
    }

    // MARK: - Typed measured values (Codex follow-up)

    func testVerificationMeasurementCodableRoundtripAcrossCases() throws {
        let measurements: [MIDIVerificationMeasurement] = [
            .platterDirection(.inverted),
            .platterRotation(MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 3932, sampleRevolutions: 2)),
            .platterNoise(MIDIPlatterNoiseMetrics(totalEvents: 500, aliasedEventCount: 7, maxPerEventDelta: 8200)),
            .crossfaderRange(MIDICrossfaderRange(rawMin: 0, rawMax: 127)),
            .crossfaderOrientation(.normal),
            .crossfaderCutThreshold(MIDICrossfaderCutThreshold(positionFraction: 0.05, rawValue: 6)),
            .quickCut(MIDIQuickCutMetrics(cutCount: 10, fastestCutSeconds: 0.02, medianCutSeconds: 0.04))
        ]
        for measurement in measurements {
            let data = try JSONEncoder().encode(measurement)
            XCTAssertEqual(try JSONDecoder().decode(MIDIVerificationMeasurement.self, from: data), measurement)
        }
    }

    func testCalibrationCodableRoundtripWithAllTypedValues() throws {
        let calibration = MIDICalibration(
            platterRotation: MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 3932, sampleRevolutions: 5),
            platterDirection: .correct,
            platterNoise: MIDIPlatterNoiseMetrics(totalEvents: 1000, aliasedEventCount: 0, maxPerEventDelta: 1),
            crossfaderRange: MIDICrossfaderRange(rawMin: 2, rawMax: 126),
            crossfaderOrientation: .normal,
            crossfaderCutThreshold: MIDICrossfaderCutThreshold(positionFraction: 0.04, rawValue: 5),
            quickCut: MIDIQuickCutMetrics(cutCount: 12, fastestCutSeconds: 0.018, medianCutSeconds: 0.033)
        )
        XCTAssertFalse(calibration.isEmpty)
        let data = try JSONEncoder().encode(calibration)
        XCTAssertEqual(try JSONDecoder().decode(MIDICalibration.self, from: data), calibration)
    }

    func testCalibrationRecordsOnlyMeasuredFields() throws {
        // Only the platter rotation was measured; everything else stays nil (not zeroed).
        let calibration = MIDICalibration(
            platterRotation: MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 4096)
        )
        XCTAssertFalse(calibration.isEmpty)
        XCTAssertNil(calibration.crossfaderRange)
        XCTAssertNil(calibration.crossfaderOrientation)
        XCTAssertNil(calibration.quickCut)
        XCTAssertEqual(calibration.platterRotation?.sampleRevolutions, 1) // default

        let empty = MIDICalibration()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(MIDICalibration.self, from: JSONEncoder().encode(empty)), empty)
    }

    func testTypedValueValidityHelpers() {
        XCTAssertTrue(MIDICrossfaderRange(rawMin: 0, rawMax: 127).isValid)
        XCTAssertEqual(MIDICrossfaderRange(rawMin: 0, rawMax: 127).span, 127)
        XCTAssertFalse(MIDICrossfaderRange(rawMin: 100, rawMax: 100).isValid)
        XCTAssertEqual(MIDICrossfaderRange(rawMin: 100, rawMax: 50).span, 0)

        XCTAssertTrue(MIDICrossfaderCutThreshold(positionFraction: 0.04).isInUnitRange)
        XCTAssertFalse(MIDICrossfaderCutThreshold(positionFraction: 1.4).isInUnitRange)

        XCTAssertTrue(MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 3932).isValid)
        XCTAssertFalse(MIDIPlatterRotationMeasurement(measuredStepsPerRevolution: 0).isValid)

        XCTAssertEqual(MIDIPlatterNoiseMetrics(totalEvents: 200, aliasedEventCount: 50, maxPerEventDelta: 9000).aliasFraction, 0.25, accuracy: 1e-12)
        XCTAssertEqual(MIDIPlatterNoiseMetrics(totalEvents: 0, aliasedEventCount: 0, maxPerEventDelta: 0).aliasFraction, 0, accuracy: 1e-12)
    }

    func testUserOverrideSchemaIsV2AndOldShapeFailsClosed() throws {
        XCTAssertEqual(MIDIUserOverrideProfile.currentSchemaVersion, 2)

        // A v1 override document (the only thing that ever existed before) must fail closed.
        let v1 = MIDIUserOverrideProfile(
            schemaVersion: 1,
            baseProfileIdentifier: "rane-one"
        )
        let data = try JSONEncoder().encode(v1)
        XCTAssertThrowsError(try MIDIUserOverrideProfile.decode(from: data)) { error in
            XCTAssertEqual(error as? MIDIControllerProfileError, .unsupportedSchemaVersion(1))
        }
    }

    func testEvaluateLeavesMeasurementNil() {
        // Pure-model guarantee: the event-count evaluate path never fabricates measurements.
        let plan = MIDIVerificationPlan.make(for: .raneOneSeed)
        let messages = (0..<8).map { _ in cc(6, channel: 0) }
        let result = MIDIVerificationResult.evaluate(plan: plan, messages: messages)
        XCTAssertTrue(result.stepResults.allSatisfy { $0.checkOutcomes.isEmpty })
        XCTAssertTrue(result.allCheckOutcomes.isEmpty)
    }

    func testCheckOutcomeMeasurementDefaultsNil() {
        let outcome = MIDIVerificationCheckOutcome(check: .platterForwardMotion, passed: true)
        XCTAssertNil(outcome.measurement)
        XCTAssertNil(outcome.detail)
    }

    // MARK: - Requirements / readiness bridge

    /// A passing outcome for a check (no measurement needed for readiness logic).
    private func pass(_ check: MIDIVerificationCheck) -> MIDIVerificationCheckOutcome {
        MIDIVerificationCheckOutcome(check: check, passed: true)
    }
    /// A failing outcome for a check.
    private func fail(_ check: MIDIVerificationCheck) -> MIDIVerificationCheckOutcome {
        MIDIVerificationCheckOutcome(check: check, passed: false)
    }
    /// A single-step result carrying the given check outcomes for a role.
    private func result(profile: String, role: MIDIControlRole, signal: MIDIControlSignalType,
                        outcomes: [MIDIVerificationCheckOutcome]) -> MIDIVerificationResult {
        MIDIVerificationResult(
            profileIdentifier: profile,
            stepResults: [
                MIDIVerificationStepResult(
                    role: role, expectedSignal: signal,
                    observedEventCount: 99, requiredEventCount: 1,
                    checkOutcomes: outcomes
                )
            ]
        )
    }

    /// A platter-only profile (one deck, relative CC) — no crossfader binding.
    private func platterOnlyFixture(confidence: MIDIProfileConfidence = .community) -> MIDIControllerProfile {
        MIDIControllerProfile(
            identifier: "test-platter-only", displayName: "Test Platter Only (synthetic)",
            confidence: confidence, matching: MIDIProfileMatching(), deckCount: 1,
            bindings: [
                MIDIControlBinding(role: MIDIControlRole(kind: .platterMovement, deck: 0),
                                   signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)), channel: 0)
            ],
            notes: "Synthetic fixture — not a certified hardware profile."
        )
    }

    /// A crossfader-only deckless mixer (DJM-S9-style) — no platter binding.
    private func decklessCrossfaderFixture(confidence: MIDIProfileConfidence = .community) -> MIDIControllerProfile {
        MIDIControllerProfile(
            identifier: "test-deckless-xf", displayName: "Test Deckless Mixer (synthetic)",
            confidence: confidence, matching: MIDIProfileMatching(), deckCount: 0,
            bindings: [
                MIDIControlBinding(role: MIDIControlRole(kind: .crossfader),
                                   signal: .absoluteCC(number: 8), channel: 6)
            ],
            notes: "Synthetic fixture — not a certified hardware profile."
        )
    }

    // MARK: Requirement derivation

    func testPlatterRequirementDerivationIncludesAllPlatterChecks() {
        let set = MIDIVerificationRequirementSet.make(for: platterOnlyFixture())
        XCTAssertEqual(
            Set(set.requirements.map(\.check)),
            [.platterForwardMotion, .platterBackwardMotion, .platterFullRotationCalibration, .platterNoAliasingNoise]
        )
        // All platter checks are required + blocking correctness gates.
        XCTAssertTrue(set.requirements.allSatisfy { $0.isRequired && $0.blocksUseOnFailure })
    }

    func testCrossfaderRequirementDerivationIncludesAllCrossfaderChecks() {
        let set = MIDIVerificationRequirementSet.make(for: decklessCrossfaderFixture())
        XCTAssertEqual(
            Set(set.requirements.map(\.check)),
            [.crossfaderMinMax, .crossfaderInversion, .crossfaderCutThreshold, .crossfaderQuickCuts]
        )
        // Quick cuts is the lone optional / non-blocking refinement.
        XCTAssertEqual(Set(set.requiredChecks), [.crossfaderMinMax, .crossfaderInversion, .crossfaderCutThreshold])
        XCTAssertEqual(set.optionalChecks, [.crossfaderQuickCuts])
        XCTAssertEqual(set.requirement(for: .crossfaderQuickCuts)?.blocksUseOnFailure, false)
    }

    func testDecklessMixerRequiresNoPlatterChecks() {
        let set = MIDIVerificationRequirementSet.make(for: decklessCrossfaderFixture())
        let platterChecks: Set<MIDIVerificationCheck> =
            [.platterForwardMotion, .platterBackwardMotion, .platterFullRotationCalibration, .platterNoAliasingNoise]
        XCTAssertTrue(Set(set.requirements.map(\.check)).isDisjoint(with: platterChecks))
    }

    func testPlatterOnlyRequiresNoCrossfaderChecks() {
        let set = MIDIVerificationRequirementSet.make(for: platterOnlyFixture())
        let crossfaderChecks: Set<MIDIVerificationCheck> =
            [.crossfaderMinMax, .crossfaderInversion, .crossfaderCutThreshold, .crossfaderQuickCuts]
        XCTAssertTrue(Set(set.requirements.map(\.check)).isDisjoint(with: crossfaderChecks))
    }

    func testRequirementSetDedupesChecksAcrossDecks() {
        // The RANE seed has two platter decks sharing the same four checks → one each.
        let set = MIDIVerificationRequirementSet.make(for: .raneOneSeed)
        XCTAssertEqual(set.requirements.count, Set(set.requirements.map(\.check)).count)
        // Two-deck platter + crossfader = 4 platter checks + 4 crossfader checks = 8 unique.
        XCTAssertEqual(set.requirements.count, 8)
    }

    // MARK: Calibration field mapping

    func testCheckToCalibrationFieldMapping() {
        XCTAssertEqual(MIDIVerificationCheck.platterForwardMotion.calibrationField, .platterDirection)
        XCTAssertEqual(MIDIVerificationCheck.platterBackwardMotion.calibrationField, .platterDirection)
        XCTAssertEqual(MIDIVerificationCheck.platterFullRotationCalibration.calibrationField, .platterRotation)
        XCTAssertEqual(MIDIVerificationCheck.platterNoAliasingNoise.calibrationField, .platterNoise)
        XCTAssertEqual(MIDIVerificationCheck.crossfaderMinMax.calibrationField, .crossfaderRange)
        XCTAssertEqual(MIDIVerificationCheck.crossfaderInversion.calibrationField, .crossfaderOrientation)
        XCTAssertEqual(MIDIVerificationCheck.crossfaderCutThreshold.calibrationField, .crossfaderCutThreshold)
        XCTAssertEqual(MIDIVerificationCheck.crossfaderQuickCuts.calibrationField, .quickCut)
        // The requirement carries the same mapping through.
        let set = MIDIVerificationRequirementSet.make(for: decklessCrossfaderFixture())
        XCTAssertEqual(set.requirement(for: .crossfaderMinMax)?.producesCalibration, .crossfaderRange)
    }

    // MARK: Readiness verdict

    func testFailedRequiredCheckProducesBlocked() {
        let profile = platterOnlyFixture(confidence: .certified)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        // All present; one required check fails (no aliasing).
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .platterMovement, deck: 0),
                         signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                         outcomes: [pass(.platterForwardMotion), pass(.platterBackwardMotion),
                                    pass(.platterFullRotationCalibration), fail(.platterNoAliasingNoise)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .blocked)
        XCTAssertEqual(readiness.blockingFailures, [.platterNoAliasingNoise])
        XCTAssertTrue(readiness.missingRequiredChecks.isEmpty)
        XCTAssertFalse(readiness.isReady)
    }

    func testFailedOptionalCheckDoesNotBlockReadiness() {
        let profile = decklessCrossfaderFixture(confidence: .certified)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        // All required crossfader checks pass; only the optional quick-cuts fails.
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .crossfader),
                         signal: .absoluteCC(number: 8),
                         outcomes: [pass(.crossfaderMinMax), pass(.crossfaderInversion),
                                    pass(.crossfaderCutThreshold), fail(.crossfaderQuickCuts)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .ready)
        XCTAssertTrue(readiness.blockingFailures.isEmpty)
        XCTAssertEqual(readiness.failedOptionalChecks, [.crossfaderQuickCuts])
        XCTAssertTrue(readiness.isReady)
    }

    func testHeuristicConfidenceProducesVerificationRequired() {
        let profile = decklessCrossfaderFixture(confidence: .heuristic)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        XCTAssertTrue(set.confidenceRequiresVerification)
        // Even with every required check passing, low confidence forces verification.
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .crossfader),
                         signal: .absoluteCC(number: 8),
                         outcomes: [pass(.crossfaderMinMax), pass(.crossfaderInversion),
                                    pass(.crossfaderCutThreshold), pass(.crossfaderQuickCuts)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .verificationRequired)
        XCTAssertTrue(readiness.confidenceRequiresVerification)
        XCTAssertTrue(readiness.blockingFailures.isEmpty)
        XCTAssertTrue(readiness.missingRequiredChecks.isEmpty)
    }

    func testUnverifiedConfidenceProducesVerificationRequired() {
        // The unverified fallback (no bindings) is gated purely by confidence.
        let fallback = MIDIHardwareRegistry.unverifiedFallback(
            for: MIDIDeviceIdentity(sourceName: "Mystery Controller")
        ).profile
        let set = MIDIVerificationRequirementSet.make(for: fallback)
        XCTAssertTrue(set.requirements.isEmpty)
        XCTAssertTrue(set.confidenceRequiresVerification)
        let readiness = MIDIVerificationReadiness.evaluate(
            requirements: set,
            result: MIDIVerificationResult(profileIdentifier: fallback.identifier, stepResults: [])
        )
        XCTAssertEqual(readiness.verdict, .verificationRequired)
    }

    func testMissingRequiredCheckReportedAndForcesVerification() {
        let profile = platterOnlyFixture(confidence: .certified)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        // Only two of the four required platter checks were exercised; both pass.
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .platterMovement, deck: 0),
                         signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                         outcomes: [pass(.platterForwardMotion), pass(.platterBackwardMotion)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .verificationRequired)
        XCTAssertTrue(readiness.blockingFailures.isEmpty)
        XCTAssertEqual(
            Set(readiness.missingRequiredChecks),
            [.platterFullRotationCalibration, .platterNoAliasingNoise]
        )
    }

    func testAllRequiredPassingTrustedProfileIsReady() {
        let profile = platterOnlyFixture(confidence: .certified)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .platterMovement, deck: 0),
                         signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                         outcomes: [pass(.platterForwardMotion), pass(.platterBackwardMotion),
                                    pass(.platterFullRotationCalibration), pass(.platterNoAliasingNoise)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .ready)
        XCTAssertFalse(readiness.confidenceRequiresVerification)
    }

    func testBlockingTakesPrecedenceOverLowConfidence() {
        // A blocking failure on a low-confidence profile is `.blocked`, not just verify.
        let profile = platterOnlyFixture(confidence: .heuristic)
        let set = MIDIVerificationRequirementSet.make(for: profile)
        let res = result(profile: profile.identifier,
                         role: MIDIControlRole(kind: .platterMovement, deck: 0),
                         signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                         outcomes: [fail(.platterForwardMotion), pass(.platterBackwardMotion),
                                    pass(.platterFullRotationCalibration), pass(.platterNoAliasingNoise)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        XCTAssertEqual(readiness.verdict, .blocked)
        XCTAssertEqual(readiness.blockingFailures, [.platterForwardMotion])
    }

    // MARK: Codable round-trips

    func testRequirementSetCodableRoundtrip() throws {
        let set = MIDIVerificationRequirementSet.make(for: .raneOneSeed)
        let data = try JSONEncoder().encode(set)
        XCTAssertEqual(try JSONDecoder().decode(MIDIVerificationRequirementSet.self, from: data), set)
    }

    func testReadinessCodableRoundtrip() throws {
        let set = MIDIVerificationRequirementSet.make(for: decklessCrossfaderFixture(confidence: .heuristic))
        let res = result(profile: "test-deckless-xf",
                         role: MIDIControlRole(kind: .crossfader),
                         signal: .absoluteCC(number: 8),
                         outcomes: [fail(.crossfaderMinMax), pass(.crossfaderInversion)])
        let readiness = MIDIVerificationReadiness.evaluate(requirements: set, result: res)
        let data = try JSONEncoder().encode(readiness)
        XCTAssertEqual(try JSONDecoder().decode(MIDIVerificationReadiness.self, from: data), readiness)
    }

    func testCalibrationFieldCodableRoundtripAcrossCases() throws {
        for field in MIDICalibrationField.allCases {
            let data = try JSONEncoder().encode(field)
            XCTAssertEqual(try JSONDecoder().decode(MIDICalibrationField.self, from: data), field)
        }
    }
}
