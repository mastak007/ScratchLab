---
title: ScratchLab Phase C — Coach Intelligence + Structured Training
role: Honest coaching architecture — wire the coaching evaluators that already exist into surfaces, with pacing and presentation-tier confidence, without becoming a fake AI teacher.
status: active (not shipped; depends on Phase B for phrase visibility before C2/C5 can land)
source: extracted verbatim from `glowing-dazzling-sketch.md` Section 0.7-0.9 and Phase C section
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — master roadmap, Section 0 framework gaps, cross-phase honesty model (Section X)
  - [notation_phase_b.md](./notation_phase_b.md) — Phase B is a hard prerequisite for C2 and C5
  - [replay_phase_d.md](./replay_phase_d.md) — Phase D-S consumes the same presentation-tier confidence model
  - [instructor_phase_e.md](./instructor_phase_e.md) — Phase E inherits the "silence is a feature" stance
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase C — "Coach Intelligence + Structured Training"

## Purpose

Phase A polished the experience; Phase B made notation feel like a game. Phase C turns ScratchLab into a structured scratch-training system — coaching that is more musical, more session-aware, more adaptive — without becoming a fake "AI teacher."

"Structured coaching" in ScratchLab means:
- The app **observes** what the user did, **names** what it noticed in honest declarative language, and **suggests** a next move — without claiming to grade skill.
- Practice sessions have a visible arc: warmup → drill → review → next.
- Coaching events appear *when relevant*, not constantly. Silence is a valid coaching state.
- Confidence is communicated through verb choice ("appears to be," "may have," "couldn't pick up") and surface-tier (advisory vs primary), never through numbers.

## Current state

**Central observation: coaching evaluators already exist and produce real events; they just never reach the user.** `DriftCoachingEvaluator` and `PhraseCoachingEvaluator` emit `CoachingEvent`s; `CoachingEventMerger` flattens them; `NotationPresentationStroke` has a `coachingKinds: [CoachingEventKind]` field. But adapters hard-code `coachingKinds: []`. Phase C's largest single act is to fill that pipe.

**Two other gaps shape the roadmap:**
- **No throttling/pacing** on coaching events (rapid bursts would overwhelm the user).
- **No confidence field** anywhere in the coaching layer (drift rules are binary thresholds).

Both must be addressed before any coaching event becomes user-visible. Both are foundational slices (C0a pacer, presentation-tier displayability) and live in Section 0 of the master roadmap.

**State at the time of writing:** `SessionReplayPresentationAdapter` and `ScratchNotationPresentationAdapter` still hard-code `coachingKinds: []`. The coaching data pipe is dry. **Therefore: "Phase C" cannot meaningfully begin until the Phase A/B framework gaps are closed.** Surfacing coaching events while phrase boundaries are still invisible reproduces exactly the App-Store overclaim shape PROFILE.md warns against ("we computed a phrase event but the user can't see the phrase that motivated it").

## Design principles

- **One vocabulary, one place.** Continue what Phase A's `CoachCopy` established.
- **Coach over critic.** Frame what to try next, not what was wrong.
- **Never invent a metric we don't have.** Copy describes what the app can see (drift, onset count, phrase boundary crossings), not what it cannot (intent, technique correctness, musicality).
- **Silence is a valid coaching state.** Sub-threshold drift → pacer suppresses; no event.
- **Confidence lives at the presentation layer, not on the value type.** `CoachingEvent`'s contract is "manual metadata only, no inference, no thresholding" (per `CoachingEvent.swift:7-14`). Confidence is layered on at the adapter via `CoachingEventDisplayability`.

## Slice roadmap

### Minimal safe start — contextual practice-tip rotation

- Reads `ProgressManager.sessionHistory.last`, `recentAccuracies`, `currentStreak`, `lastPracticeDate`. All already in memory.
- New `PracticeTipPicker` (pure, testable). Replaces random `Tip` pick in `SessionSetupOverlay`.
- Touches zero Notation/Coaching files. No evaluator wiring. No new value types.
- Flag: `CONTEXTUAL_TIPS`.

### C0a — Coaching data-path wiring (DEBUG-only initially)

**Gap:** `SessionReplayPresentationAdapter` writes `coachingKinds: []` on every stroke. `DriftCoachingEvaluator` events exist but never reach presentation. The pipe is built but mute.

