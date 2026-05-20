#!/usr/bin/env zsh
set -euo pipefail

HANDOFF="${1:-AI_HANDOFF.md}"

if [[ ! -f "$HANDOFF" ]]; then
  echo "ERROR: Handoff file not found: $HANDOFF"
  exit 1
fi

{
  echo "Review this AI_HANDOFF.md and give me the next Claude/Codex prompt."
  echo
  echo "Use the project rules already established:"
  echo "- ChatGPT = architect/reviewer"
  echo "- Claude Code = implementation executor"
  echo "- Codex = setup/audit/secondary executor"
  echo "- Keep ScratchLab beta/App Store safety constraints in mind"
  echo
  echo "----- AI_HANDOFF.md -----"
  cat "$HANDOFF"
} | pbcopy

echo "Copied ChatGPT-ready handoff prompt to clipboard."
echo "Opening ChatGPT..."
open "https://chatgpt.com/"
