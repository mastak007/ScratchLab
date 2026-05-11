#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path


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
Output exactly:
1. REVIEW_STATUS: one of APPROVED_TO_CONTINUE, NEEDS_FIXES, HUMAN_DECISION_REQUIRED, COMMIT_APPROVAL_REQUIRED
2. SUMMARY
3. RISKS
4. NEXT_CLAUDE_PROMPT"""


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

    next_prompt = extract_next_claude_prompt(review_text)
    if next_prompt is None:
        next_prompt = (
            "Stop. GPT review output could not be parsed safely.\n"
            "Ask Karl to inspect AI_HANDOFF/gpt_review.md and decide the next step.\n"
            "Do not commit or push."
        )
    next_prompt_path.write_text(next_prompt.strip() + "\n", encoding="utf-8")

    print(f"Saved GPT review to {review_path}")
    print(f"Saved next Claude prompt to {next_prompt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
