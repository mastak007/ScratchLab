#!/usr/bin/env zsh
# Extract per-frame PNGs and a per-frame PTS sidecar from Karl's owned
# baby-scratch demo video into the local-only fixture workspace.
#
# Required env:
#   BABY_PLATTER_VIDEO_PATH   absolute path to the .mov (kept outside the repo)
# Optional env:
#   BABY_PLATTER_WORK_DIR     default .scratch_fixture_work/baby_platter
#
# Writes:
#   $WORK/frames/frame_%06d.png        one PNG per source frame (1-indexed)
#   $WORK/frames/timestamps.csv        one PTS (seconds) per line, frame_NNNNNN
#
# Safety:
#   - Never copies the .mov into the repo. Workspace dir is gitignored.
#   - Native source cadence preserved via -fps_mode passthrough.
#
# Re-runnable: -y overwrites; deletes timestamps.csv first to avoid append.

set -euo pipefail
# Let unmatched globs expand to nothing instead of erroring (zsh default is nomatch).
setopt NULL_GLOB

: "${BABY_PLATTER_VIDEO_PATH:?set BABY_PLATTER_VIDEO_PATH to the .mov path}"

if [[ ! -f "$BABY_PLATTER_VIDEO_PATH" ]]; then
    print -u2 -- "error: BABY_PLATTER_VIDEO_PATH does not point at a file: $BABY_PLATTER_VIDEO_PATH"
    exit 2
fi

WORK="${BABY_PLATTER_WORK_DIR:-.scratch_fixture_work/baby_platter}"
mkdir -p "$WORK/frames"

# Wipe previous frame set so a re-run with a different stride or video does not
# leave stale PNGs lying around.
rm -f "$WORK/frames/frame_"*.png "$WORK/frames/timestamps.csv"

ffmpeg -hide_banner -loglevel error -y \
    -i "$BABY_PLATTER_VIDEO_PATH" \
    -fps_mode passthrough \
    "$WORK/frames/frame_%06d.png"

ffprobe -v error -select_streams v:0 -of csv=p=0 \
    -show_entries frame=pts_time \
    "$BABY_PLATTER_VIDEO_PATH" > "$WORK/frames/timestamps.csv"

frame_count=$(ls "$WORK/frames/" | grep -c '^frame_[0-9]\{6\}\.png$' || true)
ts_count=$(wc -l < "$WORK/frames/timestamps.csv" | tr -d ' ')

print -- "extract_frames.sh: $frame_count frames, $ts_count timestamps -> $WORK/frames/"
if [[ "$frame_count" != "$ts_count" ]]; then
    print -u2 -- "warning: frame count ($frame_count) != timestamp count ($ts_count); investigate before clicking"
    exit 3
fi
