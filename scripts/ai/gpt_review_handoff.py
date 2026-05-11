#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path

ALLOWED_REVIEW_STATUSES = {
    "APPROVED_TO_CONTINUE",
    "NEEDS_FIXES",
    "HUMAN_DECISION_REQUIRED",
    "COMMIT_APPROVAL_REQUIRED",
    "TASK_COMPLETE",
}

REVIEWER_PROMPT = """You are ChatGPT acting as ScratchLab architect/reviewer.
Review AI_HANDOFF.md.
Do not pretend you can see local files beyond the pasted handoff.
Apply ScratchLab constraints:
- no model training unless explicit
- no model bundling unless explicit
- no export/schema changes unless explicit
- no scoring/Practice/coaching changes unless explicit
- no signing/Info.plist/PrivacyInfo/resource changes unless explicit
- no YouTube/Ortofon training use
- no Co-Authored-By trailers
- commits/pushes require Karl approval
Return the first line exactly as:
REVIEW_STATUS: <one allowed value>
Then output exactly:
1. REVIEW_STATUS: one of APPROVED_TO_CONTINUE, NEEDS_FIXES, HUMAN_DECISION_REQUIRED, COMMIT_APPROVAL_REQUIRED, TASK_COMPLETE
2. SUMMARY
3. RISKS
4. NEXT_CLAUDE_PROMPT

REVIEW_STATUS semantics:
- APPROVED_TO_CONTINUE: more bounded Claude work is needed and is approved to run now.
- NEEDS_FIXES: Claude must fix issues identified before the task can advance.
- HUMAN_DECISION_REQUIRED: Karl must make a decision before any further Claude work.
- COMMIT_APPROVAL_REQUIRED: Karl must approve a commit/push before any further Claude work.
- TASK_COMPLETE: all required work for the current task is done; no further Claude action is needed. Use this when there is no remaining bounded action that would meaningfully change the codebase or AI_HANDOFF.md. Do not pad with redundant documentation passes.

Rules for NEXT_CLAUDE_PROMPT:
- Write it for Claude Code as a non-interactive executor prompt.
- Assign exactly one bounded next action.
- If REVIEW_STATUS is APPROVED_TO_CONTINUE or NEEDS_FIXES, instruct Claude to perform the bounded action, update AI_HANDOFF.md with what changed / tests / remaining risks, then stop.
- If REVIEW_STATUS is TASK_COMPLETE, NEXT_CLAUDE_PROMPT must be a single line stating that no further Claude action is required. The loop will not invoke Claude.
- Do not ask Claude to only prepare a plan.
- Do not ask Claude to only answer reviewer questions.
- Do not ask Claude to wait for more input unless REVIEW_STATUS is HUMAN_DECISION_REQUIRED or COMMIT_APPROVAL_REQUIRED.
- Restate the active ScratchLab constraints relevant to the task.
- End with a direct instruction to stop after completing the bounded action and to not commit or push."""


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def extract_text(response) -> str:
    text = getattr(response, "output_text", None)
    if text:
        return text.strip()

    parts: list[str] = []
    for item in getattr(response, "output", []) or []:
        for content in getattr(item, "content", []) or []:
            if getattr(content, "type", "") == "output_text":
                value = getattr(content, "text", "")
                if value:
                    parts.append(value)
    return "\n".join(parts).strip()


def extract_next_claude_prompt(review_text: str) -> str | None:
    pattern = re.compile(
        r"NEXT_CLAUDE_PROMPT\s*(?:\n|:)\s*(.*)\Z",
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(review_text)
    if not match:
        return None
    prompt = match.group(1).strip()
    return prompt or None


def extract_review_status(review_text: str) -> str | None:
    for raw_line in review_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        normalized = line.replace("**", "").replace("`", "")
        normalized = re.sub(r"^\d+\.\s*", "", normalized)
        match = re.match(
            r"^REVIEW_STATUS\s*(?::|-)\s*([A-Z_]+)\s*$",
            normalized,
            re.IGNORECASE,
        )
        if not match:
            continue
        candidate = match.group(1).upper()
        if candidate in ALLOWED_REVIEW_STATUSES:
            return candidate
    return None


def safe_stop_next_prompt() -> str:
    return (
        "Stop. GPT review status parsing failed.\n"
        "Ask Karl to inspect AI_HANDOFF/gpt_review.md and decide the next step.\n"
        "Do not commit or push."
    )


def main() -> int:
    handoff_arg = sys.argv[1] if len(sys.argv) > 1 else "AI_HANDOFF.md"
    handoff_path = Path(handoff_arg)
    if not handoff_path.exists():
        fail(f"Handoff file not found: {handoff_path}")

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        fail("OPENAI_API_KEY is required.")

    try:
        from openai import OpenAI
    except ImportError:
        fail("OpenAI Python package is not installed.\nInstall it with: python3 -m pip install openai")

    project_root = Path.cwd()
    review_path = project_root / "AI_HANDOFF" / "gpt_review.md"
    next_prompt_path = project_root / "AI_HANDOFF" / "next_claude_prompt.md"
    review_status_path = project_root / "AI_HANDOFF" / "review_status.txt"
    review_path.parent.mkdir(parents=True, exist_ok=True)

    handoff_text = handoff_path.read_text(encoding="utf-8")
    model = os.environ.get("OPENAI_REVIEW_MODEL", "gpt-5.5")

    client = OpenAI(api_key=api_key)
    response = client.responses.create(
        model=model,
        input=[
            {
                "role": "system",
                "content": [{"type": "input_text", "text": REVIEWER_PROMPT}],
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": f"AI_HANDOFF.md\n\n{handoff_text}",
                    }
                ],
            },
        ],
    )

    review_text = extract_text(response)
    if not review_text:
        fail("OpenAI returned an empty review response.")

    review_path.write_text(review_text + "\n", encoding="utf-8")

    review_status = extract_review_status(review_text)
    next_prompt = extract_next_claude_prompt(review_text)
    if review_status is None:
        review_status = "HUMAN_DECISION_REQUIRED"
        next_prompt = safe_stop_next_prompt()
        review_status_path.write_text(review_status + "\n", encoding="utf-8")
        next_prompt_path.write_text(next_prompt + "\n", encoding="utf-8")
        print(f"Saved GPT review to {review_path}")
        print(f"Saved review status to {review_status_path}")
        print(f"Saved next Claude prompt to {next_prompt_path}")
        fail("Could not parse REVIEW_STATUS safely from GPT response.")

    if next_prompt is None:
        next_prompt = safe_stop_next_prompt()

    review_status_path.write_text(review_status + "\n", encoding="utf-8")
    next_prompt_path.write_text(next_prompt.strip() + "\n", encoding="utf-8")

    print(f"Saved GPT review to {review_path}")
    print(f"Saved review status to {review_status_path}")
    print(f"Saved next Claude prompt to {next_prompt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
