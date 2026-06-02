---
title: ScratchLab Phase A — Core Game Feel (Planning Archive)
role: Phase A planning archive — the philosophy/slice-breakdown document that shaped the polish pass now shipped on `release/testflight-1`.
status: archive (Phase A shipped; preserved verbatim for historical reference)
source: original Phase A planning document
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — active multi-year master roadmap (the Phase A shipped manifest lives there)
  - [notation_phase_b.md](./notation_phase_b.md) — what comes after Phase A on the lane
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase A — Core Game Feel (Planning Document)

## Context

ScratchLab's underlying systems — capture, notation, review/export, additive notation v2 semantics, phrase grouping foundation, App-Store-safe copy posture — are now solid enough to ship. The next milestone is **not** more detection sophistication. It is to transform the surface area from an *engineering tool* into a *playable, polished training product* so a TestFlight tester can pick the app up, do a session, and feel that something musical and rewarding just happened. This document defines Phase A only: the minimum slices required to cross that perception threshold without changing detection, retraining models, inventing new ML, rewriting renderers, or compromising the honesty posture that PROFILE.md enforces.

Key constraints discovered in exploration that shape every slice:

- **`ProgressManager` already persists session history, per-scratch progress, daily streak, and `isMastered`** (`ScratchLab/Services/ProgressManager.swift:21-30`, `:33`, `:191-193`). There are currently *no UI surfaces* for any of it. Progression is the cheapest, most honest game-feel lever in the codebase.
- **Visual identity is half-centralized.** `ScratchLabDesignTokens.swift` (macOS) defines semantic colors, spacing, typography, radii. `ScratchMotionLane.swift:133-144`, `ScratchPhraseChartView`, and `ScratchNotationCanvasView` each hardcode their own local palettes. The same forward/back stroke colors are defined in three places.
- **Audio reactivity needs no new pipeline.** `AudioEngine.inputLevel` (`AudioEngine.swift:68`) and `ScratchLabRuntimeDiagnostics.shared.audioOnsetReviewMarks` (`CaptureCore.swift:83-193`) are live `@Published` publishers; any view can subscribe today.
- **Export schema `scratchlab_session_export_v4` is stable** and timing marks are verified *not* exported, *not* scored, *not* saved (`SessionExportCoordinator.swift:23`, `:478-479`, `:2611-2612`). New session-summary UI is safe.
- **Coaching copy is scattered inline across Views.** The only PROFILE.md-compliant template lives inline in `PracticeTimingPreviewCard` (`PracticeModeView.swift:2613-2642`). Centralizing copy is the single largest App-Store-safety risk reducer available.
- **`GameMode.tutorial` exists but is unimplemented** (`GameState.swift:9-15`). `ComboScratch` framework exists (Baby Flow). Drill modes and `GuidedCaptureMotionAssessment` already exist in `CaptureCore.swift`. Guided-challenge work is *populating existing scaffolding*, not building greenfield.
- **iOS Views are iOS-target-only per pbxproj** (per `[[project_demo_timing_slice]]`). Phase A surfaces land in `ScratchLab` target first; `ScratchLabDesktop` follows where natural.

---

## 1. Phase A Mission Statement

> Make ScratchLab feel **alive, cohesive, and rewarding to use** for a TestFlight tester — without overclaiming detection, without inventing new ML, without changing the export schema, and without rewriting any renderer. The criterion is perceptual: a first-time user opens the app, picks a scratch, captures a take, and finishes the session believing they just used a real training product, not a research prototype.

Phase A is a **polish + surfacing** pass. Nothing in Phase A invents new truth; everything in Phase A makes existing truth more present, more legible, and more emotionally resonant.

---

## 2. User-Experience Goals

1. **Recognisable identity within 2 seconds.** Open the app and the visual language is consistent across iOS Practice, capture, results, and macOS NotationLab. One palette, one type system, one motion vocabulary.
2. **Live surfaces respond to the user.** The notation lane visibly reacts to playback time, audio input level, and (later) audio onsets — so the screen feels alive rather than static.
3. **Every session ends with a moment.** A clearly-framed completion screen that names what just happened ("Baby Scratch — Take 3"), shows honest stats, and proposes a next step (run again / pick next / view history).
4. **Progress is visible without claiming mastery.** Surface streak, per-scratch best, attempt count from data already collected; never invent a score we don't have.
5. **The app never lies about what it sees.** Uncertain or low-confidence takes get a friendly, honest callout in the existing preview-language vocabulary.
6. **One canonical place to look up "what does the coach say".** All user-facing coaching strings flow through one namespace so they can be audited as a unit.

