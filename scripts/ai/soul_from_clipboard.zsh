#!/bin/zsh

set -euo pipefail

if ! command -v pbpaste >/dev/null 2>&1; then
  echo "pbpaste is required." >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI is required in PATH." >&2
  exit 1
fi

project_dir="$(pwd)"
tmpfile="$(mktemp "${TMPDIR:-/tmp}/scratchlab-claude-plan.XXXXXX")"
trap 'rm -f "$tmpfile"' EXIT

clipboard_contents="$(pbpaste)"

cat >"$tmpfile" <<EOF
Implement the following ChatGPT plan. Follow CLAUDE.md and SOUL.md.

<<<PLAN
$clipboard_contents
PLAN>>>
EOF

echo "Project directory: $project_dir"
echo "Sending wrapped plan from clipboard to claude..."

claude <"$tmpfile"
