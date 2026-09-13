
# ScratchLab – AI Context

## Current user direction — 13 September 2026

The learner app should be free. Assess direct sponsorship and institutional funding first, with ads as a possible supplement; do not require pilot learners to pay to continue. Finish current CXL fixes and a small teaching set, then one complete three-skill learner experience on a verified setup and a four-week trial with roughly ten target learners. Evaluate independent setup, repeat practice, expert-reviewed improvement and actual payer demand from sponsors/institutions. See docs/free_learner_pilot.md.

Watch capture is optional CXL research only where it can answer a useful current/future wrist-motion question; it is not a learner dependency. Live battles, private avatars and automatic live judging are deferred in docs/future_product_ideas.md. These decisions do not implement monetisation, remove existing runtime Watch routes, establish automated scoring, or supersede evidence-integrity checks. Claude's final capture handoff has been reviewed and integrated with the completed V2 library. The combined candidate adds preferred-repetition export, preserves earlier draft notes and routes CXL backing/count-in through the selected output. Software verification is complete and the signed combined CXL app is installed/opened; physical headphone/meter acceptance remains pending. See the current AI_HANDOFF.md and ScratchLab-CXL-Integration-20260913/evidence.

## Current CXL validation boundary — 2026-09-12

The active candidate is in `/Users/karlwatson/Developer/ScratchLab-CXL-Recovery-20260912/source`; the separately dirty Downloads checkout is preserved. The current repair replaces unrelated hardware-input activity in the main meter with actual generated scratch PCM peak and binds Rane ONE primary playback directly to verified USB3/4. Mac monitoring is optional and delayed. Input and output provenance remain distinct; the saved WAV is internal post-software-fader audio, not a verified physical mixer master return. Beats/count-in still use a separate system-default output and their Rane bus is not verified.

This is a diagnostic candidate, not ready for CXL production reference capture. Current targeted tests/Release verification are recorded in `../evidence/cxl-output-meter-20260912/RESULT.md` when complete. Full all-platform gate remains deferred; prior dates below do not establish this candidate's physical acceptance. Rane ONE MKII needs one no-beat movement capture, playback and export check; Seventy-Two plus Twelve needs its own output/input mapping and capture acceptance. On September12 the user explicitly authorized commits and pushes as needed; checkpoint verified source on a new codex branch without changing the dirty primary or committing captured media.

## Overview
ScratchLab is an Apple-platform application for DJ scratch training and high-quality data capture.

It is NOT just a practice app — it is a **data acquisition system** designed to:
1. Capture synchronized multi-device performance data
2. Attach structured metadata to each take
3. Export clean, validated datasets for machine learning and analysis

Supported platforms:
- iOS (primary capture + camera)
- Apple Watch (motion data)
- macOS (control surface + validation + export)

---

## What ScratchLab is — and is not

**ScratchLab is** a learn / visualize / analyze / improve platform for scratch DJing.

**ScratchLab is not:**
- Full DJ software.
- A deck-emulation platform (Serato / Traktor / rekordbox / Virtual DJ).
- A DAW or DAW replacement.
- An audio-engine showcase.

Every product decision is filtered through the first list. If a capability primarily makes ScratchLab feel more like the second list, it does not ship — even if it's individually cool.

---

## Virtual platter — what it is and isn't

**Scope of the virtual platter.** ScratchLab can render and drive a virtual platter for *teaching mechanics* (forward push, pull-back, hand position, timing windows, beat alignment). That platter alone is sufficient for **baby-scratch-class techniques** — single-deck push/pull with the fader implicitly open.

**What the virtual platter is not.** A platter without a crossfader is musically incomplete for techniques whose identity includes coordinated cuts, including chirps, transformers, flares, crabs and fader-cut orbits. Plain Tears are interrupted same-direction platter motion and may be performed with the fader open; their motion holds and any fader evidence remain independent. Scribbles are also platter-motion techniques unless a specific authored variant adds a fader pattern. Building deeper virtual-platter teaching for a cut-defined target without an honest crossfader produces a misleading surface where students can appear to succeed without learning the coordinated skill.

**Rule.** Any new virtual-platter capability must answer the question: *"does this give the student a true representation of the skill, or is it baby-scratch dressed up?"* If the answer is the second, build the crossfader pairing first.

