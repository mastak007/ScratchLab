# ScratchLab Agent Instructions

You are working in the ScratchLab repository.

---

## AI Workflow (Codex, Claude Code, ChatGPT)

This repository is worked on by multiple AI assistants with distinct roles:

- **Codex** reads `AGENTS.md` (this file) as its entry point.
- **Claude Code** reads `CLAUDE.md` as its entry point.
- **ChatGPT** acts as architect and reviewer.
- **Codex and Claude Code** are the executors that read, edit, and run.

ChatGPT may hand a plan to an executor inside a delimited block:

```text
<<<PLAN
...
PLAN>>>
```

Treat that block as architecture and review guidance from ChatGPT. Read the full plan before editing anything.

Before any project work, every executor must:

1. Read `SOUL.md` (executor rules shared by Codex and Claude Code).
2. Read `PROFILE.md` (product, ML, review, and App Store safety profile).
3. Inspect `git status --short --branch`.
4. Also read the project context files listed under "Read First" below.

Executor rules (apply to both Codex and Claude Code):

- Check the current branch or worktree before editing.
- Identify pre-existing dirty files before making changes.
- Preserve unrelated dirty files.
- Use small, reviewable diffs.
- Do not commit without explicit approval.
- Do not push without explicit approval.
- Do not add `Co-Authored-By` trailers to any commit.
- Before stopping mid-task or when context is high (compaction imminent), write or update:
  - `AI_HANDOFF.md` (current handoff record).
  - `AI_HANDOFF/next_prompt.md` (continuation prompt for the next session).

Shared workflow files:

- `SOUL.md`: executor rules shared by Codex and Claude Code.
- `PROFILE.md`: product, ML, review, and App Store safety profile.
- `CLAUDE.md`: Claude Code entry point.
- `AGENTS.md`: this file. Codex entry point and shared rules.
- `AI_HANDOFF.md`: current handoff record.
- `AI_HANDOFF/next_prompt.md`: continuation prompt template.

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
5. Run the checks required for the change's scope under Build Rules below
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
- the affected-platform build succeeds OR failure is clearly unrelated
- the required tests for the change's scope pass; report unrelated failures explicitly
- `DEV_LOG.md` updated
- `TASKS.md` updated correctly

---

## Build Rules
- User-selected cadence (18 October 2026): focused tests and an affected-platform build per fix; full suite for capture/data/shared changes and release candidates.
- For routine platform-specific UI or layout fixes, run the affected behavior/layout/playback tests and a direct affected-target `xcodebuild` in owned output directories. Group related edits before repeating checks.
- Run `scripts/build.sh all` for changes to capture, audio/MIDI, calibration, persistence, stored data, schemas, export, shared business logic/geometry, and release candidates. It covers the native/Python suites and iOS, macOS and Watch builds.
- Every current `scripts/build.sh` mode, including `cxl` and `mac`, runs the complete native suite. Do not use those modes as a shortcut for a targeted iteration build.
- For focused native tests, use `scripts/run_mac_test_gate.py --project ScratchLab.xcodeproj --mode software --only-testing ClassName/testMethod`; repeat `--only-testing` for related cases. Keep the supervisor's process ownership, evidence and admission checks. Do not reuse a complete-gate prepared context for a focused invocation.
- Reuse passing receipts when the relevant source, configuration and dependencies are unchanged. Rerun affected checks after relevant changes or a failure; do not blindly repeat a failed gate or weaken assertions, identity/loss checks, or timing limits to obtain a pass.
- Stop downstream installation/release work on a required failure, diagnose its cause, then verify the bounded repair before resuming. Software, installation, live UI and physical acceptance remain separate.
- An explicitly authorized work-in-progress checkpoint may record pending or failed verification honestly; it does not require a new full run or establish release readiness. Commit/push authorization rules still apply.

### CXL Mac installation identity

- Stage CXL Mac updates with `scripts/stage_cxl_mac.py` before installation. Do not reuse external ad hoc `codesign --sign -` recipes: Apple documents unreliable Local Network identity tracking for these across builds.
- Retain `com.machelpnz.scratchlab.cxl-authoring`, the existing permissions/entitlements, and signing team `2DDKGL33BU`. Use a valid Apple-issued certificate from that team. A successful `codesign --verify` alone is insufficient; retain the staging receipt proving the team and designated requirement.
- Preserve captures and the previous app before an authorized in-place update. Verify the running executable matches the staged receipt. Connected iPhone/Watch status is not proof of Mac relay or captured Watch motion; confirm those separately.

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

If UI shows it -> it MUST be persisted and exported

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
