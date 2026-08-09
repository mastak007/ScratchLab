#if DEBUG

import SwiftUI

// MARK: - TimecodeControlCard

/// DEBUG-only card wrapping the Batch 1 `TimecodeInputStatusCard` and adding
/// Batch 3 mode, calibration, and pipeline status controls.
///
/// ## Sections
///
/// 1. **Diagnostics** — the existing `TimecodeInputStatusCard` (L/R levels,
///    health badge, warnings).
/// 2. **Mode & Calibration** — mode picker, channel picker, invert toggle,
///    rate-scale slider, min-confidence slider, reset button.
/// 3. **Pipeline Status** — decoded direction, rate, confidence, accepted /
///    dropped counters, last drop reason, source label.
///
/// **Batch 3:** Control pipeline only. No live AVCapture wiring.
/// **Batch 10:** Profile/preset picker, setup checklist, validation-override.
struct TimecodeControlCard: View {

    // Listening-fix (SwiftUI publish-during-render, uncommitted): plain
    // (not `@ObservedObject`) for the same reason as `DVSControlVinylPanel`
    // — both objects carry realtime, lock-protected state updated at
    // ~60 Hz by the DVS control worker, and observing them directly here
    // re-ran this entire card's body (sliders, toggles, and all) on every
    // tick. Every interactive control below already used, or has been
    // converted to, a manual `Binding(get:set:)` (see `invertDirectionBinding`
    // for the pre-existing example this follows) — those read/write the
    // real `pipeline`/`bridge` directly and don't require `@ObservedObject`.
    // This card's own re-render is instead gated on `uiRefreshTick`, bumped
    // by a bounded main-actor-only timer never triggered by the realtime tick.
    let pipeline: TimecodeControlPipeline
    let bridge: TimecodePlaybackBridge
    @State private var uiRefreshTick = 0
    private let uiRefreshTimer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    /// Persisted mode so the picker survives view disappearance.
    @AppStorage("scratchlab.mac.timecodeMode") private var persistedModeRaw: String = TimecodeControlMode.disabled.rawValue

    /// Persisted preset selection.
    @AppStorage("scratchlab.mac.timecodePreset") private var persistedPresetRaw: String = TimecodeControlPreset.scratchLabPrototype.rawValue

    /// Persisted user-customized min confidence, independent of any preset's
    /// fixed constant. Only read/written when the preset is `.manual` — a
    /// fresh `TimecodeControlPipeline` instance (e.g. after relaunch) starts
    /// at its own default and has no memory of a prior manual adjustment, so
    /// this is what lets a deliberately-set value (e.g. 0.10) survive.
    @AppStorage("scratchlab.mac.timecodeMinConfidenceOverride") private var persistedMinConfidenceOverride: Double = 0.3

    /// Persisted user-customized direction sign, independent of any preset's
    /// fixed constant (both built-in presets fix this to `false`). Some real
    /// DVS hardware's quadrature wiring reports the opposite sign convention
    /// this decoder assumes — this lets a user correct it per-device and
    /// have it survive relaunch, mirroring `persistedMinConfidenceOverride`.
    @AppStorage("scratchlab.mac.timecodeInvertDirectionOverride") private var persistedInvertDirectionOverride: Bool = false

