# ScratchLab Agent Instructions

You are working in the ScratchLab repository.

---

## Read First
Always read these files before making changes:
1. `AI_CONTEXT.md`
2. `TASKS.md`
3. `DEV_LOG.md`

---

## Core Objectives
- Complete exactly one small, implementation-ready task at a time
- Prefer minimal, safe, reversible edits
- Keep the app buildable after every change

---

## Operating Rules
- Always choose the first unchecked task in `TASKS.md` that is implementation-ready
- If a task is ambiguous, too large, blocked, or needs an architecture decision, STOP and explain the blocker
- Do not guess or invent missing requirements
- Make the smallest high-confidence change that completes the selected task
- Preserve existing structure, naming, and style unless required
- Do not perform broad refactors unless explicitly requested
- Do not revert unrelated user changes
- If a referenced file does not exist, STOP and report it

---

## Required Workflow
1. Read `AI_CONTEXT.md`, `TASKS.md`, `DEV_LOG.md`
2. Select the first valid unchecked task
3. State which task you selected and why
4. Implement with minimal changes
5. Run `scripts/build.sh`
6. Fix any compile errors introduced
7. Append to `DEV_LOG.md`:
   - selected task
   - files changed
   - build result
   - follow-up notes
8. Mark task complete ONLY if fully done

---

## Definition Of Done
A task is complete only when:
- behavior is implemented
- build succeeds OR failure is clearly unrelated
- `DEV_LOG.md` updated
- `TASKS.md` updated correctly

---

## Build Rules
- Default: `scripts/build.sh`
- Covers: iOS, macOS, Watch
- Platform-specific builds allowed during iteration
- Full build required before completion unless blocked

---

# Product & Architecture Rules

## Product Intent
ScratchLab is a DJ scratch training and data capture system.

Priority order:
1. Capture reliability
2. Metadata accuracy
3. Export correctness
4. App Store safety
5. Shared architecture across platforms

---

## Architecture Rules
- Use shared models across iOS and macOS
- DO NOT duplicate logic per platform
- Platform differences = UI + hardware only
- Session configuration must be a single source of truth
- Any feature added to one platform MUST be evaluated for inclusion in all platforms

---

## Session Metadata Requirements
These MUST flow through full pipeline:
- performer name / DJ ID
- BPM
- scratch type
- drill / mode
- take duration
- take count
- handedness
- notes
- device metadata
- timestamps / session IDs

If UI shows it → it MUST be persisted and exported

---

## Capture Pipeline Rules
- Reliability > features
- No silent failures
- Validation must fail loudly
- Export must match real files
- No hidden assumptions (camA, camB, etc.)

---

## UI Rules
- No dead buttons
- No fake states
- No incomplete flows in production
- macOS must not be a reduced shell if capability exists
- Clear, functional wording only

---

## App Store Safety
- No unimplemented claims
- No misleading capability descriptions
- Permissions must match usage
- Screenshots must reflect real app

---

## Code Change Expectations
- Read existing code before editing
- Reuse patterns where possible
- Keep diffs tight
- Update ALL dependent systems:
  - state
  - persistence
  - validation
  - export
- Report:
  - files changed
  - risks
  - verification steps