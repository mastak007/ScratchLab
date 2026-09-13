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
- Finalized-take Review transport: jump to start, scrub against the captured timeline, and loop a selected repetition or visible range. Manual downbeat correction must retain the detected timing and record the operator adjustment instead of overwriting the original evidence. **Place in the current CXL sequence at Prompt 17, after finalized media and repetition boundaries are truthful.**
- Onboarding flow: target picker → mode picker → first practice run.
- App Store screenshots set: Practice / Capture / Review / Advanced + one notation hero shot.

### Definition of done for the next consumer milestone

- Auto-cut, Guided, Coached, Open modes are each named in the UI and explained inline.
- Chirp and Transform target patterns exist as target-side data only — no schema changes.
- Review surfaces a separate cut-timing score when the take used Guided or Coached mode.
- Review transport plays the exact finalized take, keeps audio, video, notation, platter, fader, beat, and sample-position views on one take-relative clock, and loops only a real selected range.
- Any operator timing correction is additive and auditable: detected timing remains recoverable, the adjustment has explicit provenance, and neither value is silently presented as ground truth.
- Default Practice screen is readable end-to-end in three seconds (per UX principles).

---

## Studio / research tooling (parallel, never blocks consumer)

Internal-only tools that live alongside the consumer build but are gated behind Advanced or build flags.

- Notation lab in Advanced (already partly there).
- Raw sidecar inspection.
- Movement-pipeline diagnostics, audio-pipeline diagnostics.
- Training-data export packaging.
- Internal-only analytics.
- Guided rig verification: one linear Advanced workflow selects the audio device and candidate input pair, proves DVS carrier/platter movement, observes the crossfader's MIDI source/channel/CC/raw range/open orientation, checks sample rate and channel support, and saves a versioned verified-rig receipt. **Place the software workflow in Prompt 20; reserve Prompt 21 for the fresh RANE verification and receipt evidence.**
- Synchronized diagnostic replay trace: a rebuildable, versioned view that aligns raw platter position, calibrated travel, pitch/rate, crossfader state, beat position, sample position, velocity, Watch motion, and media time. **Introduce the in-memory Review consumer with Prompt 17; add package/reopen support with Prompt 19 only after a real consumer and compatibility policy exist.**
- Portable verified rig profiles: export and import the verified audio routing, DVS format, MIDI mapping, fader calibration/orientation, sample-rate/channel expectations, stable hardware identity, and mapping/profile versions and hashes. **Define the profile from Prompt 20's verified receipt; implement portability only after Prompt 21 proves the receipt on hardware.**
- These tools are gated behind Advanced and never required for the consumer flow.

### CXL operator-workflow implementation order

1. **Prompt 17 — finalized Review transport.** Build playback and range-looping on the existing finalized-take identity and take-relative clock. Add the synchronized trace as a consumer of evidence already held in memory; do not introduce persistence merely to draw it.
2. **Prompt 19 — deterministic reopen.** If the synchronized trace has a real Review consumer, persist only a derived, versioned replay cache with source hashes and enough metadata to invalidate and rebuild it. Raw capture evidence remains authoritative.
3. **Prompt 20 — guided rig verification.** Replace scattered setup diagnostics with one fail-closed operator route and save a local verified-rig receipt only after every required observation passes.
4. **Prompt 21 — RANE acceptance.** Run the bounded physical checklist, record exact device and mapping evidence, and mark the receipt hardware-verified only from fresh observations. A build, saved selection, historical calibration, or lifetime MIDI counter cannot satisfy this gate.
5. **Post-Prompt 21 — profile portability.** Add import/export after the receipt format and hardware revalidation rules have survived the RANE test. Import never activates a profile silently; ScratchLab must match stable device identity, report substitutions, and revalidate live inputs before capture.

### Evidence and scope rules for these additions

- Raw capture artifacts and their take/session identities remain the source of truth. Replay traces and rig profiles are derived aids with explicit schema versions, source hashes, and invalidation rules.
- Missing platter, fader, audio, Watch, beat, or sample-position evidence stays visibly unknown. The replay view must not interpolate a decisive state across an evidentiary gap.
- Rig verification is capability-specific: audio routing, DVS, platter MIDI, crossfader MIDI, camera, and Watch each pass, fail, or remain not run independently.
- A saved profile records what was proven on a particular rig; it does not claim that future hardware is connected or correctly routed.
- Review transport and synchronized traces support learning and evidence inspection. They do not add deck emulation, live mixing, DAW editing, or performance-out routing.

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
