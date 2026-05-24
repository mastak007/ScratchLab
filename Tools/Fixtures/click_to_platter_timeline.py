#!/usr/bin/env python3
"""Convert manual clicks → PlatterPositionTimeline JSON fixture.

Reads three artifacts produced by extract_frames.sh + click_baby_platter.py:

    <work>/frames/timestamps.csv      ffprobe pts_time, one PTS per frame
    <work>/axis.json                  axis_start, axis_end, image dims, stride
    <work>/clicks.csv                 frame_index,x,y in source-image pixels

Writes one PlatterPositionTimeline JSON fixture (default
Tests/Fixtures/LocalOnly/baby_platter.json) whose schema exactly matches
ScratchLab/Models/PlatterPositionTimeline.swift:20-172:

    {
      "source": "coachAuthored",
      "startTime": <first sample t, seconds>,
      "endTime":   <last sample t, seconds>,
      "samples": [
        {"time": <t>, "position": <signed scalar>, "confidence": <0..1>},
        ...
      ]
    }

Math (per the approved plan):

  axis unit vector  A = (axis_end - axis_start) / |axis_end - axis_start|
  pixel projection  proj_px_i = (click_i - axis_start) · A
  normalized        position_i = proj_px_i / image_width
  confidence        1.0 for clicked frames, 0.75 for interpolated frames

Frames before the first click and after the last click are dropped, so
startTime == samples[0].time and endTime == samples[-1].time. Each frame
between the first and last clicks is emitted as either a clicked sample
(confidence 1.0) or a linearly-interpolated sample (confidence 0.75) at
its exact PTS from timestamps.csv.

Degenerate axis: if axis_start ≈ axis_end (|Δ| < 1 px) the saved axis is
unusable and this tool **exits with a non-zero status**. Re-do axis
setup in click_baby_platter.py. We deliberately do not derive an axis
from the click trajectory here: a degenerate saved axis is a setup
error, and silently papering over it would let bad fixtures land
without a human review.

LOCAL-ONLY. Does not touch app code, the export schema, the renderer,
the classifier, or bundle resources.
"""

import argparse
import csv
import json
import math
import os
import sys
from pathlib import Path


def load_timestamps(ts_path: Path) -> list:
    """Read ffprobe pts_time CSV; tolerate the trailing-comma artifact."""
    out = []
    with ts_path.open() as f:
        for line in f:
            s = line.strip().split(",")[0].strip()
            if s:
                out.append(float(s))
    return out


def load_clicks(path: Path) -> dict:
    """Return {frame_index: (x, y)} from clicks.csv."""
    out: dict = {}
    with path.open() as f:
        reader = csv.reader(f)
        for row in reader:
            if not row or row[0].startswith("#"):
                continue
            try:
                idx = int(row[0])
                x = float(row[1])
                y = float(row[2])
            except (ValueError, IndexError):
                continue
            out[idx] = (x, y)
    return out


def resolve_axis(axis_json: dict) -> tuple:
    """Return (axis_start, axis_unit_vector) from the saved axis.

    Exits with a non-zero status if the saved axis is degenerate
    (|axis_end - axis_start| < 1 px). A degenerate axis is a setup
    error in click_baby_platter.py; redo the two-point axis setup and
    retry rather than papering over it here.
    """
    a0 = tuple(axis_json["axis_start"])
    a1 = tuple(axis_json["axis_end"])
    dx, dy = a1[0] - a0[0], a1[1] - a0[1]
    mag = math.hypot(dx, dy)
    if mag < 1.0:
        sys.exit(
            f"error: saved axis is degenerate (|axis_end - axis_start| = {mag:.3f} px).\n"
            f"  axis_start: {a0}\n"
            f"  axis_end:   {a1}\n"
            f"  Re-run Tools/Fixtures/click_baby_platter.py and click two\n"
            f"  visibly-separated points during axis setup. The converter\n"
            f"  does not auto-derive an axis."
        )
    return (a0, (dx / mag, dy / mag))


