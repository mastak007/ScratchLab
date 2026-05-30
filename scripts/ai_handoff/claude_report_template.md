# Claude Code Handoff Report

> Copy this template to `build/ai_handoff/claude_report.md`, fill it in, then run
> `scripts/ai_handoff/run_openai_review.sh` to get an OpenAI critique.
>
> Be explicit about what is **evidence** (you actually read it / ran it) versus
> **inference** (you are assuming it). The reviewer is instructed to hold you to
> that distinction.

## 1. Task / Goal
What is being attempted, in one or two sentences. Link to the originating plan if
there is one.

## 2. Branch / Worktree State
- Current branch:
- Pre-existing dirty files (must be preserved):
- Files this work intends to touch:

## 3. What I Investigated (Evidence)
Concrete things you read or ran. Cite `file_path:line` where possible. This is the
evidence the reviewer is allowed to rely on.

- 

## 4. What I Inferred (Not Yet Verified)
Assumptions and guesses you have NOT confirmed from the code/tests. Be honest —
the reviewer will probe these.

- 

## 5. Proposed Change / Plan
The concrete plan: which files, what edits, in what order. Keep diffs small.

- 

## 6. Risks & Guardrails
How this interacts with ScratchLab guardrails (ML truth, Review truth, export
schema, signing/entitlements, no bundling of model artifacts, App Store copy).

- 

## 7. Build / Test Plan
How you intend to verify the change (which targets build, which tests run).

- 

## 8. Open Questions for the Reviewer
Specific things you want a second opinion on.

- 