---

## 3. Emotional Targets

| Moment | Target feeling | What backs it |
|---|---|---|
| App launch | "This looks like a real product." | Unified visual identity, no fragmented palettes |
| Pick a scratch | "I know where I am with this one." | Per-scratch progress badge (best, attempts, mastered) |
| Start a take | "The screen knows I'm here." | Action-line breathes with input level, beat pulse on grid |
| Finish a take | "Something just happened." | Session-complete moment with stats counting up |
| See results | "It's honest with me." | Soft uncertainty card stays; no fake scoring of timing |
| Return to level | "I'm building something." | Streak chip, last-N sessions strip |
| Hit a rough take | "It's not my fault and I know what to try." | Honest-failure callout via centralized copy |

Phase A is **not** trying to feel like Guitar Hero. It is trying to feel like a focused practice tool with care put into it. Closer to a well-made metronome app than to a rhythm game.

---

## 4. Product Identity Goals

- **A scratch *practice* tool, not a scratch *simulator*.** Practice produces and reviews real takes; it does not pretend a touchscreen can stand in for a turntable.
- **Notation-first, not score-first.** The notation chart is the artifact the user takes away. Scores are session-local context, not the product.
- **Coach-shaped, not judge-shaped.** Feedback frames what to try next, not what was wrong.
- **Quiet about ML.** No surface anywhere in Phase A says "AI", "deep learning", "detected exactly". Where models touch a surface, the copy uses the PROFILE.md vocabulary: *estimate*, *preview*, *uncertain*, *on-device audio and motion analysis*.
- **Distinct from Serato.** Visual language leans toward training/lab metaphors (timing grid, phrase strip, motion lane) and away from DJ-deck skeumorphism.

---

## 5. Visual-Language Direction

- **Single palette source of truth.** Extend the existing `ScratchLabDesignTokens` (currently macOS) into a shared module both targets consume. Notation stroke colors (`forward`, `backward`, `audioInferred`, `audioBurst`, `cut`, `fader`, `silence`) become semantic tokens, not literals.
- **Type system already exists** in `ScratchLabDesignTokens` (`pageTitle`, `cardHeading`, `body`, `chipLabel`, `statusPill`, monospaced metrics). iOS adopts it via a thin bridge.
- **Motion vocabulary** is small and consistent: a 60 Hz scroll for live notation (existing), a one-shot pulse on beat boundaries, an envelope-follower breathe on the action line, a brief flash on hit events. Nothing rotates. No bouncing. No emoji explosions.
- **Dark canvas, single-accent layering.** The existing canvas colors (black / controlBackground) hold. Each notation event class keeps its semantic hue (cyan forward, orange back, amber audio inferred, blue audio burst) but at consistent line weights and opacities across all three renderers.
- **DEBUG surfaces stay visually distinct** (e.g. dashed orange overlays) so promoted production surfaces don't accidentally look like debug overlays.

---

## 6. Gameplay-Loop Philosophy

The Phase A loop is:

```
Pick scratch → see your history with it → capture take → session-complete moment → see how it sits in your streak → run again or pick next
```

No XP. No unlocks. No currency. No leaderboards. No rivals. No leveling system beyond what `GameState.Level` already encodes. The "game" in *game feel* is satisfaction-per-loop, not progression-per-level. Everything that increases satisfaction per loop without changing what is detected, scored, or claimed is in scope; everything that adds new persistence layers or new earning mechanics is out of scope until Phase B.

---

## 7. Notation Philosophy

- **The captured notation is the truth.** Reaffirmed from PROFILE.md. Phase A surfaces (phrase glance, hit flashes, breathing playhead) decorate the notation; they never replace or override it.
- **Audio is preview-only.** Audio onsets and phrase summaries surface in Phase A only where they can be framed with the existing `(preview)` / "aren't saved, exported, or scored" language pattern.
- **Notation renderers are not rewritten in Phase A.** Existing renderers (`ScratchMotionLane`, `ScratchMotionRenderer`, `ScratchPhraseChartView`, `ScratchNotationCanvasView`, `NotationLaneGeometryView`) are routed through unified palette tokens but their geometry code is untouched.
- **Additive semantics preserved.** No new notation language. No new event classes. No schema changes.

