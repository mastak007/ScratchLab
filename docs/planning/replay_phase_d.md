---
title: ScratchLab Phase D — Studio Mode (Analysis, Cinematic Export, Spatial Replay)
role: Replay / Studio / export systems — three parallel tracks (D-A analysis, D-X cinematic export, D-S spatial replay / AR) sharing one foundation, one renderable artifact contract, and one honesty grammar.
status: active (not shipped; gated on Phase B and Phase C foundations)
source: extracted verbatim from `glowing-dazzling-sketch.md` Phase D section
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — master roadmap, cross-phase honesty model (Section X)
  - [notation_phase_b.md](./notation_phase_b.md) — D-S3 spatial phrase chapters hard-block on B2
  - [coaching_phase_c.md](./coaching_phase_c.md) — D-S consumes the same `CoachingEventDisplayability` tiering as 2D coaching surfaces
  - [instructor_phase_e.md](./instructor_phase_e.md) — Phase E consumes Studio artifacts (annotation sidecar, drill sidecar, studio package, cinematic videos, spatial sessions)
  - [spatial_phase_f.md](./spatial_phase_f.md) — Phase F long-term AR opens 60 days after D-S δ + E δ
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase D — Studio Mode (Three Parallel Tracks)

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

## Purpose

ScratchLab already has two app targets — `ScratchLab` (iOS-target, consumer) and `ScratchLabDesktop` (macOS-target, analyzer). Studio Mode is the macOS analyzer surface, productized.

Sidecar schema (`scratchlab_local_recording_sidecar_v1`) already carries `auditTrail` and `reviewMetadata`. Studio Mode is largely about **surfacing existing additive sidecar evolution paths**, not designing new schemas. Phase D never bumps the schema version unless explicitly forced; it adds optional sidecars alongside.

## Current state

- iOS consumer target and macOS analyzer target both compile and run independently.
- `scratchlab_local_recording_sidecar_v1` is stable; `auditTrail`/`reviewMetadata` already present.
- `SessionReplayTimeline`, `NotationReplayDriver`, `NotationPresentationModel` exist as the foundation that all three tracks project from.
- `DebugReviewNotationCard` and `NotationVisualizerView` patterns already exist on macOS but are not yet hosted under a unified Studio tab.
- No ARKit / RealityKit / NDI imports in the project today. D-S1 introduces ARKit + RealityKit for the first time, gated at module level so release builds compile without them when the spatial flag is off.

## Design principles

**D pillars (shared across tracks):**

1. **Inspectable notation** — every primitive can be drilled into, every metric traceable to an evaluator.
2. **Archival/replay fidelity** — captured sessions remain bit-exact playable from sidecar; Studio never alters originals.
3. **Phrase intelligence** — phrase grouping and release-tail analysis become first-class studio primitives.
4. **Additive-sidecar discipline** — studio outputs are new optional sidecars next to the original, never mutations of it.
5. **Explainable analysis** — every chart, heatmap, comparison, export, or spatial overlay has a "why" affordance.
6. **Deterministic reproducibility** — same session + same sidecar = same studio output, every time, on every surface (2D analytic, exported video, spatial replay).
7. **Layered disclosure** — Studio surfaces hide depth until requested.
8. **Surface parity** — analytic, export, and spatial surfaces show the same data, same colors, same honesty grammar.

**D-S rules (non-negotiable):**

- **Renderer-only.** D-S consumes notation/replay artifacts and produces no canonical data.
- **No realtime claims sourced from classifier output.** Realtime overlays use only deterministic signals (audio onset, target, beat grid, platter direction).
- **Solid line = audio onset. Dashed translucent = classifier-derived.** Visual grammar carried verbatim from B1/B2 into 3D.
- **Confidence visibly degrades.** When `CoachingEventDisplayability.advisory`, the spatial overlay widens / blurs / fades. The honesty grammar that crosses 2D and 3D unchanged.
- **Persistent "Replay — Estimated Timing" badge** on every D-S surface.
- **No characters in practice.** Optional abstract reactive particles only, replay/export-only.
- **No realtime coaching during execution.** D-S is replay first, optional minimal HUD second.
- **iOS AR before Vision Pro before glasses.** Hardware sequence is non-negotiable.

