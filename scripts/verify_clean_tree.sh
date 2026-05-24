#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

echo "== git status --short --branch =="
git status --short --branch

if [[ -n "$(git status --porcelain)" ]]; then
  echo "FAIL: working tree is dirty" >&2
  exit 1
fi

echo "== local log =="
git log --oneline -6

echo "== fetch origin main =="
git fetch origin main

echo "== origin/main log =="
git log --oneline origin/main -6

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"

if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "FAIL: local HEAD != origin/main" >&2
  echo "local : $LOCAL" >&2
  echo "remote: $REMOTE" >&2
  exit 1
fi

echo "PASS: clean tree and local HEAD matches origin/main"
