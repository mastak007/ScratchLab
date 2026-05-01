#!/bin/zsh
set -euo pipefail

APP_NAME="ScratchLab"
OUTPUT_DIR="build/app-review-mac-screenshots/final"

typeset -a SHOT_ORDER
SHOT_ORDER=(
  "01-session-workspace"
  "02-new-session-selected"
  "03-ready-to-record-and-metadata"
  "06-recording-in-progress"
  "07-captured-result-or-export-ready"
  "04-stage-and-audio-routing"
  "05-empty-state"
)

usage() {
  cat <<USAGE
Usage:
  $0 <output-path> [app-name]
  $0 --shot <shot-id-or-filename> [--output-dir <dir>] [--app-name <name>]
  $0 --all [--output-dir <dir>] [--app-name <name>]
  $0 --list

Deterministic final App Store order:
  01-session-workspace.png
  02-new-session-selected.png
  03-ready-to-record-and-metadata.png
  06-recording-in-progress.png
  07-captured-result-or-export-ready.png
  04-stage-and-audio-routing.png
  05-empty-state.png

Manual state requirements:
  06: Start a real Routine Capture recording and capture while "Stop Recording" or "Recording" is visible.
  07: Stop the real recording, or run ./scripts/seed_review_demo_data.sh and relaunch so a completed local routine capture is loaded.
  05: Use a clean install / no draft store, then capture the first-launch empty state last.

No-decks review capture for 04 and 06:
  No decks required. Place laptop/keyboard/notebook/phone under the guide boxes, tilt camera down, reduce ceiling, then press Enter.
USAGE
}

normalize_shot_id() {
  local shot="$1"
  shot="${shot:t}"
  shot="${shot:r}"
  case "${shot}" in
    01|1) echo "01-session-workspace" ;;
    02|2) echo "02-new-session-selected" ;;
    03|3) echo "03-ready-to-record-and-metadata" ;;
    04|4) echo "04-stage-and-audio-routing" ;;
    05|5) echo "05-empty-state" ;;
    06|6) echo "06-recording-in-progress" ;;
    07|7) echo "07-captured-result-or-export-ready" ;;
    01-session-workspace|02-new-session-selected|03-ready-to-record-and-metadata|04-stage-and-audio-routing|05-empty-state|06-recording-in-progress|07-captured-result-or-export-ready)
      echo "${shot}"
      ;;
    *)
      echo "Unknown screenshot id: $1" >&2
      exit 64
      ;;
  esac
}

shot_instruction() {
  case "$1" in
    01-session-workspace)
      echo "Open Routine Capture with seeded Demo DJ session selected and the session list/editor visible."
      ;;
    02-new-session-selected)
      echo "Click New Session once and confirm the new draft is selected."
      ;;
    03-ready-to-record-and-metadata)
      echo "Select the Demo DJ / Baby Scratch / 90 BPM session, keep Start Recording plus metadata visible, and avoid sidebar scroll ambiguity."
      ;;
    04-stage-and-audio-routing)
      echo "Show the deck/camera stage with guide overlay, plus only routing controls that support the recording workflow. No decks required; use visible desk objects under the guide boxes."
      ;;
    05-empty-state)
      echo "Use a clean install / no draft store and show the first-launch empty state. Capture this last in the App Store sequence."
      ;;
    06-recording-in-progress)
      echo "Start a real Routine Capture recording and capture while the app visibly shows Recording or Stop Recording. No decks required; use visible desk objects under the guide boxes."
      ;;
    07-captured-result-or-export-ready)
      echo "Stop the recording, or use seeded completed capture data, and show the completed take plus Save ZIP / Share Session area."
      ;;
  esac
}

requires_review_framing_confirmation() {
  case "$1" in
    04-stage-and-audio-routing|06-recording-in-progress)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

confirm_review_framing_if_needed() {
  local shot_id="$1"

  if ! requires_review_framing_confirmation "${shot_id}"; then
    return 0
  fi

  echo ""
  echo "No decks required. Place laptop/keyboard/notebook/phone under the guide boxes, tilt camera down, reduce ceiling, then press Enter."
  echo "Align Left Deck, Mixer, and Right Deck boxes over visible desk objects or desk zones."
  echo "Keep ceiling/bright light under 20% of the camera frame."

  if [[ -t 0 ]]; then
    read -r
    return 0
  fi

  echo "Refusing to capture ${shot_id}.png without interactive framing confirmation." >&2
  echo "Run this command from a terminal so the camera framing can be checked before capture." >&2
  exit 1
}