## Slice roadmap

### D0 — Studio foundation (shared)

- Productize inspection surfaces that exist on macOS. Promote `DebugReviewNotationCard` and `NotationVisualizerView` patterns into a single hosted "Studio" tab inside `MacAnalyzerView`, behind `STUDIO_MODE` flag.
- macOS-only at this stage. No analytics; just navigable entry.
- Foundation for all three tracks.

**Files:** `MacAnalyzerView.swift`, new `ScratchLabDesktop/Views/Studio/StudioSessionPickerView.swift` and `StudioSessionHostView.swift`, `FeatureFlags.swift` (`STUDIO_MODE`).

**Verification:** macOS smoke test: tab appears, session picker lists real archived sessions, opening one shows existing replay view without errors.

---

### Track D-A — Analysis

#### D-A1 (was D1) — Advanced replay/review (scrub + multi-pass)

- Scrub primitive (`StudioReplayScrubber`) over `SessionReplayTimeline`. Loop a phrase span. Variable playback rate (0.25×–1.0× for visual inspection; audio rate stays 1.0×).
- New `ReplayLoopRange` value type.
- Flag: `STUDIO_SCRUB`.
- → **TestFlight Checkpoint α-D** (macOS internal cohort).

#### D-A2 (was D2) — Phrase/session archaeology

- Phrase heatmap (per-phrase timing-drift density), session timeline, release-tail durations chart.
- All read-only, deterministic from `AudioPhraseSummary`, `PhraseBoundaryMapper`, `TimingDrift`.
- Every chart carries "what this shows / what it doesn't" footer.
- Flag: `STUDIO_ARCHAEOLOGY`.

#### D-A3 (was D3) — Creator tooling: bookmarks + annotations (additive sidecar)

- New sidecar `scratchlab_studio_annotations_v1` alongside `scratchlab_local_recording_sidecar_v1`.
- Original sidecar untouched.
- Flag: `STUDIO_ANNOTATIONS`.
- → **TestFlight Checkpoint β-D** (analytics readability, annotation workflow).

#### D-A4 (was D4) — Multi-take comparison

- Side-by-side replay of two takes of the same scratch. Shared time axis.
- Copy says "compare" not "better"; UI shows differences, never declares a winner.
- Flag: `STUDIO_MULTITAKE`.

#### D-A5 (was D5) — Notation authoring (drill composition)

- Users compose `ScratchRenderTimeline` instances by combining existing primitives. No new primitive types.
- Saved as additive sidecar `scratchlab_studio_drill_v1`.
- Flag: `STUDIO_DRILL_AUTHORING`.

#### D-A6 (was D6) — Analysis workbench

- Combine D-A1+D-A2+D-A3+D-A4 surfaces into a coherent layout.
- `@SceneStorage` for layout persistence.
- Flag: `STUDIO_WORKBENCH`.

#### D-A7 (was D7) — Export/interop (additive package)

- "Export Studio Package": zip-shaped bundle of original sidecar + studio annotation/drill sidecars + manifest.
- New sidecar `scratchlab_studio_package_v1`.
- Flag: `STUDIO_EXPORT`.
- → **TestFlight Checkpoint γ-D** (broader macOS audience).

---

### Track D-X — Cinematic Export

The export track is genuinely ScratchLab's biggest near-term differentiator before any AR hardware. Phrase comparison videos, transparent notation overlays, and clean+notation NDI feeds are valuable to instructors, streamers, and creators even without any 3D surface. They are also the prerequisite pipeline for D-S.

#### D-X0 — Renderable artifact contract

