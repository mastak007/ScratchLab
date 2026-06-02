---
title: ScratchLab Roadmap — Phases A → F (master)
role: Active multi-year master roadmap. High-level reality check, framework-gap bridge into Phase B, plus the cross-phase honesty/verification/constraint canon. Per-slice execution detail lives in the phase-specific docs linked below.
status: active (master roadmap; updated as phases ship)
source: original Phase A→F multi-year roadmap, restructured 2026-05-28 to delegate deep per-slice detail to phase docs while preserving the master's structure, principles, and constraints.
related docs:
  - [notation_phase_b.md](./notation_phase_b.md) — Phase B execution detail
  - [coaching_phase_c.md](./coaching_phase_c.md) — Phase C execution detail
  - [replay_phase_d.md](./replay_phase_d.md) — Phase D execution detail (D-A analysis + D-X cinematic export + D-S spatial replay/AR)
  - [instructor_phase_e.md](./instructor_phase_e.md) — Phase E execution detail
  - [spatial_phase_f.md](./spatial_phase_f.md) — Phase F long-term AR sketch
  - [hazy-exploring-grove.md](./hazy-exploring-grove.md) — Phase A planning archive (shipped)
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Roadmap — Phases A → F (with Spatial Replay / AR integrated)

## Reality check (2026-05-28)

The conversation refers to "Phase C" as the current phase, but actual ship state is:

- **Phase A polish (A1–A9):** SHIPPED on `release/testflight-1`. Confirmed by commits `09396bf` (gate DEBUG diagnostics) back through `8e78fe1` (streak chip).
- **Notation substrate (grammar / timing / semantics / coaching evaluators / presentation / replay-model / debug-card):** SHIPPED INVISIBLY. AI_HANDOFF Sections 1–9 closed at HEAD `f1b3b7b`. All pure value types or `#if DEBUG`-gated. Zero production capture/export/scoring/ML behavior change.
- **Phase B (B0–B5):** NOT SHIPPED. `FeatureFlags.swift:1–44` contains only the six Phase A flags. No `LANE_JUDGMENT_TINT`, `LANE_PHRASE_TINT`, `PHRASE_MOMENTUM_HUD`, `UNLOCK_LADDER`, or `SESSION_REPLAY`. The lane's `NotationLaneGeometryView` renders every primitive identically regardless of timing.
- **Phase C (C0a–C6b):** NOT SHIPPED. `SessionReplayPresentationAdapter` and `ScratchNotationPresentationAdapter` still hard-code `coachingKinds: []`. The coaching data pipe is dry.

**Therefore: "Phase C" cannot meaningfully begin until the Phase A/B framework gaps below are closed.** Surfacing coaching events while phrase boundaries are still invisible reproduces exactly the App-Store overclaim shape PROFILE.md warns against ("we computed a phrase event but the user can't see the phrase that motivated it").

---

# Section 0 — Phase A/B Framework Gaps to Close Before Phase C Work Lands

These gaps must be filled before any Phase C slice — including the "minimal safe start" contextual tips slice — is durable. Order matters: each row depends on the rows above.

## 0.1 Feature flag scaffolding

**Gap:** `FeatureFlags.swift` registers Phase A only. Phase B/C/D/E flags don't exist.

**Build now:**
- Extend `FeatureFlags.swift` with namespaced groups: `// MARK: Phase B`, `// MARK: Phase C`, `// MARK: Phase D-A`, `// MARK: Phase D-X`, `// MARK: Phase D-S`, `// MARK: Phase E`, `// MARK: Phase F`.
- Add stub accessors for every flag referenced anywhere in this plan, **all release-default-false, all DEBUG-default-false** until each owning slice opts in.
- This is one small additive commit. No behavior change.

**Files:** `ScratchLab/Models/FeatureFlags.swift` only.

**Verification:** iOS build + macOS build green; no new release behavior; grep confirms every plan-referenced flag has a registered accessor.

## 0.2 Substrate-visibility DEBUG overlay (B0)

**Gap:** `PhraseBoundaryMapper` output and `DriftCoachingEvaluator` events never reach `NotationLaneGeometryView`. The team has no way to validate evaluator behavior against real captures before user-visible surfacing.

**Build now:**
- DEBUG-only conditional overlay in `NotationLaneGeometryView` that draws phrase boundary lines (from `PhraseBoundaryMapper`) and drift markers (from `DriftCoachingEvaluator`) on top of existing primitives.
- DEBUG-only host view that lets the team scrub through captured sessions with the overlay live.
- **No release-build effect.**

**Files:** `NotationLaneGeometryView.swift` (DEBUG conditional), possibly a new `Views/Notation/DebugSubstrateOverlay.swift`.

**Verification:** iOS + macOS build; manual smoke against a known captured session; release build byte-identical for `NotationLaneGeometryView`.

## 0.3 Lane judgment-color states (B1)

**Gap:** Every notation primitive looks identical regardless of how it was hit. The lane teaches the target but never confirms the user. C1 cannot land coaching event chips on a surface that has no color hierarchy.

**Build now:**
- Recolor existing primitive markers in `NotationLaneGeometryView` based on `TimingWindowEvaluator` output: on-beat (success), early (info), late (warning), no-data (neutral). **Visual only.**
- New flag `LANE_JUDGMENT_TINT`, release-default-false initially, flip after checkpoint α.
- **Critical AR-prep:** semantic palette aliases used here (`success`/`info`/`warning`) must be addressable by name — the spatial replay renderer (Phase D-S) will consume the same semantic names to keep visual grammar identical across 2D and 3D surfaces.

**Files:** `NotationLaneGeometryView.swift`, `FeatureFlags.swift`, `ScratchLabPalette.swift` (one semantic alias if needed), `CoachCopy.swift` (state labels if any — "on-beat / early / late," never "perfect / miss").