---

## 8. Coaching Philosophy

- **One vocabulary, one place.** All user-facing strings (mode explainers, results headlines, preview disclaimers, honest-failure callouts, tutorial copy) flow through a `CoachCopy` namespace so a future App Store review pass audits one file, not seventeen Views.
- **Coach over critic.** A poor take gets "Try keeping the fader hand closer to the centre" — not "Accuracy 47%, fail."
- **Never invent a metric we don't have.** The copy describes what the app can see (motion presence, onset count, take length), not what it cannot (intent, technique correctness, musicality).
- **Honest-failure path is first-class.** When `GuidedCaptureMotionAssessment` indicates low motion or low audio onsets, the coaching surface acknowledges this directly instead of pretending success.

---

## 9. What ScratchLab is NOT (in Phase A and beyond)

- **Not a virtual turntable.** The DEBUG `VirtualPlatterPrototypeView` stays DEBUG.
- **Not a rhythm game.** No scoring of timing marks, no judgment lines that score hits as "Perfect / Great / Good / Miss".
- **Not an AI coach.** No surface uses the word "AI". No surface implies the app understands intent.
- **Not a multiplayer / social / online battle product.** `GameMode.onlineBattle` stays unimplemented in Phase A.
- **Not a marketplace, account system, or economy.** No login, no purchases, no XP store.
- **Not Serato.** No deck skeumorphism, no waveform-as-deck metaphor, no platter UI.
- **Not a music-theory teacher.** Coaching language stays about scratching motion, not musical concepts beyond beat alignment.
- **Not a session-history archive.** Phase A surfaces history that already exists in `ProgressManager`; it does not become a new long-term store-of-record.

---

## 10. Slice Breakdown

### Conventions

Each slice lists:
- **Purpose** — why this slice exists
- **User-visible outcome** — what changes for the user
- **Affected files/systems** — likely edit surface
- **Footprint** — XS (<100 LOC, 1 file) / S (100-300 LOC, 1-3 files) / M (300-700 LOC, 3-6 files) / L (700+ LOC, 6+ files)
- **Dependencies** — slices that must land first
- **App-Store risk** — None / Low / Moderate / High
- **Classification** — production-facing / DEBUG-only / additive / deferred-safe
- **Rollback complexity** — Trivial (revert one commit) / Low / Moderate
- **Test implications** — what verification looks like under `[[feedback_verification_scope]]` (iOS build + macOS build + macOS build-for-testing)

---

### SAFE BEFORE TESTFLIGHT

These ten slices form the minimum viable "feels like a game now" set. Each is independently rollback-safe.

---

#### A0 — Feature flag registry

- **Purpose**: Create a single `FeatureFlags` namespace so every subsequent Phase A slice can ship behind a flag (default-off in release, default-on in DEBUG, env-var-overridable). Eliminates the need to gate-by-`#if DEBUG` for every slice and gives a fast kill-switch if a polish surface misbehaves on TestFlight.
- **User-visible outcome**: None directly. Indirectly: every Phase A surface can be turned off without a code revert.
- **Affected files/systems**: New file `ScratchLab/Models/FeatureFlags.swift` (shared). Pattern lifted from existing `ProgressManager.gameCenterFeatureEnabled` env-var gate (`ProgressManager.swift:54-60`).
- **Footprint**: XS
- **Dependencies**: None.
- **App-Store risk**: None.
- **Classification**: production-facing infrastructure, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: Verify env-var override path via `xcrun xctest` micro-test; iOS+macOS build pass.

---

#### A1 — Notation palette consolidation

