#!/usr/bin/env python3
"""Stage A2: bind each delivered camera angle to a source title by content.

For every technique, each delivered <tech>_<bpm>bpm_angle_N_take01.mp4 is matched
against all candidate titles in its group by zero-mean cross-correlation over a run
of consecutive frames, searched across frame offsets.  A single sampled still is not
enough; this uses a temporal sequence.

Resumable: results are written per technique into inventory/angle-binding.json and
existing entries are skipped.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np

EV = Path(__file__).resolve().parent.parent
SRC = Path("/Volumes/Untitled/CXLrip")
DS = Path("/Users/karlwatson/Movies/PRO DJ DATASET/dataset")
OUTP = EV / "inventory" / "angle-binding.json"
CACHE = Path(os.environ.get("BATCH_SCRATCH", "/tmp/cxl-batch")) / "gray"
CACHE.mkdir(parents=True, exist_ok=True)
W, H = 180, 120
NF_MAX = 150                   # frames compared, 5 s; reduced if a delivered clip is shorter

def atomic(path, text):
    fd, tmp = tempfile.mkstemp(dir=str(Path(path).parent), prefix=".tmp-")
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(tmp, path)

def gray(args, dst):
    dst = CACHE / dst
    if not dst.exists() or dst.stat().st_size == 0:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", *args,
                        "-vf", f"scale={W}:{H}:flags=bicubic,format=gray",
                        "-fps_mode", "passthrough", "-f", "rawvideo", str(dst)], check=True)
    a = np.fromfile(dst, dtype=np.uint8)
    return a.reshape(-1, H, W).astype(np.float32) if a.size else np.zeros((0, H, W), np.float32)

def zn(a, b):
    a = a.reshape(len(a), -1); b = b.reshape(len(b), -1)
    a = a - a.mean(1, keepdims=True); b = b - b.mean(1, keepdims=True)
    return float(np.mean((a*b).sum(1)/(np.linalg.norm(a,axis=1)*np.linalg.norm(b,axis=1)+1e-9)))

groups = json.load(open(EV / "inventory" / "stage-a-groups.json"))
res = json.loads(OUTP.read_text()) if OUTP.exists() else {}

tasks = []
for gid, g in groups["groups"].items():
    for name in g["edit_list_candidates"]:
        e = groups["edit_lists"][name]
        cands = g["titles"]
        if len(g["audio_equality_classes"]) > 1:
            # the group holds two techniques; candidates are resolved later per class
            cands = g["titles"]
        tasks.append((name, e, cands))

for name, e, cands in tasks:
    if name in res: 
        continue
    tech, bpm = e["scratch"], e["bpm"]
    start = e["keeps"][0][0] if e["keeps"] else e["chapter2"][0]
    row = {"technique": tech, "bpm": bpm, "export_start_s": start,
           "candidate_titles": cands, "angles": {}, "audio_equality_classes": None}
    # size the comparison window to the shortest delivered clip in this technique
    avail = []
    for a in "1234":
        mp4 = DS / "video" / tech / f"{tech}_{bpm}bpm_angle_{a}_take01.mp4"
        if mp4.exists():
            avail.append(len(gray(["-i", str(mp4), "-frames:v", str(NF_MAX + 4)], f"{tech}-a{a}.gray")))
    NF = max(30, min(avail) - 4) if avail else NF_MAX
    row["frames_compared"] = NF
    srcs = {}
    for t in cands:
        srcs[t] = gray(["-ss", f"{max(0, start-0.30):.3f}", "-i", str(SRC / f"{t}.mkv"),
                        "-map", "0:v:0", "-frames:v", str(NF + 18)], f"{t}-{start:.3f}.gray")
    for a in "1234":
        mp4 = DS / "video" / tech / f"{tech}_{bpm}bpm_angle_{a}_take01.mp4"
        if not mp4.exists():
            row["angles"][a] = {"error": f"missing delivered file {mp4.name}"}
            continue
        m = gray(["-i", str(mp4), "-frames:v", str(NF_MAX + 4)], f"{tech}-a{a}.gray")
        if len(m) < NF:
            row["angles"][a] = {"error": f"only {len(m)} frames in delivered clip"}
            continue
        scores = {}
        for t, s in srcs.items():
            if len(s) < NF + 2: 
                scores[t] = {"zncc": -2.0, "offset": None}
                continue
            best = max(((zn(m[2:2+NF], s[d:d+NF]), d) for d in range(0, len(s)-NF)))
            scores[t] = {"zncc": round(best[0], 5), "offset_frames_from_seek": best[1]}
        win = max(scores, key=lambda k: scores[k]["zncc"])
        ordered = sorted((v["zncc"] for v in scores.values()), reverse=True)
        row["angles"][a] = {"title": win, "zncc": scores[win]["zncc"],
                            "margin_over_runner_up": round(ordered[0]-ordered[1], 5),
                            "all_scores": {k: v["zncc"] for k, v in scores.items()}}
    bound = [v.get("title") for v in row["angles"].values() if "title" in v]
    row["angles_resolved"] = len(bound)
    row["one_to_one"] = len(set(bound)) == len(bound) and len(bound) > 0
    row["ascending_convention"] = bound == sorted(bound)
    res[name] = row
    atomic(OUTP, json.dumps(res, indent=2))
    ok = "OK " if row["one_to_one"] else "!! "
    print(f"{ok}{name:<24} " + "  ".join(
        f"a{a}->{v.get('title','ERR').replace('Scratch_','')}({v.get('zncc','')}/m{v.get('margin_over_runner_up','')})"
        for a, v in row["angles"].items()))
