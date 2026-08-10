import Foundation

// MARK: - Fader Curve Model
//
// Configurable, persisted, per-device/per-action response curves applied to
// scratch-audio gain AFTER a learned MIDI fader's raw value has already been
// normalized and inverted by `MIDILearnedControl.normalizedValue(from:)`.
// Pure value types only — no Core MIDI, no audio, no playback, no UI —
// matching the guardrails of the sibling `MIDILearnedMapping.swift`.
//
// Two independent failure classes are handled deliberately differently:
//   - a bad LIVE MIDI position (NaN, out of range) fails toward SILENCE —
//     see `FaderCurveResponse.gain`'s position guard;
//   - a malformed/degenerate PERSISTED curve fails toward UNITY — see the
//     same function's curve-parameter guard. A corrupt saved configuration
//     must never permanently mute a control the way a bad instantaneous
//     sample should fail safe toward quiet.

// MARK: - Response Shape

/// Pure response-shape primitive. Two shapes cover every preset and custom
/// curve — no preset needs anything more expressive than these.
enum FaderCurveResponseShape: String, Codable, Equatable {
    case linear
    case smoothstep
}

/// A fully-resolved, ready-to-evaluate curve: two normalized endpoints and a
/// shape. Never persisted itself — always computed on demand from a preset,
/// or from a raw capture re-applied through the control's CURRENT
/// calibration (see `MIDIFaderCurveConfig.resolvedResponse(for:)`).
struct FaderCurveResponse: Equatable {
    let zeroAt: Double
    let oneAt: Double
    let shape: FaderCurveResponseShape

    /// Fully self-defensive: validates both the position and the curve
    /// parameters itself, independent of what the caller already checked.
    ///
    /// - A non-finite `p` fails toward 0 (silence) — mirrors the existing
    ///   `crossfaderRightDeckGain`/renderer convention for a bad
    ///   instantaneous MIDI sample.
    /// - A finite `p` is clamped to `0...1`.
    /// - Non-finite or degenerate (near-zero span) curve endpoints fail
    ///   toward 1 (unity) — a corrupt persisted curve must not mute audio.
    static func gain(forNormalizedPosition p: Double, response: FaderCurveResponse) -> Double {
        guard p.isFinite else { return 0 }
        let clampedPosition = min(max(p, 0), 1)

        guard response.zeroAt.isFinite, response.oneAt.isFinite else { return 1.0 }
        let span = response.oneAt - response.zeroAt
        guard abs(span) >= 1e-6 else { return 1.0 }

        let t = min(max((clampedPosition - response.zeroAt) / span, 0), 1)
        switch response.shape {
        case .linear:
            return t
        case .smoothstep:
            return t * t * (3 - 2 * t)
        }
    }
}

// MARK: - Presets

/// Centralized, tunable preset parameters — the only place curve widths
/// live, so every preset stays trivially auditable/unit-testable.
enum MIDIFaderCurveConstants {
    /// == the pre-existing `ScratchSamplePlaybackController.crossfaderCutInWidth`.
    /// Migration-critical: this value must not change, or every existing
    /// (unconfigured) crossfader mapping's audio behavior changes on upgrade.
    static let sharpScratchCutInWidth: Double = 0.05
    /// Upfader analogue of the above. Independently tunable — kept as its
    /// own constant rather than reusing `sharpScratchCutInWidth` so the two
    /// controls' "sharp" feel can diverge later without coupling them.
    static let sharpCutInWidth: Double = 0.05
    /// Proposed transition width for `.smooth` — not a hardware
    /// measurement, tunable.
    static let smoothTransitionWidth: Double = 0.35
}

enum FaderCurvePreset: String, Codable, CaseIterable, Equatable, Hashable {
    case sharpScratch
    case smooth
    case blend
    case sharpCut
    case linear
    case custom

    /// The presets a given action's UI may offer. NOT the sole guard
    /// against a mismatched preset ending up on an action — see
    /// `MIDIFaderCurveConfig.resolvedResponse(for:)`, which re-validates
    /// this independently of any UI filtering.
    static func availablePresets(for action: MIDISemanticAction) -> [FaderCurvePreset] {
        switch action {
        case .crossfader:
            return [.sharpScratch, .smooth, .blend, .custom]
        case .leftUpfader, .rightUpfader:
            return [.sharpCut, .linear, .custom]
        default:
            return []
        }
    }

    /// Learner-facing label. Deliberately free of engineering terms
    /// ("normalized", "transfer function", percentages).
    var displayName: String {
        switch self {
        case .sharpScratch: return "Sharp Scratch"
        case .smooth:        return "Smooth"
        case .blend:          return "Blend"
        case .sharpCut:       return "Sharp Cut"
        case .linear:          return "Linear"
        case .custom:          return "Custom"
        }
    }