- **Purpose**: Eliminate the three competing notation palettes (`ScratchLabDesignTokens` macOS, `ScratchMotionLane.swift:133-144` iOS-local, `ScratchNotationCanvasView` lines 42-50 local). Establish one semantic token enum that all renderers read from.
- **User-visible outcome**: iOS notation lane stroke colors now match macOS notation chart stroke colors. Demo/copy accent reconciliation. Subtle but a tester *will* notice.
- **Affected files/systems**: Promote `ScratchLabDesignTokens` (or its color surface) into a shared module; update `ScratchMotionLane.swift`, `ScratchMotionRenderer.swift`, `ScratchPhraseChartView.swift`, `ScratchNotationCanvasView.swift`, `NotationLaneGeometryView.swift` to read from it. Pure refactor.
- **Footprint**: S (3-5 files, mostly literal→token swaps).
- **Dependencies**: None.
- **App-Store risk**: None.
- **Classification**: production-facing, additive in spirit (deterministic refactor).
- **Rollback complexity**: Trivial.
- **Test implications**: Snapshot comparison is not realistic; verify by iOS+macOS build and a single visual check on the simulator. No XCTest needed for color tokens.

---

#### A2 — CoachCopy namespace extraction

- **Purpose**: Pull every user-facing coaching/preview/results string into one `CoachCopy` enum/namespace. Single source of truth for the App-Store-safety vocabulary audit. **This slice is the single largest insurance policy in Phase A** — every later slice that adds new copy plugs into this namespace, so the vocabulary stays auditable.
- **User-visible outcome**: None for existing copy (verbatim move). All future slices add their copy here.
- **Affected files/systems**: New `ScratchLab/Models/Coaching/CoachCopy.swift`. Lift literals from `PracticeModeView.swift:2613-2642` (`PracticeTimingPreviewCard`), `PracticeModeView.swift:28-46` (`PracticeAssistMode.explainer`), `PracticeModeView.swift:2480-2579` (`ResultsOverlayView` headlines/labels), `PracticeModeView.swift:1335-1339` (`currentTipText`).
- **Footprint**: S (1 new file, 3-4 callsite swaps; verbatim string moves only).
- **Dependencies**: None.
- **App-Store risk**: Low (touching copy is always a small risk; verbatim move minimizes it).
- **Classification**: production-facing, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: A single PROFILE.md vocabulary lint test in `Tools/TrainModels` style is optional but desirable — verify no banned phrase appears in `CoachCopy`. Otherwise iOS+macOS build.

---

#### A3 — Streak chip on level select

- **Purpose**: Surface `ProgressManager.currentStreak` and `lastPracticeDate` (`ProgressManager.swift:29-30`) on the level-select entry surface. Lowest-cost progression cue.
- **User-visible outcome**: Small chip near the top of level select reading "Day 3" / "Start a streak" with a subtle accent. Reads honestly: it's literally the streak the model has been tracking all along.
- **Affected files/systems**: `LevelSelectView.swift` (one chip view, ~50 LOC). Copy via `CoachCopy` (A2).
- **Footprint**: XS
- **Dependencies**: A0 (flag), A1 (palette), A2 (copy).
- **App-Store risk**: None.
- **Classification**: production-facing, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build only.

---

#### A4 — Per-scratch progress badge

- **Purpose**: Surface `ScratchProgress.bestAccuracy`, `practiceCount`, `isMastered` (`ProgressManager.swift:21-24`) on each scratch card in level select. Already tracked, never shown.
- **User-visible outcome**: Each scratch card shows "Best 78% · 12 takes" or "Mastered ⭐" (no emoji unless approved — use the existing star-icon system). Cards with no history show nothing (no zeros).
- **Affected files/systems**: `LevelSelectView.swift` card subview; `CoachCopy` for label formatters.
- **Footprint**: XS-S
- **Dependencies**: A0, A1, A2.
- **App-Store risk**: None.
- **Classification**: production-facing, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build; quick simulator scroll-through to verify cards render with and without history.

---

#### A5 — Last-N sessions strip on level select

- **Purpose**: Surface `ProgressManager.sessionHistory` (last 100, already persisted in UserDefaults per `ProgressManager.swift:33`, `:191-193`). A horizontal strip of the most recent 5 sessions: scratch name + accuracy chip + timestamp.
- **User-visible outcome**: A "Recent" row at the top of level select. Taps go nowhere in Phase A (or scroll the card stack to that scratch). Each entry honest: just the existing `SessionResult` data.
- **Affected files/systems**: `LevelSelectView.swift` (new row), `ProgressManager` (read-only access already public).
- **Footprint**: S
- **Dependencies**: A0, A1, A2.
- **App-Store risk**: None.
- **Classification**: production-facing, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build; verify empty-state copy ("Capture a take to see your history") routes through CoachCopy.

