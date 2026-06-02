---
title: ScratchLab Phase B — Notation Feels Like a Game
role: Detailed Phase B execution plan — surface the deterministic notation substrate that already exists invisibly so the lane reads as gameplay rather than as a developer renderer.
status: active (not shipped; gates Phase C and Phase D-S)
source: extracted verbatim from `glowing-dazzling-sketch.md` Section 0.2-0.6 + 0.10 and Phase B section
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — master roadmap, Section 0 framework gaps, cross-phase honesty model (Section X)
  - [coaching_phase_c.md](./coaching_phase_c.md) — Phase B is a hard prerequisite for C2 and C5
  - [replay_phase_d.md](./replay_phase_d.md) — Phase B AR-prep contracts are consumed by Phase D-S spatial renderer
  - [hazy-exploring-grove.md](./hazy-exploring-grove.md) — Phase A archive (shipped; Phase B builds on A0-A9)
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase B — "Notation Feels Like a Game"

## Purpose

Phase B evolves `ScratchMotionLane` and the practice loop from "developer notation renderer" into "musical gameplay surface" — additively, deterministically, behind flags — without rewriting notation/scoring/capture, without retraining ML, without changing export, and without breaking PROFILE.md's honest-uncertainty posture.

"Notation as gameplay" in ScratchLab specifically means:
- The lane *responds* to user input in ways that confirm rhythm and timing, not just record it.
- Phrase boundaries become musical chunks the user can feel, not just internal data.
- Success and timing-window deviations are **legibly differentiated** on the same surface that teaches the move.
- Session momentum and progression have a visible arc — not just a final results screen.

## Current state

**The substrate already exists invisibly.** Phase B is largely about *surfacing* what already exists deterministically:

- `Phrase` + `PhraseBoundaryMapper`
- `AudioPhraseSummary` (with `terminalDragDuration` release tail)
- `PhraseCoachingEvaluator`
- `TimingWindow` + `TimingDrift` + `TimingWindowEvaluator`
- `DriftCoachingEvaluator`
- `ReviewAudioOnsetPreview`
- `DebugReviewNotationCard`
- `RoutineMovementDebugSession`

**Inventory correction (preserved from prior plan):** `laneUserEvents` in `PracticeModeView.swift:129` is already populated (via `appendLaneUserEventForDetection` at `PracticeModeView.swift:1506`) and rendered as quiet attempt ticks via `ScratchMotionLane.drawUserEvents`. The hook is live; it just doesn't yet read as game-feel.

**State at the time of writing:** `FeatureFlags.swift:1–44` contains only the six Phase A flags. No `LANE_JUDGMENT_TINT`, `LANE_PHRASE_TINT`, `PHRASE_MOMENTUM_HUD`, `UNLOCK_LADDER`, or `SESSION_REPLAY`. `NotationLaneGeometryView` renders every primitive identically regardless of timing.

## Design principles

**What must remain instructional:**
- Notation is the source of truth; gameplay sits *on* it, never *over* it.
- Timing windows show drift, they do not invent a "perfect / miss" judgment.
- Every reward state must be honestly grounded — accuracy from real per-stroke drift, not a vibe-only score.
- Copy stays in `CoachCopy.swift`, vetted against PROFILE.md vocab (`estimated`, `preview`, `uncertain`; no "AI detects exactly").

**B pillars:**

1. Readable rhythm surface
2. Honest reinforcement
3. Musical phrase structure
4. Session momentum
5. Progression visibility
6. Tactile motion (micro-feedback)
7. Replayability
8. Flow-state pacing
9. **AR-renderable geometry (new pillar):** every visual primitive added in B is a pure projection that the D-S spatial track can render in 3D without forking the model layer.

## Slice roadmap

### B0 — Substrate visibility (DEBUG-only)

**Gap:** `PhraseBoundaryMapper` output and `DriftCoachingEvaluator` events never reach `NotationLaneGeometryView`. The team has no way to validate evaluator behavior against real captures before user-visible surfacing.

**Build now:**
- DEBUG-only conditional overlay in `NotationLaneGeometryView` that draws phrase boundary lines (from `PhraseBoundaryMapper`) and drift markers (from `DriftCoachingEvaluator`) on top of existing primitives.
- DEBUG-only host view that lets the team scrub through captured sessions with the overlay live.
- **No release-build effect.**

**Files:** `NotationLaneGeometryView.swift` (DEBUG conditional), possibly a new `Views/Notation/DebugSubstrateOverlay.swift`.

**Verification:** iOS + macOS build; manual smoke against a known captured session; release build byte-identical for `NotationLaneGeometryView`.

### B1 — Lane judgment-color states (MINIMAL SAFE START)

**Gap:** Every notation primitive looks identical regardless of how it was hit. The lane teaches the target but never confirms the user. C1 cannot land coaching event chips on a surface that has no color hierarchy.