**Build now (DEBUG-only initially):**
- `SessionReplayPresentationAdapter` populates `coachingKinds` from `DriftCoachingEvaluator` output when `COACHING_EVENTS_PIPELINE` flag is on.
- Drift events first; phrase events stay dry until B2 ships.
- DEBUG-default-true, release-default-false.

**Files:** `SessionReplayPresentationAdapter.swift`, `FeatureFlags.swift`.

**Verification:** DEBUG smoke test: known captured session produces non-empty `coachingKinds` on expected strokes; release build remains empty.

### C0b — Coaching event pacer

**Gap:** Without throttling, coaching event bursts would overwhelm any user surface. C1 cannot ship without this gating component.

**Build now:**
- New pure value type `CoachingEventPacer` in `Models/Notation/Coaching/`.
- Consumes `CoachingEventSet`; applies configurable minimum inter-event spacing + same-kind suppression window.
- Deterministic, testable in isolation, no UI.

**Files:** `Models/Notation/Coaching/CoachingEventPacer.swift` (new).

**Verification:** unit tests cover same-kind suppression, inter-event spacing, deterministic ordering preservation.

### Presentation-tier confidence (C-foundation)

**Gap:** `CoachingEvent`'s contract is "manual metadata only, no inference, no thresholding" (per `CoachingEvent.swift:7-14`). Adding numeric confidence to the value type would leak into export and violate the contract. Without a presentation-layer alternative, every coaching event surfaces as equally-asserted fact.

**Build now:**
- New `CoachingEventDisplayability` presentation-layer projection.
- Inputs: existing `isResearchOnly` flag, pacer verdict, surface-tier computed at adapter level.
- Outputs: `display(primary)`, `display(advisory)`, `hidden`.
- **Critical AR-prep:** spatial replay (D-S) consumes the same displayability tier — confidence visibly degrades (band fattens, opacity drops) when tier = advisory. This is the honesty grammar that crosses 2D and 3D surfaces unchanged.

**Files:** `Models/Notation/Presentation/CoachingEventDisplayability.swift` (new), `SessionReplayPresentationAdapter.swift` (consumer).

**Verification:** unit tests cover every input combination; surface-tier decisions reproducible across re-runs.

### C1 — Post-session drift coaching summary

- ResultsOverlayView gains a fourth reveal-stage: up to 3 drift coaching events surfaced as observational text. Drift only, no phrase events. Uses pacer from C0b.
- Confidence-tier visual treatment (advisory vs primary) ships from day one.
- Flag: `RESULTS_DRIFT_COACHING`, release-default-false until α.
- → **TestFlight Checkpoint α** (first user-visible coaching events; tone & language review).

### C2 — Phrase-aware coaching (HARD BLOCK on B2)

- Once phrase boundaries are visible (B2), surface `incompletePhrase` and `unstableTiming` events alongside drift.
- Release-tail observation copy ("the last phrase trailed off"), advisory tier by default.
- Flag: `PHRASE_COACHING_SURFACE`, release-default-false until combined-α-with-B2.

### C3 — Structured drills (parallel-safe with C0–C2)

- Explicit warmup → drill → review session arc.
- "Drill summary" card after each drill (repetition count, attempts landed within window, one named subskill).
- Builds on `ScratchRenderTimeline` and `ComboScratch`. No new dataset.
- Flag: `STRUCTURED_DRILLS`.

### C4 — Adaptive practice loops (soft-blocked on B5)

- "Next up" suggestion in `LevelSelectView` based on `sessionHistory` patterns.
- Minimal mistake-replay using `SessionReplayTimeline` (own minimal path; swap to B5 replay when available).
- Flags: `NEXT_UP_SUGGESTION`, `LAST_TAKE_REPLAY`.
- → **TestFlight Checkpoint β** (drills + replay + next-up).

### C5 — Session intelligence (HARD BLOCK on B2)

- "Focus of the day" hint in Coach card before a session, derived from yesterday's worst phrase.
- **No fatigue heuristics in C** (defer to Phase E or never).
- High overclaim risk; copy stays declarative ("Yesterday: the second phrase ran late. Try it slower today.").
- Flag: `FOCUS_OF_THE_DAY`, release-default-false until γ.