---

#### A6 — Beat-pulse on notation playhead

- **Purpose**: First "screen reacts to me" moment. On each beat boundary (subscribed to existing beat clock used by `LaneClock` in `ScratchMotionLane`), the action line emits a one-shot 120ms pulse: opacity 0.6→1.0→0.6, line weight unchanged. Pure visual; no data dependency.
- **User-visible outcome**: When a beat-driven Practice mode is running, the action line "ticks" with the beat. Silent under Open mode without beat (no beat = no pulse). Honest.
- **Affected files/systems**: `ScratchMotionLane.swift` (subscribe to beat clock; add pulse modifier). New `BeatPulseModifier` view if useful.
- **Footprint**: XS-S (~100 LOC)
- **Dependencies**: A0 (gate behind `FeatureFlags.beatPulseEnabled`), A1.
- **App-Store risk**: None.
- **Classification**: production-facing, additive, deferred-safe (kill via flag).
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build; manual simulator check with a beat-driven Practice mode.

---

#### A7 — Input-level breathing on action line

- **Purpose**: Second "screen reacts to me" moment. Subscribe action-line amplitude (within ±2pt) to `AudioEngine.inputLevel` (`AudioEngine.swift:68`). Works in *all* Practice modes regardless of beat. Strong perceptual payoff for low cost.
- **User-visible outcome**: When mic input is present, the action line gently breathes. When silent, it's still. Tester immediately understands the app is listening.
- **Affected files/systems**: `ScratchMotionLane.swift` (subscribe to `inputLevel` publisher; map to amplitude with a critically-damped low-pass to prevent jitter).
- **Footprint**: XS-S (~80 LOC).
- **Dependencies**: A0, A1.
- **App-Store risk**: None (subscribes to existing input pipeline; no new mic usage).
- **Classification**: production-facing, additive, deferred-safe.
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build; manual simulator + device check with audible input.

---

#### A8 — Session-complete cinematic pass

- **Purpose**: Reshape `ResultsOverlayView` (`PracticeModeView.swift:2480-2579`) into a deliberate moment. Same data, sequenced reveal: title card (scratch name, take number) fades in → stats grid counts up over ~500ms → CTAs fade in last. No new data, no new metrics.
- **User-visible outcome**: Finishing a take feels intentional rather than abrupt.
- **Affected files/systems**: `PracticeModeView.swift` (`ResultsOverlayView` only); copy via `CoachCopy`; tokens via shared palette.
- **Footprint**: S (~200 LOC).
- **Dependencies**: A0, A1, A2.
- **App-Store risk**: None (no new claims; just reveal sequencing).
- **Classification**: production-facing, additive (animation only).
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build; manual end-to-end take to confirm reveal cadence is < 1s total and doesn't block the CTAs.

---

#### A9 — Honest-failure callout in results

- **Purpose**: When `GuidedCaptureMotionAssessment` (`CaptureCore.swift:476-497`) indicates low motion presence or `audioOnsetReviewMarks` is sparse, surface a one-line callout in `ResultsOverlayView`: "Couldn't see much movement on this take — try keeping the fader hand closer to the centre." Copy strictly from `CoachCopy`. No accuracy change.
- **User-visible outcome**: Tough takes get a friendly, specific next-step prompt instead of a generic "Keep practicing".
- **Affected files/systems**: `PracticeModeView.swift` (results overlay condition + new sub-card); `CoachCopy.swift` (new entries audited against PROFILE.md vocabulary).
- **Footprint**: S (~150 LOC including all copy variants for the small handful of failure shapes).
- **Dependencies**: A0, A1, A2, A8.
- **App-Store risk**: Low (any new copy is risk; mitigated by A2 funneling through one auditable file).
- **Classification**: production-facing, additive.
- **Rollback complexity**: Trivial.
- **Test implications**: iOS build + a deliberate "silent take" capture to confirm the callout fires.

---

### DEFER UNTIL AFTER TESTFLIGHT

These nine slices add richer game-feel but each carries either a higher footprint, more App-Store-copy surface area, or a dependency on a system that needs more bake time. They are scoped here for planning awareness only.

---

#### B1 — Stroke approach glow

