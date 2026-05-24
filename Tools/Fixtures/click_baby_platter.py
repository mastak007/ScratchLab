#!/usr/bin/env python3
"""Manual platter-marker click tool for ScratchLab fixture generation.

LOCAL-ONLY tool — does not touch app code, schema, or bundle resources. Reads
PNG frames + PTS sidecar produced by Tools/Fixtures/extract_frames.sh and
writes two artifacts under the work dir:

    axis.json     {"axis_start": [x, y], "axis_end": [x, y],
                   "image_width": W, "image_height": H,
                   "stride": N, "video": <path>, "axis_frame": 1}
    clicks.csv    one row per clicked frame, source-image pixel coords:
                  # frame_index,x,y   (1-indexed)
                  4,1923.500,1102.250
                  7,1937.000,1093.000
                  ...

Two phases:

  1. Axis setup. The first frame is displayed; click two points along the
     platter motion axis. The axis locks and is written to axis.json.
  2. Click loop. The tool walks frames at stride N (default 3) — i.e. frame
     1, 4, 7, … — and you click the visible marker on each visited frame.
     Hotkeys:
         Mouse LMB  record marker for this frame
         n / Right  next visited frame (no click; leaves a gap)
         p / Left   previous visited frame
         u          undo the current frame's click
         s          skip (same as n)
         q / Esc    save and quit (autosave happens on every click too)

Resume: if axis.json + clicks.csv already exist when you launch, the tool
keeps both and resumes at the first unclicked visited frame.

Display: source frames are downscaled to fit a ~1200 px box; clicks are
remapped back to source-pixel space before saving, so saved coords are
always in the native image's coordinate system.

Per ScratchLab/PROFILE.md, the priority for what to click is:
    1. visible platter sticker / marker
    2. visible high-contrast vinyl point
    3. platter edge point
    4. hand center (fallback only)
Pick one target and keep it consistent across the whole take.
"""

import argparse
import csv
import json
import math
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageTk
except ImportError:
    sys.exit(
        "click_baby_platter.py requires Pillow. Install with:\n"
        "    python3 -m pip install --user Pillow"
    )

import tkinter as tk
from tkinter import ttk

# Pillow ≥ 9.1 exposes Resampling; older releases keep the bare constant.
try:
    _RESAMPLE_BILINEAR = Image.Resampling.BILINEAR  # type: ignore[attr-defined]
except AttributeError:
    _RESAMPLE_BILINEAR = Image.BILINEAR  # type: ignore[attr-defined]


def load_timestamps(ts_path: Path) -> list:
    """Read ffprobe pts_time CSV; tolerate the trailing-comma artifact."""
    out = []
    with ts_path.open() as f:
        for line in f:
            s = line.strip().split(",")[0].strip()
            if s:
                out.append(float(s))
    return out


def list_frame_paths(frames_dir: Path) -> list:
    return sorted(
        p for p in frames_dir.iterdir()
        if p.name.startswith("frame_") and p.suffix == ".png"
    )


def load_clicks_csv(path: Path) -> dict:
    if not path.exists():
        return {}
    out = {}
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


def save_clicks_csv(path: Path, clicks: dict) -> None:
    with path.open("w") as f:
        f.write("# frame_index,x,y   (1-indexed; coords in source-image pixels)\n")
        for idx in sorted(clicks):
            x, y = clicks[idx]
            f.write(f"{idx},{x:.3f},{y:.3f}\n")


