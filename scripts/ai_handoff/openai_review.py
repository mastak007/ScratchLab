#!/usr/bin/env python3
"""
openai_review.py — Send a Claude Code handoff report to OpenAI for an
architecture / code-review critique, and save the response to disk.

This is TOOLING ONLY. It does not touch product code, Swift sources, or the
Xcode project. It reads a Markdown report Claude wrote and asks an OpenAI
model to critique it as a skeptical architecture reviewer.

Security:
  - Requires OPENAI_API_KEY in the environment.
  - The key is never printed and never written to disk.
  - Fails safely (clear message, non-zero exit) if the key is missing.

Usage:
  python3 scripts/ai_handoff/openai_review.py \
      --report build/ai_handoff/claude_report.md \
      --out    build/ai_handoff/openai_review.md

Environment:
  OPENAI_API_KEY   (required) — your OpenAI API key.
  OPENAI_MODEL     (optional) — model name. Defaults to a conservative current
                                model; override to use a different one.

Exit codes:
  0  success
  1  missing/invalid arguments, missing report, or output error
  2  OPENAI_API_KEY not set
  3  openai package not installed
  4  API call failed
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Default to a conservative, widely-available current model. Override with
# OPENAI_MODEL without editing this file.
DEFAULT_MODEL = "gpt-4.1"

REVIEWER_INSTRUCTIONS = """\
You are an architecture and code-review critic for ScratchLab, a Swift/SwiftUI
multiplatform DJ scratch capture, notation, coaching, review, and export app.

You are reviewing a handoff report written by Claude Code (an executor agent).
Your job is to critique that report rigorously, like a senior reviewer who is
responsible for catching mistakes before any code is written or committed.

HARD CONSTRAINTS — read carefully:
- You do NOT have access to the repository, the build system, the tests, or any
  file beyond the report text you are given. Do not pretend otherwise.
- Never claim to have inspected code, run builds, or run tests. You have only
  the report.
- Clearly distinguish EVIDENCE (something the report actually states or shows)
  from INFERENCE (something you are assuming or guessing). Label your inferences.
- If the report lacks the evidence needed to justify a conclusion, say the
  evidence is missing rather than filling the gap with assumptions.
- Be direct and specific. Prefer concrete, actionable feedback over praise.

ScratchLab guardrails you should respect in your recommendations (from the
project's PROFILE/SOUL): exact 23-class recognition is not production-ready;
classifier labels must not be treated as truth in Practice/Review; audio-onset
timing is preview-only and not saved/exported/scored; captured notation is the
source of truth; do not recommend bundling .mlmodel/.mlpackage artifacts; do not
recommend touching signing, entitlements, Info.plist, or export schema unless
the report explicitly calls for it; no overclaiming ML in user-facing copy.

Produce your review in Markdown with EXACTLY these sections, in this order:

# OpenAI Review

## Agreement / Disagreement
What in the report you agree with, and what you disagree with, and why.

## Risky Assumptions
Assumptions in the report that could be wrong and would cause problems if they are.

## Missing Evidence
Specific facts, files, measurements, or test results the report would need to
provide before its conclusions can be trusted. Be concrete about what to gather.

## Should Implementation Proceed?
A clear verdict: PROCEED, PROCEED WITH CHANGES, or DO NOT PROCEED YET — with the
reasoning. If "with changes", list the changes.

## Is Another Read-Only Investigation Needed?
Yes/No and exactly what to investigate (read-only — no edits) if yes.

## Suggested Next Claude Prompt
A concrete, copy-pasteable prompt the user can give Claude Code for the next
step. Keep it scoped and testable.

## Commit Safety Notes
Anything about commit hygiene, scope, dirty files, or things that must NOT be
committed (per the guardrails above).

## Build / Test Recommendations
What to build and test (and how) to validate the work, given this is a Swift
multiplatform app. Note where you are inferring the commands rather than knowing
them.
"""


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a Claude handoff report to OpenAI for review.",
    )
    parser.add_argument(
        "--report",
        required=True,
        help="Path to the Claude report Markdown file.",
    )
    parser.add_argument(
        "--out",
        default="build/ai_handoff/openai_review.md",
        help="Path to write the OpenAI review Markdown (default: "
        "build/ai_handoff/openai_review.md).",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Override the model (otherwise uses OPENAI_MODEL or the built-in "
        "default).",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    # 1. Validate the report path before doing anything else.
    report_path = Path(args.report)
    if not report_path.is_file():
        print(f"ERROR: report not found: {report_path}", file=sys.stderr)
        return 1
    report_text = report_path.read_text(encoding="utf-8")
    if not report_text.strip():
        print(f"ERROR: report is empty: {report_path}", file=sys.stderr)
        return 1

    # 2. Require the API key. Never print it; never store it.
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print(
            "ERROR: OPENAI_API_KEY is not set.\n"
            "Export it in your shell (it is read from the environment only and "
            "is never printed or written to disk):\n"
            "    export OPENAI_API_KEY='sk-...'\n",
            file=sys.stderr,
        )
        return 2

    # 3. Import the official OpenAI client lazily so the missing-key and
    #    missing-report checks above can run without the package installed.
    try:
        from openai import OpenAI
    except ImportError:
        print(
            "ERROR: the 'openai' Python package is not installed.\n"
            "Install it with:\n"
            "    python3 -m pip install openai\n",
            file=sys.stderr,
        )
        return 3

    model = args.model or os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL

    # 4. Build the input and call the Responses API.
    user_input = (
        "Below is the Claude Code handoff report. Review it per your "
        "instructions. Remember: you only have this report — no repo access.\n\n"
        "----- BEGIN CLAUDE REPORT -----\n"
        f"{report_text}\n"
        "----- END CLAUDE REPORT -----\n"
    )

    print(f"Sending report to OpenAI (model: {model}) ...", file=sys.stderr)
    try:
        client = OpenAI()  # reads OPENAI_API_KEY from the environment
        response = client.responses.create(
            model=model,
            instructions=REVIEWER_INSTRUCTIONS,
            input=user_input,
        )
    except Exception as exc:  # noqa: BLE001 - surface any client/API failure
        # Print the exception type/message but not the key (the SDK does not
        # echo the key in its errors).
        print(f"ERROR: OpenAI API call failed: {exc}", file=sys.stderr)
        return 4

    review_text = getattr(response, "output_text", "") or ""
    if not review_text.strip():
        print(
            "ERROR: OpenAI returned an empty review. Nothing written.",
            file=sys.stderr,
        )
        return 4

    # 5. Write the review to disk.
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(review_text, encoding="utf-8")

    print(f"Review written to: {out_path}", file=sys.stderr)
    print(f"Model used: {model}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
