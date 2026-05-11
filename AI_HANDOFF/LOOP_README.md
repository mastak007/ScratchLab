# Claude ↔ GPT Loop

ChatGPT web cannot automatically read local Mac files. This workflow uses the OpenAI API as the GPT reviewer for local `AI_HANDOFF.md` content.

Loop model:
- Claude writes `AI_HANDOFF.md`.
- GPT reviews `AI_HANDOFF.md` through the OpenAI API.
- GPT writes `AI_HANDOFF/gpt_review.md`.
- The next Claude step is extracted into `AI_HANDOFF/next_claude_prompt.md`.
- Claude runs that next prompt.
- Karl remains the approval gate for commits, pushes, and risky product decisions.

Files:
- `scripts/ai/gpt_review_handoff.py`: sends `AI_HANDOFF.md` to GPT and writes review outputs locally.
- `scripts/ai/claude_once_from_next_prompt.zsh`: runs Claude once from `AI_HANDOFF/next_claude_prompt.md`.
- `scripts/ai/claude_gpt_loop.zsh`: repeats the review/implement cycle with guardrails.
- `AI_HANDOFF/loop_config.example.env`: example environment config.

How to run:

```sh
export OPENAI_API_KEY=...
scripts/ai/gpt_review_handoff.py
scripts/ai/claude_gpt_loop.zsh 3
```

When to stop:
- `HUMAN_DECISION_REQUIRED`
- `COMMIT_APPROVAL_REQUIRED`
- dirty git state
- build/test failure
- risky file changes

Safety notes:
- The loop does not commit, push, merge, rebase, reset, clean, or stash.
- The loop refuses to start unless git status is clean or only `AI_HANDOFF.md` / `AI_HANDOFF/*` are modified.
- The GPT reviewer only sees pasted handoff content, not arbitrary local files.
