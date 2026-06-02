# TTM Execution Plan v2 (video-grounded)

Status: **PLAN ONLY — do not implement, do not commit.**
Date: 2026-05-31
Author basis: second-pass, video/audio/artwork-grounded TTM audit (`analysis/ttm_video_audit/` + `analysis/ttm_video_audit/v2_evidence/`), validated against the actual ScratchLab source tree.

---

## 0. Purpose

This document decides the **implementation order** for TTM-informed notation work and resolves the conflict between the older planning lineage and the new video-grounded findings. It is a roadmap, not a spec to be typed in. No code, no schema, no commits result from this file.

---

## 1. The decision (read this first)

1. **The older "family / interpreter first" lineage is superseded for implementation order.**
   The planning docs in `docs/planning/` (`notation_truth_spec*.md`, `notation_phase_b.md`, `coaching_phase_c.md`, `replay_phase_d.md`, `instructor_phase_e.md`, `spatial_phase_f.md`) remain valid as *vision and vocabulary*, but their sequencing — which leads with family/technique classification and a semantic interpreter — is **demoted**. They are no longer the order of work.

2. **The video-grounded TTM v2 audit controls the next roadmap.** Where v1/older docs and v2 disagree, v2 (frame + audio evidence) wins. The corrections in §3 are binding.

3. **First coding work = pure notation primitives + invariants** (pure value types + unit tests, no UI, no export, no capture changes). See §6 and §7.

4. **Family/technique classification comes later**, and only as a *labelling layer over evidence we can already measure*, never as captured truth. See §8 Phase 4+.

Rationale: the single most important v2 finding is that **a scratch's identity is not recoverable from audio alone** (a 2-click flare and a transform are "soundalikes"; identity depends on fader-closure *width* and on whether a sound boundary came from the *fader* or the *hand*). Therefore classification-first is building on sand. The honest, durable foundation is a primitive model of *boundaries and slices* that we can derive from capture and verify with invariants. Classification is a hat we put on later.

---

## 2. Evidence base (what this plan stands on)

- **TTM v2 video evidence**: `analysis/ttm_video_audit/v2_evidence/agent_{A..E}_*.md` (frame + audio + transcript, per-video, with verdicts).
- **TTM v1 audit** (transcript-led): `analysis/ttm_video_audit/*.md` — kept, but corrected by v2.
- **Source ground truth** (read this pass, current `release/testflight-1`):
  - `ScratchLabDesktop/Models/ScratchSampleTimeline.swift` — absolute sample position, **no renormalization**; crossfader closure = binary `muted` flag; export schema **v1**.
  - `ScratchLabDesktop/Models/ScratchSampleTimelineNotation.swift` — captured→`MotionPath`, preserves absolute travel, collapses `mutedSpans`.
  - `ScratchLab/Models/ScratchStrokeGeometry.swift` — `motionPath(for:)` **DOES normalize** authored strokes to 0…1 (target/demo path; deliberately the opposite of the captured adapter).
  - `ScratchLab/Models/Notation/Grammar/NotationPrimitive.swift` — only `DirectionSegment`, `Reversal(cusp|round)`, `IdleHold`. **No** click placement, click groups, per-half grouping, tears, or sound slices.
  - `ScratchLab/Models/Notation/Semantics/ScratchFamily.swift` — cases: `baby, scribble, chirp, flare, transform, tear, orbit, crab, unknown`. Product-facing = `baby` + `unknown`; rest research-only.
  - `ScratchLab/Models/Notation/Coaching/*` — drift (late/early reversal), phrase stability, completeness. **No** fader/click/slice coaching.
  - `ScratchLab/Models/CaptureCore.swift` — `ScratchFaderEventKind { open, closed, cut, pulse, transformPulse, flareClick, unknown }`; each event already carries `startTime…endTime` ⇒ **closure width is already representable** (do not throw this away).
  - `ScratchLab/Models/SessionReplayTimeline.swift` — 4 lanes (`audioOnset, recordMovement, fader, mixerMidi`), schema **v1**.
  - `ScratchLab/Services/SessionExportCoordinator.swift` — session export schema **v4** (`scratchlab_session_export_v4`); notation/timing-marks **not exported**.
  - `ScratchLab/Models/ControllerInput/ControllerProfile.swift` — **only RANE ONE MKII** verified (platter CC6 relative, 3932 steps/rev; crossfader CC8 absolute). DDJ-GRV6 has **no** profile (tested as unrecognized). *Flagged inconsistency vs project memory — see §11.*
  - Confirmed **absent** in tree today: any `ClickPlacement`, `TechniqueTemplate`, `SoundSlice`, or TTM code. The v1 roadmap was never implemented.