    /// Current selected preset.
    @State private var selectedPreset: TimecodeControlPreset = .scratchLabPrototype

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSection
            Divider().opacity(0.3)
            profileSection
            Divider().opacity(0.3)
            setupChecklistSection
            Divider().opacity(0.3)
            playbackBridgeSection
            Divider().opacity(0.3)
#if ENABLE_TIMECODE_LIVE_TAP
            liveTapSection
            Divider().opacity(0.3)
#endif
            diagnosticsSection
            Divider().opacity(0.3)
            calibrationSection
            Divider().opacity(0.3)
            pipelineStatusSection
            Divider().opacity(0.3)
            validationSection
            Divider().opacity(0.3)
            TimecodeRecordingSection(
                recorder: pipeline.prototypeRecorder,
                isActive: pipeline.mode == .controlPrototype
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScratchLabDesign.Card.compactPadding)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Card.cornerRadius, style: .continuous)
        )
        .onAppear {
            // Restore persisted mode
            if let restored = TimecodeControlMode(rawValue: persistedModeRaw) {
                pipeline.mode = restored
            }
            // Restore persisted preset
            if let restored = TimecodeControlPreset(rawValue: persistedPresetRaw) {
                selectedPreset = restored
                if restored == .manual {
                    // A fresh pipeline instance (e.g. after relaunch) has its
                    // own defaults, not the user's prior custom values —
                    // restore them before re-applying the (round-trip)
                    // manual profile so the customization isn't lost.
                    pipeline.minConfidence = persistedMinConfidenceOverride
                    pipeline.invertDirection = persistedInvertDirectionOverride
                }
                applyPreset(restored)
            }
        }
        .onChange(of: pipeline.mode) { newMode in
            persistedModeRaw = newMode.rawValue
        }
        .onChange(of: selectedPreset) { newPreset in
            persistedPresetRaw = newPreset.rawValue
            applyPreset(newPreset)
        }
        .onReceive(uiRefreshTimer) { _ in uiRefreshTick += 1 }
    }

    // MARK: - Manual bindings (plain `pipeline`/`bridge` — see their doc comment)

    private var modeBinding: Binding<TimecodeControlMode> {
        Binding(get: { pipeline.mode }, set: { pipeline.mode = $0 })
    }

    private var inputChannelBinding: Binding<TimecodeInputChannel> {
        Binding(get: { pipeline.inputChannel }, set: { pipeline.inputChannel = $0 })
    }

    private var rateScaleBinding: Binding<Double> {
        Binding(get: { pipeline.rateScale }, set: { pipeline.rateScale = $0 })
    }

    private var minConfidenceBinding: Binding<Double> {
        Binding(get: { pipeline.minConfidence }, set: { pipeline.minConfidence = $0 })
    }

    private var maxRateBinding: Binding<Double> {
        Binding(get: { pipeline.maxRate }, set: { pipeline.maxRate = $0 })
    }

    private var signalThresholdRMSBinding: Binding<Float> {
        Binding(get: { pipeline.signalThresholdRMS }, set: { pipeline.signalThresholdRMS = $0 })
    }

    private var liveTapEnabledBinding: Binding<Bool> {
        Binding(get: { pipeline.liveTapEnabled }, set: { pipeline.liveTapEnabled = $0 })
    }

    private var playbackDriveEnabledBinding: Binding<Bool> {
        Binding(get: { bridge.playbackDriveEnabled }, set: { bridge.playbackDriveEnabled = $0 })
    }

    private var validationOverrideBinding: Binding<Bool> {
        Binding(get: { bridge.validationOverride }, set: { bridge.validationOverride = $0 })
    }

    // MARK: - Preset application

    private func applyPreset(_ preset: TimecodeControlPreset) {
        let profile = TimecodePrototypeProfile.make(preset: preset, pipeline: pipeline)
        profile.apply(to: pipeline)
        bridge.validationRequired = profile.validationRequired
        bridge.validationOverride = false
        #if ENABLE_TIMECODE_LIVE_TAP
        TimecodeCMSampleBufferAdapter.channelPairSelection = Self.channelPairSelection(for: preset)
        #endif
    }

    #if ENABLE_TIMECODE_LIVE_TAP
    /// Pure mapping from control preset to the USB channel pair the Rane
    /// DEBUG hardware profile requires — extracted from `applyPreset` so
    /// this specific, validated hardware setup detail (physical pair 3/4)
    /// is directly regression-tested instead of only exercised by hand
    /// during a live hardware session. The Rane preset pins the pair
    /// explicitly to 3/4 instead of Auto, so pair auto-selection
    /// instability during a stop/reversal (Auto losing carrier and
    /// defaulting away from an already-validated pair) cannot affect a
    /// hardware test. Any other preset restores Auto so the picker stays
    /// consistent with what's shown.
    static func channelPairSelection(
        for preset: TimecodeControlPreset
    ) -> TimecodeCMSampleBufferAdapter.ChannelPairSelection {
        preset == .raneOneMkiiDebug ? .pair(startChannel: 2) : .auto
    }
    #endif

    /// Wraps `pipeline.invertDirection` so a direct user toggle (and only a
    /// direct user toggle — `applyPreset` writes `pipeline.invertDirection`
    /// straight through the `@Published` property, never through this
    /// binding) persists the value and marks calibration as custom, the same
    /// way the Min confidence slider's `onEditingChanged` does.
    private var invertDirectionBinding: Binding<Bool> {
        Binding(
            get: { pipeline.invertDirection },
            set: { newValue in
                pipeline.invertDirection = newValue
                persistedInvertDirectionOverride = newValue
                if selectedPreset != .manual {
                    selectedPreset = .manual
                }
            }
        )
    }

    // MARK: - Mode section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timecode Control")
                .font(.headline)

            Picker("Mode", selection: modeBinding) {
                ForEach(TimecodeControlMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Profile section (Batch 10)

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(
                    TimecodeControlPreset.allCases.filter { $0 != .raneOneMkiiDebug },
                    id: \.self
                ) { preset in
                    profilePresetButton(preset, label: preset.shortLabel)
                }
            }

            // Keep the long DEBUG hardware preset on its own row. Including
            // it in the non-wrapping segmented picker above forced the whole
            // inspector wider than its container and clipped the left side.
            profilePresetButton(.raneOneMkiiDebug, label: "Rane ONE MKII (DEBUG)")

            // Show active profile summary
            let profile = TimecodePrototypeProfile.make(preset: selectedPreset, pipeline: pipeline)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Channel:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(profile.inputChannel.label)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text("Rate scale:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f×", profile.rateScale))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text("Min conf:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", profile.minConfidence))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text("Max rate:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f u/s", profile.maxRate))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
            }

            // Experimental warning for DVS preset
            if selectedPreset.isExperimental, let warning = selectedPreset.experimentalWarning {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    Text(warning)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                }
            }

            // Physical hardware setup reminder — informational, not a
            // warning, so styled distinctly from the yellow experimental
            // banner above.
            if let setupNote = selectedPreset.setupNote {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(setupNote)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Safety labels
            VStack(alignment: .leading, spacing: 2) {
                Text("Prototype only — not final compatibility")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text("Not sent to notation unless later enabled")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func profilePresetButton(
        _ preset: TimecodeControlPreset,
        label: String
    ) -> some View {
        Button {
            selectedPreset = preset
        } label: {
            HStack(spacing: 4) {
                if selectedPreset == preset {
                    Image(systemName: "checkmark")
                }
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(selectedPreset == preset ? .accentColor : .secondary)
        .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
    }

    // MARK: - Setup checklist section (Batch 10)

    private var setupChecklistSection: some View {
        let snap = pipeline.makeValidationSnapshot()
        let isStereoOK = pipeline.latestDiagnosis.map { $0.isStereo && !$0.isMonoSuspect } ?? false
        let totalDrops = snap.droppedSilence + snap.droppedClipped
            + snap.droppedChannelFault + snap.droppedWeakSignal
            + snap.droppedLowConfidence
        let dropsLow = totalDrops == 0
            || (snap.acceptedMotionSamples > 0
                && Double(snap.acceptedMotionSamples) > Double(totalDrops) * 0.2)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Setup Checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            let items: [(String, Bool, String)] = [
                ("Profile selected",
                 selectedPreset != .manual || pipeline.mode != .disabled,
                 "Select a prototype profile"),
                ("Mode: Control Prototype",
                 pipeline.mode == .controlPrototype,
                 "Set mode to Timecode Prototype"),
                ("Live tap enabled",
                 snap.liveTapEnabled,
                 "Enable the live audio tap"),
                ("L/R signal present",
                 snap.hasRecentBuffer && isStereoOK,
                 "Check timecode input cable and source"),
                ("Direction forward OK",
                 pipeline.currentDirection == .forward || snap.acceptedMotionSamples > 0,
                 "Move record forward; check direction indicator"),
                ("Direction backward OK",
                 pipeline.currentDirection == .backward || snap.acceptedMotionSamples > 0,
                 "Move record backward; check direction indicator"),
                ("Stop / idle detected",
                 pipeline.currentRate == 0 || snap.acceptedMotionSamples > 0,
                 "Stop record; rate should drop to zero"),
                ("Confidence \u{2265} threshold",
                 snap.decoderConfidence >= pipeline.minConfidence && snap.decoderConfidence > 0,
                 "Check signal level and channel balance"),
                ("Validation passed",
                 snap.validationStatus == .usablePrototypeControl,
                 "Requires accepted motion + clean signal"),
                ("Drops low",
                 dropsLow,
                 "Check for silence, clipping, or channel faults"),
            ]

            ForEach(items, id: \.0) { label, ok, hint in
                HStack(spacing: 5) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(ok ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(ok ? .primary : .secondary)
                        if !ok {
                            Text(hint)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Prototype disclaimer below checklist
            Text("Prototype only — not a compatibility checklist")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Playback bridge section (Batch 8 / Batch 10)

    private var playbackBridgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback Bridge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // Toggle
            Toggle(isOn: playbackDriveEnabledBinding) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 11))
                    Text("Drive playback from prototype timecode")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(pipeline.mode != .controlPrototype)

            // Bridge state
            HStack(spacing: 6) {
                Circle()
                    .fill(bridgeStateColor)
                    .frame(width: 6, height: 6)
                Text(bridge.state.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(bridgeStateColor)
            }

            Text("Gate: \(bridge.lastDecision.label)")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Gate counts: \(bridge.blockingDecisionSummary)")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Current drive info
            if let drive = bridge.currentDrive {
                HStack(spacing: 8) {
                    Text("Dir: \(drive.direction.rawValue)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text("Rate: \(String(format: "%.2f", drive.rate)) u/s")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(drive.sourceLabel)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Replay override indicator
            if bridge.isReplayActive {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                    Text("Replay active — timecode blocked")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }
            }

            // Validation override (Batch 10)
            if bridge.state == .blockedByValidationRequired || bridge.validationRequired {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Text("Validation required for playback")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    Toggle(isOn: validationOverrideBinding) {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.raised")
                                .font(.system(size: 11))
                            Text("Override — enable playback without validation")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    if bridge.validationOverride {
                        Text("Warning: unvalidated timecode may produce incorrect playback")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
            }

            // Prototype warnings
            VStack(alignment: .leading, spacing: 2) {
                Text("Prototype only")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("Not final Serato/SDJ support")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var bridgeStateColor: Color {
        switch bridge.state {
        case .disabled:                 return Color(nsColor: .secondaryLabelColor)
        case .armed:                    return Color(nsColor: .systemYellow)
        case .driving:                  return Color(nsColor: .systemGreen)
        case .blockedByBadSignal:       return Color(nsColor: .systemRed)
        case .blockedByReplay:          return Color(nsColor: .systemBlue)
        case .blockedByDiagnosticsOnly: return Color(nsColor: .systemOrange)
        case .blockedByLiveTapOff:      return Color(nsColor: .systemOrange)
        case .blockedByValidationRequired: return Color(nsColor: .systemOrange)
        }
    }

    // MARK: - Diagnostics section

    private var diagnosticsSection: some View {
        TimecodeInputStatusCard(
            tap: pipeline.diagnosticsTap,
            diagnostics: TimecodeSignalDiagnostics()
        )
    }

    // MARK: - Calibration section

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibration")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // Channel picker
            HStack(spacing: 8) {
                Text("Channel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: inputChannelBinding) {
                    ForEach(TimecodeInputChannel.allCases, id: \.self) { ch in
                        Text(ch.label).tag(ch)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Invert direction
            HStack(spacing: 6) {
                Toggle(isOn: invertDirectionBinding) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11))
                        Text("Invert direction")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if selectedPreset == .manual {
                    Text("custom")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }

            // Rate scale
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rate scale")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", pipeline.rateScale))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: rateScaleBinding, in: 0.1...5.0, step: 0.1)
                    .controlSize(.small)
            }

            // Min confidence
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min confidence")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if selectedPreset == .manual {
                        Text("custom")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Text(String(format: "%.2f", pipeline.minConfidence))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(
                    value: minConfidenceBinding,
                    in: 0.0...1.0,
                    step: 0.05,
                    onEditingChanged: { isEditing in
                        // Fire once, on release — not on every intermediate
                        // drag value — and only for direct user interaction
                        // (applyPreset() never goes through this callback).
                        guard !isEditing else { return }
                        persistedMinConfidenceOverride = pipeline.minConfidence
                        if selectedPreset != .manual {
                            selectedPreset = .manual
                        }
                    }
                )
                .controlSize(.small)
            }

            // Max rate
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max rate")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f u/s", pipeline.maxRate))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: maxRateBinding, in: 0.5...50.0, step: 0.5)
                    .controlSize(.small)
            }

            // Signal threshold
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Signal threshold")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.4f", pipeline.signalThresholdRMS))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: signalThresholdRMSBinding, in: 0.0001...0.1)
                    .controlSize(.small)
            }

            // Reset button
            HStack {
                Spacer()
                Button("Reset Calibration") {
                    pipeline.reset()
                    #if ENABLE_TIMECODE_LIVE_TAP
                    TimecodeCMSampleBufferAdapter.resetPairRetention()
                    #endif
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
            }
        }
    }

    // MARK: - Pipeline status section

    private var pipelineStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pipeline Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            statusRow(label: "Mode", value: pipeline.mode.label)
            statusRow(label: "Source", value: pipeline.counters.sourceLabel, mono: true)
            statusRow(label: "Direction", value: pipeline.currentDirection.rawValue, mono: true,
                      color: directionColor)
            statusRow(label: "Rate", value: String(format: "%.2f u/s", pipeline.currentRate), mono: true)
            statusRow(label: "Confidence", value: String(format: "%.3f", pipeline.counters.averageConfidence), mono: true)

            Divider().opacity(0.2)

            // Counters grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                counterChip(label: "Accepted", count: pipeline.counters.acceptedMotionSamples, color: .green)
                counterChip(label: "Dropped", count: totalDropped, color: .orange)
                counterChip(label: "Silence", count: pipeline.counters.droppedSilence, color: .secondary)
                counterChip(label: "Clip", count: pipeline.counters.droppedClipped, color: .secondary)
                counterChip(label: "Ch Fault", count: pipeline.counters.droppedChannelFault, color: .secondary)
                counterChip(label: "Weak", count: pipeline.counters.droppedWeakSignal, color: .secondary)
                counterChip(label: "Low Conf", count: pipeline.counters.droppedLowConfidence, color: .secondary)
                counterChip(label: "Dir Changes", count: pipeline.counters.directionChanges, color: .secondary)
            }

            // Last drop reason
            if !pipeline.counters.lastDropReason.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    Text("Drop: \(pipeline.counters.lastDropReason)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            // Timeline info
            if let timeline = pipeline.latestPlatterTimeline {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Timeline: \(timeline.samples.count) samples, \(String(format: "%.2f", timeline.endTime - timeline.startTime))s")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var totalDropped: Int {
        pipeline.counters.droppedSilence
        + pipeline.counters.droppedClipped
        + pipeline.counters.droppedChannelFault
        + pipeline.counters.droppedWeakSignal
        + pipeline.counters.droppedLowConfidence
    }

    private var directionColor: Color {
        switch pipeline.currentDirection {
        case .forward:  return Color(nsColor: .systemGreen)
        case .backward: return Color(nsColor: .systemRed)
        case .unknown:  return Color(nsColor: .systemGray)
        }
    }

    // MARK: - Validation section

    private var validationSection: some View {
        let snap = pipeline.makeValidationSnapshot()
        return VStack(alignment: .leading, spacing: 8) {
            // Header + disclaimer
            HStack(alignment: .firstTextBaseline) {
                Text("Validation")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Not sent to notation")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            // Big status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(validationStatusColor(snap.validationStatus))
                    .frame(width: 8, height: 8)
                Text(snap.validationStatus.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(validationStatusColor(snap.validationStatus))
            }
            .padding(.vertical, 4)

            signalPathValidationNoteView(snap: snap)

            // Actions — placed above conditional content so the buttons
            // stay fixed even when dropout duration / spike reason / etc.
            // appear or disappear below.
            HStack(spacing: 8) {
                Button("Reset Counters") {
                    pipeline.resetCounters()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)

                Button("Copy Debug") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snap.debugText, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
            }

            // Checklist
            VStack(alignment: .leading, spacing: 3) {
                let totalDrop = snap.droppedSilence + snap.droppedClipped
                    + snap.droppedChannelFault + snap.droppedWeakSignal
                    + snap.droppedLowConfidence
                let dropLow = totalDrop == 0
                    || (snap.acceptedMotionSamples > 0
                        && Double(snap.acceptedMotionSamples) > Double(totalDrop) * 0.2)
                let isStereoOK = pipeline.latestDiagnosis.map {
                    $0.isStereo && !$0.isMonoSuspect
                } ?? false
                let items: [(String, Bool)] = [
                    ("Live tap enabled", snap.liveTapEnabled),
                    ("Buffer received recently", snap.hasRecentBuffer),
                    ("Stereo signal present", isStereoOK),
                    ("Decoder confidence \u{2265} threshold",
                     snap.decoderConfidence >= pipeline.minConfidence && snap.decoderConfidence > 0),
                    ("Accepted motion samples > 0", snap.acceptedMotionSamples > 0),
                    ("Drop reasons low", dropLow),
                ]
                ForEach(items, id: \.0) { label, ok in
                    HStack(spacing: 5) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(ok ? Color(nsColor: .systemGreen) : Color(nsColor: .secondaryLabelColor))
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(ok ? .primary : .secondary)
                    }
                }
            }

            // Stability metrics (Batch 7)
            Divider().opacity(0.2)

            HStack(spacing: 8) {
                stabilityMetricPair(
                    label: "Raw rate",
                    value: String(format: "%.2f u/s", snap.decodedRate)
                )
                stabilityMetricPair(
                    label: "Smoothed",
                    value: String(format: "%.2f u/s", snap.smoothedRate)
                )
            }
            HStack(spacing: 8) {
                stabilityMetricPair(
                    label: "Spikes",
                    value: "\(snap.rejectedSpikeCount)"
                )
                stabilityMetricPair(
                    label: "Held drops",
                    value: "\(snap.heldDropoutCount)"
                )
                stabilityMetricPair(
                    label: "Long drops",
                    value: "\(snap.longDropoutCount)"
                )
            }
            if snap.smoothingActive {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                    Text("Smoothing active")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }
            }
            if snap.lastDropoutDuration > 0 {
                stabilityMetricPair(
                    label: "Dropout",
                    value: String(format: "%.0f ms", snap.lastDropoutDuration)
                )
            }
            if !snap.lastSpikeReason.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text("Spike: \(snap.lastSpikeReason)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            Divider().opacity(0.2)

            // Last drop reason
            if !snap.lastDropReason.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    Text("Last drop: \(snap.lastDropReason)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            // Source label
            HStack(spacing: 5) {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(snap.sourceLabel)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Manual test checklist (informational)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(["Move record forward → direction shows forward",
                              "Move record backward → direction shows backward",
                              "Stop record → rate drops to 0",
                              "Check direction/rate update in Pipeline Status"], id: \.self) { step in
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Text(step)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            } label: {
                Text("Manual test steps")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

        }
    }

    private func validationStatusColor(_ status: TimecodeValidationStatus) -> Color {
        switch status {
        case .noSignal:               return Color(nsColor: .secondaryLabelColor)
        case .stale:                  return Color(nsColor: .systemOrange)
        case .receivingButNoDecode:   return Color(nsColor: .systemYellow)
        case .decodingButDropping:    return Color(nsColor: .systemOrange)
        case .clipped:                return Color(nsColor: .systemRed)
        case .channelFault:           return Color(nsColor: .systemRed)
        case .usablePrototypeControl:    return Color(nsColor: .systemGreen)
        case .diagnosticsOnlyReceiving:  return Color(nsColor: .systemBlue)
        }
    }

    // MARK: - Signal path validation note

    @ViewBuilder
    private func signalPathValidationNoteView(snap: TimecodeValidationSnapshot) -> some View {
        let mode = pipeline.mode
        let isRelevantMode = mode == .diagnosticsOnly || mode == .controlPrototype
        let isSignalUsable = snap.signalHealth == .usable
            && snap.hasRecentBuffer
            && snap.liveTapEnabled

        if isRelevantMode && isSignalUsable {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                    Text("Signal path validated")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                }

                Text("Live audio is reaching ScratchLab and can be classified/accepted by the prototype. A Serato/control WAV played at normal speed validates routing and signal shape, but does not prove platter-motion tracking. Stable motion requires real phase progression, speed variation, or a supported moving-control source.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if mode == .controlPrototype
                    && snap.decoderConfidence >= pipeline.minConfidence
                    && snap.decoderConfidence > 0
                    && (abs(snap.decodedRate) < 0.5 || snap.directionChanges > 5) {
                    Text("If direction/rate flickers near zero while confidence is healthy, the source is likely near the prototype's stationary threshold rather than producing usable platter motion.")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(
                Color(nsColor: .systemBlue).opacity(0.06),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
    }

    // MARK: - Helpers

    private func statusRow(label: String, value: String, mono: Bool = false, color: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
        }
    }

    private func stabilityMetricPair(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func counterChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : .secondary)
        }
    }

    // MARK: - Live tap section

#if ENABLE_TIMECODE_LIVE_TAP
    private var liveTapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Tap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Status")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                liveTapStatusBadge()
            }

            Toggle(isOn: liveTapEnabledBinding) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                    Text("Enable live timecode tap")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(pipeline.mode == .disabled)

            // Last buffer age
            if pipeline.liveTapEnabled, let lastBuffer = pipeline.lastBufferReceivedAt {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Last buffer: \(RelativeDateTimeFormatter().localizedString(for: lastBuffer, relativeTo: Date()))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Prototype disclaimer
            Text("Prototype — live audio tap for timecode decoding")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }

    private func liveTapStatusBadge() -> some View {
        let status = liveTapStatus
        return HStack(spacing: 4) {
            Circle()
                .fill(Color(status.color))
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(status.color))
        }
    }

    private var liveTapStatus: (label: String, color: Color) {
        guard pipeline.liveTapEnabled else {
            return ("Disabled", Color(nsColor: .secondaryLabelColor))
        }
        guard pipeline.mode != .disabled else {
            return ("Mode off", Color(nsColor: .secondaryLabelColor))
        }
        if let lastBuffer = pipeline.lastBufferReceivedAt {
            let age = Date().timeIntervalSince(lastBuffer)
            if age < 0.5 {
                return ("Receiving", .green)
            } else if age < 2.0 {
                return ("Stale", .orange)
            }
        }
        return ("Waiting", .yellow)
    }
#endif
}

// MARK: - Recording section

/// Displays prototype take recording controls and stats.
/// Observes `TimecodePrototypeRecorder` directly so updates are reactive.
private struct TimecodeRecordingSection: View {

    @ObservedObject var recorder: TimecodePrototypeRecorder
    /// Whether the pipeline is in `.controlPrototype` mode.
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Prototype Take")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Prototype only · Not sent to notation")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            // State badge
            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(recorder.state.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(stateColor)
            }

            // Controls
            HStack(spacing: 8) {
                Button("Start Take") { recorder.startRecording() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isActive || recorder.state == .recording)

                Button("Stop Take") { recorder.stopRecording() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recorder.state != .recording)

                Button("Clear") { recorder.clearTake() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.secondary)
                    .disabled(recorder.state == .idle && recorder.acceptedSampleCount == 0)
            }

            // Stats grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                recorderChip(label: "Accepted", count: recorder.acceptedSampleCount, color: .green)
                recorderChip(label: "Dropped", count: recorder.droppedSampleCount, color: .orange)
            }

            // Duration + source
            recorderRow(label: "Duration",
                        value: String(format: "%.2fs", recorder.recordedDuration))
            recorderRow(label: "Source", value: recorder.sourceLabel, mono: true)

            // Last drop reason
            if !recorder.lastDropReason.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                    Text("Drop: \(recorder.lastDropReason)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            // Recorded timeline summary
            if let timeline = recorder.recordedTimeline {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    Text("Take: \(timeline.samples.count) samples · \(timeline.source.rawValue)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(isActive ? 1.0 : 0.5)
    }

    private var stateColor: Color {
        switch recorder.state {
        case .idle:      return Color(nsColor: .secondaryLabelColor)
        case .recording: return Color(nsColor: .systemRed)
        case .stopped:   return Color(nsColor: .systemGreen)
        }
    }

    private func recorderRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
        }
    }

    private func recorderChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(count > 0 ? color : .secondary)
        }
    }
}