def build_timeline(
    timestamps: list,
    axis_start: tuple,
    axis_unit: tuple,
    image_width: int,
    clicks: dict,
) -> dict:
    """Project clicks onto axis and emit one sample per frame in
    [first_clicked, last_clicked]. Confidence 1.0 / 0.75."""
    if not clicks:
        sys.exit("error: clicks.csv is empty")

    ax_sx, ax_sy = axis_start
    ux, uy = axis_unit

    def project(point):
        dx = point[0] - ax_sx
        dy = point[1] - ax_sy
        return (dx * ux + dy * uy) / image_width

    clicked_frames = sorted(clicks)
    positions = {fi: project(clicks[fi]) for fi in clicked_frames}
    first_fi = clicked_frames[0]
    last_fi = clicked_frames[-1]

    samples = []
    # Iterate over bracket pairs of consecutive clicked frames.
    for k in range(len(clicked_frames) - 1):
        lo_fi = clicked_frames[k]
        hi_fi = clicked_frames[k + 1]
        t_lo = timestamps[lo_fi - 1]
        t_hi = timestamps[hi_fi - 1]
        p_lo = positions[lo_fi]
        p_hi = positions[hi_fi]
        # Emit the lo clicked sample once.
        samples.append({"time": t_lo, "position": p_lo, "confidence": 1.0})
        # Interpolate each frame strictly between lo and hi.
        for fi in range(lo_fi + 1, hi_fi):
            t = timestamps[fi - 1]
            if t_hi > t_lo:
                frac = (t - t_lo) / (t_hi - t_lo)
            else:
                frac = 0.0
            samples.append({
                "time": t,
                "position": p_lo + frac * (p_hi - p_lo),
                "confidence": 0.75,
            })
    # Emit the final clicked sample.
    samples.append({
        "time": timestamps[last_fi - 1],
        "position": positions[last_fi],
        "confidence": 1.0,
    })

    return {
        "source": "coachAuthored",
        "startTime": samples[0]["time"],
        "endTime":   samples[-1]["time"],
        "samples":   samples,
    }


def write_timeline_json(path: Path, timeline: dict) -> None:
    """Write JSON matching the existing Codable schema exactly (top-level
    object keys + nested sample keys, all in property-name form: no
    remapping). Uses ensure_ascii=False so any debug strings remain
    human-readable, though no strings are emitted today."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(timeline, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--work",
        default=os.environ.get("BABY_PLATTER_WORK_DIR", ".scratch_fixture_work/baby_platter"),
        help="workspace dir (default .scratch_fixture_work/baby_platter)",
    )
    ap.add_argument(
        "--out",
        default="Tests/Fixtures/LocalOnly/baby_platter.json",
        help="output JSON path (default Tests/Fixtures/LocalOnly/baby_platter.json)",
    )
    args = ap.parse_args()

    work = Path(args.work)
    ts_path = work / "frames" / "timestamps.csv"
    axis_path = work / "axis.json"
    clicks_path = work / "clicks.csv"
    for required in (ts_path, axis_path, clicks_path):
        if not required.exists():
            sys.exit(f"error: missing {required}")

    timestamps = load_timestamps(ts_path)
    axis_json = json.loads(axis_path.read_text())
    image_width = int(axis_json["image_width"])
    clicks = load_clicks(clicks_path)

    if not clicks:
        sys.exit("error: clicks.csv has no rows")

    axis_start, axis_unit = resolve_axis(axis_json)
    timeline = build_timeline(timestamps, axis_start, axis_unit, image_width, clicks)

    out_path = Path(args.out)
    write_timeline_json(out_path, timeline)

    samples = timeline["samples"]
    n_clicked = sum(1 for s in samples if s["confidence"] == 1.0)
    n_interp = sum(1 for s in samples if s["confidence"] == 0.75)
    positions = [s["position"] for s in samples]
    print(
        f"wrote {out_path}\n"
        f"  axis_start:  ({axis_start[0]:.2f}, {axis_start[1]:.2f})\n"
        f"  axis_unit:   ({axis_unit[0]:+.4f}, {axis_unit[1]:+.4f})\n"
        f"  samples:     {len(samples)} "
        f"({n_clicked} clicked, {n_interp} interpolated)\n"
        f"  time span:   {timeline['startTime']:.3f} .. {timeline['endTime']:.3f} s\n"
        f"  position:    min {min(positions):+.6f}, max {max(positions):+.6f}, "
        f"span {max(positions) - min(positions):.6f}"
    )


if __name__ == "__main__":
    main()