---

## 3. What v2 changed (binding corrections to v1 / older docs)

| # | v1 / older claim | v2 video-grounded correction |
|---|---|---|
| C1 | Wave shape "implied"; triangle acceptable shorthand. | **Default motion glyph is a curved bell, not a triangle.** 059 contrasts "Analog Reverse Switch" (smooth arc = the baby scratch) vs "Digital Rev. Switch Toggles" (triangle = what it is *not*). Triangle = idealized/digital artifact. |
| C2 | Notation ≈ a motion curve + a fader lane. | **Notation is a gantry/loom diagram**: title; a **multi-rail click "staff"** carrying dots (separate from motion); twin platter-ring anchors at A/B; a thick motion curve hanging beneath on a grid; a **sweeping blue vertical playhead**. Orientation: **time horizontal, position vertical.** |
| C3 | Clicks are dots; one state. | **Two glyph states: hollow = fader open, filled = click (off instant).** Clicks ride the staff; slice-nodes also mark the curve at click positions. |
| C4 | Click = event time. | **Click = fraction of stroke travel** (25 / 50 / 75 / thirds 33·66), **pitch-invariant**. Same-count scratches differ only by placement and per-half grouping (the "seven 2-click variations"). |
| C5 | Tear ≈ a kind of click / fader thing. | **Tear = motion-origin boundary** (intra-stroke platter stop, fader stays open, same direction continues) → drawn as a **step/discontinuity in the curve**. Click = **fader-origin boundary** → dot on an intact curve. Verbatim (054): *"clicks are with the fader and tears are with your hand on the record … clicks are sharper, tears are smoother."* |
| C6 | Sound counts are per-technique trivia. | **Generative law:** `sounds = clicks + tears + 2` (the +2 = the two base out/back strokes; every fader OR motion boundary splits its stroke into one more piece). Verified with zero exceptions across 052 (1+1+2=4), 056 (3+1+2=6), 053 (1+3+2=6), 055 (3+2+2=7), 054 (3+3+2=8). Symmetric orbit special case: `sounds = clicks + 2` (6-click→14, 4-click→10 confirmed). |
| C7 | Transform vs flare ≈ click count / brief vs long. | **Discriminator is closure WIDTH, not count.** Flare = brief "kiss" closures (legato couplets); transform = wide flat gated rests ("da-da-da"). A slowed even 2-click flare = a **transform soundalike** ⇒ **audio alone cannot determine family.** |
| C8 | "Swirl"/ornaments are fader figures. | **Swirl = 0-click, pure-motion figure** (071 legend: "Swirl Tear … 0 Clicks / 3 Sounds per cycle"). Sound sources are **motion and fader independently**. |
| C9 | 047 is the rich on-screen notation source. | **047's burned-in "notation" is a Patreon paywall promo**, not per-cut labels. The real glyph dictionary is the **PMØS_100 app cells** (044) + the **overlay cards** (002/071). 047's value is the *spoken* click-fraction system. |
| C10 | "Periodic Matrix" = loose vocabulary list. | It is a literal **periodic-table grid**: axes ≈ **family/mechanism × complexity (click-density)**; each cell = name + a **mini motion-contour glyph with click dots**. It is a *sampler instrument*, not a capture/transcription tool — complementary to ScratchLab, not a competitor. |

---

## 4. Conflict resolution (older lineage vs v2)

**Superseded for ordering (not deleted):**
- "Interpreter/semantics first" framing in `notation_truth_spec*.md` and the phase letters (`*_phase_b/c/d/e/f`). Their *content* (truthful position, replay, coaching vocabulary, spatial ideas) is reused; their *position in the queue* is replaced by §8.

**Now governing:**
- **Truthfulness invariants** (already real in `ScratchSampleTimeline` / `ScratchSampleTimelineNotation`) stay canonical and untouched.
- **v2 primitive model** (boundaries → slices → fractional clicks → groups) is the new first build target.
- **Family classification** is re-scoped from "the goal" to "an optional label over measured boundaries," gated behind real capture/review validation and `PROFILE.md` claim rules.

**Non-negotiable separation (carried from older truth spec, reaffirmed):**
captured ≠ interpreted ≠ target. Captured timeline is source of truth; primitives are derived; TTM templates are target/education only and must never be drawn as, scored as, or exported as captured evidence.

