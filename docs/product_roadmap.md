# ScratchLab Product Roadmap

This roadmap is intentionally split into three independent product surfaces so consumer scope doesn't drift into research scope and vice-versa. Each track moves on its own cadence; nothing in *Studio / research* or *Experimental* may block a *Consumer coaching* release.

See:
- `AI_CONTEXT.md` for product framing (*What ScratchLab is — and is not*, *Virtual platter*, *Crossfader training & coach-assisted scratching*).
- `docs/current_architecture_reality.md` → *Scope Guards* for the explicit non-goals that bound this roadmap.

---

## Consumer coaching product (now → next two milestones)

The primary surface. Everything here is on the consumer critical path.

- Practice / Capture / Review / Advanced layout as currently built.
- Baby Scratch end-to-end (target notation, capture, scored review). **Done / in polish.**
- Crossfader teaching layer — Auto-cut, Guided, Coached, Open modes. **Next milestone.**
- Chirp + Transform target patterns over existing notation. **Next milestone.**
- Onboarding flow: target picker → mode picker → first practice run.
- App Store screenshots set: Practice / Capture / Review / Advanced + one notation hero shot.

### Definition of done for the next consumer milestone

- Auto-cut, Guided, Coached, Open modes are each named in the UI and explained inline.
- Chirp and Transform target patterns exist as target-side data only — no schema changes.
- Review surfaces a separate cut-timing score when the take used Guided or Coached mode.
- Default Practice screen is readable end-to-end in three seconds (per UX principles).

---

## Studio / research tooling (parallel, never blocks consumer)

Internal-only tools that live alongside the consumer build but are gated behind Advanced or build flags.

- Notation lab in Advanced (already partly there).
- Raw sidecar inspection.
- Movement-pipeline diagnostics, audio-pipeline diagnostics.
- Training-data export packaging.
- Internal-only analytics.
- These tools are gated behind Advanced and never required for the consumer flow.

### Constraint

If a Studio capability would force a schema, export-format, or detection-pipeline change to ship a consumer feature, the consumer feature waits. The dataset contract is upstream of UX velocity.

---

## Experimental AR / overlay (R&D, opt-in)

Research-mode work. May ship behind a build flag or as a separate research target. None of this gates a consumer release.

- Notation-on-camera AR overlay (camera + chart fused).
- Generative coach feedback (text or audio suggestions per take).
- Audio synthesis from captured motion (the "hear what your scratch would sound like on a real rig" demo).
- Watch-driven gesture inputs beyond motion capture.

### Constraint

Anything here that demonstrates well does **not** automatically promote to *Consumer coaching*. Promotion requires:

1. Honest user value beyond novelty.
2. No schema or export-format change.
3. Fits the *learn / visualize / analyze / improve* identity.
4. Default-off; opt-in path with clear coach-assist labelling if it modifies what the student hears or sees.

---

## What this roadmap deliberately excludes

These do not appear on any track. Adding them requires an explicit amendment to `docs/current_architecture_reality.md` → *Scope Guards*.

- Full deck emulation.
- A DAW or DAW-replacement workflow.
- Realtime live-mixing / perform-out features (ScratchLab pairs with real DJ apps via Performer Monitor and Direct Capture instead).
- Ultra-low-latency live-audio routing.
- A server-side training-data ingestion service in v1.