    /// `nil` only for `.custom`, which is resolved from a persisted raw
    /// capture instead of a fixed shape.
    var fixedResponse: FaderCurveResponse? {
        switch self {
        case .sharpScratch:
            return FaderCurveResponse(zeroAt: 0, oneAt: MIDIFaderCurveConstants.sharpScratchCutInWidth, shape: .linear)
        case .smooth:
            return FaderCurveResponse(zeroAt: 0, oneAt: MIDIFaderCurveConstants.smoothTransitionWidth, shape: .smoothstep)
        case .blend:
            return FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        case .sharpCut:
            return FaderCurveResponse(zeroAt: 0, oneAt: MIDIFaderCurveConstants.sharpCutInWidth, shape: .linear)
        case .linear:
            return FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        case .custom:
            return nil
        }
    }
}

// MARK: - Custom Capture

/// A user-captured physical "closed" / "full-on" pair, stored as RAW
/// learned-MIDI values (0...127 domain) — deliberately NOT normalized
/// Doubles. Persisting raw values means recalibrating min/max or flipping
/// inversion later re-derives the same physical points correctly (via
/// `MIDIFaderCurveConfig.resolvedResponse(for:)`), instead of leaving a
/// stale normalized endpoint that no longer corresponds to where the user
/// actually moved the control.
struct FaderCurveCapture: Codable, Equatable {
    let closedRawValue: Int
    let fullOnRawValue: Int
}

// MARK: - Per-Action Curve Configuration

/// Persisted per (device, action) alongside the existing learned binding.
/// See `MIDILearnedControl.curveConfig`.
struct MIDIFaderCurveConfig: Codable, Equatable {
    var preset: FaderCurvePreset
    var customCapture: FaderCurveCapture?

    /// The pre-feature, migration-safe behavior for an action with no
    /// configured curve: today's hard-coded 5% crossfader cut-in, today's
    /// linear (pass-through) upfader. `curveConfig == nil` resolves here.
    static func defaultConfig(for action: MIDISemanticAction) -> MIDIFaderCurveConfig {
        switch action {
        case .crossfader:
            return MIDIFaderCurveConfig(preset: .sharpScratch, customCapture: nil)
        default:
            return MIDIFaderCurveConfig(preset: .linear, customCapture: nil)
        }
    }

    /// Resolves this config against a specific learned control. Re-derives
    /// a custom capture through `control.normalizedValue(from:)` on every
    /// call — never caches a normalized value — so recalibration and
    /// inversion changes are transparently reflected the next time this is
    /// called, with no stale state anywhere.
    ///
    /// Independently re-validates that `preset` is actually one of
    /// `FaderCurvePreset.availablePresets(for: control.action)` — a
    /// mismatched preset (e.g. corrupt/hand-edited persistence assigning a
    /// crossfader-only preset to an upfader) falls back to that action's
    /// default rather than applying a nonsensical fixed shape. This is
    /// deliberately independent of any UI-level preset filtering.
    func resolvedResponse(for control: MIDILearnedControl) -> FaderCurveResponse {
        let allowedPresets = FaderCurvePreset.availablePresets(for: control.action)
        // An action with NO available presets (hot cues, `.unassigned`)
        // does not support curves at all. Return a harmless, non-recursive
        // unity pass-through directly here — falling through to
        // `defaultConfig(for:).resolvedResponse(for:)` below would produce
        // the exact same not-in-`allowedPresets` config and recurse
        // forever (a real stack-overflow crash this guard fixes). No
        // production call site actually applies this value for a hot cue
        // — see `MacCaptureEngine.pushResolvedCurve(for:)`, which only
        // ever resolves crossfader/right-upfader controls — this is a
        // pure-function safety net independent of that caller discipline.
        guard !allowedPresets.isEmpty else {
            return FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        }
        guard allowedPresets.contains(preset) else {
            return MIDIFaderCurveConfig.defaultConfig(for: control.action).resolvedResponse(for: control)
        }
        if let fixed = preset.fixedResponse {
            return fixed
        }
        // preset == .custom
        guard let capture = customCapture else {
            return MIDIFaderCurveConfig.defaultConfig(for: control.action).resolvedResponse(for: control)
        }
        let closedRaw = min(max(capture.closedRawValue, 0), 127)
        let fullOnRaw = min(max(capture.fullOnRawValue, 0), 127)
        return FaderCurveResponse(
            zeroAt: control.normalizedValue(from: closedRaw),
            oneAt: control.normalizedValue(from: fullOnRaw),
            shape: .linear
        )
    }
}
