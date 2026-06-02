# ScratchLab Planning Index

This folder holds the long-term ScratchLab roadmap, split into a master document plus a Phase A archive and one execution doc per remaining phase. Open the right file for what you're trying to do.

## Files

| File | Purpose | Open when… |
|---|---|---|
| [security_privacy_ip_protection_plan.md](./security_privacy_ip_protection_plan.md) | **Security, Privacy, and IP Protection Track.** Cross-cutting plan for user-sensitive data, Kid Mode research data, exports, storage, privacy manifests, and ScratchLab-sensitive IP. | You're adding storage, exports, analytics, research logging, model artifacts, or anything that could affect App Review privacy declarations. |
| [ttm_execution_plan_v2.md](./ttm_execution_plan_v2.md) | **TTM-informed notation execution plan.** Video-grounded ordering for notation primitives, evidence-derived slices, and delayed family/technique classification. Plan only; no implementation. | You're deciding the next notation primitive work after the v2 TTM audit, or you need the binding corrections to older notation plans. |
| [glowing-dazzling-sketch.md](./glowing-dazzling-sketch.md) | **Master roadmap.** Reality check (current ship state), Section 0 framework gaps, Phase A→F structure, cross-phase honesty model (Section X), verification gates (Section Y), and hard constraints (Section Z). Per-slice detail delegated to phase docs. | You need the whole-product picture, you're deciding what phase to work on, or you need the canonical honesty/verification/constraint reference. |
| [hazy-exploring-grove.md](./hazy-exploring-grove.md) | **Phase A archive.** The planning document that shaped the polish pass now shipped on `release/testflight-1`. Mission statement, slice rationale, philosophy. | You want the philosophy behind a shipped Phase A surface, or you want the rationale for why a particular A-series slice exists. |
| [notation_phase_b.md](./notation_phase_b.md) | **Phase B execution detail.** Surfacing the deterministic notation substrate (phrase boundaries, judgment colors, micro-feedback, momentum HUD, progression visibility, replay/reward) so the lane reads as gameplay rather than a developer renderer. | You're picking up Phase B work, you need the per-slice file lists, or you need the AR-prep contracts to honor while building B. |
| [coaching_phase_c.md](./coaching_phase_c.md) | **Phase C execution detail.** Honest coaching architecture — wire the coaching evaluators that already exist (drift, phrase) into surfaces with pacing and presentation-tier confidence, without becoming a fake AI teacher. | You're picking up Phase C work, you need the per-slice detail, or you need the C confidence model / uncertainty vocabulary. |
| [replay_phase_d.md](./replay_phase_d.md) | **Phase D execution detail.** Studio Mode in three parallel tracks: D-A analysis (scrub, archaeology, annotations, multi-take, drill authoring, workbench, package export), D-X cinematic export (transparent notation video, phrase comparison MP4, NDI feeds), D-S spatial replay / AR (iOS AR ribbon, ghost-take, phrase chapters, Vision Pro theatre, spatial archaeology). | You're picking up Phase D work, you need the per-track slice list, or you need the D-S non-negotiable rules and AR architecture. |
| [instructor_phase_e.md](./instructor_phase_e.md) | **Phase E execution detail.** School / instructor ecosystem — local-first package exchange, instructor-side review tooling, structured curriculum scaffolding. Inherits Studio outputs from all three Phase D tracks. Includes the "silence is a feature" rule. | You're planning instructor / school workflows, designing assignment exchange, or you need to confirm what Phase E explicitly does not do. |
| [spatial_phase_f.md](./spatial_phase_f.md) | **Phase F long-term AR sketch.** Lightweight glasses HUD, performer-only confidence monitor, spectator AR. Gated on D-S δ + E δ + 60 days; detailed slice planning deferred. | You want to understand the long-term AR horizon, or you need to confirm a Phase F-flavored idea is appropriately deferred. |

## How these files relate

```
glowing-dazzling-sketch.md  (master roadmap — load this first)
        │
        ├── hazy-exploring-grove.md     [Phase A — archive of shipped polish]
        │
        ├── notation_phase_b.md         [Phase B — gates C and D-S]
        │     │
        │     ▼
        ├── coaching_phase_c.md         [Phase C — depends on B]
        │     │
        │     ▼
        ├── replay_phase_d.md           [Phase D — D-A + D-X + D-S parallel tracks]
        │     │
        │     ▼
        ├── instructor_phase_e.md       [Phase E — consumes Phase D outputs]
        │     │
        │     ▼
        └── spatial_phase_f.md          [Phase F — gated on E δ + 60 days]
```

The master roadmap is the canonical reference for cross-phase rules. Phase docs hold execution detail. When the two seem to disagree, the master wins for principles/constraints; the phase doc wins for slice-level mechanics.

## Conventions

- All planning files include a front-matter block: title, role, status, source, related docs, last updated.
- Phase docs follow a shared template: Purpose · Current state · Design principles · Slice roadmap · Safe before TestFlight · Deferred / post-TestFlight · Risks · Verification gates · Links back to master.
- Links between planning files are relative (start with `./`) so they resolve from anywhere under `/docs/planning/`.
- `[[name]]`-style links in body text refer to entries in the user's auto-memory and are intentionally not file links.

## Editing rules

- Preserve meaning. Don't invent new commitments while reorganizing.
- Master roadmap is the place for product-strategy changes; phase docs are the place for execution detail.
- Never edit Phase A intent. Phase A is shipped — `hazy-exploring-grove.md` is a historical record.
- No `Co-Authored-By` trailers per project convention.
- No commits or pushes without explicit user approval per `SOUL.md`.