**Anti-goal.** ScratchLab is not on a path to become a Serato-style DJ simulator. The platter is a teaching scaffold, not a deck emulator.

---

## Crossfader training & coach-assisted scratching

The crossfader is the second half of every non-trivial scratch. ScratchLab introduces a coordinated crossfader teaching layer with progressive assistance.

### Modes (ordered by autonomy given to the learner)

1. **Auto-cut (beginner).** ScratchLab plays the crossfader for the student in time with the target notation. Student focuses purely on hand motion on the platter. Used for first-week chirp/transform exposure.
2. **Guided cut (intermediate).** ScratchLab visualizes the *expected* cut window in the notation (open / closed bars on the fader lane) and beeps / flashes a cue at each cut. Student is responsible for executing the cut, but the timing target is unambiguous.
3. **Coached cut (advanced).** No visual cue overlay; ScratchLab still scores cut timing against the target notation in the background and surfaces it post-take in Review. Equivalent to the current Practice → Review loop, applied to fader events.
4. **Open practice.** No assistance, no scoring overlay. The notation captures whatever the student plays — used for free-improvisation takes and recital recording.

### What the crossfader system teaches (and what it doesn't)

- It teaches **timing**, **coordination with hand motion**, and **reading notation**.
- It does **not** play the cuts for the student in any mode beyond *auto-cut*, and even there the assistance is visible (the student can see that ScratchLab moved the fader).
- It does **not** simulate the physical haptics of a real crossfader. Real-fader users plug in a real controller; the virtual fader is a teaching scaffold, identical in spirit to the virtual platter.

### Required surfaces

- **Crossfader lane** in the notation chart (open / closed bars, cut markers, transformer pulse markers — already partly modeled).
- **Mode picker** in Practice (Auto-cut / Guided / Coached / Open).
- **Score / feedback** in Review for cut timing (separate from stroke timing, surfaced when the take used Guided or Coached mode).
- **Coach copy** that names what each mode does plainly: *"Auto-cut: ScratchLab plays the fader for you. Watch how cuts line up with your scratches."*

### Naming

Call this collectively the **"coach-assisted scratching"** layer when speaking about it externally. Internally the term **"assist mode"** is fine.

---

## System Architecture

### Core Principle
All platforms must share a **single source of truth** for:
- session configuration
- metadata
- validation rules
- export structure

Current reality:
- `scripts/` is still the canonical dataset contract and strongest validator
- iOS/macOS/watch runtime acts as a staging capture frontend
- app export/upload is only trustworthy when it matches the canonical script contract
- staged app captures must carry globally unique `sessionID` values and deterministic per-session `takeID` values
- watch motion presence is only true when an artifact is explicitly linked to that exact `sessionID` + `takeID`
- watch sync can be `acknowledged`, `timedOut`, `unavailable`, or `notRequested`; degraded states must never be mislabeled as synchronized

Platform differences should exist ONLY in:
- UI layout
- hardware integration

---

## Capture System

A session consists of multiple **takes**.

Each take may include:
- camA video (REQUIRED)
- camB video (OPTIONAL)
- audio (Serato / line-in)
- Apple Watch motion data
- session metadata

---

## Required Capture Rules

- camA is REQUIRED for a valid take
- A take is INVALID if required assets are missing
- Metadata must exist before recording starts
- No silent failures — all invalid states must be explicit

---

## Session Metadata Model

Each session must capture:

- performerName (String)
- bpm (Int)
- scratchType (Enum)
- drillMode (Enum)
- takeDuration (Seconds)
- takeCount (Int)
- handedness (Enum: left/right)
- notes (String, optional)
- deviceInfo (auto-generated)
- sessionID (UUID)
- timestamp (Date)

### Rule
If a field appears in UI → it MUST:
- exist in the model
- be validated
- be persisted
- be exported

---

## Scratch Type System

`scratchType` should be a strongly typed enum, for example:

- baby
- chirp
- transform
- flare_1
- flare_2
- orbit
- stab
- freestyle

This must NOT be free-text.

---

## Notation Extensions

The notation must be the substrate for the platter and crossfader teaching layers above. Today it represents stroke direction, stroke speed, audio onsets, and (partially) crossfader events. It needs explicit, first-class room for:

