#!/usr/bin/env bash
#
# run_openai_review.sh — Wrapper to send a Claude handoff report to OpenAI for
# review and save the result.
#
# Tooling only. Does not touch product code, Swift sources, or the Xcode project.
#
# Usage:
#   scripts/ai_handoff/run_openai_review.sh [REPORT] [OUT]
#
#   REPORT   Path to the Claude report (default: build/ai_handoff/claude_report.md)
#   OUT      Path to write the review   (default: build/ai_handoff/openai_review.md)
#
# Environment:
#   OPENAI_API_KEY   (required) — read from the environment only; never printed.
#   OPENAI_MODEL     (optional) — model override.
#
# Examples:
#   export OPENAI_API_KEY='sk-...'
#   scripts/ai_handoff/run_openai_review.sh
#   scripts/ai_handoff/run_openai_review.sh build/ai_handoff/claude_report.md
#   OPENAI_MODEL=gpt-4o scripts/ai_handoff/run_openai_review.sh

set -euo pipefail

# Resolve repo root from this script's location so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPORT="${1:-build/ai_handoff/claude_report.md}"
OUT="${2:-build/ai_handoff/openai_review.md}"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY is not set." >&2
  echo "Export it first (never commit it):" >&2
  echo "    export OPENAI_API_KEY='sk-...'" >&2
  exit 2
fi

# Pick a python interpreter.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "ERROR: no python3/python found on PATH." >&2
  exit 1
fi

cd "${REPO_ROOT}"

exec "${PY}" "${SCRIPT_DIR}/openai_review.py" --report "${REPORT}" --out "${OUT}"