- Subtle leading-edge glow on strokes within ~200ms of the action line.
- Footprint: S. Risk: None. Defer because A6+A7 are likely enough motion polish for TestFlight; B1 is taste-tuning.

#### B2 — Hit confirmation flash

- 80ms flash on the action line when a stroke crosses it during capture.
- Footprint: S. Risk: Low (timing semantics must not imply scoring). Defer until A6/A7 land and we can tune flash vs. pulse interference.

#### B3 — Phrase-glance card in session results

- Show a small static `ScratchPhraseChartView` of the take inside `ResultsOverlayView`, framed "Your take".
- Footprint: S. Risk: Low (needs preview language). Defer to give phrase grouping foundation more bake time first.

#### B4 — NotationLab cosmetic polish (macOS)

- Route `NotationVisualizerView` through unified tokens; refine playhead, scrub affordance.
- Footprint: S-M. Risk: None. Defer because NotationLab is macOS-only and not on the TestFlight critical path.

#### B5 — NotationLab phrase overlay (promoted from DEBUG)

- Promote the `DebugNotationLaneHostView` phrase overlay (`DebugNotationLaneHostView.swift:150-195`) into a styled production overlay inside NotationLab review.
- Footprint: S. Risk: Moderate (must wear preview/uncertain language). Defer because it's macOS-side and depends on phrase grouping being declared production-ready.

#### B6 — Audio-onset spark on live lane

- Brief hairline at the playhead each time an audio onset fires (`audioOnsetReviewMarks`).
- Footprint: S. Risk: Moderate (introduces a live "preview" signal during capture; needs labeling). Defer to give the onset pipeline more in-field validation.

#### B7 — Tutorial mode (populate `GameMode.tutorial`)

- Three-step tutorial: scratch shape → timing → capture. Uses existing notation playback.
- Footprint: M. Risk: Moderate (new copy surface). Defer because tutorial copy benefits from real TestFlight feedback first.

#### B8 — Combo challenge framing (Baby Flow)

- Wrap the existing `ComboScratch` Baby Flow in a "Challenge" entry-point with explicit accept/complete framing.
- Footprint: S-M. Risk: Low. Defer because the Practice loop with A3-A9 already provides a clear product story for TestFlight.

#### B9 — Per-session detail screen (tap a Recent strip entry)

- Land on a screen that shows the captured notation snapshot for that session.
- Footprint: M. Risk: Low. Defer because reading existing data into a new surface is a small but real testing surface increase.

---

## Recommended Implementation Order

Strict dependency-honouring order:

1. **A0 — Feature flag registry** (foundational)
2. **A1 — Palette consolidation** (everything visual reads from it)
3. **A2 — CoachCopy namespace** (everything verbal reads from it)
4. **A3 — Streak chip** (smallest progression surface, validates A2 plumbing)
5. **A4 — Per-scratch progress badge**
6. **A5 — Last-N sessions strip**
7. **A6 — Beat-pulse on playhead**
8. **A7 — Input-level breathing**
9. **A8 — Session-complete cinematic pass**
10. **A9 — Honest-failure callout**

Order rationale: foundations first (A0, A1, A2) so every later slice consumes them; progression surfaces (A3-A5) next because they exercise A2 and produce the highest perceived-game-feel-per-LOC; motion polish (A6, A7) next because they're the most likely "wow" moment for a tester; session-complete (A8, A9) last because they sit at the *end* of the loop and benefit from all prior visual polish being already-shipped.

---

## A. Minimum Viable "Feels Like a Game Now" Milestone

The minimum perceptual threshold is reached when **all ten slices A0-A9 ship behind their feature flags, default-on in release**. A first-time tester then sees: a consistent palette, their streak, per-scratch history, a recent-sessions strip, a breathing/pulsing notation lane during capture, a sequenced session-complete moment with honest stats, and a friendly callout when a take didn't capture cleanly. None of those involve new detection, new ML, or new claims.

If aggressive cuts are needed, the **absolute minimum** is: **A0 + A1 + A2 + A5 + A7 + A8**. Six slices. That delivers (1) unified look, (2) one recent-sessions surface for progression, (3) breathing action line for live reactivity, (4) sequenced session completion. The other four are accelerants.

---

## B. Estimated Slice Count

