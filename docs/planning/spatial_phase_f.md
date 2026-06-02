---
title: ScratchLab Phase F — Long-Term AR (Lightweight Glasses / HUD / Performance Augmentation)
role: AR / battle / virtual performance futures — sketched only. Detailed design opens after Phase E δ.
status: sketch (not planned in detail; gated on multiple long-running prerequisites)
source: extracted verbatim from `glowing-dazzling-sketch.md` Phase F section
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — master roadmap, cross-phase honesty model (Section X), cross-phase hard constraints (Section Z)
  - [replay_phase_d.md](./replay_phase_d.md) — Phase F builds on Phase D-S spatial replay; iOS AR before Vision Pro before glasses is non-negotiable
  - [instructor_phase_e.md](./instructor_phase_e.md) — Phase E δ is a hard gate before Phase F planning opens
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase F — Long-Term AR (Lightweight Glasses / HUD / Performance Augmentation)

## Purpose

Phase F sketches the long-term AR direction: lightweight glasses HUD, performer-only confidence monitors, and spectator-side AR for battles and performances. Phase F **is not designed in detail in this plan** beyond high-level scope. The Phase F planning slice opens after Phase E δ.

## Current state

Phase F is gated. Phase F opens **only when**:

- Phase D-S δ has been stable for 60+ days.
- Phase E δ has been stable for 60+ days.
- Lightweight AR glasses (Apple, XREAL, Viture, Brilliant, or equivalent) have shipped a stable developer SDK accessible from Swift.
- Honest-uncertainty vocabulary has held across 90+ days of releases.

None of those gates are open at the time of writing (2026-05-28).

## Design principles

- **Replay before practice before performance.** Same hardware sequence rule that governs Phase D-S: iOS AR before Vision Pro before lightweight glasses. The instrument never moves into a virtual space; AR is overlay on real practice.
- **Performer untouched in spectator AR.** Spectator AR is a spectator-side surface only. The DJ scratches on real gear; the audience sees an optional overlay.
- **No closed feedback loop with the system during live performance.** The performer's feedback loop is with the audience, not with the app. Any HUD overlay that closes that loop with ScratchLab is an anti-goal.

## Slice roadmap

Phase F scope is sketched only; detailed slice design is deferred until Phase F's planning slice opens.

### F1 — Lightweight HUD overlay (replay)

- Single-plane HUD glasses display a minimal replay overlay above the deck. Replay-only.

### F2 — Lightweight HUD overlay (practice, target-only)

- Targets and beat grid as HUD; never live judgment. Realtime only because targets are deterministic, not because classifier output is.

### F3 — Performer-only confidence monitor

- Hidden iPad showing next phrase, accessible only to the performer. Not on-glass. Teleprompter, not XR.

### F4 — Spectator AR (audience-side)

- Optional spectator view of a battle/performance with notation overlay. Spectator side only; performer untouched.

## Safe before TestFlight

Nothing in Phase F. Phase F is entirely post-Phase-E δ.

## Deferred / post-TestFlight

All of F1–F4 is deferred. Phase F's own planning slice — the document that takes F1–F4 from sketches to executable slices — itself does not exist yet. It will be drafted after Phase E δ + 60 days.

## Risks

### F explicit non-goals

- **No live performance HUD that closes the feedback loop with the system instead of the audience.** Anti-goal restated.
- **No metaverse / virtual venue / persistent social space.** Anti-goal.
- **No AI judging of live performance.** Never.
- **No "Coach during performance."** Anti-goal full stop.
- **No fake AI certainty in any AR surface.** Honesty grammar holds at every device.

## Verification gates

Detailed verification will be defined when Phase F's planning slice opens. At minimum, Phase F surfaces will continue to honor the cross-phase honesty model:

- Visual honesty grammar: solid = audio onset, dashed = classifier-derived, confidence-as-thickness, persistent estimation badging.
- Reduce-motion path for every new animation.
- Forbidden-import grep (ARKit/RealityKit/glasses-SDK imports kept out of pure projection modules).
- No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.

## Links back to master roadmap

- Master Phase F section: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase honesty model (Section X) and hard constraints (Section Z): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Phase D-S spatial replay groundwork (iOS AR → Vision Pro → glasses sequence): [replay_phase_d.md](./replay_phase_d.md)
- Phase E δ gate: [instructor_phase_e.md](./instructor_phase_e.md)
