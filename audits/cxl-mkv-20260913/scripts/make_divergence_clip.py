#!/usr/bin/env python3
"""Render both passes of a detected divergence span so a person can compare them.

Reads <key>.repeat-profile.json and, for each divergent span, writes two clips from
the same camera: the first-pass window and its second-pass counterpart. Neither is
labelled correct - that is the whole point of the review.

Usage: python3 scripts/make_divergence_clip.py <technique_key> [--pad 2.0]
"""
import argparse, json, subprocess
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
FRAME_S = 1001 / 30000; SR = 48000
CS = ("setparams=field_mode=prog:range=tv:color_primaries=smpte170m:"
      "color_trc=smpte170m:colorspace=smpte170m")

ap = argparse.ArgumentParser()
ap.add_argument("key"); ap.add_argument("--pad", type=float, default=2.0)
a = ap.parse_args()

P = json.loads((EV / "techniques" / f"{a.key}.repeat-profile.json").read_text())
if not P.get("divergence_detected"):
    print(f"{a.key}: no divergence detected; nothing to render"); raise SystemExit(0)
R = json.loads((EV / "techniques" / f"{a.key}.json").read_text())
ang = R["angle_to_title"]
title = ang.get("3") or ang.get("1") or R["distinct_titles"][0]
nA = R["audio"]["n_streams"]
out = EV / "previews" / a.key; out.mkdir(parents=True, exist_ok=True)
made = []

def clip(name, t0, t1):
    f0, f1 = int(round(t0 / FRAME_S)), int(round(t1 / FRAME_S))
    s0, s1 = int(round(t0 * SR)), int(round(t1 * SR))
    af, maps = [], []
    for i in range(min(nA, 2)):
        af.append(f"[0:a:{i}]atrim=start_sample={s0}:end_sample={s1},asetpts=PTS-STARTPTS[a{i}]")
        maps.append(f"[a{i}]")
    fc = (f"[0:v]trim=start_frame={f0}:end_frame={f1},setpts=PTS-STARTPTS,"
          f"bwdif=mode=send_frame:parity=bff:deint=all,{CS}[v];" + ";".join(af))
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(SRC / f"{title}.mkv"),
           "-filter_complex", fc, "-map", "[v]"] + sum([["-map", m] for m in maps], []) + [
           "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
           "-fps_mode", "cfr", "-r", "30000/1001", "-video_track_timescale", "30000",
           "-c:a", "pcm_s16le", "-metadata:s:a:0", "title=0:a:0 mixed"]
    if len(maps) > 1: cmd += ["-metadata:s:a:1", "title=0:a:1 isolated scratch"]
    cmd.append(str(out / name))
    subprocess.run(cmd, check=True)
    return name

for n, ((a0, b0), (a1, b1)) in enumerate(zip(P["divergence_spans_first_pass_s"],
                                             P["divergence_spans_second_pass_s"]), 1):
    made.append(clip(f"{a.key}_DIVERGENCE{n}_pass1_{a0-a.pad:.1f}to{b0+a.pad:.1f}s_{title}.mov",
                     max(0, a0 - a.pad), b0 + a.pad))
    made.append(clip(f"{a.key}_DIVERGENCE{n}_pass2_{a1-a.pad:.1f}to{b1+a.pad:.1f}s_{title}.mov",
                     max(0, a1 - a.pad), b1 + a.pad))
print(f"{a.key}: rendered {len(made)} clips from {title}")
for m in made: print("  ", m)
