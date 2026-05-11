#!/usr/bin/env zsh
set -euo pipefail

MAX_ITERATIONS="${1:-3}"

handoff_only_dirty() {
  local git_status
  git_status="$(git status --short)"

  if [[ -z "$git_status" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    local path_part="${line[4,-1]}"

    case "$path_part" in
      AI_HANDOFF.md|AI_HANDOFF/*)
        ;;
      *)
        return 1
        ;;
    esac
  done <<< "$git_status"

  return 0
}

extract_review_status() {
  awk -F': ' '/^REVIEW_STATUS:/ { print $2; exit }' AI_HANDOFF/gpt_review.md
}

if [[ ! -d ".git" && ! -f ".git" ]]; then
  echo "ERROR: run from the repo/worktree root." >&2
  exit 1
fi

if ! handoff_only_dirty; then
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

  local_review_status="$(extract_review_status || true)"

  if [[ -z "$local_review_status" ]]; then
    echo "ERROR: Could not parse REVIEW_STATUS from AI_HANDOFF/gpt_review.md" >&2
    exit 1
  fi

  echo "REVIEW_STATUS: $local_review_status"

  case "$local_review_status" in
    HUMAN_DECISION_REQUIRED|COMMIT_APPROVAL_REQUIRED)
      echo "Stopping for Karl approval: $local_review_status"
      exit 0
      ;;
    NEEDS_FIXES|APPROVED_TO_CONTINUE)
      ;;
    *)
      echo "Unknown REVIEW_STATUS: $local_review_status" >&2
      exit 1
      ;;
  esac

  scripts/ai/claude_once_from_next_prompt.zsh

  if [[ ! -f "AI_HANDOFF.md" ]]; then
    echo "ERROR: Claude finished but AI_HANDOFF.md is missing." >&2
    exit 1
  fi

  if ! handoff_only_dirty; then
    echo "Stopping loop: Claude changed non-handoff files." >&2
    git status --short >&2
    echo "Review changes before continuing."
    exit 0
  fi
done

echo "Reached max iterations: $MAX_ITERATIONS"
echo "Review AI_HANDOFF.md and AI_HANDOFF/gpt_review.md."
