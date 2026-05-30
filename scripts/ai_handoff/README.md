# AI Handoff Review Workflow

A repo-local loop where **Claude Code** writes a handoff report, **OpenAI**
reviews it as an architecture/code-review critic, the review is saved to disk,
and Claude continues from that review.

This is **tooling only**. It does not modify product code, Swift sources, or the
Xcode project. It only reads a Markdown report and writes a Markdown review.

## Files

| Path | Purpose | Committed? |
| --- | --- | --- |
| `scripts/ai_handoff/claude_report_template.md` | Template for Claude's report | yes (tooling) |
| `scripts/ai_handoff/openai_review.py` | OpenAI Responses API client | yes (tooling) |
| `scripts/ai_handoff/run_openai_review.sh` | Shell wrapper | yes (tooling) |
| `scripts/ai_handoff/README.md` | This file | yes (tooling) |
| `build/ai_handoff/claude_report.md` | Claude's report (generated) | **no** — under `build/`, gitignored |
| `build/ai_handoff/openai_review.md` | OpenAI's review (generated) | **no** — under `build/`, gitignored |

Generated reports live under `build/ai_handoff/`, which is already covered by
`.gitignore` (`build/`). They are **not** committed by default.

## The Loop

1. **Claude writes the report** → `build/ai_handoff/claude_report.md`
   (start from `scripts/ai_handoff/claude_report_template.md`).
2. **User runs the review**:
   ```bash
   scripts/ai_handoff/run_openai_review.sh build/ai_handoff/claude_report.md
   ```
3. The script sends the report to OpenAI using `OPENAI_API_KEY`.
4. The review is saved to → `build/ai_handoff/openai_review.md`.
5. **Claude reads** `build/ai_handoff/openai_review.md` and decides the next action.

## Setup

### 1. Export your OpenAI API key

The key is read from the environment only. It is **never printed and never
written to disk** by these scripts.

```bash
export OPENAI_API_KEY='sk-...'
```

### 2. (Optional) Choose a model

```bash
export OPENAI_MODEL='gpt-4.1'   # default; override with any model you have access to
```

### 3. Install the OpenAI Python package (one time)

```bash
python3 -m pip install openai
```

If it is missing, the script tells you this exact command and exits cleanly.

## Usage

### Create a Claude report

Ask Claude Code to fill in the template and save it:

```text
Write build/ai_handoff/claude_report.md from
scripts/ai_handoff/claude_report_template.md, filling in the current task,
branch state, evidence vs. inference, plan, risks, and build/test plan.
```

### Run the review

```bash
# defaults: build/ai_handoff/claude_report.md -> build/ai_handoff/openai_review.md
scripts/ai_handoff/run_openai_review.sh

# or explicit paths
scripts/ai_handoff/run_openai_review.sh build/ai_handoff/claude_report.md build/ai_handoff/openai_review.md
```

You can also call the Python client directly:

```bash
python3 scripts/ai_handoff/openai_review.py \
  --report build/ai_handoff/claude_report.md \
  --out    build/ai_handoff/openai_review.md
```

### Paste the review back into Claude

Either point Claude at the file:

```text
Read build/ai_handoff/openai_review.md and decide the next action.
```

…or paste its contents into the Claude prompt directly. The review ends with a
**Suggested Next Claude Prompt** section you can use as the next step.

## What the reviewer does

The OpenAI reviewer acts as a skeptical architecture/code-review critic and
returns Markdown with these sections:

- Agreement / Disagreement
- Risky Assumptions
- Missing Evidence
- Should Implementation Proceed?
- Is Another Read-Only Investigation Needed?
- Suggested Next Claude Prompt
- Commit Safety Notes
- Build / Test Recommendations

It is explicitly instructed that it has **only the report** — no repo access —
and that it must distinguish **evidence** from **inference**.

## Exit codes (`openai_review.py`)

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Bad arguments / missing or empty report / output error |
| 2 | `OPENAI_API_KEY` not set |
| 3 | `openai` package not installed |
| 4 | API call failed or returned empty |

## Security

- **Never commit API keys.** Keep `OPENAI_API_KEY` in your shell environment
  only.
- The scripts never print the key and never write it to disk.
- Generated reports under `build/ai_handoff/` are gitignored. If you ever move
  them elsewhere, make sure that location is gitignored too — reports can contain
  internal details you may not want to commit.
