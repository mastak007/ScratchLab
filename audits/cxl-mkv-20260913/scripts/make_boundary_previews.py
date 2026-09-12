#!/usr/bin/env python3
"""Boundary previews for operator audition.

No automatic test can prove the absence of speech, so every technique gets short
previews around the trim boundaries carrying the mixed track (where narration lives)
and, when available, the isolated-scratch track. Operator audition stays PENDING until
a person confirms.

Usage: python3 scripts/make_boundary_previews.py <technique_key>
"""
import json, subprocess, sys
from pathlib import Path
EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
key = sys.argv[1]
R = json.load(open(EV / "techniques" / f"{key}.json"))
ch2 = R["chapter2"]
ang = R["angle_to_title"]
t = ang.get("3") or ang.get("1") or R["distinct_titles"][0]
nA = R["audio"]["n_streams"]
out = EV / "previews" / key; out.mkdir(parents=True, exist_ok=True)
CS = ("setparams=field_mode=prog:range=tv:color_primaries=smpte170m:"
      "color_trc=smpte170m:colorspace=smpte170m")
FR = 30000 / 1001

def clip(name, t0, t1):
    f0, f1 = int(round(t0 / (1001/30000))), int(round(t1 / (1001/30000)))
    amaps, afilters, labels = [], [], []
    for i in range(min(nA, 2)):
        labels.append(f"[a{i}]")
        afilters.append(f"[0:a:{i}]atrim=start_sample={int(round(t0*48000))}:"
                        f"end_sample={int(round(t1*48000))},asetpts=PTS-STARTPTS[a{i}]")
    fc = (f"[0:v]trim=start_frame={f0}:end_frame={f1},setpts=PTS-STARTPTS,"
          f"bwdif=mode=send_frame:parity=bff:deint=all,{CS}[v];" + ";".join(afilters))
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(SRC / f"{t}.mkv"),
           "-filter_complex", fc, "-map", "[v]"]
    for l in labels: cmd += ["-map", l]
    cmd += ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-fps_mode", "cfr", "-r", "30000/1001", "-video_track_timescale", "30000",
            "-c:a", "pcm_s16le",
            "-metadata:s:a:0", "title=0:a:0 (mixed - narration lives here)"]
    if len(labels) > 1:
        cmd += ["-metadata:s:a:1", "title=0:a:1 (isolated scratch)"]
    dst = out / name
    cmd.append(str(dst))
    subprocess.run(cmd, check=True)
    return dst

made = []
head0 = max(0.0, ch2[0] - 12.0)
made.append(clip(f"{key}_boundary_head_{head0:.0f}to{ch2[0]+5:.0f}s_{t}.mov", head0, ch2[0] + 5.0))
tail1 = min(ch2[1], 83.4)
made.append(clip(f"{key}_boundary_tail_{tail1-10:.0f}to{tail1:.0f}s_{t}.mov", tail1 - 10.0, tail1))
info = {"technique": key, "source_title": t, "chapter2": ch2,
        "previews": [str(p.relative_to(EV)) for p in made],
        "time_mapping": "preview t=0 corresponds to the source time in the filename",
        "operator_audition": "PENDING - no automatic test can prove absence of speech"}
(out / "README.json").write_text(json.dumps(info, indent=2))
print(json.dumps(info, indent=2))