- **Pre-TestFlight (Phase A core)**: **10 slices** (A0-A9)
- **Post-TestFlight (Phase A tail)**: **9 slices** (B1-B9)
- **Phase A total**: **19 slices**

Each pre-TestFlight slice is XS or S. Total Phase A core footprint estimated at ~1500-2500 LOC additive, ~300 LOC moved/refactored. No file deletions. No schema changes. No model changes.

---

## C. Recommended First Implementation Slice

**A0 — Feature flag registry.**

Reasons:
- Zero risk, zero user-visible surface, ~50 LOC.
- Establishes the kill-switch pattern every subsequent slice plugs into. Without it, the first time a polish surface misbehaves on TestFlight, the only options are a code revert or a hard ship-blocker.
- Pattern already exists in the codebase (`ProgressManager.gameCenterFeatureEnabled`), so this is normalising-an-existing-shape rather than introducing-a-new-shape.
- It unblocks A1 and A2 to be merged independently of each other without coordination.

---

## D. Recommended Freeze Boundary Before TestFlight

**Freeze at end of A9.** Cut a `release/testflight-2` branch from `release/testflight-1` after A9 merges. From that point until TestFlight submission: **no further Phase A slices, no B-series slices, no copy edits**. Only:

- bug fixes to A0-A9
- crash fixes
- regression fixes surfaced by the build pipeline (iOS build + macOS build + macOS build-for-testing per `[[feedback_verification_scope]]`)
- copy fixes for PROFILE.md violations spotted in review

B-series slices land on `main` post-freeze and ship in the *next* TestFlight build, not this one. This protects the App Store submission cycle from being re-opened by polish-tuning churn.

Concrete trigger: as soon as A9 builds clean on iOS + macOS + macOS build-for-testing and a manual end-to-end take exercises the full A0-A9 path, cut the branch.

---

## E. Biggest Danger to Avoid During Phase A

**Scope creep into ML, detection, or scoring under the cover of "game feel".**

The most likely failure mode: a polish slice (e.g. hit-confirmation flash, audio-onset spark, honest-failure callout) starts pulling in "let's also use the classifier here", "let's also surface confidence here", "let's also tie this to a score". Every such pull is a one-way door — once a polish surface reads a detection signal as truth, the App Store risk profile changes and the PROFILE.md honesty contract has to be re-examined.

**Mitigation rules for Phase A:**
1. No slice reads from `MLClassifier*` outputs except via signals already declared `(preview)` and routed through `CoachCopy`.
2. No slice introduces a new `(preview)` surface; only A9 inherits the existing pattern.
3. No slice changes `SessionExportCoordinator` or `scratchlab_session_export_v4`.
4. No slice persists anything that isn't already persisted by `ProgressManager` today.
5. Every new copy string lands in `CoachCopy.swift` and is vocabulary-checked against PROFILE.md.
6. If a slice grows beyond its declared footprint, stop, ship what's done, file the overflow as a new slice.

Second-tier dangers to flag explicitly:
- **Animation thrash on lower-end hardware.** A6, A7 must use critically-damped envelopes and `withAnimation(.easeOut(duration:))` not spring physics, to avoid CPU spikes.
- **Notation regressions from palette refactor (A1).** Bench against a known-good capture from `release/testflight-1` before merge.
- **Strings drifting back into Views.** Any reviewer of a Phase A PR should reject inline strings as a hard rule.

---

## Verification

Per `[[feedback_verification_scope]]`, the verification gate for each Phase A slice is:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` clean.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'generic/platform=macOS'` clean.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'generic/platform=macOS'` clean.
4. Manual simulator walk-through of the affected user flow.
5. For A2, A9 specifically: grep `CoachCopy.swift` against the PROFILE.md banned-phrase list ("AI detects", "deep learning", "real-time AI", "perfectly detects").

`xcodebuild test` is *not* part of the standard gate per project memory — XCTest hangs at test-host launch on this project. Where targeted XCTest is desired, use `xcrun xctest` with DOT-separator selectors (per `[[project_test_runner_hang]]`).

End-to-end exit criterion before requesting TestFlight: a fresh-launch capture session on iOS that exercises level-select progression surfaces (A3, A4, A5), the live lane motion polish (A6, A7), and the session-complete flow (A8, A9), all reading from feature flags (A0) and routing every string through `CoachCopy` (A2) and every notation color through the unified palette (A1).
