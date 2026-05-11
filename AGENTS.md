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