### C6a — Milestone events (additive, low-risk)

- Cosmetic milestone events (first session, 7-day streak, 100 attempts in a single scratch).
- One-shot celebratory copy in ResultsOverlayView. Read-only `ProgressManager` consumption.
- Flag: `MILESTONES`.

### C6b — "Needs review" hint (replaces mastery decay)

- Derived, ephemeral, read-time-only tag on level-select cards when `recentAccuracies` regress or `lastPracticeDate` is stale.
- **No change to `isMastered` persistence.**
- Flag: `NEEDS_REVIEW_HINT`.
- → **TestFlight Checkpoint γ** (sustainable motivation; verify no addiction-loop perception).

### Execution order

1. Minimal safe start (contextual tips). Land first.
2. C0b — pacer (pure, no UI).
3. C0a — DEBUG-only coaching data path wiring.
4. C3 — structured drills (parallel-safe).
5. C1 — post-session drift coaching summary → α.
6. **WAIT for B2.** Without B2, C2 and C5 are hard-blocked.
7. C2 — phrase-aware coaching → combined-α-with-B2.
8. C4 — adaptive practice loops → β.
9. C5 — focus of the day (high-risk; explicit copy review).
10. C6a — milestone events.
11. C6b — needs review hint → γ.

## Safe before TestFlight

The minimal safe start (contextual tips), C0a (DEBUG-only initially), C0b (pure value type), and the presentation-tier confidence foundation are all safe to land. C3 is parallel-safe. C1 can land flag-false until checkpoint α.

## Deferred / post-TestFlight

- C2 and C5 are **hard-blocked on B2**. They cannot ship until phrase boundaries are visible in the lane.
- C4 is soft-blocked on B5 (uses a minimal own-path replay until B5 lands).
- C6a and C6b sit after the earlier slices clear.

**Explicitly deferred to Phase E or later:**

- Mastery decay touching persistence.
- Fatigue detection heuristics.
- Personalized coaching tone.
- Adaptive Drift/Phrase thresholds.
- Challenge progression / multi-take escalation.
- Persisting `CoachingEvent` to disk.

## Risks

The largest risk in Phase C is overclaim shape: surfacing inferred events without the visual referent or without honest verb choice. Mitigation:

- Land B2 (phrase boundaries visible) before any phrase coaching event becomes user-visible.
- Every coaching surface uses pacer (C0b) — no bursts.
- Every coaching surface uses displayability tier — advisory copy verbs only at advisory tier.
- C5 carries the highest risk; copy stays declarative and ships behind release-default-false until γ.

## Verification gates

Per `[[feedback_verification_scope]]`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` clean.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
4. Flag wiring verified in `FeatureFlags.swift`.
5. Copy review against PROFILE.md vocabulary (Section X in master roadmap).
6. C0b pacer: deterministic unit tests via `xcrun xctest` with DOT-form selectors (per `[[project_test_runner_hang]]`).
7. Reduce-motion path for any new animation.
8. No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.

### C confidence model

**Design decision: confidence lives at the presentation layer, not on the value type.**

- Sub-threshold drift → pacer suppresses; no event.
- Above-threshold drift, single occurrence → advisory tier (verb-softened: "appears to" / "may have").
- Above-threshold drift, repeated across phrase → primary tier (catalog copy verbatim).
- No usable signal → emit `.noSignal` event, surface as `LowSignal`-style callout.

**Uncertainty vocabulary (extends PROFILE.md-compliant set):**

- Existing: "(preview)", "Timing estimates are based on on-device audio onsets. They aren't saved, exported, or scored.", "We didn't pick up any attempts on this take.", "Audio onsets suggest activity here; identity is not yet confirmed.", "Supplemental — captured notation is the source of truth.", "Diagnostics-only preview."
- Phase C additions (advisory verbs only): "appears to," "may have," "looks like," "couldn't confirm." Never numeric confidence. Never "we detect."

## Links back to master roadmap

- Master Phase C section, framework gaps (§0.7–0.9): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase honesty model (Section X): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase verification gates (Section Y): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Phase B prerequisite detail: [notation_phase_b.md](./notation_phase_b.md)
- Phase D-S consumer of presentation-tier confidence: [replay_phase_d.md](./replay_phase_d.md)
