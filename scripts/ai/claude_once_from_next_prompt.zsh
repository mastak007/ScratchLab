#!/bin/zsh

set -euo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI is required in PATH." >&2
  exit 1
fi

if [ ! -f AI_HANDOFF/next_claude_prompt.md ]; then
  echo "AI_HANDOFF/next_claude_prompt.md is missing." >&2
  exit 1
fi

claude --permission-mode acceptEdits -p "$(cat AI_HANDOFF/next_claude_prompt.md)"
