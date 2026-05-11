#!/usr/bin/env zsh
set -euo pipefail

scripts/ai/send_handoff_to_chatgpt.zsh "${1:-AI_HANDOFF.md}"

echo "Waiting for ChatGPT to open..."
sleep 3

osascript <<'OSA'
tell application "System Events"
  keystroke "v" using command down
end tell
OSA

echo "Pasted handoff into ChatGPT. Review before sending."