- **Crossfader state** as a continuous lane (open / closed) and as discrete events (cut on, cut off, transformer pulse). Already partly present — formalize.
- **Cut timing** as a scored quantity, distinct from stroke timing. Tested separately in Review.
- **Technique families** — chirp, transform, flare patterns expressed as templates over the existing stroke + fader event lanes. No new event types; new *target patterns* that pair stroke direction with fader-cut sequences.
- **Overlay visualization** — notation rendered as a transparent overlay on top of the camera feed during Practice and during Performer Monitor playback. The chart and the camera become the same visual thing.

The notation file format does not need to change to accommodate technique families — they're target-side patterns over existing event types. **No schema change required.** Anything that *would* require a schema change goes through the same review gate as any export-format change.

See `docs/capture_spec_v1.md` for the file-level appendix.

---

## UX Principles

- **Coaching, not performance.** Practice flows always frame the user as a student. Even advanced modes carry a clear "what you're working on" framing — never just "here's a DJ rig".
- **Notation is central.** Every primary screen has a route to a notation view: Practice (target overlay), Capture (target ghost while recording), Review (target vs captured), Advanced (notation lab). The chart is the spine of the product.
- **Camera + overlay + coach are one surface.** The educational story is: this is what I should do (target notation) → here's me doing it (camera) → here's the gap (captured notation + coach feedback). The three layers are designed together, not as separate tabs.
- **Beginners get less, not more.** Default mode shows the simplest target pattern and the highest assistance. Auto-cut on. Single technique loaded. Disclosures collapsed.
- **Complexity is opt-in.** Every advanced mode is reachable in two clicks but never on by default. The default Practice screen is readable end-to-end in three seconds.
- **Honest assistance.** When ScratchLab assists, the UI says so. No silent crossfader help. No silent timing widening. The student always knows whether what they're seeing is their work or the coach's.

---

## Data Pipeline

### Flow

1. Create session
2. Configure metadata
3. Record takes
4. Rename takes (operator-controlled)
5. Validate session
6. Export dataset package

---

## File Structure (Expected)

Each session should produce a structure like:

session_/
├── camA/
├── camB/ (optional)
├── audio/
├── watch/
├── take_log.csv
├── metadata.json
└── manifest.json

---

## Validation Rules

Validation MUST fail if:
- camA is missing
- renamed takes do not match `take_log.csv`
- metadata is missing required fields
- files referenced in manifest do not exist

Validation must NEVER silently pass incomplete data.

---

## Export Requirements

Exported session must:
- match actual recorded files exactly
- include all metadata
- include take log
- be deterministic and reproducible

Export formats:
- JSON (metadata + manifest)
- CSV (take log)

---

## macOS Role

macOS is NOT a secondary platform.

It should function as:
- session control surface
- metadata editor
- validation interface
- export manager

macOS must support:
- full session configuration (same as iOS)
- take review / rename
- validation feedback

---

## iOS Role

iOS is the primary:
- camera capture device
- session initiator (if standalone)
- UI for guided capture

Must support:
- full metadata input
- camera preview
- recording control

---

## Apple Watch Role

Apple Watch provides:
- motion data capture

Requirements:
- must sync timestamps with session
- must associate data with correct take

---

## Current Priorities

1. Reliable capture across devices
2. Accurate metadata capture
3. Clean validation system
4. Deterministic export pipeline

---

## Non-Priorities (for now)

- advanced UI polish
- AR features
- real-time ML inference
- multiplayer features

---

## Known Risks

- metadata inconsistency between platforms
- missing camA enforcement
- partial exports
- macOS feature parity gaps
- invalid session states passing silently

---

## Risks & Tradeoffs (current amendment)

- **Crossfader teaching layer is the highest-risk new build** — it touches Practice mode wiring, target-pattern generation, and notation scoring. We mitigate by keeping the schema unchanged and treating the modes as UI/coach behaviour over existing notation event types.
- **Auto-cut risks misleading students** — if students don't know the fader is being played for them, they'll think they're further along than they are. Mitigation: every assist mode names itself explicitly in the UI, and Auto-cut takes get a "coached" badge in Review.
- **Notation-on-camera AR overlay risks scope creep into rendering work** — kept in the experimental bucket; not on the consumer critical path.
- **"Coaching platform" identity could blur** if marketing copy starts talking about "DJ-ing in the app". Mitigation: the *What ScratchLab is — and is not* section above is the canonical positioning; any consumer-facing copy that contradicts it gets revised before ship.
- **Crossfader hardware variance** — real crossfaders curve, contour, and cut very differently across mixers. The Guided / Coached modes score against an idealized cut envelope. Document this; surface a calibration step if/when we add real-controller cut scoring.

