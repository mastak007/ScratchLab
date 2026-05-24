#!/usr/bin/env bash
set -euo pipefail

ROOT="${SCRATCHLAB_ROOT:-/Users/karlwatson/Downloads/ScratchLab}"
NAME="${1:?usage: scripts/make_worktree.sh <slice-name>}"
TARGET="$(dirname "$ROOT")/ScratchLab-${NAME}"

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "FAIL: main worktree is dirty. Clean or commit first." >&2
  git status --short --branch >&2
  exit 1
fi

if [[ -e "$TARGET" ]]; then
  echo "FAIL: target already exists: $TARGET" >&2
  exit 1
fi

git fetch origin main
git worktree add "$TARGET" main

echo "PASS: created worktree at $TARGET"
echo "Next:"
echo "  cd \"$TARGET\""