**Build now:**
- Recolor existing primitive markers in `NotationLaneGeometryView` based on `TimingWindowEvaluator` output: on-beat (success), early (info), late (warning), no-data (neutral). **Visual only.**
- New flag `LANE_JUDGMENT_TINT`, release-default-false initially, flip after checkpoint α.
- **Critical AR-prep:** semantic palette aliases used here (`success`/`info`/`warning`) must be addressable by name — the spatial replay renderer (Phase D-S) will consume the same semantic names to keep visual grammar identical across 2D and 3D surfaces.

**Files:** `NotationLaneGeometryView.swift`, `FeatureFlags.swift`, `ScratchLabPalette.swift` (one semantic alias if needed), `CoachCopy.swift` (state labels if any — "on-beat / early / late," never "perfect / miss").

**Verification:** iOS + macOS build + macOS build-for-testing; captured session with known drift produces expected colors; reduce-motion path renders colors statically; release-default-false until α checkpoint.

→ **TestFlight Checkpoint α** ("Does the lane feel more alive without feeling busier?")

### B2 — Phrase boundary tints + per-hit micro-feedback (HARD BLOCKER for C2/C5)

**Gap:** Phrases are invisible. Music has structure the renderer doesn't acknowledge. **C2 (phrase coaching) and C5 ("focus of the day") cannot ship until phrase boundaries are visible.** Surfacing phrase coaching events before the user can see phrases is the overclaim shape App Store rejects.

**Build now:**
- Phrase boundaries rendered as low-contrast vertical tints (≤8% alpha) on `NotationLaneGeometryView`, driven by `PhraseBoundaryMapper`.
- Per-hit micro-feedback layer on `ScratchMotionLane`: brief radial pulse (180ms, ease-out) on primitive completion, driven by existing `laneUserEvents`.
- Two independent flags: `LANE_PHRASE_TINT`, `LANE_MICRO_FEEDBACK`.
- **Critical AR-prep:** the phrase boundary projection used here will be the same projection consumed by the D-S spatial-ribbon renderer. Keep the geometry function pure and parametric so it can render to both 2D (lane) and 3D (RealityKit/ARKit) contexts without forking.

**Files:** `NotationLaneGeometryView.swift`, `ScratchMotionLane.swift`, `FeatureFlags.swift`.

**Verification:** iOS + macOS build + macOS build-for-testing; phrase tints render at intended low alpha; no more than two simultaneous accent animations; freeze-frame readability test passes.

### B3 — Phrase release tails + phrase-streak HUD

**Gap:** Phrases don't feel like complete musical thoughts. Mid-session has no visible momentum. C2's release-tail observation copy has no visual referent.

**Build now:**
- Brief horizontal fade-out on lane at phrase end, duration = clamped `AudioPhraseSummary.terminalDragDuration`.
- Phrase-streak HUD chip in `PracticeModeView` (consecutive phrases-within-window count). Visual-only, never affects `currentScore`.
- New flag: `PHRASE_MOMENTUM_HUD`.

**Files:** `ScratchMotionLane.swift`, `PracticeModeView.swift`, `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** standard gate + phrase-streak chip increments only on phrase boundary crossings within window; release-tail duration matches `terminalDragDuration` clamped.

→ **TestFlight Checkpoint β** ("Do phrases feel like meaningful chunks? Is mid-session readable?")

### B4 — Progression visibility

**Gap:** `ProgressManager.isScratchMastered` exists but doesn't ladder into a visible unlock arc. Mid-session has no visible progression bar.

**Build now:**
- Multi-scratch unlock ladder on `LevelSelectView` (read-only consumption of `ProgressManager.isScratchMastered` / `practiceCount`).
- Intra-session momentum bar in `PracticeModeView` (visible arc toward session end). Derived from existing session counters; no new persistence.
- Two independent flags: `UNLOCK_LADDER`, `IN_SESSION_MOMENTUM`.

**Files:** `LevelSelectView.swift`, `PracticeModeView.swift`, `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** standard gate; no `ProgressManager` writes; copy avoids "level up" — uses "available next."

### B5 — Replay & reward (soft-blocks C4)

**Gap:** Recent-sessions strip lists past sessions but they can't be revisited. `DebugReviewNotationCard` is unreachable from running app per AI_HANDOFF. C4's last-take replay has no foundation.

**Build now (own branch off `release/testflight-1`):**
- Tap-to-replay on recent-sessions cards using `ReviewAudioOnsetPreview` + production-promotion of `DebugReviewNotationCard` (specifically the preview-card surface, nothing else).
- This is the slice that breaks the AI_HANDOFF "zero production Review wiring" boundary. Plan as its own mini-project, own branch, own flag, own TestFlight cycle.
- Flag `SESSION_REPLAY`, release-default-false through γ checkpoint.

