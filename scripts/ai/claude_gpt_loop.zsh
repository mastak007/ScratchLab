#!/usr/bin/env zsh
set -euo pipefail

MAX_ITERATIONS="${1:-3}"

allowed_dirty_state() {
  local git_status_output
  git_status_output="$(git status --short)"

  if [[ -z "$git_status_output" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    local path_part="${line[4,-1]}"

    case "$path_part" in
      AI_HANDOFF.md|AI_HANDOFF/*|scripts/ai/gpt_review_handoff.py|scripts/ai/claude_gpt_loop.zsh|scripts/ai/claude_once_from_next_prompt.zsh)
        ;;
      *)
        return 1
        ;;
    esac
  done <<< "$git_status_output"

  return 0
}

execution_style_prompt() {
  local prompt_file="AI_HANDOFF/next_claude_prompt.md"
  [[ -f "$prompt_file" ]] || return 1

  if grep -Eiq '\b(prepare a step-by-step implementation plan|write a plan|answer the following|please confirm|reply in the form of|recommend the clear next command)\b' "$prompt_file"; then
    return 1
  fi

  grep -Eiq '\b(update AI_HANDOFF\.md|do not commit or push|stop after)\b' "$prompt_file"
}

if [[ ! -d ".git" && ! -f ".git" ]]; then
  echo "ERROR: run from the repo/worktree root." >&2
  exit 1
fi

if ! allowed_dirty_state; then
  echo "Refusing to run: git status is not clean and includes non-handoff files." >&2
  git status --short >&2
  exit 1
fi

if [[ ! -f "AI_HANDOFF.md" ]]; then
  echo "ERROR: AI_HANDOFF.md not found." >&2
  exit 1
fi

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo "=== Claude/GPT loop iteration $i / $MAX_ITERATIONS ==="

  scripts/ai/gpt_review_handoff.py AI_HANDOFF.md

  if [[ ! -f "AI_HANDOFF/review_status.txt" ]]; then
    echo "ERROR: AI_HANDOFF/review_status.txt is missing." >&2
    exit 1
  fi

  review_status_value="$(tr -d '[:space:]' < AI_HANDOFF/review_status.txt)"

  if [[ -z "$review_status_value" ]]; then
    echo "ERROR: review_status.txt is empty." >&2
    exit 1
  fi

  echo "REVIEW_STATUS: $review_status_value"

  case "$review_status_value" in
    HUMAN_DECISION_REQUIRED|COMMIT_APPROVAL_REQUIRED)
      echo "Stopping for Karl approval: $review_status_value"
      exit 0
      ;;
    TASK_COMPLETE)
      echo "Task complete: GPT reports no further Claude action required."
      exit 0
      ;;
    NEEDS_FIXES|APPROVED_TO_CONTINUE)
      ;;
    *)
      echo "Unknown REVIEW_STATUS: $review_status_value" >&2
      exit 1
      ;;
  esac

  if ! execution_style_prompt; then
    echo "Stopping loop: NEXT_CLAUDE_PROMPT is not an execution-style prompt." >&2
    echo "Review AI_HANDOFF/next_claude_prompt.md before continuing." >&2
    exit 1
  fi

  scripts/ai/claude_once_from_next_prompt.zsh

  if [[ ! -f "AI_HANDOFF.md" ]]; then
    echo "ERROR: Claude finished but AI_HANDOFF.md is missing." >&2
    exit 1
  fi

  if ! allowed_dirty_state; then
    echo "Stopping loop: Claude changed non-handoff files." >&2
    git status --short >&2
    echo "Review changes before continuing."
    exit 0
  fi
done

echo "Reached max iterations: $MAX_ITERATIONS"
echo "Review AI_HANDOFF.md and AI_HANDOFF/gpt_review.md."
