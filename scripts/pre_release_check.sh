#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required_files=(
  "docs/release_audit_checklist.md"
  "docs/codex_release_audit_prompt.md"
  "DEV_LOG.md"
  "TASKS.md"
)

echo "==> Verifying release-audit repo files"
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done

echo "==> Running repository build validation"
"$ROOT_DIR/scripts/build.sh"

cat <<'EOF'
==> Manual smoke-test reminders
- iPhone SE / small iPhone: confirm all guided-capture and setup screens fit without clipped actions.
- Standard iPhone: confirm normal navigation, layout, and control reachability.
- iOS System Check screen: confirm every action remains visible and reachable.
- iOS back/navigation controls: confirm ScratchLab UI does not cover native navigation areas.
- macOS small window: confirm core controls remain visible without broken layouts.
- watchOS launch: confirm the watch app launches cleanly and shows the expected branding/state.
- Practice beat controls: confirm iOS/macOS practice beat controls remain visible and functional.
- Record/export flow: confirm the intended record, review, validation, and export paths still work.
- App Review screenshots: confirm the current screenshots still match the shipped UI and capture guidance.

==> Guardrails
- This script does not upload anything to TestFlight or App Store Connect.
- This script must not modify app code.
- This script must not change bundle IDs, schemes, targets, or App Store Connect metadata.
- Review docs/release_audit_checklist.md before submission and record remaining risks in DEV_LOG.md.
EOF
