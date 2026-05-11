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

timeout_seconds="${CLAUDE_ONCE_TIMEOUT_SECONDS:-300}"
prompt_text="$(cat AI_HANDOFF/next_claude_prompt.md)"
wrapped_prompt=$'Run non-interactively.\nPerform exactly one bounded task.\nIf you make progress, update AI_HANDOFF.md before exiting.\nDo not ask follow-up questions unless blocked by a missing decision.\nDo not commit or push.\n\n'"$prompt_text"
transcript_path="AI_HANDOFF/claude_once_output.md"
tmp_output="$(mktemp "${TMPDIR:-/tmp}/scratchlab-claude-once.XXXXXX")"
trap 'rm -f "$tmp_output"' EXIT

claude --permission-mode acceptEdits -p "$wrapped_prompt" >"$tmp_output" 2>&1 &
claude_pid=$!

elapsed=0
while kill -0 "$claude_pid" >/dev/null 2>&1; do
  if [ "$elapsed" -ge "$timeout_seconds" ]; then
    kill "$claude_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$claude_pid" >/dev/null 2>&1 || true
    cp "$tmp_output" "$transcript_path"
    echo "Claude timed out after ${timeout_seconds}s. Transcript saved to $transcript_path" >&2
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

wait "$claude_pid"
cp "$tmp_output" "$transcript_path"
cat "$tmp_output"