find_window_id() {
  local app_name="$1"
  /usr/bin/swift -e '
import CoreGraphics
import Foundation

let targetAppName = CommandLine.arguments[1]
let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

let candidateWindows = windowList.filter { entry in
    let ownerName = entry[kCGWindowOwnerName as String] as? String
    let layer = entry[kCGWindowLayer as String] as? Int ?? 0
    let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
    let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return ownerName == targetAppName && layer == 0 && alpha > 0 && width >= 600 && height >= 400
}

guard let targetWindow = candidateWindows.max(by: { lhs, rhs in
    let lhsBounds = lhs[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let rhsBounds = rhs[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let lhsArea = (lhsBounds["Width"] as? Double ?? 0) * (lhsBounds["Height"] as? Double ?? 0)
    let rhsArea = (rhsBounds["Width"] as? Double ?? 0) * (rhsBounds["Height"] as? Double ?? 0)
    return lhsArea < rhsArea
}) else {
    fputs("No on-screen \(targetAppName) window was found. Launch the app and keep its main window visible.\n", stderr)
    exit(1)
}

guard let windowNumber = targetWindow[kCGWindowNumber as String] as? Int else {
    fputs("\(targetAppName) window has no window number.\n", stderr)
    exit(1)
}

print(windowNumber)
' "${app_name}"
}

validate_png() {
  local image_path="$1"

  if [[ ! -s "${image_path}" ]]; then
    echo "Capture failed: ${image_path} is empty." >&2
    return 1
  fi

  local metadata
  metadata=$(/usr/bin/sips -g pixelWidth -g pixelHeight "${image_path}" 2>/dev/null) || {
    echo "Capture failed: ${image_path} is not a readable image." >&2
    return 1
  }

  local width height
  width=$(printf "%s\n" "${metadata}" | /usr/bin/awk '/pixelWidth/ { print $2 }')
  height=$(printf "%s\n" "${metadata}" | /usr/bin/awk '/pixelHeight/ { print $2 }')

  if [[ -z "${width}" || -z "${height}" || "${width}" -lt 600 || "${height}" -lt 400 ]]; then
    echo "Capture failed: ${image_path} has invalid dimensions ${width}x${height}." >&2
    return 1
  fi
}

capture_window_to_path() {
  local output_path="$1"
  local app_name="$2"
  local output_dir="${output_path:h}"
  local temp_path="${output_path}.tmp.$$"

  /bin/mkdir -p "${output_dir}"

  /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "${app_name}"
  activate
end tell
APPLESCRIPT

  /bin/sleep 0.5

  local window_id
  window_id=$(find_window_id "${app_name}")

  /usr/sbin/screencapture -o -l "${window_id}" "${temp_path}"
  validate_png "${temp_path}"
  /bin/mv "${temp_path}" "${output_path}"

  echo "Captured ${app_name} window to ${output_path}"
}

capture_shot() {
  local shot_id="$1"
  local output_dir="$2"
  local app_name="$3"
  local normalized
  normalized=$(normalize_shot_id "${shot_id}")

  confirm_review_framing_if_needed "${normalized}"
  capture_window_to_path "${output_dir}/${normalized}.png" "${app_name}"
}

capture_all() {
  local output_dir="$1"
  local app_name="$2"

  for shot_id in "${SHOT_ORDER[@]}"; do
    echo ""
    echo "Prepare ${shot_id}.png:"
    shot_instruction "${shot_id}"
    if requires_review_framing_confirmation "${shot_id}"; then
      capture_shot "${shot_id}" "${output_dir}" "${app_name}"
      continue
    elif [[ -t 0 ]]; then
      echo "Press Return to capture ${shot_id}.png."
      read -r
    else
      echo "Non-interactive input detected; capturing current app state for ${shot_id}.png."
    fi
    capture_shot "${shot_id}" "${output_dir}" "${app_name}"
  done
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

if [[ "$1" != --* ]]; then
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 64
  fi
  capture_window_to_path "$1" "${2:-${APP_NAME}}"
  exit 0
fi

mode=""
shot_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      mode="all"
      shift
      ;;
    --shot)
      mode="shot"
      shot_id="${2:-}"
      if [[ -z "${shot_id}" ]]; then
        echo "--shot requires a screenshot id or filename." >&2
        exit 64
      fi
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      if [[ -z "${OUTPUT_DIR}" ]]; then
        echo "--output-dir requires a directory." >&2
        exit 64
      fi
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      if [[ -z "${APP_NAME}" ]]; then
        echo "--app-name requires an app name." >&2
        exit 64
      fi
      shift 2
      ;;
    --list)
      printf "%s.png\n" "${SHOT_ORDER[@]}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "${mode}" in
  all)
    capture_all "${OUTPUT_DIR}" "${APP_NAME}"
    ;;
  shot)
    capture_shot "${shot_id}" "${OUTPUT_DIR}" "${APP_NAME}"
    ;;
  *)
    echo "Choose --shot or --all." >&2
    usage >&2
    exit 64
    ;;
esac