---

## 5. Design principles / invariants we will not violate

1. **No renormalization of captured position.** `ScratchSampleTimeline` and `ScratchSampleTimelineNotation` remain absolute. New primitives derive from them read-only.
2. **Authored/target geometry may normalize** (that is what `ScratchStrokeGeometry` is for) but is always labelled `target`.
3. **Two boundary origins are first-class and distinct**: `faderBoundary` (crossfader closure) vs `motionBoundary` (tear/stop) vs `reversalBoundary` (direction change). A sound slice is bounded by any of these.
4. **Closure has width.** Reuse the existing `startTime…endTime` on fader events; never collapse a transform's wide closure into a flare's instant.
5. **Fractions are pitch-invariant and validated** (finite, clamped to 0…1).
6. **No fader dots without fader evidence.** If capture lacks crossfader data, the click lane is empty, not inferred.
7. **Audio is corroboration, not classification.** Sound-count law is used to *check* a structural reading, not to *name* the scratch.
8. **App-Store-safe language** everywhere user-facing: `estimated / preview / uncertain / on-device analysis`; never "AI detects exactly".

---

## 6. The new data model (pure, additive, no I/O) — design targets only

All of these are **pure value types** in a new isolated module (e.g. `ScratchLab/Models/Notation/Grammar/` siblings); **no** changes to capture, export, replay, coaching, or families in this layer.

- `StrokeBoundary`
  - `origin: .fader | .motion | .reversal`
  - `fraction: ClosedRange<Double>` position(s) within the parent stroke (0…1)
  - `width: Duration?` (instant for clicks; span for transform closures; nil/− for motion)
- `ClickPlacement`
  - `fraction: Double` (0…1, validated)
  - `role: .middle(.5) | .low(.25) | .high(.75) | .third | .custom`
  - `feel: .even | .burst | .triplet | .custom`
- `ClickGroup`
  - `half: .forward | .backward | .both | .sequence(index)`
  - ordered `[ClickPlacement]`
  - projects to times **only** when given a concrete stroke span (captured or target).
- `SoundSlice` (derived, non-persisted)
  - bounded by ordered `StrokeBoundary`s; carries `source: .faderCut | .motionTear | .reversal`.
- `TechniqueTemplate` (TARGET only, research-flagged) — deferred to Phase 3+, not Phase 1.

These map cleanly onto existing primitives: `DirectionSegment`→stroke span, `Reversal`→`reversalBoundary`, `IdleHold`→candidate `motionBoundary` (tear), `ScratchFaderEventKind`→`faderBoundary` with width.

---

## 7. Invariants → first test suite (the real Phase 1 deliverable)

These become deterministic unit tests *before* any model is wired to UI:

- **I1 Slice law:** for any sequence, `slices == clicks + tears + 2` per out-and-back; symmetric-orbit reduces to `clicks + 2`. (Table-test all of 052–056 and 6C/4C orbit.)
- **I2 Per-stroke split:** `N` boundaries on one stroke ⇒ `N+1` slices on that stroke.
- **I3 Fraction validity:** placements finite, within 0…1; `.middle`=0.5, `.low`=0.25, `.high`=0.75, thirds={0.33…,0.66…} within tolerance.
- **I4 Pitch invariance:** scaling stroke span leaves fractions and slice counts unchanged.
- **I5 Origin integrity:** a slice's `source` is preserved end-to-end; a fader closure of width > τ is never relabelled as an instant click and vice-versa.
- **I6 Capture non-mutation:** deriving primitives/slices does not alter `ScratchSampleTimeline` positions (golden-sample byte/position check).
- **I7 No-evidence-no-dots:** with crossfader data absent, click lane and fader boundaries are empty.
- **I8 Determinism:** same input ⇒ identical primitive/slice output (Codable round-trip if persisted later).

---

## 8. Implementation order (slices)

> Each slice = small diff + tests. Stop and re-evaluate after each. Nothing here touches export schema, signing, resources, Practice/scoring, or production copy.

**Phase 1 — Pure primitives + invariants (FIRST WORK).**
Add the §6 value types (excluding `TechniqueTemplate`) and the §7 test suite. No UI, no export, no capture edit, no family change. Done = all I1–I8 green.

**Phase 2 — Derivation from captured evidence.**
Derive `StrokeBoundary` / `SoundSlice` from existing `MotionPath` + `ScratchFaderEventKind` spans (read-only adapter, sibling to `ScratchSampleTimelineNotation`). Tear candidates from `IdleHold`/velocity minima, clearly marked low-confidence. Tests: real-capture fixtures reproduce expected slice counts; motion- vs fader-origin correctly attributed.