**Files:** `LevelSelectView.swift`, `ReviewAudioOnsetPreview.swift`, `DebugReviewNotationCard.swift` (promotion path), `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** every replayed marker carries "preview" framing; reuses `ReviewAudioOnsetPreview`'s PROFILE.md-compliant copy verbatim ("on-device audio onsets", "(preview)", "aren't saved, exported, or scored"); rollback flips flag and reverts production Review wiring without touching B0–B4.

→ **TestFlight Checkpoint γ** (gated false-by-default).

### Execution order

1. B0 (DEBUG-only).
2. B1 → checkpoint α.
3. B2.
4. B3 → checkpoint β.
5. B4.
6. B5 → checkpoint γ.

### B systems to add (summary table)

Every system listed is **visual-only** and never adjusts `currentScore`, `bestAccuracy`, or `attemptCount` math. Scoring stays exactly where Phase A left it.

| System | When | Visual-only? | DEBUG first? |
|---|---|---|---|
| Judgment color states | B1 | Yes | No |
| Per-hit micro-feedback | B2 | Yes | No |
| Phrase boundary tints | B2 | Yes | Yes (DEBUG in B0) |
| Phrase release tails | B3 | Yes | Yes (B0) |
| Phrase-streak HUD chip | B3 | Yes | No |
| Intra-session momentum bar | B4 | Yes | No |
| Unlock ladder | B4 | Yes | No |
| Tap-to-replay recent sessions | B5 | Yes | Yes (existing DEBUG card) |
| Lane intensity dynamics | B2 (small dose) | Yes | No |
| Notation zoom dynamics | Phase D-S (defer) | — | — |
| Call/response drills | Phase C | — | — |
| Cadence / live BPM tracking | Phase C+ (or never) | — | — |

## Safe before TestFlight

- B0 (DEBUG-only — no release effect, lands first).
- B1 (release-default-false until α; flip after α checkpoint).
- B2 (release-default-false until α combined with C2 readiness — but the visual layer itself is safe to land).
- B3 (release-default-false until β).
- B4 (release-default-false until β).

Order is rigid; each gate is a checkpoint cycle, not just a build pass.

## Deferred / post-TestFlight

- **B5 — Replay & reward**: lives on its own branch off `release/testflight-1` because it crosses the AI_HANDOFF "zero production Review wiring" boundary. Flag `SESSION_REPLAY` stays release-default-false through γ checkpoint. Treat as its own mini-project, own branch, own TestFlight cycle.

## Risks

**B explicit non-goals (any of these is a stop-immediately signal in PR review):**

- ML retraining or any change to classifier behavior.
- Export schema changes.
- Notation architecture rewrites; viewport/clock substrate stays as-is.
- Capture pipeline changes beyond consuming existing emitted events.
- Fake "perfect" or "100%" scoring.
- Fake classifier certainty.
- EDM-arcade-overload visuals — no continuous particle systems, no screen-wide flashes.
- Full DJ simulation or virtual deck.
- Social features / leaderboards / sharing.
- Broad gamification addiction loops.
- Misleading AI claims in any new copy.
- Unreadable notation clutter.
- Promoting DEBUG surfaces wholesale into release. B5 promotes specifically the preview-card surface, nothing else.
- Editable recent-sessions list.
- BPM live detection / beat-grid lock to live audio.
- Adaptive difficulty / dynamic timing-window scaling.
- New persistence schema in `ProgressManager`.

**Freeze boundaries:**
- After B1 flagged-true: no further lane visual changes for one TestFlight cycle.
- After B3 flagged-true: no further phrase-system additions for one TestFlight cycle.
- Before B5: lives on its own branch because it crosses the AI_HANDOFF "zero production Review wiring" boundary.

**AR-prep contracts to honor *during* B work (so D-S has nothing to refactor when it begins):**

1. **Semantic palette by name.** Phase B's color hierarchy uses semantic aliases (`success`/`info`/`warning`) addressable by name from the spatial renderer.
2. **Pure geometry functions.** Phrase boundary projection, notation ribbon projection, ghost-take projection are pure functions of sidecar inputs. No `View`-bound state, no SwiftUI-only types in the projection layer.
3. **Confidence-as-thickness primitive.** `CoachingEventDisplayability.advisory` maps to a numeric thickness/opacity coefficient consumable by both 2D `Canvas` and 3D `Mesh`.
4. **Audio-onset = solid, classifier-derived = dashed.** Visual grammar that encodes which signal is trustworthy. Established in B1/B2, carried verbatim into D-X and D-S.
5. **No SwiftUI-bound coordinate spaces in presentation models.** `NotationLaneGeometry` already uses unitless parametric coordinates; preserve this.

## Verification gates

Per `[[feedback_verification_scope]]`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` clean.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
4. Flag wiring verified in `FeatureFlags.swift`.
5. Copy review against PROFILE.md vocabulary (see [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) Section X).
6. **Reduce-motion path** confirmed for any new animation — mirror A8's pattern (`PracticeModeView.swift:2498`); every B slice that adds motion must render the same state statically when reduce-motion is on.
7. No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.
8. No commits or pushes without explicit user approval per SOUL.md.

## Links back to master roadmap

- Master Section 0 (framework gaps) and Phase B section: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase honesty model: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) Section X
- Cross-phase verification gates: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) Section Y
- Cross-phase hard constraints: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) Section Z
- Phase A shipped record: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) Phase A and [hazy-exploring-grove.md](./hazy-exploring-grove.md)