**Verification:** iOS + macOS build + macOS build-for-testing; captured session with known drift produces expected colors; reduce-motion path renders colors statically; release-default-false until α checkpoint.

## 0.4 Phrase boundary tints + per-hit micro-feedback (B2) — HARD BLOCKER for C2/C5

**Gap:** Phrases are invisible. Music has structure the renderer doesn't acknowledge. **C2 (phrase coaching) and C5 ("focus of the day") cannot ship until phrase boundaries are visible.** Surfacing phrase coaching events before the user can see phrases is the overclaim shape App Store rejects.

**Build now:**
- Phrase boundaries rendered as low-contrast vertical tints (≤8% alpha) on `NotationLaneGeometryView`, driven by `PhraseBoundaryMapper`.
- Per-hit micro-feedback layer on `ScratchMotionLane`: brief radial pulse (180ms, ease-out) on primitive completion, driven by existing `laneUserEvents`.
- Two independent flags: `LANE_PHRASE_TINT`, `LANE_MICRO_FEEDBACK`.
- **Critical AR-prep:** the phrase boundary projection used here will be the same projection consumed by the D-S spatial-ribbon renderer. Keep the geometry function pure and parametric so it can render to both 2D (lane) and 3D (RealityKit/ARKit) contexts without forking.

**Files:** `NotationLaneGeometryView.swift`, `ScratchMotionLane.swift`, `FeatureFlags.swift`.

**Verification:** iOS + macOS build + macOS build-for-testing; phrase tints render at intended low alpha; no more than two simultaneous accent animations; freeze-frame readability test passes.

## 0.5 Phrase release tails + phrase-streak HUD (B3)

**Gap:** Phrases don't feel like complete musical thoughts. Mid-session has no visible momentum. C2's release-tail observation copy has no visual referent.

**Build now:**
- Brief horizontal fade-out on lane at phrase end, duration = clamped `AudioPhraseSummary.terminalDragDuration`.
- Phrase-streak HUD chip in `PracticeModeView` (consecutive phrases-within-window count). Visual-only, never affects `currentScore`.
- New flag: `PHRASE_MOMENTUM_HUD`.

**Files:** `ScratchMotionLane.swift`, `PracticeModeView.swift`, `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** standard gate + phrase-streak chip increments only on phrase boundary crossings within window; release-tail duration matches `terminalDragDuration` clamped.

## 0.6 Progression visibility (B4)

**Gap:** `ProgressManager.isScratchMastered` exists but doesn't ladder into a visible unlock arc. Mid-session has no visible progression bar.

**Build now:**
- Multi-scratch unlock ladder on `LevelSelectView` (read-only consumption of `ProgressManager.isScratchMastered` / `practiceCount`).
- Intra-session momentum bar in `PracticeModeView` (visible arc toward session end). Derived from existing session counters; no new persistence.
- Two independent flags: `UNLOCK_LADDER`, `IN_SESSION_MOMENTUM`.

**Files:** `LevelSelectView.swift`, `PracticeModeView.swift`, `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** standard gate; no `ProgressManager` writes; copy avoids "level up" — uses "available next."

## 0.7 Coaching data-path wiring (C0a, DEBUG-only)

**Gap:** `SessionReplayPresentationAdapter` writes `coachingKinds: []` on every stroke. `DriftCoachingEvaluator` events exist but never reach presentation. The pipe is built but mute.

**Build now (DEBUG-only initially):**
- `SessionReplayPresentationAdapter` populates `coachingKinds` from `DriftCoachingEvaluator` output when `COACHING_EVENTS_PIPELINE` flag is on.
- Drift events first; phrase events stay dry until B2 ships.
- DEBUG-default-true, release-default-false.

**Files:** `SessionReplayPresentationAdapter.swift`, `FeatureFlags.swift`.

**Verification:** DEBUG smoke test: known captured session produces non-empty `coachingKinds` on expected strokes; release build remains empty.

## 0.8 Coaching event pacer (C0b)

**Gap:** Without throttling, coaching event bursts would overwhelm any user surface. C1 cannot ship without this gating component.

**Build now:**
- New pure value type `CoachingEventPacer` in `Models/Notation/Coaching/`.
- Consumes `CoachingEventSet`; applies configurable minimum inter-event spacing + same-kind suppression window.
- Deterministic, testable in isolation, no UI.

**Files:** `Models/Notation/Coaching/CoachingEventPacer.swift` (new).

**Verification:** unit tests cover same-kind suppression, inter-event spacing, deterministic ordering preservation.

## 0.9 Presentation-tier confidence (C-foundation)

**Gap:** `CoachingEvent`'s contract is "manual metadata only, no inference, no thresholding" (per `CoachingEvent.swift:7-14`). Adding numeric confidence to the value type would leak into export and violate the contract. Without a presentation-layer alternative, every coaching event surfaces as equally-asserted fact.

**Build now:**
- New `CoachingEventDisplayability` presentation-layer projection.
- Inputs: existing `isResearchOnly` flag, pacer verdict, surface-tier computed at adapter level.
- Outputs: `display(primary)`, `display(advisory)`, `hidden`.
- **Critical AR-prep:** spatial replay (D-S) consumes the same displayability tier — confidence visibly degrades (band fattens, opacity drops) when tier = advisory. This is the honesty grammar that crosses 2D and 3D surfaces unchanged.

**Files:** `Models/Notation/Presentation/CoachingEventDisplayability.swift` (new), `SessionReplayPresentationAdapter.swift` (consumer).

**Verification:** unit tests cover every input combination; surface-tier decisions reproducible across re-runs.