- Define a stable internal projection that consumes `SessionReplayTimeline` + `NotationPresentationModel` and produces a frame stream suitable for video encoding OR 3D rendering.
- Pure value-level mapper, no UI, no AVFoundation. Already foreshadowed by `NotationReplayDriver` per AI_HANDOFF Section 7.
- Flag: none (internal architecture).

**Files:** new `ScratchLabDesktop/Services/Export/CinematicFrameProducer.swift`, reuses `NotationReplayDriver`.

**Verification:** deterministic-output assertion (same session = same frame stream); no AVFoundation in producer module.

#### D-X1 — Notation-overlay transparent video export

- Export a transparent video (alpha channel) containing only the notation/timing layer — directly droppable into OBS, Premiere, Final Cut.
- macOS-only initially; uses `AVAssetWriter`.
- Strongest creator-friendly export. App-Store-safe (no claims; it's a video file).
- Flag: `EXPORT_NOTATION_OVERLAY_VIDEO`.

**Files:** new `ScratchLabDesktop/Services/Export/NotationOverlayVideoExporter.swift`.

**Verification:** macOS smoke; output video opens in OBS with alpha; deterministic-output assertion.

#### D-X2 — Phrase comparison video export

- Side-by-side notation + audio + camera, two takes of the same scratch, exported as a single MP4.
- The educational primitive. Nothing else does this.
- Flag: `EXPORT_PHRASE_COMPARISON`.

**Files:** `ScratchLabDesktop/Services/Export/PhraseComparisonExporter.swift`, depends on D-X0 and D-A4.

**Verification:** output video plays in QuickTime; both panes synced; deterministic on re-export.

#### D-X3 — Cinematic replay video (annotated practice export)

- Single take exported with notation overlay composited on the original camera feed, phrase boundaries highlighted, optional ghost-take semi-transparent under your new take.
- Educational + shareable.
- Flag: `EXPORT_CINEMATIC_REPLAY`.

**Files:** extends `NotationOverlayVideoExporter`.

**Verification:** output matches the on-screen replay frame-for-frame at chosen export settings.

#### D-X4 — NDI clean + notation feeds (creator pipeline)

- macOS NDI output: two named feeds — `ScratchLab Clean` (passthrough camera) and `ScratchLab Notation` (transparent overlay).
- Streamer in OBS pulls only what they want.
- Audio sync rides on existing audio-onset pipeline, not on classifier output.
- Flag: `NDI_FEEDS`.

**Files:** new `ScratchLabDesktop/Services/Streaming/NDIFeedPublisher.swift` (wraps an NDI Swift binding), additive only.

**Verification:** OBS on a second machine can subscribe to both feeds; clean feed has zero overlay; notation feed renders at 30/60fps without dropping capture frames.

#### D-X5 — Export workbench (D-X1+D-X2+D-X3+D-X4 surfaced together)

- One macOS pane to choose what to export, with persistent settings.
- Flag: `EXPORT_WORKBENCH`.
- → **TestFlight Checkpoint α-DX** (creator cohort: 5–10 streamers/instructors).

---

### Track D-S — Spatial Replay / AR

Per the AR planning analysis: ScratchLab is genuinely well-suited to spatial visualization because the instrument *is* a physical rotational axis. Platter angle, hand position, fader gate, and release tail are all inherently geometric — they already live in `ScratchStrokeGeometry` / `ScratchMotionRenderer`. Mapping that onto a spatial overlay is a near-direct projection of data we already have, not an invention.

#### D-S0 — Spatial artifact contract

- Define a pure 3D projection of `NotationReplayProjection` consumable by both ARKit and RealityKit.
- Reuses the same pure-geometry projection functions Phase B established (per Section 0.12 contract).
- No `ARKit` / `RealityKit` imports in the projection module — those live only in the renderer surfaces (DS1+).

**Files:** new `ScratchLabDesktop/Services/Spatial/SpatialReplayProjection.swift` (pure value types only).

**Verification:** unit tests (`swift test`-runnable) for projection determinism; zero forbidden imports.

#### D-S1 — iOS AR `SpatialReplayView` (MINIMAL SAFE FIRST SPATIAL SURFACE)

- New iOS view (`SpatialReplayView`) renders the notation timeline as a 3D ribbon arcing in front of the platter, audio-onset markers as solid spheres, classifier-derived inferences as translucent dashed segments.
- Uses ARKit + RealityKit. iPad / iPhone — camera AR. The phone propped on a mic stand is the deployment surface.
- **Replay-only.** No mid-session realtime overlay in D-S1.
- Flag: `SPATIAL_REPLAY_IOS`.
- Adds ARKit/RealityKit imports — first time in the project. Gated behind flag at module level so release builds can compile without them when flag is off.

**Files:** new `ScratchLab/Views/Spatial/SpatialReplayView.swift` (iOS-target only), new `ScratchLab/Views/Spatial/SpatialReplayARSession.swift`.

**Verification:** iOS build green; iPad / iPhone smoke test against a known captured session; release build with flag off has zero ARKit linkage; "Replay — Estimated Timing" badge persistent.

→ **TestFlight Checkpoint α-DS** (iOS internal cohort: 5–10 advanced users with iPads).

#### D-S2 — Ghost-take overlay

- D-S1's ribbon gains an optional ghost-take overlay: your previous take's notation rendered translucent beneath the current playback.
- Strongest pedagogical primitive after the ribbon itself.
- Flag: `SPATIAL_GHOST_TAKE`.

**Files:** extends `SpatialReplayView`.

**Verification:** ghost take respects displayability tier; renders translucent (≤40% opacity); never displayed during capture.

#### D-S3 — Spatial phrase chapters

- Phrase boundaries from `PhraseBoundaryMapper` rendered as physical gates the user can "walk through" (visually) by scrolling the timeline.
- Hard-blocked on B2.
- Flag: `SPATIAL_PHRASE_CHAPTERS`.

**Files:** extends `SpatialReplayView`.

**Verification:** B2 must be flagged-true on the same TestFlight; gates render at phrase boundaries exactly as in 2D.

#### D-S4 — Vision Pro replay theatre

- visionOS target. Same `SpatialReplayProjection`, different host.
- Walk-through replay; phrase chapters as physical objects; scrub timeline as a horizontal rail.
- macOS Studio gains "Open in Vision Pro" affordance for an already-archived session.
- Flag: `SPATIAL_REPLAY_VISIONOS`.

**Files:** new `ScratchLabVision/` target (visionOS only); `ScratchLabVision/Views/SpatialReplayTheatreView.swift`.

**Verification:** visionOS build green (requires Xcode + visionOS SDK on the build host); replay determinism on Vision Pro matches iOS.

→ **TestFlight Checkpoint β-DS** (Vision Pro cohort; 3–5 users).

#### D-S5 — Spatial archaeology (D-A2 in 3D)

- D-A2's phrase heatmap rendered in spatial form: phrases laid out left-to-right in space, each phrase a card you can step around.
- Educational delta over 2D: large session structure becomes physically navigable.
- Flag: `SPATIAL_ARCHAEOLOGY`.

**Files:** extends Vision Pro target.

**Verification:** charts encode uncertainty in 3D the same way they encode it in 2D (low-event-count phrases visually faded).

→ **TestFlight Checkpoint γ-DS** (full D-S surface validated).

#### D-S6 — Honesty grammar v1 enforcement

- One audit slice: walk every D-S surface and confirm:
  - Solid line / sphere = audio onset
  - Dashed translucent = classifier-derived
  - Confidence-as-thickness applied everywhere
  - "Estimated / Preview" badging persistent
  - No score, no streak, no "you did it" — none, ever
- Not a feature; a checkpoint.

→ **TestFlight Checkpoint δ-DS** (honesty grammar audit; full PROFILE.md vocab pass).

## Safe before TestFlight

- D0 (foundation; macOS-only).
- D-A1, D-A2 (read-only analytics; deterministic from existing sidecars).
- D-X0 (pure renderable contract; no UI, no AVFoundation).
- D-X1 (transparent notation video — App-Store-safe because it's a video file).
- D-S0 (pure spatial projection; no AR imports).

These can land in parallel with no checkpoint dependency on Phase B (other than honoring AR-prep contracts).

## Deferred / post-TestFlight

The track-by-track execution order across all three tracks (recommended interleaving):

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

Everything past the "safe before TestFlight" set is gated on its own checkpoint cycle.

## Risks

### Track D-X explicit non-goals

- No DAW features — no editing audio, no time-stretching, no mixing.
- No upload-to-web. Export produces files; user shares by any means.
- No OBS plugin yet — output NDI + files, let OBS consume.
- No copyright-protected content auto-handling — exports use whatever audio was captured; user is responsible.
- No realtime broadcast — D-X is post-capture export; live broadcast claims sit in PROFILE.md overclaim territory.

### Track D-S explicit non-goals

- **No virtual decks.** ScratchLab never replaces the instrument. The platter you scratch on is real.
- **No metaverse / persistent virtual social space.** Anti-goal.
- **No gamified verdicts in 3D.** No combo bursts, no celebratory sparkles during practice. Replay-only optional minimal particles, off by default.
- **No realtime coaching during live performance.** D-S does not become a performer HUD.
- **No characters in practice.** Even on Vision Pro replay theatre, abstract reactive particles are optional and off by default.
- **No lightweight AR glasses targeting in Phase D.** Deferred to Phase F.
- **No claim of "AI confirmed."** Every D-S overlay carries explicit estimation framing.
- **No content moderation / social layer.** Phase E owns instructor exchange; D-S is solo by design.

### D freeze boundaries

- After **D-A1**: no new analytics surfaces for one TestFlight cycle.
- After **D-A3**: annotation sidecar schema frozen.
- After **D-A5**: drill sidecar schema frozen.
- After **D-S1**: no new realtime claims for one cycle. iOS AR replay must be replay-only for the entire α-DS cycle.
- After **D-S4**: Vision Pro replay surface frozen; no scope creep into Vision Pro performance HUD.
- Before **Phase E**: minimum 4 weeks of δ-DS feedback. Phase E opens instructor sharing; package format and spatial format must both be stable.

## Verification gates

Per `[[feedback_verification_scope]]`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` clean.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
4. Flag wiring verified in `FeatureFlags.swift`.
5. Copy review against PROFILE.md vocabulary.
6. Reduce-motion path for any new animation.
7. No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.

### For D-S specifically

- `xcrun xctest` with dot-form selector for any added Spatial projection tests (per `[[project_test_runner_hang]]`).
- Forbidden-import grep confirms ARKit/RealityKit are absent from `Models/Notation/**` and `Services/Spatial/SpatialReplayProjection.swift` (projection module is pure).
- Release build with `SPATIAL_REPLAY_IOS=false` has zero ARKit/RealityKit linkage.
- Persistent "Replay — Estimated Timing" badge present on every D-S surface.

### For D-X specifically

- Deterministic re-export test: same session + same settings = byte-identical output video (or within encoder noise threshold).
- No AVFoundation in `CinematicFrameProducer.swift` (the producer module is pure).

## Links back to master roadmap

- Master Phase D section: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Appendix A "Where AR plugs into existing architecture": [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase honesty model (Section X): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase hard constraints (Section Z): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Phase B AR-prep contracts: [notation_phase_b.md](./notation_phase_b.md)
- Phase C presentation-tier confidence model: [coaching_phase_c.md](./coaching_phase_c.md)
- Phase E instructor consumption of Studio outputs: [instructor_phase_e.md](./instructor_phase_e.md)
- Phase F long-term AR (opens after D-S δ + E δ + 60 days): [spatial_phase_f.md](./spatial_phase_f.md)