**Phase 3 — Educational renderer (gantry model), Advanced/DEBUG only.**
ScratchLab-native recreation (NOT a copy of TTM art) of the gantry: title, multi-rail click staff with **hollow=open / filled=click**, twin anchors, hanging curve on grid, sweeping playhead. Two explicitly labelled layers: `captured` (absolute, never normalized) and `target` (may normalize via `ScratchStrokeGeometry`). Add `TechniqueTemplate` here as target-only fixtures (baby, chirp, 1C flare, 2C-triplet flare, 3TC vs 3C orbit). Tests: captured layer never renormalized; no dots without evidence; layer-role labels present.

**Phase 4 — Evidence-bound coaching (behind flag).**
New evaluators alongside existing ones (do not modify drift/phrase): cut-to-reversal alignment (chirp), click-fraction error (flare/orbit), slice-count mismatch (motion vs fader origin shown separately). Fires only where evidence exists; `estimated/preview` copy. Tests: silent when evidence absent; never scores audio-onset preview as truth.

**Phase 5 — Family/technique classification (LAST, optional).**
Only now attach `ScratchFamily`/templates as *labels over measured slices*, explicitly research-only, never in Practice/Review truth, never exported as captured. Hard rule from C7/§5.7: **never classify family from audio alone.**

**Phase 6 — Export sidecar (deferred until 1–5 proven).**
Additive, versioned `notation_semantics_v1.json` sidecar only; existing `v4` session export and `v1` replay byte-contracts unchanged; captured truth and target templates as separate top-level sections.

---

## 9. Explicit non-goals / guardrails for this roadmap

- Do **not** change export schema (`v4`) or replay schema (`v1`) before Phase 6.
- Do **not** modify Practice, scoring, or existing coaching evaluators while adding new ones.
- Do **not** touch signing, bundle IDs, entitlements, `Info.plist`, `PrivacyInfo.xcprivacy`, or `Copy Bundle Resources`.
- Do **not** bundle or copy any TTM video frame, audio, artwork, or the PMØS app UI/audio. Recreate concepts originally.
- Do **not** train on or bundle YouTube/Ortofon material.
- Do **not** widen user-facing family vocabulary beyond `baby`/`unknown` until validated.

---

## 10. Risks

- **R1 Renormalization leak:** the educational renderer (Phase 3) sits near `ScratchStrokeGeometry` which normalizes. Mitigation: hard test I6 + separate captured vs target code paths.
- **R2 Tear false positives:** camera/jitter velocity minima misread as tears. Mitigation: low-confidence flagging; tears require a sustained stop, not noise.
- **R3 Overclaiming:** classification (Phase 5) leaking into Review/Practice or copy. Mitigation: research-only gates + §5.8 language rules + C7 audio-alone prohibition.
- **R4 Schema churn:** persisting fractions too early. Mitigation: pure in-memory until Phase 6 sidecar.
- **R5 Scope creep back to "family first":** Mitigation: this document; Phase 5 is gated on Phases 1–4.

---

## 11. Open questions to resolve with real capture (not more video)

- **Q1** Can crossfader closure *width* be reliably distinguished from instant clicks on the RANE CC8 stream at battle speed? (Determines transform vs flare detectability — see C7.) 
- **Q2** Tear detection threshold τ from real platter captures (CC6 / 3932 steps-rev) — what dwell counts as a motion boundary vs a slow reversal?
- **Q3** Controller coverage: code ships **only RANE ONE MKII**; project memory claims DDJ-GRV6 maps were verified. **Inconsistency to reconcile** before any orbit/transform coaching is promised on GRV6 hardware.
- **Q4** Does audio-onset preview corroborate the §7 slice law on real ScratchLab captures (sanity check, not scoring)?

---

## 12. Pointers

- Evidence: `analysis/ttm_video_audit/v2_evidence/agent_{A,B,C,D,E}_*.md`
- v1 audit (corrected): `analysis/ttm_video_audit/`
- Superseded-for-ordering lineage: `docs/planning/notation_truth_spec*.md`, `docs/planning/notation_phase_b.md`, `coaching_phase_c.md`, `replay_phase_d.md`, `instructor_phase_e.md`, `spatial_phase_f.md`
- Source anchors: see §2.

**Next action when coding resumes:** Phase 1 only — add §6 pure types + §7 invariant tests. Nothing else.