## 0.10 Replay & reward (B5) — soft-blocks C4

**Gap:** Recent-sessions strip lists past sessions but they can't be revisited. `DebugReviewNotationCard` is unreachable from running app per AI_HANDOFF. C4's last-take replay has no foundation.

**Build now (own branch off `release/testflight-1`):**
- Tap-to-replay on recent-sessions cards using `ReviewAudioOnsetPreview` + production-promotion of `DebugReviewNotationCard` (specifically the preview-card surface, nothing else).
- This is the slice that breaks the AI_HANDOFF "zero production Review wiring" boundary. Plan as its own mini-project, own branch, own flag, own TestFlight cycle.
- Flag `SESSION_REPLAY`, release-default-false through γ checkpoint.

**Files:** `LevelSelectView.swift`, `ReviewAudioOnsetPreview.swift`, `DebugReviewNotationCard.swift` (promotion path), `CoachCopy.swift`, `FeatureFlags.swift`.

**Verification:** every replayed marker carries "preview" framing; reuses `ReviewAudioOnsetPreview`'s PROFILE.md-compliant copy verbatim ("on-device audio onsets", "(preview)", "aren't saved, exported, or scored"); rollback flips flag and reverts production Review wiring without touching B0–B4.

## 0.11 Reduce-motion path for every new animation

**Gap:** A8 set the precedent (`PracticeModeView.swift:2498`) but it's not enforced per slice. New animations without it regress accessibility.

**Build now:**
- Every B/C slice that adds motion must mirror A8's reduce-motion pattern.
- This is a verification checklist item, not a code artifact.

**Verification:** every flagged slice's verification block includes "reduce-motion path renders the same state statically."

## 0.12 AR-prep contracts (do this while doing B/C, not after)

These are design contracts to honor *during* B/C/D-A work so the D-S spatial track has nothing to refactor when it begins. None of these are new slices; they are constraints on existing slices.

**Contracts to honor:**

1. **Semantic palette by name.** Phase B's color hierarchy uses semantic aliases (`success`/`info`/`warning`) addressable by name from the spatial renderer.
2. **Pure geometry functions.** Phrase boundary projection, notation ribbon projection, ghost-take projection are pure functions of sidecar inputs. No `View`-bound state, no SwiftUI-only types in the projection layer.
3. **Confidence-as-thickness primitive.** `CoachingEventDisplayability.advisory` maps to a numeric thickness/opacity coefficient consumable by both 2D `Canvas` and 3D `Mesh`.
4. **Audio-onset = solid, classifier-derived = dashed.** Visual grammar that encodes which signal is trustworthy. Established in B1/B2, carried verbatim into D-X and D-S.
5. **No SwiftUI-bound coordinate spaces in presentation models.** `NotationLaneGeometry` already uses unitless parametric coordinates; preserve this.

**Why these contracts now:** the cost of honoring them inside B/C/D-A is zero (the abstractions exist). The cost of retrofitting them later is rewriting B/C/D-A renderers. Do it once.

---

# Phase A — Polish [SHIPPED]

Phase A is complete on `release/testflight-1`. Reference list (commits visible in `git log`):

- A0 — `FeatureFlags` registry (`57940cb`)
- A1 — shared visual palette (`6a900f4`)
- A2 — `CoachCopy` namespace + level-select copy routing (`f395882`, `b09756a`)
- A3 — streak chip (`8e78fe1`)
- A4 — per-scratch progress badges (`8071e41`)
- A5 — recent-sessions strip (`33b548f`)
- A6 — beat-pulse on action line (`3e95331`)
- A7 — input breathing on action line (`fc9e4e1`)
- A8 — session-complete cinematic (`f2b7384`)
- A9 — honest-failure callout (`5330095`, `f3eb4e2`)
- Capture: DEBUG-only diagnostic gating for Release (`09396bf`)

Notation substrate Sections 1–9 also closed at HEAD `f1b3b7b` per AI_HANDOFF.

**No new Phase A work is planned.** Phase A is shipped; Section 0 above is the bridge into Phase B.

For the Phase A planning archive (philosophy, slice rationale, mission statement), see [hazy-exploring-grove.md](./hazy-exploring-grove.md).

---

# Phase B — "Notation Feels Like a Game"

**See [notation_phase_b.md](./notation_phase_b.md) for full Phase B execution detail.**

## B context

Phase B evolves `ScratchMotionLane` and the practice loop from "developer notation renderer" into "musical gameplay surface" — additively, deterministically, behind flags — without rewriting notation/scoring/capture, without retraining ML, without changing export, and without breaking PROFILE.md's honest-uncertainty posture.

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

## B vision

"Notation as gameplay" in ScratchLab specifically means:
- The lane *responds* to user input in ways that confirm rhythm and timing, not just record it.
- Phrase boundaries become musical chunks the user can feel, not just internal data.
- Success and timing-window deviations are **legibly differentiated** on the same surface that teaches the move.
- Session momentum and progression have a visible arc — not just a final results screen.

**What must remain instructional:**
- Notation is the source of truth; gameplay sits *on* it, never *over* it.
- Timing windows show drift, they do not invent a "perfect / miss" judgment.
- Every reward state must be honestly grounded — accuracy from real per-stroke drift, not a vibe-only score.
- Copy stays in `CoachCopy.swift`, vetted against PROFILE.md vocab (`estimated`, `preview`, `uncertain`; no "AI detects exactly").

## B pillars

1. Readable rhythm surface
2. Honest reinforcement
3. Musical phrase structure
4. Session momentum
5. Progression visibility
6. Tactile motion (micro-feedback)
7. Replayability
8. Flow-state pacing
9. **AR-renderable geometry (new pillar):** every visual primitive added in B is a pure projection that the D-S spatial track can render in 3D without forking the model layer.

