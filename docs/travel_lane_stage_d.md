# Travel-driven notation lane — Stage D status & deferral

Handoff note recording where the travel-driven notation-lane amplitude work stands, and **why
Stage D PR 2 is deferred.** This fixes the long-standing "every stroke hits 100% / rail-to-rail
before a reversal" complaint by driving a stroke's lane excursion from actual platter **travel**
instead of a speed bucket — while keeping time on the horizontal axis.

## What shipped (on `main`)

The offline, UI-free proof chain (all merged):

1. **C++ scratch-notation core** + Obj-C++ bridge + Swift analysis adapters → `ScratchNotationIntent`
   (direction, start/end, `travelPercent` unclamped, audibleState incl. `.unknown`, warnings).
2. **Comparison + exports + debug readout** over the intent.
3. **`ScratchNotationLaneDisplayModel`** — adds a display-only `normalizedTravel` (0…1) from a
   caller-supplied `fullScaleTravelPercent`; raw `travelPercent` preserved.
4. **`ScratchNotationTravelMotionPath`** — builds a renderer-compatible `MotionPath` whose stroke
   excursion is driven by `normalizedTravel`.
5. **`TravelLaneDebugView`** (macOS, `#if DEBUG`, preview-only) — A/B of the current speed-bucket
   lane vs the travel lane; can load a **recorded** `ScratchTimeline` JSON via `.fileImporter`
   (`ScratchTimelineProvenance`, Data → display model). Debug-only; not wired to app navigation.

### Stage D PR 1 (done)

The production renderer is now **travel-capable**:

- `LaneStroke` gained optional `normalizedTravel: Double?` (defaults to `nil`).
- `ScratchStrokeGeometry.rawAmplitude(for:)` uses `normalizedTravel` (clamped 0…1) when non-nil,
  otherwise the **exact existing speed bucket** (slow 0.55 / medium 0.78 / fast 1.0).
- **No visible production change:** nothing populates `normalizedTravel`, so every production /
  demo / scored / reel / notation stroke is `nil` → byte-identical rendering. Demo/scored lanes
  unchanged. The iOS build is part of this slice's gate (shared types compile into iOS).

So the false-100% issue is solved at the **renderer-capability** level, but **not activated**.

## Why Stage D PR 2 is deferred

Activating it (flipping the production default to travel) needs a real per-stroke `normalizedTravel`
value reaching `LaneContent`. **No in-bounds production source does today:**

- `LaneContent.platterTimeline` is **never populated in production** (dormant scaffold channel).
- The notation grammar's `DirectionSegment` start/end **positions don't reach the lane** (only the
  Semantics/Timing layers).
- `ScratchNotation.Stroke` carries **no travel** (only direction / speed / fader).
- The only real travel (cc6 `travelPercent`) lives **only in the DEBUG path**.

## Activation requires a future, approved provenance source

| Route | Source | Boundary cost |
|---|---|---|
| 1. Recorded-timeline import (production) | cc6 `travelPercent` (accurate) | lifts the "no file I/O in production" rule; needs a real import entry point; cc6-stroke → `LaneStroke` mapping (placeholder speed/fader, `.unknown` handling) |
| 2. Rane / live capture | live `ScratchSampleTimeline` (cc6) | out of bounds (live MIDI / realtime engine / PlaybackLab) |
| 3. Vision `PlatterPositionTimeline` | per-stroke position span | new pipeline; macOS-only recorder (iOS-asymmetric); noisier than cc6 |
| 4. Grammar / notation schema | grammar Δposition | grammar→lane wiring or an export-schema change (discouraged) |

If pushed, **Route 1** is most tractable but is a 2–3 PR mini-project (2a: pure cc6-displayModel →
`[LaneStroke]` mapping adapter; 2b: production import behind a feature flag; 2c: flip default after
visual acceptance).

## Constraints until a source is chosen

- Do **not** wire provenance into the production lane.
- Do **not** start production file import or live capture.
- Do **not** pick a production `fullScaleTravelPercent` (too small re-rails everything; too large
  flattens real strokes — it must be chosen against the selected source, pinned by a fixture test).
- Do **not** change renderer/default behavior.

Stage D PR 1 is the deliberate stopping point. Resume when a provenance route + its boundary is
explicitly greenlit.