// MARK: - Standalone debug host

/// Self-contained DEBUG host for previewing and manually testing the
/// timecode control card with synthetic feed buttons.
struct TimecodeControlCard_Host: View {
    @StateObject private var pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
    @StateObject private var bridge = TimecodePlaybackBridge()

    /// Accumulate raw buffers here for manual flush; the pipeline also
    /// accumulates internally, but these are the raw [Float] arrays we
    /// need for flushDecode().
    @State private var feedCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                TimecodeControlCard(pipeline: pipeline, bridge: bridge)

                // Test-feed buttons
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test Feed (accumulates until flush)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        feedButton("Silence", color: .gray) {
                            feedSilence()
                        }
                        feedButton("Healthy", color: .green) {
                            feedHealthy()
                        }
                        feedButton("Forward", color: .blue) {
                            feedForwardProgression(count: 5)
                        }
                        feedButton("Backward", color: .red) {
                            feedBackwardProgression(count: 5)
                        }
                    }

                    HStack(spacing: 8) {
                        feedButton("Clipped", color: .orange) {
                            feedClipped()
                        }
                        feedButton("Ch Fault", color: .yellow) {
                            feedChannelFault()
                        }
                        feedButton("Weak", color: .secondary) {
                            feedWeak()
                        }

                        Button("Flush + Reset") {
                            pipeline.flushDecode()
                            pipeline.reset()
                            #if ENABLE_TIMECODE_LIVE_TAP
                            TimecodeCMSampleBufferAdapter.resetPairRetention()
                            #endif
                            feedCount = 0
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.accentColor)
                    }
                }

                Text("Buffers fed: \(feedCount)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 600)
    }

    // MARK: - Feed helpers

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441
    private let timePerBuffer: TimeInterval = 441.0 / 44100.0

    private func sineTone(frequency: Float, amplitude: Float, phaseOffset: Float = 0) -> [Float] {
        (0..<framesPerBuffer).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t + phaseOffset)
        }
    }

    private func feedSilence() {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedHealthy() {
        let tone = sineTone(frequency: carrierFrequency, amplitude: 0.3)
        pipeline.pushStereoBuffer(left: tone, right: tone, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedForwardProgression(count: Int) {
        for i in 0..<count {
            let left = sineTone(frequency: carrierFrequency, amplitude: 0.5, phaseOffset: 0)
            let right = sineTone(frequency: carrierFrequency, amplitude: 0.5,
                                 phaseOffset: 0.3 * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
            feedCount += 1
        }
        pipeline.flushDecode()
    }

    private func feedBackwardProgression(count: Int) {
        for i in 0..<count {
            let left = sineTone(frequency: carrierFrequency, amplitude: 0.5, phaseOffset: 0)
            let right = sineTone(frequency: carrierFrequency, amplitude: 0.5,
                                 phaseOffset: -0.3 * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
            feedCount += 1
        }
        pipeline.flushDecode()
    }

    private func feedClipped() {
        let clip = sineTone(frequency: carrierFrequency, amplitude: 1.0)
        pipeline.pushStereoBuffer(left: clip, right: clip, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedChannelFault() {
        let tone = sineTone(frequency: carrierFrequency, amplitude: 0.3)
        let silence = [Float](repeating: 0, count: framesPerBuffer)
        pipeline.pushStereoBuffer(left: tone, right: silence, sampleRate: sampleRate)
        feedCount += 1
    }

    private func feedWeak() {
        let weak = sineTone(frequency: carrierFrequency, amplitude: 0.005)
        pipeline.pushStereoBuffer(left: weak, right: weak, sampleRate: sampleRate)
        feedCount += 1
    }

    // MARK: - Button helper

    private func feedButton(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(color)
    }
}

// MARK: - Preview

#Preview {
    TimecodeControlCard_Host()
        .frame(width: 440, height: 800)
}

#endif // DEBUG