## B slices

(These are the Section 0 framework gaps re-stated as Phase B's own roadmap. The numbering matches.)

### B0 — Substrate visibility (DEBUG-only)
See §0.2. Trivial, DEBUG-default-true, release-default-false. No user-visible effect.

### B1 — Lane judgment-color states (MINIMAL SAFE START)
See §0.3. Single render file, deterministic, easy rollback.
→ **TestFlight Checkpoint α** ("Does the lane feel more alive without feeling busier?")

### B2 — Phrase boundary tints + per-hit micro-feedback
See §0.4. Hard prerequisite for C2 and D-S phrase ribbons.

### B3 — Phrase momentum
See §0.5. Visible release tails + phrase-streak HUD chip.
→ **TestFlight Checkpoint β** ("Do phrases feel like meaningful chunks? Is mid-session readable?")

### B4 — Progression visibility
See §0.6.

### B5 — Replay & reward (carries highest risk)
See §0.10. Lives on own branch off `release/testflight-1`.
→ **TestFlight Checkpoint γ** (gated false-by-default).

## B execution order

1. B0 (DEBUG-only).
2. B1 → checkpoint α.
3. B2.
4. B3 → checkpoint β.
5. B4.
6. B5 → checkpoint γ.

**Freeze boundaries:**
- After B1 flagged-true: no further lane visual changes for one TestFlight cycle.
- After B3 flagged-true: no further phrase-system additions for one TestFlight cycle.
- Before B5: lives on its own branch because it crosses the AI_HANDOFF "zero production Review wiring" boundary.

## B systems to add

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

## B explicit non-goals

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

---

# Phase C — "Coach Intelligence + Structured Training"

**See [coaching_phase_c.md](./coaching_phase_c.md) for full Phase C execution detail.**

## C context

Phase A polished the experience; Phase B made notation feel like a game. Phase C turns ScratchLab into a structured scratch-training system — coaching that is more musical, more session-aware, more adaptive — without becoming a fake "AI teacher."

**Central observation: coaching evaluators already exist and produce real events; they just never reach the user.** `DriftCoachingEvaluator` and `PhraseCoachingEvaluator` emit `CoachingEvent`s; `CoachingEventMerger` flattens them; `NotationPresentationStroke` has a `coachingKinds: [CoachingEventKind]` field. But adapters hard-code `coachingKinds: []`. Phase C's largest single act is to fill that pipe.

**Two other gaps shape the roadmap:**
- **No throttling/pacing** on coaching events (rapid bursts would overwhelm the user).
- **No confidence field** anywhere in the coaching layer (drift rules are binary thresholds).

Both must be addressed before any coaching event becomes user-visible. Both are in Section 0 (C0b pacer, presentation-tier displayability).

## C vision

"Structured coaching" in ScratchLab means:
- The app **observes** what the user did, **names** what it noticed in honest declarative language, and **suggests** a next move — without claiming to grade skill.
- Practice sessions have a visible arc: warmup → drill → review → next.
- Coaching events appear *when relevant*, not constantly. Silence is a valid coaching state.
- Confidence is communicated through verb choice ("appears to be," "may have," "couldn't pick up") and surface-tier (advisory vs primary), never through numbers.

## C slices (summary)

| Slice | Description | Flag | Checkpoint |
|---|---|---|---|
| Minimal safe start | Contextual practice-tip rotation in `SessionSetupOverlay` from `ProgressManager` history. Pure, no evaluator wiring. | `CONTEXTUAL_TIPS` | — |
| C0a | DEBUG-only coaching data-path wiring (`SessionReplayPresentationAdapter` populates `coachingKinds`). | `COACHING_EVENTS_PIPELINE` | — |
| C0b | `CoachingEventPacer` — pure throttle/suppression value type. | — | — |
| C1 | Post-session drift coaching summary in ResultsOverlayView (drift only, advisory tier). | `RESULTS_DRIFT_COACHING` | α |
| C2 | Phrase-aware coaching (HARD BLOCK on B2). | `PHRASE_COACHING_SURFACE` | combined α |
| C3 | Structured drills — explicit warmup → drill → review arc. | `STRUCTURED_DRILLS` | — |
| C4 | Adaptive practice loops — "next up" suggestion + mistake-replay (soft-blocked on B5). | `NEXT_UP_SUGGESTION`, `LAST_TAKE_REPLAY` | β |
| C5 | "Focus of the day" hint (HARD BLOCK on B2; high overclaim risk). | `FOCUS_OF_THE_DAY` | γ |
| C6a | Cosmetic milestone events (first session, 7-day streak, 100 attempts). | `MILESTONES` | — |
| C6b | "Needs review" hint — replaces mastery decay; read-time-only. | `NEEDS_REVIEW_HINT` | γ |

For each slice's full description, file list, build instructions, and verification, see [coaching_phase_c.md](./coaching_phase_c.md).

## C execution order

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

## C confidence model

**Design decision: confidence lives at the presentation layer, not on the value type.** See §0.9.

- Sub-threshold drift → pacer suppresses; no event.
- Above-threshold drift, single occurrence → advisory tier (verb-softened: "appears to" / "may have").
- Above-threshold drift, repeated across phrase → primary tier (catalog copy verbatim).
- No usable signal → emit `.noSignal` event, surface as `LowSignal`-style callout.

**Uncertainty vocabulary (extends PROFILE.md-compliant set):**
- Existing: "(preview)", "Timing estimates are based on on-device audio onsets. They aren't saved, exported, or scored.", "We didn't pick up any attempts on this take.", "Audio onsets suggest activity here; identity is not yet confirmed.", "Supplemental — captured notation is the source of truth.", "Diagnostics-only preview."
- Phase C additions (advisory verbs only): "appears to," "may have," "looks like," "couldn't confirm." Never numeric confidence. Never "we detect."

## C explicitly deferred (to Phase E or later)

- Mastery decay touching persistence.
- Fatigue detection heuristics.
- Personalized coaching tone.
- Adaptive Drift/Phrase thresholds.
- Challenge progression / multi-take escalation.
- Persisting `CoachingEvent` to disk.

---

# Phase D — Studio Mode (Three Parallel Tracks)

**See [replay_phase_d.md](./replay_phase_d.md) for full Phase D execution detail (D0, D-A analysis, D-X cinematic export, D-S spatial replay/AR).**

Phase D is restructured into three parallel tracks that share a foundation and consume the same artifacts. **Spatial Replay (D-S) is no longer a separate phase or a deferred future** — it is Studio's third surface, built on the same pipe as analysis and export.

```
                         ┌──────────────────────────────────┐
                         │   Phase D foundation (D0)        │
                         │   Studio tab + session picker    │
                         │   + STUDIO_MODE flag             │
                         └─────────────┬────────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              ▼                        ▼                        ▼
      ┌───────────────┐        ┌───────────────┐        ┌───────────────┐
      │  D-A          │        │  D-X          │        │  D-S          │
      │  Analysis     │        │  Cinematic    │        │  Spatial      │
      │               │        │  Export       │        │  Replay / AR  │
      │  D1 scrub     │        │  DX1 phrase   │        │  DS1 iOS AR   │
      │  D2 phrase    │        │  comparison   │        │  spatial      │
      │  archaeology  │        │  DX2 notation │        │  notation     │
      │  D3 annot.    │        │  overlay      │        │  ribbon       │
      │  D4 multi-    │        │  DX3 cinematic│        │  DS2 ghost    │
      │  take         │        │  replay video │        │  take         │
      │  D5 drill     │        │  DX4 NDI clean│        │  DS3 phrase   │
      │  authoring    │        │  + notation   │        │  chapters     │
      │  D6 workbench │        │  feeds        │        │  DS4 Vision   │
      │  D7 export    │        │  DX5 OBS-side │        │  Pro theatre  │
      │  package      │        │  packaging    │        │  DS5 spatial  │
      └───────────────┘        └───────────────┘        │  archaeology  │
                                                        │  (D2 in 3D)   │
                                                        └───────────────┘
```

Tracks run in parallel; each has its own checkpoints. Phase E (Instructor) consumes outputs from all three.

## D context

ScratchLab already has two app targets — `ScratchLab` (iOS-target, consumer) and `ScratchLabDesktop` (macOS-target, analyzer). Studio Mode is the macOS analyzer surface, productized.

Sidecar schema (`scratchlab_local_recording_sidecar_v1`) already carries `auditTrail` and `reviewMetadata`. Studio Mode is largely about **surfacing existing additive sidecar evolution paths**, not designing new schemas. Phase D never bumps the schema version unless explicitly forced; it adds optional sidecars alongside.

## D pillars (shared across tracks)

1. **Inspectable notation** — every primitive can be drilled into, every metric traceable to an evaluator.
2. **Archival/replay fidelity** — captured sessions remain bit-exact playable from sidecar; Studio never alters originals.
3. **Phrase intelligence** — phrase grouping and release-tail analysis become first-class studio primitives.
4. **Additive-sidecar discipline** — studio outputs are new optional sidecars next to the original, never mutations of it.
5. **Explainable analysis** — every chart, heatmap, comparison, export, or spatial overlay has a "why" affordance.
6. **Deterministic reproducibility** — same session + same sidecar = same studio output, every time, on every surface (2D analytic, exported video, spatial replay).
7. **Layered disclosure** — Studio surfaces hide depth until requested.
8. **Surface parity** — analytic, export, and spatial surfaces show the same data, same colors, same honesty grammar.

## D0 — Studio foundation (shared)

- Productize inspection surfaces that exist on macOS. Promote `DebugReviewNotationCard` and `NotationVisualizerView` patterns into a single hosted "Studio" tab inside `MacAnalyzerView`, behind `STUDIO_MODE` flag.
- macOS-only at this stage. No analytics; just navigable entry.
- Foundation for all three tracks.

**Files:** `MacAnalyzerView.swift`, new `ScratchLabDesktop/Views/Studio/StudioSessionPickerView.swift` and `StudioSessionHostView.swift`, `FeatureFlags.swift` (`STUDIO_MODE`).

**Verification:** macOS smoke test: tab appears, session picker lists real archived sessions, opening one shows existing replay view without errors.

## D track summaries (full detail in [replay_phase_d.md](./replay_phase_d.md))

### Track D-A — Analysis

| Slice | Description | Flag | Checkpoint |
|---|---|---|---|
| D-A1 | `StudioReplayScrubber` + variable playback rate; phrase-span looping. | `STUDIO_SCRUB` | α-D |
| D-A2 | Phrase heatmap, session timeline, release-tail durations chart. Read-only. | `STUDIO_ARCHAEOLOGY` | — |
| D-A3 | Bookmarks + annotations; additive sidecar `scratchlab_studio_annotations_v1`. | `STUDIO_ANNOTATIONS` | β-D |
| D-A4 | Multi-take comparison (compare, never "better"). | `STUDIO_MULTITAKE` | — |
| D-A5 | Notation/drill authoring; additive sidecar `scratchlab_studio_drill_v1`. | `STUDIO_DRILL_AUTHORING` | — |
| D-A6 | Analysis workbench (D-A1+D-A2+D-A3+D-A4 layout, `@SceneStorage`). | `STUDIO_WORKBENCH` | — |
| D-A7 | Studio package export (additive sidecar `scratchlab_studio_package_v1`). | `STUDIO_EXPORT` | γ-D |

### Track D-X — Cinematic Export

The export track is genuinely ScratchLab's biggest near-term differentiator before any AR hardware. Phrase comparison videos, transparent notation overlays, and clean+notation NDI feeds are valuable to instructors, streamers, and creators even without any 3D surface. They are also the prerequisite pipeline for D-S.

| Slice | Description | Flag | Checkpoint |
|---|---|---|---|
| D-X0 | Renderable artifact contract (`CinematicFrameProducer`, pure, no AVFoundation). | — | — |
| D-X1 | Notation-overlay transparent video export (alpha channel for OBS/Premiere/FCP). | `EXPORT_NOTATION_OVERLAY_VIDEO` | — |
| D-X2 | Phrase comparison video export (side-by-side MP4). | `EXPORT_PHRASE_COMPARISON` | — |
| D-X3 | Cinematic replay video (annotated practice export, optional ghost-take). | `EXPORT_CINEMATIC_REPLAY` | — |
| D-X4 | NDI clean + notation feeds for OBS-side composition. | `NDI_FEEDS` | — |
| D-X5 | Export workbench (D-X1+D-X2+D-X3+D-X4 surfaced together). | `EXPORT_WORKBENCH` | α-DX |

### Track D-S — Spatial Replay / AR

**D-S rules (non-negotiable):**
- **Renderer-only.** D-S consumes notation/replay artifacts and produces no canonical data.
- **No realtime claims sourced from classifier output.**
- **Solid line = audio onset. Dashed translucent = classifier-derived.**
- **Confidence visibly degrades** when `CoachingEventDisplayability.advisory`.
- **Persistent "Replay — Estimated Timing" badge** on every D-S surface.
- **No characters in practice.** Optional abstract reactive particles only, replay/export-only.
- **No realtime coaching during execution.**
- **iOS AR before Vision Pro before glasses.** Non-negotiable hardware sequence.

| Slice | Description | Flag | Checkpoint |
|---|---|---|---|
| D-S0 | Spatial artifact contract (`SpatialReplayProjection`, pure, no ARKit/RealityKit imports). | — | — |
| D-S1 | iOS AR `SpatialReplayView` — 3D ribbon, audio-onset spheres, classifier-derived dashes. Replay-only. | `SPATIAL_REPLAY_IOS` | α-DS |
| D-S2 | Ghost-take overlay on D-S1's ribbon. | `SPATIAL_GHOST_TAKE` | — |
| D-S3 | Spatial phrase chapters (HARD BLOCK on B2). | `SPATIAL_PHRASE_CHAPTERS` | — |
| D-S4 | Vision Pro replay theatre (visionOS target). | `SPATIAL_REPLAY_VISIONOS` | β-DS |
| D-S5 | Spatial archaeology (D-A2 in 3D). | `SPATIAL_ARCHAEOLOGY` | γ-DS |
| D-S6 | Honesty grammar v1 enforcement (audit slice, not a feature). | — | δ-DS |

## D execution order (across tracks)

Tracks run in parallel after D0 ships. Per-track ordering inside each track is rigid; cross-track parallelism is allowed.

**Recommended interleaving:**

1. **D0** (foundation).
2. **D-A1** (scrub) + **D-X0** (renderable artifact contract — pure, no UI) in parallel.
3. **D-A2** (archaeology) + **D-X1** (notation overlay video) + **D-S0** (spatial projection — pure, no AR yet) in parallel.
   → checkpoint α-D + α-DX (analytics + first export).
4. **D-A3** (annotations) + **D-X2** (phrase comparison video) + **D-S1** (iOS AR replay) in parallel.
   → checkpoint β-D + α-DS (annotations + first spatial surface on iOS).
5. **D-A4** (multi-take) + **D-X3** (cinematic replay) + **D-S2** (ghost take) in parallel.
6. **D-A5** (drill authoring) + **D-X4** (NDI feeds) + **D-S3** (spatial phrase chapters, depends on B2).
   → checkpoint γ-D + checkpoint β-DX (creator cohort).
7. **D-A6** (workbench) + **D-X5** (export workbench) + **D-S4** (Vision Pro theatre).
   → checkpoint β-DS (Vision Pro cohort).
8. **D-A7** (export package) + **D-S5** (spatial archaeology).
   → checkpoint γ-DS (full spatial surface).
9. **D-S6** honesty audit.
   → checkpoint δ-DS.

## D freeze boundaries

- After **D-A1**: no new analytics surfaces for one TestFlight cycle.
- After **D-A3**: annotation sidecar schema frozen.
- After **D-A5**: drill sidecar schema frozen.
- After **D-S1**: no new realtime claims for one cycle. iOS AR replay must be replay-only for the entire α-DS cycle.
- After **D-S4**: Vision Pro replay surface frozen; no scope creep into Vision Pro performance HUD.
- Before **Phase E**: minimum 4 weeks of δ-DS feedback. Phase E opens instructor sharing; package format and spatial format must both be stable.

## D explicit non-goals (D-X and D-S)

See [replay_phase_d.md](./replay_phase_d.md) "Risks" for the full track-specific non-goal lists. Headline anti-goals: no DAW, no upload-to-web, no live broadcast claims (D-X); no virtual decks, no metaverse, no gamified verdicts in 3D, no realtime coaching during live performance, no AI-confirmed claims, no content moderation / social layer, no lightweight AR glasses in Phase D (D-S).

---

# Phase E — Instructor Network + School Operations Layer

**See [instructor_phase_e.md](./instructor_phase_e.md) for full Phase E execution detail.**

## E context

Phases A–D made ScratchLab a credible personal training, analysis, export, and spatial replay system. Phase E asks: **how does it become usable by real scratch instructors, schools, and workshops — without becoming a social platform, an LMS clone, or an AI battle judge?**

Instructor tooling is a thin layer over Phase D's three tracks, sharing what Studio produces (annotation sidecars, drill sidecars, studio packages, exported videos, spatial sessions) via deterministic, local-first, additive mechanisms. Instructors are macOS-first power users of the same Studio. The student-instructor relationship is implemented by **package exchange**, not by an account system.

**Phase E does NOT open cloud sync, social features, or AI judgment.** It opens **package portability** + **instructor-side review tooling** + **structured curriculum scaffolding** — and stops there.

## E vision

- A way for an instructor to assign a curriculum chunk (drill pack + reference notation).
- A way for a student to complete the assignment and produce a package.
- A way for the instructor to review the package, annotate it (D-A3), optionally export cinematic feedback (D-X3), and return.
- A way for both sides to see progression across assignments.
- All local-first, all package-based, all explainable.

**Phase E inherits from D-X:** exported phrase-comparison videos become a standard feedback artifact. Instructor sends back not just an annotated package but a 60-second comparison video the student can watch on a phone.

**Phase E inherits from D-S:** if both instructor and student have Vision Pro, the package opens in a shared spatial replay theatre (asynchronous; no live multiplayer).

## E slices (summary)

| Slice | Description | Checkpoint |
|---|---|---|
| E1 | Roster + assignment queue. macOS-only "Instructor" panel. `INSTRUCTOR_MODE`. | α-E |
| E2 | Drill pack authoring + new sidecar `scratchlab_instructor_pack_v1`. | — |
| E3 | Annotation exchange workflow (instructor↔student). | β-E |
| E4 | Per-student timeline view (read-only). | — |
| E5 | Replay lesson format — new sidecar `scratchlab_replay_lesson_v1`. | — |
| E6 | Curriculum packs + ordering. | γ-E |
| E7 | Phrase-keyed feedback (extends C6b). | δ-E |

For full slice descriptions, see [instructor_phase_e.md](./instructor_phase_e.md).

## E explicit non-goals

- AI battle judging. Never.
- Cloud sync. Defer indefinitely.
- Public profiles. Never.
- Social media feed mechanics. Never.
- Auto-grading, auto-certification, skill ranking. Never.
- Marketplace, monetization, in-app pricing. Never.
- Live video/audio between instructor and student. Out of scope; use any other tool.
- Personalized AI coaching tone. Never.

## E silence rule

Identified human territory — Phase E never automates:

- **Instructors judge:** style, originality, battle creativity, performance energy, groove, swing, musicality, crowd response, improvisation quality, taste, expression.
- **Students self-reflect on:** intent, focus, satisfaction, frustration, what felt good, what didn't, what to try next.
- **App can support structurally:** timing windows, phrase boundaries, drift magnitudes, primitive counts, release-tail durations, repetition counts.
- **App cannot automate honestly:** anything in the instructor-judges list above.

The moment musical interpretation begins, the app falls silent. Silence is a feature.

---

# Phase F — Long-Term AR (Lightweight Glasses / HUD / Performance Augmentation)

**See [spatial_phase_f.md](./spatial_phase_f.md) for the Phase F sketch.**

Phase F opens **only when**:
- Phase D-S δ has been stable for 60+ days.
- Phase E δ has been stable for 60+ days.
- Lightweight AR glasses (Apple, XREAL, Viture, Brilliant, or equivalent) have shipped a stable developer SDK accessible from Swift.
- Honest-uncertainty vocabulary has held across 90+ days of releases.

Phase F is **not designed in detail in this plan** beyond high-level scope. Phase F's planning slice opens after Phase E δ.

## F scope (sketched)

- **F1 — Lightweight HUD overlay (replay).** Single-plane HUD glasses display a minimal replay overlay above the deck. Replay-only.
- **F2 — Lightweight HUD overlay (practice, target-only).** Targets and beat grid as HUD; never live judgment. Realtime only because targets are deterministic, not because classifier output is.
- **F3 — Performer-only confidence monitor.** Hidden iPad showing next phrase, accessible only to the performer. Not on-glass. Teleprompter, not XR.
- **F4 — Spectator AR (audience-side).** Optional spectator view of a battle/performance with notation overlay. Spectator side only; performer untouched.

## F explicit non-goals

- **No live performance HUD that closes the feedback loop with the system instead of the audience.** Anti-goal restated.
- **No metaverse / virtual venue / persistent social space.** Anti-goal.
- **No AI judging of live performance.** Never.
- **No "Coach during performance."** Anti-goal full stop.
- **No fake AI certainty in any AR surface.** Honesty grammar holds at every device.

---

# Section X — Honesty Model (one canonical statement, applies to every phase)

**What ScratchLab must NEVER say (any phase, any surface):**
- "You did this perfectly."
- "AI judges this as X."
- "Your skill rating is N."
- "You've mastered this." (`isMastered` exists but the label avoided)
- "This is the right way."
- "Better than yesterday."
- "Your groove is improving."
- "This phrase has good feel."
- "Battle ready."
- "Certified at level N."
- "ScratchLab is N% sure."
- "AI confirmed."
- "Deep learning detected X."
- "Real-time AI coach."

**Vocabulary that holds (PROFILE.md-compliant set, extended through this plan):**

| Token | Use |
|---|---|
| "(preview)" | Audio-only signal not multi-source confirmed |
| "estimated" | Any classifier-derived value |
| "uncertain" | Low-confidence reading |
| "on-device audio and motion analysis" | Generic description of pipeline |
| "appears to" | Advisory observation |
| "may have" | Advisory observation |
| "looks like" | Advisory observation |
| "couldn't confirm" | Negative-state advisory |
| "timing-only" | Motion not confirmed |
| "motion not confirmed" | Explicit honest state |
| "manual review recommended" | App refuses to assert |
| "practice advisory" | Soft suggestion |
| "not exported" | Explicit data-boundary statement |
| "diagnostics-only" | Internal preview framing |
| "supplemental" | Captured notation remains source of truth |
| "compare" (not "better") | Multi-take language |
| "Replay — Estimated Timing" | Persistent D-S badge |

**Visual honesty grammar:**

- **Solid line / sphere** = audio onset (deterministic).
- **Dashed / translucent** = classifier-derived.
- **Confidence-as-thickness** — overlays widen / fade / blur when `CoachingEventDisplayability.advisory`.
- **Persistent badges** — "(preview)" on 2D Review chips, "Replay — Estimated Timing" on D-S surfaces.
- **No checkmarks, no scores during practice** — replay only, and even there comparison-to-target, not absolute verdict.

---

# Section Y — Cross-Phase Verification Gates

For every slice in every phase:

1. **Standard build matrix** (`[[feedback_verification_scope]]`):
   - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` → must succeed.
   - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` → must succeed.
   - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` → must succeed.
2. **Flag wiring** verified in `FeatureFlags.swift`.
3. **Copy review** against PROFILE.md vocab (Section X table above).
4. **Reduce-motion path** confirmed for any new animation.
5. **No forbidden imports** in pure-Swift modules (`AVFoundation`, `CoreML`, `CreateML`, `ARKit`, `RealityKit` allowed **only** in their owning surfaces, never in projection/value-type modules per `[[project_test_runner_hang]]` / AI_HANDOFF Section 9 audit pattern).
6. **No commits or pushes without explicit user approval** per SOUL.md.
7. **No `Co-Authored-By` trailers** per `[[feedback_no_coauthor_trailer]]`.

For D-S specifically:
- **`xcrun xctest`** with dot-form selector for any added Spatial projection tests (per `[[project_test_runner_hang]]`).
- **Forbidden-import grep** confirms ARKit/RealityKit are absent from `Models/Notation/**` and `Services/Spatial/SpatialReplayProjection.swift` (projection module is pure).

For D-X specifically:
- **Deterministic re-export test:** same session + same settings = byte-identical output video (or within encoder noise threshold).

For Phase E:
- **Sidecar round-trip lossless test** for every new sidecar kind.
- **Original sidecar bytes unchanged** after every Studio/Instructor write.

---

# Section Z — Hard Constraints (canonical, applies to every phase)

- No ML retraining.
- No export schema redesign (`scratchlab_local_recording_sidecar_v1` untouched across all phases).
- No notation architecture rewrite.
- No broad capture pipeline rewrite.
- No broad navigation rewrite.
- No DAW ambitions.
- No cloud / social platform expansion.
- No accounts, no authentication, no in-app messaging.
- No live video/audio between users.
- Additive-only preferred.
- Deterministic systems preferred.
- Preserve honest uncertainty posture.
- Preserve instructional identity.
- Preserve App Store-safe posture.
- Avoid overclaiming language.
- Original captured sidecars are sacred — never edited in place.
- Coaching events stay session-ephemeral; never persisted, never exported.
- Mastery semantics stay binary and additive; no decay touching persistence.
- Confidence stays at the presentation layer; `CoachingEvent` value type stays untouched.
- Schema bumps require their own discrete planning slice — never embedded in a feature slice.
- AR is renderer-only; never a producer of canonical data.
- iOS AR before Vision Pro before lightweight glasses; non-negotiable hardware sequence.
- No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.
- No commits or pushes without explicit approval per SOUL.md.
- The app stops speaking where musical interpretation begins.

---

# Appendix A — Where AR plugs into existing architecture (one-page summary)

| Existing pipeline element | AR consumer | How |
|---|---|---|
| `NotationPresentationModel` | D-S0 projection | Pure projection to 3D ribbon geometry |
| `NotationLaneGeometry` | D-S0 projection | Same parametric coordinates; lifted to 3D |
| `PhraseBoundaryMapper` | D-S3 phrase chapters | Same boundary list; rendered as 3D gates |
| `AudioPhraseSummary.terminalDragDuration` | D-S2 release tail (3D) | Same scalar; drives 3D ribbon fade |
| `TimingWindowEvaluator` | D-S color states | Same `success`/`info`/`warning` palette |
| `CoachingEventDisplayability` | D-S confidence rendering | `advisory` → thickness/opacity coefficient |
| `SessionReplayTimeline` | D-S replay | Same timeline; spatial view scrubs the same way |
| `scratchlab_local_recording_sidecar_v1` | D-S source | Same sidecar; D-S never writes back |
| `scratchlab_studio_package_v1` (D-A7) | D-S package surface | Spatial replay opens the same package as 2D analysis |
| `scratchlab_replay_lesson_v1` (E5) | D-S instructor surface | Instructor's lesson opens in Vision Pro theatre if available |

**Zero new producers. Many new consumers.** That's the architecture.

---

# Appendix B — Phase order summary

```
A   Polish                            [SHIPPED]
0   Framework gaps                    ← do this before any C work
B   Notation feels like a game        ← gates C, D-S
C   Coach intelligence
D0  Studio foundation                 ← gates D-A, D-X, D-S
D-A Analysis             ┐
D-X Cinematic Export     ├ parallel after D0; cross-track checkpoints
D-S Spatial Replay / AR  ┘
E   Instructor network                ← gates F
F   Long-term AR                      ← planned after E δ + 60 days
```

End of plan.
