
# ScratchLab – AI Context

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

**What the virtual platter is not.** A platter without a crossfader is musically incomplete for almost every other named technique (chirp, transformer, flare, crab, orbit, tear, scribble — every one of these is *defined by* coordinated fader cuts). Building a deeper virtual platter without an honest crossfader does not unlock more techniques; it produces a misleading practice surface where students "succeed" without learning the half of the skill that actually matters.

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
