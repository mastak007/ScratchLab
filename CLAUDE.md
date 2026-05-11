# Claude Code Entry Point

This file is the Claude Code project instruction entry point for ScratchLab.

Before any project work:
1. Read `SOUL.md`.
2. Read `PROFILE.md`.
3. Inspect `git status --short --branch`.

If ChatGPT provides a plan delimited as:

```text
<<<PLAN
...
PLAN>>>
```

Treat that block as the implementation spec from ChatGPT. Read the full plan before editing anything.

Execution rules for Claude Code:
- Use small, testable diffs.
- Stop and ask if the plan conflicts with `PROFILE.md`.
- Check the current branch or worktree before editing.
- Identify pre-existing dirty files before making changes.
- Preserve unrelated dirty files.
- Do not commit or push without explicit approval.
- Do not add `Co-Authored-By` trailers.
- Write `AI_HANDOFF.md` and `AI_HANDOFF/next_prompt.md` before `/clear`, `compact`, or stopping mid-task.

Shared workflow files:
- `SOUL.md`: executor rules shared by Claude Code and Codex.
- `PROFILE.md`: product, ML, review, and App Store safety profile.
- `AI_HANDOFF.md`: current handoff record.
- `AI_HANDOFF/next_prompt.md`: continuation prompt template.
