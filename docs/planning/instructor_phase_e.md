---
title: ScratchLab Phase E — Instructor Network + School Operations
role: School / instructor ecosystem — thin local-first layer over Phase D Studio outputs that opens package portability, instructor-side review tooling, and structured curriculum scaffolding, without becoming a social platform, an LMS clone, or an AI battle judge.
status: active planning (not shipped; gated on Phase D-S δ and Phase D-A γ checkpoints)
source: extracted verbatim from `glowing-dazzling-sketch.md` Phase E section
related docs:
  - [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) — master roadmap, cross-phase honesty model (Section X), cross-phase hard constraints (Section Z)
  - [replay_phase_d.md](./replay_phase_d.md) — Phase E consumes Studio packages, annotation sidecars, drill sidecars, cinematic videos, spatial sessions from all three D tracks
  - [coaching_phase_c.md](./coaching_phase_c.md) — Phase E inherits Phase C's silence rule and honest-vocabulary discipline
  - [spatial_phase_f.md](./spatial_phase_f.md) — Phase F is gated 60 days after Phase E δ
  - [README.md](./README.md) — planning index
last updated: 2026-05-28
---

# ScratchLab Phase E — Instructor Network + School Operations Layer

## Purpose

Phases A–D made ScratchLab a credible personal training, analysis, export, and spatial replay system. Phase E asks: **how does it become usable by real scratch instructors, schools, and workshops — without becoming a social platform, an LMS clone, or an AI battle judge?**

Instructor tooling is a thin layer over Phase D's three tracks, sharing what Studio produces (annotation sidecars, drill sidecars, studio packages, exported videos, spatial sessions) via deterministic, local-first, additive mechanisms. Instructors are macOS-first power users of the same Studio. The student-instructor relationship is implemented by **package exchange**, not by an account system.

**Phase E does NOT open cloud sync, social features, or AI judgment.** It opens **package portability** + **instructor-side review tooling** + **structured curriculum scaffolding** — and stops there.

## Current state

Phase E cannot begin until Phase D-A γ-D (export package shipped), Phase D-X γ-DX (creator/instructor cohort happy with exports), and Phase D-S δ-DS (honesty grammar audit passed on spatial surfaces) are all stable. Before **Phase E**: minimum 4 weeks of δ-DS feedback. Phase E opens instructor sharing; package format and spatial format must both be stable.

## Design principles

A way for an instructor to:
- Assign a curriculum chunk (drill pack + reference notation).
- Receive a student-completed package.
- Review the package, annotate it (D-A3), optionally export cinematic feedback (D-X3), and return.
- Track progression across assignments.

All local-first, all package-based, all explainable.

**Phase E inherits from D-X:** exported phrase-comparison videos become a standard feedback artifact. Instructor sends back not just an annotated package but a 60-second comparison video the student can watch on a phone.

**Phase E inherits from D-S:** if both instructor and student have Vision Pro, the package opens in a shared spatial replay theatre (asynchronous; no live multiplayer).

### The silence rule

Identified human territory — Phase E never automates:

- **Instructors judge:** style, originality, battle creativity, performance energy, groove, swing, musicality, crowd response, improvisation quality, taste, expression.
- **Students self-reflect on:** intent, focus, satisfaction, frustration, what felt good, what didn't, what to try next.
- **App can support structurally:** timing windows, phrase boundaries, drift magnitudes, primitive counts, release-tail durations, repetition counts.
- **App cannot automate honestly:** anything in the instructor-judges list above.

The moment musical interpretation begins, the app falls silent. Silence is a feature.

## Slice roadmap

### E1 — Roster + assignment queue (MINIMAL FIRST SLICE)

- macOS-only "Instructor" panel inside Studio, gated by `INSTRUCTOR_MODE`.
- Lists students by local name string; per student, points to a folder where instructor receives Phase D Studio packages from that student.
- No new schemas — uses file system + Phase D packages.
- → **TestFlight Checkpoint α-E** (instructor cohort of 3–5).

### E2 — Drill pack authoring + instructor pack format

- New sidecar `scratchlab_instructor_pack_v1`: bundles drills (from D-A5) + reference notation + assignment metadata.

### E3 — Annotation exchange workflow

- Instructor opens student package, annotates (D-A3), exports annotated package; student imports and views annotations attributed to instructor.
- → **TestFlight Checkpoint β-E** (full instructor↔student loop validated).

### E4 — Per-student timeline view (read-only)

- Chronological package archive per student.

### E5 — Replay lesson format

- New sidecar `scratchlab_replay_lesson_v1`: instructor authors guided review walkthroughs.
- May include exported D-X3 cinematic video as part of the lesson.

### E6 — Curriculum packs + ordering

- Drill packs with optional prerequisite metadata.
- → **TestFlight Checkpoint γ-E** (workshop or school).

### E7 — Phrase-keyed feedback

- C6b "needs review" hint extended with per-phrase instructor flags.
- → **TestFlight Checkpoint δ-E** (final pre-Phase-F gate).

## Safe before TestFlight

Phase E is gated on Phase D δ-DS + 4 weeks. Within Phase E, **E1 is the minimal first slice** and the only thing safe to land at the start. It introduces zero new schema — just a file-system convention and a macOS-only panel.

## Deferred / post-TestFlight

E2 through E7 all sit behind their own checkpoints. E2 (instructor pack format) is the first to introduce a new sidecar; everything downstream depends on it being stable.

## Risks

### E explicit non-goals

- AI battle judging. Never.
- Cloud sync. Defer indefinitely.
- Public profiles. Never.
- Social media feed mechanics. Never.
- Auto-grading, auto-certification, skill ranking. Never.
- Marketplace, monetization, in-app pricing. Never.
- Live video/audio between instructor and student. Out of scope; use any other tool.
- Personalized AI coaching tone. Never.

The silence rule (above) is enforced by code review — any PR that automates one of the items in "instructors judge" should be rejected.

## Verification gates

Per `[[feedback_verification_scope]]`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` clean.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` clean.
4. Flag wiring verified in `FeatureFlags.swift`.
5. Copy review against PROFILE.md vocabulary.
6. No `Co-Authored-By` trailers per `[[feedback_no_coauthor_trailer]]`.

### Phase E specifically

- **Sidecar round-trip lossless test** for every new sidecar kind (`scratchlab_instructor_pack_v1`, `scratchlab_replay_lesson_v1`, etc.).
- **Original sidecar bytes unchanged** after every Studio/Instructor write. Studio writes new optional sidecars alongside the original; the original is sacred.

## Links back to master roadmap

- Master Phase E section: [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase honesty model (Section X): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Cross-phase hard constraints (Section Z): [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md)
- Phase D inputs to Phase E (annotation sidecar D-A3, drill sidecar D-A5, studio package D-A7, cinematic exports D-X3, spatial sessions D-S4): [replay_phase_d.md](./replay_phase_d.md)
- Phase C silence vocabulary that Phase E extends: [coaching_phase_c.md](./coaching_phase_c.md)
