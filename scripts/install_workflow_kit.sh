#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/Users/karlwatson/Downloads/ScratchLab}"
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$ROOT/scripts" "$ROOT/prompts"

cp "$KIT_DIR/CLAUDE_WORKFLOW.md" "$ROOT/CLAUDE_WORKFLOW.md"
cp "$KIT_DIR/scripts/"*.sh "$ROOT/scripts/"
cp "$KIT_DIR/prompts/"*.md "$ROOT/prompts/"

chmod +x "$ROOT/scripts/"*.sh

echo "Installed ScratchLab Claude workflow kit into:"
echo "$ROOT"
echo
echo "Files:"
echo "- CLAUDE_WORKFLOW.md"
echo "- scripts/verify_clean_tree.sh"
echo "- scripts/verify_mac_ui_slice.sh"
echo "- scripts/verify_full_app_builds.sh"
echo "- scripts/verify_review_copy.sh"
echo "- scripts/verify_fixture_loader.sh"
echo "- scripts/verify_review_motion_samples.sh"
echo "- scripts/make_worktree.sh"
echo "- prompts/*.md"