class App:
    DISPLAY_BOX = 1200  # max(disp_w, disp_h) target in logical pixels
    MIN_AXIS_PX = 20.0  # min separation between the two axis-setup clicks, in source pixels

    def __init__(self, root, frames_dir, timestamps, work_dir, stride, video_path):
        self.root = root
        self.frames = list_frame_paths(frames_dir)
        self.timestamps = timestamps
        self.work_dir = work_dir
        self.stride = stride
        self.video_path = video_path

        if not self.frames:
            sys.exit(f"no frames in {frames_dir}; run extract_frames.sh first")

        self.axis_path = work_dir / "axis.json"
        self.clicks_path = work_dir / "clicks.csv"
        self.clicks = load_clicks_csv(self.clicks_path)
        self.axis = self._load_axis()

        # Visited frame indices, 1-indexed to match ffmpeg's frame numbering.
        self.visit_indices = list(range(1, len(self.frames) + 1, stride))
        self.cursor = 0

        # Display scale based on source image dims (read once from frame 1).
        with Image.open(self.frames[0]) as im:
            self.image_w, self.image_h = im.size
        self.display_scale = min(1.0, self.DISPLAY_BOX / max(self.image_w, self.image_h))
        self.disp_w = int(round(self.image_w * self.display_scale))
        self.disp_h = int(round(self.image_h * self.display_scale))

        # Tk layout.
        self.root.title("baby_platter click tool")
        self.canvas = tk.Canvas(
            root, width=self.disp_w, height=self.disp_h,
            bg="black", cursor="crosshair", highlightthickness=0,
        )
        self.canvas.pack(side="top")
        self.status = ttk.Label(root, anchor="w")
        self.status.pack(side="top", fill="x")
        ttk.Label(
            root, anchor="w",
            text=("LMB click marker | n / →  next  | p / ←  prev  | "
                  "u  undo | s  skip | q / Esc  save & quit"),
        ).pack(side="top", fill="x")

        self._photo = None  # keep a reference so Tk doesn't gc the image
        self.canvas.bind("<Button-1>", self.on_click)
        for key in ("<Escape>", "q", "Q"):
            root.bind(key, lambda _e: self.quit_save())
        for key in ("n", "N", "<Right>", "s", "S"):
            root.bind(key, lambda _e: self.advance(+1))
        for key in ("p", "P", "<Left>"):
            root.bind(key, lambda _e: self.advance(-1))
        for key in ("u", "U"):
            root.bind(key, lambda _e: self.undo())
        root.protocol("WM_DELETE_WINDOW", self.quit_save)

        if self.axis is None:
            self.setup_axis_phase()
        else:
            # Resume to first unclicked visited frame, else last visited.
            self.cursor = self._first_unclicked_cursor()
            self.render_current()

    # ---- axis setup ----

    def _load_axis(self):
        if not self.axis_path.exists():
            return None
        try:
            axis = json.loads(self.axis_path.read_text())
        except (ValueError, OSError):
            return None
        # Discard a degenerate saved axis so the user is forced back through
        # axis setup instead of silently reusing a bad axis on every relaunch.
        a0 = axis.get("axis_start")
        a1 = axis.get("axis_end")
        if (isinstance(a0, list) and isinstance(a1, list)
                and len(a0) == 2 and len(a1) == 2):
            sep = math.hypot(a1[0] - a0[0], a1[1] - a0[1])
            if sep < self.MIN_AXIS_PX:
                print(
                    f"info: saved axis is degenerate (|Δ| = {sep:.2f} px "
                    f"< {self.MIN_AXIS_PX:.0f}); re-entering axis setup. "
                    f"clicks.csv is preserved.",
                    file=sys.stderr,
                )
                return None
        return axis

    def setup_axis_phase(self):
        self.axis_pts = []
        self.status.config(
            text="AXIS SETUP — click two points along the platter motion axis."
        )
        self._load_frame(self.frames[0])
        # Override the click handler for the setup phase.
        self.canvas.bind("<Button-1>", self.on_axis_click)

    def on_axis_click(self, event):
        x = event.x / self.display_scale
        y = event.y / self.display_scale
        # Min-distance guard: if a first axis point exists and this new click
        # is within MIN_AXIS_PX of it (in source pixels), reject the click
        # and keep waiting for a real second point. Prevents the
        # degenerate-axis trap where two same-pixel clicks lock a zero-length
        # axis (observed 2026-05-24).
        if len(self.axis_pts) == 1:
            x0, y0 = self.axis_pts[0]
            sep = math.hypot(x - x0, y - y0)
            if sep < self.MIN_AXIS_PX:
                self.status.config(text=(
                    f"AXIS SETUP — rejected: second click too close to first "
                    f"({sep:.1f} < {self.MIN_AXIS_PX:.0f} source px). "
                    f"Click further along the motion axis."
                ))
                return
        self.axis_pts.append((x, y))
        self.canvas.create_oval(
            event.x - 4, event.y - 4, event.x + 4, event.y + 4,
            outline="yellow", width=2,
        )
        if len(self.axis_pts) == 2:
            self.axis = {
                "axis_start": list(self.axis_pts[0]),
                "axis_end":   list(self.axis_pts[1]),
                "image_width":  self.image_w,
                "image_height": self.image_h,
                "stride":       self.stride,
                "video":        str(self.video_path),
                "axis_frame":   1,
            }
            self.axis_path.write_text(json.dumps(self.axis, indent=2) + "\n")
            self.status.config(text=f"axis locked → {self.axis_path}")
            self.canvas.bind("<Button-1>", self.on_click)
            # Jump to the first unclicked visited frame so existing click work
            # is preserved when redoing axis setup with clicks.csv already on disk.
            self.cursor = self._first_unclicked_cursor()
            self.render_current()

    def _first_unclicked_cursor(self) -> int:
        """Return index into visit_indices of the first frame that has no
        recorded click, or the last cursor position if all are clicked."""
        for i, fi in enumerate(self.visit_indices):
            if fi not in self.clicks:
                return i
        return len(self.visit_indices) - 1

    # ---- click loop ----

    def render_current(self):
        if not (0 <= self.cursor < len(self.visit_indices)):
            self.status.config(text="end of visit list reached. q to save & quit.")
            return
        fi = self.visit_indices[self.cursor]
        self._load_frame(self.frames[fi - 1])
        self._draw_axis()
        self._draw_existing_click_marker(fi)
        clicked = "✓" if fi in self.clicks else "·"
        t = self.timestamps[fi - 1] if 0 <= fi - 1 < len(self.timestamps) else float("nan")
        self.status.config(text=(
            f"frame {fi:6d}  t={t:7.3f}s  {clicked}  "
            f"(visit {self.cursor + 1}/{len(self.visit_indices)}, "
            f"{len(self.clicks)} clicks recorded)"
        ))

    def _draw_axis(self):
        if not self.axis:
            return
        x0, y0 = self.axis["axis_start"]
        x1, y1 = self.axis["axis_end"]
        s = self.display_scale
        self.canvas.create_line(
            x0 * s, y0 * s, x1 * s, y1 * s,
            fill="yellow", width=2, dash=(4, 4),
        )

    def _draw_existing_click_marker(self, fi):
        if fi in self.clicks:
            x, y = self.clicks[fi]
            s = self.display_scale
            self.canvas.create_oval(
                x * s - 6, y * s - 6, x * s + 6, y * s + 6,
                outline="lime", width=2,
            )

    def on_click(self, event):
        if not (0 <= self.cursor < len(self.visit_indices)):
            return
        fi = self.visit_indices[self.cursor]
        x = event.x / self.display_scale
        y = event.y / self.display_scale
        self.clicks[fi] = (x, y)
        save_clicks_csv(self.clicks_path, self.clicks)  # autosave
        self.advance(+1)

    def undo(self):
        if not (0 <= self.cursor < len(self.visit_indices)):
            return
        fi = self.visit_indices[self.cursor]
        if fi in self.clicks:
            del self.clicks[fi]
            save_clicks_csv(self.clicks_path, self.clicks)
            self.render_current()

    def advance(self, delta):
        self.cursor = max(0, min(len(self.visit_indices) - 1, self.cursor + delta))
        self.render_current()

    def quit_save(self):
        save_clicks_csv(self.clicks_path, self.clicks)
        self.root.destroy()

    # ---- frame I/O ----

    def _load_frame(self, png_path: Path):
        im = Image.open(png_path)
        if self.display_scale < 1.0:
            im = im.resize((self.disp_w, self.disp_h), _RESAMPLE_BILINEAR)
        self._photo = ImageTk.PhotoImage(im)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self._photo)


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
        "--stride", type=int, default=3,
        help="visit every Nth frame; default 3",
    )
    args = ap.parse_args()

    if args.stride < 1:
        sys.exit("--stride must be ≥ 1")

    work_dir = Path(args.work)
    frames_dir = work_dir / "frames"
    ts_path = frames_dir / "timestamps.csv"
    if not frames_dir.is_dir() or not ts_path.exists():
        sys.exit(f"frames not found at {frames_dir}; run extract_frames.sh first")

    timestamps = load_timestamps(ts_path)
    video_path = os.environ.get("BABY_PLATTER_VIDEO_PATH", "")

    root = tk.Tk()
    App(root, frames_dir, timestamps, work_dir, args.stride, video_path)
    root.mainloop()


if __name__ == "__main__":
    main()