---

## Development Philosophy

- correctness over speed
- explicit over implicit
- fail loudly, not silently
- minimal changes per task
- no placeholder logic in production paths

---

## Definition of a Healthy System

A session is considered valid only if:

- all required files exist
- metadata is complete and consistent
- take log matches actual files
- export package is complete and usable without modification

---

## Notes for Agents

- Do NOT invent fields not defined here unless necessary
- Do NOT remove validation rules
- Do NOT weaken requirements to “make things pass”
- If unsure, STOP and ask for clarification
- Always prefer tightening correctness over adding features
# Current CXL prompts 13–21 state (2026-09-08)

The isolated final-gate candidate is `/private/tmp/scratchlab-cxl-auto-20260908/p21-final-gates` on `codex/cxl-auto-p21-final-gates`. Prompts 13–21 are software-complete. The current hardware-feedback candidate is `/private/tmp/scratchlab-cxl-auto-20260908/products-p22c-cxl-hardware-fix/Release/ScratchLab.app`, bundle `com.machelpnz.scratchlab.cxl-authoring`, executable SHA-256 `7c1d4edaba6646b15dcd6cbd9234685661924f9aa0a77667f0710be943989cc9`. It is a universal `x86_64 arm64` Release bundle with a complete local ad-hoc signature; `codesign --verify --deep --strict` passes and its Info.plist, resources, identifier, and capture entitlements are sealed.

Focused and broad software gates pass after narrow Prompt-21 repairs. Direct full Debug and Release-optimized test harnesses each execute 3,973 tests with 56 skips and 0 failures per configured run; the final required `scripts/build.sh all` rerun executes 3,973 with 55 skips and 0 failures, then passes all three builds. Release tests require the repository's existing test-only `DEBUG ENABLE_TIMECODE_LIVE_TAP` conditions; the physical candidate was built separately with neither condition and has no checked Debug route/tool/test symbols. The original P21 candidate was not launched or connected to hardware. Continue only with `RANE_PHYSICAL_HANDOFF.md`; record physical evidence as PASS/FAIL/BLOCKED/NOT RUN and stop at the first failure.

Hardware feedback on the earlier candidate exposed three Release-only presentation/setup defects. CXL live Tear could alternate between AHHH-loop calibrated revolutions and fallback normalized coordinates, which split or rescaled one physical trace; the aligned provisional reconstruction also dropped the decoder's `meetsNoiseGates` result. Release entered capture without a visible explicit hardware setup, started camera/microphone work on route appearance, allowed Continuity companion browsing, and could react to Serato lifecycle changes by silently restoring the first camera. The repair fixes CXL to one take-local physical coordinate basis, retains the shared decoder's provisional gate, keeps genuine packet gaps explicit as `MOTION UNKNOWN`, adds visible Setup/Capture/Review & Export stages and exact MIDI/camera/audio selectors, and gates camera/audio, companion relay, and Serato process-tap work behind explicit operator actions. Generic Practice/Capture remain loop-aware.

The final frozen repair gate passed 17 unique tests in two configurations: 34/34 executions, zero failures, skips, or runtime warnings. Its 453 Swift/project/test-plan input manifest remained byte-identical, SHA-256 `5a0f72aba42016ac540b3476aae84e5c1d253324fbab0119d323a03a78c30b72`. The universal Release build passed after the focused gate. PID `80042` was agent-verified running from the exact candidate executable; UI inspection is blocked only because the Mac is locked. Every Rane, permission-dialog, live-notation, recording, calibration, media, Watch, export, and operator result remains NOT RUN. The immediate diagnostic rig is the Rane ONE MKII; the intended CXL Rane Seventy-Two plus Rane Twelve path remains separately NOT RUN, and the current Setup does not yet prove its pair-specific DVS/master routing. The established 3.2-second rolling normalization can still refit as old motion ages out; that is independent of AHHH playback and remains an explicit residual risk.
